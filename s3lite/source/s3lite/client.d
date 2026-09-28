/// A minimal, real `GetObject`-equivalent primitive: given a bucket, key,
/// region, and (optional) explicit credentials, builds a correctly
/// SigV4-signed (or, with no credentials, unsigned) virtual-hosted-style S3
/// GET, issues it over this package's own `s3lite.http` transport, and
/// returns a typed result.
///
/// Scope (see issue #46's "commit to pure-D SigV4" slice): a single GET, no
/// concurrency, no retries, explicit credentials only (no provider chain).
/// Two forward-looking non-goals are recorded deliberately, not implemented,
/// here:
///
///   1. Future bulk operations (many objects) should use a two-level
///      concurrency model mirroring s5cmd's own design: an object-level
///      worker pool (s5cmd's default: 256 workers) kept separate from
///      per-object multipart-chunk parallelism (s5cmd's default: 5
///      parts/file), with listing streamed into the worker pool rather than
///      listed-then-processed. When this package is eventually wired into
///      scrubbed (a separate, later decision) or used similarly elsewhere,
///      the object-level worker pool should reuse scrubbed's own
///      `std.parallelism.TaskPool` pattern, already used in
///      `source/effects/crawl_orchestrator.d` (`new TaskPool(workers - 1)`)
///      and exposed via its CLI's `--threads` flag -- same architecture, new
///      domain. Not needed for a single GET.
///   2. Future retries should use bounded exponential backoff, matching
///      s5cmd's own real default: 10 attempts, roughly a 1-minute total
///      budget. Not implemented here -- a single GET either succeeds or
///      returns a typed failure.
module s3lite.client;

import s3lite.sigv4;
import s3lite.http;
import s3lite.xml_error;
import std.datetime.systime : Clock, SysTime;
import std.datetime.timezone : UTC;
import std.datetime : DateTime;
import std.format : format;
import std.conv : to;

/// Explicit SigV4 credentials. `Credentials.init` (both fields empty) means
/// "sign nothing" -- the public-object test path, where the request is
/// issued with no `Authorization` header at all.
struct Credentials {
    string accessKeyId;
    string secretAccessKey;

    bool isSet() const pure {
        return accessKeyId.length > 0 && secretAccessKey.length > 0;
    }
}

struct GetObjectRequest {
    string bucket;
    string key;             // raw object key; may contain '/'; not pre-encoded
    string region;          // e.g. "us-east-1"
    Credentials credentials; // Credentials.init => unsigned (public-object) GET
    string service = "s3";
    GetOptions transport;     // pass-through knobs; tests use caBundlePath/resolveOverrides
}

enum FailureKind {
    notFound,           // S3's NoSuchKey/NoSuchBucket, or a plain HTTP 404
    forbidden,           // S3's AccessDenied, or a plain HTTP 403
    malformedResponse,   // 2xx/4xx/5xx body that isn't the shape we expect
    transportError,      // never got a real HTTP response at all (DNS/TLS/connect/timeout)
    other,               // a real S3 error we parsed but didn't specifically classify
}

struct S3Error {
    FailureKind kind;
    string code;       // raw S3 <Code>, "" if not parsed from an XML body
    string message;    // raw S3 <Message>, or a diagnostic string for transportError
    int httpStatus;    // 0 if no HTTP response was ever received
}

struct GetObjectResult {
    bool ok;
    ubyte[] body_;
    string etag;
    size_t contentLength;
    string contentType;
    S3Error error;
}

private string amzDateOf(SysTime t) {
    return format("%04d%02d%02dT%02d%02d%02dZ",
        t.year, t.month, t.day, t.hour, t.minute, t.second);
}

private string dateStampOf(SysTime t) {
    return format("%04d%02d%02d", t.year, t.month, t.day);
}

/// Virtual-hosted-style host and SigV4-canonical (already segment-encoded)
/// path for one bucket/key/region, per issue #46's explicit addressing
/// scheme: `<bucket>.s3.<region>.amazonaws.com`.
struct Route {
    string host;
    string encodedPath; // leading '/', each segment percent-encoded
}

Route routeFor(string bucket, string key, string region) pure {
    auto host = bucket ~ ".s3." ~ region ~ ".amazonaws.com";
    auto rawPath = "/" ~ key;
    return Route(host, canonicalUri(rawPath));
}

/// Builds the real HTTP request (method/URL/headers) for one GetObject call,
/// signing it with SigV4 when credentials are set. Pure and side-effect-free
/// given an explicit `now` -- this is what both the real client and the
/// loopback-TLS test fixture exercise directly, without needing a live
/// clock or network in the fixture's own assertions.
struct BuiltRequest {
    string url;
    RequestHeader[] headers;
}

BuiltRequest buildGetRequest(GetObjectRequest req, SysTime now) {
    auto route = routeFor(req.bucket, req.key, req.region);
    auto amzDate = amzDateOf(now);
    auto dateStamp = dateStampOf(now);
    auto payloadHash = emptyPayloadSha256Hex;

    Header[] signingHeaders = [
        Header("Host", route.host),
        Header("X-Amz-Date", amzDate),
        Header("X-Amz-Content-Sha256", payloadHash),
    ];

    RequestHeader[] outHeaders = [
        RequestHeader("Host", route.host),
        RequestHeader("X-Amz-Date", amzDate),
        RequestHeader("X-Amz-Content-Sha256", payloadHash),
    ];

    if (req.credentials.isSet) {
        auto input = SigningInput("GET", route.encodedPath, "", signingHeaders, [],
            req.credentials.accessKeyId, req.credentials.secretAccessKey,
            amzDate, dateStamp, req.region, req.service);
        auto signed = signRequest(input);
        outHeaders ~= RequestHeader("Authorization", signed.authorizationHeader);
    }

    auto url = "https://" ~ route.host ~ route.encodedPath;
    return BuiltRequest(url, outHeaders);
}

private S3Error classifyHttpError(int status, scope const(ubyte)[] body_) {
    auto parsed = parseS3Error(body_);
    if (parsed.valid) {
        FailureKind kind;
        if (parsed.code == "NoSuchKey" || parsed.code == "NoSuchBucket")
            kind = FailureKind.notFound;
        else if (parsed.code == "AccessDenied")
            kind = FailureKind.forbidden;
        else
            kind = FailureKind.other;
        return S3Error(kind, parsed.code, parsed.message, status);
    }
    // No parseable S3 XML error body -- fall back to plain HTTP status,
    // still typed, but flagged as unparsed via an empty `code`.
    if (status == 404) return S3Error(FailureKind.notFound, "", "HTTP 404 with no parseable S3 error body", status);
    if (status == 403) return S3Error(FailureKind.forbidden, "", "HTTP 403 with no parseable S3 error body", status);
    return S3Error(FailureKind.malformedResponse, "", "unexpected response shape", status);
}

/// Issues one real GetObject-equivalent GET. `now` defaults to the real
/// clock; the loopback fixture passes a fixed value so its expected
/// Authorization header is deterministic.
GetObjectResult getObject(GetObjectRequest req, SysTime now = Clock.currTime(UTC())) {
    auto built = buildGetRequest(req, now);
    auto result = s3lite.http.httpGet(built.url, built.headers, req.transport);

    if (!result.ok) {
        auto detail = result.failureDetail;
        return GetObjectResult(false, [], "", 0, "",
            S3Error(FailureKind.transportError, "", detail, 0));
    }

    auto resp = result.response;
    if (resp.status >= 200 && resp.status < 300) {
        auto etag = resp.header("ETag");
        auto contentType = resp.header("Content-Type");
        size_t contentLength = resp.body_.length;
        return GetObjectResult(true, resp.body_, etag is null ? "" : etag,
            contentLength, contentType is null ? "" : contentType, S3Error.init);
    }

    auto err = classifyHttpError(resp.status, resp.body_);
    return GetObjectResult(false, [], "", 0, "", err);
}

unittest {
    // routeFor: virtual-hosted-style addressing, exactly the scheme issue
    // #46 names.
    auto r = routeFor("noaa-ghcn-pds", "csv.gz/1763.csv.gz", "us-east-1");
    assert(r.host == "noaa-ghcn-pds.s3.us-east-1.amazonaws.com");
    assert(r.encodedPath == "/csv.gz/1763.csv.gz");
}

unittest {
    // buildGetRequest: unsigned path (no credentials) omits Authorization.
    auto req = GetObjectRequest("bucket", "key", "us-east-1", Credentials.init);
    auto now = SysTime(DateTime(2024, 1, 2, 3, 4, 5), UTC());
    auto built = buildGetRequest(req, now);
    assert(built.url == "https://bucket.s3.us-east-1.amazonaws.com/key");
    bool hasAuth = false;
    bool hasContentSha = false;
    foreach (h; built.headers) {
        if (h.name == "Authorization") hasAuth = true;
        if (h.name == "X-Amz-Content-Sha256") {
            hasContentSha = true;
            assert(h.value == emptyPayloadSha256Hex);
        }
    }
    assert(!hasAuth);
    assert(hasContentSha);
}

unittest {
    // buildGetRequest: signed path produces a well-formed AWS4-HMAC-SHA256
    // Authorization header referencing the right access key/scope.
    import std.algorithm.searching : canFind, startsWith;
    auto creds = Credentials("AKIDEXAMPLE", "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY");
    auto req = GetObjectRequest("examplebucket", "test.txt", "us-east-1", creds);
    auto now = SysTime(DateTime(2015, 8, 30, 12, 36, 0), UTC());
    auto built = buildGetRequest(req, now);
    string auth;
    foreach (h; built.headers) if (h.name == "Authorization") auth = h.value;
    assert(auth.startsWith("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/s3/aws4_request"));
    assert(auth.canFind("SignedHeaders=host;x-amz-content-sha256;x-amz-date"));
}

unittest {
    // classifyHttpError against real S3 XML error bodies, captured live
    // against the real `noaa-ghcn-pds` public bucket at implementation time
    // (see tests/live_public_object.d for the live round trip these were
    // captured from) -- not invented shapes.
    auto notFoundKey = cast(const(ubyte)[]) (`<?xml version="1.0" encoding="UTF-8"?>` ~
        `<Error><Code>NoSuchKey</Code><Message>The specified key does not exist.</Message>` ~
        `<Key>csv.gz/does-not-exist-99999.csv.gz</Key><RequestId>94N6A4C5ETJBJKF5</RequestId>` ~
        `<HostId>ELmq6Lb07NfxwjONX/WovjMcATyoTGY7DLIKDfttkOGmminkWrlFWxJe2b845ttIakm2qMv83eKF+tewBHTweC3ulrQKVYp1</HostId></Error>`);
    auto e1 = classifyHttpError(404, notFoundKey);
    assert(e1.kind == FailureKind.notFound);
    assert(e1.code == "NoSuchKey");

    auto notFoundBucket = cast(const(ubyte)[]) (`<?xml version="1.0" encoding="UTF-8"?>` ~
        `<Error><Code>NoSuchBucket</Code><Message>The specified bucket does not exist</Message>` ~
        `<BucketName>this-bucket-should-not-exist-scrubd-s3lite-test</BucketName>` ~
        `<RequestId>5Y81JHN0562BF093</RequestId></Error>`);
    auto e2 = classifyHttpError(404, notFoundBucket);
    assert(e2.kind == FailureKind.notFound);
    assert(e2.code == "NoSuchBucket");

    auto accessDenied = cast(const(ubyte)[]) (
        `<Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>`);
    auto e3 = classifyHttpError(403, accessDenied);
    assert(e3.kind == FailureKind.forbidden);

    // No parseable S3 XML body at all -- falls back to plain HTTP status,
    // still typed rather than crashing.
    auto e4 = classifyHttpError(404, cast(const(ubyte)[]) "");
    assert(e4.kind == FailureKind.notFound);
    auto e5 = classifyHttpError(500, cast(const(ubyte)[]) "not xml");
    assert(e5.kind == FailureKind.malformedResponse);
}
