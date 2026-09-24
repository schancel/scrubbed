/// Bounded O3/release evidence runner and strict checker for the PII pipeline.
module benchmarks.pii_pipeline_check;

import core.stdc.errno : EINTR, errno;
import core.sys.posix.sys.resource : rusage;
import core.sys.posix.sys.wait : WEXITSTATUS, WIFEXITED;
import std.algorithm.searching : canFind;
import std.algorithm.sorting : sort;
import std.array : replicate;
import std.conv : to;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;
import std.exception : enforce;
import std.file : SpanMode, copy, dirEntries, exists, getAttributes,
    mkdirRecurse, read, readText, rmdirRecurse, setAttributes, tempDir, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : absolutePath, buildPath, dirName, relativePath;
import std.process : Config, execute, spawnProcess;
import std.stdio : File, writeln;
import std.string : indexOf, split, splitLines, startsWith, strip;
import std.uuid : randomUUID;

version (Posix) extern(C) int wait4(int, int*, int, rusage*);
else static assert(0, "PII evidence currently supports POSIX wait4 hosts");

private enum schema = "scrubbed-pii-pipeline-evidence-v1";
private enum flags = "-O3 -release";
private enum inputCap = 1024 * 1024;
private enum findingCap = 4096;
private enum handoffInput = "Contact scholar@example.org from 192.0.2.44.\n";
private enum handoffMasked = "Contact ******************* from **********.\n";
private enum handoffStdin =
    `{"text":"Contact scholar@example.org from 192.0.2.44.\n"}` ~ "\n";
private enum handoffStdout =
    `{"text":"Contact ******************* from **********.\n"}` ~ "\n";
private enum analyzerIdentity = "pii.four-class/four-class:v1";
private enum policyIdentity = "pii-policy:v1";
private enum buildSchema = "scrubbed-pii-reproducible-build-v1";
private enum olderResolvableRevision =
    "3075fdf6ab7627f3ca411438de1e113b2d2fa75b";

private void need(bool value, string message) {
    if (!value) throw new Exception("pii pipeline evidence: " ~ message);
}

private string hashBytes(const(ubyte)[] value) {
    return toHexString!(LetterCase.lower)(sha256Of(value)).idup;
}

private string hashText(string value) {
    return hashBytes(cast(const(ubyte)[]) value);
}

private string hashFile(string path) {
    return hashBytes(cast(const(ubyte)[]) read(path));
}

private bool digest(string value) {
    if (value.length != 64) return false;
    foreach (c; value)
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')))
            return false;
    return true;
}

private bool revisionDigest(string value) {
    if (value.length != 40) return false;
    foreach (c; value)
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')))
            return false;
    return true;
}

private string commandVersion(string executable) {
    auto result = execute([executable, "--version"]);
    need(result.status == 0 && result.output.splitLines.length != 0,
        executable ~ " --version failed");
    return result.output.splitLines[0].strip;
}

private JSONValue stringArray(string[] values) {
    JSONValue[] result;
    foreach (value; values) result ~= JSONValue(value);
    return JSONValue(result);
}

private uint little32(const(ubyte)[] bytes, size_t offset) {
    return cast(uint) bytes[offset] | cast(uint) bytes[offset + 1] << 8 |
        cast(uint) bytes[offset + 2] << 16 | cast(uint) bytes[offset + 3] << 24;
}

private void normalizeMachOUuid(string path) {
    auto bytes = cast(ubyte[]) read(path);
    need(bytes.length >= 32 && little32(bytes, 0) == 0xfeedfacf,
        "normalization requires a 64-bit little-endian Mach-O");
    auto commands = little32(bytes, 16);
    size_t offset = 32;
    bool found;
    foreach (_; 0 .. commands) {
        need(offset + 8 <= bytes.length, "truncated Mach-O load command");
        auto command = little32(bytes, offset);
        auto size = little32(bytes, offset + 4);
        need(size >= 8 && offset + size <= bytes.length,
            "invalid Mach-O load command size");
        if (command == 0x1b) {
            need(size == 24 && !found, "invalid or duplicate Mach-O UUID");
            foreach (i; 0 .. 16) bytes[offset + 8 + i] = cast(ubyte) i;
            found = true;
        }
        offset += size;
    }
    need(found, "Mach-O UUID load command is missing");
    write(path, bytes);
}

private struct BuiltArtifact { string path; JSONValue receipt; }

private BuiltArtifact buildArtifact(string revision, string destination) {
    need(revisionDigest(revision), "build revision is not lowercase 40-hex");
    auto root = buildPath(tempDir, "scrubbed-pii-build-" ~ randomUUID.toString);
    mkdirRecurse(root);
    scope (exit) if (exists(root)) rmdirRecurse(root);
    auto archive = buildPath(root, "source.tar");
    auto source = buildPath(root, "source");
    mkdirRecurse(source);
    auto archived = execute(["git", "archive", "--format=tar",
        "--output=" ~ archive, revision]);
    need(archived.status == 0, "git archive failed: " ~ archived.output);
    auto archiveHash = hashFile(archive);
    auto extracted = execute(["tar", "-xf", archive, "-C", source]);
    need(extracted.status == 0, "source archive extraction failed");
    auto tree = execute(["git", "rev-parse", revision ~ "^{tree}"]);
    auto compilerPath = execute(["which", "ldc2"]);
    auto dubPath = execute(["which", "dub"]);
    need(tree.status == 0 && compilerPath.status == 0 && dubPath.status == 0,
        "build identity probe failed");
    auto compiler = absolutePath(compilerPath.output.strip);
    auto dub = absolutePath(dubPath.output.strip);
    auto buildCommand = [dub, "build", "--compiler=" ~ compiler,
        "--build=release", "--force", "--non-interactive"];
    auto environment = ["DFLAGS": flags];
    auto built = execute(buildCommand, environment, Config.none, size_t.max,
        source);
    need(built.status == 0, "private archived-source build failed: " ~
        built.output);
    auto privateBinary = buildPath(source, "scrubbed");
    need(exists(privateBinary), "private build did not produce scrubbed");
    auto codesign = "/usr/bin/codesign";
    auto stripTool = "/usr/bin/strip";
    auto unsignedResult = execute([codesign, "--remove-signature",
        privateBinary]);
    need(unsignedResult.status == 0,
        "signature normalization failed: " ~ unsignedResult.output);
    auto stripped = execute([stripTool, "-S", privateBinary]);
    need(stripped.status == 0, "debug normalization failed: " ~
        stripped.output);
    normalizeMachOUuid(privateBinary);
    auto resigned = execute([codesign, "--force", "-s", "-", privateBinary]);
    need(resigned.status == 0, "deterministic ad-hoc signing failed: " ~
        resigned.output);
    auto afterArchive = buildPath(root, "source-after.tar");
    auto rearchived = execute(["git", "archive", "--format=tar",
        "--output=" ~ afterArchive, revision]);
    need(rearchived.status == 0 && hashFile(afterArchive) == archiveHash,
        "source archive changed during build");
    need(!exists(destination), "artifact destination already exists");
    mkdirRecurse(dirName(destination));
    copy(privateBinary, destination);
    setAttributes(destination, getAttributes(privateBinary));
    auto receipt = JSONValue([
        "schema": JSONValue(buildSchema),
        "source_revision": JSONValue(revision),
        "source_tree_git_oid": JSONValue(tree.output.strip),
        "source_archive_sha256": JSONValue(archiveHash),
        "dub_recipe_sha256": JSONValue(hashFile(buildPath(source, "dub.json"))),
        "dub_lock_sha256": JSONValue(hashFile(buildPath(source,
            "dub.selections.json"))),
        "build_argv": stringArray(buildCommand),
        "build_working_tree": JSONValue("exact-git-archive"),
        "dflags": JSONValue(environment["DFLAGS"]),
        "compiler": JSONValue(["executable": JSONValue(compiler),
            "sha256": JSONValue(hashFile(compiler)),
            "version": JSONValue(commandVersion(compiler))]),
        "dub": JSONValue(["executable": JSONValue(dub),
            "sha256": JSONValue(hashFile(dub)),
            "version": JSONValue(commandVersion(dub))]),
        "normalization": JSONValue([
            "codesign_argv": stringArray([codesign, "--remove-signature",
                "<PRIVATE_BUILD>/scrubbed"]),
            "codesign_sha256": JSONValue(hashFile(codesign)),
            "strip_argv": stringArray([stripTool, "-S",
                "<PRIVATE_BUILD>/scrubbed"]),
            "strip_sha256": JSONValue(hashFile(stripTool)),
            "uuid_bytes_hex": JSONValue("000102030405060708090a0b0c0d0e0f"),
            "resign_argv": stringArray([codesign, "--force", "-s", "-",
                "<PRIVATE_BUILD>/scrubbed"])]),
        "artifact_sha256": JSONValue(hashFile(destination))]);
    return BuiltArtifact(destination, receipt);
}

private void contentPrivate(string label, string[] channels) {
    foreach (channel; channels)
        foreach (canary; ["scholar@example.org", "@example.org",
                "192.0.2.44", "private-canary"])
            need(!channel.canFind(canary), label ~ " leaked content canary");
}

private bool privacyRejects(scope void delegate() operation) {
    try operation();
    catch (Exception) return true;
    return false;
}

private void privacyNegativeControls() {
    foreach (route; ["dry", "explain", "durable-stale"])
        foreach (channel; ["stdout", "stderr"])
            foreach (canary; ["scholar@example.org", "@example.org",
                    "192.0.2.44", "private-canary"])
                need(privacyRejects(() {
                    contentPrivate(route ~ " " ~ channel,
                        ["diagnostic:" ~ canary]);
                }), "privacy negative control survived: " ~ route ~ "/" ~
                    channel ~ "/" ~ canary);
}

private string disabledConfig() {
    return `{"version":3,"stages":[{"id":"plain","implementation":` ~
        `"text-transform","options":{},"filters":[]}]}`;
}

private string piiConfig(string policy) {
    auto option = policy == "report" ? "" :
        `,"policy":"` ~ policy ~ `"` ~
        (policy == "redact" ? `,"allow-redact":true` : "");
    return `{"version":3,"stages":[{"id":"privacy","implementation":` ~
        `"pii-four-class","options":{"max-input-bytes":1048576,` ~
        `"max-findings":4096` ~ option ~ `},"filters":[]}]}`;
}

private string cleanFixture() {
    auto result = "Synthetic public-domain clean fixture. ".replicate(
        inputCap / "Synthetic public-domain clean fixture. ".length + 1);
    return result[0 .. inputCap].idup;
}

private string heavyFixture() {
    string result;
    foreach (i; 0 .. findingCap)
        result ~= "u" ~ i.to!string ~ "@example.org ";
    need(result.length < inputCap, "finding fixture exceeds input cap");
    result ~= "x".replicate(inputCap - result.length);
    return result;
}

private ulong micros(ref const typeof(rusage.init.ru_utime) value) {
    return cast(ulong) value.tv_sec * 1_000_000 + value.tv_usec;
}

private ulong peakRss(ref const rusage value) {
    version (OSX) return value.ru_opaque[0];
    else version (linux) return value.ru_maxrss * 1024;
    else return 0;
}

private struct ChildResult {
    int status;
    ulong wallUs, userUs, systemUs, rssBytes;
    string stdoutText, stderrText;
}

private ChildResult invoke(string[] command, string root, string label,
        File input = File.init, string workDir = null) {
    auto stdoutPath = buildPath(root, label ~ ".stdout");
    auto stderrPath = buildPath(root, label ~ ".stderr");
    auto source = input.isOpen ? input : File("/dev/null", "rb");
    auto output = File(stdoutPath, "wb");
    auto errors = File(stderrPath, "wb");
    auto timer = StopWatch(AutoStart.yes);
    auto child = spawnProcess(command, source, output, errors, null,
        Config.none, workDir);
    if (!input.isOpen) source.close();
    output.close();
    errors.close();
    int rawStatus;
    rusage usage;
    int waited;
    do waited = wait4(child.processID, &rawStatus, 0, &usage);
    while (waited < 0 && errno == EINTR);
    timer.stop();
    need(waited == child.processID && WIFEXITED(rawStatus),
        label ~ " did not exit normally");
    return ChildResult(WEXITSTATUS(rawStatus), timer.peek.total!"usecs",
        micros(usage.ru_utime), micros(usage.ru_stime), peakRss(usage),
        readText(stdoutPath), readText(stderrPath));
}

private string[] stageArgs(string policy) {
    string[] result = ["--stage", "privacy=pii-four-class", "--stage-option",
        "max-input-bytes=integer:1048576", "--stage-option",
        "max-findings=integer:4096"];
    if (policy != "report") {
        result ~= ["--stage-option", "policy=text:" ~ policy];
        if (policy == "redact")
            result ~= ["--stage-option", "allow-redact=boolean:true"];
    }
    return result;
}

private JSONValue metric(string binary, string root, string fixture,
        string policy, string inputPath) {
    auto auditName = fixture ~ "-" ~ policy ~ ".audit";
    auto configName = policy ~ ".json";
    auto audit = buildPath(root, auditName);
    auto config = buildPath(root, configName);
    auto jsonInput = buildPath(root, fixture ~ "-transport.jsonl");
    write(jsonInput, JSONValue(["text": JSONValue(readText(inputPath))]).toString ~
        "\n");
    auto command = [binary, "run", "--input", "-", "--output", "-",
        "--jsonl-fields", "text", "--dataset-namespace",
        "pii-metric-synthetic-v1", "--source-key", fixture,
        "--max-jsonl-line-bytes", "1050000", "--max-jsonl-output-bytes",
        "1050000"];
    if (policy == "disabled") command ~= ["--config", configName];
    else command ~= ["--sidecar-output", auditName] ~ stageArgs(policy);
    auto metricInput = File(jsonInput, "rb");
    auto result = invoke(command, root, "metric-" ~ fixture ~ "-" ~ policy,
        metricInput, root);
    metricInput.close();
    need(result.status == 0, fixture ~ "/" ~ policy ~ " failed: " ~
        result.stderrText);
    auto inputBytes = cast(const(ubyte)[]) read(inputPath);
    auto outputBytes = cast(const(ubyte)[])
        parseJSON(result.stdoutText)["text"].str;
    const hasAudit = policy != "disabled";
    auto auditBytes = hasAudit ? cast(const(ubyte)[]) read(audit) : null;
    if (hasAudit) {
        auto parsed = parseJSON(cast(string) auditBytes);
        need(parsed["input_revision_sha256"].str == hashBytes(inputBytes) &&
            parsed["output_sha256"].str == hashBytes(outputBytes),
            "audit revision/output binding mismatch");
        need(parsed["unions"].array.length ==
                (fixture == "finding-heavy" ? findingCap : 0),
            "fixture finding cardinality mismatch");
        contentPrivate("metric audit", [cast(string) auditBytes]);
    }
    contentPrivate("metric diagnostics", [result.stderrText]);
    if (policy == "disabled" || policy == "report")
        need(outputBytes == inputBytes, "preserving policy changed bytes");
    else contentPrivate("metric transformed output", [cast(string) outputBytes]);
    return JSONValue([
        "fixture": JSONValue(fixture), "policy": JSONValue(policy),
        "wall_seconds": JSONValue(result.wallUs / 1_000_000.0),
        "user_seconds": JSONValue(result.userUs / 1_000_000.0),
        "system_seconds": JSONValue(result.systemUs / 1_000_000.0),
        "peak_rss_bytes": JSONValue(cast(long) result.rssBytes),
        "input_bytes": JSONValue(cast(long) inputBytes.length),
        "output_bytes": JSONValue(cast(long) outputBytes.length),
        "audit_bytes": JSONValue(cast(long) auditBytes.length),
        "input_sha256": JSONValue(hashBytes(inputBytes)),
        "output_sha256": JSONValue(hashBytes(outputBytes)),
        "audit_sha256": JSONValue(hasAudit ? hashBytes(auditBytes) :
            hashText("")),
        "document_id": JSONValue(hasAudit ?
            parseJSON(cast(string) auditBytes)["document_id"].str :
            "NOT_APPLICABLE"),
        "config_sha256": JSONValue(hashFile(config)),
        "analyzer_sha256": JSONValue(hasAudit ?
            hashText(analyzerIdentity) : hashText("NOT_APPLICABLE")),
        "policy_sha256": JSONValue(hasAudit ?
            hashText(policyIdentity ~ "/" ~ policy) :
            hashText("NOT_APPLICABLE"))]);
}

private JSONValue[] deterministicMetrics(string binary) {
    auto root = buildPath(tempDir, "scrubbed-pii-metrics-" ~
        randomUUID.toString);
    mkdirRecurse(root);
    scope (exit) if (exists(root)) rmdirRecurse(root);
    auto cleanPath = buildPath(root, "clean.txt");
    auto heavyPath = buildPath(root, "finding-heavy.txt");
    write(cleanPath, cleanFixture());
    write(heavyPath, heavyFixture());
    foreach (policy; ["disabled", "report", "mask", "redact"])
        write(buildPath(root, policy ~ ".json"), policy == "disabled" ?
            disabledConfig() : piiConfig(policy));
    JSONValue[] metrics;
    foreach (fixture; ["clean", "finding-heavy"])
        foreach (policy; ["disabled", "report", "mask", "redact"])
            metrics ~= metric(binary, root, fixture, policy,
                fixture == "clean" ? cleanPath : heavyPath);
    return metrics;
}

private JSONValue gcEvidence(string binary, string root, string inputPath) {
    auto output = buildPath(root, "gc.out");
    auto audit = buildPath(root, "gc.audit");
    auto result = invoke([binary, "--DRT-gcopt=profile:2", "run", "--input",
        inputPath, "--output", output, "--sidecar-output", audit,
        "--threads", "1"] ~ stageArgs("mask"), root, "gc-profile");
    if (result.status != 0 || !result.stdoutText.canFind("GC summary:"))
        return JSONValue(["status": JSONValue("UNSUPPORTED"),
            "reason": JSONValue("D runtime emitted no parseable GC summary")]);
    long allocated = -1, collections = -1;
    foreach (line; result.stdoutText.splitLines) {
        auto clean = line.strip;
        if (clean.startsWith("Number of collections:"))
            collections = clean["Number of collections:".length .. $].strip.to!long;
        if (clean.startsWith("GC summary:")) {
            auto fields = clean.split;
            if (fields.length >= 8 && fields[0] == "GC" &&
                    fields[1] == "summary:" && fields[3] == "MB," &&
                    fields[5] == "GC" && fields[7] == "ms,")
                allocated = fields[2].to!long * 1024 * 1024;
        }
    }
    if (allocated < 0 || collections < 0)
        return JSONValue(["status": JSONValue("UNSUPPORTED"),
            "reason": JSONValue("runtime GC field format is not stable on this host")]);
    return JSONValue(["status": JSONValue("SUPPORTED"),
        "semantics": JSONValue("D-runtime GC-only; excludes native allocations"),
        "allocated_bytes": JSONValue(allocated),
        "allocated_bytes_semantics": JSONValue(
            "druntime whole-MB summary converted with 1048576 bytes per MiB"),
        "collections": JSONValue(collections)]);
}

private JSONValue deterministicGc(string binary) {
    auto root = buildPath(tempDir, "scrubbed-pii-gc-" ~ randomUUID.toString);
    mkdirRecurse(root);
    scope (exit) if (exists(root)) rmdirRecurse(root);
    auto input = buildPath(root, "finding-heavy.txt");
    write(input, heavyFixture());
    return gcEvidence(binary, root, input);
}

private JSONValue fileManifest(string root, bool canonicalAudit = false) {
    auto canonicalRoot = absolutePath(root);
    string[] paths;
    foreach (entry; dirEntries(canonicalRoot, SpanMode.depth, false))
        if (entry.isFile) paths ~= relativePath(entry.name, canonicalRoot);
    paths.sort;
    JSONValue[] result;
    foreach (path; paths) {
        auto bytes = cast(const(ubyte)[]) read(buildPath(canonicalRoot, path));
        auto digestBytes = bytes;
        if (canonicalAudit) {
            auto audit = parseJSON(cast(string) bytes);
            audit["document_id"] = JSONValue("doc:v1:" ~ "0".replicate(64));
            digestBytes = cast(const(ubyte)[]) audit.toString;
        }
        result ~= JSONValue(["path": JSONValue(path),
            "bytes": JSONValue(cast(long) bytes.length),
            "sha256": JSONValue(hashBytes(digestBytes))]);
    }
    return JSONValue(result);
}

private JSONValue runMatrix(string binary, string root) {
    privacyNegativeControls();
    auto treeInput = buildPath(root, "tree-input");
    mkdirRecurse(treeInput);
    foreach (i; 0 .. 4)
        write(buildPath(treeInput, i.to!string ~ ".txt"),
            i == 0 ? handoffInput : "clean synthetic text\n");
    JSONValue firstTree, firstSide, fourthTree, fourthSide;
    foreach (threads; [1, 4]) {
        auto output = buildPath(root, "tree-output-" ~ threads.to!string);
        auto side = buildPath(root, "tree-side-" ~ threads.to!string);
        auto result = invoke([binary, "run", "--input", treeInput,
            "--output", output, "--sidecar-output", side, "--threads",
            threads.to!string] ~ stageArgs("mask"), root,
            "tree-" ~ threads.to!string);
        need(result.status == 0, "tree/thread matrix failed");
        contentPrivate("tree diagnostics", [result.stdoutText, result.stderrText]);
        foreach (i; 0 .. 4) {
            contentPrivate("tree transformed output", [readText(buildPath(output,
                i.to!string ~ ".txt"))]);
            contentPrivate("tree audit", [readText(buildPath(side,
                i.to!string ~ ".txt.pii-audit.json"))]);
        }
        auto outManifest = fileManifest(output);
        auto sideManifest = fileManifest(side, true);
        need(outManifest.array.length == 4 && sideManifest.array.length == 4,
            "tree manifest cardinality mismatch");
        if (threads == 1) {
            firstTree = outManifest;
            firstSide = sideManifest;
        } else {
            fourthTree = outManifest;
            fourthSide = sideManifest;
            need(outManifest == firstTree && sideManifest == firstSide,
                "one/four-thread complete manifest mismatch");
        }
    }

    auto validation = invoke([binary, "run", "--input", treeInput,
        "--output", buildPath(root, "validate-out"), "--sidecar-output",
        buildPath(root, "validate-side"), "--threads", "1", "--validate"] ~
        stageArgs("mask"), root, "validate");
    need(validation.status == 0, "validate route failed");
    contentPrivate("validate diagnostics", [validation.stdoutText,
        validation.stderrText]);
    auto dry = invoke([binary, "run", "--input", treeInput, "--output",
        buildPath(root, "dry-out"), "--sidecar-output",
        buildPath(root, "dry-side"), "--threads", "1", "--dry-run"] ~
        stageArgs("mask"), root, "dry");
    need(dry.status == 0 && !exists(buildPath(root, "dry-out")) &&
        !exists(buildPath(root, "dry-side")),
        "dry-run route failed");
    contentPrivate("dry diagnostics", [dry.stdoutText,
        dry.stderrText]);
    auto explainOutput = buildPath(root, "explain-out");
    auto explainSide = buildPath(root, "explain-side");
    auto explained = invoke([binary, "run", "--input", treeInput, "--output",
        explainOutput, "--sidecar-output", explainSide, "--threads", "1",
        "--explain"] ~ stageArgs("mask"), root, "explain");
    need(explained.status == 0, "explain route failed");
    contentPrivate("explain diagnostics", [explained.stdoutText,
        explained.stderrText]);
    foreach (i; 0 .. 4) {
        contentPrivate("explain transformed output", [readText(buildPath(
            explainOutput, i.to!string ~ ".txt"))]);
        contentPrivate("explain audit", [readText(buildPath(explainSide,
            i.to!string ~ ".txt.pii-audit.json"))]);
    }

    auto jsonlInput = buildPath(root, "input.jsonl");
    write(jsonlInput, `{"text":"scholar@example.org","keep":7}` ~ "\n");
    auto jsonlOut = buildPath(root, "output.jsonl");
    auto jsonlErr = buildPath(root, "jsonl-errors.txt");
    auto jsonlSide = buildPath(root, "jsonl-side.jsonl");
    {
        auto input = File(jsonlInput, "rb");
        auto output = File(jsonlOut, "wb");
        auto errors = File(jsonlErr, "wb");
        auto child = spawnProcess([binary, "run", "--input", "-", "--output",
            "-", "--sidecar-output", jsonlSide, "--jsonl-fields", "text",
            "--dataset-namespace", "synthetic-public-v1", "--source-key",
            "pii-handoff", "--max-jsonl-line-bytes", "4096",
            "--max-jsonl-output-bytes", "4096"] ~ stageArgs("mask"), input,
            output, errors);
        input.close(); output.close(); errors.close();
        int raw; rusage usage;
        need(wait4(child.processID, &raw, 0, &usage) == child.processID &&
            WIFEXITED(raw) && WEXITSTATUS(raw) == 0, "selected JSONL failed");
    }
    need(readText(jsonlOut) ==
            `{"keep":7,"text":"*******************"}` ~ "\n",
        "selected JSONL stdout changed");
    contentPrivate("selected JSONL", [readText(jsonlOut), readText(jsonlSide),
        readText(jsonlErr)]);

    auto equivalentInput = buildPath(root, "equivalent.txt");
    auto cliOutput = buildPath(root, "equivalent-cli.out");
    auto cliAudit = buildPath(root, "equivalent-cli.audit");
    auto jsonOutput = buildPath(root, "equivalent-json.out");
    auto jsonAudit = buildPath(root, "equivalent-json.audit");
    auto jsonConfig = buildPath(root, "mask.json");
    write(equivalentInput, handoffInput);
    auto cliEquivalent = invoke([binary, "run", "--input", equivalentInput,
        "--output",
        cliOutput, "--sidecar-output", cliAudit, "--threads", "1"] ~
        stageArgs("mask"), root, "equivalent-cli");
    auto jsonEquivalent = invoke([binary, "run", "--input", equivalentInput,
        "--output",
            jsonOutput, "--sidecar-output", jsonAudit, "--threads", "1",
            "--config", jsonConfig], root, "equivalent-json");
    need(cliEquivalent.status == 0 && jsonEquivalent.status == 0 &&
        read(cliOutput) == read(jsonOutput) && read(cliAudit) == read(jsonAudit),
        "CLI/JSON configuration equivalence failed");
    contentPrivate("CLI/JSON equivalence", [cliEquivalent.stdoutText,
        cliEquivalent.stderrText, jsonEquivalent.stdoutText,
        jsonEquivalent.stderrText, readText(cliOutput), readText(cliAudit),
        readText(jsonOutput), readText(jsonAudit)]);

    auto durableIn = buildPath(root, "durable.txt");
    auto durableOut = buildPath(root, "durable.out");
    auto durableSide = buildPath(root, "durable.audit");
    auto manifest = buildPath(root, "durable.db");
    write(durableIn, handoffInput);
    auto args = [binary, "run", "--input", durableIn, "--output", durableOut,
        "--sidecar-output", durableSide, "--manifest", manifest,
        "--threads", "1"] ~ stageArgs("mask");
    auto first = invoke(args, root, "durable-first");
    need(first.status == 0, "durable initial run failed");
    contentPrivate("durable first", [readText(durableOut),
        readText(durableSide), first.stdoutText, first.stderrText]);
    auto expectedSide = read(durableSide);
    write(durableSide, "stale-sidecar");
    auto stale = invoke(args, root, "durable-stale");
    need(stale.status != 0,
        "stale sidecar was accepted on restart");
    contentPrivate("durable stale diagnostics", [stale.stdoutText,
        stale.stderrText]);
    auto retried = invoke(args ~ ["--manifest-retry"], root, "durable-retry");
    need(retried.status == 0 && read(durableSide) == expectedSide,
        "durable retry failed");
    contentPrivate("durable retry", [readText(durableOut),
        readText(durableSide), retried.stdoutText, retried.stderrText]);
    return JSONValue([
        "cli_json_equivalent": JSONValue(true),
        "validate": JSONValue(true), "dry_run": JSONValue(true),
        "explain": JSONValue(true), "local_tree": JSONValue(true),
        "selected_jsonl": JSONValue(true),
        "selected_jsonl_stdout_utf8": JSONValue(
            `{"keep":7,"text":"*******************"}` ~ "\n"),
        "durable_restart_refusal": JSONValue(true),
        "durable_retry": JSONValue(true),
        "threads_1_4_exact": JSONValue(true),
        "privacy_canaries": JSONValue(true),
        "thread_manifests": JSONValue([
            "threads_1": JSONValue(["primary": firstTree, "sidecar": firstSide]),
            "threads_4": JSONValue(["primary": fourthTree, "sidecar": fourthSide])])]);
}

private JSONValue deterministicMatrix(string binary) {
    auto root = buildPath(tempDir, "scrubbed-pii-matrix-" ~
        randomUUID.toString);
    mkdirRecurse(root);
    scope (exit) if (exists(root)) rmdirRecurse(root);
    write(buildPath(root, "mask.json"), piiConfig("mask"));
    return runMatrix(binary, root);
}

private JSONValue canonicalHandoffArgv() {
    JSONValue[] result;
    foreach (arg; ["<SCRUBBED>", "run", "--input", "-", "--output", "-",
            "--sidecar-output", "<AUDIT>", "--jsonl-fields", "text",
            "--dataset-namespace", "synthetic-public-v1", "--source-key",
            "pii-handoff", "--max-jsonl-line-bytes", "4096",
            "--max-jsonl-output-bytes", "4096", "--stage",
            "privacy=pii-four-class", "--stage-option",
            "max-input-bytes=integer:1048576", "--stage-option",
            "max-findings=integer:4096", "--stage-option", "policy=text:mask"])
        result ~= JSONValue(arg);
    return JSONValue(result);
}

private struct HandoffRun { string stdoutText, stderrText, auditText; }

private HandoffRun runHandoff(string binary, string root, string label) {
    auto inputPath = buildPath(root, "handoff.jsonl");
    auto outputPath = buildPath(root, label ~ "-output.jsonl");
    auto errorPath = buildPath(root, label ~ "-errors.txt");
    auto auditPath = buildPath(root, label ~ "-audit.jsonl");
    write(inputPath, handoffStdin);
    {
        auto input = File(inputPath, "rb");
        auto output = File(outputPath, "wb");
        auto errors = File(errorPath, "wb");
        auto child = spawnProcess([binary, "run", "--input", "-", "--output",
            "-", "--sidecar-output", auditPath, "--jsonl-fields", "text",
            "--dataset-namespace", "synthetic-public-v1", "--source-key",
            "pii-handoff", "--max-jsonl-line-bytes", "4096",
            "--max-jsonl-output-bytes", "4096"] ~ stageArgs("mask"), input,
            output, errors);
        input.close(); output.close(); errors.close();
        int raw; rusage usage;
        need(wait4(child.processID, &raw, 0, &usage) == child.processID &&
            WIFEXITED(raw) && WEXITSTATUS(raw) == 0, "handoff command failed");
    }
    auto audit = readText(auditPath);
    auto stdoutText = readText(outputPath);
    auto stderrText = readText(errorPath);
    need(stdoutText == handoffStdout &&
        parseJSON(audit)["output_sha256"].str == hashText(handoffMasked),
        "handoff stdout/audit mismatch");
    contentPrivate("handoff", [stdoutText, stderrText, audit]);
    return HandoffRun(stdoutText, stderrText, audit);
}

private JSONValue handoff(string binary, string root) {
    auto actual = runHandoff(binary, root, "handoff");
    return JSONValue([
        "license": JSONValue("CC0-1.0"),
        "provenance": JSONValue([
            "kind": JSONValue("authored-synthetic"),
            "author": JSONValue("scrubbed project"),
            "source": JSONValue("benchmarks/pii_pipeline_check.d"),
            "network_data": JSONValue(false),
            "private_data": JSONValue(false)]),
        "executable": JSONValue("<SCRUBBED>"),
        "argv": canonicalHandoffArgv(),
        "stdin_utf8": JSONValue(handoffStdin),
        "expected_stdout_utf8": JSONValue(handoffStdout),
        "expected_stdout_sha256": JSONValue(hashText(handoffStdout)),
        "fixture_utf8": JSONValue(handoffInput),
        "fixture_sha256": JSONValue(hashText(handoffInput)),
        "expected_transformed_utf8": JSONValue(handoffMasked),
        "expected_transformed_sha256": JSONValue(hashText(handoffMasked)),
        "expected_audit_utf8": JSONValue(actual.auditText),
        "expected_audit_sha256": JSONValue(hashText(actual.auditText))]);
}

private void exactMetricRows(JSONValue[] recorded, JSONValue[] rerun) {
    need(recorded.length == rerun.length, "rerun metric cardinality mismatch");
    foreach (i; 0 .. recorded.length)
        foreach (key; ["fixture", "policy", "input_bytes", "output_bytes",
                "audit_bytes", "input_sha256", "output_sha256",
                "audit_sha256", "document_id", "config_sha256",
                "analyzer_sha256", "policy_sha256"])
            need(recorded[i][key] == rerun[i][key],
                "rerun metric binding mismatch: " ~ key);
    foreach (i; 0 .. recorded.length) {
        foreach (key; ["wall_seconds", "user_seconds", "system_seconds"]) {
            auto observed = recorded[i][key].floating;
            auto fresh = rerun[i][key].floating;
            need(observed >= 0 && observed <= 300 && fresh >= 0 &&
                fresh <= 300 && observed <= fresh * 20 + 1 &&
                fresh <= observed * 20 + 1,
                "resource metric outside bounded rerun envelope: " ~ key);
        }
        auto observedRss = recorded[i]["peak_rss_bytes"].integer;
        auto freshRss = rerun[i]["peak_rss_bytes"].integer;
        need(observedRss > 0 && observedRss <= 8L * 1024 * 1024 * 1024 &&
            freshRss > 0 && freshRss <= 8L * 1024 * 1024 * 1024 &&
            observedRss <= freshRss * 4 + 256L * 1024 * 1024 &&
            freshRss <= observedRss * 4 + 256L * 1024 * 1024,
            "peak RSS outside bounded rerun envelope");
    }
}

private void validateManifest(JSONValue manifest, bool sidecar) {
    need(manifest.type == JSONType.array && manifest.array.length == 4,
        "thread manifest cardinality mismatch");
    string prior;
    foreach (i, item; manifest.array) {
        auto expected = i.to!string ~ ".txt" ~
            (sidecar ? ".pii-audit.json" : "");
        need(item["path"].str == expected &&
            (i == 0 || item["path"].str > prior) &&
            item["bytes"].integer > 0 && digest(item["sha256"].str),
            "thread manifest is incomplete or noncanonical");
        prior = item["path"].str;
    }
}

private void validate(JSONValue report, string binary = null) {
    need(report.type == JSONType.object && report["schema"].str == schema,
        "wrong schema");
    auto revision = report["source_revision"].str;
    need(revisionDigest(revision) &&
        execute(["git", "cat-file", "-e", revision ~ "^{commit}"]).status == 0,
        "source revision is not lowercase 40-hex and resolvable");
    auto recordedCompilerVersion = execute([
        report["compiler"]["executable"].str, "--version"]);
    need(recordedCompilerVersion.status == 0 &&
        recordedCompilerVersion.output.splitLines.length != 0 &&
        recordedCompilerVersion.output.splitLines[0].strip ==
            report["compiler"]["version"].str &&
        report["compiler"]["flags"].str == flags &&
        report["compiler"]["executable"].str.length != 0 &&
        digest(report["compiler"]["executable_sha256"].str) &&
        report["compiler"]["version"].str.length != 0 &&
        hashFile(report["compiler"]["executable"].str) ==
            report["compiler"]["executable_sha256"].str,
        "compiler/flags identity mismatch");
    auto build = report["build"];
    need(build["schema"].str == buildSchema &&
        build["source_revision"].str == revision &&
        build["source_tree_git_oid"].str ==
            report["identities"]["source_tree_git_oid"].str &&
        build["artifact_sha256"].str ==
            report["identities"]["target_binary_sha256"].str &&
        digest(build["source_archive_sha256"].str) &&
        digest(build["dub_recipe_sha256"].str) &&
        digest(build["dub_lock_sha256"].str) &&
        build["build_working_tree"].str == "exact-git-archive" &&
        build["dflags"].str == flags &&
        build["normalization"]["uuid_bytes_hex"].str ==
            "000102030405060708090a0b0c0d0e0f" &&
        build["compiler"]["executable"].str ==
            report["compiler"]["executable"].str &&
        build["compiler"]["sha256"].str ==
            report["compiler"]["executable_sha256"].str &&
        build["compiler"]["version"].str ==
            report["compiler"]["version"].str &&
        hashFile(build["dub"]["executable"].str) ==
            build["dub"]["sha256"].str &&
        commandVersion(build["dub"]["executable"].str) ==
            build["dub"]["version"].str &&
        hashFile("/usr/bin/codesign") ==
            build["normalization"]["codesign_sha256"].str &&
        hashFile("/usr/bin/strip") ==
            build["normalization"]["strip_sha256"].str,
        "build receipt is not bound to source/tools/artifact");
    auto identities = report["identities"];
    foreach (key; ["target_binary_sha256", "harness_source_sha256",
            "stage_source_sha256", "audit_source_sha256", "clean_fixture_sha256",
            "finding_fixture_sha256", "disabled_config_sha256",
            "report_config_sha256", "mask_config_sha256", "redact_config_sha256"])
        need(digest(identities[key].str), "invalid identity digest: " ~ key);
    need(revisionDigest(identities["source_tree_git_oid"].str),
        "invalid source tree identity");
    need(identities["clean_fixture_sha256"].str == hashText(cleanFixture()) &&
        identities["finding_fixture_sha256"].str == hashText(heavyFixture()) &&
        identities["disabled_config_sha256"].str == hashText(disabledConfig()) &&
        identities["report_config_sha256"].str == hashText(piiConfig("report")) &&
        identities["mask_config_sha256"].str == hashText(piiConfig("mask")) &&
        identities["redact_config_sha256"].str == hashText(piiConfig("redact")),
        "fixture/config identity mismatch");
    need(identities["harness_source_sha256"].str == hashFile(
            "benchmarks/pii_pipeline_check.d") &&
        identities["stage_source_sha256"].str == hashFile(
            "source/stages/pii_four_class.d") &&
        identities["audit_source_sha256"].str == hashFile(
            "source/effects/pii_audit.d"),
        "recorded source identity does not match checkout");
    auto revisionStage = execute(["git", "show", revision ~
        ":source/stages/pii_four_class.d"]);
    auto revisionAudit = execute(["git", "show", revision ~
        ":source/effects/pii_audit.d"]);
    auto revisionHarness = execute(["git", "show", revision ~
        ":benchmarks/pii_pipeline_check.d"]);
    auto revisionTree = execute(["git", "rev-parse", revision ~ "^{tree}"]);
    need(revisionStage.status == 0 && revisionAudit.status == 0 &&
        revisionHarness.status == 0 && revisionTree.status == 0 &&
        hashText(revisionStage.output) == identities["stage_source_sha256"].str &&
        hashText(revisionAudit.output) == identities["audit_source_sha256"].str &&
        hashText(revisionHarness.output) ==
            identities["harness_source_sha256"].str &&
        revisionTree.output.strip == identities["source_tree_git_oid"].str,
        "source revision is not bound to the exact recorded source tree");
    auto metrics = report["metrics"].array;
    need(metrics.length == 8, "metric cardinality mismatch");
    string[string] documentByFixture;
    bool[string] seenRows;
    foreach (entry; metrics) {
        auto fixture = entry["fixture"].str;
        auto policy = entry["policy"].str;
        need((fixture == "clean" || fixture == "finding-heavy") &&
            (policy == "disabled" || policy == "report" ||
                policy == "mask" || policy == "redact"),
            "unknown fixture/policy matrix row");
        auto rowKey = fixture ~ "/" ~ policy;
        need(rowKey !in seenRows, "duplicate fixture/policy matrix row");
        seenRows[rowKey] = true;
        need(entry["input_bytes"].integer == inputCap &&
            entry["output_bytes"].integer >= 0 && entry["audit_bytes"].integer >= 0 &&
            entry["wall_seconds"].floating >= 0 &&
            entry["wall_seconds"].floating <= 300 &&
            entry["user_seconds"].floating >= 0 &&
            entry["user_seconds"].floating <= 300 &&
            entry["system_seconds"].floating >= 0 &&
            entry["system_seconds"].floating <= 300 &&
            entry["peak_rss_bytes"].integer > 0 &&
            entry["peak_rss_bytes"].integer <= 8L * 1024 * 1024 * 1024,
            "invalid metric domain");
        foreach (key; ["input_sha256", "output_sha256", "audit_sha256",
                "config_sha256", "analyzer_sha256", "policy_sha256"])
            need(digest(entry[key].str), "invalid metric digest: " ~ key);
        need(entry["config_sha256"].str == identities[policy ~
            "_config_sha256"].str, "metric/config mismatch");
        if (policy == "disabled")
            need(entry["document_id"].str == "NOT_APPLICABLE" &&
                entry["audit_bytes"].integer == 0, "disabled audit mismatch");
        else {
            need(entry["document_id"].str.length == 71 &&
                entry["document_id"].str[0 .. 7] == "doc:v1:",
                "invalid document identity");
            auto prior = fixture in documentByFixture;
            if (prior is null)
                documentByFixture[fixture] = entry["document_id"].str;
            else need(*prior == entry["document_id"].str,
                "document identity changed across policies");
            need(entry["analyzer_sha256"].str == hashText(analyzerIdentity) &&
                entry["policy_sha256"].str == hashText(policyIdentity ~ "/" ~
                    policy), "analyzer/policy identity mismatch");
        }
    }
    foreach (fixture; ["clean", "finding-heavy"])
        foreach (policy; ["disabled", "report", "mask", "redact"])
            need(((fixture ~ "/" ~ policy) in seenRows) !is null,
                "missing fixture/policy matrix row");
    if (binary.length) exactMetricRows(metrics, deterministicMetrics(binary));
    auto matrix = report["actual_binary"];
    foreach (key; ["cli_json_equivalent", "validate", "dry_run", "explain",
            "local_tree", "selected_jsonl", "durable_restart_refusal",
            "durable_retry", "threads_1_4_exact", "privacy_canaries"])
        need(matrix[key].type == JSONType.true_, "matrix proof missing: " ~ key);
    need(matrix["selected_jsonl_stdout_utf8"].str ==
        `{"keep":7,"text":"*******************"}` ~ "\n",
        "selected JSONL exact stdout evidence mismatch");
    auto manifests = matrix["thread_manifests"];
    foreach (threads; ["threads_1", "threads_4"]) {
        validateManifest(manifests[threads]["primary"], false);
        validateManifest(manifests[threads]["sidecar"], true);
    }
    need(manifests["threads_1"] == manifests["threads_4"],
        "one/four-thread complete manifests differ");
    if (binary.length)
        need(matrix == deterministicMatrix(binary),
            "actual-binary evidence differs from fresh bounded rerun");
    auto gc = report["gc"];
    if (gc["status"].str == "SUPPORTED")
        need(gc["allocated_bytes"].integer >= 0 &&
            gc["allocated_bytes"].integer <= 8L * 1024 * 1024 * 1024 &&
            gc["collections"].integer >= 0 &&
            gc["collections"].integer <= 1_000_000 &&
            gc["semantics"].str.canFind("D-runtime GC-only"),
            "invalid D-GC measurement");
    else need(gc["status"].str == "UNSUPPORTED" &&
        gc["reason"].str.length != 0, "unsupported D-GC metric lacks reason");
    if (binary.length)
        need(gc == deterministicGc(binary),
            "D-GC evidence differs from fresh bounded rerun");
    auto handoff = report["handoff"];
    need(handoff["license"].str == "CC0-1.0" &&
        handoff["provenance"].object.length == 5 &&
        handoff["provenance"]["kind"].str == "authored-synthetic" &&
        handoff["provenance"]["author"].str == "scrubbed project" &&
        handoff["provenance"]["source"].str ==
            "benchmarks/pii_pipeline_check.d" &&
        handoff["provenance"]["network_data"].type == JSONType.false_ &&
        handoff["provenance"]["private_data"].type == JSONType.false_ &&
        handoff["executable"].str == "<SCRUBBED>" &&
        handoff["argv"] == canonicalHandoffArgv() &&
        handoff["stdin_utf8"].str == handoffStdin &&
        handoff["expected_stdout_utf8"].str == handoffStdout &&
        handoff["expected_stdout_sha256"].str == hashText(handoffStdout) &&
        handoff["fixture_utf8"].str == handoffInput &&
        handoff["expected_transformed_utf8"].str == handoffMasked &&
        handoff["fixture_sha256"].str == hashText(handoff["fixture_utf8"].str) &&
        handoff["expected_transformed_sha256"].str ==
            hashText(handoff["expected_transformed_utf8"].str) &&
        handoff["expected_audit_sha256"].str ==
            hashText(handoff["expected_audit_utf8"].str),
        "handoff byte/hash mismatch");
    auto audit = parseJSON(handoff["expected_audit_utf8"].str);
    need(handoff["expected_audit_utf8"].str.length <= 1024 * 1024,
        "handoff audit exceeds cap");
    need(audit["input_revision_sha256"].str == hashText(handoffInput) &&
        audit["output_sha256"].str == hashText(handoffMasked) &&
        !handoff["expected_audit_utf8"].str.canFind("scholar@example.org"),
        "handoff audit binding/privacy mismatch");
    need(audit["schema"].str == "scrubbed-pii-audit-v1" &&
        audit["analyzer"]["name"].str == "pii.four-class" &&
        audit["analyzer"]["version"].str == "four-class:v1" &&
        audit["policy_version"].str == policyIdentity &&
        audit["options"]["policy"].str == "mask" &&
        audit["unions"].array.length == 2,
        "handoff audit semantic identity/cardinality mismatch");
    long previousEnd = -1;
    foreach (unionValue; audit["unions"].array) {
        need(unionValue["start"].integer >= 0 &&
            unionValue["start"].integer >= previousEnd &&
            unionValue["end"].integer > unionValue["start"].integer &&
            unionValue["contributors"].array.length == 1,
            "handoff union order/cardinality mismatch");
        auto contributor = unionValue["contributors"].array[0];
        need(contributor["start"].integer == unionValue["start"].integer &&
            contributor["end"].integer == unionValue["end"].integer,
            "handoff contributor binding mismatch");
        previousEnd = unionValue["end"].integer;
    }
    if (binary.length) {
        auto root = buildPath(tempDir, "scrubbed-pii-handoff-check-" ~
            randomUUID.toString);
        mkdirRecurse(root);
        scope (exit) if (exists(root)) rmdirRecurse(root);
        auto actual = runHandoff(binary, root, "check");
        need(actual.stdoutText == handoff["expected_stdout_utf8"].str &&
            actual.auditText == handoff["expected_audit_utf8"].str,
            "executed handoff bytes differ from report");
    }
}

private void mustReject(JSONValue good, string binary,
        void delegate(ref JSONValue) mutate, string message,
        bool needsRerun = false) {
    auto changed = parseJSON(good.toString);
    mutate(changed);
    bool rejected;
    try validate(changed, needsRerun ? binary : null);
    catch (Exception) rejected = true;
    need(rejected, "mutation accepted: " ~ message);
}

private void mutationControls(JSONValue good, string binary) {
    mustReject(good, binary, (ref JSONValue r) {
        r["source_revision"] = JSONValue(olderResolvableRevision);
    }, "older resolvable source revision");
    mustReject(good, binary, (ref JSONValue r) {
        r["compiler"]["version"] = JSONValue("forged compiler version");
    }, "compiler version execution binding");
    mustReject(good, binary, (ref JSONValue r) {
        r["build"]["source_revision"] = JSONValue(olderResolvableRevision);
    }, "build receipt source revision");
    mustReject(good, binary, (ref JSONValue r) {
        r["build"]["artifact_sha256"] = JSONValue(hashText("arbitrary"));
    }, "build receipt arbitrary binary");
    mustReject(good, binary, (ref JSONValue r) {
        r["identities"]["source_tree_git_oid"] =
            JSONValue("0".replicate(40));
    }, "wrong source tree identity");
    mustReject(good, binary, (ref JSONValue r) {
        auto text = "{";
        r["handoff"]["expected_audit_utf8"] = JSONValue(text);
        r["handoff"]["expected_audit_sha256"] = JSONValue(hashText(text));
    }, "malformed audit");
    mustReject(good, binary, (ref JSONValue r) {
        auto audit = parseJSON(r["handoff"]["expected_audit_utf8"].str);
        audit["padding"] = JSONValue("x".replicate(1024 * 1024));
        auto text = audit.toString;
        r["handoff"]["expected_audit_utf8"] = JSONValue(text);
        r["handoff"]["expected_audit_sha256"] = JSONValue(hashText(text));
    }, "oversize audit");
    foreach (field; ["input_revision_sha256", "output_sha256"])
        mustReject(good, binary, (ref JSONValue r) {
            auto audit = parseJSON(r["handoff"]["expected_audit_utf8"].str);
            audit[field] = JSONValue(hashText("wrong"));
            auto text = audit.toString;
            r["handoff"]["expected_audit_utf8"] = JSONValue(text);
            r["handoff"]["expected_audit_sha256"] = JSONValue(hashText(text));
        }, "wrong audit " ~ field);
    mustReject(good, binary, (ref JSONValue r) {
        r["metrics"][0]["config_sha256"] = JSONValue(hashText("wrong"));
    }, "wrong config_sha256");
    foreach (field; ["analyzer_sha256", "policy_sha256"])
        mustReject(good, binary, (ref JSONValue r) {
            r["metrics"][1][field] = JSONValue(hashText("wrong"));
        }, "wrong " ~ field);
    mustReject(good, binary, (ref JSONValue r) {
        r["metrics"][1]["document_id"] = JSONValue(
            "doc:v1:" ~ "0".replicate(64));
    }, "wrong document identity");
    mustReject(good, binary, (ref JSONValue r) {
        auto audit = parseJSON(r["handoff"]["expected_audit_utf8"].str);
        auto unions = audit["unions"].array;
        auto first = unions[0];
        unions[0] = unions[$ - 1];
        unions[$ - 1] = first;
        auto text = audit.toString;
        r["handoff"]["expected_audit_utf8"] = JSONValue(text);
        r["handoff"]["expected_audit_sha256"] = JSONValue(hashText(text));
    }, "contributor/order corruption");
    mustReject(good, binary, (ref JSONValue r) {
        auto audit = parseJSON(r["handoff"]["expected_audit_utf8"].str);
        audit["unions"].array.length = 0;
        auto text = audit.toString;
        r["handoff"]["expected_audit_utf8"] = JSONValue(text);
        r["handoff"]["expected_audit_sha256"] = JSONValue(hashText(text));
    }, "cardinality corruption");
    mustReject(good, binary, (ref JSONValue r) {
        auto audit = parseJSON(r["handoff"]["expected_audit_utf8"].str);
        audit["leaked_content"] = JSONValue("scholar@example.org");
        auto text = audit.toString;
        r["handoff"]["expected_audit_utf8"] = JSONValue(text);
        r["handoff"]["expected_audit_sha256"] = JSONValue(hashText(text));
    }, "leaked content");
    mustReject(good, binary, (ref JSONValue r) {
        r["actual_binary"]["durable_restart_refusal"] = JSONValue(false);
    }, "stale sidecar");
    foreach (field; ["input_bytes", "output_bytes", "audit_bytes"])
        mustReject(good, binary, (ref JSONValue r) {
            r["metrics"][1][field] = JSONValue(
                r["metrics"][1][field].integer + 1);
        }, "wrong metric " ~ field, true);
    foreach (field; ["input_sha256", "output_sha256", "audit_sha256"])
        mustReject(good, binary, (ref JSONValue r) {
            r["metrics"][1][field] = JSONValue(hashText("wrong-" ~ field));
        }, "wrong metric " ~ field, true);
    mustReject(good, binary, (ref JSONValue r) {
        r["metrics"][1]["fixture"] = JSONValue("finding-heavy");
    }, "wrong metric fixture");
    mustReject(good, binary, (ref JSONValue r) {
        r["metrics"][1]["policy"] = JSONValue("mask");
    }, "wrong metric policy");
    mustReject(good, binary, (ref JSONValue r) {
        r["metrics"][0] = r["metrics"][1];
    }, "duplicate matrix row");
    mustReject(good, binary, (ref JSONValue r) {
        r["actual_binary"]["selected_jsonl_stdout_utf8"] = JSONValue("{}");
    }, "selected JSONL stdout");
    mustReject(good, binary, (ref JSONValue r) {
        r["actual_binary"]["thread_manifests"]["threads_4"]["primary"]
            [0]["sha256"] = JSONValue(hashText("wrong-manifest"));
    }, "thread manifest digest");
    mustReject(good, binary, (ref JSONValue r) {
        foreach (threads; ["threads_1", "threads_4"])
            foreach (ref item; r["actual_binary"]["thread_manifests"]
                    [threads]["primary"].array)
                item["sha256"] = JSONValue("0".replicate(64));
    }, "paired same-value thread manifest rebinding", true);
    mustReject(good, binary, (ref JSONValue r) {
        r["actual_binary"]["thread_manifests"]["threads_4"]["sidecar"]
            .array.length = 3;
    }, "thread manifest cardinality");
    mustReject(good, binary, (ref JSONValue r) {
        auto manifest = r["actual_binary"]["thread_manifests"]
            ["threads_4"]["primary"].array;
        auto first = manifest[0];
        manifest[0] = manifest[1];
        manifest[1] = first;
    }, "thread manifest order");
    mustReject(good, binary, (ref JSONValue r) {
        r["handoff"]["argv"][1] = JSONValue("validate");
    }, "handoff argv");
    mustReject(good, binary, (ref JSONValue r) {
        r["handoff"]["provenance"]["author"] = JSONValue("");
    }, "handoff provenance");
    mustReject(good, binary, (ref JSONValue r) {
        r["handoff"]["fixture_utf8"] = JSONValue("wrong\n");
        r["handoff"]["fixture_sha256"] = JSONValue(hashText("wrong\n"));
    }, "handoff fixture bytes");
    mustReject(good, binary, (ref JSONValue r) {
        r["handoff"]["expected_transformed_utf8"] = JSONValue("wrong\n");
        r["handoff"]["expected_transformed_sha256"] =
            JSONValue(hashText("wrong\n"));
    }, "handoff transformed bytes");
    mustReject(good, binary, (ref JSONValue r) {
        r["handoff"]["expected_stdout_utf8"] = JSONValue("{}");
        r["handoff"]["expected_stdout_sha256"] = JSONValue(hashText("{}"));
    }, "handoff executed stdout");
    mustReject(good, binary, (ref JSONValue r) {
        r["actual_binary"]["privacy_canaries"] = JSONValue(false);
    }, "privacy proof status");
    foreach (field; ["wall_seconds", "user_seconds", "system_seconds"])
        mustReject(good, binary, (ref JSONValue r) {
            r["metrics"][0][field] = JSONValue(1_000_000_000.5);
        }, "extreme resource metric " ~ field);
    mustReject(good, binary, (ref JSONValue r) {
        r["metrics"][0]["peak_rss_bytes"] = JSONValue(9_000_000_000_000_000L);
    }, "extreme peak RSS");
    mustReject(good, binary, (ref JSONValue r) {
        r["gc"] = JSONValue(["status": JSONValue("SUPPORTED"),
            "semantics": JSONValue("D-runtime GC-only; excludes native allocations"),
            "allocated_bytes": JSONValue(9_000_000_000_000_000L),
            "allocated_bytes_semantics": JSONValue("forged"),
            "collections": JSONValue(9_000_000_000_000_000L)]);
    }, "extreme D-GC evidence");
}

private JSONValue generate(string binary, JSONValue buildReceipt,
        string reportPath) {
    need(exists(binary), "target binary does not exist");
    auto root = buildPath(tempDir, "scrubbed-pii-evidence-" ~ randomUUID.toString);
    mkdirRecurse(root);
    scope (exit) if (exists(root)) rmdirRecurse(root);
    auto cleanPath = buildPath(root, "clean.txt");
    auto heavyPath = buildPath(root, "finding-heavy.txt");
    write(cleanPath, cleanFixture());
    write(heavyPath, heavyFixture());
    foreach (policy; ["disabled", "report", "mask", "redact"])
        write(buildPath(root, policy ~ ".json"), policy == "disabled" ?
            disabledConfig() : piiConfig(policy));
    auto metrics = deterministicMetrics(binary);
    auto matrix = deterministicMatrix(binary);
    auto compiler = execute(["ldc2", "--version"]);
    auto compilerPath = execute(["which", "ldc2"]);
    auto revision = execute(["git", "rev-parse", "HEAD"]);
    auto sourceTree = execute(["git", "rev-parse", "HEAD^{tree}"]);
    need(compiler.status == 0 && compilerPath.status == 0 &&
        revision.status == 0 && sourceTree.status == 0,
        "compiler/source identity probe failed");
    auto resolvedCompiler = compilerPath.output.strip;
    auto report = JSONValue([
        "schema": JSONValue(schema),
        "source_revision": JSONValue(revision.output.strip),
        "build": buildReceipt,
        "compiler": JSONValue(["executable": JSONValue(resolvedCompiler),
            "executable_sha256": JSONValue(hashFile(resolvedCompiler)),
            "version": JSONValue(compiler.output.splitLines[0]),
            "flags": JSONValue(flags)]),
        "identities": JSONValue([
            "source_tree_git_oid": JSONValue(sourceTree.output.strip),
            "target_binary_sha256": JSONValue(hashFile(binary)),
            "harness_source_sha256": JSONValue(hashFile(
                "benchmarks/pii_pipeline_check.d")),
            "stage_source_sha256": JSONValue(hashFile(
                "source/stages/pii_four_class.d")),
            "audit_source_sha256": JSONValue(hashFile(
                "source/effects/pii_audit.d")),
            "clean_fixture_sha256": JSONValue(hashText(cleanFixture())),
            "finding_fixture_sha256": JSONValue(hashText(heavyFixture())),
            "disabled_config_sha256": JSONValue(hashText(disabledConfig())),
            "report_config_sha256": JSONValue(hashText(piiConfig("report"))),
            "mask_config_sha256": JSONValue(hashText(piiConfig("mask"))),
            "redact_config_sha256": JSONValue(hashText(piiConfig("redact")))]),
        "metrics": JSONValue(metrics),
        "gc": gcEvidence(binary, root, heavyPath),
        "actual_binary": matrix,
        "handoff": handoff(binary, root),
        "unsupported": JSONValue([
            JSONValue("total-process allocations: unsupported; D-GC is not a substitute"),
            JSONValue("cross-platform performance: unsupported; one local observation only")]),
        "nonclaims": JSONValue([
            JSONValue("no complete de-identification claim"),
            JSONValue("no Presidio or model-backed NER comparison"),
            JSONValue("no speed, streaming, or detector-fusion claim")])]);
    validate(report, binary);
    mutationControls(report, binary);
    write(reportPath, report.toPrettyString ~ "\n");
    return report;
}

private void checkOnce(string reportPath, string binaryPath) {
        auto report = parseJSON(readText(reportPath));
        auto binary = absolutePath(binaryPath);
        need(hashFile(binary) ==
            report["identities"]["target_binary_sha256"].str,
            "target binary identity mismatch");
        auto rebuiltPath = buildPath(tempDir, "scrubbed-pii-rebuilt-" ~
            randomUUID.toString, "scrubbed");
        auto rebuilt = buildArtifact(report["source_revision"].str,
            rebuiltPath);
        scope (exit) if (exists(dirName(rebuiltPath)))
            rmdirRecurse(dirName(rebuiltPath));
        need(rebuilt.receipt == report["build"] &&
            hashFile(rebuilt.path) == hashFile(binary),
            "fresh archived-source build differs from receipt/artifact");
        validate(report, binary);
        mutationControls(report, binary);
}

private void concurrentStrictCheck(string self, string report, string binary) {
    auto root = buildPath(tempDir, "scrubbed-pii-concurrent-check-" ~
        randomUUID.toString);
    mkdirRecurse(root);
    scope (exit) if (exists(root)) rmdirRecurse(root);
    auto input = File("/dev/null", "rb");
    auto out1 = File(buildPath(root, "one.stdout"), "wb");
    auto err1 = File(buildPath(root, "one.stderr"), "wb");
    auto out2 = File(buildPath(root, "two.stdout"), "wb");
    auto err2 = File(buildPath(root, "two.stderr"), "wb");
    auto first = spawnProcess([self, "--check-one", report, binary], input,
        out1, err1);
    auto second = spawnProcess([self, "--check-one", report, binary], input,
        out2, err2);
    input.close(); out1.close(); err1.close(); out2.close(); err2.close();
    int rawFirst, rawSecond; rusage usage;
    need(wait4(first.processID, &rawFirst, 0, &usage) == first.processID &&
        wait4(second.processID, &rawSecond, 0, &usage) == second.processID &&
        WIFEXITED(rawFirst) && WEXITSTATUS(rawFirst) == 0 &&
        WIFEXITED(rawSecond) && WEXITSTATUS(rawSecond) == 0,
        "concurrent strict checks failed: " ~
        readText(buildPath(root, "one.stderr")) ~
        readText(buildPath(root, "two.stderr")));
}

int main(string[] args) {
    if (args.length == 4 && args[1] == "--check-one") {
        checkOnce(args[2], args[3]);
        return 0;
    }
    if (args.length == 4 && args[1] == "--check") {
        concurrentStrictCheck(absolutePath(args[0]), absolutePath(args[2]),
            absolutePath(args[3]));
        writeln("pii pipeline evidence: report and mutation controls passed");
        return 0;
    }
    need(args.length == 4 && args[1] == "--generate",
        "usage: pii-pipeline-check --generate REPORT ARTIFACT | " ~
        "pii-pipeline-check --check REPORT ARTIFACT");
    auto revision = execute(["git", "rev-parse", "HEAD"]);
    need(revision.status == 0, "cannot resolve generation revision");
    auto built = buildArtifact(revision.output.strip, absolutePath(args[3]));
    generate(built.path, built.receipt, args[2]);
    writeln("pii pipeline evidence: wrote ", args[2], " using ", built.path);
    return 0;
}
