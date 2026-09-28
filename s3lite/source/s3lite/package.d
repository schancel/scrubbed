/// s3lite: a minimal, zero-dependency, pure-D S3 client.
///
/// `import s3lite;` re-exports the small public surface most callers need:
/// `Credentials`, `GetObjectRequest`, `GetObjectResult`, `FailureKind`, and
/// `getObject`. Lower-level pieces (the SigV4 signer, the curl-based HTTP
/// transport, the S3 XML error parser) are available from their own
/// `s3lite.sigv4`/`s3lite.http`/`s3lite.xml_error` modules for callers who
/// need them directly.
module s3lite;

public import s3lite.client : Credentials, GetObjectRequest, GetObjectResult,
    FailureKind, S3Error, getObject, buildGetRequest, routeFor;
