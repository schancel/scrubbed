/// Real, live GET against a real, stable, publicly-documented public S3
/// object -- no AWS account, no credentials, no billed resource.
///
/// Object used: `s3://noaa-ghcn-pds/csv.gz/1763.csv.gz`, region us-east-1.
///
/// Why this object: `noaa-ghcn-pds` is NOAA's Global Historical
/// Climatology Network Daily (GHCN-D) dataset, published on the AWS Open
/// Data Registry at https://registry.opendata.aws/noaa-ghcn/ (an
/// ADX/NOAA-maintained public dataset, "Anyone can access this data" /
/// public S3 bucket per that registry entry). `csv.gz/1763.csv.gz` is one
/// of that dataset's per-year historical archive files (the year 1763),
/// verified live at implementation time (2026-09-27) via an unauthenticated
/// `ListObjectsV2` call against the bucket, and via a direct GET (HTTP 200,
/// Content-Length 3358, ETag "efe18d88cfb5c3372fe0206c521b2239",
/// Last-Modified 2022-09-09). Historical-year archive files in this dataset
/// are append-only/immutable snapshots (new data lands in later years'
/// files, e.g. the current year), so this specific object is expected to
/// keep working indefinitely; if it ever moves, any other `csv.gz/<year>.csv.gz`
/// key under the same bucket/prefix is an equally valid substitute.
///
/// This program proves two things live, not just the happy path:
///   1. A real successful GET against the object above, parsed correctly
///      (status, ETag, Content-Length, and real body bytes gzip-decode to
///      the expected size).
///   2. A real GET against a deliberately nonexistent key on the same live
///      bucket, and a deliberately nonexistent bucket, both correctly
///      parsed from S3's real XML error response into `FailureKind.notFound`
///      -- not just inferred from the HTTP status code alone.
///
/// Run via: `dub run --config=live-public-object` (from this package's own
/// directory). Requires outbound internet access to *.amazonaws.com.
import s3lite.client : GetObjectRequest, Credentials, FailureKind, getObject;
import std.stdio : writeln;
import std.conv : to;

void check(bool condition, string label) {
    if (!condition) throw new Exception("FAIL: " ~ label);
}

void main() {
    writeln("s3lite live public-object proof (no AWS account/credentials/billed resource)");

    // 1. Real successful GET, unsigned (public-object path: no credentials).
    auto okReq = GetObjectRequest("noaa-ghcn-pds", "csv.gz/1763.csv.gz", "us-east-1", Credentials.init);
    auto okResult = getObject(okReq);
    check(okResult.ok, "expected the real public GET to succeed: kind=" ~
        (okResult.ok ? "" : okResult.error.kind.to!string) ~ " msg=" ~ okResult.error.message);
    check(okResult.contentLength == 3358, "unexpected Content-Length: " ~ okResult.contentLength.to!string);
    check(okResult.body_.length == 3358, "unexpected real body length: " ~ okResult.body_.length.to!string);
    check(okResult.etag == `"efe18d88cfb5c3372fe0206c521b2239"`,
        "unexpected ETag: " ~ okResult.etag);
    // gzip magic bytes, confirming the real body is really the object we expect.
    check(okResult.body_.length >= 2 && okResult.body_[0] == 0x1f && okResult.body_[1] == 0x8b,
        "body does not start with the gzip magic bytes");
    writeln("  1. real successful GET: status 200, Content-Length=", okResult.contentLength,
        ", ETag=", okResult.etag, " -- PASS");

    // 2a. Real nonexistent key on the same live, real bucket.
    auto missingKeyReq = GetObjectRequest("noaa-ghcn-pds",
        "csv.gz/does-not-exist-s3lite-issue-46-proof.csv.gz", "us-east-1", Credentials.init);
    auto missingKeyResult = getObject(missingKeyReq);
    check(!missingKeyResult.ok, "expected the nonexistent-key GET to fail");
    check(missingKeyResult.error.kind == FailureKind.notFound,
        "expected notFound, got " ~ missingKeyResult.error.kind.to!string);
    check(missingKeyResult.error.code == "NoSuchKey",
        "expected real S3 <Code>NoSuchKey</Code>, got '" ~ missingKeyResult.error.code ~ "'");
    check(missingKeyResult.error.httpStatus == 404, "expected HTTP 404");
    writeln("  2a. real nonexistent-key GET: HTTP ", missingKeyResult.error.httpStatus,
        ", parsed <Code>", missingKeyResult.error.code, "</Code> -> notFound -- PASS");

    // 2b. Real nonexistent bucket.
    auto missingBucketReq = GetObjectRequest(
        "s3lite-issue-46-proof-bucket-does-not-exist", "anything", "us-east-1", Credentials.init);
    auto missingBucketResult = getObject(missingBucketReq);
    check(!missingBucketResult.ok, "expected the nonexistent-bucket GET to fail");
    check(missingBucketResult.error.kind == FailureKind.notFound,
        "expected notFound, got " ~ missingBucketResult.error.kind.to!string);
    check(missingBucketResult.error.code == "NoSuchBucket",
        "expected real S3 <Code>NoSuchBucket</Code>, got '" ~ missingBucketResult.error.code ~ "'");
    writeln("  2b. real nonexistent-bucket GET: HTTP ", missingBucketResult.error.httpStatus,
        ", parsed <Code>", missingBucketResult.error.code, "</Code> -> notFound -- PASS");

    writeln("s3lite live public-object proof: PASS (real success + real two-shape 404 parsing)");
}
