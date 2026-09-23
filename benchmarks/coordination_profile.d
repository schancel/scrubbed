/// Frozen O3/release coordination attribution for issue #182.
module benchmarks.coordination_profile;

import core.atomic : atomicLoad, atomicStore;
import core.stdc.errno : EINTR, errno;
import core.sys.posix.signal : SIGKILL;
import core.sys.posix.sys.resource : rusage;
import core.sys.posix.sys.stat : chmod, S_IRUSR, S_IWUSR, S_IXUSR, S_IRWXU;
import core.sys.posix.unistd : link;
import core.sys.posix.sys.wait : WEXITSTATUS, WIFEXITED;
import core.thread : Thread;
import core.time : msecs;
import std.algorithm.sorting : sort;
import std.algorithm.searching : canFind;
import std.array : appender;
import std.ascii : isHexDigit;
import std.conv : to;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.digest : LetterCase, toHexString;
import std.digest.sha : SHA256, sha256Of;
import std.file : SpanMode, copy, dirEntries, exists, getAttributes, isFile,
    isSymlink, mkdirRecurse, read, readText, remove, rmdirRecurse,
    setAttributes, tempDir, write;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : absolutePath, buildPath, relativePath;
import std.process : execute, kill, spawnProcess;
import std.stdio : File, writeln;
import std.string : splitLines, strip, toStringz;
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

private struct ExecutableSnapshot { string path, digest; }

private string privateScratch(string prefix) {
    auto root = buildPath(tempDir, prefix ~ randomUUID.toString);
    mkdirRecurse(root);
    need(chmod(root.toStringz, S_IRWXU) == 0,
        "cannot restrict benchmark scratch directory");
    return root;
}

private ExecutableSnapshot snapshotExecutable(string source, string root,
        string label) {
    need(isFile(source) && !isSymlink(source),
        label ~ " binary must be a regular non-symlink file");
    auto destination = buildPath(root, label ~ "-executable");
    copy(source, destination);
    need(chmod(destination.toStringz, S_IRUSR | S_IXUSR) == 0,
        label ~ " executable snapshot could not be made read-only");
    need(isFile(destination) && !isSymlink(destination),
        label ~ " executable snapshot differs");
    auto digest = fileDigest(destination);
    need(digest == fileDigest(source), label ~ " binary changed while snapshotting");
    return ExecutableSnapshot(destination, digest);
}

private void verifySnapshot(ref const ExecutableSnapshot snapshot) {
    need(isFile(snapshot.path) && !isSymlink(snapshot.path) &&
        fileDigest(snapshot.path) == snapshot.digest,
        "executable snapshot changed during benchmark");
}

private void publishReport(string reportPath, string text) {
    auto temporary = reportPath ~ ".tmp-" ~ randomUUID.toString;
    scope(exit) if (exists(temporary)) remove(temporary);
    write(temporary, text ~ "\n");
    need(readText(temporary) == text ~ "\n",
        "temporary report reopen differs");
    parseJSON(readText(temporary));
    need(link(temporary.toStringz, reportPath.toStringz) == 0,
        "cannot publish report without overwriting an existing path");
    remove(temporary);
    need(readText(reportPath) == text ~ "\n", "report reopen differs");
}

private bool isDigest(string value, size_t length) {
    if (value.length != length) return false;
    foreach (c; value) if (!c.isHexDigit) return false;
    return true;
}

private JSONValue loadBuildAttestation(string reportPath,
        string expectedBinaryDigest) {
    need(isFile(reportPath) && !isSymlink(reportPath),
        "build attestation report must be a regular non-symlink file");
    auto sourceReport = parseJSON(readText(reportPath));
    need(sourceReport["source_binary_mapping"].str == "ATTESTED" &&
        sourceReport["binary_sha256"].str == expectedBinaryDigest,
        "build attestation report does not bind the supplied binary");
    auto attestation = sourceReport["build_attestation"];
    need(attestation["schema"].str == "scrubbed-build-attestation-v4" &&
        attestation["target_sha256"].str == expectedBinaryDigest &&
        attestation["source_status"].str == "clean-before-and-after" &&
        attestation["build_status"].integer == 0 &&
        attestation["compiler_executable_name"].str == "ldc2" &&
        attestation["compiler_version"].str.length > 0 &&
        attestation["build_flags"].str ==
            "release; force; non-interactive; cache=local" &&
        isDigest(attestation["source_sha"].str, 40) &&
        isDigest(attestation["source_tree_id"].str, 40) &&
        isDigest(attestation["source_archive_sha256"].str, 64) &&
        isDigest(attestation["dub_recipe_sha256"].str, 64) &&
        isDigest(attestation["dependency_lock_sha256"].str, 64) &&
        isDigest(attestation["compiler_executable_sha256"].str, 64) &&
        isDigest(attestation["dub_executable_sha256"].str, 64),
        "build attestation is incomplete or inconsistent");
    return attestation;
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

private void makeSizeOrderFixture(string root, string variant) {
    enum files = 4096;
    enum largeFiles = 64;
    enum smallRecords = 64; // 16 KiB
    enum largeRecords = 4096; // 1 MiB
    mkdirRecurse(root);
    size_t recordOrdinal;
    foreach (index; 0 .. files) {
        bool large;
        if (variant == "clustered-late") large = index >= files - largeFiles;
        else if (variant == "largest-first") large = index < largeFiles;
        else if (variant == "seeded-distribution")
            large = ((index * 4051) % files) < largeFiles;
        else throw new Exception("unknown size-order fixture");
        auto file = File(buildPath(root, format!"doc-%04d.txt"(index)), "wb");
        foreach (_; 0 .. (large ? largeRecords : smallRecords))
            file.rawWrite(inputRecord(recordOrdinal++));
    }
    string[] names;
    foreach (entry; dirEntries(root, SpanMode.shallow, false))
        names ~= relativePath(entry.name, root);
    names.sort();
    size_t[] largeRanks;
    foreach (rank, name; names) {
        auto index = name[4 .. 8].to!size_t;
        bool large = variant == "clustered-late" ? index >= files - largeFiles :
            variant == "largest-first" ? index < largeFiles :
            ((index * 4051) % files) < largeFiles;
        if (large) largeRanks ~= rank;
    }
    need(largeRanks.length == largeFiles, "size-order large-file count differs");
    if (variant == "clustered-late")
        foreach (offset, rank; largeRanks)
            need(rank == files - largeFiles + offset,
                "clustered-late canonical ranks differ");
    else if (variant == "largest-first")
        foreach (offset, rank; largeRanks)
            need(rank == offset, "largest-first canonical ranks differ");
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
        bool instrumented, string expectedBinaryDigest,
        bool injectProbeFailure = false) {
    need(fileDigest(binary) == expectedBinaryDigest,
        "executable snapshot changed before invocation");
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
        "SCRUBBED_COORDINATION_METRICS_V2=" ~ metricsPath, binary] : [binary];
    if (instrumented && ordinal == 0) command ~= "--DRT-gcopt=profile:2";
    command ~= ["run", "--input", input, "--output", output, "--config", config,
        "--threads", threads.to!string, "--max-open-inputs", threads.to!string];
    auto timer = StopWatch(AutoStart.yes);
    auto child = spawnProcess(command, stdinFile, stdoutFile, stderrFile);
    stdinFile.close(); stdoutFile.close(); stderrFile.close();
    bool childReaped;
    scope(failure) if (!childReaped) {
        try kill(child, SIGKILL); catch (Exception) {}
        int cleanupStatus; rusage cleanupUsage; int cleanupWaited;
        do cleanupWaited = wait4(child.processID, &cleanupStatus, 0,
            &cleanupUsage);
        while (cleanupWaited < 0 && errno == EINTR);
    }
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
    bool samplerJoined;
    scope(exit) if (!samplerJoined) {
        atomicStore(stopped, true);
        sampler.join();
    }
    if (injectProbeFailure)
        throw new Exception("injected post-spawn probe failure");
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
    childReaped = waited == child.processID;
    timer.stop();
    atomicStore(stopped, true); sampler.join();
    samplerJoined = true;
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
        need(metrics["schema"].str == "scrubbed.coordination-metrics.v2",
            "metrics schema differs");
        result["metrics"] = metrics;
    }
    need(fileDigest(binary) == expectedBinaryDigest,
        "executable snapshot changed during invocation");
    return result;
}

private void requireKeys(ref JSONValue value, string[] expected,
        string label) {
    need(value.type == JSONType.object, label ~ " must be an object");
    need(value.object.length == expected.length,
        label ~ " field cardinality differs");
    foreach (key; expected)
        need((key in value.object) !is null, label ~ " omitted " ~ key);
}

private long metricInteger(ref JSONValue value, string key, string label) {
    auto result = value[key].integer;
    need(result >= 0, label ~ " contains negative " ~ key);
    return result;
}

private void validateMetrics(ref JSONValue sample, size_t expectedFiles,
        ulong expectedBytes) {
    auto metrics = sample["metrics"];
    requireKeys(metrics, ["schema", "version", "wall_nanoseconds", "limits",
        "counts", "phases"], "metrics");
    need(metrics["schema"].str == "scrubbed.coordination-metrics.v2" &&
        metrics["version"].integer == 2,
        "metrics revision differs");
    need(metricInteger(metrics, "wall_nanoseconds", "metrics") > 0,
        "metrics wall duration is empty");
    auto limits = metrics["limits"];
    requireKeys(limits, ["queued_documents", "reserved_bytes",
        "worker_descriptors"], "metrics limits");
    auto queuedLimit = metricInteger(limits, "queued_documents", "limits");
    auto byteLimit = metricInteger(limits, "reserved_bytes", "limits");
    auto descriptorLimit = metricInteger(limits, "worker_descriptors", "limits");
    need(queuedLimit > 0 && byteLimit > 0 && descriptorLimit > 0,
        "metrics limits must be positive");
    auto counts = metrics["counts"];
    requireKeys(counts, ["queued_documents", "reserved_bytes",
        "worker_descriptors", "peak_queued_documents", "peak_reserved_bytes",
        "peak_worker_descriptors", "submitted", "succeeded", "failed",
        "skipped"], "metrics counts");
    foreach (key; ["queued_documents", "reserved_bytes", "worker_descriptors",
            "peak_queued_documents", "peak_reserved_bytes",
            "peak_worker_descriptors", "submitted", "succeeded", "failed",
            "skipped"])
        metricInteger(counts, key, "counts");
    need(counts["submitted"].integer == expectedFiles &&
        counts["succeeded"].integer == expectedFiles &&
        counts["failed"].integer == 0 && counts["skipped"].integer == 0 &&
        counts["queued_documents"].integer == 0 &&
        counts["reserved_bytes"].integer == 0 &&
        counts["worker_descriptors"].integer == 0 &&
        counts["peak_queued_documents"].integer <= queuedLimit &&
        counts["peak_reserved_bytes"].integer <= byteLimit &&
        counts["peak_worker_descriptors"].integer <= descriptorLimit,
        "terminal/reservation accounting differs");
    auto phases = metrics["phases"];
    auto rootPhases = ["source_stat", "ordinal_assignment", "admission_wait",
            "accepted_worker_queue", "descriptor_wait", "descriptor_hold",
            "transform", "ordered_result_wait", "atomic_publication"];
    requireKeys(phases, ["discovery"] ~ rootPhases ~ ["shutdown_join"],
        "metrics phases");
    foreach (name; ["discovery"] ~ rootPhases ~ ["shutdown_join"]) {
        auto phase = phases[name];
        requireKeys(phase, ["calls", "units", "nanoseconds"],
            "metrics phase " ~ name);
        foreach (key; ["calls", "units", "nanoseconds"])
            metricInteger(phase, key, "metrics phase " ~ name);
    }
    foreach (name; rootPhases)
        need(phases[name]["calls"].integer == expectedFiles,
            name ~ " root count differs");
    need(phases["discovery"]["calls"].integer == 1 &&
        phases["discovery"]["units"].integer == expectedFiles &&
        phases["source_stat"]["units"].integer == expectedFiles &&
        phases["ordinal_assignment"]["units"].integer == expectedFiles &&
        phases["admission_wait"]["units"].integer == expectedBytes &&
        phases["accepted_worker_queue"]["units"].integer == expectedBytes &&
        phases["accepted_worker_queue"]["nanoseconds"].integer > 0,
        "accepted-worker queue accounting differs");
    need(phases["descriptor_wait"]["units"].integer == expectedBytes &&
        phases["descriptor_hold"]["units"].integer == expectedBytes &&
        phases["transform"]["units"].integer == expectedBytes &&
        phases["ordered_result_wait"]["units"].integer == 0 &&
        phases["atomic_publication"]["units"].integer > 0,
        "transform byte accounting differs");
    need(phases["shutdown_join"]["calls"].integer == 1 &&
        phases["shutdown_join"]["units"].integer == 0,
        "shutdown count differs");
    auto processCpuNanoseconds =
        (sample["user_us"].integer + sample["system_us"].integer) * 1_000;
    need(phases["transform"]["nanoseconds"].integer <=
        processCpuNanoseconds + 1_000_000,
        "transform CPU exceeds whole-process CPU");
}

private void runSelfTest(string harnessPath) {
    auto root = privateScratch("scrubbed-coordination-self-test-");
    scope(exit) if (exists(root)) rmdirRecurse(root);
    need((getAttributes(root) & 511) == S_IRWXU,
        "benchmark scratch permissions differ");

    auto mutableExecutable = buildPath(root, "mutable-executable");
    write(mutableExecutable, "#!/bin/sh\nexit 0\n");
    setAttributes(mutableExecutable, getAttributes(harnessPath));
    auto snapshot = snapshotExecutable(mutableExecutable, root, "self-test");
    auto snapshotDigest = fileDigest(snapshot.path);
    write(mutableExecutable, "replaced after snapshot\n");
    need(fileDigest(snapshot.path) == snapshotDigest &&
        fileDigest(mutableExecutable) != snapshotDigest,
        "executable snapshot followed mutable source");

    need(chmod(snapshot.path.toStringz, S_IRUSR | S_IWUSR | S_IXUSR) == 0,
        "cannot make self-test snapshot writable");
    write(snapshot.path, "changed snapshot\n");
    bool changedSnapshotRejected;
    try verifySnapshot(snapshot);
    catch (Exception) { changedSnapshotRejected = true; }
    need(changedSnapshotRejected, "changed executable snapshot was accepted");

    bool cleanupFailureObserved;
    auto trueDigest = fileDigest("/usr/bin/true");
    try invoke("/usr/bin/true", root, root, root, 1, 0, root, false,
        trueDigest, true);
    catch (Exception error) {
        cleanupFailureObserved = error.msg == "injected post-spawn probe failure";
    }
    need(cleanupFailureObserved, "post-spawn cleanup injection differed");

    enum validMetrics = `{"user_us":1000,"system_us":1000,"metrics":{` ~
        `"schema":"scrubbed.coordination-metrics.v2","version":2,` ~
        `"wall_nanoseconds":1000,` ~
        `"limits":{"queued_documents":1,"reserved_bytes":1,` ~
        `"worker_descriptors":1},` ~
        `"counts":{"submitted":1,"succeeded":1,"failed":0,"skipped":0,` ~
        `"queued_documents":0,"reserved_bytes":0,"worker_descriptors":0,` ~
        `"peak_queued_documents":1,"peak_reserved_bytes":1,` ~
        `"peak_worker_descriptors":1},` ~
        `"phases":{` ~
        `"discovery":{"calls":1,"units":1,"nanoseconds":1},` ~
        `"source_stat":{"calls":1,"units":1,"nanoseconds":1},` ~
        `"ordinal_assignment":{"calls":1,"units":1,"nanoseconds":1},` ~
        `"admission_wait":{"calls":1,"units":1,"nanoseconds":1},` ~
        `"accepted_worker_queue":{"calls":1,"units":1,"nanoseconds":1},` ~
        `"descriptor_wait":{"calls":1,"units":1,"nanoseconds":1},` ~
        `"descriptor_hold":{"calls":1,"units":1,"nanoseconds":1},` ~
        `"transform":{"calls":1,"units":1,"nanoseconds":1},` ~
        `"ordered_result_wait":{"calls":1,"units":0,"nanoseconds":1},` ~
        `"atomic_publication":{"calls":1,"units":1,"nanoseconds":1},` ~
        `"shutdown_join":{"calls":1,"units":0,"nanoseconds":1}}}}`;
    auto valid = parseJSON(validMetrics);
    validateMetrics(valid, 1, 1);
    auto invalid = parseJSON(validMetrics);
    invalid["metrics"]["phases"]["accepted_worker_queue"]["calls"] = 0;
    bool invalidRejected;
    try validateMetrics(invalid, 1, 1);
    catch (Exception) { invalidRejected = true; }
    need(invalidRejected, "zeroed comparison attribution was accepted");
    invalid = parseJSON(validMetrics);
    invalid["metrics"]["version"] = 999;
    invalidRejected = false;
    try validateMetrics(invalid, 1, 1);
    catch (Exception) { invalidRejected = true; }
    need(invalidRejected, "mismatched metrics revision was accepted");
    invalid = parseJSON(validMetrics);
    invalid["metrics"]["unexpected"] = 1;
    invalidRejected = false;
    try validateMetrics(invalid, 1, 1);
    catch (Exception) { invalidRejected = true; }
    need(invalidRejected, "unexpected metrics field was accepted");
    auto reportPath = buildPath(root, "atomic-report.json");
    publishReport(reportPath, `{"schema":"self-test"}`);
    need(parseJSON(readText(reportPath))["schema"].str == "self-test",
        "atomic report publication differed");
    bool overwriteRejected;
    try publishReport(reportPath, `{"schema":"replacement"}`);
    catch (Exception) { overwriteRejected = true; }
    need(overwriteRejected &&
        parseJSON(readText(reportPath))["schema"].str == "self-test",
        "report publication overwrote an existing path");

    auto attestationPath = buildPath(root, "build-attestation.json");
    enum digest40 = "0000000000000000000000000000000000000000";
    enum digest64 = "0000000000000000000000000000000000000000000000000000000000000000";
    auto attestationReport = JSONValue([
        "source_binary_mapping": JSONValue("ATTESTED"),
        "binary_sha256": JSONValue(trueDigest),
        "build_attestation": JSONValue([
            "schema": JSONValue("scrubbed-build-attestation-v4"),
            "target_sha256": JSONValue(trueDigest),
            "source_status": JSONValue("clean-before-and-after"),
            "build_status": JSONValue(0),
            "compiler_executable_name": JSONValue("ldc2"),
            "compiler_version": JSONValue("self-test"),
            "build_flags": JSONValue(
                "release; force; non-interactive; cache=local"),
            "source_sha": JSONValue(digest40),
            "source_tree_id": JSONValue(digest40),
            "source_archive_sha256": JSONValue(digest64),
            "dub_recipe_sha256": JSONValue(digest64),
            "dependency_lock_sha256": JSONValue(digest64),
            "compiler_executable_sha256": JSONValue(digest64),
            "dub_executable_sha256": JSONValue(digest64)])]);
    write(attestationPath, attestationReport.toString);
    loadBuildAttestation(attestationPath, trueDigest);
    attestationReport["build_attestation"]["target_sha256"] = digest64;
    write(attestationPath, attestationReport.toString);
    bool mismatchedAttestationRejected;
    try loadBuildAttestation(attestationPath, trueDigest);
    catch (Exception) { mismatchedAttestationRejected = true; }
    need(mismatchedAttestationRejected,
        "mismatched source-to-binary attestation was accepted");
    writeln("coordination profile self-test: ok");
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

private bool pairedMedianWithinFivePercent(JSONValue[] baseline,
        JSONValue[] candidate, size_t threads, string field) {
    long[] ratiosBasisPoints;
    foreach (round; 0 .. runs) {
        auto base = sampleValue(baseline, threads, round, field);
        auto changed = sampleValue(candidate, threads, round, field);
        need(base > 0, "comparison control baseline must be positive");
        ratiosBasisPoints ~= changed * 10_000 / base;
    }
    ratiosBasisPoints.sort();
    return ratiosBasisPoints[runs / 2] <= 10_500;
}

private void runComparison(string[] args) {
    auto baseline = absolutePath(args[2]);
    auto baselineAttestationPath = absolutePath(args[3]);
    auto candidate = absolutePath(args[4]);
    auto candidateAttestationPath = absolutePath(args[5]);
    auto reportPath = absolutePath(args[6]);
    need(exists(baseline) && exists(candidate) &&
        exists(baselineAttestationPath) && exists(candidateAttestationPath) &&
        !exists(reportPath),
        "comparison binary/attestation missing or report exists");
    need(tableIdentity() == fixtureTablePin, "fixture table pin differs");
    auto root = privateScratch("scrubbed-coordination-compare-");
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto baselineSnapshot = snapshotExecutable(baseline, root, "baseline");
    auto candidateSnapshot = snapshotExecutable(candidate, root, "candidate");
    auto baselineAttestation = loadBuildAttestation(
        baselineAttestationPath, baselineSnapshot.digest);
    auto candidateAttestation = loadBuildAttestation(
        candidateAttestationPath, candidateSnapshot.digest);
    auto baselineAttestationDigest = fileDigest(baselineAttestationPath);
    auto candidateAttestationDigest = fileDigest(candidateAttestationPath);
    baseline = baselineSnapshot.path;
    candidate = candidateSnapshot.path;
    auto harnessDigest = fileDigest(absolutePath(args[0]));
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
                    round, root, false, isCandidate ?
                        candidateSnapshot.digest : baselineSnapshot.digest);
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
                    controlsPass = controlsPass && pairedMedianWithinFivePercent(
                        baselineSamples, candidateSamples, threads, field);
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
                root, true, isCandidate ?
                    candidateSnapshot.digest : baselineSnapshot.digest);
            validateMetrics(sample, layout.files, inputId.bytes);
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
        "schema": JSONValue("scrubbed.coordination-scheduler-comparison.v2"),
        "version": JSONValue(2),
        "host_os": JSONValue(commandOutput(["uname", "-s"])),
        "host_architecture": JSONValue(commandOutput(["uname", "-m"])),
        "host_cpu": JSONValue(commandOutput(
            ["sysctl", "-n", "machdep.cpu.brand_string"])),
        "baseline_binary_sha256": JSONValue(baselineSnapshot.digest),
        "candidate_binary_sha256": JSONValue(candidateSnapshot.digest),
        "baseline_attestation_report_sha256": JSONValue(
            baselineAttestationDigest),
        "candidate_attestation_report_sha256": JSONValue(
            candidateAttestationDigest),
        "baseline_build_attestation": baselineAttestation,
        "candidate_build_attestation": candidateAttestation,
        "source_binary_mapping": JSONValue("ATTESTED"),
        "harness_sha256": JSONValue(harnessDigest),
        "fixture_table_sha256": JSONValue(fixtureTablePin),
        "config_sha256": JSONValue(configPin),
        "cache_semantics": JSONValue("application-cold; OS cache uncontrolled"),
        "control_method": JSONValue(
            "median paired candidate-to-baseline ratio <= 1.05"),
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
    verifySnapshot(baselineSnapshot);
    verifySnapshot(candidateSnapshot);
    need(fileDigest(baselineAttestationPath) == baselineAttestationDigest &&
        fileDigest(candidateAttestationPath) == candidateAttestationDigest,
        "build attestation report changed during benchmark");
    publishReport(reportPath, text);
    writeln("coordination comparison: wrote ", reportPath);
}

private void runDisabledMetricsOverhead(string[] args) {
    auto baseline = absolutePath(args[2]);
    auto candidate = absolutePath(args[3]);
    auto reportPath = absolutePath(args[4]);
    need(exists(baseline) && exists(candidate) && !exists(reportPath),
        "overhead binary missing or report exists");
    need(tableIdentity() == fixtureTablePin, "fixture table pin differs");
    auto root = privateScratch("scrubbed-coordination-overhead-");
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto baselineSnapshot = snapshotExecutable(baseline, root, "baseline");
    auto candidateSnapshot = snapshotExecutable(candidate, root, "candidate");
    baseline = baselineSnapshot.path;
    candidate = candidateSnapshot.path;
    auto harnessDigest = fileDigest(absolutePath(args[0]));
    auto config = buildPath(root, "mixed-v3.json");
    write(config, configText());
    need(fileDigest(config) == configPin, "config pin differs");
    auto layout = layouts[0];
    auto input = buildPath(root, layout.name ~ "-input");
    makeFixture(input, layout);
    auto inputId = identify(input);
    need(inputId.tree == inputTreePins[layout.name], "input tree pin differs");
    JSONValue[] baselineSamples, candidateSamples;
    foreach (round; 0 .. runs) foreach (threads; [1, 4])
    foreach (candidateFirst; [round % 2 == 1, round % 2 == 0]) {
        auto isCandidate = candidateFirst;
        auto binary = isCandidate ? candidate : baseline;
        auto output = buildPath(root, (isCandidate ? "candidate-" : "baseline-") ~
            threads.to!string ~ "-" ~ round.to!string);
        auto sample = invoke(binary, input, output, config, threads,
            round, root, false, isCandidate ?
                candidateSnapshot.digest : baselineSnapshot.digest);
        auto outputId = identify(output);
        need(outputId.tree == outputTreePins[layout.name],
            "overhead exact output tree pin differs");
        sample["output_bytes"] = cast(long)outputId.bytes;
        sample["output_tree_sha256"] = outputId.tree;
        if (isCandidate) candidateSamples ~= sample;
        else baselineSamples ~= sample;
        rmdirRecurse(output);
    }
    bool accepted = true;
    foreach (threads; [1, 4]) foreach (field;
            ["wall_us", "cpu_us", "peak_rss_bytes", "sampled_fd_peak"])
        accepted = accepted && pairedMedianWithinFivePercent(
            baselineSamples, candidateSamples, threads, field);
    auto report = JSONValue([
        "schema": JSONValue("scrubbed.coordination-disabled-overhead.v1"),
        "host_os": JSONValue(commandOutput(["uname", "-s"])),
        "host_architecture": JSONValue(commandOutput(["uname", "-m"])),
        "host_cpu": JSONValue(commandOutput(
            ["sysctl", "-n", "machdep.cpu.brand_string"])),
        "baseline_binary_sha256": JSONValue(baselineSnapshot.digest),
        "candidate_binary_sha256": JSONValue(candidateSnapshot.digest),
        "harness_sha256": JSONValue(harnessDigest),
        "fixture_table_sha256": JSONValue(fixtureTablePin),
        "config_sha256": JSONValue(configPin),
        "cache_semantics": JSONValue("application-cold; OS cache uncontrolled"),
        "control_method": JSONValue(
            "median paired candidate-to-baseline ratio <= 1.05"),
        "metrics_environment": JSONValue("absent for every child"),
        "disabled_metrics_overhead_accepted": JSONValue(accepted),
        "baseline_samples": JSONValue(baselineSamples),
        "candidate_samples": JSONValue(candidateSamples)]);
    auto text = report.toString;
    need(!text.canFind(root), "overhead report leaked temporary path");
    parseJSON(text);
    verifySnapshot(baselineSnapshot);
    verifySnapshot(candidateSnapshot);
    publishReport(reportPath, text);
    writeln("coordination disabled-overhead: wrote ", reportPath);
}

private void runSizeOrder(string[] args) {
    auto binary = absolutePath(args[2]);
    auto reportPath = absolutePath(args[3]);
    need(exists(binary) && !exists(reportPath),
        "size-order binary missing or report exists");
    need(tableIdentity() == fixtureTablePin, "fixture table pin differs");
    auto root = privateScratch("scrubbed-size-order-");
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto binarySnapshot = snapshotExecutable(binary, root, "shipping");
    binary = binarySnapshot.path;
    auto harnessDigest = fileDigest(absolutePath(args[0]));
    auto config = buildPath(root, "mixed-v3.json");
    write(config, configText());
    need(fileDigest(config) == configPin, "config pin differs");
    static immutable variants = ["clustered-late", "largest-first",
        "seeded-distribution"];
    string[string] inputs;
    Tree[string] inputIds;
    JSONValue[][string] samples;
    string[string] expectedOutputTrees;
    ulong[string] expectedOutputBytes;
    foreach (variant; variants) {
        auto input = buildPath(root, variant ~ "-input");
        makeSizeOrderFixture(input, variant);
        inputs[variant] = input;
        inputIds[variant] = identify(input);
    }
    foreach (round; 0 .. runs) foreach (threads; [2, 4])
    foreach (offset; 0 .. variants.length) {
            auto variant = variants[(round + offset +
                (threads == 4 ? 1 : 0)) % variants.length];
            auto output = buildPath(root, variant ~ "-output-" ~
                threads.to!string ~ "-" ~ round.to!string);
            auto sample = invoke(binary, inputs[variant], output, config, threads,
                round, root, false, binarySnapshot.digest);
            auto outputId = identify(output);
            if ((variant in expectedOutputTrees) is null) {
                expectedOutputTrees[variant] = outputId.tree;
                expectedOutputBytes[variant] = outputId.bytes;
            }
            need(outputId.tree == expectedOutputTrees[variant],
                "size-order output tree differs between samples");
            need(outputId.bytes == expectedOutputBytes[variant],
                "size-order output byte count differs between samples");
            sample["output_bytes"] = cast(long)outputId.bytes;
            sample["output_tree_sha256"] = outputId.tree;
            sample["output_concatenated_sha256"] = outputId.concatenated;
            samples[variant] ~= sample;
            rmdirRecurse(output);
    }
    JSONValue[] variantReports;
    foreach (variant; variants) {
        variantReports ~= JSONValue([
            "variant": JSONValue(variant),
            "files": JSONValue(4096),
            "large_files": JSONValue(64),
            "input_bytes": JSONValue(cast(long)inputIds[variant].bytes),
            "input_tree_sha256": JSONValue(inputIds[variant].tree),
            "output_tree_sha256": JSONValue(expectedOutputTrees[variant]),
            "samples": JSONValue(samples[variant])]);
    }
    auto report = JSONValue([
        "schema": JSONValue("scrubbed.size-order-profile.v1"),
        "host_os": JSONValue(commandOutput(["uname", "-s"])),
        "host_architecture": JSONValue(commandOutput(["uname", "-m"])),
        "host_cpu": JSONValue(commandOutput(
            ["sysctl", "-n", "machdep.cpu.brand_string"])),
        "shipping_binary_sha256": JSONValue(binarySnapshot.digest),
        "harness_sha256": JSONValue(harnessDigest),
        "fixture_table_sha256": JSONValue(fixtureTablePin),
        "config_sha256": JSONValue(configPin),
        "cache_semantics": JSONValue("application-cold; OS cache uncontrolled"),
        "variants": JSONValue(variantReports)]);
    auto text = report.toString;
    need(!text.canFind(root), "size-order report leaked temporary path");
    parseJSON(text);
    verifySnapshot(binarySnapshot);
    publishReport(reportPath, text);
    writeln("size-order profile: wrote ", reportPath);
}

private void runAttribution(string[] args) {
    auto binary = absolutePath(args[1]);
    auto reportPath = absolutePath(args[2]);
    need(exists(binary) && !exists(reportPath), "binary missing or report exists");
    need(tableIdentity() == fixtureTablePin, "fixture table pin differs");
    auto root = privateScratch("scrubbed-coordination-");
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto binarySnapshot = snapshotExecutable(binary, root, "shipping");
    binary = binarySnapshot.path;
    auto harnessDigest = fileDigest(absolutePath(args[0]));
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
                root, instrumented, binarySnapshot.digest);
            auto outputId = identify(output);
            need(outputId.tree == outputTreePins[layout.name],
                "exact output tree pin differs");
            if (instrumented) {
                validateMetrics(sample, layout.files, inputId.bytes);
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
        "shipping_binary_sha256": JSONValue(binarySnapshot.digest),
        "harness_sha256": JSONValue(harnessDigest),
        "fixture_table_sha256": JSONValue(fixtureTablePin),
        "config_sha256": JSONValue(configPin),
        "cache_semantics": JSONValue("application-cold; OS cache uncontrolled"),
        "production_candidate_authorized": JSONValue(false),
        "decision": JSONValue("ATTRIBUTION_ONLY_NO_CANDIDATE"),
        "layouts": JSONValue(layoutReports)]);
    auto text = report.toString;
    need(!text.canFind(root), "report leaked temporary path");
    parseJSON(text);
    verifySnapshot(binarySnapshot);
    publishReport(reportPath, text);
    writeln("coordination profile: wrote ", reportPath);
}

void main(string[] args) {
    need(args.length == 2 || args.length == 3 || args.length == 4 ||
        args.length == 5 || args.length == 7,
        "usage: coordination_profile <release-binary> <report> | " ~
        "--compare <baseline-binary> <baseline-attestation-report> " ~
        "<candidate-binary> <candidate-attestation-report> <report> | " ~
        "--size-order <release-binary> <report> | " ~
        "--disabled-overhead <baseline-binary> <candidate-binary> <report> | " ~
        "--self-test");
    if (args.length == 2 && args[1] == "--self-test")
        runSelfTest(absolutePath(args[0]));
    else if (args.length == 5 && args[1] == "--disabled-overhead")
        runDisabledMetricsOverhead(args);
    else if (args.length == 4 && args[1] == "--size-order") runSizeOrder(args);
    else if (args.length == 7 && args[1] == "--compare") runComparison(args);
    else if (args.length == 3) runAttribution(args);
    else need(false, "arguments do not select a supported mode");
}
