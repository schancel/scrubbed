/// Release-active equivalence, dispatch, and evidence harness for #185.
module sha256_backend_check;

import crypto.sha256 : Sha256, Sha256Backend, selectedSha256Backend,
    sha256BackendAvailable, sha256BackendName;
import core.thread : Thread;
import std.algorithm.searching : count;
import std.array : array, split;
import std.conv : to;
import std.datetime.stopwatch : StopWatch, AutoStart;
import std.digest : LetterCase, toHexString;
import std.digest.sha : SHA256, sha256Of;
import std.exception : enforce;
import std.file : dirEntries, isFile, read, readText, rmdirRecurse, SpanMode,
    thisExePath, write;
import std.json : JSONOptions, JSONValue, parseJSON;
import std.math : isFinite;
import std.path : buildPath;
import std.process : execute;
import std.random : MinstdRand0;
import std.stdio : writeln;
import std.string : indexOf, join, strip;
import std.uuid : randomUUID;

version (LDC) {} else static assert(false, "SHA-256 evidence requires LDC");
version (Sha256BackendO3Release) {} else
    static assert(false, "SHA-256 evidence requires the O3/release build marker");
version (assert) static assert(false, "SHA-256 evidence must be compiled with -release");
static assert(__VERSION__ == 2113, "SHA-256 evidence frontend version drift");

private enum expectedCompiler = "LDC - the LLVM D compiler (1.43.0):";
private enum buildRecipe = "ldc2 -O3 -release -d-version=Sha256BackendO3Release " ~
    "-Isource benchmarks/sha256_backend_check.d source/crypto/sha256.d " ~
    "source/crypto/sha256_arm64.d source/crypto/sha256_x86_64.d " ~
    "-of=/tmp/scrubbed-sha256-backend-check";

private struct InventoryEntry { string path; size_t occurrences; }
private immutable InventoryEntry[] expectedInventory = [
    InventoryEntry("source/cli.d", 3),
    InventoryEntry("source/domain/document.d", 3),
    InventoryEntry("source/domain/exact_dedup.d", 3),
    InventoryEntry("source/domain/mix_policy.d", 2),
    InventoryEntry("source/domain/quality_features.d", 3),
    InventoryEntry("source/domain/shard_format.d", 5),
    InventoryEntry("source/domain/source_rights.d", 2),
    InventoryEntry("source/domain/structured_chunks.d", 2),
    InventoryEntry("source/effects/dispatch_record.d", 4),
    InventoryEntry("source/effects/document_shards.d", 4),
    InventoryEntry("source/effects/durable_job.d", 12),
    InventoryEntry("source/effects/error_export.d", 4),
    InventoryEntry("source/effects/exact_dedup_overlay.d", 4),
    InventoryEntry("source/effects/independent_sinks.d", 2),
    InventoryEntry("source/effects/local_job.d", 2),
    InventoryEntry("source/effects/local_manifest.d", 6),
    InventoryEntry("source/effects/metadata_route_cli.d", 2),
    InventoryEntry("source/effects/mix_export.d", 8),
    InventoryEntry("source/effects/pii_policy_overlay.d", 2),
    InventoryEntry("source/job/dispatch_json.d", 2),
    InventoryEntry("source/job/json.d", 2),
];

private immutable string[] identityFixtures = [
    "doc:v1:489f01dcef5067959e03264b17467e6774c6b95e93bbbeb6cbb4784d15567a30",
    "child:v1:17f0922cd16212a59c775405caa7b62699118778b3de07c67870a4f4af5d5413",
    "job:v3:d901650f7a0633860298590a8b868363f1ee470f9325f046bd16a21c15593116",
];

private immutable string[] forbiddenShaBypasses = [
    "std.digest.sha",
    "crypto.sha256_arm64",
    "crypto.sha256_x86_64",
    "compressArmSha2",
    "armSha2Available",
    "compressX86ShaNi",
    "x86ShaNiAvailable",
];

private immutable string[] backendSourcePaths = [
    "source/crypto/sha256.d",
    "source/crypto/sha256_arm64.d",
    "source/crypto/sha256_x86_64.d",
    "benchmarks/sha256_backend_check.d",
];

private string hex(const ubyte[32] digest) {
    return toHexString!(LetterCase.lower)(digest).idup;
}

private ubyte[32] facadeDigest(const(ubyte)[] bytes, Sha256Backend backend,
        size_t[] chunks = null) {
    auto digest = Sha256.create(backend);
    if (chunks.length == 0) digest.put(bytes);
    else {
        size_t at, ordinal;
        while (at < bytes.length) {
            auto requested = chunks[ordinal++ % chunks.length];
            auto amount = requested < bytes.length - at ? requested : bytes.length - at;
            digest.put(bytes[at .. at + amount]);
            at += amount;
        }
    }
    return digest.finish;
}

private ubyte[] deterministicBytes(size_t length, uint seed) {
    auto random = MinstdRand0(seed);
    auto result = new ubyte[length];
    foreach (ref value; result) value = cast(ubyte)random.front, random.popFront;
    return result;
}

private bool identifierByte(char value) pure nothrow {
    return value >= 'a' && value <= 'z' || value >= 'A' && value <= 'Z' ||
        value >= '0' && value <= '9' || value == '_';
}

private size_t wordOccurrences(string source, string token) {
    size_t result, from;
    while (from < source.length) {
        auto relative = source[from .. $].indexOf(token);
        if (relative < 0) break;
        auto at = from + cast(size_t)relative;
        auto end = at + token.length;
        if ((at == 0 || !identifierByte(source[at - 1])) &&
                (end == source.length || !identifierByte(source[end])))
            ++result;
        from = end;
    }
    return result;
}

private size_t tokenOccurrences(string source) {
    return wordOccurrences(source, "Sha256") +
        wordOccurrences(source, "sha256Of");
}

private JSONValue inventoryEvidence() {
    bool[string] expected;
    JSONValue[] rows;
    size_t total;
    foreach (entry; expectedInventory) {
        expected[entry.path] = true;
        auto bytes = cast(ubyte[])read(entry.path);
        auto source = cast(string)bytes;
        auto occurrences = tokenOccurrences(source);
        enforce(occurrences == entry.occurrences,
            "production SHA-256 inventory count drift: " ~ entry.path);
        JSONValue row;
        row["path"] = entry.path;
        row["occurrences"] = cast(long)occurrences;
        row["source_sha256"] = hex(sha256Of(bytes));
        rows ~= row;
        total += occurrences;
    }
    foreach (entry; dirEntries("source", "*.d", SpanMode.depth, false)) {
        auto path = entry.name;
        auto source = cast(string)read(path);
        if (path != "source/crypto/sha256.d" &&
                path != "source/crypto/sha256_arm64.d" &&
                path != "source/crypto/sha256_x86_64.d") {
            foreach (token; forbiddenShaBypasses)
                enforce(source.indexOf(token) < 0,
                    "production SHA-256 facade bypass: " ~ path ~
                    " references " ~ token);
        }
        if (path.indexOf("source/crypto/") != 0 &&
                tokenOccurrences(source) != 0)
            enforce((path in expected) !is null,
                "new production SHA-256 caller is outside the frozen inventory: " ~ path);
    }
    enforce(total == 77 && rows.length == 21,
        "production SHA-256 inventory cardinality drift");
    JSONValue result;
    result["base"] = "cd15948466509055ae0431439f651ecba8a301f6";
    result["module_count"] = cast(long)rows.length;
    result["occurrence_count"] = cast(long)total;
    result["modules"] = rows;
    JSONValue[] fixtures;
    foreach (fixture; identityFixtures) fixtures ~= JSONValue(fixture);
    result["identity_fixtures"] = fixtures;
    return result;
}

private void checkKat(string input, string expected) {
    auto bytes = cast(const(ubyte)[])input;
    auto phobos = sha256Of(bytes);
    enforce(hex(phobos) == expected, "Phobos SHA-256 KAT mismatch");
    foreach (backend; [Sha256Backend.scalar, selectedSha256Backend]) {
        auto actual = facadeDigest(bytes, backend);
        enforce(actual == phobos, "facade SHA-256 KAT mismatch: " ~
            sha256BackendName(backend));
    }
}

private void checkVectors() {
    checkKat("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    checkKat("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    checkKat("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
    auto millionA = new char[1_000_000];
    millionA[] = 'a';
    checkKat(cast(string)millionA,
        "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");

    immutable size_t[] lengths = [0, 1, 2, 3, 7, 31, 55, 56, 57, 63, 64,
        65, 127, 128, 129, 1024, 8193];
    immutable size_t[] chunking = [1, 2, 3, 7, 13, 55, 56, 63, 64, 65, 127];
    foreach (length; lengths) {
        auto storage = deterministicBytes(length + 32, cast(uint)(length + 17));
        foreach (alignment; 0 .. 32) {
            auto bytes = storage[alignment .. alignment + length];
            auto oracle = sha256Of(bytes);
            foreach (backend; [Sha256Backend.scalar, selectedSha256Backend]) {
                enforce(facadeDigest(bytes, backend) == oracle,
                    "unaligned SHA-256 mismatch");
                enforce(facadeDigest(bytes, backend, chunking.dup) == oracle,
                    "chunked SHA-256 mismatch");
            }
        }
    }
}

private void checkLifecycle() {
    auto digest = Sha256.create(Sha256Backend.scalar);
    digest.put(cast(const(ubyte)[])"first");
    auto first = digest.finish;
    bool refused;
    try digest.finish;
    catch (Exception error) refused = error.msg == "SHA-256 facade is not active";
    enforce(refused, "finished SHA-256 accepted a second finish");
    digest.start;
    digest.put(cast(const(ubyte)[])"second");
    enforce(first == sha256Of(cast(const(ubyte)[])"first") &&
        digest.finish == sha256Of(cast(const(ubyte)[])"second"),
        "SHA-256 repeated start mismatch");

    foreach (backend; [Sha256Backend.armSha2, Sha256Backend.x86ShaNi]) {
        if (sha256BackendAvailable(backend)) continue;
        refused = false;
        try { auto unavailable = Sha256.create(backend); unavailable.start; }
        catch (Exception error) refused = error.msg == "SHA-256 backend unavailable: " ~
            sha256BackendName(backend);
        enforce(refused, "unsupported forced SHA-256 backend did not refuse");
    }
}

private void checkConcurrency() {
    enum workers = 8;
    ubyte[32][workers] actual;
    ubyte[32][workers] expected;
    final class Work {
        size_t ordinal;
        ubyte[] bytes;
        ubyte[32]* output;
        this(size_t ordinal, ubyte[] bytes, ubyte[32]* output) {
            this.ordinal = ordinal;
            this.bytes = bytes;
            this.output = output;
        }
        void run() {
            *output = facadeDigest(bytes, selectedSha256Backend,
                [1, 63, 2, 64, 3]);
        }
    }
    Thread[] threads;
    foreach (ordinal; 0 .. workers) {
        auto bytes = deterministicBytes(32_769 + ordinal * 17,
            cast(uint)(ordinal + 100));
        expected[ordinal] = sha256Of(bytes);
        auto work = new Work(ordinal, bytes, &actual[ordinal]);
        threads ~= new Thread(&work.run);
    }
    foreach (thread; threads) thread.start;
    foreach (thread; threads) thread.join;
    enforce(actual == expected, "concurrent SHA-256 instances interfered");
}

private void checkSystemOracle() {
    auto root = buildPath("/tmp", "scrubbed-sha256-oracle-" ~ randomUUID.toString);
    import std.file : mkdir;
    mkdir(root);
    scope(exit) rmdirRecurse(root);
    auto path = buildPath(root, "fixture.bin");
    auto bytes = deterministicBytes(131_089, 0x185);
    write(path, bytes);
    auto result = execute(["/usr/bin/shasum", "-a", "256", path]);
    enforce(result.status == 0, "system SHA-256 oracle failed");
    auto fields = result.output.strip.split;
    enforce(fields.length >= 1 && fields[0] == hex(facadeDigest(bytes,
        selectedSha256Backend)), "system SHA-256 oracle mismatch");
}

private void selfTest() {
    auto compiler = execute(["ldc2", "--version"]);
    enforce(compiler.status == 0 && compiler.output.split("\n")[0] ==
        expectedCompiler, "LDC compiler identity drift");
    enforce(selectedSha256Backend != Sha256Backend.automatic,
        "automatic SHA-256 selection was not resolved");
    inventoryEvidence;
    checkVectors;
    checkLifecycle;
    checkConcurrency;
    checkSystemOracle;
    writeln("sha256 backend self-test passed: inventory, KATs, chunks, " ~
        "alignments, lifecycle, concurrency, system oracle; selected=" ~
        sha256BackendName(selectedSha256Backend));
}

private void longTest() {
    enum chunkBytes = 1024 * 1024;
    enum iterations = 4097;
    auto chunk = deterministicBytes(chunkBytes, 0x185185);
    auto selected = Sha256.create(selectedSha256Backend);
    SHA256 oracle;
    foreach (_; 0 .. iterations) {
        selected.put(chunk);
        oracle.put(chunk);
    }
    auto tail = cast(const(ubyte)[])"multi-gib-tail-185";
    selected.put(tail); oracle.put(tail);
    enforce(selected.finish == oracle.finish,
        "multi-GiB logical SHA-256 mismatch");
    writeln("sha256 multi-GiB logical test passed: ",
        cast(ulong)chunkBytes * iterations + tail.length, " bytes");
}

private void writeNativeReport(string path) {
    selfTest;
    auto os = commandValue(["/usr/bin/uname", "-s"], "operating system");
    auto release = commandValue(["/usr/bin/uname", "-r"], "OS release");
    auto architecture = commandValue(["/usr/bin/uname", "-m"], "architecture");
    string expectedBackend;
    version (AArch64) {
        enforce(architecture == "aarch64" || architecture == "arm64",
            "native ARM runner architecture mismatch");
        enforce(sha256BackendAvailable(Sha256Backend.armSha2),
            "native ARM runner does not expose SHA2");
        expectedBackend = "armv8-sha2";
    } else version (X86_64) {
        enforce(architecture == "x86_64",
            "native x86 runner architecture mismatch");
        enforce(sha256BackendAvailable(Sha256Backend.x86ShaNi),
            "native x86 runner does not expose SHA-NI");
        expectedBackend = "x86-sha-ni";
    } else static assert(false, "unsupported native SHA-256 evidence architecture");
    enforce(sha256BackendName(selectedSha256Backend) == expectedBackend,
        "automatic SHA-256 backend did not select native hardware");
    JSONValue report;
    report["schema"] = "scrubbed-sha256-native-backend-v2";
    report["os"] = os;
    report["os_release"] = release;
    report["architecture"] = architecture;
    report["selected_backend"] = expectedBackend;
    report["hardware_execution"] = "SUPPORTED_AND_PASSED";
    report["compiler"] = expectedCompiler;
    report["frontend"] = cast(long)__VERSION__;
    report["harness_binary_sha256"] = sourceHash(thisExePath);
    JSONValue sources;
    foreach (source; backendSourcePaths)
        sources[source] = sourceHash(source);
    report["source_sha256"] = sources;
    immutable size_t[10] crossoverSizes =
        [32, 55, 56, 63, 64, 65, 128, 256, 512, 1024];
    report["short_message_microbench"] = benchmarkRows(crossoverSizes[]);
    report["microbench_claim"] =
        "descriptive crossover evidence; hosted runner frequency uncontrolled";
    write(path, report.toString(JSONOptions.doNotEscapeSlashes));
    validateNativeReport(path);
    writeln("wrote native SHA-256 evidence: ", path);
}

private struct BenchmarkRow {
    string role;
    string backend;
    size_t sample;
    size_t bytes;
    size_t iterations;
    double seconds;
    string digest;
}

private BenchmarkRow benchmark(size_t bytes, Sha256Backend backend,
        size_t sample, string role) {
    auto input = deterministicBytes(bytes, cast(uint)(bytes + 185));
    auto iterations = cast(size_t)((32UL * 1024 * 1024) / bytes);
    if (iterations == 0) iterations = 1;
    ubyte[32] consumed;
    StopWatch watch = StopWatch(AutoStart.yes);
    foreach (_; 0 .. iterations) consumed = facadeDigest(input, backend);
    watch.stop;
    return BenchmarkRow(role, sha256BackendName(backend), sample, bytes, iterations,
        watch.peek.total!"nsecs" / 1_000_000_000.0, hex(consumed));
}

private JSONValue[] benchmarkRows(const(size_t)[] sizes) {
    JSONValue[] rows;
    foreach (bytes; sizes) {
        foreach (sample; 0 .. 5) foreach (pairOrdinal, backend;
                sample % 2 == 0
                    ? [Sha256Backend.scalar, selectedSha256Backend]
                    : [selectedSha256Backend, Sha256Backend.scalar]) {
            auto role = sample % 2 == 0
                ? (pairOrdinal == 0 ? "baseline" : "selected")
                : (pairOrdinal == 0 ? "selected" : "baseline");
            auto row = benchmark(bytes, backend, sample, role);
            JSONValue value;
            value["role"] = row.role;
            value["backend"] = row.backend;
            value["sample"] = cast(long)row.sample;
            value["bytes"] = cast(long)row.bytes;
            value["iterations"] = cast(long)row.iterations;
            value["seconds"] = row.seconds;
            value["last_digest"] = row.digest;
            rows ~= value;
        }
    }
    return rows;
}

private string sourceHash(string path) {
    auto digest = sha256Of(cast(ubyte[])read(path));
    return hex(digest);
}

private bool isLowerHexDigest(string value) pure nothrow {
    if (value.length != 64) return false;
    foreach (character; value)
        if (!(character >= '0' && character <= '9') &&
                !(character >= 'a' && character <= 'f')) return false;
    return true;
}

private void validateNativeReport(string path) {
    auto report = parseJSON(readText(path));
    enforce(report.object.length == 12 &&
        report["schema"].str == "scrubbed-sha256-native-backend-v2" &&
        report["compiler"].str == expectedCompiler &&
        report["frontend"].integer == __VERSION__ &&
        report["hardware_execution"].str == "SUPPORTED_AND_PASSED" &&
        report["os"].str.length != 0 && report["os_release"].str.length != 0 &&
        report["microbench_claim"].str ==
            "descriptive crossover evidence; hosted runner frequency uncontrolled" &&
        isLowerHexDigest(report["harness_binary_sha256"].str),
        "native SHA-256 report identity mismatch");

    auto architecture = report["architecture"].str;
    string expectedBackend;
    if (architecture == "aarch64" || architecture == "arm64")
        expectedBackend = "armv8-sha2";
    else if (architecture == "x86_64")
        expectedBackend = "x86-sha-ni";
    else enforce(false, "native SHA-256 report architecture mismatch");
    enforce(report["selected_backend"].str == expectedBackend,
        "native SHA-256 report backend mismatch");

    auto sources = report["source_sha256"].object;
    enforce(sources.length == backendSourcePaths.length,
        "native SHA-256 report source cardinality mismatch");
    foreach (source; backendSourcePaths)
        enforce(sources[source].str == sourceHash(source),
            "native SHA-256 report source hash mismatch: " ~ source);

    immutable sizes = [32, 55, 56, 63, 64, 65, 128, 256, 512, 1024];
    auto rows = report["short_message_microbench"].array;
    enforce(rows.length == sizes.length * 5 * 2,
        "native SHA-256 report microbench cardinality mismatch");
    foreach (index, row; rows) {
        enforce(row.object.length == 7,
            "native SHA-256 report microbench shape mismatch");
        auto sizeIndex = index / 10;
        auto withinSize = index % 10;
        auto sample = withinSize / 2;
        auto pairOrdinal = withinSize % 2;
        auto baselineFirst = sample % 2 == 0;
        auto expectedRole = (baselineFirst == (pairOrdinal == 0))
            ? "baseline" : "selected";
        auto expectedRowBackend = expectedRole == "baseline"
            ? "scalar" : expectedBackend;
        enforce(row["bytes"].integer == sizes[sizeIndex] &&
            row["sample"].integer == sample &&
            row["role"].str == expectedRole &&
            row["backend"].str == expectedRowBackend,
            "native SHA-256 report microbench ordering mismatch");
        auto expectedIterations = cast(long)((32UL * 1024 * 1024) /
            sizes[sizeIndex]);
        enforce(row["iterations"].integer == expectedIterations,
            "native SHA-256 report iteration mismatch");
        auto seconds = row["seconds"].floating;
        enforce(seconds.isFinite && seconds > 0,
            "native SHA-256 report duration mismatch");
        auto input = deterministicBytes(sizes[sizeIndex],
            cast(uint)(sizes[sizeIndex] + 185));
        enforce(row["last_digest"].str == hex(sha256Of(input)),
            "native SHA-256 report digest mismatch");
    }
}

private string commandValue(string[] command, string label) {
    auto result = execute(command);
    enforce(result.status == 0 && result.output.strip.length != 0,
        "cannot identify host " ~ label);
    return result.output.strip;
}

private JSONValue hostIdentity() {
    auto os = commandValue(["/usr/bin/uname", "-s"], "operating system");
    auto release = commandValue(["/usr/bin/uname", "-r"], "OS release");
    auto architecture = commandValue(["/usr/bin/uname", "-m"], "architecture");
    auto cpu = commandValue(["/usr/sbin/sysctl", "-n",
        "machdep.cpu.brand_string"], "CPU");
    enforce(os == "Darwin", "SHA-256 evidence requires Darwin host identity");
    version (AArch64)
        enforce(architecture == "arm64",
            "compiled AArch64 does not match host architecture");
    else version (X86_64)
        enforce(architecture == "x86_64",
            "compiled x86-64 does not match host architecture");
    else
        enforce(false, "unsupported SHA-256 evidence host architecture");
    JSONValue result;
    result["os"] = os;
    result["os_release"] = release;
    result["architecture"] = architecture;
    result["cpu"] = cpu;
    return result;
}

private string armExecutionStatus(const JSONValue host) {
    if (host["architecture"].str != "arm64") {
        enforce(!sha256BackendAvailable(Sha256Backend.armSha2),
            "ARM SHA2 backend available on a non-ARM host");
        return "BLOCKED_EXTERNAL_ARCHITECTURE_MISMATCH_FEATURE_UNKNOWN";
    }
    return sha256BackendAvailable(Sha256Backend.armSha2)
        ? "SUPPORTED_AND_PASSED"
        : "BLOCKED_EXTERNAL_NATIVE_ARM_SHA2_UNAVAILABLE";
}

private string x86ExecutionStatus(const JSONValue host) {
    if (host["architecture"].str != "x86_64") {
        enforce(!sha256BackendAvailable(Sha256Backend.x86ShaNi),
            "x86 SHA-NI backend available on a non-x86 host");
        return "BLOCKED_EXTERNAL_ARCHITECTURE_MISMATCH_CPUID_UNKNOWN";
    }
    return sha256BackendAvailable(Sha256Backend.x86ShaNi)
        ? "SUPPORTED_AND_PASSED"
        : "BLOCKED_EXTERNAL_NATIVE_X86_CPUID_HAS_NO_SHA";
}

private JSONValue disassemblyEvidence(const JSONValue host) {
    JSONValue result;
    auto root = buildPath("/tmp", "scrubbed-sha256-disassembly-" ~
        randomUUID.toString);
    import std.file : mkdir;
    mkdir(root);
    scope(exit) rmdirRecurse(root);

    auto armObject = buildPath(root, "sha256_arm64.o");
    auto armBuild = execute(["ldc2", "-O3", "-release",
        "-mtriple=arm64-apple-darwin", "-Isource", "-c",
        "source/crypto/sha256_arm64.d", "-of=" ~ armObject]);
    enforce(armBuild.status == 0, "ARM SHA2 cross-compile failed");
    auto arm = execute(["/opt/homebrew/opt/llvm/bin/llvm-objdump", "-d",
        "--arch=arm64", armObject]);
    enforce(arm.status == 0, "ARM SHA2 disassembly failed");
    foreach (instruction; ["sha256h.4s", "sha256h2.4s", "sha256su0.4s",
            "sha256su1.4s"])
        result["arm_" ~ instruction] = cast(long)arm.output.count(instruction);
    enforce(result["arm_sha256h.4s"].integer > 0 &&
        result["arm_sha256h2.4s"].integer > 0 &&
        result["arm_sha256su0.4s"].integer > 0 &&
        result["arm_sha256su1.4s"].integer > 0,
        "ARM SHA2 instruction proof missing");
    result["arm_object_sha256"] = sourceHash(armObject);

    auto object = buildPath(root, "sha256_x86_64.o");
    auto build = execute(["ldc2", "-O3", "-release",
        "-mtriple=x86_64-apple-darwin", "-Isource", "-c",
        "source/crypto/sha256_x86_64.d", "-of=" ~ object]);
    enforce(build.status == 0, "x86 SHA-NI cross-compile failed");
    auto dump = execute(["/opt/homebrew/opt/llvm/bin/llvm-objdump", "-d",
        "--arch=x86_64", object]);
    enforce(dump.status == 0 && dump.output.count("sha256rnds2") == 32,
        "x86 SHA-NI instruction proof missing");
    result["x86_sha256rnds2"] = cast(long)dump.output.count("sha256rnds2");
    result["x86_object_sha256"] = sourceHash(object);
    result["x86_execution"] = x86ExecutionStatus(host);
    return result;
}

private void writeReport(string path) {
    selfTest;
    longTest;
    JSONValue report;
    report["schema"] = "scrubbed-sha256-backend-evidence-v2";
    report["base_source_sha"] = "cd15948466509055ae0431439f651ecba8a301f6";
    report["compiler"] = expectedCompiler;
    report["frontend"] = cast(long)__VERSION__;
    report["build_recipe"] = buildRecipe;
    report["selected_backend"] = sha256BackendName(selectedSha256Backend);
    auto host = hostIdentity;
    report["host_identity"] = host;
    report["arm_sha2_execution"] = armExecutionStatus(host);
    report["x86_sha_ni_execution"] = x86ExecutionStatus(host);
    report["production_migration"] =
        "MIGRATED_AFTER_NATIVE_AND_COMBINED_GATES";
    report["multi_gib_logical_bytes"] = 4_296_015_890L;
    report["multi_gib_status"] = "PASSED_AGAINST_PHOBOS";
    report["inventory"] = inventoryEvidence;
    JSONValue sources;
    foreach (source; backendSourcePaths)
        sources[source] = sourceHash(source);
    report["source_sha256"] = sources;
    report["harness_binary_sha256"] = sourceHash(thisExePath);
    report["system_oracle"] = "/usr/bin/shasum -a 256";
    report["system_oracle_sha256"] = sourceHash("/usr/bin/shasum");
    auto compilerPath = execute(["/usr/bin/which", "ldc2"]);
    enforce(compilerPath.status == 0, "cannot resolve LDC executable");
    report["compiler_executable"] = compilerPath.output.strip;
    report["compiler_executable_sha256"] =
        sourceHash(compilerPath.output.strip);
    report["llvm_objdump_sha256"] =
        sourceHash("/opt/homebrew/opt/llvm/bin/llvm-objdump");
    report["disassembly"] = disassemblyEvidence(host);
    immutable size_t[4] sizes = [64, 1024, 8192, 1024 * 1024];
    report["microbench"] = benchmarkRows(sizes[]);
    report["claims"] = [JSONValue("digest bytes only; no production speed claim"),
        JSONValue("OS cache and frequency state uncontrolled")];
    write(path, report.toString(JSONOptions.doNotEscapeSlashes));
    validateReport(path);
    writeln("wrote ", path);
}

private void validateReport(string path) {
    auto report = parseJSON(readText(path));
    enforce(report["schema"].str == "scrubbed-sha256-backend-evidence-v2" &&
        report["base_source_sha"].str ==
            "cd15948466509055ae0431439f651ecba8a301f6" &&
        report["compiler"].str == expectedCompiler &&
        report["frontend"].integer == __VERSION__ &&
        report["build_recipe"].str == buildRecipe,
        "SHA-256 report identity mismatch");
    auto host = hostIdentity;
    enforce(report["host_identity"].toString == host.toString,
        "SHA-256 report host identity mismatch");
    enforce(report["selected_backend"].str ==
        sha256BackendName(selectedSha256Backend) &&
        report["arm_sha2_execution"].str == armExecutionStatus(host) &&
        report["x86_sha_ni_execution"].str == x86ExecutionStatus(host) &&
        report["production_migration"].str ==
            "MIGRATED_AFTER_NATIVE_AND_COMBINED_GATES" &&
        report["multi_gib_logical_bytes"].integer == 4_296_015_890L &&
        report["multi_gib_status"].str == "PASSED_AGAINST_PHOBOS",
        "SHA-256 report status mismatch");
    enforce(report["inventory"].toString == inventoryEvidence.toString,
        "SHA-256 report inventory mismatch");
    auto claims = report["claims"].array;
    enforce(claims.length == 2 && claims[0].str ==
        "digest bytes only; no production speed claim" && claims[1].str ==
        "OS cache and frequency state uncontrolled",
        "SHA-256 report claim mismatch");
    auto sources = report["source_sha256"].object;
    enforce(sources.length == backendSourcePaths.length,
        "SHA-256 report source cardinality mismatch");
    foreach (source; backendSourcePaths)
        enforce(sources[source].str == sourceHash(source),
            "SHA-256 report source hash mismatch: " ~ source);
    enforce(report["harness_binary_sha256"].str == sourceHash(thisExePath) &&
        report["system_oracle_sha256"].str == sourceHash("/usr/bin/shasum") &&
        report["compiler_executable_sha256"].str ==
            sourceHash(report["compiler_executable"].str) &&
        report["llvm_objdump_sha256"].str ==
            sourceHash("/opt/homebrew/opt/llvm/bin/llvm-objdump"),
        "SHA-256 report tool/binary hash mismatch");
    enforce(report["disassembly"].toString == disassemblyEvidence(host).toString,
        "SHA-256 report disassembly mismatch");

    immutable sizes = [64, 1024, 8192, 1024 * 1024];
    bool[2][5][4] seen;
    auto rows = report["microbench"].array;
    enforce(rows.length == sizes.length * 5 * 2,
        "SHA-256 report microbench cardinality mismatch");
    foreach (row; rows) {
        size_t sizeIndex = size_t.max;
        foreach (i, size; sizes)
            if (row["bytes"].integer == size) sizeIndex = i;
        enforce(sizeIndex != size_t.max, "SHA-256 report size mismatch");
        auto sample = cast(size_t)row["sample"].integer;
        enforce(sample < 5, "SHA-256 report sample mismatch");
        size_t backendIndex;
        auto role = row["role"].str;
        enforce(role == "baseline" || role == "selected",
            "SHA-256 report role mismatch");
        backendIndex = role == "baseline" ? 0 : 1;
        auto backendName = row["backend"].str;
        enforce(backendName == (backendIndex == 0 ? "scalar" :
            sha256BackendName(selectedSha256Backend)),
            "SHA-256 report backend mismatch");
        enforce(!seen[sizeIndex][sample][backendIndex],
            "SHA-256 report duplicate microbench row");
        seen[sizeIndex][sample][backendIndex] = true;
        auto seconds = row["seconds"].floating;
        enforce(seconds.isFinite && seconds > 0,
            "SHA-256 report duration mismatch");
        auto expectedIterations = cast(long)((32UL * 1024 * 1024) /
            sizes[sizeIndex]);
        if (expectedIterations == 0) expectedIterations = 1;
        enforce(row["iterations"].integer == expectedIterations,
            "SHA-256 report iteration mismatch");
        auto input = deterministicBytes(sizes[sizeIndex],
            cast(uint)(sizes[sizeIndex] + 185));
        enforce(row["last_digest"].str == hex(sha256Of(input)),
            "SHA-256 report digest mismatch");
    }
    foreach (bySize; seen) foreach (bySample; bySize)
        enforce(bySample[0] && bySample[1],
            "SHA-256 report missing microbench pair");
}

int main(string[] args) {
    if (args.length == 2 && args[1] == "--self-test") { selfTest; return 0; }
    if (args.length == 2 && args[1] == "--long-test") { longTest; return 0; }
    if (args.length == 3 && args[1] == "--report") {
        writeReport(args[2]); return 0;
    }
    if (args.length == 3 && args[1] == "--check-report") {
        validateReport(args[2]); writeln("sha256 backend report valid"); return 0;
    }
    if (args.length == 3 && args[1] == "--native-report") {
        writeNativeReport(args[2]); return 0;
    }
    if (args.length == 3 && args[1] == "--check-native-report") {
        validateNativeReport(args[2]);
        writeln("native SHA-256 backend report valid");
        return 0;
    }
    writeln("usage: sha256_backend_check --self-test|--long-test|" ~
        "--report PATH|--check-report PATH|--native-report PATH|" ~
        "--check-native-report PATH");
    return 2;
}
