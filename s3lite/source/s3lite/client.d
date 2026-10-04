/// Convenience layer: `GetObject`, `PutObject` and `ListObjectsV2` as
/// one-call, whole-buffer functions.
///
/// Each call here opens a connection, runs one `s3lite.core` operation and
/// returns everything in garbage-collected memory: a download as one
/// `ubyte[]`, a listing page as an `S3Object[]`, errors as `string`s. That
/// is the right shape for a small object or a short script and the wrong
/// one for a large object or a program that must not allocate -- those use
/// `s3lite.core.S3Client` directly, which streams and reuses its
/// connection. Nothing in the core depends on this module.
///
/// Like the core operations they wrap, these are single-shot: no retries,
/// no concurrency. `s3lite.transfer` adds both.
module s3lite.client;

import core_ = s3lite.core;
import s3lite.core : AmzTime, ByteRange, ListContinuation, ListOptions, PayloadHash, PreparedRequest,
    RequestSpec, S3Client, S3Config, S3ObjectView, S3Status, SliceBody, isChunkRange,
    prepareRequest, recommendedListEntryBuffer, recommendedWorkBytes;
import s3lite.curl_transport : openCurlTransport;
import s3lite.http : GetOptions, RequestHeader, assumeNoGC, curlOptionsOf;
import s3lite.sigv4 : QueryParam, emptyPayloadSha256Hex;
import s3lite.transport : HttpMethod, Transport;
import std.conv : to;
import std.datetime.systime : Clock, SysTime;
import std.datetime.timezone : UTC;

public import s3lite.core : Credentials, FailureKind;

struct GetObjectRequest {
    string bucket;
    string key;             // raw object key; may contain '/'; not pre-encoded
    string region;          // e.g. "us-east-1"
    Credentials credentials; // Credentials.init => unsigned (public-object) GET
    string service = "s3";
    GetOptions transport;     // pass-through knobs; tests use caBundlePath/resolveOverrides
}

struct S3Error {
    FailureKind kind;
    string code;       // raw S3 <Code>, "" if not parsed from an XML body
    string message;    // raw S3 <Message>, or a diagnostic string
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

/// One object entry from a `ListObjectsV2` page, owning its strings.
struct S3Object {
    string key;
    size_t size;
    string etag;
    string lastModified;
}

/// The core's status as this layer's string-carrying error.
S3Error toS3Error(scope ref const S3Status status) {
    return S3Error(status.kind, status.code[].idup, status.message[].idup, status.httpStatus);
}

package(s3lite) AmzTime amzTimeOf(SysTime t) {
    return AmzTime.fromUnix(t.toUnixTime());
}

/// Opens a core client the way this layer's requests describe one: a fresh
/// libcurl transport configured from `options`, and a collected work
/// buffer. `options.urlOverride` becomes the client's dispatch origin.
package(s3lite) S3Status openClient(ref S3Client client, string region, Credentials credentials,
        string service, GetOptions options) {
    Transport transport;
    auto opened = openCurlTransport(curlOptionsOf(options), transport);
    if (!opened.ok) {
        S3Status status;
        status.kind = FailureKind.transportError;
        status.transport = opened.failure;
        status.message.set(opened.detail);
        return status;
    }
    auto config = S3Config(region, credentials, service, options.urlOverride);
    return client.open(config, transport, new char[recommendedWorkBytes]);
}

/// Virtual-hosted-style host and SigV4-canonical (already segment-encoded)
/// path for one bucket/key/region: `<bucket>.s3.<region>.amazonaws.com`.
struct Route {
    string host;
    string encodedPath; // leading '/', each segment percent-encoded
}

Route routeFor(string bucket, string key, string region) {
    auto built = build(S3Config(region), RequestSpec(HttpMethod.get, bucket, key, null,
        emptyPayloadSha256Hex));
    return Route(built.host, built.url["https://".length + built.host.length .. $]);
}

/// The HTTP request (URL and headers) for one call, as owned strings.
struct BuiltRequest {
    string url;
    RequestHeader[] headers;
    private string host;
}

private BuiltRequest build(S3Config config, RequestSpec spec) {
    auto work = new char[recommendedWorkBytes];
    PreparedRequest prepared;
    S3Status status;
    if (!prepareRequest(config, spec, work, prepared, status)) return BuiltRequest.init;
    BuiltRequest built;
    built.url = prepared.url.idup;
    built.host = prepared.host.idup;
    foreach (h; prepared.headers) built.headers ~= RequestHeader(h.name.idup, h.value.idup);
    return built;
}

/// Builds the request for one GetObject call, signed with SigV4 when
/// credentials are set. Pure given an explicit `now`: this is what the
/// loopback fixture asserts on without a live clock or network.
BuiltRequest buildGetRequest(GetObjectRequest req, SysTime now) {
    return build(S3Config(req.region, req.credentials, req.service),
        RequestSpec(HttpMethod.get, req.bucket, req.key, null, emptyPayloadSha256Hex,
            ByteRange.whole, amzTimeOf(now)));
}

/// Issues one GetObject and returns the whole body. `now` defaults to the
/// real clock; fixtures pass a fixed value so the signature is
/// deterministic.
GetObjectResult getObject(GetObjectRequest req, SysTime now = Clock.currTime(UTC())) {
    S3Client client;
    auto opened = openClient(client, req.region, req.credentials, req.service, req.transport);
    if (!opened.ok) return GetObjectResult(false, [], "", 0, "", toS3Error(opened));

    ubyte[] body_;
    auto got = client.getObject(req.bucket, req.key, ByteRange.whole,
        assumeNoGC((scope const(ubyte)[] chunk) nothrow { body_ ~= chunk; return true; }),
        amzTimeOf(now));
    if (!got.ok) return GetObjectResult(false, [], "", 0, "", toS3Error(got.status));
    return GetObjectResult(true, body_, got.etag[].idup, body_.length, got.contentType[].idup, S3Error.init);
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

/// Builds the request for one whole-buffer PutObject call. The payload hash
/// is the SHA-256 of `req.body_`, which this form has in memory.
BuiltRequest buildPutRequest(PutObjectRequest req, SysTime now) {
    auto hash = PayloadHash.ofBytes(req.body_);
    return build(S3Config(req.region, req.credentials, req.service),
        RequestSpec(HttpMethod.put, req.bucket, req.key, null, hash.headerValue,
            ByteRange.whole, amzTimeOf(now)));
}

/// Issues one PutObject with `req.body_` as the whole body, its SHA-256
/// signed into the request.
PutObjectResult putObject(PutObjectRequest req, SysTime now = Clock.currTime(UTC())) {
    S3Client client;
    auto opened = openClient(client, req.region, req.credentials, req.service, req.transport);
    if (!opened.ok) return PutObjectResult(false, "", toS3Error(opened));

    auto body_ = SliceBody(req.body_);
    auto put = client.putObject(req.bucket, req.key, body_.source, PayloadHash.ofBytes(req.body_),
        amzTimeOf(now));
    if (!put.ok) return PutObjectResult(false, "", toS3Error(put.status));
    return PutObjectResult(true, put.etag[].idup, S3Error.init);
}

/// Issues one PutObject whose body is any input range of byte chunks
/// totalling `length` bytes -- including ranges that allocate or throw
/// (`File.byChunk`, for one), which the `@nogc nothrow` core form does not
/// accept. `req.body_` is ignored. The range is walked as the connection
/// accepts data and is never gathered into one buffer. An exception thrown
/// by the range stops the upload and is reported in the result.
PutObjectResult putObject(R)(PutObjectRequest req, R chunks, ulong length, PayloadHash hash,
        SysTime now = Clock.currTime(UTC()))
if (isChunkRange!R) {
    import std.range.primitives : empty, front, popFront;

    S3Client client;
    auto opened = openClient(client, req.region, req.credentials, req.service, req.transport);
    if (!opened.ok) return PutObjectResult(false, "", toS3Error(opened));

    string thrown;
    bool handedOut = false;
    bool pull(ref const(ubyte)[] chunk) nothrow {
        try {
            while (true) {
                if (handedOut) { chunks.popFront(); handedOut = false; }
                if (chunks.empty) { chunk = null; return true; }
                chunk = chunks.front;
                handedOut = true;
                if (chunk.length) return true;
            }
        } catch (Exception e) {
            thrown = e.msg;
            return false;
        }
    }

    auto put = client.putObject(req.bucket, req.key, core_.BodySource(length, assumeNoGC(&pull), null),
        hash, amzTimeOf(now));
    if (!put.ok) {
        auto error = toS3Error(put.status);
        if (thrown !is null) error.message = "body range threw: " ~ thrown;
        return PutObjectResult(false, "", error);
    }
    return PutObjectResult(true, put.etag[].idup, S3Error.init);
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

/// Builds the request for one `ListObjectsV2` page. `continuationToken` is
/// "" for the first page. Query values are passed to the signer as
/// separate pairs, so a prefix, delimiter or token containing '&' or '=' is
/// encoded as content.
BuiltRequest buildListRequest(ListObjectsV2Request req, string continuationToken, SysTime now) {
    QueryParam[] query = [
        QueryParam("list-type", "2"),
        QueryParam("max-keys", req.maxKeysPerPage.to!string),
    ];
    if (req.prefix.length) query ~= QueryParam("prefix", req.prefix);
    if (req.delimiter.length) query ~= QueryParam("delimiter", req.delimiter);
    if (continuationToken.length) query ~= QueryParam("continuation-token", continuationToken);
    return build(S3Config(req.region, req.credentials, req.service),
        RequestSpec(HttpMethod.get, req.bucket, "", query, emptyPayloadSha256Hex,
            ByteRange.whole, amzTimeOf(now)));
}

private ListObjectsV2Page fetchPage(ref S3Client client, ListObjectsV2Request req,
        ref ListContinuation where, char[] entryBuffer, SysTime now) {
    S3Object[] objects;
    auto options = ListOptions(req.prefix, req.delimiter, cast(uint) req.maxKeysPerPage);
    auto page = client.listObjectsV2(req.bucket, options, where, entryBuffer,
        assumeNoGC((scope ref const S3ObjectView e) nothrow {
            objects ~= S3Object(e.key.idup, cast(size_t) e.size, e.etag.idup, e.lastModified.idup);
            return true;
        }), amzTimeOf(now));
    if (!page.ok) return ListObjectsV2Page(false, [], false, "", toS3Error(page.status));
    return ListObjectsV2Page(true, objects, page.isTruncated, where.token.idup, S3Error.init);
}

/// Fetches one `ListObjectsV2` page and returns its entries as an array.
ListObjectsV2Page listObjectsV2Page(ListObjectsV2Request req, string continuationToken = "",
        SysTime now = Clock.currTime(UTC())) {
    S3Client client;
    auto opened = openClient(client, req.region, req.credentials, req.service, req.transport);
    if (!opened.ok) return ListObjectsV2Page(false, [], false, "", toS3Error(opened));

    ListContinuation where;
    if (!where.resumeFrom(continuationToken))
        return ListObjectsV2Page(false, [], false, "",
            S3Error(FailureKind.bufferTooSmall, "", "continuation token is too long", 0));
    return fetchPage(client, req, where, new char[recommendedListEntryBuffer], now);
}

/// Walks every page of a listing over one connection, invoking `sink` once
/// per object after each page arrives. Pages are fetched lazily, one
/// continuation hop at a time; the whole listing is never held.
///
/// Stops and returns a failure on the first page that fails.
ListObjectsV2Result listObjectsV2(ListObjectsV2Request req,
        scope void delegate(S3Object) sink, SysTime now = Clock.currTime(UTC())) {
    S3Client client;
    auto opened = openClient(client, req.region, req.credentials, req.service, req.transport);
    if (!opened.ok) return ListObjectsV2Result(false, 0, toS3Error(opened));

    auto entryBuffer = new char[recommendedListEntryBuffer];
    size_t count = 0;
    ListContinuation where;
    while (!where.done) {
        // `sink` may allocate or throw, so it runs here, between pages,
        // never inside the transport's callbacks.
        auto page = fetchPage(client, req, where, entryBuffer, now);
        if (!page.ok) return ListObjectsV2Result(false, count, page.error);
        foreach (obj; page.objects) {
            sink(obj);
            count++;
        }
    }
    return ListObjectsV2Result(true, count, S3Error.init);
}

unittest {
    // routeFor: virtual-hosted-style addressing.
    auto r = routeFor("noaa-ghcn-pds", "csv.gz/1763.csv.gz", "us-east-1");
    assert(r.host == "noaa-ghcn-pds.s3.us-east-1.amazonaws.com");
    assert(r.encodedPath == "/csv.gz/1763.csv.gz");
}

version(unittest) {
    import std.datetime : DateTime;

    private string headerOf(BuiltRequest built, string name) {
        foreach (h; built.headers) if (h.name == name) return h.value;
        return null;
    }
}

unittest {
    // buildGetRequest: unsigned path (no credentials) omits Authorization.
    auto req = GetObjectRequest("bucket", "key", "us-east-1", Credentials.init);
    auto built = buildGetRequest(req, SysTime(DateTime(2024, 1, 2, 3, 4, 5), UTC()));
    assert(built.url == "https://bucket.s3.us-east-1.amazonaws.com/key");
    assert(headerOf(built, "Authorization") is null);
    assert(headerOf(built, "X-Amz-Date") == "20240102T030405Z");
    assert(headerOf(built, "X-Amz-Content-Sha256") == emptyPayloadSha256Hex);
}

unittest {
    // buildGetRequest: signed path produces a well-formed AWS4-HMAC-SHA256
    // Authorization header referencing the right access key/scope.
    import std.algorithm.searching : canFind, startsWith;
    auto creds = Credentials("AKIDEXAMPLE", "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY");
    auto req = GetObjectRequest("examplebucket", "test.txt", "us-east-1", creds);
    auto built = buildGetRequest(req, SysTime(DateTime(2015, 8, 30, 12, 36, 0), UTC()));
    auto auth = headerOf(built, "Authorization");
    assert(auth.startsWith("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/s3/aws4_request"));
    assert(auth.canFind("SignedHeaders=host;x-amz-content-sha256;x-amz-date"));
}

unittest {
    // buildPutRequest: the payload hash covers the real body, signed or not.
    import std.algorithm.searching : canFind, startsWith;
    auto body_ = cast(const(ubyte)[]) "hello world";
    auto now = SysTime(DateTime(2015, 8, 30, 12, 36, 0), UTC());
    auto unsigned = buildPutRequest(PutObjectRequest("bucket", "key", "us-east-1", Credentials.init, body_), now);
    assert(unsigned.url == "https://bucket.s3.us-east-1.amazonaws.com/key");
    assert(headerOf(unsigned, "Authorization") is null);
    assert(headerOf(unsigned, "X-Amz-Content-Sha256") ==
        "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9");

    auto creds = Credentials("AKIDEXAMPLE", "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY");
    auto signed = buildPutRequest(PutObjectRequest("examplebucket", "test.txt", "us-east-1", creds, body_), now);
    auto auth = headerOf(signed, "Authorization");
    assert(auth.startsWith("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/s3/aws4_request"));
    assert(auth.canFind("SignedHeaders=host;x-amz-content-sha256;x-amz-date"));
}

unittest {
    // buildListRequest: the query is sorted and encoded, a continuation
    // token round-trips, and '&'/'=' inside a value stay content
    // (regression, issue #367 review).
    import std.algorithm.searching : canFind;
    auto now = SysTime(DateTime(2024, 1, 2, 3, 4, 5), UTC());
    auto req = ListObjectsV2Request("bucket", "us-east-1", Credentials.init, "my prefix/");
    req.maxKeysPerPage = 50;
    assert(buildListRequest(req, "", now).url == "https://bucket.s3.us-east-1.amazonaws.com/?" ~
        "list-type=2&max-keys=50&prefix=my%20prefix%2F");
    assert(!buildListRequest(req, "", now).url.canFind("continuation-token"));
    assert(buildListRequest(req, "abc+def=", now).url.canFind("continuation-token=abc%2Bdef%3D"));

    auto hostile = ListObjectsV2Request("bucket", "us-east-1", Credentials.init, "foo&evil=1", "a&b");
    auto built = buildListRequest(hostile, "tok&en", now);
    assert(built.url.canFind("prefix=foo%26evil%3D1"), built.url);
    assert(!built.url.canFind("evil=1&"), built.url);
    assert(built.url.canFind("delimiter=a%26b"), built.url);
    assert(built.url.canFind("continuation-token=tok%26en"), built.url);
}
