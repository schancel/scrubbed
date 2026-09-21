// Local full-process benchmark. Build with ldc2 -O3 -release.
module pipeline;

import core.sys.posix.signal : kill, SIGKILL;
import core.sys.posix.sys.stat : chmod, S_IRUSR, S_IXUSR, S_IRWXU;
import core.thread : Thread;
import std.algorithm.searching : canFind, endsWith, startsWith;
import std.algorithm.sorting : sort;
import std.array : replicate;
import std.ascii : isHexDigit;
import std.conv : to;
import std.digest : toHexString;
import std.digest.sha : sha256Of;
import std.datetime : dur;
import std.file : SpanMode, copy, dirEntries, exists, getSize, mkdirRecurse,
    read, readText, remove, rename, rmdirRecurse, tempDir, write;
import std.json : JSONValue;
import std.path : buildPath, relativePath;
import std.process : execute, spawnProcess, wait;
import std.stdio : File, stderr, writeln;
import std.string : replace, split, splitLines, strip, toStringz;
import std.uuid : randomUUID;

private void require(bool condition, string message) {
    if (!condition) throw new Exception(message);
}

private string hashFile(string path) {
    return toHexString(sha256Of(read(path))).to!string;
}

private struct ExecutableSnapshot {
    string path;
    string sha256;
}

private string privateScratch(string prefix) {
    auto root = buildPath(tempDir, prefix ~ randomUUID.toString);
    mkdirRecurse(root);
    require(chmod(root.toStringz, S_IRWXU) == 0,
        "cannot restrict benchmark scratch directory");
    return root;
}

private ExecutableSnapshot snapshotExecutable(string source, string root,
                                               string name) {
    auto target = buildPath(root, name);
    copy(source, target);
    require(chmod(target.toStringz, S_IRUSR | S_IXUSR) == 0,
        "cannot make executable snapshot read-only");
    return ExecutableSnapshot(target, hashFile(target));
}

private void verifySnapshot(ExecutableSnapshot snapshot) {
    require(hashFile(snapshot.path) == snapshot.sha256,
        "executable snapshot changed during benchmark");
}

private string checked(string[] args) {
    auto result = execute(args);
    require(result.status == 0, args[0] ~ " failed: " ~ result.output);
    return result.output.strip;
}

private JSONValue arr(string[] values) {
    JSONValue[] items;
    foreach (value; values) items ~= JSONValue(value);
    return JSONValue(items);
}

private bool digestField(string value, size_t length) {
    if (value.length != length) return false;
    foreach (letter; value)
        if (!isHexDigit(letter)) return false;
    return true;
}

private bool expectedDos2unixVersion(string value) {
    return value == "dos2unix 7.5.7 (2026-08-27)";
}

private string linuxCpuModel(string cpuinfo) {
    foreach (key; ["model name", "Hardware", "Processor"]) {
        foreach (line; cpuinfo.splitLines) {
            auto parts = line.split(":");
            if (parts.length == 2 && parts[0].strip == key &&
                parts[1].strip.length) return parts[1].strip;
        }
    }
    throw new Exception("Linux /proc/cpuinfo lacks a CPU model");
}

private long linuxRamBytes(string meminfo) {
    long result;
    size_t matches;
    foreach (line; meminfo.splitLines) {
        auto parts = line.split(":");
        if (parts.length != 2 || parts[0] != "MemTotal") continue;
        auto fields = parts[1].strip.split();
        require(fields.length == 2 && fields[1] == "kB",
            "invalid Linux MemTotal units");
        auto kib = fields[0].to!long;
        require(kib > 0 && kib <= long.max / 1024,
            "invalid Linux MemTotal value");
        result = kib * 1024;
        matches++;
    }
    require(matches == 1, "Linux /proc/meminfo must have one MemTotal");
    return result;
}

private JSONValue unsupportedCases() {
    return arr(["OS cold cache not controlled",
        "peak open FDs and GC not instrumented",
        "actual syscall read/write bytes not observable",
        "greater-than-RAM case not attempted; verify host RAM, scratch, and time budget before running",
        "changed-executable timing not included; paired correctness gate covers identity"]);
}

private string identityPolicy() {
    return "private read-only executable snapshots hashed before and after all samples";
}

private void validateBuildProvenance(JSONValue report, bool comparator) {
    require(report["binary_identity_policy"].str == identityPolicy(),
        "report did not declare verified executable snapshot policy");
    require(("compiler" in report.object) is null &&
        ("build_flags" in report.object) is null &&
        ("scrubbed_build_command" in report.object) is null &&
        ("dos2unix_build_command" in report.object) is null,
        "ambiguous measured-binary build attribution");
    require(report["harness_compiler_available_version"].str.length != 0 &&
        report["harness_reproduction_command"].str.length != 0,
        "missing harness environment/recipe");
    require(report["target_binary_compiler"].str == "UNVERIFIED" &&
        report["target_binary_build_flags"].str == "UNVERIFIED",
        "supplied target binary build provenance was not attested");
    if (comparator)
        require(report["dos2unix_binary_compiler"].str == "UNVERIFIED" &&
            report["dos2unix_binary_build_flags"].str == "UNVERIFIED",
            "supplied comparator binary build provenance was not attested");
}

private double elapsed(string value) {
    double result;
    foreach (field; value.split(":")) result = result * 60 + field.to!double;
    return result;
}

private bool allSkipped(string output, size_t expected) {
    return output.split("EXPLAIN\tinput=").length - 1 == expected &&
        output.split("status=skipped").length - 1 == expected;
}

private JSONValue treeStatuses(string output, size_t files) {
    JSONValue[string] byFile;
    foreach (line; output.splitLines) {
        if (!line.startsWith("EXPLAIN\tinput=")) continue;
        auto fields = line.split("\t");
        require(fields.length >= 3, "malformed EXPLAIN record");
        string filename;
        foreach (i; 0 .. files) {
            auto candidate = "doc-" ~ i.to!string ~ ".txt";
            if (fields[1].endsWith(candidate ~ "\"")) {
                require(filename.length == 0, "ambiguous EXPLAIN input");
                filename = candidate;
            }
        }
        require(filename.length && (filename in byFile) is null,
            "unknown or duplicate EXPLAIN input");
        string status;
        foreach (field; fields) {
            if (field.startsWith("status=")) {
                require(status.length == 0, "duplicate EXPLAIN status");
                status = field[7 .. $];
            }
        }
        require(status.length != 0, "missing EXPLAIN status");
        byFile[filename] = JSONValue(status);
    }
    require(byFile.length == files, "missing EXPLAIN input status");
    return JSONValue(byFile);
}

private void requireTreeStatus(JSONValue sample, size_t files,
                               string first, string other) {
    auto byFile = sample["status_by_file"];
    require(byFile.object.length == files, "status map size differs");
    foreach (i; 0 .. files) {
        auto name = "doc-" ~ i.to!string ~ ".txt";
        require((name in byFile.object) !is null &&
            byFile[name].str == (i == 0 ? first : other),
            "wrong EXPLAIN status for " ~ name);
    }
}

private JSONValue timed(string[] command, bool mac, size_t expectedSkips = 0,
                        size_t treeFiles = 0) {
    auto result = execute((mac ? ["/usr/bin/time", "-l", "-p"] :
        ["/usr/bin/time", "-v"]) ~ command);
    require(result.status == 0, "timed command failed: " ~ result.output);
    size_t decisionCount = result.output.split("EXPLAIN\tinput=").length - 1;
    size_t skipCount = result.output.split("status=skipped").length - 1;
    size_t retryCount = result.output.split("status=retry").length - 1;
    size_t changedCount = result.output.split("status=changed").length - 1;
    size_t unchangedCount = result.output.split("status=unchanged").length - 1;
    if (expectedSkips) {
        require(allSkipped(result.output, expectedSkips),
            "manifest warm run did not report every verified skip");
    }
    JSONValue sample = JSONValue(["status": JSONValue(result.status)]);
    sample["decisions"] = cast(long) decisionCount;
    sample["skipped"] = cast(long) skipCount;
    sample["retry"] = cast(long) retryCount;
    sample["changed"] = cast(long) changedCount;
    sample["unchanged"] = cast(long) unchangedCount;
    if (treeFiles) sample["status_by_file"] = treeStatuses(result.output, treeFiles);
    foreach (line; result.output.splitLines) {
        auto s = line.strip;
        if (mac) {
            if (s.startsWith("real ")) sample["wall_seconds"] = s[5 .. $].strip.to!double;
            if (s.startsWith("user ")) sample["user_seconds"] = s[5 .. $].strip.to!double;
            if (s.startsWith("sys ")) sample["system_seconds"] = s[4 .. $].strip.to!double;
            if (s.canFind("maximum resident set size"))
                sample["peak_rss_bytes"] = s.split(" ")[0].to!long;
        } else {
            auto fields = s.split(": ");
            if (fields.length < 2) continue;
            auto value = fields[$ - 1].strip;
            if (s.startsWith("Elapsed (wall clock) time"))
                sample["wall_seconds"] = elapsed(value);
            if (s.startsWith("User time")) sample["user_seconds"] = value.to!double;
            if (s.startsWith("System time")) sample["system_seconds"] = value.to!double;
            if (s.startsWith("Maximum resident set size"))
                sample["peak_rss_bytes"] = value.to!long * 1024;
        }
    }
    foreach (field; ["wall_seconds", "user_seconds", "system_seconds", "peak_rss_bytes"])
        require((field in sample.object) !is null, "missing time metric " ~ field);
    return sample;
}

private string expectedBytes(size_t records) {
    string result;
    foreach (_; 0 .. records) result ~= "alpha\nbeta\ngammadelta\n";
    return result;
}

private void fixture(string root, size_t files, size_t records) {
    mkdirRecurse(root);
    foreach (i; 0 .. files) {
        auto file = File(buildPath(root, "doc-" ~ i.to!string ~ ".txt"), "wb");
        foreach (_; 0 .. records) file.rawWrite("alpha\r\nbeta\rgamma\x01delta\n");
    }
}

private JSONValue verifyTree(string input, string output, size_t files,
                             size_t records, bool firstChanged = false) {
    require(exists(output), "missing output tree");
    string[] found;
    foreach (entry; dirEntries(output, SpanMode.depth, false)) {
        require(entry.isFile, "non-file in output tree");
        found ~= relativePath(entry.name, output);
    }
    found.sort();
    require(found.length == files, "extra or missing output tree entry");
    JSONValue[] identities;
    auto canonical = expectedBytes(records);
    foreach (i; 0 .. files) {
        auto name = "doc-" ~ i.to!string ~ ".txt";
        require(found.canFind(name), "missing expected output file");
        auto outPath = buildPath(output, name);
        string expected = canonical;
        if (firstChanged && i == 0) {
            auto edited = canonical.dup;
            edited[0] = 'A';
            expected = cast(string) edited;
        }
        require(readText(outPath) == expected, "wrong output bytes in " ~ name);
        identities ~= JSONValue(["path": JSONValue(name),
            "input_sha256": JSONValue(hashFile(buildPath(input, name))),
            "output_sha256": JSONValue(hashFile(outPath))]);
    }
    return JSONValue(identities);
}

private JSONValue caseRun(string name, string[] command, string input,
                          string output, size_t files, size_t records,
                          bool mac, bool manifest) {
    JSONValue[] samples;
    JSONValue identities;
    foreach (run; 0 .. 3) {
        if (!manifest || run == 0) {
            if (exists(output)) rmdirRecurse(output);
        }
        auto sample = timed(command, mac, manifest && run > 0 ? files : 0,
            manifest ? files : 0);
        if (manifest) requireTreeStatus(sample, files,
            run == 0 ? "changed" : "skipped",
            run == 0 ? "changed" : "skipped");
        identities = verifyTree(input, output, files, records);
        sample["exact_output"] = true;
        long observedInputBytes, observedOutputBytes;
        foreach (i; 0 .. files) {
            auto filename = "doc-" ~ i.to!string ~ ".txt";
            observedInputBytes += getSize(buildPath(input, filename));
            observedOutputBytes += getSize(buildPath(output, filename));
        }
        sample["input_tree_bytes_observed"] = observedInputBytes;
        sample["output_tree_bytes_observed"] = observedOutputBytes;
        sample["input_fixture_bytes"] = cast(long)(files * records *
            "alpha\r\nbeta\rgamma\x01delta\n".length);
        sample["expected_output_bytes"] = cast(long)(files * records *
            "alpha\nbeta\ngammadelta\n".length);
        sample["phase"] = run == 0 ? "first-process-warm-OS-unspecified" :
            "new-process-warm-application-cache-empty";
        if (manifest) sample["manifest_phase"] = run == 0 ?
            "first" : "verified-skip";
        samples ~= sample;
    }
    require(samples.length == 3, "partial samples");
    JSONValue result = JSONValue(["name": JSONValue(name),
        "files": identities, "samples": JSONValue(samples)]);
    result["filter_config"] = "normalize-line-endings,strip-control";
    result["filter_selection_sha256"] = toHexString(
        sha256Of(cast(ubyte[])"normalize-line-endings,strip-control".dup)).to!string;
    result["command_template"] = manifest ?
        "<scrubbed-binary> --input <fixture-input> --output <fixture-output> --filters normalize-line-endings,strip-control --threads 1 --manifest <manifest-db> --explain" :
        "<scrubbed-binary> --input <fixture-input> --output <fixture-output> --filters normalize-line-endings,strip-control --threads 1";
    return result;
}

private JSONValue manifestTransitions(string[] command, string input,
                                      string output, size_t files,
                                      size_t records, bool mac) {
    JSONValue[] steps;
    auto firstFile = buildPath(input, "doc-0.txt");
    auto bytes = cast(ubyte[]) read(firstFile);
    require(bytes.length && bytes[0] == 'a', "fixture lacks visible mutation site");
    bytes[0] = 'A';
    write(firstFile, bytes);
    auto changedInput = timed(command ~ ["--manifest-retry"], mac, 0, files);
    require(changedInput["decisions"].integer == files &&
        changedInput["retry"].integer == 1 &&
        changedInput["skipped"].integer == files - 1,
        "changed input did not retry exactly one file");
    requireTreeStatus(changedInput, files, "retry", "skipped");
    verifyTree(input, output, files, records, true);
    changedInput["phase"] = "changed-input-explicit-retry";
    steps ~= changedInput;

    auto changedConfig = command.dup;
    changedConfig[6] = "strip-control,normalize-line-endings";
    auto configSample = timed(changedConfig ~ ["--manifest-retry"], mac, 0, files);
    require(configSample["decisions"].integer == files &&
        configSample["retry"].integer == files,
        "changed config did not retry every file");
    requireTreeStatus(configSample, files, "retry", "retry");
    verifyTree(input, output, files, records, true);
    configSample["phase"] = "changed-filter-selection-explicit-retry";
    steps ~= configSample;

    auto newRoute = changedConfig.dup;
    auto alternate = output ~ "-alternate";
    newRoute[4] = alternate;
    auto routeSample = timed(newRoute, mac, 0, files);
    require(routeSample["decisions"].integer == files &&
        routeSample["changed"].integer == files,
        "changed output route did not publish every file");
    requireTreeStatus(routeSample, files, "changed", "changed");
    verifyTree(input, alternate, files, records, true);
    routeSample["phase"] = "changed-output-route-first";
    steps ~= routeSample;
    return JSONValue(steps);
}

private JSONValue restartProbe(string binary, string root, bool mac) {
    auto input = buildPath(root, "restart-input.txt");
    auto output = buildPath(root, "restart-output.txt");
    auto db = buildPath(root, "restart.sqlite");
    {
        auto file = File(input, "wb");
        auto chunk = "x".replicate(1024 * 1024);
        foreach (_; 0 .. 64) file.rawWrite(chunk);
    }
    auto command = [binary, "run", "--input", input, "--output", output,
        "--manifest", db, "--filters", "normalize-line-endings",
        "--max-input-bytes", "134217728", "--threads", "1", "--explain"];
    auto child = spawnProcess(command);
    bool planned;
    foreach (_; 0 .. 250) {
        if (exists(db)) {
            auto query = execute(["sqlite3", "-readonly", db,
                "SELECT count(*) FROM sink_state WHERE state='planned';"]);
            if (query.status == 0 && query.output.strip == "1") {
                planned = true; break;
            }
        }
        Thread.sleep(dur!"msecs"(4));
    }
    if (!planned) {
        wait(child);
        throw new Exception("restart probe never observed a durable planned row");
    }
    require(kill(child.processID, SIGKILL) == 0, "kill exact planned process");
    require(wait(child) == -SIGKILL, "planned process did not die by SIGKILL");
    auto query = checked(["sqlite3", "-readonly", db,
        "SELECT count(*) FROM sink_state WHERE state='planned';"]);
    require(query == "1", "killed process lost durable planned row");
    bool hadOutput = exists(output);
    auto replay = timed(hadOutput ? command ~ ["--manifest-retry"] : command,
        mac);
    require(replay["decisions"].integer == 1 &&
        (replay["changed"].integer == 1 || replay["unchanged"].integer == 1 ||
         replay["retry"].integer == 1),
        "restart replay was not a publish/retry: " ~ replay.toString);
    require(exists(output) && getSize(output) == 64UL * 1024 * 1024 &&
        hashFile(output) == hashFile(input), "restart output bytes differ");
    auto skip = timed(command, mac, 1);
    require(hashFile(output) == hashFile(input), "restart skip changed output");
    JSONValue result = JSONValue(["planned_seen": JSONValue(planned),
        "killed_after_planned": JSONValue(true),
        "output_existed_at_kill": JSONValue(hadOutput),
        "input_sha256": JSONValue(hashFile(input)),
        "output_sha256": JSONValue(hashFile(output)),
        "input_bytes": JSONValue(cast(long) getSize(input))]);
    result["replay"] = replay;
    result["verified_skip"] = skip;
    return result;
}

private void validateRestart(JSONValue probe) {
    require(probe["planned_seen"].boolean &&
        probe["killed_after_planned"].boolean,
        "restart report lacks proven planned kill");
    require(probe["replay"]["status"].integer == 0 &&
        probe["replay"]["decisions"].integer == 1 &&
        probe["verified_skip"]["status"].integer == 0 &&
        probe["verified_skip"]["skipped"].integer == 1 &&
        probe["verified_skip"]["decisions"].integer == 1,
        "restart report false skip or incomplete replay");
    require(probe["input_sha256"].str == probe["output_sha256"].str &&
        digestField(probe["input_sha256"].str, 64) &&
        probe["input_bytes"].integer > 0,
        "restart report incorrect output identity");
}

private void validate(JSONValue report) {
    require(report["schema"].str == "scrubbed-pipeline-v3", "report schema");
    foreach (key; ["source_sha", "binary_sha256", "harness_sha256", "os",
                   "cpu"])
        require(key in report.object && report[key].str.length,
            "missing report metadata " ~ key);
    validateBuildProvenance(report, false);
    require(digestField(report["source_sha"].str, 40) &&
        digestField(report["binary_sha256"].str, 64) &&
        digestField(report["harness_sha256"].str, 64),
        "invalid report hash metadata");
    foreach (key; ["os", "cpu", "harness_compiler_available_version"]) {
        auto value = report[key].str;
        require(!value.canFind('/') && !value.canFind('\\') &&
            !value.canFind('\n') && !value.canFind('\r') &&
            !value.canFind('\t'), "hostile report metadata " ~ key);
    }
    require(report["source_binary_mapping"].str == "UNVERIFIED",
        "unverified source/binary relation must not be claimed verified");
    bool darwinReport = report["os"].str.startsWith("Darwin ");
    bool linuxReport = report["os"].str.startsWith("Linux ");
    require(report["ram_bytes"].integer > 0 &&
        ((darwinReport && report["ram_source"].str == "sysctl hw.memsize") ||
         (linuxReport && report["ram_source"].str == "/proc/meminfo MemTotal")),
        "RAM metadata was not measured");
    require(report["unsupported"].toString == unsupportedCases().toString,
        "unsupported status must be host-neutral and complete");
    require(report["cases"].array.length > 0, "zero cases");
    foreach (item; report["cases"].array) {
        require(item["samples"].array.length == 3, "zero/partial samples");
        foreach (sample; item["samples"].array)
            require(sample["exact_output"].boolean && sample["status"].integer == 0,
                "bad sample");
    }
    auto published = report.toString.replace("\\/", "/");
    require(!published.canFind(tempDir) && !published.canFind(checked(["uname", "-n"])) &&
        !published.canFind("/Users/") && !published.canFind("/home/") &&
        !published.canFind("/private/") && !published.canFind("/tmp/") &&
        !published.canFind("\\\\Users\\\\"),
        "private path or hostname in report");
}

private void selfTest() {
    JSONValue report = JSONValue(["schema": JSONValue("scrubbed-pipeline-v3"),
        "source_sha": JSONValue("0".replicate(40)),
        "binary_sha256": JSONValue("0".replicate(64)),
        "harness_sha256": JSONValue("0".replicate(64)),
        "os": JSONValue("Linux test"),
        "cpu": JSONValue("x"),
        "harness_compiler_available_version": JSONValue("x"),
        "harness_reproduction_command": JSONValue("x"),
        "target_binary_compiler": JSONValue("UNVERIFIED"),
        "target_binary_build_flags": JSONValue("UNVERIFIED"),
        "source_binary_mapping": JSONValue("UNVERIFIED"),
        "binary_identity_policy": JSONValue(identityPolicy()),
        "ram_bytes": JSONValue(1024),
        "ram_source": JSONValue("/proc/meminfo MemTotal"),
        "unsupported": unsupportedCases()]);
    JSONValue sample = JSONValue(["exact_output": JSONValue(true),
        "status": JSONValue(0)]);
    report["cases"] = JSONValue([JSONValue(["samples":
        JSONValue([sample, sample, sample])])]);
    validate(report);
    foreach (key; ["binary_sha256", "harness_sha256", "source_sha",
                   "harness_compiler_available_version"]) {
        auto bad = report;
        bad[key] = "";
        bool failed;
        try { validate(bad); } catch (Exception) { failed = true; }
        require(failed, "metadata negative did not fail");
    }
    foreach (count; [0, 1, 2]) {
        auto bad = report;
        JSONValue[] samples;
        foreach (_; 0 .. count) samples ~= sample;
        bad["cases"][0]["samples"] = JSONValue(samples);
        bool failed;
        try { validate(bad); } catch (Exception) { failed = true; }
        require(failed, "sample-count negative did not fail");
    }
    auto bad = report;
    bad["cpu"] = tempDir;
    bool failed;
    try { validate(bad); } catch (Exception) { failed = true; }
    require(failed, "path privacy negative did not fail");
    bad = report;
    bad["cpu"] = "/Users/alice/private";
    failed = false;
    try { validate(bad); } catch (Exception) { failed = true; }
    require(failed, "hostile absolute path negative did not fail");
    bad = report;
    bad["harness_reproduction_command"] = "-of=/Users/alice/private";
    failed = false;
    try { validate(bad); } catch (Exception) { failed = true; }
    require(failed, "hostile build flags negative did not fail");
    bad = report;
    bad["compiler"] = "LDC 1.43.0";
    failed = false;
    try { validate(bad); } catch (Exception) { failed = true; }
    require(failed, "ambiguous compiler attribution negative did not fail");
    bad = report;
    bad["target_binary_compiler"] = "LDC 1.43.0";
    failed = false;
    try { validate(bad); } catch (Exception) { failed = true; }
    require(failed, "unattested target compiler negative did not fail");
    bad = report;
    bad["binary_identity_policy"] = "hash original path after timing";
    failed = false;
    try { validate(bad); } catch (Exception) { failed = true; }
    require(failed, "post-timing original-path identity negative did not fail");
    JSONValue comparison = JSONValue([
        "binary_identity_policy": JSONValue(identityPolicy()),
        "harness_compiler_available_version": JSONValue("LDC available"),
        "harness_reproduction_command": JSONValue("ldc2 -O3 -release"),
        "target_binary_compiler": JSONValue("UNVERIFIED"),
        "target_binary_build_flags": JSONValue("UNVERIFIED"),
        "dos2unix_binary_compiler": JSONValue("UNVERIFIED"),
        "dos2unix_binary_build_flags": JSONValue("UNVERIFIED")]);
    validateBuildProvenance(comparison, true);
    comparison["dos2unix_binary_build_flags"] = "-O2";
    failed = false;
    try { validateBuildProvenance(comparison, true); }
    catch (Exception) { failed = true; }
    require(failed, "unattested comparator flags negative did not fail");
    bad = report;
    bad["ram_bytes"] = -1;
    failed = false;
    try { validate(bad); } catch (Exception) { failed = true; }
    require(failed, "unmeasured Linux RAM negative did not fail");
    bad = report;
    bad["ram_source"] = "sysctl hw.memsize";
    failed = false;
    try { validate(bad); } catch (Exception) { failed = true; }
    require(failed, "cross-host RAM source negative did not fail");
    bad = report;
    bad["unsupported"] = arr(["greater-than-RAM unsafe on measured 16 GiB RAM and 23.75 GiB scratch"]);
    failed = false;
    try { validate(bad); } catch (Exception) { failed = true; }
    require(failed, "cross-host capacity claim negative did not fail");
    require(linuxCpuModel("processor : 0\nmodel name : Example CPU\n") ==
        "Example CPU" &&
        linuxRamBytes("MemTotal: 16384 kB\n") == 16_777_216,
        "Linux hardware metadata parse positive failed");
    failed = false;
    try { linuxRamBytes("MemTotal: unknown MB\n"); }
    catch (Exception) { failed = true; }
    require(failed, "invalid Linux RAM negative did not fail");
    failed = false;
    try { linuxCpuModel("processor : 0\n"); }
    catch (Exception) { failed = true; }
    require(failed, "missing Linux CPU negative did not fail");
    bad = report;
    bad["source_binary_mapping"] = "VERIFIED";
    failed = false;
    try { validate(bad); } catch (Exception) { failed = true; }
    require(failed, "stale binary provenance negative did not fail");
    require(expectedDos2unixVersion("dos2unix 7.5.7 (2026-08-27)") &&
        !expectedDos2unixVersion("dos2unix 7.5.70 (2026-08-27)"),
        "comparator prefix-version negative did not fail");
    bad = report;
    bad["cases"][0]["samples"][0]["exact_output"] = false;
    failed = false;
    try { validate(bad); } catch (Exception) { failed = true; }
    require(failed, "false quality claim did not fail");
    auto root = buildPath(tempDir, "scrubbed-pipeline-test-" ~ randomUUID.toString);
    mkdirRecurse(root);
    scope(exit) rmdirRecurse(root);
    auto input = buildPath(root, "input");
    auto output = buildPath(root, "output");
    fixture(input, 1, 1);
    mkdirRecurse(output);
    auto outFile = buildPath(output, "doc-0.txt");
    write(outFile, expectedBytes(1));
    verifyTree(input, output, 1, 1);
    failed = false;
    try { verifyTree(input, output, 1, 1, true); }
    catch (Exception) { failed = true; }
    require(failed, "visible changed-input output negative did not fail");
    auto changedExpected = expectedBytes(1).dup;
    changedExpected[0] = 'A';
    write(outFile, changedExpected);
    verifyTree(input, output, 1, 1, true);
    write(outFile, "wrong");
    failed = false;
    try { verifyTree(input, output, 1, 1); } catch (Exception) { failed = true; }
    require(failed, "wrong output negative did not fail");
    write(outFile, expectedBytes(1));
    write(buildPath(output, "extra.txt"), "extra");
    failed = false;
    try { verifyTree(input, output, 1, 1); } catch (Exception) { failed = true; }
    require(failed, "extra output negative did not fail");
    string skipRows;
    foreach (_; 0 .. 31) skipRows ~= "EXPLAIN\tinput=a\tstatus=skipped\n";
    skipRows ~= "EXPLAIN\tinput=b\tstatus=changed\n";
    require(!allSkipped(skipRows, 32), "31/32 false-skip negative did not fail");
    skipRows = "";
    foreach (_; 0 .. 32) skipRows ~= "EXPLAIN\tinput=a\tstatus=skipped\n";
    require(allSkipped(skipRows, 32), "32/32 skip positive did not pass");
    auto keyed = JSONValue(["status_by_file": treeStatuses(
        "EXPLAIN\tinput=\"/tmp/doc-0.txt\"\tstatus=retry\n" ~
        "EXPLAIN\tinput=\"/tmp/doc-1.txt\"\tstatus=skipped\n", 2)]);
    requireTreeStatus(keyed, 2, "retry", "skipped");
    keyed["status_by_file"] = treeStatuses(
        "EXPLAIN\tinput=\"/tmp/doc-0.txt\"\tstatus=skipped\n" ~
        "EXPLAIN\tinput=\"/tmp/doc-1.txt\"\tstatus=retry\n", 2);
    failed = false;
    try { requireTreeStatus(keyed, 2, "retry", "skipped"); }
    catch (Exception) { failed = true; }
    require(failed, "swapped per-file retry/skip negative did not fail");
    JSONValue replaySample = JSONValue(["status": JSONValue(0),
        "decisions": JSONValue(1)]);
    JSONValue skipSample = JSONValue(["status": JSONValue(0),
        "decisions": JSONValue(1), "skipped": JSONValue(1)]);
    JSONValue probe = JSONValue(["planned_seen": JSONValue(true),
        "killed_after_planned": JSONValue(true),
        "replay": replaySample, "verified_skip": skipSample,
        "input_sha256": JSONValue("0".replicate(64)),
        "output_sha256": JSONValue("0".replicate(64)),
        "input_bytes": JSONValue(1)]);
    validateRestart(probe);
    bad = probe;
    bad["verified_skip"]["skipped"] = 0;
    failed = false;
    try { validateRestart(bad); } catch (Exception) { failed = true; }
    require(failed, "restart false-skip negative did not fail");
    bad = probe;
    bad["planned_seen"] = false;
    failed = false;
    try { validateRestart(bad); } catch (Exception) { failed = true; }
    require(failed, "unproven restart negative did not fail");
    writeln("pipeline release self-test passed");
}

private JSONValue compareDos2unix(string scrubbed, string dos2unix,
                                  string reportPath, bool injectSwap = false) {
    auto os = checked(["uname", "-s"]);
    require(os == "Darwin" || os == "Linux", "BSD/GNU time required");
    auto root = privateScratch("scrubbed-dos2unix-");
    scope(exit) rmdirRecurse(root);
    auto scrubbedCopy = snapshotExecutable(scrubbed, root, "scrubbed-snapshot");
    auto dos2unixCopy = snapshotExecutable(dos2unix, root, "dos2unix-snapshot");
    auto toolVersion = checked([dos2unixCopy.path, "--version"]).splitLines[0];
    require(expectedDos2unixVersion(toolVersion),
        "expected official dos2unix 7.5.7, got " ~ toolVersion);
    auto input = buildPath(root, "input.txt");
    auto output = buildPath(root, "output.txt");
    auto file = File(input, "wb");
    foreach (_; 0 .. 65536) file.rawWrite("alpha\r\nbeta\r\n");
    file.close();
    auto expected = "alpha\nbeta\n";
    JSONValue[] samples;
    foreach (index; 0 .. 4) {
        bool useScrubbed = index % 2 == 0;
        if (exists(output)) remove(output);
        auto command = useScrubbed ?
            [scrubbedCopy.path, "--input", input, "--output", output,
             "--filters", "normalize-line-endings", "--threads", "1"] :
            [dos2unixCopy.path, "-n", input, output];
        auto sample = timed(command, os == "Darwin");
        require(exists(output), "comparator produced no output");
        auto outputBytes = readText(output);
        require(outputBytes.length == 65536 * expected.length,
            "comparator output length mismatch");
        foreach (i; 0 .. 65536)
            require(outputBytes[i * expected.length .. (i + 1) * expected.length] ==
                expected, "comparator exact output mismatch");
        sample["tool"] = useScrubbed ? "scrubbed" : "dos2unix";
        sample["output_sha256"] = hashFile(output);
        sample["exact_output"] = true;
        samples ~= sample;
        if (injectSwap && index == 1) {
            // The caller supplies only an owned disposable path in this mode.
            auto replacement = buildPath(root, "invalid-original-replacement");
            write(replacement, "not an executable\n");
            rename(replacement, dos2unix);
        }
    }
    verifySnapshot(scrubbedCopy);
    verifySnapshot(dos2unixCopy);
    require(samples.length == 4 && samples[0]["tool"].str == "scrubbed" &&
        samples[1]["tool"].str == "dos2unix" &&
        samples[2]["tool"].str == "scrubbed" &&
        samples[3]["tool"].str == "dos2unix", "A/B/A/B order");
    JSONValue report = JSONValue(["schema": JSONValue("scrubbed-comparator-v3")]);
    report["source_sha"] = checked(["git", "rev-parse", "HEAD"]);
    report["source_binary_mapping"] = "UNVERIFIED";
    report["harness_sha256"] = hashFile("benchmarks/pipeline.d");
    report["scrubbed_binary_sha256"] = scrubbedCopy.sha256;
    report["dos2unix_binary_sha256"] = dos2unixCopy.sha256;
    report["binary_identity_policy"] = identityPolicy();
    report["dos2unix_source_tar_sha256"] =
        "669ee27120ae71589f638fe3a167d6ea54f8633f5ab1b282551bd7a7c9510dfa";
    report["source_tar_binary_mapping"] = "UNVERIFIED; observed manual build";
    report["dos2unix_version"] = toolVersion;
    report["dos2unix_license"] = "FreeBSD (official COPYING.txt)";
    report["dos2unix_reproduction_recipe"] = "make ENABLE_NLS= dos2unix (cc, default -O2)";
    report["harness_reproduction_command"] =
        "ldc2 -O3 -release benchmarks/pipeline.d -of=<path>";
    report["target_binary_compiler"] = "UNVERIFIED";
    report["target_binary_build_flags"] = "UNVERIFIED";
    report["dos2unix_binary_compiler"] = "UNVERIFIED";
    report["dos2unix_binary_build_flags"] = "UNVERIFIED";
    report["input_sha256"] = hashFile(input);
    report["output_sha256"] = samples[0]["output_sha256"];
    report["input_bytes"] = cast(long)(65536 * "alpha\r\nbeta\r\n".length);
    report["output_bytes"] = cast(long)(65536 * expected.length);
    report["os"] = os ~ " " ~ checked(["uname", "-r"]) ~ " " ~
        checked(["uname", "-m"]);
    report["harness_compiler_available_version"] =
        checked(["ldc2", "--version"]).splitLines[0];
    report["scrubbed_command_template"] =
        "<scrubbed-binary> --input <fixture> --output <output> --filters normalize-line-endings --threads 1";
    report["dos2unix_command_template"] =
        "<dos2unix-binary> -n <fixture> <output>";
    report["boundary"] = "single file to fresh file; full process; CRLF-only text; exact bytes";
    report["samples"] = JSONValue(samples);
    validateBuildProvenance(report, true);
    auto published = report.toString.replace("\\/", "/");
    require(!published.canFind(root) && !published.canFind(scrubbed) &&
        !published.canFind(dos2unix) && !published.canFind(checked(["uname", "-n"])) &&
        !published.canFind("/Users/") && !published.canFind("/home/") &&
        !published.canFind("/private/") && !published.canFind("/tmp/"),
        "private comparator report path/host");
    if (reportPath.length) write(reportPath, published ~ "\n");
    else writeln(published);
    return report;
}

private void selfTestSnapshot(string scrubbed, string dos2unix) {
    auto root = privateScratch("scrubbed-snapshot-test-");
    scope(exit) rmdirRecurse(root);
    auto disposableOriginal = buildPath(root, "dos2unix-original");
    copy(dos2unix, disposableOriginal);
    auto expectedHash = hashFile(disposableOriginal);
    auto report = compareDos2unix(scrubbed, disposableOriginal,
        buildPath(root, "race-report.json"), true);
    require(hashFile(disposableOriginal) != expectedHash &&
        report["dos2unix_binary_sha256"].str == expectedHash &&
        report["samples"][1]["output_sha256"].str ==
            report["samples"][3]["output_sha256"].str &&
        report["samples"][3]["exact_output"].boolean,
        "atomic original swap changed reported/executed snapshot identity");
    writeln("atomic original-path swap remained snapshot-bound");
}

int main(string[] args) {
    try {
        if (args.length == 2 && args[1] == "--self-test") {
            selfTest(); return 0;
        }
        if (args.length == 4 && args[1] == "--self-test-snapshot") {
            selfTestSnapshot(args[2], args[3]); return 0;
        }
        if ((args.length == 4 || args.length == 5) &&
            args[1] == "--compare-dos2unix") {
            compareDos2unix(args[2], args[3], args.length == 5 ? args[4] : "");
            return 0;
        }
        require(args.length == 2 || args.length == 3,
            "usage: pipeline SCRUBBED_BINARY [REPORT_JSON]");
        auto os = checked(["uname", "-s"]);
        require(os == "Darwin" || os == "Linux", "BSD/GNU time required");
        auto root = privateScratch("scrubbed-pipeline-");
        scope(exit) rmdirRecurse(root);
        auto binaryCopy = snapshotExecutable(args[1], root, "scrubbed-snapshot");
        JSONValue[] cases;
        JSONValue[] transitions;
        foreach (index, name; ["many-small", "few-large"]) {
            size_t files = [32, 2][index];
            size_t records = [1024, 16384][index];
            auto input = buildPath(root, name ~ "-input");
            auto output = buildPath(root, name ~ "-output");
            fixture(input, files, records);
            auto command = [binaryCopy.path, "--input", input, "--output", output,
                "--filters", "normalize-line-endings,strip-control", "--threads", "1"];
            cases ~= caseRun(name, command, input, output, files, records,
                os == "Darwin", false);
            auto manifest = buildPath(root, name ~ ".sqlite");
            command ~= ["--manifest", manifest, "--explain"];
            cases ~= caseRun(name ~ "/manifest", command, input, output,
                files, records, os == "Darwin", true);
            transitions ~= JSONValue(["name": JSONValue(name),
                "steps": manifestTransitions(command, input, output, files,
                    records, os == "Darwin")]);
        }
        JSONValue report = JSONValue(["schema": JSONValue("scrubbed-pipeline-v3")]);
        report["source_sha"] = checked(["git", "rev-parse", "HEAD"]);
        report["binary_sha256"] = binaryCopy.sha256;
        report["binary_identity_policy"] = identityPolicy();
        report["source_binary_mapping"] = "UNVERIFIED";
        report["harness_sha256"] = hashFile("benchmarks/pipeline.d");
        report["os"] = os ~ " " ~ checked(["uname", "-r"]) ~ " " ~
            checked(["uname", "-m"]);
        report["cpu"] = os == "Darwin" ?
            checked(["sysctl", "-n", "machdep.cpu.brand_string"]) :
            linuxCpuModel(readText("/proc/cpuinfo"));
        report["ram_bytes"] = os == "Darwin" ?
            checked(["sysctl", "-n", "hw.memsize"]).to!long :
            linuxRamBytes(readText("/proc/meminfo"));
        report["ram_source"] = os == "Darwin" ?
            "sysctl hw.memsize" : "/proc/meminfo MemTotal";
        report["harness_compiler_available_version"] =
            checked(["ldc2", "--version"]).splitLines[0];
        report["harness_reproduction_command"] =
            "ldc2 -O3 -release benchmarks/pipeline.d -of=<path>";
        report["target_binary_compiler"] = "UNVERIFIED";
        report["target_binary_build_flags"] = "UNVERIFIED";
        report["cases"] = JSONValue(cases);
        report["manifest_transitions"] = JSONValue(transitions);
        report["restart_probe"] = restartProbe(binaryCopy.path, root, os == "Darwin");
        validateRestart(report["restart_probe"]);
        verifySnapshot(binaryCopy);
        report["unsupported"] = unsupportedCases();
        validate(report);
        if (args.length == 3) write(args[2], report.toString ~ "\n");
        else writeln(report.toString);
        return 0;
    } catch (Exception error) {
        stderr.writeln("pipeline: ", error.msg);
        return 1;
    }
}
