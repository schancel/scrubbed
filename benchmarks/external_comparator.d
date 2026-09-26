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

import core.sys.posix.signal : kill, SIGKILL, SIGTERM;
import core.sys.posix.sys.stat : chmod, S_IRUSR, S_IXUSR;
import core.sys.posix.sys.wait : WEXITSTATUS, WIFEXITED, WNOHANG, WTERMSIG,
    waitpid;
import core.sys.posix.unistd : _exit, dup2, execvp, fork, setpgid;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.algorithm.searching : canFind, endsWith, startsWith;
import std.conv : to;
import std.digest : toHexString;
import std.digest.sha : sha256Of;
import std.file : copy, exists, mkdirRecurse, read, readText, remove,
    rmdirRecurse, tempDir, write;
import std.json : JSONValue;
import std.path : buildPath, dirName, dirSeparator, relativePath;
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
        if (args.length != 3)
            throw new Exception("usage: external_comparator SCRUBBED_BINARY FTFY_BINARY");
        auto os = checked(["uname", "-s"]);
        bool darwin = os == "Darwin";
        require(darwin || os == "Linux", "BSD/GNU time only");
        auto root = buildPath(tempDir, "scrubbed-external-comparator-" ~ randomUUID.toString);
        mkdirRecurse(root);
        scope(exit) rmdirRecurse(root);
        auto python = buildPath(dirName(args[2]), "python");
        auto pythonVersion = checked([python, "--version"]);

        auto mojibake = compareFtfyMojibake(args[1], args[2], python, root, darwin,
            60.0, 512L * 1024 * 1024);
        auto report = assembleReport([mojibake], ["mojibake/scrubbed-vs-ftfy"]);
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
            !published.canFind(args[2]) && !published.canFind(checked(["uname", "-n"])),
            "result contains a private run path or hostname");
        writeln(published);
        return 0;
    } catch (Exception error) {
        stderr.writeln("external_comparator: ", error.msg);
        return 1;
    }
}
