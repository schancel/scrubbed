/// Minimal synchronous HTTP(S) GET transport built on `s3lite.curl_ffi`.
///
/// This is this package's own HTTP transport -- it does not import or link
/// against scrubbed's `effects.http_fetch`/`effects.curl_ffi`. It supports
/// exactly what a single SigV4-signed (or unsigned) S3 GET needs: a URL, an
/// arbitrary caller-supplied header list, response status/headers/body
/// capture, and an optional custom CA bundle (used only by this package's
/// own loopback-TLS test fixture; real callers rely on the system default
/// trust store).
module s3lite.http;

import s3lite.curl_ffi;
import std.string : toStringz, indexOf, strip;
import std.conv : to;

/// One request header, name and value exactly as sent (no SigV4
/// canonicalization here -- that already happened in `s3lite.sigv4`).
struct RequestHeader {
    string name;
    string value;
}

/// A successfully-completed HTTP round trip: real status code, response
/// headers (in receipt order, duplicates preserved), and the raw body.
struct HttpResponse {
    int status;
    RequestHeader[] headers;
    ubyte[] body_;

    /// Case-insensitive header lookup; returns the first match or null.
    string header(string name) const {
        import std.uni : sicmp;
        foreach (h; headers)
            if (sicmp(h.name, name) == 0) return h.value;
        return null;
    }
}

/// Why the transport itself failed (never reached / never completed an
/// HTTP response at all) -- distinct from an HTTP-level error status, which
/// comes back as a normal `HttpResponse` for the caller to interpret.
enum TransportFailure {
    none,
    couldNotConnect,
    tlsVerificationFailed,
    timedOut,
    other,
}

struct HttpResult {
    bool ok;
    HttpResponse response;
    TransportFailure failure;
    string failureDetail; // libcurl's own strerror text; diagnostic only

    static HttpResult success(HttpResponse r) pure {
        return HttpResult(true, r, TransportFailure.none, null);
    }

    static HttpResult transportError(TransportFailure f, string detail) pure {
        return HttpResult(false, HttpResponse.init, f, detail);
    }
}

/// Optional knobs beyond the request line/headers -- used by this package's
/// own tests (custom CA bundle, DNS-free `host:port` override for loopback
/// fixtures) as well as real callers who need a connect timeout.
struct GetOptions {
    /// Path to a PEM CA bundle to trust instead of the system default.
    /// Only ever set by this package's own loopback-TLS test fixture.
    string caBundlePath;
    /// "host:actualPort:ip" entries applied via CURLOPT_RESOLVE, letting a
    /// test point a real virtual-hosted-style URL at a loopback server
    /// without needing real DNS. Empty for real callers.
    string[] resolveOverrides;
    /// When non-empty, a literal "scheme://host[:port]" origin substituted
    /// in place of the caller-computed URL's own origin, while everything
    /// from the path onward (path, query string) is preserved exactly as
    /// computed, and the `Host` header used for SigV4 signing still reflects
    /// the real virtual-hosted address -- the same technique
    /// `tests/loopback_fixture.d`'s plaintext section already uses by hand,
    /// generalized so `tests/put_list_loopback_fixture.d` and
    /// `tests/transfer_bulk_fixture.d` can exercise the real signed
    /// request-building path (including query strings, e.g. `ListObjectsV2`
    /// pagination) end to end against a plaintext loopback server with no
    /// TLS certificate machinery. Only ever set by this package's own test
    /// fixtures; never touched by a real caller.
    string urlOverride;
    int connectTimeoutMs = 5000;
    int totalTimeoutMs = 15000;
}

private extern(C) size_t writeBodyCallback(const(char)* ptr, size_t size, size_t nmemb, void* userdata) nothrow {
    auto buf = cast(ubyte[]*) userdata;
    auto n = size * nmemb;
    *buf ~= cast(ubyte[]) ptr[0 .. n];
    return n;
}

/// Read-cursor state for `CURLOPT_READFUNCTION` during a PUT upload: curl
/// calls back repeatedly, each time wanting up to `size*nmemb` more bytes
/// from wherever `pos` last left off.
private struct ReadCursor {
    const(ubyte)[] data;
    size_t pos;
}

private extern(C) size_t readBodyCallback(char* ptr, size_t size, size_t nmemb, void* userdata) nothrow {
    auto cur = cast(ReadCursor*) userdata;
    auto want = size * nmemb;
    auto remain = cur.data.length - cur.pos;
    auto n = want < remain ? want : remain;
    if (n > 0) {
        ptr[0 .. n] = cast(char[]) cur.data[cur.pos .. cur.pos + n];
        cur.pos += n;
    }
    return n;
}

private extern(C) size_t writeHeaderCallback(const(char)* ptr, size_t size, size_t nmemb, void* userdata) nothrow {
    auto headers = cast(RequestHeader[]*) userdata;
    auto n = size * nmemb;
    auto line = cast(string) ptr[0 .. n].idup;
    // Strip the trailing CRLF/LF; skip the status line and blank
    // separator lines, which contain no ':'.
    auto trimmed = line;
    while (trimmed.length && (trimmed[$ - 1] == '\n' || trimmed[$ - 1] == '\r'))
        trimmed = trimmed[0 .. $ - 1];
    auto colon = trimmed.indexOf(':');
    if (colon > 0) {
        auto name = trimmed[0 .. colon];
        auto value = trimmed[colon + 1 .. $].strip;
        *headers ~= RequestHeader(name, value);
    }
    return n;
}

/// Substitutes `urlOverride` (a literal "scheme://host[:port]" origin) for
/// `url`'s own origin, preserving everything from the path onward
/// unchanged. Falls back to prepending `urlOverride` verbatim if `url`
/// doesn't parse as an absolute "scheme://..." URL (defensive only --
/// every caller in this package always builds an absolute URL).
private string applyUrlOverride(string url, string urlOverride) pure {
    if (urlOverride.length == 0) return url;
    auto schemeSep = url.indexOf("://");
    if (schemeSep < 0) return urlOverride ~ url;
    auto pathStart = url.indexOf('/', schemeSep + 3);
    auto suffix = pathStart < 0 ? "" : url[pathStart .. $];
    return urlOverride ~ suffix;
}

unittest {
    assert(applyUrlOverride("https://bucket.s3.us-east-1.amazonaws.com/key", "") ==
        "https://bucket.s3.us-east-1.amazonaws.com/key");
    assert(applyUrlOverride("https://bucket.s3.us-east-1.amazonaws.com/key", "http://127.0.0.1:9000") ==
        "http://127.0.0.1:9000/key");
    assert(applyUrlOverride("https://bucket.s3.us-east-1.amazonaws.com/?list-type=2&max-keys=1",
        "http://127.0.0.1:9000") == "http://127.0.0.1:9000/?list-type=2&max-keys=1");
}

private void ensureCurlGlobalInit() {
    static bool globalInitDone = false;
    if (!globalInitDone) {
        curl_global_init(curlGlobalAll);
        globalInitDone = true;
    }
}

/// Applies every option common to a GET and a PUT: destination URL (or its
/// `urlOverride`), protocol allowlist, redirect policy, timeouts, real TLS
/// verification (plus the test-only CA bundle/DNS-override escape hatches),
/// request headers, and response header capture. Caller still wires up
/// method-specific bits (`CURLOPT_WRITEFUNCTION`/`CURLOPT_WRITEDATA` for the
/// response body always; `CURLOPT_UPLOAD`/`CURLOPT_READFUNCTION` only for a
/// PUT) and always calls `curl_easy_perform` itself, inside the same scope
/// that keeps `keepAlive`'s backing storage alive.
private struct EasySetup {
    CURL* easy;
    curl_slist* resolveList;
    curl_slist* headerList;
    string caz;

    void teardown() {
        if (resolveList !is null) curl_slist_free_all(resolveList);
        if (headerList !is null) curl_slist_free_all(headerList);
        if (easy !is null) curl_easy_cleanup(easy);
    }
}

private HttpResult setupCommon(string url, const(RequestHeader)[] headers, GetOptions options,
        out EasySetup setup) {
    ensureCurlGlobalInit();

    auto easy = curl_easy_init();
    if (easy is null)
        return HttpResult.transportError(TransportFailure.other, "curl_easy_init returned null");
    setup.easy = easy;

    auto dispatchUrl = applyUrlOverride(url, options.urlOverride);
    auto urlz = dispatchUrl.toStringz;
    curl_easy_setopt(easy, CURLOPT_URL, urlz);
    curl_easy_setopt(easy, CURLOPT_PROTOCOLS_STR, "http,https\0".ptr);
    curl_easy_setopt(easy, CURLOPT_REDIR_PROTOCOLS_STR, "http,https\0".ptr);
    curl_easy_setopt(easy, CURLOPT_FOLLOWLOCATION, 0L);
    curl_easy_setopt(easy, CURLOPT_MAXREDIRS, 0L);
    curl_easy_setopt(easy, CURLOPT_NOPROGRESS, 1L);
    curl_easy_setopt(easy, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(easy, CURLOPT_CONNECTTIMEOUT_MS, cast(long) options.connectTimeoutMs);
    curl_easy_setopt(easy, CURLOPT_TIMEOUT_MS, cast(long) options.totalTimeoutMs);
    // Real TLS verification, always on. The only overrides this package
    // exposes are a custom CA bundle and a literal dispatch-URL override
    // (both for its own loopback test fixtures) -- never a way to disable
    // verification.
    curl_easy_setopt(easy, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(easy, CURLOPT_SSL_VERIFYHOST, 2L);

    if (options.caBundlePath.length) {
        setup.caz = options.caBundlePath;
        curl_easy_setopt(easy, CURLOPT_CAINFO, setup.caz.toStringz);
    }

    foreach (entry; options.resolveOverrides)
        setup.resolveList = curl_slist_append(setup.resolveList, entry.toStringz);
    if (setup.resolveList !is null)
        curl_easy_setopt(easy, CURLOPT_RESOLVE, setup.resolveList);

    foreach (h; headers) {
        auto line = h.name ~ ": " ~ h.value;
        setup.headerList = curl_slist_append(setup.headerList, line.toStringz);
    }
    if (setup.headerList !is null)
        curl_easy_setopt(easy, CURLOPT_HTTPHEADER, setup.headerList);

    return HttpResult.success(HttpResponse.init); // ok placeholder; caller ignores on success path
}

private HttpResult finishPerform(CURL* easy, ref ubyte[] body_, ref RequestHeader[] responseHeaders) {
    auto code = curl_easy_perform(easy);
    if (code != CURLE_OK) {
        auto detail = curl_easy_strerror(code).to!string;
        return HttpResult.transportError(classifyCurlError(code), detail);
    }

    long statusCode;
    curl_easy_getinfo(easy, CURLINFO_RESPONSE_CODE, &statusCode);
    return HttpResult.success(HttpResponse(cast(int) statusCode, responseHeaders, body_));
}

/// Issues one synchronous HTTP(S) GET. Never throws for network-level
/// failure -- those come back as `HttpResult.transportError(...)`.
HttpResult httpGet(string url, const(RequestHeader)[] headers, GetOptions options) {
    EasySetup setup;
    auto setupResult = setupCommon(url, headers, options, setup);
    scope(exit) setup.teardown();
    if (!setupResult.ok) return setupResult;

    ubyte[] body_;
    RequestHeader[] responseHeaders;
    curl_easy_setopt(setup.easy, CURLOPT_WRITEFUNCTION, &writeBodyCallback);
    curl_easy_setopt(setup.easy, CURLOPT_WRITEDATA, &body_);
    curl_easy_setopt(setup.easy, CURLOPT_HEADERFUNCTION, &writeHeaderCallback);
    curl_easy_setopt(setup.easy, CURLOPT_HEADERDATA, &responseHeaders);

    return finishPerform(setup.easy, body_, responseHeaders);
}

/// Issues one synchronous HTTP(S) PUT with `body_` as the full request
/// payload (never chunked/streamed from disk -- this package's callers
/// already hold the bytes in memory, matching `PutObjectRequest.body_` in
/// `s3lite.client`). Never throws for network-level failure, same contract
/// as `httpGet`.
HttpResult httpPut(string url, const(RequestHeader)[] headers, const(ubyte)[] body_, GetOptions options) {
    EasySetup setup;
    auto setupResult = setupCommon(url, headers, options, setup);
    scope(exit) setup.teardown();
    if (!setupResult.ok) return setupResult;

    curl_easy_setopt(setup.easy, CURLOPT_UPLOAD, 1L);
    curl_easy_setopt(setup.easy, CURLOPT_INFILESIZE_LARGE, cast(long) body_.length);
    auto cursor = ReadCursor(body_, 0);
    curl_easy_setopt(setup.easy, CURLOPT_READFUNCTION, &readBodyCallback);
    curl_easy_setopt(setup.easy, CURLOPT_READDATA, &cursor);

    ubyte[] responseBody;
    RequestHeader[] responseHeaders;
    curl_easy_setopt(setup.easy, CURLOPT_WRITEFUNCTION, &writeBodyCallback);
    curl_easy_setopt(setup.easy, CURLOPT_WRITEDATA, &responseBody);
    curl_easy_setopt(setup.easy, CURLOPT_HEADERFUNCTION, &writeHeaderCallback);
    curl_easy_setopt(setup.easy, CURLOPT_HEADERDATA, &responseHeaders);

    return finishPerform(setup.easy, responseBody, responseHeaders);
}

private TransportFailure classifyCurlError(int code) pure {
    // include/curl/curl.h CURLcode values relevant to a GET's failure modes.
    switch (code) {
        case 7:  return TransportFailure.couldNotConnect;  // CURLE_COULDNT_CONNECT
        case 6:  return TransportFailure.couldNotConnect;  // CURLE_COULDNT_RESOLVE_HOST
        case 28: return TransportFailure.timedOut;          // CURLE_OPERATION_TIMEDOUT
        case 35: return TransportFailure.tlsVerificationFailed; // CURLE_SSL_CONNECT_ERROR
        case 51: return TransportFailure.tlsVerificationFailed; // CURLE_PEER_FAILED_VERIFICATION (old)
        case 60: return TransportFailure.tlsVerificationFailed; // CURLE_PEER_FAILED_VERIFICATION
        case 58: return TransportFailure.tlsVerificationFailed; // CURLE_SSL_CERTPROBLEM
        case 59: return TransportFailure.tlsVerificationFailed; // CURLE_SSL_CIPHER
        default: return TransportFailure.other;
    }
}
