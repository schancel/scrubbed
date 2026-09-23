// Read-only summary of publication-safe v4/v6 pipeline resource reports.
module pipeline_resource_check;

import std.conv : to;
import std.algorithm.searching : canFind;
import std.file : readText;
import std.json : parseJSON;
import std.stdio : writeln;

private bool digest(string value, size_t length) {
    if (value.length != length) return false;
    foreach (letter; value)
        if (!((letter >= '0' && letter <= '9') ||
              (letter >= 'a' && letter <= 'f') ||
              (letter >= 'A' && letter <= 'F'))) return false;
    return true;
}

int main(string[] args) {
    if (args.length != 2) {
        writeln("usage: pipeline_resource_check REPORT_JSON");
        return 2;
    }
    try {
        auto report = parseJSON(readText(args[1]));
        if (report["schema"].str == "scrubbed-cli-profile-v1") {
            if (report["source_binary_mapping"].str != "ATTESTED" ||
                report["build_attestation"]["schema"].str !=
                    "scrubbed-build-attestation-v4" ||
                report["build_attestation"]["target_sha256"].str !=
                    report["binary_sha256"].str ||
                !digest(report["binary_sha256"].str, 64) ||
                !digest(report["harness_sha256"].str, 64) ||
                report["harness_executable_name"].str !=
                    "scrubbed-pipeline-profile-check" ||
                report["preflight"]["derived_fixture_footprint_bytes"].integer !=
                    134_217_728L * 12 ||
                report["preflight"]["required_scratch_bytes"].integer !=
                    134_217_728L * 48 ||
                report["preflight"]["scratch_free_bytes"].integer <
                    134_217_728L * 48 ||
                report["selector_freeze"]["selectors"].array.length != 5 ||
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
                    foreach (sample; item["result"]["samples"].array)
                        if (!sample["exact_output"].boolean ||
                            sample["exit_code"].integer != 0 ||
                            sample["target_binary_sha256"].str !=
                                report["binary_sha256"].str ||
                            sample["fd_metric_semantics"].str !=
                                "sampled lower bound; not exact peak")
                            throw new Exception("invalid canonical sample");
                }
                foreach (routeIndex, route; layout["durable"].array)
                    if (route["kind"].str !=
                            (routeIndex == 0 ? "manifest-v2" : "journal-v3") ||
                        route["pairs"].array.length != 3)
                        throw new Exception("incomplete durable profile pairs");
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
             report["build_attestation"]["schema"].str !=
                "scrubbed-build-attestation-v4" ||
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
