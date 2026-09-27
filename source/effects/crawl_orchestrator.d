/// Concurrent, resumable frontier -> fetch -> discover orchestration for the
/// shipped `scrubbed crawl` command (issue #329). This promotes the proven,
/// strictly-serial `experiments/corpus_crawl/crawl.d` (issue #305) shape to
/// real OS-thread concurrency over the same, UNMODIFIED building blocks:
///
///   - `domain.job_queue` / `domain.frontier_contract`: admission, leasing,
///     and bounded-discovery lifecycle. `FrontierLimits.maxActiveLeases` is
///     finally driven above 1 here.
///   - `effects.http_fetch`: the one real network call, including its own
///     content-addressed raw-body persistence and typed failure taxonomy.
///     Already internally thread-safe (a fresh libcurl "easy" handle per
///     call, a global atomic concurrency counter) -- untouched here.
///   - `effects.html_discovery` over `effects.html_tree`'s restricted parser:
///     turns a fetched page's bytes back into new frontier candidates.
///
/// Like its experiment precedent, this is orchestration glue only: it writes
/// zero page bytes itself, does zero HTML parsing beyond handing bytes to the
/// existing restricted parser, and invents no new frontier/fetch/discovery
/// semantics. It is NOT a document-processing pipeline: no mojibake repair,
/// no metadata/main-content/PII, no `StageDocument` involvement anywhere in
/// this file. Cleaning is a separate, later `clean-web-document` pass over
/// the raw output this orchestrator produces.
///
/// ## The real correctness work beyond the experiment
///
/// Both frontier backends push serialization onto the caller by their own
/// documented contract (`domain.url_frontier`: "callers provide serialization
/// when adapting it to persistence"; `effects.sqlite_frontier`: "multiple
/// local handles coordinate through SQLite's single-writer transactions").
/// Every `takeLease`/`finish`/`counts` call any worker thread makes here goes
/// through `mutex_`, so the whole admit/lease/finish lifecycle is a single
/// serialized critical section from this orchestrator's point of view,
/// exactly matching the single-writer model both backends assume.
///
/// The experiment's `HostThrottle` mutated a plain associative array keyed by
/// host with no lock -- not safe for concurrent callers. `HostThrottle` here
/// holds its own mutex and reserves the next attempt's start time in the same
/// critical section that reads the elapsed time, so two threads racing on the
/// same host can never both observe "no wait needed" for the same window; a
/// per-host `Thread.sleep` never blocks a different host's fetch, since only
/// the map check-and-reserve is serialized, not the sleep itself.
module effects.crawl_orchestrator;

import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.sys.posix.unistd : fsync;
import core.thread : Thread;
import core.time : Duration, msecs;
import domain.frontier_contract : CandidateInput, CandidateKey, CandidateState,
    FinishCode, FrontierLimits, LeaseAttempt, LeaseOutcome, LeaseToken,
    LeaseUnavailable, SnapshotCode;
import domain.job_queue : JobQueue;
import effects.html_discovery : DiscoveryScopeKind, DiscoveryScopePolicy,
    discoverHtmlLinks;
import effects.html_tree : defaultExtractHtmlBytes, parseHtml;
import effects.http_fetch : defaultMaxConcurrentFetches, FetchFailureCategory,
    FetchRequest, fetchHttp;
import effects.web_url : WebUrl, resolveWebUrl;
import std.algorithm.searching : canFind;
import std.conv : to;
import std.datetime.systime : Clock, SysTime;
import std.datetime.timezone : UTC;
import std.digest : LetterCase, toHexString;
import std.exception : enforce;
import std.file : read;
import std.json : JSONValue;
import std.parallelism : task, TaskPool;
import std.stdio : File, stderr;
import std.string : indexOf, toLower;

/// Fixed policy identity for every candidate this orchestrator ever admits.
/// Opaque to the frontier; only used to namespace this tool's own candidates
/// so a future co-resident frontier user could never collide identities.
enum string crawlPolicyId = "scrubbed-crawl:v1";

/// User-facing crawl bounds, one-to-one with the CLI flags in
/// `effects.crawl_cli`. `concurrency` drives both `FrontierLimits
/// .maxActiveLeases` (set by the caller when building `FrontierLimits`) and
/// the number of OS worker threads this orchestrator spawns -- there is
/// never a reason to run more worker threads than the frontier will ever
/// hand out active leases to, or vice versa.
struct CrawlBounds {
    size_t maxPages;
    size_t maxPagesPerHost;
    size_t maxDepth;
    size_t concurrency;
    long minHostDelayMs;
    DiscoveryScopeKind scopeKind;
    /// `allowedDomain` scope: the exact allow-listed origins. `oneHopExternal`
    /// scope: the "core" origin set a page must belong to for this
    /// orchestrator to discover further links from it at all -- an
    /// already-external one-hop page is still fetched and saved, but never
    /// itself a source of new discoveries (matching
    /// `effects.html_discovery`'s own documented `oneHopExternal` semantics,
    /// which explicitly leaves "no further hop" to the caller). Unused for
    /// `sameOrigin` scope.
    string[] allowedOrigins;
}

struct CrawlSummary {
    size_t attempts;
    size_t completed;
    size_t failed;
    size_t pagesAdmitted;
    size_t activeLeases;
    size_t queued;
    size_t deferred;
}

/// New orchestration-local politeness logic only; `effects.http_fetch` itself
/// has no per-host concept. Thread-safe: `await` may be called concurrently
/// by every worker thread. Blocks only the calling thread, never a timer or
/// another thread's progress on a different host.
final class HostThrottle {
private:
    Mutex mutex_;
    SysTime[string] lastAttemptStart_;
    Duration minDelay_;

public:
    this(Duration minDelay) {
        minDelay_ = minDelay;
        mutex_ = new Mutex;
    }

    /// Sleeps, if necessary, until at least `minDelay` has elapsed since the
    /// last attempt against `host`, then records and returns this attempt's
    /// own start time (in UTC) as the value to log as `fetchedAtUtc`. The
    /// read of the last attempt time and the reservation of this attempt's
    /// slot happen in the same locked critical section, so two threads
    /// racing on the same host can never both compute "no wait needed" for
    /// overlapping windows.
    SysTime await(string host) {
        while (true) {
            mutex_.lock();
            auto now = Clock.currTime(UTC());
            Duration remaining;
            if (auto last = host in lastAttemptStart_) {
                auto elapsed = now - *last;
                if (elapsed < minDelay_) remaining = minDelay_ - elapsed;
            }
            if (remaining <= Duration.zero) {
                auto attemptStart = Clock.currTime(UTC());
                lastAttemptStart_[host] = attemptStart;
                mutex_.unlock();
                return attemptStart;
            }
            mutex_.unlock();
            Thread.sleep(remaining);
        }
    }
}

/// Thread-safe append-only JSONL sink. Every finished lease (success or
/// failure) gets exactly one flushed, fsynced line; concurrent callers are
/// serialized so no two lines can ever interleave. Opened in append mode so
/// a resumed run against the same `--corpus-dir` preserves prior history
/// rather than truncating it.
final class ManifestWriter {
private:
    Mutex mutex_;
    File file_;

public:
    this(string path) {
        file_ = File(path, "ab");
        mutex_ = new Mutex;
    }

    void append(JSONValue[string] fields) {
        mutex_.lock();
        scope(exit) mutex_.unlock();
        file_.writeln(JSONValue(fields).toString);
        file_.flush();
        fsync(file_.fileno);
    }
}

private WebUrl parseAbsoluteUrl(string url) {
    // An absolute reference resolved "against itself" simply parses that
    // absolute URL, same idiom as `experiments/corpus_crawl/crawl.d`.
    auto outcome = resolveWebUrl(url, url);
    enforce(outcome.isResolved, "crawl orchestrator: unparsable URL: " ~ url);
    return outcome.value;
}

private bool looksLikeHtml(string contentType) {
    return contentType.toLower.indexOf("html") >= 0;
}

/// Re-reads the just-persisted raw body from `shardPath` (this orchestrator
/// writes zero page bytes itself; it only ever reads back what
/// `effects.http_fetch` already durably wrote) and turns any in-scope
/// discovered links into new frontier candidates. Best-effort: a parse
/// failure or an unreadable shard file only means this one page discovers no
/// further links -- the fetch itself already succeeded and was already
/// recorded in the manifest, so this never turns a successful fetch attempt
/// into a failure.
private CandidateInput[] discoverCandidates(WebUrl finalUrl, string shardPath,
        size_t depth, size_t maxDepth, DiscoveryScopePolicy policy) {
    if (depth >= maxDepth) return null;

    const(ubyte)[] raw;
    try raw = cast(const(ubyte)[]) read(shardPath);
    catch (Exception) return null;

    auto parsed = parseHtml(raw, null, finalUrl.canonical, defaultExtractHtmlBytes);
    if (!parsed.isParsed) return null;

    auto discovered = discoverHtmlLinks(parsed.tree, finalUrl.canonical, policy);
    CandidateInput[] discoveries;
    foreach (candidate; discovered.candidates)
        discoveries ~= CandidateInput(crawlPolicyId, candidate.locator.canonical,
            candidate.locator.origin, depth + 1, finalUrl.canonical);
    return discoveries;
}

/// A process kill can leave a durable (SQLite) frontier with candidates
/// stuck in `leased` state forever -- nothing else ever reclaims them, and
/// `takeLease` never times out a lease on its own (by frontier design, not a
/// bug: see `domain.frontier_contract`). Without this, a killed-and-restarted
/// crawl against the same database would NOT genuinely resume: every
/// orphaned lease would sit inert, and once enough of them accumulate to
/// reach `maxActiveLeases`, new leases would never be handed out at all.
/// Called once, single-threaded, before any worker starts.
private void recoverOrphanedLeases(JobQueue queue) {
    auto counts = queue.counts();
    if (counts.pages == 0) return;
    auto snapshot = queue.snapshot(counts.pages);
    if (snapshot.code != SnapshotCode.captured) return;
    foreach (view; snapshot.candidates) {
        if (view.state != CandidateState.leased) continue;
        auto key = CandidateKey(view.candidate.policyId, view.candidate.canonicalLocator);
        cast(void) queue.reclaim(LeaseToken(key, view.generation));
    }
}

/// Coordinates `concurrency` real OS worker threads over one `JobQueue`.
/// Every frontier transition (`takeLease`, `finish`, `counts` used for
/// termination decisions) is made while holding `mutex_`: this is the
/// serialization both `UrlFrontier` and `SQLiteJobQueue` explicitly require
/// callers to provide themselves. Fetch, throttle-wait, and HTML parsing all
/// happen OUTSIDE the lock, so concurrent workers genuinely overlap network
/// I/O; only the frontier bookkeeping itself is serialized.
final class CrawlOrchestrator {
private:
    JobQueue queue_;
    Mutex mutex_;
    Condition activity_;
    HostThrottle throttle_;
    ManifestWriter manifest_;
    string rawDir_;
    CrawlBounds bounds_;
    DiscoveryScopePolicy discoveryPolicy_;
    size_t attemptsTaken_;
    size_t attemptBudget_;
    size_t completed_;
    size_t failed_;

public:
    /// `attemptBudget_` caps total lease *attempts* (not distinct admitted
    /// candidates) at `bounds.maxPages`, exactly the accepted termination
    /// guarantee `experiments/corpus_crawl/crawl.d` already establishes: a
    /// `LeaseOutcome.retryableFailure` re-queues the same candidate for
    /// another lease, so without an attempt budget a single persistently-
    /// but-transiently-unreachable host could keep this orchestrator busy
    /// forever. Reusing `maxPages` rather than inventing a distinct new cap
    /// keeps this a pure orchestration-level policy addition, not a new
    /// frontier-layer concept.
    this(JobQueue queue, string rawDir, ManifestWriter manifest, CrawlBounds bounds) {
        enforce(bounds.concurrency > 0, "crawl orchestrator: concurrency must be positive");
        queue_ = queue;
        rawDir_ = rawDir;
        manifest_ = manifest;
        bounds_ = bounds;
        mutex_ = new Mutex;
        activity_ = new Condition(mutex_);
        throttle_ = new HostThrottle(bounds.minHostDelayMs.msecs);
        attemptBudget_ = bounds.maxPages;
        discoveryPolicy_.kind = bounds.scopeKind;
        discoveryPolicy_.allowedOrigins = bounds.allowedOrigins;
    }

    /// Deliberately never seals the frontier: sealing would permanently
    /// refuse admission of any further discovery, which would make a later
    /// invocation against the same durable database unable to keep expanding
    /// a crawl that stopped only because `attemptBudget_` (or wall-clock
    /// process termination) cut it short rather than because the frontier
    /// was genuinely exhausted. A single run still terminates on its own:
    /// every worker stops once either the attempt budget is spent or the
    /// frontier reports no queued work and no active leases anywhere (see
    /// `takeLeaseOrDone`).
    CrawlSummary run() {
        recoverOrphanedLeases(queue_);
        auto workers = bounds_.concurrency;
        if (workers > 1) {
            auto pool = new TaskPool(workers - 1);
            foreach (i; 0 .. workers - 1)
                pool.put(task!workerEntry(this));
            workerEntry(this);
            pool.finish(true);
        } else {
            workerEntry(this);
        }
        auto counts = queue_.counts();
        return CrawlSummary(attemptsTaken_, completed_, failed_, counts.pages,
            counts.activeLeases, counts.queued, counts.deferred);
    }

private:
    static void workerEntry(CrawlOrchestrator self) { self.workerLoop(); }

    void workerLoop() {
        while (true) {
            LeaseAttempt lease;
            if (!takeLeaseOrDone(lease)) return;
            processLease(lease);
        }
    }

    /// The one place every worker thread touches the frontier's lease
    /// lifecycle. `noQueuedWork` does not by itself mean this worker should
    /// stop: another worker may still hold an active lease whose eventual
    /// `finish()` (a retryable failure, or a completion with discoveries)
    /// could repopulate the ready queue. Only when the frontier reports zero
    /// active leases *anywhere* alongside `noQueuedWork` is it safe to
    /// conclude no more work will ever appear. Waiting on `activity_`
    /// (signaled after every `finish()`) avoids a busy-spin while still
    /// reacting immediately once new work might exist.
    bool takeLeaseOrDone(out LeaseAttempt lease) {
        mutex_.lock();
        scope(exit) mutex_.unlock();
        while (true) {
            if (attemptsTaken_ >= attemptBudget_) return false;
            lease = queue_.takeLease();
            if (lease.available) {
                ++attemptsTaken_;
                return true;
            }
            final switch (lease.unavailable) {
            case LeaseUnavailable.none:
                return false; // unreachable: available == false always sets a real reason
            case LeaseUnavailable.canceled:
            case LeaseUnavailable.generationExhausted:
                return false;
            case LeaseUnavailable.activeLimit:
                activity_.wait();
                continue;
            case LeaseUnavailable.noQueuedWork:
                if (queue_.counts().activeLeases == 0) return false;
                activity_.wait();
                continue;
            }
        }
    }

    void processLease(LeaseAttempt lease) {
        auto candidate = lease.candidate;
        auto url = parseAbsoluteUrl(candidate.canonicalLocator);
        auto attemptStart = throttle_.await(url.origin);

        FetchRequest request;
        request.url = url;
        request.shardRoot = rawDir_;
        // Never let the fetch layer's own default concurrency cap (8)
        // silently undercut a higher configured `--concurrency`: each
        // worker here holds at most one in-flight fetch, so the real
        // concurrency ceiling this orchestrator wants is exactly
        // `bounds_.concurrency`.
        request.limits.maxConcurrentFetches = bounds_.concurrency > defaultMaxConcurrentFetches ?
            bounds_.concurrency : defaultMaxConcurrentFetches;
        auto outcome = fetchHttp(request);

        JSONValue[string] fields;
        fields["url"] = JSONValue(candidate.canonicalLocator);
        fields["depth"] = JSONValue(candidate.depth);
        fields["discoveredFrom"] = JSONValue(candidate.provenance);
        fields["fetchedAtUtc"] = JSONValue(attemptStart.toISOExtString());

        LeaseOutcome leaseOutcome;
        CandidateInput[] discoveries;
        bool succeeded = outcome.succeeded;
        if (succeeded) {
            auto evidence = outcome.evidence;
            fields["finalUrl"] = JSONValue(evidence.finalUrl.canonical);
            fields["httpStatus"] = JSONValue(evidence.status);
            fields["contentSha256"] = JSONValue(
                toHexString!(LetterCase.lower)(evidence.bodyDigest).idup);
            fields["bodyBytes"] = JSONValue(evidence.bodyBytes);
            fields["contentType"] = JSONValue(evidence.contentType);
            fields["shardPath"] = JSONValue(evidence.shardPath);
            leaseOutcome = LeaseOutcome.completed;

            bool discoverFurther = bounds_.scopeKind != DiscoveryScopeKind.oneHopExternal ||
                bounds_.allowedOrigins.canFind(candidate.hostKey);
            if (discoverFurther && evidence.bodyStored && looksLikeHtml(evidence.contentType))
                discoveries = discoverCandidates(evidence.finalUrl, evidence.shardPath,
                    candidate.depth, bounds_.maxDepth, discoveryPolicy_);
        } else {
            auto failure = outcome.failure;
            fields["httpStatus"] = JSONValue(failure.httpStatus);
            fields["failureReason"] = JSONValue(failure.reason.to!string);
            fields["failureCategory"] = JSONValue(failure.category.to!string);
            // Same composition as the experiment: `LeaseOutcome` maps
            // directly onto `FetchFailure.category()`.
            leaseOutcome = failure.category == FetchFailureCategory.retryable ?
                LeaseOutcome.retryableFailure : LeaseOutcome.permanentFailure;
        }

        // Never silently drop a failed fetch: it is always recorded here,
        // whether or not the frontier transition below succeeds.
        manifest_.append(fields);

        mutex_.lock();
        if (succeeded) ++completed_; else ++failed_;
        auto finished = queue_.finish(lease.lease, leaseOutcome, discoveries);
        if (finished.code != FinishCode.applied)
            stderr.writeln("scrubbed: crawl-finish-warning: ", finished.code);
        activity_.notifyAll();
        mutex_.unlock();
    }
}

version (unittest) {
    import core.atomic : atomicLoad, atomicStore;
    import domain.frontier_contract : AdmissionCode;
    import domain.job_queue : openInMemoryJobQueue, QueueOpenCode;
    import effects.html_discovery : DiscoveryScopeKind;
    import effects.sqlite_frontier : openSQLiteJobQueue, SQLiteJobQueue;
    import std.algorithm.sorting : sort;
    import std.file : mkdirRecurse, readText, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.socket : AddressFamily, InternetAddress, Socket, SocketOption,
        SocketOptionLevel, TcpSocket;
    import std.string : split, splitLines;
    import std.uuid : randomUUID;

    /// A tiny real loopback HTTP test server: one accept thread, one handler
    /// thread per connection, so concurrent client fetches genuinely overlap
    /// (the same real-network posture `effects.http_fetch`'s own test already
    /// uses, extended to serve more than one canned page by path). Never used
    /// outside this module's own tests; no real network access is required.
    /// A bound method delegate on a dedicated heap object per connection --
    /// never a delegate literal closing over `acceptLoop`'s locals directly.
    /// See the comment on `ThrottleWorker` for why.
    private final class ConnectionHandler {
    private:
        TestServer server_;
        Socket client_;

    public:
        this(TestServer server, Socket client) {
            server_ = server;
            client_ = client;
        }

        void run() { server_.serveOne(client_); }
    }

    private final class TestServer {
    private:
        TcpSocket listener_;
        Thread acceptThread_;
        shared bool stopping_;
        const(string[string]) pages_;
        // Deliberately NOT `shared`: every access is already protected by
        // `hitsMutex_` (the same "plain field, real mutex" discipline
        // `effects.bounded_input.BoundedInput` uses for its own counters).
        // A `shared` associative array has poor codegen/runtime support in
        // this compiler and is not needed on top of manual locking.
        size_t[string] hits_;
        Mutex hitsMutex_;

    public:
        ushort port;

        this(string[string] pages) {
            pages_ = pages;
            hitsMutex_ = new Mutex;
            listener_ = new TcpSocket(AddressFamily.INET);
            listener_.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
            listener_.bind(new InternetAddress("127.0.0.1", 0));
            listener_.listen(64);
            port = (cast(InternetAddress) listener_.localAddress).port;
            acceptThread_ = new Thread(&acceptLoop);
            acceptThread_.isDaemon = true;
            acceptThread_.start();
        }

        size_t hitsFor(string path) {
            hitsMutex_.lock();
            scope(exit) hitsMutex_.unlock();
            auto found = path in hits_;
            return found is null ? 0 : *found;
        }

        void stop() {
            atomicStore(stopping_, true);
            try listener_.close(); catch (Exception ignored) {}
            try acceptThread_.join(); catch (Exception ignored) {}
        }

    private:
        void acceptLoop() {
            while (!atomicLoad(stopping_)) {
                Socket client;
                try client = listener_.accept();
                catch (Exception) return;
                if (atomicLoad(stopping_)) { client.close(); return; }
                auto connection = new ConnectionHandler(this, client);
                auto handler = new Thread(&connection.run);
                handler.isDaemon = true;
                handler.start();
            }
        }

        void serveOne(Socket client) {
            scope(exit) client.close();
            ubyte[8192] buffer;
            string received;
            while (received.indexOf("\r\n\r\n") < 0) {
                auto count = client.receive(buffer[]);
                if (count <= 0) return;
                received ~= cast(string) buffer[0 .. count].idup;
            }
            auto firstLine = received[0 .. received.indexOf("\r\n")];
            auto parts = firstLine.split(' ');
            if (parts.length < 2) return;
            auto path = parts[1];
            hitsMutex_.lock();
            auto existing = path in hits_;
            hits_[path] = (existing is null ? 0 : *existing) + 1;
            hitsMutex_.unlock();
            auto found = path in pages_;
            if (found is null) {
                client.send(cast(const(ubyte)[])
                    "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                return;
            }
            auto body = *found;
            client.send(cast(const(ubyte)[])("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n" ~
                "Content-Length: " ~ body.length.to!string ~
                "\r\nConnection: close\r\n\r\n" ~ body));
        }
    }

    private string freshTempDir(string label) {
        auto path = buildPath(tempDir(), "scrubbed-crawl-test-" ~ label ~ "-" ~
            randomUUID.toString);
        mkdirRecurse(path);
        return path;
    }

    private void removeTempDir(string path) {
        try rmdirRecurse(path);
        catch (Exception ignored) {}
    }

    private CrawlBounds smallGraphBounds(size_t concurrency, string origin) {
        CrawlBounds bounds;
        bounds.maxPages = 32;
        bounds.maxPagesPerHost = 32;
        bounds.maxDepth = 4;
        bounds.concurrency = concurrency;
        bounds.minHostDelayMs = 0;
        bounds.scopeKind = DiscoveryScopeKind.allowedDomain;
        bounds.allowedOrigins = [origin];
        return bounds;
    }
}

// Real synchronization proof #1: the per-host throttle enforces its minimum
// delay across genuinely concurrent OS threads (not merely per-thread-local),
// while never serializing an unrelated host behind it -- the exact
// thread-safety gap the ticket identified in the experiment's own unlocked
// associative-array `HostThrottle`.
private final class ThrottleWorker {
private:
    HostThrottle throttle_;
    string host_;
    size_t attempts_;

public:
    SysTime[] results;

    this(HostThrottle throttle, string host, size_t attempts) {
        throttle_ = throttle;
        host_ = host;
        attempts_ = attempts;
    }

    void run() {
        foreach (n; 0 .. attempts_) results ~= throttle_.await(host_);
    }
}

unittest {
    enum threadsCount = 6;
    enum attemptsPerThread = 4;
    enum minDelay = 30.msecs;

    auto throttle = new HostThrottle(minDelay);
    // Bound method delegates on dedicated, GC-kept-alive heap objects (the
    // same `LeaseWorker`/`&state[index].run` idiom
    // `experiments/sqlite_frontier/check.d` already uses for cross-thread
    // work) -- never a delegate literal closing over locals directly, which
    // this compiler's optimizer does not reliably heap-promote across a real
    // `core.thread.Thread` boundary. Each worker collects its own results;
    // the main thread only reads them back after every `join()`.
    ThrottleWorker[threadsCount] state;
    Thread[threadsCount] workers;
    foreach (i; 0 .. threadsCount) {
        state[i] = new ThrottleWorker(throttle, "concurrent-host", attemptsPerThread);
        workers[i] = new Thread(&state[i].run);
    }
    foreach (w; workers) w.start();
    foreach (w; workers) w.join();
    SysTime[] observed;
    foreach (worker; state) observed ~= worker.results;

    assert(observed.length == threadsCount * attemptsPerThread);
    observed.sort();
    foreach (i; 1 .. observed.length)
        assert(observed[i] - observed[i - 1] >= minDelay,
            "host throttle allowed two attempts against the same host closer " ~
            "than minDelay under concurrency");

    // A distinct host is never serialized behind a busy, unrelated host.
    auto before = Clock.currTime(UTC());
    throttle.await("a-different-host");
    auto after = Clock.currTime(UTC());
    assert(after - before < minDelay,
        "host throttle incorrectly serialized an unrelated host");
}

// Real synchronization proof #2: concurrent lease admission correctness.
// Several leaf pages all link to the same shared page, so multiple worker
// threads race to `admit()` the identical candidate at nearly the same
// moment; every frontier transition here is the orchestrator's own mutex
// serializing genuinely concurrent OS threads over one shared in-memory
// `JobQueue` (the backend whose own doc comment demands caller-provided
// serialization). A missing or broken mutex would corrupt `UrlFrontier`'s
// plain (non-thread-safe) internal arrays/hashmaps under this contention --
// this reliably surfaces as a wrong completed count, a duplicate fetch, or an
// outright crash from one of the frontier's own internal `require()` checks.
unittest {
    enum leafCount = 6;
    string[string] pages;
    string leafLinks;
    foreach (i; 0 .. leafCount) {
        leafLinks ~= `<a href="/leaf` ~ i.to!string ~ `">leaf</a>`;
        pages["/leaf" ~ i.to!string] =
            `<html><body><a href="/shared">shared</a></body></html>`;
    }
    pages["/"] = "<html><body>" ~ leafLinks ~ "</body></html>";
    pages["/shared"] = "<html><body>no further links</body></html>";

    auto server = new TestServer(pages);
    scope(exit) server.stop();
    auto origin = "http://127.0.0.1:" ~ server.port.to!string;

    auto opened = openInMemoryJobQueue(FrontierLimits(32, 32, 4, 32, leafCount,
        16 * 1024 * 1024, 8192, 4096, 1024 * 1024));
    assert(opened.code == QueueOpenCode.opened);
    JobQueue queue = opened.queue;
    auto seedAdmission = queue.admit(CandidateInput(crawlPolicyId, origin ~ "/",
        origin, 0, "seed"));
    assert(seedAdmission.code == AdmissionCode.admittedQueued);

    auto workDir = freshTempDir("concurrent-admission");
    scope(exit) removeTempDir(workDir);
    auto rawDir = buildPath(workDir, "raw");
    mkdirRecurse(rawDir);
    auto manifest = new ManifestWriter(buildPath(workDir, "manifest.jsonl"));

    auto orchestrator = new CrawlOrchestrator(queue, rawDir, manifest,
        smallGraphBounds(leafCount, origin));
    auto summary = orchestrator.run();

    // Exactly one hub, `leafCount` leaves, and one shared page -- never a
    // double-admitted or double-fetched "/shared" despite every leaf
    // discovering it at nearly the same moment from a different thread.
    enum expectedPages = leafCount + 2;
    assert(summary.pagesAdmitted == expectedPages,
        "concurrent admission produced the wrong distinct page count");
    assert(summary.completed == expectedPages);
    assert(summary.failed == 0);
    assert(summary.activeLeases == 0 && summary.queued == 0 && summary.deferred == 0);
    assert(server.hitsFor("/shared") == 1,
        "the shared page was fetched more than once under concurrency");
    foreach (i; 0 .. leafCount)
        assert(server.hitsFor("/leaf" ~ i.to!string) == 1);

    auto manifestLines = readText(buildPath(workDir, "manifest.jsonl")).splitLines;
    assert(manifestLines.length == expectedPages,
        "manifest recorded a different count than the frontier's own completed count");
}

// Resumability proof #1: a genuinely restarted process opens a brand-new
// `SQLiteJobQueue` handle against the same durable database file. Re-running
// the orchestrator against that fresh handle must not re-fetch anything
// already completed by the first run -- proven here by asserting zero
// additional server hits on the second run, not merely that the command
// "succeeds" again.
unittest {
    string[string] pages = [
        "/": `<html><body><a href="/a">a</a><a href="/b">b</a></body></html>`,
        "/a": "<html><body>a</body></html>",
        "/b": "<html><body>b</body></html>",
    ];
    auto server = new TestServer(pages);
    scope(exit) server.stop();
    auto origin = "http://127.0.0.1:" ~ server.port.to!string;

    auto workDir = freshTempDir("resume");
    scope(exit) removeTempDir(workDir);
    auto dbPath = buildPath(workDir, "frontier.sqlite3");
    auto rawDir = buildPath(workDir, "raw");
    mkdirRecurse(rawDir);
    auto manifestPath = buildPath(workDir, "manifest.jsonl");
    auto limits = FrontierLimits(32, 32, 4, 32, 3, 16 * 1024 * 1024, 8192, 4096, 1024 * 1024);

    {
        auto opened = openSQLiteJobQueue(dbPath, limits);
        assert(opened.code == QueueOpenCode.opened);
        JobQueue queue = opened.queue;
        auto admission = queue.admit(CandidateInput(crawlPolicyId, origin ~ "/",
            origin, 0, "seed"));
        assert(admission.code == AdmissionCode.admittedQueued);
        auto manifest = new ManifestWriter(manifestPath);
        auto orchestrator = new CrawlOrchestrator(queue, rawDir, manifest,
            smallGraphBounds(3, origin));
        auto summary = orchestrator.run();
        assert(summary.completed == 3 && summary.failed == 0);
    }
    assert(server.hitsFor("/") == 1 && server.hitsFor("/a") == 1 && server.hitsFor("/b") == 1);

    // "Restart": a completely fresh handle against the same file, exactly as
    // a newly launched process would open it. No new admission is made --
    // the same seed would simply come back `duplicate`, matching what a
    // real restarted `scrubbed crawl` invocation does with unchanged args.
    {
        auto reopened = openSQLiteJobQueue(dbPath, limits);
        assert(reopened.code == QueueOpenCode.opened);
        JobQueue resumedQueue = reopened.queue;
        auto manifest = new ManifestWriter(manifestPath);
        auto orchestrator = new CrawlOrchestrator(resumedQueue, rawDir, manifest,
            smallGraphBounds(3, origin));
        auto summary = orchestrator.run();
        assert(summary.attempts == 0,
            "a resumed run against an already-drained database re-attempted work");
        assert(summary.completed == 0,
            "a resumed run completed new leases when nothing was left to do");
        // The durable frontier's own cumulative state (not this run's fresh
        // `CrawlOrchestrator`, whose own counters legitimately start at 0)
        // still shows all three pages completed from the first run.
        assert(resumedQueue.counts().completed == 3, "resumed counts regressed");
    }
    // Not a single extra request reached the server on the "restarted" run.
    assert(server.hitsFor("/") == 1 && server.hitsFor("/a") == 1 && server.hitsFor("/b") == 1,
        "restarting against the same database re-fetched already-completed pages");
}

// Resumability proof #2: a process kill mid-fetch leaves a durable frontier
// candidate stuck in `leased` state forever (nothing else ever times out a
// lease). Without `recoverOrphanedLeases`, that candidate would sit inert on
// every future run, and enough orphaned leases would eventually exhaust
// `maxActiveLeases` and stall the crawl permanently. This simulates exactly
// that crash: lease a candidate, then close the handle without ever calling
// `finish()`.
unittest {
    string[string] pages = ["/only": "<html><body>alone</body></html>"];
    auto server = new TestServer(pages);
    scope(exit) server.stop();
    auto origin = "http://127.0.0.1:" ~ server.port.to!string;

    auto workDir = freshTempDir("orphan-lease");
    scope(exit) removeTempDir(workDir);
    auto dbPath = buildPath(workDir, "frontier.sqlite3");
    auto rawDir = buildPath(workDir, "raw");
    mkdirRecurse(rawDir);
    auto limits = FrontierLimits(32, 32, 4, 32, 2, 16 * 1024 * 1024, 8192, 4096, 1024 * 1024);

    {
        auto opened = openSQLiteJobQueue(dbPath, limits);
        assert(opened.code == QueueOpenCode.opened);
        JobQueue queue = opened.queue;
        auto admission = queue.admit(CandidateInput(crawlPolicyId,
            origin ~ "/only", origin, 0, "seed"));
        assert(admission.code == AdmissionCode.admittedQueued);
        auto lease = queue.takeLease();
        assert(lease.available);
        // No `finish()` call: simulates a process kill while the fetch was
        // in flight. The candidate is now durably stuck in `leased` state.
        assert(queue.counts().activeLeases == 1);
        auto sqliteQueue = cast(SQLiteJobQueue) queue;
        sqliteQueue.close();
    }

    {
        auto reopened = openSQLiteJobQueue(dbPath, limits);
        assert(reopened.code == QueueOpenCode.opened);
        JobQueue queue = reopened.queue;
        assert(queue.counts().activeLeases == 1, "orphaned lease not durably preserved");
        auto manifest = new ManifestWriter(buildPath(workDir, "manifest.jsonl"));
        auto orchestrator = new CrawlOrchestrator(queue, rawDir, manifest,
            smallGraphBounds(2, origin));
        auto summary = orchestrator.run();
        assert(summary.completed == 1,
            "a kill-and-restart run never recovered the orphaned lease");
        assert(queue.counts().activeLeases == 0 && queue.counts().completed == 1);
    }
    assert(server.hitsFor("/only") == 1);
}
