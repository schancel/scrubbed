// Read-only summary of the publication-safe v4 pipeline resource report.
module pipeline_resource_check;

import std.conv : to;
import std.file : readText;
import std.json : parseJSON;
import std.stdio : writeln;

int main(string[] args) {
    if (args.length != 2) {
        writeln("usage: pipeline_resource_check REPORT_JSON");
        return 2;
    }
    try {
        auto report = parseJSON(readText(args[1]));
        if (report["schema"].str != "scrubbed-pipeline-v4" ||
            report["cases"].array.length != 12)
            throw new Exception("not a complete v4 resource report");
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
