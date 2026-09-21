// Isolated S01 contract probe. No AWS calls or production client implementation.
import std.algorithm.searching : canFind;
import std.conv : to;
import std.file : mkdir, rmdir, remove, tempDir;
import std.path : buildPath;
import std.process : Config, environment, execute, spawnProcess, wait, kill;
import std.socket : Socket, TcpSocket, InternetAddress, SocketOptionLevel, SocketOption;
import std.string : indexOf, startsWith;
import std.stdio : File, stdin, writeln;
import std.uuid : randomUUID;
import core.thread : Thread;
import core.time : msecs;

enum AuthSource { explicit, environment, profile, missing }
enum Addressing { path, virtualHost }
enum Capability { getObject, listObjectsV2, unsupported }
enum FakeResponse { ok, forbidden, notFound, serverError, malformed, missingSeparator }
enum Failure { none, missingCredentials, incompleteCredentials, unsupportedCapability,
               badAuth, tlsUntrusted, endpointFailure }

struct Credentials { string accessKey; string secretKey; }
struct AuthSelection { AuthSource source; Credentials value; }
struct Endpoint { string host; ushort port; string region; Addressing addressing; }

AuthSelection chooseAuth(Credentials explicitValue, Credentials environmentValue,
                         Credentials profileValue)
{
    if (explicitValue.accessKey.length || explicitValue.secretKey.length)
        return AuthSelection(AuthSource.explicit, explicitValue);
    if (environmentValue.accessKey.length || environmentValue.secretKey.length)
        return AuthSelection(AuthSource.environment, environmentValue);
    if (profileValue.accessKey.length || profileValue.secretKey.length)
        return AuthSelection(AuthSource.profile, profileValue);
    return AuthSelection(AuthSource.missing);
}

struct Route { string host; string path; string signingRegion; }
Route route(Endpoint endpoint, string bucket, string key)
{
    if (endpoint.addressing == Addressing.virtualHost)
        return Route(bucket ~ "." ~ endpoint.host, "/" ~ key, endpoint.region);
    return Route(endpoint.host, "/" ~ bucket ~ "/" ~ key, endpoint.region);
}

Failure authorize(Capability capability, AuthSelection auth)
{
    if (capability == Capability.unsupported) return Failure.unsupportedCapability;
    if (auth.source == AuthSource.missing) return Failure.missingCredentials;
    if (!auth.value.accessKey.length || !auth.value.secretKey.length)
        return Failure.incompleteCredentials;
    return Failure.none;
}

// Only fixed error labels cross the publication boundary. Never include URL,
// headers, environment, certificate diagnostics, or underlying exception text.
string publicFailure(Failure failure)
{
    final switch (failure) {
    case Failure.none: return "none";
    case Failure.missingCredentials: return "missing_credentials";
    case Failure.incompleteCredentials: return "incomplete_credentials";
    case Failure.unsupportedCapability: return "unsupported_capability";
    case Failure.badAuth: return "bad_auth";
    case Failure.tlsUntrusted: return "tls_untrusted";
    case Failure.endpointFailure: return "endpoint_failure";
    }
}

void check(bool condition, string label)
{
    if (!condition) throw new Exception(label);
}

string receiveRequest(Socket peer)
{
    char[4096] bytes;
    auto n = peer.receive(bytes[]);
    check(n > 0, "local endpoint received no request");
    return bytes[0 .. cast(size_t)n].idup;
}

void fakeEndpoint(Socket listener, string expectedPath, string expectedHost,
                  string expectedKey, FakeResponse result)
{
    auto peer = listener.accept();
    scope(exit) peer.close();
    auto request = receiveRequest(peer);
    check(request.startsWith("GET " ~ expectedPath ~ " HTTP/1.1\r\n"), "route mismatch");
    check(request.canFind("Host: " ~ expectedHost ~ "\r\n"), "host mismatch");
    check(request.canFind("X-Fake-Access: " ~ expectedKey ~ "\r\n"), "auth precedence mismatch");
    string status;
    final switch (result) {
    case FakeResponse.ok: status = "HTTP/1.1 200 OK"; break;
    case FakeResponse.forbidden: status = "HTTP/1.1 403 Forbidden"; break;
    case FakeResponse.notFound: status = "HTTP/1.1 404 Not Found"; break;
    case FakeResponse.serverError: status = "HTTP/1.1 500 Internal Server Error"; break;
    case FakeResponse.malformed: status = "HTTP/1.1 200bogus"; break;
    case FakeResponse.missingSeparator: status = "HTTP/1.1 200"; break;
    }
    auto response = status ~ "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    peer.send(response);
}

ushort unusedPort()
{
    auto sock = new TcpSocket();
    scope(exit) sock.close();
    sock.bind(new InternetAddress("127.0.0.1", 0));
    return (cast(InternetAddress)sock.localAddress()).port;
}

Failure probeLocal(Endpoint endpoint, AuthSelection auth, FakeResponse result)
{
    auto cap = authorize(Capability.getObject, auth);
    if (cap != Failure.none) return cap;
    auto r = route(endpoint, "bucket", "object");
    auto listener = new TcpSocket();
    listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
    listener.bind(new InternetAddress("127.0.0.1", endpoint.port));
    auto boundPort = (cast(InternetAddress)listener.localAddress()).port;
    listener.listen(1);
    auto worker = new Thread({ fakeEndpoint(listener, r.path, r.host,
                                         auth.value.accessKey, result); });
    worker.start();
    // A socket connection to the loopback fault server; fake header is NOT SigV4.
    auto client = new TcpSocket();
    scope(exit) { client.close(); worker.join(); listener.close(); }
    client.connect(new InternetAddress("127.0.0.1", boundPort));
    auto request = "GET " ~ r.path ~ " HTTP/1.1\r\nHost: " ~ r.host ~
        "\r\nX-Fake-Access: " ~ auth.value.accessKey ~
        "\r\nConnection: close\r\n\r\n";
    client.send(request);
    auto response = receiveRequest(client);
    auto endOfStatus = response.indexOf("\r\n");
    if (endOfStatus < 0) return Failure.endpointFailure;
    auto status = response[0 .. endOfStatus];
    if (!status.startsWith("HTTP/1.1 ") || status.length < 13 || status[12] != ' ')
        return Failure.endpointFailure;
    foreach (digit; status[9 .. 12])
        if (digit < '0' || digit > '9') return Failure.endpointFailure;
    if (status[9 .. 12] == "200") return Failure.none;
    if (status[9 .. 12] == "403") return Failure.badAuth;
    return Failure.endpointFailure;
}

void main()
{
    enum fakeExplicit = Credentials("EXPLICIT_FAKE", "EXPLICIT_SECRET_FAKE");
    enum fakeEnvironment = Credentials("ENV_FAKE", "ENV_SECRET_FAKE");
    enum fakeProfile = Credentials("PROFILE_FAKE", "PROFILE_SECRET_FAKE");
    auto auth = chooseAuth(fakeExplicit, fakeEnvironment, fakeProfile);
    check(auth.source == AuthSource.explicit, "explicit precedence");
    check(chooseAuth(Credentials.init, fakeEnvironment, fakeProfile).source ==
          AuthSource.environment, "environment precedence");
    check(chooseAuth(Credentials.init, Credentials.init, fakeProfile).source ==
          AuthSource.profile, "profile fallback");
    auto partial = chooseAuth(Credentials("PARTIAL_FAKE", ""), fakeEnvironment, fakeProfile);
    check(partial.source == AuthSource.explicit &&
          authorize(Capability.getObject, partial) == Failure.incompleteCredentials,
          "partial explicit credentials must fail closed");
    check(chooseAuth(Credentials.init, Credentials.init, Credentials.init).source ==
          AuthSource.missing, "missing auth");
    auto path = route(Endpoint("127.0.0.1", 1, "us-west-2", Addressing.path), "bucket", "object");
    check(path.path == "/bucket/object" && path.host == "127.0.0.1" &&
          path.signingRegion == "us-west-2", "path/region");
    auto virtualRoute = route(Endpoint("s3.us-west-2.amazonaws.com", 443,
        "us-west-2", Addressing.virtualHost), "bucket", "object");
    check(virtualRoute.host == "bucket.s3.us-west-2.amazonaws.com" &&
          virtualRoute.path == "/object", "virtual host proposal");
    check(authorize(Capability.unsupported, auth) == Failure.unsupportedCapability,
          "unsupported operation must fail closed");
    check(authorize(Capability.getObject, AuthSelection(AuthSource.missing)) ==
          Failure.missingCredentials, "missing credentials must fail closed");
    auto endpoint = Endpoint("127.0.0.1", 0, "us-west-2", Addressing.path);
    check(probeLocal(endpoint, auth, FakeResponse.ok) == Failure.none, "local success");
    check(probeLocal(endpoint, auth, FakeResponse.forbidden) == Failure.badAuth,
          "local 403 mapping");
    check(probeLocal(endpoint, auth, FakeResponse.notFound) == Failure.endpointFailure,
          "local 404 mapping");
    check(probeLocal(endpoint, auth, FakeResponse.serverError) == Failure.endpointFailure,
          "local 500 mapping");
    check(probeLocal(endpoint, auth, FakeResponse.malformed) == Failure.endpointFailure,
          "malformed status rejected");
    check(probeLocal(endpoint, auth, FakeResponse.missingSeparator) == Failure.endpointFailure,
          "status missing second separator rejected");
    // Real TLS stack, loopback-only certificate. No -k/--insecure option is used.
    auto dir = buildPath(tempDir(), "s3-capability-" ~ randomUUID().toString());
    mkdir(dir);
    auto cert = buildPath(dir, "local.crt");
    auto key = buildPath(dir, "local.key");
    scope(exit) { remove(cert); remove(key); rmdir(dir); }
    // Exclude inherited AWS credentials, proxy settings and CA overrides from
    // every subprocess. PATH is retained only to find the two local tools.
    string[string] cleanEnv = ["PATH": environment.get("PATH", "/usr/bin:/bin")];
    auto generated = execute(["openssl", "req", "-x509", "-newkey", "rsa:2048",
        "-nodes", "-days", "1", "-subj", "/CN=localhost",
        "-addext", "subjectAltName=IP:127.0.0.1", "-keyout", key, "-out", cert],
        cleanEnv, Config.newEnv);
    check(generated.status == 0, "local certificate generation");
    auto tlsPort = unusedPort();
    auto portText = to!string(tlsPort);
    auto sink = File("/dev/null", "w");
    auto server = spawnProcess(["openssl", "s_server", "-accept", "127.0.0.1:" ~ portText,
        "-cert", cert, "-key", key, "-www", "-quiet"],
        stdin, sink, sink, cleanEnv, Config.newEnv);
    scope(exit) { kill(server); wait(server); }
    Thread.sleep(250.msecs);
    auto sockets = execute(["lsof", "-nP", "-a", "-p", to!string(server.processID),
        "-iTCP:" ~ portText, "-sTCP:LISTEN"], cleanEnv, Config.newEnv);
    check(sockets.status == 0 &&
          sockets.output.canFind("127.0.0.1:" ~ portText ~ " (LISTEN)") &&
          !sockets.output.canFind("*:" ~ portText ~ " (LISTEN)") &&
          !sockets.output.canFind("0.0.0.0:" ~ portText ~ " (LISTEN)"),
          "TLS listener must bind loopback, never wildcard");
    auto url = "https://127.0.0.1:" ~ portText ~ "/";
    auto untrusted = execute(["curl", "--disable", "--noproxy", "*",
        "--silent", "--show-error", "--max-time", "3",
        "--output", "/dev/null", url], cleanEnv, Config.newEnv);
    check(untrusted.status == 60, "untrusted TLS failed for wrong reason");
    auto trusted = execute(["curl", "--disable", "--noproxy", "*",
        "--silent", "--show-error", "--max-time", "3",
        "--cacert", cert, "--output", "/dev/null", url], cleanEnv, Config.newEnv);
    check(trusted.status == 0, "trusted local TLS certificate was rejected");
    auto wrongName = execute(["curl", "--disable", "--noproxy", "*",
        "--silent", "--show-error", "--max-time", "3",
        "--resolve", "localhost:" ~ portText ~ ":127.0.0.1",
        "--cacert", cert, "--output", "/dev/null",
        "https://localhost:" ~ portText ~ "/"], cleanEnv, Config.newEnv);
    check(wrongName.status == 60, "TLS hostname mismatch failed for wrong reason");
    foreach (failure; [Failure.none, Failure.missingCredentials,
                       Failure.incompleteCredentials,
                       Failure.unsupportedCapability, Failure.badAuth,
                       Failure.tlsUntrusted, Failure.endpointFailure]) {
        auto label = publicFailure(failure);
        foreach (secret; [fakeExplicit.accessKey, fakeExplicit.secretKey,
                          fakeEnvironment.accessKey, fakeEnvironment.secretKey,
                          fakeProfile.accessKey, fakeProfile.secretKey])
            check(!label.canFind(secret), "secret leaked in public failure");
    }
    writeln("s3 capability D probe: auth/route/fault/TLS/redaction PASS");
}
