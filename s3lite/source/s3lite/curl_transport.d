/// The blocking libcurl implementation of `s3lite.transport.Transport`.
///
/// One transport owns one libcurl easy handle for its whole life, so
/// consecutive exchanges to the same host reuse the connection (and its TLS
/// session) libcurl keeps cached on that handle. A transport serves one
/// exchange at a time and must not be shared between threads; give each
/// thread its own.
///
/// The transport sends the method the call names (GET, PUT, HEAD, DELETE),
/// the path exactly as given (no "." or ".." collapsing), and refuses a
/// URL or header that contains a control byte before libcurl sees it.
///
/// Memory: the request body is copied from the source's current chunk
/// straight into libcurl's own upload buffer, and response bytes are handed
/// to the sink straight out of libcurl's receive buffer. This module keeps
/// no body buffer of its own. What it does use is fixed:
///
///   - one small C-heap block per transport (`CurlState`), made at open and
///     freed at close. It holds the state of the exchange in progress, and
///     it is the only thing libcurl's callbacks are ever pointed at: no
///     callback data refers to a stack frame, and every callback is
///     unregistered again before `perform` returns, by whichever path;
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

/// State of the exchange in progress. `call` is null between exchanges,
/// and every callback treats that as "nothing to do".
private struct Exchange {
    const(HttpCall)* call;
    const(ubyte)[] chunk; // unread remainder of the body chunk last pulled
    bool pulled;          // the source has been pulled from since its start
    bool bodyEnded;
    bool aborted;
    bool rewindFailed;
}

private struct CurlState {
    CURL* easy;
    curl_slist* resolveList;
    Exchange exchange;
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
    auto x = &(cast(CurlState*) userdata).exchange;
    if (x.call is null || !x.call.hasBody || x.call.pull is null) return 0;
    // libcurl does not stop at a failed rewind: it would go on to send the
    // rest of a body it could not restart, as if it were the whole of it.
    // Nothing more is pulled from the source once that has happened.
    if (x.rewindFailed) return CURL_READFUNC_ABORT;
    immutable want = size * nmemb;
    size_t filled = 0;
    while (filled < want && !x.bodyEnded) {
        if (x.chunk.length == 0) {
            const(ubyte)[] next;
            x.pulled = true;
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
    auto x = &(cast(CurlState*) userdata).exchange;
    // libcurl asks for this only to resend a body from its first byte.
    if (offset != 0 || origin != 0) return CURL_SEEKFUNC_FAIL;
    // With no body there is nothing to reposition.
    if (x.call is null || !x.call.hasBody) return CURL_SEEKFUNC_OK;
    // A source nobody has pulled from is at its start already. This is not
    // a formality: libcurl remembers a rewind it could not do and asks for
    // it again at the start of the *next* transfer on the handle, whose
    // body is a different one and has done nothing to deserve it.
    if (!x.pulled) return CURL_SEEKFUNC_OK;
    if (x.call.rewind !is null && x.call.rewind()) {
        // Whatever was left of the chunk in hand belongs to the old pass.
        x.chunk = null;
        x.bodyEnded = false;
        x.pulled = false;
        x.rewindFailed = false;
        return CURL_SEEKFUNC_OK;
    }
    x.rewindFailed = true;
    return CURL_SEEKFUNC_FAIL;
}

private extern(C) size_t writeCallback(const(char)* ptr, size_t size, size_t nmemb, void* userdata) @nogc nothrow {
    auto state = cast(CurlState*) userdata;
    auto x = &state.exchange;
    immutable n = size * nmemb;
    if (n == 0 || x.call is null || x.call.onBody is null) return n;
    if (x.call.onBody(responseStatus(state.easy), cast(const(ubyte)[]) ptr[0 .. n])) return n;
    x.aborted = true;
    return size_t.max; // any value other than `n` abandons the transfer
}

private extern(C) size_t headerCallback(const(char)* ptr, size_t size, size_t nmemb, void* userdata) @nogc nothrow {
    auto state = cast(CurlState*) userdata;
    auto x = &state.exchange;
    immutable n = size * nmemb;
    if (x.call is null || x.call.onHeader is null) return n;
    auto line = trim(ptr[0 .. n]);
    // Status lines and the blank separator carry no "name: value".
    immutable colon = indexOf(line, ':');
    if (colon > 0 && !(line.length >= 5 && line[0 .. 5] == "HTTP/"))
        x.call.onHeader(responseStatus(state.easy), line[0 .. colon], trim(line[colon + 1 .. $]));
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

private TransportResult refuse(TransportFailure failure, const(char)[] why) @nogc nothrow pure {
    return TransportResult(failure, 0, 0, why);
}

/// Registers the callbacks, all pointed at the heap state.
private void attachCallbacks(CurlState* state) @nogc nothrow {
    auto easy = state.easy;
    curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, &writeCallback);
    curl_easy_setopt(easy, CURLOPT_WRITEDATA, state);
    curl_easy_setopt(easy, CURLOPT_HEADERFUNCTION, &headerCallback);
    curl_easy_setopt(easy, CURLOPT_HEADERDATA, state);
    curl_easy_setopt(easy, CURLOPT_READFUNCTION, &readCallback);
    curl_easy_setopt(easy, CURLOPT_READDATA, state);
    curl_easy_setopt(easy, CURLOPT_SEEKFUNCTION, &seekCallback);
    curl_easy_setopt(easy, CURLOPT_SEEKDATA, state);
}

/// Unregisters every callback and its data, the header list, and the
/// exchange itself, so nothing registered for one call outlives it.
private void detachCallbacks(CurlState* state) @nogc nothrow {
    auto easy = state.easy;
    curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, cast(void*) null);
    curl_easy_setopt(easy, CURLOPT_WRITEDATA, cast(void*) null);
    curl_easy_setopt(easy, CURLOPT_HEADERFUNCTION, cast(void*) null);
    curl_easy_setopt(easy, CURLOPT_HEADERDATA, cast(void*) null);
    curl_easy_setopt(easy, CURLOPT_READFUNCTION, cast(void*) null);
    curl_easy_setopt(easy, CURLOPT_READDATA, cast(void*) null);
    curl_easy_setopt(easy, CURLOPT_SEEKFUNCTION, cast(void*) null);
    curl_easy_setopt(easy, CURLOPT_SEEKDATA, cast(void*) null);
    curl_easy_setopt(easy, CURLOPT_HTTPHEADER, cast(curl_slist*) null);
    curl_easy_setopt(easy, CURLOPT_CUSTOMREQUEST, cast(char*) null);
    state.exchange = Exchange.init;
}

private TransportResult curlPerform(void* context, scope ref const HttpCall call) @nogc nothrow {
    auto state = cast(CurlState*) context;
    auto easy = state.easy;
    char[maxLineBytes + 1] line = void;

    // Refuse what cannot be sent as described before libcurl sees any of it.
    if (hasControlBytes(call.url) || indexOf(call.url, ' ') >= 0)
        return refuse(TransportFailure.invalidCall, "URL contains a control byte or a space");
    foreach (ref h; call.headers)
        if (!isHeaderName(h.name) || hasControlBytes(h.value))
            return refuse(TransportFailure.invalidCall, "header name or value contains a control byte");
    if (call.hasBody && call.method != HttpMethod.put)
        return refuse(TransportFailure.invalidCall, "only PUT carries a request body");
    if (call.hasBody && call.pull is null)
        return refuse(TransportFailure.invalidCall, "request has a body but no source");
    if (call.hasBody && call.bodyLength > maxBodyLength)
        return refuse(TransportFailure.invalidCall, "body length exceeds maxBodyLength");

    if (!terminated(line, call.url))
        return refuse(TransportFailure.requestTooLarge, "URL exceeds the transport's line bound");

    // From here on the handle is being configured for this call; whatever
    // the exit, it is left with no callback, no header list and no call.
    curl_slist* headerList;
    scope(exit) {
        detachCallbacks(state);
        if (headerList !is null) curl_slist_free_all(headerList);
    }

    curl_easy_setopt(easy, CURLOPT_URL, line.ptr);
    foreach (ref h; call.headers) {
        if (h.name.length + 2 + h.value.length > maxLineBytes)
            return refuse(TransportFailure.requestTooLarge, "header line exceeds the transport's line bound");
        line[0 .. h.name.length] = h.name[];
        line[h.name.length .. h.name.length + 2] = ": ";
        line[h.name.length + 2 .. h.name.length + 2 + h.value.length] = h.value[];
        line[h.name.length + 2 + h.value.length] = '\0';
        auto grown = curl_slist_append(headerList, line.ptr);
        if (grown is null) return refuse(TransportFailure.other, "curl_slist_append failed");
        headerList = grown;
    }
    curl_easy_setopt(easy, CURLOPT_HTTPHEADER, headerList);

    state.exchange = Exchange(&call);
    attachCallbacks(state);

    // The method is the call's, stated outright. Start from a plain GET so
    // nothing of the previous exchange's verb survives.
    curl_easy_setopt(easy, CURLOPT_UPLOAD, 0L);
    curl_easy_setopt(easy, CURLOPT_NOBODY, 0L);
    curl_easy_setopt(easy, CURLOPT_HTTPGET, 1L);
    final switch (call.method) {
        case HttpMethod.get:
            break;
        case HttpMethod.put:
            curl_easy_setopt(easy, CURLOPT_UPLOAD, 1L);
            curl_easy_setopt(easy, CURLOPT_INFILESIZE_LARGE, call.hasBody ? cast(long) call.bodyLength : 0L);
            break;
        case HttpMethod.head:
            curl_easy_setopt(easy, CURLOPT_NOBODY, 1L);
            break;
        case HttpMethod.delete_:
            curl_easy_setopt(easy, CURLOPT_CUSTOMREQUEST, "DELETE\0".ptr);
            break;
    }

    immutable code = curl_easy_perform(easy);
    if (code != CURLE_OK) {
        auto failure = classifyCurlError(code);
        if (state.exchange.rewindFailed) failure = TransportFailure.bodyNotRewindable;
        else if (state.exchange.aborted) failure = TransportFailure.aborted;
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
    // Send the path exactly as given. Without this libcurl collapses "."
    // and ".." segments, so the request would name a different object from
    // the one that was signed.
    curl_easy_setopt(easy, CURLOPT_PATH_AS_IS, 1L);
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

unittest {
    // Text that could split a request or header line never reaches libcurl,
    // and a call that misdescribes itself is refused.
    Transport t;
    assert(openCurlTransport(CurlOptions.init, t).ok);
    scope(exit) t.close();

    HttpCall call;
    call.url = "http://127.0.0.1:1/a\r\nX: 1";
    assert(t.perform(call).failure == TransportFailure.invalidCall);
    call.url = "http://127.0.0.1:1/a b";
    assert(t.perform(call).failure == TransportFailure.invalidCall);

    call.url = "http://127.0.0.1:1/";
    foreach (bad; [HttpHeader("X-A", "v\r\nX-B: 1"), HttpHeader("X-A", "v\n"), HttpHeader("X-A", "v\0"),
            HttpHeader("X\r\n-A", "v"), HttpHeader("X A", "v"), HttpHeader("X:A", "v"), HttpHeader("", "v")]) {
        HttpHeader[1] headers = [bad];
        call.headers = headers[];
        assert(t.perform(call).failure == TransportFailure.invalidCall);
    }
    call.headers = null;

    bool pull(ref const(ubyte)[] chunk) @nogc nothrow { chunk = null; return true; }
    call.hasBody = true;
    call.pull = &pull;
    call.method = HttpMethod.get;
    assert(t.perform(call).failure == TransportFailure.invalidCall); // body on a GET
    call.method = HttpMethod.put;
    call.bodyLength = cast(ulong) long.max + 1;
    assert(t.perform(call).failure == TransportFailure.invalidCall);
    call.bodyLength = 0;
    call.pull = null;
    assert(t.perform(call).failure == TransportFailure.invalidCall);
}

unittest {
    // After an exchange -- here one that fails, with a body that cannot be
    // rewound -- nothing of it remains on the handle's state, and a
    // callback libcurl might still make (it keeps a pending rewind across
    // requests) finds nothing to act on: no stale call, no dead pointer.
    Transport t;
    assert(openCurlTransport(CurlOptions.init, t).ok);
    scope(exit) t.close();
    auto state = cast(CurlState*) t.context;

    static immutable ubyte[4] bytes = [1, 2, 3, 4];
    int pulls;
    bool pull(ref const(ubyte)[] chunk) @nogc nothrow { chunk = pulls++ == 0 ? bytes[] : null; return true; }
    {
        // The call lives in an inner scope: once it is gone, any pointer
        // to it would dangle.
        HttpCall call;
        call.method = HttpMethod.put;
        call.url = "http://127.0.0.1:1/unreachable";
        call.hasBody = true;
        call.bodyLength = bytes.length;
        call.pull = &pull;
        assert(t.perform(call).failure == TransportFailure.couldNotConnect);
    }
    assert(state.exchange == Exchange.init);

    char[8] buffer;
    assert(seekCallback(state, 0, 0) == CURL_SEEKFUNC_OK);
    assert(readCallback(buffer.ptr, 1, buffer.length, state) == 0);
    assert(writeCallback(buffer.ptr, 1, buffer.length, state) == buffer.length);
    assert(headerCallback("X: y\r\n".ptr, 1, 6, state) == 6);
    assert(state.exchange == Exchange.init && pulls == 0);

    // The same holds after a call that is refused before it starts.
    HttpCall bad;
    bad.url = "http://127.0.0.1:1/a b";
    assert(t.perform(bad).failure == TransportFailure.invalidCall);
    assert(state.exchange == Exchange.init);
}

unittest {
    // A seek to the start of an exchange whose source has not been pulled
    // from succeeds without touching the source, rewindable or not: it is
    // libcurl settling a rewind left over from an earlier transfer. Once
    // the source has been pulled from, the seek is a real rewind.
    Transport t;
    assert(openCurlTransport(CurlOptions.init, t).ok);
    scope(exit) t.close();
    auto state = cast(CurlState*) t.context;

    static immutable ubyte[4] bytes = [1, 2, 3, 4];
    int pulls, rewinds;
    bool pull(ref const(ubyte)[] chunk) @nogc nothrow { chunk = pulls++ == 0 ? bytes[] : null; return true; }
    bool rewind() @nogc nothrow { rewinds++; pulls = 0; return true; }

    HttpCall call;
    call.method = HttpMethod.put;
    call.hasBody = true;
    call.bodyLength = bytes.length;
    call.pull = &pull;
    char[8] buffer;

    // Single-pass body, fresh exchange.
    state.exchange = Exchange(&call);
    assert(seekCallback(state, 0, 0) == CURL_SEEKFUNC_OK);
    assert(!state.exchange.rewindFailed && pulls == 0);
    assert(readCallback(buffer.ptr, 1, 2, state) == 2); // the body then goes out as usual
    // ... and after that the same seek is a rewind this body cannot do.
    assert(seekCallback(state, 0, 0) == CURL_SEEKFUNC_FAIL && state.exchange.rewindFailed);
    assert(readCallback(buffer.ptr, 1, 2, state) == CURL_READFUNC_ABORT);

    // Rewindable body, fresh exchange: no needless rewind.
    pulls = 0;
    call.rewind = &rewind;
    state.exchange = Exchange(&call);
    assert(seekCallback(state, 0, 0) == CURL_SEEKFUNC_OK && rewinds == 0);
    assert(readCallback(buffer.ptr, 1, 2, state) == 2);
    assert(seekCallback(state, 0, 0) == CURL_SEEKFUNC_OK && rewinds == 1);
    assert(state.exchange.chunk.length == 0 && !state.exchange.pulled);
    // Straight after a rewind the source is at its start again.
    assert(seekCallback(state, 0, 0) == CURL_SEEKFUNC_OK && rewinds == 1);
    assert(readCallback(buffer.ptr, 1, buffer.length, state) == 4 && buffer[0 .. 4] == cast(const(char)[]) bytes[]);

    // A call with no body has nothing to rewind, whatever state says: its
    // rewind delegate, if it carries one, is never called.
    HttpCall bodiless;
    bodiless.method = HttpMethod.get;
    bodiless.rewind = &rewind;
    state.exchange = Exchange(&bodiless);
    state.exchange.pulled = true;
    assert(seekCallback(state, 0, 0) == CURL_SEEKFUNC_OK && rewinds == 1);
    state.exchange = Exchange(&call);

    // Anything but "to the start" is not something this transport does.
    assert(seekCallback(state, 1, 0) == CURL_SEEKFUNC_FAIL);
    state.exchange = Exchange.init;
}
