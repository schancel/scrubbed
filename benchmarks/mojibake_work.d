/// Release-active, D-only work attribution for issue #181.
/// Build with -version=MojibakeWorkProbe; the ordinary product build has no
/// counter API or counter branches.
module mojibake_work;

import core.thread : Thread;
import filters.mojibake : MojibakeEncodingWork, MojibakePassWork,
    MojibakeWorkEvidence, fixMojibake, measureMojibakeWork,
    mojibakeWorkProbePasses;
import std.digest : toHexString;
import std.digest.sha : sha256Of;
import std.conv : to;
import std.exception : enforce;
import std.file : read;
import std.json : JSONValue, parseJSON;
import std.process : execute;
import std.stdio : writeln;
import std.string : splitLines;

version (LDC) {} else static assert(false,
    "mojibake work evidence requires the pinned LDC recipe");
version (MojibakeWorkO3Release) {} else static assert(false,
    "mojibake work evidence requires the O3/release build marker");
version (assert) static assert(false,
    "mojibake work evidence must be compiled with -release");
static assert(__VERSION__ == 2113,
    "mojibake work evidence compiler frontend version changed");

private enum probeSourcePath = "source/filters/mojibake.d";
private enum harnessSourcePath = "benchmarks/mojibake_work.d";
private enum expectedProbeSourceSha256 =
    "A71A31E9A7DCB859B04D0311DEC82A28A3DAA5AE406A0F8854198248BB70A694";
private enum expectedCompilerVersion =
    "LDC - the LLVM D compiler (1.43.0):";
private enum buildFlags = "-O3 -release -d-version=MojibakeWorkProbe " ~
    "-d-version=MojibakeWorkO3Release -Isource";
private enum buildMode = "O3-release";

private string digest(T)(T value) {
    return toHexString(sha256Of(value)).to!string;
}

private string hashFile(string path) {
    return digest(read(path));
}

private string compilerVersion() {
    auto result = execute(["ldc2", "--version"]);
    enforce(result.status == 0 && result.output.splitLines.length != 0,
        "cannot identify the evidence compiler");
    return result.output.splitLines[0];
}

private struct Case {
    string name;
    string input;
    size_t maxPasses = 4;
    bool latin1 = true;
    bool cp1252 = true;
}

private immutable Case[] cases = [
    Case("clean-ascii", "plain ASCII text"),
    Case("clean-unicode", "café 日本語 Ελληνικά"),
    Case("latin1-one-layer", "schÃ¶n", 4, true, false),
    Case("cp1252-one-layer", "donâ€™t", 4, false, true),
    Case("double-mangled", "FranÃƒÂ§ais"),
    Case("triple-mangled", "The Mona Lisa doesnÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢t"),
    Case("local-islands", "🙂 schÃ¶n 東京 donâ€™t 🐈"),
    Case("ambiguous-c2", "🙂 café Â© Ω"),
    Case("incomplete", "東京 Ãx🙂"),
    Case("grouped", "schÃ¶ndonâ€™tFranÃƒÂ§ais")
];

private string caseIdentity(ref const Case spec) {
    return digest(spec.name ~ "\0" ~ spec.input ~ "\0" ~
        spec.maxPasses.to!string ~ "\0" ~ spec.latin1.to!string ~ "\0" ~
        spec.cp1252.to!string);
}

private string caseSetIdentity() {
    string canonical;
    foreach (ref spec; cases) canonical ~= caseIdentity(spec) ~ "\n";
    return digest(canonical);
}

private JSONValue encodingJson(ref const MojibakeEncodingWork work) {
    JSONValue value;
    value["legacy_byte_calls"] = cast(long) work.legacyByteCalls;
    value["legacy_byte_scalars"] = cast(long) work.legacyByteScalars;
    value["cp1252_table_entries"] = cast(long) work.cp1252TableEntries;
    value["legacy_byte_mapped"] = cast(long) work.legacyByteMapped;
    value["legacy_byte_unmapped"] = cast(long) work.legacyByteUnmapped;
    value["sequence_calls"] = cast(long) work.sequenceCalls;
    value["sequence_scalars"] = cast(long) work.sequenceScalars;
    value["sequence_valid"] = cast(long) work.sequenceValid;
    value["sequence_invalid"] = cast(long) work.sequenceInvalid;
    value["can_encode_calls"] = cast(long) work.canEncodeCalls;
    value["can_encode_scalars"] = cast(long) work.canEncodeScalars;
    value["can_encode_success"] = cast(long) work.canEncodeSuccess;
    value["can_encode_failure"] = cast(long) work.canEncodeFailure;
    value["candidate_score_calls"] = cast(long) work.candidateScoreCalls;
    value["candidate_decoded_scalars"] = cast(long) work.candidateDecodedScalars;
    value["candidate_success"] = cast(long) work.candidateSuccess;
    value["candidate_unencodable"] = cast(long) work.candidateUnencodable;
    value["candidate_utf_failure"] = cast(long) work.candidateUtfFailure;
    value["plausibility_calls"] = cast(long) work.plausibilityCalls;
    value["plausibility_scalars"] = cast(long) work.plausibilityScalars;
    value["grouping_attempts"] = cast(long) work.groupingAttempts;
    value["grouping_spans"] = cast(long) work.groupingSpans;
    value["materializations"] = cast(long) work.materializations;
    value["materialized_source_bytes"] = cast(long) work.materializedSourceBytes;
    value["materialized_output_bytes"] = cast(long) work.materializedOutputBytes;
    return value;
}

private void validateEncoding(ref const MojibakeEncodingWork work) {
    enforce(work.legacyByteMapped + work.legacyByteUnmapped ==
        work.legacyByteCalls, "legacy-byte outcomes do not reconcile");
    enforce(work.legacyByteScalars == work.legacyByteCalls,
        "legacy-byte scalar work does not reconcile");
    enforce(work.sequenceValid + work.sequenceInvalid == work.sequenceCalls,
        "sequence outcomes do not reconcile");
    enforce(work.canEncodeSuccess + work.canEncodeFailure == work.canEncodeCalls,
        "can-encode outcomes do not reconcile");
    enforce(work.candidateSuccess + work.candidateUnencodable +
        work.candidateUtfFailure == work.candidateScoreCalls,
        "candidate outcomes do not reconcile");
    enforce(work.groupingSpans <= work.groupingAttempts,
        "grouping spans exceed attempts");
    enforce((work.materializations == 0) ==
        (work.materializedSourceBytes == 0 && work.materializedOutputBytes == 0),
        "materialization byte accounting does not reconcile");
}

private JSONValue passJson(ref const MojibakePassWork pass, size_t index) {
    validateEncoding(pass.latin1);
    validateEncoding(pass.cp1252);
    enforce(pass.scoreZeroExits + pass.wholeWinnerExits +
        pass.localRepairExits + pass.unchangedExits == pass.entered,
        "pass outcomes do not reconcile");
    JSONValue value;
    value["pass"] = cast(long) index;
    value["entered"] = cast(long) pass.entered;
    value["current_plausibility_calls"] =
        cast(long) pass.currentPlausibilityCalls;
    value["current_plausibility_scalars"] =
        cast(long) pass.currentPlausibilityScalars;
    value["score_zero"] = cast(long) pass.scoreZeroExits;
    value["whole_winner"] = cast(long) pass.wholeWinnerExits;
    value["local_repair"] = cast(long) pass.localRepairExits;
    value["unchanged"] = cast(long) pass.unchangedExits;
    value["latin1"] = encodingJson(pass.latin1);
    value["cp1252"] = encodingJson(pass.cp1252);
    return value;
}

private JSONValue caseJson(ref const Case spec) {
    auto evidence = measureMojibakeWork(spec.input, spec.maxPasses,
        spec.latin1, spec.cp1252);
    JSONValue value;
    value["name"] = spec.name;
    value["input_sha256"] = digest(spec.input);
    value["case_identity_sha256"] = caseIdentity(spec);
    value["input_bytes"] = cast(long) spec.input.length;
    value["output_bytes"] = cast(long) evidence.output.length;
    value["changed"] = evidence.output != spec.input;
    JSONValue[] passes;
    foreach (index; 0 .. mojibakeWorkProbePasses) {
        auto pass = evidence.passes[index];
        if (pass.entered) passes ~= passJson(pass, index);
        else {
            enforce(pass == MojibakePassWork.init,
                "unused pass bucket is not empty");
        }
    }
    value["passes"] = JSONValue(passes);
    return value;
}

private JSONValue buildReport() {
    JSONValue root;
    root["schema"] = "scrubbed-mojibake-work-v2";
    root["source_base"] =
        "7eecd67768c7c16a87011cdb7420520468faa16c";
    JSONValue attribution;
    attribution["probe_source_path"] = probeSourcePath;
    attribution["probe_source_sha256"] = hashFile(probeSourcePath);
    attribution["harness_source_path"] = harnessSourcePath;
    attribution["harness_source_sha256"] = hashFile(harnessSourcePath);
    attribution["compiler_vendor"] = __VENDOR__;
    attribution["compiler_version"] = compilerVersion();
    attribution["compiler_frontend_version"] = cast(long) __VERSION__;
    attribution["build_flags"] = buildFlags;
    attribution["build_mode"] = buildMode;
    attribution["case_set_sha256"] = caseSetIdentity();
    root["attribution"] = attribution;
    root["ordinary_algorithm_changed"] = false;
    root["production_optimization_authorized"] = false;
    root["reason"] = "evidence-only landing; no candidate comparison";
    JSONValue[] results;
    foreach (ref spec; cases) results ~= caseJson(spec);
    root["cases"] = JSONValue(results);
    return root;
}

private void validatePublishedGoldens(ref const JSONValue report) {
    auto rows = report["cases"].array;
    enforce(rows.length == cases.length, "work case cardinality differs");

    // These are the exact counts and outcomes published in the README.
    auto local = rows[6];
    enforce(local["name"].str == "local-islands" && local["changed"].boolean,
        "local-island result golden differs");
    auto localPasses = local["passes"].array;
    enforce(localPasses.length == 2 &&
        localPasses[0]["pass"].integer == 0 &&
        localPasses[0]["latin1"]["sequence_calls"].integer == 19 &&
        localPasses[0]["latin1"]["legacy_byte_calls"].integer == 38 &&
        localPasses[0]["cp1252"]["sequence_calls"].integer == 20 &&
        localPasses[0]["cp1252"]["legacy_byte_calls"].integer == 58 &&
        localPasses[0]["local_repair"].integer == 1 &&
        localPasses[0]["whole_winner"].integer == 0 &&
        localPasses[0]["unchanged"].integer == 0 &&
        localPasses[0]["score_zero"].integer == 0 &&
        localPasses[1]["pass"].integer == 1 &&
        localPasses[1]["score_zero"].integer == 1 &&
        localPasses[1]["local_repair"].integer == 0 &&
        localPasses[1]["whole_winner"].integer == 0 &&
        localPasses[1]["unchanged"].integer == 0,
        "local-island pass/encoding golden differs");

    auto ambiguous = rows[7];
    enforce(ambiguous["name"].str == "ambiguous-c2" &&
        !ambiguous["changed"].boolean, "ambiguous-C2 result golden differs");
    auto ambiguousPasses = ambiguous["passes"].array;
    enforce(ambiguousPasses.length == 1 &&
        ambiguousPasses[0]["pass"].integer == 0 &&
        ambiguousPasses[0]["latin1"]["sequence_calls"].integer == 11 &&
        ambiguousPasses[0]["latin1"]["legacy_byte_calls"].integer == 22 &&
        ambiguousPasses[0]["cp1252"]["sequence_calls"].integer == 11 &&
        ambiguousPasses[0]["cp1252"]["legacy_byte_calls"].integer == 22 &&
        ambiguousPasses[0]["unchanged"].integer == 1 &&
        ambiguousPasses[0]["local_repair"].integer == 0 &&
        ambiguousPasses[0]["whole_winner"].integer == 0 &&
        ambiguousPasses[0]["score_zero"].integer == 0,
        "ambiguous-C2 pass/encoding golden differs");

    foreach (rowIndex; 2 .. 6) {
        foreach (pass; rows[rowIndex]["passes"].array) {
            enforce(pass["latin1"]["sequence_calls"].integer == 0 &&
                pass["cp1252"]["sequence_calls"].integer == 0,
                "whole-string sequence-call golden differs");
        }
    }
}

private void validateReport(ref const JSONValue report) {
    enforce(report["schema"].str == "scrubbed-mojibake-work-v2",
        "work evidence schema differs");
    auto attribution = report["attribution"];
    enforce(attribution["probe_source_path"].str == probeSourcePath &&
        attribution["probe_source_sha256"].str == expectedProbeSourceSha256 &&
        attribution["probe_source_sha256"].str == hashFile(probeSourcePath),
        "probe source identity differs");
    enforce(attribution["harness_source_path"].str == harnessSourcePath &&
        attribution["harness_source_sha256"].str == hashFile(harnessSourcePath),
        "harness source identity differs");
    enforce(attribution["compiler_vendor"].str == __VENDOR__ &&
        attribution["compiler_version"].str == expectedCompilerVersion &&
        attribution["compiler_version"].str == compilerVersion() &&
        attribution["compiler_frontend_version"].integer == __VERSION__ &&
        attribution["build_flags"].str == buildFlags &&
        attribution["build_mode"].str == buildMode,
        "compiler/build identity differs");
    enforce(attribution["case_set_sha256"].str == caseSetIdentity(),
        "work case-set identity differs");
    auto rows = report["cases"].array;
    enforce(rows.length == cases.length, "work case cardinality differs");
    foreach (index, ref spec; cases) {
        enforce(rows[index]["name"].str == spec.name &&
            rows[index]["input_sha256"].str == digest(spec.input) &&
            rows[index]["case_identity_sha256"].str == caseIdentity(spec),
            "work case/input identity differs");
    }
    enforce(!report["ordinary_algorithm_changed"].boolean &&
        !report["production_optimization_authorized"].boolean,
        "negative evidence decision differs");
    validatePublishedGoldens(report);
}

private void expectInvalid(JSONValue report, string message) {
    bool rejected;
    try validateReport(report);
    catch (Exception) rejected = true;
    enforce(rejected, message);
}

private void selfTest() {
    auto report = buildReport();
    validateReport(report);

    auto counterMutant = parseJSON(report.toString);
    counterMutant["cases"].array[6]["passes"].array[0]
        ["latin1"]["legacy_byte_calls"] = 39;
    expectInvalid(counterMutant,
        "published exact-count mutation was accepted");

    auto identityMutant = parseJSON(report.toString);
    identityMutant["attribution"]["probe_source_sha256"] =
        "B71A31E9A7DCB859B04D0311DEC82A28A3DAA5AE406A0F8854198248BB70A694";
    expectInvalid(identityMutant, "probe identity mutation was accepted");

    auto inputHashMutant = parseJSON(report.toString);
    inputHashMutant["cases"].array[7]["input_sha256"] =
        "0000000000000000000000000000000000000000000000000000000000000000";
    expectInvalid(inputHashMutant, "case input-hash mutation was accepted");

    enforce(measureMojibakeWork("FranÃƒÂ§ais", 1).output != "Français",
        "one-pass golden unexpectedly completed a double repair");
    bool capacityRejected;
    try measureMojibakeWork("schÃ¶n", mojibakeWorkProbePasses + 1);
    catch (Exception error) capacityRejected =
        error.msg == "mojibake work probe pass count exceeds fixed capacity";
    enforce(capacityRejected, "oversized pass probe was not rejected");

    auto corrupted = measureMojibakeWork("🙂 schÃ¶n 🐈");
    enforce(corrupted.passes[0].latin1.sequenceCalls != 0 &&
        corrupted.passes[0].cp1252.sequenceCalls != 0,
        "local-island probe did not exercise both sequence scanners");
    ++corrupted.passes[0].latin1.legacyByteMapped;
    bool counterRejected;
    try validateEncoding(corrupted.passes[0].latin1);
    catch (Exception) counterRejected = true;
    enforce(counterRejected, "forged counter total was accepted");

    auto falseOutput = measureMojibakeWork("schÃ¶n");
    falseOutput.output = "not the ordinary output";
    bool outputRejected;
    try enforce(falseOutput.output == fixMojibake("schÃ¶n"),
        "instrumented output differs from ordinary execution");
    catch (Exception) outputRejected = true;
    enforce(outputRejected, "forged equivalent-output claim was accepted");

    auto invalid = cast(string)[cast(char) 0xC3];
    string ordinaryFailure;
    string measuredFailure;
    try fixMojibake(invalid);
    catch (Throwable error)
        ordinaryFailure = typeid(error).name ~ ":" ~ error.msg;
    try measureMojibakeWork(invalid);
    catch (Throwable error)
        measuredFailure = typeid(error).name ~ ":" ~ error.msg;
    enforce(ordinaryFailure.length && measuredFailure == ordinaryFailure,
        "instrumented invalid UTF-8 exception differs: " ~ ordinaryFailure ~
        " / " ~ measuredFailure);

    string[2] outputs;
    auto first = new Thread({ outputs[0] =
        measureMojibakeWork("FranÃƒÂ§ais").output; });
    auto second = new Thread({ outputs[1] =
        measureMojibakeWork("🙂 schÃ¶n 🐈").output; });
    first.start();
    second.start();
    first.join();
    second.join();
    enforce(outputs == ["Français", "🙂 schön 🐈"],
        "concurrent caller-owned probes interfere");
    writeln("mojibake work probe self-test passed: ", cases.length,
        " equivalence cases, five mutants, exact attribution/goldens, ",
        "invalid UTF-8, fixed capacity, concurrent reuse");
}

void main(string[] args) {
    enforce(args.length <= 2, "usage: mojibake-work [--self-test]");
    if (args.length == 2) {
        enforce(args[1] == "--self-test", "unknown option: " ~ args[1]);
        selfTest();
        return;
    }
    auto report = buildReport();
    validateReport(report);
    writeln(report.toString);
}
