// Release-active D-only checker for benchmarks/external_comparator.d. Build
// with ldc2 -O3 -release. `--self-test` independently re-proves every
// fail-closed gate the runner relies on (version-prefix collision, url-pin
// mismatch, executable mutation, fixture drift, independently authored
// expectation drift, output drift, zero samples, missing case, duplicate
// case, nonzero exit, timeout, resource refusal, and -- against a synthetic
// report -- `checkReport` itself rejecting a corrupted expected hash,
// corrupted sample, broken A/B/A/B interleave, or omitted case for either
// mojibake case) using its own copies of the gating primitives, not by
// importing the runner module. `--check <report.json>`
// structurally validates a report actually produced by external_comparator
// and proves both migrated ftfy mojibake cases (CP1252's
// `mojibake/scrubbed-vs-ftfy` and its Windows-1251 sibling
// `mojibake/scrubbed-vs-ftfy-windows1251`) reproduce cli_baseline.d's prior
// correctness result for that case (same input/expected hashes, same
// exact-output gate) even though the report format itself intentionally
// broke compatibility with the old A00 shape.
module external_comparator_check;

import core.stdc.errno : errno, ESRCH;
import core.sys.posix.signal : kill, SIGKILL, SIGTERM;
import core.sys.posix.sys.wait : WEXITSTATUS, WIFEXITED, WNOHANG, WTERMSIG,
    waitpid;
import core.sys.posix.unistd : _exit, dup2, execvp, fork, setpgid;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.algorithm.searching : endsWith, startsWith;
import std.conv : to;
import std.digest : toHexString;
import std.digest.sha : sha256Of;
import std.file : exists, read, readText, remove, tempDir, write;
import std.json : JSONValue, parseJSON;
import std.path : buildPath;
import std.process : execute;
import std.stdio : File, stderr, writeln;
import std.string : indexOf, split, splitLines, strip, toStringz;
import std.uuid : randomUUID;

private void require(bool condition, string message) {
    if (!condition) throw new Exception(message);
}

private string digest(string path) {
    return toHexString(sha256Of(read(path))).to!string;
}

private string scratchFile(string label) {
    return buildPath(tempDir, "scrubbed-external-comparator-check-" ~ label ~
        "-" ~ randomUUID.toString);
}

// ---- Independent copy of the executable-snapshot mechanism (proves
// mutation detection without importing the runner). ----

private struct Snapshot {
    string path;
    string sha256;
}

private Snapshot snapshot(string path) {
    return Snapshot(path, digest(path));
}

private void verify(Snapshot snap) {
    require(digest(snap.path) == snap.sha256, "executable snapshot changed");
}

private void checkExecutableMutation() {
    auto path = scratchFile("mutation-fixture");
    write(path, cast(ubyte[]) "original executable bytes");
    scope(exit) if (exists(path)) remove(path);
    auto snap = snapshot(path);
    verify(snap); // unmutated: must pass
    write(path, cast(ubyte[]) "MUTATED executable bytes");
    bool rejected;
    try verify(snap);
    catch (Exception) rejected = true;
    require(rejected, "executable mutation after snapshot was not detected");
}

// ---- Independent copy of the pinned-package acquisition-order/version
// verification (proves version-prefix-collision and duplicate-row
// rejection without importing the runner). ----

// `url` is non-empty for a package pinned by an exact download URL instead
// of a plain PyPI version (issue #302's spaCy model: `en_core_web_sm` has no
// ordinary versioned PyPI release, only a GitHub release-asset wheel, so
// `uv pip freeze` represents it as "name @ url" rather than "name==version").
// Exactly one of `exactVersion`/`url` is set per declared package. Kept as
// an independent copy of `external_comparator.d`'s own struct, matching this
// checker's own "no import of the runner module" design.
private struct PinnedPackage {
    string name;
    string exactVersion;
    string url;
}

private struct FreezeEntry {
    string exactVersion; // empty when this row was a "name @ url" install
    string url;          // empty when this row was a "name==version" install
}

private FreezeEntry[string] parseFreeze(string output) {
    FreezeEntry[string] entries;
    foreach (line; output.splitLines) {
        auto row = line.strip;
        if (row.length == 0) continue;
        if (row.startsWith("Using Python ")) continue;
        auto separator = row.indexOf(" @ ");
        if (separator >= 0) {
            auto name = row[0 .. separator];
            auto url = row[separator + 3 .. $];
            if (name.length == 0 || url.length == 0 || name in entries)
                throw new Exception("unparseable or duplicate uv freeze row: " ~ row);
            entries[name] = FreezeEntry("", url);
            continue;
        }
        auto fields = row.split("==");
        if (fields.length != 2 || fields[0].length == 0 || fields[1].length == 0 ||
            fields[0] in entries)
            throw new Exception("unparseable or duplicate uv freeze row: " ~ row);
        entries[fields[0]] = FreezeEntry(fields[1], "");
    }
    return entries;
}

private JSONValue verifyPinnedPackages(string freezeOutput,
                                       const PinnedPackage[] pinned) {
    require(pinned.length != 0, "no pinned packages declared");
    auto entries = parseFreeze(freezeOutput);
    JSONValue[] order;
    foreach (pkg; pinned) {
        auto found = pkg.name in entries;
        if (pkg.url.length != 0) {
            require(found !is null && found.url == pkg.url,
                "expected " ~ pkg.name ~ " @ " ~ pkg.url ~ " exactly");
            order ~= JSONValue(pkg.name ~ " @ " ~ pkg.url);
        } else {
            require(found !is null && found.url.length == 0 &&
                found.exactVersion == pkg.exactVersion,
                "expected " ~ pkg.name ~ "==" ~ pkg.exactVersion ~ " exactly");
            order ~= JSONValue(pkg.name ~ "==" ~ pkg.exactVersion);
        }
    }
    return JSONValue(order);
}

private void checkPinnedPackageVerification() {
    auto pinned = [PinnedPackage("ftfy", "6.3.1"), PinnedPackage("wcwidth", "0.8.4")];
    verifyPinnedPackages("ftfy==6.3.1\nwcwidth==0.8.4\n", pinned); // exact pins: must pass
    foreach (bad; ["ftfy==6.3.10\nwcwidth==0.8.4",             // prefix collision
                   "ftfy==6.3.1\nwcwidth==0.8.40",              // prefix collision
                   "ftfy==6.3.1\nftfy==6.3.10\nwcwidth==0.8.4", // duplicate row
                   "wcwidth==0.8.4\n"]) {                       // missing package
        bool rejected;
        try verifyPinnedPackages(bad, pinned);
        catch (Exception) rejected = true;
        require(rejected, "prefix-collision, duplicate, or missing pin accepted: " ~ bad);
    }

    // URL-pinned package (a spaCy model with no plain-PyPI release): accepted
    // only when the freeze row's URL matches byte-for-byte, and a version/URL
    // type mismatch is rejected in both directions.
    enum urlPinUrl = "https://example.invalid/en_core_web_sm-3.8.0.whl";
    auto urlPin = PinnedPackage("en-core-web-sm", "", urlPinUrl);
    verifyPinnedPackages("en-core-web-sm @ " ~ urlPinUrl ~ "\n", [urlPin]); // exact pin: must pass
    foreach (bad; ["en-core-web-sm @ https://example.invalid/en_core_web_sm-3.9.0.whl",
                   "en-core-web-sm==3.8.0"]) {
        bool rejected;
        try verifyPinnedPackages(bad, [urlPin]);
        catch (Exception) rejected = true;
        require(rejected, "url-pin mismatch or version/url type confusion accepted: " ~ bad);
    }
}

// ---- Independent copy of the fixture/expectation drift gate (an
// on-disk fixture or independently authored expected file that no longer
// matches its declared hash must be rejected before any subprocess runs). ----

private void requireHash(string path, string expectedSha256, string label) {
    require(digest(path) == expectedSha256, label ~ " drift: hash mismatch");
}

private void checkFixtureAndExpectationDrift() {
    foreach (label; ["fixture", "expectation"]) {
        auto path = scratchFile(label);
        scope(exit) if (exists(path)) remove(path);
        write(path, cast(ubyte[]) "authored bytes, version 1");
        auto pinned = digest(path);
        requireHash(path, pinned, label); // unmutated: must pass
        write(path, cast(ubyte[]) "silently drifted bytes, version 2");
        bool rejected;
        try requireHash(path, pinned, label);
        catch (Exception) rejected = true;
        require(rejected, label ~ " drift was not detected");
    }
}

// ---- Independent copy of the exact-output gate (comparator output is
// never ground truth; a produced output that drifts from the independently
// authored expected bytes must be rejected). ----

private void checkOutputDrift() {
    auto expectedPath = scratchFile("output-expected");
    auto actualPath = scratchFile("output-actual");
    scope(exit) { if (exists(expectedPath)) remove(expectedPath);
                  if (exists(actualPath)) remove(actualPath); }
    write(expectedPath, cast(ubyte[]) "independently authored expected output");
    write(actualPath, cast(ubyte[]) "independently authored expected output");
    require(digest(actualPath) == digest(expectedPath), "identical output falsely rejected");
    write(actualPath, cast(ubyte[]) "a comparator's own drifted output");
    require(digest(actualPath) != digest(expectedPath),
        "drifted comparator output was not detected against the independently authored expectation");
}

// ---- Independent copy of the case-set gates: zero samples, missing
// declared case, and duplicate declared case must each fail closed. ----

private void requireSamples(const JSONValue[] samples) {
    require(samples.length != 0, "zero samples retained");
}

private void assembleAndCheck(JSONValue[] cases, const string[] requiredNames) {
    bool[string] seen;
    foreach (c; cases) {
        auto name = c["name"].str;
        require(name !in seen, "duplicate case: " ~ name);
        seen[name] = true;
    }
    foreach (name; requiredNames)
        require((name in seen) !is null, "missing required case: " ~ name);
}

private void checkZeroSamplesMissingAndDuplicateCase() {
    bool rejected;
    try requireSamples([]);
    catch (Exception) rejected = true;
    require(rejected, "zero samples were accepted");

    auto a = JSONValue(["name": JSONValue("a")]);
    assembleAndCheck([a], ["a"]); // present, unique: must pass

    bool duplicateRejected;
    try assembleAndCheck([a, a], []);
    catch (Exception) duplicateRejected = true;
    require(duplicateRejected, "duplicate case name was accepted");

    bool missingRejected;
    try assembleAndCheck([a], ["a", "never-produced"]);
    catch (Exception) missingRejected = true;
    require(missingRejected, "missing required case was accepted");
}

// ---- Independent copy of the bounded-timeout/resource-bound sample
// runner (proves nonzero exit, timeout, and resource-refusal rejection
// using cheap, portable system commands; no pinned external tool needed). ----

private double metricValue(string report, string prefix) {
    foreach (line; report.splitLines) {
        auto trimmed = line.strip;
        if (trimmed.startsWith(prefix))
            return trimmed[prefix.length .. $].strip.to!double;
    }
    throw new Exception("missing time metric " ~ prefix);
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

// ---- Independent copy of the whole-process-group ownership for the timed
// sample child (behavioral model:
// experiments/document_adapters/run_limited.d and
// experiments/embedding_clusters/run_evaluation.d's startServer). The
// direct /usr/bin/time child is forked, made its own process-group leader
// via setpgid(0, 0) before exec, and its stdin/stdout/stderr are dup2'd
// from devNull/captureFile. A timeout signals the whole group
// (kill(-pid, ...)), not just the direct child. ----

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

private JSONValue runBoundedSample(string[] command, bool darwin, double timeoutSeconds) {
    string[] wrapper = (darwin ? ["/usr/bin/time", "-l", "-p"] :
        ["/usr/bin/time", "-v"]) ~ command;
    auto capturePath = scratchFile("sample");
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
        kill(-pid, SIGTERM);
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
        throw new Exception("declared timeout exceeded; process terminated");
    }
    captureFile.close();
    return parseTimedMetrics(readText(capturePath), darwin, waitResult.status);
}

private bool darwinHost() {
    auto result = execute(["uname", "-s"]);
    require(result.status == 0, "uname failed");
    return result.output.strip == "Darwin";
}

private void checkNonzeroExit() {
    auto darwin = darwinHost();
    auto sample = runBoundedSample(["/usr/bin/false"], darwin, 10.0);
    require(sample["status"].integer != 0,
        "a nonzero-exit comparator command was reported as status 0");
}

private void checkTimeout() {
    auto darwin = darwinHost();
    bool rejected;
    try runBoundedSample(["/bin/sleep", "2"], darwin, 0.3);
    catch (Exception) rejected = true;
    require(rejected, "a command that exceeded its declared timeout was not rejected");
}

// Proves the whole process group -- not just the direct child -- is
// terminated on timeout. The synthetic /bin/sh command backgrounds a long
// sleep as a grandchild, records that grandchild's PID to a known temp
// file, then itself sleeps well past the declared timeout so the direct
// child is still running when runBoundedSample's deadline fires. After the
// call throws, the grandchild's PID must go away (ESRCH on kill(pid, 0)):
// if only the direct /usr/bin/time child were signaled (the pre-fix
// behavior), the backgrounded grandchild would survive as an orphan.
private void checkProcessGroupTimeout() {
    auto darwin = darwinHost();
    auto pidFile = scratchFile("grandchild-pid");
    scope(exit) if (exists(pidFile)) remove(pidFile);
    auto script = "sleep 30 & echo $! > " ~ pidFile ~ "; sleep 30";

    bool rejected;
    try runBoundedSample(["/bin/sh", "-c", script], darwin, 0.4);
    catch (Exception) rejected = true;
    require(rejected, "a process-group timeout command was not rejected");

    auto pidDeadline = MonoTime.currTime + seconds(1);
    while (!exists(pidFile) && MonoTime.currTime < pidDeadline)
        Thread.sleep(msecs(10));
    require(exists(pidFile), "grandchild PID file was never written");
    auto grandchildPid = readText(pidFile).strip.to!int;

    bool gone;
    auto goneDeadline = MonoTime.currTime + seconds(1);
    while (MonoTime.currTime < goneDeadline) {
        errno = 0;
        if (kill(grandchildPid, 0) != 0 && errno == ESRCH) { gone = true; break; }
        Thread.sleep(msecs(10));
    }
    require(gone, "the backgrounded grandchild survived the declared timeout: " ~
        "only the direct child was signaled, not its whole process group");
}

private void checkResourceRefusal() {
    auto darwin = darwinHost();
    auto sample = runBoundedSample(["/bin/echo", "hi"], darwin, 10.0);
    auto peakRss = sample["peak_rss_bytes"].integer;
    require(peakRss > 1, "test precondition: /bin/echo unexpectedly used <=1 byte RSS");
    bool rejected;
    // Mirrors external_comparator.d's `peakRss <= maxRssBytes` gate.
    try require(peakRss <= 1, "exceeded the declared resource bound: " ~
        peakRss.to!string ~ " > 1 bytes");
    catch (Exception) rejected = true;
    require(rejected, "an over-budget process was not refused on its declared RSS bound");
}

private void selfTest() {
    checkPinnedPackageVerification();
    checkExecutableMutation();
    checkFixtureAndExpectationDrift();
    checkOutputDrift();
    checkZeroSamplesMissingAndDuplicateCase();
    checkNonzeroExit();
    checkTimeout();
    checkProcessGroupTimeout();
    checkResourceRefusal();
    checkReportGates();
    writeln("external comparator negative-control self-test passed: ",
        "version-prefix-collision, url-pin-mismatch, executable-mutation, ",
        "fixture-drift, expectation-drift, output-drift, zero-samples, ",
        "missing-case, duplicate-case, nonzero-exit, timeout, ",
        "process-group-timeout, resource-refusal, report-check-gates ",
        "(both mojibake cases' corrupted-hash/corrupted-sample/broken-interleave/missing-case)");
}

// ---- Report validation: proves a real external_comparator run reproduces
// cli_baseline.d's prior mojibake correctness result under the new,
// intentionally non-backward-compatible report shape. ----

private enum mojibakeFixtureSha256 =
    "FBB0ED284337887CD1EE5419735AC30C1189DBE94609A5119916A2906EE5889B";
private enum mojibakeExpectedSha256 =
    "14A9EDC0944EF516E12E1CE8ABBF3D78CCF41D48CDDD1F2A8AD13173363F7DCA";

// The Windows-1251 (Cyrillic) sibling of the pair above, matching
// external_comparator.d's own `mojibakeWindows1251FixtureSha256`/
// `mojibakeWindows1251ExpectedSha256` pins (issue #377's comparator case,
// left unvalidated by this checker until issue #383).
private enum mojibakeWindows1251FixtureSha256 =
    "C1B6EDDA8EA799948C6F3E34D42E5224D316A157B9159DEB01593BDECD815248";
private enum mojibakeWindows1251ExpectedSha256 =
    "D9AC303E3E045729B922A123B5B9EC58DFEA3EC8B6DC46F89C47226C74DA3F85";

// Shared validation for both ftfy/mojibake cases (issue #383): the CP1252
// case `mojibake/scrubbed-vs-ftfy` and its Windows-1251 (Cyrillic) sibling
// `mojibake/scrubbed-vs-ftfy-windows1251` are checked exactly the same way,
// against each one's own pinned fixture/expected hashes.
private void checkMojibakeCase(JSONValue report, string caseName, string fixtureSha256,
                               string expectedSha256, string logLabel) {
    JSONValue found;
    bool hasCase;
    foreach (c; report["cases"].array)
        if (c["name"].str == caseName) { found = c; hasCase = true; }
    require(hasCase, "missing " ~ caseName ~ " case");
    require(found["fixture_sha256"].str == fixtureSha256,
        "fixture hash differs from the pinned " ~ logLabel ~ " mojibake fixture");
    require(found["expected_sha256"].str == expectedSha256,
        "expected hash differs from the pinned independently authored " ~ logLabel ~
        " expectation" ~ (caseName == "mojibake/scrubbed-vs-ftfy" ?
            " (this is exactly the hash cli_baseline.d's mojibake case bound)" : ""));
    auto samples = found["samples"].array;
    require(samples.length == 4, "expected four A/B/A/B samples");
    require(samples[0]["tool"].str == "scrubbed" && samples[1]["tool"].str == "ftfy" &&
        samples[2]["tool"].str == "scrubbed" && samples[3]["tool"].str == "ftfy",
        "samples lost their A/B/A/B interleave order");
    foreach (sample; samples) {
        require(sample["status"].integer == 0, "a sample exited nonzero or was signaled");
        require(sample["exact_output"].boolean, "a sample failed the exact-output gate");
        require(sample["output_sha256"].str == expectedSha256,
            "a sample's output hash differs from the independently authored expectation");
        foreach (metric; ["wall_seconds", "user_seconds", "system_seconds", "peak_rss_bytes"])
            require((metric in sample.object) !is null, "sample missing " ~ metric);
    }
    require(found["python_packages_acquisition_order"].array.length == 2 &&
        found["python_packages_acquisition_order"].array[0].str == "ftfy==6.3.1" &&
        found["python_packages_acquisition_order"].array[1].str == "wcwidth==0.8.4",
        "unexpected package acquisition order");
    require(found["ftfy_version"].str.startsWith("ftfy (fixes text for you), version 6.3.1"),
        "unexpected pinned ftfy version");
    require(found["timeout_seconds"].floating > 0, "missing declared timeout");
    require(found["max_rss_bytes"].integer > 0, "missing declared resource bound");
    writeln("external comparator report check passed: ", caseName, " reproduces the pinned ",
        logLabel, " fixture/expected hashes and exact-output gate under the ",
        "scrubbed-external-comparator-v1 report format");
}

private void checkReport(string path) {
    auto report = parseJSON(readText(path));
    require(report["schema"].str == "scrubbed-external-comparator-v1",
        "unexpected schema");
    require(report["harness_sha256"].str == digest("benchmarks/external_comparator.d"),
        "harness hash mismatch: report was not produced by the checked-out harness");
    bool[string] seenNames;
    foreach (c; report["cases"].array) {
        auto name = c["name"].str;
        require(name !in seenNames, "duplicate case in report: " ~ name);
        seenNames[name] = true;
    }

    checkMojibakeCase(report, "mojibake/scrubbed-vs-ftfy", mojibakeFixtureSha256,
        mojibakeExpectedSha256, "CP1252");
    checkMojibakeCase(report, "mojibake/scrubbed-vs-ftfy-windows1251",
        mojibakeWindows1251FixtureSha256, mojibakeWindows1251ExpectedSha256, "Windows-1251");

    checkMainContentTrafilaturaCase(report);
    checkLanguageIdLangdetectCase(report);
    checkPiiFourClassPresidioCase(report);
}

// ---- main-content/scrubbed-vs-trafilatura case validation (issue #229's
// next-slice contract). Precision/recall are reported, not gated, so this
// structurally validates required fields/shape rather than recomputing the
// score: `--check` proves the report has the right shape, not that this
// particular run's numbers are "correct" (there is no accepted numeric
// target, matching #26's own stance). ----

private enum expectedHeldOutCommit = "1e31e3e9eb2e4f6fbfd4bc04355bc74005a780e6";
private enum expectedHeldOutFixtureCount = 20;

private void requireUnitInterval(double value, string label) {
    require(value >= 0.0 && value <= 1.0, label ~ " is out of the [0,1] unit interval: " ~
        value.to!string);
}

private void checkMainContentTrafilaturaCase(JSONValue report) {
    JSONValue found;
    bool hasCase;
    foreach (c; report["cases"].array)
        if (c["name"].str == "main-content/scrubbed-vs-trafilatura") { found = c; hasCase = true; }
    require(hasCase, "missing main-content/scrubbed-vs-trafilatura case");

    require(found["scrubbed_binary_sha256"].str.length == 64,
        "scrubbed_binary_sha256 is not a SHA-256 hex digest");
    require(found["trafilatura_binary_sha256"].str.length == 64,
        "trafilatura_binary_sha256 is not a SHA-256 hex digest");
    require(found["trafilatura_version"].str.startsWith("Trafilatura "),
        "unexpected trafilatura version string");
    require(found["held_out_corpus_commit"].str == expectedHeldOutCommit,
        "held-out corpus commit differs from the pinned commit reused from issue #26");
    require(found["held_out_fixture_count"].integer == expectedHeldOutFixtureCount,
        "held-out corpus did not resolve all pinned fixtures");
    require(found["python_packages_acquisition_order"].array.length == 1 &&
        found["python_packages_acquisition_order"].array[0].str.startsWith("trafilatura=="),
        "unexpected trafilatura package acquisition order");
    require(found["timeout_seconds"].floating > 0, "missing declared timeout");
    require(found["max_rss_bytes"].integer > 0, "missing declared resource bound");

    auto samples = found["samples"].array;
    require(samples.length == 4, "expected four A/B/A/B samples");
    require(samples[0]["tool"].str == "scrubbed" && samples[1]["tool"].str == "trafilatura" &&
        samples[2]["tool"].str == "scrubbed" && samples[3]["tool"].str == "trafilatura",
        "samples lost their A/B/A/B interleave order");
    foreach (i, sample; samples) {
        auto status = sample["status"].integer;
        if (i == 0 || i == 2)
            require(status == 0 || status == 1,
                "a scrubbed sample's status is neither a clean run nor an expected " ~
                "content-driven quarantine");
        else
            require(status == 0, "a trafilatura sample exited nonzero or was signaled");
        foreach (metric; ["wall_seconds", "user_seconds", "system_seconds", "peak_rss_bytes"])
            require((metric in sample.object) !is null, "sample missing " ~ metric);
    }

    require(found["reproducibility"]["scrubbed"].boolean &&
        found["reproducibility"]["trafilatura"].boolean,
        "a tool's output-reproducibility check did not pass");

    auto scoring = found["scoring"];
    require(scoring["gold_fixture_count"].integer == expectedHeldOutFixtureCount,
        "unexpected gold fixture count");
    auto fixtures = scoring["fixtures"].array;
    require(fixtures.length == expectedHeldOutFixtureCount,
        "scoring fixtures array does not cover all pinned held-out fixtures");

    foreach (toolName; ["scrubbed", "trafilatura"]) {
        auto summary = scoring[toolName];
        auto extracted = summary["extractedCount"].integer;
        auto abstained = summary["abstainedCount"].integer;
        require(extracted + abstained == expectedHeldOutFixtureCount,
            toolName ~ "'s extracted/abstained counts do not add up to the fixture count");
        requireUnitInterval(summary["meanPrecision"].floating, toolName ~ " meanPrecision");
        requireUnitInterval(summary["meanRecall"].floating, toolName ~ " meanRecall");
        require(summary["withoutLeakTotal"].integer >= 0,
            toolName ~ " withoutLeakTotal must be non-negative");
    }

    bool[string] seenFixtureIds;
    foreach (fixture; fixtures) {
        auto id = fixture["id"].str;
        require(id !in seenFixtureIds, "duplicate scoring fixture id: " ~ id);
        seenFixtureIds[id] = true;
        foreach (toolName; ["scrubbed", "trafilatura"]) {
            auto entry = fixture[toolName];
            auto status = entry["status"].str;
            require(status == "produced" || status == "abstained",
                toolName ~ " fixture status must be 'produced' or 'abstained': " ~ status);
            if (status == "produced") {
                requireUnitInterval(entry["precision"].floating, toolName ~ " fixture precision");
                requireUnitInterval(entry["recall"].floating, toolName ~ " fixture recall");
                require(entry["withoutLeaks"].integer >= 0,
                    toolName ~ " fixture withoutLeaks must be non-negative");
            }
        }
    }
    writeln("external comparator report check passed: main-content/scrubbed-vs-trafilatura ",
        "case has the required provenance, reproducibility, and precision/recall scoring ",
        "shape (", expectedHeldOutFixtureCount, "/", expectedHeldOutFixtureCount,
        " held-out fixtures accounted for)");
}

// ---- language-id/scrubbed-vs-langdetect case validation (issue #301's
// accepted next-slice contract). Classification agreement/accuracy against
// each fixture's own authored gold label is reported, not gated -- there is
// no accepted numeric target -- so this structurally validates required
// fields/shape (provenance, A/B/A/B interleave, both tools' output
// reproducibility, and the scoring object's shape restricted to exactly the
// 11 original languages) rather than recomputing the scores itself. ----

private enum expectedOriginalLanguageIdLanguages = ["en", "es", "fr", "de", "pt", "it",
    "nl", "tr", "vi", "pl", "id"];

private void checkLanguageIdLangdetectCase(JSONValue report) {
    JSONValue found;
    bool hasCase;
    foreach (c; report["cases"].array)
        if (c["name"].str == "language-id/scrubbed-vs-langdetect") { found = c; hasCase = true; }
    require(hasCase, "missing language-id/scrubbed-vs-langdetect case");

    require(found["scrubbed_binary_sha256"].str.length == 64,
        "scrubbed_binary_sha256 is not a SHA-256 hex digest");
    require(found["langdetect_driver_sha256"].str.length == 64,
        "langdetect_driver_sha256 is not a SHA-256 hex digest");
    require(found["python_packages_acquisition_order"].array.length == 1 &&
        found["python_packages_acquisition_order"].array[0].str == "langdetect==1.0.9",
        "unexpected langdetect package acquisition order");
    require(found["detector_factory_seed"].integer == 0,
        "DetectorFactory.seed must be pinned to 0 for reproducibility");
    require(found["timeout_seconds"].floating > 0, "missing declared timeout");
    require(found["max_rss_bytes"].integer > 0, "missing declared resource bound");

    auto originalLanguages = found["original_languages"].array;
    require(originalLanguages.length == expectedOriginalLanguageIdLanguages.length,
        "original_languages must list exactly the 11 originally-supported languages");
    bool[string] seenOriginal;
    foreach (entry; originalLanguages) seenOriginal[entry.str] = true;
    foreach (lang; expectedOriginalLanguageIdLanguages)
        require((lang in seenOriginal) !is null, "original_languages is missing " ~ lang);
    foreach (excluded; ["hi", "bn", "ta", "te", "gu", "pa"])
        require(excluded !in seenOriginal,
            "original_languages must not include issue #299's Devanagari-family addition: " ~
            excluded);

    auto samples = found["samples"].array;
    require(samples.length == 4, "expected four A/B/A/B samples");
    require(samples[0]["tool"].str == "scrubbed" && samples[1]["tool"].str == "langdetect" &&
        samples[2]["tool"].str == "scrubbed" && samples[3]["tool"].str == "langdetect",
        "samples lost their A/B/A/B interleave order");
    foreach (sample; samples) {
        require(sample["status"].integer == 0,
            "a sample exited nonzero or was signaled");
        foreach (metric; ["wall_seconds", "user_seconds", "system_seconds", "peak_rss_bytes"])
            require((metric in sample.object) !is null, "sample missing " ~ metric);
    }

    require(found["reproducibility"]["scrubbed"].boolean &&
        found["reproducibility"]["langdetect"].boolean,
        "a tool's output-reproducibility check did not pass");

    auto scoring = found["scoring"];
    require(scoring["language_count"].integer == expectedOriginalLanguageIdLanguages.length,
        "unexpected scored language count");
    requireUnitInterval(scoring["agreement_rate"].floating, "agreement_rate");
    require(scoring["agreement_count"].integer >= 0 &&
        scoring["agreement_count"].integer <= expectedOriginalLanguageIdLanguages.length,
        "agreement_count out of range");

    foreach (toolName; ["scrubbed", "langdetect"]) {
        auto summary = scoring[toolName];
        require(summary["correctCount"].integer >= 0 &&
            summary["correctCount"].integer <= expectedOriginalLanguageIdLanguages.length,
            toolName ~ " correctCount out of range");
        requireUnitInterval(summary["accuracy"].floating, toolName ~ " accuracy");
    }
    require(scoring["scrubbed"]["abstainedCount"].integer >= 0,
        "scrubbed abstainedCount must be non-negative");
    require(scoring["langdetect"]["errorCount"].integer >= 0,
        "langdetect errorCount must be non-negative");

    auto languages = scoring["languages"].array;
    require(languages.length == expectedOriginalLanguageIdLanguages.length,
        "scoring languages array does not cover all 11 original languages");
    bool[string] seenScoredLanguage;
    foreach (entry; languages) {
        auto lang = entry["language"].str;
        require(lang !in seenScoredLanguage, "duplicate scoring language: " ~ lang);
        seenScoredLanguage[lang] = true;
        require((lang in seenOriginal) !is null, "scored a language outside the original 11: " ~ lang);
        foreach (toolName; ["scrubbed", "langdetect"]) {
            auto outcome = entry[toolName];
            auto status = outcome["status"].str;
            require(status == "produced" || status == "abstained",
                toolName ~ " outcome status must be 'produced' or 'abstained': " ~ status);
            require(outcome["predicted"].str.length != 0,
                toolName ~ " outcome is missing a predicted label");
        }
        entry["agreement"].boolean; // throws unless this is a genuine JSON boolean
    }
    writeln("external comparator report check passed: language-id/scrubbed-vs-langdetect ",
        "case has the required provenance, reproducibility, and classification-agreement ",
        "scoring shape (", expectedOriginalLanguageIdLanguages.length, "/",
        expectedOriginalLanguageIdLanguages.length, " original-language fixtures accounted ",
        "for, #299's six Devanagari-family languages correctly excluded)");
}

// ---- pii-four-class/scrubbed-vs-presidio case validation (issue #302's
// accepted next-slice contract). Per-category precision/recall against the
// authored gold fixture is reported, not gated -- there is no accepted
// numeric target -- so this structurally validates required fields/shape
// (provenance including the pinned URL-installed spaCy model, the
// empirically re-verified recognizer scoping, A/B/A/B interleave, both
// tools' output reproducibility, and the per-category scoring object's
// shape restricted to exactly the four overlap categories) rather than
// recomputing the scores itself. ----

private enum expectedPresidioSupportedEntities =
    ["CREDIT_CARD", "EMAIL_ADDRESS", "IP_ADDRESS", "PHONE_NUMBER"];
private enum expectedPiiCategories = ["email", "phone", "card", "ip"];

private void checkPiiFourClassPresidioCase(JSONValue report) {
    JSONValue found;
    bool hasCase;
    foreach (c; report["cases"].array)
        if (c["name"].str == "pii-four-class/scrubbed-vs-presidio") { found = c; hasCase = true; }
    require(hasCase, "missing pii-four-class/scrubbed-vs-presidio case");

    require(found["scrubbed_binary_sha256"].str.length == 64,
        "scrubbed_binary_sha256 is not a SHA-256 hex digest");
    require(found["presidio_driver_sha256"].str.length == 64,
        "presidio_driver_sha256 is not a SHA-256 hex digest");
    require(found["presidio_spacy_model"].str == "en_core_web_sm",
        "unexpected presidio_spacy_model: the small model was expected to suffice for these " ~
        "four pattern/checksum recognizers");
    require(found["presidio_python_version"].str.length != 0,
        "missing presidio_python_version provenance");

    auto acquisition = found["python_packages_acquisition_order"].array;
    require(acquisition.length == 3 &&
        acquisition[0].str.startsWith("presidio-analyzer==") &&
        acquisition[1].str.startsWith("presidio-anonymizer==") &&
        acquisition[2].str.startsWith("en-core-web-sm @ "),
        "unexpected presidio package acquisition order");
    require(found["timeout_seconds"].floating > 0, "missing declared timeout");
    require(found["max_rss_bytes"].integer > 0, "missing declared resource bound");

    auto supported = found["presidio_supported_entities"].array;
    require(supported.length == expectedPresidioSupportedEntities.length,
        "presidio_supported_entities must name exactly the four overlap entities");
    foreach (i, entity; expectedPresidioSupportedEntities)
        require(supported[i].str == entity,
            "presidio recognizer configuration is not empirically confirmed scoped to the " ~
            "four overlap entities (position " ~ i.to!string ~ " was " ~ supported[i].str ~ ")");

    auto samples = found["samples"].array;
    require(samples.length == 4, "expected four A/B/A/B samples");
    require(samples[0]["tool"].str == "scrubbed" && samples[1]["tool"].str == "presidio" &&
        samples[2]["tool"].str == "scrubbed" && samples[3]["tool"].str == "presidio",
        "samples lost their A/B/A/B interleave order");
    foreach (sample; samples) {
        require(sample["status"].integer == 0, "a sample exited nonzero or was signaled");
        foreach (metric; ["wall_seconds", "user_seconds", "system_seconds", "peak_rss_bytes"])
            require((metric in sample.object) !is null, "sample missing " ~ metric);
    }

    require(found["reproducibility"]["scrubbed"].boolean &&
        found["reproducibility"]["presidio"].boolean,
        "a tool's output-reproducibility check did not pass");

    require(found["fixture_spec_sha256"].str.length == 64,
        "fixture_spec_sha256 is not a SHA-256 hex digest");
    require(found["fixture_count"].integer > 0, "fixture_count must be positive");

    auto scoring = found["scoring"];
    auto categories = scoring["categories"].array;
    require(categories.length == expectedPiiCategories.length,
        "scoring categories must name exactly the four overlap categories");
    foreach (i, category; expectedPiiCategories)
        require(categories[i].str == category,
            "unexpected scoring category order: " ~ categories[i].str);

    foreach (toolName; ["scrubbed", "presidio"]) {
        auto perCategory = scoring[toolName];
        foreach (category; expectedPiiCategories) {
            auto entry = perCategory[category];
            require(entry["truePositive"].integer >= 0 && entry["falsePositive"].integer >= 0 &&
                entry["falseNegative"].integer >= 0,
                toolName ~ " " ~ category ~ " counts must be non-negative");
            requireUnitInterval(entry["precision"].floating, toolName ~ " " ~ category ~ " precision");
            requireUnitInterval(entry["recall"].floating, toolName ~ " " ~ category ~ " recall");
        }
    }
    writeln("external comparator report check passed: pii-four-class/scrubbed-vs-presidio ",
        "case has the required provenance (including the URL-pinned small spaCy model), ",
        "reproducibility, an empirically re-verified four-entity recognizer scope, and ",
        "per-category precision/recall scoring shape for exactly the four overlap categories ",
        "(email/phone/card/ip)");
}

// ---- Report-level self-test (issue #383): proves `checkReport` itself --
// not just its independently reimplemented gate primitives above -- fails
// closed. A synthetic report is assembled that satisfies every case's shape
// (including main-content/language-id/pii-four-class, which `checkReport`
// also validates whenever any case is checked), `checkReport` is proven to
// accept that unmodified baseline, and then each mojibake case (CP1252 and
// its Windows-1251 sibling) is independently proven to reject a corrupted
// expected hash, a corrupted sample, a broken A/B/A/B interleave, and the
// case being omitted entirely. Before this fix, the Windows-1251 variants of
// these four rejections did not happen: `checkReport` never looked at that
// case at all, so a corrupted or missing Windows-1251 case wrongly passed.

private string syntheticHash(string seed) {
    return toHexString(sha256Of(cast(ubyte[]) seed)).to!string;
}

private JSONValue syntheticSample(string tool, int status) {
    JSONValue sample = JSONValue(["tool": JSONValue(tool)]);
    sample["status"] = JSONValue(status);
    sample["wall_seconds"] = JSONValue(0.01);
    sample["user_seconds"] = JSONValue(0.01);
    sample["system_seconds"] = JSONValue(0.0);
    sample["peak_rss_bytes"] = JSONValue(1024);
    return sample;
}

private JSONValue syntheticMojibakeSample(string tool, string expectedSha256) {
    auto sample = syntheticSample(tool, 0);
    sample["exact_output"] = JSONValue(true);
    sample["output_sha256"] = JSONValue(expectedSha256);
    return sample;
}

private JSONValue syntheticMojibakeCase(string name, string fixtureSha256, string expectedSha256) {
    JSONValue[] samples;
    foreach (i; 0 .. 4)
        samples ~= syntheticMojibakeSample(i % 2 == 0 ? "scrubbed" : "ftfy", expectedSha256);
    JSONValue c = JSONValue(["name": JSONValue(name)]);
    c["fixture_sha256"] = JSONValue(fixtureSha256);
    c["expected_sha256"] = JSONValue(expectedSha256);
    c["python_packages_acquisition_order"] =
        JSONValue([JSONValue("ftfy==6.3.1"), JSONValue("wcwidth==0.8.4")]);
    c["ftfy_version"] = JSONValue("ftfy (fixes text for you), version 6.3.1 (synthetic self-test)");
    c["timeout_seconds"] = JSONValue(30.0);
    c["max_rss_bytes"] = JSONValue(1_048_576);
    c["samples"] = JSONValue(samples);
    return c;
}

private JSONValue syntheticMainContentCase() {
    JSONValue[] samples;
    foreach (i; 0 .. 4)
        samples ~= syntheticSample(i % 2 == 0 ? "scrubbed" : "trafilatura", 0);

    JSONValue[] fixtures;
    foreach (i; 0 .. expectedHeldOutFixtureCount) {
        JSONValue fixture = JSONValue(["id": JSONValue("fixture-" ~ i.to!string)]);
        foreach (toolName; ["scrubbed", "trafilatura"]) {
            JSONValue entry = JSONValue(["status": JSONValue("produced")]);
            entry["precision"] = JSONValue(1.0);
            entry["recall"] = JSONValue(1.0);
            entry["withoutLeaks"] = JSONValue(0);
            fixture[toolName] = entry;
        }
        fixtures ~= fixture;
    }
    JSONValue scoring = JSONValue(["gold_fixture_count": JSONValue(expectedHeldOutFixtureCount)]);
    scoring["fixtures"] = JSONValue(fixtures);
    foreach (toolName; ["scrubbed", "trafilatura"]) {
        JSONValue summary = JSONValue(["extractedCount": JSONValue(expectedHeldOutFixtureCount)]);
        summary["abstainedCount"] = JSONValue(0);
        summary["meanPrecision"] = JSONValue(1.0);
        summary["meanRecall"] = JSONValue(1.0);
        summary["withoutLeakTotal"] = JSONValue(0);
        scoring[toolName] = summary;
    }

    JSONValue c = JSONValue(["name": JSONValue("main-content/scrubbed-vs-trafilatura")]);
    c["scrubbed_binary_sha256"] = JSONValue(syntheticHash("scrubbed-binary-main-content"));
    c["trafilatura_binary_sha256"] = JSONValue(syntheticHash("trafilatura-binary"));
    c["trafilatura_version"] = JSONValue("Trafilatura 1.x (synthetic self-test)");
    c["held_out_corpus_commit"] = JSONValue(expectedHeldOutCommit);
    c["held_out_fixture_count"] = JSONValue(expectedHeldOutFixtureCount);
    c["python_packages_acquisition_order"] = JSONValue([JSONValue("trafilatura==1.0.0")]);
    c["timeout_seconds"] = JSONValue(30.0);
    c["max_rss_bytes"] = JSONValue(1_048_576);
    c["samples"] = JSONValue(samples);
    c["reproducibility"] =
        JSONValue(["scrubbed": JSONValue(true), "trafilatura": JSONValue(true)]);
    c["scoring"] = scoring;
    return c;
}

private JSONValue syntheticLanguageIdCase() {
    JSONValue[] samples;
    foreach (i; 0 .. 4)
        samples ~= syntheticSample(i % 2 == 0 ? "scrubbed" : "langdetect", 0);

    JSONValue[] languages;
    foreach (lang; expectedOriginalLanguageIdLanguages) {
        JSONValue entry = JSONValue(["language": JSONValue(lang)]);
        foreach (toolName; ["scrubbed", "langdetect"]) {
            JSONValue outcome = JSONValue(["status": JSONValue("produced")]);
            outcome["predicted"] = JSONValue(lang);
            entry[toolName] = outcome;
        }
        entry["agreement"] = JSONValue(true);
        languages ~= entry;
    }
    auto languageCount = cast(int) expectedOriginalLanguageIdLanguages.length;
    JSONValue scoring = JSONValue(["language_count": JSONValue(languageCount)]);
    scoring["agreement_rate"] = JSONValue(1.0);
    scoring["agreement_count"] = JSONValue(languageCount);
    foreach (toolName; ["scrubbed", "langdetect"]) {
        JSONValue summary = JSONValue(["correctCount": JSONValue(languageCount)]);
        summary["accuracy"] = JSONValue(1.0);
        if (toolName == "scrubbed") summary["abstainedCount"] = JSONValue(0);
        else summary["errorCount"] = JSONValue(0);
        scoring[toolName] = summary;
    }
    scoring["languages"] = JSONValue(languages);

    JSONValue[] originalLanguages;
    foreach (lang; expectedOriginalLanguageIdLanguages) originalLanguages ~= JSONValue(lang);

    JSONValue c = JSONValue(["name": JSONValue("language-id/scrubbed-vs-langdetect")]);
    c["scrubbed_binary_sha256"] = JSONValue(syntheticHash("scrubbed-binary-language-id"));
    c["langdetect_driver_sha256"] = JSONValue(syntheticHash("langdetect-driver"));
    c["python_packages_acquisition_order"] = JSONValue([JSONValue("langdetect==1.0.9")]);
    c["detector_factory_seed"] = JSONValue(0);
    c["timeout_seconds"] = JSONValue(30.0);
    c["max_rss_bytes"] = JSONValue(1_048_576);
    c["original_languages"] = JSONValue(originalLanguages);
    c["samples"] = JSONValue(samples);
    c["reproducibility"] =
        JSONValue(["scrubbed": JSONValue(true), "langdetect": JSONValue(true)]);
    c["scoring"] = scoring;
    return c;
}

private JSONValue syntheticPiiCase() {
    JSONValue[] samples;
    foreach (i; 0 .. 4)
        samples ~= syntheticSample(i % 2 == 0 ? "scrubbed" : "presidio", 0);

    JSONValue[] categoryNames;
    foreach (cat; expectedPiiCategories) categoryNames ~= JSONValue(cat);
    JSONValue scoring = JSONValue(["categories": JSONValue(categoryNames)]);
    foreach (toolName; ["scrubbed", "presidio"]) {
        JSONValue[string] perCategory;
        foreach (cat; expectedPiiCategories) {
            JSONValue entry = JSONValue(["truePositive": JSONValue(1)]);
            entry["falsePositive"] = JSONValue(0);
            entry["falseNegative"] = JSONValue(0);
            entry["precision"] = JSONValue(1.0);
            entry["recall"] = JSONValue(1.0);
            perCategory[cat] = entry;
        }
        scoring[toolName] = JSONValue(perCategory);
    }

    JSONValue[] supportedEntities;
    foreach (entity; expectedPresidioSupportedEntities) supportedEntities ~= JSONValue(entity);

    JSONValue c = JSONValue(["name": JSONValue("pii-four-class/scrubbed-vs-presidio")]);
    c["scrubbed_binary_sha256"] = JSONValue(syntheticHash("scrubbed-binary-pii"));
    c["presidio_driver_sha256"] = JSONValue(syntheticHash("presidio-driver"));
    c["presidio_spacy_model"] = JSONValue("en_core_web_sm");
    c["presidio_python_version"] = JSONValue("Python 3.x (synthetic self-test)");
    c["python_packages_acquisition_order"] = JSONValue([
        JSONValue("presidio-analyzer==2.2.0"),
        JSONValue("presidio-anonymizer==2.2.0"),
        JSONValue("en-core-web-sm @ https://example.invalid/en_core_web_sm-3.8.0.whl")]);
    c["timeout_seconds"] = JSONValue(30.0);
    c["max_rss_bytes"] = JSONValue(1_048_576);
    c["presidio_supported_entities"] = JSONValue(supportedEntities);
    c["samples"] = JSONValue(samples);
    c["reproducibility"] = JSONValue(["scrubbed": JSONValue(true), "presidio": JSONValue(true)]);
    c["fixture_spec_sha256"] = JSONValue(syntheticHash("fixture-spec"));
    c["fixture_count"] = JSONValue(4);
    c["scoring"] = scoring;
    return c;
}

// A complete, internally-consistent synthetic report: every case `checkReport`
// currently validates is present and shaped to pass. Each self-test scenario
// below starts from a fresh call to this (JSONValue is reference-typed for
// objects/arrays, so reusing one built report across scenarios would let an
// earlier scenario's mutation leak into a later one).
private JSONValue buildValidSyntheticReport() {
    JSONValue report = JSONValue(["schema": JSONValue("scrubbed-external-comparator-v1")]);
    report["harness_sha256"] = JSONValue(digest("benchmarks/external_comparator.d"));
    report["cases"] = JSONValue([
        syntheticMojibakeCase("mojibake/scrubbed-vs-ftfy", mojibakeFixtureSha256,
            mojibakeExpectedSha256),
        syntheticMojibakeCase("mojibake/scrubbed-vs-ftfy-windows1251",
            mojibakeWindows1251FixtureSha256, mojibakeWindows1251ExpectedSha256),
        syntheticMainContentCase(),
        syntheticLanguageIdCase(),
        syntheticPiiCase(),
    ]);
    return report;
}

private JSONValue withoutCase(JSONValue report, string caseName) {
    JSONValue[] kept;
    foreach (c; report["cases"].array)
        if (c["name"].str != caseName) kept ~= c;
    report["cases"] = JSONValue(kept);
    return report;
}

private JSONValue withCorruptedField(JSONValue report, string caseName, string field,
                                     JSONValue badValue) {
    JSONValue[] cases;
    foreach (c; report["cases"].array) {
        if (c["name"].str == caseName) c[field] = badValue;
        cases ~= c;
    }
    report["cases"] = JSONValue(cases);
    return report;
}

private JSONValue withCorruptedSample(JSONValue report, string caseName, size_t sampleIndex) {
    JSONValue[] cases;
    foreach (c; report["cases"].array) {
        if (c["name"].str == caseName) {
            auto samples = c["samples"].array;
            samples[sampleIndex]["status"] = JSONValue(9);
            samples[sampleIndex]["exact_output"] = JSONValue(false);
            c["samples"] = JSONValue(samples);
        }
        cases ~= c;
    }
    report["cases"] = JSONValue(cases);
    return report;
}

private JSONValue withBrokenInterleave(JSONValue report, string caseName) {
    JSONValue[] cases;
    foreach (c; report["cases"].array) {
        if (c["name"].str == caseName) {
            auto samples = c["samples"].array;
            samples[0]["tool"] = JSONValue("ftfy"); // must be "scrubbed" first
            c["samples"] = JSONValue(samples);
        }
        cases ~= c;
    }
    report["cases"] = JSONValue(cases);
    return report;
}

private void checkReportGate(string scenario, JSONValue report, bool shouldPass) {
    auto path = scratchFile("report-" ~ scenario);
    scope(exit) if (exists(path)) remove(path);
    write(path, report.toString());
    bool rejected;
    try checkReport(path);
    catch (Exception) rejected = true;
    if (shouldPass)
        require(!rejected, "valid synthetic report was wrongly rejected: " ~ scenario);
    else
        require(rejected, "invalid synthetic report was wrongly accepted: " ~ scenario);
}

// Runs the same four negative-control scenarios (corrupted expected hash,
// corrupted sample, broken A/B/A/B interleave, case omitted entirely)
// against one named mojibake case, so the CP1252 case and its Windows-1251
// sibling are proven to fail closed identically.
private void checkMojibakeCaseNegativeControl(string caseName, string label) {
    checkReportGate(label ~ "-corrupted-expected-hash",
        withCorruptedField(buildValidSyntheticReport(), caseName, "expected_sha256",
            JSONValue("BAD")), false);
    checkReportGate(label ~ "-corrupted-sample",
        withCorruptedSample(buildValidSyntheticReport(), caseName, 0), false);
    checkReportGate(label ~ "-broken-interleave",
        withBrokenInterleave(buildValidSyntheticReport(), caseName), false);
    checkReportGate(label ~ "-missing-case",
        withoutCase(buildValidSyntheticReport(), caseName), false);
}

private void checkReportGates() {
    checkReportGate("valid-baseline", buildValidSyntheticReport(), true);
    checkMojibakeCaseNegativeControl("mojibake/scrubbed-vs-ftfy", "cp1252");
    checkMojibakeCaseNegativeControl("mojibake/scrubbed-vs-ftfy-windows1251", "windows1251");
    writeln("external comparator report-check self-test passed: a valid synthetic report is ",
        "accepted, and both mojibake cases (CP1252 and Windows-1251) are independently ",
        "rejected on a corrupted expected hash, a corrupted sample, a broken A/B/A/B ",
        "interleave, or the case being omitted entirely");
}

int main(string[] args) {
    try {
        if (args.length == 2 && args[1] == "--self-test") {
            selfTest();
            return 0;
        }
        if (args.length == 3 && args[1] == "--check") {
            checkReport(args[2]);
            return 0;
        }
        stderr.writeln("usage: external_comparator_check --self-test | --check REPORT.json");
        return 2;
    } catch (Exception error) {
        stderr.writeln("external_comparator_check: ", error.msg);
        return 1;
    }
}
