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
///     The work buffer holds the request's `Authorization` header while a
///     call is in progress and is zeroed before every operation returns,
///     so nothing derived from the credentials is left in it.
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

import s3lite.fixed : InlineText, Writer, equalIgnoreCase, indexOf, parseUnsigned, startsWith, toLowerAscii;
import s3lite.sigv4;
import s3lite.transport;
import s3lite.xml_error : parseS3Error;
import s3lite.xml_list;
import std.range.primitives : ElementType, empty, front, isForwardRange, isInputRange, isOutputRange,
    popFront, save;

public import s3lite.sigv4 : AmzTime;
public import s3lite.transport : BodyPull, BodyRewind, Transport, TransportFailure;
public import s3lite.xml_list : ListEntryCallback, ListPrefixCallback, S3ObjectView, minListEntryBuffer,
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

/// Most user-metadata pairs one upload may carry.
enum size_t maxUserMetadata = 16;

/// Most headers an operation may add to the three every request signs
/// (and `Range`); the signer's own bound is `maxSignedHeaders`.
package enum size_t maxExtraHeaders = maxSignedHeaders - 4;

/// A range body may yield this many empty chunks in a row; one more and
/// the upload fails with `bodyLengthMismatch` instead of waiting on a range
/// that never produces data.
enum size_t maxConsecutiveEmptyChunks = 64;

/// SigV4 credentials. `Credentials.init` (both empty) means "do not sign":
/// the request is sent with no `Authorization` header, which only a public
/// object or a test fixture accepts. One field without the other is not
/// "unsigned": it is refused as `invalidRequest`.
struct Credentials {
    const(char)[] accessKeyId;
    const(char)[] secretAccessKey;

@nogc nothrow pure:
    bool isSet() const {
        return accessKeyId.length > 0 && secretAccessKey.length > 0;
    }

    /// Both fields empty, or both present with an access key id that can
    /// sit inside an `Authorization` header: visible ASCII with none of
    /// the separators (`/`, `,`, `=`) that header gives meaning to.
    bool isWellFormed() const {
        if (accessKeyId.length == 0 && secretAccessKey.length == 0) return true;
        if (!isSet) return false;
        foreach (c; accessKeyId)
            if (c <= 0x20 || c >= 0x7f || c == '/' || c == ',' || c == '=') return false;
        return true;
    }
}

enum FailureKind {
    none,               /// success; the value of a default `S3Status`
    notFound,           /// S3's NoSuchKey/NoSuchBucket, or a plain HTTP 404
    forbidden,          /// S3's AccessDenied, or a plain HTTP 403
    malformedResponse,  /// a response whose shape is not what S3 documents
    transportError,     /// no HTTP response was obtained (DNS/TLS/connect/timeout)
    other,              /// an S3 error that was parsed but is not classified above
    bufferTooSmall,     /// a caller-supplied buffer cannot hold what the request needs
    invalidRequest,     /// the arguments cannot form a request (nothing was sent)
    aborted,            /// a body source, sink or listing callback stopped the request
    bodyLengthMismatch, /// an upload body did not produce exactly its declared length
    rangeIgnored,       /// a byte range was asked for and the whole object came back (200, not 206)
    preconditionFailed, /// `ifMatch` did not hold (HTTP 412)
    notModified,        /// `ifNoneMatch` matched: the object is unchanged (HTTP 304)
}

/// Outcome of one operation. A plain value: no pointers, no borrowed
/// memory.
struct S3Status {
    FailureKind kind;                /// `none` on success
    int httpStatus;                  /// 0 if no HTTP response was received
    TransportFailure transport;      /// set when `kind == transportError` or `aborted`
    int transportCode;               /// the transport's own error number; diagnostic
    InlineText!64 code;              /// S3's `<Code>`, "" if no error body was parsed
    InlineText!256 message;          /// S3's `<Message>`, or a diagnostic

    bool ok() const @nogc nothrow pure { return kind == FailureKind.none; }

    package static S3Status failure(FailureKind kind, scope const(char)[] message, int httpStatus = 0)
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

/// One user-metadata entry; sent as the header `x-amz-meta-<name>`.
struct MetadataPair {
    const(char)[] name;  /// letters, digits, '-', '_' and '.'
    const(char)[] value;
}

/// The additional checksums S3 can verify an upload against.
enum ChecksumAlgorithm : ubyte { none, crc32, crc32c, crc64nvme, sha1, sha256 }

/// What an upload may say about its object beyond the bytes. Everything
/// set here is sent as a header and covered by the signature. All slices
/// are borrowed for the call.
struct PutObjectOptions {
    const(char)[] contentType;
    /// At most `maxUserMetadata` pairs.
    const(MetadataPair)[] metadata;
    const(char)[] storageClass;  /// e.g. "STANDARD_IA"
    const(char)[] contentMd5;    /// base64 MD5 of the body, as `Content-MD5`
    /// With `checksumValue` (base64), sent as `x-amz-checksum-<algorithm>`.
    ChecksumAlgorithm checksumAlgorithm;
    const(char)[] checksumValue;
}

/// Which part of an object a download wants, and on what condition.
struct GetObjectOptions {
    ByteRange range;            /// `ByteRange.init` is the whole object
    const(char)[] ifMatch;      /// an ETag; a mismatch is `preconditionFailed`
    const(char)[] ifNoneMatch;  /// an ETag; a match is `notModified`
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
    bool stalled;   // gave up on a run of empty elements

    bool pull(ref const(ubyte)[] chunk) {
        // An empty element is not the end of the body, so it is skipped --
        // but only so many times: this runs inside the transport, where a
        // range that never produces data would otherwise never return.
        foreach (attempt; 0 .. maxConsecutiveEmptyChunks + 1) {
            if (handedOut) { current.popFront(); handedOut = false; }
            if (current.empty) { chunk = null; return true; }
            chunk = current.front;
            handedOut = true;
            if (chunk.length) return true;
        }
        stalled = true;
        return false;
    }

    static if (isForwardRange!R)
    bool rewind() {
        current = start.save;
        handedOut = false;
        stalled = false;
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
    ulong prefixes; /// common prefixes seen by this call, likewise
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

/// One request, described independently of any connection. Internal to
/// the package: operations build one, and later stages add operations
/// rather than callers assembling requests.
package struct RequestSpec {
    HttpMethod method;
    const(char)[] bucket;
    const(char)[] key;           /// raw object key, not encoded; "" for the bucket itself
    const(QueryParam)[] query;   /// unencoded pairs
    const(char)[] payloadHash;   /// the `x-amz-content-sha256` value
    ByteRange range;
    AmzTime when;
    /// Further headers to send, all of them signed; at most
    /// `maxExtraHeaders`. None may repeat a header the request already
    /// carries (Host, X-Amz-Date, X-Amz-Content-Sha256, Range,
    /// Authorization).
    const(HttpHeader)[] extraHeaders;
}

/// A request ready for a transport. Everything here is a view into the work
/// buffer `prepareRequest` was given, or into its arguments.
package struct PreparedRequest {
    const(char)[] url;
    const(char)[] host;
    private HttpHeader[maxSignedHeaders + 1] headerStore; // + Authorization
    private size_t headerCount;
    /// The part of the work buffer the request does not occupy.
    char[] spare;

    const(HttpHeader)[] headers() const return @nogc nothrow pure { return headerStore[0 .. headerCount]; }
}

/// Builds one request -- virtual-hosted-style URL, headers, and a SigV4
/// `Authorization` over every header when `config.credentials` is set --
/// into `work`. Pure given `spec.when`: no clock, no network, no
/// allocation. On failure `status` says why, nothing in `prepared` may be
/// used, and `work` has been zeroed. On success `work` holds the request,
/// its `Authorization` included; the caller zeroes it when done.
package bool prepareRequest(scope ref const S3Config config, scope ref const RequestSpec spec,
        return scope char[] work, out PreparedRequest prepared, out S3Status status) @nogc nothrow pure {
    if (buildRequest(config, spec, work, prepared, status)) return true;
    work[] = '\0';
    prepared = PreparedRequest.init;
    return false;
}

private bool buildRequest(scope ref const S3Config config, scope ref const RequestSpec spec,
        return scope char[] work, ref PreparedRequest prepared, ref S3Status status) @nogc nothrow pure {
    bool refuse(FailureKind kind, string why) {
        status = S3Status.failure(kind, why);
        return false;
    }

    if (spec.bucket.length == 0 || config.region.length == 0 || config.service.length == 0)
        return refuse(FailureKind.invalidRequest, "bucket, region and service are required");
    // These are written into the Host header, the URL and the credential
    // scope as they stand, so nothing that could end a header line or a
    // host name may pass.
    if (!isHostText(spec.bucket) || !isHostText(config.region) || !isHostText(config.service))
        return refuse(FailureKind.invalidRequest,
            "bucket, region and service may contain only letters, digits, '.', '-' and '_'");
    if (!config.credentials.isWellFormed)
        return refuse(FailureKind.invalidRequest,
            "credentials need both an access key id and a secret, and a key id without separators");
    if (!spec.range.isValid)
        return refuse(FailureKind.invalidRequest, "byte range ends before it starts");
    if (spec.extraHeaders.length > maxExtraHeaders)
        return refuse(FailureKind.invalidRequest, "too many extra headers");
    foreach (ref h; spec.extraHeaders) {
        if (!isHeaderName(h.name) || hasControlBytes(h.value))
            return refuse(FailureKind.invalidRequest, "extra header name or value is not sendable");
        static immutable string[5] reservedNames = ["Host", "X-Amz-Date", "X-Amz-Content-Sha256", "Range",
            "Authorization"];
        foreach (reserved; reservedNames)
            if (equalIgnoreCase(h.name, reserved))
                return refuse(FailureKind.invalidRequest, "extra header repeats one the request already carries");
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
    if (canonicalQueryFromPairsInto(w, spec.query) == SignFailure.tooManyQueryParams)
        return refuse(FailureKind.invalidRequest, "too many query parameters");
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

    // Checked here, before anything is signed or sent: an unsigned request
    // has no later step that would notice a URL cut short.
    if (w.overflow)
        return refuse(FailureKind.bufferTooSmall, "work buffer cannot hold the request");

    prepared.url = url;
    prepared.host = host;
    void add(const(char)[] name, const(char)[] value) {
        prepared.headerStore[prepared.headerCount++] = HttpHeader(name, value);
    }
    add("Host", host);
    add("X-Amz-Date", spec.when.amzDate);
    add("X-Amz-Content-Sha256", spec.payloadHash);
    if (rangeValue.length) add("Range", rangeValue);
    foreach (ref h; spec.extraHeaders) add(h.name, h.value);

    if (config.credentials.isSet) {
        Header[maxSignedHeaders] toSign;
        foreach (i, h; prepared.headers) toSign[i] = Header(h.name, h.value);

        SigningInput input;
        final switch (spec.method) {
            case HttpMethod.get: input.method = "GET"; break;
            case HttpMethod.put: input.method = "PUT"; break;
            case HttpMethod.head: input.method = "HEAD"; break;
            case HttpMethod.delete_: input.method = "DELETE"; break;
        }
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
        if (signRequest(input, w, signed) != SignFailure.none)
            return refuse(FailureKind.bufferTooSmall, "work buffer cannot hold the signature");
        // Only the Authorization value is needed from here on: slide it
        // down over the canonical request and string-to-sign, and clear
        // what it leaves behind.
        import core.stdc.string : memmove;
        immutable authLength = signed.authorizationHeader.length;
        immutable signEnd = w.mark;
        memmove(w.buf.ptr + signStart, signed.authorizationHeader.ptr, authLength);
        w.buf[signStart + authLength .. signEnd] = '\0';
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
    bool rangeRequested;
    bool rangeIgnored; // a 200 arrived where only a 206 is acceptable

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
        if (rangeRequested && status == 200) {
            // The whole object is coming where a part was asked for. None
            // of it may reach a sink that expects the part.
            rangeIgnored = true;
            return false;
        }
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
        if (rangeIgnored || (rangeRequested && result.ok && result.status == 200))
            return S3Status.failure(FailureKind.rangeIgnored,
                "server answered a ranged request with the whole object", 200);
        if (!result.ok) {
            auto s = S3Status.failure(result.failure == TransportFailure.aborted
                ? FailureKind.aborted : FailureKind.transportError, result.detail);
            s.transport = result.failure;
            s.transportCode = result.nativeCode;
            return s;
        }
        if (result.status >= 200 && result.status < 300) {
            S3Status s;
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
        else if (parsed.code[] == "PreconditionFailed") s.kind = FailureKind.preconditionFailed;
        else s.kind = FailureKind.other;
        return s;
    }
    if (httpStatus == 304)
        return S3Status.failure(FailureKind.notModified, "HTTP 304: the object is unchanged", httpStatus);
    if (httpStatus == 412)
        return S3Status.failure(FailureKind.preconditionFailed, "HTTP 412 with no parseable S3 error body", httpStatus);
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
/// // `transport` is now closed-and-empty; the client owns the connection.
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

    /// Takes ownership of `transport`: whether this succeeds or fails, the
    /// caller's handle is cleared, so there is exactly one owner and the
    /// connection cannot be closed twice. On failure the transport is
    /// closed and the client stays closed. `work` and the slices in
    /// `config` are borrowed until `close`.
    S3Status open(S3Config config, ref Transport transport, char[] work) {
        close();
        auto taken = transport;
        transport = Transport.init;

        S3Status status;
        if (!taken.isOpen)
            status = S3Status.failure(FailureKind.invalidRequest, "transport is not open");
        else if (!isHostText(config.region) || config.region.length == 0 ||
                !isHostText(config.service) || config.service.length == 0)
            status = S3Status.failure(FailureKind.invalidRequest,
                "region and service are required and may contain only letters, digits, '.', '-' and '_'");
        else if (!config.credentials.isWellFormed)
            status = S3Status.failure(FailureKind.invalidRequest,
                "credentials need both an access key id and a secret, and a key id without separators");
        else if (work.length < minWorkBytes)
            status = S3Status.failure(FailureKind.bufferTooSmall, "work buffer is smaller than minWorkBytes");
        else {
            transport_ = taken;
            config_ = config;
            work_ = work;
            return status;
        }
        taken.close();
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
            PayloadHash hash, PutObjectOptions options = PutObjectOptions.init,
            AmzTime when = AmzTime.now()) {
        PutResult result;
        if (!hash.isSet || body_.pull is null) {
            result.status = S3Status.failure(FailureKind.invalidRequest,
                !hash.isSet ? "payload hash policy is not set" : "body source has no pull");
            return result;
        }
        if (body_.length > maxBodyLength) {
            result.status = S3Status.failure(FailureKind.invalidRequest,
                "declared body length exceeds what a Content-Length can state");
            return result;
        }
        scope(exit) wipeWork();

        // Header names built for this call (x-amz-meta-...) go at the front
        // of the work buffer; the request is built in what follows.
        auto names = Writer(work_);
        HttpHeader[maxExtraHeaders] extra;
        size_t extraCount;
        if (!putHeaders(options, names, extra, extraCount, result.status)) return result;

        RequestSpec spec;
        spec.method = HttpMethod.put;
        spec.bucket = bucket;
        spec.key = key;
        spec.payloadHash = hash.headerValue;
        spec.when = when;
        spec.extraHeaders = extra[0 .. extraCount];
        PreparedRequest prepared;
        if (!prepare(spec, names.spare(), prepared, result.status)) return result;

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
            const(ubyte)[] extraBody;
            if (!guard.pull(extraBody) && guard.mismatch)
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
    /// range is consumed and can be sent once. Empty elements are skipped,
    /// up to `maxConsecutiveEmptyChunks` in a row.
    PutResult putObject(R)(scope const(char)[] bucket, scope const(char)[] key, auto ref R chunks,
            ulong length, PayloadHash hash, PutObjectOptions options = PutObjectOptions.init,
            AmzTime when = AmzTime.now())
    if (isChunkRange!R) {
        static if (isForwardRange!R) {
            auto adapter = RangeBody!R(chunks.save, chunks.save);
            auto source = BodySource(length, &adapter.pull, &adapter.rewind);
        } else {
            auto adapter = RangeBody!R(&chunks);
            auto source = BodySource(length, &adapter.pull, null);
        }
        auto result = putObject(bucket, key, source, hash, options, when);
        if (adapter.stalled)
            result.status = S3Status.failure(FailureKind.bodyLengthMismatch,
                "body range yielded too many empty chunks in a row", result.status.httpStatus);
        return result;
    }

    /// Downloads one object, or `options.range` of it, into `sink` as it
    /// arrives. Only a successful body reaches the sink; an error body is
    /// parsed into the status instead. When a range was asked for, only a
    /// 206 is a success: a server that answers with the whole object is
    /// reported as `rangeIgnored` and none of it reaches the sink.
    GetResult getObject(scope const(char)[] bucket, scope const(char)[] key, scope BodySink sink,
            GetObjectOptions options = GetObjectOptions.init, AmzTime when = AmzTime.now()) {
        GetResult result;
        scope(exit) wipeWork();

        HttpHeader[2] extra;
        size_t extraCount;
        if (options.ifMatch.length) extra[extraCount++] = HttpHeader("If-Match", options.ifMatch);
        if (options.ifNoneMatch.length) extra[extraCount++] = HttpHeader("If-None-Match", options.ifNoneMatch);

        RequestSpec spec;
        spec.method = HttpMethod.get;
        spec.bucket = bucket;
        spec.key = key;
        spec.payloadHash = emptyPayloadSha256Hex;
        spec.range = options.range;
        spec.when = when;
        spec.extraHeaders = extra[0 .. extraCount];
        PreparedRequest prepared;
        if (!prepare(spec, work_, prepared, result.status)) return result;

        auto response = ResponseState(prepared.spare, 0, sink);
        response.rangeRequested = !options.range.isWhole;
        HttpCall call;
        call.method = HttpMethod.get;
        call.url = prepared.url;
        call.headers = prepared.headers;
        call.onHeader = &response.onHeader;
        call.onBody = &response.onBody;

        auto outcome = transport_.perform(call);
        result.status = response.statusOf(outcome);
        result.bytesDelivered = response.delivered;
        if (result.status.kind == FailureKind.aborted)
            result.status.message.set("download stopped by the sink");
        // A successful response's headers are reported even if its body was
        // then cut short: they are what a resumed download needs.
        if (response.status < 200 || response.status >= 300 || response.rangeIgnored) return result;
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
    GetResult getObject(R)(scope const(char)[] bucket, scope const(char)[] key, ref R sink,
            GetObjectOptions options = GetObjectOptions.init, AmzTime when = AmzTime.now())
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
        return getObject(bucket, key, &adapter.put, options, when);
    }

    /// Fetches one page of a listing. Each entry is handed to `onEntry`,
    /// and each common prefix (when `options.delimiter` is set) to
    /// `onPrefix`, as views into `entryBuffer` as the response arrives;
    /// nothing is kept. Either callback may be null. `continuation` says
    /// which page: pass `ListContinuation.init` first, then the same value
    /// again until its `done` is set.
    ///
    /// `entryBuffer` must hold the largest single entry of the response
    /// (`recommendedListEntryBuffer`); its size does not depend on the page
    /// size or the number of objects.
    ///
    /// Entries are delivered before the page is known to be complete. A
    /// page counts as complete only when its closing element has arrived.
    /// If the call fails, `continuation` is unchanged and asking again
    /// delivers that page's entries from its start.
    ListPageResult listObjectsV2(scope const(char)[] bucket, ListOptions options,
            ref ListContinuation continuation, scope char[] entryBuffer,
            scope ListEntryCallback onEntry, scope ListPrefixCallback onPrefix = null,
            AmzTime when = AmzTime.now()) {
        ListPageResult result;
        if (entryBuffer.length < minListEntryBuffer) {
            result.status = S3Status.failure(FailureKind.bufferTooSmall,
                "entry buffer is smaller than minListEntryBuffer");
            return result;
        }
        scope(exit) wipeWork();

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
        if (!prepare(spec, work_, prepared, result.status)) return result;

        // The next token is parsed into its own storage and only copied
        // into `continuation` once the page has succeeded.
        char[maxContinuationToken] nextToken = void;
        static struct Feeder {
            ListPageParser parser;
            ListEntryCallback onEntry;
            ListPrefixCallback onPrefix;
            ListFeed last;
            bool put(scope const(ubyte)[] chunk) @nogc nothrow {
                last = parser.feed(chunk, onEntry, onPrefix);
                return last == ListFeed.more;
            }
        }
        auto feeder = Feeder(ListPageParser(entryBuffer, nextToken[]), onEntry, onPrefix);
        auto response = ResponseState(prepared.spare, 0, &feeder.put);

        HttpCall call;
        call.method = HttpMethod.get;
        call.url = prepared.url;
        call.headers = prepared.headers;
        call.onHeader = &response.onHeader;
        call.onBody = &response.onBody;

        auto outcome = transport_.perform(call);
        result.entries = feeder.parser.entries;
        result.prefixes = feeder.parser.prefixes;
        result.status = response.statusOf(outcome);
        if (feeder.last == ListFeed.entryTooLarge) {
            result.status = S3Status.failure(FailureKind.bufferTooSmall,
                "a listing entry does not fit the entry buffer");
            return result;
        }
        if (feeder.last == ListFeed.stopped) {
            result.status.message.set("listing stopped by a callback");
            return result;
        }
        if (!result.status.ok) return result;

        immutable httpStatus = result.status.httpStatus;
        if (!feeder.parser.sawRoot)
            result.status = S3Status.failure(FailureKind.malformedResponse,
                "unparseable ListBucketResult body", httpStatus);
        else if (!feeder.parser.sawRootEnd)
            // A 200 whose body stops short would otherwise read as a short,
            // final page -- and silently end the listing early.
            result.status = S3Status.failure(FailureKind.malformedResponse,
                "ListBucketResult body ended before its closing element", httpStatus);
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

    private bool prepare(scope ref const RequestSpec spec, char[] work, out PreparedRequest prepared,
            out S3Status status) {
        if (!transport_.isOpen) {
            status = S3Status.failure(FailureKind.invalidRequest, "client is not open");
            return false;
        }
        return prepareRequest(config_, spec, work, prepared, status);
    }

    /// Nothing a request was built from stays in the caller's buffer.
    private void wipeWork() { work_[] = '\0'; }

    /// Turns `options` into headers. Names that must be composed
    /// (`x-amz-meta-<name>`) are written into `names`.
    private static bool putHeaders(scope ref const PutObjectOptions options, ref Writer names,
            ref HttpHeader[maxExtraHeaders] headers, ref size_t count, ref S3Status status) {
        bool refuse(FailureKind kind, string why) {
            status = S3Status.failure(kind, why);
            return false;
        }
        if (options.metadata.length > maxUserMetadata)
            return refuse(FailureKind.invalidRequest, "more than maxUserMetadata metadata pairs");
        if ((options.checksumAlgorithm == ChecksumAlgorithm.none) != (options.checksumValue.length == 0))
            return refuse(FailureKind.invalidRequest, "a checksum needs both an algorithm and a value");

        if (options.contentType.length) headers[count++] = HttpHeader("Content-Type", options.contentType);
        if (options.storageClass.length) headers[count++] = HttpHeader("x-amz-storage-class", options.storageClass);
        if (options.contentMd5.length) headers[count++] = HttpHeader("Content-MD5", options.contentMd5);
        final switch (options.checksumAlgorithm) {
            case ChecksumAlgorithm.none: break;
            case ChecksumAlgorithm.crc32: headers[count++] = HttpHeader("x-amz-checksum-crc32", options.checksumValue); break;
            case ChecksumAlgorithm.crc32c: headers[count++] = HttpHeader("x-amz-checksum-crc32c", options.checksumValue); break;
            case ChecksumAlgorithm.crc64nvme: headers[count++] = HttpHeader("x-amz-checksum-crc64nvme", options.checksumValue); break;
            case ChecksumAlgorithm.sha1: headers[count++] = HttpHeader("x-amz-checksum-sha1", options.checksumValue); break;
            case ChecksumAlgorithm.sha256: headers[count++] = HttpHeader("x-amz-checksum-sha256", options.checksumValue); break;
        }
        foreach (ref pair; options.metadata) {
            if (pair.name.length == 0) return refuse(FailureKind.invalidRequest, "metadata name is empty");
            foreach (c; pair.name)
                if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
                        c == '-' || c == '_' || c == '.'))
                    return refuse(FailureKind.invalidRequest,
                        "metadata names may contain only letters, digits, '-', '_' and '.'");
            immutable start = names.mark;
            names.put("x-amz-meta-");
            foreach (c; pair.name) names.put(toLowerAscii(c));
            headers[count++] = HttpHeader(names.since(start), pair.value);
        }
        if (names.overflow)
            return refuse(FailureKind.bufferTooSmall, "work buffer cannot hold the metadata header names");
        // Values are checked for control bytes where every header is: in
        // the request builder.
        return true;
    }
}

version(unittest) {
    private immutable testTime = AmzTime.fromUnix(1_440_938_160); // 20150830T123600Z
    private immutable testCredentials = Credentials("AKIDEXAMPLE", "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY");

    private const(char)[] headerNamed(scope ref const PreparedRequest p, scope const(char)[] name) @nogc nothrow pure {
        foreach (h; p.headers) if (h.name == name) return h.value;
        return null;
    }

    private bool allZero(scope const(char)[] buffer) @nogc nothrow pure {
        foreach (c; buffer) if (c != '\0') return false;
        return true;
    }
}

@nogc nothrow pure unittest {
    // A default status is a success, and is not "not found".
    S3Status status;
    assert(status.ok && status.kind == FailureKind.none && status.kind != FailureKind.notFound);
    assert(!S3Status.failure(FailureKind.notFound, "x").ok);
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
    // Keys with "." and ".." segments are signed and addressed as written.
    char[minWorkBytes] work;
    auto config = S3Config("us-east-1");
    static immutable string[7] keys = ["a/../b", "../x", "./x", "a/./b", "..", ".", "x/.."];
    foreach (key; keys) {
        RequestSpec spec;
        spec.bucket = "bucket";
        spec.key = key;
        spec.payloadHash = emptyPayloadSha256Hex;
        spec.when = testTime;
        PreparedRequest p;
        S3Status status;
        assert(prepareRequest(config, spec, work[], p, status));
        assert(p.url.length == "https://bucket.s3.us-east-1.amazonaws.com/".length + key.length);
        assert(p.url[$ - key.length .. $] == key);
    }
}

@nogc nothrow pure unittest {
    // Signed, ranged, with a dispatch origin and extra headers: the URL
    // changes, the signed Host does not, and every header sent is signed.
    char[minWorkBytes] work;
    auto config = S3Config("us-east-1", testCredentials);
    config.dispatchOrigin = "http://127.0.0.1:9000";
    static immutable HttpHeader[2] extra = [HttpHeader("If-Match", `"abc"`), HttpHeader("x-amz-meta-owner", "me")];
    RequestSpec spec;
    spec.bucket = "examplebucket";
    spec.key = "test.txt";
    spec.payloadHash = emptyPayloadSha256Hex;
    spec.range = ByteRange.bytes(10, 19);
    spec.when = testTime;
    spec.extraHeaders = extra[];
    PreparedRequest p;
    S3Status status;
    assert(prepareRequest(config, spec, work[], p, status));
    assert(p.url == "http://127.0.0.1:9000/test.txt");
    assert(headerNamed(p, "Host") == "examplebucket.s3.us-east-1.amazonaws.com");
    assert(headerNamed(p, "Range") == "bytes=10-19");
    assert(headerNamed(p, "If-Match") == `"abc"` && headerNamed(p, "x-amz-meta-owner") == "me");
    auto auth = headerNamed(p, "Authorization");
    assert(startsWith(auth, "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/s3/aws4_request, " ~
        "SignedHeaders=host;if-match;range;x-amz-content-sha256;x-amz-date;x-amz-meta-owner, Signature="));
    // Nothing of the request overlaps the space left for an error body,
    // which is clean, and the secret is nowhere in the buffer.
    assert(p.spare.ptr >= auth.ptr + auth.length);
    assert(allZero(p.spare) || indexOf(p.spare, "AWS4") < 0);
    assert(indexOf(work[], "wJalrXUtnFEMI") < 0);
    assert(indexOf(work[], "AWS4-HMAC-SHA256\n") < 0); // the string-to-sign is gone
}

@nogc nothrow pure unittest {
    // The extra-header slot refuses what it must not carry.
    char[minWorkBytes] work;
    auto config = S3Config("us-east-1", testCredentials);
    RequestSpec spec;
    spec.bucket = "bucket";
    spec.payloadHash = emptyPayloadSha256Hex;
    spec.when = testTime;
    PreparedRequest p;
    S3Status status;

    static immutable HttpHeader[6] bad = [HttpHeader("X-A", "v\r\nX-B: 1"), HttpHeader("X\nA", "v"),
        HttpHeader("", "v"), HttpHeader("host", "evil"), HttpHeader("AUTHORIZATION", "x"),
        HttpHeader("x-amz-date", "19700101T000000Z")];
    foreach (i; 0 .. bad.length) {
        spec.extraHeaders = bad[i .. i + 1];
        assert(!prepareRequest(config, spec, work[], p, status) && status.kind == FailureKind.invalidRequest);
    }

    static immutable HttpHeader[maxExtraHeaders + 1] many = HttpHeader("X-A", "v");
    spec.extraHeaders = many[];
    assert(!prepareRequest(config, spec, work[], p, status) && status.kind == FailureKind.invalidRequest);
    spec.extraHeaders = many[0 .. maxExtraHeaders];
    assert(prepareRequest(config, spec, work[], p, status) && p.headers.length == maxSignedHeaders);
}

@nogc nothrow pure unittest {
    // A request that cannot fit is refused, not cut short -- signed or
    // not -- and the buffer is left holding nothing.
    auto signedConfig = S3Config("us-east-1", Credentials("AKIDEXAMPLE", "secret"));
    auto unsignedConfig = S3Config("us-east-1");
    RequestSpec spec;
    spec.bucket = "examplebucket";
    spec.key = "test.txt";
    spec.payloadHash = emptyPayloadSha256Hex;
    spec.when = testTime;
    PreparedRequest p;
    S3Status status;

    // 96 bytes hold the host and path but not the URL after them: for an
    // unsigned request this is the only check that can notice.
    char[96] tight = 'x';
    assert(!prepareRequest(unsignedConfig, spec, tight[], p, status));
    assert(status.kind == FailureKind.bufferTooSmall && !status.ok);
    assert(p.url is null && allZero(tight[]));

    // Room for the request but not for its signature: nothing derived from
    // the credentials is left behind.
    char[300] noRoomToSign = 'x';
    assert(!prepareRequest(signedConfig, spec, noRoomToSign[], p, status));
    assert(status.kind == FailureKind.bufferTooSmall && allZero(noRoomToSign[]));

    char[minWorkBytes] enough;
    spec.range = ByteRange.bytes(5, 4);
    assert(!prepareRequest(signedConfig, spec, enough[], p, status));
    assert(status.kind == FailureKind.invalidRequest);
}

@nogc nothrow pure unittest {
    // Nothing that goes into a header line or the credential scope can
    // smuggle a line break or a separator: bucket, region, service, access
    // key id. Half a credential is not "unsigned".
    char[minWorkBytes] work;
    RequestSpec spec;
    spec.bucket = "bucket";
    spec.payloadHash = emptyPayloadSha256Hex;
    spec.when = testTime;
    PreparedRequest p;
    S3Status status;

    bool refused(S3Config config, const(char)[] bucket = "bucket") {
        spec.bucket = bucket;
        return !prepareRequest(config, spec, work[], p, status) && status.kind == FailureKind.invalidRequest;
    }
    assert(refused(S3Config("us-east-1"), "bucket\r\nX-Injected: 1"));
    assert(refused(S3Config("us-east-1"), "evil.example/"));
    assert(refused(S3Config("us-east-1\r\nX: 1")));
    assert(refused(S3Config("us-east-1", testCredentials, "s3\r\nX-Injected: 1")));
    assert(refused(S3Config("us-east-1", testCredentials, "s3/aws4_request, SignedHeaders=host")));
    assert(refused(S3Config("us-east-1", testCredentials, "")));
    assert(refused(S3Config("us-east-1", Credentials("AKID\r\nX-Injected: 1", "secret"))));
    assert(refused(S3Config("us-east-1", Credentials("AKID\n", "secret"))));
    assert(refused(S3Config("us-east-1", Credentials("AKID/20150830", "secret"))));
    assert(refused(S3Config("us-east-1", Credentials("AKID, SignedHeaders=host", "secret"))));
    assert(refused(S3Config("us-east-1", Credentials("AKIDEXAMPLE", ""))));
    assert(refused(S3Config("us-east-1", Credentials("", "secret"))));
    assert(!refused(S3Config("us-east-1", testCredentials)));
    assert(!refused(S3Config("us-east-1")));
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

    // Conditional requests.
    assert(classifyHttpError(304, null).kind == FailureKind.notModified);
    assert(classifyHttpError(412, null).kind == FailureKind.preconditionFailed);
    assert(classifyHttpError(412, cast(const(ubyte)[])
        `<Error><Code>PreconditionFailed</Code><Message>At least one of the pre-conditions you specified did not hold</Message></Error>`)
        .kind == FailureKind.preconditionFailed);
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
        bool rewindOnce;      // ask for the body twice, as a transport resending would
        bool stopAtDeclared;  // stop pulling at the declared length, as libcurl does

        HttpMethod method;
        char[512] url = 0;
        size_t urlLen;
        char[4096] headerText = 0; // "name: value\n" per header
        size_t headerLen;
        ubyte[4096] sent;
        size_t sentLen;
        ulong declaredLength;
        int performs;
        int closes;
        bool workHeldRequest; // the URL was readable while the call ran

    @nogc nothrow:
        Transport handle() return {
            return Transport(&this, &performImpl, &closeImpl);
        }

        const(char)[] headers() const return { return headerText[0 .. headerLen]; }

        private static void closeImpl(void* context) {
            (cast(FakeTransport*) context).closes++;
        }

        private static TransportResult performImpl(void* context, scope ref const HttpCall call) {
            auto self = cast(FakeTransport*) context;
            self.performs++;
            self.method = call.method;
            self.urlLen = call.url.length;
            self.url[0 .. call.url.length] = call.url[];
            self.headerLen = 0;
            foreach (h; call.headers) {
                auto w = Writer(self.headerText[self.headerLen .. $]);
                w.put(h.name);
                w.put(": ");
                w.put(h.value);
                w.put('\n');
                self.headerLen += w.len;
            }
            if (call.hasBody) {
                self.declaredLength = call.bodyLength;
                foreach (pass; 0 .. (self.rewindOnce ? 2 : 1)) {
                    if (pass == 1 && (call.rewind is null || !call.rewind()))
                        return TransportResult(TransportFailure.bodyNotRewindable, 0, 65, "cannot rewind");
                    self.sentLen = 0;
                    while (!(self.stopAtDeclared && self.sentLen >= call.bodyLength)) {
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

    private S3Status openFake(ref S3Client client, ref FakeTransport fake, char[] work,
            S3Config config = S3Config("us-east-1")) @nogc nothrow {
        auto handle = fake.handle;
        auto status = client.open(config, handle, work);
        assert(!handle.isOpen); // ownership moved either way
        return status;
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

    /// `empties` empty chunks, then one real one, then (if `forever`) empty
    /// chunks without end.
    private struct Sparse {
        size_t empties;
        bool forever;
        size_t at;
        static immutable ubyte[3] data = [1, 2, 3];
    @nogc nothrow:
        bool empty() const { return !forever && at > empties; }
        const(ubyte)[] front() const { return at == empties ? data[] : null; }
        void popFront() { at++; }
        Sparse save() { return this; }
    }
}

@nogc nothrow unittest {
    // open takes the transport over: the caller's handle is cleared, so a
    // second close through it cannot reach the connection. A failed open
    // closes the transport, once.
    char[minWorkBytes] work;
    FakeTransport fake;
    {
        auto handle = fake.handle;
        S3Client client;
        assert(client.open(S3Config("us-east-1"), handle, work[]).ok && client.isOpen);
        assert(!handle.isOpen);
        handle.close();
        assert(fake.closes == 0);
    }
    assert(fake.closes == 1); // the client's destructor

    FakeTransport refusedFake;
    S3Client refused;
    char[minWorkBytes - 1] small;
    assert(openFake(refused, refusedFake, small[]).kind == FailureKind.bufferTooSmall);
    assert(!refused.isOpen && refusedFake.closes == 1);
    assert(openFake(refused, refusedFake, work[], S3Config("us-east-1", Credentials("AKID", "")))
        .kind == FailureKind.invalidRequest);
    assert(openFake(refused, refusedFake, work[], S3Config("us-east-1", testCredentials, "s3\r\nX: 1"))
        .kind == FailureKind.invalidRequest);
    assert(openFake(refused, refusedFake, work[], S3Config("")).kind == FailureKind.invalidRequest);
    assert(refusedFake.closes == 4 && refusedFake.performs == 0);

    Transport never;
    assert(refused.open(S3Config("us-east-1"), never, work[]).kind == FailureKind.invalidRequest);
}

@nogc nothrow unittest {
    // putObject from a forward range of small chunks: the transport pulls
    // them one at a time, a resend rewinds, and the caller's range is left
    // untouched so it can be passed again.
    static immutable ubyte[][4] pieces = [[1, 2, 3], [], [4], [5, 6]];
    static immutable ubyte[6] whole = [1, 2, 3, 4, 5, 6];
    char[minWorkBytes] work = 'x';
    FakeTransport fake;
    fake.rewindOnce = true;
    S3Client client;
    assert(openFake(client, fake, work[], S3Config("us-east-1", testCredentials)).ok);

    const(ubyte[])[] chunks = pieces[];
    auto put = client.putObject("bucket", "key", chunks, 6, PayloadHash.unsigned, PutObjectOptions.init, testTime);
    assert(put.ok && put.etag[] == `"fake-etag"` && put.bytesSent == 6);
    assert(fake.method == HttpMethod.put);
    assert(fake.declaredLength == 6 && fake.sent[0 .. fake.sentLen] == whole[]);
    assert(fake.url[0 .. fake.urlLen] == "https://bucket.s3.us-east-1.amazonaws.com/key");
    assert(indexOf(fake.headers, "Authorization: AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/") >= 0);
    assert(chunks.length == 4);
    // The request is gone from the caller's buffer once the call returns.
    assert(allZero(work[]));

    // A body that ends short of its declared length is an error.
    fake.rewindOnce = false;
    assert(client.putObject("bucket", "key", chunks, 7, PayloadHash.unsigned, PutObjectOptions.init, testTime)
        .status.kind == FailureKind.bodyLengthMismatch);
    // A chunk that runs past the declared length is caught as it is
    // pulled: the transport is never handed the excess.
    auto over = client.putObject("bucket", "key", chunks, 5, PayloadHash.unsigned, PutObjectOptions.init, testTime);
    assert(over.status.kind == FailureKind.bodyLengthMismatch);
    assert(fake.sentLen == 4 && over.bytesSent == 4);
    // The hash policy must be stated.
    assert(client.putObject("bucket", "key", chunks, 6, PayloadHash.init, PutObjectOptions.init, testTime)
        .status.kind == FailureKind.invalidRequest);
    // A length no Content-Length can state.
    immutable sentBefore = fake.performs;
    assert(client.putObject("bucket", "key", chunks, cast(ulong) long.max + 1, PayloadHash.unsigned,
        PutObjectOptions.init, testTime).status.kind == FailureKind.invalidRequest);
    assert(fake.performs == sentBefore);
    assert(allZero(work[]));

    client.close();
    assert(fake.closes == 1 && !client.isOpen);
    assert(client.putObject("bucket", "key", chunks, 6, PayloadHash.unsigned, PutObjectOptions.init, testTime)
        .status.kind == FailureKind.invalidRequest);
}

@nogc nothrow unittest {
    // A transport that stops pulling at the declared length (as libcurl
    // does) cannot see a body that goes on. The core looks once more and
    // reports the object as truncated.
    static immutable ubyte[][3] pieces = [[1, 2, 3], [4], [5, 6]];
    char[minWorkBytes] work;
    FakeTransport fake;
    fake.stopAtDeclared = true;
    S3Client client;
    assert(openFake(client, fake, work[]).ok);

    const(ubyte[])[] chunks = pieces[];
    auto longer = client.putObject("bucket", "key", chunks, 4, PayloadHash.unsigned, PutObjectOptions.init, testTime);
    assert(fake.sentLen == 4);
    assert(!longer.ok && longer.status.kind == FailureKind.bodyLengthMismatch && longer.status.httpStatus == 200);

    // Exactly the declared length is fine through the same transport.
    assert(client.putObject("bucket", "key", chunks, 6, PayloadHash.unsigned, PutObjectOptions.init, testTime).ok);
}

@nogc nothrow unittest {
    // Empty chunks are skipped up to a stated bound; a range that never
    // produces data ends the upload instead of spinning in the transport.
    char[minWorkBytes] work;
    FakeTransport fake;
    S3Client client;
    assert(openFake(client, fake, work[]).ok);

    auto patient = Sparse(maxConsecutiveEmptyChunks);
    assert(client.putObject("bucket", "key", patient, 3, PayloadHash.unsigned, PutObjectOptions.init, testTime).ok);
    assert(fake.sentLen == 3);

    auto tooMany = Sparse(maxConsecutiveEmptyChunks + 1);
    assert(client.putObject("bucket", "key", tooMany, 3, PayloadHash.unsigned, PutObjectOptions.init, testTime)
        .status.kind == FailureKind.bodyLengthMismatch);

    auto endless = Sparse(0, true);
    auto stuck = client.putObject("bucket", "key", endless, 6, PayloadHash.unsigned, PutObjectOptions.init, testTime);
    assert(stuck.status.kind == FailureKind.bodyLengthMismatch && stuck.bytesSent == 3);
}

@nogc nothrow unittest {
    // An empty object, and a whole in-memory body through SliceBody and
    // through std.range.only.
    import std.range : only;
    static immutable ubyte[5] bytes = [10, 20, 30, 40, 50];
    char[minWorkBytes] work;
    FakeTransport fake;
    S3Client client;
    assert(openFake(client, fake, work[]).ok);

    const(ubyte[])[] nothing;
    auto empty = client.putObject("bucket", "empty", nothing, 0, PayloadHash.ofBytes(null),
        PutObjectOptions.init, testTime);
    assert(empty.ok && empty.bytesSent == 0 && fake.declaredLength == 0 && fake.sentLen == 0);

    auto slab = SliceBody(bytes[]);
    fake.rewindOnce = true;
    assert(client.putObject("bucket", "slab", slab.source, PayloadHash.ofBytes(bytes[]),
        PutObjectOptions.init, testTime).ok);
    assert(fake.sent[0 .. fake.sentLen] == bytes[]);

    const(ubyte)[] view = bytes[];
    assert(client.putObject("bucket", "only", only(view), 5, PayloadHash.unsigned).ok);
    assert(fake.sent[0 .. fake.sentLen] == bytes[]);
}

@nogc nothrow unittest {
    // An input-only range is consumed and cannot be resent.
    static immutable ubyte[][2] pieces = [[9, 8], [7]];
    static immutable ubyte[3] whole = [9, 8, 7];
    char[minWorkBytes] work;
    FakeTransport fake;
    S3Client client;
    assert(openFake(client, fake, work[]).ok);

    auto once = OnePass(pieces[]);
    assert(client.putObject("bucket", "key", once, 3, PayloadHash.unsigned, PutObjectOptions.init, testTime).ok);
    assert(once.empty && fake.sent[0 .. fake.sentLen] == whole[]);

    fake.rewindOnce = true;
    auto again = OnePass(pieces[]);
    auto put = client.putObject("bucket", "key", again, 3, PayloadHash.unsigned, PutObjectOptions.init, testTime);
    assert(!put.ok && put.status.kind == FailureKind.transportError);
    assert(put.status.transport == TransportFailure.bodyNotRewindable);
}

@nogc nothrow unittest {
    // Upload options become headers, every one of them signed.
    static immutable ubyte[2] bytes = [1, 2];
    static immutable MetadataPair[2] metadata = [MetadataPair("Owner", "me"), MetadataPair("batch-id", "42")];
    char[minWorkBytes] work;
    FakeTransport fake;
    S3Client client;
    assert(openFake(client, fake, work[], S3Config("us-east-1", testCredentials)).ok);

    PutObjectOptions options;
    options.contentType = "text/plain; charset=utf-8";
    options.metadata = metadata[];
    options.storageClass = "STANDARD_IA";
    options.contentMd5 = "DA7ZlRH1pbZ3bkrR3F5vrA==";
    options.checksumAlgorithm = ChecksumAlgorithm.crc32c;
    options.checksumValue = "yZRlqg==";
    auto body_ = SliceBody(bytes[]);
    assert(client.putObject("bucket", "key", body_.source, PayloadHash.unsigned, options, testTime).ok);

    auto sent = fake.headers;
    assert(indexOf(sent, "Content-Type: text/plain; charset=utf-8\n") >= 0);
    assert(indexOf(sent, "x-amz-storage-class: STANDARD_IA\n") >= 0);
    assert(indexOf(sent, "Content-MD5: DA7ZlRH1pbZ3bkrR3F5vrA==\n") >= 0);
    assert(indexOf(sent, "x-amz-checksum-crc32c: yZRlqg==\n") >= 0);
    assert(indexOf(sent, "x-amz-meta-owner: me\n") >= 0 && indexOf(sent, "x-amz-meta-batch-id: 42\n") >= 0);
    assert(indexOf(sent, "SignedHeaders=content-md5;content-type;host;x-amz-checksum-crc32c;" ~
        "x-amz-content-sha256;x-amz-date;x-amz-meta-batch-id;x-amz-meta-owner;x-amz-storage-class, ") >= 0);

    // What cannot be a header is refused before anything is sent.
    immutable before = fake.performs;
    bool refused(PutObjectOptions bad) {
        auto source = SliceBody(bytes[]);
        return client.putObject("bucket", "key", source.source, PayloadHash.unsigned, bad, testTime)
            .status.kind == FailureKind.invalidRequest;
    }
    PutObjectOptions bad;
    bad.contentType = "text/plain\r\nX-Injected: 1";
    assert(refused(bad));
    bad = PutObjectOptions.init;
    static immutable MetadataPair[1] badValue = [MetadataPair("k", "v\nX-Injected: 1")];
    bad.metadata = badValue[];
    assert(refused(bad));
    static immutable MetadataPair[1] badName = [MetadataPair("k: v\r\nX", "v")];
    bad.metadata = badName[];
    assert(refused(bad));
    static immutable MetadataPair[1] emptyName = [MetadataPair("", "v")];
    bad.metadata = emptyName[];
    assert(refused(bad));
    static immutable MetadataPair[maxUserMetadata + 1] tooMany = MetadataPair("k", "v");
    bad.metadata = tooMany[];
    assert(refused(bad));
    bad = PutObjectOptions.init;
    bad.checksumAlgorithm = ChecksumAlgorithm.sha256; // no value
    assert(refused(bad));
    bad = PutObjectOptions.init;
    bad.checksumValue = "AAAA"; // no algorithm
    assert(refused(bad));
    assert(fake.performs == before);

    // The most metadata allowed, with everything else set, still fits.
    static immutable MetadataPair[maxUserMetadata] full = MetadataPair("k", "v");
    options.metadata = full[];
    auto source = SliceBody(bytes[]);
    assert(client.putObject("bucket", "key", source.source, PayloadHash.unsigned, options, testTime).ok);
}

version(unittest) {
    private struct Collect {
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
}

@nogc nothrow unittest {
    // getObject into a delegate sink and into an output range; an error
    // body never reaches the sink; a sink can stop the download.
    char[minWorkBytes] work = 'x';
    FakeTransport fake;
    fake.responseBody = "0123456789abcdefghij";
    S3Client client;
    assert(openFake(client, fake, work[], S3Config("us-east-1", testCredentials)).ok);

    Collect viaDelegate;
    auto got = client.getObject("bucket", "key", &viaDelegate.take, GetObjectOptions.init, testTime);
    assert(got.ok && got.bytesDelivered == 20 && got.etag[] == `"fake-etag"`);
    assert(fake.method == HttpMethod.get);
    assert(cast(const(char)[]) viaDelegate.data[0 .. viaDelegate.len] == "0123456789abcdefghij");
    assert(allZero(work[]));

    Collect viaRange;
    assert(client.getObject("bucket", "key", viaRange).ok);
    assert(viaRange.len == 20);

    Collect stops;
    stops.limit = 10;
    auto stopped = client.getObject("bucket", "key", &stops.take, GetObjectOptions.init, testTime);
    assert(!stopped.ok && stopped.status.kind == FailureKind.aborted && stopped.bytesDelivered == 7);

    fake.status = 404;
    fake.responseBody = "<Error><Code>NoSuchKey</Code><Message>gone</Message></Error>";
    Collect untouched;
    auto missing = client.getObject("bucket", "key", &untouched.take, GetObjectOptions.init, testTime);
    assert(!missing.ok && missing.status.kind == FailureKind.notFound && missing.status.code[] == "NoSuchKey");
    assert(untouched.len == 0 && missing.bytesDelivered == 0);
    assert(allZero(work[])); // the captured error body too
}

@nogc nothrow unittest {
    // A ranged request accepts only a 206. A server that sends the whole
    // object is a typed failure, and none of that body reaches the sink --
    // which may well be a slice of a larger buffer expecting only its part.
    char[minWorkBytes] work;
    FakeTransport fake;
    fake.responseBody = "0123456789abcdefghij";
    S3Client client;
    assert(openFake(client, fake, work[]).ok);

    GetObjectOptions ranged;
    ranged.range = ByteRange.bytes(5, 9);
    ranged.ifMatch = `"etag-1"`;
    ranged.ifNoneMatch = `"etag-2"`;

    Collect ignoredRange;
    auto whole = client.getObject("bucket", "key", &ignoredRange.take, ranged, testTime);
    assert(!whole.ok && whole.status.kind == FailureKind.rangeIgnored && whole.status.httpStatus == 200);
    assert(ignoredRange.len == 0 && whole.bytesDelivered == 0 && whole.etag[] == "");
    assert(indexOf(fake.headers, "Range: bytes=5-9\n") >= 0);
    assert(indexOf(fake.headers, "If-Match: \"etag-1\"\n") >= 0);
    assert(indexOf(fake.headers, "If-None-Match: \"etag-2\"\n") >= 0);

    // The same with an empty 200: no body callback ever runs.
    fake.responseBody = null;
    assert(client.getObject("bucket", "key", &ignoredRange.take, ranged, testTime).status.kind
        == FailureKind.rangeIgnored);

    fake.status = 206;
    fake.responseBody = "56789";
    Collect part;
    auto partial = client.getObject("bucket", "key", &part.take, ranged, testTime);
    assert(partial.ok && partial.partial && part.len == 5);

    // Conditions that do not hold are typed, not "malformed".
    fake.responseBody = null;
    fake.status = 304;
    assert(client.getObject("bucket", "key", &part.take, ranged, testTime).status.kind == FailureKind.notModified);
    fake.status = 412;
    assert(client.getObject("bucket", "key", &part.take, ranged, testTime).status.kind
        == FailureKind.preconditionFailed);
    GetObjectOptions injected;
    injected.ifMatch = "x\r\nX-Injected: 1";
    assert(client.getObject("bucket", "key", &part.take, injected, testTime).status.kind
        == FailureKind.invalidRequest);
}

@nogc nothrow unittest {
    // listObjectsV2: entries and common prefixes through their callbacks,
    // explicit continuation, and a failed page leaving the continuation
    // where it was.
    static struct Keys {
        char[64] text = 0;
        size_t len;
    @nogc nothrow:
        bool take(scope ref const S3ObjectView e) { return add(e.key); }
        bool add(scope const(char)[] s) {
            text[len .. len + s.length] = s[];
            len += s.length;
            text[len++] = ',';
            return true;
        }
    }

    char[minWorkBytes] work = 'x';
    char[minListEntryBuffer] entryBuffer;
    FakeTransport fake;
    S3Client client;
    assert(openFake(client, fake, work[], S3Config("us-east-1", testCredentials)).ok);

    fake.responseBody = `<ListBucketResult><IsTruncated> true </IsTruncated>` ~
        `<Contents><Key>a.txt</Key><Size>1</Size></Contents>` ~
        `<CommonPrefixes><Prefix>p/sub&amp;1/</Prefix></CommonPrefixes>` ~
        `<Contents><Key>b.txt</Key><Size>2</Size></Contents>` ~
        `<NextContinuationToken>page&amp;2</NextContinuationToken></ListBucketResult>`;
    Keys keys, prefixes;
    ListContinuation where;
    auto page = client.listObjectsV2("bucket", ListOptions("p/", "/"), where, entryBuffer[], &keys.take,
        &prefixes.add, testTime);
    assert(page.ok && page.entries == 2 && page.prefixes == 1 && page.isTruncated);
    assert(keys.text[0 .. keys.len] == "a.txt,b.txt," && prefixes.text[0 .. prefixes.len] == "p/sub&1/,");
    assert(!where.done && where.token == "page&2");
    assert(indexOf(fake.url[0 .. fake.urlLen], "continuation-token") < 0);
    assert(indexOf(fake.url[0 .. fake.urlLen], "delimiter=%2F") > 0);
    assert(allZero(work[]));

    // A page that fails part-way: the continuation still names it.
    fake.failAfterBody = true;
    auto failed = client.listObjectsV2("bucket", ListOptions("p/"), where, entryBuffer[], &keys.take, null, testTime);
    assert(!failed.ok && failed.status.kind == FailureKind.transportError && failed.entries == 2);
    assert(where.token == "page&2" && !where.done);
    assert(indexOf(fake.url[0 .. fake.urlLen], "continuation-token=page%262") > 0);

    // A 200 whose body stops before the closing element is not a page, and
    // above all not the last one: the listing must not end here.
    fake.failAfterBody = false;
    fake.responseBody = `<ListBucketResult><IsTruncated>false</IsTruncated>` ~
        `<Contents><Key>c.txt</Key><Size>3</Size></Contents>`;
    auto cut = client.listObjectsV2("bucket", ListOptions("p/"), where, entryBuffer[], null, null, testTime);
    assert(!cut.ok && cut.status.kind == FailureKind.malformedResponse && cut.status.httpStatus == 200);
    assert(cut.entries == 1 && where.token == "page&2" && !where.done);

    fake.responseBody = `<ListBucketResult><IsTruncated>false</IsTruncated>` ~
        `<Contents><Key>c.txt</Key><Size>3</Size></Contents></ListBucketResult>`;
    keys = Keys.init;
    auto last = client.listObjectsV2("bucket", ListOptions("p/"), where, entryBuffer[], &keys.take, null, testTime);
    assert(last.ok && last.entries == 1 && !last.isTruncated && where.done);
    assert(keys.text[0 .. keys.len] == "c.txt,");

    // Truncated with no token, and a body that is not a listing.
    fake.responseBody = `<ListBucketResult><IsTruncated>true</IsTruncated></ListBucketResult>`;
    ListContinuation fresh;
    assert(client.listObjectsV2("bucket", ListOptions.init, fresh, entryBuffer[], null, null, testTime).status.kind
        == FailureKind.malformedResponse);
    fake.responseBody = "<html>proxy says hello</html>";
    assert(client.listObjectsV2("bucket", ListOptions.init, fresh, entryBuffer[], null, null, testTime).status.kind
        == FailureKind.malformedResponse);
    assert(fresh.token == "" && !fresh.done);
}
