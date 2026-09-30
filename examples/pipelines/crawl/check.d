/// Release-active actual-binary check for the `crawl` example against a
/// local, loopback-only fixture HTTP server (issue #509). Mirrors
/// `examples/pipelines/custom-composition/check.d`'s and
/// `examples/pipelines/clean-web-document/check.d`'s structure (validate the
/// corpus manifest and its required negative mutants, then exercise the real
/// shipping binary from a clean temporary directory), but this is the first
/// example whose target is a live server the checker itself starts and stops
/// rather than a static file on disk -- `crawl` takes URL seeds, and there is
/// no existing local-fixture-server pattern anywhere else in this repo's
/// examples/tests to reuse.
///
/// The fixture server is a minimal `std.socket`-based static responder,
/// deliberately modeled on `effects.crawl_orchestrator`'s own proven
/// `TestServer` unittest helper (same accept-thread-plus-per-connection-
/// thread shape, same Darwin/Linux-safe `stop()` idiom -- see that module's
/// doc comment on issue #353 for why a plain `listener.close()` alone does
/// not reliably unblock a blocked `accept()` on Linux). It is bound to
/// `127.0.0.1` ONLY, on an ephemeral port, and this file verifies that bind
/// address directly (not by assumption) before ever starting a crawl against
/// it, and again attempts a real connect to it from a non-loopback local
/// address to prove it is not externally reachable.
///
/// compile with ldc2 -O, then pass scrubbed. This checker imports
/// `effects.sqlite_frontier` directly (to reopen and inspect the durable
/// frontier database after each run), which pulls in the project's embedded
/// sqlite3 C sources the same way the main `scrubbed` target does -- so,
/// unlike a checker that only imports pure-D modules (e.g.
/// `examples/pipelines/custom-composition/check.d`), this one must also
/// link the object file `dub build` already produced at
/// `third_party/sqlite/sqlite3.o` (build `scrubbed` at least once first so
/// that object file exists):
///   ldc2 -O3 -release -preview=dip1000 -i -Isource \
///     -of=.dub/crawl-check examples/pipelines/crawl/check.d \
///     third_party/sqlite/sqlite3.o
///   .dub/crawl-check ./scrubbed
module crawl_check;

import core.atomic : atomicLoad, atomicStore;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : MonoTime, msecs;
import std.algorithm.searching : canFind, startsWith;
import std.algorithm.sorting : sort;
import std.array : array, replace;
import std.conv : to;
import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;
import std.file : SpanMode, dirEntries, exists, isFile, mkdirRecurse, read,
    readText, rmdirRecurse, tempDir, write;
import std.json : JSONValue, parseJSON;
import std.path : absolutePath, baseName, buildPath;
import std.process : execute;
import std.socket : AddressFamily, InternetAddress, Socket, SocketOption,
    SocketOptionLevel, SocketType, TcpSocket, UdpSocket;
import std.string : indexOf, split;
import std.uuid : randomUUID;

import domain.frontier_contract : FrontierLimits;
import domain.job_queue : JobQueue, QueueOpenCode;
import effects.sqlite_frontier : openSQLiteJobQueue, SQLiteJobQueue;

private enum provenanceAuthored =
    "Authored for scrubbed issue #509 by Shammah Chancellor.";
private enum provenanceGeneratedPrefix =
    "Generated from the authored issue #509";
private enum string crawlHelpSentence =
    "Fetch, discover links, and save raw HTML with a concurrent, resumable " ~
    "frontier. Fetch + discover + save raw only: no mojibake repair, no " ~
    "metadata/main-content/PII stages. Use 'clean-web-document' as a " ~
    "separate later pass over the raw output.";

/// The exact `FrontierLimits` `effects.crawl_cli.buildLimits` derives from
/// this example's recipe flags (`--max-pages 10 --max-pages-per-host 10
/// --max-depth 3 --concurrency 2`), plus its four fixed internal byte/count
/// caps. `openSQLiteJobQueue` requires an exactly matching `FrontierLimits`
/// to reopen an existing database (`effects.sqlite_frontier`'s own doc
/// comment: "an existing path must already be a compatible v1 frontier with
/// exactly matching limits") -- these constants are private to
/// `effects.crawl_cli` and so are intentionally duplicated here, not
/// imported; a drift between the two is caught immediately by this checker's
/// own `openSQLiteJobQueue` calls below failing to open the database at all.
private enum size_t recipeMaxPages = 10;
private enum size_t recipeMaxPagesPerHost = 10;
private enum size_t recipeMaxDepth = 3;
private enum size_t recipeConcurrency = 2;
private enum FrontierLimits recipeFrontierLimits = FrontierLimits(
    recipeMaxPages, recipeMaxPagesPerHost, recipeMaxDepth, recipeMaxPages,
    recipeConcurrency, 16 * 1024 * 1024, 8192, 4096, 1024 * 1024);

private void need(bool condition, string label) {
    if (!condition) throw new Exception("crawl check: " ~ label);
}

private string digest(string path) {
    return toHexString!(LetterCase.lower)(sha256Of(read(path))).idup;
}

private string digestBytes(const(ubyte)[] bytes) {
    return toHexString!(LetterCase.lower)(sha256Of(bytes)).idup;
}

private void expectRejected(string label, void delegate() mutation) {
    bool rejected;
    try mutation();
    catch (Exception) rejected = true;
    need(rejected, "negative mutant accepted: " ~ label);
}

private string[] filesBelow(string root) {
    string[] result;
    foreach (entry; dirEntries(root, SpanMode.shallow))
        if (entry.isFile) result ~= baseName(entry.name);
    result.sort;
    return result;
}

// ---------------------------------------------------------------------------
// Manifest validation.
// ---------------------------------------------------------------------------

private struct FixturePage {
    string path; // repository-relative source file path
    string sha256;
}

private void validateManifest(string repository, JSONValue manifest,
        out FixturePage[] sitePages) {
    need(manifest["schema"].str == "scrubbed.crawl-corpus.v1", "manifest schema");
    auto licensePath = manifest["licenseFile"].str;
    need(licensePath == "examples/corpus/crawl/LICENSE.txt" &&
        digest(buildPath(repository, licensePath)) ==
            "d05e83eb1213daac7371eee9bb40c8d06e767e37dc38f6f10b8f0b06d72708e0",
        "exact corpus license");

    auto claims = manifest["claims"];
    need(claims["crawlOnly"].boolean && claims["localOnly"].boolean &&
        !claims["mainContentExtraction"].boolean && !claims["piiDetection"].boolean &&
        !claims["trainingReady"].boolean,
        "crawl performs no main-content extraction, no PII detection, is not " ~
        "training-ready, and this example is local-only by construction");

    string[] declaredHtml;
    foreach (artifact; manifest["artifacts"].array) {
        auto path = artifact["path"].str;
        need((path.startsWith("examples/corpus/crawl/inputs/") ||
            path.startsWith("examples/corpus/crawl/expected/")) &&
            !path.canFind(".."), "artifact path escape: " ~ path);
        need(artifact["mediaType"].str.length != 0, "missing media type: " ~ path);
        need(artifact["provenance"].str == provenanceAuthored ||
            artifact["provenance"].str.startsWith(provenanceGeneratedPrefix),
            "missing attribution/provenance: " ~ path);
        need(artifact["license"].str == "MIT", "missing artifact license: " ~ path);
        need(digest(buildPath(repository, path)) == artifact["sha256"].str,
            "artifact hash drift: " ~ path);
        if (path.startsWith("examples/corpus/crawl/inputs/site/")) {
            sitePages ~= FixturePage(path, artifact["sha256"].str);
            declaredHtml ~= path;
        }
    }
    need(sitePages.length >= 3 && sitePages.length <= 5,
        "fixture site must be a small 3-5 page graph");

    auto recipes = manifest["recipes"].array;
    need(recipes.length == 3, "recipe count");
    need(recipes[0]["id"].str == "crawl-fixture-site" &&
        recipes[0]["expectedExit"].integer == 0, "stale first-run recipe");
    need(recipes[1]["id"].str == "crawl-fixture-site-second-run-noop" &&
        recipes[1]["expectedExit"].integer == 0, "stale second-run recipe");
    need(recipes[2]["id"].str == "clean-web-document-over-raw-crawl-output" &&
        recipes[2]["expectedExit"].integer == 0, "stale follow-on recipe");

    bool sawScopeFlag;
    foreach (token; recipes[0]["cliArguments"].array)
        if (token.str == "allowed-domain") sawScopeFlag = true;
    need(sawScopeFlag, "recipe must exercise --scope allowed-domain, as documented");
}

private void negativeMutants(string repository, string manifestText) {
    expectRejected("hash drift", {
        FixturePage[] pages;
        validateManifest(repository, parseJSON(manifestText.replace(
            "e87a1594725b66289bed07665c2948ac377e0c0b46dd381b23b4608cc0556559",
            "0000000000000000000000000000000000000000000000000000000000000000")),
            pages);
    });
    expectRejected("missing attribution", {
        FixturePage[] pages;
        validateManifest(repository, parseJSON(manifestText.replace(provenanceAuthored, "")),
            pages);
    });
    expectRejected("missing license", {
        FixturePage[] pages;
        validateManifest(repository, parseJSON(manifestText.replace(`"license": "MIT"`,
            `"license": ""`)), pages);
    });
    expectRejected("path escape", {
        FixturePage[] pages;
        validateManifest(repository, parseJSON(manifestText.replace(
            "examples/corpus/crawl/inputs/site/index.html", "../../../etc/passwd")), pages);
    });
    expectRejected("false main-content-extraction claim", {
        FixturePage[] pages;
        validateManifest(repository, parseJSON(manifestText.replace(
            `"mainContentExtraction": false`, `"mainContentExtraction": true`)), pages);
    });
    expectRejected("false training-ready claim", {
        FixturePage[] pages;
        validateManifest(repository, parseJSON(manifestText.replace(
            `"trainingReady": false`, `"trainingReady": true`)), pages);
    });
    expectRejected("scope recipe silently weakened", {
        FixturePage[] pages;
        validateManifest(repository, parseJSON(manifestText.replace(
            `"allowed-domain"`, `"one-hop-external"`)), pages);
    });
}

// ---------------------------------------------------------------------------
// Loopback-only fixture HTTP server.
//
// Deliberately modeled on `effects.crawl_orchestrator`'s own `TestServer`
// unittest helper: one accept thread, one handler thread per connection, a
// bound method delegate on a dedicated heap object per connection (never a
// delegate literal closing over locals -- see that module's own comment on
// why), and the same real-loopback-poke `stop()` that is required for a
// reliable unblock on Linux (issue #353) as well as Darwin.
// ---------------------------------------------------------------------------

private final class ConnectionHandler {
private:
    FixtureServer server_;
    Socket client_;

public:
    this(FixtureServer server, Socket client) {
        server_ = server;
        client_ = client;
    }

    void run() { server_.serveOne(client_); }
}

private final class FixtureServer {
private:
    TcpSocket listener_;
    Thread acceptThread_;
    shared bool stopping_;
    const(string[string]) pages_;
    size_t[string] hits_;
    Mutex hitsMutex_;

public:
    ushort port;
    string boundAddress;

    this(string[string] pages) {
        pages_ = pages;
        hitsMutex_ = new Mutex;
        listener_ = new TcpSocket(AddressFamily.INET);
        listener_.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
        // Bound to the loopback address ONLY -- never `0.0.0.0`/`INADDR_ANY`
        // and never a real external interface. `boundAddress` below is read
        // back from the live socket itself, not merely the literal passed
        // to `bind`, so a caller of this checker can see the real,
        // kernel-confirmed bind address rather than trusting this source
        // line alone.
        listener_.bind(new InternetAddress("127.0.0.1", 0));
        listener_.listen(64);
        auto local = cast(InternetAddress) listener_.localAddress;
        port = local.port;
        boundAddress = local.toAddrString();
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

    // See `effects.crawl_orchestrator.TestServer.stop` for why this pokes a
    // real loopback connection before closing the listener: on Linux, a
    // `listener.close()` from a different thread than the one blocked in
    // `accept()` does not reliably unblock that `accept()`, so the accept
    // thread's own `join()` below would hang forever without this poke.
    void stop() {
        atomicStore(stopping_, true);
        try {
            auto poke = new TcpSocket(AddressFamily.INET);
            scope(exit) poke.close();
            poke.connect(new InternetAddress("127.0.0.1", port));
        } catch (Exception ignored) {}
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
        client.send(cast(const(ubyte)[])("HTTP/1.1 200 OK\r\n" ~
            "Content-Type: text/html; charset=utf-8\r\n" ~
            "Content-Length: " ~ body.length.to!string ~
            "\r\nConnection: close\r\n\r\n" ~ body));
    }
}

/// Best-effort external-reachability probe. Determines a real, routable,
/// non-loopback local address via a UDP "connect" to a documentation-only
/// reserved address (`203.0.113.1`, RFC 5737 TEST-NET-3 -- guaranteed not a
/// real host; `connect()` on a `SOCK_DGRAM` socket never itself puts a
/// packet on the wire, it only performs a local kernel routing-table lookup
/// to pick a source address, exactly the same no-network-dependency trick
/// used to discover "my own LAN IP" without ever transmitting anything).
/// Returns `false` (skip) if no such address can be determined -- an
/// offline/sandboxed environment is not a reason to fail this checker.
private bool probedOutwardAddress(out string address) {
    try {
        auto udp = new Socket(AddressFamily.INET, SocketType.DGRAM);
        scope(exit) udp.close();
        udp.connect(new InternetAddress("203.0.113.1", 65330));
        auto local = cast(InternetAddress) udp.localAddress();
        address = local.toAddrString();
        return address.length != 0 && address != "0.0.0.0" && address != "127.0.0.1";
    } catch (Exception) {
        return false;
    }
}

/// Attempts a real TCP connect to `address:port`, bounded to `maxWaitMs`
/// wall-clock: an unanswered/dropped SYN (the expected outcome against a
/// loopback-only listener from a non-loopback source, when a host firewall
/// or the surrounding sandbox drops rather than actively refuses it) still
/// correctly reports "did not succeed" once the deadline passes, without
/// this checker itself hanging. A daemon thread is used so a stuck connect
/// attempt past the deadline is simply abandoned, never joined.
private bool externalConnectSucceeds(string address, ushort port, long maxWaitMs) {
    shared bool succeeded;
    shared bool finished;
    auto worker = new Thread({
        try {
            auto probe = new TcpSocket(AddressFamily.INET);
            scope(exit) probe.close();
            probe.connect(new InternetAddress(address, port));
            atomicStore(succeeded, true);
        } catch (Exception) {}
        atomicStore(finished, true);
    });
    worker.isDaemon = true;
    worker.start();
    auto deadline = MonoTime.currTime + maxWaitMs.msecs;
    while (!atomicLoad(finished) && MonoTime.currTime < deadline) Thread.sleep(10.msecs);
    return atomicLoad(succeeded);
}

private void verifyLoopbackOnly(FixtureServer server) {
    import std.stdio : writeln;

    need(server.boundAddress == "127.0.0.1",
        "fixture server must be bound to 127.0.0.1 exactly, not " ~ server.boundAddress ~
        " (never 0.0.0.0/INADDR_ANY and never a real external interface)");

    // A real loopback connect must succeed -- proof the server actually
    // serves real HTTP, not merely that it accepted a bind. Deliberately
    // requests a path outside the real fixture page set (never one of the
    // pages `pages` maps) so this pre-crawl probe cannot itself pollute the
    // real per-page hit counts the crawl-run checks below depend on; a real
    // 404 response is just as much proof of a genuine HTTP server as a 200.
    {
        auto probe = new TcpSocket(AddressFamily.INET);
        scope(exit) probe.close();
        probe.connect(new InternetAddress("127.0.0.1", server.port));
        probe.send(cast(const(ubyte)[])
            "GET /__loopback-serving-probe__ HTTP/1.1\r\nHost: x\r\n\r\n");
        ubyte[256] buffer;
        auto count = probe.receive(buffer[]);
        need(count > 0 && (cast(string) buffer[0 .. count]).startsWith("HTTP/1.1 404"),
            "fixture server did not serve a real HTTP response over loopback");
    }

    string outward;
    if (probedOutwardAddress(outward)) {
        auto reachable = externalConnectSucceeds(outward, server.port, 800);
        need(!reachable,
            "fixture server was reachable from a non-loopback local address (" ~
            outward ~ ") -- it must be loopback-only");
        writeln("crawl check: confirmed fixture server is unreachable from ", outward,
            " (loopback-only bind proven both by bound-address inspection and a real " ~
            "failed external connect attempt)");
    } else {
        writeln("crawl check: no non-loopback local address available in this " ~
            "environment to attempt an external connect against; relying on the " ~
            "direct bound-address inspection above (127.0.0.1, not 0.0.0.0)");
    }
}

// ---------------------------------------------------------------------------
// Real, release-active binary execution.
// ---------------------------------------------------------------------------

private struct Captured {
    int status;
    string output;
}

private Captured run(string[] command) {
    auto result = execute(command);
    return Captured(result.status, result.output);
}

private struct CrawlRunResult {
    string corpusDir;
    string origin;
}

private JSONValue[] readManifestLines(string path) {
    JSONValue[] result;
    foreach (line; readText(path).split("\n")) {
        if (line.length == 0) continue;
        result ~= parseJSON(line);
    }
    return result;
}

/// Strips a manifest entry's `url`/`discoveredFrom` field down to its
/// repository-independent, port-independent form: the URL path alone (e.g.
/// `http://127.0.0.1:54321/about.html` -> `/about.html`), or the literal
/// `"seed"` unchanged. The ephemeral port this checker's own fixture server
/// binds to is different on every run, so nothing about the port -- or the
/// rest of the origin -- can be pinned in a checked-in golden file; only the
/// path is stable across runs.
private string pathOnly(string url, string origin) {
    if (url == "seed") return url;
    need(url.startsWith(origin), "manifest URL not under the expected origin: " ~ url);
    return url[origin.length .. $];
}

private void runCrawlChecks(string repository, string executable) {
    auto sitePagesDir = buildPath(repository, "examples/corpus/crawl/inputs/site");
    string[string] pages;
    foreach (entry; dirEntries(sitePagesDir, SpanMode.shallow)) {
        if (!entry.isFile) continue;
        pages["/" ~ baseName(entry.name)] = cast(string) read(entry.name);
    }
    need(pages.length >= 3 && pages.length <= 5, "fixture site page count out of range");

    auto expectedPages = parseJSON(readText(buildPath(repository,
        "examples/corpus/crawl/expected/discovered-pages.json"))).array;
    need(expectedPages.length == pages.length,
        "expected discovered-page golden does not match the fixture site's own page count");

    auto server = new FixtureServer(pages);
    bool serverStopped;
    scope(exit) if (!serverStopped) server.stop();

    verifyLoopbackOnly(server);
    auto origin = "http://127.0.0.1:" ~ server.port.to!string;
    auto seed = origin ~ "/index.html";

    // `crawl --help` (the real shipping binary's argparse-generated help,
    // not a copy of the source string) must itself say crawl runs no
    // repair/metadata/main-content/PII stage -- the acceptance criterion is
    // "per the command's own help text", proven here against real captured
    // stdout, not source inspection.
    auto help = run([executable, "crawl", "--help"]);
    need(help.status == 0 && help.output.canFind(crawlHelpSentence),
        "crawl --help no longer documents its fetch+discover+save-raw-only scope");

    auto root = buildPath(tempDir, "scrubbed-crawl-" ~ randomUUID.toString);
    mkdirRecurse(root);
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto corpusDir = buildPath(root, "corpus");

    string[] recipeArgs(string corpus) {
        return [executable, "crawl", "--seed", seed, "--corpus-dir", corpus,
            "--max-pages", "10", "--max-pages-per-host", "10", "--max-depth", "3",
            "--concurrency", "2", "--min-host-delay-ms", "10", "--scope", "allowed-domain"];
    }

    // ---- First run: a genuine bounded crawl of the whole in-scope graph ---
    auto first = run(recipeArgs(corpusDir));
    need(first.status == 0, "first crawl run failed: " ~ first.output);
    need(first.output.canFind("completed=" ~ pages.length.to!string) &&
        first.output.canFind("failed=0"),
        "first crawl run did not report completing exactly the expected page count: " ~
        first.output);

    // Every discovered page was fetched exactly once, and the out-of-scope
    // external-looking link was never even attempted against this server
    // (it targets a different origin entirely, so this server would never
    // see it regardless of scope -- the real proof is that no manifest line
    // below ever names it).
    foreach (path; pages.keys) need(server.hitsFor(path) == 1,
        "page fetched a number of times other than exactly once: " ~ path);

    auto rawDir = buildPath(corpusDir, "raw");
    auto manifestPath = buildPath(corpusDir, "manifest.jsonl");
    need(exists(rawDir) && exists(manifestPath), "crawl did not produce raw/ and manifest.jsonl");

    // ---- raw/: exactly the expected content-addressed shard set ----------
    string[] expectedShards;
    foreach (expected; expectedPages) expectedShards ~= expected["sha256"].str;
    expectedShards.sort;
    need(filesBelow(rawDir).equal2(expectedShards),
        "raw/ shard file set differs from the pinned expected discovered-page hashes");
    foreach (path, content; pages) {
        auto shard = buildPath(rawDir, digestBytes(cast(const(ubyte)[]) content));
        need(exists(shard), "missing raw shard for " ~ path);
        // The defining proof crawl performs zero repair/cleaning of any
        // kind: the raw saved bytes are byte-for-byte identical to the
        // fixture site's own source bytes, entities and mojibake included.
        need(cast(const(ubyte)[]) read(shard) == cast(const(ubyte)[]) content,
            "raw shard bytes differ from the fixture's own source bytes for " ~ path);
    }
    need((cast(string) read(buildPath(rawDir, digestBytes(cast(const(ubyte)[]) pages["/about.html"]))))
            .canFind("FranÃ§ois"),
        "raw about.html shard must still carry the unrepaired mojibake byte pattern");

    // ---- manifest.jsonl: exactly the expected structural shape -----------
    auto manifestLines = readManifestLines(manifestPath);
    need(manifestLines.length == pages.length,
        "manifest.jsonl line count differs from the expected page count");
    JSONValue[string] byPath;
    foreach (entry; manifestLines) {
        auto path = pathOnly(entry["url"].str, origin);
        need((path in byPath) is null, "duplicate manifest entry for " ~ path);
        byPath[path] = entry;
        need(!entry["url"].str.canFind("external-example") &&
            !entry["discoveredFrom"].str.canFind("external-example"),
            "manifest references the deliberately out-of-scope external link");
    }
    foreach (expected; expectedPages) {
        auto path = expected["path"].str;
        auto found = path in byPath;
        need(found !is null, "expected discovered page missing from manifest: " ~ path);
        auto entry = *found;
        need(entry["depth"].integer == expected["depth"].integer,
            "wrong depth for " ~ path);
        need(pathOnly(entry["discoveredFrom"].str, origin) == expected["discoveredFrom"].str,
            "wrong discoveredFrom provenance for " ~ path);
        need(entry["httpStatus"].integer == 200, "non-200 status for " ~ path);
        need(entry["contentType"].str.canFind("html"), "wrong content type for " ~ path);
        need(entry["contentSha256"].str == expected["sha256"].str,
            "wrong content hash for " ~ path);
        need(pathOnly(entry["finalUrl"].str, origin) == path,
            "unexpected redirect/finalUrl mismatch for " ~ path);
        need(entry["shardPath"].str.canFind(expected["sha256"].str),
            "shardPath does not name the expected content-addressed digest for " ~ path);
    }

    // ---- frontier.sqlite3: durable state matches the manifest exactly ----
    auto dbPath = buildPath(corpusDir, "frontier.sqlite3");
    need(exists(dbPath), "crawl did not create the default frontier.sqlite3 (no --in-memory was passed)");
    {
        auto opened = openSQLiteJobQueue(dbPath, recipeFrontierLimits);
        need(opened.code == QueueOpenCode.opened,
            "could not reopen frontier.sqlite3 with the recipe's own FrontierLimits");
        auto counts = opened.queue.counts();
        need(counts.pages == pages.length && counts.completed == pages.length &&
            counts.retryableFailed == 0 && counts.permanentFailed == 0 &&
            counts.activeLeases == 0 && counts.queued == 0 && counts.deferred == 0,
            "frontier.sqlite3 durable counts do not match the expected fully-completed crawl");
        (cast(SQLiteJobQueue) opened.queue).close();
    }

    // ---- Resumability proof: idempotent re-run, not interrupt-and-resume -
    // See this example's README for why: reliably killing the real shipping
    // binary mid-fetch from this checker is high-effort and flaky compared
    // to `effects.crawl_orchestrator`'s own existing unit-level proof of
    // exactly that scenario (orphaned-lease recovery). What this checker
    // proves instead, end to end against the real binary: a second full run
    // against the identical --corpus-dir/--db is a correct no-op that
    // neither re-fetches anything already completed nor corrupts state.
    auto second = run(recipeArgs(corpusDir));
    need(second.status == 0, "second (idempotent) crawl run failed: " ~ second.output);
    need(second.output.canFind("attempts=0") && second.output.canFind("completed=0"),
        "second run against an already-drained corpus-dir re-attempted work: " ~ second.output);
    foreach (path; pages.keys) need(server.hitsFor(path) == 1,
        "second run re-fetched a page that was already completed: " ~ path);
    need(readManifestLines(manifestPath).length == pages.length,
        "second (idempotent) run appended new manifest lines");
    {
        auto reopened = openSQLiteJobQueue(dbPath, recipeFrontierLimits);
        need(reopened.code == QueueOpenCode.opened, "could not reopen frontier.sqlite3 after the second run");
        auto counts = reopened.queue.counts();
        need(counts.pages == pages.length && counts.completed == pages.length,
            "frontier.sqlite3 durable counts regressed after the idempotent second run");
        (cast(SQLiteJobQueue) reopened.queue).close();
    }

    // ---- Follow-on clean-web-document pass proves crawl itself cleans ----
    // nothing: the raw about.html shard (copied to a `.html`-suffixed path
    // so `clean-web-document` mirrors its input's own name, matching how a
    // real downstream user would run this) still carries the unrepaired
    // "FranÃ§ois" mojibake going in; the sealed clean-web-document/v1
    // preset (a completely separate command -- see
    // examples/pipelines/clean-web-document/, cross-referenced rather than
    // duplicated here) repairs it on the way out.
    auto renamedInput = buildPath(root, "about.html");
    write(renamedInput, pages["/about.html"]);
    auto cleanedOutput = buildPath(root, "about-cleaned.txt");
    auto cleaned = run([executable, "clean-web-document", "--input", renamedInput,
        "--output", cleanedOutput]);
    need(cleaned.status == 0, "follow-on clean-web-document pass failed: " ~ cleaned.output);
    need(!readText(cleanedOutput).canFind("FranÃ§ois"),
        "clean-web-document did not repair the mojibake that crawl deliberately left intact");
    need(readText(cleanedOutput).canFind("François"),
        "clean-web-document's repaired output does not contain the correctly-decoded name");

    // ---- Stop the fixture server and prove it actually released the port -
    server.stop();
    serverStopped = true;
    {
        // If the listening socket were still held open, a fresh bind to the
        // identical port would fail; succeeding here is direct proof the
        // kernel socket was really closed, not merely that `stop()`
        // returned without throwing.
        auto rebind = new TcpSocket(AddressFamily.INET);
        scope(exit) rebind.close();
        rebind.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
        rebind.bind(new InternetAddress("127.0.0.1", server.port));
        rebind.listen(1);
    }
}

private bool equal2(string[] a, string[] b) {
    if (a.length != b.length) return false;
    foreach (i; 0 .. a.length) if (a[i] != b[i]) return false;
    return true;
}

int main(string[] args) {
    need(args.length == 2 || args.length == 3,
        "usage: check <release executable> [repository root]");
    auto executable = absolutePath(args[1]);
    auto repository = absolutePath(args.length == 3 ? args[2] : ".");
    auto manifestPath = buildPath(repository, "examples/corpus/crawl/manifest.json");
    auto manifestText = readText(manifestPath);
    auto manifest = parseJSON(manifestText);
    FixturePage[] sitePages;
    validateManifest(repository, manifest, sitePages);
    negativeMutants(repository, manifestText);
    runCrawlChecks(repository, executable);
    import std.stdio : writeln;
    writeln("crawl check: manifest, mutants, loopback-only fixture server, " ~
        "exact discovered-page set/paths/depths/provenance, raw-bytes-unrepaired " ~
        "proof, idempotent second-run resumability, and the follow-on " ~
        "clean-web-document contrast all pass");
    return 0;
}
