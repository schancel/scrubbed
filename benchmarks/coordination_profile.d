/// Frozen O3/release coordination attribution for issue #182.
module benchmarks.coordination_profile;

import core.atomic : atomicLoad, atomicStore;
import core.stdc.errno : EINTR, errno;
import core.sys.posix.sys.resource : rusage;
import core.sys.posix.sys.wait : WEXITSTATUS, WIFEXITED;
import core.thread : Thread;
import core.time : msecs;
import std.algorithm.sorting : sort;
import std.algorithm.searching : canFind;
import std.array : appender;
import std.conv : to;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.digest : LetterCase, toHexString;
import std.digest.sha : SHA256, sha256Of;
import std.file : SpanMode, dirEntries, exists, mkdirRecurse, read, readText,
    remove, rmdirRecurse, tempDir, write;
import std.json : JSONValue, parseJSON;
import std.path : absolutePath, buildPath, relativePath;
import std.process : execute, spawnProcess;
import std.stdio : File, writeln;
import std.string : splitLines, strip;
import std.uuid : randomUUID;

extern(C) int wait4(int pid, int* status, int options, rusage* usage);

private enum recordBytes = 256;
private enum recordCount = 524_288;
private enum runs = 5;
private enum fixtureTablePin =
    "34B08DAEE0547466C0EEF809A0A1BEDBDC4FEE26BEABE23F4478BBDAFFF0727E";
private enum configPin =
    "FC1829939C5EC9347EFBD576978F3EBE017F069C525157FDCC626E8842EBD7FB";

private struct RecordCase { string input, scalar, mixed; }
private immutable RecordCase[] records = [
    RecordCase("plain ASCII unchanged 123\t\n", "plain ASCII unchanged 123\t\n", "plain ASCII unchanged 123\t\n"),
    RecordCase("valid café 😀 unchanged\n", "valid café 😀 unchanged\n", "valid café 😀 unchanged\n"),
    RecordCase("repair cafÃ© and FranÃ§ais\n", "repair cafÃ© and FranÃ§ais\n", "repair café and Français\n"),
    RecordCase("negative © α 中 remains valid\n", "negative © α 中 remains valid\n", "negative © α 中 remains valid\n"),
    RecordCase("entities &amp; &lt; &#33; &unknown;\n", "entities &amp; &lt; &#33; &unknown;\n", "entities & < ! &unknown;\n"),
    RecordCase("quotes “hello” ‘world’ straight \"ok\"\n", "quotes “hello” ‘world’ straight \"ok\"\n", "quotes \"hello\" 'world' straight \"ok\"\n"),
    RecordCase("lines a\r\nb\rc\n", "lines a\nb\nc\n", "lines a\nb\nc\n"),
    RecordCase("control \x01 removed; tab\tand LF\n", "control  removed; tab\tand LF\n", "control  removed; tab\tand LF\n")
];

private struct Layout { string name; size_t files; size_t perFile; }
private immutable Layout[] layouts = [
    Layout("many-small", 4096, 128),
    Layout("few-large", 8, 65_536)
];
private immutable string[string] inputTreePins = [
    "many-small": "5B5D9E66435A5BC705152EB88C551046BE0AA37B51F4FA42A038683AAFB51167",
    "few-large": "A69113BEE8E66CE349C620BD122821F4D0719ABC2263A143E8AA0264CF030548"];
private immutable string[string] outputTreePins = [
    "many-small": "3ED0A176AA89B8B9428FD3F937042EE45781C6FF3546069BB7CF92A4FA6D9529",
    "few-large": "9AAC92A1892B67FCADCAD16E98917446B8077ABB0F8B6826810E5767EACB6DDC"];

private void need(bool value, string message) {
    if (!value) throw new Exception("coordination evidence: " ~ message);
}

private string hexDigest(const(ubyte)[] value) {
    return toHexString(sha256Of(value)).idup;
}

private string fileDigest(string path) {
    return hexDigest(cast(const(ubyte)[])read(path));
}

private string commandOutput(string[] command) {
    auto result = execute(command);
    need(result.status == 0, "host identity command failed");
    return result.output.strip.idup;
}

private string inputRecord(size_t index) {
    auto value = records[index % records.length].input;
    auto result = (value ~ cast(string)new char[](recordBytes - value.length)).dup;
    foreach (ref c; result[value.length .. $]) c = 'x';
    return cast(string)result;
}

private string tableIdentity() {
    string value;
    foreach (row; records)
        value ~= row.input.length.to!string ~ ":" ~ row.input ~
            row.scalar.length.to!string ~ ":" ~ row.scalar ~
            row.mixed.length.to!string ~ ":" ~ row.mixed;
    return hexDigest(cast(const(ubyte)[])value);
}

private string configText() {
    return `{"version":3,"stages":[{"id":"legacy-text",` ~
        `"implementation":"text-transform","options":{},"filters":[` ~
        `{"name":"uncurl-quotes","options":{}},` ~
        `{"name":"fix-mojibake","options":{"max-passes":2}},` ~
        `{"name":"decode-html-entities","options":{}},` ~
        `{"name":"normalize-line-endings","options":{}},` ~
        `{"name":"strip-control","options":{}}]}]}`;
}

private void makeFixture(string root, ref const Layout layout) {
    mkdirRecurse(root);
    size_t ordinal;
    foreach (index; 0 .. layout.files) {
        auto file = File(buildPath(root, "doc-" ~ index.to!string ~ ".txt"), "wb");
        foreach (_; 0 .. layout.perFile) file.rawWrite(inputRecord(ordinal++));
    }
    need(ordinal == recordCount, "fixture cardinality differs");
}

private struct Tree { ulong bytes; string tree; string concatenated; }
private Tree identify(string root) {
    string[] names;
    foreach (entry; dirEntries(root, SpanMode.depth, false)) {
        need(entry.isFile, "tree contains non-file");
        names ~= relativePath(entry.name, root);
    }
    names.sort();
    SHA256 tree, concatenated;
    ulong bytes;
    foreach (name; names) {
        auto body = cast(const(ubyte)[])read(buildPath(root, name));
        auto leaf = hexDigest(body);
        foreach (part; [name, body.length.to!string, leaf]) {
            auto length = part.length.to!string;
            tree.put(cast(const(ubyte)[])length);
            tree.put(cast(const(ubyte)[])":");
            tree.put(cast(const(ubyte)[])part);
        }
        concatenated.put(body); bytes += body.length;
    }
    return Tree(bytes,
        toHexString(tree.finish()).idup,
        toHexString(concatenated.finish()).idup);
}

private ulong micros(ref const typeof(rusage.init.ru_utime) value) {
    return cast(ulong)value.tv_sec * 1_000_000 + value.tv_usec;
}

private JSONValue invoke(string binary, string input, string output,
        string config, size_t threads, size_t ordinal, string root,
        bool instrumented) {
    auto label = (instrumented ? "attribution-" : "performance-") ~
        threads.to!string ~ "-" ~ ordinal.to!string ~ "-" ~
        randomUUID.toString;
    auto metricsPath = buildPath(root, label ~ ".metrics.json");
    auto stdoutPath = buildPath(root, label ~ ".out");
    auto stderrPath = buildPath(root, label ~ ".err");
    auto stdinFile = File("/dev/null", "rb");
    auto stdoutFile = File(stdoutPath, "wb");
    auto stderrFile = File(stderrPath, "wb");
    string[] command = instrumented ? ["/usr/bin/env",
        "SCRUBBED_COORDINATION_METRICS_V1=" ~ metricsPath, binary] : [binary];
    if (instrumented && ordinal == 0) command ~= "--DRT-gcopt=profile:2";
    command ~= ["run", "--input", input, "--output", output, "--config", config,
        "--threads", threads.to!string, "--max-open-inputs", threads.to!string];
    auto timer = StopWatch(AutoStart.yes);
    auto child = spawnProcess(command, stdinFile, stdoutFile, stderrFile);
    stdinFile.close(); stdoutFile.close(); stderrFile.close();
    shared bool stopped;
    shared size_t peakFd;
    auto sampler = new Thread({
        while (!atomicLoad(stopped)) {
            auto seen = execute(["/usr/sbin/lsof", "-p", child.processID.to!string]);
            if (seen.status == 0) {
                auto count = seen.output.splitLines.length;
                if (count) --count;
                if (count > atomicLoad(peakFd)) atomicStore(peakFd, count);
            }
            Thread.sleep(10.msecs);
        }
    });
    sampler.start();
    string stackStatus = "not-attempted", stackHash;
    if (instrumented && ordinal == 0) {
        auto stackPath = buildPath(root, label ~ ".sample.txt");
        auto sampled = execute(["/usr/bin/sample", child.processID.to!string,
            "1", "10", "-file", stackPath]);
        if (sampled.status == 0 && exists(stackPath)) {
            auto body = cast(const(ubyte)[])read(stackPath);
            stackStatus = body.length ? "supported" : "unsupported-empty";
            if (body.length) stackHash = hexDigest(body);
        } else stackStatus = "unsupported-sample-failed";
    }
    int status; rusage usage; int waited;
    do waited = wait4(child.processID, &status, 0, &usage);
    while (waited < 0 && errno == EINTR);
    atomicStore(stopped, true); sampler.join(); timer.stop();
    need(waited == child.processID && WIFEXITED(status) && WEXITSTATUS(status) == 0,
        "child failed: " ~ readText(stderrPath));
    auto log = readText(stdoutPath);
    need(log.canFind("done. "), "missing completion diagnostic");
    if (instrumented && ordinal == 0)
        need(log.canFind("GC summary:"), "missing D-GC summary");
    auto result = JSONValue([
        "threads": JSONValue(cast(long)threads),
        "ordinal": JSONValue(cast(long)ordinal),
        "wall_us": JSONValue(timer.peek.total!"usecs"),
        "user_us": JSONValue(cast(long)micros(usage.ru_utime)),
        "system_us": JSONValue(cast(long)micros(usage.ru_stime)),
        "peak_rss_bytes": JSONValue(cast(long)usage.ru_opaque[0]),
        "sampled_fd_peak": JSONValue(cast(long)atomicLoad(peakFd)),
        "log_sha256": JSONValue(hexDigest(cast(const(ubyte)[])log)),
        "stack_status": JSONValue(stackStatus),
        "stack_sha256": JSONValue(stackHash),
        "d_gc_status": JSONValue(instrumented && ordinal == 0 ?
            "supported" : "not-attempted"),
        "syscall_status": JSONValue("unsupported-no-exact-child-counter")]);
    if (instrumented) {
        auto metrics = parseJSON(readText(metricsPath));
        need(metrics["schema"].str == "scrubbed.coordination-metrics.v1",
            "metrics schema differs");
        result["metrics"] = metrics;
    }
    return result;
}

private long[] values(JSONValue[] samples, size_t threads, string field) {
    long[] result;
    foreach (sample; samples)
        if (sample["threads"].integer == threads)
            result ~= field == "cpu_us" ?
                sample["user_us"].integer + sample["system_us"].integer :
                sample[field].integer;
    result.sort();
    return result;
}

private long median(JSONValue[] samples, size_t threads, string field) {
    auto ordered = values(samples, threads, field);
    need(ordered.length == runs, "comparison sample cardinality differs");
    return ordered[ordered.length / 2];
}

private long sampleValue(JSONValue[] samples, size_t threads,
        size_t ordinal, string field) {
    foreach (sample; samples)
        if (sample["threads"].integer == threads &&
                sample["ordinal"].integer == ordinal)
            return field == "cpu_us" ?
                sample["user_us"].integer + sample["system_us"].integer :
                sample[field].integer;
    throw new Exception("comparison sample missing");
}

private bool withinFivePercent(long candidate, long baseline) {
    return candidate * 100 <= baseline * 105;
}

private void runComparison(string[] args) {
    auto baseline = absolutePath(args[1]);
    auto candidate = absolutePath(args[2]);
    auto reportPath = absolutePath(args[3]);
    need(exists(baseline) && exists(candidate) && !exists(reportPath),
        "comparison binary missing or report exists");
    need(tableIdentity() == fixtureTablePin, "fixture table pin differs");
    auto root = buildPath(tempDir, "scrubbed-coordination-compare-" ~
        randomUUID.toString);
    mkdirRecurse(root); scope(exit) if (exists(root)) rmdirRecurse(root);
    auto config = buildPath(root, "mixed-v3.json");
    write(config, configText());
    need(fileDigest(config) == configPin, "config pin differs");
    JSONValue[] layoutReports;
    bool controlsPass = true;
    size_t targetWins;
    long targetBaselineWall, targetCandidateWall;
    JSONValue[] baselineAttribution, candidateAttribution;
    foreach (ref layout; layouts) {
        auto input = buildPath(root, layout.name ~ "-input");
        makeFixture(input, layout);
        auto inputId = identify(input);
        need(inputId.tree == inputTreePins[layout.name], "input tree pin differs");
        JSONValue[] baselineSamples, candidateSamples;
        foreach (round; 0 .. runs) foreach (threads; [1, 2, 4]) {
            foreach (candidateFirst; [round % 2 == 1, round % 2 == 0]) {
                auto isCandidate = candidateFirst;
                auto binary = isCandidate ? candidate : baseline;
                auto output = buildPath(root, layout.name ~
                    (isCandidate ? "-candidate-" : "-baseline-") ~
                    threads.to!string ~ "-" ~ round.to!string);
                auto sample = invoke(binary, input, output, config, threads,
                    round, root, false);
                auto outputId = identify(output);
                need(outputId.tree == outputTreePins[layout.name],
                    "comparison exact output tree pin differs");
                sample["output_bytes"] = cast(long)outputId.bytes;
                sample["output_tree_sha256"] = outputId.tree;
                sample["output_concatenated_sha256"] = outputId.concatenated;
                if (isCandidate) candidateSamples ~= sample;
                else baselineSamples ~= sample;
                rmdirRecurse(output);
            }
        }
        foreach (threads; [1, 2, 4]) {
            auto baselineWall = median(baselineSamples, threads, "wall_us");
            auto candidateWall = median(candidateSamples, threads, "wall_us");
            if (layout.name == "many-small" && threads == 4) {
                targetBaselineWall = baselineWall;
                targetCandidateWall = candidateWall;
                foreach (round; 0 .. runs)
                    if (sampleValue(candidateSamples, threads, round, "wall_us") <
                            sampleValue(baselineSamples, threads, round, "wall_us"))
                        ++targetWins;
            }
            if (threads == 1 || layout.name == "few-large") {
                foreach (field; ["wall_us", "cpu_us", "peak_rss_bytes",
                        "sampled_fd_peak"])
                    controlsPass = controlsPass && withinFivePercent(
                        median(candidateSamples, threads, field),
                        median(baselineSamples, threads, field));
            }
        }
        if (layout.name == "many-small")
        foreach (round; 0 .. runs) foreach (candidateFirst;
                [round % 2 == 1, round % 2 == 0]) {
            auto isCandidate = candidateFirst;
            auto binary = isCandidate ? candidate : baseline;
            auto output = buildPath(root, "many-small-attribution-" ~
                (isCandidate ? "candidate-" : "baseline-") ~ round.to!string);
            auto sample = invoke(binary, input, output, config, 4, round,
                root, true);
            auto outputId = identify(output);
            need(outputId.tree == outputTreePins[layout.name],
                "comparison attribution output tree pin differs");
            if (isCandidate) candidateAttribution ~= sample;
            else baselineAttribution ~= sample;
            rmdirRecurse(output);
        }
        layoutReports ~= JSONValue([
            "layout": JSONValue(layout.name),
            "files": JSONValue(cast(long)layout.files),
            "input_bytes": JSONValue(cast(long)inputId.bytes),
            "input_tree_sha256": JSONValue(inputId.tree),
            "baseline_samples": JSONValue(baselineSamples),
            "candidate_samples": JSONValue(candidateSamples)]);
    }
    auto waitField = "accepted_worker_queue";
    long[] baselineWait, candidateWait;
    foreach (sample; baselineAttribution)
        baselineWait ~= sample["metrics"]["phases"][waitField]["nanoseconds"].integer;
    foreach (sample; candidateAttribution)
        candidateWait ~= sample["metrics"]["phases"][waitField]["nanoseconds"].integer;
    baselineWait.sort(); candidateWait.sort();
    auto waitFalls = candidateWait[runs / 2] < baselineWait[runs / 2];
    auto authorized = targetWins >= 4 &&
        targetCandidateWall * 100 <= targetBaselineWall * 90 &&
        waitFalls && controlsPass;
    auto report = JSONValue([
        "schema": JSONValue("scrubbed.coordination-scheduler-comparison.v1"),
        "host_os": JSONValue(commandOutput(["uname", "-s"])),
        "host_architecture": JSONValue(commandOutput(["uname", "-m"])),
        "host_cpu": JSONValue(commandOutput(
            ["sysctl", "-n", "machdep.cpu.brand_string"])),
        "baseline_binary_sha256": JSONValue(fileDigest(baseline)),
        "candidate_binary_sha256": JSONValue(fileDigest(candidate)),
        "harness_sha256": JSONValue(fileDigest(args[0])),
        "fixture_table_sha256": JSONValue(fixtureTablePin),
        "config_sha256": JSONValue(configPin),
        "cache_semantics": JSONValue("application-cold; OS cache uncontrolled"),
        "target_wins": JSONValue(cast(long)targetWins),
        "target_baseline_median_wall_us": JSONValue(targetBaselineWall),
        "target_candidate_median_wall_us": JSONValue(targetCandidateWall),
        "target_baseline_median_queue_ns": JSONValue(baselineWait[runs / 2]),
        "target_candidate_median_queue_ns": JSONValue(candidateWait[runs / 2]),
        "controls_within_five_percent": JSONValue(controlsPass),
        "production_candidate_authorized": JSONValue(authorized),
        "decision": JSONValue(authorized ?
            "AUTHORIZED_BOUNDED_WORKER_AVAILABILITY" :
            "REJECTED_THRESHOLD_NOT_MET"),
        "baseline_attribution": JSONValue(baselineAttribution),
        "candidate_attribution": JSONValue(candidateAttribution),
        "layouts": JSONValue(layoutReports)]);
    auto text = report.toString;
    need(!text.canFind(root), "comparison report leaked temporary path");
    parseJSON(text);
    write(reportPath, text ~ "\n");
    need(readText(reportPath) == text ~ "\n", "comparison report reopen differs");
    writeln("coordination comparison: wrote ", reportPath);
}

private void runAttribution(string[] args) {
    auto binary = absolutePath(args[1]);
    auto reportPath = absolutePath(args[2]);
    need(exists(binary) && !exists(reportPath), "binary missing or report exists");
    need(tableIdentity() == fixtureTablePin, "fixture table pin differs");
    auto root = buildPath(tempDir, "scrubbed-coordination-" ~ randomUUID.toString);
    mkdirRecurse(root); scope(exit) if (exists(root)) rmdirRecurse(root);
    auto config = buildPath(root, "mixed-v3.json");
    write(config, configText());
    need(fileDigest(config) == configPin, "config pin differs");
    JSONValue[] layoutReports;
    foreach (ref layout; layouts) {
        auto input = buildPath(root, layout.name ~ "-input");
        makeFixture(input, layout);
        auto inputId = identify(input);
        need(inputId.tree == inputTreePins[layout.name], "input tree pin differs");
        JSONValue[] performanceSamples, attributionSamples;
        foreach (instrumented; [false, true])
        foreach (round; 0 .. runs) foreach (threads; [1, 2, 4]) {
            auto output = buildPath(root, layout.name ~
                (instrumented ? "-attribution-t" : "-performance-t") ~
                threads.to!string ~ "-r" ~ round.to!string);
            auto sample = invoke(binary, input, output, config, threads, round,
                root, instrumented);
            auto outputId = identify(output);
            need(outputId.tree == outputTreePins[layout.name],
                "exact output tree pin differs");
            if (instrumented) {
                auto metrics = sample["metrics"];
                auto counts = metrics["counts"];
                need(counts["submitted"].integer == layout.files &&
                    counts["succeeded"].integer == layout.files &&
                    counts["failed"].integer == 0 &&
                    counts["skipped"].integer == 0 &&
                    counts["queued_documents"].integer == 0 &&
                    counts["reserved_bytes"].integer == 0 &&
                    counts["worker_descriptors"].integer == 0,
                    "terminal/reservation accounting differs");
                auto phases = metrics["phases"];
                foreach (name; ["source_stat", "ordinal_assignment",
                        "admission_wait", "accepted_worker_queue",
                        "descriptor_wait", "descriptor_hold", "transform",
                        "ordered_result_wait", "atomic_publication"])
                    need(phases[name]["calls"].integer == layout.files,
                        name ~ " root count differs");
                need(phases["shutdown_join"]["calls"].integer == 1,
                    "shutdown count differs");
            }
            sample["output_bytes"] = cast(long)outputId.bytes;
            sample["output_tree_sha256"] = outputId.tree;
            sample["output_concatenated_sha256"] = outputId.concatenated;
            if (instrumented) attributionSamples ~= sample;
            else performanceSamples ~= sample;
            rmdirRecurse(output);
        }
        layoutReports ~= JSONValue([
            "layout": JSONValue(layout.name),
            "files": JSONValue(cast(long)layout.files),
            "input_bytes": JSONValue(cast(long)inputId.bytes),
            "input_tree_sha256": JSONValue(inputId.tree),
            "input_concatenated_sha256": JSONValue(inputId.concatenated),
            "performance_samples": JSONValue(performanceSamples),
            "attribution_samples": JSONValue(attributionSamples)]);
    }
    auto report = JSONValue([
        "schema": JSONValue("scrubbed.coordination-profile.v1"),
        "host_os": JSONValue(commandOutput(["uname", "-s"])),
        "host_architecture": JSONValue(commandOutput(["uname", "-m"])),
        "host_kernel": JSONValue(commandOutput(["uname", "-r"])),
        "host_cpu": JSONValue(commandOutput(
            ["sysctl", "-n", "machdep.cpu.brand_string"])),
        "compiler": JSONValue(commandOutput(["ldc2", "--version"])),
        "shipping_binary_sha256": JSONValue(fileDigest(binary)),
        "harness_sha256": JSONValue(fileDigest(args[0])),
        "fixture_table_sha256": JSONValue(fixtureTablePin),
        "config_sha256": JSONValue(configPin),
        "cache_semantics": JSONValue("application-cold; OS cache uncontrolled"),
        "production_candidate_authorized": JSONValue(false),
        "decision": JSONValue("ATTRIBUTION_ONLY_NO_CANDIDATE"),
        "layouts": JSONValue(layoutReports)]);
    auto text = report.toString;
    need(!text.canFind(root), "report leaked temporary path");
    parseJSON(text);
    write(reportPath, text ~ "\n");
    need(readText(reportPath) == text ~ "\n", "report reopen differs");
    writeln("coordination profile: wrote ", reportPath);
}

void main(string[] args) {
    need(args.length == 3 || args.length == 4,
        "usage: coordination_profile <release-binary> <report> | " ~
        "<baseline-binary> <candidate-binary> <report>");
    if (args.length == 4) runComparison(args);
    else runAttribution(args);
}
