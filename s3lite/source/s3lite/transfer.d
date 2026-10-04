/// Worker-pool bulk S3 pull/push: concurrency and retry policy layered on
/// the single-shot operations of `s3lite.core`.
///
/// This module depends on the core and on `s3lite.client`'s request and
/// result types; the reverse is never true. A consumer who only wants
/// `GetObject`/`PutObject`/`ListObjectsV2` never drags in the worker-pool
/// machinery below.
///
/// It is part of the convenience layer: outcomes are delivered as whole
/// buffers (`DownloadOutcome.body_`, `UploadItem.body_`) and bookkeeping
/// uses the collector. Its transfer loops, though, use the core's streaming
/// forms, so the only object-sized memory is the one buffer the caller
/// receives or supplies:
///
///   - a chunked download writes each ranged response straight into its
///     slice of the object's buffer, as it arrives;
///   - a whole-object download fills one buffer sized from the listing;
///   - an upload is pulled from the caller's bytes by the transport.
///
/// Each object (and each chunk) works through one `S3Client`, so its retry
/// attempts reuse a connection.
///
/// Architecture (issue #367, matching s5cmd's published design):
///
///   - A global, object-level worker pool (`TransferConfig.objectWorkers`,
///     default 256, s5cmd's own default) bounds how many objects transfer
///     concurrently, on `std.parallelism.TaskPool`.
///   - A separate, bounded per-file concurrency (`TransferConfig
///     .perFileChunkConcurrency`, default 5, s5cmd's own default) bounds how
///     many byte-range chunks of *one* large object download concurrently,
///     via a second, per-object `TaskPool`. This applies to `downloadBulk`,
///     for objects above `chunkThresholdBytes`: one ranged `getObject` per
///     chunk. `uploadBulk` does not chunk a single object's upload -- the
///     package has no multipart upload yet -- so `perFileChunkConcurrency`
///     is inert for uploads.
///   - `downloadBulk`'s object list is fed by `s3lite.client.listObjectsV2`
///     page by page: each object is dispatched to the pool as its page
///     arrives, rather than after the whole listing.
///   - Bounded exponential-backoff retry (`TransferConfig.maxAttempts`,
///     default 10; `baseDelayMs`/`maxDelayMs`, default budget matching
///     s5cmd's ~1 minute) wraps every whole-object transfer and every chunk
///     fetch. Only `FailureKind.transportError` and
///     `FailureKind.malformedResponse` are retried; `notFound`, `forbidden`
///     and the rest are failures a retry cannot fix. An upload is retryable
///     because its body is in memory and can be read again.
module s3lite.transfer;

import s3lite.client;
import s3lite.core : ByteRange, PayloadHash, S3Client, SliceBody;
import s3lite.http : GetOptions, assumeNoGC;
import std.algorithm.comparison : min;
import std.exception : enforce;
import std.parallelism : task, TaskPool;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : Duration, msecs;

/// Tunable knobs for the two-level worker-pool architecture described in
/// this module's doc comment. `sleepFn`, when set, replaces the real
/// `Thread.sleep` used between retry attempts -- only ever set by this
/// package's own fixture tests, to keep bounded-retry tests fast and
/// deterministic instead of actually waiting out real backoff delays.
struct TransferConfig {
    size_t objectWorkers = 256;           // s5cmd default: cross-object parallelism
    size_t perFileChunkConcurrency = 5;   // s5cmd default: per-object chunk parallelism (downloadBulk only)
    size_t chunkThresholdBytes = 8 * 1024 * 1024; // objects at/below this size download whole, unchunked
    size_t chunkSizeBytes = 8 * 1024 * 1024;
    size_t maxAttempts = 10;              // s5cmd default
    long baseDelayMs = 100;
    long maxDelayMs = 60_000;             // ~1-minute total retry budget, matching s5cmd's documented default
    void delegate(Duration) sleepFn;      // test seam only; null => real Thread.sleep
}

/// Pure backoff-delay computation for 1-based `attempt`: `baseDelayMs *
/// 2^(attempt-1)`, capped at `maxDelayMs`. Exposed standalone so it's
/// directly unit-testable without exercising real sleeps or network calls.
long backoffDelayMs(TransferConfig cfg, size_t attempt) pure {
    if (attempt == 0) return 0;
    long delay = cfg.baseDelayMs;
    foreach (_; 1 .. attempt) {
        if (delay >= cfg.maxDelayMs) return cfg.maxDelayMs;
        delay *= 2;
    }
    return delay > cfg.maxDelayMs ? cfg.maxDelayMs : delay;
}

private bool isRetryableKind(FailureKind k) {
    return k == FailureKind.transportError || k == FailureKind.malformedResponse;
}

/// `std.parallelism.TaskPool.finish(true)` -- which both `downloadBulk` and
/// `uploadBulk` call to drain their object-level pool -- documents that it
/// "use[s] this thread as a worker until everything is finished"
/// (`executeWorkLoop()` inside `finish`). That means the calling thread
/// itself becomes an (objectWorkers+1)-th concurrent worker during drain
/// unless the pool is sized one smaller to begin with -- exactly the
/// reasoning `source/effects/crawl_orchestrator.d`'s own `new
/// TaskPool(workers - 1)` already documents and relies on. Caught here by
/// this module's own bulk fixture test (`tests/transfer_bulk_fixture.d`),
/// which observed 5 concurrent object transfers against a configured bound
/// of 4 before this helper existed.
private size_t objectPoolSize(TransferConfig cfg) pure {
    return cfg.objectWorkers - 1;
}

/// Runs `attemptFn` up to `cfg.maxAttempts` times, sleeping with bounded
/// exponential backoff between attempts, stopping early on the first
/// non-failing result or the first failure `isRetryable` says not to retry.
private T withRetry(T)(TransferConfig cfg, scope T delegate() attemptFn,
        scope bool delegate(T) isFailure, scope bool delegate(T) isRetryable) {
    T result;
    foreach (attempt; 1 .. cfg.maxAttempts + 1) {
        result = attemptFn();
        if (!isFailure(result)) return result;
        if (!isRetryable(result)) return result;
        if (attempt == cfg.maxAttempts) return result;
        auto delayMs = backoffDelayMs(cfg, attempt);
        if (cfg.sleepFn !is null) cfg.sleepFn(delayMs.msecs);
        else Thread.sleep(delayMs.msecs);
    }
    return result;
}

// ---------------------------------------------------------------------
// downloadBulk (bulk pull)
// ---------------------------------------------------------------------

struct DownloadOutcome {
    string key;
    bool ok;
    ubyte[] body_;
    S3Error error;
    size_t attempts;
}

struct DownloadBulkResult {
    size_t succeeded;
    size_t failed;
    string[] failedKeys;
    bool listingOk;
    S3Error listingError;
}

private struct ChunkResult {
    bool ok;
    bool retryable;
    S3Error error;
}

/// Receives a ranged response directly into its place in the object's
/// buffer. More bytes than the range asked for stop the download.
private struct SliceSink {
    ubyte[] target;
    size_t filled;

    bool put(scope const(ubyte)[] chunk) @nogc nothrow {
        if (chunk.length > target.length - filled) return false;
        target[filled .. filled + chunk.length] = chunk[];
        filled += chunk.length;
        return true;
    }
}

/// One attempt at bytes `start .. start + target.length` of `key`, written
/// into `target` as they arrive.
private ChunkResult fetchRange(ref S3Client client, string bucket, string key, size_t start, ubyte[] target) {
    auto sink = SliceSink(target);
    auto got = client.getObject(bucket, key, ByteRange.bytes(start, start + target.length - 1), &sink.put);
    if (got.ok && sink.filled == target.length) return ChunkResult(true, false, S3Error.init);
    if (got.ok)
        return ChunkResult(false, true,
            S3Error(FailureKind.malformedResponse, "", "chunk response shorter than its range", got.status.httpStatus));
    if (got.status.kind == FailureKind.aborted)
        return ChunkResult(false, true,
            S3Error(FailureKind.malformedResponse, "", "chunk response longer than its range", got.status.httpStatus));
    return ChunkResult(false, isRetryableKind(got.status.kind), toS3Error(got.status));
}

/// Downloads one large object as `ceil(size / chunkSizeBytes)` byte-range
/// GETs, up to `cfg.perFileChunkConcurrency` of them in flight at once via a
/// per-object `TaskPool`. Each chunk streams into its own disjoint slice of
/// one buffer, so no synchronization is needed on the buffer itself -- only
/// on the shared failure/attempt bookkeeping -- and no per-chunk copy of the
/// data is ever made.
private DownloadOutcome downloadObjectChunked(ListObjectsV2Request listReq, S3Object obj, TransferConfig cfg) {
    immutable size = obj.size;
    immutable chunkSize = cfg.chunkSizeBytes;
    immutable numChunks = (size + chunkSize - 1) / chunkSize;
    auto buffer = new ubyte[size];
    auto mutex = new Mutex;
    bool anyFailed = false;
    S3Error firstError;
    size_t totalAttempts = 0;

    void doChunk(size_t idx) {
        immutable start = idx * chunkSize;
        immutable end = min(start + chunkSize, size);
        size_t attempts = 0;
        ChunkResult result;
        S3Client client;
        auto opened = openClient(client, listReq.region, listReq.credentials, listReq.service, listReq.transport);
        if (!opened.ok) result = ChunkResult(false, false, toS3Error(opened));
        else result = withRetry!ChunkResult(cfg,
            () { attempts++; return fetchRange(client, listReq.bucket, obj.key, start, buffer[start .. end]); },
            (ChunkResult r) => !r.ok,
            (ChunkResult r) => r.retryable);
        mutex.lock();
        scope(exit) mutex.unlock();
        totalAttempts += attempts;
        if (!result.ok) {
            if (!anyFailed) firstError = result.error;
            anyFailed = true;
        }
    }

    if (cfg.perFileChunkConcurrency > 1 && numChunks > 1) {
        auto filePool = new TaskPool(cfg.perFileChunkConcurrency - 1);
        foreach (i; 1 .. numChunks) filePool.put(task(&doChunk, i));
        doChunk(0);
        filePool.finish(true);
    } else {
        foreach (i; 0 .. numChunks) doChunk(i);
    }

    if (anyFailed) return DownloadOutcome(obj.key, false, [], firstError, totalAttempts);
    return DownloadOutcome(obj.key, true, buffer, S3Error.init, totalAttempts);
}

private DownloadOutcome downloadOneObject(ListObjectsV2Request listReq, S3Object obj, TransferConfig cfg) {
    if (obj.size > cfg.chunkThresholdBytes && cfg.perFileChunkConcurrency > 0)
        return downloadObjectChunked(listReq, obj, cfg);

    S3Client client;
    auto opened = openClient(client, listReq.region, listReq.credentials, listReq.service, listReq.transport);
    if (!opened.ok) return DownloadOutcome(obj.key, false, [], toS3Error(opened), 0);

    // One buffer, sized from the listing and filled as the body arrives. It
    // still grows if the object turns out larger than it was listed.
    ubyte[] body_;
    body_.reserve(obj.size);
    auto sink = assumeNoGC((scope const(ubyte)[] chunk) nothrow { body_ ~= chunk; return true; });

    static struct Attempt { bool ok; S3Error error; bool retryable; }
    size_t attempts = 0;
    auto result = withRetry!Attempt(cfg,
        () {
            attempts++;
            body_.length = 0;
            body_.assumeSafeAppend();
            auto got = client.getObject(listReq.bucket, obj.key, ByteRange.whole, sink);
            return got.ok ? Attempt(true) : Attempt(false, toS3Error(got.status), isRetryableKind(got.status.kind));
        },
        (Attempt r) => !r.ok,
        (Attempt r) => r.retryable);
    return DownloadOutcome(obj.key, result.ok, result.ok ? body_ : null, result.error, attempts);
}

/// Bulk-downloads every object `listReq` (a `ListObjectsV2Request`) matches,
/// streamed page by page, up to `cfg.objectWorkers` objects concurrently.
/// `onComplete` is invoked once per object, from whichever pool worker
/// thread finished it -- callers that need to persist bytes (e.g. write each
/// one to disk) do so inside `onComplete`, keeping this module itself free
/// of any filesystem-layout policy.
DownloadBulkResult downloadBulk(ListObjectsV2Request listReq, TransferConfig cfg,
        scope void delegate(DownloadOutcome) onComplete) {
    enforce(cfg.objectWorkers > 0, "s3lite.transfer: objectWorkers must be positive");

    auto mutex = new Mutex;
    size_t succeeded = 0;
    size_t failed = 0;
    string[] failedKeys;

    auto pool = new TaskPool(objectPoolSize(cfg));

    void handleObject(S3Object obj) {
        auto outcome = downloadOneObject(listReq, obj, cfg);
        mutex.lock();
        if (outcome.ok) succeeded++;
        else { failed++; failedKeys ~= outcome.key; }
        mutex.unlock();
        onComplete(outcome);
    }

    void dispatch(S3Object obj) {
        pool.put(task(&handleObject, obj));
    }

    auto listResult = listObjectsV2(listReq, &dispatch);
    pool.finish(true);

    return DownloadBulkResult(succeeded, failed, failedKeys, listResult.ok, listResult.error);
}

// ---------------------------------------------------------------------
// uploadBulk (bulk push)
// ---------------------------------------------------------------------

/// One in-memory object to upload. Bytes, not a local path: this module
/// moves bytes, and leaves reading them from a caller-chosen filesystem
/// layout (or any other source) to the caller, consistent with the rest of
/// this package's zero-filesystem-policy primitives.
struct UploadItem {
    string key;
    const(ubyte)[] body_;
}

struct UploadOutcome {
    string key;
    bool ok;
    string etag;
    S3Error error;
    size_t attempts;
}

struct UploadBulkResult {
    size_t succeeded;
    size_t failed;
    string[] failedKeys;
}

/// Bulk-uploads every item in `items`, up to `cfg.objectWorkers` objects
/// concurrently. `cfg.perFileChunkConcurrency` has no effect here -- see
/// this module's doc comment on why multipart upload isn't implemented yet.
/// `transport` is applied to every item's own `PutObjectRequest` (the same
/// role `ListObjectsV2Request.transport` plays for `downloadBulk` -- both a
/// real caller's timeout/CA-bundle knobs and this package's own test-only
/// `urlOverride` route through it identically).
UploadBulkResult uploadBulk(string bucket, string region, Credentials credentials, string service,
        UploadItem[] items, TransferConfig cfg, GetOptions transport,
        scope void delegate(UploadOutcome) onComplete) {
    enforce(cfg.objectWorkers > 0, "s3lite.transfer: objectWorkers must be positive");

    auto mutex = new Mutex;
    size_t succeeded = 0;
    size_t failed = 0;
    string[] failedKeys;

    auto pool = new TaskPool(objectPoolSize(cfg));

    void handleItem(UploadItem item) {
        UploadOutcome outcome;
        S3Client client;
        auto opened = openClient(client, region, credentials, service, transport);
        if (!opened.ok) outcome = UploadOutcome(item.key, false, "", toS3Error(opened), 0);
        else {
            // Hashed once; every attempt re-reads the same bytes.
            immutable hash = PayloadHash.ofBytes(item.body_);
            size_t attempts = 0;
            auto result = withRetry!PutObjectResult(cfg,
                () {
                    attempts++;
                    auto body_ = SliceBody(item.body_);
                    auto put = client.putObject(bucket, item.key, body_.source, hash);
                    return put.ok ? PutObjectResult(true, put.etag[].idup, S3Error.init)
                        : PutObjectResult(false, "", toS3Error(put.status));
                },
                (PutObjectResult r) => !r.ok,
                (PutObjectResult r) => isRetryableKind(r.error.kind));
            outcome = UploadOutcome(item.key, result.ok, result.etag, result.error, attempts);
        }
        mutex.lock();
        if (outcome.ok) succeeded++;
        else { failed++; failedKeys ~= outcome.key; }
        mutex.unlock();
        onComplete(outcome);
    }

    foreach (item; items)
        pool.put(task(&handleItem, item));
    pool.finish(true);

    return UploadBulkResult(succeeded, failed, failedKeys);
}

unittest {
    // backoffDelayMs: 1st attempt has no prior delay; subsequent attempts
    // double, capped at maxDelayMs.
    TransferConfig cfg;
    cfg.baseDelayMs = 100;
    cfg.maxDelayMs = 1000;
    assert(backoffDelayMs(cfg, 0) == 0);
    assert(backoffDelayMs(cfg, 1) == 100);
    assert(backoffDelayMs(cfg, 2) == 200);
    assert(backoffDelayMs(cfg, 3) == 400);
    assert(backoffDelayMs(cfg, 4) == 800);
    assert(backoffDelayMs(cfg, 5) == 1000); // capped
    assert(backoffDelayMs(cfg, 10) == 1000); // stays capped
}

unittest {
    // withRetry: succeeds on the 3rd attempt of a retryable failure,
    // without any real sleeping (sleepFn stubbed to a no-op).
    TransferConfig cfg;
    cfg.maxAttempts = 5;
    cfg.sleepFn = (Duration d) {}; // no-op: keep the unit test instant
    int calls = 0;
    auto result = withRetry!int(cfg,
        () { calls++; return calls; },
        (int r) => r < 3,
        (int r) => true);
    assert(result == 3);
    assert(calls == 3);
}

unittest {
    // withRetry: a non-retryable failure stops immediately, not exhausting
    // maxAttempts.
    TransferConfig cfg;
    cfg.maxAttempts = 5;
    cfg.sleepFn = (Duration d) {};
    int calls = 0;
    auto result = withRetry!int(cfg,
        () { calls++; return -1; },
        (int r) => r < 0,
        (int r) => false);
    assert(result == -1);
    assert(calls == 1);
}

unittest {
    // withRetry: exhausts maxAttempts on a persistently retryable failure
    // and returns the last (still-failing) result rather than looping
    // forever.
    TransferConfig cfg;
    cfg.maxAttempts = 4;
    cfg.sleepFn = (Duration d) {};
    int calls = 0;
    auto result = withRetry!int(cfg,
        () { calls++; return -1; },
        (int r) => r < 0,
        (int r) => true);
    assert(result == -1);
    assert(calls == 4);
}
