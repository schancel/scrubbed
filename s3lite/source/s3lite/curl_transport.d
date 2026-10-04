/// The blocking libcurl implementation of `s3lite.transport.Transport`.
///
/// One transport owns one libcurl easy handle for its whole life, so
/// consecutive exchanges to the same host reuse the connection (and its TLS
/// session) libcurl keeps cached on that handle. A transport serves one
/// exchange at a time and must not be shared between threads; give each
/// thread its own.
///
/// Memory: the request body is copied from the source's current chunk
/// straight into libcurl's own upload buffer, and response bytes are handed
/// to the sink straight out of libcurl's receive buffer. This module keeps
/// no body buffer of its own. What it does use is fixed:
///
///   - one small C-heap block per transport (`CurlState`), made at open and
///     freed at close;
///   - `maxLineBytes` of stack during `perform`, to NUL-terminate the URL
///     and each header line for libcurl;
///   - libcurl's internal allocations (its handle, its buffers, one list
///     node per request header), none of which grow with object size.
module s3lite.curl_transport;

import s3lite.curl_ffi;
import s3lite.transport;
import s3lite.fixed : indexOf, trim;

/// Largest URL, header line, CA bundle path or resolve entry this transport
/// accepts, in bytes, excluding the terminating NUL it adds. Anything longer
/// fails with `TransportFailure.requestTooLarge`.
enum size_t maxLineBytes = 16 * 1024 - 1;

/// Settings fixed for the life of one transport. The slices are read during
/// `openCurlTransport` only; libcurl keeps its own copies.
struct CurlOptions {
    /// PEM CA bundle to trust instead of the system default. TLS
    /// verification itself cannot be turned off.
    const(char)[] caBundlePath;
    /// "host:port:address" entries (libcurl's `CURLOPT_RESOLVE`), letting a
    /// name be pointed at a chosen address without DNS.
    const(char[])[] resolveOverrides;
    int connectTimeoutMs = 5000;
    /// Limit on one whole exchange. 0 means none, which is what a large
    /// object needs; `stallTimeoutSecs` then bounds a dead connection.
    int totalTimeoutMs = 0;
    /// Abandon an exchange that moves less than one byte per second for
    /// this long. 0 disables the check.
    int stallTimeoutSecs = 60;
}

private struct CurlState {
    CURL* easy;
    curl_slist* resolveList;
}

/// State for one exchange, on `curlPerform`'s stack.
private struct Exchange {
    CURL* easy;
    const(HttpCall)* call;
    const(ubyte)[] chunk; // unread remainder of the body chunk last pulled
    bool bodyEnded;
    bool aborted;
    bool rewindFailed;
}

private shared int globalInitState; // 0: not started, 1: in progress, 2: done

private void ensureCurlGlobalInit() @nogc nothrow {
    import core.atomic : atomicLoad, atomicStore, cas;
    import core.thread : Thread;

    if (atomicLoad(globalInitState) == 2) return;
    if (cas(&globalInitState, 0, 1)) {
        curl_global_init(curlGlobalAll);
        atomicStore(globalInitState, 2);
        return;
    }
    while (atomicLoad(globalInitState) != 2) Thread.yield();
}

/// Copies `text` into `dst` with a terminating NUL. False if it does not
/// fit or contains a NUL of its own.
private bool terminated(ref char[maxLineBytes + 1] dst, scope const(char)[] text) @nogc nothrow pure {
    if (text.length > maxLineBytes) return false;
    foreach (c; text) if (c == '\0') return false;
    dst[0 .. text.length] = text[];
    dst[text.length] = '\0';
    return true;
}

private int responseStatus(CURL* easy) @nogc nothrow {
    long status = 0;
    curl_easy_getinfo(easy, CURLINFO_RESPONSE_CODE, &status);
    return cast(int) status;
}

private extern(C) size_t readCallback(char* ptr, size_t size, size_t nmemb, void* userdata) @nogc nothrow {
    auto x = cast(Exchange*) userdata;
    immutable want = size * nmemb;
    size_t filled = 0;
    while (filled < want && !x.bodyEnded) {
        if (x.chunk.length == 0) {
            const(ubyte)[] next;
            if (!x.call.pull(next)) { x.aborted = true; return CURL_READFUNC_ABORT; }
            if (next.length == 0) { x.bodyEnded = true; break; }
            x.chunk = next;
        }
        immutable n = x.chunk.length < want - filled ? x.chunk.length : want - filled;
        ptr[filled .. filled + n] = cast(const(char)[]) x.chunk[0 .. n];
        x.chunk = x.chunk[n .. $];
        filled += n;
    }
    return filled;
}

private extern(C) int seekCallback(void* userdata, long offset, int origin) @nogc nothrow {
    auto x = cast(Exchange*) userdata;
    // libcurl asks for this only to resend a body from its first byte.
    if (offset == 0 && origin == 0 && x.call.rewind !is null && x.call.rewind()) {
        x.chunk = null;
        x.bodyEnded = false;
        return CURL_SEEKFUNC_OK;
    }
    x.rewindFailed = true;
    return CURL_SEEKFUNC_FAIL;
}

private extern(C) size_t writeCallback(const(char)* ptr, size_t size, size_t nmemb, void* userdata) @nogc nothrow {
    auto x = cast(Exchange*) userdata;
    immutable n = size * nmemb;
    if (n == 0 || x.call.onBody is null) return n;
    if (x.call.onBody(responseStatus(x.easy), cast(const(ubyte)[]) ptr[0 .. n])) return n;
    x.aborted = true;
    return size_t.max; // any value other than `n` abandons the transfer
}

private extern(C) size_t headerCallback(const(char)* ptr, size_t size, size_t nmemb, void* userdata) @nogc nothrow {
    auto x = cast(Exchange*) userdata;
    immutable n = size * nmemb;
    if (x.call.onHeader is null) return n;
    auto line = trim(ptr[0 .. n]);
    // Status lines and the blank separator carry no "name: value".
    immutable colon = indexOf(line, ':');
    if (colon > 0 && !(line.length >= 5 && line[0 .. 5] == "HTTP/"))
        x.call.onHeader(responseStatus(x.easy), line[0 .. colon], trim(line[colon + 1 .. $]));
    return n;
}

private TransportFailure classifyCurlError(int code) @nogc nothrow pure {
    // include/curl/curl.h CURLcode values.
    switch (code) {
        case 6:  return TransportFailure.couldNotConnect;       // CURLE_COULDNT_RESOLVE_HOST
        case 7:  return TransportFailure.couldNotConnect;       // CURLE_COULDNT_CONNECT
        case 28: return TransportFailure.timedOut;              // CURLE_OPERATION_TIMEDOUT
        case 35: return TransportFailure.tlsVerificationFailed; // CURLE_SSL_CONNECT_ERROR
        case 51: return TransportFailure.tlsVerificationFailed; // CURLE_PEER_FAILED_VERIFICATION (old)
        case 58: return TransportFailure.tlsVerificationFailed; // CURLE_SSL_CERTPROBLEM
        case 59: return TransportFailure.tlsVerificationFailed; // CURLE_SSL_CIPHER
        case 60: return TransportFailure.tlsVerificationFailed; // CURLE_PEER_FAILED_VERIFICATION
        case 65: return TransportFailure.bodyNotRewindable;     // CURLE_SEND_FAIL_REWIND
        default: return TransportFailure.other;
    }
}

private const(char)[] curlErrorText(int code) @nogc nothrow {
    import core.stdc.string : strlen;
    auto text = curl_easy_strerror(code);
    return text is null ? null : text[0 .. strlen(text)];
}

private TransportResult curlPerform(void* context, scope ref const HttpCall call) @nogc nothrow {
    auto state = cast(CurlState*) context;
    auto easy = state.easy;
    char[maxLineBytes + 1] line = void;

    if (!terminated(line, call.url))
        return TransportResult(TransportFailure.requestTooLarge, 0, 0, "URL exceeds the transport's line bound");
    curl_easy_setopt(easy, CURLOPT_URL, line.ptr);

    curl_slist* headerList;
    scope(exit) {
        // The handle outlives this list; never leave it pointing at freed nodes.
        curl_easy_setopt(easy, CURLOPT_HTTPHEADER, cast(curl_slist*) null);
        if (headerList !is null) curl_slist_free_all(headerList);
    }
    foreach (ref h; call.headers) {
        if (h.name.length + 2 + h.value.length > maxLineBytes)
            return TransportResult(TransportFailure.requestTooLarge, 0, 0,
                "header line exceeds the transport's line bound");
        line[0 .. h.name.length] = h.name[];
        line[h.name.length .. h.name.length + 2] = ": ";
        line[h.name.length + 2 .. h.name.length + 2 + h.value.length] = h.value[];
        line[h.name.length + 2 + h.value.length] = '\0';
        auto grown = curl_slist_append(headerList, line.ptr);
        if (grown is null)
            return TransportResult(TransportFailure.other, 0, 0, "curl_slist_append failed");
        headerList = grown;
    }
    curl_easy_setopt(easy, CURLOPT_HTTPHEADER, headerList);

    auto exchange = Exchange(easy, &call);
    curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, &writeCallback);
    curl_easy_setopt(easy, CURLOPT_WRITEDATA, &exchange);
    curl_easy_setopt(easy, CURLOPT_HEADERFUNCTION, &headerCallback);
    curl_easy_setopt(easy, CURLOPT_HEADERDATA, &exchange);

    if (call.hasBody) {
        if (call.pull is null)
            return TransportResult(TransportFailure.other, 0, 0, "request has a body but no source");
        curl_easy_setopt(easy, CURLOPT_UPLOAD, 1L);
        curl_easy_setopt(easy, CURLOPT_INFILESIZE_LARGE, cast(long) call.bodyLength);
        curl_easy_setopt(easy, CURLOPT_READFUNCTION, &readCallback);
        curl_easy_setopt(easy, CURLOPT_READDATA, &exchange);
        curl_easy_setopt(easy, CURLOPT_SEEKFUNCTION, &seekCallback);
        curl_easy_setopt(easy, CURLOPT_SEEKDATA, &exchange);
    } else {
        curl_easy_setopt(easy, CURLOPT_UPLOAD, 0L);
        curl_easy_setopt(easy, CURLOPT_HTTPGET, 1L);
    }

    immutable code = curl_easy_perform(easy);
    if (code != CURLE_OK) {
        auto failure = classifyCurlError(code);
        if (exchange.rewindFailed) failure = TransportFailure.bodyNotRewindable;
        else if (exchange.aborted) failure = TransportFailure.aborted;
        return TransportResult(failure, 0, code, curlErrorText(code));
    }
    return TransportResult(TransportFailure.none, responseStatus(easy), 0, null);
}

private void curlClose(void* context) @nogc nothrow {
    import core.stdc.stdlib : free;
    auto state = cast(CurlState*) context;
    if (state is null) return;
    if (state.easy !is null) curl_easy_cleanup(state.easy);
    if (state.resolveList !is null) curl_slist_free_all(state.resolveList);
    free(state);
}

/// Opens a libcurl transport. On success `transport` is open and the caller
/// owns it (hand it to `S3Client.open`, or call `transport.close()`); on
/// failure it is left closed and the returned result says why.
TransportResult openCurlTransport(scope const CurlOptions options, out Transport transport) @nogc nothrow {
    import core.stdc.stdlib : calloc;

    ensureCurlGlobalInit();

    auto state = cast(CurlState*) calloc(1, CurlState.sizeof);
    if (state is null)
        return TransportResult(TransportFailure.other, 0, 0, "out of memory");
    state.easy = curl_easy_init();
    if (state.easy is null) {
        curlClose(state);
        return TransportResult(TransportFailure.other, 0, 0, "curl_easy_init returned null");
    }
    auto easy = state.easy;

    curl_easy_setopt(easy, CURLOPT_PROTOCOLS_STR, "http,https\0".ptr);
    curl_easy_setopt(easy, CURLOPT_REDIR_PROTOCOLS_STR, "http,https\0".ptr);
    curl_easy_setopt(easy, CURLOPT_FOLLOWLOCATION, 0L);
    curl_easy_setopt(easy, CURLOPT_MAXREDIRS, 0L);
    curl_easy_setopt(easy, CURLOPT_NOPROGRESS, 1L);
    curl_easy_setopt(easy, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(easy, CURLOPT_CONNECTTIMEOUT_MS, cast(long) options.connectTimeoutMs);
    curl_easy_setopt(easy, CURLOPT_TIMEOUT_MS, cast(long) options.totalTimeoutMs);
    if (options.stallTimeoutSecs > 0) {
        curl_easy_setopt(easy, CURLOPT_LOW_SPEED_LIMIT, 1L);
        curl_easy_setopt(easy, CURLOPT_LOW_SPEED_TIME, cast(long) options.stallTimeoutSecs);
    }
    // Real TLS verification, always on. The only overrides are a custom CA
    // bundle and name-to-address pinning -- never a way to disable it.
    curl_easy_setopt(easy, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(easy, CURLOPT_SSL_VERIFYHOST, 2L);

    char[maxLineBytes + 1] line = void;
    if (options.caBundlePath.length) {
        if (!terminated(line, options.caBundlePath)) {
            curlClose(state);
            return TransportResult(TransportFailure.requestTooLarge, 0, 0, "CA bundle path is too long");
        }
        curl_easy_setopt(easy, CURLOPT_CAINFO, line.ptr);
    }
    foreach (entry; options.resolveOverrides) {
        curl_slist* grown = terminated(line, entry) ? curl_slist_append(state.resolveList, line.ptr) : null;
        if (grown is null) {
            curlClose(state);
            return TransportResult(TransportFailure.requestTooLarge, 0, 0, "resolve override could not be added");
        }
        state.resolveList = grown;
    }
    if (state.resolveList !is null)
        curl_easy_setopt(easy, CURLOPT_RESOLVE, state.resolveList);

    transport = Transport(state, &curlPerform, &curlClose);
    return TransportResult.init;
}

unittest {
    // Open/close with no network, and the closed-handle guard.
    Transport t;
    assert(!t.isOpen);
    assert(openCurlTransport(CurlOptions.init, t).ok && t.isOpen);
    t.close();
    assert(!t.isOpen);
    t.close(); // idempotent
    HttpCall call;
    assert(t.perform(call).failure == TransportFailure.other);
}

unittest {
    // An over-long URL is refused before libcurl sees it.
    Transport t;
    assert(openCurlTransport(CurlOptions.init, t).ok);
    scope(exit) t.close();
    static immutable char[maxLineBytes + 1] huge = 'a';
    HttpCall call;
    call.url = huge[];
    assert(t.perform(call).failure == TransportFailure.requestTooLarge);
}
