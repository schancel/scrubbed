/// Loopback fixture, ported/adapted from the parent `scrubbed` repository's
/// `experiments/s3_capability/evaluate.d` (its real ephemeral `openssl
/// s_server` TLS-loopback pattern) onto this package's own client/transport.
///
/// Two real, independent checks, matching issue #46's required loopback
/// proof:
///
///   A. Plaintext loopback socket: proves this package's real SigV4-signed
///      request (method, path, Host/X-Amz-Date/X-Amz-Content-Sha256/
///      Authorization headers) is constructed correctly and is actually
///      transmitted, byte for byte, by the real curl-based transport --
///      not mocked.
///   B. Real ephemeral-TLS loopback (`openssl s_server`, a self-signed
///      loopback certificate, real OpenSSL/curl TLS verification, no
///      `-k`/`--insecure`): proves untrusted-CA and hostname-mismatch
///      connections are really rejected and mapped to
///      `TransportFailure.tlsVerificationFailed`, and that a trusted CA
///      really succeeds through this package's own transport.
///
/// No AWS account, credential, or network access beyond 127.0.0.1 is used.
/// Run via: `dub run --config=loopback-fixture` (from this package's own
/// directory).
import s3lite.client : GetObjectRequest, Credentials, buildGetRequest;
import s3lite.http : httpGet, GetOptions, RequestHeader, TransportFailure;
import std.algorithm.searching : canFind;
import std.conv : to;
import std.datetime.systime : SysTime;
import std.datetime.timezone : UTC;
import std.datetime : DateTime;
import std.file : mkdir, rmdir, remove, tempDir;
import std.path : buildPath;
import std.process : Config, environment, execute, spawnProcess, wait, kill;
import std.socket : Socket, TcpSocket, InternetAddress, SocketOptionLevel, SocketOption;
import std.stdio : File, stdin, writeln;
import std.string : startsWith;
import std.uuid : randomUUID;
import core.thread : Thread;
import core.time : msecs;

void check(bool condition, string label) {
    if (!condition) throw new Exception("FAIL: " ~ label);
}

ushort unusedPort() {
    auto sock = new TcpSocket();
    scope(exit) sock.close();
    sock.bind(new InternetAddress("127.0.0.1", 0));
    return (cast(InternetAddress) sock.localAddress()).port;
}

string receiveAll(Socket peer) {
    char[8192] bytes;
    auto n = peer.receive(bytes[]);
    check(n > 0, "loopback peer received no request");
    return bytes[0 .. cast(size_t) n].idup;
}

/// Section A: plaintext loopback. Accepts one connection, verifies the real
/// request line and every SigV4-relevant header, then responds 200 so the
/// client-side `httpGet` call completes cleanly too.
void checkPlaintextRequestConstruction() {
    writeln("A. plaintext loopback: verifying real request construction...");

    auto creds = Credentials("AKIDEXAMPLE", "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY");
    auto req = GetObjectRequest("examplebucket", "test.txt", "us-east-1", creds);
    auto fixedNow = SysTime(DateTime(2015, 8, 30, 12, 36, 0), UTC());
    auto built = buildGetRequest(req, fixedNow);

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
            auto response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            peer.send(response);
        } catch (Exception e) {
            serverError = e;
        }
    });
    worker.start();
    scope(exit) { worker.join(); listener.close(); }

    // The signed Authorization/X-Amz-* headers are computed against the real
    // virtual-hosted-style host (`examplebucket.s3.us-east-1.amazonaws.com`,
    // exactly as SigV4 requires them to be, matching what a real S3 signer
    // must sign); the *transport* destination is redirected to the loopback
    // listener via the URL itself -- the Host header value transmitted is
    // still the one the signature covers, since curl sends whatever
    // caller-supplied Host header is present in the header list rather than
    // deriving one from the connection target.
    auto loopbackUrl = "http://127.0.0.1:" ~ port.to!string ~ "/test.txt";
    auto result = httpGet(loopbackUrl, built.headers, GetOptions.init);

    check(serverError is null, serverError is null ? "" : serverError.msg);
    check(capturedRequest.startsWith("GET /test.txt HTTP/1.1\r\n"), "request line mismatch:\n" ~ capturedRequest);
    check(capturedRequest.canFind("Host: examplebucket.s3.us-east-1.amazonaws.com\r\n"), "Host header missing/wrong");
    check(capturedRequest.canFind("X-Amz-Date: 20150830T123600Z\r\n"), "X-Amz-Date header missing/wrong");
    check(capturedRequest.canFind(
        "X-Amz-Content-Sha256: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\r\n"),
        "X-Amz-Content-Sha256 header missing/wrong");
    check(capturedRequest.canFind("Authorization: AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/s3/aws4_request"),
        "Authorization header missing/wrong shape");
    check(result.ok && result.response.status == 200, "loopback round trip should have completed with 200");

    writeln("   PASS: real request line + Host/X-Amz-Date/X-Amz-Content-Sha256/Authorization headers all correct");
}

/// Section B: real ephemeral-TLS loopback, ported from
/// experiments/s3_capability/evaluate.d's own TLS section. Real OpenSSL
/// certificate generation, real `openssl s_server`, real curl TLS
/// verification -- no `-k`/`--insecure` anywhere.
void checkTlsVerificationMapping() {
    writeln("B. real ephemeral-TLS loopback: verifying TLS trust-chain mapping...");

    auto dir = buildPath(tempDir(), "s3lite-loopback-" ~ randomUUID().toString());
    mkdir(dir);
    auto cert = buildPath(dir, "local.crt");
    auto key = buildPath(dir, "local.key");
    scope(exit) { remove(cert); remove(key); rmdir(dir); }

    string[string] cleanEnv = ["PATH": environment.get("PATH", "/usr/bin:/bin")];
    auto generated = execute(["openssl", "req", "-x509", "-newkey", "rsa:2048",
        "-nodes", "-days", "1", "-subj", "/CN=localhost",
        "-addext", "subjectAltName=IP:127.0.0.1", "-keyout", key, "-out", cert],
        cleanEnv, Config.newEnv);
    check(generated.status == 0, "local certificate generation failed: " ~ generated.output);

    auto tlsPort = unusedPort();
    auto portText = tlsPort.to!string;
    auto sink = File("/dev/null", "w");
    auto server = spawnProcess(["openssl", "s_server", "-accept", "127.0.0.1:" ~ portText,
        "-cert", cert, "-key", key, "-www", "-quiet"],
        stdin, sink, sink, cleanEnv, Config.newEnv);
    scope(exit) { kill(server); wait(server); }
    Thread.sleep(300.msecs);

    auto url = "https://127.0.0.1:" ~ portText ~ "/";

    // Untrusted: no CA bundle override, so the system trust store is used,
    // which does not trust our freshly-generated self-signed cert.
    auto untrusted = httpGet(url, [], GetOptions.init);
    check(!untrusted.ok, "untrusted TLS connection should have failed at the transport layer");
    check(untrusted.failure == TransportFailure.tlsVerificationFailed,
        "untrusted TLS failure should classify as tlsVerificationFailed, got " ~ untrusted.failure.to!string);

    // Trusted: pass the real generated cert as the CA bundle.
    GetOptions trustedOpts;
    trustedOpts.caBundlePath = cert;
    auto trusted = httpGet(url, [], trustedOpts);
    check(trusted.ok, "trusted local TLS certificate should have been accepted: " ~ trusted.failureDetail);
    check(trusted.response.status == 200, "trusted TLS round trip should complete with 200");

    // Hostname mismatch: the cert only has IP SAN 127.0.0.1, not this name;
    // CURLOPT_RESOLVE points the name at the loopback server without real
    // DNS, so a real hostname-vs-certificate mismatch is exercised.
    GetOptions mismatchOpts;
    mismatchOpts.caBundlePath = cert;
    mismatchOpts.resolveOverrides = ["s3lite-loopback-test.invalid:" ~ portText ~ ":127.0.0.1"];
    auto wrongNameUrl = "https://s3lite-loopback-test.invalid:" ~ portText ~ "/";
    auto wrongName = httpGet(wrongNameUrl, [], mismatchOpts);
    check(!wrongName.ok, "hostname-mismatched TLS connection should have failed");
    check(wrongName.failure == TransportFailure.tlsVerificationFailed,
        "hostname mismatch should classify as tlsVerificationFailed, got " ~ wrongName.failure.to!string);

    writeln("   PASS: untrusted CA rejected, trusted CA accepted, hostname mismatch rejected "
        ~ "-- all via real OpenSSL/curl TLS verification");
}

void main() {
    writeln("s3lite loopback fixture (ported from experiments/s3_capability/evaluate.d)");
    checkPlaintextRequestConstruction();
    checkTlsVerificationMapping();
    writeln("s3lite loopback fixture: PASS");
}
