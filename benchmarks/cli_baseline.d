// Full-process, file-boundary baseline. Build with ldc2 -O -release.
module cli_baseline;

import std.algorithm.searching : canFind, endsWith, startsWith;
import std.array : replicate;
import std.conv : to;
import std.digest.sha : sha256Of;
import std.file : exists, mkdirRecurse, read, readText, remove, rmdirRecurse, tempDir, write;
import std.json : JSONValue;
import std.path : buildPath, dirName;
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
        if (args.length != 3)
            throw new Exception("usage: cli_baseline SCRUBBED_BINARY FTFY_BINARY");
        auto os = checked(["uname", "-s"]);
        bool darwin = os == "Darwin";
        if (!darwin && os != "Linux") throw new Exception("BSD/GNU time only");
        auto root = buildPath(tempDir, "scrubbed-baseline-" ~ randomUUID.toString);
        mkdirRecurse(root);
        scope(exit) rmdirRecurse(root);

        auto mojibake = buildPath(root, "mojibake.txt");
        auto repaired = buildPath(root, "repaired.txt");
        auto normalization = buildPath(root, "normalization.txt");
        auto normalized = buildPath(root, "normalized.txt");
        // Deterministic generated fixtures: no third-party bytes are redistributed.
        string damaged, clean, raw, canonical;
        foreach (i; 0 .. 4096) {
            damaged ~= "CafÃ© at noon; the sign said rÃ©sumÃ©.\n";
            clean ~= "Café at noon; the sign said résumé.\n";
        }
        foreach (i; 0 .. 262_144) {
            raw ~= "alpha\r\nbeta\rgamma\x01delta\n";
            canonical ~= "alpha\nbeta\ngammadelta\n";
        }
        write(mojibake, damaged);
        write(repaired, clean);
        write(normalization, raw);
        write(normalized, canonical);

        JSONValue[] cases;
        auto outputPath = buildPath(root, "out.txt");
        cases ~= runCase("mojibake/scrubbed", [args[1], "--input", mojibake,
            "--output", outputPath, "--filters", "fix-mojibake", "--threads", "1"],
            mojibake, outputPath, repaired, darwin, 5);
        cases ~= runCase("mojibake/ftfy", [args[2], "--preserve-entities", "-n",
            "none", "-o", outputPath, mojibake], mojibake, outputPath, repaired, darwin, 5);
        cases ~= runCase("normalization/scrubbed", [args[1], "--input",
            normalization, "--output", outputPath, "--filters",
            "normalize-line-endings,strip-control", "--threads", "1"],
            normalization, outputPath, normalized, darwin, 5);
        // Perl is a separate executable implementation of the two regex-level
        // normalization operations. This fixture intentionally contains ASCII
        // controls only; its result is not a Unicode-domain equivalence claim.
        const perlProgram = `local $/; open my $in, '<:raw', $ARGV[0] or die $!;
            my $s = <$in>; $s =~ s/\r\n?/\n/g;
            $s =~ s/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]//g;
            open my $out, '>:raw', $ARGV[1] or die $!; print $out $s;`;
        cases ~= runCase("normalization/perl", ["/usr/bin/perl", "-e",
            perlProgram, normalization, outputPath], normalization, outputPath,
            normalized, darwin, 5);
        cases ~= runTree(args[1], root, darwin);

        JSONValue report = JSONValue(["schema": JSONValue("scrubbed-cli-baseline-v1")]);
        report["source_sha"] = checked(["git", "rev-parse", "HEAD"]);
        report["fixture_policy"] = "generated deterministic UTF-8; exact byte equality required";
        report["os"] = checked(["uname", "-a"]);
        report["hardware"] = darwin ? checked(["sysctl", "-n", "hw.model"]) :
            checked(["uname", "-m"]);
        report["compiler"] = checked(["ldc2", "--version"]).splitLines[0];
        foreach (line; checked([args[2], "--help"]).splitLines)
            if (line.startsWith("ftfy (fixes text for you)"))
                report["ftfy_version"] = line;
        if ("ftfy_version" !in report.object)
            throw new Exception("ftfy CLI version was not discoverable");
        report["scrubbed_binary_sha256"] = digest(args[1]);
        report["ftfy_binary_sha256"] = digest(args[2]);
        report["harness_sha256"] = digest("benchmarks/cli_baseline.d");
        report["binary_build_command"] = "dub build --build=release --compiler=ldc2";
        report["harness_build_command"] =
            "ldc2 -O -release benchmarks/cli_baseline.d -of=<path>";
        auto python = buildPath(dirName(args[2]), "python");
        report["python_version"] = checked([python, "--version"]);
        report["python_packages"] = checked(["uv", "pip", "list", "--python", python]);
        if (!report["python_packages"].str.canFind("ftfy    6.3.1") ||
            !report["python_packages"].str.canFind("wcwidth 0.8.4"))
            throw new Exception("expected ftfy==6.3.1 and wcwidth==0.8.4");
        report["perl_version"] = checked(["/usr/bin/perl", "-v"]);
        report["perl_capability"] =
            "ASCII CRLF/CR and C0/DEL controls only on generated fixture; not Unicode C1 parity";
        report["unsupported"] = strings([
            "ftfy CLI has no recursive tree input/output mode; no process-equivalent tree baseline",
            "trafilatura HTML extraction: scrubbed html2md is unimplemented; #59 owns future pipeline comparison",
            "no independently verified quality-matched executable for current quote/entity semantics",
            "no independently verified additional mojibake repair executable beyond ftfy"]);
        report["time_variant"] = darwin ? "BSD time -l -p; RSS bytes" :
            "GNU time -v; RSS KiB converted to bytes";
        report["cases"] = JSONValue(cases);
        writeln(report.toString);
        return 0;
    } catch (Exception error) {
        stderr.writeln("baseline: ", error.msg);
        return 1;
    }
}
