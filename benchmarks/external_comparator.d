// Shared D-owned external-tool comparator result/runner. Build with
// ldc2 -O3 -release. Every declared case binds a fixture hash, an
// independently authored expectation hash, an executable snapshot/hash/
// version, the exact command/options, bounded raw output/hash, exit
// status/signal, a declared timeout, wall/CPU/RSS, and package acquisition
// order. Correctness gates run before timing; a missing, duplicate, or
// partial result fails closed. Comparator output is never treated as
// ground truth: every candidate output is checked against an independently
// authored expected file, not against the comparator's own output.
module external_comparator;

import core.stdc.stdlib : free;
import core.sys.posix.signal : kill, SIGKILL, SIGTERM;
import core.sys.posix.stdlib : realpath;
import core.sys.posix.sys.stat : chmod, S_IRUSR, S_IXUSR;
import core.sys.posix.sys.wait : WEXITSTATUS, WIFEXITED, WNOHANG, WTERMSIG,
    waitpid;
import core.sys.posix.unistd : _exit, dup2, execvp, fork, setpgid;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import domain.document : DocumentId, SourceLocator;
import domain.language_id : LanguageDetectionStatus, decodeLanguageIdentity;
import experiments.html_main_content.token_overlap : containsNormalized,
    mergeTokenCounts, normalized, scoreTokenOverlap, tokenCounts;
import std.algorithm.iteration : map;
import std.algorithm.searching : canFind, endsWith, startsWith;
import std.array : array;
import std.conv : to;
import std.digest : toHexString;
import std.digest.sha : sha256Of;
import std.file : copy, exists, mkdirRecurse, read, readText, remove,
    rmdirRecurse, tempDir, write;
import std.format : format;
import std.json : JSONValue, parseJSON;
import std.path : buildPath, dirName, dirSeparator, relativePath;
import std.process : execute;
import std.stdio : File, stderr, writeln;
import std.string : fromStringz, split, splitLines, strip, toStringz;
import std.uuid : randomUUID;

private void require(bool condition, string message) {
    if (!condition) throw new Exception(message);
}

private string digest(string path) {
    return toHexString(sha256Of(read(path))).to!string;
}

private string checked(string[] command) {
    auto result = execute(command);
    require(result.status == 0, command[0] ~ " exited " ~
        result.status.to!string ~ ": " ~ result.output);
    return result.output.strip;
}

private JSONValue strings(string[] values) {
    JSONValue[] result;
    foreach (value; values) result ~= JSONValue(value);
    return JSONValue(result);
}

// ---- Executable snapshots (behavioral model: benchmarks/pipeline.d's
// ExecutableSnapshot/snapshotExecutable/verifySnapshot for the dos2unix
// comparator). A snapshot is a private, read-only, hash-bound copy; a
// hash mismatch after the run means the original executable was mutated
// (or the snapshot copy was tampered with) mid-benchmark. ----

private struct ExecutableSnapshot {
    string path;
    string sha256;
}

private ExecutableSnapshot snapshotExecutable(string source, string root,
                                              string name) {
    auto target = buildPath(root, name);
    copy(source, target);
    require(chmod(target.toStringz, S_IRUSR | S_IXUSR) == 0,
        "cannot make executable snapshot read-only");
    return ExecutableSnapshot(target, digest(target));
}

private void verifySnapshot(ExecutableSnapshot snapshot) {
    require(digest(snapshot.path) == snapshot.sha256,
        "executable snapshot changed during the comparator run");
}

// ---- Pinned package acquisition (reuses cli_baseline.d's existing
// acquisition pattern exactly: uv venv + uv pip install --python
// <venv>/bin/python <pkg>==<exact version>, verified here via uv pip
// freeze at run time). ----

private struct PinnedPackage {
    string name;
    string exactVersion;
}

private string[string] parseFreeze(string output) {
    string[string] versions;
    foreach (line; output.splitLines) {
        auto row = line.strip;
        if (row.length == 0) continue;
        if (row.startsWith("Using Python ")) continue; // uv environment notice
        auto fields = row.split("==");
        if (fields.length != 2 || fields[0].length == 0 || fields[1].length == 0 ||
            fields[0] in versions)
            throw new Exception("unparseable or duplicate uv freeze row: " ~ row);
        versions[fields[0]] = fields[1];
    }
    return versions;
}

// Verifies every pinned package is present at its exact version (rejecting
// a prefix-collision version such as ftfy==6.3.10 when 6.3.1 is pinned, and
// rejecting duplicate freeze rows), then returns the *declared* acquisition
// order as a JSON array bound into the case, independent of whatever row
// order `uv pip freeze` happened to print.
private JSONValue verifyPinnedPackages(string freezeOutput,
                                       const PinnedPackage[] pinned) {
    require(pinned.length != 0, "no pinned packages declared for acquisition");
    auto versions = parseFreeze(freezeOutput);
    JSONValue[] order;
    foreach (pkg; pinned) {
        auto found = pkg.name in versions;
        require(found !is null && *found == pkg.exactVersion,
            "expected " ~ pkg.name ~ "==" ~ pkg.exactVersion ~ " exactly, observed " ~
            (found is null ? "missing" : pkg.name ~ "==" ~ *found));
        order ~= JSONValue(pkg.name ~ "==" ~ pkg.exactVersion);
    }
    return JSONValue(order);
}

// ---- Bounded, timed execution. Correctness (exact output, resource bound)
// is gated by the caller after this returns; this function only owns
// wall/CPU/RSS observation and declared-timeout enforcement. ----

private double metricValue(string report, string prefix) {
    foreach (line; report.splitLines) {
        auto trimmed = line.strip;
        if (trimmed.startsWith(prefix))
            return trimmed[prefix.length .. $].strip.to!double;
    }
    throw new Exception("missing time metric " ~ prefix ~ " in: " ~ report);
}

private JSONValue parseTimedMetrics(string output, bool darwin, int status) {
    JSONValue sample = JSONValue(["status": JSONValue(status)]);
    if (darwin) {
        sample["wall_seconds"] = metricValue(output, "real ");
        sample["user_seconds"] = metricValue(output, "user ");
        sample["system_seconds"] = metricValue(output, "sys ");
        foreach (line; output.splitLines)
            if (line.strip.endsWith("maximum resident set size")) {
                sample["peak_rss_bytes"] = line.strip.split(" ")[0].to!long;
                return sample;
            }
        throw new Exception("missing BSD peak RSS: " ~ output);
    }
    // GNU time reports wall as m:ss or h:mm:ss and RSS in KiB.
    foreach (line; output.splitLines) {
        auto parts = line.split(": ");
        if (parts.length < 2) continue;
        auto value = parts[$ - 1].strip;
        if (line.startsWith("\tUser time")) sample["user_seconds"] = value.to!double;
        if (line.startsWith("\tSystem time")) sample["system_seconds"] = value.to!double;
        if (line.startsWith("\tMaximum resident set size"))
            sample["peak_rss_bytes"] = value.to!long * 1024;
        if (line.startsWith("\tElapsed (wall clock) time")) {
            auto fields = value.split(":");
            double seconds_ = 0;
            foreach (field; fields) seconds_ = seconds_ * 60 + field.to!double;
            sample["wall_seconds"] = seconds_;
        }
    }
    foreach (key; ["wall_seconds", "user_seconds", "system_seconds", "peak_rss_bytes"])
        require((key in sample.object) !is null, "missing GNU time metric " ~ key);
    return sample;
}

// ---- Whole-process-group ownership for the timed sample child (behavioral
// model: experiments/document_adapters/run_limited.d and
// experiments/embedding_clusters/run_evaluation.d's startServer). The
// direct /usr/bin/time child is forked, made its own process-group leader
// via setpgid(0, 0) before exec, and its stdin/stdout/stderr are
// dup2'd from devNull/captureFile. A timeout signals the whole group
// (kill(-pid, ...)), not just the direct child, so a grandchild the
// wrapped command spawned is also terminated instead of orphaned. ----

private struct GroupWaitResult {
    bool terminated;
    int status;
}

private int exitStatusOf(int rawStatus) {
    return WIFEXITED(rawStatus) ? WEXITSTATUS(rawStatus) : -WTERMSIG(rawStatus);
}

private int spawnGroupLeader(string[] wrapper, File stdinFile, File stdoutFile,
                             File stderrFile) {
    auto pid = fork();
    require(pid >= 0, "cannot fork timed sample process");
    if (pid == 0) {
        if (setpgid(0, 0) != 0) _exit(126);
        if (dup2(stdinFile.fileno, 0) < 0) _exit(126);
        if (dup2(stdoutFile.fileno, 1) < 0) _exit(126);
        if (dup2(stderrFile.fileno, 2) < 0) _exit(126);
        auto argv = new const(char)*[wrapper.length + 1];
        foreach (index, argument; wrapper) argv[index] = argument.toStringz;
        argv[$ - 1] = null;
        execvp(argv[0], argv.ptr);
        _exit(127);
    }
    return pid;
}

private GroupWaitResult tryWaitGroupLeader(int pid) {
    int rawStatus;
    auto waited = waitpid(pid, &rawStatus, WNOHANG);
    if (waited == 0) return GroupWaitResult(false, 0);
    require(waited == pid, "waitpid failed for timed sample process");
    return GroupWaitResult(true, exitStatusOf(rawStatus));
}

private void reapGroupLeader(int pid) {
    int rawStatus;
    waitpid(pid, &rawStatus, 0);
}

// Runs `command` under BSD/GNU /usr/bin/time with a declared wall-clock
// timeout. The direct /usr/bin/time child is its own process-group leader;
// a process that outlives the timeout has its whole process group sent
// SIGTERM, then SIGKILL after a bounded grace period, and the run fails
// closed with an exception (no partial sample is ever returned for a
// timed-out run). A grandchild the wrapped command spawned is terminated
// along with it, not left running as an orphan.
private JSONValue runBoundedSample(string[] command, bool darwin,
                                   double timeoutSeconds) {
    require(timeoutSeconds > 0, "declared timeout must be positive");
    string[] wrapper = (darwin ? ["/usr/bin/time", "-l", "-p"] :
        ["/usr/bin/time", "-v"]) ~ command;
    auto capturePath = buildPath(tempDir,
        "scrubbed-external-comparator-sample-" ~ randomUUID.toString);
    auto devNull = File("/dev/null", "r");
    auto captureFile = File(capturePath, "wb");
    scope(exit) if (exists(capturePath)) remove(capturePath);
    auto pid = spawnGroupLeader(wrapper, devNull, captureFile, captureFile);
    auto deadline = MonoTime.currTime + msecs(cast(long)(timeoutSeconds * 1000));
    auto waitResult = tryWaitGroupLeader(pid);
    while (!waitResult.terminated && MonoTime.currTime < deadline) {
        Thread.sleep(msecs(10));
        waitResult = tryWaitGroupLeader(pid);
    }
    if (!waitResult.terminated) {
        require(kill(-pid, SIGTERM) == 0, "cannot signal timed-out process");
        auto grace = MonoTime.currTime + seconds(1);
        while (!waitResult.terminated && MonoTime.currTime < grace) {
            Thread.sleep(msecs(10));
            waitResult = tryWaitGroupLeader(pid);
        }
        if (!waitResult.terminated) {
            kill(-pid, SIGKILL);
            reapGroupLeader(pid);
            waitResult.terminated = true;
        }
        captureFile.close();
        throw new Exception("declared timeout of " ~ timeoutSeconds.to!string ~
            "s exceeded; process was terminated");
    }
    captureFile.close();
    return parseTimedMetrics(readText(capturePath), darwin, waitResult.status);
}

// ---- Publication scrubbing: a shareable report must be reproducible
// without publishing the current machine's checkout, account, or
// temporary-directory names. ----

private JSONValue publicCommand(string[] command, string scrubbedPath,
                                string ftfyPath, string root) {
    JSONValue[] safe;
    foreach (arg; command) {
        if (arg == scrubbedPath) safe ~= JSONValue("<scrubbed-binary>");
        else if (arg == ftfyPath) safe ~= JSONValue("<ftfy-cli>");
        else if (arg.startsWith(root ~ dirSeparator))
            safe ~= JSONValue("<fixture-root>/" ~ relativePath(arg, root));
        else safe ~= JSONValue(arg);
    }
    return JSONValue(safe);
}

// Generic version of publicCommand() above for cases with more than two
// private executables/paths to redact (the mojibake/scrubbed-vs-ftfy case
// above keeps using its own original publicCommand() unchanged). Any
// argument exactly matching a key in `exactReplacements` becomes that key's
// replacement string; any argument prefixed with `root` becomes
// "<fixture-root>/..."; everything else (flag names, literal shell script
// text) publishes unchanged.
private JSONValue publicCommandGeneric(string[] command,
                                       const string[string] exactReplacements,
                                       string root) {
    JSONValue[] safe;
    foreach (arg; command) {
        if (auto replacement = arg in exactReplacements) safe ~= JSONValue(*replacement);
        else if (arg.startsWith(root ~ dirSeparator))
            safe ~= JSONValue("<fixture-root>/" ~ relativePath(arg, root));
        else safe ~= JSONValue(arg);
    }
    return JSONValue(safe);
}

// ---- The migrated ftfy/mojibake case. Fixture and independently authored
// expectation bytes are generated deterministically (no third-party bytes
// are redistributed) and pinned by SHA-256 in source, exactly as
// cli_baseline.d's "mojibake" case did; a generator change that silently
// altered either string is caught here as fixture/expectation drift before
// any subprocess runs. ----

private enum mojibakeFixtureSha256 =
    "FBB0ED284337887CD1EE5419735AC30C1189DBE94609A5119916A2906EE5889B";
private enum mojibakeExpectedSha256 =
    "14A9EDC0944EF516E12E1CE8ABBF3D78CCF41D48CDDD1F2A8AD13173363F7DCA";

private void generateMojibakeFixture(string fixturePath, string expectedPath) {
    string damaged, clean;
    foreach (i; 0 .. 4096) {
        damaged ~= "CafÃ© at noon; the sign said rÃ©sumÃ©.\n";
        clean ~= "Café at noon; the sign said résumé.\n";
    }
    write(fixturePath, damaged);
    write(expectedPath, clean);
    require(digest(fixturePath) == mojibakeFixtureSha256,
        "mojibake fixture drift: generated bytes no longer match the pinned fixture hash");
    require(digest(expectedPath) == mojibakeExpectedSha256,
        "independently authored expectation drift: generated bytes no longer match the pinned expected hash");
}

// Runs the scrubbed candidate and the pinned ftfy comparator on the same
// fixture in A/B/A/B order (behavioral model: pipeline.d's compareDos2unix),
// gating correctness (exact output, resource bound, exit status/signal)
// before any sample is retained.
private JSONValue compareFtfyMojibake(string scrubbedBinary, string ftfyBinary,
                                      string pythonBinary, string root,
                                      bool darwin, double timeoutSeconds,
                                      long maxRssBytes) {
    auto fixture = buildPath(root, "mojibake.txt");
    auto expected = buildPath(root, "repaired.txt");
    generateMojibakeFixture(fixture, expected);

    auto scrubbedSnapshot = snapshotExecutable(scrubbedBinary, root, "scrubbed-snapshot");
    auto ftfySnapshot = snapshotExecutable(ftfyBinary, root, "ftfy-snapshot");

    string ftfyVersion;
    foreach (line; checked([ftfySnapshot.path, "--help"]).splitLines)
        if (line.startsWith("ftfy (fixes text for you)")) ftfyVersion = line;
    require(ftfyVersion.length != 0, "ftfy CLI version was not discoverable");

    auto acquisitionOrder = verifyPinnedPackages(
        checked(["uv", "pip", "freeze", "--python", pythonBinary]),
        [PinnedPackage("ftfy", "6.3.1"), PinnedPackage("wcwidth", "0.8.4")]);

    auto outputPath = buildPath(root, "out.txt");
    JSONValue[] samples;
    string[] scrubbedCommand = [scrubbedSnapshot.path, "--input", fixture,
        "--output", outputPath, "--filters", "fix-mojibake", "--threads", "1"];
    string[] ftfyCommand = [ftfySnapshot.path, "--preserve-entities", "-n",
        "none", "-o", outputPath, fixture];
    foreach (index; 0 .. 4) {
        bool useScrubbed = index % 2 == 0;
        auto tool = useScrubbed ? "scrubbed" : "ftfy";
        if (exists(outputPath)) remove(outputPath);
        auto sample = runBoundedSample(useScrubbed ? scrubbedCommand : ftfyCommand,
            darwin, timeoutSeconds);
        require(sample["status"].integer == 0,
            tool ~ " exited nonzero or was terminated by a signal: status=" ~
            sample["status"].integer.to!string);
        auto peakRss = sample["peak_rss_bytes"].integer;
        require(peakRss <= maxRssBytes,
            tool ~ " exceeded the declared resource bound: " ~ peakRss.to!string ~
            " > " ~ maxRssBytes.to!string ~ " bytes");
        require(exists(outputPath) && digest(outputPath) == mojibakeExpectedSha256,
            tool ~ " failed the exact-output quality gate");
        sample["tool"] = tool;
        sample["output_sha256"] = digest(outputPath);
        sample["exact_output"] = true;
        samples ~= sample;
    }
    verifySnapshot(scrubbedSnapshot);
    verifySnapshot(ftfySnapshot);
    require(samples.length != 0, "zero samples retained for mojibake/scrubbed-vs-ftfy");
    require(samples.length == 4 && samples[0]["tool"].str == "scrubbed" &&
        samples[1]["tool"].str == "ftfy" && samples[2]["tool"].str == "scrubbed" &&
        samples[3]["tool"].str == "ftfy",
        "mojibake comparator lost its A/B/A/B interleave order");

    JSONValue result = JSONValue(["name": JSONValue("mojibake/scrubbed-vs-ftfy")]);
    result["fixture_sha256"] = mojibakeFixtureSha256;
    result["expected_sha256"] = mojibakeExpectedSha256;
    result["scrubbed_binary_sha256"] = scrubbedSnapshot.sha256;
    result["ftfy_binary_sha256"] = ftfySnapshot.sha256;
    result["ftfy_version"] = ftfyVersion;
    result["python_packages_acquisition_order"] = acquisitionOrder;
    result["scrubbed_command"] = publicCommand(scrubbedCommand,
        scrubbedSnapshot.path, ftfySnapshot.path, root);
    result["ftfy_command"] = publicCommand(ftfyCommand,
        scrubbedSnapshot.path, ftfySnapshot.path, root);
    result["timeout_seconds"] = timeoutSeconds;
    result["max_rss_bytes"] = maxRssBytes;
    result["samples"] = JSONValue(samples);
    return result;
}

// ---- The main-content/scrubbed-vs-trafilatura case (issue #229's next-slice
// contract). Unlike the mojibake case above, correctness here is scored by
// precision/recall against held-out real-page ground truth (issue #26's own
// word-level tokenized-overlap metric and its own pinned 20-URL trafilatura
// held-out corpus, reused via `fetch_held_out.sh --emit-corpus-dir`, not a
// second parallel implementation), not exact-byte equality. Precision/recall
// are REPORTED, not gated; what still fails closed is corpus-acquisition
// failure, either tool's own resource/timeout/genuine-failure bound, or a
// non-reproducible output between a tool's own two timed samples. ----

private enum expectedHeldOutFixtureCount = 20;

// `scrubbed run --input <dir>` (the generic `--stage id=IMPLEMENTATION`
// composition-token path; `extract --format` is hardcoded to two other
// stage names and cannot reach `html-main-content`) treats every file under
// its input directory as a document to process, so the held-out corpus's own
// `gold.json` must never sit inside the directory passed as --input. This
// copies out just the resolved fixtures' HTML into a clean directory first.
private string[] materializeHtmlOnlyCorpus(string corpusDir, string htmlInputDir,
                                           const JSONValue[] goldFixtures) {
    mkdirRecurse(htmlInputDir);
    string[] htmlFiles;
    foreach (fixture; goldFixtures) {
        auto name = fixture["htmlFile"].str;
        copy(buildPath(corpusDir, name), buildPath(htmlInputDir, name));
        htmlFiles ~= name;
    }
    return htmlFiles;
}

// Combines the existence and content of a fixed, ordered file list into one
// SHA-256 signature, so two independent full-corpus runs of the same tool
// can be compared for byte-identical reproducibility without a recursive
// directory diff. A file that does not exist (an abstention, or trafilatura
// declining to extract anything) is folded into the signature as a distinct
// "missing" marker rather than being skipped, so a run that silently drops a
// fixture cannot appear identical to one that legitimately abstained on it.
private string directorySignature(string dir, const string[] filenames) {
    string combined;
    foreach (name; filenames) {
        auto path = buildPath(dir, name);
        combined ~= exists(path) ? "F:" ~ digest(path) ~ "\n" : "M\n";
    }
    return toHexString(sha256Of(cast(const(ubyte)[]) combined)).to!string;
}

private string outputTextOrEmpty(string path) {
    return exists(path) ? readText(path) : "";
}

private struct FixtureScoreEntry {
    bool produced;
    double precision = 0.0;
    double recall = 0.0;
    size_t withoutLeaks;
}

// Scores one tool's output for one fixture against that fixture's gold
// "with"/"without" probe phrases, reusing issue #26's own token_overlap
// module (the same normalized()/tokenCounts()/scoreTokenOverlap() used by
// fetch_held_out.sh's own driver) rather than a second implementation of the
// metric. An empty (or missing) output file is treated as an abstention:
// both tools' shell/CLI wrappers always create their declared output path,
// but leave it empty when nothing was extracted.
private FixtureScoreEntry scoreOneFixture(string outputText, JSONValue goldFixture) {
    FixtureScoreEntry result;
    if (outputText.length == 0) return result;
    result.produced = true;
    auto folded = normalized(outputText);
    auto extractedTokens = tokenCounts(folded);
    int[string] goldTokens;
    foreach (chunk; goldFixture["with"].array)
        mergeTokenCounts(goldTokens, tokenCounts(normalized(chunk.str)));
    auto overlap = scoreTokenOverlap(extractedTokens, goldTokens);
    result.precision = overlap.precision;
    result.recall = overlap.recall;
    foreach (chunk; goldFixture["without"].array)
        if (containsNormalized(folded, chunk.str)) ++result.withoutLeaks;
    return result;
}

private struct ToolScoreSummary {
    size_t extractedCount;
    size_t abstainedCount;
    double meanPrecision = 0.0;
    double meanRecall = 0.0;
    size_t withoutLeakTotal;
    FixtureScoreEntry[] perFixture;
}

// Precision/recall are computed once per tool -- from a single canonical
// output directory, proven interchangeable with that tool's other timed
// sample by the reproducibility check above -- never recomputed per sample.
private ToolScoreSummary scoreToolAgainstGold(const string[] outputPaths,
                                              const JSONValue[] goldFixtures) {
    require(outputPaths.length == goldFixtures.length,
        "output path count must match gold fixture count");
    ToolScoreSummary summary;
    double precisionSum = 0, recallSum = 0;
    foreach (i, fixture; goldFixtures) {
        auto scored = scoreOneFixture(outputTextOrEmpty(outputPaths[i]), fixture);
        summary.perFixture ~= scored;
        if (scored.produced) {
            ++summary.extractedCount;
            precisionSum += scored.precision;
            recallSum += scored.recall;
            summary.withoutLeakTotal += scored.withoutLeaks;
        } else ++summary.abstainedCount;
    }
    summary.meanPrecision = summary.extractedCount ? precisionSum / summary.extractedCount : 0.0;
    summary.meanRecall = summary.extractedCount ? recallSum / summary.extractedCount : 0.0;
    return summary;
}

private JSONValue toolSummaryJson(const ref ToolScoreSummary summary) {
    return JSONValue([
        "extractedCount": JSONValue(summary.extractedCount),
        "abstainedCount": JSONValue(summary.abstainedCount),
        "meanPrecision": JSONValue(summary.meanPrecision),
        "meanRecall": JSONValue(summary.meanRecall),
        "withoutLeakTotal": JSONValue(summary.withoutLeakTotal),
    ]);
}

private JSONValue fixtureEntryJson(const ref FixtureScoreEntry entry) {
    if (!entry.produced) return JSONValue(["status": JSONValue("abstained")]);
    return JSONValue([
        "status": JSONValue("produced"),
        "precision": JSONValue(entry.precision),
        "recall": JSONValue(entry.recall),
        "withoutLeaks": JSONValue(entry.withoutLeaks),
    ]);
}

// One shell-loop sample = one full pass over all held-out fixtures, wrapping
// single-file invocations (the fallback shape the accepted contract names
// for when trafilatura's batch-directory convention doesn't hold for the
// pinned version -- confirmed necessary here: `trafilatura --input-dir
// --output-dir --keep-dirs` on the pinned 2.2.0 silently drops every file in
// this version's own CLI, a real, verified upstream bug, not an assumption;
// see this ticket's handoff for the captured `--help` output and the exact
// verification). Each fixture is fed on trafilatura's stdin and its
// extracted text captured from trafilatura's stdout to its own output file
// -- the one single-file invocation shape this pinned version actually
// supports (`-i`/`--input-file` is batch URL-list mode, not single-file HTML
// extraction). `/usr/bin/time` (added by the caller via runBoundedSample)
// wraps this whole shell process, so one timed sample still times one full
// pass over every fixture, matching the mojibake case's own methodology.
private string trafilaturaBatchScript() {
    return "traf=\"$1\"; outdir=\"$2\"; shift 2; status=0; " ~
        "for f in \"$@\"; do base=$(basename \"$f\"); " ~
        "\"$traf\" --output-format txt < \"$f\" > \"$outdir/${base%.html}.txt\" " ~
        "|| status=$?; done; exit \"$status\"";
}

private JSONValue compareMainContentTrafilatura(string scrubbedBinary,
        string trafilaturaBinary, string pythonBinary, string root,
        bool darwin, double timeoutSeconds, long maxRssBytes) {
    auto scrubbedSnapshot = snapshotExecutable(scrubbedBinary, root, "scrubbed-mc-snapshot");
    auto trafilaturaSnapshot = snapshotExecutable(trafilaturaBinary, root, "trafilatura-snapshot");

    auto acquisitionOrder = verifyPinnedPackages(
        checked(["uv", "pip", "freeze", "--python", pythonBinary]),
        [PinnedPackage("trafilatura", "2.2.0")]);

    auto trafilaturaVersion = checked([trafilaturaSnapshot.path, "--version"]);
    require(trafilaturaVersion.startsWith("Trafilatura "),
        "trafilatura CLI version was not discoverable via --version: " ~ trafilaturaVersion);

    // Corpus acquisition: reuses issue #26's own pinned held-out corpus and
    // scoring module unmodified via the additive `--emit-corpus-dir` flag.
    // A nonzero exit here (network failure, resolution failure, a checked-
    // out commit that doesn't match the pin) fails the whole case closed.
    auto corpusDir = buildPath(root, "held-out-corpus");
    auto heldOutReportPath = buildPath(root, "held-out-report.json");
    checked(["experiments/html_main_content/fetch_held_out.sh",
        "--emit-corpus-dir", corpusDir, heldOutReportPath]);

    auto gold = parseJSON(readText(buildPath(corpusDir, "gold.json")));
    auto goldFixtures = gold["fixtures"].array;
    require(goldFixtures.length == expectedHeldOutFixtureCount,
        "held-out corpus did not resolve all " ~
        expectedHeldOutFixtureCount.to!string ~ " pinned fixtures: got " ~
        goldFixtures.length.to!string);

    auto htmlInputDir = buildPath(root, "held-out-html-only");
    auto htmlFiles = materializeHtmlOnlyCorpus(corpusDir, htmlInputDir, goldFixtures);
    string[] scrubbedOutputNames = htmlFiles; // scrubbed mirrors the input file name exactly.
    string[] trafilaturaOutputNames;
    foreach (name; htmlFiles) trafilaturaOutputNames ~= name[0 .. $ - 5] ~ ".txt"; // strip ".html"
    auto trafilaturaInputPaths = htmlFiles.map!(name => buildPath(htmlInputDir, name)).array;

    JSONValue[] samples;
    string[2] scrubbedOutputDirs, trafilaturaOutputDirs;
    size_t scrubbedSampleIndex, trafilaturaSampleIndex;
    string[] scrubbedCommand, trafilaturaCommand;

    foreach (index; 0 .. 4) {
        bool useScrubbed = index % 2 == 0;
        auto tool = useScrubbed ? "scrubbed" : "trafilatura";
        JSONValue sample;
        if (useScrubbed) {
            auto outDir = buildPath(root, "scrubbed-out-" ~ index.to!string);
            scrubbedCommand = [scrubbedSnapshot.path, "--input", htmlInputDir,
                "--output", outDir, "--stage", "content=html-main-content",
                "--threads", "1"];
            sample = runBoundedSample(scrubbedCommand, darwin, timeoutSeconds);
            auto status = sample["status"].integer;
            // `scrubbed run`'s process exit code is 1 whenever ANY input is
            // quarantined, which conflates a genuine per-file crash with an
            // entirely expected, already-documented content-driven
            // abstention (this real corpus reproducibly abstains on some
            // fixtures -- see docs/html-main-content.md). Status 0 or 1 are
            // both a clean invocation; anything else (a bad-argument exit, a
            // signal-terminated crash) is not. The reproducibility check
            // below is what actually catches a genuine nondeterministic
            // failure: unlike content-driven abstention, a real crash/race
            // would not reliably reproduce byte-identical output twice.
            require(status == 0 || status == 1,
                "scrubbed exited with a status that is neither a clean run nor an " ~
                "expected content-driven quarantine: " ~ status.to!string);
            scrubbedOutputDirs[scrubbedSampleIndex++] = outDir;
        } else {
            auto outDir = buildPath(root, "trafilatura-out-" ~ index.to!string);
            mkdirRecurse(outDir);
            trafilaturaCommand = ["/bin/sh", "-c", trafilaturaBatchScript(), "sh",
                trafilaturaSnapshot.path, outDir] ~ trafilaturaInputPaths;
            sample = runBoundedSample(trafilaturaCommand, darwin, timeoutSeconds);
            require(sample["status"].integer == 0,
                "trafilatura batch invocation exited nonzero: " ~
                sample["status"].integer.to!string);
            trafilaturaOutputDirs[trafilaturaSampleIndex++] = outDir;
        }
        auto peakRss = sample["peak_rss_bytes"].integer;
        require(peakRss <= maxRssBytes,
            tool ~ " exceeded the declared resource bound: " ~ peakRss.to!string ~
            " > " ~ maxRssBytes.to!string ~ " bytes");
        sample["tool"] = tool;
        samples ~= sample;
    }
    verifySnapshot(scrubbedSnapshot);
    verifySnapshot(trafilaturaSnapshot);
    require(samples.length == 4 && samples[0]["tool"].str == "scrubbed" &&
        samples[1]["tool"].str == "trafilatura" && samples[2]["tool"].str == "scrubbed" &&
        samples[3]["tool"].str == "trafilatura",
        "main-content comparator lost its A/B/A/B interleave order");

    auto scrubbedSignatureA = directorySignature(scrubbedOutputDirs[0], scrubbedOutputNames);
    auto scrubbedSignatureB = directorySignature(scrubbedOutputDirs[1], scrubbedOutputNames);
    require(scrubbedSignatureA == scrubbedSignatureB,
        "scrubbed produced non-reproducible output between its own two timed samples");
    auto trafilaturaSignatureA = directorySignature(trafilaturaOutputDirs[0], trafilaturaOutputNames);
    auto trafilaturaSignatureB = directorySignature(trafilaturaOutputDirs[1], trafilaturaOutputNames);
    require(trafilaturaSignatureA == trafilaturaSignatureB,
        "trafilatura produced non-reproducible output between its own two timed samples");

    string[] scrubbedOutputPaths, trafilaturaOutputPaths;
    foreach (name; scrubbedOutputNames) scrubbedOutputPaths ~= buildPath(scrubbedOutputDirs[0], name);
    foreach (name; trafilaturaOutputNames) trafilaturaOutputPaths ~= buildPath(trafilaturaOutputDirs[0], name);
    auto scrubbedScore = scoreToolAgainstGold(scrubbedOutputPaths, goldFixtures);
    auto trafilaturaScore = scoreToolAgainstGold(trafilaturaOutputPaths, goldFixtures);

    JSONValue[] combinedFixtures;
    foreach (i; 0 .. goldFixtures.length) {
        JSONValue entry = JSONValue(["id": JSONValue(format("%02d", i + 1))]);
        entry["scrubbed"] = fixtureEntryJson(scrubbedScore.perFixture[i]);
        entry["trafilatura"] = fixtureEntryJson(trafilaturaScore.perFixture[i]);
        combinedFixtures ~= entry;
    }
    JSONValue scoring = JSONValue(["gold_fixture_count": JSONValue(goldFixtures.length)]);
    scoring["scrubbed"] = toolSummaryJson(scrubbedScore);
    scoring["trafilatura"] = toolSummaryJson(trafilaturaScore);
    scoring["fixtures"] = JSONValue(combinedFixtures);

    JSONValue result = JSONValue(["name": JSONValue("main-content/scrubbed-vs-trafilatura")]);
    result["scrubbed_binary_sha256"] = scrubbedSnapshot.sha256;
    result["trafilatura_binary_sha256"] = trafilaturaSnapshot.sha256;
    result["trafilatura_version"] = trafilaturaVersion;
    result["held_out_corpus_commit"] = gold["trafilaturaCommit"].str;
    result["held_out_fixture_count"] = goldFixtures.length;
    result["python_packages_acquisition_order"] = acquisitionOrder;
    result["scrubbed_command"] = publicCommandGeneric(scrubbedCommand,
        [scrubbedSnapshot.path: "<scrubbed-binary>"], root);
    result["trafilatura_command"] = publicCommandGeneric(trafilaturaCommand,
        [trafilaturaSnapshot.path: "<trafilatura-cli>"], root);
    result["timeout_seconds"] = timeoutSeconds;
    result["max_rss_bytes"] = maxRssBytes;
    result["samples"] = JSONValue(samples);
    result["reproducibility"] = JSONValue([
        "scrubbed": JSONValue(true),
        "trafilatura": JSONValue(true),
    ]);
    result["scoring"] = scoring;
    return result;
}

// ---- The language-id/scrubbed-vs-langdetect case (issue #301's accepted
// next-slice contract). Like the trafilatura case above (and unlike
// mojibake's exact-byte gate), correctness here is scored by classification
// agreement against the fixture's own authored language label -- for BOTH
// tools symmetrically, never treating either tool's own output as the
// other's ground truth. Strictly scoped to the 11 original Latin-script
// languages `domain.language_id` shipped before issue #299's six-language
// Devanagari-family expansion (en/es/fr/de/pt/it/nl/tr/vi/pl/id); #299's
// added languages (hi/bn/ta/te/gu/pa) are out of scope here in both
// directions. Reuses `domain.language_id`'s own held-out fixture set
// (`experiments/language_id/fixtures/heldout/<lang>.txt`, disjoint from its
// seed corpus) unmodified -- no new fixtures are authored. ----

private enum originalLanguageIdLanguages = ["en", "es", "fr", "de", "pt", "it",
    "nl", "tr", "vi", "pl", "id"];

// langdetect==1.0.9 is a pure-Python library with no CLI of its own, so a
// thin driver script substitutes for one -- mirroring this file's own
// precedent (the trafilatura case's shell wrapper above) for authoring a
// pinned wrapper when the pinned tool has no suitable CLI. Its checked-in
// bytes are pinned by SHA-256 here, in the same fixture/expectation-drift
// idiom as `mojibakeFixtureSha256` above: a silently edited driver is caught
// before any subprocess runs.
private enum langdetectDriverPath = "benchmarks/langdetect_driver.py";
private enum langdetectDriverSha256 =
    "D6080AA5C1E1A83081EC83438570DD7C744719F1D2E25A6ACFC0F3B1B8575E8E";

// `scrubbed run`'s own `resolveExistingPrefix` (cli.d) calls POSIX
// `realpath` on an existing `--input` path before deriving that document's
// `DocumentId`; this reproduces that exact resolution so
// `decodeLanguageIdentity`'s `expectedId` binds to byte-identical
// provenance below, without importing or modifying `cli.d` itself. The
// raw, unresolved relative fixture path (never this resolved absolute one)
// is what actually gets passed as `--input` and published in the report's
// command fields, so no local checkout path is ever published.
private string resolveRealPath(string path) {
    auto resolved = realpath(path.toStringz, null);
    require(resolved !is null, "cannot resolve fixture path: " ~ path);
    scope(exit) free(resolved);
    return fromStringz(resolved).idup;
}

private ubyte[32] fileTextRevision(string path) {
    return sha256Of(read(path));
}

/// One tool's outcome for one fixture: `produced` is false only for a
/// genuine abstention (scrubbed) or driver-reported error (langdetect) --
/// never scored as a match, and never treated as the other tool's ground
/// truth. `predicted` is either a language code or an "abstain:"/"error:"
/// label, kept for the published per-language detail either way.
private struct LangIdOutcome {
    bool produced;
    string predicted;
    bool correct;
}

private JSONValue langIdOutcomeJson(const ref LangIdOutcome outcome) {
    return JSONValue([
        "status": JSONValue(outcome.produced ? "produced" : "abstained"),
        "predicted": JSONValue(outcome.predicted),
        "correct": JSONValue(outcome.correct),
    ]);
}

private LangIdOutcome scoreScrubbedLanguageId(string sidecarPath, string fixturePath,
                                              string goldLanguage) {
    auto expectedId = DocumentId.from(SourceLocator("local-files:v1",
        resolveRealPath(fixturePath), "."));
    auto record = decodeLanguageIdentity(cast(ubyte[]) read(sidecarPath), expectedId,
        fileTextRevision(fixturePath));
    if (record.result.status != LanguageDetectionStatus.detected)
        return LangIdOutcome(false, "abstain:" ~ record.result.reason.to!string, false);
    auto predicted = record.result.language.to!string;
    return LangIdOutcome(true, predicted, predicted == goldLanguage);
}

private LangIdOutcome scoreLangdetectLanguageId(string outputPath, string goldLanguage) {
    auto line = readText(outputPath).strip;
    auto fields = line.split(" ");
    require(fields.length >= 1 && fields[0].length != 0,
        "langdetect driver produced an empty or malformed result line: " ~ line);
    if (fields[0].startsWith("error:"))
        return LangIdOutcome(false, fields[0], false);
    return LangIdOutcome(true, fields[0], fields[0] == goldLanguage);
}

// One shell-loop sample = one full pass over all 11 held-out fixtures,
// wrapping single-file invocations that match issue #311's own proven
// `scrubbed run --input FILE --output FILE --sidecar-output FILE --stage
// id=language-id-detect --threads 1` shape exactly. `/usr/bin/time` (added
// by the caller via runBoundedSample) wraps this whole shell process, so one
// timed sample still times one full pass over every fixture, matching the
// mojibake/trafilatura cases' own methodology.
private string languageIdScrubbedBatchScript() {
    return "scrubbed=\"$1\"; outdir=\"$2\"; sidecardir=\"$3\"; shift 3; status=0; " ~
        "for f in \"$@\"; do base=$(basename \"$f\"); stem=${base%.txt}; " ~
        "\"$scrubbed\" run --input \"$f\" --output \"$outdir/$stem.out\" " ~
        "--sidecar-output \"$sidecardir/$stem.sidecar\" " ~
        "--stage id=language-id-detect --threads 1 || status=$?; done; exit \"$status\"";
}

// The langdetect-side equivalent: one full pass over the same 11 fixtures,
// one `langdetect_driver.py` invocation per file (its only supported
// single-file shape -- it has no batch mode of its own).
private string languageIdLangdetectBatchScript() {
    return "python=\"$1\"; driver=\"$2\"; outdir=\"$3\"; shift 3; status=0; " ~
        "for f in \"$@\"; do base=$(basename \"$f\"); stem=${base%.txt}; " ~
        "\"$python\" \"$driver\" \"$f\" > \"$outdir/$stem.out\" || status=$?; done; " ~
        "exit \"$status\"";
}

private JSONValue compareLanguageIdLangdetect(string scrubbedBinary,
        string langdetectPython, string root, bool darwin, double timeoutSeconds,
        long maxRssBytes) {
    auto scrubbedSnapshot = snapshotExecutable(scrubbedBinary, root, "scrubbed-langid-snapshot");

    auto acquisitionOrder = verifyPinnedPackages(
        checked(["uv", "pip", "freeze", "--python", langdetectPython]),
        [PinnedPackage("langdetect", "1.0.9")]);

    require(digest(langdetectDriverPath) == langdetectDriverSha256,
        "langdetect driver script drift: on-disk bytes no longer match the pinned hash");

    // Deliberately relative paths (never realpath-resolved here): these are
    // what is actually passed as `--input` and published in the report's
    // command fields below, so no local checkout path is ever published.
    // `scoreScrubbedLanguageId` independently resolves each one via
    // `resolveRealPath` only for `DocumentId` reconstruction, matching
    // `cli.d`'s own internal resolution exactly without publishing it.
    string[] fixturePaths;
    foreach (lang; originalLanguageIdLanguages)
        fixturePaths ~= buildPath("experiments", "language_id", "fixtures", "heldout",
            lang ~ ".txt");

    JSONValue[] samples;
    string[2] scrubbedSidecarDirs, langdetectOutDirs;
    size_t scrubbedSampleIndex, langdetectSampleIndex;
    string[] scrubbedCommand, langdetectCommand;

    foreach (index; 0 .. 4) {
        bool useScrubbed = index % 2 == 0;
        auto tool = useScrubbed ? "scrubbed" : "langdetect";
        JSONValue sample;
        if (useScrubbed) {
            auto outDir = buildPath(root, "langid-scrubbed-out-" ~ index.to!string);
            auto sidecarDir = buildPath(root, "langid-scrubbed-sidecar-" ~ index.to!string);
            mkdirRecurse(outDir);
            mkdirRecurse(sidecarDir);
            scrubbedCommand = ["/bin/sh", "-c", languageIdScrubbedBatchScript(), "sh",
                scrubbedSnapshot.path, outDir, sidecarDir] ~ fixturePaths;
            sample = runBoundedSample(scrubbedCommand, darwin, timeoutSeconds);
            require(sample["status"].integer == 0,
                "scrubbed exited nonzero across the language-id held-out batch: " ~
                sample["status"].integer.to!string);
            scrubbedSidecarDirs[scrubbedSampleIndex++] = sidecarDir;
        } else {
            auto outDir = buildPath(root, "langid-langdetect-out-" ~ index.to!string);
            mkdirRecurse(outDir);
            langdetectCommand = ["/bin/sh", "-c", languageIdLangdetectBatchScript(), "sh",
                langdetectPython, langdetectDriverPath, outDir] ~ fixturePaths;
            sample = runBoundedSample(langdetectCommand, darwin, timeoutSeconds);
            require(sample["status"].integer == 0,
                "langdetect driver exited nonzero across the held-out batch: " ~
                sample["status"].integer.to!string);
            langdetectOutDirs[langdetectSampleIndex++] = outDir;
        }
        auto peakRss = sample["peak_rss_bytes"].integer;
        require(peakRss <= maxRssBytes,
            tool ~ " exceeded the declared resource bound: " ~ peakRss.to!string ~
            " > " ~ maxRssBytes.to!string ~ " bytes");
        sample["tool"] = tool;
        samples ~= sample;
    }
    verifySnapshot(scrubbedSnapshot);
    require(samples.length == 4 && samples[0]["tool"].str == "scrubbed" &&
        samples[1]["tool"].str == "langdetect" && samples[2]["tool"].str == "scrubbed" &&
        samples[3]["tool"].str == "langdetect",
        "language-id comparator lost its A/B/A/B interleave order");

    string[] scrubbedSidecarNames, langdetectOutputNames;
    foreach (lang; originalLanguageIdLanguages) {
        scrubbedSidecarNames ~= lang ~ ".sidecar";
        langdetectOutputNames ~= lang ~ ".out";
    }
    auto scrubbedSignatureA = directorySignature(scrubbedSidecarDirs[0], scrubbedSidecarNames);
    auto scrubbedSignatureB = directorySignature(scrubbedSidecarDirs[1], scrubbedSidecarNames);
    require(scrubbedSignatureA == scrubbedSignatureB,
        "scrubbed produced non-reproducible language-id output between its own two timed samples");
    auto langdetectSignatureA = directorySignature(langdetectOutDirs[0], langdetectOutputNames);
    auto langdetectSignatureB = directorySignature(langdetectOutDirs[1], langdetectOutputNames);
    require(langdetectSignatureA == langdetectSignatureB,
        "langdetect driver produced non-reproducible output between its own two timed " ~
        "samples (DetectorFactory.seed=0 should make this fully deterministic)");

    JSONValue[] languageEntries;
    size_t scrubbedCorrect, scrubbedAbstained, langdetectCorrect, langdetectError, agreementCount;
    foreach (i, lang; originalLanguageIdLanguages) {
        auto sidecarPath = buildPath(scrubbedSidecarDirs[0], lang ~ ".sidecar");
        auto scrubbedOutcome = scoreScrubbedLanguageId(sidecarPath, fixturePaths[i], lang);
        auto langdetectOutcome = scoreLangdetectLanguageId(
            buildPath(langdetectOutDirs[0], lang ~ ".out"), lang);
        if (scrubbedOutcome.correct) ++scrubbedCorrect;
        if (!scrubbedOutcome.produced) ++scrubbedAbstained;
        if (langdetectOutcome.correct) ++langdetectCorrect;
        if (!langdetectOutcome.produced) ++langdetectError;
        auto agree = scrubbedOutcome.predicted == langdetectOutcome.predicted;
        if (agree) ++agreementCount;
        JSONValue entry = JSONValue(["language": JSONValue(lang)]);
        entry["scrubbed"] = langIdOutcomeJson(scrubbedOutcome);
        entry["langdetect"] = langIdOutcomeJson(langdetectOutcome);
        entry["agreement"] = JSONValue(agree);
        languageEntries ~= entry;
    }

    auto totalLanguages = originalLanguageIdLanguages.length;
    JSONValue scoring = JSONValue(["language_count": JSONValue(totalLanguages)]);
    scoring["agreement_count"] = JSONValue(agreementCount);
    scoring["agreement_rate"] = JSONValue(cast(double) agreementCount / totalLanguages);
    scoring["scrubbed"] = JSONValue([
        "correctCount": JSONValue(scrubbedCorrect),
        "abstainedCount": JSONValue(scrubbedAbstained),
        "accuracy": JSONValue(cast(double) scrubbedCorrect / totalLanguages),
    ]);
    scoring["langdetect"] = JSONValue([
        "correctCount": JSONValue(langdetectCorrect),
        "errorCount": JSONValue(langdetectError),
        "accuracy": JSONValue(cast(double) langdetectCorrect / totalLanguages),
    ]);
    scoring["languages"] = JSONValue(languageEntries);

    JSONValue result = JSONValue(["name": JSONValue("language-id/scrubbed-vs-langdetect")]);
    result["scrubbed_binary_sha256"] = scrubbedSnapshot.sha256;
    result["langdetect_driver_sha256"] = langdetectDriverSha256;
    result["python_packages_acquisition_order"] = acquisitionOrder;
    result["scrubbed_command"] = publicCommandGeneric(scrubbedCommand,
        [scrubbedSnapshot.path: "<scrubbed-binary>"], root);
    result["langdetect_command"] = publicCommandGeneric(langdetectCommand,
        [langdetectPython: "<langdetect-python>"], root);
    result["timeout_seconds"] = timeoutSeconds;
    result["max_rss_bytes"] = maxRssBytes;
    result["samples"] = JSONValue(samples);
    result["reproducibility"] = JSONValue([
        "scrubbed": JSONValue(true),
        "langdetect": JSONValue(true),
    ]);
    result["detector_factory_seed"] = JSONValue(0);
    result["original_languages"] = strings(originalLanguageIdLanguages.dup);
    result["scoring"] = scoring;
    return result;
}

// ---- Report assembly: fails closed on a duplicate declared case name or a
// required case that never produced a result. ----

private JSONValue assembleReport(JSONValue[] cases, const string[] requiredNames) {
    bool[string] seen;
    foreach (c; cases) {
        auto name = c["name"].str;
        require(name !in seen, "duplicate case: " ~ name);
        seen[name] = true;
    }
    foreach (name; requiredNames)
        require((name in seen) !is null, "missing required case: " ~ name);
    JSONValue report = JSONValue(["schema": JSONValue("scrubbed-external-comparator-v1")]);
    report["cases"] = JSONValue(cases);
    return report;
}

private void selfTest() {
    auto ok = verifyPinnedPackages(
        "Using Python 3 at: /tmp/example\nftfy==6.3.1\nwcwidth==0.8.4\n",
        [PinnedPackage("ftfy", "6.3.1"), PinnedPackage("wcwidth", "0.8.4")]);
    require(ok.array.length == 2 && ok.array[0].str == "ftfy==6.3.1" &&
        ok.array[1].str == "wcwidth==0.8.4", "acquisition order self-test regression");
    foreach (bad; ["ftfy==6.3.10\nwcwidth==0.8.4", "ftfy==6.3.1\nwcwidth==0.8.40",
                   "ftfy==6.3.1\nftfy==6.3.10\nwcwidth==0.8.4", "ftfy==6.3.1\n"]) {
        bool rejected;
        try verifyPinnedPackages(bad,
            [PinnedPackage("ftfy", "6.3.1"), PinnedPackage("wcwidth", "0.8.4")]);
        catch (Exception) rejected = true;
        require(rejected, "version prefix, duplicate, or missing package accepted: " ~ bad);
    }
    auto a = JSONValue(["name": JSONValue("a")]);
    auto b = JSONValue(["name": JSONValue("b")]);
    assembleReport([a, b], ["a", "b"]);
    bool dupRejected;
    try assembleReport([a, a], []);
    catch (Exception) dupRejected = true;
    require(dupRejected, "duplicate case accepted");
    bool missingRejected;
    try assembleReport([a], ["a", "b"]);
    catch (Exception) missingRejected = true;
    require(missingRejected, "missing required case accepted");
    writeln("external comparator self-test passed");
}

int main(string[] args) {
    try {
        if (args.length == 2 && args[1] == "--self-test") {
            selfTest();
            return 0;
        }
        if (args.length != 5)
            throw new Exception(
                "usage: external_comparator SCRUBBED_BINARY FTFY_BINARY TRAFILATURA_BINARY " ~
                "LANGDETECT_PYTHON");
        auto os = checked(["uname", "-s"]);
        bool darwin = os == "Darwin";
        require(darwin || os == "Linux", "BSD/GNU time only");
        auto root = buildPath(tempDir, "scrubbed-external-comparator-" ~ randomUUID.toString);
        mkdirRecurse(root);
        scope(exit) rmdirRecurse(root);
        auto python = buildPath(dirName(args[2]), "python");
        auto pythonVersion = checked([python, "--version"]);
        auto trafilaturaPython = buildPath(dirName(args[3]), "python");
        auto langdetectPython = args[4];

        auto mojibake = compareFtfyMojibake(args[1], args[2], python, root, darwin,
            60.0, 512L * 1024 * 1024);
        auto mainContent = compareMainContentTrafilatura(args[1], args[3],
            trafilaturaPython, root, darwin, 180.0, 512L * 1024 * 1024);
        auto languageId = compareLanguageIdLangdetect(args[1], langdetectPython, root,
            darwin, 60.0, 512L * 1024 * 1024);
        auto report = assembleReport([mojibake, mainContent, languageId],
            ["mojibake/scrubbed-vs-ftfy", "main-content/scrubbed-vs-trafilatura",
             "language-id/scrubbed-vs-langdetect"]);
        report["source_sha"] = checked(["git", "rev-parse", "HEAD"]);
        report["harness_sha256"] = digest("benchmarks/external_comparator.d");
        report["harness_build_command"] =
            "ldc2 -O3 -release benchmarks/external_comparator.d -of=<path>";
        report["binary_build_command"] = "dub build --build=release --compiler=ldc2";
        report["os"] = JSONValue([
            "name": JSONValue(os),
            "release": JSONValue(checked(["uname", "-r"])),
            "architecture": JSONValue(checked(["uname", "-m"]))]);
        report["compiler"] = checked(["ldc2", "--version"]).splitLines[0];
        report["python_version"] = pythonVersion;
        report["fixture_policy"] =
            "generated deterministic UTF-8; exact byte equality required; fixture and " ~
            "independently authored expectation hashes are pinned in source";
        report["package_acquisition_policy"] =
            "uv venv + uv pip install --python <venv>/bin/python <pkg>==<exact pinned " ~
            "version>, verified via uv pip freeze at run time; nothing vendored";
        auto published = report.toString;
        require(!published.canFind(root) && !published.canFind(args[1]) &&
            !published.canFind(args[2]) && !published.canFind(args[3]) &&
            !published.canFind(args[4]) &&
            !published.canFind(checked(["uname", "-n"])),
            "result contains a private run path or hostname");
        writeln(published);
        return 0;
    } catch (Exception error) {
        stderr.writeln("external_comparator: ", error.msg);
        return 1;
    }
}
