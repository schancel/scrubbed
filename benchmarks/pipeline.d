// Local full-process benchmark. Build with ldc2 -O3 -release.
module pipeline;

import std.algorithm.searching : canFind, startsWith;
import std.algorithm.sorting : sort;
import std.conv : to;
import std.digest : toHexString;
import std.digest.sha : sha256Of;
import std.file : SpanMode, dirEntries, exists, mkdirRecurse, read, readText,
    remove, rmdirRecurse, tempDir, write;
import std.json : JSONValue;
import std.path : buildPath, relativePath;
import std.process : execute;
import std.stdio : File, stderr, writeln;
import std.string : split, splitLines, strip;
import std.uuid : randomUUID;

private void require(bool condition, string message) {
    if (!condition) throw new Exception(message);
}

private string hashFile(string path) {
    return toHexString(sha256Of(read(path))).to!string;
}

private string checked(string[] args) {
    auto result = execute(args);
    require(result.status == 0, args[0] ~ " failed: " ~ result.output);
    return result.output.strip;
}

private JSONValue arr(string[] values) {
    JSONValue[] items;
    foreach (value; values) items ~= JSONValue(value);
    return JSONValue(items);
}

private double elapsed(string value) {
    double result;
    foreach (field; value.split(":")) result = result * 60 + field.to!double;
    return result;
}

private JSONValue timed(string[] command, bool mac, bool expectSkip = false) {
    auto result = execute((mac ? ["/usr/bin/time", "-l", "-p"] :
        ["/usr/bin/time", "-v"]) ~ command);
    require(result.status == 0, "timed command failed: " ~ result.output);
    if (expectSkip)
        require(result.output.canFind("skipped"),
            "manifest warm run did not report a verified skip");
    JSONValue sample = JSONValue(["status": JSONValue(result.status)]);
    foreach (line; result.output.splitLines) {
        auto s = line.strip;
        if (mac) {
            if (s.startsWith("real ")) sample["wall_seconds"] = s[5 .. $].strip.to!double;
            if (s.startsWith("user ")) sample["user_seconds"] = s[5 .. $].strip.to!double;
            if (s.startsWith("sys ")) sample["system_seconds"] = s[4 .. $].strip.to!double;
            if (s.canFind("maximum resident set size"))
                sample["peak_rss_bytes"] = s.split(" ")[0].to!long;
        } else {
            auto fields = s.split(": ");
            if (fields.length < 2) continue;
            auto value = fields[$ - 1].strip;
            if (s.startsWith("Elapsed (wall clock) time"))
                sample["wall_seconds"] = elapsed(value);
            if (s.startsWith("User time")) sample["user_seconds"] = value.to!double;
            if (s.startsWith("System time")) sample["system_seconds"] = value.to!double;
            if (s.startsWith("Maximum resident set size"))
                sample["peak_rss_bytes"] = value.to!long * 1024;
        }
    }
    foreach (field; ["wall_seconds", "user_seconds", "system_seconds", "peak_rss_bytes"])
        require((field in sample.object) !is null, "missing time metric " ~ field);
    return sample;
}

private string expectedBytes(size_t records) {
    string result;
    foreach (_; 0 .. records) result ~= "alpha\nbeta\ngammadelta\n";
    return result;
}

private void fixture(string root, size_t files, size_t records) {
    mkdirRecurse(root);
    foreach (i; 0 .. files) {
        auto file = File(buildPath(root, "doc-" ~ i.to!string ~ ".txt"), "wb");
        foreach (_; 0 .. records) file.rawWrite("alpha\r\nbeta\rgamma\x01delta\n");
    }
}

private JSONValue verifyTree(string input, string output, size_t files,
                             size_t records) {
    require(exists(output), "missing output tree");
    string[] found;
    foreach (entry; dirEntries(output, SpanMode.depth, false)) {
        require(entry.isFile, "non-file in output tree");
        found ~= relativePath(entry.name, output);
    }
    found.sort();
    require(found.length == files, "extra or missing output tree entry");
    JSONValue[] identities;
    auto canonical = expectedBytes(records);
    foreach (i; 0 .. files) {
        auto name = "doc-" ~ i.to!string ~ ".txt";
        require(found.canFind(name), "missing expected output file");
        auto outPath = buildPath(output, name);
        require(readText(outPath) == canonical, "wrong output bytes");
        identities ~= JSONValue(["path": JSONValue(name),
            "input_sha256": JSONValue(hashFile(buildPath(input, name))),
            "output_sha256": JSONValue(hashFile(outPath))]);
    }
    return JSONValue(identities);
}

private JSONValue caseRun(string name, string[] command, string input,
                          string output, size_t files, size_t records,
                          bool mac, bool manifest) {
    JSONValue[] samples;
    JSONValue identities;
    foreach (run; 0 .. 3) {
        if (!manifest || run == 0) {
            if (exists(output)) rmdirRecurse(output);
        }
        auto sample = timed(command, mac, manifest && run > 0);
        identities = verifyTree(input, output, files, records);
        sample["exact_output"] = true;
        sample["input_fixture_bytes"] = cast(long)(files * records *
            "alpha\r\nbeta\rgamma\x01delta\n".length);
        sample["expected_output_bytes"] = cast(long)(files * records *
            "alpha\nbeta\ngammadelta\n".length);
        sample["phase"] = run == 0 ? "first-process-warm-OS-unspecified" :
            "new-process-warm-application-cache-empty";
        if (manifest) sample["manifest_phase"] = run == 0 ?
            "first" : "verified-skip";
        samples ~= sample;
    }
    require(samples.length == 3, "partial samples");
    JSONValue result = JSONValue(["name": JSONValue(name),
        "files": identities, "samples": JSONValue(samples)]);
    result["filter_config"] = "normalize-line-endings,strip-control";
    result["filter_config_sha256"] = toHexString(
        sha256Of(cast(ubyte[])"normalize-line-endings,strip-control".dup)).to!string;
    result["command_template"] = manifest ?
        "<scrubbed-binary> --input <fixture-input> --output <fixture-output> --filters normalize-line-endings,strip-control --threads 1 --manifest <manifest-db> --explain" :
        "<scrubbed-binary> --input <fixture-input> --output <fixture-output> --filters normalize-line-endings,strip-control --threads 1";
    return result;
}

private void validate(JSONValue report) {
    require(report["schema"].str == "scrubbed-pipeline-v1", "report schema");
    foreach (key; ["source_sha", "binary_sha256", "harness_sha256", "os",
                   "cpu", "compiler", "build_flags"])
        require(key in report.object && report[key].str.length,
            "missing report metadata " ~ key);
    require(report["cases"].array.length > 0, "zero cases");
    foreach (item; report["cases"].array) {
        require(item["samples"].array.length == 3, "zero/partial samples");
        foreach (sample; item["samples"].array)
            require(sample["exact_output"].boolean && sample["status"].integer == 0,
                "bad sample");
    }
    auto published = report.toString;
    require(!published.canFind(tempDir) && !published.canFind(checked(["uname", "-n"])),
        "private path or hostname in report");
}

private void selfTest() {
    JSONValue report = JSONValue(["schema": JSONValue("scrubbed-pipeline-v1"),
        "source_sha": JSONValue("x"), "binary_sha256": JSONValue("x"),
        "harness_sha256": JSONValue("x"), "os": JSONValue("x"),
        "cpu": JSONValue("x"), "compiler": JSONValue("x"),
        "build_flags": JSONValue("x")]);
    JSONValue sample = JSONValue(["exact_output": JSONValue(true),
        "status": JSONValue(0)]);
    report["cases"] = JSONValue([JSONValue(["samples":
        JSONValue([sample, sample, sample])])]);
    validate(report);
    foreach (key; ["binary_sha256", "harness_sha256", "source_sha", "compiler"]) {
        auto bad = report;
        bad[key] = "";
        bool failed;
        try { validate(bad); } catch (Exception) { failed = true; }
        require(failed, "metadata negative did not fail");
    }
    foreach (count; [0, 1, 2]) {
        auto bad = report;
        JSONValue[] samples;
        foreach (_; 0 .. count) samples ~= sample;
        bad["cases"][0]["samples"] = JSONValue(samples);
        bool failed;
        try { validate(bad); } catch (Exception) { failed = true; }
        require(failed, "sample-count negative did not fail");
    }
    auto bad = report;
    bad["cpu"] = tempDir;
    bool failed;
    try { validate(bad); } catch (Exception) { failed = true; }
    require(failed, "path privacy negative did not fail");
    bad = report;
    bad["cases"][0]["samples"][0]["exact_output"] = false;
    failed = false;
    try { validate(bad); } catch (Exception) { failed = true; }
    require(failed, "false quality claim did not fail");
    auto root = buildPath(tempDir, "scrubbed-pipeline-test-" ~ randomUUID.toString);
    mkdirRecurse(root);
    scope(exit) rmdirRecurse(root);
    auto input = buildPath(root, "input");
    auto output = buildPath(root, "output");
    fixture(input, 1, 1);
    mkdirRecurse(output);
    auto outFile = buildPath(output, "doc-0.txt");
    write(outFile, expectedBytes(1));
    verifyTree(input, output, 1, 1);
    write(outFile, "wrong");
    failed = false;
    try { verifyTree(input, output, 1, 1); } catch (Exception) { failed = true; }
    require(failed, "wrong output negative did not fail");
    write(outFile, expectedBytes(1));
    write(buildPath(output, "extra.txt"), "extra");
    failed = false;
    try { verifyTree(input, output, 1, 1); } catch (Exception) { failed = true; }
    require(failed, "extra output negative did not fail");
    writeln("pipeline release self-test passed");
}

int main(string[] args) {
    try {
        if (args.length == 2 && args[1] == "--self-test") {
            selfTest(); return 0;
        }
        require(args.length == 2 || args.length == 3,
            "usage: pipeline SCRUBBED_BINARY [REPORT_JSON]");
        auto os = checked(["uname", "-s"]);
        require(os == "Darwin" || os == "Linux", "BSD/GNU time required");
        auto root = buildPath(tempDir, "scrubbed-pipeline-" ~ randomUUID.toString);
        mkdirRecurse(root);
        scope(exit) rmdirRecurse(root);
        JSONValue[] cases;
        foreach (index, name; ["many-small", "few-large"]) {
            size_t files = [32, 2][index];
            size_t records = [1024, 16384][index];
            auto input = buildPath(root, name ~ "-input");
            auto output = buildPath(root, name ~ "-output");
            fixture(input, files, records);
            auto command = [args[1], "--input", input, "--output", output,
                "--filters", "normalize-line-endings,strip-control", "--threads", "1"];
            cases ~= caseRun(name, command, input, output, files, records,
                os == "Darwin", false);
            auto manifest = buildPath(root, name ~ ".sqlite");
            command ~= ["--manifest", manifest, "--explain"];
            cases ~= caseRun(name ~ "/manifest", command, input, output,
                files, records, os == "Darwin", true);
        }
        JSONValue report = JSONValue(["schema": JSONValue("scrubbed-pipeline-v1")]);
        report["source_sha"] = checked(["git", "rev-parse", "HEAD"]);
        report["binary_sha256"] = hashFile(args[1]);
        report["harness_sha256"] = hashFile("benchmarks/pipeline.d");
        report["os"] = os ~ " " ~ checked(["uname", "-r"]) ~ " " ~
            checked(["uname", "-m"]);
        report["cpu"] = os == "Darwin" ?
            checked(["sysctl", "-n", "machdep.cpu.brand_string"]) :
            "see /proc/cpuinfo; not captured";
        report["compiler"] = checked(["ldc2", "--version"]).splitLines[0];
        report["build_flags"] = "dub build --build=release --compiler=ldc2; ldc2 -O3 -release benchmarks/pipeline.d";
        report["cases"] = JSONValue(cases);
        report["unsupported"] = arr(["OS cold cache not controlled",
            "peak open FDs and GC not instrumented", "greater-than-RAM preflight/run not performed",
            "process-kill restart injection not included"]);
        validate(report);
        if (args.length == 3) write(args[2], report.toString ~ "\n");
        else writeln(report.toString);
        return 0;
    } catch (Exception error) {
        stderr.writeln("pipeline: ", error.msg);
        return 1;
    }
}
