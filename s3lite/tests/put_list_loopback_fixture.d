/// Loopback fixture proving `PutObject` and `ListObjectsV2` (paginated)
/// round-trip against a real (plaintext) TCP loopback HTTP server --
/// extending `tests/loopback_fixture.d`'s own proven Section-A technique
/// (verify the real signed request bytes on the wire, then parse a real
/// response back through this package's own transport) to issue #367's two
/// new primitives. TLS trust-chain behavior itself is already fully proven,
/// method-agnostically, by `loopback_fixture.d`'s Section B (the same
/// `s3lite.http` transport code path handles GET/PUT/LIST alike), so this
/// fixture stays plaintext and focuses on what's new: PUT body signing plus
/// response ETag parsing, and multi-page `ListObjectsV2` continuation-token
/// pagination actually driving two real HTTP round trips.
///
/// No AWS account, credential, or network access beyond 127.0.0.1 is used.
/// Run via: `dub run --config=put-list-loopback-fixture` (from this
/// package's own directory).
import s3lite.client : Credentials, PutObjectRequest, ListObjectsV2Request,
    S3Object, putObject, listObjectsV2;
import s3lite.http : GetOptions;
import std.algorithm.searching : canFind;
import std.conv : to;
import std.datetime.systime : SysTime;
import std.datetime.timezone : UTC;
import std.datetime : DateTime;
import std.socket : Socket, TcpSocket, InternetAddress, SocketOptionLevel, SocketOption;
import std.stdio : writeln;
import std.string : startsWith;
import core.thread : Thread;

void check(bool condition, string label) {
    if (!condition) throw new Exception("FAIL: " ~ label);
}

string receiveAll(Socket peer) {
    char[16384] bytes;
    auto n = peer.receive(bytes[]);
    check(n > 0, "loopback peer received no request");
    return bytes[0 .. cast(size_t) n].idup;
}

/// A. PutObject: real request construction (method, path, signed headers,
/// real body bytes on the wire) plus a real 200 response with an ETag
/// parsed back correctly.
void checkPutObjectRoundTrip() {
    writeln("A. PutObject loopback round trip...");

    auto listener = new TcpSocket();
    listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
    listener.bind(new InternetAddress("127.0.0.1", 0));
    auto port = (cast(InternetAddress) listener.localAddress()).port;
    listener.listen(1);

    string capturedRequest;
    Exception serverError;
    auto worker = new Thread({
        try {
            auto peer = listener.accept();
            scope(exit) peer.close();
            capturedRequest = receiveAll(peer);
            auto response = "HTTP/1.1 200 OK\r\nETag: \"deadbeef\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            peer.send(response);
        } catch (Exception e) {
            serverError = e;
        }
    });
    worker.start();
    scope(exit) { worker.join(); listener.close(); }

    auto creds = Credentials("AKIDEXAMPLE", "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY");
    GetOptions opts;
    opts.urlOverride = "http://127.0.0.1:" ~ port.to!string;
    auto req = PutObjectRequest("examplebucket", "put-key.txt", "us-east-1", creds,
        cast(const(ubyte)[]) "hello loopback", "s3", opts);
    auto now = SysTime(DateTime(2015, 8, 30, 12, 36, 0), UTC());
    auto result = putObject(req, now);

    check(serverError is null, serverError is null ? "" : serverError.msg);
    check(capturedRequest.startsWith("PUT /put-key.txt HTTP/1.1\r\n"), "request line mismatch:\n" ~ capturedRequest);
    check(capturedRequest.canFind("Host: examplebucket.s3.us-east-1.amazonaws.com\r\n"), "Host header missing/wrong");
    check(capturedRequest.canFind("Authorization: AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE"), "Authorization header missing/wrong");
    check(capturedRequest.canFind("\r\n\r\nhello loopback"), "request body missing/wrong");
    check(result.ok, "PutObject should have succeeded");
    check(result.etag == `"deadbeef"`, "unexpected ETag: " ~ result.etag);

    writeln("   PASS: real signed PUT request + body on the wire, ETag parsed from a real response");
}

/// B. ListObjectsV2: two real, sequential HTTP round trips -- the first
/// page's `NextContinuationToken` really drives the second request's
/// `continuation-token` query parameter, and `listObjectsV2`'s streaming
/// driver delivers all three objects across both pages to the caller.
void checkListObjectsV2Pagination() {
    writeln("B. ListObjectsV2 pagination loopback round trip...");

    auto listener = new TcpSocket();
    listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
    listener.bind(new InternetAddress("127.0.0.1", 0));
    auto port = (cast(InternetAddress) listener.localAddress()).port;
    listener.listen(2);

    string[] capturedRequests;
    Exception serverError;
    auto worker = new Thread({
        try {
            auto firstPageBody = `<?xml version="1.0" encoding="UTF-8"?>` ~
                `<ListBucketResult><IsTruncated>true</IsTruncated>` ~
                `<Contents><Key>a.txt</Key><ETag>"a"</ETag><Size>1</Size></Contents>` ~
                `<Contents><Key>b.txt</Key><ETag>"b"</ETag><Size>2</Size></Contents>` ~
                `<NextContinuationToken>page-2-token</NextContinuationToken></ListBucketResult>`;
            auto secondPageBody = `<?xml version="1.0" encoding="UTF-8"?>` ~
                `<ListBucketResult><IsTruncated>false</IsTruncated>` ~
                `<Contents><Key>c.txt</Key><ETag>"c"</ETag><Size>3</Size></Contents>` ~
                `</ListBucketResult>`;

            foreach (body_; [firstPageBody, secondPageBody]) {
                auto peer = listener.accept();
                scope(exit) peer.close();
                capturedRequests ~= receiveAll(peer);
                auto response = "HTTP/1.1 200 OK\r\nContent-Type: application/xml\r\n" ~
                    "Content-Length: " ~ body_.length.to!string ~ "\r\nConnection: close\r\n\r\n" ~ body_;
                peer.send(response);
            }
        } catch (Exception e) {
            serverError = e;
        }
    });
    worker.start();
    scope(exit) { worker.join(); listener.close(); }

    GetOptions opts;
    opts.urlOverride = "http://127.0.0.1:" ~ port.to!string;
    auto req = ListObjectsV2Request("examplebucket", "us-east-1", Credentials.init);
    req.transport = opts;
    auto now = SysTime(DateTime(2015, 8, 30, 12, 36, 0), UTC());

    S3Object[] delivered;
    auto result = listObjectsV2(req, (S3Object obj) { delivered ~= obj; }, now);

    check(serverError is null, serverError is null ? "" : serverError.msg);
    check(capturedRequests.length == 2, "expected exactly 2 real HTTP requests, got " ~ capturedRequests.length.to!string);
    check(capturedRequests[0].startsWith("GET /?"), "first page request line mismatch:\n" ~ capturedRequests[0]);
    check(capturedRequests[0].canFind("list-type=2"), "first page missing list-type=2");
    check(!capturedRequests[0].canFind("continuation-token"), "first page should not send a continuation-token yet");
    check(capturedRequests[1].canFind("continuation-token=page-2-token"),
        "second page should carry the token the first page returned:\n" ~ capturedRequests[1]);

    check(result.ok, "listObjectsV2 should have completed successfully across both pages");
    check(result.objectCount == 3, "expected 3 objects delivered, got " ~ result.objectCount.to!string);
    check(delivered.length == 3, "sink should have been called exactly 3 times");
    check(delivered[0].key == "a.txt" && delivered[1].key == "b.txt" && delivered[2].key == "c.txt",
        "objects delivered out of order or wrong keys");

    writeln("   PASS: real 2-page ListObjectsV2 round trip, continuation token really drives page 2, "
        ~ "3 objects streamed to the caller across both pages");
}

void main() {
    writeln("s3lite PutObject/ListObjectsV2 loopback fixture (issue #367)");
    checkPutObjectRoundTrip();
    checkListObjectsV2Pagination();
    writeln("s3lite put/list loopback fixture: PASS");
}
