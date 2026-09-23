// Companion attribution evidence for the frozen canonical shipping-CLI profile.
module pipeline_attribution_check;

import core.sys.posix.sys.resource : rusage;
import core.sys.posix.sys.wait : WEXITSTATUS, WIFEXITED, WIFSIGNALED, WTERMSIG;
import core.thread : Thread;
import core.time : msecs;
import std.algorithm.sorting : sort;
import std.algorithm.searching : canFind;
import std.array : join, replicate;
import std.conv : to;
import std.digest : toHexString;
import std.digest.sha : SHA256, sha256Of;
import std.datetime.stopwatch : StopWatch;
import std.file : SpanMode, copy, dirEntries, exists, mkdirRecurse, read, readText,
    remove, rmdirRecurse, tempDir, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.math : isFinite;
import std.path : baseName, buildPath, relativePath;
import std.process : Config, execute, spawnProcess, wait;
import std.stdio : File, writeln;
import std.string : endsWith, indexOf, lastIndexOf, replace, split,
    splitLines, startsWith, strip, toLower;
import std.uuid : randomUUID;

version (OSX) {} else static assert(0,
    "canonical CLI attribution currently requires Darwin");

version (OSX) extern(C) nothrow @nogc int wait4(int, int*, int, rusage*);

private enum schema = "scrubbed-cli-attribution-v1";
private enum harnessName = "scrubbed-pipeline-attribution-check";
private enum harnessBuildRecipe =
    "ldc2 -O3 -release benchmarks/pipeline_attribution_check.d -of=<STANDARD_TMP>/scrubbed-pipeline-attribution-check";
private enum canonicalProfilePin =
    "00CFF582B3C93EDA270BF8FAF349AAD53F2EFBA5723112812EA34BC383B75870";
private enum canonicalProfileBinaryPin =
    "A606ABF6DF8AC912256B39A213F61E493D6FA9706C237A692EAFE437BEC901A7";
private enum canonicalProfileSourcePin =
    "61e8ff9c70ff51842c1dd0063dc253fccc29f1dd";
private enum acceptedBasePin =
    "0fe58a0955e1afe16894c91acfdb7bf59077eee5";
private enum historicalMergeBasePin =
    "65789b90b294b9d0edfe4270d8654e120e7c4928";
private enum recordBytes = 256L;
private enum recordCount = 524_288L;
private enum corpusBytes = recordBytes * recordCount;
private enum scalarBytes = 134_086_656L;
private enum mixedBytes = 132_579_328L;
private enum minimumBudget = 1_800L;
private enum minimumCapacity = 2L * 1024 * 1024 * 1024;
private enum sampleDuration = 2L;
private enum sampleInterval = 10L;
private enum minimumStacks = 100L;
private enum repetitions = 3L;
private enum unavailableToolVersion = "UNAVAILABLE";
private enum fixtureTablePin = "34B08DAEE0547466C0EEF809A0A1BEDBDC4FEE26BEABE23F4478BBDAFFF0727E";
private enum scalarConfigPin = "C985D95C6C2B8B13C2354BEDE8649D1557A13C4E211E647F804787E002C10ED1";
private enum mixedConfigPin = "FC1829939C5EC9347EFBD576978F3EBE017F069C525157FDCC626E8842EBD7FB";
private enum inputConcatPin = "4538A0B393E57FA6EBEE19A7C40FC50E1F6D00FFAE80C8B2424645B8C8938B3C";
private enum scalarConcatPin = "078DEB0171237F42A344DBA9BBCA6124647F514EED7BD5D7AD6D2C68418826B7";
private enum mixedConcatPin = "870D401642B372263AED96C938DE8B2E1E1A466DDCEFA193085889435665A069";
private immutable string[string] inputTrees = [
    "many-small": "5B5D9E66435A5BC705152EB88C551046BE0AA37B51F4FA42A038683AAFB51167",
    "few-large": "A69113BEE8E66CE349C620BD122821F4D0719ABC2263A143E8AA0264CF030548"];
private immutable string[string] scalarTrees = [
    "many-small": "69CDDA2CC549BC8D25A47536A98C45AAA74211EC563DEC0B8E0943C1A1E43BF5",
    "few-large": "6013483B2883A00408833C17E0B5517213062D3DAA2AED3B1B4470D67CCD9FC0"];
private immutable string[string] mixedTrees = [
    "many-small": "3ED0A176AA89B8B9428FD3F937042EE45781C6FF3546069BB7CF92A4FA6D9529",
    "few-large": "9AAC92A1892B67FCADCAD16E98917446B8077ABB0F8B6826810E5767EACB6DDC"];

private void need(bool value, string message) {
    if (!value) throw new Exception(message);
}

private string hashBytes(const(ubyte)[] value) {
    return toHexString(sha256Of(value)).to!string;
}
private string hashFile(string path) { return hashBytes(cast(const(ubyte)[])read(path)); }
private bool digest(string value) {
    if (value.length != 64) return false;
    foreach (c; value) if (!((c >= '0' && c <= '9') ||
        (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) return false;
    return true;
}
private double number(JSONValue value) {
    need(value.type == JSONType.integer || value.type == JSONType.float_,
        "expected JSON number");
    return value.type == JSONType.integer ? cast(double)value.integer : value.floating;
}
private bool digestLength(string value, size_t length) {
    if (value.length != length) return false;
    foreach (c; value) if (!((c >= '0' && c <= '9') ||
        (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) return false;
    return true;
}
private string attestedBuildCommand() {
    return "git archive <source-sha> -> <private-source>; " ~
        "private read-only dub describe/build --root=<private-source> " ~
        "--build=release --compiler=<private-read-only-ldc2> " ~
        "--force --non-interactive --cache=local with private DUB_HOME";
}
private string nativeEnvironmentTemplate() {
    return "PATH=<private-pinned-tools>:/usr/bin:/bin:/usr/sbin:/sbin; " ~
        "CC=<attested-selected-clang>; AR=<attested-ar>; " ~
        "RANLIB=<attested-ranlib>; COMPILER_PATH=<private-pinned-tools>; " ~
        "SDKROOT=<xcrun-selected-sdk>";
}
private void digestPart(ref SHA256 value, string part) {
    value.put(cast(const(ubyte)[])part.length.to!string);
    value.put(cast(const(ubyte)[])":");
    value.put(cast(const(ubyte)[])part);
}
private string scratch() {
    auto path = buildPath(tempDir, "scrubbed-cli-attribution-" ~ randomUUID.toString);
    mkdirRecurse(path);
    need(execute(["chmod", "700", path]).status == 0, "private scratch chmod failed");
    return path;
}
private long checkedMultiply(long left, long right, string context) {
    need(left > 0 && right > 0 && left <= long.max / right,
        "unsafe capacity arithmetic: " ~ context);
    return left * right;
}
private JSONValue preflight(string root, long budget) {
    auto ramResult = execute(["sysctl", "-n", "hw.memsize"]);
    auto freeResult = execute(["df", "-Pk", root]);
    need(ramResult.status == 0 && freeResult.status == 0,
        "attribution capacity probe failed");
    auto lines = freeResult.output.splitLines;
    need(lines.length == 2 && lines[1].split.length >= 6,
        "unexpected attribution df output");
    auto free = checkedMultiply(lines[1].split[$ - 3].to!long, 1024,
        "scratch bytes");
    auto ram = ramResult.output.strip.to!long;
    auto derived = checkedMultiply(corpusBytes, 12, "derived fixture footprint");
    auto required = checkedMultiply(derived, 4, "four-times scratch headroom");
    need(ram >= minimumCapacity && free >= minimumCapacity && free >= required &&
        budget >= minimumBudget, "attribution capacity/budget preflight failed");
    return JSONValue(["physical_ram_bytes": JSONValue(ram),
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
    auto result = (text ~ cast(string)new char[](recordBytes - inputLength)).dup;
    foreach (ref c; result[text.length .. $]) c = 'x';
    return cast(string)result;
}
private string inputRecord(size_t i) {
    auto value = recordTable[i % $].input; return padded(value, value.length);
}
private string tableSerialization() {
    string result;
    foreach (item; recordTable) result ~= item.input.length.to!string ~ ":" ~ item.input ~
        item.scalar.length.to!string ~ ":" ~ item.scalar ~
        item.mixed.length.to!string ~ ":" ~ item.mixed;
    return result;
}
private string config(bool mixed) {
    auto filters = mixed ?
        `[{"name":"uncurl-quotes","options":{}},{"name":"fix-mojibake","options":{"max-passes":2}},{"name":"decode-html-entities","options":{}},{"name":"normalize-line-endings","options":{}},{"name":"strip-control","options":{}}]` :
        `[{"name":"normalize-line-endings","options":{}},{"name":"strip-control","options":{}}]`;
    return `{"version":3,"stages":[{"id":"legacy-text","implementation":"text-transform","options":{},"filters":` ~ filters ~ `}]}`;
}
private struct Layout { string name; size_t files, recordsPerFile; }
private immutable Layout[] layouts = [Layout("many-small", 4096, 128),
    Layout("few-large", 8, 65_536)];
private void makeFixture(string root, Layout layout) {
    mkdirRecurse(root); size_t record;
    foreach (i; 0 .. layout.files) {
        auto file = File(buildPath(root, "doc-" ~ i.to!string ~ ".txt"), "wb");
        foreach (_; 0 .. layout.recordsPerFile) file.rawWrite(inputRecord(record++));
    }
    need(record == recordCount, "frozen fixture record cardinality drift");
}
private struct TreeIdentity { long bytes; string tree, concatenated; }
private TreeIdentity identifyTree(string root) {
    string[] names;
    foreach (entry; dirEntries(root, SpanMode.depth, false)) {
        need(entry.isFile, "output contains non-file");
        names ~= relativePath(entry.name, root);
    }
    names.sort(); SHA256 tree, concat; long bytes;
    foreach (name; names) {
        auto body = cast(const(ubyte)[])read(buildPath(root, name));
        auto hash = hashBytes(body);
        digestPart(tree, name); digestPart(tree, body.length.to!string); digestPart(tree, hash);
        concat.put(body); bytes += body.length;
    }
    return TreeIdentity(bytes, toHexString(tree.finish()).to!string,
        toHexString(concat.finish()).to!string);
}
private void exactTree(string output, string layout, bool mixed) {
    auto actual = identifyTree(output);
    need(actual.bytes == (mixed ? mixedBytes : scalarBytes) &&
        actual.tree == (mixed ? mixedTrees[layout] : scalarTrees[layout]) &&
        actual.concatenated == (mixed ? mixedConcatPin : scalarConcatPin),
        "instrumented exact output gate failed");
}

private string canonicalExisting(string path) {
    import core.stdc.stdlib : free;
    import core.sys.posix.stdlib : realpath;
    import std.string : fromStringz, toStringz;
    auto value = realpath(path.toStringz, null);
    need(value !is null, "cannot canonicalize executable path");
    scope(exit) free(value);
    return fromStringz(value).idup;
}
private bool redactedSamplePathMatches(string sampled, string canonical) {
    need(sampled.split("*").length == 2,
        "sample path has an unexpected redaction shape");
    need(baseName(sampled) == baseName(canonical),
        "sample redacted path basename differs from launched binary");
    if (sampled.startsWith("/private/var/folders/*/"))
        return canonical.startsWith("/private/var/folders/") ||
            canonical.startsWith("/var/folders/");
    if (sampled.startsWith("/Users/USER/*/"))
        return canonical.startsWith("/Users/");
    return false;
}

private double seconds(ref const typeof(rusage.init.ru_utime) value) {
    return value.tv_sec + value.tv_usec / 1_000_000.0;
}

private struct SymbolCount { string symbol, image; long count; }
private bool parseCounted(string line, out long count, out string rest) {
    auto clean = line.strip;
    while (clean.length && (clean[0] == '+' || clean[0] == '!' ||
            clean[0] == '|' || clean[0] == ':'))
        clean = clean[1 .. $].strip;
    auto splitAt = clean.indexOf(' ');
    if (splitAt <= 0) return false;
    try count = clean[0 .. splitAt].to!long;
    catch (Exception) { return false; }
    rest = clean[splitAt .. $].strip;
    return count >= 0 && rest.length != 0;
}
private bool parseTrailingCount(string line, out long count, out string rest) {
    auto clean = line.strip;
    auto splitAt = clean.lastIndexOf(' ');
    if (splitAt <= 0) return false;
    rest = clean[0 .. splitAt].strip;
    try count = clean[splitAt .. $].strip.to!long;
    catch (Exception) { return false; }
    return count >= 0 && rest.length != 0;
}
private SymbolCount parseSymbol(long count, string rest, string targetName) {
    string image = "unresolved";
    auto marker = rest.indexOf("  (in ");
    if (marker < 0) marker = rest.indexOf(" (in ");
    string symbol = marker >= 0 ? rest[0 .. marker].strip : rest;
    if (marker >= 0) {
        auto start = rest.indexOf("(in ", marker);
        auto end = rest.indexOf(')', start);
        if (start >= 0 && end > start) image = rest[start + 4 .. end];
    }
    auto offset = symbol.lastIndexOf(" + ");
    if (offset >= 0) symbol = symbol[0 .. offset].strip;
    auto address = symbol.indexOf("  [");
    if (address >= 0) symbol = symbol[0 .. address].strip;
    if (!symbol.length) symbol = "???";
    if (symbol.canFind('/')) symbol = "<private-symbol>";
    if (image.canFind('/')) image = "<private-image>";
    if (image == targetName || image == "scrubbed-attested-snapshot") image = "<target>";
    return SymbolCount(symbol, image, count);
}
private string symbolKey(SymbolCount item) { return item.symbol ~ "\t" ~ item.image; }
private JSONValue topSymbols(SymbolCount[] values, long total) {
    long[string] counts;
    string[string] symbols, images;
    foreach (value; values) {
        auto key = symbolKey(value); counts[key] += value.count;
        symbols[key] = value.symbol; images[key] = value.image;
    }
    SymbolCount[] merged;
    foreach (key, count; counts) merged ~= SymbolCount(symbols[key], images[key], count);
    merged.sort!((a, b) => a.count > b.count ||
        (a.count == b.count && symbolKey(a) < symbolKey(b)));
    JSONValue[] rows;
    foreach (item; merged[0 .. (merged.length < 20 ? merged.length : 20)])
        rows ~= JSONValue(["symbol": JSONValue(item.symbol), "image": JSONValue(item.image),
            "count": JSONValue(item.count),
            "fraction": JSONValue(cast(double)item.count / total)]);
    return JSONValue(rows);
}
private string partition(SymbolCount item) {
    if (item.symbol == "???" || item.image == "unresolved") return "unresolved";
    auto lower = (item.symbol ~ " " ~ item.image).toLower;
    if (lower.canFind("libsystem_kernel") || lower.canFind("kernel")) return "kernel";
    if (lower.canFind("_d_") || lower.canFind("druntime") ||
        lower.canFind("core.thread") || lower.canFind("rt.")) return "runtime";
    if (item.image == "<target>") return "project";
    return "system";
}

private string sanitizedSampleDigest(JSONValue value) {
    auto payload = JSONValue([
        "accepted_stacks": value["accepted_stacks"],
        "inclusive_top": value["inclusive_top"],
        "leaf_top": value["leaf_top"],
        "dominant_leaf_component": value["dominant_leaf_component"],
        "sample_path_redacted": value["sample_path_redacted"],
        "path_binding_semantics": value["path_binding_semantics"],
        "partitions": value["partitions"]]);
    return hashBytes(cast(const(ubyte)[])payload.toString);
}

private JSONValue parseSample(string raw, long expectedPid, string binary) {
    auto lines = raw.splitLines;
    auto canonicalBinary = canonicalExisting(binary);
    bool analysisBound, processBound, pathBound, pathRedacted, inCallGraph, inLeaf;
    long accepted;
    SymbolCount[] inclusive, leaf;
    foreach (line; lines) {
        auto clean = line.strip;
        if (clean.startsWith("Analysis of sampling ") &&
            clean.canFind("(pid " ~ expectedPid.to!string ~ ")") &&
            clean.endsWith("every " ~ sampleInterval.to!string ~ " milliseconds"))
            analysisBound = true;
        if (clean.startsWith("Process:") && clean.canFind("[" ~ expectedPid.to!string ~ "]"))
            processBound = true;
        if (clean.startsWith("Path:")) {
            auto sampledPath = clean[5 .. $].strip;
            if (sampledPath.canFind('*')) {
                pathBound = redactedSamplePathMatches(sampledPath, canonicalBinary);
                pathRedacted = true;
            } else pathBound = canonicalExisting(sampledPath) == canonicalBinary;
        }
        if (clean == "Call graph:") { inCallGraph = true; inLeaf = false; continue; }
        if (clean.startsWith("Total number in stack")) { inCallGraph = false; continue; }
        if (clean.startsWith("Sort by top of stack")) { inLeaf = true; continue; }
        if (clean == "Binary Images:") { inLeaf = false; continue; }
        long count; string rest;
        if (inCallGraph) {
            if (!parseCounted(line, count, rest)) continue;
            if (rest.startsWith("Thread_")) accepted += count;
            else inclusive ~= parseSymbol(count, rest, baseName(canonicalBinary));
        } else if (inLeaf && parseTrailingCount(line, count, rest))
            leaf ~= parseSymbol(count, rest, baseName(canonicalBinary));
    }
    need(analysisBound && processBound && pathBound,
        "sample PID/binary/settings binding failed");
    need(accepted >= minimumStacks, "sample contained fewer than 100 accepted stacks");
    long accounted;
    long[string] partitions = ["kernel": 0L, "system": 0L,
        "runtime": 0L, "project": 0L, "unresolved": 0L];
    foreach (item; leaf) { partitions[partition(item)] += item.count; accounted += item.count; }
    need(accounted <= accepted, "sample leaf accounting exceeds accepted stacks");
    partitions["unresolved"] += accepted - accounted;
    JSONValue partitionJson = JSONValue();
    string dominant; long dominantCount = -1;
    foreach (name; ["kernel", "system", "runtime", "project", "unresolved"]) {
        auto count = partitions[name];
        partitionJson[name] = JSONValue(["count": JSONValue(count),
            "fraction": JSONValue(cast(double)count / accepted)]);
        if (count > dominantCount) { dominant = name; dominantCount = count; }
    }
    auto inclusiveTop = topSymbols(inclusive, accepted);
    auto leafTop = topSymbols(leaf, accepted);
    auto component = leafTop.array.length ?
        leafTop[0]["symbol"].str ~ " (" ~ leafTop[0]["image"].str ~ ")" : "unresolved";
    auto sanitized = JSONValue(["accepted_stacks": JSONValue(accepted),
        "inclusive_top": inclusiveTop, "leaf_top": leafTop,
        "dominant_leaf_component": JSONValue(component), "partitions": partitionJson]);
    sanitized["sample_path_redacted"] = pathRedacted;
    sanitized["path_binding_semantics"] = pathRedacted ?
        "Darwin sample privacy-redacted root/basename plus exact direct-child PID and launched binary hash" :
        "canonical sampled path plus exact direct-child PID and launched binary hash";
    auto serialized = sanitized.toString;
    foreach (token; ["/Users/", "/private/var/", "/tmp/"])
        need(!serialized.canFind(token), "sanitized sample leaks a private path");
    sanitized["sanitized_sha256"] = sanitizedSampleDigest(sanitized);
    sanitized["dominant_partition"] = dominant;
    sanitized["pid_binary_bound"] = true;
    return sanitized;
}

private JSONValue timeProfilerFallback(string[] command, string binary,
        string output, string layout, bool mixed, string root) {
    auto xctraceVersion = execute(["xcrun", "xctrace", "version"]);
    if (xctraceVersion.status != 0) return JSONValue(["status": JSONValue("UNSUPPORTED"),
        "reason": JSONValue("xctrace Time Profiler unavailable noninteractively")]);
    bool durable;
    foreach (arg; command) durable = durable || arg == "--manifest" || arg == "--error-journal";
    if (!durable && exists(output)) rmdirRecurse(output);
    auto log = File(buildPath(root, "xctrace-child-" ~ randomUUID.toString ~ ".log"), "wb");
    auto child = spawnProcess(command, File("/dev/null", "rb"), log, log,
        null, Config.none);
    auto trace = buildPath(root, "time-profiler-" ~ randomUUID.toString ~ ".trace");
    auto captured = execute(["xcrun", "xctrace", "record", "--template",
        "Time Profiler", "--attach", child.processID.to!string, "--time-limit",
        "2s", "--output", trace, "--no-prompt"]);
    auto status = wait(child); log.close();
    need(status == 0, "Time Profiler fallback child failed");
    exactTree(output, layout, mixed);
    return JSONValue(["status": JSONValue("UNSUPPORTED"),
        "reason": JSONValue(captured.status == 0 ?
            "xctrace exact-PID capture succeeded but no stable noninteractive named-stack export parser is accepted" :
            "xctrace exact-PID noninteractive Time Profiler capture failed"),
        "capture_exit_code": JSONValue(cast(long)captured.status)]);
}

private JSONValue traceRun(string[] command, string binary, string binaryHash,
        string sourceSha, string sourceTree, string attestationHash,
        string input, string output, string layout, bool mixed, string root, long repetition,
        string workload, long threads, string route) {
    auto childLogPath = buildPath(root, "trace-child-" ~ randomUUID.toString ~ ".log");
    auto childLog = File(childLogPath, "wb");
    auto nullIn = File("/dev/null", "rb");
    StopWatch clock; clock.start();
    auto child = spawnProcess(command, nullIn, childLog, childLog, null, Config.none);
    auto pid = child.processID;
    auto rawPath = buildPath(root, "sample-" ~ randomUUID.toString ~ ".txt");
    auto sampled = execute(["/usr/bin/sample", pid.to!string,
        sampleDuration.to!string, sampleInterval.to!string, "-file", rawPath]);
    int waitStatus;
    rusage usage;
    need(wait4(pid, &waitStatus, 0, &usage) == pid,
        "cannot collect instrumented child diagnostics");
    clock.stop(); childLog.close();
    auto exited = WIFEXITED(waitStatus);
    auto childStatus = exited ? WEXITSTATUS(waitStatus) : -1;
    auto childSignal = WIFSIGNALED(waitStatus) ? WTERMSIG(waitStatus) : 0;
    need(childStatus == 0 && childSignal == 0 && exists(output),
        "instrumented child failed");
    exactTree(output, layout, mixed);
    auto logText = readText(childLogPath);
    JSONValue durableStatuses;
    if (route.length) {
        auto files = layout == "many-small" ? 4096 : 8;
        durableStatuses = explainStatuses(logText, input, files, "skipped",
            route == "journal-v3");
    }
    JSONValue parsed;
    string failure;
    try {
        need(sampled.status == 0 && exists(rawPath), "/usr/bin/sample command failed");
        parsed = parseSample(readText(rawPath), pid, binary);
    } catch (Exception error) failure = error.msg;
    JSONValue result = JSONValue(["repetition": JSONValue(repetition),
        "layout": JSONValue(layout), "workload": JSONValue(workload),
        "threads": JSONValue(threads), "max_open_inputs": JSONValue(threads),
        "route": JSONValue(route.length ? route : "ordinary"),
        "config_sha256": JSONValue(mixed ? mixedConfigPin : scalarConfigPin),
        "fixture_table_sha256": JSONValue(fixtureTablePin),
        "sampled_pid": JSONValue(cast(long)pid),
        "target_binary_sha256": JSONValue(binaryHash),
        "source_sha": JSONValue(sourceSha), "source_tree_id": JSONValue(sourceTree),
        "build_attestation_sha256": JSONValue(attestationHash),
        "process_exit_code": JSONValue(cast(long)childStatus),
        "process_signal": JSONValue(cast(long)childSignal),
        "exact_output": JSONValue(true),
        "output_tree_sha256": JSONValue(mixed ? mixedTrees[layout] : scalarTrees[layout]),
        "output_concatenated_sha256": JSONValue(mixed ? mixedConcatPin : scalarConcatPin),
        "output_bytes": JSONValue(mixed ? mixedBytes : scalarBytes),
        "status_gate": JSONValue(route.length ? "all-skipped" : "ordinary-complete"),
        "tool": JSONValue("/usr/bin/sample"),
        "duration_seconds": JSONValue(sampleDuration),
        "interval_milliseconds": JSONValue(sampleInterval),
        "instrumented_wall_seconds": JSONValue(clock.peek.total!"nsecs" / 1_000_000_000.0),
        "instrumented_user_seconds": JSONValue(seconds(usage.ru_utime)),
        "instrumented_system_seconds": JSONValue(seconds(usage.ru_stime)),
        "instrumented_peak_rss_bytes": JSONValue(cast(long)usage.ru_opaque[0]),
        "diagnostic_metrics_semantics": JSONValue(
            "direct-child wait4 diagnostics; excluded from frozen canonical timings"),
        "child_log_sha256": JSONValue(hashFile(childLogPath))]);
    if (route.length) result["durable_statuses"] = durableStatuses;
    if (failure.length) {
        result["status"] = "UNSUPPORTED";
        result["reason"] = failure;
        result["time_profiler_fallback"] = timeProfilerFallback(command, binary,
            output, layout, mixed, root);
    } else {
        result["status"] = "SUPPORTED";
        result["sample"] = parsed;
        result["raw_private_sha256"] = hashFile(rawPath);
    }
    return result;
}

private long singleLong(string line, string prefix, string suffix) {
    need(line.startsWith(prefix) && line.endsWith(suffix), "wrong-format GC field");
    auto body = line[prefix.length .. $ - suffix.length].strip;
    need(body.length && body[0] != '-', "negative GC field");
    try return body.to!long;
    catch (Exception) { throw new Exception("overflowed or invalid GC field"); }
}
private JSONValue parseGc(string raw) {
    long collections = -1, allocatedMiB = -1, collectionMs = -1;
    long summaryCollections = -1, summaryMs = -1;
    size_t collectionFields, summaryFields, timeFields;
    string[] sanitized;
    foreach (line; raw.splitLines) {
        auto clean = line.strip;
        if (clean.startsWith("Number of collections:")) {
            ++collectionFields;
            collections = singleLong(clean, "Number of collections:", "");
            sanitized ~= "Number of collections:" ~ collections.to!string;
        } else if (clean.startsWith("Grand total GC time:")) {
            ++timeFields;
            collectionMs = singleLong(clean, "Grand total GC time:", " milliseconds");
            sanitized ~= "Grand total GC time:" ~ collectionMs.to!string ~ "ms";
        } else if (clean.startsWith("GC summary:")) {
            ++summaryFields;
            auto fields = clean.split;
            need(fields.length >= 8 && fields[0] == "GC" && fields[1] == "summary:" &&
                fields[3] == "MB," && fields[5] == "GC" && fields[7] == "ms,",
                "wrong-format GC summary");
            allocatedMiB = fields[2].to!long;
            summaryCollections = fields[4].to!long;
            summaryMs = fields[6].to!long;
            need(allocatedMiB >= 0 && allocatedMiB <= long.max / (1024 * 1024),
                "negative or overflowed GC allocation summary");
            sanitized ~= "GC summary:" ~ allocatedMiB.to!string ~ "MiB";
        }
    }
    need(collectionFields == 1 && summaryFields == 1 && timeFields == 1,
        "truncated or duplicate GC summary");
    need(collections == summaryCollections && collectionMs == summaryMs,
        "inconsistent GC summary totals");
    auto sanitizedText = sanitized.join("\n");
    return JSONValue(["status": JSONValue("SUPPORTED"),
        "semantics": JSONValue("D runtime GC-only; excludes native and total-process allocations"),
        "collection_count": JSONValue(collections),
        "allocated_bytes": JSONValue(allocatedMiB * 1024 * 1024),
        "allocated_bytes_semantics": JSONValue(
            "druntime whole-MB summary converted with 1048576 bytes per MiB"),
        "collection_time_milliseconds": JSONValue(collectionMs),
        "pool_size": JSONValue(["status": JSONValue("UNSUPPORTED"),
            "reason": JSONValue("druntime profile summary exposes no pool size")]),
        "heap_size": JSONValue(["status": JSONValue("UNSUPPORTED"),
            "reason": JSONValue("druntime profile summary exposes no heap size")]),
        "sanitized_sha256": JSONValue(hashBytes(cast(const(ubyte)[])sanitizedText))]);
}

private JSONValue gcRun(string[] command, string binaryHash, string sourceSha,
        string sourceTree, string attestationHash, string output,
        string layout, bool mixed, long repetition) {
    auto result = execute(command);
    need(result.status == 0 && exists(output), "D-GC instrumented child failed");
    exactTree(output, layout, mixed);
    auto parsed = parseGc(result.output);
    parsed["repetition"] = repetition;
    parsed["layout"] = layout;
    parsed["workload"] = mixed ? "mixed" : "scalar";
    parsed["threads"] = 1L;
    parsed["max_open_inputs"] = 1L;
    parsed["target_binary_sha256"] = binaryHash;
    parsed["source_sha"] = sourceSha;
    parsed["source_tree_id"] = sourceTree;
    parsed["build_attestation_sha256"] = attestationHash;
    parsed["config_sha256"] = mixed ? mixedConfigPin : scalarConfigPin;
    parsed["fixture_table_sha256"] = fixtureTablePin;
    parsed["output_tree_sha256"] = mixed ? mixedTrees[layout] : scalarTrees[layout];
    parsed["output_concatenated_sha256"] = mixed ? mixedConcatPin : scalarConcatPin;
    parsed["output_bytes"] = mixed ? mixedBytes : scalarBytes;
    parsed["exact_output"] = true;
    parsed["raw_private_sha256"] = hashBytes(cast(const(ubyte)[])result.output);
    return parsed;
}

private void validateAttestation(JSONValue value, string binaryHash) {
    need(value["schema"].str == "scrubbed-build-attestation-v4",
        "build attestation schema");
    foreach (key; ["source_sha", "source_tree_id", "source_archive_sha256",
            "dub_recipe_sha256", "dependency_lock_sha256",
            "compiler_executable_sha256", "dub_executable_sha256",
            "argparse_recipe_sha256", "argparse_inputs_sha256",
            "native_prebuild_commands_sha256", "target_sha256"])
        need(digestLength(value[key].str,
            key == "source_sha" || key == "source_tree_id" ? 40 : 64),
            "invalid attestation digest " ~ key);
    need(value["source_status"].str == "clean-before-and-after" &&
        value["source_materialization"].str ==
            "hashed Git archive extracted into private scratch" &&
        value["compiler_executable_name"].str == "ldc2" &&
        value["compiler_version"].str.length &&
        !value["compiler_version"].str.canFind('/') &&
        !value["compiler_version"].str.canFind('\\') &&
        value["dub_version"].str.startsWith("DUB version 1.42.0,") &&
        !value["dub_version"].str.canFind('/') &&
        !value["dub_version"].str.canFind('\\') &&
        value["primary_tool_policy"].str ==
            "private read-only LDC/DUB snapshots invoked and hash-verified after build" &&
        value["dependency_cache_policy"].str ==
            "private DUB_HOME and --cache=local under private source" &&
        value["argparse_name"].str == "argparse" &&
        value["argparse_version"].str == "2.0.2" &&
        value["argparse_input_files"].integer > 1 &&
        value["native_prebuild_command_count"].integer == 5 &&
        value["native_environment_template"].str == nativeEnvironmentTemplate() &&
        value["sdk_version"].str.length && value["sdk_build_version"].str.length &&
        !value["sdk_version"].str.canFind('/') &&
        !value["sdk_build_version"].str.canFind('/') &&
        value["native_tool_policy"].str ==
            "exact executables hashed and verified before and after; per-executable version or UNAVAILABLE; separately bound archive-suite evidence; private pinned PATH; CMake selections verified" &&
        value["linker_selection"].str ==
            "COMPILER_PATH private ld selected by attested compiler -### trace" &&
        value["target_relative_path"].str == "scrubbed" &&
        value["target_discovery"].str ==
            "DUB 1.42.0 describe root targetPath plus targetFileName" &&
        value["build_command_template"].str == attestedBuildCommand() &&
        value["build_flags"].str == "release; force; non-interactive; cache=local" &&
        value["build_status"].integer == 0 &&
        value["target_sha256"].str == binaryHash,
        "inconsistent build attestation");
    auto names = ["cc-driver", "cc-compiler", "ar-driver", "ar-writer",
        "ranlib-driver", "ranlib-writer", "linker", "cmake", "make"];
    auto roles = ["ambient cc command selector",
        "selected C compiler for SQLite, Lexbor, and zstd",
        "ambient ar command selector", "selected static archive writer",
        "ambient ranlib command selector", "selected static archive index writer",
        "selected final executable linker", "Lexbor build generator",
        "Lexbor and zstd build executor"];
    need(value["native_tools"].array.length == names.length,
        "native build tool closure is incomplete");
    foreach (index, tool; value["native_tools"].array)
        need(tool["name"].str == names[index] && tool["role"].str == roles[index] &&
            digest(tool["sha256"].str) && tool["version"].str.length &&
            (index == 0 || index == 2 || index == 3 || index == 4 ?
                tool["version"].str == unavailableToolVersion :
                tool["version"].str != unavailableToolVersion) &&
            !tool["version"].str.canFind('/') && !tool["version"].str.canFind('\\'),
            "invalid native build tool attestation");
    auto archive = value["archive_suite_evidence"];
    need(archive["schema"].str == "scrubbed-archive-suite-evidence-v1" &&
        archive["evidence_tool_name"].str == "ranlib-writer" &&
        archive["evidence_tool_sha256"].str ==
            value["native_tools"][5]["sha256"].str &&
        archive["evidence_arguments"].array.length == 1 &&
        archive["evidence_arguments"][0].str == "-V" &&
        archive["version"].str == value["native_tools"][5]["version"].str &&
        archive["version"].str != unavailableToolVersion,
        "archive suite evidence is not bound to exact evidence tool");
}
private void validateCanonical(JSONValue value) {
    need(value["schema"].str == "scrubbed-cli-profile-v1" &&
        value["binary_sha256"].str == canonicalProfileBinaryPin &&
        value["build_attestation"]["source_sha"].str == canonicalProfileSourcePin &&
        value["fixture_table_sha256"].str == fixtureTablePin &&
        value["fixture_record_bytes"].integer == recordBytes &&
        value["fixture_record_count"].integer == recordCount &&
        value["config_sha256"]["scalar_v3_sha256"].str == scalarConfigPin &&
        value["config_sha256"]["mixed_v3_sha256"].str == mixedConfigPin &&
        value["layouts"].array.length == 2,
        "canonical profile binding drift");
    foreach (i, layout; value["layouts"].array) {
        auto name = layouts[i].name;
        need(layout["name"].str == name && layout["input_bytes"].integer == corpusBytes &&
            layout["input_tree_sha256"].str == inputTrees[name] &&
            layout["input_concatenated_sha256"].str == inputConcatPin &&
            layout["scalar_expected_tree_sha256"].str == scalarTrees[name] &&
            layout["scalar_expected_concatenated_sha256"].str == scalarConcatPin &&
            layout["mixed_expected_tree_sha256"].str == mixedTrees[name] &&
            layout["mixed_expected_concatenated_sha256"].str == mixedConcatPin,
            "canonical layout/material identity drift");
    }
}

private JSONValue rangeSummary(double[] values) {
    need(values.length == repetitions, "summary repetition cardinality differs");
    values.sort();
    return JSONValue(["minimum": JSONValue(values[0]),
        "median": JSONValue(values[1]), "maximum": JSONValue(values[2])]);
}
private JSONValue summarizeGc(JSONValue[] values) {
    need(values.length == repetitions, "GC repetition cardinality differs");
    double[] collections, allocated, time;
    foreach (i, item; values) {
        need(item["repetition"].integer == i, "GC repetition order differs");
        collections ~= cast(double)item["collection_count"].integer;
        allocated ~= cast(double)item["allocated_bytes"].integer;
        time ~= cast(double)item["collection_time_milliseconds"].integer;
    }
    return JSONValue(["collection_count": rangeSummary(collections),
        "allocated_bytes": rangeSummary(allocated),
        "collection_time_milliseconds": rangeSummary(time),
        "semantics": JSONValue(
            "D runtime GC-only; excludes native and total-process allocations")]);
}
private JSONValue summarizeTraces(JSONValue[] traces) {
    need(traces.length == repetitions, "trace repetition cardinality differs");
    double[] counts, walls, users, systems, rss;
    double[][string] partitionCounts, partitionFractions;
    string component;
    bool supported = true, stable = true;
    foreach (i, trace; traces) {
        need(trace["repetition"].integer == i, "trace repetition order differs");
        supported = supported && trace["status"].str == "SUPPORTED";
        walls ~= number(trace["instrumented_wall_seconds"]);
        users ~= number(trace["instrumented_user_seconds"]);
        systems ~= number(trace["instrumented_system_seconds"]);
        rss ~= cast(double)trace["instrumented_peak_rss_bytes"].integer;
        if (trace["status"].str == "SUPPORTED") {
            counts ~= cast(double)trace["sample"]["accepted_stacks"].integer;
            foreach (name; ["kernel", "system", "runtime", "project", "unresolved"]) {
                auto part = trace["sample"]["partitions"][name];
                partitionCounts[name] ~= cast(double)part["count"].integer;
                partitionFractions[name] ~= number(part["fraction"]);
            }
            auto current = trace["sample"]["dominant_leaf_component"].str;
            if (!component.length) component = current;
            else stable = stable && current == component;
        }
    }
    auto diagnostics = JSONValue([
        "instrumented_wall_seconds": rangeSummary(walls),
        "instrumented_user_seconds": rangeSummary(users),
        "instrumented_system_seconds": rangeSummary(systems),
        "instrumented_peak_rss_bytes": rangeSummary(rss)]);
    if (!supported) return JSONValue(["status": JSONValue("UNSUPPORTED"),
        "reason": JSONValue("one or more exact-PID repetitions lacked accepted named stacks"),
        "diagnostics": diagnostics]);
    JSONValue partitionSummary = JSONValue();
    foreach (name; ["kernel", "system", "runtime", "project", "unresolved"])
        partitionSummary[name] = JSONValue([
            "count": rangeSummary(partitionCounts[name]),
            "fraction": rangeSummary(partitionFractions[name])]);
    return JSONValue(["status": JSONValue("SUPPORTED"),
        "accepted_stacks": rangeSummary(counts),
        "diagnostics": diagnostics,
        "partition_ranges": partitionSummary,
        "stable_named_component": JSONValue(stable && component != "unresolved"),
        "component": JSONValue(component)]);
}

private string[] ordinaryCommand(string binary, string input, string output,
        string configPath, long threads) {
    return [binary, "--input", input, "--output", output, "--config", configPath,
        "--threads", threads.to!string, "--max-open-inputs", threads.to!string];
}
private string[] durableCommand(string binary, string input, string output,
        string configPath, string database, bool journal) {
    return ordinaryCommand(binary, input, output, configPath, 4) ~
        (journal ? ["--error-journal", database, "--explain"] :
            ["--manifest", database, "--explain"]);
}
private void identityField(ref SHA256 value, string field) {
    need(field.length <= uint.max, "identity field too long");
    auto length = cast(uint)field.length;
    foreach_reverse (shift; [0, 8, 16, 24])
        value.put(cast(ubyte)(length >> shift));
    value.put(cast(const(ubyte)[])field);
}
private string localDocumentId(string inputRoot, string filename) {
    auto canonicalRoot = canonicalExisting(inputRoot);
    SHA256 value;
    value.put(cast(const(ubyte)[])"scrubbed:document-id:v1\0");
    identityField(value, "local-files:v1");
    identityField(value, canonicalRoot);
    identityField(value, filename);
    return "doc:v1:" ~ toHexString(value.finish()).to!string.toLower;
}
private JSONValue explainStatuses(string output, string inputRoot, size_t files,
        string expectedStatus, bool journal) {
    string[string] byFile;
    string[string] filenameByDocument;
    if (journal) foreach (i; 0 .. files) {
        auto filename = "doc-" ~ i.to!string ~ ".txt";
        filenameByDocument[localDocumentId(inputRoot, filename)] = filename;
    }
    foreach (line; output.splitLines) {
        if (!line.startsWith("EXPLAIN\t")) continue;
        auto fields = line.split("\t");
        need(fields.length >= 3, "malformed EXPLAIN record");
        string filename;
        if (journal) {
            string document;
            foreach (field; fields) if (field.startsWith("document_id="))
                document = field[12 .. $];
            if (auto mapped = document in filenameByDocument) filename = *mapped;
        } else foreach (i; 0 .. files) {
            auto candidate = "doc-" ~ i.to!string ~ ".txt";
            if (fields[1].endsWith(candidate ~ "\"")) {
                need(filename.length == 0, "ambiguous EXPLAIN input");
                filename = candidate;
            }
        }
        need(filename.length && (filename in byFile) is null,
            "unknown or duplicate EXPLAIN input");
        string status;
        foreach (field; fields) if (field.startsWith("status=")) {
            need(!status.length, "duplicate EXPLAIN status");
            status = field[7 .. $];
        }
        need(status == expectedStatus, "unexpected EXPLAIN status");
        byFile[filename] = status;
    }
    need(byFile.length == files, "missing EXPLAIN input status");
    SHA256 statusDigest;
    foreach (i; 0 .. files) {
        auto filename = "doc-" ~ i.to!string ~ ".txt";
        need((filename in byFile) !is null, "missing keyed EXPLAIN input");
        digestPart(statusDigest, filename);
        digestPart(statusDigest, byFile[filename]);
    }
    return JSONValue(["file_count": JSONValue(cast(long)files),
        "expected_status": JSONValue(expectedStatus),
        "status_by_file_sha256": JSONValue(
            toHexString(statusDigest.finish()).to!string)]);
}
private void prepareDurable(string[] command, string binary, string database,
        bool journal, string output, string layout) {
    if (journal) need(execute([binary, "errors-init", "--journal", database]).status == 0,
        "journal-v3 preparation failed");
    auto first = execute(command);
    auto files = layout == "many-small" ? 4096 : 8;
    need(first.status == 0, "durable first-publication process failed");
    explainStatuses(first.output, command[2], files, "changed", journal);
    exactTree(output, layout, true);
}

private JSONValue runAttribution(string binary, JSONValue attestation,
        string canonicalPath, string harnessPath, string root, long budget) {
    auto binaryHash = hashFile(binary), harnessHash = hashFile(harnessPath);
    auto attestationHash = hashBytes(cast(const(ubyte)[])attestation.toString);
    validateAttestation(attestation, binaryHash);
    auto canonical = parseJSON(readText(canonicalPath));
    need(hashFile(canonicalPath) == canonicalProfilePin,
        "canonical profile artifact hash drift");
    validateCanonical(canonical);
    auto compilerPath = execute(["which", "ldc2"]);
    auto compilerVersion = execute(["ldc2", "--version"]);
    need(compilerPath.status == 0 && compilerVersion.status == 0 &&
        hashFile(compilerPath.output.strip) ==
            attestation["compiler_executable_sha256"].str &&
        compilerVersion.output.splitLines.length &&
        compilerVersion.output.splitLines[0] == attestation["compiler_version"].str,
        "documented attribution checker compiler closure differs from attestation");
    auto capacity = preflight(root, budget);
    need(hashBytes(cast(const(ubyte)[])tableSerialization()) == fixtureTablePin &&
        hashBytes(cast(const(ubyte)[])config(false)) == scalarConfigPin &&
        hashBytes(cast(const(ubyte)[])config(true)) == mixedConfigPin,
        "frozen fixture/config generator drift");
    auto scalarConfig = buildPath(root, "scalar-v3.json");
    auto mixedConfig = buildPath(root, "mixed-v3.json");
    write(scalarConfig, config(false)); write(mixedConfig, config(true));

    JSONValue[] layoutReports;
    bool allSupported = true, allStable = true;
    foreach (layout; layouts) {
        auto input = buildPath(root, "input-" ~ layout.name);
        makeFixture(input, layout);
        auto inputIdentity = identifyTree(input);
        need(inputIdentity.bytes == corpusBytes && inputIdentity.tree == inputTrees[layout.name] &&
            inputIdentity.concatenated == inputConcatPin, "frozen input identity drift");
        JSONValue[][string] traceCases;
        JSONValue[] gcScalar, gcMixed;
        foreach (rep; 0 .. repetitions) {
            foreach (kind; 0 .. 5) {
                string name, output, route; bool mixed; long threads;
                string[] command;
                if (kind == 0) { name = "scalar-threads1"; mixed = false; threads = 1; }
                else if (kind == 1) { name = "mixed-threads1"; mixed = true; threads = 1; }
                else if (kind == 2) { name = "mixed-threads4"; mixed = true; threads = 4; }
                else { name = kind == 3 ? "manifest-verified-skip" : "journal-verified-skip";
                    mixed = true; threads = 4; route = kind == 3 ? "manifest-v2" : "journal-v3"; }
                output = buildPath(root, layout.name ~ "-" ~ name ~ "-" ~ rep.to!string);
                if (kind < 3) command = ordinaryCommand(binary, input, output,
                    mixed ? mixedConfig : scalarConfig, threads);
                else {
                    auto database = output ~ (kind == 3 ? ".manifest.db" : ".journal.db");
                    command = durableCommand(binary, input, output, mixedConfig, database, kind == 4);
                    prepareDurable(command, binary, database, kind == 4, output, layout.name);
                }
                traceCases[name] ~= traceRun(command, binary, binaryHash,
                    attestation["source_sha"].str, attestation["source_tree_id"].str,
                    attestationHash, input, output,
                    layout.name, mixed, root, rep, mixed ? "mixed" : "scalar", threads, route);
                if (exists(output)) rmdirRecurse(output);
            }
            foreach (mixed; [false, true]) {
                auto output = buildPath(root, layout.name ~ "-gc-" ~
                    (mixed ? "mixed-" : "scalar-") ~ rep.to!string);
                auto command = ordinaryCommand(binary, input, output,
                    mixed ? mixedConfig : scalarConfig, 1);
                command = [binary, "--DRT-gcopt=profile:1"] ~ command[1 .. $];
                auto evidence = gcRun(command, binaryHash, attestation["source_sha"].str,
                    attestation["source_tree_id"].str, attestationHash,
                    output, layout.name, mixed, rep);
                if (mixed) gcMixed ~= evidence; else gcScalar ~= evidence;
                rmdirRecurse(output);
            }
        }
        JSONValue[] cases;
        foreach (name; ["scalar-threads1", "mixed-threads1", "mixed-threads4",
                "manifest-verified-skip", "journal-verified-skip"]) {
            auto summary = summarizeTraces(traceCases[name]);
            allSupported = allSupported && summary["status"].str == "SUPPORTED";
            if (summary["status"].str == "SUPPORTED")
                allStable = allStable && summary["stable_named_component"].boolean;
            cases ~= JSONValue(["name": JSONValue(name),
                "traces": JSONValue(traceCases[name]), "summary": summary]);
        }
        layoutReports ~= JSONValue(["name": JSONValue(layout.name),
            "files": JSONValue(cast(long)layout.files),
            "input_bytes": JSONValue(corpusBytes),
            "input_tree_sha256": JSONValue(inputTrees[layout.name]),
            "input_concatenated_sha256": JSONValue(inputConcatPin),
            "trace_cases": JSONValue(cases),
            "gc_profiles": JSONValue(["scalar_threads1": JSONValue(gcScalar),
                "mixed_threads1": JSONValue(gcMixed)]),
            "gc_summaries": JSONValue([
                "scalar_threads1": summarizeGc(gcScalar),
                "mixed_threads1": summarizeGc(gcMixed)])]);
        rmdirRecurse(input);
    }
    auto decision = !allSupported ? "UNAVAILABLE_ATTRIBUTION" :
        (allStable ? "STABLE_NAMED_HOTSPOT" : "DISTRIBUTED_COST");
    auto report = JSONValue(["schema": JSONValue(schema),
        "source_binary_mapping": JSONValue("ATTESTED"),
        "decision": JSONValue(decision),
        "optimization_authorized": JSONValue(false),
        "binary_sha256": JSONValue(binaryHash), "harness_sha256": JSONValue(harnessHash),
        "canonical_profile_sha256": JSONValue(canonicalProfilePin),
        "canonical_profile_binary_sha256": JSONValue(canonicalProfileBinaryPin),
        "canonical_profile_schema": JSONValue("scrubbed-cli-profile-v1"),
        "source_ancestry": JSONValue([
            "canonical_profile_source_sha": JSONValue(canonicalProfileSourcePin),
            "historical_merge_base_sha": JSONValue(historicalMergeBasePin),
            "accepted_attribution_base_sha": JSONValue(acceptedBasePin),
            "attribution_source_sha": attestation["source_sha"],
            "relationship": JSONValue(
                "historical issue-branch profile source and attribution line share the pinned merge base; accepted attribution base is an ancestor of attribution source"),
            "intervening_production_commits": JSONValue([
                JSONValue("7b0f164 bounded extraction detection contracts"),
                JSONValue("fc61fdf bounded ZIP container inspection")])]),
        "harness_executable_name": JSONValue(harnessName),
        "harness_build_recipe": JSONValue(harnessBuildRecipe),
        "harness_compiler_executable_sha256":
            attestation["compiler_executable_sha256"],
        "harness_compiler_version": attestation["compiler_version"],
        "preflight": capacity,
        "build_attestation": attestation,
        "build_attestation_sha256": JSONValue(attestationHash),
        "frozen_materials": JSONValue(["fixture_table_sha256": JSONValue(fixtureTablePin),
            "record_bytes": JSONValue(recordBytes), "record_count": JSONValue(recordCount),
            "scalar_config_sha256": JSONValue(scalarConfigPin),
            "mixed_config_sha256": JSONValue(mixedConfigPin),
            "input_concatenated_sha256": JSONValue(inputConcatPin),
            "scalar_concatenated_sha256": JSONValue(scalarConcatPin),
            "mixed_concatenated_sha256": JSONValue(mixedConcatPin)]),
        "tool": JSONValue(["name": JSONValue("/usr/bin/sample"),
            "executable_sha256": JSONValue(hashFile("/usr/bin/sample")),
            "darwin_product_version": JSONValue(
                execute(["sw_vers", "-productVersion"]).output.strip),
            "duration_seconds": JSONValue(sampleDuration),
            "interval_milliseconds": JSONValue(sampleInterval),
            "minimum_accepted_stacks": JSONValue(minimumStacks),
            "semantics": JSONValue("sampled stacks, not exact calls")]),
        "layouts": JSONValue(layoutReports),
        "nonclaims": JSONValue([JSONValue("no speedup or tuning claim"),
            JSONValue("no exact-call claim"), JSONValue("no native-allocation claim"),
            JSONValue("no direct timing comparison across source revisions"),
            JSONValue("no cross-platform or greater-than-RAM claim")])]);
    validateReport(report, harnessHash);
    return report;
}

private void noLeak(string value) {
    foreach (token; ["/Users/", "Users\\/", "/private/var/", "private\\/var",
            "/tmp/", "tmp\\/"])
        need(!value.canFind(token), "attribution report leaks a private path");
}
private string expectedStatusDigest(size_t files, string status) {
    SHA256 value;
    foreach (i; 0 .. files) {
        digestPart(value, "doc-" ~ i.to!string ~ ".txt");
        digestPart(value, status);
    }
    return toHexString(value.finish()).to!string;
}
private void validateTrace(JSONValue trace, string binaryHash, string layout,
        string caseName, long repetition, string sourceSha = "",
        string sourceTree = "", string attestationHash = "") {
    auto mixed = caseName != "scalar-threads1";
    auto expectedThreads = caseName == "scalar-threads1" ||
        caseName == "mixed-threads1" ? 1L : 4L;
    auto expectedRoute = caseName == "manifest-verified-skip" ? "manifest-v2" :
        (caseName == "journal-verified-skip" ? "journal-v3" : "ordinary");
    auto expectedWorkload = caseName == "scalar-threads1" ? "scalar" : "mixed";
    need(trace["repetition"].integer == repetition && trace["layout"].str == layout &&
        trace["workload"].str == expectedWorkload &&
        trace["threads"].integer == expectedThreads &&
        trace["max_open_inputs"].integer == expectedThreads &&
        trace["route"].str == expectedRoute && trace["sampled_pid"].integer > 0 &&
        trace["config_sha256"].str == (mixed ? mixedConfigPin : scalarConfigPin) &&
        trace["fixture_table_sha256"].str == fixtureTablePin &&
        trace["target_binary_sha256"].str == binaryHash &&
        (!sourceSha.length || (trace["source_sha"].str == sourceSha &&
            trace["source_tree_id"].str == sourceTree &&
            trace["build_attestation_sha256"].str == attestationHash)) &&
        trace["process_exit_code"].integer == 0 && trace["process_signal"].integer == 0 &&
        trace["exact_output"].boolean &&
        trace["output_tree_sha256"].str == (mixed ? mixedTrees[layout] : scalarTrees[layout]) &&
        trace["output_concatenated_sha256"].str ==
            (mixed ? mixedConcatPin : scalarConcatPin) &&
        trace["output_bytes"].integer == (mixed ? mixedBytes : scalarBytes) &&
        trace["status_gate"].str ==
            (expectedRoute == "ordinary" ? "ordinary-complete" : "all-skipped") &&
        trace["tool"].str == "/usr/bin/sample" &&
        trace["duration_seconds"].integer == sampleDuration &&
        trace["interval_milliseconds"].integer == sampleInterval &&
        isFinite(number(trace["instrumented_wall_seconds"])) &&
        number(trace["instrumented_wall_seconds"]) > 0 &&
        isFinite(number(trace["instrumented_user_seconds"])) &&
        number(trace["instrumented_user_seconds"]) >= 0 &&
        isFinite(number(trace["instrumented_system_seconds"])) &&
        number(trace["instrumented_system_seconds"]) >= 0 &&
        trace["instrumented_peak_rss_bytes"].integer > 0 &&
        trace["diagnostic_metrics_semantics"].str ==
            "direct-child wait4 diagnostics; excluded from frozen canonical timings" &&
        digest(trace["child_log_sha256"].str), "invalid trace process/output binding");
    if (expectedRoute != "ordinary") {
        auto files = layout == "many-small" ? 4096L : 8L;
        need(trace["durable_statuses"]["file_count"].integer == files &&
            trace["durable_statuses"]["expected_status"].str == "skipped" &&
            trace["durable_statuses"]["status_by_file_sha256"].str ==
                expectedStatusDigest(cast(size_t)files, "skipped"),
            "durable status evidence differs");
    }
    if (trace["status"].str == "SUPPORTED") {
        auto sample = trace["sample"];
        need(sample["pid_binary_bound"].boolean,
            "supported stack sample lacks PID/binary binding");
        need(sample["accepted_stacks"].integer >= minimumStacks,
            "supported stack sample has fewer than 100 stacks");
        need(sample["sanitized_sha256"].str == sanitizedSampleDigest(sample),
            "supported stack sanitized digest differs");
        need(((!sample["sample_path_redacted"].boolean &&
                sample["path_binding_semantics"].str ==
                "canonical sampled path plus exact direct-child PID and launched binary hash") ||
             (sample["sample_path_redacted"].boolean &&
                sample["path_binding_semantics"].str ==
                "Darwin sample privacy-redacted root/basename plus exact direct-child PID and launched binary hash")),
            "supported stack path binding semantics differ");
        need(digest(trace["raw_private_sha256"].str),
            "supported stack raw digest is invalid");
        need(sample["inclusive_top"].array.length > 0 &&
            sample["inclusive_top"].array.length <= 20,
            "supported stack inclusive top cardinality differs");
        need(sample["leaf_top"].array.length > 0 &&
            sample["leaf_top"].array.length <= 20,
            "supported stack leaf top cardinality differs");
        need(sample["dominant_leaf_component"].str.length != 0,
            "supported stack dominant component is empty");
        foreach (collection; [sample["inclusive_top"], sample["leaf_top"]])
            foreach (symbol; collection.array)
                need(symbol["symbol"].str.length && symbol["image"].str.length &&
                    symbol["count"].integer >= 0 &&
                    isFinite(number(symbol["fraction"])) &&
                    number(symbol["fraction"]) >= 0 &&
                    number(symbol["fraction"]) ==
                        cast(double)symbol["count"].integer /
                            sample["accepted_stacks"].integer,
                    "invalid top-symbol accounting");
        long total; double fraction = 0;
        foreach (name; ["kernel", "system", "runtime", "project", "unresolved"]) {
            auto part = sample["partitions"][name];
            need(part["count"].integer >= 0 && isFinite(number(part["fraction"])) &&
                number(part["fraction"]) >= 0 && number(part["fraction"]) <= 1,
                "invalid stack partition domain");
            total += part["count"].integer; fraction += number(part["fraction"]);
        }
        need(total == sample["accepted_stacks"].integer &&
            fraction > 0.999999 && fraction < 1.000001,
            "stack partition accounting differs: " ~ total.to!string ~ "/" ~
                sample["accepted_stacks"].integer.to!string ~ " fraction=" ~
                fraction.to!string);
    } else need(trace["status"].str == "UNSUPPORTED" && trace["reason"].str.length &&
        trace["time_profiler_fallback"]["status"].str == "UNSUPPORTED",
        "unsupported trace lacks exact fallback evidence");
}
private void validateGc(JSONValue item, string binaryHash, string layout,
        bool mixed, long repetition, string sourceSha, string sourceTree,
        string attestationHash) {
    need(item["status"].str == "SUPPORTED" && item["repetition"].integer == repetition &&
        item["layout"].str == layout && item["workload"].str == (mixed ? "mixed" : "scalar") &&
        item["threads"].integer == 1 && item["max_open_inputs"].integer == 1 &&
        item["target_binary_sha256"].str == binaryHash &&
        item["source_sha"].str == sourceSha && item["source_tree_id"].str == sourceTree &&
        item["build_attestation_sha256"].str == attestationHash &&
        item["config_sha256"].str == (mixed ? mixedConfigPin : scalarConfigPin) &&
        item["fixture_table_sha256"].str == fixtureTablePin &&
        item["exact_output"].boolean &&
        item["output_tree_sha256"].str == (mixed ? mixedTrees[layout] : scalarTrees[layout]) &&
        item["output_concatenated_sha256"].str ==
            (mixed ? mixedConcatPin : scalarConcatPin) &&
        item["output_bytes"].integer == (mixed ? mixedBytes : scalarBytes) &&
        item["collection_count"].integer >= 0 && item["allocated_bytes"].integer >= 0 &&
        item["allocated_bytes_semantics"].str ==
            "druntime whole-MB summary converted with 1048576 bytes per MiB" &&
        item["collection_time_milliseconds"].integer >= 0 &&
        item["semantics"].str ==
            "D runtime GC-only; excludes native and total-process allocations" &&
        item["pool_size"]["status"].str == "UNSUPPORTED" &&
        item["heap_size"]["status"].str == "UNSUPPORTED" &&
        digest(item["raw_private_sha256"].str) && digest(item["sanitized_sha256"].str),
        "invalid structured D-GC evidence");
}
private bool sameRange(JSONValue left, JSONValue right) {
    foreach (key; ["minimum", "median", "maximum"])
        if (number(left[key]) != number(right[key])) return false;
    return true;
}
private void validateSummary(JSONValue summary, JSONValue[] traces) {
    auto expected = summarizeTraces(traces);
    need(summary["status"].str == expected["status"].str,
        "trace summary is not derived from repetitions");
    foreach (key; ["instrumented_wall_seconds", "instrumented_user_seconds",
            "instrumented_system_seconds", "instrumented_peak_rss_bytes"])
        need(sameRange(summary["diagnostics"][key], expected["diagnostics"][key]),
            "diagnostic trace range differs from repetitions");
    if (expected["status"].str == "SUPPORTED")
        need(sameRange(summary["accepted_stacks"], expected["accepted_stacks"]) &&
            summary["stable_named_component"].boolean ==
                expected["stable_named_component"].boolean &&
            summary["component"].str == expected["component"].str,
            "supported trace summary differs from repetitions");
    else need(summary["reason"].str == expected["reason"].str,
        "unsupported trace summary reason differs");
    if (expected["status"].str == "SUPPORTED")
        foreach (name; ["kernel", "system", "runtime", "project", "unresolved"])
            foreach (key; ["count", "fraction"])
                need(sameRange(summary["partition_ranges"][name][key],
                    expected["partition_ranges"][name][key]),
                    "partition range differs from repetitions");
}
private void validateReport(JSONValue report, string expectedHarness = "") {
    need(report.type == JSONType.object && report["schema"].str == schema &&
        report["source_binary_mapping"].str == "ATTESTED" &&
        digest(report["binary_sha256"].str) && digest(report["harness_sha256"].str) &&
        report["canonical_profile_sha256"].str == canonicalProfilePin &&
        report["canonical_profile_binary_sha256"].str == canonicalProfileBinaryPin &&
        report["canonical_profile_schema"].str == "scrubbed-cli-profile-v1" &&
        report["source_ancestry"]["canonical_profile_source_sha"].str ==
            canonicalProfileSourcePin &&
        report["source_ancestry"]["historical_merge_base_sha"].str ==
            historicalMergeBasePin &&
        report["source_ancestry"]["accepted_attribution_base_sha"].str ==
            acceptedBasePin &&
        report["source_ancestry"]["attribution_source_sha"].str ==
            report["build_attestation"]["source_sha"].str &&
        report["source_ancestry"]["relationship"].str ==
            "historical issue-branch profile source and attribution line share the pinned merge base; accepted attribution base is an ancestor of attribution source" &&
        report["source_ancestry"]["intervening_production_commits"].array.length == 2 &&
        report["source_ancestry"]["intervening_production_commits"][0].str ==
            "7b0f164 bounded extraction detection contracts" &&
        report["source_ancestry"]["intervening_production_commits"][1].str ==
            "fc61fdf bounded ZIP container inspection" &&
        report["harness_executable_name"].str == harnessName &&
        report["harness_build_recipe"].str == harnessBuildRecipe &&
        report["harness_compiler_executable_sha256"].str ==
            report["build_attestation"]["compiler_executable_sha256"].str &&
        report["harness_compiler_version"].str ==
            report["build_attestation"]["compiler_version"].str &&
        !report["optimization_authorized"].boolean && report["layouts"].array.length == 2,
        "not a complete canonical attribution report");
    if (expectedHarness.length) need(report["harness_sha256"].str == expectedHarness,
        "attribution harness drift");
    validateAttestation(report["build_attestation"], report["binary_sha256"].str);
    need(report["build_attestation_sha256"].str == hashBytes(
            cast(const(ubyte)[])report["build_attestation"].toString),
        "build attestation publication digest differs");
    need(report["frozen_materials"]["fixture_table_sha256"].str == fixtureTablePin &&
        report["frozen_materials"]["record_bytes"].integer == recordBytes &&
        report["frozen_materials"]["record_count"].integer == recordCount &&
        report["frozen_materials"]["scalar_config_sha256"].str == scalarConfigPin &&
        report["frozen_materials"]["mixed_config_sha256"].str == mixedConfigPin &&
        report["frozen_materials"]["input_concatenated_sha256"].str == inputConcatPin &&
        report["frozen_materials"]["scalar_concatenated_sha256"].str == scalarConcatPin &&
        report["frozen_materials"]["mixed_concatenated_sha256"].str == mixedConcatPin &&
        report["preflight"]["checked_before_fixture_creation"].boolean &&
        report["preflight"]["physical_ram_bytes"].integer >= minimumCapacity &&
        report["preflight"]["scratch_free_bytes"].integer >= minimumCapacity &&
        report["preflight"]["derived_fixture_footprint_bytes"].integer ==
            corpusBytes * 12 &&
        report["preflight"]["required_scratch_bytes"].integer ==
            corpusBytes * 12 * 4 &&
        report["preflight"]["scratch_free_bytes"].integer >=
            report["preflight"]["required_scratch_bytes"].integer &&
        report["preflight"]["declared_budget_seconds"].integer >= minimumBudget &&
        report["tool"]["name"].str == "/usr/bin/sample" &&
        digest(report["tool"]["executable_sha256"].str) &&
        report["tool"]["darwin_product_version"].str.length &&
        report["tool"]["duration_seconds"].integer == sampleDuration &&
        report["tool"]["interval_milliseconds"].integer == sampleInterval &&
        report["tool"]["minimum_accepted_stacks"].integer == minimumStacks &&
        report["tool"]["semantics"].str == "sampled stacks, not exact calls",
        "frozen attribution materials/tool settings drift");
    bool allSupported = true, allStable = true;
    auto names = ["scalar-threads1", "mixed-threads1", "mixed-threads4",
        "manifest-verified-skip", "journal-verified-skip"];
    foreach (layoutIndex, layout; report["layouts"].array) {
        auto layoutName = layouts[layoutIndex].name;
        need(layout["name"].str == layoutName &&
            layout["files"].integer == cast(long)layouts[layoutIndex].files &&
            layout["input_bytes"].integer == corpusBytes &&
            layout["trace_cases"].array.length == 5 &&
            layout["input_tree_sha256"].str == inputTrees[layoutName] &&
            layout["input_concatenated_sha256"].str == inputConcatPin,
            "attribution layout identity/cardinality differs");
        foreach (caseIndex, item; layout["trace_cases"].array) {
            need(item["name"].str == names[caseIndex] &&
                item["traces"].array.length == repetitions,
                "trace case order/cardinality differs");
            foreach (rep, trace; item["traces"].array)
                validateTrace(trace, report["binary_sha256"].str, layoutName,
                    names[caseIndex], rep,
                    report["build_attestation"]["source_sha"].str,
                    report["build_attestation"]["source_tree_id"].str,
                    report["build_attestation_sha256"].str);
            auto summary = item["summary"];
            validateSummary(summary, item["traces"].array);
            allSupported = allSupported && summary["status"].str == "SUPPORTED";
            if (summary["status"].str == "SUPPORTED")
                allStable = allStable && summary["stable_named_component"].boolean;
        }
        foreach (mixed; [false, true]) {
            auto values = layout["gc_profiles"][mixed ? "mixed_threads1" : "scalar_threads1"];
            need(values.array.length == repetitions, "D-GC repetition cardinality differs");
            foreach (rep, item; values.array)
                validateGc(item, report["binary_sha256"].str, layoutName, mixed, rep,
                    report["build_attestation"]["source_sha"].str,
                    report["build_attestation"]["source_tree_id"].str,
                    report["build_attestation_sha256"].str);
            auto expectedGc = summarizeGc(values.array);
            auto summaryGc = layout["gc_summaries"][
                mixed ? "mixed_threads1" : "scalar_threads1"];
            need(summaryGc["semantics"].str == expectedGc["semantics"].str,
                "D-GC summary semantics differ");
            foreach (key; ["collection_count", "allocated_bytes",
                    "collection_time_milliseconds"])
                need(sameRange(summaryGc[key], expectedGc[key]),
                    "D-GC range differs from repetitions");
        }
    }
    auto expectedDecision = !allSupported ? "UNAVAILABLE_ATTRIBUTION" :
        (allStable ? "STABLE_NAMED_HOTSPOT" : "DISTRIBUTED_COST");
    need(report["decision"].str == expectedDecision, "attribution decision is not derived");
    noLeak(report.toString);
}

private void mustThrow(void delegate() action, string message) {
    bool rejected;
    try action(); catch (Exception) rejected = true;
    need(rejected, message);
}
private void mustRejectTrace(JSONValue good, void delegate(ref JSONValue) mutate,
        string message) {
    auto bad = parseJSON(good.toString);
    mutate(bad);
    mustThrow(() { validateTrace(bad, "A".replicate(64), "many-small",
        "scalar-threads1", 0); }, message);
}
private void selfTest() {
    auto raw = "Analysis of sampling sleep (pid 123) every 10 milliseconds\n" ~
        "Process: sleep [123]\nPath: /bin/sleep\nCall graph:\n" ~
        "    120 Thread_1\n      120 work  (in sleep) + 4  [0x1]\n" ~
        "Total number in stack (recursive counted multiple, when >=5):\n\n" ~
        "Sort by top of stack, same collapsed (when >= 5):\n" ~
        "        work  (in sleep)        120\n\nBinary Images:\n";
    auto parsed = parseSample(raw, 123, "/bin/sleep");
    need(parsed["accepted_stacks"].integer == 120, "valid sample parser control failed");
    need(parsed["inclusive_top"].array.length == 1 &&
        parsed["leaf_top"].array.length == 1,
        "valid sample top-symbol parser control failed");
    mustThrow(() { parseSample(raw, 124, "/bin/sleep"); }, "wrong PID accepted");
    mustThrow(() { parseSample(raw.replace("Path: /bin/sleep", "Path: /bin/date"),
        123, "/bin/sleep"); }, "wrong binary accepted");
    need(redactedSamplePathMatches(
        "/private/var/folders/*/scrubbed-attested-snapshot",
        "/private/var/folders/j3/private/scrubbed-attested-snapshot"),
        "valid Darwin privacy-redacted path control failed");
    mustThrow(() { redactedSamplePathMatches(
        "/private/var/folders/*/wrong-name",
        "/private/var/folders/j3/private/scrubbed-attested-snapshot"); },
        "wrong redacted basename accepted");
    mustThrow(() { need(redactedSamplePathMatches(
        "/untrusted/root/*/scrubbed-attested-snapshot",
        "/private/var/folders/j3/private/scrubbed-attested-snapshot"),
        "untrusted redacted root"); }, "untrusted redacted root accepted");
    mustThrow(() { redactedSamplePathMatches(
        "/private/var/folders/*/*/scrubbed-attested-snapshot",
        "/private/var/folders/j3/private/scrubbed-attested-snapshot"); },
        "multiple redactions accepted");
    mustThrow(() { parseSample(raw.replace("120 Thread", "99 Thread").replace(
        "120 work", "99 work"), 123, "/bin/sleep"); }, "too few stacks accepted");
    auto privateSymbol = parseSample(raw.replace("work  (in sleep)",
        "/Users/private  (in sleep)"), 123, "/bin/sleep");
    noLeak(privateSymbol.toString);
    mustThrow(() { parseSample(raw.replace("every 10 milliseconds",
        "every 20 milliseconds"), 123, "/bin/sleep"); },
        "wrong sampling settings accepted");
    mustThrow(() { parseSample(raw.replace("(in sleep)        120",
        "(in sleep)        121"), 123, "/bin/sleep"); },
        "over-accounted leaf stacks accepted");
    auto gc = "\tNumber of collections:  2\n\tGrand total GC time:  3 milliseconds\n" ~
        "GC summary:    5 MB,    2 GC    3 ms, Pauses    1 ms <    2 ms\n";
    need(parseGc(gc)["allocated_bytes"].integer == 5L * 1024 * 1024,
        "valid GC parser control failed");
    mustThrow(() { parseGc("Number of collections: 1\n"); }, "truncated GC accepted");
    mustThrow(() { parseGc(gc ~ "Number of collections: 2\n"); }, "duplicate GC accepted");
    mustThrow(() { parseGc(gc.replace("  2\n", "  -2\n")); }, "negative GC accepted");
    mustThrow(() { parseGc(gc.replace("    5 MB", "  999999999999999999999 MB")); },
        "overflow GC accepted");
    mustThrow(() { parseGc(gc.replace("GC summary:", "GC totals:")); },
        "wrong-format GC accepted");
    auto trace = JSONValue([
        "repetition": JSONValue(0L), "layout": JSONValue("many-small"),
        "workload": JSONValue("scalar"), "threads": JSONValue(1L),
        "max_open_inputs": JSONValue(1L), "route": JSONValue("ordinary"),
        "config_sha256": JSONValue(scalarConfigPin),
        "fixture_table_sha256": JSONValue(fixtureTablePin),
        "sampled_pid": JSONValue(123L),
        "target_binary_sha256": JSONValue("A".replicate(64)),
        "process_exit_code": JSONValue(0L), "process_signal": JSONValue(0L),
        "exact_output": JSONValue(true),
        "output_tree_sha256": JSONValue(scalarTrees["many-small"]),
        "output_concatenated_sha256": JSONValue(scalarConcatPin),
        "output_bytes": JSONValue(scalarBytes),
        "status_gate": JSONValue("ordinary-complete"),
        "tool": JSONValue("/usr/bin/sample"),
        "duration_seconds": JSONValue(sampleDuration),
        "interval_milliseconds": JSONValue(sampleInterval),
        "instrumented_wall_seconds": JSONValue(2.1),
        "instrumented_user_seconds": JSONValue(1.0),
        "instrumented_system_seconds": JSONValue(0.1),
        "instrumented_peak_rss_bytes": JSONValue(4096L),
        "diagnostic_metrics_semantics": JSONValue(
            "direct-child wait4 diagnostics; excluded from frozen canonical timings"),
        "child_log_sha256": JSONValue("B".replicate(64)),
        "status": JSONValue("SUPPORTED"), "sample": parsed,
        "raw_private_sha256": JSONValue("C".replicate(64))]);
    validateTrace(trace, "A".replicate(64), "many-small", "scalar-threads1", 0);
    mustRejectTrace(trace, (ref JSONValue t) { t["sampled_pid"] = 0L; },
        "missing PID binding accepted");
    mustRejectTrace(trace, (ref JSONValue t) { t["config_sha256"] = "D".replicate(64); },
        "stale config binding accepted");
    mustRejectTrace(trace, (ref JSONValue t) { t["sample"]["accepted_stacks"] = 99L; },
        "fewer than 100 published stacks accepted");
    mustRejectTrace(trace, (ref JSONValue t) {
        t["sample"]["partitions"]["project"]["fraction"] = 0.5;
    }, "bad published partition fraction accepted");
    mustRejectTrace(trace, (ref JSONValue t) { t["workload"] = "mixed"; },
        "mixed workload binding accepted");
    mustRejectTrace(trace, (ref JSONValue t) { t["exact_output"] = false; },
        "failed exact output accepted");
    mustRejectTrace(trace, (ref JSONValue t) { t["process_exit_code"] = 1L; },
        "failed process accepted");
    mustRejectTrace(trace, (ref JSONValue t) {
        t["sample"]["dominant_leaf_component"] = "";
    }, "empty dominant component accepted");
    JSONValue[] sequence;
    foreach (rep; 0 .. repetitions) {
        auto item = parseJSON(trace.toString);
        item["repetition"] = rep;
        sequence ~= item;
    }
    auto summary = summarizeTraces(sequence);
    validateSummary(summary, sequence);
    auto mixedSequence = sequence.dup;
    mixedSequence[2]["repetition"] = 1L;
    mustThrow(() { summarizeTraces(mixedSequence); },
        "mixed trace repetition indexes accepted");
    mustThrow(() { noLeak(`{"symbol":"/Users/private/name"}`); },
        "published private path accepted");
    writeln("canonical attribution self-test passed (23 release-active negatives)");
}

private void selfTestLiveSample(string self) {
    auto root = scratch(); scope(exit) if (exists(root)) rmdirRecurse(root);
    auto rawPath = buildPath(root, "sample.txt");
    auto child = spawnProcess(["/bin/sleep", "4"]);
    auto pid = child.processID;
    auto sampled = execute(["/usr/bin/sample", pid.to!string,
        sampleDuration.to!string, sampleInterval.to!string, "-file", rawPath]);
    auto status = wait(child);
    need(sampled.status == 0 && status == 0 && exists(rawPath),
        "live sample control process failed");
    auto parsed = parseSample(readText(rawPath), pid, "/bin/sleep");
    need(parsed["accepted_stacks"].integer >= minimumStacks,
        "live sample control accepted too few stacks");
    need(parsed["inclusive_top"].array.length && parsed["leaf_top"].array.length,
        "live exact-path sample lacked parsed symbol rows");
    auto privateTarget = buildPath(root, "scrubbed-attested-snapshot");
    copy(self, privateTarget);
    need(execute(["chmod", "700", privateTarget]).status == 0,
        "cannot prepare live redacted-path control");
    rawPath = buildPath(root, "redacted-sample.txt");
    child = spawnProcess([privateTarget, "--self-test-sample-child"]);
    pid = child.processID;
    sampled = execute(["/usr/bin/sample", pid.to!string,
        sampleDuration.to!string, sampleInterval.to!string, "-file", rawPath]);
    status = wait(child);
    need(sampled.status == 0 && status == 0 && exists(rawPath),
        "live redacted-path sample control process failed");
    auto redacted = parseSample(readText(rawPath), pid, privateTarget);
    need(redacted["sample_path_redacted"].boolean &&
        redacted["accepted_stacks"].integer >= minimumStacks &&
        redacted["inclusive_top"].array.length && redacted["leaf_top"].array.length,
        "live Darwin redacted-path binding control failed");
    writeln("canonical attribution live sample parser passed: ",
        parsed["accepted_stacks"].integer, " exact-path and ",
        redacted["accepted_stacks"].integer, " redacted-path accepted stacks");
}

int main(string[] args) {
    try {
        if (args.length == 2 && args[1] == "--self-test-sample-child") {
            Thread.sleep(msecs(4_000)); return 0;
        }
        need(baseName(args[0]) == harnessName,
            "attribution checker executable basename must be " ~ harnessName);
        if (args.length == 2 && args[1] == "--self-test") { selfTest(); return 0; }
        if (args.length == 2 && args[1] == "--self-test-live-sample") {
            selfTestLiveSample(args[0]); return 0;
        }
        if (args.length == 3 && args[1] == "--check") {
            validateReport(parseJSON(readText(args[2])), hashFile(args[0]));
            writeln("canonical CLI attribution valid: ",
                parseJSON(readText(args[2]))["decision"].str);
            return 0;
        }
        need(args.length == 8 && args[1] == "--run",
            "usage: pipeline_attribution_check --self-test | --self-test-live-sample | --check REPORT | --run BINARY ATTESTATION CANONICAL_PROFILE REPORT BUDGET HARNESS");
        need(hashFile(args[7]) == hashFile(args[0]), "attribution harness path differs");
        auto root = scratch(); scope(exit) if (exists(root)) rmdirRecurse(root);
        auto report = runAttribution(args[2], parseJSON(readText(args[3])),
            args[4], args[7], root, args[6].to!long);
        auto serialized = report.toString; noLeak(serialized);
        write(args[5], serialized ~ "\n");
        writeln("canonical CLI attribution written: ", args[5]);
        return 0;
    } catch (Exception error) {
        writeln("canonical attribution failure: ", error.msg);
        return 1;
    }
}
