/// Bounded, D-owned HTTP(S) fetch operation over the host libcurl evaluated
/// in `experiments/http_fetch/check.d` (verdict ADOPT_DYNAMIC, recorded in
/// `docs/http-fetch-evaluation.md`). One call performs one fetch: no shared
/// connection pool, no persistent handle, no CLI/frontier wiring. TLS
/// verification is always on; there is no option, flag, or code path in this
/// module that disables `CURLOPT_SSL_VERIFYPEER`/`CURLOPT_SSL_VERIFYHOST`.
///
/// This is the package's headline API -- ported unchanged (aside from this
/// module's own path) from scrubbed's `source/effects/http_fetch.d`. See the
/// package README for usage; `httpfetch.curl_ffi` is the secondary,
/// low-level API for callers who want raw libcurl access.
module httpfetch.http_fetch;

import httpfetch.curl_ffi;
import httpfetch.web_url : WebUrl, resolveWebUrl;
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
/// Cap on `FetchRequest.requestBody` (issue #355). An unbounded
/// caller-supplied request body is a resource-exhaustion vector in its own
/// right, independent of the response-side `maxEncodedBytes`/
/// `maxDecodedBytes` caps above -- so it gets its own typed limit rather than
/// reusing either of those. 8 MiB comfortably covers a JSON API request body
/// (#65's own motivating use case) with headroom, while still being a real,
/// enforced bound rather than `size_t.max`.
enum size_t defaultMaxRequestBodyBytes = 8 * 1024 * 1024;

/// Sent as `User-Agent` on every request (issue #305 review found real
/// Wikipedia fetches came back HTTP 403 for having none at all). Honest
/// crawler self-identification — name/version + URL for more info, the same
/// pattern as Googlebot — never a spoofed browser string; see this project's
/// established transparency/provenance discipline elsewhere (executable
/// snapshots, exact tool versions, no silent anything). Fixed literal rather
/// than derived from a release version: `dub.json` carries no version field
/// today, and this fix is scoped to this file only, so there's nothing to
/// derive from without expanding scope.
enum string userAgent = "scrubbed/0.1 (+https://github.com/schancel/scrubbed)";

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
    size_t maxRequestBodyBytes = defaultMaxRequestBodyBytes;
}

/// A cooperative cancellation probe, checked on libcurl's progress callback.
/// Must itself be `nothrow`: it runs inside an `extern(C) nothrow` callback.
alias CancellationCheck = bool delegate() nothrow;

/// A single caller-supplied request header. Unlike `FetchRequest.ifNoneMatch`
/// (which composes one hardcoded `If-None-Match` line), this is a generic
/// `(name, value)` pair validated by `fetchHttp` before it is ever composed
/// into a `curl_slist` entry -- see `isHeaderNameToken`/`isSafeHeaderValue`.
/// Works unchanged for either a GET or a POST (`FetchRequest.requestBody`,
/// issue #355): a caller sending a JSON POST body still supplies its
/// `Content-Type` via this same generic list.
struct FetchHeader {
    string name;
    string value;
}

struct FetchRequest {
    /// Fetch identity. `httpfetch.web_url.WebUrl` already restricts this to
    /// `http`/`https` with no embedded userinfo credentials.
    WebUrl url;
    /// Conditional-retrieval validator; empty means an unconditional GET.
    /// Sent as `If-None-Match`, never as a raw caller-composed header. Kept
    /// exactly as-is -- not validated by the `headers` mechanism below;
    /// additive only.
    string ifNoneMatch;
    /// Additional caller-supplied request headers, generic beyond the single
    /// hardcoded `ifNoneMatch` field above. Every name/value pair is
    /// validated by `fetchHttp` (CR/LF/NUL rejected in either; the name is
    /// further restricted to the HTTP token character set) before being
    /// appended to the same `curl_slist`/`CURLOPT_HTTPHEADER` mechanism
    /// `ifNoneMatch` already uses. A validation failure is a typed
    /// `FetchFailureReason.invalidHeader` returned before any request is
    /// attempted -- never a silent drop and never a crash.
    FetchHeader[] headers;
    /// Optional POST request body (issue #355). Empty (the default, `null`
    /// or a zero-length array -- both have `.length == 0`) means an
    /// unconditional GET, exactly as this module behaved before #355: no
    /// separate GET/POST method field exists because presence of a body is
    /// itself the only signal `CURLOPT_POST` actually needs (libcurl has no
    /// notion of a required non-empty POST body; a deliberately empty POST
    /// is out of scope for this HTTP-transport-prerequisite ticket -- see
    /// #65 -- and would be indistinguishable from "no body" under this
    /// design, so it is left to a future ticket to add an explicit method
    /// field if that ever becomes a real need). When non-empty, `fetchHttp`
    /// sends exactly these bytes as the request body via
    /// `CURLOPT_POST`/`CURLOPT_POSTFIELDS`/`CURLOPT_POSTFIELDSIZE`, bounded
    /// by `FetchLimits.maxRequestBodyBytes` (checked before any request is
    /// attempted, the same content-free-rejection discipline as
    /// `headerCapExceeded`/`encodedBodyCapExceeded`/`decodedBodyCapExceeded`
    /// below). Named `requestBody` rather than `body` -- `body` is a
    /// deprecated-but-still-reserved D keyword (function-contract syntax)
    /// and would shadow-collide with it.
    immutable(ubyte)[] requestBody;
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
    /// `FetchRequest.requestBody.length` exceeded `FetchLimits.
    /// maxRequestBodyBytes` (issue #355). Returned before `curl_easy_init`
    /// is ever reached and before any request is attempted -- the same
    /// before-any-attempt discipline `invalidHeader` below already uses.
    requestBodyCapExceeded,
    tlsVerificationFailed,
    cancelled,
    transportError,
    invalidResponse,
    storageFailure,
    /// A caller-supplied `FetchRequest.headers` entry failed validation
    /// (embedded CR/LF/NUL, or a name outside the HTTP token character set).
    /// Returned before `curl_easy_init`/`curl_slist_append` is ever reached
    /// and before any request is attempted.
    invalidHeader,
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
    case FetchFailureReason.requestBodyCapExceeded: return FetchFailureCategory.permanent;
    case FetchFailureReason.tlsVerificationFailed: return FetchFailureCategory.permanent;
    case FetchFailureReason.cancelled: return FetchFailureCategory.permanent;
    case FetchFailureReason.invalidResponse: return FetchFailureCategory.permanent;
    case FetchFailureReason.invalidHeader: return FetchFailureCategory.permanent;
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

/// RFC 7230 section 3.2.6 `tchar`/`token`: the character set permitted in an
/// HTTP header field *name*. Alphanumeric plus `!#$%&'*+-.^_`|~` -- no
/// colon, no whitespace, no control character. This alone already excludes
/// CR/LF/NUL, but that property is also checked explicitly below so the
/// injection-safety guarantee this function exists for is independently
/// readable and doesn't rely solely on this charset staying exactly as
/// written.
private bool isHeaderNameToken(string name) pure nothrow @safe @nogc {
    if (name.length == 0) return false;
    foreach (ch; name) {
        switch (ch) {
        case 'a': .. case 'z':
        case 'A': .. case 'Z':
        case '0': .. case '9':
        case '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~':
            continue;
        default:
            return false;
        }
    }
    return true;
}

/// A header *value* has no similarly strict grammar in general real-world
/// use (arbitrary printable text, spaces, commas, etc. are legitimate), so
/// this only enforces the hard requirement for this codebase's
/// injection-safety property: no CR, LF, or NUL, any of which would let a
/// caller-controlled value inject a second header, terminate the request
/// line early, or otherwise smuggle content into the request.
private bool isSafeHeaderValue(string value) pure nothrow @safe @nogc {
    foreach (ch; value) {
        if (ch == '\r' || ch == '\n' || ch == '\0') return false;
    }
    return true;
}

/// True if every entry in `headers` passes `isHeaderNameToken`/
/// `isSafeHeaderValue`. Checked as one pass over the whole list before any
/// entry is composed into a `curl_slist` line, so a single bad entry fails
/// the entire request rather than silently dropping just that header.
private bool allHeadersValid(const(FetchHeader)[] headers) pure nothrow @safe @nogc {
    foreach (header; headers) {
        if (!isHeaderNameToken(header.name)) return false;
        if (!isSafeHeaderValue(header.value)) return false;
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

/// The one place this module appends a raw header line to a `curl_slist`.
/// Generalizes (does not duplicate) the append-and-check pattern `ifNoneMatch`
/// already used inline: both `ifNoneMatch` and the validated entries in
/// `FetchRequest.headers` now compose their line and call through here.
/// Callers remain responsible for whatever validation their own header line
/// needs before calling this -- `ifNoneMatch` deliberately does none (its
/// existing behavior is unchanged), while `FetchRequest.headers` entries are
/// validated by `allHeadersValid` before `fetchHttp` ever reaches this point.
private curl_slist* appendHeaderLine(curl_slist* list, string line) {
    auto next = curl_slist_append(list, line.toStringz);
    enforce(next !is null, "http fetch: header list allocation failed");
    return next;
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
    enforce(limits.maxRequestBodyBytes > 0, "http fetch: request-body cap must be positive");
    enforce(limits.maxRequestBodyBytes <= cast(size_t) long.max,
        "http fetch: request-body cap exceeds representable range");
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
    if (!allHeadersValid(request.headers)) {
        outcome.failure_ = FetchFailure(FetchFailureReason.invalidHeader, 0, 0);
        return outcome;
    }
    if (request.requestBody.length > request.limits.maxRequestBodyBytes) {
        outcome.failure_ = FetchFailure(FetchFailureReason.requestBodyCapExceeded, 0, 0);
        return outcome;
    }
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
    auto userAgentz = userAgent.toStringz;
    setOption(curl_easy_setopt(easy, CURLOPT_USERAGENT, userAgentz));
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
        requestHeaders = appendHeaderLine(requestHeaders, "If-None-Match: " ~ request.ifNoneMatch);
    }
    foreach (header; request.headers) {
        // Already validated by `allHeadersValid` at the top of this
        // function; no unvalidated header ever reaches this line.
        requestHeaders = appendHeaderLine(requestHeaders, header.name ~ ": " ~ header.value);
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
    if (request.requestBody.length) {
        // Already bounded by `FetchLimits.maxRequestBodyBytes` at the top of
        // this function (`requestBodyCapExceeded` returns before this point
        // is ever reached). `CURLOPT_POST` must be set before
        // `CURLOPT_POSTFIELDS`/`CURLOPT_POSTFIELDSIZE` per libcurl's own
        // documented requirement for a fixed-length POST. `request` (and so
        // the `ubyte[]` `requestBody` slices) outlives `curl_easy_perform`
        // below -- both are still in scope on this same stack frame -- so
        // libcurl reading `CURLOPT_POSTFIELDS` without copying it (the
        // default; `CURLOPT_COPYPOSTFIELDS` is not used here) is safe.
        setOption(curl_easy_setopt(easy, CURLOPT_POST, 1L));
        setOption(curl_easy_setopt(easy, CURLOPT_POSTFIELDS, request.requestBody.ptr));
        setOption(curl_easy_setopt(easy, CURLOPT_POSTFIELDSIZE,
            cast(long) request.requestBody.length));
    }

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
    assert(categoryOf(FetchFailureReason.invalidHeader) == FetchFailureCategory.permanent);
}

unittest {
    // Header validation is a pure, isolated gate: exercised directly here
    // (no curl involvement at all), independent of the end-to-end injection
    // proof further down that shows it actually short-circuits `fetchHttp`.
    assert(isHeaderNameToken("X-Scrubbed-Test"));
    assert(isHeaderNameToken("Content-MD5"));
    assert(isHeaderNameToken("x_amz_date"));
    assert(!isHeaderNameToken(""));
    assert(!isHeaderNameToken("X-Bad:Name"));
    assert(!isHeaderNameToken("X Bad Name"));
    assert(!isHeaderNameToken("X-Bad\r\nName"));
    assert(!isHeaderNameToken("X-Bad\0Name"));

    assert(isSafeHeaderValue(""));
    assert(isSafeHeaderValue("hello world, 42; q=0.9"));
    assert(!isSafeHeaderValue("evil\r\nX-Injected: yes"));
    assert(!isSafeHeaderValue("evil\nX-Injected: yes"));
    assert(!isSafeHeaderValue("evil\rX-Injected: yes"));
    assert(!isSafeHeaderValue("evil\0value"));

    assert(allHeadersValid(null));
    assert(allHeadersValid([FetchHeader("X-A", "1"), FetchHeader("X-B", "2")]));
    assert(!allHeadersValid([FetchHeader("X-A", "1"), FetchHeader("X-Bad\r\n", "2")]));
    assert(!allHeadersValid([FetchHeader("X-A", "1\r\nX-Injected: yes")]));
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

unittest {
    // Real proof, per issue #307's acceptance criteria: not that setopt was
    // called, but that the exact `User-Agent` value is genuinely present on
    // the wire. This sandbox has no outbound network access for a live
    // fetch against a header-echoing service (e.g. httpbin.org), so this
    // stands up a real loopback TCP server on an ephemeral port, drives a
    // real `fetchHttp()` call at it over a real socket, and inspects the
    // literal bytes the server received.
    import core.thread : Thread;
    import std.conv : to;
    import std.socket : AddressFamily, InternetAddress, SocketOption,
        SocketOptionLevel, TcpSocket;
    import std.string : indexOf;

    auto listener = new TcpSocket(AddressFamily.INET);
    scope(exit) listener.close();
    listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
    listener.bind(new InternetAddress("127.0.0.1", 0));
    listener.listen(1);
    immutable port = (cast(InternetAddress) listener.localAddress).port;

    string capturedRequest;
    auto worker = new Thread({
        auto client = listener.accept();
        scope(exit) client.close();
        ubyte[4_096] buffer;
        string received;
        while (received.indexOf("\r\n\r\n") < 0) {
            auto count = client.receive(buffer[]);
            if (count <= 0) break;
            received ~= cast(string) buffer[0 .. count].idup;
        }
        capturedRequest = received;
        enum string responseBody = "ok";
        client.send(cast(const(ubyte)[])("HTTP/1.1 200 OK\r\nContent-Length: " ~
            responseBody.length.to!string ~ "\r\nConnection: close\r\n\r\n" ~ responseBody));
    });
    worker.start();

    auto rawUrl = "http://127.0.0.1:" ~ port.to!string ~ "/probe";
    auto resolved = resolveWebUrl(rawUrl, rawUrl);
    assert(resolved.isResolved);

    FetchRequest request;
    request.url = resolved.value;
    request.limits.connectTimeoutMs = 500;
    request.limits.totalTimeoutMs = 2_000;

    auto outcome = fetchHttp(request);
    worker.join();

    assert(outcome.succeeded);
    assert(outcome.evidence.status == 200);
    assert(capturedRequest.indexOf("User-Agent: " ~ userAgent ~ "\r\n") >= 0,
        "http fetch: exact User-Agent header not found on the wire");
}

unittest {
    // Real proof, per issue #46's acceptance criteria: a CRLF- or
    // NUL-containing caller-supplied header (value or name) must be rejected
    // *before* any request is attempted -- not just that curl itself would
    // reject a malformed request. Proven by pointing at
    // `http://127.0.0.1:1/`, `curl_ffi.d`'s own established
    // guaranteed-connection-refused target: if validation ran first, the
    // outcome is `invalidHeader` with no curl code; if it were skipped and
    // the request actually reached curl, the outcome would instead be
    // `transportError` with a real nonzero curl code from the refused
    // connection. Getting `invalidHeader` here is proof no request was even
    // attempted.
    auto resolved = resolveWebUrl("http://127.0.0.1:1/", "http://127.0.0.1:1/");
    assert(resolved.isResolved);

    FetchRequest crlfValue;
    crlfValue.url = resolved.value;
    crlfValue.headers = [FetchHeader("X-Test", "evil\r\nX-Injected: yes")];
    auto crlfValueOutcome = fetchHttp(crlfValue);
    assert(!crlfValueOutcome.succeeded);
    assert(crlfValueOutcome.failure.reason == FetchFailureReason.invalidHeader);
    assert(crlfValueOutcome.failure.curlCode == 0);
    assert(crlfValueOutcome.failure.httpStatus == 0);

    FetchRequest lfOnlyValue;
    lfOnlyValue.url = resolved.value;
    lfOnlyValue.headers = [FetchHeader("X-Test", "evil\nX-Injected: yes")];
    auto lfOnlyOutcome = fetchHttp(lfOnlyValue);
    assert(!lfOnlyOutcome.succeeded);
    assert(lfOnlyOutcome.failure.reason == FetchFailureReason.invalidHeader);

    FetchRequest nulValue;
    nulValue.url = resolved.value;
    nulValue.headers = [FetchHeader("X-Test", "bad\0value")];
    auto nulValueOutcome = fetchHttp(nulValue);
    assert(!nulValueOutcome.succeeded);
    assert(nulValueOutcome.failure.reason == FetchFailureReason.invalidHeader);

    FetchRequest crlfName;
    crlfName.url = resolved.value;
    crlfName.headers = [FetchHeader("X-Test\r\nX-Injected", "value")];
    auto crlfNameOutcome = fetchHttp(crlfName);
    assert(!crlfNameOutcome.succeeded);
    assert(crlfNameOutcome.failure.reason == FetchFailureReason.invalidHeader);

    FetchRequest colonName;
    colonName.url = resolved.value;
    colonName.headers = [FetchHeader("X-Test:Bad", "value")];
    auto colonNameOutcome = fetchHttp(colonName);
    assert(!colonNameOutcome.succeeded);
    assert(colonNameOutcome.failure.reason == FetchFailureReason.invalidHeader);

    FetchRequest spaceName;
    spaceName.url = resolved.value;
    spaceName.headers = [FetchHeader("X Test", "value")];
    auto spaceNameOutcome = fetchHttp(spaceName);
    assert(!spaceNameOutcome.succeeded);
    assert(spaceNameOutcome.failure.reason == FetchFailureReason.invalidHeader);

    // Control: the same target with a single *valid* header must actually
    // reach curl and fail with `transportError` (connection refused), not
    // `invalidHeader` -- proving the rejections above are really about the
    // bad header content, not about the unreachable target.
    FetchRequest validHeader;
    validHeader.url = resolved.value;
    validHeader.headers = [FetchHeader("X-Test", "fine")];
    auto validHeaderOutcome = fetchHttp(validHeader);
    assert(!validHeaderOutcome.succeeded);
    assert(validHeaderOutcome.failure.reason == FetchFailureReason.transportError);
}

unittest {
    // Real proof that a caller-supplied generic header actually reaches the
    // real curl transport and is received by a real peer -- mirroring this
    // module's own established real-loopback-TCP pattern above (the
    // `User-Agent` proof) rather than mocking curl. Also proves, in the same
    // real request, that `ifNoneMatch` keeps working unchanged side-by-side
    // with the new generic `headers` mechanism.
    import core.thread : Thread;
    import std.conv : to;
    import std.socket : AddressFamily, InternetAddress, SocketOption,
        SocketOptionLevel, TcpSocket;
    import std.string : indexOf;

    auto listener = new TcpSocket(AddressFamily.INET);
    scope(exit) listener.close();
    listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
    listener.bind(new InternetAddress("127.0.0.1", 0));
    listener.listen(1);
    immutable port = (cast(InternetAddress) listener.localAddress).port;

    string capturedRequest;
    auto worker = new Thread({
        auto client = listener.accept();
        scope(exit) client.close();
        ubyte[4_096] buffer;
        string received;
        while (received.indexOf("\r\n\r\n") < 0) {
            auto count = client.receive(buffer[]);
            if (count <= 0) break;
            received ~= cast(string) buffer[0 .. count].idup;
        }
        capturedRequest = received;
        enum string responseBody = "ok";
        client.send(cast(const(ubyte)[])("HTTP/1.1 200 OK\r\nContent-Length: " ~
            responseBody.length.to!string ~ "\r\nConnection: close\r\n\r\n" ~ responseBody));
    });
    worker.start();

    auto rawUrl = "http://127.0.0.1:" ~ port.to!string ~ "/probe";
    auto resolved = resolveWebUrl(rawUrl, rawUrl);
    assert(resolved.isResolved);

    FetchRequest request;
    request.url = resolved.value;
    request.limits.connectTimeoutMs = 500;
    request.limits.totalTimeoutMs = 2_000;
    request.ifNoneMatch = `"abc123"`;
    request.headers = [
        FetchHeader("X-Scrubbed-Test", "hello-world-42"),
        FetchHeader("X-Amz-Content-Sha256", "deadbeef"),
    ];

    auto outcome = fetchHttp(request);
    worker.join();

    assert(outcome.succeeded);
    assert(outcome.evidence.status == 200);
    assert(capturedRequest.indexOf("X-Scrubbed-Test: hello-world-42\r\n") >= 0,
        "http fetch: caller-supplied header not found on the wire");
    assert(capturedRequest.indexOf("X-Amz-Content-Sha256: deadbeef\r\n") >= 0,
        "http fetch: second caller-supplied header not found on the wire");
    assert(capturedRequest.indexOf("If-None-Match: \"abc123\"\r\n") >= 0,
        "http fetch: ifNoneMatch header not found on the wire alongside generic headers");
}

unittest {
    // Real proof, per issue #355's acceptance criteria: a `FetchRequest`
    // with `requestBody` set actually reaches the wire as a genuine POST
    // (method line, not just a setopt call), with the exact body bytes
    // following the header block -- not a mocked assertion. Mirrors this
    // module's established real-loopback-TCP pattern (the `User-Agent` and
    // header-transmission proofs above) rather than trusting curl's own
    // behavior on faith. The server keeps reading past the header/body
    // boundary until it has collected the full expected body length, since
    // the body may not arrive in the same `recv` as the headers.
    import core.thread : Thread;
    import std.conv : to;
    import std.socket : AddressFamily, InternetAddress, SocketOption,
        SocketOptionLevel, TcpSocket;
    import std.string : indexOf;

    auto listener = new TcpSocket(AddressFamily.INET);
    scope(exit) listener.close();
    listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
    listener.bind(new InternetAddress("127.0.0.1", 0));
    listener.listen(1);
    immutable port = (cast(InternetAddress) listener.localAddress).port;

    enum string requestBodyText = `{"hello":"world","n":42}`;
    immutable requestBodyBytes = cast(immutable(ubyte)[]) requestBodyText;

    string capturedRequest;
    auto worker = new Thread({
        auto client = listener.accept();
        scope(exit) client.close();
        ubyte[16_384] buffer;
        string received;
        while (received.indexOf("\r\n\r\n") < 0) {
            auto count = client.receive(buffer[]);
            if (count <= 0) break;
            received ~= cast(string) buffer[0 .. count].idup;
        }
        auto headerEnd = received.indexOf("\r\n\r\n") + 4;
        while (received.length - headerEnd < requestBodyBytes.length) {
            auto count = client.receive(buffer[]);
            if (count <= 0) break;
            received ~= cast(string) buffer[0 .. count].idup;
        }
        capturedRequest = received;
        enum string responseBody = "ok";
        client.send(cast(const(ubyte)[])("HTTP/1.1 200 OK\r\nContent-Length: " ~
            responseBody.length.to!string ~ "\r\nConnection: close\r\n\r\n" ~ responseBody));
    });
    worker.start();

    auto rawUrl = "http://127.0.0.1:" ~ port.to!string ~ "/probe";
    auto resolved = resolveWebUrl(rawUrl, rawUrl);
    assert(resolved.isResolved);

    FetchRequest request;
    request.url = resolved.value;
    request.limits.connectTimeoutMs = 500;
    request.limits.totalTimeoutMs = 2_000;
    request.requestBody = requestBodyBytes;
    request.headers = [FetchHeader("Content-Type", "application/json")];

    auto outcome = fetchHttp(request);
    worker.join();

    assert(outcome.succeeded);
    assert(outcome.evidence.status == 200);
    assert(capturedRequest.indexOf("POST /probe HTTP/1.1\r\n") == 0,
        "http fetch: request line is not a real POST to the expected path");
    assert(capturedRequest.indexOf("GET ") < 0,
        "http fetch: a GET line leaked into a POST request");
    assert(capturedRequest.indexOf("Content-Length: " ~
        requestBodyBytes.length.to!string ~ "\r\n") >= 0,
        "http fetch: Content-Length does not match the real request-body length");
    assert(capturedRequest.indexOf("Content-Type: application/json\r\n") >= 0,
        "http fetch: caller-supplied Content-Type header not found on the wire");
    assert(capturedRequest[$ - requestBodyBytes.length .. $] == requestBodyText,
        "http fetch: exact request-body bytes not found at the tail of the wire request");
}

unittest {
    // Regression proof, per issue #355's acceptance criteria: a
    // `FetchRequest` with no `requestBody` set (the zero-value default)
    // still issues a plain GET exactly as before #355, on the same real
    // loopback pattern used for the POST proof above -- not merely "the
    // field is empty" but that the real wire request line still reads GET.
    import core.thread : Thread;
    import std.conv : to;
    import std.socket : AddressFamily, InternetAddress, SocketOption,
        SocketOptionLevel, TcpSocket;
    import std.string : indexOf;

    auto listener = new TcpSocket(AddressFamily.INET);
    scope(exit) listener.close();
    listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
    listener.bind(new InternetAddress("127.0.0.1", 0));
    listener.listen(1);
    immutable port = (cast(InternetAddress) listener.localAddress).port;

    string capturedRequest;
    auto worker = new Thread({
        auto client = listener.accept();
        scope(exit) client.close();
        ubyte[4_096] buffer;
        string received;
        while (received.indexOf("\r\n\r\n") < 0) {
            auto count = client.receive(buffer[]);
            if (count <= 0) break;
            received ~= cast(string) buffer[0 .. count].idup;
        }
        capturedRequest = received;
        enum string responseBody = "ok";
        client.send(cast(const(ubyte)[])("HTTP/1.1 200 OK\r\nContent-Length: " ~
            responseBody.length.to!string ~ "\r\nConnection: close\r\n\r\n" ~ responseBody));
    });
    worker.start();

    auto rawUrl = "http://127.0.0.1:" ~ port.to!string ~ "/probe";
    auto resolved = resolveWebUrl(rawUrl, rawUrl);
    assert(resolved.isResolved);

    // Deliberately a default-initialized `FetchRequest` beyond `url`/
    // `limits`: `requestBody` is left at its zero value (`null`, `.length
    // == 0`).
    FetchRequest request;
    request.url = resolved.value;
    request.limits.connectTimeoutMs = 500;
    request.limits.totalTimeoutMs = 2_000;

    auto outcome = fetchHttp(request);
    worker.join();

    assert(outcome.succeeded);
    assert(outcome.evidence.status == 200);
    assert(capturedRequest.indexOf("GET /probe HTTP/1.1\r\n") == 0,
        "http fetch: a FetchRequest with no body set did not issue a plain GET");
    assert(capturedRequest.indexOf("POST ") < 0,
        "http fetch: a FetchRequest with no body set unexpectedly issued a POST");
    assert(capturedRequest.indexOf("Content-Length:") < 0,
        "http fetch: a bodyless GET unexpectedly carried a Content-Length header");
}

unittest {
    // Real proof, per issue #355's acceptance criteria: a request body
    // exceeding `FetchLimits.maxRequestBodyBytes` produces the typed
    // `requestBodyCapExceeded` failure, not a crash and not a silent
    // truncation -- and it does so *before* any request is attempted, using
    // this module's own established `http://127.0.0.1:1/`
    // guaranteed-connection-refused target (the same technique the
    // `invalidHeader` proof above uses): if the cap were checked first, the
    // outcome is `requestBodyCapExceeded` with no curl code at all; if the
    // cap were skipped and the oversized body actually reached curl, the
    // outcome would instead be `transportError` with a real nonzero curl
    // code from the refused connection.
    auto resolved = resolveWebUrl("http://127.0.0.1:1/", "http://127.0.0.1:1/");
    assert(resolved.isResolved);

    FetchRequest oversized;
    oversized.url = resolved.value;
    oversized.limits.maxRequestBodyBytes = 4;
    oversized.requestBody = cast(immutable(ubyte)[]) "this body is way over the cap";
    auto oversizedOutcome = fetchHttp(oversized);
    assert(!oversizedOutcome.succeeded);
    assert(oversizedOutcome.failure.reason == FetchFailureReason.requestBodyCapExceeded);
    assert(oversizedOutcome.failure.curlCode == 0);
    assert(oversizedOutcome.failure.httpStatus == 0);

    // Exactly at the cap must pass the gate (and then hit the real refused
    // connection, proving the gate isn't off-by-one in the wrong direction).
    FetchRequest atCap;
    atCap.url = resolved.value;
    atCap.limits.maxRequestBodyBytes = 4;
    atCap.requestBody = cast(immutable(ubyte)[]) "abcd";
    auto atCapOutcome = fetchHttp(atCap);
    assert(!atCapOutcome.succeeded);
    assert(atCapOutcome.failure.reason == FetchFailureReason.transportError);

    // Control: a body comfortably under the cap must also actually reach
    // curl and fail with `transportError`, not `requestBodyCapExceeded` --
    // proving the rejection above is really about the oversized body, not
    // about the unreachable target.
    FetchRequest underCap;
    underCap.url = resolved.value;
    underCap.requestBody = cast(immutable(ubyte)[]) "small";
    auto underCapOutcome = fetchHttp(underCap);
    assert(!underCapOutcome.succeeded);
    assert(underCapOutcome.failure.reason == FetchFailureReason.transportError);
}
