/// AWS Signature Version 4 (SigV4) request signing, without the collector.
///
/// Every function here is `@nogc nothrow pure` (the clock read in
/// `AmzTime.now` excepted). Output is written into a caller-supplied
/// `s3lite.fixed.Writer`; the canonical request, string-to-sign and
/// Authorization header come back as views of that buffer. Running out of
/// room is reported, never papered over. SHA-256 and HMAC are Phobos's own
/// `std.digest.sha.SHA256` and `std.digest.hmac.HMAC`, which are already
/// `@nogc`, so this package still has no dependencies.
///
/// The payload hash is an input, not something this module computes from a
/// body: the caller states it (a SHA-256 it already has, or
/// `unsignedPayload`), so signing never requires the body in memory.
///
/// Fixed bounds: at most `maxSignedHeaders` headers and `maxQueryParams`
/// query parameters per request. A request needs, in the writer, roughly
/// its canonical request plus 400 bytes plus the lengths of the access key,
/// secret key, region and service; `signRequest` fails with
/// `bufferTooSmall` when that is not available.
///
/// Verified byte-exact against the AWS SigV4 test-suite vectors -- see
/// `tests/sigv4_fixtures.d`.
module s3lite.sigv4;

import s3lite.fixed : Writer, toLowerAscii, indexOf;
import std.digest.hmac : HMAC;
import std.digest.sha : SHA256, sha256Of;

/// A request header as it will be transmitted, before SigV4's lowercasing,
/// trimming and merging.
struct Header {
    const(char)[] name;
    const(char)[] value;
}

/// One query parameter, key and value kept apart and not yet encoded.
struct QueryParam {
    const(char)[] key;
    const(char)[] value;
}

enum size_t maxSignedHeaders = 32;
enum size_t maxQueryParams = 16;

/// SHA-256 of the empty string: the `x-amz-content-sha256` value of a
/// request with no body.
enum string emptyPayloadSha256Hex =
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

/// The `x-amz-content-sha256` value (and canonical-request payload line)
/// that tells S3 the body is not covered by the signature.
enum string unsignedPayload = "UNSIGNED-PAYLOAD";

enum SignFailure {
    none,
    bufferTooSmall,
    tooManyHeaders,
    tooManyQueryParams,
}

@nogc nothrow pure {

/// Lowercase hex of a 32-byte digest.
char[64] hexOf(scope const ubyte[32] bytes) {
    static immutable char[16] digits = "0123456789abcdef";
    char[64] result = void;
    foreach (i, b; bytes) {
        result[i * 2] = digits[b >> 4];
        result[i * 2 + 1] = digits[b & 0xf];
    }
    return result;
}

/// SHA-256 of `data`, lowercase hex.
char[64] sha256Hex(scope const(ubyte)[] data) {
    return hexOf(sha256Of(data));
}

/// HMAC-SHA256 (RFC 2104) of `message` under `key`.
ubyte[32] hmacSha256(scope const(ubyte)[] key, scope const(ubyte)[] message) {
    auto hmac = HMAC!SHA256(key);
    hmac.put(message);
    return hmac.finish();
}

private bool isUnreserved(char c) {
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
        (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_' || c == '~';
}

private immutable char[16] upperHex = "0123456789ABCDEF";

/// SigV4's UriEncode(): every byte outside the unreserved set becomes
/// `%XX` with uppercase hex; space is `%20`, never `+`.
void uriEncodeInto(ref Writer w, scope const(char)[] value) {
    foreach (c; value) {
        if (isUnreserved(c)) w.put(c);
        else {
            w.put('%');
            w.put(upperHex[(cast(ubyte) c) >> 4]);
            w.put(upperHex[(cast(ubyte) c) & 0xf]);
        }
    }
}

/// Canonical URI: each '/'-delimited segment encoded on its own, '/' kept.
/// An empty path becomes "/".
void canonicalUriInto(ref Writer w, scope const(char)[] rawPath) {
    if (rawPath.length == 0) { w.put('/'); return; }
    size_t start = 0;
    foreach (i, c; rawPath) {
        if (c == '/') {
            uriEncodeInto(w, rawPath[start .. i]);
            w.put('/');
            start = i + 1;
        }
    }
    uriEncodeInto(w, rawPath[start .. $]);
}

/// Walks the encoded form of a string without materialising it, so two
/// values can be ordered by their encoded bytes in place.
private struct EncodedChars {
    const(char)[] source;
    size_t index;
    ubyte phase; // 0: at a byte; 1, 2: the two hex digits of an escape

@nogc nothrow pure:
    bool empty() const { return index >= source.length; }

    char front() const {
        immutable c = source[index];
        if (isUnreserved(c)) return c;
        final switch (phase) {
            case 0: return '%';
            case 1: return upperHex[(cast(ubyte) c) >> 4];
            case 2: return upperHex[(cast(ubyte) c) & 0xf];
        }
    }

    void popFront() {
        if (isUnreserved(source[index]) || phase == 2) { index++; phase = 0; }
        else phase++;
    }
}

private int compareEncoded(scope const(char)[] a, scope const(char)[] b) {
    auto x = EncodedChars(a);
    auto y = EncodedChars(b);
    for (; !x.empty && !y.empty; x.popFront(), y.popFront()) {
        immutable cx = x.front, cy = y.front;
        if (cx != cy) return cx < cy ? -1 : 1;
    }
    if (x.empty && y.empty) return 0;
    return x.empty ? -1 : 1;
}

private bool writeSortedQuery(ref Writer w, scope QueryParam[] pairs) {
    // Insertion sort: at most maxQueryParams entries, and stable.
    foreach (i; 1 .. pairs.length) {
        auto item = pairs[i];
        size_t j = i;
        for (; j > 0; j--) {
            auto c = compareEncoded(pairs[j - 1].key, item.key);
            if (c == 0) c = compareEncoded(pairs[j - 1].value, item.value);
            if (c <= 0) break;
            pairs[j] = pairs[j - 1];
        }
        pairs[j] = item;
    }
    foreach (i, p; pairs) {
        if (i) w.put('&');
        uriEncodeInto(w, p.key);
        w.put('=');
        uriEncodeInto(w, p.value);
    }
    return true;
}

/// Canonical query string from key/value pairs that are already apart:
/// each key and value is encoded, then pairs are sorted by encoded key and
/// encoded value. Use this for values that come from data (prefixes,
/// delimiters, continuation tokens): a literal `&` or `=` inside one is
/// content and is encoded as such.
SignFailure canonicalQueryFromPairsInto(ref Writer w, scope const(QueryParam)[] params) {
    if (params.length > maxQueryParams) return SignFailure.tooManyQueryParams;
    QueryParam[maxQueryParams] pairs;
    foreach (i, p; params) pairs[i] = QueryParam(p.key, p.value);
    writeSortedQuery(w, pairs[0 .. params.length]);
    return w.overflow ? SignFailure.bufferTooSmall : SignFailure.none;
}

/// Canonical query string from a raw `a=b&c=d` string. This splits on `&`
/// and the first `=` *before* encoding, so it is only correct when those
/// characters in `rawQuery` are structural. For values that come from data
/// use `canonicalQueryFromPairsInto`.
SignFailure canonicalQueryInto(ref Writer w, scope const(char)[] rawQuery) {
    if (rawQuery.length == 0) return SignFailure.none;
    QueryParam[maxQueryParams] pairs;
    size_t count = 0;
    size_t start = 0;
    while (start <= rawQuery.length) {
        auto amp = indexOf(rawQuery, '&', start);
        immutable end = amp < 0 ? rawQuery.length : cast(size_t) amp;
        auto part = rawQuery[start .. end];
        if (count == maxQueryParams) return SignFailure.tooManyQueryParams;
        immutable eq = indexOf(part, '=');
        pairs[count++] = eq < 0 ? QueryParam(part, null) : QueryParam(part[0 .. eq], part[eq + 1 .. $]);
        start = end + 1;
    }
    writeSortedQuery(w, pairs[0 .. count]);
    return w.overflow ? SignFailure.bufferTooSmall : SignFailure.none;
}

private int compareNames(scope const(char)[] a, scope const(char)[] b) {
    immutable n = a.length < b.length ? a.length : b.length;
    foreach (i; 0 .. n) {
        immutable x = toLowerAscii(a[i]), y = toLowerAscii(b[i]);
        if (x != y) return x < y ? -1 : 1;
    }
    return a.length == b.length ? 0 : (a.length < b.length ? -1 : 1);
}

/// A header value with leading/trailing blanks removed and inner runs of
/// spaces and tabs collapsed to one space.
private void putTrimmedValue(ref Writer w, scope const(char)[] raw) {
    import s3lite.fixed : trim;
    bool lastWasSpace = false;
    foreach (c; trim(raw)) {
        if (c == ' ' || c == '\t') {
            if (!lastWasSpace) w.put(' ');
            lastWasSpace = true;
        } else {
            w.put(c);
            lastWasSpace = false;
        }
    }
}

/// Full input to one signing operation. All slices are borrowed for the
/// call only.
struct SigningInput {
    const(char)[] method;
    const(char)[] canonicalUri;   /// already canonical (`canonicalUriInto`)
    const(char)[] canonicalQuery; /// already canonical (`canonicalQuery*Into`); "" if none
    const(Header)[] headers;      /// every header to sign; must include Host and X-Amz-Date
    const(char)[] payloadHash;    /// hex SHA-256 of the body, or `unsignedPayload`
    const(char)[] accessKeyId;
    const(char)[] secretAccessKey;
    const(char)[] amzDate;        /// e.g. "20150830T123600Z"
    const(char)[] dateStamp;      /// e.g. "20150830"
    const(char)[] region;
    const(char)[] service;
}

/// Views into the writer `signRequest` was given, valid while that buffer
/// is left alone.
struct SignedRequest {
    const(char)[] canonicalRequest;
    const(char)[] stringToSign;
    const(char)[] credentialScope;
    const(char)[] authorizationHeader;
    char[64] signatureHex;
}

/// Zeroes key material with stores the optimiser may not drop as dead.
void wipe(scope ubyte[] bytes) @trusted {
    static void volatileZero(ubyte* p, size_t n) @nogc nothrow {
        import core.volatile : volatileStore;
        foreach (i; 0 .. n) volatileStore(p + i, cast(ubyte) 0);
    }
    // Writing zeroes has no effect a caller can observe through `pure`.
    (cast(void function(ubyte*, size_t) @nogc nothrow pure) &volatileZero)(bytes.ptr, bytes.length);
}

/// The four-step signing-key derivation:
///   kDate    = HMAC("AWS4" + secretKey, dateStamp)
///   kRegion  = HMAC(kDate, region)
///   kService = HMAC(kRegion, service)
///   kSigning = HMAC(kService, "aws4_request")
/// `scratch` briefly holds "AWS4" + secret and is wiped before returning.
SignFailure deriveSigningKey(ref Writer scratch, scope const(char)[] secretAccessKey,
        scope const(char)[] dateStamp, scope const(char)[] region, scope const(char)[] service,
        out ubyte[32] key) {
    immutable start = scratch.mark;
    scratch.put("AWS4");
    scratch.put(secretAccessKey);
    if (scratch.overflow) return SignFailure.bufferTooSmall;
    auto kDate = hmacSha256(cast(const(ubyte)[]) scratch.since(start), cast(const(ubyte)[]) dateStamp);
    scratch.rewind(start, true);
    auto kRegion = hmacSha256(kDate[], cast(const(ubyte)[]) region);
    auto kService = hmacSha256(kRegion[], cast(const(ubyte)[]) service);
    key = hmacSha256(kService[], cast(const(ubyte)[]) "aws4_request");
    // The intermediate keys are as good as the secret for their scope.
    wipe(kDate[]);
    wipe(kRegion[]);
    wipe(kService[]);
    return SignFailure.none;
}

/// Builds the canonical request and string-to-sign, derives the signing
/// key, and produces the signature and Authorization header, all appended
/// to `w`. Headers are lowercased, their values trimmed, duplicates merged
/// with ',' in the order given, and the result sorted by name.
SignFailure signRequest(scope ref const SigningInput input, ref Writer w, out SignedRequest signed) {
    if (input.headers.length > maxSignedHeaders) return SignFailure.tooManyHeaders;

    // Header order: indexes sorted by lowercased name, stably, so equal
    // names stay in the order they were given.
    ubyte[maxSignedHeaders] order;
    foreach (i; 0 .. input.headers.length) {
        size_t j = i;
        for (; j > 0; j--) {
            if (compareNames(input.headers[order[j - 1]].name, input.headers[i].name) <= 0) break;
            order[j] = order[j - 1];
        }
        order[j] = cast(ubyte) i;
    }
    auto sorted = order[0 .. input.headers.length];

    immutable requestStart = w.mark;
    w.put(input.method);
    w.put('\n');
    w.put(input.canonicalUri);
    w.put('\n');
    w.put(input.canonicalQuery);
    w.put('\n');
    foreach (n, idx; sorted) {
        auto h = input.headers[idx];
        immutable continues = n > 0 && compareNames(input.headers[sorted[n - 1]].name, h.name) == 0;
        if (continues) w.put(',');
        else {
            if (n > 0) w.put('\n');
            foreach (c; h.name) w.put(toLowerAscii(c));
            w.put(':');
        }
        putTrimmedValue(w, h.value);
    }
    if (sorted.length) w.put('\n');
    w.put('\n');
    immutable namesStart = w.mark;
    foreach (n, idx; sorted) {
        auto name = input.headers[idx].name;
        if (n > 0) {
            if (compareNames(input.headers[sorted[n - 1]].name, name) == 0) continue;
            w.put(';');
        }
        foreach (c; name) w.put(toLowerAscii(c));
    }
    immutable namesEnd = w.mark;
    w.put('\n');
    w.put(input.payloadHash);
    if (w.overflow) return SignFailure.bufferTooSmall;
    signed.canonicalRequest = w.since(requestStart);
    auto signedNames = w.buf[namesStart .. namesEnd];

    immutable requestHash = sha256Hex(cast(const(ubyte)[]) signed.canonicalRequest);
    immutable stringStart = w.mark;
    w.put("AWS4-HMAC-SHA256\n");
    w.put(input.amzDate);
    w.put('\n');
    immutable scopeStart = w.mark;
    w.put(input.dateStamp);
    w.put('/');
    w.put(input.region);
    w.put('/');
    w.put(input.service);
    w.put("/aws4_request");
    immutable scopeEnd = w.mark;
    w.put('\n');
    w.put(requestHash[]);
    if (w.overflow) return SignFailure.bufferTooSmall;
    signed.stringToSign = w.since(stringStart);
    signed.credentialScope = w.buf[scopeStart .. scopeEnd];

    ubyte[32] signingKey;
    auto keyStatus = deriveSigningKey(w, input.secretAccessKey, input.dateStamp, input.region,
        input.service, signingKey);
    if (keyStatus != SignFailure.none) return keyStatus;
    signed.signatureHex = hexOf(hmacSha256(signingKey[], cast(const(ubyte)[]) signed.stringToSign));
    wipe(signingKey[]);

    immutable authStart = w.mark;
    w.put("AWS4-HMAC-SHA256 Credential=");
    w.put(input.accessKeyId);
    w.put('/');
    w.put(signed.credentialScope);
    w.put(", SignedHeaders=");
    w.put(signedNames);
    w.put(", Signature=");
    w.put(signed.signatureHex[]);
    if (w.overflow) return SignFailure.bufferTooSmall;
    signed.authorizationHeader = w.since(authStart);
    return SignFailure.none;
}

} // @nogc nothrow pure

/// The request time in the two forms SigV4 uses, held inline.
struct AmzTime {
    private char[16] stamp_ = "19700101T000000Z";

@nogc nothrow:
    /// "YYYYMMDDTHHMMSSZ", the `X-Amz-Date` value.
    const(char)[] amzDate() const return pure { return stamp_[]; }

    /// "YYYYMMDD", the credential-scope date.
    const(char)[] dateStamp() const return pure { return stamp_[0 .. 8]; }

    /// From seconds since 1970-01-01T00:00:00Z.
    static AmzTime fromUnix(long seconds) pure {
        long days = seconds / 86_400;
        long rem = seconds % 86_400;
        if (rem < 0) { rem += 86_400; days--; }

        // Civil date from a day count (proleptic Gregorian).
        immutable z = days + 719_468;
        immutable era = (z >= 0 ? z : z - 146_096) / 146_097;
        immutable doe = z - era * 146_097;
        immutable yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        immutable doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        immutable mp = (5 * doy + 2) / 153;
        immutable day = doy - (153 * mp + 2) / 5 + 1;
        immutable month = mp < 10 ? mp + 3 : mp - 9;
        immutable year = yoe + era * 400 + (month <= 2 ? 1 : 0);

        AmzTime t;
        static void digits(char[] dst, long value) @nogc nothrow pure {
            foreach_reverse (ref c; dst) { c = cast(char)('0' + value % 10); value /= 10; }
        }
        digits(t.stamp_[0 .. 4], year);
        digits(t.stamp_[4 .. 6], month);
        digits(t.stamp_[6 .. 8], day);
        t.stamp_[8] = 'T';
        digits(t.stamp_[9 .. 11], rem / 3600);
        digits(t.stamp_[11 .. 13], rem / 60 % 60);
        digits(t.stamp_[13 .. 15], rem % 60);
        t.stamp_[15] = 'Z';
        return t;
    }

    /// The system clock, read without the collector.
    static AmzTime now() {
        import core.stdc.time : time;
        return fromUnix(cast(long) time(null));
    }
}

unittest {
    assert(sha256Hex(null) == emptyPayloadSha256Hex);
}

unittest {
    assert(AmzTime.fromUnix(0).amzDate == "19700101T000000Z");
    assert(AmzTime.fromUnix(1_440_938_160).amzDate == "20150830T123600Z");
    assert(AmzTime.fromUnix(1_440_938_160).dateStamp == "20150830");
    assert(AmzTime.fromUnix(951_782_399).amzDate == "20000228T235959Z");
    assert(AmzTime.fromUnix(951_782_400).amzDate == "20000229T000000Z"); // leap day
    assert(AmzTime.fromUnix(4_102_444_799).amzDate == "20991231T235959Z");
}

unittest {
    // A value containing '&' or '=' is content when it arrives as a pair --
    // regression for the ListObjectsV2 prefix/delimiter/continuation-token
    // corruption (issue #367 review).
    char[128] storage;
    auto w = Writer(storage[]);
    assert(canonicalQueryFromPairsInto(w, [QueryParam("list-type", "2"),
        QueryParam("prefix", "foo&evil=1")]) == SignFailure.none);
    assert(w.since(0) == "list-type=2&prefix=foo%26evil%3D1");

    w.rewind(0);
    canonicalQueryFromPairsInto(w, [QueryParam("delimiter", "a&b"), QueryParam("continuation-token", "tok&en")]);
    assert(w.since(0) == "continuation-token=tok%26en&delimiter=a%26b");

    // Raw form: sorted by encoded key, then encoded value.
    w.rewind(0);
    assert(canonicalQueryInto(w, "b=2&a=z&a=%") == SignFailure.none);
    assert(w.since(0) == "a=%25&a=z&b=2");
}

unittest {
    char[64] storage;
    auto w = Writer(storage[]);
    canonicalUriInto(w, "/a b/c+d/");
    assert(w.since(0) == "/a%20b/c%2Bd/");
    w.rewind(0);
    canonicalUriInto(w, "");
    assert(w.since(0) == "/");
}

@nogc nothrow pure unittest {
    // Too little room is an error, and the secret never stays in the buffer.
    static immutable Header[2] headers = [Header("Host", "example.amazonaws.com"),
        Header("X-Amz-Date", "20150830T123600Z")];
    SigningInput input;
    input.method = "GET";
    input.canonicalUri = "/";
    input.headers = headers[];
    input.payloadHash = emptyPayloadSha256Hex;
    input.accessKeyId = "AKIDEXAMPLE";
    input.secretAccessKey = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY";
    input.amzDate = "20150830T123600Z";
    input.dateStamp = "20150830";
    input.region = "us-east-1";
    input.service = "service";

    char[100] small;
    auto tight = Writer(small[]);
    SignedRequest signed;
    assert(signRequest(input, tight, signed) == SignFailure.bufferTooSmall);

    char[1024] storage = 0;
    auto w = Writer(storage[]);
    assert(signRequest(input, w, signed) == SignFailure.none);
    // AWS test suite, get-vanilla.
    assert(signed.signatureHex == "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31");
    assert(indexOf(storage[], "wJalrXUtnFEMI") < 0);
}
