/// Reproducible release-binary evidence for dispatch-v4 shipping overhead.
module experiments.dispatch_shipping.check;

import content.pieces : Content, ContentPiece;
import core.atomic : atomicLoad, atomicStore;
import core.memory : GC;
import core.stdc.errno : EINTR, errno;
import core.sys.posix.sys.resource : rusage;
import core.sys.posix.sys.wait : WEXITSTATUS, WIFEXITED;
import core.thread : Thread;
import core.time : msecs;
import domain.document : Document, OutputName, SourceLocator;
import effects.mapped_file : openMappedFile;
import extraction.contracts : DetectionOutcomeV1, DetectionResultV1,
    EvidenceKindV1, MediaEvidenceV1;
import extraction.plain_text : configureCorePlainTextV1,
    maxOutputBytesOptionV1;
import extraction.port : ExtractionInputV1, ExtractorOptionV1,
    ExtractorOptionsV1, SourceContentV1;
import std.algorithm.searching : canFind;
import std.algorithm.sorting : sort;
import std.array : appender, array, replicate;
import std.conv : to;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.digest : LetterCase, toHexString;
import std.digest.sha : SHA256, sha256Of;
import std.file : SpanMode, dirEntries, exists, getSize, mkdir, mkdirRecurse,
    read, readText, rmdirRecurse, tempDir, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : absolutePath, baseName, buildPath, relativePath;
import std.process : execute, spawnProcess;
import std.stdio : File, writeln;
import std.string : indexOf, replace, splitLines, startsWith;
import std.uuid : randomUUID;

extern (C) int wait4(int pid, int* status, int options, rusage* usage);

private enum schema = "scrubbed.dispatch-shipping-evidence.v1";
private enum evidenceVersion = 1;
private enum runsPerVariant = 3;
private enum detectorPrefixBytes = 4096;

private void need(bool condition, string message) {
    if (!condition) throw new Exception("dispatch shipping evidence: " ~ message);
}

private string hexDigest(const(ubyte)[] bytes) {
    return toHexString!(LetterCase.lower)(sha256Of(bytes)).idup;
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

private string[] regularFiles(string root) {
    string[] files;
    foreach (entry; dirEntries(root, SpanMode.depth, false))
        if (entry.isFile) files ~= entry.name;
    sort!((a, b) => relativePath(a, root) < relativePath(b, root))(files);
    return files;
}

private struct Digests {
    string tree;
    string concatenated;
    ulong bytes;
    size_t files;
}

private Digests digestTree(string root) {
    SHA256 tree, concatenated;
    auto files = regularFiles(root);
    ulong bytes;
    foreach (path; files) {
        auto relative = relativePath(path, root);
        auto content = cast(ubyte[])read(path);
        auto leaf = sha256Of(content);
        tree.put(cast(const(ubyte)[]) relative);
        tree.put([cast(ubyte) 0]);
        tree.put(leaf[]);
        tree.put([cast(ubyte) 0]);
        concatenated.put(content);
        bytes += content.length;
    }
    return Digests(
        toHexString!(LetterCase.lower)(tree.finish()).idup,
        toHexString!(LetterCase.lower)(concatenated.finish()).idup,
        bytes, files.length);
}

private bool treesEqual(string left, string right) {
    auto leftFiles = regularFiles(left);
    auto rightFiles = regularFiles(right);
    if (leftFiles.length != rightFiles.length) return false;
    foreach (index; 0 .. leftFiles.length) {
        if (relativePath(leftFiles[index], left) !=
                relativePath(rightFiles[index], right)) return false;
        if (read(leftFiles[index]) != read(rightFiles[index])) return false;
    }
    return true;
}

private void makeFixture(string root, size_t count, size_t bytesEach) {
    mkdirRecurse(root);
    foreach (index; 0 .. count) {
        auto bytes = new ubyte[bytesEach];
        bytes[] = cast(ubyte)('a' + index % 23);
        auto header = cast(const(ubyte)[])("record-" ~ index.to!string ~ "\r\n");
        bytes[0 .. header.length] = header;
        bytes[$ - 2] = '\r';
        bytes[$ - 1] = '\n';
        write(buildPath(root, "input-" ~ index.to!string ~ ".txt"), bytes);
    }
}

private ulong cpuMicros(const ref typeof(rusage.init.ru_utime) value) {
    return cast(ulong)value.tv_sec * 1_000_000UL +
        cast(ulong)value.tv_usec;
}

private ulong peakRss(const ref rusage usage) {
    version (OSX) return cast(ulong)usage.ru_opaque[0];
    else version (linux) return cast(ulong)usage.ru_maxrss * 1024;
    else static assert(0, "dispatch evidence requires Darwin or Linux");
}

private size_t fdCount() {
    version (OSX) return dirEntries("/dev/fd", SpanMode.shallow, false).array.length;
    else version (linux) return dirEntries("/proc/self/fd", SpanMode.shallow, false).array.length;
    else return 0;
}

private struct ProcessObservation {
    long wallUs;
    ulong userUs;
    ulong systemUs;
    ulong peakRssBytes;
    size_t fdBefore;
    size_t fdAfter;
    size_t childFdPeak;
}

private ProcessObservation runChild(string[] command, string stdoutPath,
        string stderrPath) {
    auto input = File("/dev/null", "rb");
    auto output = File(stdoutPath, "wb");
    auto diagnostics = File(stderrPath, "wb");
    auto before = fdCount();
    auto wall = StopWatch(AutoStart.yes);
    auto child = spawnProcess(command, input, output, diagnostics);
    input.close();
    output.close();
    diagnostics.close();
    shared bool stopped;
    shared size_t sampledPeak;
    auto sampler = new Thread({
        while (!atomicLoad(stopped)) {
            auto observed = execute(["/usr/sbin/lsof", "-p",
                child.processID.to!string]);
            if (observed.status == 0) {
                auto lines = observed.output.splitLines.length;
                auto count = lines > 0 ? lines - 1 : 0;
                auto prior = atomicLoad(sampledPeak);
                if (count > prior) atomicStore(sampledPeak, count);
            }
            Thread.sleep(20.msecs);
        }
    });
    sampler.start();
    int status;
    rusage usage;
    int waited;
    do waited = wait4(child.processID, &status, 0, &usage);
    while (waited < 0 && errno == EINTR);
    atomicStore(stopped, true);
    sampler.join();
    wall.stop();
    need(waited == child.processID && WIFEXITED(status) &&
        WEXITSTATUS(status) == 0,
        "shipping child failed: " ~ readText(stderrPath));
    return ProcessObservation(wall.peek.total!"usecs",
        cpuMicros(usage.ru_utime), cpuMicros(usage.ru_stime), peakRss(usage),
        before, fdCount(), atomicLoad(sampledPeak));
}

private struct Accounting {
    size_t records;
    ulong availableBytes;
    ulong inspectedBytes;
    ulong emittedSourceBytes;
}

private string jobIdentity(string log) {
    foreach (line; log.splitLines)
        if (line.startsWith("job: job:")) return line["job: ".length .. $];
    throw new Exception("dispatch shipping evidence: missing job identity");
}

private Accounting accounting(string log) {
    Accounting result;
    foreach (line; log.splitLines) {
        if (!line.startsWith("EXPLAIN\t{")) continue;
        auto record = parseJSON(line["EXPLAIN\t".length .. $]);
        need(record["schema"].str == "scrubbed.dispatch.v1",
            "unexpected dispatch record schema");
        ++result.records;
        result.availableBytes += record["accounting"]["available_bytes"].integer;
        result.inspectedBytes += record["accounting"]["bytes_inspected"].integer;
        if (auto provenance = "provenance" in record.object)
            result.emittedSourceBytes += (*provenance)["source_bytes"].integer;
    }
    return result;
}

private struct RunEvidence {
    string variant;
    size_t ordinal;
    ProcessObservation process;
    Accounting accounting;
    Digests output;
}

private RunEvidence runOne(string executable, string input, string output,
        string config, string variant, size_t ordinal, string scratch,
        bool explain) {
    auto stdoutPath = buildPath(scratch, variant ~ "-" ~ ordinal.to!string ~ ".out");
    auto stderrPath = buildPath(scratch, variant ~ "-" ~ ordinal.to!string ~ ".err");
    string[] command = [executable, "run", "--input", input, "--output", output,
        "--threads", "1", "--max-open-inputs", "1", "--max-queued-docs", "1",
        "--config", config];
    if (explain) command ~= "--explain";
    auto process = runChild(command, stdoutPath, stderrPath);
    auto log = readText(stdoutPath);
    auto observed = explain ? accounting(log) : Accounting.init;
    return RunEvidence(variant, ordinal, process, observed, digestTree(output));
}

private struct CopyEvidence {
    ulong sourceBytes;
    ulong gcAllocatedBytes;
    ulong retainedBytes;
    ulong secondWholePayloadCopyCountUpperBound;
}

private CopyEvidence mappedCopyEvidence(string path) {
    auto sourceBytes = getSize(path);
    auto owner = openMappedFile(path, sourceBytes);
    scope(exit) owner.close();
    auto content = new Content([ContentPiece.borrow(owner.view(0,
        cast(size_t)sourceBytes))]);
    auto detected = DetectionResultV1.detected(DetectionOutcomeV1.plainText,
        [MediaEvidenceV1(EvidenceKindV1.textualContent,
            DetectionOutcomeV1.plainText, "valid-utf8-text-prefix")],
        "dispatch-evidence:v1", null, detectorPrefixBytes,
        detectorPrefixBytes, cast(size_t)sourceBytes);
    ExtractorOptionsV1 options;
    options[maxOutputBytesOptionV1] = ExtractorOptionV1.integer(sourceBytes);
    auto configured = configureCorePlainTextV1(options);
    auto document = Document(SourceLocator("dispatch-evidence", "mapped", "1"),
        OutputName("probe.txt"));
    GC.collect();
    auto before = GC.allocatedInCurrentThread;
    auto text = configured(ExtractionInputV1(document,
        SourceContentV1.from(content), detected, "text", null));
    auto allocated = GC.allocatedInCurrentThread - before;
    need(text.content.size == sourceBytes,
        "mapped extractor did not retain the exact payload");
    need(allocated < sourceBytes * 2,
        "observable allocations permit a second whole-payload copy");
    owner.close();
    need(text.content.size == sourceBytes,
        "owned extraction did not outlive the mapping");
    return CopyEvidence(sourceBytes, allocated, text.content.size, 0);
}

private string v3Config() {
    return `{"version":3,"stages":[{"id":"clean","implementation":"text-transform",` ~
        `"options":{},"filters":[{"name":"normalize-line-endings","options":{}},` ~
        `{"name":"strip-control","options":{}}]}]}`;
}

private string v4Config() {
    return `{"version":4,"dispatch":{"detector":{"prefix-bytes":4096,` ~
        `"evidence-records":16,"warnings":8},"container":{"max-physical-bytes":33554432,` ~
        `"max-expanded-bytes":134217728,"max-entries":2048,"max-depth":2,` ~
        `"max-ratio":100},"routes":[{"name":"text","extractor":"core-plain-text",` ~
        `"options":{"max-output-bytes":268435456}}],"actions":[` ~
        `{"outcome":"unknown","action":"reject","reason":"unsupported"},` ~
        `{"outcome":"plain-text","action":"route","route":"text"},` ~
        `{"outcome":"html","action":"reject","reason":"unsupported"},` ~
        `{"outcome":"pdf","action":"reject","reason":"unsupported"},` ~
        `{"outcome":"png","action":"reject","reason":"unsupported"},` ~
        `{"outcome":"jpeg","action":"reject","reason":"unsupported"},` ~
        `{"outcome":"gif","action":"reject","reason":"unsupported"},` ~
        `{"outcome":"ambiguous","action":"reject","reason":"unsupported"},` ~
        `{"outcome":"malformed","action":"reject","reason":"unsupported"},` ~
        `{"outcome":"encrypted","action":"reject","reason":"unsupported"},` ~
        `{"outcome":"unsupported","action":"reject","reason":"unsupported"},` ~
        `{"outcome":"generic-zip","action":"reject","reason":"unsupported"},` ~
        `{"outcome":"ooxml-word","action":"reject","reason":"unsupported"}]},` ~
        `"common":` ~ v3Config ~ `}`;
}

private string q(string value) { return JSONValue(value).toString; }

private string runJson(ref const RunEvidence run) {
    return `{"variant":` ~ q(run.variant) ~ `,"ordinal":` ~ run.ordinal.to!string ~
        `,"wall_us":` ~ run.process.wallUs.to!string ~
        `,"user_cpu_us":` ~ run.process.userUs.to!string ~
        `,"system_cpu_us":` ~ run.process.systemUs.to!string ~
        `,"peak_rss_bytes":` ~ run.process.peakRssBytes.to!string ~
        `,"fd_before":` ~ run.process.fdBefore.to!string ~
        `,"fd_after":` ~ run.process.fdAfter.to!string ~
        `,"child_fd_peak":` ~ run.process.childFdPeak.to!string ~
        `,"dispatch_records":` ~ run.accounting.records.to!string ~
        `,"available_bytes":` ~ run.accounting.availableBytes.to!string ~
        `,"inspected_bytes":` ~ run.accounting.inspectedBytes.to!string ~
        `,"emitted_source_bytes":` ~ run.accounting.emittedSourceBytes.to!string ~
        `,"output_bytes":` ~ run.output.bytes.to!string ~
        `,"output_files":` ~ run.output.files.to!string ~
        `,"tree_sha256":` ~ q(run.output.tree) ~
        `,"concatenated_sha256":` ~ q(run.output.concatenated) ~ `}`;
}

private struct FixtureEvidence {
    string label;
    size_t count;
    size_t bytesEach;
    Digests input;
    string v3Identity;
    string v4Identity;
    RunEvidence[] runs;
}

private string fixtureJson(ref const FixtureEvidence fixture) {
    auto output = appender!string;
    output.put(`{"label":`); output.put(q(fixture.label));
    output.put(`,"documents":`); output.put(fixture.count.to!string);
    output.put(`,"bytes_each":`); output.put(fixture.bytesEach.to!string);
    output.put(`,"input_bytes":`); output.put(fixture.input.bytes.to!string);
    output.put(`,"input_tree_sha256":`); output.put(q(fixture.input.tree));
    output.put(`,"input_concatenated_sha256":`);
    output.put(q(fixture.input.concatenated));
    output.put(`,"v3_identity":`); output.put(q(fixture.v3Identity));
    output.put(`,"v4_identity":`); output.put(q(fixture.v4Identity));
    output.put(`,"accounting_deltas_vs_v3":{"detection_records":`);
    output.put(fixture.count.to!string);
    output.put(`,"inspection_bytes":`);
    output.put((cast(ulong)fixture.count * detectorPrefixBytes).to!string);
    output.put(`,"emission_bytes":0,"owned_extraction_bytes":`);
    output.put(fixture.input.bytes.to!string);
    output.put(`}`);
    output.put(`,"runs":[`);
    foreach (index, ref run; fixture.runs) {
        if (index) output.put(',');
        output.put(runJson(run));
    }
    output.put(`]}`);
    return output.data;
}

private void needKeys(ref JSONValue value, string[] expected, string label) {
    need(value.type == JSONType.object, label ~ " must be an object");
    auto actual = value.object.keys.array;
    actual.sort;
    expected.sort;
    need(actual == expected, label ~ " has an inexact schema");
}

private void validateEvidence(string text, string binaryHash,
        string v3Hash, string v4Hash) {
    auto root = parseJSON(text);
    needKeys(root, ["copy_accounting", "fixtures", "method", "schema",
        "shipping_binary_sha256", "v3_config_sha256", "v4_config_sha256",
        "version"], "evidence root");
    need(root.type == JSONType.object && root["schema"].str == schema &&
        root["version"].integer == evidenceVersion,
        "evidence schema/version mismatch");
    need(root["shipping_binary_sha256"].str == binaryHash,
        "stale or foreign shipping binary evidence");
    need(root["v3_config_sha256"].str == v3Hash &&
        root["v4_config_sha256"].str == v4Hash,
        "stale or foreign config evidence");
    need(root["fixtures"].array.length == 2,
        "evidence fixture cardinality mismatch");
    auto method = root["method"];
    needKeys(method, ["build", "claim", "runs_per_variant", "schedule",
        "speed_threshold", "warmups"], "method");
    need(method["build"].str == "O3-release" &&
        method["warmups"].integer == 1 &&
        method["runs_per_variant"].integer == runsPerVariant &&
        method["schedule"].str == "interleaved" &&
        method["speed_threshold"].type == JSONType.null_ &&
        method["claim"].str == "descriptive-only", "method mismatch");
    auto copies = root["copy_accounting"];
    needKeys(copies, ["extractor_gc_allocated_bytes", "mapped_source_bytes",
        "nonpayload_gc_allocation_bytes", "retained_output_bytes",
        "second_whole_payload_copy_count_upper_bound"], "copy accounting");
    need(copies["mapped_source_bytes"].integer ==
            copies["retained_output_bytes"].integer &&
        copies["extractor_gc_allocated_bytes"].integer <
            copies["mapped_source_bytes"].integer * 2 &&
        copies["nonpayload_gc_allocation_bytes"].integer ==
            copies["extractor_gc_allocated_bytes"].integer -
            copies["mapped_source_bytes"].integer &&
        copies["second_whole_payload_copy_count_upper_bound"].integer == 0,
        "copy-accounting invariant mismatch");
    foreach (fixture; root["fixtures"].array) {
        needKeys(fixture, ["accounting_deltas_vs_v3", "bytes_each",
            "documents", "input_bytes", "input_concatenated_sha256",
            "input_tree_sha256", "label", "runs", "v3_identity",
            "v4_identity"], "fixture");
        need(fixture["v3_identity"].str == "job:v3:" ~ v3Hash &&
            fixture["v4_identity"].str == "job:v4:" ~ v4Hash,
            "job identity mismatch");
        auto deltas = fixture["accounting_deltas_vs_v3"];
        needKeys(deltas, ["detection_records", "emission_bytes",
            "inspection_bytes", "owned_extraction_bytes"],
            "accounting deltas");
        need(deltas["detection_records"].integer == fixture["documents"].integer &&
            deltas["inspection_bytes"].integer ==
                fixture["documents"].integer * detectorPrefixBytes &&
            deltas["emission_bytes"].integer == 0 &&
            deltas["owned_extraction_bytes"].integer ==
                fixture["input_bytes"].integer,
            "accounting delta mismatch");
        need(fixture["runs"].array.length == runsPerVariant * 2,
            "evidence run cardinality mismatch");
        auto tree = fixture["runs"].array[0]["tree_sha256"].str;
        auto concatenated = fixture["runs"].array[0]["concatenated_sha256"].str;
        size_t v3Runs, v4Runs;
        foreach (run; fixture["runs"].array) {
            needKeys(run, ["available_bytes", "child_fd_peak",
                "concatenated_sha256", "dispatch_records",
                "emitted_source_bytes", "fd_after", "fd_before",
                "inspected_bytes", "ordinal", "output_bytes", "output_files",
                "peak_rss_bytes", "system_cpu_us", "tree_sha256",
                "user_cpu_us", "variant", "wall_us"],
                "run");
            need(run["tree_sha256"].str == tree &&
                run["concatenated_sha256"].str == concatenated,
                "evidence contains divergent exact outputs");
            if (run["variant"].str == "v3") ++v3Runs;
            else if (run["variant"].str == "v4") ++v4Runs;
            else need(false, "unknown run variant");
        }
        need(v3Runs == runsPerVariant && v4Runs == runsPerVariant,
            "variant run cardinality mismatch");
    }
}

private void expectedFailure(scope void delegate() operation, string label) {
    try { operation(); }
    catch (Exception) { return; }
    throw new Exception("dispatch shipping evidence: negative accepted: " ~ label);
}

private string replaceFirst(string value, string needle, string replacement) {
    auto offset = value.indexOf(needle);
    need(offset >= 0, "negative fixture token is absent");
    return value[0 .. offset] ~ replacement ~ value[offset + needle.length .. $];
}

private FixtureEvidence observeFixture(string executable, string root,
        string label, size_t count, size_t bytesEach, string v3Path,
        string v4Path) {
    auto input = buildPath(root, label ~ "-input");
    makeFixture(input, count, bytesEach);
    auto inputDigest = digestTree(input);

    // Full-fixture warmups precede all three measured interleaved pairs.
    foreach (variant, config; ["v3": v3Path, "v4": v4Path]) {
        auto warmOutput = buildPath(root, label ~ "-warm-" ~ variant);
        auto warm = runOne(executable, input, warmOutput, config, variant, 99,
            root, variant == "v4");
        need(warm.output.files == count, "warmup output cardinality mismatch");
        rmdirRecurse(warmOutput);
    }

    RunEvidence[] runs;
    string v3Identity, v4Identity;
    foreach (round; 0 .. runsPerVariant) {
        auto order = round % 2 == 0 ? ["v3", "v4"] : ["v4", "v3"];
        foreach (variant; order) {
            auto output = buildPath(root, label ~ "-" ~ variant ~ "-" ~ round.to!string);
            auto run = runOne(executable, input, output,
                variant == "v3" ? v3Path : v4Path, variant, round, root,
                variant == "v4");
            auto log = readText(buildPath(root,
                variant ~ "-" ~ round.to!string ~ ".out"));
            if (variant == "v3") v3Identity = jobIdentity(log);
            else v4Identity = jobIdentity(log);
            need(run.output.files == count, "measured output cardinality mismatch");
            if (variant == "v4") {
                need(run.accounting.records == count,
                    "dispatch record cardinality mismatch");
                need(run.accounting.inspectedBytes ==
                    cast(ulong)count * detectorPrefixBytes,
                    "detector inspection accounting exceeded prefix bound");
                need(run.accounting.availableBytes == inputDigest.bytes &&
                    run.accounting.emittedSourceBytes == inputDigest.bytes,
                    "dispatch source/emission accounting mismatch");
            }
            runs ~= run;
        }
        auto v3Output = buildPath(root, label ~ "-v3-" ~ round.to!string);
        auto v4Output = buildPath(root, label ~ "-v4-" ~ round.to!string);
        need(treesEqual(v3Output, v4Output),
            "v3/v4 exact output mismatch");
        auto altered = buildPath(v4Output, baseName(regularFiles(v4Output)[0]));
        auto original = cast(ubyte[])read(altered);
        auto changed = original.dup;
        changed[0] ^= 1;
        write(altered, changed);
        need(!treesEqual(v3Output, v4Output),
            "deliberate exact-output mismatch was not detected");
        write(altered, original);
        need(treesEqual(v3Output, v4Output),
            "exact output did not recover after mismatch control");
    }
    return FixtureEvidence(label, count, bytesEach, inputDigest,
        v3Identity, v4Identity, runs);
}

void main(string[] args) {
    need(args.length == 3,
        "usage: check <O3 release shipping executable> <evidence.json>");
    auto executable = absolutePath(args[1]);
    need(exists(executable), "shipping executable is missing");
    auto evidencePath = absolutePath(args[2]);
    need(!exists(evidencePath), "evidence destination already exists");
    auto root = buildPath(tempDir, "scrubbed-dispatch-shipping-" ~
        randomUUID.toString);
    mkdir(root);
    scope(exit) if (exists(root)) rmdirRecurse(root);

    auto v3 = v3Config;
    auto v4 = v4Config;
    auto v3Path = buildPath(root, "v3.json");
    auto v4Path = buildPath(root, "v4.json");
    write(v3Path, v3);
    write(v4Path, v4);
    auto binaryHash = fileDigest(executable);
    auto v3Hash = hexDigest(cast(const(ubyte)[])v3);
    auto v4Hash = hexDigest(cast(const(ubyte)[])v4);

    FixtureEvidence[] fixtures;
    fixtures ~= observeFixture(executable, root, "many-small", 4096,
        8 * 1024, v3Path, v4Path);
    fixtures ~= observeFixture(executable, root, "few-large", 8,
        4 * 1024 * 1024, v3Path, v4Path);
    auto probePath = buildPath(root, "few-large-input", "input-0.txt");
    auto copies = mappedCopyEvidence(probePath);

    auto output = appender!string;
    output.put(`{"schema":`); output.put(q(schema));
    output.put(`,"version":1,"shipping_binary_sha256":`);
    output.put(q(binaryHash));
    output.put(`,"v3_config_sha256":`); output.put(q(v3Hash));
    output.put(`,"v4_config_sha256":`); output.put(q(v4Hash));
    output.put(`,"method":{"build":"O3-release","warmups":1,` ~
        `"runs_per_variant":3,"schedule":"interleaved",` ~
        `"speed_threshold":null,"claim":"descriptive-only"}`);
    output.put(`,"copy_accounting":{"mapped_source_bytes":`);
    output.put(copies.sourceBytes.to!string);
    output.put(`,"extractor_gc_allocated_bytes":`);
    output.put(copies.gcAllocatedBytes.to!string);
    output.put(`,"retained_output_bytes":`);
    output.put(copies.retainedBytes.to!string);
    output.put(`,"second_whole_payload_copy_count_upper_bound":0,` ~
        `"nonpayload_gc_allocation_bytes":`);
    output.put((copies.gcAllocatedBytes - copies.sourceBytes).to!string);
    output.put(`}`);
    output.put(`,"fixtures":[`);
    foreach (index, ref fixture; fixtures) {
        if (index) output.put(',');
        output.put(fixtureJson(fixture));
    }
    output.put(`]}`);
    auto evidence = output.data;
    need(!evidence.canFind(root), "evidence leaked temporary paths");
    validateEvidence(evidence, binaryHash, v3Hash, v4Hash);
    write(evidencePath, evidence ~ "\n");
    auto reopened = readText(evidencePath);
    need(reopened == evidence ~ "\n", "evidence reopen changed bytes");
    validateEvidence(reopened, binaryHash, v3Hash, v4Hash);

    expectedFailure(() => validateEvidence(reopened, "0".replicate(64),
        v3Hash, v4Hash), "binary digest");
    expectedFailure(() => validateEvidence(reopened, binaryHash,
        "0".replicate(64), v4Hash), "config digest");
    expectedFailure(() => validateEvidence(reopened.replace(schema,
        "scrubbed.dispatch-shipping-evidence.v0"), binaryHash, v3Hash, v4Hash),
        "schema identity");
    expectedFailure(() => validateEvidence(replaceFirst(reopened,
        `"version":1`, `"version":2`), binaryHash, v3Hash, v4Hash),
        "schema version");
    expectedFailure(() => validateEvidence(replaceFirst(reopened,
        `"version":1`, `"version":1,"foreign":true`), binaryHash, v3Hash,
        v4Hash), "exact schema");
    expectedFailure(() => validateEvidence(replaceFirst(reopened,
        "job:v4:" ~ v4Hash, "job:v4:" ~ "e".replicate(64)), binaryHash,
        v3Hash, v4Hash), "job identity");
    auto stale = replaceFirst(reopened, fixtures[0].runs[0].output.tree,
        "f".replicate(64));
    expectedFailure(() => validateEvidence(stale, binaryHash, v3Hash, v4Hash),
        "stale output digest");

    writeln("dispatch shipping evidence: wrote ", evidencePath);
    writeln("dispatch shipping evidence: copy probe source_bytes=",
        copies.sourceBytes, " allocated_bytes=", copies.gcAllocatedBytes,
        " second_whole_payload_copy_count_upper_bound=0");
}
