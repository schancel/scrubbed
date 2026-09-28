/// Loopback fixture proving `s3lite.transfer`'s object-level worker pool is
/// really bounded by the configured worker count -- for both `downloadBulk`
/// (bulk pull) and `uploadBulk` (bulk push) -- via a real, multi-connection,
/// plaintext TCP loopback server, the same `GetOptions.urlOverride`
/// technique `tests/put_list_loopback_fixture.d` uses. No AWS account,
/// credential, or network access beyond 127.0.0.1 is used.
///
/// Concurrency proof shape: the test server tracks how many object-transfer
/// requests are simultaneously in flight (a real atomic counter,
/// incremented on accept, decremented on completion). Each such connection
/// is deliberately held open until either every configured worker has piled
/// on concurrently (a real rendezvous, not a fixed sleep guess) or a
/// generous timeout elapses, so the observed peak is a real property of the
/// client's own dispatch, not scheduler luck. Two things are checked: the
/// in-flight count never exceeds the configured worker bound (the hard
/// safety invariant `s3lite.transfer` must uphold), and it actually reaches
/// that bound at least once (proving real parallelism happened, not
/// accidental serialization).
///
/// Run via: `dub run --config=transfer-bulk-fixture` (from this package's
/// own directory).
import s3lite.client : Credentials, ListObjectsV2Request;
import s3lite.http : GetOptions;
import s3lite.transfer : DownloadOutcome, TransferConfig, UploadItem,
    UploadOutcome, downloadBulk, uploadBulk;
import std.conv : to;
import std.socket : Socket, TcpSocket, InternetAddress, SocketOptionLevel, SocketOption;
import std.stdio : writeln;
import std.algorithm.searching : canFind;
import std.string : indexOf, startsWith;
import core.atomic : atomicOp, atomicLoad, cas;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : msecs, MonoTime;

void check(bool condition, string label) {
    if (!condition) throw new Exception("FAIL: " ~ label);
}

enum objectWorkers = 4;
enum numObjects = 16; // >> objectWorkers, so all workers fill before any completes
enum rendezvousTimeoutMs = 2000;

/// Tracks how many *tracked* (object-transfer) connections are concurrently
/// in flight, and the highest value ever observed.
final class ConcurrencyTracker {
    private shared int current_ = 0;
    private shared int max_ = 0;

    int enter() {
        auto now = atomicOp!"+="(current_, 1);
        while (true) {
            auto observedMax = atomicLoad(max_);
            if (now <= observedMax) break;
            if (cas(&max_, observedMax, now)) break;
        }
        return now;
    }

    void leave() {
        atomicOp!"-="(current_, 1);
    }

    int current() { return atomicLoad(current_); }
    int max() { return atomicLoad(max_); }
}

string receiveRequestRaw(Socket peer) {
    char[8192] bytes;
    auto n = peer.receive(bytes[]);
    check(n > 0, "loopback peer received no request");
    return bytes[0 .. cast(size_t) n].idup;
}

string firstLine(string raw) {
    auto lineEnd = raw.indexOf("\r\n");
    return lineEnd < 0 ? raw : raw[0 .. lineEnd];
}

/// Case-sensitive (the client always sends "Range" exactly), single-value
/// header lookup straight out of the raw request text -- no general header
/// parser needed for this fixture's own narrow purposes.
string headerValue(string raw, string name) {
    auto marker = "\r\n" ~ name ~ ": ";
    auto start = raw.indexOf(marker);
    if (start < 0) return null;
    start += marker.length;
    auto end = raw.indexOf("\r\n", start);
    return end < 0 ? raw[start .. $] : raw[start .. end];
}

void sendResponse(Socket peer, string body_, string contentType = "application/octet-stream") {
    auto resp = "HTTP/1.1 200 OK\r\nContent-Type: " ~ contentType ~
        "\r\nContent-Length: " ~ body_.length.to!string ~ "\r\nConnection: close\r\n\r\n" ~ body_;
    peer.send(resp);
}

/// Runs one loopback server on an ephemeral port. `respond(requestLine,
/// peer)` decides, per connection, what to send back; it receives the
/// tracker so it can rendezvous only for the connections it considers
/// "tracked" (object transfers), and reply immediately for anything else
/// (e.g. the one `ListObjectsV2` listing request).
/// Plain reference-type box so every handler closure (each captures this by
/// reference implicitly, being a class instance) can append to the same
/// underlying error list under one shared mutex.
final class ErrorBox {
    private Mutex mutex_;
    private Exception[] list_;

    this() { mutex_ = new Mutex; }

    void record(Exception e) {
        mutex_.lock();
        scope(exit) mutex_.unlock();
        list_ ~= e;
    }

    Exception first() {
        mutex_.lock();
        scope(exit) mutex_.unlock();
        return list_.length ? list_[0] : null;
    }
}

struct LoopbackServer {
    TcpSocket listener;
    ushort port;
    ConcurrencyTracker tracker;
    Thread acceptThread;
    ErrorBox errors;

    static LoopbackServer start(int totalConns,
            void delegate(string rawRequest, Socket peer, ConcurrencyTracker tracker) respond) {
        LoopbackServer self;
        self.listener = new TcpSocket();
        self.listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
        self.listener.bind(new InternetAddress("127.0.0.1", 0));
        self.port = (cast(InternetAddress) self.listener.localAddress()).port;
        self.listener.listen(totalConns + 4);
        self.tracker = new ConcurrencyTracker();
        self.errors = new ErrorBox();

        auto tracker = self.tracker;
        auto listener = self.listener;
        auto errors = self.errors;

        // `peer` must be captured fresh per accepted connection, not as a
        // loop-body local re-bound each iteration (a delegate literal
        // inside a simple `foreach` closes over the loop's stack slot, not
        // a fresh one per iteration -- every handler thread would otherwise
        // see whatever `peer` most recently held, including null before the
        // first accept() or another connection's socket, a real
        // segfault-on-null-deref this shipped with once already). Passing
        // it as a parameter to a helper forces a distinct binding per call.
        Thread acceptOne(Socket peer) {
            return new Thread({
                try {
                    scope(exit) peer.close();
                    auto raw = receiveRequestRaw(peer);
                    respond(raw, peer, tracker);
                } catch (Exception e) {
                    errors.record(e);
                }
            });
        }

        self.acceptThread = new Thread({
            Thread[] handlers;
            foreach (i; 0 .. totalConns) {
                Socket peer;
                try {
                    peer = listener.accept();
                } catch (Exception e) {
                    errors.record(e);
                    break;
                }
                auto h = acceptOne(peer);
                h.start();
                handlers ~= h;
            }
            foreach (h; handlers) h.join();
        });
        self.acceptThread.start();
        return self;
    }

    void finish() { acceptThread.join(); }

    Exception firstError() { return errors.first(); }
}

/// Object-GET/PUT (or chunk-GET) handler: tracked and rendezvoused against
/// `bound`, so the test can prove real bounded concurrency rather than
/// accidental serialization.
void trackedRespond(string requestLine, Socket peer, ConcurrencyTracker tracker, string body_,
        int bound = objectWorkers, int status = 200) {
    tracker.enter();
    scope(exit) tracker.leave();
    auto deadline = MonoTime.currTime + rendezvousTimeoutMs.msecs;
    while (tracker.current() < bound && MonoTime.currTime < deadline)
        Thread.sleep(2.msecs);
    auto resp = "HTTP/1.1 " ~ status.to!string ~ (status == 206 ? " Partial Content\r\n" : " OK\r\n") ~
        "Content-Type: application/octet-stream\r\nContent-Length: " ~ body_.length.to!string ~
        "\r\nConnection: close\r\n\r\n" ~ body_;
    peer.send(resp);
}

string listObjectsV2Xml(int count, string prefix, int size = 4) {
    string body_ = `<?xml version="1.0" encoding="UTF-8"?><ListBucketResult><IsTruncated>false</IsTruncated>`;
    foreach (i; 0 .. count)
        body_ ~= `<Contents><Key>` ~ prefix ~ i.to!string ~
            `.bin</Key><ETag>"e` ~ i.to!string ~ `"</ETag><Size>` ~ size.to!string ~ `</Size></Contents>`;
    body_ ~= `</ListBucketResult>`;
    return body_;
}

/// A. downloadBulk: object-level parallelism is bounded by `objectWorkers`.
/// One server handles both the single `ListObjectsV2` listing connection
/// (untracked, answered immediately) and the `numObjects` object-GET
/// connections that follow (tracked + rendezvoused).
void checkDownloadBulkBounded() {
    writeln("A. downloadBulk: object-level parallelism bounded by objectWorkers=", objectWorkers, "...");

    auto server = LoopbackServer.start(1 + numObjects, (string raw, Socket peer, ConcurrencyTracker tracker) {
        auto requestLine = firstLine(raw);
        if (requestLine.canFind("list-type=2")) {
            check(requestLine.startsWith("GET /?"), "listing request line mismatch: " ~ requestLine);
            sendResponse(peer, listObjectsV2Xml(numObjects, "obj-"), "application/xml");
        } else {
            check(requestLine.startsWith("GET /obj-"), "expected an object GET: " ~ requestLine);
            trackedRespond(requestLine, peer, tracker, "four");
        }
    });

    GetOptions opts;
    opts.urlOverride = "http://127.0.0.1:" ~ server.port.to!string;
    auto listReq = ListObjectsV2Request("bucket", "us-east-1", Credentials.init);
    listReq.transport = opts;

    TransferConfig cfg;
    cfg.objectWorkers = objectWorkers;

    // `onComplete` fires from whichever pool worker thread finished that
    // object (see downloadBulk's own doc comment) -- guard this test's own
    // shared `outcomes` array explicitly; downloadBulk's internal
    // succeeded/failed bookkeeping is already safe on its own.
    auto outcomesMutex = new Mutex;
    DownloadOutcome[] outcomes;
    auto result = downloadBulk(listReq, cfg, (DownloadOutcome o) {
        outcomesMutex.lock();
        scope(exit) outcomesMutex.unlock();
        outcomes ~= o;
    });

    server.finish();
    check(server.firstError() is null, server.firstError() is null ? "" : server.firstError().msg);

    check(result.listingOk, "listing should have succeeded");
    check(result.succeeded == numObjects, "expected all " ~ numObjects.to!string ~ " downloads to succeed, got " ~ result.succeeded.to!string);
    check(result.failed == 0, "expected zero failed downloads, got " ~ result.failed.to!string);
    check(outcomes.length == numObjects, "onComplete should have fired once per object");
    foreach (o; outcomes)
        check(o.ok && cast(string) o.body_ == "four", "unexpected outcome for " ~ o.key);

    check(server.tracker.max() <= objectWorkers,
        "SAFETY VIOLATION: observed " ~ server.tracker.max().to!string ~
        " concurrent object downloads, configured bound was " ~ objectWorkers.to!string);
    check(server.tracker.max() == objectWorkers,
        "expected real parallelism to reach the configured bound of " ~ objectWorkers.to!string ~
        ", only reached " ~ server.tracker.max().to!string);

    writeln("   PASS: ", numObjects, " objects downloaded, peak concurrent in-flight = ",
        server.tracker.max(), " (== configured objectWorkers, never exceeded)");
}

/// B. uploadBulk: object-level parallelism is bounded by `objectWorkers`,
/// same proof shape as A, over PUTs instead of GETs.
void checkUploadBulkBounded() {
    writeln("B. uploadBulk: object-level parallelism bounded by objectWorkers=", objectWorkers, "...");

    auto server = LoopbackServer.start(numObjects, (string raw, Socket peer, ConcurrencyTracker tracker) {
        auto requestLine = firstLine(raw);
        check(requestLine.startsWith("PUT /push-"), "expected an object PUT: " ~ requestLine);
        trackedRespond(requestLine, peer, tracker, "");
    });

    GetOptions opts;
    opts.urlOverride = "http://127.0.0.1:" ~ server.port.to!string;

    UploadItem[] items;
    foreach (i; 0 .. numObjects)
        items ~= UploadItem("push-" ~ i.to!string ~ ".bin", cast(const(ubyte)[]) "payload");

    TransferConfig cfg;
    cfg.objectWorkers = objectWorkers;

    auto outcomesMutex = new Mutex;
    UploadOutcome[] outcomes;
    auto result = uploadBulk("bucket", "us-east-1", Credentials.init, "s3", items, cfg, opts,
        (UploadOutcome o) {
            outcomesMutex.lock();
            scope(exit) outcomesMutex.unlock();
            outcomes ~= o;
        });

    server.finish();
    check(server.firstError() is null, server.firstError() is null ? "" : server.firstError().msg);

    check(result.succeeded == numObjects, "expected all " ~ numObjects.to!string ~ " uploads to succeed, got " ~ result.succeeded.to!string);
    check(result.failed == 0, "expected zero failed uploads, got " ~ result.failed.to!string);
    check(outcomes.length == numObjects, "onComplete should have fired once per item");

    check(server.tracker.max() <= objectWorkers,
        "SAFETY VIOLATION: observed " ~ server.tracker.max().to!string ~
        " concurrent object uploads, configured bound was " ~ objectWorkers.to!string);
    check(server.tracker.max() == objectWorkers,
        "expected real parallelism to reach the configured bound of " ~ objectWorkers.to!string ~
        ", only reached " ~ server.tracker.max().to!string);

    writeln("   PASS: ", numObjects, " objects uploaded, peak concurrent in-flight = ",
        server.tracker.max(), " (== configured objectWorkers, never exceeded)");
}

enum perFileChunkConcurrency = 3;
enum chunkSizeBytes = 5;
enum chunkThresholdBytes = 10;

string makeContent(size_t n) {
    auto buf = new char[n];
    foreach (i, ref c; buf) c = cast(char)('A' + (i % 26));
    return cast(string) buf;
}

/// C. downloadBulk, chunked path: one object above `chunkThresholdBytes` is
/// fetched as several concurrent byte-range GETs, bounded by
/// `perFileChunkConcurrency`, and reassembled byte-exact regardless of which
/// chunk's connection happens to complete first.
void checkDownloadBulkChunked() {
    writeln("C. downloadBulk: per-file chunk parallelism bounded by perFileChunkConcurrency=",
        perFileChunkConcurrency, "...");

    auto content = makeContent(27); // 27 bytes / 5-byte chunks -> 6 chunks (5,5,5,5,5,2)
    auto numChunks = (content.length + chunkSizeBytes - 1) / chunkSizeBytes;

    auto server = LoopbackServer.start(1 + cast(int) numChunks, (string raw, Socket peer, ConcurrencyTracker tracker) {
        auto requestLine = firstLine(raw);
        if (requestLine.canFind("list-type=2")) {
            check(requestLine.startsWith("GET /?"), "listing request line mismatch: " ~ requestLine);
            sendResponse(peer, listObjectsV2Xml(1, "big-", cast(int) content.length), "application/xml");
        } else {
            check(requestLine.startsWith("GET /big-0.bin"), "expected the chunked object's GET: " ~ requestLine);
            auto range = headerValue(raw, "Range");
            check(range !is null, "expected a Range header on a chunk fetch: " ~ raw);
            check(range.startsWith("bytes="), "unexpected Range header shape: " ~ range);
            auto dash = range.indexOf('-');
            auto start = range[6 .. dash].to!size_t;
            auto end = range[dash + 1 .. $].to!size_t;
            auto slice = content[start .. end + 1 > content.length ? content.length : end + 1];
            trackedRespond(requestLine, peer, tracker, slice, perFileChunkConcurrency, 206);
        }
    });

    GetOptions opts;
    opts.urlOverride = "http://127.0.0.1:" ~ server.port.to!string;
    auto listReq = ListObjectsV2Request("bucket", "us-east-1", Credentials.init);
    listReq.transport = opts;

    TransferConfig cfg;
    cfg.objectWorkers = 1;
    cfg.perFileChunkConcurrency = perFileChunkConcurrency;
    cfg.chunkSizeBytes = chunkSizeBytes;
    cfg.chunkThresholdBytes = chunkThresholdBytes;

    DownloadOutcome[] outcomes;
    auto result = downloadBulk(listReq, cfg, (DownloadOutcome o) { outcomes ~= o; }); // single object: no concurrent onComplete calls possible

    server.finish();
    check(server.firstError() is null, server.firstError() is null ? "" : server.firstError().msg);

    check(result.listingOk, "listing should have succeeded");
    check(result.succeeded == 1, "expected the single chunked object to succeed, got " ~ result.succeeded.to!string);
    check(outcomes.length == 1, "expected exactly one onComplete call for the one object");
    check(outcomes[0].ok, "chunked download should have succeeded");
    check(cast(string) outcomes[0].body_ == content,
        "chunked reassembly mismatch: got " ~ (cast(string) outcomes[0].body_) ~ ", expected " ~ content);

    check(server.tracker.max() <= perFileChunkConcurrency,
        "SAFETY VIOLATION: observed " ~ server.tracker.max().to!string ~
        " concurrent chunk fetches, configured bound was " ~ perFileChunkConcurrency.to!string);
    check(server.tracker.max() == perFileChunkConcurrency,
        "expected real chunk parallelism to reach the configured bound of " ~ perFileChunkConcurrency.to!string ~
        ", only reached " ~ server.tracker.max().to!string);

    writeln("   PASS: ", numChunks, "-chunk object reassembled byte-exact, peak concurrent chunk fetches = ",
        server.tracker.max(), " (== configured perFileChunkConcurrency, never exceeded)");
}

void main() {
    writeln("s3lite transfer bulk loopback fixture (issue #367)");
    checkDownloadBulkBounded();
    checkUploadBulkBounded();
    checkDownloadBulkChunked();
    writeln("s3lite transfer bulk fixture: PASS");
}
