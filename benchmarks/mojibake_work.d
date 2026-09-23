/// Release-active, D-only work attribution for issue #181.
/// Build with -version=MojibakeWorkProbe; the ordinary product build has no
/// counter API or counter branches.
module mojibake_work;

import core.thread : Thread;
import filters.mojibake : MojibakeEncodingWork, MojibakePassWork,
    MojibakeWorkEvidence, fixMojibake, measureMojibakeWork,
    mojibakeWorkProbePasses;
import std.conv : to;
import std.exception : enforce;
import std.json : JSONValue;
import std.stdio : writeln;

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

private void selfTest() {
    foreach (ref spec; cases) caseJson(spec);
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
        " equivalence cases, two mutants, invalid UTF-8, fixed capacity, concurrent reuse");
}

void main(string[] args) {
    enforce(args.length <= 2, "usage: mojibake-work [--self-test]");
    if (args.length == 2) {
        enforce(args[1] == "--self-test", "unknown option: " ~ args[1]);
        selfTest();
        return;
    }
    JSONValue root;
    root["schema"] = "scrubbed-mojibake-work-v1";
    root["source_base"] =
        "7eecd67768c7c16a87011cdb7420520468faa16c";
    root["ordinary_algorithm_changed"] = false;
    root["production_optimization_authorized"] = false;
    root["reason"] = "evidence-only landing; no candidate comparison";
    JSONValue[] results;
    foreach (ref spec; cases) results ~= caseJson(spec);
    root["cases"] = JSONValue(results);
    writeln(root.toString);
}
