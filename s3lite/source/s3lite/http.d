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
    int connectTimeoutMs = 5000;
    int totalTimeoutMs = 15000;
}

private extern(C) size_t writeBodyCallback(const(char)* ptr, size_t size, size_t nmemb, void* userdata) nothrow {
    auto buf = cast(ubyte[]*) userdata;
    auto n = size * nmemb;
    *buf ~= cast(ubyte[]) ptr[0 .. n];
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

/// Issues one synchronous HTTP(S) GET. Never throws for network-level
/// failure -- those come back as `HttpResult.transportError(...)`.
HttpResult httpGet(string url, const(RequestHeader)[] headers, GetOptions options) {
    static bool globalInitDone = false;
    if (!globalInitDone) {
        curl_global_init(curlGlobalAll);
        globalInitDone = true;
    }

    auto easy = curl_easy_init();
    if (easy is null)
        return HttpResult.transportError(TransportFailure.other, "curl_easy_init returned null");
    scope(exit) curl_easy_cleanup(easy);

    auto urlz = url.toStringz;
    curl_easy_setopt(easy, CURLOPT_URL, urlz);
    curl_easy_setopt(easy, CURLOPT_PROTOCOLS_STR, "http,https\0".ptr);
    curl_easy_setopt(easy, CURLOPT_REDIR_PROTOCOLS_STR, "http,https\0".ptr);
    curl_easy_setopt(easy, CURLOPT_FOLLOWLOCATION, 0L);
    curl_easy_setopt(easy, CURLOPT_MAXREDIRS, 0L);
    curl_easy_setopt(easy, CURLOPT_NOPROGRESS, 1L);
    curl_easy_setopt(easy, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(easy, CURLOPT_CONNECTTIMEOUT_MS, cast(long) options.connectTimeoutMs);
    curl_easy_setopt(easy, CURLOPT_TIMEOUT_MS, cast(long) options.totalTimeoutMs);
    // Real TLS verification, always on. The only override this package
    // exposes is a custom CA bundle (for its own loopback fixture) -- never
    // a way to disable verification.
    curl_easy_setopt(easy, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(easy, CURLOPT_SSL_VERIFYHOST, 2L);

    string caz; // keep alive for the duration of the call
    if (options.caBundlePath.length) {
        caz = options.caBundlePath;
        curl_easy_setopt(easy, CURLOPT_CAINFO, caz.toStringz);
    }

    curl_slist* resolveList = null;
    scope(exit) if (resolveList !is null) curl_slist_free_all(resolveList);
    foreach (entry; options.resolveOverrides)
        resolveList = curl_slist_append(resolveList, entry.toStringz);
    if (resolveList !is null)
        curl_easy_setopt(easy, CURLOPT_RESOLVE, resolveList);

    curl_slist* headerList = null;
    scope(exit) if (headerList !is null) curl_slist_free_all(headerList);
    foreach (h; headers) {
        auto line = h.name ~ ": " ~ h.value;
        headerList = curl_slist_append(headerList, line.toStringz);
    }
    if (headerList !is null)
        curl_easy_setopt(easy, CURLOPT_HTTPHEADER, headerList);

    ubyte[] body_;
    RequestHeader[] responseHeaders;
    curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, &writeBodyCallback);
    curl_easy_setopt(easy, CURLOPT_WRITEDATA, &body_);
    curl_easy_setopt(easy, CURLOPT_HEADERFUNCTION, &writeHeaderCallback);
    curl_easy_setopt(easy, CURLOPT_HEADERDATA, &responseHeaders);

    auto code = curl_easy_perform(easy);
    if (code != CURLE_OK) {
        auto detail = curl_easy_strerror(code).to!string;
        return HttpResult.transportError(classifyCurlError(code), detail);
    }

    long statusCode;
    curl_easy_getinfo(easy, CURLINFO_RESPONSE_CODE, &statusCode);
    return HttpResult.success(HttpResponse(cast(int) statusCode, responseHeaders, body_));
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
