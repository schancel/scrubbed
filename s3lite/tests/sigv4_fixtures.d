/// Verifies the collector-free `s3lite.sigv4` signer, byte-exact, against
/// published SigV4 vectors: canonical request, string-to-sign and
/// Authorization header.
///
/// Three groups of vectors under `tests/fixtures/`, each a `.req`/`.creq`/
/// `.sts`/`.authz` quadruple:
///
///   1. The AWS SigV4 test suite
///      (https://docs.aws.amazon.com/general/latest/gr/signature-v4-test-suite.html,
///      obtained via https://github.com/saibotsivad/aws-sig-v4-test-suite,
///      Apache-2.0): eight cases signed for a service named "service".
///   2. Two examples from the Amazon S3 API reference, "Signature
///      Calculations for the Authorization Header: Transferring Payload in a
///      Single Chunk": a ranged GetObject and a ListObjects. Their
///      signatures are the ones that page prints.
///      A third from the same page, `s3-put-object`, signs a body and two
///      headers beyond the usual three (`Date`, `x-amz-storage-class`).
///   3. Two vectors AWS does not publish, with the credentials, date and
///      bucket of group 2. Their expected files were derived with a
///      separate implementation (Python's `hashlib`/`hmac`), which
///      reproduces all three group-2 signatures; they are not AWS's.
///      `s3-put-unsigned-payload`: a PutObject under the
///      `UNSIGNED-PAYLOAD` policy.
///      `s3-put-extra-signed-headers`: a PutObject carrying nine signed
///      headers -- content type, Content-MD5, storage class, a checksum
///      and user metadata -- with mixed-case names and a value that needs
///      trimming.
///
/// The signer takes the payload hash as an input. For a case whose request
/// carries `X-Amz-Content-Sha256`, that header's value is the hash, as it is
/// for S3; otherwise the hash is the SHA-256 of the request body.
///
/// Run via: `dub run --config=sigv4-fixtures` (from this package's own
/// directory).
import s3lite.fixed : Writer;
import s3lite.sigv4;
import std.array : split;
import std.file : readText;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : indexOf;
import std.uni : sicmp;

/// Who signs, when, and for which service.
struct Signer {
    string accessKeyId;
    string secretAccessKey;
    string amzDate;
    string service;
}

immutable suiteSigner = Signer("AKIDEXAMPLE", "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
    "20150830T123600Z", "service");
immutable s3DocsSigner = Signer("AKIAIOSFODNN7EXAMPLE", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    "20130524T000000Z", "s3");
enum region = "us-east-1";

void check(bool condition, string label) {
    if (!condition) throw new Exception(label);
}

struct ParsedRequest {
    string method;
    string path;
    string query;
    Header[] headers;
    ubyte[] body_;
}

private ptrdiff_t lastIndexOfChar(string s, char c) {
    foreach_reverse (i, ch; s) if (ch == c) return i;
    return -1;
}

/// Parses one AWS test-suite `.req` file: request-line, header lines, a
/// blank line if a body follows, then the raw body (LF-only line endings,
/// as the AWS test-suite files use; a multi-line body is rejoined with
/// CRLF, matching the reference generator this suite was fetched from).
ParsedRequest parseReq(string text) {
    auto lines = text.split("\n");
    check(lines.length >= 1, "empty .req fixture");
    auto requestLine = lines[0];
    auto firstSpace = requestLine.indexOf(' ');
    auto lastSpace = requestLine.lastIndexOfChar(' ');
    check(firstSpace > 0 && lastSpace > firstSpace, "malformed request line");
    auto method = requestLine[0 .. firstSpace];
    auto uri = requestLine[firstSpace + 1 .. lastSpace];
    string path = uri;
    string query = "";
    auto q = uri.indexOf('?');
    if (q >= 0) { path = uri[0 .. q]; query = uri[q + 1 .. $]; }

    Header[] headers;
    size_t i = 1;
    while (i < lines.length) {
        if (lines[i].length == 0) { i++; break; }
        auto colon = lines[i].indexOf(':');
        check(colon > 0, "malformed header line: " ~ lines[i]);
        headers ~= Header(lines[i][0 .. colon], lines[i][colon + 1 .. $]);
        i++;
    }
    string bodyText;
    foreach (idx, line; lines[i .. $]) {
        if (idx > 0) bodyText ~= "\r\n";
        bodyText ~= line;
    }
    return ParsedRequest(method, path, query, headers, cast(ubyte[]) bodyText);
}

/// The signing itself: no collector, no exceptions, caller's buffer.
SignFailure sign(scope ref const ParsedRequest parsed, scope ref const Signer signer,
        scope const(char)[] payloadHash, ref Writer w, out SignedRequest signed) @nogc nothrow pure {
    immutable uriStart = w.mark;
    canonicalUriInto(w, parsed.path);
    auto uri = w.since(uriStart);
    immutable queryStart = w.mark;
    auto queryStatus = canonicalQueryInto(w, parsed.query);
    if (queryStatus != SignFailure.none) return queryStatus;

    SigningInput input;
    input.method = parsed.method;
    input.canonicalUri = uri;
    input.canonicalQuery = w.since(queryStart);
    input.headers = parsed.headers;
    input.payloadHash = payloadHash;
    input.accessKeyId = signer.accessKeyId;
    input.secretAccessKey = signer.secretAccessKey;
    input.amzDate = signer.amzDate;
    input.dateStamp = signer.amzDate[0 .. 8];
    input.region = region;
    input.service = signer.service;
    return signRequest(input, w, signed);
}

void checkCase(string fixturesRoot, string name, Signer signer) {
    auto dir = buildPath(fixturesRoot, name);
    auto reqText = readText(buildPath(dir, name ~ ".req"));
    auto expectedCreq = readText(buildPath(dir, name ~ ".creq"));
    auto expectedSts = readText(buildPath(dir, name ~ ".sts"));
    auto expectedAuthz = readText(buildPath(dir, name ~ ".authz"));

    auto parsed = parseReq(reqText);
    string payloadHash = sha256Hex(parsed.body_).idup;
    foreach (h; parsed.headers)
        if (sicmp(h.name, "X-Amz-Content-Sha256") == 0) payloadHash = h.value.idup;

    char[2048] work;
    auto w = Writer(work[]);
    SignedRequest signed;
    check(sign(parsed, signer, payloadHash, w, signed) == SignFailure.none, name ~ ": signing failed");

    check(signed.canonicalRequest == expectedCreq, name ~ ": canonical request mismatch");
    check(signed.stringToSign == expectedSts, name ~ ": string-to-sign mismatch");
    check(signed.authorizationHeader == expectedAuthz, name ~ ": authorization header/signature mismatch");
    writeln("  ", name, ": PASS (canonical request, string-to-sign, signature)");
}

void main() {
    // Relative to the process cwd, which is the package root under `dub run`.
    auto fixturesRoot = buildPath("tests", "fixtures");
    writeln("s3lite SigV4 verification: @nogc signer vs. published vectors");
    foreach (name; ["get-vanilla", "get-vanilla-query", "post-vanilla",
        "get-unreserved", "get-vanilla-query-order-key-case",
        "get-header-key-duplicate", "get-header-value-order",
        "get-header-value-trim"])
        checkCase(fixturesRoot, name, suiteSigner);
    foreach (name; ["s3-get-object-range", "s3-list-objects", "s3-put-object"])
        checkCase(fixturesRoot, name, s3DocsSigner);
    writeln("  (independently derived, not published by AWS:)");
    foreach (name; ["s3-put-unsigned-payload", "s3-put-extra-signed-headers"])
        checkCase(fixturesRoot, name, s3DocsSigner);
    writeln("s3lite sigv4 verification: 8/8 AWS test-suite vectors, 3/3 S3 API-reference vectors "
        ~ "and 2/2 independently derived vectors (unsigned payload, extra signed headers) PASS "
        ~ "(canonical request + string-to-sign + signature, byte-exact)");
}
