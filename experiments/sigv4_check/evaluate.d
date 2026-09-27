/// Verifies the pure-D SigV4 signer in sigv4.d against real AWS SigV4 test
/// vectors, for issue #46 (S01 S3 client/capability decision).
///
/// Evidence source: the AWS-published SigV4 test suite described at
/// https://docs.aws.amazon.com/general/latest/gr/signature-v4-test-suite.html
/// (AWS's own live page did not render usable content when checked
/// 2026-09-27; see docs/sigv4-evaluation.md for details), obtained here via
/// https://github.com/saibotsivad/aws-sig-v4-test-suite (Apache-2.0, per that
/// repository's own README and LICENSE, and per its README's statement that
/// "these are the test suite files found in the AWS documentation"). The
/// eight `.req`/`.creq`/`.sts`/`.authz` fixture quadruples under
/// experiments/sigv4_check/fixtures/ are byte-for-byte copies of files
/// fetched from that repository's `raw/aws-sig-v4-test-suite/` directory on
/// 2026-09-27, unmodified. Shared test credentials/config
/// (accessKeyId=AKIDEXAMPLE, secretAccessKey, region=us-east-1,
/// service=service) come from that repository's `index.json` `config` object,
/// fetched the same day.
///
/// This is evaluation-only: no network I/O, no AWS account, no production
/// wiring. Run from the repository root:
///   ldc2 -i -I=source -O -release experiments/sigv4_check/evaluate.d \
///     experiments/sigv4_check/sigv4.d -of=/tmp/sigv4-evaluate
///   /tmp/sigv4-evaluate
import sigv4 : Header, SigningInput, signRequest;
import std.array : split;
import std.file : readText;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : indexOf, startsWith;

// Fixed test configuration, taken verbatim from the AWS SigV4 test suite's
// index.json `config` object (region/service/accessKeyId/secretAccessKey)
// and shared `X-Amz-Date` value used by every fixture below.
enum accessKeyId = "AKIDEXAMPLE";
enum secretAccessKey = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY";
enum region = "us-east-1";
enum service = "service";
enum amzDate = "20150830T123600Z";
enum dateStamp = "20150830";

enum fixturesRoot = buildPath("experiments", "sigv4_check", "fixtures");

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

/// Parses one AWS test-suite `.req` file: an HTTP/1.1 request-line, header
/// lines (name:value, no leading-space continuations in this fixture set),
/// a blank line if a body follows, then the raw body. Mirrors the reference
/// parser in https://github.com/saibotsivad/aws-sig-v4-test-suite's
/// generate.js (LF-only line endings, as the AWS test-suite files use).
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

private ptrdiff_t lastIndexOfChar(string s, char c) {
    foreach_reverse (i, ch; s) if (ch == c) return i;
    return -1;
}

void checkCase(string name) {
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
    writeln("SigV4 evaluation: verifying pure-D signer against AWS SigV4 test suite fixtures");
    foreach (name; ["get-vanilla", "get-vanilla-query", "post-vanilla",
        "get-unreserved", "get-vanilla-query-order-key-case",
        "get-header-key-duplicate", "get-header-value-order",
        "get-header-value-trim"])
        checkCase(name);
    writeln("sigv4 evaluate: 8/8 AWS test-suite fixtures PASS "
        ~ "(canonical request + string-to-sign + final signature, byte-exact)");
}
