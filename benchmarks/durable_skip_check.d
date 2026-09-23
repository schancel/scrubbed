/// O3/release evidence for exact manifest-v2 and journal-v3 verified skips.
module benchmarks.durable_skip_check;

import core.atomic : atomicLoad, atomicStore;
import core.stdc.errno : EINTR, errno;
import core.sys.posix.sys.resource : rusage;
import core.sys.posix.sys.wait : WEXITSTATUS, WIFEXITED;
import core.thread : Thread;
import core.time : msecs;
import std.algorithm.sorting : sort;
import std.algorithm.searching : canFind;
import std.array : appender, array;
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

private enum recordBytes = 256;
private enum recordCount = 524_288;
private enum runs = 3;

private void need(bool value, string message) {
    if (!value) throw new Exception("durable skip evidence: " ~ message);
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
    need(ordinal == recordCount, "frozen record cardinality mismatch");
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
    size_t fdPeak;
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
    shared size_t peak;
    auto sampler = new Thread({
        while (!atomicLoad(stopped)) {
            auto seen = execute(["/usr/sbin/lsof", "-p", child.processID.to!string]);
            if (seen.status == 0) {
                auto count = seen.output.splitLines.length;
                if (count) --count;
                if (count > atomicLoad(peak)) atomicStore(peak, count);
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
    atomicStore(stopped, true); sampler.join(); timer.stop();
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
        `,"log_sha256":` ~ q(item.logHash) ~ `,"output_tree_sha256":` ~
        q(output.tree) ~ `,"output_concatenated_sha256":` ~ q(output.concatenated) ~
        `,"stack_status":` ~ q(item.stackStatus) ~ `,"stack_sha256":` ~
        q(item.stackHash) ~ `,"d_gc_status":` ~ q(item.gcStatus) ~
        `,"metrics":` ~ phases.toString ~ `}`;
}

private string layoutEvidence(string binary, string root, ref const Layout layout) {
    auto input = buildPath(root, layout.name ~ "-input");
    makeFixture(input, layout);
    auto inputId = identify(input);
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

void main(string[] args) {
    need(args.length == 3, "usage: durable_skip_check <release binary> <evidence.json>");
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
