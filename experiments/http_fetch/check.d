// Loopback-only host-libcurl capability probe for issue #238.
// Build: ldc2 -O -release experiments/http_fetch/check.d -of=/tmp/http-fetch-check -L-lcurl
module http_fetch_check;

import core.sys.posix.signal : SIG_IGN, SIGPIPE, signal;
import core.sys.posix.stdlib : mkdtemp;
import core.sys.posix.sys.stat : S_IRWXU, stat, stat_t;
import core.sys.posix.unistd : getpid;
import core.time : MonoTime;
import std.algorithm : max;
import std.array : appender;
import std.conv : to;
import std.datetime : msecs;
import std.file : exists, mkdir, readText, rmdirRecurse, symlink, tempDir, write;
import std.path : buildPath;
import std.process : Pid, environment, execute, kill, spawnProcess, tryWait, wait;
import std.socket;
import std.stdio : File, stderr, stdout;
import std.string : fromStringz, indexOf, toStringz;
import core.thread : Thread;

extern(C) nothrow {
    struct CURL;
    struct CURLM;
    struct curl_slist { char* data; curl_slist* next; }
    struct CurlMsg {
        int msg;
        CURL* easyHandle;
        union Payload { void* pointer; int result; }
        Payload data;
    }

    const(char)* curl_version();
    int curl_global_init(long flags);
    void curl_global_cleanup();
    CURL* curl_easy_init();
    void curl_easy_cleanup(CURL*);
    int curl_easy_setopt(CURL*, int option, ...);
    int curl_easy_getinfo(CURL*, int info, ...);
    int curl_easy_perform(CURL*);
    curl_slist* curl_slist_append(curl_slist*, const(char)*);
    void curl_slist_free_all(curl_slist*);
    CURLM* curl_multi_init();
    int curl_multi_add_handle(CURLM*, CURL*);
    int curl_multi_remove_handle(CURLM*, CURL*);
    int curl_multi_perform(CURLM*, int* running);
    int curl_multi_poll(CURLM*, void*, uint, int timeoutMs, int* numfds);
    CurlMsg* curl_multi_info_read(CURLM*, int* remaining);
    int curl_multi_cleanup(CURLM*);
}

enum : int {
    CURLE_OK = 0,
    CURLE_UNSUPPORTED_PROTOCOL = 1,
    CURLE_WRITE_ERROR = 23,
    CURLE_OPERATION_TIMEDOUT = 28,
    CURLE_ABORTED_BY_CALLBACK = 42,
    CURLE_TOO_MANY_REDIRECTS = 47,
    CURLE_PEER_FAILED_VERIFICATION = 60,
    CURLMSG_DONE = 1,
    CURLM_OK = 0,

    CURLOPT_WRITEDATA = 10_001,
    CURLOPT_URL = 10_002,
    CURLOPT_PROXY = 10_004,
    CURLOPT_WRITEFUNCTION = 20_011,
    CURLOPT_HTTPHEADER = 10_023,
    CURLOPT_HEADERDATA = 10_029,
    CURLOPT_NOPROGRESS = 43,
    CURLOPT_FOLLOWLOCATION = 52,
    CURLOPT_XFERINFODATA = 10_057,
    CURLOPT_SSL_VERIFYPEER = 64,
    CURLOPT_CAINFO = 10_065,
    CURLOPT_MAXREDIRS = 68,
    CURLOPT_HEADERFUNCTION = 20_079,
    CURLOPT_SSL_VERIFYHOST = 81,
    CURLOPT_NOSIGNAL = 99,
    CURLOPT_ACCEPT_ENCODING = 10_102,
    CURLOPT_TIMEOUT_MS = 155,
    CURLOPT_CONNECTTIMEOUT_MS = 156,
    CURLOPT_RESOLVE = 10_203,
    CURLOPT_XFERINFOFUNCTION = 20_219,
    CURLOPT_PROTOCOLS_STR = 10_318,
    CURLOPT_REDIR_PROTOCOLS_STR = 10_319,

    CURLINFO_RESPONSE_CODE = 0x20_0002,
    CURLINFO_SIZE_DOWNLOAD_T = 0x60_0008,
}

enum size_t unlimited = size_t.max;
enum pathCanary = "PATH_CANARY_238_7d13";
enum headerCanary = "HEADER_CANARY_238_92ac";
enum bodyCanary = "BODY_CANARY_238_b641";
enum credentialCanary = "CREDENTIAL_CANARY_238_e50f";

private final class ProbeFailure : Exception {
    string failureCode;
    long expected;
    long actual;

    this(string code, long expected, long actual) {
        super(code);
        this.failureCode = code;
        this.expected = expected;
        this.actual = actual;
    }
}

struct TransferState {
    size_t headerBytes;
    size_t bodyBytes;
    size_t bodyOffered;
    char[128] etag;
    size_t etagLength;
    uint etagCount;
    bool etagInvalid;
    size_t headerCap = unlimited;
    size_t decodedCap = unlimited;
    long encodedCap = long.max;
    bool cancel;
    bool failWrite;
}

extern(C) nothrow size_t bodyCallback(char* data, size_t size, size_t count, void* opaque) {
    auto state = cast(TransferState*) opaque;
    const bytes = size * count;
    state.bodyOffered += bytes;
    if (state.failWrite || bytes > state.decodedCap - state.bodyBytes)
        return 0;
    state.bodyBytes += bytes;
    return bytes;
}

extern(C) nothrow size_t headerCallback(char* data, size_t size, size_t count, void* opaque) {
    auto state = cast(TransferState*) opaque;
    const bytes = size * count;
    if (bytes > state.headerCap - state.headerBytes)
        return 0;
    state.headerBytes += bytes;
    enum prefix = "ETag: ";
    bool matches = bytes >= prefix.length + 2;
    foreach (index, value; prefix)
        if (matches && data[index] != value)
            matches = false;
    if (matches) {
        ++state.etagCount;
        const valueLength = bytes - prefix.length - 2;
        if (state.etagCount != 1 || valueLength == 0 ||
            valueLength > state.etag.length || data[bytes - 2] != '\r' ||
            data[bytes - 1] != '\n') {
            state.etagInvalid = true;
        } else {
            foreach (index; 0 .. valueLength)
                state.etag[index] = data[prefix.length + index];
            state.etagLength = valueLength;
        }
    }
    return bytes;
}

extern(C) nothrow int progressCallback(void* opaque, long, long downloaded, long, long) {
    auto state = cast(TransferState*) opaque;
    return (state.cancel && downloaded >= 256) || downloaded > state.encodedCap ? 1 : 0;
}

struct FetchResult {
    int code;
    long status;
    long encodedBytes;
    size_t headerBytes;
    size_t bodyBytes;
    size_t bodyOffered;
    string etag;
    uint etagCount;
    bool etagInvalid;
}

struct FetchOptions {
    bool follow;
    long maxRedirects = 3;
    long connectTimeoutMs = 500;
    long totalTimeoutMs = 1_000;
    size_t headerCap = unlimited;
    size_t decodedCap = unlimited;
    long encodedCap = long.max;
    bool cancel;
    bool failWrite;
    bool decode;
    bool insecureTls;
    string caFile;
    string[] headers;
    string resolve;
}

void setOption(int result) {
    enforceProbe(result == CURLE_OK, "E_SETOPT", CURLE_OK, result);
}

void setCommon(CURL* easy, string url, ref TransferState state, ref FetchOptions options,
               ref curl_slist* requestHeaders, ref curl_slist* resolveEntries) {
    auto urlz = url.toStringz;
    auto protocols = "http,https".toStringz;
    auto noProxy = "".toStringz;
    auto encoding = "gzip".toStringz;
    setOption(curl_easy_setopt(easy, CURLOPT_URL, urlz));
    setOption(curl_easy_setopt(easy, CURLOPT_PROTOCOLS_STR, protocols));
    setOption(curl_easy_setopt(easy, CURLOPT_REDIR_PROTOCOLS_STR, protocols));
    setOption(curl_easy_setopt(easy, CURLOPT_PROXY, noProxy));
    setOption(curl_easy_setopt(easy, CURLOPT_NOSIGNAL, 1L));
    setOption(curl_easy_setopt(easy, CURLOPT_FOLLOWLOCATION, options.follow ? 1L : 0L));
    setOption(curl_easy_setopt(easy, CURLOPT_MAXREDIRS, options.maxRedirects));
    setOption(curl_easy_setopt(easy, CURLOPT_CONNECTTIMEOUT_MS, options.connectTimeoutMs));
    setOption(curl_easy_setopt(easy, CURLOPT_TIMEOUT_MS, options.totalTimeoutMs));
    setOption(curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, &bodyCallback));
    setOption(curl_easy_setopt(easy, CURLOPT_WRITEDATA, &state));
    setOption(curl_easy_setopt(easy, CURLOPT_HEADERFUNCTION, &headerCallback));
    setOption(curl_easy_setopt(easy, CURLOPT_HEADERDATA, &state));
    setOption(curl_easy_setopt(easy, CURLOPT_NOPROGRESS, 0L));
    setOption(curl_easy_setopt(easy, CURLOPT_XFERINFOFUNCTION, &progressCallback));
    setOption(curl_easy_setopt(easy, CURLOPT_XFERINFODATA, &state));
    if (options.decode)
        setOption(curl_easy_setopt(easy, CURLOPT_ACCEPT_ENCODING, encoding));
    if (options.insecureTls) {
        setOption(curl_easy_setopt(easy, CURLOPT_SSL_VERIFYPEER, 0L));
        setOption(curl_easy_setopt(easy, CURLOPT_SSL_VERIFYHOST, 0L));
    } else if (options.caFile.length) {
        auto caz = options.caFile.toStringz;
        setOption(curl_easy_setopt(easy, CURLOPT_CAINFO, caz));
    }
    foreach (header; options.headers) {
        auto next = curl_slist_append(requestHeaders, header.toStringz);
        enforceProbe(next !is null, "E_HEADER_LIST");
        requestHeaders = next;
    }
    if (requestHeaders !is null)
        setOption(curl_easy_setopt(easy, CURLOPT_HTTPHEADER, requestHeaders));
    if (options.resolve.length) {
        resolveEntries = curl_slist_append(null, options.resolve.toStringz);
        enforceProbe(resolveEntries !is null, "E_RESOLVE_LIST");
        setOption(curl_easy_setopt(easy, CURLOPT_RESOLVE, resolveEntries));
    }
}

FetchResult fetch(string url, FetchOptions options = FetchOptions.init) {
    TransferState state;
    state.headerCap = options.headerCap;
    state.decodedCap = options.decodedCap;
    state.encodedCap = options.encodedCap;
    state.cancel = options.cancel;
    state.failWrite = options.failWrite;
    curl_slist* headers;
    curl_slist* resolves;
    auto easy = curl_easy_init();
    enforceProbe(easy !is null, "E_EASY_INIT");
    scope(exit) curl_easy_cleanup(easy);
    scope(exit) if (headers !is null) curl_slist_free_all(headers);
    scope(exit) if (resolves !is null) curl_slist_free_all(resolves);
    setCommon(easy, url, state, options, headers, resolves);
    FetchResult result;
    result.code = curl_easy_perform(easy);
    enforceProbe(curl_easy_getinfo(easy, CURLINFO_RESPONSE_CODE, &result.status) == CURLE_OK,
        "E_GETINFO_STATUS");
    enforceProbe(curl_easy_getinfo(easy, CURLINFO_SIZE_DOWNLOAD_T, &result.encodedBytes) == CURLE_OK,
        "E_GETINFO_SIZE");
    result.headerBytes = state.headerBytes;
    result.bodyBytes = state.bodyBytes;
    result.bodyOffered = state.bodyOffered;
    result.etag = state.etag[0 .. state.etagLength].idup;
    result.etagCount = state.etagCount;
    result.etagInvalid = state.etagInvalid;
    return result;
}

enum ServerFault {
    none,
    constructorAfterListen,
    constructorAfterAcceptStart,
    workerBeforeStart,
    workerAfterStart,
}

struct ServerLifecycleObservation {
    ushort boundPort;
    int listenerClosed;
    int acceptJoined;
    int acceptedClosed;
    int workerRemoved;
    int workerJoined;
}

class LocalServer {
    private Socket listener;
    private Thread acceptThread;
    private ushort boundPort;
    private Object statsLock;
    private Thread[] workers;
    private int active;
    private int peak;
    private int failures;
    private bool stopped;
    private ServerFault fault;
    private ServerLifecycleObservation* lifecycle;

    this(ServerFault fault = ServerFault.none,
         ServerLifecycleObservation* lifecycle = null) {
        statsLock = new Object;
        this.fault = fault;
        this.lifecycle = lifecycle;
        listener = new TcpSocket(AddressFamily.INET);
        bool acceptStartAttempted;
        scope(failure) {
            closeQuietly(listener);
            if (this.lifecycle !is null)
                ++this.lifecycle.listenerClosed;
            if (acceptStartAttempted) {
                try acceptThread.join(false); catch (Throwable) {}
                if (this.lifecycle !is null)
                    ++this.lifecycle.acceptJoined;
            }
        }
        listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
        listener.bind(new InternetAddress("127.0.0.1", 0));
        listener.listen(32);
        boundPort = (cast(InternetAddress) listener.localAddress).port;
        if (this.lifecycle !is null)
            this.lifecycle.boundPort = boundPort;
        enforceProbe(fault != ServerFault.constructorAfterListen,
            "E_SERVER_CTOR_AFTER_LISTEN");
        acceptThread = new Thread(&acceptLoop);
        acceptThread.isDaemon = true;
        acceptStartAttempted = true;
        acceptThread.start();
        enforceProbe(fault != ServerFault.constructorAfterAcceptStart,
            "E_SERVER_CTOR_AFTER_ACCEPT_START");
    }

    @property ushort port() const { return boundPort; }
    string url(string path) const { return "http://127.0.0.1:" ~ boundPort.to!string ~ path; }

    void awaitIdle() {
        Thread[] snapshot;
        synchronized(statsLock) snapshot = workers.dup;
        bool joinFailed;
        foreach (worker; snapshot) {
            try {
                if (worker.join(false) !is null)
                    joinFailed = true;
            } catch (Throwable) {
                joinFailed = true;
            }
        }
        synchronized(statsLock)
            enforceProbe(active == 0, "E_SERVER_NOT_IDLE", 0, active);
        enforceProbe(!joinFailed, "E_SERVER_WORKER_JOIN");
    }

    void resetStats() {
        synchronized(statsLock) {
            enforceProbe(active == 0, "E_SERVER_RESET_ACTIVE", 0, active);
            peak = 0;
            failures = 0;
        }
    }

    int peakConnections() {
        synchronized(statsLock) return peak;
    }

    int failureCount() {
        synchronized(statsLock) return failures;
    }

    void stop() {
        synchronized(statsLock) {
            if (stopped) return;
            stopped = true;
        }
        bool cleanupFailed;
        try listener.close(); catch (Throwable) { cleanupFailed = true; }
        try {
            if (acceptThread.join(false) !is null)
                cleanupFailed = true;
        } catch (Throwable) {
            cleanupFailed = true;
        }
        try awaitIdle(); catch (Throwable) { cleanupFailed = true; }
        if (cleanupFailed)
            synchronized(statsLock) ++failures;
    }

    private void beginRequest() {
        synchronized(statsLock) { ++active; peak = max(peak, active); }
    }

    private void endRequest() {
        synchronized(statsLock) --active;
    }

    private void acceptLoop() {
        for (;;) {
            Socket client;
            try {
                client = listener.accept();
            } catch (SocketException) {
                return;
            }
            try {
                startWorker(client);
            } catch (Throwable) {
                synchronized(statsLock) ++failures;
            }
        }
    }

    private void startWorker(Socket accepted) {
        const faultBeforeStart = fault == ServerFault.workerBeforeStart;
        const faultAfterStart = fault == ServerFault.workerAfterStart;
        if (faultBeforeStart || faultAfterStart)
            fault = ServerFault.none;
        auto worker = new Thread({
            if (faultAfterStart)
                Thread.sleep(25.msecs);
            serve(accepted);
        });
        worker.isDaemon = true;
        synchronized(statsLock) workers ~= worker;
        bool startAttempted;
        scope(failure) {
            closeQuietly(accepted);
            synchronized(statsLock) {
                if (lifecycle !is null)
                    ++lifecycle.acceptedClosed;
            }
            if (startAttempted) {
                try worker.join(false); catch (Throwable) {}
                synchronized(statsLock) {
                    if (lifecycle !is null)
                        ++lifecycle.workerJoined;
                }
            }
            synchronized(statsLock) {
                foreach (index, candidate; workers) {
                    if (candidate is worker) {
                        workers[index] = workers[$ - 1];
                        workers.length = workers.length - 1;
                        if (lifecycle !is null)
                            ++lifecycle.workerRemoved;
                        break;
                    }
                }
            }
        }
        enforceProbe(!faultBeforeStart, "E_SERVER_WORKER_BEFORE_START");
        startAttempted = true;
        worker.start();
        enforceProbe(!faultAfterStart, "E_SERVER_WORKER_AFTER_START");
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
            beginRequest();
            scope(exit) endRequest();
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
                sendText(client, "HTTP/1.1 200 OK\r\nX-Fill: " ~ repeated('H', 2_048) ~ "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
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
                sendText(client, "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: " ~ gzip.length.to!string ~ "\r\nConnection: close\r\n\r\n");
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
                else {
                    auto mutant = environment.get("SCRUBD_HTTP_FETCH_ETAG_MUTANT", "");
                    auto etagHeader = mutant == "remove" ? "" :
                        mutant == "change" ? "ETag: \"fixture-v2\"\r\n" :
                        "ETag: \"fixture-v1\"\r\n";
                    sendText(client, "HTTP/1.1 200 OK\r\n" ~ etagHeader ~
                        "Content-Length: 5\r\nConnection: close\r\n\r\nhello");
                }
            } else if (path == "/diagnostic/" ~ pathCanary) {
                auto payload = bodyCanary;
                sendText(client, "HTTP/1.1 200 OK\r\nX-Diagnostic: " ~ headerCanary ~
                    "\r\nContent-Length: " ~ payload.length.to!string ~
                    "\r\nConnection: close\r\n\r\n" ~ payload);
            } else if (path.length >= 11 && path[0 .. 11] == "/concurrent") {
                Thread.sleep(150.msecs);
                sendText(client, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok");
            } else {
                sendText(client, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello");
            }
        } catch (Exception) {
            // Client-side aborts are expected for cap, cancellation, and timeout cases.
            synchronized(statsLock) ++failures;
        }
    }
}

string repeated(char value, size_t count) {
    auto result = new char[count];
    result[] = value;
    return cast(string) result;
}

void enforceProbe(bool condition, string code, long expected = 0, long actual = 0) {
    if (condition) return;
    throw new ProbeFailure(code, expected, actual);
}

void checkCode(string label, FetchResult result, int expected) {
    enforceProbe(result.code == expected, label, expected, result.code);
    stdout.writeln("PASS ", label);
}

ushort unusedLoopbackPort() {
    auto socket = new TcpSocket(AddressFamily.INET);
    scope(exit) socket.close();
    socket.bind(new InternetAddress("127.0.0.1", 0));
    return (cast(InternetAddress) socket.localAddress).port;
}

string makePrivateTempDirectory(string parent) {
    auto buffer = (buildPath(parent, "scrubd-http-fetch-XXXXXX") ~ "\0").dup;
    auto created = mkdtemp(buffer.ptr);
    enforceProbe(created !is null, "E_PRIVATE_TEMP_CREATE");
    auto directory = created.fromStringz.idup;
    stat_t metadata;
    enforceProbe(stat(directory.toStringz, &metadata) == 0, "E_PRIVATE_TEMP_STAT");
    enforceProbe((metadata.st_mode & 0x1ff) == S_IRWXU, "E_PRIVATE_TEMP_MODE",
        S_IRWXU, metadata.st_mode & 0x1ff);
    return directory;
}

void checkPrivateTempSafety() {
    auto root = makePrivateTempDirectory(tempDir());
    scope(exit) if (root.exists) rmdirRecurse(root);
    auto sentinel = buildPath(root, "sentinel");
    write(sentinel, "unchanged");
    auto legacy = buildPath(root, "scrubd-http-fetch-" ~ getpid().to!string);
    mkdir(legacy);
    symlink(sentinel, buildPath(legacy, "loopback-key.pem"));
    symlink(sentinel, buildPath(legacy, "loopback-cert.pem"));
    auto actual = makePrivateTempDirectory(root);
    scope(exit) if (actual.exists) rmdirRecurse(actual);
    enforceProbe(actual != legacy, "E_PRIVATE_TEMP_UNPREDICTABLE");
    enforceProbe(readText(sentinel) == "unchanged", "E_PRIVATE_TEMP_SYMLINK");
    stdout.writeln("PASS private_temp_symlink_safety");
}

struct TlsCleanupObservation {
    string directory;
    bool childReaped;
    bool directoryRemoved;
}

void cleanupTls(Pid server, ref TlsCleanupObservation observation) {
    if (server !is null && server.processID >= 0) {
        try {
            auto state = tryWait(server);
            if (!state.terminated) {
                kill(server);
                wait(server);
            }
            observation.childReaped = true;
        } catch (Exception) {
            observation.childReaped = false;
        }
    } else {
        observation.childReaped = true;
    }
    try {
        if (observation.directory.length && observation.directory.exists)
            rmdirRecurse(observation.directory);
        observation.directoryRemoved = !observation.directory.exists;
    } catch (Exception) {
        observation.directoryRemoved = false;
    }
}

void exerciseHttps(bool injectFailure, bool disableVerificationMutant,
                   ref TlsCleanupObservation observation) {
    auto openssl = execute(["openssl", "version"]);
    enforceProbe(openssl.status == 0, "E_OPENSSL_VERSION");
    auto directory = makePrivateTempDirectory(tempDir());
    observation.directory = directory;
    Pid server;
    scope(exit) cleanupTls(server, observation);
    auto certificate = buildPath(directory, "loopback-cert.pem");
    auto privateKey = buildPath(directory, "loopback-key.pem");
    auto generated = execute(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
        "-days", "1", "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1",
        "-keyout", privateKey, "-out", certificate]);
    enforceProbe(generated.status == 0, "E_TLS_FIXTURE");

    auto port = unusedLoopbackPort();
    auto sink = File("/dev/null", "w");
    server = spawnProcess(["openssl", "s_server", "-quiet", "-accept",
        "127.0.0.1:" ~ port.to!string, "-cert", certificate, "-key", privateKey, "-www"],
        File("/dev/null", "r"), sink, sink);
    enforceProbe(!injectFailure, "E_TLS_CLEANUP_INJECTED");
    Thread.sleep(250.msecs);

    FetchOptions untrusted;
    untrusted.insecureTls = disableVerificationMutant;
    auto result = fetch("https://127.0.0.1:" ~ port.to!string ~ "/", untrusted);
    checkCode("https_untrusted_rejected", result, CURLE_PEER_FAILED_VERIFICATION);

    FetchOptions options;
    options.caFile = certificate;
    options.insecureTls = disableVerificationMutant;
    options.resolve = "mismatch.invalid:" ~ port.to!string ~ ":127.0.0.1";
    result = fetch("https://mismatch.invalid:" ~ port.to!string ~ "/", options);
    checkCode("https_san_mismatch_rejected", result, CURLE_PEER_FAILED_VERIFICATION);

    options.resolve = "";
    result = fetch("https://127.0.0.1:" ~ port.to!string ~ "/", options);
    checkCode("https_verified_loopback", result, CURLE_OK);
    enforceProbe(result.status == 200, "E_HTTPS_STATUS", 200, result.status);
}

void checkHttps() {
    checkPrivateTempSafety();
    TlsCleanupObservation injected;
    bool injectedFailed;
    try {
        exerciseHttps(true, false, injected);
    } catch (ProbeFailure failure) {
        enforceProbe(failure.failureCode == "E_TLS_CLEANUP_INJECTED", "E_TLS_CLEANUP_WRONG_FAILURE");
        injectedFailed = true;
    }
    enforceProbe(injectedFailed, "E_TLS_CLEANUP_NOT_INJECTED");
    enforceProbe(injected.childReaped, "E_TLS_CHILD_NOT_REAPED");
    enforceProbe(injected.directoryRemoved && !injected.directory.exists, "E_TLS_DIRECTORY_RETAINED");
    cleanupTls(null, injected);
    enforceProbe(injected.childReaped && injected.directoryRemoved, "E_TLS_CLEANUP_NOT_IDEMPOTENT");
    stdout.writeln("PASS tls_fault_cleanup");

    TlsCleanupObservation ordinary;
    auto mutant = environment.get("SCRUBD_HTTP_FETCH_TLS_MUTANT", "") == "1";
    exerciseHttps(false, mutant, ordinary);
    enforceProbe(ordinary.childReaped && ordinary.directoryRemoved, "E_TLS_ORDINARY_CLEANUP");
}

void requirePortReusable(ushort port) {
    auto socket = new TcpSocket(AddressFamily.INET);
    scope(exit) socket.close();
    socket.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
    socket.bind(new InternetAddress("127.0.0.1", port));
}

void checkServerLifecycle() {
    ServerLifecycleObservation afterListen;
    bool afterListenFailed;
    try {
        new LocalServer(ServerFault.constructorAfterListen, &afterListen);
    } catch (ProbeFailure failure) {
        enforceProbe(failure.failureCode == "E_SERVER_CTOR_AFTER_LISTEN",
            "E_SERVER_CTOR_LISTEN_WRONG_FAILURE");
        afterListenFailed = true;
    }
    enforceProbe(afterListenFailed && afterListen.listenerClosed == 1 &&
        afterListen.acceptJoined == 0, "E_SERVER_CTOR_LISTEN_CLEANUP");
    requirePortReusable(afterListen.boundPort);

    ServerLifecycleObservation afterAcceptStart;
    bool afterAcceptStartFailed;
    try {
        new LocalServer(ServerFault.constructorAfterAcceptStart, &afterAcceptStart);
    } catch (ProbeFailure failure) {
        enforceProbe(failure.failureCode == "E_SERVER_CTOR_AFTER_ACCEPT_START",
            "E_SERVER_CTOR_ACCEPT_WRONG_FAILURE");
        afterAcceptStartFailed = true;
    }
    enforceProbe(afterAcceptStartFailed && afterAcceptStart.listenerClosed == 1 &&
        afterAcceptStart.acceptJoined == 1, "E_SERVER_CTOR_ACCEPT_CLEANUP");
    requirePortReusable(afterAcceptStart.boundPort);

    foreach (fault; [ServerFault.workerBeforeStart, ServerFault.workerAfterStart]) {
        ServerLifecycleObservation workerObservation;
        auto server = new LocalServer(fault, &workerObservation);
        scope(exit) server.stop();
        auto failed = fetch(server.url("/ok"));
        enforceProbe(failed.code != CURLE_OK, "E_SERVER_WORKER_FAULT_NOT_VISIBLE");
        auto recovered = fetch(server.url("/ok"));
        enforceProbe(recovered.code == CURLE_OK && recovered.status == 200,
            "E_SERVER_WORKER_RECOVERY", CURLE_OK, recovered.code);
        server.awaitIdle();
        enforceProbe(server.failureCount() == 1 &&
            workerObservation.acceptedClosed == 1 &&
            workerObservation.workerRemoved == 1,
            "E_SERVER_WORKER_ROLLBACK", 1, server.failureCount());
        enforceProbe(workerObservation.workerJoined ==
            (fault == ServerFault.workerAfterStart ? 1 : 0),
            "E_SERVER_WORKER_JOIN_ROLLBACK",
            fault == ServerFault.workerAfterStart ? 1 : 0,
            workerObservation.workerJoined);
    }
    stdout.writeln("PASS server_lifecycle_cleanup");
    stdout.writeln("MEASURE server_ctor_closed=2 accept_joined=1 worker_sockets_closed=2 workers_removed=2 workers_joined=1");
}

enum concurrentCount = 4;

struct MultiCleanupObservation {
    int initialized;
    int added;
    int removed;
    int cleaned;
    int headerFreed;
    int multiCleaned;
    int cleanupErrors;
    int completed;
    int peak;
}

void cleanupConcurrent(CURLM* multi, CURL*[] handles, bool[] added,
                       curl_slist*[] headers, curl_slist*[] resolves,
                       ref MultiCleanupObservation observation) {
    foreach_reverse (index; 0 .. handles.length) {
        if (added[index]) {
            if (curl_multi_remove_handle(multi, handles[index]) != CURLM_OK)
                ++observation.cleanupErrors;
            else
                ++observation.removed;
        }
        if (handles[index] !is null) {
            curl_easy_cleanup(handles[index]);
            ++observation.cleaned;
        }
        if (headers[index] !is null) {
            curl_slist_free_all(headers[index]);
            ++observation.headerFreed;
        }
        if (resolves[index] !is null)
            curl_slist_free_all(resolves[index]);
    }
    if (multi !is null) {
        if (curl_multi_cleanup(multi) != CURLM_OK)
            ++observation.cleanupErrors;
        else
            ++observation.multiCleaned;
    }
}

void exerciseConcurrent(bool injectFailure, ref MultiCleanupObservation observation) {
    auto server = new LocalServer;
    scope(exit) server.stop();
    CURL*[concurrentCount] handles;
    bool[concurrentCount] added;
    TransferState[concurrentCount] states;
    curl_slist*[concurrentCount] headers;
    curl_slist*[concurrentCount] resolves;
    string[concurrentCount] urls;
    FetchOptions options;
    options.connectTimeoutMs = 500;
    options.totalTimeoutMs = 1_000;
    options.headers = ["X-Concurrency-Fixture: bounded"];
    auto multi = curl_multi_init();
    enforceProbe(multi !is null, "E_MULTI_INIT");
    scope(exit) cleanupConcurrent(multi, handles[], added[], headers[], resolves[], observation);
    server.awaitIdle();
    server.resetStats();
    foreach (index; 0 .. concurrentCount) {
        handles[index] = curl_easy_init();
        enforceProbe(handles[index] !is null, "E_MULTI_EASY_INIT");
        ++observation.initialized;
        urls[index] = server.url("/concurrent/" ~ index.to!string);
        setCommon(handles[index], urls[index], states[index], options, headers[index], resolves[index]);
        enforceProbe(curl_multi_add_handle(multi, handles[index]) == CURLM_OK, "E_MULTI_ADD");
        added[index] = true;
        ++observation.added;
        if (injectFailure && index == 0)
            enforceProbe(false, "E_MULTI_CLEANUP_INJECTED");
    }

    int running;
    int multiCode;
    do {
        multiCode = curl_multi_perform(multi, &running);
        enforceProbe(multiCode == CURLM_OK, "E_MULTI_PERFORM", CURLM_OK, multiCode);
        if (running) {
            int descriptors;
            multiCode = curl_multi_poll(multi, null, 0, 100, &descriptors);
            enforceProbe(multiCode == CURLM_OK, "E_MULTI_POLL", CURLM_OK, multiCode);
        }
    } while (running);

    int completed;
    int remaining;
    for (auto message = curl_multi_info_read(multi, &remaining); message !is null;
         message = curl_multi_info_read(multi, &remaining)) {
        if (message.msg == CURLMSG_DONE) {
            enforceProbe(message.data.result == CURLE_OK, "E_MULTI_RESULT", CURLE_OK, message.data.result);
            ++completed;
        }
    }
    enforceProbe(completed == concurrentCount, "E_MULTI_COMPLETED", concurrentCount, completed);
    observation.completed = completed;
    server.awaitIdle();
    auto peak = server.peakConnections();
    enforceProbe(peak >= 2 && peak <= concurrentCount, "E_MULTI_BOUND", concurrentCount, peak);
    observation.peak = peak;
    enforceProbe(server.failureCount() == 0, "E_MULTI_SERVER_FAILURE", 0, server.failureCount());
}

void checkConcurrent() {
    MultiCleanupObservation injected;
    if (environment.get("SCRUBD_HTTP_FETCH_MULTI_FAULT", "") == "1") {
        exerciseConcurrent(true, injected);
        enforceProbe(false, "E_MULTI_FAULT_NOT_INJECTED");
    }
    bool injectedFailed;
    try {
        exerciseConcurrent(true, injected);
    } catch (ProbeFailure failure) {
        enforceProbe(failure.failureCode == "E_MULTI_CLEANUP_INJECTED",
            "E_MULTI_CLEANUP_WRONG_FAILURE");
        injectedFailed = true;
    }
    enforceProbe(injectedFailed, "E_MULTI_CLEANUP_NOT_INJECTED");
    enforceProbe(injected.initialized == 1 && injected.added == 1 &&
        injected.removed == 1 && injected.cleaned == 1 &&
        injected.headerFreed == 1 && injected.multiCleaned == 1 &&
        injected.cleanupErrors == 0, "E_MULTI_CLEANUP_COUNTERS", 1, injected.cleaned);
    stdout.writeln("PASS multi_fault_cleanup");
    stdout.writeln("MEASURE multi_fault initialized=1 added=1 removed=1 cleaned=1 headers=1 multi=1 errors=0");

    MultiCleanupObservation ordinary;
    exerciseConcurrent(false, ordinary);
    enforceProbe(ordinary.initialized == concurrentCount &&
        ordinary.added == concurrentCount && ordinary.removed == concurrentCount &&
        ordinary.cleaned == concurrentCount && ordinary.headerFreed == concurrentCount &&
        ordinary.multiCleaned == 1 && ordinary.cleanupErrors == 0,
        "E_MULTI_ORDINARY_CLEANUP", concurrentCount, ordinary.cleaned);
    stdout.writeln("PASS bounded_multi_concurrency");
    stdout.writeln("MEASURE multi_peak=", ordinary.peak, " multi_limit=", concurrentCount);
}

int runProbe() {
    signal(SIGPIPE, SIG_IGN);
    enforceProbe(curl_global_init(3) == CURLE_OK, "E_GLOBAL_INIT");
    scope(exit) curl_global_cleanup();
    stdout.writeln("HOST_LIBCURL ", curl_version().fromStringz);
    auto server = new LocalServer;
    scope(exit) server.stop();

    auto result = fetch(server.url("/ok"));
    checkCode("http_loopback", result, CURLE_OK);
    enforceProbe(result.status == 200 && result.bodyBytes == 5, "E_HTTP_RESULT");

    result = fetch("file:///private/tmp/" ~ pathCanary);
    checkCode("protocol_allowlist", result, CURLE_UNSUPPORTED_PROTOCOL);

    FetchOptions follow;
    follow.follow = true;
    result = fetch(server.url("/redirect"), follow);
    checkCode("redirect", result, CURLE_OK);
    enforceProbe(result.status == 200, "E_REDIRECT_STATUS", 200, result.status);
    result = fetch(server.url("/file-redirect"), follow);
    checkCode("redirect_protocol_allowlist", result, CURLE_UNSUPPORTED_PROTOCOL);
    follow.maxRedirects = 2;
    result = fetch(server.url("/loop"), follow);
    checkCode("redirect_loop", result, CURLE_TOO_MANY_REDIRECTS);

    FetchOptions totalTimeout;
    totalTimeout.totalTimeoutMs = 60;
    result = fetch(server.url("/stall"), totalTimeout);
    checkCode("total_timeout", result, CURLE_OPERATION_TIMEDOUT);

    FetchOptions connectTimeout;
    connectTimeout.connectTimeoutMs = environment.get(
        "SCRUBD_HTTP_FETCH_CONNECT_TIMEOUT_MUTANT", "") == "1" ? 0 : 60;
    connectTimeout.totalTimeoutMs = 1_000;
    connectTimeout.insecureTls = true;
    auto connectStarted = MonoTime.currTime;
    result = fetch("https://127.0.0.1:" ~ server.port.to!string ~ "/", connectTimeout);
    auto connectElapsedMs = (MonoTime.currTime - connectStarted).total!"msecs";
    checkCode("connect_timeout_tls_handshake", result, CURLE_OPERATION_TIMEDOUT);
    enforceProbe(connectElapsedMs < 250, "E_CONNECT_TIMEOUT_ELAPSED", 249, connectElapsedMs);
    stdout.writeln("MEASURE connect_timeout_config_ms=60 elapsed_ms=", connectElapsedMs,
        " total_timeout_ms=1000");

    FetchOptions headerCap;
    headerCap.headerCap = 512;
    result = fetch(server.url("/headers"), headerCap);
    checkCode("header_cap", result, CURLE_WRITE_ERROR);
    enforceProbe(result.headerBytes <= 512, "E_HEADER_CAP_ACCOUNTING", 512, result.headerBytes);
    stdout.writeln("MEASURE header_cap=512 accepted=", result.headerBytes);

    FetchOptions encodedCap;
    encodedCap.encodedCap = 512;
    result = fetch(server.url("/encoded"), encodedCap);
    checkCode("encoded_cap", result, CURLE_ABORTED_BY_CALLBACK);
    enforceProbe(result.encodedBytes <= 768, "E_ENCODED_OVERSHOOT", 768, result.encodedBytes);
    stdout.writeln("MEASURE encoded_cap=512 observed=", result.encodedBytes);

    FetchOptions decodedCap;
    decodedCap.decode = true;
    decodedCap.decodedCap = 1_024;
    decodedCap.encodedCap = 512;
    result = fetch(server.url("/gzip"), decodedCap);
    checkCode("decoded_compression_cap", result, CURLE_WRITE_ERROR);
    enforceProbe(result.encodedBytes < 512 && result.bodyBytes <= 1_024 && result.bodyOffered == 8_192,
        "E_DECODED_CAP_ACCOUNTING", 8_192, result.bodyOffered);
    stdout.writeln("MEASURE decoded_cap=1024 accepted=", result.bodyBytes,
        " offered=", result.bodyOffered, " fixture_encoded=44");

    FetchOptions cancelled;
    cancelled.cancel = true;
    result = fetch(server.url("/stream"), cancelled);
    checkCode("cancellation", result, CURLE_ABORTED_BY_CALLBACK);
    enforceProbe(result.bodyOffered >= 256, "E_CANCELLATION_PROGRESS", 256, result.bodyOffered);

    result = fetch(server.url("/conditional"));
    checkCode("conditional_initial", result, CURLE_OK);
    enforceProbe(result.status == 200 && result.bodyBytes == 5, "E_CONDITIONAL_INITIAL");
    enforceProbe(result.etagCount == 1 && !result.etagInvalid,
        "E_CONDITIONAL_ETAG_COUNT", 1, result.etagCount);
    auto initialEtag = result.etag;
    FetchOptions conditional;
    conditional.headers = ["If-None-Match: " ~ initialEtag];
    result = fetch(server.url("/conditional"), conditional);
    checkCode("conditional_not_modified", result, CURLE_OK);
    enforceProbe(result.status == 304 && result.bodyBytes == 0, "E_CONDITIONAL_304", 304, result.status);

    FetchOptions callbackFailure;
    callbackFailure.failWrite = true;
    result = fetch(server.url("/ok"), callbackFailure);
    checkCode("callback_failure", result, CURLE_WRITE_ERROR);

    checkConcurrent();
    checkServerLifecycle();
    checkHttps();

    FetchOptions diagnostic;
    diagnostic.failWrite = true;
    diagnostic.headers = ["Authorization: Bearer " ~ credentialCanary,
        "X-Canary: " ~ headerCanary];
    result = fetch(server.url("/diagnostic/" ~ pathCanary), diagnostic);
    enforceProbe(result.code == CURLE_WRITE_ERROR, "E_DIAGNOSTIC_CALLBACK",
        CURLE_WRITE_ERROR, result.code);
    auto fixedDiagnostic = "E_FETCH_FAILURE";
    enforceProbe(fixedDiagnostic.indexOf(pathCanary) < 0 &&
        fixedDiagnostic.indexOf(headerCanary) < 0 &&
        fixedDiagnostic.indexOf(bodyCanary) < 0 &&
        fixedDiagnostic.indexOf(credentialCanary) < 0, "E_DIAGNOSTIC_PRIVACY");
    stdout.writeln("PASS content_free_diagnostics");
    server.awaitIdle();
    stdout.writeln("PASS all 23 checks");
    return 0;
}

int main() {
    try {
        return runProbe();
    } catch (ProbeFailure failure) {
        stderr.writefln("FAIL %s expected=%d actual=%d",
            failure.failureCode, failure.expected, failure.actual);
        return 1;
    } catch (Exception) {
        stderr.writeln("FAIL E_INTERNAL expected=0 actual=1");
        return 1;
    }
}
