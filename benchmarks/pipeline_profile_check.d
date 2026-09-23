// Canonical shipping-CLI profiler and publication checker.
module pipeline_profile_check;

import core.stdc.errno : errno, EINTR;
import core.stdc.stdint : uint64_t;
import core.sys.posix.sys.resource : rusage;
import core.sys.posix.sys.wait : WEXITSTATUS, WIFEXITED, WIFSIGNALED, WNOHANG,
    WTERMSIG;
import core.thread : Thread;
import core.time : msecs;
import std.algorithm.searching : canFind;
import std.algorithm.sorting : sort;
import std.array : replicate;
import std.conv : to;
import std.digest : toHexString;
import std.digest.sha : SHA256, sha256Of;
import std.datetime.stopwatch : StopWatch;
import std.file : SpanMode, dirEntries, exists, mkdirRecurse, read,
    readText, remove, rmdirRecurse, tempDir, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : baseName, buildPath, relativePath;
import std.process : Config, execute, spawnProcess, wait;
import std.stdio : File, writeln;
import std.string : indexOf, lastIndexOf, split, splitLines, strip;
import std.uuid : randomUUID;

version (OSX) {
    extern(C) nothrow @nogc {
        int wait4(int, int*, int, rusage*);
        int proc_pidinfo(int, int, uint64_t, void*, int);
        int proc_pid_rusage(int, int, void*);
    }
} else static assert(0, "canonical CLI profiling currently requires Darwin");

private enum schema = "scrubbed-cli-profile-v1";
private enum recordBytes = 256L;
private enum recordCount = 524_288L;
private enum corpusBytes = recordBytes * recordCount;
private enum minimumScratch = 2L * 1024 * 1024 * 1024;
private enum minimumRam = 2L * 1024 * 1024 * 1024;
private enum minimumBudget = 1_800L;
private enum fdPollMilliseconds = 10L;
private enum procPidListFds = 1;
private enum rusageInfoV4 = 4;
private enum fixtureTablePin = "34B08DAEE0547466C0EEF809A0A1BEDBDC4FEE26BEABE23F4478BBDAFFF0727E";
private enum legacyConfigPin = "0F02941A34B68AC9CD86760C8B6F66F8EF9A4F08D16A02ABBE194EB719B7A0F4";
private enum scalarConfigPin = "C985D95C6C2B8B13C2354BEDE8649D1557A13C4E211E647F804787E002C10ED1";
private enum mixedConfigPin = "FC1829939C5EC9347EFBD576978F3EBE017F069C525157FDCC626E8842EBD7FB";

private void need(bool okay, string message) {
    if (!okay) throw new Exception(message);
}

private string hashBytes(const(ubyte)[] bytes) {
    return toHexString(sha256Of(bytes)).to!string;
}

private string hashFile(string path) {
    return hashBytes(cast(const(ubyte)[])read(path));
}

private void digestPart(ref SHA256 digest, string value) {
    auto size = value.length.to!string;
    digest.put(cast(const(ubyte)[])size);
    digest.put(cast(const(ubyte)[])":");
    digest.put(cast(const(ubyte)[])value);
}

private bool digest(string value) {
    if (value.length != 64) return false;
    foreach (c; value)
        if (!((c >= '0' && c <= '9') || (c >= 'A' && c <= 'F') ||
              (c >= 'a' && c <= 'f'))) return false;
    return true;
}

private string scratch() {
    auto path = buildPath(tempDir, "scrubbed-cli-profile-" ~ randomUUID.toString);
    mkdirRecurse(path);
    auto result = execute(["chmod", "700", path]);
    need(result.status == 0, "cannot restrict private profile scratch");
    return path;
}

private long checkedMultiply(long left, long right, string context) {
    need(left > 0 && right > 0 && left <= long.max / right,
        "unsafe capacity arithmetic: " ~ context);
    return left * right;
}

private long freeBytes(string path) {
    auto result = execute(["df", "-Pk", path]);
    need(result.status == 0, "df preflight failed");
    auto lines = result.output.splitLines;
    need(lines.length == 2, "unexpected df preflight output");
    auto fields = lines[1].split;
    need(fields.length >= 6, "incomplete df preflight output");
    auto kib = fields[$ - 3].to!long;
    return checkedMultiply(kib, 1024, "scratch bytes");
}

private JSONValue preflight(string root, long budget) {
    auto ramResult = execute(["sysctl", "-n", "hw.memsize"]);
    need(ramResult.status == 0, "physical RAM preflight failed");
    auto ram = ramResult.output.strip.to!long;
    auto free = freeBytes(root);
    // Two inputs, ordinary/durable outputs, expected streams, and generous
    // transient space. This is deliberately checked before fixture creation.
    auto derived = checkedMultiply(corpusBytes, 12, "derived fixture footprint");
    auto required = checkedMultiply(derived, 4, "four-times scratch headroom");
    need(ram >= minimumRam, "profile needs at least 2 GiB physical RAM");
    need(free >= minimumScratch && free >= required,
        "profile needs at least 2 GiB free and four-times derived headroom");
    need(budget >= minimumBudget, "profile needs a declared 1800-second budget");
    return JSONValue([
        "physical_ram_bytes": JSONValue(ram),
        "scratch_free_bytes": JSONValue(free),
        "derived_fixture_footprint_bytes": JSONValue(derived),
        "required_scratch_bytes": JSONValue(required),
        "declared_budget_seconds": JSONValue(budget),
        "checked_before_fixture_creation": JSONValue(true)]);
}

private struct RecordCase { string input, scalar, mixed; }

private immutable RecordCase[] recordTable = [
    RecordCase("plain ASCII unchanged 123\t\n", "plain ASCII unchanged 123\t\n", "plain ASCII unchanged 123\t\n"),
    RecordCase("valid café 😀 unchanged\n", "valid café 😀 unchanged\n", "valid café 😀 unchanged\n"),
    RecordCase("repair cafÃ© and FranÃ§ais\n", "repair cafÃ© and FranÃ§ais\n", "repair café and Français\n"),
    RecordCase("negative © α 中 remains valid\n", "negative © α 中 remains valid\n", "negative © α 中 remains valid\n"),
    RecordCase("entities &amp; &lt; &#33; &unknown;\n", "entities &amp; &lt; &#33; &unknown;\n", "entities & < ! &unknown;\n"),
    RecordCase("quotes “hello” ‘world’ straight \"ok\"\n", "quotes “hello” ‘world’ straight \"ok\"\n", "quotes \"hello\" 'world' straight \"ok\"\n"),
    RecordCase("lines a\r\nb\rc\n", "lines a\nb\nc\n", "lines a\nb\nc\n"),
    RecordCase("control \x01 removed; tab\tand LF\n", "control  removed; tab\tand LF\n", "control  removed; tab\tand LF\n")
];

private string padded(string text, size_t inputLength) {
    need(inputLength <= recordBytes && text.length <= recordBytes,
        "record table entry exceeds fixed width");
    return text ~ cast(string)new char[](recordBytes - inputLength);
}

private string inputRecord(size_t index) {
    auto value = recordTable[index % recordTable.length].input;
    auto result = padded(value, value.length).dup;
    foreach (ref c; result[value.length .. $]) c = 'x';
    return cast(string)result;
}

private string outputRecord(size_t index, bool mixed) {
    auto item = recordTable[index % recordTable.length];
    auto value = mixed ? item.mixed : item.scalar;
    auto result = padded(value, item.input.length).dup;
    foreach (ref c; result[value.length .. $]) c = 'x';
    return cast(string)result;
}

private string tableSerialization() {
    string result;
    foreach (item; recordTable)
        result ~= item.input.length.to!string ~ ":" ~ item.input ~
            item.scalar.length.to!string ~ ":" ~ item.scalar ~
            item.mixed.length.to!string ~ ":" ~ item.mixed;
    return result;
}

private struct Layout {
    string name;
    size_t files;
    size_t recordsPerFile;
}

private immutable Layout[] layouts = [
    Layout("many-small", 4096, 128),
    Layout("few-large", 8, 65_536)
];

private void makeFixture(string root, Layout layout) {
    mkdirRecurse(root);
    size_t record;
    foreach (fileIndex; 0 .. layout.files) {
        auto file = File(buildPath(root, "doc-" ~ fileIndex.to!string ~ ".txt"), "wb");
        foreach (_; 0 .. layout.recordsPerFile) file.rawWrite(inputRecord(record++));
    }
    need(record == layout.files * layout.recordsPerFile,
        "layout record count differs");
}

private struct TreeIdentity {
    long bytes;
    string treeHash;
    string concatenatedHash;
    JSONValue files;
}

private TreeIdentity identifyTree(string root) {
    string[] names;
    foreach (entry; dirEntries(root, SpanMode.depth, false)) {
        need(entry.isFile, "tree contains a non-file");
        names ~= relativePath(entry.name, root);
    }
    names.sort();
    SHA256 tree, concat;
    JSONValue[] files;
    long bytes;
    foreach (name; names) {
        auto body = cast(const(ubyte)[])read(buildPath(root, name));
        auto hash = hashBytes(body);
        digestPart(tree, name);
        digestPart(tree, body.length.to!string);
        digestPart(tree, hash);
        concat.put(body);
        bytes += body.length;
        files ~= JSONValue(["path": JSONValue(name), "bytes": JSONValue(cast(long)body.length),
            "sha256": JSONValue(hash)]);
    }
    TreeIdentity result;
    result.bytes = bytes;
    result.treeHash = toHexString(tree.finish()).to!string;
    result.concatenatedHash = toHexString(concat.finish()).to!string;
    result.files = JSONValue(files);
    return result;
}

private TreeIdentity expectedIdentity(Layout layout, bool mixed) {
    auto root = scratch();
    scope(exit) rmdirRecurse(root);
    size_t record;
    foreach (fileIndex; 0 .. layout.files) {
        auto file = File(buildPath(root, "doc-" ~ fileIndex.to!string ~ ".txt"), "wb");
        foreach (_; 0 .. layout.recordsPerFile)
            file.rawWrite(outputRecord(record++, mixed));
    }
    return identifyTree(root);
}

private void exactTree(string output, TreeIdentity expected) {
    auto actual = identifyTree(output);
    need(actual.bytes == expected.bytes && actual.treeHash == expected.treeHash &&
        actual.concatenatedHash == expected.concatenatedHash,
        "exact output tree mismatch");
}

private struct RusageV4 {
    ubyte[16] uuid;
    ulong userTime, systemTime, pkgIdleWakeups, interruptWakeups, pageins;
    ulong wiredSize, residentSize, physFootprint, startAbs, exitAbs;
    ulong childUser, childSystem, childPkg, childInterrupt, childPageins, childElapsed;
    ulong diskRead, diskWrite;
    ulong[9] qosAndBilling;
    ulong logicalWrites, lifetimeMaxFootprint, instructions, cycles;
}

private double seconds(ref const typeof(rusage.init.ru_utime) value) {
    return value.tv_sec + value.tv_usec / 1_000_000.0;
}

private JSONValue measured(string[] command, string logPath, string binaryHash) {
    auto log = File(logPath, "wb");
    auto nullIn = File("/dev/null", "rb");
    StopWatch clock;
    clock.start();
    auto child = spawnProcess(command, nullIn, log, log, null, Config.none);
    auto pid = child.processID;
    int status;
    rusage usage;
    long fdPeak, fdSamples, fdErrors;
    RusageV4 lastRusage;
    long rusageSamples, rusageErrors;
    while (true) {
        auto fds = proc_pidinfo(pid, procPidListFds, 0, null, 0);
        if (fds >= 0) {
            auto count = fds / 8;
            if (count > fdPeak) fdPeak = count;
            ++fdSamples;
        } else ++fdErrors;
        RusageV4 current;
        if (proc_pid_rusage(pid, rusageInfoV4, &current) == 0) {
            lastRusage = current;
            ++rusageSamples;
        } else ++rusageErrors;
        auto waited = wait4(pid, &status, WNOHANG, &usage);
        if (waited == pid) break;
        need(waited == 0 || (waited < 0 && errno == EINTR), "wait4 failed");
        Thread.sleep(msecs(fdPollMilliseconds));
    }
    clock.stop();
    log.close();
    auto exited = WIFEXITED(status);
    auto code = exited ? WEXITSTATUS(status) : -1;
    auto signal = WIFSIGNALED(status) ? WTERMSIG(status) : 0;
    JSONValue result = JSONValue([
        "target_binary_sha256": JSONValue(binaryHash),
        "exit_code": JSONValue(cast(long)code),
        "signal": JSONValue(cast(long)signal),
        "wall_seconds": JSONValue(clock.peek.total!"nsecs" / 1_000_000_000.0),
        "user_seconds": JSONValue(seconds(usage.ru_utime)),
        "system_seconds": JSONValue(seconds(usage.ru_stime)),
        "peak_rss_bytes": JSONValue(cast(long)usage.ru_opaque[0]),
        "sampled_peak_fd_lower_bound": JSONValue(fdPeak),
        "fd_poll_interval_milliseconds": JSONValue(fdPollMilliseconds),
        "fd_poll_samples": JSONValue(fdSamples),
        "fd_poll_errors": JSONValue(fdErrors),
        "fd_metric_semantics": JSONValue("sampled lower bound; not exact peak"),
        "rusage_v4_samples": JSONValue(rusageSamples),
        "rusage_v4_errors": JSONValue(rusageErrors)]);
    if (rusageSamples) {
        result["disk_io"] = JSONValue([
            "status": JSONValue("SUPPORTED"),
            "bytes_read": JSONValue(cast(long)lastRusage.diskRead),
            "bytes_written": JSONValue(cast(long)lastRusage.diskWrite),
            "semantics": JSONValue("Darwin proc_pid_rusage RUSAGE_INFO_V4 disk-I/O bytes; last successful live-child sample; not syscall bytes")]);
    } else result["disk_io"] = JSONValue([
        "status": JSONValue("UNSUPPORTED"),
        "reason": JSONValue("no successful live-child RUSAGE_INFO_V4 sample")]);
    return result;
}

private string[] selectorArgs(string selector, string config, bool mixed) {
    auto scalar = "normalize-line-endings,strip-control";
    auto chain = "uncurl-quotes,fix-mojibake,decode-html-entities,normalize-line-endings,strip-control";
    if (selector == "filters") return ["--filters", mixed ? chain : scalar];
    if (selector == "config") return ["--config", config];
    if (selector == "tokens") {
        string[] result = ["--stage", "legacy-text=text-transform"];
        foreach (name; (mixed ? chain : scalar).split(",")) {
            result ~= ["--filter", name];
            if (mixed && name == "fix-mojibake")
                result ~= ["--filter-option", "max-passes=integer:2"];
        }
        return result;
    }
    if (selector == "default") return [];
    throw new Exception("unknown selector");
}

private string canonicalConfig(bool mixed) {
    auto filters = mixed ?
        `[{"name":"uncurl-quotes","options":{}},{"name":"fix-mojibake","options":{"max-passes":2}},{"name":"decode-html-entities","options":{}},{"name":"normalize-line-endings","options":{}},{"name":"strip-control","options":{}}]` :
        `[{"name":"normalize-line-endings","options":{}},{"name":"strip-control","options":{}}]`;
    return `{"version":3,"stages":[{"id":"legacy-text","implementation":"text-transform","options":{},"filters":` ~ filters ~ `}]}`;
}

private string legacyConfig() {
    return `{"filters":["normalize-line-endings","strip-control"]}`;
}

private string explainIdentity(string log) {
    string identity;
    foreach (line; log.splitLines) {
        auto marker = line.indexOf("\tchain=");
        if (marker < 0) continue;
        auto rest = line[marker + 7 .. $];
        auto end = rest.indexOf('\t');
        auto value = end < 0 ? rest : rest[0 .. end];
        if (!identity.length) identity = value;
        need(identity == value, "selector emitted mixed canonical identities");
    }
    need(identity.length != 0, "selector did not expose canonical identity");
    return identity;
}

private JSONValue runOnce(string binary, string binaryHash, string input,
        string output, string selector, string config, bool mixed,
        string root, bool explain = false, string[] durable = []) {
    if (exists(output)) rmdirRecurse(output);
    auto log = buildPath(root, "run-" ~ randomUUID.toString ~ ".log");
    auto command = [binary, "--input", input, "--output", output] ~
        selectorArgs(selector, config, mixed) ~
        ["--threads", "4", "--max-open-inputs", "4"] ~ durable;
    if (explain) command ~= "--explain";
    auto result = measured(command, log, binaryHash);
    result["log_sha256"] = hashFile(log);
    result["canonical_identity"] = explain ? explainIdentity(readText(log)) : "NOT_EXPOSED";
    remove(log);
    return result;
}

private JSONValue selectorFreeze(string binary, string binaryHash, string input,
        string root, string v1, string v3, TreeIdentity expected) {
    JSONValue[] results;
    string identity;
    foreach (name; ["default", "filters", "v1-json", "v3-json", "tokens"]) {
        auto selector = name == "v1-json" || name == "v3-json" ? "config" : name;
        auto config = name == "v1-json" ? v1 : v3;
        auto output = buildPath(root, "selector-" ~ name);
        const exposesCanonicalIdentity = name == "v3-json" || name == "tokens";
        auto sample = runOnce(binary, binaryHash, input, output, selector, config,
            false, root, exposesCanonicalIdentity);
        need(sample["exit_code"].integer == 0, "selector freeze command failed");
        exactTree(output, expected);
        auto current = sample["canonical_identity"].str;
        if (exposesCanonicalIdentity) {
            if (!identity.length) identity = current;
            need(current == identity, "selector canonical identity divergence");
        } else need(current == "NOT_EXPOSED", "legacy selector invented canonical identity");
        results ~= JSONValue(["selector": JSONValue(name),
            "tree_sha256": JSONValue(identifyTree(output).treeHash),
            "canonical_identity": JSONValue(current)]);
        rmdirRecurse(output);
    }
    return JSONValue(["input_bytes": JSONValue(8L * 1024 * 1024),
        "canonical_identity": JSONValue(identity), "selectors": JSONValue(results)]);
}

private struct OrdinaryProfileCase {
    string workload;
    string selector;
    string config;
    bool mixed;
    TreeIdentity expected;
    string outputBase;
    JSONValue[] samples;
}

private JSONValue ordinaryMatrix(string binary, string binaryHash, string input,
        string scalarConfig, string mixedConfig, string root, string layoutName,
        TreeIdentity scalarExpected, TreeIdentity mixedExpected) {
    OrdinaryProfileCase[] cases = [
        OrdinaryProfileCase("scalar", "config", scalarConfig, false,
            scalarExpected, buildPath(root, layoutName ~ "-scalar-config")),
        OrdinaryProfileCase("mixed", "config", mixedConfig, true,
            mixedExpected, buildPath(root, layoutName ~ "-mixed-config")),
        OrdinaryProfileCase("scalar", "tokens", scalarConfig, false,
            scalarExpected, buildPath(root, layoutName ~ "-scalar-tokens")),
        OrdinaryProfileCase("mixed", "tokens", mixedConfig, true,
            mixedExpected, buildPath(root, layoutName ~ "-mixed-tokens"))
    ];
    foreach (ref item; cases) {
        auto output = item.outputBase ~ "-conditioning";
        auto conditioning = runOnce(binary, binaryHash, input, output,
            item.selector, item.config, item.mixed, root);
        need(conditioning["exit_code"].integer == 0, "conditioning run failed");
        exactTree(output, item.expected);
        rmdirRecurse(output);
    }
    // Round-robin order is frozen here so adjacent timed children are never
    // five repetitions of one selector/workload case.
    foreach (round; 0 .. 5) foreach (ref item; cases) {
        auto output = item.outputBase ~ "-" ~ round.to!string;
        auto sample = runOnce(binary, binaryHash, input, output, item.selector,
            item.config, item.mixed, root);
        need(sample["exit_code"].integer == 0, "timed ordinary run failed");
        exactTree(output, item.expected);
        auto actual = identifyTree(output);
        sample["sample_index"] = cast(long)round;
        sample["input_bytes"] = corpusBytes;
        sample["output_bytes"] = actual.bytes;
        sample["output_tree_sha256"] = actual.treeHash;
        sample["exact_output"] = true;
        item.samples ~= sample;
        rmdirRecurse(output);
    }
    JSONValue[] result;
    foreach (item; cases) result ~= JSONValue([
        "workload": JSONValue(item.workload),
        "selector": JSONValue(item.selector),
        "result": JSONValue(["samples": JSONValue(item.samples),
            "conditioning": JSONValue("one untimed application-cold process; OS cache uncontrolled")])]);
    return JSONValue(result);
}

private JSONValue durableCase(string binary, string binaryHash, string input,
        string outputBase, string config, string root, TreeIdentity expected,
        bool journal) {
    JSONValue[] pairs;
    foreach (pair; 0 .. 3) {
        auto output = outputBase ~ "-" ~ pair.to!string;
        auto database = output ~ (journal ? ".journal.db" : ".manifest.db");
        if (journal) {
            auto init = execute([binary, "errors-init", "--journal", database]);
            need(init.status == 0, "journal-v3 explicit initialization failed");
        }
        auto durable = journal ? ["--error-journal", database, "--explain"] :
            ["--manifest", database, "--explain"];
        auto first = runOnce(binary, binaryHash, input, output, "config", config,
            true, root, false, durable);
        need(first["exit_code"].integer == 0, "durable first publication failed");
        exactTree(output, expected);
        // Preserve destination/database for the verified skip.
        auto log = buildPath(root, "durable-skip-" ~ randomUUID.toString ~ ".log");
        auto command = [binary, "--input", input, "--output", output,
            "--config", config, "--threads", "4", "--max-open-inputs", "4"] ~ durable;
        auto skip = measured(command, log, binaryHash);
        auto logText = readText(log);
        skip["log_sha256"] = hashFile(log);
        remove(log);
        need(skip["exit_code"].integer == 0 && logText.canFind("status=skipped"),
            "durable verified skip failed");
        exactTree(output, expected);
        auto actual = identifyTree(output);
        first["exact_output"] = true;
        skip["exact_output"] = true;
        first["input_bytes"] = corpusBytes;
        skip["input_bytes"] = corpusBytes;
        first["output_bytes"] = actual.bytes;
        skip["output_bytes"] = actual.bytes;
        first["output_tree_sha256"] = actual.treeHash;
        skip["output_tree_sha256"] = actual.treeHash;
        first["phase"] = "first-publication";
        skip["phase"] = "verified-skip";
        pairs ~= JSONValue(["pair_index": JSONValue(cast(long)pair),
            "first": first, "skip": skip]);
        rmdirRecurse(output);
        foreach (suffix; ["", "-wal", "-shm"])
            if (exists(database ~ suffix)) remove(database ~ suffix);
    }
    return JSONValue(["kind": JSONValue(journal ? "journal-v3" : "manifest-v2"),
        "pairs": JSONValue(pairs)]);
}

private JSONValue unsupported(string reason) {
    return JSONValue(["status": JSONValue("UNSUPPORTED"), "reason": JSONValue(reason)]);
}

private JSONValue sampleProbe(string binary, string input, string output,
        string config, string root, string layout, TreeIdentity expected) {
    if (exists(output)) rmdirRecurse(output);
    scope(exit) if (exists(output)) rmdirRecurse(output);
    auto childLog = File(buildPath(root, "sample-child-" ~ layout ~ ".log"), "wb");
    auto nullIn = File("/dev/null", "rb");
    auto command = [binary, "--input", input, "--output", output,
        "--config", config, "--threads", "1", "--max-open-inputs", "1"];
    StopWatch clock;
    clock.start();
    auto child = spawnProcess(command, nullIn, childLog, childLog,
        null, Config.none);
    auto pid = child.processID;
    auto rawPath = buildPath(root, "sample-" ~ layout ~ ".txt");
    auto sampled = execute(["/usr/bin/sample", pid.to!string, "2", "10",
        "-file", rawPath]);
    auto childStatus = wait(child);
    clock.stop();
    childLog.close();
    if (childStatus != 0 || !exists(output))
        return unsupported("instrumented single-thread mixed child failed");
    exactTree(output, expected);
    if (sampled.status != 0 || !exists(rawPath))
        return unsupported("/usr/bin/sample exact-PID control failed");
    auto raw = readText(rawPath);
    auto pidMarker = "[" ~ pid.to!string ~ "]";
    auto bound = raw.canFind(pidMarker) &&
        (raw.canFind("Path:       " ~ binary) || raw.canFind(baseName(binary)));
    long count;
    foreach (line; raw.splitLines) {
        auto marker = line.indexOf(" samples");
        if (marker < 0) continue;
        auto open = line[0 .. marker].lastIndexOf('(');
        if (open >= 0) {
            try count = line[open + 1 .. marker].strip.to!long;
            catch (Exception) {}
        }
    }
    if (!bound || count < 2)
        return unsupported("/usr/bin/sample output lacked exact PID/binary binding or enough samples");
    return JSONValue(["status": JSONValue("SUPPORTED"),
        "layout": JSONValue(layout), "pid_binary_bound": JSONValue(true),
        "sample_count": JSONValue(count), "raw_sha256": JSONValue(hashFile(rawPath)),
        "tool": JSONValue("/usr/bin/sample"), "duration_seconds": JSONValue(2L),
        "interval_milliseconds": JSONValue(10L),
        "instrumented_wall_seconds": JSONValue(clock.peek.total!"nsecs" / 1_000_000_000.0),
        "semantics": JSONValue("instrumented single-thread mixed run; excluded from timing samples")]);
}

private JSONValue probes(string binary, string input, string output,
        string config, string root) {
    JSONValue result = JSONValue();
    int dtraceStatus = -1;
    try dtraceStatus = execute(["/usr/bin/dtrace", "-q", "-n",
        "BEGIN { exit(0); }"]).status;
    catch (Exception) {}
    result["syscall_bytes"] = unsupported(dtraceStatus == 0 ?
        "privilege-free DTrace probe ran, but no exact-child syscall-byte aggregation control is accepted" :
        "noninteractive privilege-free DTrace probe failed; dtruss therefore unavailable");
    int xctraceStatus = -1;
    try xctraceStatus = execute(["xcrun", "xctrace", "version"]).status;
    catch (Exception) {}
    string allocationReason;
    if (xctraceStatus == 0) {
        auto sleeper = spawnProcess(["/bin/sleep", "3"]);
        auto tracePath = buildPath(root, "allocation-calibration.trace");
        int tracedStatus = -1;
        try tracedStatus = execute(["xcrun", "xctrace", "record", "--template",
                "Allocations", "--attach", sleeper.processID.to!string,
                "--time-limit", "1s", "--output", tracePath,
                "--no-prompt"]).status;
        catch (Exception) {}
        auto sleeperStatus = wait(sleeper);
        allocationReason = tracedStatus == 0 && exists(tracePath) ?
            "exact-PID xctrace capture succeeded, but its export has no stable validated total-process allocation counter" :
            "xctrace exact-PID noninteractive allocation control failed";
        if (exists(tracePath)) rmdirRecurse(tracePath);
    } else allocationReason = "xctrace unavailable for exact-PID allocation calibration";
    result["total_process_allocations"] = unsupported(allocationReason);
    auto gcLog = buildPath(root, "gc-profile.log");
    auto gcOut = output ~ "-gc";
    if (exists(gcOut)) rmdirRecurse(gcOut);
    auto gc = execute([binary, "--DRT-gcopt=profile:1", "--input", input,
        "--output", gcOut, "--config", config, "--threads", "1",
        "--max-open-inputs", "1"]);
    write(gcLog, gc.output);
    result["gc_allocations"] = gc.status == 0 &&
        (gc.output.canFind("GC summary") || gc.output.canFind("Number of collections")) ?
        JSONValue(["status": JSONValue("SUPPORTED"),
            "semantics": JSONValue("D runtime GC-only profile; excludes native allocations"),
            "raw_sha256": JSONValue(hashFile(gcLog))]) :
        unsupported("D runtime GC profile calibration produced no recognized GC-only summary");
    remove(gcLog);
    return result;
}

private void validateAttestation(JSONValue attestation, string binaryHash) {
    need(attestation["schema"].str == "scrubbed-build-attestation-v4" &&
        attestation["target_sha256"].str == binaryHash &&
        digest(attestation["source_archive_sha256"].str) &&
        digest(attestation["argparse_inputs_sha256"].str) &&
        digest(attestation["native_prebuild_commands_sha256"].str),
        "profile target is not bound to build-attestation-v4");
}

private JSONValue runProfile(string binary, JSONValue attestation,
        string harnessPath, string root, long budget) {
    auto binaryHash = hashFile(binary);
    auto harnessHash = hashFile(harnessPath);
    validateAttestation(attestation, binaryHash);
    auto capacity = preflight(root, budget);
    auto v1 = buildPath(root, "scalar-v1.json");
    auto scalarV3 = buildPath(root, "scalar-v3.json");
    auto mixedV3 = buildPath(root, "mixed-v3.json");
    write(v1, legacyConfig());
    write(scalarV3, canonicalConfig(false));
    write(mixedV3, canonicalConfig(true));
    need(hashFile(v1) == legacyConfigPin && hashFile(scalarV3) == scalarConfigPin &&
        hashFile(mixedV3) == mixedConfigPin &&
        hashBytes(cast(const(ubyte)[])tableSerialization()) == fixtureTablePin,
        "frozen fixture/config generator drift");
    auto configHashes = JSONValue([
        "legacy_v1_sha256": JSONValue(hashFile(v1)),
        "scalar_v3_sha256": JSONValue(hashFile(scalarV3)),
        "mixed_v3_sha256": JSONValue(hashFile(mixedV3))]);

    JSONValue[] layoutReports;
    JSONValue[] sampleRuns;
    foreach (layout; layouts) {
        auto input = buildPath(root, "input-" ~ layout.name);
        makeFixture(input, layout);
        auto inputIdentity = identifyTree(input);
        need(inputIdentity.bytes == corpusBytes, "fixture byte count differs");
        auto scalarExpected = expectedIdentity(layout, false);
        auto mixedExpected = expectedIdentity(layout, true);
        auto ordinary = ordinaryMatrix(binary, binaryHash, input, scalarV3,
            mixedV3, root, layout.name, scalarExpected, mixedExpected);
        auto durable = JSONValue([
            durableCase(binary, binaryHash, input,
                buildPath(root, layout.name ~ "-manifest"), mixedV3, root,
                mixedExpected, false),
            durableCase(binary, binaryHash, input,
                buildPath(root, layout.name ~ "-journal"), mixedV3, root,
                mixedExpected, true)]);
        sampleRuns ~= sampleProbe(binary, input,
            buildPath(root, layout.name ~ "-sample-profile"), mixedV3, root,
            layout.name, mixedExpected);
        layoutReports ~= JSONValue([
            "name": JSONValue(layout.name), "files": JSONValue(cast(long)layout.files),
            "input_bytes": JSONValue(inputIdentity.bytes),
            "input_tree_sha256": JSONValue(inputIdentity.treeHash),
            "input_concatenated_sha256": JSONValue(inputIdentity.concatenatedHash),
            "input_files": inputIdentity.files,
            "scalar_expected_tree_sha256": JSONValue(scalarExpected.treeHash),
            "scalar_expected_concatenated_sha256": JSONValue(scalarExpected.concatenatedHash),
            "scalar_expected_files": scalarExpected.files,
            "mixed_expected_tree_sha256": JSONValue(mixedExpected.treeHash),
            "mixed_expected_concatenated_sha256": JSONValue(mixedExpected.concatenatedHash),
            "mixed_expected_files": mixedExpected.files,
            "ordinary": ordinary, "durable": durable]);
    }
    need(layoutReports[0]["input_concatenated_sha256"].str ==
        layoutReports[1]["input_concatenated_sha256"].str,
        "swapped or logically unequal layouts");
    need(layoutReports[0]["scalar_expected_concatenated_sha256"].str ==
            layoutReports[1]["scalar_expected_concatenated_sha256"].str &&
        layoutReports[0]["mixed_expected_concatenated_sha256"].str ==
            layoutReports[1]["mixed_expected_concatenated_sha256"].str,
        "expected logical output differs by layout");
    auto freezeInput = buildPath(root, "selector-freeze-input");
    auto freezeLayout = Layout("selector-freeze", 256, 128); // exactly 8 MiB
    makeFixture(freezeInput, freezeLayout);
    auto freeze = selectorFreeze(binary, binaryHash, freezeInput, root,
        v1, scalarV3, expectedIdentity(freezeLayout, false));
    auto profileProbes = probes(binary, buildPath(root, "input-few-large"),
        buildPath(root, "instrumented"), mixedV3, root);
    bool samplesSupported = sampleRuns.length == layouts.length;
    long totalProfileSamples;
    SHA256 sampleDigest;
    foreach (sample; sampleRuns) {
        samplesSupported = samplesSupported && sample["status"].str == "SUPPORTED";
        if (sample["status"].str == "SUPPORTED") {
            totalProfileSamples += sample["sample_count"].integer;
            digestPart(sampleDigest, sample["raw_sha256"].str);
        }
    }
    if (samplesSupported) profileProbes["sample"] = JSONValue([
        "status": JSONValue("SUPPORTED"), "pid_binary_bound": JSONValue(true),
        "sample_count": JSONValue(totalProfileSamples),
        "raw_sha256": JSONValue(toHexString(sampleDigest.finish()).to!string),
        "runs": JSONValue(sampleRuns)]);
    else profileProbes["sample"] = JSONValue([
        "status": JSONValue("UNSUPPORTED"),
        "reason": JSONValue("one or more layout-specific /usr/bin/sample exact-PID controls failed"),
        "runs": JSONValue(sampleRuns)]);
    auto result = JSONValue([
        "schema": JSONValue(schema),
        "source_binary_mapping": JSONValue("ATTESTED"),
        "binary_sha256": JSONValue(binaryHash),
        "harness_sha256": JSONValue(harnessHash),
        "fixture_table_sha256": JSONValue(fixtureTablePin),
        "fixture_record_bytes": JSONValue(recordBytes),
        "fixture_record_count": JSONValue(recordCount),
        "config_sha256": configHashes,
        "build_attestation": attestation,
        "preflight": capacity,
        "selector_freeze": freeze,
        "layouts": JSONValue(layoutReports),
        "profiles": profileProbes,
        "sample_order": JSONValue("per layout: scalar-v3-json, mixed-v3-json, scalar-v3-tokens, mixed-v3-tokens; five fresh-output child processes each"),
        "cache_semantics": JSONValue("application-cold process; OS cache uncontrolled"),
        "nonclaims": JSONValue([JSONValue("no OS-cold claim"), JSONValue("no >RAM or 1 TiB claim"),
            JSONValue("no comparator or cross-platform claim"), JSONValue("no exact FD, syscall, or total-allocation claim"),
            JSONValue("no statistical performance guarantee")])]);
    validateReport(result, harnessHash, binaryHash);
    return result;
}

private void noLeak(string serialized) {
    foreach (token; ["/Users/", "Users\\/", "/private/var/", "private\\/var",
            "/tmp/", "tmp\\/", "<unknown>", "hostname", "username"])
        need(!serialized.canFind(token), "publication report leaks host/path identity");
}

private void validateFileSet(JSONValue files, size_t count) {
    need(files.array.length == count, "file set size differs");
    bool[string] expected;
    foreach (index; 0 .. count)
        expected["doc-" ~ index.to!string ~ ".txt"] = true;
    bool[string] seen;
    foreach (item; files.array) {
        auto path = item["path"].str;
        need((path in expected) !is null && (path in seen) is null &&
            item["bytes"].integer > 0 && digest(item["sha256"].str),
            "file set path/hash differs");
        seen[path] = true;
    }
}

private void validateReport(JSONValue report, string expectedHarness = "",
        string expectedBinary = "") {
    need(report.type == JSONType.object && report["schema"].str == schema &&
        report["source_binary_mapping"].str == "ATTESTED" &&
        digest(report["binary_sha256"].str) && digest(report["harness_sha256"].str) &&
        digest(report["fixture_table_sha256"].str) &&
        report["fixture_table_sha256"].str == fixtureTablePin &&
        report["fixture_record_bytes"].integer == recordBytes &&
        report["fixture_record_count"].integer == recordCount,
        "not a complete canonical CLI profile report");
    if (expectedHarness.length) need(report["harness_sha256"].str == expectedHarness,
        "harness drift");
    if (expectedBinary.length) need(report["binary_sha256"].str == expectedBinary,
        "binary drift");
    validateAttestation(report["build_attestation"], report["binary_sha256"].str);
    need(report["config_sha256"]["legacy_v1_sha256"].str == legacyConfigPin &&
        report["config_sha256"]["scalar_v3_sha256"].str == scalarConfigPin &&
        report["config_sha256"]["mixed_v3_sha256"].str == mixedConfigPin,
        "missing or drifted config hash");
    auto capacity = report["preflight"];
    need(capacity["checked_before_fixture_creation"].boolean &&
        capacity["physical_ram_bytes"].integer >= minimumRam &&
        capacity["scratch_free_bytes"].integer >= minimumScratch &&
        capacity["declared_budget_seconds"].integer >= minimumBudget &&
        capacity["required_scratch_bytes"].integer ==
            checkedMultiply(capacity["derived_fixture_footprint_bytes"].integer, 4,
                "report headroom"), "unsafe or incomplete preflight");
    need(report["selector_freeze"]["selectors"].array.length == 5,
        "incomplete selector freeze");
    auto canonical = report["selector_freeze"]["canonical_identity"].str;
    foreach (selector; report["selector_freeze"]["selectors"].array)
        need(selector["canonical_identity"].str == canonical ||
            selector["canonical_identity"].str == "NOT_EXPOSED",
            "selector identity divergence");
    need(report["layouts"].array.length == 2 &&
        report["layouts"][0]["name"].str == "many-small" &&
        report["layouts"][1]["name"].str == "few-large" &&
        report["layouts"][0]["input_concatenated_sha256"].str ==
            report["layouts"][1]["input_concatenated_sha256"].str &&
        report["layouts"][0]["scalar_expected_concatenated_sha256"].str ==
            report["layouts"][1]["scalar_expected_concatenated_sha256"].str &&
        report["layouts"][0]["mixed_expected_concatenated_sha256"].str ==
            report["layouts"][1]["mixed_expected_concatenated_sha256"].str,
        "missing, swapped, or unequal layouts");
    foreach (layout; report["layouts"].array) {
        auto fileCount = layout["name"].str == "many-small" ? 4096 : 8;
        validateFileSet(layout["input_files"], fileCount);
        validateFileSet(layout["scalar_expected_files"], fileCount);
        validateFileSet(layout["mixed_expected_files"], fileCount);
        need(layout["input_bytes"].integer == corpusBytes &&
            digest(layout["input_concatenated_sha256"].str) &&
            digest(layout["scalar_expected_concatenated_sha256"].str) &&
            digest(layout["mixed_expected_concatenated_sha256"].str) &&
            layout["input_files"].array.length == fileCount &&
            layout["scalar_expected_files"].array.length ==
                layout["input_files"].array.length &&
            layout["mixed_expected_files"].array.length ==
                layout["input_files"].array.length &&
            layout["ordinary"].array.length == 4 &&
            layout["durable"].array.length == 2,
            "incomplete layout profile matrix");
        foreach (item; layout["ordinary"].array) {
            auto samples = item["result"]["samples"].array;
            auto expectedTree = item["workload"].str == "mixed" ?
                layout["mixed_expected_tree_sha256"].str :
                layout["scalar_expected_tree_sha256"].str;
            need(samples.length == 5, "incomplete or duplicate ordinary samples");
            bool[long] seen;
            foreach (sample; samples) {
                auto index = sample["sample_index"].integer;
                need((index in seen) is null, "duplicate sample index");
                seen[index] = true;
                need(sample["exit_code"].integer == 0 && sample["signal"].integer == 0 &&
                    sample["exact_output"].boolean && sample["wall_seconds"].floating > 0 &&
                    sample["peak_rss_bytes"].integer > 0 &&
                    sample["target_binary_sha256"].str == report["binary_sha256"].str &&
                    sample["output_tree_sha256"].str == expectedTree &&
                    sample["fd_metric_semantics"].str == "sampled lower bound; not exact peak",
                    "invalid ordinary sample");
                auto io = sample["disk_io"];
                need(io["status"].str == "SUPPORTED" ||
                    (io["status"].str == "UNSUPPORTED" && io["reason"].str.length),
                    "unsupported disk metric represented as zero/substitute");
            }
        }
        foreach (route; layout["durable"].array) {
            need(route["pairs"].array.length == 3, "incomplete durable pairs");
            foreach (pair; route["pairs"].array)
                foreach (phase; ["first", "skip"])
                    need(pair[phase]["exit_code"].integer == 0 &&
                        pair[phase]["exact_output"].boolean &&
                        pair[phase]["output_tree_sha256"].str ==
                            layout["mixed_expected_tree_sha256"].str &&
                        pair[phase]["target_binary_sha256"].str == report["binary_sha256"].str,
                        "invalid durable sample");
        }
    }
    foreach (name; ["syscall_bytes", "total_process_allocations", "gc_allocations", "sample"]) {
        auto metric = report["profiles"][name];
        need(metric["status"].str == "SUPPORTED" ||
            (metric["status"].str == "UNSUPPORTED" && metric["reason"].str.length),
            "unsupported metric represented as zero/substitute: " ~ name);
        if (metric["status"].str == "SUPPORTED") {
            if (name == "syscall_bytes")
                need(metric["exact_child_pid_calibrated"].boolean &&
                    metric["semantics"].str == "syscall read/write bytes" &&
                    metric["bytes_read"].integer + metric["bytes_written"].integer > 0,
                    "syscall bytes lack exact-PID calibrated semantics");
            else if (name == "total_process_allocations")
                need(metric["exact_child_pid_calibrated"].boolean &&
                    metric["allocation_count"].integer > 0,
                    "total allocation metric lacks exact-PID calibration");
            else if (name == "gc_allocations")
                need(metric["semantics"].str ==
                    "D runtime GC-only profile; excludes native allocations" &&
                    digest(metric["raw_sha256"].str),
                    "GC metric is represented as total allocation");
            else
                need(metric["pid_binary_bound"].boolean &&
                    metric["sample_count"].integer >= 2 &&
                    digest(metric["raw_sha256"].str),
                    "sample profile lacks PID/binary binding");
        }
    }
    noLeak(report.toString);
}

private void mustReject(JSONValue good, void delegate(ref JSONValue) mutate,
        string message) {
    auto bad = parseJSON(good.toString);
    mutate(bad);
    bool rejected;
    try validateReport(bad);
    catch (Exception) rejected = true;
    need(rejected, message);
}

private JSONValue syntheticReport() {
    auto hash = "A".replicate(64);
    JSONValue sample = JSONValue([
        "sample_index": JSONValue(0L), "exit_code": JSONValue(0L),
        "signal": JSONValue(0L), "exact_output": JSONValue(true),
        "wall_seconds": JSONValue(1.0), "user_seconds": JSONValue(0.5),
        "system_seconds": JSONValue(0.1), "peak_rss_bytes": JSONValue(1L),
        "target_binary_sha256": JSONValue(hash),
        "output_tree_sha256": JSONValue(hash),
        "fd_metric_semantics": JSONValue("sampled lower bound; not exact peak"),
        "disk_io": JSONValue(["status": JSONValue("UNSUPPORTED"),
            "reason": JSONValue("calibration unavailable")])]);
    JSONValue[] samples;
    foreach (i; 0 .. 5) { auto copy = parseJSON(sample.toString); copy["sample_index"] = cast(long)i; samples ~= copy; }
    JSONValue[] ordinaryItems;
    foreach (i; 0 .. 4) ordinaryItems ~= JSONValue([
        "workload": JSONValue(i % 2 ? "mixed" : "scalar"),
        "selector": JSONValue(i < 2 ? "config" : "tokens"),
        "result": JSONValue(["samples": JSONValue(samples)])]);
    auto phase = JSONValue(["exit_code": JSONValue(0L), "exact_output": JSONValue(true),
        "target_binary_sha256": JSONValue(hash), "output_tree_sha256": JSONValue(hash)]);
    JSONValue[] pairs;
    foreach (i; 0 .. 3) pairs ~= JSONValue(["first": phase, "skip": phase]);
    auto route = JSONValue(["pairs": JSONValue(pairs)]);
    JSONValue[] manyFiles;
    foreach (i; 0 .. 4096) manyFiles ~= JSONValue([
        "path": JSONValue("doc-" ~ i.to!string ~ ".txt"),
        "bytes": JSONValue(1L), "sha256": JSONValue(hash)]);
    auto layout = JSONValue(["name": JSONValue("many-small"),
        "input_bytes": JSONValue(corpusBytes), "input_concatenated_sha256": JSONValue(hash),
        "input_files": JSONValue(manyFiles), "scalar_expected_files": JSONValue(manyFiles),
        "mixed_expected_files": JSONValue(manyFiles),
        "scalar_expected_tree_sha256": JSONValue(hash),
        "scalar_expected_concatenated_sha256": JSONValue(hash),
        "mixed_expected_tree_sha256": JSONValue(hash),
        "mixed_expected_concatenated_sha256": JSONValue(hash),
        "ordinary": JSONValue(ordinaryItems), "durable": JSONValue([route, route])]);
    JSONValue[] fewFiles;
    foreach (i; 0 .. 8) fewFiles ~= JSONValue([
        "path": JSONValue("doc-" ~ i.to!string ~ ".txt"),
        "bytes": JSONValue(1L), "sha256": JSONValue(hash)]);
    auto layout2 = parseJSON(layout.toString); layout2["name"] = "few-large";
    layout2["input_files"] = JSONValue(fewFiles);
    layout2["scalar_expected_files"] = JSONValue(fewFiles);
    layout2["mixed_expected_files"] = JSONValue(fewFiles);
    JSONValue[] selectors;
    foreach (i; 0 .. 5) selectors ~= JSONValue(["canonical_identity": JSONValue("identity")]);
    auto unsupportedMetric = unsupported("not available");
    return JSONValue([
        "schema": JSONValue(schema), "source_binary_mapping": JSONValue("ATTESTED"),
        "binary_sha256": JSONValue(hash), "harness_sha256": JSONValue(hash),
        "fixture_table_sha256": JSONValue(fixtureTablePin), "fixture_record_bytes": JSONValue(recordBytes),
        "fixture_record_count": JSONValue(recordCount),
        "config_sha256": JSONValue(["legacy_v1_sha256": JSONValue(legacyConfigPin),
            "scalar_v3_sha256": JSONValue(scalarConfigPin), "mixed_v3_sha256": JSONValue(mixedConfigPin)]),
        "build_attestation": JSONValue(["schema": JSONValue("scrubbed-build-attestation-v4"),
            "target_sha256": JSONValue(hash), "source_archive_sha256": JSONValue(hash),
            "argparse_inputs_sha256": JSONValue(hash),
            "native_prebuild_commands_sha256": JSONValue(hash)]),
        "preflight": JSONValue(["checked_before_fixture_creation": JSONValue(true),
            "physical_ram_bytes": JSONValue(minimumRam), "scratch_free_bytes": JSONValue(minimumScratch),
            "derived_fixture_footprint_bytes": JSONValue(1L), "required_scratch_bytes": JSONValue(4L),
            "declared_budget_seconds": JSONValue(minimumBudget)]),
        "selector_freeze": JSONValue(["canonical_identity": JSONValue("identity"),
            "selectors": JSONValue(selectors)]),
        "layouts": JSONValue([layout, layout2]),
        "profiles": JSONValue(["syscall_bytes": unsupportedMetric,
            "total_process_allocations": unsupportedMetric,
            "gc_allocations": unsupportedMetric, "sample": unsupportedMetric])]);
}

private void selfTest() {
    auto good = syntheticReport();
    validateReport(good);
    mustReject(good, (ref JSONValue r) { r["fixture_table_sha256"] = "B"; }, "fixture drift accepted");
    mustReject(good, (ref JSONValue r) { r["build_attestation"]["target_sha256"] = "B".replicate(64); }, "binary drift accepted");
    mustReject(good, (ref JSONValue r) { r["harness_sha256"] = "bad"; }, "harness drift accepted");
    auto otherHarness = parseJSON(good.toString);
    otherHarness["harness_sha256"] = "B".replicate(64);
    bool harnessRejected;
    try validateReport(otherHarness, good["harness_sha256"].str);
    catch (Exception) harnessRejected = true;
    need(harnessRejected, "valid but different harness hash accepted");
    mustReject(good, (ref JSONValue r) { r["layouts"][0]["input_concatenated_sha256"] = "B".replicate(64); }, "swapped layout accepted");
    mustReject(good, (ref JSONValue r) { r["selector_freeze"]["selectors"][0]["canonical_identity"] = "other"; }, "selector divergence accepted");
    mustReject(good, (ref JSONValue r) { r["layouts"][0]["ordinary"][0]["result"]["samples"].array.length = 4; }, "partial samples accepted");
    mustReject(good, (ref JSONValue r) { r["layouts"][0]["ordinary"][0]["result"]["samples"][1]["sample_index"] = 0; }, "duplicate samples accepted");
    mustReject(good, (ref JSONValue r) { r["layouts"][0]["ordinary"][0]["result"]["samples"][0]["wall_seconds"] = 0.0; }, "zero sample accepted");
    mustReject(good, (ref JSONValue r) { r["layouts"][0]["ordinary"][0]["result"]["samples"][0]["output_tree_sha256"] = "B".replicate(64); }, "output hash mismatch accepted");
    mustReject(good, (ref JSONValue r) { r["profiles"]["syscall_bytes"] = JSONValue(["status": JSONValue("SUPPORTED"), "bytes": JSONValue(0L)]); }, "zero substituted unsupported metric accepted");
    mustReject(good, (ref JSONValue r) { r["layouts"][0]["ordinary"][0]["result"]["samples"][0]["fd_metric_semantics"] = "exact peak"; }, "sampled FD represented as exact accepted");
    mustReject(good, (ref JSONValue r) { r["profiles"]["gc_allocations"] = JSONValue(["status": JSONValue("SUPPORTED"), "semantics": JSONValue("total allocations")]); }, "GC represented as total accepted");
    mustReject(good, (ref JSONValue r) { r["preflight"]["required_scratch_bytes"] = long.max; }, "unsafe capacity accepted");
    mustReject(good, (ref JSONValue r) { r["cache_semantics"] = "/Users/person/private"; }, "path leakage accepted");
    writeln("canonical profile self-test passed (15 release-active negatives)");
}

private void selfTestLive(string binary) {
    auto root = scratch();
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto layout = Layout("live", 1, recordTable.length);
    auto input = buildPath(root, "input");
    makeFixture(input, layout);
    auto scalarConfig = buildPath(root, "scalar-v3.json");
    auto mixedConfig = buildPath(root, "mixed-v3.json");
    write(scalarConfig, canonicalConfig(false));
    write(mixedConfig, canonicalConfig(true));
    auto binaryHash = hashFile(binary);
    auto scalarExpected = expectedIdentity(layout, false);
    auto mixedExpected = expectedIdentity(layout, true);
    auto scalar = runOnce(binary, binaryHash, input, buildPath(root, "scalar"),
        "config", scalarConfig, false, root, true);
    need(scalar["exit_code"].integer == 0 && scalar["peak_rss_bytes"].integer > 0,
        "live scalar process metrics failed");
    exactTree(buildPath(root, "scalar"), scalarExpected);
    auto mixed = runOnce(binary, binaryHash, input, buildPath(root, "mixed"),
        "config", mixedConfig, true, root, true);
    need(mixed["exit_code"].integer == 0 && mixed["peak_rss_bytes"].integer > 0,
        "live mixed process metrics failed");
    exactTree(buildPath(root, "mixed"), mixedExpected);
    auto tokens = runOnce(binary, binaryHash, input, buildPath(root, "tokens"),
        "tokens", mixedConfig, true, root, true);
    need(tokens["exit_code"].integer == 0 &&
        tokens["canonical_identity"].str == mixed["canonical_identity"].str,
        "live JSON/token canonical identity differs: " ~
            mixed["canonical_identity"].str ~ " vs " ~
            tokens["canonical_identity"].str);
    exactTree(buildPath(root, "tokens"), mixedExpected);
    writeln("canonical profile live self-test passed: fixture/output/identity/wait4/proc PID metrics");
}

int main(string[] args) {
    try {
        if (args.length == 2 && args[1] == "--self-test") { selfTest(); return 0; }
        if (args.length == 3 && args[1] == "--self-test-live") {
            selfTestLive(args[2]); return 0;
        }
        if (args.length == 3 && args[1] == "--check") {
            auto report = parseJSON(readText(args[2]));
            validateReport(report, hashFile(args[0]));
            writeln("canonical CLI profile valid: ", report["binary_sha256"].str);
            return 0;
        }
        need(args.length == 7 && args[1] == "--run",
            "usage: pipeline_profile_check --self-test | --self-test-live BINARY | --check REPORT | --run BINARY ATTESTATION_JSON REPORT_JSON TIME_BUDGET_SECONDS HARNESS_PATH");
        auto binary = args[2];
        auto attestation = parseJSON(readText(args[3]));
        auto reportPath = args[4];
        auto budget = args[5].to!long;
        auto harnessPath = args[6];
        need(hashFile(harnessPath) == hashFile(args[0]), "profile harness path differs from executable");
        auto root = scratch();
        scope(exit) if (exists(root)) rmdirRecurse(root);
        auto report = runProfile(binary, attestation, harnessPath, root, budget);
        auto serialized = report.toString;
        noLeak(serialized);
        write(reportPath, serialized ~ "\n");
        writeln("canonical CLI profile written: ", reportPath);
        return 0;
    } catch (Exception error) {
        writeln("canonical profile failure: ", error.msg);
        return 1;
    }
}
