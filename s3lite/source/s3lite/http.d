/// Convenience layer: one-call, whole-buffer HTTP(S) GET and PUT.
///
/// These forms collect the response headers and body into garbage-collected
/// arrays and open a fresh connection per call. They are built on the
/// streaming `s3lite.transport` interface (through `s3lite.curl_transport`)
/// and exist for callers and fixtures that want a whole response in hand.
/// Code that must not allocate, or that moves large bodies, uses the
/// transport -- or `s3lite.core` above it -- directly.
module s3lite.http;

import s3lite.curl_transport : CurlOptions, openCurlTransport;
import s3lite.transport : HttpCall, HttpHeader, HttpMethod, Transport, TransportResult;
import std.string : indexOf;

public import s3lite.transport : TransportFailure;

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

/// Presents a collector-using delegate under the `@nogc` type the transport
/// interface requires. The attribute is a compile-time promise only; this
/// convenience layer is where the package deliberately gives it up. The
/// delegate must still be `nothrow`.
package(s3lite) auto assumeNoGC(T)(T dg) {
    import std.traits : FunctionAttribute, SetFunctionAttributes, functionAttributes, functionLinkage;
    enum attrs = functionAttributes!T | FunctionAttribute.nogc;
    return cast(SetFunctionAttributes!(T, functionLinkage!T, attrs)) dg;
}

/// `GetOptions` as the per-transport settings the core takes.
package(s3lite) CurlOptions curlOptionsOf(GetOptions options) {
    CurlOptions o;
    o.caBundlePath = options.caBundlePath;
    o.resolveOverrides = options.resolveOverrides;
    o.connectTimeoutMs = options.connectTimeoutMs;
    o.totalTimeoutMs = options.totalTimeoutMs;
    return o;
}

private HttpResult exchange(HttpMethod method, string url, const(RequestHeader)[] headers,
        bool hasBody, const(ubyte)[] body_, GetOptions options) {
    Transport transport;
    auto opened = openCurlTransport(curlOptionsOf(options), transport);
    if (!opened.ok) return HttpResult.transportError(opened.failure, opened.detail.idup);
    scope(exit) transport.close();

    auto wireHeaders = new HttpHeader[headers.length];
    foreach (i, h; headers) wireHeaders[i] = HttpHeader(h.name, h.value);

    ubyte[] responseBody;
    RequestHeader[] responseHeaders;
    bool bodySent = false;

    HttpCall call;
    call.method = method;
    call.url = applyUrlOverride(url, options.urlOverride);
    call.headers = wireHeaders;
    call.hasBody = hasBody;
    call.bodyLength = body_.length;
    call.pull = (ref const(ubyte)[] chunk) @nogc nothrow {
        chunk = bodySent ? null : body_;
        bodySent = true;
        return true;
    };
    call.rewind = () @nogc nothrow { bodySent = false; return true; };
    call.onHeader = assumeNoGC((int status, scope const(char)[] name, scope const(char)[] value) nothrow {
        // Interim (1xx) responses are not the response the caller asked for.
        if (status >= 200) responseHeaders ~= RequestHeader(name.idup, value.idup);
    });
    call.onBody = assumeNoGC((int status, scope const(ubyte)[] chunk) nothrow {
        responseBody ~= chunk;
        return true;
    });

    auto result = transport.perform(call);
    if (!result.ok) return HttpResult.transportError(result.failure, result.detail.idup);
    return HttpResult.success(HttpResponse(result.status, responseHeaders, responseBody));
}

/// Issues one synchronous HTTP(S) GET. Never throws for network-level
/// failure -- those come back as `HttpResult.transportError(...)`.
HttpResult httpGet(string url, const(RequestHeader)[] headers, GetOptions options) {
    return exchange(HttpMethod.get, url, headers, false, null, options);
}

/// Issues one synchronous HTTP(S) PUT with `body_` as the full request
/// payload. Never throws for network-level failure, same contract as
/// `httpGet`.
HttpResult httpPut(string url, const(RequestHeader)[] headers, const(ubyte)[] body_, GetOptions options) {
    return exchange(HttpMethod.put, url, headers, true, body_, options);
}
