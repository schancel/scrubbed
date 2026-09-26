// Release-active checker for issue #238's production fetch module
// (effects.http_fetch / effects.curl_ffi). Reuses the loopback-only fixture
// idiom (a local D HTTP server plus an ephemeral openssl-backed TLS fixture)
// that experiments/http_fetch/check.d already demonstrated, but exercises it
// against the PRODUCTION module instead of a standalone probe. That earlier
// probe file is untouched historical evidence; this is a new, separate path.
//
// Build (from the repository root, after `dub build` has produced
// .dub/lexbor/liblexbor_static.a):
//   ldc2 -O -release -preview=dip1000 -Isource \
//     experiments/http_fetch_seam/check.d source/effects/http_fetch.d \
//     source/effects/curl_ffi.d source/effects/web_url.d source/crypto/sha256.d \
//     source/crypto/sha256_arm64.d source/crypto/sha256_x86_64.d \
//     .dub/lexbor/liblexbor_static.a -L-lcurl -of=/tmp/http-fetch-seam-check
module http_fetch_seam_check;

import core.sys.posix.signal : SIG_IGN, SIGPIPE, signal;
import core.sys.posix.stdlib : mkdtemp;
import core.sys.posix.sys.stat : S_IRWXU, stat, stat_t;
import core.atomic : atomicOp;
import core.thread : Thread;
import core.time : MonoTime, msecs;
import std.algorithm : max;
import std.array : appender;
import std.conv : to;
import std.file : exists, mkdir, rmdirRecurse, tempDir;
import std.path : buildPath;
import std.process : Pid, execute, kill, spawnProcess, tryWait, wait;
import std.socket;
import std.stdio : File, stderr, stdout;
import std.string : fromStringz, indexOf, toStringz;

import effects.http_fetch;
import effects.web_url : WebUrl, resolveWebUrl;

enum pathCanary = "PATH_CANARY_238_seam_7d13";
enum headerCanary = "HEADER_CANARY_238_seam_92ac";
enum bodyCanary = "BODY_CANARY_238_seam_b641";
enum credentialCanary = "CREDENTIAL_CANARY_238_seam_e50f";

private final class CheckFailure : Exception {
    string code;
    this(string code) { super(code); this.code = code; }
}

private void must(bool condition, string code) {
    if (!condition) throw new CheckFailure(code);
}

private void pass(string label) { stdout.writeln("PASS ", label); }
private void measure(string text) { stdout.writeln("MEASURE ", text); }

string repeated(char value, size_t count) {
    auto result = new char[count];
    result[] = value;
    return cast(string) result;
}

// --- Loopback HTTP fixture server, adapted from the evaluation probe's idiom
// for exercising the production module instead of the probe's own bindings.

final class LocalServer {
    private Socket listener;
    private Thread acceptThread;
    private ushort boundPort;
    private Object statsLock;
    private Thread[] workers;
    private bool stopped;

    this() {
        statsLock = new Object;
        listener = new TcpSocket(AddressFamily.INET);
        listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
        listener.bind(new InternetAddress("127.0.0.1", 0));
        listener.listen(32);
        boundPort = (cast(InternetAddress) listener.localAddress).port;
        acceptThread = new Thread(&acceptLoop);
        acceptThread.isDaemon = true;
        acceptThread.start();
    }

    @property ushort port() const { return boundPort; }
    string url(string path) const { return "http://127.0.0.1:" ~ boundPort.to!string ~ path; }

    void stop() {
        synchronized(statsLock) { if (stopped) return; stopped = true; }
        try listener.close(); catch (Throwable) {}
        try acceptThread.join(false); catch (Throwable) {}
        Thread[] snapshot;
        synchronized(statsLock) snapshot = workers.dup;
        foreach (worker; snapshot) { try worker.join(false); catch (Throwable) {} }
    }

    private void acceptLoop() {
        for (;;) {
            Socket client;
            try client = listener.accept();
            catch (SocketException) return;
            startWorker(client);
        }
    }

    // `accepted` is a genuine per-call parameter, so the lambda's closure
    // cannot alias a stack slot shared with another iteration.
    private void startWorker(Socket accepted) {
        auto worker = new Thread({ serve(accepted); });
        worker.isDaemon = true;
        synchronized(statsLock) workers ~= worker;
        worker.start();
    }

    private static void sendAll(Socket socket, const(ubyte)[] bytes) {
        size_t sent;
        while (sent < bytes.length) {
            auto amount = socket.send(bytes[sent .. $]);
            if (amount <= 0) throw new Exception("loopback send failed");
            sent += amount;
        }
    }

    private static void sendText(Socket socket, string text) {
        sendAll(socket, cast(const(ubyte)[]) text);
    }

    private static void closeQuietly(Socket socket) {
        try socket.close(); catch (Exception) {}
    }

    private void serve(Socket client) {
        scope(exit) closeQuietly(client);
        ubyte[4096] storage;
        auto request = appender!string;
        try {
            while (request.data.indexOf("\r\n\r\n") < 0 && request.data.length < 16_384) {
                auto count = client.receive(storage[]);
                if (count <= 0) return;
                request.put(cast(char[]) storage[0 .. count]);
            }
            auto text = request.data;
            auto firstSpace = text.indexOf(' ');
            auto secondSpace = firstSpace < 0 ? -1 : text.indexOf(' ', firstSpace + 1);
            if (firstSpace < 0 || secondSpace < 0) return;
            auto path = text[firstSpace + 1 .. secondSpace];

            if (path == "/redirect") {
                sendText(client, "HTTP/1.1 302 Found\r\nLocation: /ok\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            } else if (path == "/loop") {
                sendText(client, "HTTP/1.1 302 Found\r\nLocation: /loop\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            } else if (path == "/file-redirect") {
                sendText(client, "HTTP/1.1 302 Found\r\nLocation: file:///private/tmp/" ~
                    pathCanary ~ "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            } else if (path == "/stall") {
                Thread.sleep(300.msecs);
            } else if (path == "/headers") {
                sendText(client, "HTTP/1.1 200 OK\r\nX-Fill: " ~ repeated('H', 2_048) ~
                    "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            } else if (path == "/encoded") {
                sendText(client, "HTTP/1.1 200 OK\r\nContent-Length: 4096\r\nConnection: close\r\n\r\n");
                foreach (_; 0 .. 16) {
                    sendText(client, repeated('E', 256));
                    Thread.sleep(5.msecs);
                }
            } else if (path == "/gzip") {
                immutable ubyte[] gzip = [
                    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
                    0xed, 0xc1, 0x01, 0x0d, 0x00, 0x00, 0x00, 0xc2, 0xa0, 0x6c,
                    0xef, 0x5f, 0xca, 0x1c, 0x6e, 0x40, 0x01, 0x00, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00, 0xef, 0x06, 0xcc, 0x3b, 0x25, 0x32,
                    0x00, 0x20, 0x00, 0x00
                ];
                sendText(client, "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: " ~
                    gzip.length.to!string ~ "\r\nConnection: close\r\n\r\n");
                sendAll(client, gzip);
            } else if (path == "/stream") {
                sendText(client, "HTTP/1.1 200 OK\r\nContent-Length: 8192\r\nConnection: close\r\n\r\n");
                foreach (_; 0 .. 32) {
                    sendText(client, repeated('C', 256));
                    Thread.sleep(10.msecs);
                }
            } else if (path == "/conditional") {
                if (text.indexOf("If-None-Match: \"fixture-v1\"") >= 0)
                    sendText(client, "HTTP/1.1 304 Not Modified\r\nETag: \"fixture-v1\"\r\nConnection: close\r\n\r\n");
                else
                    sendText(client, "HTTP/1.1 200 OK\r\nETag: \"fixture-v1\"\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello");
            } else if (path == "/diagnostic/" ~ pathCanary) {
                auto payload = bodyCanary;
                sendText(client, "HTTP/1.1 200 OK\r\nX-Diagnostic: " ~ headerCanary ~
                    "\r\nContent-Length: " ~ payload.length.to!string ~
                    "\r\nConnection: close\r\n\r\n" ~ payload);
            } else if (path == "/occupy") {
                Thread.sleep(400.msecs);
                sendText(client, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok");
            } else {
                sendText(client, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello");
            }
        } catch (Exception) {
            // Client-side aborts are expected for cap/cancellation/timeout cases.
        }
    }
}

// --- Ephemeral loopback TLS fixture, adapted from the evaluation probe.

string makePrivateTempDirectory(string parent) {
    auto buffer = (buildPath(parent, "scrubd-http-fetch-seam-XXXXXX") ~ "\0").dup;
    auto created = mkdtemp(buffer.ptr);
    must(created !is null, "E_PRIVATE_TEMP_CREATE");
    auto directory = created.fromStringz.idup;
    stat_t metadata;
    must(stat(directory.toStringz, &metadata) == 0, "E_PRIVATE_TEMP_STAT");
    must((metadata.st_mode & 0x1ff) == S_IRWXU, "E_PRIVATE_TEMP_MODE");
    return directory;
}

ushort unusedLoopbackPort() {
    auto socket = new TcpSocket(AddressFamily.INET);
    scope(exit) socket.close();
    socket.bind(new InternetAddress("127.0.0.1", 0));
    return (cast(InternetAddress) socket.localAddress).port;
}

struct TlsFixture {
    string directory;
    string certificate;
    ushort port;
    Pid server;
}

TlsFixture startTlsFixture() {
    auto openssl = execute(["openssl", "version"]);
    must(openssl.status == 0, "E_OPENSSL_VERSION");
    TlsFixture fixture;
    fixture.directory = makePrivateTempDirectory(tempDir());
    fixture.certificate = buildPath(fixture.directory, "loopback-cert.pem");
    auto privateKey = buildPath(fixture.directory, "loopback-key.pem");
    auto generated = execute(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
        "-days", "1", "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1",
        "-keyout", privateKey, "-out", fixture.certificate]);
    must(generated.status == 0, "E_TLS_FIXTURE");
    fixture.port = unusedLoopbackPort();
    auto sink = File("/dev/null", "w");
    fixture.server = spawnProcess(["openssl", "s_server", "-quiet", "-accept",
        "127.0.0.1:" ~ fixture.port.to!string, "-cert", fixture.certificate,
        "-key", privateKey, "-www"], File("/dev/null", "r"), sink, sink);
    Thread.sleep(250.msecs);
    return fixture;
}

void stopTlsFixture(ref TlsFixture fixture) {
    if (fixture.server !is null && fixture.server.processID >= 0) {
        try {
            auto state = tryWait(fixture.server);
            if (!state.terminated) { kill(fixture.server); wait(fixture.server); }
        } catch (Exception) {}
    }
    try { if (fixture.directory.length && fixture.directory.exists) rmdirRecurse(fixture.directory); }
    catch (Exception) {}
}

// --- Helpers over the production module.

WebUrl mustResolve(string url) {
    // An absolute reference resolved "against itself" simply parses that
    // absolute URL: the WHATWG algorithm ignores the base once the
    // reference is itself absolute.
    auto outcome = resolveWebUrl(url, url);
    must(outcome.isResolved, "E_URL_RESOLVE");
    return outcome.value;
}

FetchRequest baseRequest(WebUrl url) {
    FetchRequest request;
    request.url = url;
    request.limits.connectTimeoutMs = 500;
    request.limits.totalTimeoutMs = 2_000;
    return request;
}

// --- Capability checks against effects.http_fetch, mirroring the evaluation
// probe's demonstrated boundaries but calling fetchHttp() directly.

void checkBasicFetch(LocalServer server) {
    auto outcome = fetchHttp(baseRequest(mustResolve(server.url("/ok"))));
    must(outcome.succeeded, "E_BASIC_FETCH");
    must(outcome.evidence.status == 200, "E_BASIC_STATUS");
    must(outcome.evidence.bodyBytes == 5, "E_BASIC_BODY_BYTES");
    import crypto.sha256 : sha256Of;
    must(outcome.evidence.bodyDigest == sha256Of(cast(const(ubyte)[]) "hello"), "E_BASIC_DIGEST");
    pass("basic_fetch");
}

void checkRedirect(LocalServer server) {
    auto request = baseRequest(mustResolve(server.url("/redirect")));
    auto outcome = fetchHttp(request);
    must(outcome.succeeded, "E_REDIRECT_FETCH");
    must(outcome.evidence.status == 200, "E_REDIRECT_STATUS");
    must(outcome.evidence.finalUrl.canonical == server.url("/ok"), "E_REDIRECT_FINAL_URL");
    must(outcome.evidence.redirectChain.length == 0, "E_REDIRECT_CHAIN_EMPTY");
    pass("redirect_final_url");
}

void checkRedirectLoop(LocalServer server) {
    auto request = baseRequest(mustResolve(server.url("/loop")));
    request.limits.maxRedirects = 2;
    auto outcome = fetchHttp(request);
    must(!outcome.succeeded, "E_LOOP_SHOULD_FAIL");
    must(outcome.failure.reason == FetchFailureReason.tooManyRedirects, "E_LOOP_REASON");
    must(outcome.failure.category == FetchFailureCategory.permanent, "E_LOOP_CATEGORY");
    pass("redirect_loop_bounded");
}

void checkRedirectProtocolAllowlist(LocalServer server) {
    auto outcome = fetchHttp(baseRequest(mustResolve(server.url("/file-redirect"))));
    must(!outcome.succeeded, "E_FILE_REDIRECT_SHOULD_FAIL");
    must(outcome.failure.reason == FetchFailureReason.protocolNotAllowed, "E_FILE_REDIRECT_REASON");
    pass("redirect_protocol_allowlist");
}

void checkTotalTimeout(LocalServer server) {
    auto request = baseRequest(mustResolve(server.url("/stall")));
    request.limits.connectTimeoutMs = 60;
    request.limits.totalTimeoutMs = 60;
    auto started = MonoTime.currTime;
    auto outcome = fetchHttp(request);
    auto elapsedMs = (MonoTime.currTime - started).total!"msecs";
    must(!outcome.succeeded, "E_TOTAL_TIMEOUT_SHOULD_FAIL");
    must(outcome.failure.reason == FetchFailureReason.timedOut, "E_TOTAL_TIMEOUT_REASON");
    must(outcome.failure.category == FetchFailureCategory.retryable, "E_TOTAL_TIMEOUT_CATEGORY");
    must(elapsedMs < 1_000, "E_TOTAL_TIMEOUT_ELAPSED");
    measure("total_timeout_elapsed_ms=" ~ elapsedMs.to!string);
    pass("total_timeout");
}

void checkConnectTimeout(LocalServer server) {
    // The plain-HTTP loopback server never speaks TLS: an https:// request to
    // its port stalls exactly at the TLS handshake, isolating the connect
    // timeout from the total timeout (the same trick the evaluation probe
    // used to distinguish the two caps without a raw stalled-accept peer).
    FetchRequest request;
    request.url = mustResolve("https://127.0.0.1:" ~ server.port.to!string ~ "/");
    request.limits.connectTimeoutMs = 60;
    request.limits.totalTimeoutMs = 2_000;
    auto started = MonoTime.currTime;
    auto outcome = fetchHttp(request);
    auto elapsedMs = (MonoTime.currTime - started).total!"msecs";
    must(!outcome.succeeded, "E_CONNECT_TIMEOUT_SHOULD_FAIL");
    must(outcome.failure.reason == FetchFailureReason.timedOut, "E_CONNECT_TIMEOUT_REASON");
    must(elapsedMs < 500, "E_CONNECT_TIMEOUT_ELAPSED");
    measure("connect_timeout_elapsed_ms=" ~ elapsedMs.to!string);
    pass("connect_timeout_distinct_from_total");
}

void checkHeaderCap(LocalServer server) {
    auto request = baseRequest(mustResolve(server.url("/headers")));
    request.limits.maxHeaderBytes = 128;
    auto outcome = fetchHttp(request);
    must(!outcome.succeeded, "E_HEADER_CAP_SHOULD_FAIL");
    must(outcome.failure.reason == FetchFailureReason.headerCapExceeded, "E_HEADER_CAP_REASON");
    must(outcome.failure.category == FetchFailureCategory.permanent, "E_HEADER_CAP_CATEGORY");
    pass("header_cap_truncation");
}

void checkEncodedCap(LocalServer server) {
    auto request = baseRequest(mustResolve(server.url("/encoded")));
    request.limits.maxEncodedBytes = 512;
    auto outcome = fetchHttp(request);
    must(!outcome.succeeded, "E_ENCODED_CAP_SHOULD_FAIL");
    must(outcome.failure.reason == FetchFailureReason.encodedBodyCapExceeded, "E_ENCODED_CAP_REASON");
    pass("encoded_cap_truncation");
}

void checkDecodedCapCompressionBomb(LocalServer server) {
    auto request = baseRequest(mustResolve(server.url("/gzip")));
    request.limits.maxDecodedBytes = 1_024;
    auto outcome = fetchHttp(request);
    must(!outcome.succeeded, "E_DECODED_CAP_SHOULD_FAIL");
    must(outcome.failure.reason == FetchFailureReason.decodedBodyCapExceeded, "E_DECODED_CAP_REASON");
    pass("decoded_cap_compression_bomb");
}

void checkCancellation(LocalServer server) {
    shared int progressTicks;
    auto request = baseRequest(mustResolve(server.url("/stream")));
    request.shouldCancel = () nothrow {
        return atomicOp!"+="(progressTicks, 1) >= 1;
    };
    auto outcome = fetchHttp(request);
    must(!outcome.succeeded, "E_CANCEL_SHOULD_FAIL");
    must(outcome.failure.reason == FetchFailureReason.cancelled, "E_CANCEL_REASON");
    must(outcome.failure.category == FetchFailureCategory.permanent, "E_CANCEL_CATEGORY");
    pass("cancellation");
}

void checkConditionalRetrieval(LocalServer server) {
    auto initial = fetchHttp(baseRequest(mustResolve(server.url("/conditional"))));
    must(initial.succeeded, "E_CONDITIONAL_INITIAL_FAIL");
    must(initial.evidence.status == 200 && initial.evidence.etag == `"fixture-v1"`,
        "E_CONDITIONAL_INITIAL_ETAG");
    auto conditional = baseRequest(mustResolve(server.url("/conditional")));
    conditional.ifNoneMatch = initial.evidence.etag;
    auto outcome = fetchHttp(conditional);
    must(outcome.succeeded, "E_CONDITIONAL_304_FAIL");
    must(outcome.evidence.status == 304 && outcome.evidence.notModified &&
        outcome.evidence.bodyBytes == 0, "E_CONDITIONAL_304_SHAPE");
    pass("conditional_retrieval_etag");
}

void checkContentAddressedPersistence(LocalServer server, string shardRoot) {
    auto request = baseRequest(mustResolve(server.url("/ok")));
    request.shardRoot = shardRoot;
    auto outcome = fetchHttp(request);
    must(outcome.succeeded, "E_PERSIST_FETCH_FAIL");
    must(outcome.evidence.bodyStored, "E_PERSIST_NOT_STORED");
    must(outcome.evidence.shardPath.length && outcome.evidence.shardPath.exists,
        "E_PERSIST_MISSING_FILE");
    import std.digest : LetterCase, toHexString;
    auto expectedName = toHexString!(LetterCase.lower)(outcome.evidence.bodyDigest).idup;
    must(outcome.evidence.shardPath.indexOf(expectedName) >= 0, "E_PERSIST_NAME_MISMATCH");
    // A second fetch of identical bytes is idempotent: same digest, same path.
    auto again = fetchHttp(request);
    must(again.succeeded && again.evidence.shardPath == outcome.evidence.shardPath,
        "E_PERSIST_NOT_IDEMPOTENT");
    pass("content_addressed_persistence");
}

void checkFailureTaxonomy() {
    must(categoryOf(FetchFailureReason.timedOut) == FetchFailureCategory.retryable,
        "E_TAXONOMY_TIMEOUT");
    must(categoryOf(FetchFailureReason.concurrencyLimit) == FetchFailureCategory.retryable,
        "E_TAXONOMY_CONCURRENCY");
    must(categoryOf(FetchFailureReason.storageFailure) == FetchFailureCategory.retryable,
        "E_TAXONOMY_STORAGE");
    must(categoryOf(FetchFailureReason.tooManyRedirects) == FetchFailureCategory.permanent,
        "E_TAXONOMY_REDIRECTS");
    must(categoryOf(FetchFailureReason.protocolNotAllowed) == FetchFailureCategory.permanent,
        "E_TAXONOMY_PROTOCOL");
    must(categoryOf(FetchFailureReason.tlsVerificationFailed) == FetchFailureCategory.permanent,
        "E_TAXONOMY_TLS");
    must(categoryOf(FetchFailureReason.cancelled) == FetchFailureCategory.permanent,
        "E_TAXONOMY_CANCELLED");
    pass("retryable_vs_permanent_taxonomy");
}

void checkConcurrencyCap(LocalServer server) {
    enum cap = 3;
    enum attempts = cap + 2;
    shared int succeeded;
    shared int rejected;
    Thread[attempts] threads;
    foreach (i; 0 .. attempts) {
        threads[i] = new Thread({
            auto request = baseRequest(mustResolve(server.url("/occupy")));
            request.limits.maxConcurrentFetches = cap;
            request.limits.totalTimeoutMs = 3_000;
            auto outcome = fetchHttp(request);
            if (outcome.succeeded) atomicOp!"+="(succeeded, 1);
            else if (outcome.failure.reason == FetchFailureReason.concurrencyLimit)
                atomicOp!"+="(rejected, 1);
        });
        threads[i].start();
    }
    foreach (i; 0 .. attempts) threads[i].join();
    must(succeeded <= cap, "E_CONCURRENCY_CAP_EXCEEDED");
    must(succeeded + rejected == attempts, "E_CONCURRENCY_ACCOUNTING");
    must(rejected >= 1, "E_CONCURRENCY_NEVER_REJECTED");
    measure("concurrency_cap=" ~ cap.to!string ~ " succeeded=" ~ succeeded.to!string ~
        " rejected=" ~ rejected.to!string);
    pass("bounded_concurrency_enforced");
}

void checkTls() {
    auto fixture = startTlsFixture();
    scope(exit) stopTlsFixture(fixture);

    auto untrusted = fetchHttp(baseRequest(
        mustResolve("https://127.0.0.1:" ~ fixture.port.to!string ~ "/")));
    must(!untrusted.succeeded, "E_TLS_UNTRUSTED_SHOULD_FAIL");
    must(untrusted.failure.reason == FetchFailureReason.tlsVerificationFailed,
        "E_TLS_UNTRUSTED_REASON");
    must(untrusted.failure.category == FetchFailureCategory.permanent, "E_TLS_UNTRUSTED_CATEGORY");

    auto mismatch = baseRequest(mustResolve(
        "https://mismatch.invalid:" ~ fixture.port.to!string ~ "/"));
    mismatch.caFile = fixture.certificate;
    mismatch.resolveEntries = ["mismatch.invalid:" ~ fixture.port.to!string ~ ":127.0.0.1"];
    auto sanMismatch = fetchHttp(mismatch);
    must(!sanMismatch.succeeded, "E_TLS_SAN_MISMATCH_SHOULD_FAIL");
    must(sanMismatch.failure.reason == FetchFailureReason.tlsVerificationFailed,
        "E_TLS_SAN_MISMATCH_REASON");

    auto verified = baseRequest(mustResolve("https://127.0.0.1:" ~ fixture.port.to!string ~ "/"));
    verified.caFile = fixture.certificate;
    auto trusted = fetchHttp(verified);
    must(trusted.succeeded, "E_TLS_VERIFIED_SHOULD_SUCCEED");
    must(trusted.evidence.status == 200, "E_TLS_VERIFIED_STATUS");
    pass("tls_verified_by_default_no_insecure_path");
}

void checkRestartAfterFailure(LocalServer server) {
    auto failing = baseRequest(mustResolve(server.url("/loop")));
    failing.limits.maxRedirects = 1;
    auto failed = fetchHttp(failing);
    must(!failed.succeeded, "E_RESTART_PRECONDITION");
    auto recovered = fetchHttp(baseRequest(mustResolve(server.url("/ok"))));
    must(recovered.succeeded && recovered.evidence.status == 200, "E_RESTART_RECOVERY");
    pass("restart_after_failure");
}

void checkCredentialRejectedAtConstruction() {
    auto rawUrl = "http://user:" ~ credentialCanary ~ "@127.0.0.1:1/";
    auto outcome = resolveWebUrl(rawUrl, rawUrl);
    must(!outcome.isResolved, "E_CREDENTIAL_URL_SHOULD_BE_REJECTED");
    pass("embedded_credentials_rejected_at_url_construction");
}

void checkDiagnosticCanaries(LocalServer server) {
    auto request = baseRequest(mustResolve(server.url("/diagnostic/" ~ pathCanary)));
    request.limits.maxDecodedBytes = 1; // forces a real decodedBodyCapExceeded failure
    request.ifNoneMatch = credentialCanary; // a secret-shaped value that must never leak
    string caught;
    FetchOutcome outcome;
    try outcome = fetchHttp(request);
    catch (Exception failure) caught = failure.msg;
    must(caught is null, "E_DIAGNOSTIC_UNEXPECTED_EXCEPTION");
    must(!outcome.succeeded, "E_DIAGNOSTIC_SHOULD_FAIL");
    must(outcome.failure.reason == FetchFailureReason.decodedBodyCapExceeded,
        "E_DIAGNOSTIC_REASON");
    // FetchFailure carries only a fixed reason plus numeric codes: there is no
    // string field it could smuggle a header, URL, or body byte through.
    auto rendered = "reason=" ~ outcome.failure.reason.to!string ~
        " curlCode=" ~ outcome.failure.curlCode.to!string ~
        " httpStatus=" ~ outcome.failure.httpStatus.to!string;
    foreach (canary; [pathCanary, headerCanary, bodyCanary, credentialCanary])
        must(rendered.indexOf(canary) < 0, "E_DIAGNOSTIC_PRIVACY");
    pass("content_free_diagnostics");
}

void checkStorageFailureIsTyped(LocalServer server) {
    auto request = baseRequest(mustResolve(server.url("/ok")));
    request.shardRoot = "/private/tmp/scrubd-http-fetch-seam-missing-" ~ credentialCanary;
    auto outcome = fetchHttp(request);
    must(!outcome.succeeded, "E_STORAGE_FAILURE_SHOULD_FAIL");
    must(outcome.failure.reason == FetchFailureReason.storageFailure, "E_STORAGE_FAILURE_REASON");
    must(outcome.failure.category == FetchFailureCategory.retryable, "E_STORAGE_FAILURE_CATEGORY");
    pass("storage_failure_typed_and_content_free");
}

int runChecks() {
    signal(SIGPIPE, SIG_IGN);
    auto server = new LocalServer;
    scope(exit) server.stop();

    checkBasicFetch(server);
    checkRedirect(server);
    checkRedirectLoop(server);
    checkRedirectProtocolAllowlist(server);
    checkTotalTimeout(server);
    checkConnectTimeout(server);
    checkHeaderCap(server);
    checkEncodedCap(server);
    checkDecodedCapCompressionBomb(server);
    checkCancellation(server);
    checkConditionalRetrieval(server);
    checkFailureTaxonomy();
    checkConcurrencyCap(server);
    checkTls();
    checkRestartAfterFailure(server);
    checkCredentialRejectedAtConstruction();
    checkDiagnosticCanaries(server);
    checkStorageFailureIsTyped(server);

    auto shardRoot = makePrivateTempDirectory(tempDir());
    scope(exit) if (shardRoot.exists) rmdirRecurse(shardRoot);
    checkContentAddressedPersistence(server, shardRoot);

    stdout.writeln("PASS all 18 checks");
    return 0;
}

int main() {
    try {
        return runChecks();
    } catch (CheckFailure failure) {
        stderr.writefln("FAIL %s", failure.code);
        return 1;
    } catch (Exception failure) {
        stderr.writefln("FAIL E_INTERNAL %s", failure.msg);
        return 1;
    }
}
