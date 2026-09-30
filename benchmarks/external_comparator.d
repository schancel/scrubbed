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
import domain.document_metadata : DocumentMetadata, decodeDocumentMetadataV1,
    encodeDocumentMetadataV2;
import domain.language_id : LanguageDetectionStatus, decodeLanguageIdentity;
import effects.language_id_detect_stage : languageIdDetectExtensionKeyV1,
    languageIdDetectStageKeyV1;
import experiments.html_main_content.token_overlap : containsNormalized,
    mergeTokenCounts, normalized, scoreTokenOverlap, tokenCounts;
import std.algorithm.iteration : filter, map;
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
import std.string : fromStringz, indexOf, split, splitLines, strip, toLower,
    toStringz;
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

// `url` is non-empty for a package pinned by an exact download URL instead
// of a plain PyPI version (issue #302's spaCy model: `en_core_web_sm` has no
// ordinary versioned PyPI release, only a GitHub release-asset wheel, so
// `uv pip install <url>` and `uv pip freeze` both represent it as
// "name @ url" rather than "name==version" -- verified empirically, not
// assumed). Exactly one of `exactVersion`/`url` is set per declared package.
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
        if (row.startsWith("Using Python ")) continue; // uv environment notice
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

// Verifies every pinned package is present at its exact version or exact
// install URL (rejecting a prefix-collision version such as ftfy==6.3.10
// when 6.3.1 is pinned, a URL that doesn't match byte-for-byte, a
// version/URL type mismatch, and duplicate freeze rows), then returns the
// *declared* acquisition order as a JSON array bound into the case,
// independent of whatever row order `uv pip freeze` happened to print.
private JSONValue verifyPinnedPackages(string freezeOutput,
                                       const PinnedPackage[] pinned) {
    require(pinned.length != 0, "no pinned packages declared for acquisition");
    auto entries = parseFreeze(freezeOutput);
    JSONValue[] order;
    foreach (pkg; pinned) {
        auto found = pkg.name in entries;
        string observed = found is null ? "missing" :
            found.url.length != 0 ? pkg.name ~ " @ " ~ found.url :
            pkg.name ~ "==" ~ found.exactVersion;
        if (pkg.url.length != 0) {
            require(found !is null && found.url == pkg.url,
                "expected " ~ pkg.name ~ " @ " ~ pkg.url ~ " exactly, observed " ~ observed);
            order ~= JSONValue(pkg.name ~ " @ " ~ pkg.url);
        } else {
            require(found !is null && found.url.length == 0 &&
                found.exactVersion == pkg.exactVersion,
                "expected " ~ pkg.name ~ "==" ~ pkg.exactVersion ~ " exactly, observed " ~ observed);
            order ~= JSONValue(pkg.name ~ "==" ~ pkg.exactVersion);
        }
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
    // "run" is the required argparse subcommand (issue #377 found this
    // command array predates the subcommand CLI restructuring and would
    // exit 2 -- unrecognized/missing subcommand -- against the current
    // shipping CLI; the fix is scoped to the mojibake cases' own command
    // construction only).
    string[] scrubbedCommand = [scrubbedSnapshot.path, "run", "--input", fixture,
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

// ---- The Windows-1251 (Cyrillic) sibling of the ftfy/mojibake case above
// (issue #377, the remainder of #366's acceptance criteria that PR #376 did
// not close: a real ftfy-parity comparator case, not just an in-repo
// unittest). Same shape as compareFtfyMojibake exactly -- fixture/expectation
// bytes are generated deterministically and pinned by SHA-256 in source, the
// candidate and comparator run on the same fixture in A/B/A/B interleaved
// order, and correctness is gated by exact byte equality before any sample
// is retained. The fixture text below is independently authored for this
// ticket (a short original Russian sentence), not copied from ftfy's own
// test corpus (ftfy/tests/test-cases/in-the-wild.json). ----

private enum mojibakeWindows1251FixtureSha256 =
    "C1B6EDDA8EA799948C6F3E34D42E5224D316A157B9159DEB01593BDECD815248";
private enum mojibakeWindows1251ExpectedSha256 =
    "D9AC303E3E045729B922A123B5B9EC58DFEA3EC8B6DC46F89C47226C74DA3F85";

private void generateMojibakeWindows1251Fixture(string fixturePath, string expectedPath) {
    string damaged, clean;
    foreach (i; 0 .. 4096) {
        damaged ~= "РџСЂРёРІРµС‚, РґСЂСѓРі! РЎРµРіРѕРґРЅСЏ С…РѕСЂРѕС€Р°СЏ РїРѕРіРѕРґР° Рё СЏ РёРґСѓ РіСѓР»СЏС‚СЊ.\n";
        clean ~= "Привет, друг! Сегодня хорошая погода и я иду гулять.\n";
    }
    write(fixturePath, damaged);
    write(expectedPath, clean);
    require(digest(fixturePath) == mojibakeWindows1251FixtureSha256,
        "windows-1251 mojibake fixture drift: generated bytes no longer match the pinned fixture hash");
    require(digest(expectedPath) == mojibakeWindows1251ExpectedSha256,
        "independently authored windows-1251 expectation drift: generated bytes no longer match the pinned expected hash");
}

// Runs the scrubbed candidate and the pinned ftfy comparator on the same
// Windows-1251 fixture in A/B/A/B order, exactly mirroring
// compareFtfyMojibake above (same pinned packages, same gates, same
// interleave discipline).
private JSONValue compareFtfyMojibakeWindows1251(string scrubbedBinary,
                                                 string ftfyBinary,
                                                 string pythonBinary, string root,
                                                 bool darwin, double timeoutSeconds,
                                                 long maxRssBytes) {
    auto fixture = buildPath(root, "mojibake-windows1251.txt");
    auto expected = buildPath(root, "repaired-windows1251.txt");
    generateMojibakeWindows1251Fixture(fixture, expected);

    auto scrubbedSnapshot = snapshotExecutable(scrubbedBinary, root,
        "scrubbed-snapshot-windows1251");
    auto ftfySnapshot = snapshotExecutable(ftfyBinary, root, "ftfy-snapshot-windows1251");

    string ftfyVersion;
    foreach (line; checked([ftfySnapshot.path, "--help"]).splitLines)
        if (line.startsWith("ftfy (fixes text for you)")) ftfyVersion = line;
    require(ftfyVersion.length != 0, "ftfy CLI version was not discoverable");

    auto acquisitionOrder = verifyPinnedPackages(
        checked(["uv", "pip", "freeze", "--python", pythonBinary]),
        [PinnedPackage("ftfy", "6.3.1"), PinnedPackage("wcwidth", "0.8.4")]);

    auto outputPath = buildPath(root, "out-windows1251.txt");
    JSONValue[] samples;
    string[] scrubbedCommand = [scrubbedSnapshot.path, "run", "--input", fixture,
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
        require(exists(outputPath) && digest(outputPath) == mojibakeWindows1251ExpectedSha256,
            tool ~ " failed the exact-output quality gate");
        sample["tool"] = tool;
        sample["output_sha256"] = digest(outputPath);
        sample["exact_output"] = true;
        samples ~= sample;
    }
    verifySnapshot(scrubbedSnapshot);
    verifySnapshot(ftfySnapshot);
    require(samples.length != 0, "zero samples retained for mojibake/scrubbed-vs-ftfy-windows1251");
    require(samples.length == 4 && samples[0]["tool"].str == "scrubbed" &&
        samples[1]["tool"].str == "ftfy" && samples[2]["tool"].str == "scrubbed" &&
        samples[3]["tool"].str == "ftfy",
        "windows-1251 mojibake comparator lost its A/B/A/B interleave order");

    JSONValue result = JSONValue(["name": JSONValue("mojibake/scrubbed-vs-ftfy-windows1251")]);
    result["fixture_sha256"] = mojibakeWindows1251FixtureSha256;
    result["expected_sha256"] = mojibakeWindows1251ExpectedSha256;
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
            // "run" is the required argparse subcommand (issue #377/#418 --
            // this case's own command construction predates the subcommand
            // CLI restructuring the mojibake cases were already fixed for;
            // #377's fix explicitly scoped itself to the mojibake cases'
            // own command construction only, leaving this one broken).
            scrubbedCommand = [scrubbedSnapshot.path, "run", "--input", htmlInputDir,
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

// ---- The main-content/scrubbed-vs-justext case (issue #59's jusText
// next-slice contract, owner-approved 2026-09-30). Mirrors
// compareMainContentTrafilatura above exactly: same reused held-out corpus
// (`fetch_held_out.sh --emit-corpus-dir`, no new fixtures authored), same
// token_overlap.d precision/recall/without-leak scoring, same "quality
// reported, not gated" stance, same private-path/hostname redaction, and
// the same mutation-detection INTENT as the executable-snapshot-and-verify
// discipline elsewhere in this file (see point 3 below for why the
// mechanism itself has to differ here). Three real quirks, all empirically
// confirmed at implementation time (2026-09-30) by actually installing and
// running the pinned package, not assumed from documentation:
//
// 1. jusText 3.0.2's standalone `justext` console script was removed
//    upstream in favor of `python -m justext` (a real `uv pip install
//    justext==3.0.2` leaves no `justext` entry under the venv's `bin/`).
//    Its `-s STOPLIST`/`-o OUTPUT_FILE`/positional-HTML-file CLI genuinely
//    supports single-file invocation with no batch mode of its own -- the
//    per-file shell loop below exists only for that reason, the same
//    reason langdetect/presidio's own drivers are looped one file at a
//    time, not because of a bug like trafilatura's `--keep-dirs` one. A
//    second, real per-version quirk WAS found by running the pinned CLI
//    directly: `-o OUTPUT_FILE` is silently ignored (output goes to stdout
//    instead, no file is created, exit status still 0) unless `-o` is
//    given *before* the positional HTML file argument; `justextBatchScript`
//    below places it there deliberately, not incidentally.
// 2. Unlike trafilatura (which auto-detects each page's language
//    internally), jusText's `-s STOPLIST` argument is REQUIRED and selects
//    the exact word list its own boilerplate classifier scores paragraphs
//    against. Running it against a page in the wrong language is not a
//    fair, task-equivalent comparison (this issue's own long-standing
//    "Alternatives" policy: "Compare only exact-output quality-matched
//    tasks with comparable I/O boundaries; normalize no hidden work
//    away") -- empirically confirmed at implementation time: `-s English`
//    against this corpus's own German-language fixture 01 produces zero
//    output bytes, while the identical page against `-s German` produces
//    1,002 bytes of real extracted text. `justextStoplistFor` below selects
//    each fixture's stoplist from that fixture's own already-present,
//    reused (never authored or invented) HTML `lang` attribute -- covering
//    exactly the three languages this pinned 20-URL corpus actually
//    contains (German/English/French, both single- and double-quoted
//    attribute forms empirically confirmed present) -- with an explicit
//    English default for the two fixtures that declare no `lang` attribute
//    at all. `-s None` ("language-independent mode") was also tried and
//    rejected as a fallback: it is a real, verified crash in the pinned
//    3.0.2 CLI (`TypeError: unhashable type: 'set'` inside
//    `justext.core.classify_paragraphs`'s own `define_stoplist` call), not
//    a usable option.
// 3. jusText has no console-script binary of its own (point 1 above), and
//    -- unlike trafilatura's own console script, a tiny wrapper whose
//    shebang line still points at its ORIGINAL, unmoved interpreter even
//    after the wrapper file itself is snapshotted/copied elsewhere by
//    `snapshotExecutable` -- the interpreter binary itself cannot safely be
//    relocated that way: empirically confirmed at implementation time, a
//    uv-managed venv's own `bin/python` is a symlink into a shared,
//    unpacked CPython install (e.g. `~/.local/share/uv/python/cpython-...
//    /bin/python3.12`) whose own stdlib/path resolution depends on that
//    install's sibling `lib/` directory tree; a plain byte-for-byte copy
//    elsewhere (exactly what `snapshotExecutable` does for every other
//    tool in this file) reproducibly fails at Python startup ("Could not
//    find platform independent libraries <prefix>" / "ModuleNotFoundError:
//    No module named 'encodings'") because that sibling tree is left
//    behind. This case instead hashes the ORIGINAL, unmoved interpreter
//    path before and after the run (reusing `ExecutableSnapshot`/
//    `verifySnapshot` unchanged, just without the copy step) -- weaker
//    than a private immutable copy's TOCTOU protection, but strictly more
//    verification than langdetect/presidio's own python interpreters get
//    today (no mutation check on the interpreter at all) -- rather than
//    silently dropping mutation detection entirely. ----

private enum justextDefaultStoplist = "English";

// Exactly the three languages this pinned held-out corpus's own HTML `lang`
// attributes actually declare (German/English/French), plus the explicit
// default above for the two fixtures with no `lang` attribute at all --
// verified by direct inspection of the live corpus, not assumed.
private string justextStoplistForLangPrefix(string prefix) {
    switch (prefix) {
        case "de": return "German";
        case "en": return "English";
        case "fr": return "French";
        default: return justextDefaultStoplist;
    }
}

// Case-insensitive ASCII substring search starting at byte offset `from`,
// operating directly on the original bytes (never on a `toLower`-transformed
// copy, so returned indices always stay aligned to the original string --
// relevant because, unlike ASCII, some Unicode uppercase/lowercase mappings
// change UTF-8 byte length). `needle` must already be lowercase ASCII.
private ptrdiff_t indexOfAsciiCI(string haystack, string needle, size_t from) {
    if (needle.length == 0 || from > haystack.length || haystack.length < needle.length)
        return -1;
    foreach (i; from .. haystack.length - needle.length + 1) {
        bool match = true;
        foreach (j; 0 .. needle.length) {
            auto c = haystack[i + j];
            auto lower = (c >= 'A' && c <= 'Z') ? cast(char)(c + 32) : c;
            if (lower != needle[j]) { match = false; break; }
        }
        if (match) return cast(ptrdiff_t) i;
    }
    return -1;
}

// True when the byte immediately before a `lang=` match at `matchIndex`
// cannot be part of a longer attribute name -- i.e. `matchIndex` is the
// start of the tag, or the preceding byte is whitespace or `:` (accepting
// the XHTML `xml:lang` spelling). Any other preceding byte (a letter,
// digit, `-`, `_`, `.`, ...) means this `lang=` is the tail of some other
// attribute name entirely, such as `data-lang=`, and must be skipped.
private bool isLangAttributeBoundary(string tag, size_t matchIndex) {
    if (matchIndex == 0) return true;
    auto before = tag[matchIndex - 1];
    return before == ' ' || before == '\t' || before == '\n' || before == '\r' ||
        before == ':';
}

// Extracts the actual `lang="xx"`/`lang='xx'` (or `xml:lang=...`) attribute's
// two-letter prefix from the opening `<html ...>` tag only (a plain
// substring scan, not a full HTML parse -- this only selects which of
// jusText's inbuilt stoplists to use, it is never treated as document
// content or scored). Case-insensitive (`<HTML LANG="DE">` is real, legal
// HTML) and scoped to the `<html>` tag specifically, skipping any `lang=`
// match that is actually the tail of a longer attribute name (`data-lang=`,
// `xlang=`, ...) rather than the `lang`/`xml:lang` attribute itself, so an
// unrelated attribute can never influence the choice. Returns "" when no
// `<html>` tag or no genuine `lang` attribute is present (e.g. this
// corpus's own fixture 02, a bare `<html>` with no lang attribute at all).
private string htmlLangPrefix(string html) {
    auto tagStart = indexOfAsciiCI(html, "<html", 0);
    if (tagStart < 0) return "";
    auto tagEnd = html.indexOf(">", tagStart);
    if (tagEnd < 0) return "";
    auto tag = html[tagStart .. tagEnd];
    size_t searchFrom = 0;
    while (true) {
        auto langIndex = indexOfAsciiCI(tag, "lang=", searchFrom);
        if (langIndex < 0) return "";
        if (!isLangAttributeBoundary(tag, cast(size_t) langIndex)) {
            searchFrom = cast(size_t) langIndex + 5;
            continue;
        }
        auto valueStart = cast(size_t) langIndex + 5;
        if (valueStart >= tag.length) return "";
        auto quote = tag[valueStart];
        if (quote != '"' && quote != '\'') {
            searchFrom = valueStart;
            continue;
        }
        auto valueEnd = tag.indexOf(quote, valueStart + 1);
        if (valueEnd <= cast(ptrdiff_t) valueStart) return "";
        auto value = tag[valueStart + 1 .. valueEnd];
        return value.length >= 2 ? value[0 .. 2].toLower : "";
    }
}

private string justextStoplistFor(string html) {
    return justextStoplistForLangPrefix(htmlLangPrefix(html));
}

// One shell-loop sample = one full pass over all held-out fixtures, one
// `python -m justext` invocation per file (its only supported single-file
// shape -- it has no batch mode of its own, mirroring langdetect/presidio's
// own drivers' precedent above/below). Each fixture's own selected stoplist
// travels alongside its path as an interleaved (file, stoplist) argument
// pair. `-o` is placed before the positional HTML file deliberately (see
// this case's own header comment: giving it afterward is a real, verified
// per-version quirk that silently sends output to stdout instead).
private string justextBatchScript() {
    return "python=\"$1\"; outdir=\"$2\"; shift 2; status=0; " ~
        "while [ $# -gt 0 ]; do f=\"$1\"; lang=\"$2\"; shift 2; " ~
        "base=$(basename \"$f\"); " ~
        "\"$python\" -m justext -s \"$lang\" -o \"$outdir/${base%.html}.txt\" \"$f\" " ~
        "|| status=$?; done; exit \"$status\"";
}

private JSONValue compareMainContentJustext(string scrubbedBinary,
        string justextPython, string root, bool darwin, double timeoutSeconds,
        long maxRssBytes) {
    auto scrubbedSnapshot = snapshotExecutable(scrubbedBinary, root, "scrubbed-mc-justext-snapshot");
    // Hashes the jusText interpreter IN PLACE, at its own original path --
    // never relocated/copied -- and verifies that hash again after the run
    // (point 3 of this case's header comment: relocating a uv-managed
    // venv's own `bin/python` the way `snapshotExecutable` copies every
    // other tool's executable reproducibly breaks Python's own stdlib path
    // resolution). `justextPython` is used directly as the invoked path
    // below; `ExecutableSnapshot`/`verifySnapshot` are reused unchanged for
    // the hash-compare mechanics only, never for a private copy.
    auto justextSnapshot = ExecutableSnapshot(justextPython, digest(justextPython));

    auto acquisitionOrder = verifyPinnedPackages(
        checked(["uv", "pip", "freeze", "--python", justextPython]),
        [PinnedPackage("justext", "3.0.2"), PinnedPackage("lxml", "6.1.3"),
         PinnedPackage("lxml-html-clean", "0.4.5")]);

    string justextVersion;
    foreach (line; checked([justextSnapshot.path, "-m", "justext", "-V"]).splitLines)
        if (line.startsWith("__main__.py: jusText v")) justextVersion = line;
    require(justextVersion.length != 0, "jusText CLI version was not discoverable via -V");

    // Corpus acquisition: reuses issue #26's own pinned held-out corpus and
    // scoring module unmodified via the additive `--emit-corpus-dir` flag,
    // exactly as compareMainContentTrafilatura does above (its own,
    // separate materialization -- each case in this file is independently
    // self-contained and independently callable). A nonzero exit here
    // (network failure, resolution failure, a checked-out commit that
    // doesn't match the pin) fails the whole case closed.
    auto corpusDir = buildPath(root, "held-out-corpus-justext");
    auto heldOutReportPath = buildPath(root, "held-out-report-justext.json");
    checked(["experiments/html_main_content/fetch_held_out.sh",
        "--emit-corpus-dir", corpusDir, heldOutReportPath]);

    auto gold = parseJSON(readText(buildPath(corpusDir, "gold.json")));
    auto goldFixtures = gold["fixtures"].array;
    require(goldFixtures.length == expectedHeldOutFixtureCount,
        "held-out corpus did not resolve all " ~
        expectedHeldOutFixtureCount.to!string ~ " pinned fixtures: got " ~
        goldFixtures.length.to!string);

    auto htmlInputDir = buildPath(root, "held-out-html-only-justext");
    auto htmlFiles = materializeHtmlOnlyCorpus(corpusDir, htmlInputDir, goldFixtures);
    string[] scrubbedOutputNames = htmlFiles; // scrubbed mirrors the input file name exactly.
    string[] justextOutputNames;
    foreach (name; htmlFiles) justextOutputNames ~= name[0 .. $ - 5] ~ ".txt"; // strip ".html"

    // Stoplist selection reuses the same already-materialized HTML bytes
    // (never re-fetched, never a second corpus) -- each fixture's chosen
    // stoplist is bound into the published report below, per fixture, so
    // the exact selection is independently auditable.
    string[] justextStoplists;
    foreach (name; htmlFiles)
        justextStoplists ~= justextStoplistFor(readText(buildPath(htmlInputDir, name)));
    string[] justextArgs;
    foreach (i, name; htmlFiles) {
        justextArgs ~= buildPath(htmlInputDir, name);
        justextArgs ~= justextStoplists[i];
    }

    JSONValue[] samples;
    string[2] scrubbedOutputDirs, justextOutputDirs;
    size_t scrubbedSampleIndex, justextSampleIndex;
    string[] scrubbedCommand, justextCommand;

    foreach (index; 0 .. 4) {
        bool useScrubbed = index % 2 == 0;
        auto tool = useScrubbed ? "scrubbed" : "justext";
        JSONValue sample;
        if (useScrubbed) {
            auto outDir = buildPath(root, "scrubbed-out-justext-" ~ index.to!string);
            scrubbedCommand = [scrubbedSnapshot.path, "run", "--input", htmlInputDir,
                "--output", outDir, "--stage", "content=html-main-content",
                "--threads", "1"];
            sample = runBoundedSample(scrubbedCommand, darwin, timeoutSeconds);
            auto status = sample["status"].integer;
            // Same reasoning as compareMainContentTrafilatura above: exit 1
            // is an expected content-driven quarantine on this real corpus,
            // not a crash; the reproducibility check below is what actually
            // catches a genuine failure.
            require(status == 0 || status == 1,
                "scrubbed exited with a status that is neither a clean run nor an " ~
                "expected content-driven quarantine: " ~ status.to!string);
            scrubbedOutputDirs[scrubbedSampleIndex++] = outDir;
        } else {
            auto outDir = buildPath(root, "justext-out-" ~ index.to!string);
            mkdirRecurse(outDir);
            justextCommand = ["/bin/sh", "-c", justextBatchScript(), "sh",
                justextSnapshot.path, outDir] ~ justextArgs;
            sample = runBoundedSample(justextCommand, darwin, timeoutSeconds);
            require(sample["status"].integer == 0,
                "jusText batch invocation exited nonzero: " ~
                sample["status"].integer.to!string);
            justextOutputDirs[justextSampleIndex++] = outDir;
        }
        auto peakRss = sample["peak_rss_bytes"].integer;
        require(peakRss <= maxRssBytes,
            tool ~ " exceeded the declared resource bound: " ~ peakRss.to!string ~
            " > " ~ maxRssBytes.to!string ~ " bytes");
        sample["tool"] = tool;
        samples ~= sample;
    }
    verifySnapshot(scrubbedSnapshot);
    verifySnapshot(justextSnapshot);
    require(samples.length == 4 && samples[0]["tool"].str == "scrubbed" &&
        samples[1]["tool"].str == "justext" && samples[2]["tool"].str == "scrubbed" &&
        samples[3]["tool"].str == "justext",
        "main-content/justext comparator lost its A/B/A/B interleave order");

    auto scrubbedSignatureA = directorySignature(scrubbedOutputDirs[0], scrubbedOutputNames);
    auto scrubbedSignatureB = directorySignature(scrubbedOutputDirs[1], scrubbedOutputNames);
    require(scrubbedSignatureA == scrubbedSignatureB,
        "scrubbed produced non-reproducible output between its own two timed samples");
    auto justextSignatureA = directorySignature(justextOutputDirs[0], justextOutputNames);
    auto justextSignatureB = directorySignature(justextOutputDirs[1], justextOutputNames);
    require(justextSignatureA == justextSignatureB,
        "jusText produced non-reproducible output between its own two timed samples");

    string[] scrubbedOutputPaths, justextOutputPaths;
    foreach (name; scrubbedOutputNames) scrubbedOutputPaths ~= buildPath(scrubbedOutputDirs[0], name);
    foreach (name; justextOutputNames) justextOutputPaths ~= buildPath(justextOutputDirs[0], name);
    auto scrubbedScore = scoreToolAgainstGold(scrubbedOutputPaths, goldFixtures);
    auto justextScore = scoreToolAgainstGold(justextOutputPaths, goldFixtures);

    JSONValue[] combinedFixtures;
    foreach (i; 0 .. goldFixtures.length) {
        JSONValue entry = JSONValue(["id": JSONValue(format("%02d", i + 1))]);
        entry["scrubbed"] = fixtureEntryJson(scrubbedScore.perFixture[i]);
        entry["justext"] = fixtureEntryJson(justextScore.perFixture[i]);
        entry["justext_stoplist"] = JSONValue(justextStoplists[i]);
        combinedFixtures ~= entry;
    }
    JSONValue scoring = JSONValue(["gold_fixture_count": JSONValue(goldFixtures.length)]);
    scoring["scrubbed"] = toolSummaryJson(scrubbedScore);
    scoring["justext"] = toolSummaryJson(justextScore);
    scoring["fixtures"] = JSONValue(combinedFixtures);

    JSONValue result = JSONValue(["name": JSONValue("main-content/scrubbed-vs-justext")]);
    result["scrubbed_binary_sha256"] = scrubbedSnapshot.sha256;
    result["justext_python_sha256"] = justextSnapshot.sha256;
    result["justext_version"] = justextVersion;
    result["justext_stoplist_policy"] =
        "selected per fixture from that fixture's own already-present HTML lang attribute " ~
        "(de->German, en->English, fr->French), defaulting to English when no lang " ~
        "attribute is present; jusText's -s STOPLIST argument is required, never inferred " ~
        "by the tool itself";
    result["held_out_corpus_commit"] = gold["trafilaturaCommit"].str;
    result["held_out_fixture_count"] = goldFixtures.length;
    result["python_packages_acquisition_order"] = acquisitionOrder;
    result["scrubbed_command"] = publicCommandGeneric(scrubbedCommand,
        [scrubbedSnapshot.path: "<scrubbed-binary>"], root);
    result["justext_command"] = publicCommandGeneric(justextCommand,
        [justextSnapshot.path: "<justext-python>"], root);
    result["timeout_seconds"] = timeoutSeconds;
    result["max_rss_bytes"] = maxRssBytes;
    result["samples"] = JSONValue(samples);
    result["reproducibility"] = JSONValue([
        "scrubbed": JSONValue(true),
        "justext": JSONValue(true),
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

// Since #300 Slice 2 (`effects.language_id_detect_stage`), `language-id-
// detect` no longer emits a standalone `scrubbed:language-id:v1` sidecar
// directly: it writes that same encoded record, unchanged, into the shared
// `document-metadata:v1` envelope's own `extension` array (as the
// `languageIdDetectExtensionKeyV1` ("language-id") entry's hex-encoded
// opaque value), published by the paired `document-metadata-publish` stage.
// Unlike the PII case's structured-section payload (a large, JSON-shaped
// `pii-audit-v1` document requiring the `document-metadata:v2` envelope),
// `language-id-detect` writes a small scalar via `.withExtensionField`, so
// the two-stage chain here never produces a structured section and the
// publish stage always emits the plain, unchanged `document-metadata:v1`
// wire (see `effects.document_metadata_publish_stage`'s per-document v1/v2
// choice) -- this unwraps that one level via the existing
// `decodeDocumentMetadataV1` domain function, then decodes the
// `LanguageIdentityRecord` from the unwrapped extension value exactly as
// before.
private LangIdOutcome scoreScrubbedLanguageId(string sidecarPath, string fixturePath,
                                              string goldLanguage) {
    auto expectedId = DocumentId.from(SourceLocator("local-files:v1",
        resolveRealPath(fixturePath), "."));
    auto envelope = decodeDocumentMetadataV1(expectedId, readText(sidecarPath));
    auto languageIdFields = envelope.extensionFields
        .filter!(f => f.key == languageIdDetectExtensionKeyV1).array;
    require(languageIdFields.length == 1,
        "expected exactly one language-id extension field, found " ~
        languageIdFields.length.to!string);
    require(languageIdFields[0].sourceStage == languageIdDetectStageKeyV1,
        "language-id extension field has unexpected sourceStage: " ~
        languageIdFields[0].sourceStage);
    auto record = decodeLanguageIdentity(languageIdFields[0].value, expectedId,
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
// wrapping single-file invocations that originally matched issue #311's own
// `scrubbed run --input FILE --output FILE --sidecar-output FILE --stage
// id=language-id-detect --threads 1` shape. #300 Slice 2 (commit reachable
// via `effects.language_id_detect_stage`) moved `language-id-detect` onto
// the annotate-only `SideOutputCapability.none` shape (it writes into the
// shared `DocumentMetadata` accumulator's extension fields, mirroring
// `effects.html_metadata_annotate_stage`/`effects.compressibility_annotate_
// stage`), published by the separate `document-metadata-publish` terminal
// stage -- `--stage id=language-id-detect` alone no longer produces a side
// output and now fails "--sidecar-output requires a side-output-producing
// plan" (issue #418, the same root cause already fixed for the PII case in
// issue #412/PR #419: see that fix's `piiScrubbedBatchScript` for the
// identical two-stage chain pattern). `/usr/bin/time` (added by the caller
// via runBoundedSample) wraps this whole shell process, so one timed sample
// still times one full pass over every fixture, matching the
// mojibake/trafilatura cases' own methodology.
private string languageIdScrubbedBatchScript() {
    return "scrubbed=\"$1\"; outdir=\"$2\"; sidecardir=\"$3\"; shift 3; status=0; " ~
        "for f in \"$@\"; do base=$(basename \"$f\"); stem=${base%.txt}; " ~
        "\"$scrubbed\" run --input \"$f\" --output \"$outdir/$stem.out\" " ~
        "--sidecar-output \"$sidecardir/$stem.sidecar\" " ~
        "--stage lang=language-id-detect --stage pub=document-metadata-publish " ~
        "--threads 1 || status=$?; done; exit \"$status\"";
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

// ---- The pii-four-class/scrubbed-vs-presidio case (issue #302's accepted
// next-slice contract). Like the trafilatura and language-id cases above,
// correctness here is scored by precision/recall against authored gold
// spans rather than exact-byte equality, computed per category (email/
// phone/card/ip -- the only four categories `pii-four-class` implements) for
// BOTH tools symmetrically against the same fixture set; neither tool's
// output is ever treated as the other's ground truth. All five fixture
// texts and their gold spans are originally authored here (no scraped or
// real PII-bearing text anywhere): emails use RFC 2606 documentation-
// reserved domains (example.com/.org/.net), phone numbers use the NANPA
// 555-01XX range reserved for fictional use, IPs use RFC 5737 TEST-NET
// documentation ranges, and card numbers are long-standing published
// payment-gateway test numbers (never real accounts) -- each fixture is
// additionally exercised with the pinned real Presidio install below and its
// gold spans confirmed to line up exactly with what a real run reports
// before being pinned, not merely handwritten. A few deliberate near-miss
// decoys (an invalid-domain "address", out-of-range IP octets, a card
// number one Luhn digit off) are not gold spans, to observe both tools'
// precision rather than only recall.
//
// **Owner-resolved model-size decision, empirically verified at
// implementation time (2026-09-27)**: `en_core_web_sm` (~12 MiB), not
// `en_core_web_lg`, is used. `AnalyzerEngine`'s own bare, unconfigured
// default has no model installed and instead attempts to auto-download the
// *large* model on first use; this driver never takes that path; it always
// constructs its own `NlpEngineProvider` naming the small model explicitly.
// The four entities compared here are Presidio's pattern/checksum
// recognizers, not NER-dependent, and the small model was empirically
// confirmed sufficient for all four in a real install (see
// benchmarks/README.md for the live sample) -- the large-model fallback the
// contract named was not needed and is not used.
//
// Presidio has no ordinary versioned PyPI release for `en_core_web_sm` (only
// a GitHub release-asset wheel, exactly as `python -m spacy download` itself
// installs it), so it is pinned by exact download URL rather than by
// version -- see `PinnedPackage.url` above, added for this case.
//
// Presidio's recognizer configuration is scoped to exactly the four overlap
// entities two ways: **by construction**, `presidio_driver.py` builds its
// `AnalyzerEngine` from a `RecognizerRegistry` containing only
// `EmailRecognizer`/`PhoneRecognizer`/`CreditCardRecognizer`/`IpRecognizer`
// -- requesting any other entity (PERSON, LOCATION, DATE_TIME, ...) from
// that analyzer instance raises, it does not silently no-op -- and
// **empirically**, `--print-scope` prints that analyzer's own
// `get_supported_entities()` at run time, verified below to be exactly the
// four overlap entities, not Presidio's full default catalog.
private enum presidioSpacyModelUrl =
    "https://github.com/explosion/spacy-models/releases/download/" ~
    "en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl";
private enum presidioSupportedEntitiesLine =
    "CREDIT_CARD,EMAIL_ADDRESS,IP_ADDRESS,PHONE_NUMBER";

private enum presidioDriverPath = "benchmarks/presidio_driver.py";
private enum presidioDriverSha256 =
    "BDE2AE9D44F8749A076BB4D6073921576C6E161FEF2BD888189971908F24EF34";

private enum piiCategories = ["email", "phone", "card", "ip"];

private struct PiiGoldSpanSpec { string category; string text; }
private struct PiiFixtureSpec { string fileName; string text; PiiGoldSpanSpec[] spans; }

private PiiFixtureSpec[] piiFixtures() {
    return [
        PiiFixtureSpec("01.txt",
            "Please route billing questions to billing.dept@example.com or call " ~
            "+1-415-555-0148 during business hours. Our staff-only mirror lives at " ~
            "203.0.113.10. A recent sandbox transaction used test card " ~
            "4111 1111 1111 1111 to confirm the checkout flow.\n",
            [PiiGoldSpanSpec("email", "billing.dept@example.com"),
             PiiGoldSpanSpec("phone", "+1-415-555-0148"),
             PiiGoldSpanSpec("ip", "203.0.113.10"),
             PiiGoldSpanSpec("card", "4111 1111 1111 1111")]),
        PiiFixtureSpec("02.txt",
            "Ticket reopened: customer reachable at 415-555-0148 or via " ~
            "a.tester@example.org. VPN egress was observed from 198.51.100.23. A " ~
            "refund is pending on card 5500 0000 0000 0004. Note: user@localhost " ~
            "was rejected as an invalid contact and 10.0.0.999 is not a routable " ~
            "address.\n",
            [PiiGoldSpanSpec("phone", "415-555-0148"),
             PiiGoldSpanSpec("email", "a.tester@example.org"),
             PiiGoldSpanSpec("ip", "198.51.100.23"),
             PiiGoldSpanSpec("card", "5500 0000 0000 0004")]),
        PiiFixtureSpec("03.txt",
            "Escalation contact: security.desk@example.net, alternate line " ~
            "+1-212-555-0199. Firewall logs show 192.0.2.77 attempting repeated " ~
            "logins. The disputed charge references card 378282246310005, already " ~
            "flagged by fraud review. A malformed serial like " ~
            "4111-1111-1111-1112 failed the checksum and was ignored.\n",
            [PiiGoldSpanSpec("email", "security.desk@example.net"),
             PiiGoldSpanSpec("phone", "+1-212-555-0199"),
             PiiGoldSpanSpec("ip", "192.0.2.77"),
             PiiGoldSpanSpec("card", "378282246310005")]),
        PiiFixtureSpec("04.txt",
            "Support macro: reach out at helpdesk@example.com or dial " ~
            "646-555-0136 first, then +1-415-555-0177 if unanswered. Internal " ~
            "telemetry uses 203.0.113.99 as a sinkhole address. Test refund card " ~
            "6011111111111117 was used for the demo store. The string " ~
            "999.999.999.999 in the log is not a valid host.\n",
            [PiiGoldSpanSpec("email", "helpdesk@example.com"),
             PiiGoldSpanSpec("phone", "646-555-0136"),
             PiiGoldSpanSpec("phone", "+1-415-555-0177"),
             PiiGoldSpanSpec("ip", "203.0.113.99"),
             PiiGoldSpanSpec("card", "6011111111111117")]),
        PiiFixtureSpec("05.txt",
            "Customer service line: (415) 555-0199, or email " ~
            "support.line@example.org for written requests. Our staging subnet " ~
            "exposes 203.0.113.5 to partners only. The mock invoice lists card " ~
            "4012888888881881 as fully refunded.\n",
            [PiiGoldSpanSpec("phone", "(415) 555-0199"),
             PiiGoldSpanSpec("email", "support.line@example.org"),
             PiiGoldSpanSpec("ip", "203.0.113.5"),
             PiiGoldSpanSpec("card", "4012888888881881")]),
    ];
}

private enum piiFixtureSpecSha256 =
    "38A60E319B25D84ABBE2363B85D68B33054B7E5BF1CFF64B3DCB5BD323D99539";

// Deterministic serialization of the authored fixture texts and their gold
// spans, hashed and pinned above in the same fixture/expectation-drift idiom
// as `mojibakeFixtureSha256`/`mojibakeExpectedSha256`: a silently edited
// fixture or gold label is caught before any subprocess runs. "\x00" never
// appears in the authored ASCII prose above, so it is a safe, unambiguous
// field separator for this hash input only (not a wire format).
private string encodePiiFixtureSpec(const PiiFixtureSpec[] fixtures) {
    string encoded;
    foreach (fixture; fixtures) {
        encoded ~= "FILE:" ~ fixture.fileName ~ "\x00";
        encoded ~= "TEXT:" ~ fixture.text ~ "\x00";
        foreach (span; fixture.spans)
            encoded ~= "SPAN:" ~ span.category ~ ":" ~ span.text ~ "\x00";
    }
    return encoded;
}

private struct PiiSpan { string category; size_t start; size_t end; }

// Resolves each gold span's literal text to a byte offset by searching the
// generated fixture text, rather than hand-computed offsets: any edit that
// makes a gold span's literal text missing or non-unique in its own fixture
// fails closed here, before any subprocess runs.
private PiiSpan[] resolvePiiGoldSpans(string text, const PiiGoldSpanSpec[] specs) {
    PiiSpan[] spans;
    foreach (spec; specs) {
        auto start = text.indexOf(spec.text);
        require(start >= 0, "pii fixture gold span text not found: " ~ spec.text);
        require(text[start + 1 .. $].indexOf(spec.text) < 0,
            "pii fixture gold span text is not unique in its fixture: " ~ spec.text);
        spans ~= PiiSpan(spec.category, cast(size_t) start,
            cast(size_t) start + spec.text.length);
    }
    return spans;
}

private bool piiSpansOverlap(PiiSpan a, PiiSpan b) {
    return a.category == b.category && a.start < b.end && b.start < a.end;
}

private struct PiiCategoryCounts { size_t truePositive; size_t falsePositive; size_t falseNegative; }

private PiiCategoryCounts[string] emptyPiiCategoryCounts() {
    PiiCategoryCounts[string] counts;
    foreach (category; piiCategories) counts[category] = PiiCategoryCounts.init;
    return counts;
}

// Greedily matches each gold span in this one fixture against an unused
// predicted span of the same category with any byte overlap (fixtures are
// authored with well-separated single-instance spans per category, so this
// has no order-dependent ambiguity), then folds the result into the running
// per-category totals: a matched gold span is a true positive, an unmatched
// gold span is a false negative, and an unmatched predicted span is a false
// positive. Never lets one tool's predictions serve as another's gold.
private void accumulatePiiFixtureScore(PiiCategoryCounts[string] totals,
        const PiiSpan[] predicted, const PiiSpan[] gold) {
    auto predictedUsed = new bool[](predicted.length);
    auto goldUsed = new bool[](gold.length);
    foreach (gi, g; gold)
        foreach (pi, p; predicted) {
            if (predictedUsed[pi] || goldUsed[gi]) continue;
            if (piiSpansOverlap(p, g)) { predictedUsed[pi] = true; goldUsed[gi] = true; break; }
        }
    foreach (gi, g; gold)
        if (goldUsed[gi]) ++totals[g.category].truePositive;
        else ++totals[g.category].falseNegative;
    foreach (pi, p; predicted)
        if (!predictedUsed[pi]) ++totals[p.category].falsePositive;
}

private JSONValue piiCategoryCountsJson(const ref PiiCategoryCounts counts) {
    auto precisionDenominator = counts.truePositive + counts.falsePositive;
    auto recallDenominator = counts.truePositive + counts.falseNegative;
    return JSONValue([
        "truePositive": JSONValue(counts.truePositive),
        "falsePositive": JSONValue(counts.falsePositive),
        "falseNegative": JSONValue(counts.falseNegative),
        "precision": JSONValue(precisionDenominator ?
            cast(double) counts.truePositive / precisionDenominator : 0.0),
        "recall": JSONValue(recallDenominator ?
            cast(double) counts.truePositive / recallDenominator : 0.0),
    ]);
}

private JSONValue piiToolScoringJson(const PiiCategoryCounts[string] totals) {
    JSONValue[string] fields;
    foreach (category; piiCategories) fields[category] = piiCategoryCountsJson(totals[category]);
    return JSONValue(fields);
}

// Parses one real `pii-four-class` sidecar audit (`encodePiiAuditV1`'s own
// JSON shape from `stages.pii_four_class.d`, read here as plain JSON --
// never imported -- since only the already-human-readable category/start/end
// fields are needed, not the full identity/policy binding that module
// encodes for its own production consumers). Each contributor within each
// union is one predicted PII span; a union's own merged bounds are not used,
// since a contributor's own start/end is the actual per-category detection.
// Since #300 Slice 3 (commit 384f404), `pii-four-class` no longer emits a
// standalone `scrubbed-pii-audit-v1` sidecar directly: it writes that same
// JSON, unchanged, into the `document-metadata:v2` envelope's own
// `structuredSections` array (as the `sectionId: "pii-audit"` entry's
// hex-encoded opaque `payload`), published by the paired
// document-metadata-publish stage. This unwraps that one level -- the
// `unions`/`contributors` shape parsed below is otherwise identical to the
// old top-level sidecar.
private ubyte[] decodeHex(string hex) {
    require(hex.length % 2 == 0, "structured section payload has odd hex length");
    ubyte[] bytes;
    bytes.reserve(hex.length / 2);
    foreach (i; 0 .. hex.length / 2) {
        int hi = hexNibble(hex[2 * i]);
        int lo = hexNibble(hex[2 * i + 1]);
        bytes ~= cast(ubyte)((hi << 4) | lo);
    }
    return bytes;
}

private int hexNibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    throw new Exception("structured section payload has non-hex byte");
}

private PiiSpan[] parseScrubbedPiiAudit(string sidecarPath) {
    auto envelope = parseJSON(readText(sidecarPath));
    JSONValue[] sections = "structuredSections" in envelope ?
        envelope["structuredSections"].array : [];
    auto piiSections = sections.filter!(s => s["sectionId"].str == "pii-audit").array;
    require(piiSections.length == 1,
        "expected exactly one pii-audit structured section, found " ~
        piiSections.length.to!string);
    require(piiSections[0]["sourceStage"].str == "pii-four-class",
        "pii-audit structured section has unexpected sourceStage: " ~
        piiSections[0]["sourceStage"].str);
    auto payloadBytes = decodeHex(piiSections[0]["payload"].str);
    auto audit = parseJSON(cast(string) payloadBytes);
    PiiSpan[] spans;
    foreach (unionSpan; audit["unions"].array)
        foreach (contributor; unionSpan["contributors"].array)
            spans ~= PiiSpan(contributor["category"].str,
                cast(size_t) contributor["start"].integer,
                cast(size_t) contributor["end"].integer);
    return spans;
}

// Parses one real `presidio_driver.py` run's "CATEGORY START END" lines
// (already scrubbed-audit-fashioned lowercase categories -- see the driver's
// own CATEGORY_NAME table). An "error:" line is never silently scored as an
// abstention here (unlike langdetect's own genuinely-ambiguous-input
// abstentions): these fixtures are small, authored, and known-good, so a
// driver error indicates a real environment or install problem that must
// fail the whole case closed rather than silently under-count recall.
private PiiSpan[] parsePresidioOutput(string outputPath) {
    PiiSpan[] spans;
    foreach (line; outputTextOrEmpty(outputPath).splitLines) {
        auto trimmed = line.strip;
        if (trimmed.length == 0) continue;
        require(!trimmed.startsWith("error:"),
            "presidio driver reported an error for an authored fixture: " ~ trimmed);
        auto fields = trimmed.split(" ");
        require(fields.length == 3, "malformed presidio driver output line: " ~ trimmed);
        spans ~= PiiSpan(fields[0], fields[1].to!size_t, fields[2].to!size_t);
    }
    return spans;
}

// One shell-loop sample = one full pass over all five authored fixtures,
// via `scrubbed run --input FILE --output FILE --sidecar-output FILE --stage
// pii=pii-four-class --stage pub=document-metadata-publish --threads 1`
// (default stage options already select all four categories and both
// confidence levels). #300 Slice 3 (commit 384f404) moved pii-four-class off
// its own standalone TerminalSideOutput: it now writes its audit into the
// shared DocumentMetadata accumulator as a structured section, published by
// the separate document-metadata-publish terminal stage (see
// docs/cli-commands.md's own two-stage example) -- `--stage id=pii-four-class`
// alone no longer produces a side output and now fails
// "--sidecar-output requires a side-output-producing plan" (issue #412
// re-verification found this while re-running the real comparator).
private string piiScrubbedBatchScript() {
    return "scrubbed=\"$1\"; outdir=\"$2\"; sidecardir=\"$3\"; shift 3; status=0; " ~
        "for f in \"$@\"; do base=$(basename \"$f\"); stem=${base%.txt}; " ~
        "\"$scrubbed\" run --input \"$f\" --output \"$outdir/$stem.out\" " ~
        "--sidecar-output \"$sidecardir/$stem.sidecar\" " ~
        "--stage pii=pii-four-class --stage pub=document-metadata-publish " ~
        "--threads 1 || status=$?; done; exit \"$status\"";
}

// The presidio-side equivalent: one full pass over the same five fixtures,
// one `presidio_driver.py` invocation per file (its only supported
// single-file shape -- it has no batch mode of its own, mirroring
// langdetect_driver.py's own precedent above).
private string piiPresidioBatchScript() {
    return "python=\"$1\"; driver=\"$2\"; outdir=\"$3\"; shift 3; status=0; " ~
        "for f in \"$@\"; do base=$(basename \"$f\"); stem=${base%.txt}; " ~
        "\"$python\" \"$driver\" \"$f\" > \"$outdir/$stem.out\" || status=$?; done; " ~
        "exit \"$status\"";
}

private JSONValue comparePiiFourClassPresidio(string scrubbedBinary,
        string presidioPython, string root, bool darwin, double timeoutSeconds,
        long maxRssBytes) {
    auto scrubbedSnapshot = snapshotExecutable(scrubbedBinary, root, "scrubbed-pii-snapshot");

    auto acquisitionOrder = verifyPinnedPackages(
        checked(["uv", "pip", "freeze", "--python", presidioPython]),
        [PinnedPackage("presidio-analyzer", "2.2.364"),
         PinnedPackage("presidio-anonymizer", "2.2.364"),
         PinnedPackage("en-core-web-sm", "", presidioSpacyModelUrl)]);

    require(digest(presidioDriverPath) == presidioDriverSha256,
        "presidio driver script drift: on-disk bytes no longer match the pinned hash");

    auto presidioPythonVersion = checked([presidioPython, "--version"]);

    // Empirically verifies the by-construction recognizer scoping (never
    // Presidio's full default catalog) at run time, not just by reading the
    // pinned driver source.
    auto supportedEntities = checked([presidioPython, presidioDriverPath, "--print-scope"]);
    require(supportedEntities == presidioSupportedEntitiesLine,
        "presidio analyzer is not strictly scoped to the four overlap entities: " ~
        supportedEntities);

    auto fixtures = piiFixtures();
    require(toHexString(sha256Of(cast(const(ubyte)[]) encodePiiFixtureSpec(fixtures))).to!string ==
        piiFixtureSpecSha256,
        "authored pii fixture/gold-span spec drift: generated bytes no longer match the " ~
        "pinned hash");

    auto fixtureDir = buildPath(root, "pii-fixtures");
    mkdirRecurse(fixtureDir);
    string[] fixtureNames;
    PiiSpan[][] goldByFixture;
    foreach (fixture; fixtures) {
        write(buildPath(fixtureDir, fixture.fileName), fixture.text);
        fixtureNames ~= fixture.fileName;
        goldByFixture ~= resolvePiiGoldSpans(fixture.text, fixture.spans);
    }
    string[] fixturePaths;
    foreach (name; fixtureNames) fixturePaths ~= buildPath(fixtureDir, name);

    JSONValue[] samples;
    string[2] scrubbedSidecarDirs, presidioOutDirs;
    size_t scrubbedSampleIndex, presidioSampleIndex;
    string[] scrubbedCommand, presidioCommand;

    foreach (index; 0 .. 4) {
        bool useScrubbed = index % 2 == 0;
        auto tool = useScrubbed ? "scrubbed" : "presidio";
        JSONValue sample;
        if (useScrubbed) {
            auto outDir = buildPath(root, "pii-scrubbed-out-" ~ index.to!string);
            auto sidecarDir = buildPath(root, "pii-scrubbed-sidecar-" ~ index.to!string);
            mkdirRecurse(outDir);
            mkdirRecurse(sidecarDir);
            scrubbedCommand = ["/bin/sh", "-c", piiScrubbedBatchScript(), "sh",
                scrubbedSnapshot.path, outDir, sidecarDir] ~ fixturePaths;
            sample = runBoundedSample(scrubbedCommand, darwin, timeoutSeconds);
            require(sample["status"].integer == 0,
                "scrubbed exited nonzero across the pii-four-class fixture batch: " ~
                sample["status"].integer.to!string);
            scrubbedSidecarDirs[scrubbedSampleIndex++] = sidecarDir;
        } else {
            auto outDir = buildPath(root, "pii-presidio-out-" ~ index.to!string);
            mkdirRecurse(outDir);
            presidioCommand = ["/bin/sh", "-c", piiPresidioBatchScript(), "sh",
                presidioPython, presidioDriverPath, outDir] ~ fixturePaths;
            sample = runBoundedSample(presidioCommand, darwin, timeoutSeconds);
            require(sample["status"].integer == 0,
                "presidio driver exited nonzero across the pii-four-class fixture batch: " ~
                sample["status"].integer.to!string);
            presidioOutDirs[presidioSampleIndex++] = outDir;
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
        samples[1]["tool"].str == "presidio" && samples[2]["tool"].str == "scrubbed" &&
        samples[3]["tool"].str == "presidio",
        "pii-four-class comparator lost its A/B/A/B interleave order");

    string[] scrubbedSidecarNames, presidioOutputNames;
    foreach (name; fixtureNames) {
        auto stem = name[0 .. $ - 4]; // strip ".txt"
        scrubbedSidecarNames ~= stem ~ ".sidecar";
        presidioOutputNames ~= stem ~ ".out";
    }
    auto scrubbedSignatureA = directorySignature(scrubbedSidecarDirs[0], scrubbedSidecarNames);
    auto scrubbedSignatureB = directorySignature(scrubbedSidecarDirs[1], scrubbedSidecarNames);
    require(scrubbedSignatureA == scrubbedSignatureB,
        "scrubbed produced non-reproducible pii-audit output between its own two timed samples");
    auto presidioSignatureA = directorySignature(presidioOutDirs[0], presidioOutputNames);
    auto presidioSignatureB = directorySignature(presidioOutDirs[1], presidioOutputNames);
    require(presidioSignatureA == presidioSignatureB,
        "presidio driver produced non-reproducible output between its own two timed samples");

    auto scrubbedTotals = emptyPiiCategoryCounts();
    auto presidioTotals = emptyPiiCategoryCounts();
    foreach (i, name; fixtureNames) {
        auto stem = name[0 .. $ - 4];
        auto scrubbedPredicted = parseScrubbedPiiAudit(
            buildPath(scrubbedSidecarDirs[0], stem ~ ".sidecar"));
        auto presidioPredicted = parsePresidioOutput(
            buildPath(presidioOutDirs[0], stem ~ ".out"));
        accumulatePiiFixtureScore(scrubbedTotals, scrubbedPredicted, goldByFixture[i]);
        accumulatePiiFixtureScore(presidioTotals, presidioPredicted, goldByFixture[i]);
    }

    JSONValue scoring = JSONValue(["categories": strings(piiCategories.dup)]);
    scoring["scrubbed"] = piiToolScoringJson(scrubbedTotals);
    scoring["presidio"] = piiToolScoringJson(presidioTotals);

    JSONValue result = JSONValue(["name": JSONValue("pii-four-class/scrubbed-vs-presidio")]);
    result["scrubbed_binary_sha256"] = scrubbedSnapshot.sha256;
    result["presidio_driver_sha256"] = presidioDriverSha256;
    result["presidio_spacy_model"] = "en_core_web_sm";
    result["presidio_python_version"] = presidioPythonVersion;
    result["presidio_supported_entities"] = strings(supportedEntities.split(","));
    result["python_packages_acquisition_order"] = acquisitionOrder;
    result["scrubbed_command"] = publicCommandGeneric(scrubbedCommand,
        [scrubbedSnapshot.path: "<scrubbed-binary>"], root);
    result["presidio_command"] = publicCommandGeneric(presidioCommand,
        [presidioPython: "<presidio-python>"], root);
    result["timeout_seconds"] = timeoutSeconds;
    result["max_rss_bytes"] = maxRssBytes;
    result["samples"] = JSONValue(samples);
    result["reproducibility"] = JSONValue([
        "scrubbed": JSONValue(true),
        "presidio": JSONValue(true),
    ]);
    result["fixture_spec_sha256"] = piiFixtureSpecSha256;
    result["fixture_count"] = fixtureNames.length;
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
    // jusText stoplist selection (issue #59): both quoting styles, a
    // missing `lang` attribute entirely, an unhandled language falling
    // back to the documented English default, and a `lang=` substring
    // outside the `<html>` tag never influencing the choice.
    require(htmlLangPrefix(`<html lang="de-DE">`) == "de",
        "double-quoted lang attribute not detected");
    require(htmlLangPrefix(`<html lang='en'>`) == "en",
        "single-quoted lang attribute not detected");
    require(htmlLangPrefix(`<html>`) == "",
        "bare <html> tag with no lang attribute must yield an empty prefix");
    require(htmlLangPrefix(`<body lang="de">no html tag</body>`) == "",
        "a lang= substring outside the <html> tag must never be detected");
    require(htmlLangPrefix(`<html>` ~ "\n" ~ `<meta lang="de">`) == "",
        "a lang= substring after the <html> tag's own close must not be detected");
    // Code-review fix (PR #585): a `lang=` that is the tail of a longer
    // attribute name (`data-lang=`) must never be mistaken for the real
    // `lang` attribute, even when it appears earlier in the tag.
    require(htmlLangPrefix(`<html data-lang="fr" lang="de">`) == "de",
        "data-lang= must not be mistaken for the real lang attribute");
    require(htmlLangPrefix(`<html data-lang="fr">`) == "",
        "a tag with only data-lang= (no real lang attribute) must yield an empty prefix");
    // xml:lang (real XHTML spelling) is still accepted via its `:` boundary.
    require(htmlLangPrefix(`<html xml:lang="de">`) == "de",
        "xml:lang= must be accepted as the lang attribute");
    // Code-review fix (PR #585): both the <html> tag search and the lang=
    // attribute search must be case-insensitive (legal, real HTML).
    require(htmlLangPrefix(`<HTML LANG="DE">`) == "de",
        "uppercase <HTML LANG=...> must be detected case-insensitively");
    require(htmlLangPrefix(`<Html Lang='En'>`) == "en",
        "mixed-case <Html Lang=...> must be detected case-insensitively");
    require(justextStoplistFor(`<html lang="de-DE">`) == "German",
        "German stoplist selection regression");
    require(justextStoplistFor(`<html lang='en'>`) == "English",
        "English stoplist selection regression");
    require(justextStoplistFor(`<html lang="fr">`) == "French",
        "French stoplist selection regression");
    require(justextStoplistFor(`<html lang="ja">`) == justextDefaultStoplist,
        "an unhandled language must fall back to the documented English default");
    require(justextStoplistFor(`<html>`) == justextDefaultStoplist,
        "a missing lang attribute must fall back to the documented English default");

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
    // URL-pinned package (a spaCy model with no plain-PyPI release): accepted
    // only when the freeze row's URL matches byte-for-byte, and a version/URL
    // type mismatch is rejected in both directions.
    enum urlPinUrl = "https://example.invalid/en_core_web_sm-3.8.0.whl";
    auto urlPin = PinnedPackage("en-core-web-sm", "", urlPinUrl);
    auto urlOk = verifyPinnedPackages("en-core-web-sm @ " ~ urlPinUrl ~ "\n", [urlPin]);
    require(urlOk.array.length == 1 && urlOk.array[0].str == "en-core-web-sm @ " ~ urlPinUrl,
        "url-pinned acquisition order self-test regression");
    foreach (bad; ["en-core-web-sm @ https://example.invalid/en_core_web_sm-3.9.0.whl",
                   "en-core-web-sm==3.8.0"]) {
        bool rejected;
        try verifyPinnedPackages(bad, [urlPin]);
        catch (Exception) rejected = true;
        require(rejected, "url-pin mismatch or version/url type confusion accepted: " ~ bad);
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

    // parseScrubbedPiiAudit synthetic-envelope round-trip (issue #420): this
    // is the parsing logic that silently broke during the #300 Slice 3
    // refactor and was only caught by an expensive manual re-verification
    // (#412/#419). Build a `document-metadata:v2` envelope through the real
    // `withStructuredSection`/`encodeDocumentMetadataV2` helpers -- never
    // hand-authoring the wire JSON for the positive case -- write it to a
    // temp file, and confirm `parseScrubbedPiiAudit` decodes it back to
    // exactly the audit data that went in. Pure in-process/offline: no live
    // `scrubbed` binary and no Presidio venv involved.
    {
        JSONValue contributorA = JSONValue([
            "category": JSONValue("EMAIL"), "start": JSONValue(10), "end": JSONValue(25)]);
        JSONValue unionA = JSONValue(["contributors": JSONValue([contributorA])]);
        JSONValue contributorB = JSONValue([
            "category": JSONValue("PHONE"), "start": JSONValue(40), "end": JSONValue(52)]);
        JSONValue unionB = JSONValue(["contributors": JSONValue([contributorB])]);
        auto auditPayload = JSONValue(["unions": JSONValue([unionA, unionB])]);
        auto payloadBytes = cast(immutable(ubyte)[]) auditPayload.toString();

        auto piiTestId = DocumentId.from(SourceLocator("self-test", "pii-audit-roundtrip", "."));
        auto piiTestMeta = DocumentMetadata.empty()
            .withStructuredSection("pii-audit", payloadBytes, "pii-four-class");
        auto piiTestWire = encodeDocumentMetadataV2(piiTestId, piiTestMeta);

        auto piiTestPath = buildPath(tempDir,
            "scrubbed-external-comparator-selftest-pii-audit-" ~ randomUUID.toString ~ ".json");
        write(piiTestPath, piiTestWire);
        scope(exit) if (exists(piiTestPath)) remove(piiTestPath);

        auto roundTripSpans = parseScrubbedPiiAudit(piiTestPath);
        require(roundTripSpans.length == 2,
            "pii-audit round-trip: unexpected span count " ~ roundTripSpans.length.to!string);
        require(roundTripSpans[0].category == "EMAIL" && roundTripSpans[0].start == 10 &&
            roundTripSpans[0].end == 25, "pii-audit round-trip: first span mismatch");
        require(roundTripSpans[1].category == "PHONE" && roundTripSpans[1].start == 40 &&
            roundTripSpans[1].end == 52, "pii-audit round-trip: second span mismatch");

        // Deliberately-corrupted envelopes must fail parsing cleanly (not
        // silently return empty/wrong data): a wrong section id (the
        // `withStructuredSection`/`encodeDocumentMetadataV2` real encoder
        // just given the wrong sectionId string), and a malformed
        // (non-hex) payload byte, hand-authored directly since the real
        // encoder can never itself produce invalid hex.
        auto piiWrongSectionMeta = DocumentMetadata.empty()
            .withStructuredSection("pii-audit-v1", payloadBytes, "pii-four-class");
        auto piiWrongSectionWire = encodeDocumentMetadataV2(piiTestId, piiWrongSectionMeta);
        auto badHexWire = `{"version":"document-metadata:v2","documentId":"` ~ piiTestId.text ~
            `","standard":{"title":null,"author":null,"date":null,"url":null},"extension":[],` ~
            `"structuredSections":[{"sectionId":"pii-audit","payload":"zz","sourceStage":"pii-four-class"}]}`;
        foreach (badWire; [piiWrongSectionWire, badHexWire]) {
            auto badPath = buildPath(tempDir,
                "scrubbed-external-comparator-selftest-pii-audit-bad-" ~ randomUUID.toString ~ ".json");
            write(badPath, badWire);
            scope(exit) if (exists(badPath)) remove(badPath);
            bool rejected;
            try parseScrubbedPiiAudit(badPath);
            catch (Exception) rejected = true;
            require(rejected, "corrupted pii-audit envelope accepted: " ~ badWire);
        }
    }

    writeln("external comparator self-test passed");
}

int main(string[] args) {
    try {
        if (args.length == 2 && args[1] == "--self-test") {
            selfTest();
            return 0;
        }
        if (args.length != 7)
            throw new Exception(
                "usage: external_comparator SCRUBBED_BINARY FTFY_BINARY TRAFILATURA_BINARY " ~
                "LANGDETECT_PYTHON PRESIDIO_PYTHON JUSTEXT_PYTHON");
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
        auto presidioPython = args[5];
        auto justextPython = args[6];

        auto mojibake = compareFtfyMojibake(args[1], args[2], python, root, darwin,
            60.0, 512L * 1024 * 1024);
        auto mojibakeWindows1251 = compareFtfyMojibakeWindows1251(args[1], args[2],
            python, root, darwin, 60.0, 512L * 1024 * 1024);
        auto mainContent = compareMainContentTrafilatura(args[1], args[3],
            trafilaturaPython, root, darwin, 180.0, 512L * 1024 * 1024);
        auto languageId = compareLanguageIdLangdetect(args[1], langdetectPython, root,
            darwin, 60.0, 512L * 1024 * 1024);
        auto piiPresidio = comparePiiFourClassPresidio(args[1], presidioPython, root,
            darwin, 60.0, 512L * 1024 * 1024);
        auto mainContentJustext = compareMainContentJustext(args[1], justextPython, root,
            darwin, 180.0, 512L * 1024 * 1024);
        auto report = assembleReport(
            [mojibake, mojibakeWindows1251, mainContent, languageId, piiPresidio,
             mainContentJustext],
            ["mojibake/scrubbed-vs-ftfy", "mojibake/scrubbed-vs-ftfy-windows1251",
             "main-content/scrubbed-vs-trafilatura",
             "language-id/scrubbed-vs-langdetect", "pii-four-class/scrubbed-vs-presidio",
             "main-content/scrubbed-vs-justext"]);
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
            !published.canFind(args[4]) && !published.canFind(args[5]) &&
            !published.canFind(args[6]) &&
            !published.canFind(checked(["uname", "-n"])),
            "result contains a private run path or hostname");
        writeln(published);
        return 0;
    } catch (Exception error) {
        stderr.writeln("external_comparator: ", error.msg);
        return 1;
    }
}
