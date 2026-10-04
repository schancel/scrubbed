/// The transport seam: everything the S3 core needs from an HTTP
/// implementation, and nothing else.
///
/// A transport performs one HTTP exchange at a time. The request is a
/// method, an absolute URL, a header list and, optionally, a body the
/// transport *pulls* in chunks as the connection accepts them. The response
/// is pushed back through two delegates as it arrives: one call per header,
/// one call per piece of body. No part of the request or the response is
/// ever handed over as a whole buffer, so neither side of this interface
/// holds memory proportional to an object.
///
/// The surface is one function pointer plus a context pointer (`Transport`)
/// and the plain-data `HttpCall`, all `@nogc nothrow`. `s3lite.curl_transport`
/// implements it over a blocking libcurl easy handle. A different
/// implementation -- an event loop, a test double -- supplies the same two
/// pointers; the core never names libcurl.
module s3lite.transport;

/// Why an exchange produced no usable HTTP response. An HTTP error status is
/// not a transport failure: it comes back as `TransportResult.status` with
/// `failure == none`.
enum TransportFailure {
    none,
    couldNotConnect,
    tlsVerificationFailed,
    timedOut,
    other,
    /// A body source or a response sink asked for the exchange to stop.
    aborted,
    /// The transport had to resend the request body from the start (for
    /// example a reused connection turned out to be dead) and the body
    /// source could not be rewound.
    bodyNotRewindable,
    /// The URL or a header line exceeds the transport's fixed bounds.
    requestTooLarge,
    /// The call cannot be sent as described: a control byte in the URL or
    /// in a header, a body on a method that takes none, or a body length
    /// the transport cannot declare.
    invalidCall,
}

/// The verb of an exchange. A transport sends exactly this method; it does
/// not infer one from whether there is a body. Only `put` carries a
/// request body.
enum HttpMethod : ubyte {
    get,
    put,
    head,
    delete_,
}

/// Largest request body length a call may declare.
enum ulong maxBodyLength = long.max;

/// True if `text` could end or split a header line or a request line: any
/// control byte (CR, LF, NUL and the rest below 0x20) or DEL. Transports
/// refuse such text with `TransportFailure.invalidCall`.
bool hasControlBytes(scope const(char)[] text) @nogc nothrow pure {
    foreach (c; text) if (c < 0x20 || c == 0x7f) return true;
    return false;
}

/// True if `name` is a usable header name: non-empty, visible ASCII, no
/// separator a header line gives meaning to.
bool isHeaderName(scope const(char)[] name) @nogc nothrow pure {
    if (name.length == 0) return false;
    foreach (c; name) if (c <= 0x20 || c >= 0x7f || c == ':') return false;
    return true;
}

/// One header, name and value exactly as sent or received.
struct HttpHeader {
    const(char)[] name;
    const(char)[] value;
}

/// Request body, pull form. Each call sets `chunk` to the next piece of the
/// body and returns true; an empty `chunk` means the body is complete.
/// Returning false abandons the request. A chunk must stay valid only until
/// the next call, so one buffer may be refilled and handed out repeatedly.
alias BodyPull = bool delegate(ref const(ubyte)[] chunk) @nogc nothrow;

/// Repositions a body source at its first byte. Returns false if it cannot.
alias BodyRewind = bool delegate() @nogc nothrow;

/// Called once per response header line. `status` is the status of the
/// response the header belongs to (interim 1xx responses included).
alias HeaderHandler = void delegate(int status, scope const(char)[] name,
    scope const(char)[] value) @nogc nothrow;

/// Called for each piece of response body, in order. Returning false
/// abandons the exchange.
alias BodyHandler = bool delegate(int status, scope const(ubyte)[] chunk) @nogc nothrow;

/// One HTTP exchange. All slices and delegates are borrowed for the duration
/// of `Transport.perform` only.
struct HttpCall {
    HttpMethod method;
    const(char)[] url;
    const(HttpHeader)[] headers;

    /// Set, with `method == put`, to send a body. `bodyLength` is the exact
    /// number of bytes `pull` will produce (at most `maxBodyLength`) and is
    /// sent as `Content-Length`. A `put` without it sends an empty body.
    bool hasBody;
    ulong bodyLength;
    BodyPull pull;
    /// Null when the body can only be read once.
    BodyRewind rewind;

    HeaderHandler onHeader; /// may be null
    BodyHandler onBody;     /// may be null: the body is then discarded
}

struct TransportResult {
    TransportFailure failure;
    /// HTTP status of the final response; 0 when `failure != none`.
    int status;
    /// The implementation's own error number (a `CURLcode` for the libcurl
    /// transport); diagnostic only.
    int nativeCode;
    /// Static, NUL-free description of `nativeCode`; diagnostic only.
    const(char)[] detail;

    bool ok() const @nogc nothrow pure { return failure == TransportFailure.none; }
}

/// A transport instance: a context pointer and the two operations on it.
/// The value is a handle; copying it does not copy the connection. Whoever
/// holds the handle last calls `close` exactly once.
struct Transport {
    void* context;
    TransportResult function(void* context, scope ref const HttpCall call) @nogc nothrow performFn;
    void function(void* context) @nogc nothrow closeFn;

    bool isOpen() const @nogc nothrow pure { return performFn !is null; }

    TransportResult perform(scope ref const HttpCall call) @nogc nothrow {
        if (performFn is null)
            return TransportResult(TransportFailure.other, 0, 0, "transport is not open");
        return performFn(context, call);
    }

    /// Releases the connection and everything the transport holds. Safe to
    /// call on a closed or never-opened handle.
    void close() @nogc nothrow {
        if (closeFn !is null) closeFn(context);
        this = Transport.init;
    }
}
