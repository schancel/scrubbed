/// Hand-rolled option parsing and orchestration wiring for the top-level
/// `scrubbed crawl` command (issue #329), dispatched from `cli_commands.d`
/// before argparse ever sees `argv[2 .. $]` -- the same established pattern
/// `effects.metadata_route_cli` and `effects.error_cli` already use for a
/// genuinely new top-level command rather than a `run`/`repair`/`extract`
/// pipeline variant.
module effects.crawl_cli;

import domain.frontier_contract : AdmissionCode, CandidateInput, FrontierLimits;
import domain.job_queue : JobQueue, openInMemoryJobQueue, QueueOpenCode;
import effects.cli_option_parsing : nextOption;
import effects.crawl_orchestrator : CrawlBounds, crawlPolicyId,
    CrawlOrchestrator, CrawlSummary, ManifestWriter;
import effects.html_discovery : DiscoveryScopeKind;
import effects.sqlite_frontier : openSQLiteJobQueue;
import effects.web_url : WebUrl, resolveWebUrl;
import std.algorithm.iteration : filter, map;
import std.algorithm.searching : canFind;
import std.array : array;
import std.exception : enforce;
import std.file : exists, mkdirRecurse, readText;
import std.path : buildPath;
import std.stdio : stderr, writeln;
import std.string : splitLines, startsWith, strip;

// Owner-facing defaults; deliberately the same values
// `experiments/corpus_crawl/crawl.d` already established as reasonable for a
// bounded, polite local crawl.
private enum size_t defaultMaxPages = 200;
private enum size_t defaultMaxPagesPerHost = 50;
private enum size_t defaultMaxDepth = 3;
private enum size_t defaultConcurrency = 4;
private enum long defaultMinHostDelayMs = 3000;
private enum string defaultScope = "allowed-domain";

private enum size_t frontierStoredByteLimit = 16 * 1024 * 1024;
private enum size_t frontierProvenanceByteLimit = 8192;
private enum size_t frontierDiscoveriesPerFinishLimit = 4096;
private enum size_t frontierDiscoveryInputByteLimit = 1024 * 1024;

private struct Options {
    string[] seedFiles;
    string[] seedUrls;
    string corpusDir;
    string db;
    bool inMemory;
    bool hasCorpusDir;
    bool hasDb;
    size_t maxPages = defaultMaxPages;
    size_t maxPagesPerHost = defaultMaxPagesPerHost;
    size_t maxDepth = defaultMaxDepth;
    size_t concurrency = defaultConcurrency;
    long minHostDelayMs = defaultMinHostDelayMs;
    string scopeText = defaultScope;
    string[] allowedOrigins;
}

private bool parseSizeT(string value, ref size_t result) {
    if (!value.length) return false;
    size_t parsed;
    foreach (ch; value) {
        if (ch < '0' || ch > '9') return false;
        if (parsed > (size_t.max - (cast(size_t)(ch - '0'))) / 10) return false;
        parsed = parsed * 10 + cast(size_t)(ch - '0');
    }
    result = parsed;
    return true;
}

private bool parseNonNegativeLong(string value, ref long result) {
    if (!value.length) return false;
    long parsed;
    foreach (ch; value) {
        if (ch < '0' || ch > '9') return false;
        if (parsed > (long.max - (ch - '0')) / 10) return false;
        parsed = parsed * 10 + (ch - '0');
    }
    result = parsed;
    return true;
}

private bool parseOptions(const string[] args, ref Options o) {
    for (size_t i; i < args.length; ) {
        if (args[i] == "--in-memory") {
            o.inMemory = true;
            ++i;
            continue;
        }
        auto parsed = nextOption(args, i);
        if (!parsed.ok) return false;
        string flag = parsed.flag;
        string value = parsed.value;
        switch (flag) {
        case "--seeds":
            o.seedFiles ~= value; break;
        case "--seed":
            o.seedUrls ~= value; break;
        case "--corpus-dir":
            if (o.hasCorpusDir) return false;
            o.corpusDir = value; o.hasCorpusDir = true; break;
        case "--db":
            if (o.hasDb) return false;
            o.db = value; o.hasDb = true; break;
        case "--max-pages":
            if (!parseSizeT(value, o.maxPages) || o.maxPages == 0) return false;
            break;
        case "--max-pages-per-host":
            if (!parseSizeT(value, o.maxPagesPerHost) || o.maxPagesPerHost == 0) return false;
            break;
        case "--max-depth":
            if (!parseSizeT(value, o.maxDepth)) return false;
            break;
        case "--concurrency":
            if (!parseSizeT(value, o.concurrency) || o.concurrency == 0) return false;
            break;
        case "--min-host-delay-ms":
            if (!parseNonNegativeLong(value, o.minHostDelayMs)) return false;
            break;
        case "--scope":
            if (value != "allowed-domain" && value != "same-origin" &&
                value != "one-hop-external") return false;
            o.scopeText = value;
            break;
        case "--allowed-origin":
            o.allowedOrigins ~= value; break;
        default:
            return false;
        }
    }
    if (!o.hasCorpusDir) return false;
    if (o.seedFiles.length == 0 && o.seedUrls.length == 0) return false;
    if (o.inMemory && o.hasDb) return false;
    return true;
}

private WebUrl parseAbsoluteUrl(string url) {
    auto outcome = resolveWebUrl(url, url);
    enforce(outcome.isResolved, "crawl: unparsable URL: " ~ url);
    return outcome.value;
}

private WebUrl[] readSeedFile(string path) {
    enforce(exists(path), "crawl: seeds file not found: " ~ path);
    auto lines = readText(path).splitLines
        .map!strip
        .filter!(line => line.length != 0 && !line.startsWith("#"))
        .array;
    return lines.map!parseAbsoluteUrl.array;
}

private string[] distinctOrigins(const(WebUrl)[] urls) {
    string[] origins;
    foreach (url; urls) if (!origins.canFind(url.origin)) origins ~= url.origin;
    return origins;
}

private DiscoveryScopeKind scopeKindOf(string text) {
    final switch (text) {
    case "allowed-domain": return DiscoveryScopeKind.allowedDomain;
    case "same-origin": return DiscoveryScopeKind.sameOrigin;
    case "one-hop-external": return DiscoveryScopeKind.oneHopExternal;
    }
}

private FrontierLimits buildLimits(const ref Options o) {
    FrontierLimits limits;
    limits.maxPages = o.maxPages;
    limits.maxPagesPerHost = o.maxPagesPerHost;
    limits.maxDepth = o.maxDepth;
    limits.maxQueued = o.maxPages;
    limits.maxActiveLeases = o.concurrency;
    limits.maxStoredBytes = frontierStoredByteLimit;
    limits.maxProvenanceBytes = frontierProvenanceByteLimit;
    limits.maxDiscoveriesPerFinish = frontierDiscoveriesPerFinishLimit;
    limits.maxDiscoveryInputBytes = frontierDiscoveryInputByteLimit;
    return limits;
}

/// Seed admission tolerates exactly the outcomes a resumed or bounded run can
/// legitimately produce: `duplicate` (already admitted by a prior run of the
/// same command against the same database) and the finite capacity refusals
/// (a seed arriving after the frontier is already saturated is a real,
/// expected boundary condition, not a bug). Anything else -- a malformed
/// identity/host, or a sealed frontier this orchestrator never seals -- is a
/// genuine misuse and aborts the run.
private void admitSeed(JobQueue queue, WebUrl seed) {
    auto admission = queue.admit(CandidateInput(crawlPolicyId, seed.canonical,
        seed.origin, 0, "seed"));
    switch (admission.code) {
    case AdmissionCode.admittedQueued:
    case AdmissionCode.admittedDeferred:
    case AdmissionCode.duplicate:
        return;
    case AdmissionCode.refusedPageLimit:
    case AdmissionCode.refusedHostLimit:
    case AdmissionCode.refusedDepthLimit:
    case AdmissionCode.refusedProvenanceLimit:
    case AdmissionCode.refusedStoredByteLimit:
        stderr.writeln("scrubbed: crawl-seed-refused: ", seed.origin);
        return;
    default:
        throw new Exception("crawl: seed rejected");
    }
}

private int executeCrawl(Options o) {
    WebUrl[] seeds;
    foreach (path; o.seedFiles) seeds ~= readSeedFile(path);
    foreach (url; o.seedUrls) seeds ~= parseAbsoluteUrl(url);
    enforce(seeds.length != 0, "crawl: no seed URLs resolved");

    string[] coreOrigins = distinctOrigins(seeds);
    foreach (origin; o.allowedOrigins)
        if (!coreOrigins.canFind(origin)) coreOrigins ~= origin;

    mkdirRecurse(buildPath(o.corpusDir, "raw"));
    auto rawDir = buildPath(o.corpusDir, "raw");
    auto manifest = new ManifestWriter(buildPath(o.corpusDir, "manifest.jsonl"));

    auto limits = buildLimits(o);
    JobQueue queue;
    if (o.inMemory) {
        auto opened = openInMemoryJobQueue(limits);
        enforce(opened.code == QueueOpenCode.opened, "crawl: failed to open in-memory frontier");
        queue = opened.queue;
    } else {
        auto dbPath = o.hasDb ? o.db : buildPath(o.corpusDir, "frontier.sqlite3");
        auto opened = openSQLiteJobQueue(dbPath, limits);
        enforce(opened.code == QueueOpenCode.opened, "crawl: failed to open SQLite frontier");
        queue = opened.queue;
    }

    foreach (seed; seeds) admitSeed(queue, seed);

    CrawlBounds bounds;
    bounds.maxPages = o.maxPages;
    bounds.maxPagesPerHost = o.maxPagesPerHost;
    bounds.maxDepth = o.maxDepth;
    bounds.concurrency = o.concurrency;
    bounds.minHostDelayMs = o.minHostDelayMs;
    bounds.scopeKind = scopeKindOf(o.scopeText);
    bounds.allowedOrigins = coreOrigins;

    auto orchestrator = new CrawlOrchestrator(queue, rawDir, manifest, bounds);
    auto summary = orchestrator.run();

    writeln("scrubbed crawl: attempts=", summary.attempts,
        " completed=", summary.completed, " failed=", summary.failed,
        " pagesAdmitted=", summary.pagesAdmitted,
        " active=", summary.activeLeases,
        " queued=", summary.queued, " deferred=", summary.deferred,
        " backend=", o.inMemory ? "in-memory" : "sqlite");
    return 0;
}

/// Dispatch entry point called from `cli_commands.runCommands` for
/// `scrubbed crawl ...` (after `--help`/`-h` has already been intercepted
/// and routed through argparse's generated help for the `Crawl` stub).
int runCrawl(const string[] args) {
    Options o;
    if (!parseOptions(args, o)) {
        stderr.writeln("scrubbed: crawl-invalid-arguments");
        return 2;
    }
    try {
        return executeCrawl(o);
    } catch (Exception error) {
        stderr.writeln("scrubbed: ", error.msg);
        return 2;
    }
}

version (unittest) {
    import std.file : remove, rmdirRecurse, tempDir, write;
    import std.stdio : File;
    import std.typecons : tuple;
    import std.uuid : randomUUID;

    private string freshTempFile(string label) {
        return buildPath(tempDir(), "scrubbed-crawl-cli-test-" ~ label ~ "-" ~
            randomUUID.toString ~ ".txt");
    }

    private string freshTempDir(string label) {
        return buildPath(tempDir(), "scrubbed-crawl-cli-test-" ~ label ~ "-" ~
            randomUUID.toString);
    }

    /// Runs `runCrawl(args)` with the real `stderr` redirected to a temp
    /// file, and returns (exit code, captured stderr text) so a test can
    /// assert on the message that would actually reach a real CLI user --
    /// not just that the underlying exception's `.msg` happens to be
    /// right -- exactly like `cli_commands.d`'s own
    /// `runCommandsCapturingStderr` helper does for the rest of the CLI.
    private auto runCrawlCapturingStderr(string[] args) {
        auto capturePath = freshTempFile("stderr-capture");
        auto saved = stderr;
        scope(exit) {
            stderr = saved;
            if (exists(capturePath)) remove(capturePath);
        }
        stderr = File(capturePath, "w");
        auto exitCode = runCrawl(args);
        stderr.flush();
        stderr = saved;
        return tuple(exitCode, exists(capturePath) ? readText(capturePath) : "");
    }
}

// Issue #546: `runCrawl()` used to catch every validation exception
// generically and print only "scrubbed: crawl-refused" to stderr,
// discarding the real, specific `error.msg` -- for *every* crawl
// validation path, not just one. These two regressions prove the fix
// end-to-end (through the real `runCrawl()` entry point and its real
// `stderr` output, not just by inspecting a caught exception's `.msg` in
// isolation) across two independent validation paths, so the fix isn't
// narrowly special-cased to a single message.

unittest {
    // The #521/#544 --concurrency upper-bound path (the one that motivated
    // this ticket): must surface the specific "--concurrency must be at
    // most N (M cores detected)" message, not the generic token, while
    // still exiting 2 and never spawning a thread pool (that safety
    // property is `CrawlOrchestrator`'s constructor guard, unaffected by
    // this fix).
    auto corpusDir = freshTempDir("oversized-concurrency");
    scope(exit) if (exists(corpusDir)) rmdirRecurse(corpusDir);

    auto result = runCrawlCapturingStderr(["--seed", "http://127.0.0.1:1/x",
        "--concurrency", "999999999", "--corpus-dir", corpusDir, "--in-memory"]);
    assert(result[0] == 2, "an oversized --concurrency must still exit 2");
    assert(result[1].canFind("--concurrency must be at most "),
        "the specific --concurrency upper-bound message must reach the " ~
        "real stderr output, got: " ~ result[1]);
    assert(!result[1].canFind("crawl-refused"),
        "the generic 'crawl-refused' token must not shadow the specific " ~
        "message, got: " ~ result[1]);
}

unittest {
    // A second, independently pre-existing crawl validation path (a seeds
    // file that resolves to zero URLs, once comments/blanks are skipped)
    // must also surface its own specific message end-to-end -- proving
    // this fix covers crawl validation uniformly, not just the
    // --concurrency case above.
    auto corpusDir = freshTempDir("no-seeds-resolved");
    scope(exit) if (exists(corpusDir)) rmdirRecurse(corpusDir);
    auto seedsPath = freshTempFile("empty-seeds");
    write(seedsPath, "# nothing but comments\n\n   \n");
    scope(exit) remove(seedsPath);

    auto result = runCrawlCapturingStderr(["--seeds", seedsPath,
        "--corpus-dir", corpusDir, "--in-memory"]);
    assert(result[0] == 2, "zero resolved seed URLs must still exit 2");
    assert(result[1].canFind("crawl: no seed URLs resolved"),
        "the specific no-seed-URLs message must reach the real stderr " ~
        "output, got: " ~ result[1]);
    assert(!result[1].canFind("crawl-refused"),
        "the generic 'crawl-refused' token must not shadow the specific " ~
        "message, got: " ~ result[1]);
}

unittest {
    // A valid full flag set -- every flag `parseOptions` recognizes, mixing
    // the `--flag value` and `--flag=value` spellings the loop supports --
    // parses correctly into `Options`, and it defaults to the SQLite backend
    // (not `--in-memory`) whenever an explicit `--db` is given.
    string[] args = [
        "--corpus-dir", "/tmp/some-corpus",
        "--seed", "https://example.test/a",
        "--seed=https://example.test/b",
        "--db", "/tmp/some-corpus/frontier.sqlite3",
        "--max-pages", "500",
        "--max-pages-per-host", "10",
        "--max-depth", "2",
        "--concurrency", "8",
        "--min-host-delay-ms", "1500",
        "--scope", "one-hop-external",
        "--allowed-origin", "https://other.test",
    ];
    Options o;
    assert(parseOptions(args, o), "a fully-specified, valid flag set was rejected");
    assert(o.corpusDir == "/tmp/some-corpus");
    assert(o.hasCorpusDir);
    assert(o.seedUrls == ["https://example.test/a", "https://example.test/b"]);
    assert(o.seedFiles.length == 0);
    assert(o.db == "/tmp/some-corpus/frontier.sqlite3");
    assert(o.hasDb);
    assert(!o.inMemory);
    assert(o.maxPages == 500);
    assert(o.maxPagesPerHost == 10);
    assert(o.maxDepth == 2);
    assert(o.concurrency == 8);
    assert(o.minHostDelayMs == 1500);
    assert(o.scopeText == "one-hop-external");
    assert(o.allowedOrigins == ["https://other.test"]);
}

unittest {
    // `--in-memory` alone is exactly as valid as `--db` alone, but the
    // required `--corpus-dir` is genuinely required: omitting it fails
    // validation even though every other flag given is individually valid.
    string[] withCorpusDir = ["--corpus-dir", "/tmp/c", "--seed", "https://example.test/", "--in-memory"];
    Options ok;
    assert(parseOptions(withCorpusDir, ok));

    string[] missingCorpusDir = ["--seed", "https://example.test/", "--in-memory"];
    Options rejected;
    assert(!parseOptions(missingCorpusDir, rejected),
        "parseOptions accepted a flag set missing the required --corpus-dir");
}

unittest {
    // `--db` and `--in-memory` are mutually exclusive: each is independently
    // valid, but combining them must be rejected. Proven against both flag
    // orderings so this isn't an artifact of parse order.
    string[] dbOnly = ["--corpus-dir", "/tmp/c", "--seed", "https://example.test/", "--db", "/tmp/c/f.sqlite3"];
    Options dbOptions;
    assert(parseOptions(dbOnly, dbOptions), "--db alone was incorrectly rejected");

    string[] inMemoryOnly = ["--corpus-dir", "/tmp/c", "--seed", "https://example.test/", "--in-memory"];
    Options inMemoryOptions;
    assert(parseOptions(inMemoryOnly, inMemoryOptions), "--in-memory alone was incorrectly rejected");

    string[] both = ["--corpus-dir", "/tmp/c", "--seed", "https://example.test/",
        "--db", "/tmp/c/f.sqlite3", "--in-memory"];
    Options combined;
    assert(!parseOptions(both, combined),
        "parseOptions accepted mutually exclusive --db and --in-memory together");

    string[] reversed = ["--corpus-dir", "/tmp/c", "--seed", "https://example.test/",
        "--in-memory", "--db", "/tmp/c/f.sqlite3"];
    Options reversedCombined;
    assert(!parseOptions(reversed, reversedCombined),
        "parseOptions accepted --in-memory/--db together in reversed order");
}

unittest {
    // Numeric overflow guards: a decimal literal far beyond `size_t.max` (for
    // `--max-pages`) or `long.max` (for `--min-host-delay-ms`) must be
    // rejected outright rather than silently wrapping into some small or
    // negative bound. A merely large-but-representable value is still
    // accepted, so this isn't just rejecting any long digit string.
    enum string wayTooBig = "999999999999999999999999999999999999999999"; // far beyond size_t.max
    string[] overflowMaxPages = ["--corpus-dir", "/tmp/c", "--seed", "https://example.test/",
        "--max-pages", wayTooBig];
    Options rejectedMaxPages;
    assert(!parseOptions(overflowMaxPages, rejectedMaxPages),
        "an overflowing --max-pages value was not rejected");

    string[] overflowDelay = ["--corpus-dir", "/tmp/c", "--seed", "https://example.test/",
        "--min-host-delay-ms", wayTooBig];
    Options rejectedDelay;
    assert(!parseOptions(overflowDelay, rejectedDelay),
        "an overflowing --min-host-delay-ms value was not rejected");

    string[] largeButValid = ["--corpus-dir", "/tmp/c", "--seed", "https://example.test/",
        "--max-pages", "1000000"];
    Options acceptedMaxPages;
    assert(parseOptions(largeButValid, acceptedMaxPages) && acceptedMaxPages.maxPages == 1_000_000,
        "a large but representable --max-pages value was incorrectly rejected");

    // Zero is a distinct, separately-guarded rejection (see `--max-pages ==
    // 0` in `parseOptions`), not the same code path as overflow.
    string[] zeroMaxPages = ["--corpus-dir", "/tmp/c", "--seed", "https://example.test/",
        "--max-pages", "0"];
    Options rejectedZero;
    assert(!parseOptions(zeroMaxPages, rejectedZero),
        "--max-pages 0 was not rejected");
}

unittest {
    // Regression for issue #351: a NUL byte embedded in an option value is
    // rejected here, in both flag spellings, unchanged from before this
    // file's `parseOptions` switched to the shared
    // `effects.cli_option_parsing.nextOption` helper. This is the same
    // check `metadata_route_cli.d` also has and `error_cli.d` was, before
    // the fix, missing.
    string[] spaceForm = ["--corpus-dir", "/tmp/c", "--seed", "bad\0value"];
    Options rejectedSpaceForm;
    assert(!parseOptions(spaceForm, rejectedSpaceForm),
        "crawl_cli.d parseOptions accepted a NUL-byte-containing value (--flag value form)");

    string[] equalsForm = ["--corpus-dir", "/tmp/c", "--seed=bad\0value"];
    Options rejectedEqualsForm;
    assert(!parseOptions(equalsForm, rejectedEqualsForm),
        "crawl_cli.d parseOptions accepted a NUL-byte-containing value (--flag=value form)");
}

unittest {
    // Seed-file reading: comments and blank lines are skipped, surviving
    // lines are resolved as absolute URLs in file order, and a missing file
    // is a hard failure rather than an empty seed list.
    auto path = freshTempFile("seeds");
    write(path, "# a comment\n\nhttps://example.test/one\n   \nhttps://example.test/two\n# trailing\n");
    scope(exit) remove(path);

    auto seeds = readSeedFile(path);
    assert(seeds.length == 2, "comments/blank lines were not correctly skipped");
    assert(seeds[0].canonical == "https://example.test/one");
    assert(seeds[1].canonical == "https://example.test/two");

    bool threw;
    try readSeedFile(freshTempFile("does-not-exist"));
    catch (Exception) threw = true;
    assert(threw, "reading a nonexistent seeds file did not fail");
}
