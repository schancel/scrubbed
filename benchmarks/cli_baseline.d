// Full-process, file-boundary baseline. Build with ldc2 -O -release.
module cli_baseline;

import std.algorithm.searching : canFind, endsWith, startsWith;
import std.algorithm.sorting : sort;
import std.array : replicate;
import std.conv : to;
import std.digest.sha : sha256Of;
import std.file : SpanMode, dirEntries, exists, mkdirRecurse, read, readText,
    remove, rmdirRecurse, tempDir, write;
import std.json : JSONValue;
import std.path : buildPath, dirSeparator, relativePath;
import std.process : execute;
import std.string : split, splitLines, strip;
import std.uuid : randomUUID;
import std.stdio : stderr, writeln;

private string digest(string path) {
    import std.digest : toHexString;
    return toHexString(sha256Of(read(path))).to!string;
}

private string checked(string[] command) {
    auto result = execute(command);
    if (result.status != 0)
        throw new Exception(command[0] ~ " exited " ~ result.status.to!string ~
            ": " ~ result.output);
    return result.output.strip;
}

private JSONValue strings(string[] values) {
    JSONValue[] result;
    foreach (value; values) result ~= JSONValue(value);
    return JSONValue(result);
}

private string cpuModelFromProc(string cpuinfo) {
    foreach (key; ["model name", "Hardware", "Processor"]) {
        foreach (line; cpuinfo.splitLines) {
            auto fields = line.split(":");
            if (fields.length >= 2 && fields[0].strip == key && fields[1].strip.length)
                return fields[1].strip;
        }
    }
    return "unavailable (/proc/cpuinfo has no CPU model field)";
}

private string cpuModel(bool darwin) {
    if (darwin) {
        auto result = execute(["sysctl", "-n", "machdep.cpu.brand_string"]);
        return result.status == 0 && result.output.strip.length
            ? result.output.strip
            : "unavailable (machdep.cpu.brand_string not reported)";
    }
    try {
        return cpuModelFromProc(readText("/proc/cpuinfo"));
    } catch (Exception) {
        return "unavailable (/proc/cpuinfo unreadable)";
    }
}

private void selfTest() {
    if (cpuModelFromProc("model name : Example CPU\n") != "Example CPU" ||
        cpuModelFromProc("Hardware : Example SoC\n") != "Example SoC" ||
        !cpuModelFromProc("processor : 0\n").startsWith("unavailable"))
        throw new Exception("Linux CPU model parse regression");
}

// Commands in a shareable report must be reproducible without publishing the
// current machine's checkout, account, or temporary-directory names.
private JSONValue publicCommand(string[] command, string binary,
                                string fixtureRoot) {
    string[] safe;
    foreach (arg; command) {
        if (arg == binary) safe ~= "<scrubbed-binary>";
        else if (arg.startsWith(fixtureRoot ~ dirSeparator))
            safe ~= "<fixture-root>/" ~ relativePath(arg, fixtureRoot);
        else safe ~= arg;
    }
    return strings(safe);
}

private double metric(string report, string prefix) {
    foreach (line; report.splitLines) {
        auto trimmed = line.strip;
        if (trimmed.startsWith(prefix)) {
            auto tail = trimmed[prefix.length .. $].strip;
            // BSD time uses "value  label"; GNU time uses "label: value".
            if (prefix == "maximum resident set size")
                return tail.to!double;
            return tail.to!double;
        }
    }
    throw new Exception("missing time metric " ~ prefix ~ " in: " ~ report);
}

private JSONValue timed(string[] command, bool darwin) {
    string[] wrapper = darwin ? ["/usr/bin/time", "-l", "-p"] :
        ["/usr/bin/time", "-v"];
    wrapper ~= command;
    auto result = execute(wrapper);
    if (result.status != 0)
        throw new Exception(command[0] ~ " exited " ~ result.status.to!string ~
            ": " ~ result.output);
    JSONValue sample = JSONValue(["status": JSONValue(result.status)]);
    if (darwin) {
        sample["wall_seconds"] = metric(result.output, "real ");
        sample["user_seconds"] = metric(result.output, "user ");
        sample["system_seconds"] = metric(result.output, "sys ");
        foreach (line; result.output.splitLines)
            if (line.strip.endsWith("maximum resident set size")) {
                sample["peak_rss_bytes"] = line.strip.split(" ")[0].to!long;
                return sample;
            }
        throw new Exception("missing BSD peak RSS: " ~ result.output);
    }
    // GNU time reports wall as m:ss or h:mm:ss and RSS in KiB.
    foreach (line; result.output.splitLines) {
        auto parts = line.split(": ");
        if (parts.length < 2) continue;
        auto value = parts[$-1].strip;
        if (line.startsWith("\tUser time")) sample["user_seconds"] = value.to!double;
        if (line.startsWith("\tSystem time")) sample["system_seconds"] = value.to!double;
        if (line.startsWith("\tMaximum resident set size"))
            sample["peak_rss_bytes"] = value.to!long * 1024;
        if (line.startsWith("\tElapsed (wall clock) time")) {
            auto fields = value.split(":");
            double seconds;
            foreach (field; fields) seconds = seconds * 60 + field.to!double;
            sample["wall_seconds"] = seconds;
        }
    }
    foreach (key; ["wall_seconds", "user_seconds", "system_seconds", "peak_rss_bytes"])
        if (key !in sample.object) throw new Exception("missing GNU time metric " ~ key);
    return sample;
}

private JSONValue runCase(string name, string[] command, string input,
                          string output, string expected, bool darwin,
                          int repetitions) {
    JSONValue[] samples;
    foreach (_; 0 .. repetitions) {
        // Each run has a fresh destination; never measure a failed overwrite.
        if (exists(output)) remove(output);
        auto sample = timed(command, darwin);
        if (!exists(output) || read(output) != read(expected))
            throw new Exception(name ~ " failed exact-output quality gate");
        sample["output_sha256"] = digest(output);
        samples ~= sample;
    }
    JSONValue result = JSONValue(["name": JSONValue(name)]);
    result["command"] = strings(command);
    result["input_sha256"] = digest(input);
    result["expected_sha256"] = digest(expected);
    result["exact_output"] = true;
    result["samples"] = JSONValue(samples);
    return result;
}

private JSONValue runTree(string binary, string root, bool darwin) {
    auto inputRoot = buildPath(root, "tree-input");
    auto outputRoot = buildPath(root, "tree-output");
    mkdirRecurse(buildPath(inputRoot, "nested"));
    JSONValue[] fixtureFiles;
    foreach (i; 0 .. 32) {
        auto relative = i % 2 ? "nested/doc-" ~ i.to!string ~ ".txt" :
            "doc-" ~ i.to!string ~ ".txt";
        auto path = buildPath(inputRoot, relative);
        string raw;
        foreach (_; 0 .. 2048) raw ~= "alpha\r\nbeta\rgamma\x01delta\n";
        write(path, raw);
        JSONValue fixture = JSONValue(["path": JSONValue(relative)]);
        fixture["input_sha256"] = digest(path);
        fixtureFiles ~= fixture;
    }
    auto command = [binary, "--input", inputRoot, "--output", outputRoot,
        "--filters", "normalize-line-endings,strip-control", "--threads", "1"];
    JSONValue[] samples;
    foreach (_; 0 .. 5) {
        if (exists(outputRoot)) rmdirRecurse(outputRoot);
        auto sample = timed(command, darwin);
        bool[string] expectedNames;
        foreach (fixture; fixtureFiles) expectedNames[fixture["path"].str] = true;
        size_t seen;
        foreach (entry; dirEntries(outputRoot, SpanMode.depth, false)) {
            auto relative = relativePath(entry.name, outputRoot);
            if (entry.isDir && relative == "nested") continue;
            if (!entry.isFile || relative !in expectedNames)
                throw new Exception("unexpected tree output entry " ~ relative);
            seen++;
        }
        if (seen != fixtureFiles.length)
            throw new Exception("tree output set differs from expected fixture set");
        foreach (ref fixture; fixtureFiles) {
            auto path = buildPath(outputRoot, fixture["path"].str);
            if (!exists(path)) throw new Exception("missing tree output " ~ path);
            auto text = readText(path);
            if (text.length != 22 * 2048 || text !=
                "alpha\nbeta\ngammadelta\n".replicate(2048))
                throw new Exception("tree exact-output quality gate failed: " ~ path);
            fixture["expected_sha256"] = digest(path);
        }
        sample["exact_output"] = true;
        samples ~= sample;
    }
    JSONValue result = JSONValue(["name": JSONValue("normalization/tree/scrubbed")]);
    result["command"] = strings(command);
    result["files"] = JSONValue(fixtureFiles);
    result["samples"] = JSONValue(samples);
    return result;
}

int main(string[] args) {
    try {
        if (args.length == 2 && args[1] == "--self-test") {
            selfTest();
            writeln("version and CPU-model parsers passed");
            return 0;
        }
        if (args.length != 2)
            throw new Exception("usage: cli_baseline SCRUBBED_BINARY");
        auto os = checked(["uname", "-s"]);
        bool darwin = os == "Darwin";
        if (!darwin && os != "Linux") throw new Exception("BSD/GNU time only");
        auto root = buildPath(tempDir, "scrubbed-baseline-" ~ randomUUID.toString);
        mkdirRecurse(root);
        scope(exit) rmdirRecurse(root);

        auto normalization = buildPath(root, "normalization.txt");
        auto normalized = buildPath(root, "normalized.txt");
        // Deterministic generated fixtures: no third-party bytes are redistributed.
        string raw, canonical;
        foreach (i; 0 .. 262_144) {
            raw ~= "alpha\r\nbeta\rgamma\x01delta\n";
            canonical ~= "alpha\nbeta\ngammadelta\n";
        }
        write(normalization, raw);
        write(normalized, canonical);

        JSONValue[] cases;
        auto outputPath = buildPath(root, "out.txt");
        cases ~= runCase("normalization/scrubbed", [args[1], "--input",
            normalization, "--output", outputPath, "--filters",
            "normalize-line-endings,strip-control", "--threads", "1"],
            normalization, outputPath, normalized, darwin, 5);
        cases ~= runTree(args[1], root, darwin);

        foreach (ref result; cases) {
            string[] command;
            foreach (arg; result["command"].array) command ~= arg.str;
            result["command"] = publicCommand(command, args[1], root);
        }

        JSONValue report = JSONValue(["schema": JSONValue("scrubbed-cli-baseline-v2")]);
        report["source_sha"] = checked(["git", "rev-parse", "HEAD"]);
        report["fixture_policy"] = "generated deterministic UTF-8; exact byte equality required";
        report["os"] = JSONValue([
            "name": JSONValue(os),
            "release": JSONValue(checked(["uname", "-r"])),
            "architecture": JSONValue(checked(["uname", "-m"]))]);
        report["cpu_model"] = cpuModel(darwin);
        if (darwin) report["hardware_model"] = checked(["sysctl", "-n", "hw.model"]);
        report["compiler"] = checked(["ldc2", "--version"]).splitLines[0];
        report["scrubbed_binary_sha256"] = digest(args[1]);
        report["harness_sha256"] = digest("benchmarks/cli_baseline.d");
        report["binary_build_command"] = "dub build --build=release --compiler=ldc2";
        report["harness_build_command"] =
            "ldc2 -O -release benchmarks/cli_baseline.d -of=<path>";
        report["unsupported"] = strings([
            "no independently sourced recursive-tree executable comparator; no process-equivalent tree baseline",
            "trafilatura HTML extraction: scrubbed html2md is unimplemented; #59 owns future pipeline comparison",
            "no independently sourced executable matches current normalize-line-endings plus strip-control semantics",
            "no independently verified quality-matched executable for current quote/entity semantics"]);
        report["time_variant"] = darwin ? "BSD time -l -p; RSS bytes" :
            "GNU time -v; RSS KiB converted to bytes";
        report["cases"] = JSONValue(cases);
        auto published = report.toString;
        if (published.canFind(root) || published.canFind(args[1]) ||
            published.canFind(checked(["uname", "-n"])))
            throw new Exception("result contains a private run path or hostname");
        writeln(published);
        return 0;
    } catch (Exception error) {
        stderr.writeln("baseline: ", error.msg);
        return 1;
    }
}
