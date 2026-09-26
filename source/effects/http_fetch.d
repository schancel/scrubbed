/// Bounded, D-owned HTTP(S) fetch operation over the host libcurl evaluated
/// in `experiments/http_fetch/check.d` (verdict ADOPT_DYNAMIC, recorded in
/// `docs/http-fetch-evaluation.md`). One call performs one fetch: no shared
/// connection pool, no persistent handle, no CLI/frontier wiring. TLS
/// verification is always on; there is no option, flag, or code path in this
/// module that disables `CURLOPT_SSL_VERIFYPEER`/`CURLOPT_SSL_VERIFYHOST`.
module effects.http_fetch;

import effects.curl_ffi;
import effects.web_url : WebUrl, resolveWebUrl;
import core.atomic : atomicOp;
import core.stdc.errno : errno, EEXIST, EINTR;
import core.sys.posix.fcntl : open, O_CREAT, O_EXCL, O_NOFOLLOW, O_WRONLY;
import core.sys.posix.unistd : close, fsync, link, unlink, write;
import crypto.sha256 : sha256Of;
import std.datetime.systime : Clock, SysTime;
import std.digest : LetterCase, toHexString;
import std.exception : enforce;
import std.file : exists, isDir, isSymlink;
import std.path : absolutePath, buildNormalizedPath, buildPath;
import std.string : toStringz;
import std.uuid : randomUUID;

enum long defaultConnectTimeoutMs = 5_000;
enum long defaultTotalTimeoutMs = 30_000;
enum size_t defaultMaxRedirects = 8;
enum size_t defaultMaxHeaderBytes = 64 * 1024;
enum long defaultMaxEncodedBytes = 16 * 1024 * 1024;
enum size_t defaultMaxDecodedBytes = 32 * 1024 * 1024;
enum size_t defaultMaxConcurrentFetches = 8;

/// Typed connection/total-time/redirect/header/encoded-body/decoded-body/
/// concurrency caps. Every cap is enforced as a content-free rejection: no
/// captured header, body byte, or URL ever appears in a `FetchFailure`.
struct FetchLimits {
    long connectTimeoutMs = defaultConnectTimeoutMs;
    long totalTimeoutMs = defaultTotalTimeoutMs;
    size_t maxRedirects = defaultMaxRedirects;
    size_t maxHeaderBytes = defaultMaxHeaderBytes;
    long maxEncodedBytes = defaultMaxEncodedBytes;
    size_t maxDecodedBytes = defaultMaxDecodedBytes;
    size_t maxConcurrentFetches = defaultMaxConcurrentFetches;
}

/// A cooperative cancellation probe, checked on libcurl's progress callback.
/// Must itself be `nothrow`: it runs inside an `extern(C) nothrow` callback.
alias CancellationCheck = bool delegate() nothrow;

struct FetchRequest {
    /// Fetch identity. `effects.web_url.WebUrl` already restricts this to
    /// `http`/`https` with no embedded userinfo credentials.
    WebUrl url;
    /// Conditional-retrieval validator; empty means an unconditional GET.
    /// Sent as `If-None-Match`, never as a raw caller-composed header.
    string ifNoneMatch;
    /// Optional `host:port:address` IP pins (`CURLOPT_RESOLVE`). Pins the
    /// connection target only; verification is never weakened by this list.
    string[] resolveEntries;
    /// Optional additional trust root (`CURLOPT_CAINFO`). Verification stays
    /// mandatory; this only changes which store is checked against.
    string caFile;
    /// Directory for content-addressed raw-body persistence. Empty disables
    /// persistence; the digest is still computed and returned either way.
    string shardRoot;
    FetchLimits limits;
    CancellationCheck shouldCancel;
}

enum FetchFailureReason : ubyte {
    none,
    concurrencyLimit,
    timedOut,
    tooManyRedirects,
    protocolNotAllowed,
    headerCapExceeded,
    encodedBodyCapExceeded,
    decodedBodyCapExceeded,
    tlsVerificationFailed,
    cancelled,
    transportError,
    invalidResponse,
    storageFailure,
}

enum FetchFailureCategory : ubyte { retryable, permanent }

/// libcurl reports connect and total-time exhaustion as the same
/// `CURLE_OPERATION_TIMEDOUT` result; the evaluation probe distinguished them
/// only by external wall-clock measurement, a test technique this module
/// does not reuse as an implementation signal. `timedOut` therefore covers
/// both configured caps; `FetchLimits.connectTimeoutMs` and `.totalTimeoutMs`
/// remain independently enforced by libcurl, just not independently typed
/// in the failure taxonomy.
FetchFailureCategory categoryOf(FetchFailureReason reason) pure nothrow @safe @nogc {
    final switch (reason) {
    case FetchFailureReason.none: return FetchFailureCategory.permanent;
    case FetchFailureReason.concurrencyLimit: return FetchFailureCategory.retryable;
    case FetchFailureReason.timedOut: return FetchFailureCategory.retryable;
    case FetchFailureReason.transportError: return FetchFailureCategory.retryable;
    case FetchFailureReason.storageFailure: return FetchFailureCategory.retryable;
    case FetchFailureReason.tooManyRedirects: return FetchFailureCategory.permanent;
    case FetchFailureReason.protocolNotAllowed: return FetchFailureCategory.permanent;
    case FetchFailureReason.headerCapExceeded: return FetchFailureCategory.permanent;
    case FetchFailureReason.encodedBodyCapExceeded: return FetchFailureCategory.permanent;
    case FetchFailureReason.decodedBodyCapExceeded: return FetchFailureCategory.permanent;
    case FetchFailureReason.tlsVerificationFailed: return FetchFailureCategory.permanent;
    case FetchFailureReason.cancelled: return FetchFailureCategory.permanent;
    case FetchFailureReason.invalidResponse: return FetchFailureCategory.permanent;
    }
}

/// Content-free failure: a fixed reason plus numeric libcurl/HTTP codes.
/// Never carries a URL, header, body byte, or raw libcurl error string.
struct FetchFailure {
    FetchFailureReason reason;
    int curlCode;
    long httpStatus;

    FetchFailureCategory category() const pure nothrow @safe @nogc {
        return categoryOf(reason);
    }
}

struct FetchEvidence {
    WebUrl requestedUrl;
    WebUrl finalUrl;
    /// Intermediate hop targets in visited order; excludes `requestedUrl`
    /// and `finalUrl`.
    WebUrl[] redirectChain;
    long status;
    bool notModified;
    string contentType;
    string contentEncoding;
    string etag;
    string lastModified;
    string retryAfter;
    long contentLengthHeader = -1;
    ubyte[32] bodyDigest;
    size_t bodyBytes;
    bool bodyStored;
    string shardPath;
    SysTime startedAt;
    SysTime finishedAt;
}

struct FetchOutcome {
    private bool succeeded_;
    private FetchEvidence evidence_;
    private FetchFailure failure_;

    bool succeeded() const pure nothrow @safe @nogc { return succeeded_; }

    ref const(FetchEvidence) evidence() const pure {
        enforce(succeeded_, "fetch outcome is a failure");
        return evidence_;
    }

    FetchFailure failure() const pure {
        enforce(!succeeded_, "fetch outcome is a success");
        return failure_;
    }
}

private shared int activeFetches;

private bool acquireConcurrencySlot(size_t cap) nothrow {
    auto next = atomicOp!"+="(activeFetches, 1);
    if (cast(size_t) next > cap) {
        atomicOp!"-="(activeFetches, 1);
        return false;
    }
    return true;
}

private void releaseConcurrencySlot() nothrow {
    atomicOp!"-="(activeFetches, 1);
}

private struct TransferState {
    size_t headerCap = size_t.max;
    size_t decodedCap = size_t.max;
    long encodedCap = long.max;
    size_t maxLocations = 16;
    CancellationCheck shouldCancel;

    FetchFailureReason abortReason;
    size_t headerBytes;
    ubyte[] body;

    string contentType;
    string contentEncoding;
    string etag;
    string lastModified;
    string retryAfter;
    long contentLength = -1;

    string[] locations;
}

private bool equalsIgnoreCase(const(char)[] a, string b) pure nothrow @safe @nogc {
    if (a.length != b.length) return false;
    foreach (i; 0 .. a.length) {
        char ca = a[i];
        char cb = b[i];
        if (ca >= 'A' && ca <= 'Z') ca = cast(char)(ca + 32);
        if (cb >= 'A' && cb <= 'Z') cb = cast(char)(cb + 32);
        if (ca != cb) return false;
    }
    return true;
}

private bool parseHeaderLong(const(char)[] text, out long value) pure nothrow @safe @nogc {
    if (text.length == 0) return false;
    long result;
    foreach (ch; text) {
        if (ch < '0' || ch > '9') return false;
        if (result > (long.max - (ch - '0')) / 10) return false;
        result = result * 10 + (ch - '0');
    }
    value = result;
    return true;
}

extern(C) private nothrow size_t fetchBodyCallback(char* data, size_t size,
        size_t count, void* opaque) {
    auto state = cast(TransferState*) opaque;
    const bytes = size * count;
    if (bytes > state.decodedCap - state.body.length) {
        state.abortReason = FetchFailureReason.decodedBodyCapExceeded;
        return 0;
    }
    state.body ~= cast(const(ubyte)[]) data[0 .. bytes];
    return bytes;
}

extern(C) private nothrow size_t fetchHeaderCallback(char* data, size_t size,
        size_t count, void* opaque) {
    auto state = cast(TransferState*) opaque;
    const bytes = size * count;
    if (bytes > state.headerCap - state.headerBytes) {
        state.abortReason = FetchFailureReason.headerCapExceeded;
        return 0;
    }
    state.headerBytes += bytes;
    auto line = data[0 .. bytes];
    if (line.length >= 5 && line[0 .. 5] == "HTTP/") {
        // A new status line starts a new hop: selected headers describe only
        // the most recently started response.
        state.contentType = null;
        state.contentEncoding = null;
        state.etag = null;
        state.lastModified = null;
        state.retryAfter = null;
        state.contentLength = -1;
        return bytes;
    }
    ptrdiff_t colon = -1;
    foreach (i, ch; line) {
        if (ch == ':') { colon = cast(ptrdiff_t) i; break; }
    }
    if (colon <= 0) return bytes;
    auto name = line[0 .. colon];
    auto rest = line[colon + 1 .. $];
    size_t start;
    while (start < rest.length && rest[start] == ' ') ++start;
    size_t end = rest.length;
    while (end > start && (rest[end - 1] == '\r' || rest[end - 1] == '\n')) --end;
    auto value = rest[start .. end];
    if (equalsIgnoreCase(name, "content-type")) state.contentType = value.idup;
    else if (equalsIgnoreCase(name, "content-encoding")) state.contentEncoding = value.idup;
    else if (equalsIgnoreCase(name, "etag")) state.etag = value.idup;
    else if (equalsIgnoreCase(name, "last-modified")) state.lastModified = value.idup;
    else if (equalsIgnoreCase(name, "retry-after")) state.retryAfter = value.idup;
    else if (equalsIgnoreCase(name, "content-length")) {
        long parsed;
        if (parseHeaderLong(value, parsed)) state.contentLength = parsed;
    } else if (equalsIgnoreCase(name, "location")) {
        if (state.locations.length < state.maxLocations)
            state.locations ~= value.idup;
    }
    return bytes;
}

extern(C) private nothrow int fetchProgressCallback(void* opaque, long, long downloaded,
        long, long) {
    auto state = cast(TransferState*) opaque;
    if (downloaded > state.encodedCap) {
        state.abortReason = FetchFailureReason.encodedBodyCapExceeded;
        return 1;
    }
    if (state.shouldCancel !is null && state.shouldCancel()) {
        state.abortReason = FetchFailureReason.cancelled;
        return 1;
    }
    return 0;
}

private void setOption(int result) {
    enforce(result == CURLE_OK, "http fetch: setopt failed");
}

private void validateLimits(FetchLimits limits) {
    enforce(limits.connectTimeoutMs > 0, "http fetch: connect timeout must be positive");
    enforce(limits.totalTimeoutMs > 0, "http fetch: total timeout must be positive");
    enforce(limits.connectTimeoutMs <= limits.totalTimeoutMs,
        "http fetch: connect timeout must not exceed total timeout");
    enforce(limits.maxHeaderBytes > 0, "http fetch: header cap must be positive");
    enforce(limits.maxEncodedBytes > 0, "http fetch: encoded-body cap must be positive");
    enforce(limits.maxDecodedBytes > 0, "http fetch: decoded-body cap must be positive");
    enforce(limits.maxConcurrentFetches > 0, "http fetch: concurrency cap must be positive");
    enforce(limits.maxRedirects <= cast(size_t) long.max,
        "http fetch: redirect cap exceeds representable range");
}

private FetchFailure classifyFailure(int code, ref TransferState state, long status) {
    if (state.abortReason != FetchFailureReason.none)
        return FetchFailure(state.abortReason, code, status);
    FetchFailureReason reason;
    if (code == CURLE_UNSUPPORTED_PROTOCOL) reason = FetchFailureReason.protocolNotAllowed;
    else if (code == CURLE_TOO_MANY_REDIRECTS) reason = FetchFailureReason.tooManyRedirects;
    else if (code == CURLE_OPERATION_TIMEDOUT) reason = FetchFailureReason.timedOut;
    else if (code == CURLE_PEER_FAILED_VERIFICATION) reason = FetchFailureReason.tlsVerificationFailed;
    else reason = FetchFailureReason.transportError;
    return FetchFailure(reason, code, status);
}

private void writeAllBytes(int fd, const(ubyte)[] bytes) {
    size_t offset;
    while (offset < bytes.length) {
        auto amount = write(fd, bytes.ptr + offset, bytes.length - offset);
        if (amount < 0 && errno == EINTR) continue;
        enforce(amount > 0, "http fetch: shard write failed");
        offset += cast(size_t) amount;
    }
}

/// Content-addressable persistence for a fetched raw body. Reuses
/// `effects.document_shards`'s bounded POSIX publication *mechanics*: an
/// unpredictable-named temporary file created with
/// `O_CREAT|O_EXCL|O_NOFOLLOW`, `fsync`, close, then a hard link into the
/// digest-named destination. Trusting a losing `link` with `EEXIST` as proof
/// that identical bytes are already durably stored under this digest is a
/// new decision for this module (it relies on SHA-256 collision resistance,
/// standard for content-addressed stores) — it is not `document_shards`'s
/// existing behavior: `DocumentShardWriter.publish` fails closed on any
/// nonzero `link` result, including `EEXIST`, and `OverlayWriter.publish`
/// uses `rename` with an explicit target-identity guard instead.
private string persistContentAddressed(string root, ubyte[32] digest,
        const(ubyte)[] bytes) {
    enforce(root.length != 0, "http fetch: empty shard root");
    auto normalizedRoot = buildNormalizedPath(absolutePath(root));
    // `isDir`/`isSymlink` throw `FileException` (with the path in the
    // message) when the path does not exist; `exists` alone never does. Test
    // existence first so no path can reach an exception message.
    enforce(exists(normalizedRoot) && isDir(normalizedRoot) && !isSymlink(normalizedRoot),
        "http fetch: unsafe shard root");
    auto hex = toHexString!(LetterCase.lower)(digest).idup;
    auto destination = buildPath(normalizedRoot, hex);
    if (exists(destination)) {
        enforce(!isSymlink(destination), "http fetch: unsafe shard destination");
        return destination;
    }
    auto temporary = buildPath(normalizedRoot,
        "." ~ hex ~ ".scrubbed-fetch-" ~ randomUUID.toString ~ ".tmp");
    auto temporaryZ = temporary ~ "\0";
    auto fd = open(temporaryZ.ptr, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 384);
    enforce(fd >= 0, "http fetch: cannot create temporary shard");
    bool closed;
    scope(exit) { if (!closed) close(fd); unlink(temporaryZ.ptr); }
    writeAllBytes(fd, bytes);
    enforce(fsync(fd) == 0, "http fetch: shard fsync failed");
    enforce(close(fd) == 0, "http fetch: shard close failed");
    closed = true;
    auto destinationZ = destination ~ "\0";
    if (link(temporaryZ.ptr, destinationZ.ptr) != 0) {
        auto linkErrno = errno;
        enforce(linkErrno == EEXIST, "http fetch: shard publish failed");
    }
    return destination;
}

shared static this() {
    enforce(curl_global_init(curlGlobalAll) == CURLE_OK,
        "http fetch: libcurl global initialization failed");
}

/// Perform one bounded HTTP(S) fetch. TLS verification is always on
/// (`CURLOPT_SSL_VERIFYPEER=1`, `CURLOPT_SSL_VERIFYHOST=2`); nothing in this
/// function can disable it. Every cap in `request.limits` is enforced as a
/// typed, content-free `FetchFailure`, never a raw libcurl error string.
FetchOutcome fetchHttp(FetchRequest request) {
    validateLimits(request.limits);
    FetchOutcome outcome;
    if (!acquireConcurrencySlot(request.limits.maxConcurrentFetches)) {
        outcome.failure_ = FetchFailure(FetchFailureReason.concurrencyLimit, 0, 0);
        return outcome;
    }
    scope(exit) releaseConcurrencySlot();

    auto startedAt = Clock.currTime;
    TransferState state;
    state.headerCap = request.limits.maxHeaderBytes;
    state.decodedCap = request.limits.maxDecodedBytes;
    state.encodedCap = request.limits.maxEncodedBytes;
    state.maxLocations = request.limits.maxRedirects + 1;
    state.shouldCancel = request.shouldCancel;

    auto easy = curl_easy_init();
    if (easy is null) {
        outcome.failure_ = FetchFailure(FetchFailureReason.transportError, 0, 0);
        return outcome;
    }
    scope(exit) curl_easy_cleanup(easy);
    curl_slist* requestHeaders;
    curl_slist* resolveList;
    scope(exit) if (requestHeaders !is null) curl_slist_free_all(requestHeaders);
    scope(exit) if (resolveList !is null) curl_slist_free_all(resolveList);

    auto urlz = request.url.canonical.toStringz;
    auto protocols = "http,https".toStringz;
    auto noProxy = "".toStringz;
    auto encoding = "gzip".toStringz;
    setOption(curl_easy_setopt(easy, CURLOPT_URL, urlz));
    setOption(curl_easy_setopt(easy, CURLOPT_PROTOCOLS_STR, protocols));
    setOption(curl_easy_setopt(easy, CURLOPT_REDIR_PROTOCOLS_STR, protocols));
    setOption(curl_easy_setopt(easy, CURLOPT_PROXY, noProxy));
    setOption(curl_easy_setopt(easy, CURLOPT_NOSIGNAL, 1L));
    setOption(curl_easy_setopt(easy, CURLOPT_FOLLOWLOCATION, 1L));
    setOption(curl_easy_setopt(easy, CURLOPT_MAXREDIRS, cast(long) request.limits.maxRedirects));
    setOption(curl_easy_setopt(easy, CURLOPT_CONNECTTIMEOUT_MS, request.limits.connectTimeoutMs));
    setOption(curl_easy_setopt(easy, CURLOPT_TIMEOUT_MS, request.limits.totalTimeoutMs));
    setOption(curl_easy_setopt(easy, CURLOPT_SSL_VERIFYPEER, 1L));
    setOption(curl_easy_setopt(easy, CURLOPT_SSL_VERIFYHOST, 2L));
    setOption(curl_easy_setopt(easy, CURLOPT_ACCEPT_ENCODING, encoding));
    setOption(curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, &fetchBodyCallback));
    setOption(curl_easy_setopt(easy, CURLOPT_WRITEDATA, &state));
    setOption(curl_easy_setopt(easy, CURLOPT_HEADERFUNCTION, &fetchHeaderCallback));
    setOption(curl_easy_setopt(easy, CURLOPT_HEADERDATA, &state));
    setOption(curl_easy_setopt(easy, CURLOPT_NOPROGRESS, 0L));
    setOption(curl_easy_setopt(easy, CURLOPT_XFERINFOFUNCTION, &fetchProgressCallback));
    setOption(curl_easy_setopt(easy, CURLOPT_XFERINFODATA, &state));

    if (request.caFile.length) {
        auto caz = request.caFile.toStringz;
        setOption(curl_easy_setopt(easy, CURLOPT_CAINFO, caz));
    }
    if (request.ifNoneMatch.length) {
        auto header = "If-None-Match: " ~ request.ifNoneMatch;
        auto next = curl_slist_append(requestHeaders, header.toStringz);
        enforce(next !is null, "http fetch: header list allocation failed");
        requestHeaders = next;
    }
    if (requestHeaders !is null)
        setOption(curl_easy_setopt(easy, CURLOPT_HTTPHEADER, requestHeaders));
    foreach (entry; request.resolveEntries) {
        auto next = curl_slist_append(resolveList, entry.toStringz);
        enforce(next !is null, "http fetch: resolve list allocation failed");
        resolveList = next;
    }
    if (resolveList !is null)
        setOption(curl_easy_setopt(easy, CURLOPT_RESOLVE, resolveList));

    auto code = curl_easy_perform(easy);
    auto finishedAt = Clock.currTime;

    long status;
    long encodedBytes;
    curl_easy_getinfo(easy, CURLINFO_RESPONSE_CODE, &status);
    curl_easy_getinfo(easy, CURLINFO_SIZE_DOWNLOAD_T, &encodedBytes);

    if (code != CURLE_OK) {
        outcome.failure_ = classifyFailure(code, state, status);
        return outcome;
    }

    WebUrl[] visited;
    auto base = request.url;
    foreach (location; state.locations) {
        auto resolved = resolveWebUrl(base.canonical, location);
        if (!resolved.isResolved) {
            outcome.failure_ = FetchFailure(FetchFailureReason.invalidResponse, code, status);
            return outcome;
        }
        base = resolved.value;
        visited ~= base;
    }
    auto finalUrl = visited.length ? visited[$ - 1] : request.url;
    auto redirectChain = visited.length ? visited[0 .. $ - 1] : null;

    auto digest = sha256Of(cast(const(ubyte)[]) state.body);
    string shardPath;
    bool stored;
    if (request.shardRoot.length && status != 304 && state.body.length) {
        try {
            shardPath = persistContentAddressed(request.shardRoot, digest, state.body);
            stored = true;
        } catch (Exception) {
            outcome.failure_ = FetchFailure(FetchFailureReason.storageFailure, code, status);
            return outcome;
        }
    }

    FetchEvidence evidence;
    evidence.requestedUrl = request.url;
    evidence.finalUrl = finalUrl;
    evidence.redirectChain = redirectChain;
    evidence.status = status;
    evidence.notModified = status == 304;
    evidence.contentType = state.contentType;
    evidence.contentEncoding = state.contentEncoding;
    evidence.etag = state.etag;
    evidence.lastModified = state.lastModified;
    evidence.retryAfter = state.retryAfter;
    evidence.contentLengthHeader = state.contentLength;
    evidence.bodyDigest = digest;
    evidence.bodyBytes = state.body.length;
    evidence.bodyStored = stored;
    evidence.shardPath = shardPath;
    evidence.startedAt = startedAt;
    evidence.finishedAt = finishedAt;

    outcome.succeeded_ = true;
    outcome.evidence_ = evidence;
    return outcome;
}

unittest {
    assert(equalsIgnoreCase("ETag", "etag"));
    assert(equalsIgnoreCase("Content-Type", "content-type"));
    assert(!equalsIgnoreCase("Content-Type", "content-length"));
    assert(!equalsIgnoreCase("etag", "etags"));

    long parsed;
    assert(parseHeaderLong("1234", parsed) && parsed == 1234);
    assert(!parseHeaderLong("", parsed));
    assert(!parseHeaderLong("12a4", parsed));

    assert(categoryOf(FetchFailureReason.timedOut) == FetchFailureCategory.retryable);
    assert(categoryOf(FetchFailureReason.concurrencyLimit) == FetchFailureCategory.retryable);
    assert(categoryOf(FetchFailureReason.storageFailure) == FetchFailureCategory.retryable);
    assert(categoryOf(FetchFailureReason.tooManyRedirects) == FetchFailureCategory.permanent);
    assert(categoryOf(FetchFailureReason.tlsVerificationFailed) == FetchFailureCategory.permanent);
    assert(categoryOf(FetchFailureReason.cancelled) == FetchFailureCategory.permanent);
}

unittest {
    // Concurrency accounting is symmetric and content-free: exhausting the
    // cap rejects without touching libcurl, and release restores headroom.
    assert(acquireConcurrencySlot(1));
    assert(!acquireConcurrencySlot(1));
    releaseConcurrencySlot();
    assert(acquireConcurrencySlot(1));
    releaseConcurrencySlot();
}
