/// Re-verifies the Phobos-HMAC-based `s3lite.sigv4` signer against the real
/// AWS SigV4 test-suite fixtures, byte-exact, after porting the algorithm
/// off scrubbed's `crypto.sha256`/`crypto.hmac_sha256` and onto
/// `std.digest.hmac.HMAC!(std.digest.sha.SHA256)`.
///
/// Evidence source (unchanged from scrubbed's own prior evaluation, see
/// `experiments/sigv4_check/evaluate.d` in the parent repository): the
/// AWS-published SigV4 test suite described at
/// https://docs.aws.amazon.com/general/latest/gr/signature-v4-test-suite.html,
/// obtained via https://github.com/saibotsivad/aws-sig-v4-test-suite
/// (Apache-2.0; that repository's own README states "these are the test
/// suite files found in the AWS documentation"). The `.req`/`.creq`/`.sts`/
/// `.authz` fixture quadruples under `tests/fixtures/` are byte-for-byte
/// copies of the same files already vetted in the parent repository's
/// `experiments/sigv4_check/fixtures/`, copied here so this package is
/// fully self-contained (no path back into the parent `scrubbed` checkout).
/// Shared test credentials/config (accessKeyId=AKIDEXAMPLE, secretAccessKey,
/// region=us-east-1, service=service) come from that same source's
/// `index.json` `config` object.
///
/// Run via: `dub run --config=sigv4-fixtures` (from this package's own
/// directory).
import s3lite.sigv4 : Header, SigningInput, signRequest;
import std.array : split;
import std.file : readText;
import std.path : buildPath, dirName;
import std.stdio : writeln;
import std.string : indexOf, startsWith;

enum accessKeyId = "AKIDEXAMPLE";
enum secretAccessKey = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY";
enum region = "us-east-1";
enum service = "service";
enum amzDate = "20150830T123600Z";
enum dateStamp = "20150830";

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

void checkCase(string fixturesRoot, string name) {
    auto dir = buildPath(fixturesRoot, name);
    auto reqText = readText(buildPath(dir, name ~ ".req"));
    auto expectedCreq = readText(buildPath(dir, name ~ ".creq"));
    auto expectedSts = readText(buildPath(dir, name ~ ".sts"));
    auto expectedAuthz = readText(buildPath(dir, name ~ ".authz"));

    auto parsed = parseReq(reqText);
    auto input = SigningInput(parsed.method, parsed.path, parsed.query,
        parsed.headers, parsed.body_, accessKeyId, secretAccessKey,
        amzDate, dateStamp, region, service);
    auto signed = signRequest(input);

    check(signed.canonicalRequest == expectedCreq, name ~ ": canonical request mismatch");
    check(signed.stringToSign == expectedSts, name ~ ": string-to-sign mismatch");
    check(signed.authorizationHeader == expectedAuthz, name ~ ": authorization header/signature mismatch");
    writeln("  ", name, ": PASS (canonical request, string-to-sign, signature all match AWS test suite)");
}

void main() {
    // __FILE_FULL_PATH__ would be more robust, but buildPath from the
    // process cwd matches how `dub run` invokes this (cwd == package root).
    auto fixturesRoot = buildPath("tests", "fixtures");
    writeln("s3lite SigV4 re-verification: Phobos-HMAC signer vs. AWS SigV4 test suite fixtures");
    foreach (name; ["get-vanilla", "get-vanilla-query", "post-vanilla",
        "get-unreserved", "get-vanilla-query-order-key-case",
        "get-header-key-duplicate", "get-header-value-order",
        "get-header-value-trim"])
        checkCase(fixturesRoot, name);
    writeln("s3lite sigv4 re-verification: 8/8 AWS test-suite fixtures PASS "
        ~ "(canonical request + string-to-sign + final signature, byte-exact, "
        ~ "on std.digest.hmac.HMAC!SHA256)");
}
