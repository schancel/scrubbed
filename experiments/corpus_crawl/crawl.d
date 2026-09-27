/// Real frontier -> fetch -> discover batch crawl for issue #305: builds a
/// small, real raw-HTML test corpus for R4 benchmarking by composing three
/// already-shipped, UNMODIFIED pieces exactly as they exist on `origin/main`
/// today:
///
///   - `domain.job_queue` / `domain.frontier_contract` (#251/#253): admission,
///     leasing, and bounded-discovery lifecycle (`openInMemoryJobQueue`,
///     `CandidateInput`, `FrontierLimits`).
///   - `effects.http_fetch` (#238): the one real network call
///     (`fetchHttp`), including its own content-addressed raw-body
///     persistence (`FetchRequest.shardRoot`) and typed
///     `FetchFailure.category()`.
///   - `effects.html_discovery` (#239) over `effects.html_tree`'s restricted
///     parser: turns a fetched page's bytes back into new frontier
///     candidates (`discoverHtmlLinks`).
///
/// This driver is the orchestration glue only: it writes zero page bytes
/// itself (that is `http_fetch.d`'s job), does zero HTML parsing beyond
/// handing bytes to the existing restricted parser, and invents no new
/// frontier/fetch/discovery semantics. It is NOT a document-processing
/// pipeline: no mojibake repair, no metadata/main-content/PII, no
/// `StageDocument` involvement anywhere in this file.
///
/// This tool makes real network requests to the owner-approved seed sites
/// (see `experiments/corpus_crawl/seeds.txt`) -- that is expected and
/// intentional; see `experiments/corpus_crawl/README.md` for the acquisition
/// policy this matches (the same "public package acquisition boundary"
/// posture already used by #26/#229's trafilatura held-out corpus work).
///
/// ## Owner-accepted design defaults (issue #305)
///
/// - In-memory frontier (`openInMemoryJobQueue`): a single-shot batch run,
///   not a resumable service. Nothing here persists frontier state across
///   process restarts.
/// - `hostKey = WebUrl.origin` (scheme+host+port-sensitive): an accepted
///   simplification for a handful of owner-approved seeds.
/// - Politeness: a strictly serial fetch loop (`maxActiveLeases = 1`) plus an
///   explicit per-host minimum delay (`HostThrottle`, default 3000ms,
///   `--min-host-delay-ms` overridable). This is new orchestration-local
///   logic only -- `effects.http_fetch` itself is untouched and has no
///   per-host concept.
/// - Discovery scope: `DiscoveryScopeKind.allowedDomain`, pre-populated from
///   the seed file's own distinct origins -- stays within the owner-approved
///   sites rather than `oneHopExternal`'s risk of wandering off to arbitrary
///   destinations.
/// - Bounds: `maxPages=200`, `maxPagesPerHost=50`, `maxDepth=3`, reusing
///   `FrontierLimits` completely unchanged. This driver's total *attempt*
///   budget is also capped at `maxPages`: `LeaseOutcome.retryableFailure`
///   re-queues the same candidate for another lease (that mapping is this
///   composition's own explicit, accepted design -- see the issue body's
///   "Composition" section), and a batch tool with no backoff must still
///   guarantee termination if a seed is transiently but persistently
///   unreachable for an entire run. Capping total lease attempts at the same
///   `maxPages` number (rather than inventing a distinct new cap) is what
///   makes "frontier exhausted or `maxPages` hit" a real guarantee rather
///   than merely bounding *distinct admitted* candidates.
/// - Failed fetches get a manifest row (useful for debugging), never a
///   silent drop.
/// - `manifest.jsonl` is a new, plain, append-only JSONL file (one JSON
///   object per line, one line per finished lease) -- deliberately NOT
///   `effects.local_manifest.LocalManifest`, which is keyed on
///   document-processing identity concepts this tool has no reason to
///   import.
///
/// ## Crash / Ctrl-C safety
///
/// Raw-body atomicity is entirely `effects.http_fetch`'s own existing
/// guarantee (temp-file + fsync + hard-link into the digest-named
/// destination): a kill at any point can only ever leave behind an
/// unpredictable-named, dot-prefixed temporary file, never a file under the
/// expected `<sha256-hex>` name that is not fully written. This driver adds
/// nothing to that guarantee and changes nothing about it.
///
/// For `manifest.jsonl`, this driver writes and flushes+fsyncs exactly one
/// complete JSON line per finished lease, only after that lease's fetch
/// outcome (success or failure) is fully known, and only ever appends (never
/// rewrites earlier lines). A crash between two leases leaves every
/// already-written line complete and valid; the in-flight lease at the
/// moment of the crash (still sleeping for the per-host delay, or still
/// inside `fetchHttp`) has not yet produced any manifest write attempt, so
/// there is no line to be torn.
module experiments.corpus_crawl.crawl;

import core.stdc.stdlib : exit;
import core.sys.posix.unistd : fsync;
import core.thread : Thread;
import core.time : Duration, msecs;
import domain.frontier_contract : AdmissionCode, CandidateInput, FinishCode,
    FrontierLimits, LeaseOutcome;
import domain.job_queue : JobQueue, openInMemoryJobQueue, QueueOpenCode;
import effects.html_discovery : DiscoveryScopeKind, DiscoveryScopePolicy,
    discoverHtmlLinks;
import effects.html_tree : defaultExtractHtmlBytes, parseHtml;
import effects.http_fetch : FetchFailureCategory, FetchRequest, fetchHttp;
import effects.web_url : WebUrl, resolveWebUrl;
import std.algorithm.iteration : filter, map;
import std.algorithm.searching : canFind;
import std.array : array;
import std.conv : to;
import std.datetime.systime : Clock, SysTime;
import std.datetime.timezone : UTC;
import std.digest : LetterCase, toHexString;
import std.exception : enforce;
import std.file : exists, mkdirRecurse, read, readText;
import std.getopt : config, defaultGetoptPrinter, getopt;
import std.json : JSONValue;
import std.path : buildPath;
import std.stdio : File, stderr, stdout;
import std.string : indexOf, splitLines, startsWith, strip, toLower;

/// Fixed policy identity for every candidate this tool ever admits. Opaque
/// to the frontier; only used to namespace this tool's own candidates so a
/// future co-resident frontier user could never collide identities with it.
enum string crawlPolicyId = "corpus-crawl:v1";

// Owner-accepted defaults (issue #305). Not exposed as flags except
// `--min-host-delay-ms`, which is the one override the issue body calls out.
enum size_t defaultMaxPages = 200;
enum size_t defaultMaxPagesPerHost = 50;
enum size_t defaultMaxDepth = 3;
enum long defaultMinHostDelayMs = 3000;

private FrontierLimits buildLimits() {
    FrontierLimits limits;
    limits.maxPages = defaultMaxPages;
    limits.maxPagesPerHost = defaultMaxPagesPerHost;
    limits.maxDepth = defaultMaxDepth;
    // >= maxPages: nothing this tool admits should ever need real deferral.
    limits.maxQueued = defaultMaxPages;
    // Strictly serial: one in-flight fetch at a time (owner-accepted
    // politeness posture; see `HostThrottle` for the added per-host delay).
    limits.maxActiveLeases = 1;
    // The remaining fields are `FrontierLimits` plumbing this (unmodified)
    // struct already requires a value for; these are generous enough that a
    // real run against the owner-approved seed list never approaches them,
    // not a newly invented tunable cap.
    limits.maxStoredBytes = 16 * 1024 * 1024;
    limits.maxProvenanceBytes = 8192;
    limits.maxDiscoveriesPerFinish = 4096;
    limits.maxDiscoveryInputBytes = 1024 * 1024;
    return limits;
}

/// New orchestration-local politeness logic only: `effects.http_fetch` is
/// untouched and has no per-host concept of its own. Blocks the calling
/// (single) fetch loop, never spawns a timer or a thread.
private struct HostThrottle {
    private SysTime[string] lastAttemptStart;
    private Duration minDelay;

    this(Duration minDelay) { this.minDelay = minDelay; }

    /// Sleeps, if necessary, until at least `minDelay` has elapsed since the
    /// last attempt against `host`, then records and returns this attempt's
    /// own start time (in UTC) as the value to log as `fetchedAtUtc`.
    SysTime await(string host) {
        auto now = Clock.currTime(UTC());
        if (auto last = host in lastAttemptStart) {
            auto elapsed = now - *last;
            if (elapsed < minDelay) Thread.sleep(minDelay - elapsed);
        }
        auto attemptStart = Clock.currTime(UTC());
        lastAttemptStart[host] = attemptStart;
        return attemptStart;
    }
}

private WebUrl parseAbsoluteUrl(string url) {
    // An absolute reference resolved "against itself" simply parses that
    // absolute URL (the same idiom `experiments/http_fetch_seam/check.d`'s
    // own `mustResolve` already uses): the WHATWG algorithm ignores the base
    // once the reference is itself absolute.
    auto outcome = resolveWebUrl(url, url);
    enforce(outcome.isResolved, "corpus_crawl: unparsable URL: " ~ url);
    return outcome.value;
}

private WebUrl[] readSeeds(string path) {
    enforce(exists(path), "corpus_crawl: seeds file not found: " ~ path);
    auto lines = readText(path).splitLines
        .map!strip
        .filter!(line => line.length != 0 && !line.startsWith("#"))
        .array;
    enforce(lines.length != 0, "corpus_crawl: no seed URLs found in " ~ path);
    return lines.map!parseAbsoluteUrl.array;
}

private string[] distinctOrigins(const(WebUrl)[] urls) {
    string[] origins;
    foreach (url; urls) if (!origins.canFind(url.origin)) origins ~= url.origin;
    return origins;
}

private bool looksLikeHtml(string contentType) {
    return contentType.toLower.indexOf("html") >= 0;
}

/// Re-reads the just-persisted raw body from `shardPath` (the orchestrator
/// writes zero page bytes itself; it only ever reads back what
/// `effects.http_fetch` already durably wrote) and turns any in-scope
/// discovered links into new frontier candidates. Best-effort: a parse
/// failure or an unreadable shard file only means this one page discovers no
/// further links -- the fetch itself already succeeded and was already
/// recorded in the manifest, so this never turns a successful fetch attempt
/// into a failure.
private CandidateInput[] discoverCandidates(WebUrl finalUrl, string shardPath,
        size_t depth, size_t maxDepth, const(string)[] allowedOrigins) {
    if (depth >= maxDepth) return null;

    const(ubyte)[] raw;
    try raw = cast(const(ubyte)[]) read(shardPath);
    catch (Exception) return null;

    auto parsed = parseHtml(raw, null, finalUrl.canonical, defaultExtractHtmlBytes);
    if (!parsed.isParsed) return null;

    DiscoveryScopePolicy policy;
    policy.kind = DiscoveryScopeKind.allowedDomain;
    policy.allowedOrigins = allowedOrigins;
    auto discovered = discoverHtmlLinks(parsed.tree, finalUrl.canonical, policy);

    CandidateInput[] discoveries;
    foreach (candidate; discovered.candidates)
        discoveries ~= CandidateInput(crawlPolicyId, candidate.locator.canonical,
            candidate.locator.origin, depth + 1, finalUrl.canonical);
    return discoveries;
}

private void appendManifestLine(File manifestFile, JSONValue[string] fields) {
    manifestFile.writeln(JSONValue(fields).toString);
    manifestFile.flush();
    fsync(manifestFile.fileno);
}

private int run(string[] args) {
    string seedsPath;
    string corpusDir;
    long minHostDelayMs = defaultMinHostDelayMs;
    auto helpInfo = getopt(args,
        config.caseSensitive,
        "seeds", "Newline-delimited seed URL file (required)", &seedsPath,
        "corpus-dir", "Output corpus directory; raw/ and manifest.jsonl are created inside it (required)", &corpusDir,
        "min-host-delay-ms", "Minimum delay between requests to the same host, in ms (default 3000)", &minHostDelayMs);
    if (helpInfo.helpWanted) {
        defaultGetoptPrinter(
            "experiments/corpus_crawl/crawl: real frontier->fetch->discover batch crawl (issue #305, not shipped)",
            helpInfo.options);
        return 0;
    }
    enforce(seedsPath.length != 0, "corpus_crawl: --seeds is required");
    enforce(corpusDir.length != 0, "corpus_crawl: --corpus-dir is required");
    enforce(minHostDelayMs >= 0, "corpus_crawl: --min-host-delay-ms must be non-negative");

    auto seeds = readSeeds(seedsPath);
    auto allowedOrigins = distinctOrigins(seeds);

    auto rawDir = buildPath(corpusDir, "raw");
    mkdirRecurse(rawDir);
    auto manifestFile = File(buildPath(corpusDir, "manifest.jsonl"), "wb");

    auto opened = openInMemoryJobQueue(buildLimits());
    enforce(opened.code == QueueOpenCode.opened,
        "corpus_crawl: failed to open in-memory frontier: " ~ opened.code.to!string);
    JobQueue queue = opened.queue;

    foreach (seed; seeds) {
        auto admission = queue.admit(CandidateInput(crawlPolicyId, seed.canonical,
            seed.origin, 0, "seed"));
        enforce(admission.code == AdmissionCode.admittedQueued ||
            admission.code == AdmissionCode.admittedDeferred ||
            admission.code == AdmissionCode.duplicate,
            "corpus_crawl: seed rejected: " ~ admission.code.to!string ~ ": " ~ seed.canonical);
    }

    auto limits = queue.limits();
    auto throttle = HostThrottle(minHostDelayMs.msecs);
    size_t attempts, completed, failed;

    // Terminates on its own: either the frontier is exhausted (`takeLease`
    // reports no queued work -- nothing left reachable within scope/depth),
    // or the total attempt budget (`limits.maxPages`) is hit. See this
    // file's header comment for why the attempt budget, not merely the
    // frontier's own distinct-admission cap, is the thing that guarantees
    // termination under a retried, persistently-failing candidate.
    while (attempts < limits.maxPages) {
        auto lease = queue.takeLease();
        if (!lease.available) break;
        ++attempts;

        auto candidate = lease.candidate;
        auto url = parseAbsoluteUrl(candidate.canonicalLocator);
        auto attemptStart = throttle.await(url.origin);

        FetchRequest request;
        request.url = url;
        request.shardRoot = rawDir;
        auto outcome = fetchHttp(request);

        JSONValue[string] fields;
        fields["url"] = JSONValue(candidate.canonicalLocator);
        fields["depth"] = JSONValue(candidate.depth);
        fields["discoveredFrom"] = JSONValue(candidate.provenance);
        fields["fetchedAtUtc"] = JSONValue(attemptStart.toISOExtString());

        LeaseOutcome leaseOutcome;
        CandidateInput[] discoveries;
        if (outcome.succeeded) {
            auto evidence = outcome.evidence;
            fields["finalUrl"] = JSONValue(evidence.finalUrl.canonical);
            fields["httpStatus"] = JSONValue(evidence.status);
            fields["contentSha256"] = JSONValue(
                toHexString!(LetterCase.lower)(evidence.bodyDigest).idup);
            fields["bodyBytes"] = JSONValue(evidence.bodyBytes);
            fields["contentType"] = JSONValue(evidence.contentType);
            fields["shardPath"] = JSONValue(evidence.shardPath);
            leaseOutcome = LeaseOutcome.completed;
            ++completed;

            if (evidence.bodyStored && looksLikeHtml(evidence.contentType))
                discoveries = discoverCandidates(evidence.finalUrl,
                    evidence.shardPath, candidate.depth, limits.maxDepth,
                    allowedOrigins);
        } else {
            auto failure = outcome.failure;
            fields["httpStatus"] = JSONValue(failure.httpStatus);
            fields["failureReason"] = JSONValue(failure.reason.to!string);
            fields["failureCategory"] = JSONValue(failure.category.to!string);
            // Composition per the issue body: `LeaseOutcome` maps directly
            // onto `FetchFailure.category()`.
            leaseOutcome = failure.category == FetchFailureCategory.retryable ?
                LeaseOutcome.retryableFailure : LeaseOutcome.permanentFailure;
            ++failed;
        }

        appendManifestLine(manifestFile, fields);

        auto finished = queue.finish(lease.lease, leaseOutcome, discoveries);
        if (finished.code != FinishCode.applied)
            stderr.writeln("corpus_crawl: warning: finish() returned ",
                finished.code, " for ", candidate.canonicalLocator);
    }
    queue.seal();

    auto counts = queue.counts();
    stdout.writeln("corpus_crawl: attempts=", attempts, " completed=", completed,
        " failed=", failed, " pagesAdmitted=", counts.pages,
        " queueComplete=", queue.isComplete());
    return 0;
}

void main(string[] args) { exit(run(args)); }
