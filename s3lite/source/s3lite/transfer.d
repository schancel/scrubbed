/// Worker-pool bulk S3 pull/push, built entirely on `s3lite.client`'s
/// single-object primitives (`getObject`, `putObject`, `listObjectsV2`).
///
/// This module depends on `s3lite.client`; the reverse is never true --
/// `s3lite.client` does not import anything from here (see its own module
/// doc comment), so a consumer who only wants `GetObject`/`PutObject`/
/// `ListObjectsV2` and does `import s3lite.client;` never drags in the
/// worker-pool machinery below. Only a caller who explicitly wants bulk
/// transfer does `import s3lite.transfer;`.
///
/// Architecture (issue #367, matching s5cmd's real published design,
/// verified against its own docs/source rather than assumed):
///
///   - A global, object-level worker pool (`TransferConfig.objectWorkers`,
///     default 256, s5cmd's own default) bounds how many objects transfer
///     concurrently. Built on scrubbed's own `std.parallelism.TaskPool`
///     pattern, already used in `source/effects/crawl_orchestrator.d`
///     (`new TaskPool(workers - 1)`) -- reused here rather than inventing a
///     new concurrency primitive.
///   - A separate, bounded per-file concurrency (`TransferConfig
///     .perFileChunkConcurrency`, default 5, s5cmd's own default) bounds how
///     many byte-range chunks of *one* large object download concurrently,
///     via a second, per-object `TaskPool` sized to that bound. This applies
///     to `downloadBulk` today, for objects above `chunkThresholdBytes`: a
///     ranged `GetObject`-equivalent GET per chunk, built directly on
///     `s3lite.client.buildGetRequest` plus an appended `Range` header --
///     `s3lite.client` itself gains no new ranged-GET primitive, since the
///     signature it already produces covers a request `s3lite.transfer` is
///     free to add ordinary (unsigned) headers to before dispatch. `pushBulk`
///     does not yet chunk a single object's upload -- this package has no
///     multipart-upload primitive (`CreateMultipartUpload`/`UploadPart`/
///     `CompleteMultipartUpload`), which is out of issue #367's explicit
///     `s3lite.client` scope (`PutObject`/`ListObjectsV2` only). The
///     `perFileChunkConcurrency` knob still exists on `TransferConfig` for
///     the two-level architecture's sake and is honestly documented as
///     inert for uploads until multipart upload lands.
///   - `downloadBulk`'s object list is fed by `s3lite.client.listObjectsV2`'s
///     own streaming pagination: each object is dispatched to the
///     object-level pool as its page arrives, rather than collecting the
///     entire bucket listing into memory before the first download starts.
///   - Bounded exponential-backoff retry (`TransferConfig.maxAttempts`,
///     default 10; `baseDelayMs`/`maxDelayMs`, default budget matching
///     s5cmd's own ~1-minute total) wraps every whole-object transfer and
///     every chunk fetch. Only `FailureKind.transportError` and
///     `FailureKind.malformedResponse` are treated as retryable --
///     `notFound`/`forbidden`/`other` are deterministic failures a retry
///     cannot fix.
module s3lite.transfer;

import s3lite.client;
import s3lite.http : httpGet, RequestHeader, GetOptions;
import std.algorithm.comparison : min;
import std.datetime.systime : Clock;
import std.datetime.timezone : UTC;
import std.exception : enforce;
import std.format : format;
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
    ubyte[] data;
    bool retryable;
    S3Error error;
}

private ChunkResult fetchRange(GetObjectRequest baseReq, size_t start, size_t end) {
    auto now = Clock.currTime(UTC());
    auto built = buildGetRequest(baseReq, now);
    auto rangeHeaders = built.headers ~ RequestHeader("Range", format("bytes=%d-%d", start, end));
    auto result = httpGet(built.url, rangeHeaders, baseReq.transport);
    if (!result.ok)
        return ChunkResult(false, [], true, S3Error(FailureKind.transportError, "", result.failureDetail, 0));
    auto resp = result.response;
    if (resp.status == 206 || resp.status == 200)
        return ChunkResult(true, resp.body_, false, S3Error.init);
    // Any other status for a ranged GET is treated as a retryable,
    // coarsely-classified failure -- s3lite.client's richer S3 XML error
    // classification is reserved for its own whole-object primitives, not
    // duplicated here for an internal chunk-fetch detail.
    return ChunkResult(false, [], true,
        S3Error(FailureKind.malformedResponse, "", "unexpected chunk response status", resp.status));
}

/// Downloads one large object as `ceil(size / chunkSizeBytes)` byte-range
/// GETs, up to `cfg.perFileChunkConcurrency` of them in flight at once via a
/// per-object `TaskPool`, assembling them into one contiguous buffer (each
/// chunk owns a disjoint byte range, so no synchronization is needed on the
/// buffer itself -- only on the shared failure/attempt bookkeeping).
private DownloadOutcome downloadObjectChunked(GetObjectRequest baseReq, S3Object obj, TransferConfig cfg) {
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
        immutable end = min(start + chunkSize, size) - 1;
        size_t attempts = 0;
        auto result = withRetry!ChunkResult(cfg,
            () { attempts++; return fetchRange(baseReq, start, end); },
            (ChunkResult r) => !r.ok,
            (ChunkResult r) => r.retryable);
        mutex.lock();
        scope(exit) mutex.unlock();
        totalAttempts += attempts;
        if (result.ok) {
            buffer[start .. end + 1] = result.data[];
        } else {
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
    auto baseReq = GetObjectRequest(listReq.bucket, obj.key, listReq.region,
        listReq.credentials, listReq.service, listReq.transport);
    if (obj.size > cfg.chunkThresholdBytes && cfg.perFileChunkConcurrency > 0)
        return downloadObjectChunked(baseReq, obj, cfg);

    size_t attempts = 0;
    auto result = withRetry!GetObjectResult(cfg,
        () { attempts++; return getObject(baseReq); },
        (GetObjectResult r) => !r.ok,
        (GetObjectResult r) => isRetryableKind(r.error.kind));
    return DownloadOutcome(obj.key, result.ok, result.body_, result.error, attempts);
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
        auto req = PutObjectRequest(bucket, item.key, region, credentials, item.body_, service, transport);
        size_t attempts = 0;
        auto result = withRetry!PutObjectResult(cfg,
            () { attempts++; return putObject(req); },
            (PutObjectResult r) => !r.ok,
            (PutObjectResult r) => isRetryableKind(r.error.kind));
        auto outcome = UploadOutcome(item.key, result.ok, result.etag, result.error, attempts);
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
