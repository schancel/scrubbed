/// s3lite: a minimal, dependency-free S3 client in D.
///
/// The package has two layers, and `import s3lite;` gives both:
///
///   - **The core** (`s3lite.core`): `S3Client`, whose `putObject`,
///     `getObject` and `listObjectsV2` stream -- an upload from a range of
///     chunks, a download into a sink, a listing through a callback -- and
///     are `@nogc nothrow`, with all working memory supplied by the caller.
///     Beneath it sit the signer (`s3lite.sigv4`), the transport interface
///     (`s3lite.transport`) and its libcurl implementation
///     (`s3lite.curl_transport`).
///   - **The convenience layer** (`s3lite.client`): one-call functions that
///     return whole buffers in collected memory.
///
/// `s3lite.transfer` (worker-pool bulk transfer with retries) and
/// `s3lite.http` (one-call HTTP) are imported by name when wanted.
module s3lite;

public import s3lite.core : AmzTime, BodyPull, BodyRewind, BodySink, BodySource, ByteRange, Credentials,
    FailureKind, GetResult, ListContinuation, ListEntryCallback, ListOptions, ListPageResult,
    PayloadHash, PutResult, S3Client, S3Config, S3ObjectView, S3Status, SliceBody, Transport,
    TransportFailure, isChunkRange, maxContinuationToken, minListEntryBuffer, minWorkBytes,
    recommendedListEntryBuffer, recommendedWorkBytes;
public import s3lite.curl_transport : CurlOptions, openCurlTransport;
public import s3lite.client : GetObjectRequest, GetObjectResult, S3Error, getObject,
    buildGetRequest, routeFor;
