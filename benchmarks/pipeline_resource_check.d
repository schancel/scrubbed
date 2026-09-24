// Read-only summary of publication-safe v4/v6 pipeline resource reports.
module pipeline_resource_check;

import std.conv : to;
import std.algorithm.searching : canFind;
import std.array : replicate;
import std.file : readText;
import std.json : JSONValue, parseJSON;
import std.math : isFinite;
import std.stdio : writeln;

private bool digest(string value, size_t length) {
    if (value.length != length) return false;
    foreach (letter; value)
        if (!((letter >= '0' && letter <= '9') ||
              (letter >= 'a' && letter <= 'f') ||
              (letter >= 'A' && letter <= 'F'))) return false;
    return true;
}

private bool validSdkIdentity(JSONValue attestation) {
    try {
        if (attestation["schema"].str !=
                "scrubbed-build-attestation-v6") return true;
        return digest(attestation["sdk_tree_content_sha256"].str, 64) &&
            attestation["sdk_tree_entries"].integer > 0 &&
            attestation["sdk_tree_bytes"].integer > 0;
    } catch (Exception) { return false; }
}

private void selfTest() {
    auto valid = JSONValue([
        "schema": JSONValue("scrubbed-build-attestation-v6"),
        "sdk_tree_content_sha256": JSONValue("a".replicate(64)),
        "sdk_tree_entries": JSONValue(1),
        "sdk_tree_bytes": JSONValue(1)]);
    if (!validSdkIdentity(valid))
        throw new Exception("valid v6 SDK identity was rejected");
    foreach (field; ["sdk_tree_content_sha256", "sdk_tree_entries",
            "sdk_tree_bytes"]) {
        auto missing = parseJSON(valid.toString);
        missing.object.remove(field);
        if (validSdkIdentity(missing))
            throw new Exception("v6 SDK identity accepted without " ~ field);
    }
    auto legacySubstitution = parseJSON(valid.toString);
    legacySubstitution["sdk_tree_metadata_sha256"] = "b".replicate(64);
    legacySubstitution.object.remove("sdk_tree_content_sha256");
    if (validSdkIdentity(legacySubstitution))
        throw new Exception("legacy metadata-only v6 SDK identity was accepted");
    foreach (field; ["sdk_tree_entries", "sdk_tree_bytes"]) {
        auto zero = parseJSON(valid.toString);
        zero[field] = 0;
        if (validSdkIdentity(zero))
            throw new Exception("v6 SDK identity accepted zero " ~ field);
    }
    auto malformed = parseJSON(valid.toString);
    malformed["sdk_tree_content_sha256"] = "not-a-digest";
    if (validSdkIdentity(malformed))
        throw new Exception("malformed v6 SDK content identity was accepted");
    auto historical = JSONValue([
        "schema": JSONValue("scrubbed-build-attestation-v5")]);
    if (!validSdkIdentity(historical))
        throw new Exception("historical attestation SDK handling changed");
    writeln("pipeline resource checker self-test passed (7 negatives)");
}

private bool validProfileSample(JSONValue sample,
        string binary, string tree, long outputBytes) {
    try {
        auto wall = sample["wall_seconds"].floating;
        auto user = sample["user_seconds"].floating;
        auto system = sample["system_seconds"].floating;
        auto fdSamples = sample["fd_poll_samples"].integer;
        auto fdErrors = sample["fd_poll_errors"].integer;
        auto ruSamples = sample["rusage_v4_samples"].integer;
        auto ruErrors = sample["rusage_v4_errors"].integer;
        if (sample["exit_code"].integer != 0 || sample["signal"].integer != 0 ||
            !sample["exact_output"].boolean || !isFinite(wall) || wall <= 0 ||
            !isFinite(user) || user < 0 || !isFinite(system) || system < 0 ||
            sample["peak_rss_bytes"].integer <= 0 ||
            sample["target_binary_sha256"].str != binary ||
            sample["input_bytes"].integer != 134_217_728 ||
            sample["output_bytes"].integer != outputBytes ||
            sample["output_tree_sha256"].str != tree ||
            sample["sampled_peak_fd_lower_bound"].integer <= 0 || fdSamples <= 0 ||
            fdErrors < 0 || sample["fd_poll_interval_milliseconds"].integer != 10 ||
            sample["fd_metric_semantics"].str != "sampled lower bound; not exact peak" ||
            ruSamples < 0 || ruErrors < 0 || fdSamples + fdErrors != ruSamples + ruErrors)
            return false;
        auto io = sample["disk_io"];
        if (io["status"].str == "SUPPORTED")
            return ruSamples > 0 && io["bytes_read"].integer >= 0 &&
                io["bytes_written"].integer >= 0 && io["semantics"].str ==
                "Darwin proc_pid_rusage RUSAGE_INFO_V4 disk-I/O bytes; last successful live-child sample; not syscall bytes";
        return io["status"].str == "UNSUPPORTED" && ruSamples == 0 &&
            io["reason"].str.length != 0;
    } catch (Exception) { return false; }
}

int main(string[] args) {
    if (args.length == 2 && args[1] == "--self-test") {
        try { selfTest(); return 0; }
        catch (Exception error) {
            writeln("resource checker self-test failed: ", error.msg);
            return 1;
        }
    }
    if (args.length != 2) {
        writeln("usage: pipeline_resource_check --self-test | REPORT_JSON");
        return 2;
    }
    try {
        auto report = parseJSON(readText(args[1]));
        if (report["schema"].str == "scrubbed-cli-profile-v1") {
            if (report["source_binary_mapping"].str != "ATTESTED" ||
                (report["build_attestation"]["schema"].str !=
                    "scrubbed-build-attestation-v4" &&
                 report["build_attestation"]["schema"].str !=
                    "scrubbed-build-attestation-v5" &&
                 report["build_attestation"]["schema"].str !=
                    "scrubbed-build-attestation-v6") ||
                !validSdkIdentity(report["build_attestation"]) ||
                report["build_attestation"]["target_sha256"].str !=
                    report["binary_sha256"].str ||
                !digest(report["binary_sha256"].str, 64) ||
                !digest(report["harness_sha256"].str, 64) ||
                report["harness_executable_name"].str !=
                    "scrubbed-pipeline-profile-check" ||
                report["harness_build_recipe"].str !=
                    "ldc2 -O3 -release <PROFILE_SOURCE> -of=<STANDARD_TMP>/scrubbed-pipeline-profile-check" ||
                report["harness_compiler_executable_sha256"].str !=
                    report["build_attestation"]["compiler_executable_sha256"].str ||
                report["harness_compiler_version"].str !=
                    report["build_attestation"]["compiler_version"].str ||
                report["preflight"]["derived_fixture_footprint_bytes"].integer !=
                    134_217_728L * 12 ||
                report["preflight"]["required_scratch_bytes"].integer !=
                    134_217_728L * 48 ||
                report["preflight"]["scratch_free_bytes"].integer <
                    134_217_728L * 48 ||
                report["selector_freeze"]["selectors"].array.length != 5 ||
                report["selector_freeze"]["expected_tree_sha256"].str !=
                    "1CA96072CB1A056D38EC6A95E52C17D4ADF46BE3293740307A0A0DB98964662D" ||
                report["selector_freeze"]["expected_concatenated_sha256"].str !=
                    "30B29564DC4C991F3BB7EC53F0269FE09E76FA617897F81A4E545E1DB43B3BE2" ||
                report["selector_freeze"]["canonical_identity"].str !=
                    "job:v3:c985d95c6c2b8b13c2354bede8649d1557a13c4e211e647f804787e002c10ed1" ||
                report["layouts"].array.length != 2)
                throw new Exception("not a complete canonical CLI profile");
            foreach (layoutIndex, layout; report["layouts"].array) {
                auto expectedName = layoutIndex == 0 ? "many-small" : "few-large";
                auto expectedFiles = layoutIndex == 0 ? 4096 : 8;
                if (layout["name"].str != expectedName ||
                    layout["input_bytes"].integer != 134_217_728 ||
                    layout["input_files"].array.length != expectedFiles ||
                    layout["ordinary"].array.length != 4 ||
                    layout["durable"].array.length != 2)
                    throw new Exception("incomplete canonical layout matrix");
                foreach (item; layout["ordinary"].array) {
                    if (item["result"]["samples"].array.length != 5)
                        throw new Exception("incomplete canonical samples");
                    auto mixed = item["workload"].str == "mixed";
                    auto tree = mixed ? layout["mixed_expected_tree_sha256"].str :
                        layout["scalar_expected_tree_sha256"].str;
                    auto bytes = mixed ? layout["mixed_expected_bytes"].integer :
                        layout["scalar_expected_bytes"].integer;
                    foreach (sample; item["result"]["samples"].array)
                        if (!validProfileSample(sample,
                            report["binary_sha256"].str, tree, bytes))
                            throw new Exception("invalid canonical sample");
                }
                foreach (routeIndex, route; layout["durable"].array) {
                    if (route["kind"].str !=
                            (routeIndex == 0 ? "manifest-v2" : "journal-v3") ||
                        route["pairs"].array.length != 3)
                        throw new Exception("incomplete durable profile pairs");
                    foreach (pair; route["pairs"].array)
                        foreach (phase; ["first", "skip"])
                            if (!validProfileSample(pair[phase],
                                report["binary_sha256"].str,
                                layout["mixed_expected_tree_sha256"].str,
                                layout["mixed_expected_bytes"].integer))
                                throw new Exception("invalid durable resource sample");
                }
                writeln(expectedName, ": input=", layout["input_bytes"].integer,
                    " ordinary-cases=4 x 5 durable-routes=2 x 3 pairs");
            }
            auto serialized = report.toString;
            if (serialized.canFind("/Users/") || serialized.canFind("Users\\/") ||
                serialized.canFind("/private/var/") || serialized.canFind("private\\/var"))
                throw new Exception("canonical report leaks local paths");
            writeln("Harness SHA-256: ", report["harness_sha256"].str);
            writeln("Target SHA-256: ", report["binary_sha256"].str);
            return 0;
        }
        auto attested = report["schema"].str == "scrubbed-pipeline-v6";
        if ((!attested && report["schema"].str != "scrubbed-pipeline-v4") ||
            report["cases"].array.length != 12)
            throw new Exception("not a complete v4/v6 resource report");
        if (attested &&
            (report["source_binary_mapping"].str != "ATTESTED" ||
                (report["build_attestation"]["schema"].str !=
                    "scrubbed-build-attestation-v4" &&
                 report["build_attestation"]["schema"].str !=
                    "scrubbed-build-attestation-v5" &&
                 report["build_attestation"]["schema"].str !=
                    "scrubbed-build-attestation-v6") ||
             !validSdkIdentity(report["build_attestation"]) ||
             report["build_attestation"]["target_sha256"].str !=
                report["binary_sha256"].str ||
             !digest(report["build_attestation"]["source_archive_sha256"].str, 64) ||
             !digest(report["build_attestation"]["argparse_inputs_sha256"].str, 64) ||
             report["build_attestation"]["argparse_version"].str != "2.0.2" ||
             report["build_attestation"]["native_tools"].array.length != 9 ||
             !digest(report["build_attestation"]
                ["native_prebuild_commands_sha256"].str, 64) ||
             report["build_attestation"]["target_relative_path"].str !=
                "scrubbed"))
            throw new Exception("inconsistent v6 build attestation");
        writeln("RAM bytes: ", report["ram_bytes"].integer);
        writeln("Harness SHA-256: ", report["harness_sha256"].str);
        writeln("Target SHA-256: ", report["binary_sha256"].str);
        writeln("Scratch free bytes before fixture: ",
            report["large_preflight"]["scratch_free_bytes_before_fixture"].integer);
        foreach (item; report["cases"].array) {
            if (item["samples"].array.length != 3)
                throw new Exception("incomplete samples");
            double minWall = double.max, maxWall = 0;
            double minCpu = double.max, maxCpu = 0;
            long maxRss, inputBytes, outputBytes;
            foreach (sample; item["samples"].array) {
                if (!sample["exact_output"].boolean || sample["status"].integer != 0)
                    throw new Exception("failed exact-output sample");
                if (attested && sample["target_binary_sha256"].str !=
                    report["binary_sha256"].str)
                    throw new Exception("mixed v6 target sample attribution");
                auto wall = sample["wall_seconds"].floating;
                if (wall < minWall) minWall = wall;
                if (wall > maxWall) maxWall = wall;
                auto cpu = sample["user_seconds"].floating +
                    sample["system_seconds"].floating;
                if (cpu < minCpu) minCpu = cpu;
                if (cpu > maxCpu) maxCpu = cpu;
                if (sample["peak_rss_bytes"].integer > maxRss)
                    maxRss = sample["peak_rss_bytes"].integer;
                inputBytes = sample["input_tree_bytes_observed"].integer;
                outputBytes = sample["output_tree_bytes_observed"].integer;
            }
            writeln(item["name"].str, ": input=", inputBytes,
                " output=", outputBytes, " wall=[", minWall,
                ",", maxWall, "] CPU=[", minCpu, ",", maxCpu,
                "] max RSS=", maxRss);
        }
        return 0;
    } catch (Exception error) {
        writeln("invalid report: ", error.msg);
        return 1;
    }
}
