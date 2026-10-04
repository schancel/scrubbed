/// The S3 core: `PutObject`, `GetObject` and `ListObjectsV2` as streaming,
/// `@nogc nothrow` operations on a client value that owns its connection.
///
/// What this module promises:
///
///   - **No allocation proportional to an object or a listing.** An upload
///     body is pulled chunk by chunk from a range or delegate; a download
///     is pushed chunk by chunk into a sink; a listing entry is handed to a
///     callback and then forgotten.
///   - **No collector, no exceptions.** Every operation is `@nogc nothrow`
///     and reports its outcome as a value (`S3Status` inside each result).
///     Results carry their text inline, so they can be copied to another
///     thread and outlive every buffer involved.
///   - **Memory comes from the caller, with stated bounds.** A client is
///     given one work buffer at `open` (`minWorkBytes` ..
///     `recommendedWorkBytes`) in which each request's URL, header values,
///     canonical request and signature are built, and in which an error
///     response body is captured. A listing takes an entry buffer
///     (`recommendedListEntryBuffer`). A request that does not fit fails
///     with `FailureKind.bufferTooSmall`; nothing is truncated or grown.
///   - **One connection, reused.** A client owns its `Transport` handle
///     from `open` to `close`, so consecutive requests to a bucket share a
///     connection.
///
/// A client is single-threaded: one request at a time, one thread at a
/// time. Programs that transfer in parallel give each thread its own client
/// and work buffer.
///
/// Operations are single-shot. There is no retry, backoff or concurrency
/// here; `s3lite.transfer` layers those on top, and `s3lite.client` offers
/// the one-call, whole-buffer convenience forms.
module s3lite.core;

import s3lite.fixed : InlineText, Writer, equalIgnoreCase, indexOf, parseUnsigned, startsWith;
import s3lite.sigv4;
import s3lite.transport;
import s3lite.xml_error : parseS3Error;
import s3lite.xml_list;
import std.range.primitives : ElementType, empty, front, isForwardRange, isInputRange, isOutputRange,
    popFront, save;

public import s3lite.sigv4 : AmzTime;
public import s3lite.transport : BodyPull, BodyRewind, Transport, TransportFailure;
public import s3lite.xml_list : ListEntryCallback, S3ObjectView, minListEntryBuffer,
    recommendedListEntryBuffer;

/// Smallest work buffer `S3Client.open` accepts.
enum size_t minWorkBytes = 2048;

/// A work buffer of this size holds any request these operations can form
/// within S3's own limits (1024-byte keys and prefixes, a continuation
/// token of `maxContinuationToken` bytes) with room to capture an error
/// body. One request needs about three times its host, encoded path and
/// encoded query, plus 1 KiB; most need well under 4 KiB.
enum size_t recommendedWorkBytes = 32 * 1024;

/// Longest continuation token a `ListContinuation` holds.
enum size_t maxContinuationToken = 2048;

/// SigV4 credentials. `Credentials.init` (both empty) means "do not sign":
/// the request is sent with no `Authorization` header, which only a public
/// object or a test fixture accepts.
struct Credentials {
    const(char)[] accessKeyId;
    const(char)[] secretAccessKey;

    bool isSet() const @nogc nothrow pure {
        return accessKeyId.length > 0 && secretAccessKey.length > 0;
    }
}

enum FailureKind {
    notFound,           /// S3's NoSuchKey/NoSuchBucket, or a plain HTTP 404
    forbidden,          /// S3's AccessDenied, or a plain HTTP 403
    malformedResponse,  /// a response whose shape is not what S3 documents
    transportError,     /// no HTTP response was obtained (DNS/TLS/connect/timeout)
    other,              /// an S3 error that was parsed but is not classified above
    bufferTooSmall,     /// a caller-supplied buffer cannot hold what the request needs
    invalidRequest,     /// the arguments cannot form a request (nothing was sent)
    aborted,            /// a body source, sink or listing callback stopped the request
    bodyLengthMismatch, /// an upload body did not produce exactly its declared length
}

/// Outcome of one operation. A plain value: no pointers, no borrowed
/// memory.
struct S3Status {
    bool ok;
    FailureKind kind;                /// meaningful only when `!ok`
    int httpStatus;                  /// 0 if no HTTP response was received
    TransportFailure transport;      /// set when `kind == transportError` or `aborted`
    int transportCode;               /// the transport's own error number; diagnostic
    InlineText!64 code;              /// S3's `<Code>`, "" if no error body was parsed
    InlineText!256 message;          /// S3's `<Message>`, or a diagnostic

    private static S3Status failure(FailureKind kind, scope const(char)[] message, int httpStatus = 0)
            @nogc nothrow pure {
        S3Status s;
        s.kind = kind;
        s.httpStatus = httpStatus;
        s.message.set(message);
        return s;
    }
}

/// How the `x-amz-content-sha256` value of an upload is decided. There is
/// no default: `PayloadHash.init` is rejected, so every upload states its
/// policy.
struct PayloadHash {
    private enum Kind : ubyte { unset, unsigned, sha256 }
    private Kind kind_;
    private char[64] hex_ = '0';

@nogc nothrow pure:

    /// The body is not covered by the request signature
    /// (`UNSIGNED-PAYLOAD`). Nothing is hashed, so the body need not be
    /// read before it is sent. Integrity in transit then rests on TLS.
    static PayloadHash unsigned() {
        PayloadHash h;
        h.kind_ = Kind.unsigned;
        return h;
    }

    /// The body's SHA-256, computed by the caller.
    static PayloadHash sha256(scope const ubyte[32] digest) {
        PayloadHash h;
        h.kind_ = Kind.sha256;
        h.hex_ = hexOf(digest);
        return h;
    }

    /// The body's SHA-256 as 64 hex digits (either case). Anything else
    /// yields an unset policy, which the operation rejects.
    static PayloadHash sha256Hex(scope const(char)[] hex) {
        PayloadHash h;
        if (hex.length != 64) return h;
        foreach (i, c; hex) {
            if (c >= 'A' && c <= 'F') h.hex_[i] = cast(char)(c + 32);
            else if ((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) h.hex_[i] = c;
            else return PayloadHash.init;
        }
        h.kind_ = Kind.sha256;
        return h;
    }

    /// Hashes a body that is already whole in memory.
    static PayloadHash ofBytes(scope const(ubyte)[] wholeBody) {
        PayloadHash h;
        h.kind_ = Kind.sha256;
        h.hex_ = .sha256Hex(wholeBody);
        return h;
    }

    bool isSet() const { return kind_ != Kind.unset; }
    bool isSigned() const { return kind_ == Kind.sha256; }

    /// The header value: 64 hex digits, or `UNSIGNED-PAYLOAD`.
    const(char)[] headerValue() const return {
        return kind_ == Kind.sha256 ? hex_[] : unsignedPayload;
    }
}

/// Which bytes of an object a download asks for. `ByteRange.init` is the
/// whole object.
struct ByteRange {
    private enum Kind : ubyte { whole, span, from, last }
    private Kind kind_;
    private ulong a_, b_;

@nogc nothrow pure:

    static ByteRange whole() { return ByteRange.init; }

    /// Bytes `first` through `lastInclusive`.
    static ByteRange bytes(ulong first, ulong lastInclusive) {
        return ByteRange(Kind.span, first, lastInclusive);
    }

    /// From byte `first` to the end; resumes a download that stopped there.
    static ByteRange from(ulong first) { return ByteRange(Kind.from, first, 0); }

    /// The final `count` bytes.
    static ByteRange last(ulong count) { return ByteRange(Kind.last, count, 0); }

    bool isWhole() const { return kind_ == Kind.whole; }
    private bool isValid() const { return kind_ != Kind.span || a_ <= b_; }

    private void headerValueInto(ref Writer w) const {
        w.put("bytes=");
        final switch (kind_) {
            case Kind.whole: break;
            case Kind.span: w.putUnsigned(a_); w.put('-'); w.putUnsigned(b_); break;
            case Kind.from: w.putUnsigned(a_); w.put('-'); break;
            case Kind.last: w.put('-'); w.putUnsigned(a_); break;
        }
    }
}

/// An upload body in pull form.
///
/// `pull` hands out the body one chunk at a time (see
/// `s3lite.transport.BodyPull`): a chunk stays valid until the next pull,
/// an empty chunk ends the body, and after the end every further pull must
/// report the end again. `length` is the exact total, which S3 requires
/// before the first byte.
///
/// `rewind`, when not null, repositions the source at its first byte. It is
/// what makes a body retryable: the transport uses it if it must resend
/// from the start within one request, and a caller that retries a failed
/// `putObject` calls it (or passes a fresh source) first. A source with no
/// `rewind` is sent once.
struct BodySource {
    ulong length;
    BodyPull pull;
    BodyRewind rewind;
}

/// A whole in-memory body as a `BodySource`: one chunk, rewindable. Keep
/// the `SliceBody` alive (and unmoved) while its `source` is in use.
struct SliceBody {
    const(ubyte)[] data;
    private bool sent;

@nogc nothrow:
    BodySource source() return {
        return BodySource(data.length, &pull, &rewind);
    }

    private bool pull(ref const(ubyte)[] chunk) {
        chunk = sent ? null : data;
        sent = true;
        return true;
    }

    private bool rewind() { sent = false; return true; }
}

/// True for an input range whose elements are chunks of bytes.
enum isChunkRange(R) = isInputRange!R && is(ElementType!R : const(ubyte)[]);

/// Adapts a chunk range to `BodySource`. A forward range is walked through
/// a `save`d copy and can be rewound; an input range is consumed in place
/// and cannot.
private struct RangeBody(R) {
    static if (isForwardRange!R) {
        R start;
        R current;
    } else {
        R* current_;
        ref R current() { return *current_; }
    }
    bool handedOut; // `current.front` was given out and not yet popped

    bool pull(ref const(ubyte)[] chunk) {
        while (true) {
            if (handedOut) { current.popFront(); handedOut = false; }
            if (current.empty) { chunk = null; return true; }
            chunk = current.front;
            handedOut = true;
            if (chunk.length) return true; // an empty element is not the end
        }
    }

    static if (isForwardRange!R)
    bool rewind() {
        current = start.save;
        handedOut = false;
        return true;
    }
}

/// Receives a download in order, one chunk at a time. A chunk is valid only
/// during the call. Returning false stops the download.
alias BodySink = bool delegate(scope const(ubyte)[] chunk) @nogc nothrow;

struct PutResult {
    S3Status status;
    InlineText!128 etag; /// as S3 sends it, quotes included
    ulong bytesSent;     /// body bytes handed to the transport

    bool ok() const @nogc nothrow pure { return status.ok; }
}

struct GetResult {
    S3Status status;
    InlineText!128 etag;
    InlineText!128 contentType;
    bool partial;         /// the response was 206 Partial Content
    bool hasContentLength;
    ulong contentLength;  /// length of this response body, when the server stated it
    bool hasTotalSize;
    ulong totalSize;      /// size of the whole object, when known
    /// Bytes given to the sink. On failure this is how far the download
    /// got: resume with `ByteRange.from(start + bytesDelivered)`.
    ulong bytesDelivered;

    bool ok() const @nogc nothrow pure { return status.ok; }
}

struct ListOptions {
    const(char)[] prefix;
    const(char)[] delimiter;
    uint maxKeys = 1000; /// entries per page; S3 caps this at 1000
}

/// Where a listing has got to. Start with `ListContinuation.init`; each
/// successful `listObjectsV2` call advances it, and `done` turns true after
/// the last page. A failed call leaves it untouched, so the same page can
/// be asked for again. The token is stored inline: the value can be kept,
/// copied or persisted to resume a listing later.
struct ListContinuation {
    private char[maxContinuationToken] token_ = '\0';
    private ushort length_;
    bool done;

@nogc nothrow pure:
    /// The token the next call will send; "" before the first page.
    const(char)[] token() const return { return token_[0 .. length_]; }

    /// Resumes from a token saved earlier. False if it is too long.
    bool resumeFrom(scope const(char)[] savedToken) {
        if (savedToken.length > maxContinuationToken) return false;
        token_[0 .. savedToken.length] = savedToken[];
        length_ = cast(ushort) savedToken.length;
        done = false;
        return true;
    }
}

struct ListPageResult {
    S3Status status;
    /// Entries handed to the callback by this call -- including, on a
    /// failure part-way through a page, those delivered before it.
    ulong entries;
    bool isTruncated;

    bool ok() const @nogc nothrow pure { return status.ok; }
}

/// Fixed settings of a client. The slices are borrowed: they must stay
/// valid for as long as the client is open.
struct S3Config {
    const(char)[] region;      /// e.g. "us-east-1"
    Credentials credentials;   /// `Credentials.init` sends unsigned requests
    const(char)[] service = "s3";
    /// When set, a literal "scheme://host[:port]" the request is sent to in
    /// place of `https://<bucket>.s3.<region>.amazonaws.com`. The `Host`
    /// header and the signature still name the real S3 host. This is the
    /// loopback-fixture seam; it is not an endpoint setting.
    const(char)[] dispatchOrigin;
}

/// One request, described independently of any connection.
struct RequestSpec {
    HttpMethod method;
    const(char)[] bucket;
    const(char)[] key;           /// raw object key, not encoded; "" for the bucket itself
    const(QueryParam)[] query;   /// unencoded pairs
    const(char)[] payloadHash;   /// the `x-amz-content-sha256` value
    ByteRange range;
    AmzTime when;
}

/// A request ready for a transport. Everything here is a view into the work
/// buffer `prepareRequest` was given, or into its arguments.
struct PreparedRequest {
    const(char)[] url;
    const(char)[] host;
    private HttpHeader[5] headerStore;
    private size_t headerCount;
    /// The part of the work buffer the request does not occupy.
    char[] spare;

    const(HttpHeader)[] headers() const return @nogc nothrow pure { return headerStore[0 .. headerCount]; }
}

/// Builds one request -- virtual-hosted-style URL, headers, and a SigV4
/// `Authorization` when `config.credentials` is set -- into `work`. Pure
/// given `spec.when`: no clock, no network, no allocation. On failure
/// `status` says why and nothing in `prepared` should be used.
bool prepareRequest(scope ref const S3Config config, scope ref const RequestSpec spec,
        return scope char[] work, out PreparedRequest prepared, out S3Status status) @nogc nothrow pure {
    if (spec.bucket.length == 0 || config.region.length == 0) {
        status = S3Status.failure(FailureKind.invalidRequest, "bucket and region are required");
        return false;
    }
    // Both are written into the Host header and the URL as they stand, so
    // nothing that could end a header line or a host name may pass.
    if (!isHostText(spec.bucket) || !isHostText(config.region)) {
        status = S3Status.failure(FailureKind.invalidRequest,
            "bucket and region may contain only letters, digits, '.', '-' and '_'");
        return false;
    }
    if (!spec.range.isValid) {
        status = S3Status.failure(FailureKind.invalidRequest, "byte range ends before it starts");
        return false;
    }

    auto w = Writer(work);

    immutable hostStart = w.mark;
    w.put(spec.bucket);
    w.put(".s3.");
    w.put(config.region);
    w.put(".amazonaws.com");
    auto host = w.since(hostStart);

    immutable pathStart = w.mark;
    w.put('/');
    if (spec.key.length) canonicalUriInto(w, spec.key);
    auto path = w.since(pathStart);

    immutable queryStart = w.mark;
    if (canonicalQueryFromPairsInto(w, spec.query) == SignFailure.tooManyQueryParams) {
        status = S3Status.failure(FailureKind.invalidRequest, "too many query parameters");
        return false;
    }
    auto query = w.since(queryStart);

    immutable urlStart = w.mark;
    if (config.dispatchOrigin.length) w.put(config.dispatchOrigin);
    else { w.put("https://"); w.put(host); }
    w.put(path);
    if (query.length) { w.put('?'); w.put(query); }
    auto url = w.since(urlStart);

    immutable rangeStart = w.mark;
    if (!spec.range.isWhole) spec.range.headerValueInto(w);
    auto rangeValue = w.since(rangeStart);

    if (w.overflow) {
        status = S3Status.failure(FailureKind.bufferTooSmall, "work buffer cannot hold the request");
        return false;
    }

    prepared.url = url;
    prepared.host = host;
    void add(const(char)[] name, const(char)[] value) {
        prepared.headerStore[prepared.headerCount++] = HttpHeader(name, value);
    }
    add("Host", host);
    add("X-Amz-Date", spec.when.amzDate);
    add("X-Amz-Content-Sha256", spec.payloadHash);
    if (rangeValue.length) add("Range", rangeValue);

    if (config.credentials.isSet) {
        Header[4] toSign;
        foreach (i, h; prepared.headers) toSign[i] = Header(h.name, h.value);

        SigningInput input;
        input.method = spec.method == HttpMethod.put ? "PUT" : "GET";
        input.canonicalUri = path;
        input.canonicalQuery = query;
        input.headers = toSign[0 .. prepared.headerCount];
        input.payloadHash = spec.payloadHash;
        input.accessKeyId = config.credentials.accessKeyId;
        input.secretAccessKey = config.credentials.secretAccessKey;
        input.amzDate = spec.when.amzDate;
        input.dateStamp = spec.when.dateStamp;
        input.region = config.region;
        input.service = config.service;

        immutable signStart = w.mark;
        SignedRequest signed;
        if (signRequest(input, w, signed) != SignFailure.none) {
            status = S3Status.failure(FailureKind.bufferTooSmall, "work buffer cannot hold the signature");
            return false;
        }
        // Only the Authorization value is needed from here on: slide it
        // down over the canonical request and string-to-sign.
        import core.stdc.string : memmove;
        immutable authLength = signed.authorizationHeader.length;
        memmove(w.buf.ptr + signStart, signed.authorizationHeader.ptr, authLength);
        w.rewind(signStart);
        w.len += authLength;
        add("Authorization", w.since(signStart));
    }

    prepared.spare = w.spare();
    return true;
}

private bool isHostText(scope const(char)[] text) @nogc nothrow pure {
    foreach (c; text)
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
                c == '.' || c == '-' || c == '_')) return false;
    return true;
}

/// Collects what the core needs from a response as it streams past.
private struct ResponseState {
    char[] errorBuf;
    size_t errorLen;
    BodySink sink;

    InlineText!128 etag;
    InlineText!128 contentType;
    bool hasContentLength;
    ulong contentLength;
    bool hasTotalSize;
    ulong totalSize;
    ulong delivered;
    int status; // of the final response, once its head has been seen

@nogc nothrow:
    void onHeader(int status, scope const(char)[] name, scope const(char)[] value) {
        if (status < 200) return; // interim response
        this.status = status;
        if (equalIgnoreCase(name, "ETag")) etag.set(value);
        else if (equalIgnoreCase(name, "Content-Type")) contentType.set(value);
        else if (equalIgnoreCase(name, "Content-Length")) hasContentLength = parseUnsigned(value, contentLength);
        else if (equalIgnoreCase(name, "Content-Range")) {
            // "bytes first-last/total"; total is "*" when unknown.
            immutable slash = indexOf(value, '/');
            if (slash >= 0) hasTotalSize = parseUnsigned(value[slash + 1 .. $], totalSize);
        }
    }

    bool onBody(int status, scope const(ubyte)[] chunk) {
        this.status = status;
        if (status >= 200 && status < 300) {
            if (sink !is null && !sink(chunk)) return false;
            delivered += chunk.length;
            return true;
        }
        // An error body: keep as much as fits, for classification.
        immutable room = errorBuf.length - errorLen;
        immutable n = chunk.length < room ? chunk.length : room;
        errorBuf[errorLen .. errorLen + n] = cast(const(char)[]) chunk[0 .. n];
        errorLen += n;
        return true;
    }

    S3Status statusOf(scope ref const TransportResult result) const {
        if (!result.ok) {
            auto s = S3Status.failure(result.failure == TransportFailure.aborted
                ? FailureKind.aborted : FailureKind.transportError, result.detail);
            s.transport = result.failure;
            s.transportCode = result.nativeCode;
            return s;
        }
        if (result.status >= 200 && result.status < 300) {
            S3Status s;
            s.ok = true;
            s.httpStatus = result.status;
            return s;
        }
        return classifyHttpError(result.status, cast(const(ubyte)[]) errorBuf[0 .. errorLen]);
    }
}

/// Types an HTTP error status, using S3's XML error body when there is one.
S3Status classifyHttpError(int httpStatus, scope const(ubyte)[] body_) @nogc nothrow pure {
    auto parsed = parseS3Error(body_);
    if (parsed.valid) {
        S3Status s;
        s.httpStatus = httpStatus;
        s.code = parsed.code;
        s.message = parsed.message;
        if (parsed.code[] == "NoSuchKey" || parsed.code[] == "NoSuchBucket") s.kind = FailureKind.notFound;
        else if (parsed.code[] == "AccessDenied") s.kind = FailureKind.forbidden;
        else s.kind = FailureKind.other;
        return s;
    }
    // No parseable S3 error body: fall back to the status alone, flagged by
    // an empty `code`.
    if (httpStatus == 404)
        return S3Status.failure(FailureKind.notFound, "HTTP 404 with no parseable S3 error body", httpStatus);
    if (httpStatus == 403)
        return S3Status.failure(FailureKind.forbidden, "HTTP 403 with no parseable S3 error body", httpStatus);
    return S3Status.failure(FailureKind.malformedResponse, "unexpected response shape", httpStatus);
}

/// Holds an upload body to its declared length.
private struct LengthGuard {
    BodySource source;
    ulong produced;
    bool ended;
    bool mismatch;
    bool sourceFailed;

@nogc nothrow:
    bool pull(ref const(ubyte)[] chunk) {
        if (!source.pull(chunk)) { sourceFailed = true; return false; }
        if (chunk.length == 0) {
            ended = true;
            if (produced != source.length) mismatch = true;
            return !mismatch;
        }
        if (chunk.length > source.length - produced) { mismatch = true; return false; }
        produced += chunk.length;
        return true;
    }

    bool rewind() {
        if (source.rewind is null || !source.rewind()) return false;
        produced = 0;
        ended = false;
        return true;
    }
}

/// An S3 client: settings, a work buffer, and the transport handle it owns.
///
/// ---
/// char[recommendedWorkBytes] work = void;
/// Transport transport;
/// if (!openCurlTransport(CurlOptions.init, transport).ok) return;
/// S3Client client;
/// if (!client.open(S3Config("us-east-1", credentials), transport, work[]).ok) return;
/// scope(exit) client.close();
/// auto put = client.putObject("bucket", "key", chunks, totalLength, PayloadHash.unsigned);
/// ---
struct S3Client {
    private Transport transport_;
    private S3Config config_;
    private char[] work_;

    @disable this(this);

@nogc nothrow:

    ~this() { close(); }

    /// Takes ownership of `transport` and borrows `work` and the slices in
    /// `config` until `close`. If this fails the transport is closed and
    /// the client stays closed.
    S3Status open(S3Config config, Transport transport, char[] work) {
        close();
        S3Status status;
        if (!transport.isOpen)
            status = S3Status.failure(FailureKind.invalidRequest, "transport is not open");
        else if (config.region.length == 0)
            status = S3Status.failure(FailureKind.invalidRequest, "region is required");
        else if (work.length < minWorkBytes)
            status = S3Status.failure(FailureKind.bufferTooSmall, "work buffer is smaller than minWorkBytes");
        else {
            transport_ = transport;
            config_ = config;
            work_ = work;
            status.ok = true;
            return status;
        }
        transport.close();
        return status;
    }

    bool isOpen() const pure { return transport_.isOpen; }

    /// Closes the connection. The work buffer and config slices are no
    /// longer referenced afterwards. Safe to call twice.
    void close() {
        transport_.close();
        work_ = null;
        config_ = S3Config.init;
    }

    /// Uploads one object from a pull-form body. See `BodySource` for what
    /// the source owes and what a retry needs, and `PayloadHash` for the
    /// hash policy, which has no default.
    PutResult putObject(scope const(char)[] bucket, scope const(char)[] key, BodySource body_,
            PayloadHash hash, AmzTime when = AmzTime.now()) {
        PutResult result;
        if (!hash.isSet || body_.pull is null) {
            result.status = S3Status.failure(FailureKind.invalidRequest,
                !hash.isSet ? "payload hash policy is not set" : "body source has no pull");
            return result;
        }

        RequestSpec spec;
        spec.method = HttpMethod.put;
        spec.bucket = bucket;
        spec.key = key;
        spec.payloadHash = hash.headerValue;
        spec.when = when;
        PreparedRequest prepared;
        if (!prepare(spec, prepared, result.status)) return result;

        auto guard = LengthGuard(body_);
        auto response = ResponseState(prepared.spare);

        HttpCall call;
        call.method = HttpMethod.put;
        call.url = prepared.url;
        call.headers = prepared.headers;
        call.hasBody = true;
        call.bodyLength = body_.length;
        call.pull = &guard.pull;
        call.rewind = body_.rewind is null ? null : &guard.rewind;
        call.onHeader = &response.onHeader;
        call.onBody = &response.onBody;

        auto outcome = transport_.perform(call);
        result.bytesSent = guard.produced;
        result.status = response.statusOf(outcome);
        if (guard.mismatch)
            result.status = S3Status.failure(FailureKind.bodyLengthMismatch,
                "body ended before or ran past its declared length", result.status.httpStatus);
        else if (guard.sourceFailed)
            result.status.message.set("body source reported a failure");
        else if (result.status.ok && !guard.ended) {
            // The transport stopped pulling at the declared length. Make
            // sure the source had nothing more: a longer body would mean
            // the stored object is a silent prefix of what was meant.
            const(ubyte)[] extra;
            if (!guard.pull(extra) && guard.mismatch)
                result.status = S3Status.failure(FailureKind.bodyLengthMismatch,
                    "body is longer than its declared length; the stored object is truncated",
                    result.status.httpStatus);
        }
        if (result.status.ok) result.etag = response.etag;
        return result;
    }

    /// Uploads one object whose body is an input range of byte chunks
    /// (`const(ubyte)[]` elements) totalling exactly `length` bytes. The
    /// range is walked as the connection accepts data; a chunk need only
    /// stay valid until the range is advanced.
    ///
    /// A forward range is read through `save` and left as it was: the same
    /// range can be passed again to retry. A range that is only an input
    /// range is consumed and can be sent once. Empty elements are skipped.
    PutResult putObject(R)(scope const(char)[] bucket, scope const(char)[] key, auto ref R chunks,
            ulong length, PayloadHash hash, AmzTime when = AmzTime.now())
    if (isChunkRange!R) {
        static if (isForwardRange!R) {
            auto adapter = RangeBody!R(chunks.save, chunks.save);
            return putObject(bucket, key, BodySource(length, &adapter.pull, &adapter.rewind), hash, when);
        } else {
            auto adapter = RangeBody!R(&chunks);
            return putObject(bucket, key, BodySource(length, &adapter.pull, null), hash, when);
        }
    }

    /// Downloads one object, or `range` of it, into `sink` as it arrives.
    /// Only a successful (2xx) body reaches the sink; an error body is
    /// parsed into the status instead.
    GetResult getObject(scope const(char)[] bucket, scope const(char)[] key, ByteRange range,
            scope BodySink sink, AmzTime when = AmzTime.now()) {
        GetResult result;
        RequestSpec spec;
        spec.method = HttpMethod.get;
        spec.bucket = bucket;
        spec.key = key;
        spec.payloadHash = emptyPayloadSha256Hex;
        spec.range = range;
        spec.when = when;
        PreparedRequest prepared;
        if (!prepare(spec, prepared, result.status)) return result;

        auto response = ResponseState(prepared.spare, 0, sink);
        HttpCall call;
        call.method = HttpMethod.get;
        call.url = prepared.url;
        call.headers = prepared.headers;
        call.onHeader = &response.onHeader;
        call.onBody = &response.onBody;

        auto outcome = transport_.perform(call);
        result.status = response.statusOf(outcome);
        result.bytesDelivered = response.delivered;
        if (result.status.kind == FailureKind.aborted && !result.status.ok)
            result.status.message.set("download stopped by the sink");
        // A successful response's headers are reported even if its body was
        // then cut short: they are what a resumed download needs.
        if (response.status < 200 || response.status >= 300) return result;
        result.etag = response.etag;
        result.contentType = response.contentType;
        result.partial = response.status == 206;
        result.hasContentLength = response.hasContentLength;
        result.contentLength = response.contentLength;
        if (response.hasTotalSize) {
            result.hasTotalSize = true;
            result.totalSize = response.totalSize;
        } else if (response.status == 200 && response.hasContentLength) {
            result.hasTotalSize = true;
            result.totalSize = response.contentLength;
        }
        return result;
    }

    /// Downloads into an output range of byte chunks (anything
    /// `std.range.primitives.put` accepts a `const(ubyte)[]` for), passed
    /// by reference.
    GetResult getObject(R)(scope const(char)[] bucket, scope const(char)[] key, ByteRange range,
            ref R sink, AmzTime when = AmzTime.now())
    if (isOutputRange!(R, const(ubyte)[]) && !is(R : BodySink)) {
        static struct Adapter {
            R* target;
            bool put(scope const(ubyte)[] chunk) {
                import std.range.primitives : put;
                put(*target, chunk);
                return true;
            }
        }
        auto adapter = Adapter(&sink);
        return getObject(bucket, key, range, &adapter.put, when);
    }

    /// Fetches one page of a listing. Each entry is handed to `onEntry` as
    /// views into `entryBuffer` as the response arrives; nothing is kept.
    /// `continuation` says which page: pass `ListContinuation.init` first,
    /// then the same value again until its `done` is set.
    ///
    /// `entryBuffer` must hold the largest single entry of the response
    /// (`recommendedListEntryBuffer`); its size does not depend on the page
    /// size or the number of objects.
    ///
    /// Entries are delivered before the page is known to be complete. If
    /// the call then fails, `continuation` is unchanged and asking again
    /// delivers that page's entries from its start.
    ListPageResult listObjectsV2(scope const(char)[] bucket, ListOptions options,
            ref ListContinuation continuation, scope char[] entryBuffer,
            scope ListEntryCallback onEntry, AmzTime when = AmzTime.now()) {
        ListPageResult result;
        if (entryBuffer.length < minListEntryBuffer) {
            result.status = S3Status.failure(FailureKind.bufferTooSmall,
                "entry buffer is smaller than minListEntryBuffer");
            return result;
        }

        char[10] maxKeysText = void;
        auto maxKeysWriter = Writer(maxKeysText[]);
        maxKeysWriter.putUnsigned(options.maxKeys);

        QueryParam[5] query;
        size_t queryCount = 0;
        query[queryCount++] = QueryParam("list-type", "2");
        query[queryCount++] = QueryParam("max-keys", maxKeysWriter.since(0));
        if (options.prefix.length) query[queryCount++] = QueryParam("prefix", options.prefix);
        if (options.delimiter.length) query[queryCount++] = QueryParam("delimiter", options.delimiter);
        if (continuation.token.length)
            query[queryCount++] = QueryParam("continuation-token", continuation.token);

        RequestSpec spec;
        spec.method = HttpMethod.get;
        spec.bucket = bucket;
        spec.query = query[0 .. queryCount];
        spec.payloadHash = emptyPayloadSha256Hex;
        spec.when = when;
        PreparedRequest prepared;
        if (!prepare(spec, prepared, result.status)) return result;

        // The next token is parsed into its own storage and only copied
        // into `continuation` once the page has succeeded.
        char[maxContinuationToken] nextToken = void;
        static struct Feeder {
            ListPageParser parser;
            ListEntryCallback onEntry;
            ListFeed last;
            bool put(scope const(ubyte)[] chunk) @nogc nothrow {
                last = parser.feed(chunk, onEntry);
                return last == ListFeed.more;
            }
        }
        auto feeder = Feeder(ListPageParser(entryBuffer, nextToken[]), onEntry);
        auto response = ResponseState(prepared.spare, 0, &feeder.put);

        HttpCall call;
        call.method = HttpMethod.get;
        call.url = prepared.url;
        call.headers = prepared.headers;
        call.onHeader = &response.onHeader;
        call.onBody = &response.onBody;

        auto outcome = transport_.perform(call);
        result.entries = feeder.parser.entries;
        result.status = response.statusOf(outcome);
        if (feeder.last == ListFeed.entryTooLarge) {
            result.status = S3Status.failure(FailureKind.bufferTooSmall,
                "a listing entry does not fit the entry buffer");
            return result;
        }
        if (feeder.last == ListFeed.stopped) {
            result.status.message.set("listing stopped by the callback");
            return result;
        }
        if (!result.status.ok) return result;

        immutable httpStatus = result.status.httpStatus;
        if (!feeder.parser.sawRoot)
            result.status = S3Status.failure(FailureKind.malformedResponse,
                "unparseable ListBucketResult body", httpStatus);
        else if (feeder.parser.tokenTooLarge)
            result.status = S3Status.failure(FailureKind.bufferTooSmall,
                "continuation token is longer than maxContinuationToken", httpStatus);
        else if (feeder.parser.isTruncated && feeder.parser.nextToken.length == 0)
            // Truncated with nothing to continue from: refuse rather than
            // ask for the first page forever.
            result.status = S3Status.failure(FailureKind.malformedResponse,
                "isTruncated but no NextContinuationToken", httpStatus);
        if (!result.status.ok) return result;

        result.isTruncated = feeder.parser.isTruncated;
        continuation.resumeFrom(feeder.parser.nextToken);
        continuation.done = !result.isTruncated;
        return result;
    }

    private bool prepare(scope ref const RequestSpec spec, out PreparedRequest prepared, out S3Status status) {
        if (!transport_.isOpen) {
            status = S3Status.failure(FailureKind.invalidRequest, "client is not open");
            return false;
        }
        return prepareRequest(config_, spec, work_, prepared, status);
    }
}

version(unittest) {
    private immutable testTime = AmzTime.fromUnix(1_440_938_160); // 20150830T123600Z

    private const(char)[] headerNamed(scope ref const PreparedRequest p, scope const(char)[] name) @nogc nothrow pure {
        foreach (h; p.headers) if (h.name == name) return h.value;
        return null;
    }
}

@nogc nothrow pure unittest {
    // Unsigned request: virtual-hosted URL, no Authorization.
    char[minWorkBytes] work;
    auto config = S3Config("us-east-1");
    RequestSpec spec;
    spec.bucket = "noaa-ghcn-pds";
    spec.key = "csv.gz/a b+c.csv.gz";
    spec.payloadHash = emptyPayloadSha256Hex;
    spec.when = testTime;
    PreparedRequest p;
    S3Status status;
    assert(prepareRequest(config, spec, work[], p, status));
    assert(p.url == "https://noaa-ghcn-pds.s3.us-east-1.amazonaws.com/csv.gz/a%20b%2Bc.csv.gz");
    assert(p.host == "noaa-ghcn-pds.s3.us-east-1.amazonaws.com");
    assert(headerNamed(p, "Authorization") is null);
    assert(headerNamed(p, "X-Amz-Date") == "20150830T123600Z");
    assert(headerNamed(p, "X-Amz-Content-Sha256") == emptyPayloadSha256Hex);
}

@nogc nothrow pure unittest {
    // Signed, ranged, with a dispatch origin: the URL changes, the signed
    // Host does not, and Range is among the signed headers.
    char[minWorkBytes] work;
    auto config = S3Config("us-east-1",
        Credentials("AKIDEXAMPLE", "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"));
    config.dispatchOrigin = "http://127.0.0.1:9000";
    RequestSpec spec;
    spec.bucket = "examplebucket";
    spec.key = "test.txt";
    spec.payloadHash = emptyPayloadSha256Hex;
    spec.range = ByteRange.bytes(10, 19);
    spec.when = testTime;
    PreparedRequest p;
    S3Status status;
    assert(prepareRequest(config, spec, work[], p, status));
    assert(p.url == "http://127.0.0.1:9000/test.txt");
    assert(headerNamed(p, "Host") == "examplebucket.s3.us-east-1.amazonaws.com");
    assert(headerNamed(p, "Range") == "bytes=10-19");
    auto auth = headerNamed(p, "Authorization");
    assert(startsWith(auth, "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/s3/aws4_request, " ~
        "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature="));
    // Nothing of the request overlaps the space left for an error body.
    assert(p.spare.ptr >= auth.ptr + auth.length);
    assert(indexOf(work[], "wJalrXUtnFEMI") < 0);
}

@nogc nothrow pure unittest {
    // A request that cannot fit is refused, not cut short.
    char[96] work;
    auto config = S3Config("us-east-1", Credentials("AKIDEXAMPLE", "secret"));
    RequestSpec spec;
    spec.bucket = "examplebucket";
    spec.key = "test.txt";
    spec.payloadHash = emptyPayloadSha256Hex;
    spec.when = testTime;
    PreparedRequest p;
    S3Status status;
    assert(!prepareRequest(config, spec, work[], p, status));
    assert(status.kind == FailureKind.bufferTooSmall && !status.ok);

    char[minWorkBytes] enough;
    spec.range = ByteRange.bytes(5, 4);
    assert(!prepareRequest(config, spec, enough[], p, status));
    assert(status.kind == FailureKind.invalidRequest);

    // A bucket name cannot smuggle a header line or a different host.
    spec.range = ByteRange.whole;
    spec.bucket = "bucket\r\nX-Injected: 1";
    assert(!prepareRequest(config, spec, enough[], p, status) && status.kind == FailureKind.invalidRequest);
    spec.bucket = "evil.example/";
    assert(!prepareRequest(config, spec, enough[], p, status) && status.kind == FailureKind.invalidRequest);
}

@nogc nothrow pure unittest {
    // Listing query: values that contain '&' or '=' are content.
    char[minWorkBytes] work;
    auto config = S3Config("us-east-1");
    static immutable QueryParam[4] query = [QueryParam("list-type", "2"), QueryParam("max-keys", "50"),
        QueryParam("prefix", "foo&evil=1"), QueryParam("continuation-token", "abc+def=")];
    RequestSpec spec;
    spec.bucket = "bucket";
    spec.query = query[];
    spec.payloadHash = emptyPayloadSha256Hex;
    spec.when = testTime;
    PreparedRequest p;
    S3Status status;
    assert(prepareRequest(config, spec, work[], p, status));
    assert(p.url == "https://bucket.s3.us-east-1.amazonaws.com/?continuation-token=abc%2Bdef%3D" ~
        "&list-type=2&max-keys=50&prefix=foo%26evil%3D1");
}

@nogc nothrow pure unittest {
    assert(!PayloadHash.init.isSet);
    assert(PayloadHash.unsigned.headerValue == "UNSIGNED-PAYLOAD" && !PayloadHash.unsigned.isSigned);
    assert(PayloadHash.ofBytes(null).headerValue == emptyPayloadSha256Hex);
    assert(PayloadHash.sha256Hex("E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855")
        .headerValue == emptyPayloadSha256Hex);
    assert(!PayloadHash.sha256Hex("not a digest").isSet);
}

@nogc nothrow pure unittest {
    // Error classification against real S3 bodies (captured from the
    // public noaa-ghcn-pds bucket; see tests/live_public_object.d).
    static immutable notFoundKey = `<?xml version="1.0" encoding="UTF-8"?>` ~
        `<Error><Code>NoSuchKey</Code><Message>The specified key does not exist.</Message>` ~
        `<Key>csv.gz/does-not-exist-99999.csv.gz</Key><RequestId>94N6A4C5ETJBJKF5</RequestId>` ~
        `<HostId>ELmq6Lb07NfxwjONX/WovjMcATyoTGY7DLIKDfttkOGmminkWrlFWxJe2b845ttIakm2qMv83eKF+tewBHTweC3ulrQKVYp1</HostId></Error>`;
    auto e1 = classifyHttpError(404, cast(const(ubyte)[]) notFoundKey);
    assert(!e1.ok && e1.kind == FailureKind.notFound && e1.code[] == "NoSuchKey" && e1.httpStatus == 404);

    static immutable notFoundBucket = `<?xml version="1.0" encoding="UTF-8"?>` ~
        `<Error><Code>NoSuchBucket</Code><Message>The specified bucket does not exist</Message>` ~
        `<BucketName>this-bucket-should-not-exist-scrubd-s3lite-test</BucketName>` ~
        `<RequestId>5Y81JHN0562BF093</RequestId></Error>`;
    auto e2 = classifyHttpError(404, cast(const(ubyte)[]) notFoundBucket);
    assert(e2.kind == FailureKind.notFound && e2.code[] == "NoSuchBucket");

    auto e3 = classifyHttpError(403, cast(const(ubyte)[])
        `<Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>`);
    assert(e3.kind == FailureKind.forbidden && e3.message[] == "Access Denied");

    assert(classifyHttpError(404, null).kind == FailureKind.notFound);
    assert(classifyHttpError(404, null).code[] == "");
    assert(classifyHttpError(500, cast(const(ubyte)[]) "not xml").kind == FailureKind.malformedResponse);
    assert(classifyHttpError(503, cast(const(ubyte)[])
        `<Error><Code>SlowDown</Code><Message>Reduce your request rate.</Message></Error>`).kind
        == FailureKind.other);
}

version(unittest) {
    /// A transport double: records the request and plays back a canned
    /// response, so the operations can be exercised with no network -- and
    /// proves the core runs against something that is not libcurl.
    private struct FakeTransport {
        int status = 200;
        const(char)[] responseBody;
        size_t responseChunk = 7;
        bool failAfterBody;
        bool rewindOnce; // ask for the body twice, as a transport resending would

        char[512] url = 0;
        size_t urlLen;
        ubyte[4096] sent;
        size_t sentLen;
        ulong declaredLength;
        int performs;
        bool closed;

    @nogc nothrow:
        Transport handle() return {
            return Transport(&this, &performImpl, &closeImpl);
        }

        private static void closeImpl(void* context) {
            (cast(FakeTransport*) context).closed = true;
        }

        private static TransportResult performImpl(void* context, scope ref const HttpCall call) {
            auto self = cast(FakeTransport*) context;
            self.performs++;
            self.urlLen = call.url.length;
            self.url[0 .. call.url.length] = call.url[];
            if (call.hasBody) {
                self.declaredLength = call.bodyLength;
                foreach (pass; 0 .. (self.rewindOnce ? 2 : 1)) {
                    if (pass == 1 && (call.rewind is null || !call.rewind()))
                        return TransportResult(TransportFailure.bodyNotRewindable, 0, 65, "cannot rewind");
                    self.sentLen = 0;
                    while (true) {
                        const(ubyte)[] chunk;
                        if (!call.pull(chunk)) return TransportResult(TransportFailure.aborted, 0, 42, "aborted");
                        if (chunk.length == 0) break;
                        self.sent[self.sentLen .. self.sentLen + chunk.length] = chunk[];
                        self.sentLen += chunk.length;
                    }
                }
            }
            call.onHeader(self.status, "ETag", `"fake-etag"`);
            call.onHeader(self.status, "content-type", "application/xml");
            auto remaining = cast(const(ubyte)[]) self.responseBody;
            while (remaining.length) {
                immutable n = remaining.length < self.responseChunk ? remaining.length : self.responseChunk;
                if (!call.onBody(self.status, remaining[0 .. n]))
                    return TransportResult(TransportFailure.aborted, 0, 23, "aborted");
                remaining = remaining[n .. $];
            }
            if (self.failAfterBody) return TransportResult(TransportFailure.other, 0, 56, "connection reset");
            return TransportResult(TransportFailure.none, self.status);
        }
    }

    /// An input-only (single-pass) chunk range.
    private struct OnePass {
        const(ubyte[])[] chunks;
        @disable this(this);
    @nogc nothrow:
        bool empty() const { return chunks.length == 0; }
        const(ubyte)[] front() const { return chunks[0]; }
        void popFront() { chunks = chunks[1 .. $]; }
    }
}

@nogc nothrow unittest {
    // putObject from a forward range of small chunks: the transport pulls
    // them one at a time, a resend rewinds, and the caller's range is left
    // untouched so it can be passed again.
    static immutable ubyte[][4] pieces = [[1, 2, 3], [], [4], [5, 6]];
    static immutable ubyte[6] whole = [1, 2, 3, 4, 5, 6];
    char[minWorkBytes] work;
    FakeTransport fake;
    fake.rewindOnce = true;
    S3Client client;
    assert(client.open(S3Config("us-east-1"), fake.handle, work[]).ok);

    const(ubyte[])[] chunks = pieces[];
    auto put = client.putObject("bucket", "key", chunks, 6, PayloadHash.unsigned, testTime);
    assert(put.ok && put.etag[] == `"fake-etag"` && put.bytesSent == 6);
    assert(fake.declaredLength == 6 && fake.sent[0 .. fake.sentLen] == whole[]);
    assert(fake.url[0 .. fake.urlLen] == "https://bucket.s3.us-east-1.amazonaws.com/key");
    assert(chunks.length == 4);

    // A body that is shorter or longer than declared is an error.
    assert(client.putObject("bucket", "key", chunks, 7, PayloadHash.unsigned, testTime).status.kind
        == FailureKind.bodyLengthMismatch);
    assert(client.putObject("bucket", "key", chunks, 5, PayloadHash.unsigned, testTime).status.kind
        == FailureKind.bodyLengthMismatch);
    // The hash policy must be stated.
    assert(client.putObject("bucket", "key", chunks, 6, PayloadHash.init, testTime).status.kind
        == FailureKind.invalidRequest);

    client.close();
    assert(fake.closed && !client.isOpen);
    assert(client.putObject("bucket", "key", chunks, 6, PayloadHash.unsigned, testTime).status.kind
        == FailureKind.invalidRequest);
}

@nogc nothrow unittest {
    // An empty object, and a whole in-memory body through SliceBody and
    // through std.range.only.
    import std.range : only;
    static immutable ubyte[5] bytes = [10, 20, 30, 40, 50];
    char[minWorkBytes] work;
    FakeTransport fake;
    S3Client client;
    assert(client.open(S3Config("us-east-1"), fake.handle, work[]).ok);

    const(ubyte[])[] nothing;
    auto empty = client.putObject("bucket", "empty", nothing, 0, PayloadHash.ofBytes(null), testTime);
    assert(empty.ok && empty.bytesSent == 0 && fake.declaredLength == 0 && fake.sentLen == 0);

    auto slab = SliceBody(bytes[]);
    fake.rewindOnce = true;
    assert(client.putObject("bucket", "slab", slab.source, PayloadHash.ofBytes(bytes[]), testTime).ok);
    assert(fake.sent[0 .. fake.sentLen] == bytes[]);

    const(ubyte)[] view = bytes[];
    assert(client.putObject("bucket", "only", only(view), 5, PayloadHash.unsigned, testTime).ok);
    assert(fake.sent[0 .. fake.sentLen] == bytes[]);
}

@nogc nothrow unittest {
    // An input-only range is consumed and cannot be resent.
    static immutable ubyte[][2] pieces = [[9, 8], [7]];
    static immutable ubyte[3] whole = [9, 8, 7];
    char[minWorkBytes] work;
    FakeTransport fake;
    S3Client client;
    assert(client.open(S3Config("us-east-1"), fake.handle, work[]).ok);

    auto once = OnePass(pieces[]);
    assert(client.putObject("bucket", "key", once, 3, PayloadHash.unsigned, testTime).ok);
    assert(once.empty && fake.sent[0 .. fake.sentLen] == whole[]);

    fake.rewindOnce = true;
    auto again = OnePass(pieces[]);
    auto put = client.putObject("bucket", "key", again, 3, PayloadHash.unsigned, testTime);
    assert(!put.ok && put.status.kind == FailureKind.transportError);
    assert(put.status.transport == TransportFailure.bodyNotRewindable);
}

@nogc nothrow unittest {
    // getObject into a delegate sink and into an output range; an error
    // body never reaches the sink; a sink can stop the download.
    static struct Collect {
        ubyte[64] data;
        size_t len;
        size_t limit = size_t.max;
    @nogc nothrow:
        bool take(scope const(ubyte)[] chunk) {
            if (len + chunk.length > limit) return false;
            put(chunk);
            return true;
        }
        void put(scope const(ubyte)[] chunk) {
            data[len .. len + chunk.length] = chunk[];
            len += chunk.length;
        }
    }

    char[minWorkBytes] work;
    FakeTransport fake;
    fake.responseBody = "0123456789abcdefghij";
    S3Client client;
    assert(client.open(S3Config("us-east-1"), fake.handle, work[]).ok);

    Collect viaDelegate;
    auto got = client.getObject("bucket", "key", ByteRange.whole, &viaDelegate.take, testTime);
    assert(got.ok && got.bytesDelivered == 20 && got.etag[] == `"fake-etag"`);
    assert(cast(const(char)[]) viaDelegate.data[0 .. viaDelegate.len] == "0123456789abcdefghij");

    Collect viaRange;
    assert(client.getObject("bucket", "key", ByteRange.whole, viaRange, testTime).ok);
    assert(viaRange.len == 20);

    Collect stops;
    stops.limit = 10;
    auto stopped = client.getObject("bucket", "key", ByteRange.whole, &stops.take, testTime);
    assert(!stopped.ok && stopped.status.kind == FailureKind.aborted && stopped.bytesDelivered == 7);

    fake.status = 404;
    fake.responseBody = "<Error><Code>NoSuchKey</Code><Message>gone</Message></Error>";
    Collect untouched;
    auto missing = client.getObject("bucket", "key", ByteRange.whole, &untouched.take, testTime);
    assert(!missing.ok && missing.status.kind == FailureKind.notFound && missing.status.code[] == "NoSuchKey");
    assert(untouched.len == 0 && missing.bytesDelivered == 0);
}

@nogc nothrow unittest {
    // listObjectsV2: entries through the callback, explicit continuation,
    // and a failed page leaving the continuation where it was.
    static struct Keys {
        char[64] text = 0;
        size_t len;
        bool take(scope ref const S3ObjectView e) @nogc nothrow {
            text[len .. len + e.key.length] = e.key[];
            len += e.key.length;
            text[len++] = ',';
            return true;
        }
    }

    char[minWorkBytes] work;
    char[minListEntryBuffer] entryBuffer;
    FakeTransport fake;
    S3Client client;
    assert(client.open(S3Config("us-east-1"), fake.handle, work[]).ok);

    fake.responseBody = `<ListBucketResult><IsTruncated>true</IsTruncated>` ~
        `<Contents><Key>a.txt</Key><Size>1</Size></Contents>` ~
        `<Contents><Key>b.txt</Key><Size>2</Size></Contents>` ~
        `<NextContinuationToken>page&amp;2</NextContinuationToken></ListBucketResult>`;
    Keys keys;
    ListContinuation where;
    auto page = client.listObjectsV2("bucket", ListOptions("p/"), where, entryBuffer[], &keys.take, testTime);
    assert(page.ok && page.entries == 2 && page.isTruncated);
    assert(!where.done && where.token == "page&2");
    assert(indexOf(fake.url[0 .. fake.urlLen], "continuation-token") < 0);

    // A page that fails part-way: the continuation still names it.
    fake.failAfterBody = true;
    auto failed = client.listObjectsV2("bucket", ListOptions("p/"), where, entryBuffer[], &keys.take, testTime);
    assert(!failed.ok && failed.status.kind == FailureKind.transportError && failed.entries == 2);
    assert(where.token == "page&2" && !where.done);
    assert(indexOf(fake.url[0 .. fake.urlLen], "continuation-token=page%262") > 0);

    fake.failAfterBody = false;
    fake.responseBody = `<ListBucketResult><IsTruncated>false</IsTruncated>` ~
        `<Contents><Key>c.txt</Key><Size>3</Size></Contents></ListBucketResult>`;
    keys = Keys.init;
    auto last = client.listObjectsV2("bucket", ListOptions("p/"), where, entryBuffer[], &keys.take, testTime);
    assert(last.ok && last.entries == 1 && !last.isTruncated && where.done);
    assert(keys.text[0 .. keys.len] == "c.txt,");

    // Truncated with no token, and a body that is not a listing.
    fake.responseBody = `<ListBucketResult><IsTruncated>true</IsTruncated></ListBucketResult>`;
    ListContinuation fresh;
    assert(client.listObjectsV2("bucket", ListOptions.init, fresh, entryBuffer[], null, testTime).status.kind
        == FailureKind.malformedResponse);
    fake.responseBody = "<html>proxy says hello</html>";
    assert(client.listObjectsV2("bucket", ListOptions.init, fresh, entryBuffer[], null, testTime).status.kind
        == FailureKind.malformedResponse);
    assert(fresh.token == "" && !fresh.done);
}
