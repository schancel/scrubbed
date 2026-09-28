/// Real S3 request primitives: `GetObject`, `PutObject`, and `ListObjectsV2`.
/// Given a bucket, key/prefix, region, and (optional) explicit credentials,
/// builds a correctly SigV4-signed (or, with no credentials, unsigned)
/// virtual-hosted-style S3 request, issues it over this package's own
/// `s3lite.http` transport, and returns a typed result.
///
/// Scope (see issue #46's "commit to pure-D SigV4" slice, extended by
/// issue #367 to add `PutObject`/`ListObjectsV2`): single-object/single-page
/// primitives, explicit credentials only (no provider chain), no retries.
/// `s3lite.transfer` (a separate module, deliberately not imported from
/// here -- see its own doc comment) builds the bulk-pull/bulk-push,
/// worker-pool, and bounded-retry behavior described below on top of these
/// primitives:
///
///   1. Bulk operations (many objects) use a two-level concurrency model
///      mirroring s5cmd's own design: an object-level worker pool (s5cmd's
///      default: 256 workers) kept separate from per-object chunk
///      parallelism (s5cmd's default: 5 parts/file), with listing streamed
///      into the worker pool rather than listed-then-processed. The
///      object-level worker pool reuses scrubbed's own
///      `std.parallelism.TaskPool` pattern, already used in
///      `source/effects/crawl_orchestrator.d` (`new TaskPool(workers - 1)`)
///      and exposed via its CLI's `--threads` flag -- same architecture, new
///      domain.
///   2. Retries use bounded exponential backoff, matching s5cmd's own real
///      default: 10 attempts, roughly a 1-minute total budget.
///
/// The primitives in *this* module remain single-shot and retry-free: a
/// single `getObject`/`putObject`/`listObjectsV2Page` call either succeeds or
/// returns a typed failure, with no hidden concurrency or backoff -- that
/// policy lives entirely in `s3lite.transfer`, opted into only by callers who
/// `import s3lite.transfer` themselves.
module s3lite.client;

import s3lite.sigv4;
import s3lite.http;
import s3lite.xml_error;
import s3lite.xml_list;
import std.datetime.systime : Clock, SysTime;
import std.datetime.timezone : UTC;
import std.datetime : DateTime;
import std.format : format;
import std.conv : to;

// Re-exported so callers of `s3lite.client` see one flat `S3Object` type for
// `ListObjectsV2` results without also having to `import s3lite.xml_list`
// themselves.
public import s3lite.xml_list : S3Object;

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

// ---------------------------------------------------------------------
// PutObject
// ---------------------------------------------------------------------

struct PutObjectRequest {
    string bucket;
    string key;
    string region;
    Credentials credentials; // Credentials.init => unsigned PUT (only ever valid against a fixture)
    const(ubyte)[] body_;
    string service = "s3";
    GetOptions transport;
}

struct PutObjectResult {
    bool ok;
    string etag;
    S3Error error;
}

/// Builds the real HTTP request (method/URL/headers/body) for one PutObject
/// call, signing it with SigV4 when credentials are set. Pure and
/// side-effect-free given an explicit `now`, mirroring `buildGetRequest` --
/// the payload hash covers the real body bytes rather than
/// `emptyPayloadSha256Hex`.
BuiltRequest buildPutRequest(PutObjectRequest req, SysTime now) {
    auto route = routeFor(req.bucket, req.key, req.region);
    auto amzDate = amzDateOf(now);
    auto dateStamp = dateStampOf(now);
    auto payloadHash = sha256Hex(req.body_);

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
        auto input = SigningInput("PUT", route.encodedPath, "", signingHeaders, req.body_,
            req.credentials.accessKeyId, req.credentials.secretAccessKey,
            amzDate, dateStamp, req.region, req.service);
        auto signed = signRequest(input);
        outHeaders ~= RequestHeader("Authorization", signed.authorizationHeader);
    }

    auto url = "https://" ~ route.host ~ route.encodedPath;
    return BuiltRequest(url, outHeaders);
}

/// Issues one real PutObject-equivalent PUT. `now` defaults to the real
/// clock; fixture tests pass a fixed value the same way `getObject`'s do.
PutObjectResult putObject(PutObjectRequest req, SysTime now = Clock.currTime(UTC())) {
    auto built = buildPutRequest(req, now);
    auto result = s3lite.http.httpPut(built.url, built.headers, req.body_, req.transport);

    if (!result.ok) {
        auto detail = result.failureDetail;
        return PutObjectResult(false, "", S3Error(FailureKind.transportError, "", detail, 0));
    }

    auto resp = result.response;
    if (resp.status >= 200 && resp.status < 300) {
        auto etag = resp.header("ETag");
        return PutObjectResult(true, etag is null ? "" : etag, S3Error.init);
    }

    auto err = classifyHttpError(resp.status, resp.body_);
    return PutObjectResult(false, "", err);
}

// ---------------------------------------------------------------------
// ListObjectsV2
// ---------------------------------------------------------------------

struct ListObjectsV2Request {
    string bucket;
    string region;
    Credentials credentials; // Credentials.init => unsigned LIST (only ever valid against a fixture)
    string prefix = "";
    string delimiter = "";
    int maxKeysPerPage = 1000; // S3's own per-page cap; this bounds one page, not the overall listing
    string service = "s3";
    GetOptions transport;
}

struct ListObjectsV2Page {
    bool ok;
    S3Object[] objects;
    bool isTruncated;
    string nextContinuationToken;
    S3Error error;
}

/// Result of draining a full (possibly multi-page) listing via
/// `listObjectsV2`.
struct ListObjectsV2Result {
    bool ok;
    size_t objectCount; // number of objects actually delivered to `sink` before any failure
    S3Error error;       // set only when `ok` is false
}

/// Builds this page's query as already-separated key/value pairs, never as
/// one concatenated raw string -- `prefix`/`delimiter`/`continuationToken`
/// are caller/S3-controlled values that may themselves legally contain '&'
/// or '=' (S3 key prefixes in particular), and splicing them into a raw
/// "&"-joined string before encoding would let such a character be misread
/// as a query delimiter instead of literal content. See
/// `s3lite.sigv4.canonicalQueryString`'s doc comment for the corruption
/// this sidesteps.
private QueryParam[] listQueryParams(ListObjectsV2Request req, string continuationToken) {
    QueryParam[] q = [
        QueryParam("list-type", "2"),
        QueryParam("max-keys", req.maxKeysPerPage.to!string),
    ];
    if (req.prefix.length) q ~= QueryParam("prefix", req.prefix);
    if (req.delimiter.length) q ~= QueryParam("delimiter", req.delimiter);
    if (continuationToken.length) q ~= QueryParam("continuation-token", continuationToken);
    return q;
}

/// Builds the real HTTP request for one `ListObjectsV2` page against the
/// bucket root, signing it with SigV4 when credentials are set. Pure and
/// side-effect-free given an explicit `now`, mirroring `buildGetRequest`.
/// `continuationToken` is `""` for the first page.
BuiltRequest buildListRequest(ListObjectsV2Request req, string continuationToken, SysTime now) {
    auto route = routeFor(req.bucket, "", req.region);
    auto amzDate = amzDateOf(now);
    auto dateStamp = dateStampOf(now);
    auto payloadHash = emptyPayloadSha256Hex;
    auto queryParams = listQueryParams(req, continuationToken);
    auto query = canonicalQueryStringFromPairs(queryParams);

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
            amzDate, dateStamp, req.region, req.service, queryParams);
        auto signed = signRequest(input);
        outHeaders ~= RequestHeader("Authorization", signed.authorizationHeader);
    }

    // Reuses `canonicalQueryStringFromPairs`'s own encoding+sort for the
    // dispatched URL too -- S3 doesn't care about query-parameter order in
    // the actual request, only the signature computation does, so one
    // encoder is enough and it's guaranteed consistent with what was signed.
    auto url = "https://" ~ route.host ~ route.encodedPath ~
        (query.length ? "?" ~ query : "");
    return BuiltRequest(url, outHeaders);
}

/// Issues one real `ListObjectsV2` page fetch (single HTTP GET, single
/// response). `now` defaults to the real clock. Low-level and directly
/// testable/deterministic; `listObjectsV2` below is the streaming driver
/// most callers want.
ListObjectsV2Page listObjectsV2Page(ListObjectsV2Request req, string continuationToken = "",
        SysTime now = Clock.currTime(UTC())) {
    auto built = buildListRequest(req, continuationToken, now);
    auto result = s3lite.http.httpGet(built.url, built.headers, req.transport);

    if (!result.ok) {
        auto detail = result.failureDetail;
        return ListObjectsV2Page(false, [], false, "",
            S3Error(FailureKind.transportError, "", detail, 0));
    }

    auto resp = result.response;
    if (resp.status >= 200 && resp.status < 300) {
        auto parsed = parseListObjectsV2(resp.body_);
        if (!parsed.valid)
            return ListObjectsV2Page(false, [], false, "",
                S3Error(FailureKind.malformedResponse, "", "unparseable ListBucketResult body", resp.status));
        return ListObjectsV2Page(true, parsed.objects, parsed.isTruncated,
            parsed.nextContinuationToken, S3Error.init);
    }

    auto err = classifyHttpError(resp.status, resp.body_);
    return ListObjectsV2Page(false, [], false, "", err);
}

/// Streams every object across every page of a `ListObjectsV2` listing,
/// invoking `sink` once per object as each page arrives -- pages are fetched
/// lazily, one continuation-token hop at a time, never materializing the
/// full listing into memory up front. This is precisely what
/// `s3lite.transfer`'s bulk-pull path feeds its object-level worker pool
/// from, so a very large bucket listing doesn't have to finish before the
/// first download starts.
///
/// Stops and returns a failure on the first page that fails; stops cleanly
/// (returns `ok == true`) once a page reports `isTruncated == false`.
ListObjectsV2Result listObjectsV2(ListObjectsV2Request req,
        scope void delegate(S3Object) sink, SysTime now = Clock.currTime(UTC())) {
    size_t count = 0;
    string token = "";
    while (true) {
        auto page = listObjectsV2Page(req, token, now);
        if (!page.ok)
            return ListObjectsV2Result(false, count, page.error);
        foreach (obj; page.objects) {
            sink(obj);
            count++;
        }
        if (!page.isTruncated) return ListObjectsV2Result(true, count, S3Error.init);
        token = page.nextContinuationToken;
        if (token.length == 0) {
            // S3 contract violation guard: truncated but no token to
            // continue with. Treat as a malformed response rather than
            // looping forever on an empty-token first page.
            return ListObjectsV2Result(false, count,
                S3Error(FailureKind.malformedResponse, "", "isTruncated but no NextContinuationToken", 0));
        }
    }
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

unittest {
    // buildPutRequest: unsigned path omits Authorization but the payload
    // hash covers the real body -- not emptyPayloadSha256Hex like a GET.
    auto req = PutObjectRequest("bucket", "key", "us-east-1", Credentials.init,
        cast(const(ubyte)[]) "hello world");
    auto now = SysTime(DateTime(2024, 1, 2, 3, 4, 5), UTC());
    auto built = buildPutRequest(req, now);
    assert(built.url == "https://bucket.s3.us-east-1.amazonaws.com/key");
    bool hasAuth = false;
    string contentSha;
    foreach (h; built.headers) {
        if (h.name == "Authorization") hasAuth = true;
        if (h.name == "X-Amz-Content-Sha256") contentSha = h.value;
    }
    assert(!hasAuth);
    assert(contentSha == sha256Hex(cast(const(ubyte)[]) "hello world"));
    assert(contentSha != emptyPayloadSha256Hex);
}

unittest {
    // buildPutRequest: signed path produces a well-formed Authorization
    // header, same shape/credential-scope machinery as buildGetRequest,
    // now over a PUT with a real payload hash.
    import std.algorithm.searching : canFind, startsWith;
    auto creds = Credentials("AKIDEXAMPLE", "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY");
    auto req = PutObjectRequest("examplebucket", "test.txt", "us-east-1", creds,
        cast(const(ubyte)[]) "payload bytes");
    auto now = SysTime(DateTime(2015, 8, 30, 12, 36, 0), UTC());
    auto built = buildPutRequest(req, now);
    string auth;
    foreach (h; built.headers) if (h.name == "Authorization") auth = h.value;
    assert(auth.startsWith("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/s3/aws4_request"));
    assert(auth.canFind("SignedHeaders=host;x-amz-content-sha256;x-amz-date"));
}

unittest {
    // buildListRequest: query string is present, sorted/encoded, and
    // consistent between the dispatched URL and what got signed.
    auto req = ListObjectsV2Request("bucket", "us-east-1", Credentials.init, "my prefix/");
    req.maxKeysPerPage = 50;
    auto now = SysTime(DateTime(2024, 1, 2, 3, 4, 5), UTC());
    auto built = buildListRequest(req, "", now);
    assert(built.url == "https://bucket.s3.us-east-1.amazonaws.com/?" ~
        "list-type=2&max-keys=50&prefix=my%20prefix%2F");
}

unittest {
    // buildListRequest: a continuation token (opaque, S3-supplied) round
    // trips into the query string exactly, percent-encoded like any other
    // query value.
    import std.algorithm.searching : canFind;
    auto req = ListObjectsV2Request("bucket", "us-east-1", Credentials.init);
    auto now = SysTime(DateTime(2024, 1, 2, 3, 4, 5), UTC());
    auto built = buildListRequest(req, "abc+def=", now);
    assert(built.url.canFind("continuation-token=abc%2Bdef%3D"));
}

unittest {
    // Regression (issue #367 review): a prefix/delimiter/continuation-token
    // containing a literal '&' must be percent-encoded as ordinary content,
    // never misread as a query-parameter delimiter. Before the fix, this
    // silently truncated `prefix` at the '&' and injected a bogus
    // `evil=1` parameter (`?evil=1&list-type=2&max-keys=1000&prefix=foo`)
    // rather than a %26-encoded `foo&evil=1`.
    import std.algorithm.searching : canFind;
    auto req = ListObjectsV2Request("bucket", "us-east-1", Credentials.init, "foo&evil=1");
    auto now = SysTime(DateTime(2024, 1, 2, 3, 4, 5), UTC());
    auto built = buildListRequest(req, "", now);
    assert(built.url.canFind("prefix=foo%26evil%3D1"), built.url);
    assert(!built.url.canFind("evil=1&"), built.url);

    auto req2 = ListObjectsV2Request("bucket", "us-east-1", Credentials.init, "", "a&b");
    auto built2 = buildListRequest(req2, "tok&en", now);
    assert(built2.url.canFind("delimiter=a%26b"), built2.url);
    assert(built2.url.canFind("continuation-token=tok%26en"), built2.url);
}

unittest {
    // listObjectsV2: streams objects across two pages via a fake page
    // fetcher stitched in through a delegate is not possible here (the
    // function issues real HTTP internally), so this unit test instead
    // exercises the pure `listQueryParams`/pagination-token plumbing indirectly
    // via `buildListRequest`'s own first/second-page shape -- the full
    // multi-page streaming drive itself is proven end to end by
    // `tests/put_list_loopback_fixture.d`.
    import std.algorithm.searching : canFind;
    auto req = ListObjectsV2Request("bucket", "us-east-1", Credentials.init);
    auto now = SysTime(DateTime(2024, 1, 2, 3, 4, 5), UTC());
    auto firstPage = buildListRequest(req, "", now);
    auto secondPage = buildListRequest(req, "next-token", now);
    assert(!firstPage.url.canFind("continuation-token"));
    assert(secondPage.url.canFind("continuation-token=next-token"));
}
