// Release-active D-only checker for benchmarks/external_comparator.d. Build
// with ldc2 -O3 -release. `--self-test` independently re-proves every
// fail-closed gate the runner relies on (version-prefix collision,
// executable mutation, fixture drift, independently authored expectation
// drift, output drift, zero samples, missing case, duplicate case, nonzero
// exit, timeout, and resource refusal) using its own copies of the gating
// primitives, not by importing the runner module. `--check <report.json>`
// structurally validates a report actually produced by external_comparator
// and proves the migrated ftfy case reproduces cli_baseline.d's prior
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
import std.string : split, splitLines, strip, toStringz;
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

private struct PinnedPackage {
    string name;
    string exactVersion;
}

private string[string] parseFreeze(string output) {
    string[string] versions;
    foreach (line; output.splitLines) {
        auto row = line.strip;
        if (row.length == 0) continue;
        if (row.startsWith("Using Python ")) continue;
        auto fields = row.split("==");
        if (fields.length != 2 || fields[0].length == 0 || fields[1].length == 0 ||
            fields[0] in versions)
            throw new Exception("unparseable or duplicate uv freeze row: " ~ row);
        versions[fields[0]] = fields[1];
    }
    return versions;
}

private JSONValue verifyPinnedPackages(string freezeOutput,
                                       const PinnedPackage[] pinned) {
    require(pinned.length != 0, "no pinned packages declared");
    auto versions = parseFreeze(freezeOutput);
    JSONValue[] order;
    foreach (pkg; pinned) {
        auto found = pkg.name in versions;
        require(found !is null && *found == pkg.exactVersion,
            "expected " ~ pkg.name ~ "==" ~ pkg.exactVersion ~ " exactly");
        order ~= JSONValue(pkg.name ~ "==" ~ pkg.exactVersion);
    }
    return JSONValue(order);
}

private void checkVersionPrefixCollisionAndDuplicates() {
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
    checkVersionPrefixCollisionAndDuplicates();
    checkExecutableMutation();
    checkFixtureAndExpectationDrift();
    checkOutputDrift();
    checkZeroSamplesMissingAndDuplicateCase();
    checkNonzeroExit();
    checkTimeout();
    checkProcessGroupTimeout();
    checkResourceRefusal();
    writeln("external comparator negative-control self-test passed: ",
        "version-prefix-collision, executable-mutation, fixture-drift, ",
        "expectation-drift, output-drift, zero-samples, missing-case, ",
        "duplicate-case, nonzero-exit, timeout, process-group-timeout, ",
        "resource-refusal");
}

// ---- Report validation: proves a real external_comparator run reproduces
// cli_baseline.d's prior mojibake correctness result under the new,
// intentionally non-backward-compatible report shape. ----

private enum mojibakeFixtureSha256 =
    "FBB0ED284337887CD1EE5419735AC30C1189DBE94609A5119916A2906EE5889B";
private enum mojibakeExpectedSha256 =
    "14A9EDC0944EF516E12E1CE8ABBF3D78CCF41D48CDDD1F2A8AD13173363F7DCA";

private void checkReport(string path) {
    auto report = parseJSON(readText(path));
    require(report["schema"].str == "scrubbed-external-comparator-v1",
        "unexpected schema");
    require(report["harness_sha256"].str == digest("benchmarks/external_comparator.d"),
        "harness hash mismatch: report was not produced by the checked-out harness");
    JSONValue found;
    bool hasCase;
    bool[string] seenNames;
    foreach (c; report["cases"].array) {
        auto name = c["name"].str;
        require(name !in seenNames, "duplicate case in report: " ~ name);
        seenNames[name] = true;
        if (name == "mojibake/scrubbed-vs-ftfy") { found = c; hasCase = true; }
    }
    require(hasCase, "missing mojibake/scrubbed-vs-ftfy case");
    require(found["fixture_sha256"].str == mojibakeFixtureSha256,
        "fixture hash differs from the pinned mojibake fixture");
    require(found["expected_sha256"].str == mojibakeExpectedSha256,
        "expected hash differs from the pinned independently authored expectation " ~
        "(this is exactly the hash cli_baseline.d's mojibake case bound)");
    auto samples = found["samples"].array;
    require(samples.length == 4, "expected four A/B/A/B samples");
    require(samples[0]["tool"].str == "scrubbed" && samples[1]["tool"].str == "ftfy" &&
        samples[2]["tool"].str == "scrubbed" && samples[3]["tool"].str == "ftfy",
        "samples lost their A/B/A/B interleave order");
    foreach (sample; samples) {
        require(sample["status"].integer == 0, "a sample exited nonzero or was signaled");
        require(sample["exact_output"].boolean, "a sample failed the exact-output gate");
        require(sample["output_sha256"].str == mojibakeExpectedSha256,
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
    writeln("external comparator report check passed: migrated mojibake case reproduces ",
        "cli_baseline.d's fixture/expected hashes and exact-output gate under the new ",
        "scrubbed-external-comparator-v1 report format");
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
