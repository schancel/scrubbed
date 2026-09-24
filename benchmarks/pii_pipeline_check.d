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
import std.file : SpanMode, dirEntries, exists, mkdirRecurse, read, readText,
    rmdirRecurse, tempDir, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : absolutePath, buildPath, relativePath;
import std.process : execute, spawnProcess;
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
        File input = File.init) {
    auto stdoutPath = buildPath(root, label ~ ".stdout");
    auto stderrPath = buildPath(root, label ~ ".stderr");
    auto source = input.isOpen ? input : File("/dev/null", "rb");
    auto output = File(stdoutPath, "wb");
    auto errors = File(stderrPath, "wb");
    auto timer = StopWatch(AutoStart.yes);
    auto child = spawnProcess(command, source, output, errors);
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
    auto output = buildPath(root, fixture ~ "-" ~ policy ~ ".out");
    auto audit = buildPath(root, fixture ~ "-" ~ policy ~ ".audit");
    auto config = buildPath(root, policy ~ ".json");
    auto command = [binary, "run", "--input", inputPath, "--output", output,
        "--threads", "1"];
    if (policy == "disabled") command ~= ["--config", config];
    else command ~= ["--sidecar-output", audit] ~ stageArgs(policy);
    auto result = invoke(command, root, "metric-" ~ fixture ~ "-" ~ policy);
    need(result.status == 0, fixture ~ "/" ~ policy ~ " failed: " ~
        result.stderrText);
    auto inputBytes = cast(const(ubyte)[]) read(inputPath);
    auto outputBytes = cast(const(ubyte)[]) read(output);
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
    contentPrivate("metric diagnostics", [result.stdoutText, result.stderrText]);
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
    enum root = ".dub/pii-pipeline-evidence-v1";
    if (exists(root)) rmdirRecurse(root);
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

private JSONValue fileManifest(string root) {
    auto canonicalRoot = absolutePath(root);
    string[] paths;
    foreach (entry; dirEntries(canonicalRoot, SpanMode.depth, false))
        if (entry.isFile) paths ~= relativePath(entry.name, canonicalRoot);
    paths.sort;
    JSONValue[] result;
    foreach (path; paths) {
        auto bytes = cast(const(ubyte)[]) read(buildPath(canonicalRoot, path));
        result ~= JSONValue(["path": JSONValue(path),
            "bytes": JSONValue(cast(long) bytes.length),
            "sha256": JSONValue(hashBytes(bytes))]);
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
        auto sideManifest = fileManifest(side);
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
    enum root = ".dub/pii-pipeline-matrix-v1";
    if (exists(root)) rmdirRecurse(root);
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
    need(report["compiler"]["flags"].str == flags &&
        report["compiler"]["executable"].str.length != 0 &&
        digest(report["compiler"]["executable_sha256"].str) &&
        report["compiler"]["version"].str.length != 0 &&
        hashFile(report["compiler"]["executable"].str) ==
            report["compiler"]["executable_sha256"].str,
        "compiler/flags identity mismatch");
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
            entry["user_seconds"].floating >= 0 &&
            entry["system_seconds"].floating >= 0 &&
            entry["peak_rss_bytes"].integer > 0,
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
            gc["collections"].integer >= 0 &&
            gc["semantics"].str.canFind("D-runtime GC-only"),
            "invalid D-GC measurement");
    else need(gc["status"].str == "UNSUPPORTED" &&
        gc["reason"].str.length != 0, "unsupported D-GC metric lacks reason");
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
        void delegate(ref JSONValue) mutate, string message) {
    auto changed = parseJSON(good.toString);
    mutate(changed);
    bool rejected;
    try validate(changed, binary);
    catch (Exception) rejected = true;
    need(rejected, "mutation accepted: " ~ message);
}

private void mutationControls(JSONValue good, string binary) {
    mustReject(good, binary, (ref JSONValue r) {
        r["source_revision"] = JSONValue(olderResolvableRevision);
    }, "older resolvable source revision");
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
        }, "wrong metric " ~ field);
    foreach (field; ["input_sha256", "output_sha256", "audit_sha256"])
        mustReject(good, binary, (ref JSONValue r) {
            r["metrics"][1][field] = JSONValue(hashText("wrong-" ~ field));
        }, "wrong metric " ~ field);
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
    }, "paired same-value thread manifest rebinding");
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
}

private JSONValue generate(string binary, string reportPath) {
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

int main(string[] args) {
    if (args.length == 4 && args[1] == "--check") {
        auto report = parseJSON(readText(args[2]));
        auto binary = absolutePath(args[3]);
        need(hashFile(binary) ==
            report["identities"]["target_binary_sha256"].str,
            "target binary identity mismatch");
        validate(report, binary);
        mutationControls(report, binary);
        writeln("pii pipeline evidence: report and mutation controls passed");
        return 0;
    }
    need(args.length == 3, "usage: pii-pipeline-check SCRUBBED REPORT | " ~
        "pii-pipeline-check --check REPORT SCRUBBED");
    generate(absolutePath(args[1]), args[2]);
    writeln("pii pipeline evidence: wrote ", args[2]);
    return 0;
}
