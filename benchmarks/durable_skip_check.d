/// O3/release evidence for exact manifest-v2 and journal-v3 verified skips.
module benchmarks.durable_skip_check;

import core.atomic : atomicLoad, atomicStore;
import core.stdc.errno : EINTR, errno;
import core.stdc.stdint : uint64_t;
import core.sys.posix.sys.resource : rusage;
import core.sys.posix.sys.wait : WEXITSTATUS, WIFEXITED;
import core.thread : Thread;
import core.time : msecs;
import std.algorithm.sorting : sort;
import std.algorithm.searching : canFind;
import std.array : appender, array, replicate;
import std.conv : to;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.digest : LetterCase, toHexString;
import std.digest.sha : SHA256, sha256Of;
import std.file : SpanMode, dirEntries, exists, mkdirRecurse, read, readText,
    rmdirRecurse, tempDir, write;
import std.json : JSONValue, parseJSON;
import std.path : absolutePath, buildPath, relativePath;
import std.process : execute, spawnProcess;
import std.stdio : File, writeln;
import std.string : splitLines;
import std.uuid : randomUUID;

extern(C) int wait4(int pid, int* status, int options, rusage* usage);
version(OSX) extern(C) int proc_pidinfo(int pid, int flavor, uint64_t arg,
    void* buffer, int bufferSize);

private enum recordBytes = 256;
private enum recordCount = 524_288;
private enum runs = 3;
private enum comparisonRuns = 5;
private enum procPidListFds = 1;
private enum double materialImprovementPercent = 10.0;
private enum double maxTimeRegressionPercent = 5.0;
private enum ulong maxTimeRegressionUs = 50_000;
private enum ulong maxPhaseRegressionNs = 5_000_000;
private enum double maxRssRegressionPercent = 10.0;
private enum ulong maxRssRegressionBytes = 4 * 1024 * 1024;
private immutable string[] phaseNames = [
    "compiled_execution", "identity", "ledger_query", "ledger_transaction",
    "output_hash", "output_read", "output_safe_open", "publication",
    "shutdown", "source_hash", "source_open", "source_read", "source_stat"
];

private void need(bool value, string message) {
    if (!value) throw new Exception("durable skip evidence: " ~ message);
}

private bool exactKeys(ref JSONValue value, scope const string[] keys) {
    auto object = value.object;
    if (object.length != keys.length) return false;
    foreach (key; keys)
        if ((key in object) is null) return false;
    return true;
}

private immutable string[] records = [
    "plain ASCII unchanged 123\t\n",
    "valid café 😀 unchanged\n",
    "repair cafÃ© and FranÃ§ais\n",
    "negative © α 中 remains valid\n",
    "entities &amp; &lt; &#33; &unknown;\n",
    "quotes “hello” ‘world’ straight \"ok\"\n",
    "lines a\r\nb\rc\n",
    "control \x01 removed; tab\tand LF\n"
];

private struct Layout { string name; size_t files; size_t recordsPerFile; }
private immutable Layout[] layouts = [
    Layout("many-small", 4096, 128),
    Layout("few-large", 8, 65_536)
];
private immutable Layout[] comparisonLayouts = [
    Layout("many-small", 4096, 128),
    Layout("few-large", 8, 65_536),
    Layout("startup", 1, 1),
];

private string expectedInputTree(string layout) {
    if (layout == "many-small")
        return "109a64d1735023b4760b506bfa3b185a48177d7742953ee3f1301ca1b91e2c75";
    if (layout == "few-large")
        return "5293cfb9082107b5c698d9e048f9649bbcb4393b26c84d6c83881f260fe94468";
    if (layout == "startup")
        return "5d4b3434d25542e8e684614c962d35a758585a24cb290e38520340cb11e29a03";
    need(false, "unknown comparison layout");
    return null;
}

private string expectedInputConcatenated(string layout) {
    if (layout == "startup")
        return "bddd9ae8f27c17e350bc258e8a96a268abf8be75bebe36323c53dd7d5d3b70b5";
    if (layout == "many-small" || layout == "few-large")
        return "4538a0b393e57fa6ebee19a7c40fc50e1f6d00ffae80c8b2424645b8c8938b3c";
    need(false, "unknown comparison layout");
    return null;
}

private string record(size_t ordinal) {
    auto value = records[ordinal % records.length];
    auto result = new char[recordBytes];
    result[] = 'x';
    result[0 .. value.length] = value;
    return cast(string)result;
}

private void makeFixture(string root, ref const Layout layout) {
    mkdirRecurse(root);
    size_t ordinal;
    foreach (index; 0 .. layout.files) {
        auto output = File(buildPath(root, "doc-" ~ index.to!string ~ ".txt"), "wb");
        foreach (_; 0 .. layout.recordsPerFile) output.rawWrite(record(ordinal++));
    }
    need(ordinal == layout.files * layout.recordsPerFile,
        "frozen record cardinality mismatch");
}

private string[] files(string root) {
    string[] result;
    foreach (entry; dirEntries(root, SpanMode.depth, false))
        if (entry.isFile) result ~= entry.name;
    sort!((a, b) => relativePath(a, root) < relativePath(b, root))(result);
    return result;
}

private struct Tree { ulong bytes; string tree; string concatenated; }

private Tree identify(string root) {
    SHA256 tree, concatenated;
    ulong bytes;
    foreach (path; files(root)) {
        auto relative = relativePath(path, root);
        auto value = cast(ubyte[])read(path);
        auto leaf = sha256Of(value);
        tree.put(cast(const(ubyte)[])relative); tree.put([cast(ubyte)0]);
        tree.put(leaf[]); tree.put([cast(ubyte)0]);
        concatenated.put(value); bytes += value.length;
    }
    return Tree(bytes, toHexString!(LetterCase.lower)(tree.finish()).idup,
        toHexString!(LetterCase.lower)(concatenated.finish()).idup);
}

private string fileDigest(string path) {
    auto input = File(path, "rb");
    SHA256 digest;
    ubyte[64 * 1024] buffer;
    while (!input.eof) {
        auto chunk = input.rawRead(buffer[]);
        if (!chunk.length) break;
        digest.put(chunk);
    }
    return toHexString!(LetterCase.lower)(digest.finish()).idup;
}

private ulong micros(ref const typeof(rusage.init.ru_utime) value) {
    return cast(ulong)value.tv_sec * 1_000_000 + value.tv_usec;
}

private ulong rss(ref const rusage value) {
    version(OSX) return value.ru_opaque[0];
    else version(linux) return value.ru_maxrss * 1024;
    else static assert(0, "Darwin/Linux only");
}

private struct Observation {
    ulong wallUs, userUs, systemUs, rssBytes;
    size_t fdPeak, fdSamples, fdErrors;
    string logHash;
    string stackStatus;
    string stackHash;
    string gcStatus;
    JSONValue metrics;
}

private Observation invoke(string[] args, string root, string label,
        size_t expectedSkips, bool disabled, bool gcProfile = false) {
    auto outPath = buildPath(root, label ~ ".out");
    auto errPath = buildPath(root, label ~ ".err");
    auto metricsPath = buildPath(root, label ~ ".metrics.json");
    auto input = File("/dev/null", "rb");
    auto output = File(outPath, "wb");
    auto errors = File(errPath, "wb");
    string[] command = ["/usr/bin/env", "SCRUBBED_DURABLE_METRICS_V1=" ~ metricsPath,
        "SCRUBBED_DURABLE_SKIP_DISABLE_V1=" ~ (disabled ? "1" : "0"), args[0]];
    if (gcProfile) command ~= "--DRT-gcopt=profile:2";
    command ~= args[1 .. $];
    auto timer = StopWatch(AutoStart.yes);
    auto child = spawnProcess(command, input, output, errors);
    input.close(); output.close(); errors.close();
    shared bool stopped;
    shared size_t peak, fdSamples, fdErrors;
    auto sampler = new Thread({
        ubyte[64 * 1024] fdBuffer;
        while (!atomicLoad(stopped)) {
            version(OSX) {
                auto bytes = proc_pidinfo(child.processID, procPidListFds,
                    0, fdBuffer.ptr, cast(int)fdBuffer.length);
                if (bytes > 0) {
                    auto count = cast(size_t)bytes / 8;
                    atomicStore(fdSamples, atomicLoad(fdSamples) + 1);
                    if (count > atomicLoad(peak)) atomicStore(peak, count);
                } else atomicStore(fdErrors, atomicLoad(fdErrors) + 1);
            } else {
                auto seen = execute(["/usr/sbin/lsof", "-p",
                    child.processID.to!string]);
                if (seen.status == 0) {
                    auto count = seen.output.splitLines.length;
                    if (count) --count;
                    atomicStore(fdSamples, atomicLoad(fdSamples) + 1);
                    if (count > atomicLoad(peak)) atomicStore(peak, count);
                } else atomicStore(fdErrors, atomicLoad(fdErrors) + 1);
            }
            Thread.sleep(10.msecs);
        }
    });
    sampler.start();
    string stackStatus = "not-attempted", stackHash;
    if (gcProfile) {
        auto tracePath = buildPath(root, label ~ ".sample.txt");
        auto sampled = execute(["/usr/bin/sample", child.processID.to!string,
            "1", "10", "-file", tracePath]);
        if (sampled.status == 0 && exists(tracePath)) {
            auto trace = readText(tracePath);
            if (trace.canFind("scrubbed")) {
                stackStatus = "supported";
                stackHash = toHexString!(LetterCase.lower)(sha256Of(
                    cast(const(ubyte)[])trace)).idup;
            } else stackStatus = "unsupported-unbound-trace";
        } else stackStatus = "unsupported-sample-failed";
    }
    int status; rusage usage; int waited;
    do waited = wait4(child.processID, &status, 0, &usage);
    while (waited < 0 && errno == EINTR);
    timer.stop(); atomicStore(stopped, true); sampler.join();
    need(waited == child.processID && WIFEXITED(status) && WEXITSTATUS(status) == 0,
        label ~ " failed: " ~ readText(errPath));
    auto log = readText(outPath);
    size_t skips;
    foreach (line; log.splitLines)
        if (line.canFind("status=skipped")) ++skips;
    need(skips == expectedSkips, label ~ " skip status cardinality mismatch");
    if (gcProfile) need(log.canFind("GC summary:"), "missing D-GC summary");
    auto metrics = parseJSON(readText(metricsPath));
    need(metrics["schema"].str == "scrubbed.durable-metrics.v1",
        "metrics schema mismatch");
    return Observation(timer.peek.total!"usecs", micros(usage.ru_utime),
        micros(usage.ru_stime), rss(usage), atomicLoad(peak),
        atomicLoad(fdSamples), atomicLoad(fdErrors),
        toHexString!(LetterCase.lower)(sha256Of(cast(const(ubyte)[])log)).idup,
        stackStatus, stackHash, gcProfile ? "supported" : "not-attempted",
        metrics);
}

private string q(string value) { return JSONValue(value).toString; }

private string observationJson(ref const Observation item, string route,
        string variant, size_t ordinal, ref const Tree output) {
    auto phases = item.metrics["phases"];
    return `{"route":` ~ q(route) ~ `,"variant":` ~ q(variant) ~
        `,"ordinal":` ~ ordinal.to!string ~
        `,"wall_us":` ~ item.wallUs.to!string ~ `,"user_us":` ~ item.userUs.to!string ~
        `,"system_us":` ~ item.systemUs.to!string ~ `,"peak_rss_bytes":` ~
        item.rssBytes.to!string ~ `,"sampled_fd_peak":` ~ item.fdPeak.to!string ~
        `,"fd_poll_samples":` ~ item.fdSamples.to!string ~
        `,"fd_poll_errors":` ~ item.fdErrors.to!string ~
        `,"log_sha256":` ~ q(item.logHash) ~ `,"output_tree_sha256":` ~
        q(output.tree) ~ `,"output_concatenated_sha256":` ~ q(output.concatenated) ~
        `,"stack_status":` ~ q(item.stackStatus) ~ `,"stack_sha256":` ~
        q(item.stackHash) ~ `,"d_gc_status":` ~ q(item.gcStatus) ~
        `,"metrics":` ~ phases.toString ~ `}`;
}

private string layoutEvidence(string binary, string root, ref const Layout layout) {
    need(layout.files * layout.recordsPerFile == recordCount,
        "standard layout record cardinality drift");
    auto input = buildPath(root, layout.name ~ "-input");
    makeFixture(input, layout);
    auto inputId = identify(input);
    need(inputId.tree == expectedInputTree(layout.name) &&
        inputId.concatenated == expectedInputConcatenated(layout.name),
        "comparison fixture identity mismatch");
    auto result = appender!string;
    result.put(`{"layout":`); result.put(q(layout.name));
    result.put(`,"files":`); result.put(layout.files.to!string);
    result.put(`,"input_bytes":`); result.put(inputId.bytes.to!string);
    result.put(`,"input_tree_sha256":`); result.put(q(inputId.tree));
    result.put(`,"input_concatenated_sha256":`); result.put(q(inputId.concatenated));
    result.put(`,"runs":[`);
    bool firstJson = true;
    foreach (route; ["manifest-v2", "journal-v3"]) {
        string[string] outputs, stores;
        Tree[string] expected;
        foreach (variant; ["before", "candidate"]) {
            auto output = buildPath(root, layout.name ~ "-" ~ route ~ "-" ~
                variant ~ "-output");
            auto store = buildPath(root, layout.name ~ "-" ~ route ~ "-" ~
                variant ~ ".db");
            outputs[variant] = output; stores[variant] = store;
            if (route == "journal-v3") {
                auto init = execute([binary, "errors-init", "--journal", store]);
                need(init.status == 0, "journal initialization failed");
            }
            string[] firstArgs = [binary, "run", "--input", input, "--output", output,
                "--threads", "1", "--explain"];
            firstArgs ~= route == "manifest-v2" ? ["--manifest", store] :
                ["--error-journal", store];
            auto first = invoke(firstArgs, root, layout.name ~ "-" ~ route ~ "-" ~
                variant ~ "-first", 0, variant == "before");
            expected[variant] = identify(output);
            need(first.metrics["phases"]["compiled_execution"]["calls"].integer ==
                layout.files, "first publication execution count mismatch");
        }
        foreach (ordinal; 0 .. runs) {
            auto order = ordinal % 2 == 0 ? ["before", "candidate"] :
                ["candidate", "before"];
            foreach (variant; order) {
                string[] sampleArgs = [binary, "run", "--input", input,
                    "--output", outputs[variant], "--threads", "1", "--explain"];
                sampleArgs ~= route == "manifest-v2" ? ["--manifest", stores[variant]] :
                    ["--error-journal", stores[variant]];
                auto sample = invoke(sampleArgs, root, layout.name ~ "-" ~ route ~
                    "-" ~ variant ~ "-skip-" ~ ordinal.to!string,
                    layout.files, variant == "before", ordinal == 0);
                auto actual = identify(outputs[variant]);
                need(actual.tree == expected[variant].tree &&
                    actual.concatenated == expected[variant].concatenated,
                    "verified skip changed output");
                auto phases = sample.metrics["phases"];
                auto expectedExecutions = variant == "before" ? layout.files : 0;
                need(phases["compiled_execution"]["calls"].integer ==
                        expectedExecutions &&
                    phases["publication"]["calls"].integer == 0,
                    "before/candidate execution or publication mismatch");
                need(phases["source_hash"]["calls"].integer == layout.files &&
                    phases["output_hash"]["calls"].integer == layout.files,
                    "exact hash accounting mismatch");
                if (!firstJson) result.put(','); firstJson = false;
                result.put(observationJson(sample, route, variant, ordinal, actual));
            }
        }
    }
    result.put(`]}`);
    return result.data;
}

private struct ComparisonTarget {
    string role;
    string binary;
}

private struct ComparisonState {
    string output;
    string store;
    Tree expected;
}

private string stateKey(string role, string mode) {
    return role ~ ":" ~ mode;
}

private JSONValue upgradeProof(ComparisonTarget[] targets, string root,
        ref const Layout layout, string input, string route) {
    auto stem = layout.name ~ "-" ~ route ~ "-base-to-candidate";
    auto output = buildPath(root, stem ~ "-output");
    auto store = buildPath(root, stem ~ ".db");
    if (route == "journal-v3") {
        auto init = execute([targets[0].binary, "errors-init", "--journal", store]);
        need(init.status == 0, stem ~ " base journal initialization failed");
    }
    string[] baseArgs = [targets[0].binary, "run", "--input", input,
        "--output", output, "--threads", "1", "--explain"];
    baseArgs ~= route == "manifest-v2" ? ["--manifest", store] :
        ["--error-journal", store];
    auto base = invoke(baseArgs, root, stem ~ "-base", 0, false);
    auto expected = identify(output);
    need(base.metrics["phases"]["compiled_execution"]["calls"].integer ==
        layout.files, stem ~ " base publication execution mismatch");

    string[] retryArgs = [targets[1].binary, "run", "--input", input,
        "--output", output, "--threads", "1", "--explain"];
    retryArgs ~= route == "manifest-v2"
        ? ["--manifest", store, "--manifest-retry"]
        : ["--error-journal", store, "--error-retry"];
    auto retry = invoke(retryArgs, root, stem ~ "-candidate-retry", 0, false);
    auto retryOutput = identify(output);
    need(retryOutput.tree == expected.tree &&
        retryOutput.concatenated == expected.concatenated,
        stem ~ " candidate retry changed output");
    need(retry.metrics["phases"]["compiled_execution"]["calls"].integer ==
            layout.files &&
        retry.metrics["phases"]["publication"]["calls"].integer == layout.files,
        stem ~ " candidate retry execution/publication mismatch");

    string[] replayArgs = [targets[1].binary, "run", "--input", input,
        "--output", output, "--threads", "1", "--explain"];
    replayArgs ~= route == "manifest-v2" ? ["--manifest", store] :
        ["--error-journal", store];
    auto replay = invoke(replayArgs, root, stem ~ "-candidate-replay",
        layout.files, false);
    auto replayOutput = identify(output);
    need(replayOutput.tree == expected.tree &&
        replayOutput.concatenated == expected.concatenated,
        stem ~ " candidate replay changed output");
    auto replayPhases = replay.metrics["phases"];
    need(replayPhases["compiled_execution"]["calls"].integer == 0 &&
        replayPhases["publication"]["calls"].integer == 0 &&
        replayPhases["source_hash"]["calls"].integer == layout.files &&
        replayPhases["output_hash"]["calls"].integer == layout.files,
        stem ~ " candidate replay accounting mismatch");

    JSONValue result;
    result["route"] = route;
    result["output_tree_sha256"] = expected.tree;
    result["output_concatenated_sha256"] = expected.concatenated;
    result["base_execution_calls"] =
        base.metrics["phases"]["compiled_execution"]["calls"];
    result["candidate_retry_execution_calls"] =
        retry.metrics["phases"]["compiled_execution"]["calls"];
    result["candidate_retry_publication_calls"] =
        retry.metrics["phases"]["publication"]["calls"];
    result["candidate_replay_execution_calls"] =
        replayPhases["compiled_execution"]["calls"];
    result["candidate_replay_publication_calls"] =
        replayPhases["publication"]["calls"];
    return result;
}

private JSONValue comparisonLayoutEvidence(ComparisonTarget[] targets,
        string root, ref const Layout layout) {
    auto input = buildPath(root, layout.name ~ "-input");
    makeFixture(input, layout);
    auto inputId = identify(input);
    need(inputId.tree == expectedInputTree(layout.name) &&
        inputId.concatenated == expectedInputConcatenated(layout.name),
        "comparison fixture identity mismatch");
    JSONValue result;
    result["layout"] = layout.name;
    result["files"] = cast(long)layout.files;
    result["input_bytes"] = cast(long)inputId.bytes;
    result["input_tree_sha256"] = inputId.tree;
    result["input_concatenated_sha256"] = inputId.concatenated;
    JSONValue[] upgradeProofs;
    foreach (route; ["manifest-v2", "journal-v3"])
        upgradeProofs ~= upgradeProof(targets, root, layout, input, route);
    result["upgrade_proofs"] = upgradeProofs;
    JSONValue[] rows;

    foreach (route; ["manifest-v2", "journal-v3"]) {
        ComparisonState[string] states;
        foreach (target; targets) foreach (mode; ["reexecute", "verified-skip"]) {
            auto key = stateKey(target.role, mode);
            auto stem = layout.name ~ "-" ~ route ~ "-" ~ target.role ~ "-" ~ mode;
            ComparisonState state;
            state.output = buildPath(root, stem ~ "-output");
            state.store = buildPath(root, stem ~ ".db");
            if (route == "journal-v3") {
                auto init = execute([target.binary, "errors-init", "--journal", state.store]);
                need(init.status == 0, stem ~ " journal initialization failed");
            }
            string[] firstArgs = [target.binary, "run", "--input", input,
                "--output", state.output, "--threads", "1", "--explain"];
            firstArgs ~= route == "manifest-v2" ? ["--manifest", state.store] :
                ["--error-journal", state.store];
            auto first = invoke(firstArgs, root, stem ~ "-first", 0,
                mode == "reexecute");
            state.expected = identify(state.output);
            need(first.metrics["phases"]["compiled_execution"]["calls"].integer ==
                layout.files, stem ~ " first publication execution mismatch");
            states[key] = state;
        }

        foreach (mode; ["reexecute", "verified-skip"]) {
            auto reference = states[stateKey("base", mode)].expected;
            auto candidate = states[stateKey("candidate", mode)].expected;
            need(reference.tree == candidate.tree &&
                reference.concatenated == candidate.concatenated,
                layout.name ~ " " ~ route ~ " initial output identity mismatch");
        }

        foreach (ordinal; 0 .. comparisonRuns) {
            foreach (mode; comparisonModeOrder(ordinal)) {
                foreach (role; comparisonRoleOrder(ordinal)) {
                    auto target = role == "base" ? targets[0] : targets[1];
                    auto state = states[stateKey(role, mode)];
                    string[] sampleArgs = [target.binary, "run", "--input", input,
                        "--output", state.output, "--threads", "1", "--explain"];
                    sampleArgs ~= route == "manifest-v2"
                        ? ["--manifest", state.store]
                        : ["--error-journal", state.store];
                    auto label = layout.name ~ "-" ~ route ~ "-" ~ role ~ "-" ~
                        mode ~ "-" ~ ordinal.to!string;
                    auto sample = invoke(sampleArgs, root, label, layout.files,
                        mode == "reexecute", false);
                    auto actual = identify(state.output);
                    need(actual.tree == state.expected.tree &&
                        actual.concatenated == state.expected.concatenated,
                        label ~ " changed output");
                    auto phases = sample.metrics["phases"];
                    auto expectedExecutions = mode == "reexecute" ? layout.files : 0;
                    need(phases["compiled_execution"]["calls"].integer ==
                            expectedExecutions &&
                        phases["publication"]["calls"].integer == 0,
                        label ~ " execution or publication mismatch");
                    need(phases["source_hash"]["calls"].integer == layout.files &&
                        phases["output_hash"]["calls"].integer == layout.files,
                        label ~ " exact hash accounting mismatch");
                    auto row = parseJSON(observationJson(sample, route, mode,
                        ordinal, actual));
                    row["binary_role"] = role;
                    rows ~= row;
                }
            }
        }
    }
    result["runs"] = rows;
    return result;
}

private string[] comparisonModeOrder(size_t ordinal) {
    return ordinal % 2 == 0
        ? ["reexecute", "verified-skip"]
        : ["verified-skip", "reexecute"];
}

private string[] comparisonRoleOrder(size_t ordinal) {
    return ordinal % 2 == 0
        ? ["base", "candidate"]
        : ["candidate", "base"];
}

private ulong[] scalarSamples(ref JSONValue layout, string route, string mode,
        string role, string field) {
    ulong[] values;
    bool[comparisonRuns] seen;
    foreach (row; layout["runs"].array) {
        if (row["route"].str != route || row["variant"].str != mode ||
                row["binary_role"].str != role) continue;
        auto ordinal = cast(size_t)row["ordinal"].integer;
        need(ordinal < comparisonRuns && !seen[ordinal],
            "comparison ordinal duplicate or out of range");
        seen[ordinal] = true;
        values ~= cast(ulong)row[field].integer;
    }
    need(values.length == comparisonRuns, "comparison sample cardinality mismatch");
    return values;
}

private ulong[] phaseSamples(ref JSONValue layout, string route, string mode,
        string role, string phase) {
    ulong[] values;
    bool[comparisonRuns] seen;
    foreach (row; layout["runs"].array) {
        if (row["route"].str != route || row["variant"].str != mode ||
                row["binary_role"].str != role) continue;
        auto ordinal = cast(size_t)row["ordinal"].integer;
        need(ordinal < comparisonRuns && !seen[ordinal],
            "comparison phase ordinal duplicate or out of range");
        seen[ordinal] = true;
        values ~= cast(ulong)row["metrics"][phase]["nanoseconds"].integer;
    }
    need(values.length == comparisonRuns,
        "comparison phase sample cardinality mismatch");
    return values;
}

private ulong[] cpuSamples(ref JSONValue layout, string route, string mode,
        string role) {
    ulong[] values;
    bool[comparisonRuns] seen;
    foreach (row; layout["runs"].array) {
        if (row["route"].str != route || row["variant"].str != mode ||
                row["binary_role"].str != role) continue;
        auto ordinal = cast(size_t)row["ordinal"].integer;
        need(ordinal < comparisonRuns && !seen[ordinal],
            "comparison CPU ordinal duplicate or out of range");
        seen[ordinal] = true;
        values ~= cast(ulong)row["user_us"].integer +
            cast(ulong)row["system_us"].integer;
    }
    need(values.length == comparisonRuns,
        "comparison CPU sample cardinality mismatch");
    return values;
}

private ulong median(ulong[] values) {
    need(values.length == comparisonRuns, "comparison median cardinality mismatch");
    values.sort;
    return values[values.length / 2];
}

private double percentChange(ulong before, ulong after) {
    need(before > 0, "comparison percentage has zero baseline");
    return (cast(double)after - before) * 100.0 / before;
}

private bool meaningfulRegression(ulong before, ulong after,
        double percentLimit, ulong absoluteLimit) {
    return after > before && after - before > absoluteLimit &&
        percentChange(before, after) > percentLimit;
}

private JSONValue comparisonThresholds() {
    JSONValue result;
    result["material_improvement_percent"] = materialImprovementPercent;
    result["max_time_regression_percent"] = maxTimeRegressionPercent;
    result["max_time_regression_us"] = cast(long)maxTimeRegressionUs;
    result["max_phase_regression_ns"] = cast(long)maxPhaseRegressionNs;
    result["max_rss_regression_percent"] = maxRssRegressionPercent;
    result["max_rss_regression_bytes"] = cast(long)maxRssRegressionBytes;
    result["fd_regression_allowed"] = 0;
    return result;
}

private JSONValue[] comparisonRows(JSONValue[] layoutRows,
        out bool thresholdsPassed) {
    JSONValue[] result;
    bool materialWall, materialHash;
    bool noRegression = true;
    foreach (ref layout; layoutRows) foreach (route;
            ["manifest-v2", "journal-v3"]) foreach (mode;
            ["reexecute", "verified-skip"]) {
        auto baseWall = median(scalarSamples(layout, route, mode, "base", "wall_us"));
        auto candidateWall = median(scalarSamples(layout, route, mode,
            "candidate", "wall_us"));
        auto baseUser = median(scalarSamples(layout, route, mode, "base", "user_us"));
        auto candidateUser = median(scalarSamples(layout, route, mode,
            "candidate", "user_us"));
        auto baseSystem = median(scalarSamples(layout, route, mode,
            "base", "system_us"));
        auto candidateSystem = median(scalarSamples(layout, route, mode,
            "candidate", "system_us"));
        auto baseRss = median(scalarSamples(layout, route, mode,
            "base", "peak_rss_bytes"));
        auto candidateRss = median(scalarSamples(layout, route, mode,
            "candidate", "peak_rss_bytes"));
        auto baseFd = median(scalarSamples(layout, route, mode,
            "base", "sampled_fd_peak"));
        auto candidateFd = median(scalarSamples(layout, route, mode,
            "candidate", "sampled_fd_peak"));
        auto baseSourceHash = median(phaseSamples(layout, route, mode,
            "base", "source_hash"));
        auto candidateSourceHash = median(phaseSamples(layout, route, mode,
            "candidate", "source_hash"));
        auto baseOutputHash = median(phaseSamples(layout, route, mode,
            "base", "output_hash"));
        auto candidateOutputHash = median(phaseSamples(layout, route, mode,
            "candidate", "output_hash"));
        auto baseCpu = median(cpuSamples(layout, route, mode, "base"));
        auto candidateCpu = median(cpuSamples(layout, route, mode, "candidate"));

        auto wallPercent = percentChange(baseWall, candidateWall);
        auto cpuPercent = percentChange(baseCpu, candidateCpu);
        auto rssPercent = percentChange(baseRss, candidateRss);
        auto sourceHashPercent = percentChange(baseSourceHash,
            candidateSourceHash);
        auto outputHashPercent = percentChange(baseOutputHash,
            candidateOutputHash);
        if (layout["layout"].str != "startup" &&
                wallPercent <= -materialImprovementPercent) materialWall = true;
        if (layout["layout"].str != "startup" &&
                sourceHashPercent <= -materialImprovementPercent &&
                outputHashPercent <= -materialImprovementPercent)
            materialHash = true;
        if (meaningfulRegression(baseWall, candidateWall,
                maxTimeRegressionPercent, maxTimeRegressionUs) ||
                meaningfulRegression(baseCpu, candidateCpu,
                    maxTimeRegressionPercent, maxTimeRegressionUs) ||
                meaningfulRegression(baseRss, candidateRss,
                    maxRssRegressionPercent, maxRssRegressionBytes) ||
                meaningfulRegression(baseSourceHash, candidateSourceHash,
                    maxTimeRegressionPercent, maxPhaseRegressionNs) ||
                meaningfulRegression(baseOutputHash, candidateOutputHash,
                    maxTimeRegressionPercent, maxPhaseRegressionNs) ||
                (layout["layout"].str != "startup" &&
                    candidateFd > baseFd)) noRegression = false;

        JSONValue row;
        row["layout"] = layout["layout"].str;
        row["route"] = route;
        row["mode"] = mode;
        row["base_wall_us"] = cast(long)baseWall;
        row["candidate_wall_us"] = cast(long)candidateWall;
        row["wall_percent"] = wallPercent;
        row["base_user_us"] = cast(long)baseUser;
        row["candidate_user_us"] = cast(long)candidateUser;
        row["base_system_us"] = cast(long)baseSystem;
        row["candidate_system_us"] = cast(long)candidateSystem;
        row["base_cpu_us"] = cast(long)baseCpu;
        row["candidate_cpu_us"] = cast(long)candidateCpu;
        row["cpu_percent"] = cpuPercent;
        row["base_peak_rss_bytes"] = cast(long)baseRss;
        row["candidate_peak_rss_bytes"] = cast(long)candidateRss;
        row["rss_percent"] = rssPercent;
        row["base_fd_peak"] = cast(long)baseFd;
        row["candidate_fd_peak"] = cast(long)candidateFd;
        row["base_source_hash_ns"] = cast(long)baseSourceHash;
        row["candidate_source_hash_ns"] = cast(long)candidateSourceHash;
        row["source_hash_percent"] = sourceHashPercent;
        row["base_output_hash_ns"] = cast(long)baseOutputHash;
        row["candidate_output_hash_ns"] = cast(long)candidateOutputHash;
        row["output_hash_percent"] = outputHashPercent;
        result ~= row;
    }
    thresholdsPassed = materialWall && materialHash && noRegression;
    return result;
}

private bool lowerHex(string value, size_t length) {
    if (value.length != length) return false;
    foreach (character; value)
        if (!(character >= '0' && character <= '9') &&
                !(character >= 'a' && character <= 'f')) return false;
    return true;
}

private void validateComparisonReport(string path, string baseBinary,
        string baseSource, string candidateBinary, string candidateSource,
        string harnessBinary) {
    auto report = parseJSON(readText(path));
    need(exactKeys(report, ["schema", "version", "base_source_sha",
            "candidate_source_sha", "base_binary_sha256",
            "candidate_binary_sha256", "harness_sha256", "method",
            "thresholds", "layouts", "comparisons", "decision", "claim"]) &&
        report["schema"].str == "scrubbed-sha256-migration-comparison-v2" &&
        report["version"].integer == 2 &&
        lowerHex(report["base_source_sha"].str, 40) &&
        lowerHex(report["candidate_source_sha"].str, 40) &&
        report["base_source_sha"].str != report["candidate_source_sha"].str &&
        report["base_source_sha"].str == baseSource &&
        report["candidate_source_sha"].str == candidateSource,
        "comparison report identity mismatch");
    need(report["base_binary_sha256"].str == fileDigest(baseBinary) &&
        report["candidate_binary_sha256"].str == fileDigest(candidateBinary) &&
        report["base_binary_sha256"].str !=
            report["candidate_binary_sha256"].str &&
        report["harness_sha256"].str == fileDigest(harnessBinary),
        "comparison report binary identity mismatch");
    auto method = report["method"];
    need(exactKeys(method, ["ordering", "runs_per_case", "instrumentation"]) &&
        method["ordering"].str ==
            "paired alternating base/candidate and mode order" &&
        method["runs_per_case"].integer == comparisonRuns &&
        method["instrumentation"].str ==
            "durable-phase-metrics-enabled; production-default-off",
        "comparison method mismatch");
    auto thresholds = report["thresholds"];
    need(exactKeys(thresholds, ["material_improvement_percent",
            "max_time_regression_percent", "max_time_regression_us",
            "max_phase_regression_ns", "max_rss_regression_percent",
            "max_rss_regression_bytes", "fd_regression_allowed"]) &&
        thresholds["material_improvement_percent"].floating ==
            materialImprovementPercent &&
        thresholds["max_time_regression_percent"].floating ==
            maxTimeRegressionPercent &&
        thresholds["max_time_regression_us"].integer == maxTimeRegressionUs &&
        thresholds["max_phase_regression_ns"].integer == maxPhaseRegressionNs &&
        thresholds["max_rss_regression_percent"].floating ==
            maxRssRegressionPercent &&
        thresholds["max_rss_regression_bytes"].integer ==
            maxRssRegressionBytes &&
        thresholds["fd_regression_allowed"].integer == 0,
        "comparison thresholds mismatch");
    auto layoutRows = report["layouts"].array;
    need(layoutRows.length == comparisonLayouts.length,
        "comparison layout cardinality mismatch");
    foreach (index, ref layout; layoutRows) {
        auto expected = comparisonLayouts[index];
        need(exactKeys(layout, ["layout", "files", "input_bytes",
                "input_tree_sha256", "input_concatenated_sha256",
                "upgrade_proofs", "runs"]) &&
            layout["layout"].str == expected.name &&
            layout["files"].integer == expected.files &&
            layout["input_bytes"].integer ==
                expected.files * expected.recordsPerFile * recordBytes &&
            layout["input_tree_sha256"].str == expectedInputTree(expected.name) &&
            layout["input_concatenated_sha256"].str ==
                expectedInputConcatenated(expected.name) &&
            layout["runs"].array.length == 2 * 2 * 2 * comparisonRuns,
            "comparison layout shape mismatch");
        auto proofs = layout["upgrade_proofs"].array;
        need(proofs.length == 2, "comparison upgrade proof cardinality mismatch");
        foreach (proofIndex, proof; proofs) {
            need(exactKeys(proof, ["route", "output_tree_sha256",
                    "output_concatenated_sha256", "base_execution_calls",
                    "candidate_retry_execution_calls",
                    "candidate_retry_publication_calls",
                    "candidate_replay_execution_calls",
                    "candidate_replay_publication_calls"]) &&
                proof["route"].str == (proofIndex == 0
                    ? "manifest-v2" : "journal-v3") &&
                lowerHex(proof["output_tree_sha256"].str, 64) &&
                lowerHex(proof["output_concatenated_sha256"].str, 64) &&
                proof["base_execution_calls"].integer == expected.files &&
                proof["candidate_retry_execution_calls"].integer ==
                    expected.files &&
                proof["candidate_retry_publication_calls"].integer ==
                    expected.files &&
                proof["candidate_replay_execution_calls"].integer == 0 &&
                proof["candidate_replay_publication_calls"].integer == 0,
                "comparison upgrade proof mismatch");
        }
        auto runs = layout["runs"].array;
        size_t sequenceIndex;
        foreach (route; ["manifest-v2", "journal-v3"])
            foreach (ordinal; 0 .. comparisonRuns)
                foreach (mode; comparisonModeOrder(ordinal))
                    foreach (role; comparisonRoleOrder(ordinal)) {
                        auto row = runs[sequenceIndex++];
                        need(row["route"].str == route &&
                            row["variant"].str == mode &&
                            row["ordinal"].integer == ordinal &&
                            row["binary_role"].str == role,
                            "comparison acquisition order mismatch");
                    }
        need(sequenceIndex == runs.length,
            "comparison acquisition order cardinality mismatch");
        string outputTree, outputConcatenated;
        foreach (row; runs) {
            auto tree = row["output_tree_sha256"].str;
            auto concatenated = row["output_concatenated_sha256"].str;
            auto mode = row["variant"].str;
            auto phases = row["metrics"];
            auto expectedExecutions = mode == "reexecute" ? expected.files : 0;
            need(exactKeys(row, ["route", "variant", "ordinal", "wall_us",
                    "user_us", "system_us", "peak_rss_bytes",
                    "sampled_fd_peak", "fd_poll_samples", "fd_poll_errors",
                    "log_sha256", "output_tree_sha256",
                    "output_concatenated_sha256", "stack_status",
                    "stack_sha256", "d_gc_status", "metrics", "binary_role"]) &&
                (row["route"].str == "manifest-v2" ||
                    row["route"].str == "journal-v3") &&
                (mode == "reexecute" || mode == "verified-skip") &&
                (row["binary_role"].str == "base" ||
                    row["binary_role"].str == "candidate") &&
                row["ordinal"].integer >= 0 &&
                row["ordinal"].integer < comparisonRuns &&
                row["wall_us"].integer > 0 && row["user_us"].integer >= 0 &&
                row["system_us"].integer >= 0 &&
                row["peak_rss_bytes"].integer > 0 &&
                row["sampled_fd_peak"].integer >= 0 &&
                row["fd_poll_samples"].integer >= 0 &&
                row["fd_poll_errors"].integer >= 0 &&
                (expected.name == "startup" ||
                    (row["fd_poll_samples"].integer > 0 &&
                        row["sampled_fd_peak"].integer > 0)) &&
                row["stack_status"].str == "not-attempted" &&
                row["stack_sha256"].str.length == 0 &&
                row["d_gc_status"].str == "not-attempted" &&
                lowerHex(row["log_sha256"].str, 64) &&
                lowerHex(tree, 64) && lowerHex(concatenated, 64),
                "comparison output identity shape mismatch");
            need(exactKeys(phases, phaseNames),
                "comparison phase set mismatch");
            foreach (phaseName; phaseNames) {
                auto phase = phases[phaseName];
                need(exactKeys(phase, ["calls", "bytes", "nanoseconds"]) &&
                    phase["calls"].integer >= 0 &&
                    phase["bytes"].integer >= 0 &&
                    phase["nanoseconds"].integer >= 0,
                    "comparison phase shape mismatch: " ~ phaseName);
            }
            need(phases["compiled_execution"]["calls"].integer ==
                    expectedExecutions &&
                phases["publication"]["calls"].integer == 0 &&
                phases["source_hash"]["calls"].integer == expected.files &&
                phases["output_hash"]["calls"].integer == expected.files,
                "comparison phase accounting mismatch");
            if (outputTree.length == 0) {
                outputTree = tree;
                outputConcatenated = concatenated;
            } else need(tree == outputTree && concatenated == outputConcatenated,
                "comparison output identity mismatch");
        }
        foreach (proof; proofs)
            need(proof["output_tree_sha256"].str == outputTree &&
                proof["output_concatenated_sha256"].str == outputConcatenated,
                "comparison upgrade output identity mismatch");
    }
    bool passed;
    auto derived = comparisonRows(layoutRows, passed);
    need(report["comparisons"].toString == JSONValue(derived).toString,
        "comparison derived medians mismatch");
    need(report["decision"].str == (passed ? "PASS" : "FAIL") && passed,
        "comparison thresholds not satisfied");
    need(report["claim"].str ==
        "same-host interleaved comparison; cache and frequency uncontrolled",
        "comparison claim mismatch");
}

private JSONValue syntheticComparisonReport(string baseBinary,
        string candidateBinary, string harnessBinary) {
    JSONValue[] layoutRows;
    foreach (ref layout; comparisonLayouts) {
        JSONValue layoutRow;
        layoutRow["layout"] = layout.name;
        layoutRow["files"] = cast(long)layout.files;
        layoutRow["input_bytes"] = cast(long)(layout.files *
            layout.recordsPerFile * recordBytes);
        layoutRow["input_tree_sha256"] = expectedInputTree(layout.name);
        layoutRow["input_concatenated_sha256"] =
            expectedInputConcatenated(layout.name);
        JSONValue[] proofs;
        foreach (route; ["manifest-v2", "journal-v3"]) {
            JSONValue proof;
            proof["route"] = route;
            proof["output_tree_sha256"] = "4".replicate(64);
            proof["output_concatenated_sha256"] = "5".replicate(64);
            proof["base_execution_calls"] = cast(long)layout.files;
            proof["candidate_retry_execution_calls"] = cast(long)layout.files;
            proof["candidate_retry_publication_calls"] = cast(long)layout.files;
            proof["candidate_replay_execution_calls"] = 0;
            proof["candidate_replay_publication_calls"] = 0;
            proofs ~= proof;
        }
        layoutRow["upgrade_proofs"] = proofs;
        JSONValue[] rows;
        foreach (route; ["manifest-v2", "journal-v3"])
            foreach (ordinal; 0 .. comparisonRuns)
                foreach (mode; comparisonModeOrder(ordinal))
                    foreach (role; comparisonRoleOrder(ordinal)) {
                        auto candidate = role == "candidate";
                        JSONValue row;
                        row["route"] = route;
                        row["variant"] = mode;
                        row["ordinal"] = cast(long)ordinal;
                        row["wall_us"] = candidate ? 800_000 : 1_000_000;
                        row["user_us"] = candidate ? 700_000 : 800_000;
                        row["system_us"] = 100_000;
                        row["peak_rss_bytes"] = 64 * 1024 * 1024;
                        row["sampled_fd_peak"] = 12;
                        row["fd_poll_samples"] = 10;
                        row["fd_poll_errors"] = 0;
                        row["log_sha256"] = "3".replicate(64);
                        row["output_tree_sha256"] = "4".replicate(64);
                        row["output_concatenated_sha256"] = "5".replicate(64);
                        row["stack_status"] = "not-attempted";
                        row["stack_sha256"] = "";
                        row["d_gc_status"] = "not-attempted";
                        JSONValue phases;
                        foreach (phaseName; phaseNames) {
                            JSONValue phase;
                            phase["calls"] = 0;
                            phase["bytes"] = 0;
                            phase["nanoseconds"] = 0;
                            phases[phaseName] = phase;
                        }
                        phases["compiled_execution"]["calls"] =
                            mode == "reexecute" ? cast(long)layout.files : 0;
                        phases["source_hash"]["calls"] = cast(long)layout.files;
                        phases["source_hash"]["nanoseconds"] = candidate ?
                            70_000_000 : 100_000_000;
                        phases["output_hash"]["calls"] = cast(long)layout.files;
                        phases["output_hash"]["nanoseconds"] = candidate ?
                            70_000_000 : 100_000_000;
                        row["metrics"] = phases;
                        row["binary_role"] = role;
                        rows ~= row;
                    }
        layoutRow["runs"] = rows;
        layoutRows ~= layoutRow;
    }
    bool passed;
    auto comparisons = comparisonRows(layoutRows, passed);
    need(passed, "synthetic comparison should pass");
    JSONValue report;
    report["schema"] = "scrubbed-sha256-migration-comparison-v2";
    report["version"] = 2;
    report["base_source_sha"] = "a".replicate(40);
    report["candidate_source_sha"] = "b".replicate(40);
    report["base_binary_sha256"] = fileDigest(baseBinary);
    report["candidate_binary_sha256"] = fileDigest(candidateBinary);
    report["harness_sha256"] = fileDigest(harnessBinary);
    report["method"] = JSONValue([
        "ordering": JSONValue("paired alternating base/candidate and mode order"),
        "runs_per_case": JSONValue(comparisonRuns),
        "instrumentation": JSONValue(
            "durable-phase-metrics-enabled; production-default-off")]);
    report["thresholds"] = comparisonThresholds();
    report["layouts"] = layoutRows;
    report["comparisons"] = comparisons;
    report["decision"] = "PASS";
    report["claim"] =
        "same-host interleaved comparison; cache and frequency uncontrolled";
    return report;
}

private void comparisonDecisionSelfTest(ref const JSONValue good) {
    bool passed;
    auto noWall = parseJSON(good.toString);
    foreach (ref layout; noWall["layouts"].array) {
        if (layout["layout"].str == "startup") continue;
        foreach (ref row; layout["runs"].array)
            if (row["binary_role"].str == "candidate") row["wall_us"] = 950_000;
    }
    auto noWallRows = noWall["layouts"].array;
    comparisonRows(noWallRows, passed);
    need(!passed, "missing material wall improvement accepted");

    auto noHash = parseJSON(good.toString);
    foreach (ref layout; noHash["layouts"].array) {
        if (layout["layout"].str == "startup") continue;
        foreach (ref row; layout["runs"].array)
            if (row["binary_role"].str == "candidate") {
                row["metrics"]["source_hash"]["nanoseconds"] = 95_000_000;
                row["metrics"]["output_hash"]["nanoseconds"] = 95_000_000;
            }
    }
    auto noHashRows = noHash["layouts"].array;
    comparisonRows(noHashRows, passed);
    need(!passed, "missing material hash improvement accepted");

    auto cpuRegression = parseJSON(good.toString);
    long[comparisonRuns] users = [100_000, 100_000, 100_000, 1_100_000,
        1_100_000];
    long[comparisonRuns] systems = [1_100_000, 1_100_000, 100_000, 100_000,
        100_000];
    foreach (ref row; cpuRegression["layouts"][0]["runs"].array) {
        if (row["route"].str != "manifest-v2" ||
                row["variant"].str != "reexecute") continue;
        row["wall_us"] = 2_000_000;
        if (row["binary_role"].str == "candidate") {
            auto ordinal = cast(size_t)row["ordinal"].integer;
            row["user_us"] = users[ordinal];
            row["system_us"] = systems[ordinal];
        }
    }
    auto cpuRows = cpuRegression["layouts"].array;
    comparisonRows(cpuRows, passed);
    need(!passed, "paired CPU regression accepted");

    auto fdRegression = parseJSON(good.toString);
    foreach (ref row; fdRegression["layouts"][0]["runs"].array)
        if (row["route"].str == "manifest-v2" &&
                row["variant"].str == "reexecute" &&
                row["binary_role"].str == "candidate")
            row["sampled_fd_peak"] = 13;
    auto fdRows = fdRegression["layouts"].array;
    comparisonRows(fdRows, passed);
    need(!passed, "file-descriptor regression accepted");
}

private void comparisonValidatorSelfTest(string harnessBinary) {
    auto root = buildPath(tempDir, "scrubbed-sha-comparison-selftest-" ~
        randomUUID.toString);
    mkdirRecurse(root);
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto base = buildPath(root, "base");
    auto candidate = buildPath(root, "candidate");
    auto reportPath = buildPath(root, "report.json");
    write(base, "base");
    write(candidate, "candidate");
    auto startupFixture = buildPath(root, "startup-fixture");
    makeFixture(startupFixture, comparisonLayouts[2]);
    auto startupIdentity = identify(startupFixture);
    need(startupIdentity.tree == expectedInputTree("startup") &&
        startupIdentity.concatenated == expectedInputConcatenated("startup"),
        "startup fixture pin mismatch");
    auto good = syntheticComparisonReport(base, candidate, harnessBinary);
    comparisonDecisionSelfTest(good);
    write(reportPath, good.toString);
    validateComparisonReport(reportPath, base, "a".replicate(40), candidate,
        "b".replicate(40), harnessBinary);

    void mustReject(JSONValue mutant, string message) {
        write(reportPath, mutant.toString);
        bool rejected;
        try validateComparisonReport(reportPath, base, "a".replicate(40),
            candidate, "b".replicate(40), harnessBinary);
        catch (Exception) rejected = true;
        need(rejected, message);
    }
    auto threshold = parseJSON(good.toString);
    threshold["thresholds"]["max_time_regression_percent"] = 50.0;
    mustReject(threshold, "threshold mutation accepted");
    auto nestedShape = parseJSON(good.toString);
    nestedShape["method"]["unexpected"] = true;
    mustReject(nestedShape, "nested schema extension accepted");
    auto acquisitionOrder = parseJSON(good.toString);
    auto first = acquisitionOrder["layouts"][0]["runs"][0];
    acquisitionOrder["layouts"][0]["runs"][0] =
        acquisitionOrder["layouts"][0]["runs"][1];
    acquisitionOrder["layouts"][0]["runs"][1] = first;
    mustReject(acquisitionOrder, "acquisition order mutation accepted");
    auto observation = parseJSON(good.toString);
    foreach (ref row; observation["layouts"][0]["runs"].array)
        if (row["route"].str == "manifest-v2" &&
                row["variant"].str == "reexecute" &&
                row["binary_role"].str == "candidate" &&
                row["ordinal"].integer < 3)
            row["wall_us"] = 2_000_000;
    mustReject(observation, "observation mutation accepted");
    auto source = parseJSON(good.toString);
    source["candidate_source_sha"] = "c".replicate(40);
    mustReject(source, "forged source identity accepted");
    auto fixture = parseJSON(good.toString);
    fixture["layouts"][0]["input_tree_sha256"] = "6".replicate(64);
    mustReject(fixture, "fixture identity mutation accepted");
    auto fdSampling = parseJSON(good.toString);
    fdSampling["layouts"][0]["runs"][0]["sampled_fd_peak"] = 0;
    mustReject(fdSampling, "zero non-startup FD sample accepted");
    auto decision = parseJSON(good.toString);
    decision["decision"] = "FAIL";
    mustReject(decision, "decision mutation accepted");
    writeln("SHA-256 migration comparison validator self-test passed");
}

private void upgradeSelfTest(string baseBinary, string candidateBinary) {
    baseBinary = absolutePath(baseBinary);
    candidateBinary = absolutePath(candidateBinary);
    need(exists(baseBinary) && exists(candidateBinary),
        "upgrade self-test binary missing");
    auto root = buildPath(tempDir, "scrubbed-sha-upgrade-selftest-" ~
        randomUUID.toString);
    mkdirRecurse(root);
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto input = buildPath(root, "startup-input");
    makeFixture(input, comparisonLayouts[2]);
    auto identity = identify(input);
    need(identity.tree == expectedInputTree("startup") &&
        identity.concatenated == expectedInputConcatenated("startup"),
        "upgrade self-test fixture mismatch");
    ComparisonTarget[] targets = [ComparisonTarget("base", baseBinary),
        ComparisonTarget("candidate", candidateBinary)];
    foreach (route; ["manifest-v2", "journal-v3"])
        upgradeProof(targets, root, comparisonLayouts[2], input, route);
    writeln("SHA-256 base-to-candidate durable upgrade self-test passed");
}

private void writeComparisonReport(string baseBinary, string baseSource,
        string candidateBinary, string candidateSource, string evidence,
        string harnessBinary) {
    baseBinary = absolutePath(baseBinary);
    candidateBinary = absolutePath(candidateBinary);
    evidence = absolutePath(evidence);
    need(exists(baseBinary) && exists(candidateBinary) && !exists(evidence),
        "comparison binary missing or evidence exists");
    need(lowerHex(baseSource, 40) && lowerHex(candidateSource, 40) &&
        baseSource != candidateSource, "comparison source identity mismatch");
    auto root = buildPath(tempDir, "scrubbed-sha256-comparison-" ~
        randomUUID.toString);
    mkdirRecurse(root);
    scope(exit) if (exists(root)) rmdirRecurse(root);
    ComparisonTarget[] targets = [ComparisonTarget("base", baseBinary),
        ComparisonTarget("candidate", candidateBinary)];
    JSONValue[] layoutRows;
    foreach (ref layout; comparisonLayouts)
        layoutRows ~= comparisonLayoutEvidence(targets, root, layout);
    bool passed;
    auto comparisons = comparisonRows(layoutRows, passed);
    JSONValue report;
    report["schema"] = "scrubbed-sha256-migration-comparison-v2";
    report["version"] = 2;
    report["base_source_sha"] = baseSource;
    report["candidate_source_sha"] = candidateSource;
    report["base_binary_sha256"] = fileDigest(baseBinary);
    report["candidate_binary_sha256"] = fileDigest(candidateBinary);
    report["harness_sha256"] = fileDigest(harnessBinary);
    JSONValue method;
    method["ordering"] = "paired alternating base/candidate and mode order";
    method["runs_per_case"] = comparisonRuns;
    method["instrumentation"] =
        "durable-phase-metrics-enabled; production-default-off";
    report["method"] = method;
    report["thresholds"] = comparisonThresholds();
    report["layouts"] = layoutRows;
    report["comparisons"] = comparisons;
    report["decision"] = passed ? "PASS" : "FAIL";
    report["claim"] = "same-host interleaved comparison; cache and frequency uncontrolled";
    auto text = report.toString;
    need(!text.canFind(root), "comparison evidence leaked temporary path");
    write(evidence, text ~ "\n");
    validateComparisonReport(evidence, baseBinary, baseSource, candidateBinary,
        candidateSource, harnessBinary);
    writeln("SHA-256 migration comparison: wrote ", evidence);
}

void main(string[] args) {
    if (args.length == 2 && args[1] == "--self-test-comparison") {
        comparisonValidatorSelfTest(args[0]);
        return;
    }
    if (args.length == 4 && args[1] == "--self-test-upgrade") {
        upgradeSelfTest(args[2], args[3]);
        return;
    }
    if (args.length == 7 && args[1] == "--compare") {
        writeComparisonReport(args[2], args[3], args[4], args[5], args[6],
            args[0]);
        return;
    }
    if (args.length == 7 && args[1] == "--check-compare") {
        validateComparisonReport(args[2], absolutePath(args[3]), args[4],
            absolutePath(args[5]), args[6], args[0]);
        writeln("SHA-256 migration comparison valid");
        return;
    }
    need(args.length == 3, "usage: durable_skip_check <release binary> " ~
        "<evidence.json> | --compare <base binary> <base source SHA> " ~
        "<candidate binary> <candidate source SHA> <evidence.json> | " ~
        "--check-compare <evidence.json> <base binary> <base source SHA> " ~
        "<candidate binary> <candidate source SHA> | " ~
        "--self-test-comparison | --self-test-upgrade <base binary> " ~
        "<candidate binary>");
    auto binary = absolutePath(args[1]);
    auto evidence = absolutePath(args[2]);
    need(exists(binary) && !exists(evidence), "binary missing or evidence exists");
    auto root = buildPath(tempDir, "scrubbed-durable-skip-" ~ randomUUID.toString);
    mkdirRecurse(root);
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto output = appender!string;
    output.put(`{"schema":"scrubbed.durable-skip-evidence.v1","version":1,` ~
        `"shipping_binary_sha256":`); output.put(q(fileDigest(binary)));
    output.put(`,"harness_sha256":`); output.put(q(fileDigest(args[0])));
    output.put(`,"method":{"claim":"descriptive","runs":3,"instrumentation":"default-off"},` ~
        `"layouts":[`);
    foreach (index, ref layout; layouts) {
        if (index) output.put(',');
        output.put(layoutEvidence(binary, root, layout));
    }
    output.put(`]}`);
    auto text = output.data;
    need(!text.canFind(root), "evidence leaked temporary path");
    parseJSON(text);
    write(evidence, text ~ "\n");
    need(readText(evidence) == text ~ "\n", "evidence reopen mismatch");
    writeln("durable skip evidence: wrote ", evidence);
}
