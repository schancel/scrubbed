/// Full-process, exact-output comparison on a larger synthetic repair file.
/// Pin ftfy==6.3.1 and wcwidth==0.8.4 as documented before running.
module mojibake_scale;

import std.array : appender;
import std.conv : to;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.digest : toHexString;
import std.digest.sha : sha256Of;
import std.file : exists, mkdir, read, readText, remove, rmdirRecurse,
    tempDir, write;
import std.json : JSONValue;
import std.path : buildPath, dirName;
import std.process : execute;
import std.stdio : writeln;
import std.string : split, splitLines, strip;
import std.uuid : randomUUID;

private string digest(string path) {
    return toHexString(sha256Of(read(path))).to!string;
}

private string checked(string[] command) {
    auto result = execute(command);
    if (result.status != 0) throw new Exception(command[0] ~ " failed");
    return result.output.strip;
}

private string cpuModel(string os) {
    if (os == "Darwin") return checked(["sysctl", "-n", "machdep.cpu.brand_string"]);
    if (os == "Linux") {
        foreach (line; readText("/proc/cpuinfo").splitLines) {
            auto fields = line.split(":");
            if (fields.length > 1 && fields[0].strip == "model name" &&
                fields[1].strip.length) return fields[1].strip;
        }
    }
    return "UNAVAILABLE";
}

void main(string[] args) {
    if (args.length != 3)
        throw new Exception("usage: mojibake_scale SCRUBBED_BINARY PINNED_FTFY_CLI");
    auto ftfyHelp = execute([args[2], "--help"]);
    bool pinnedVersion;
    foreach (line; ftfyHelp.output.splitLines)
        if (line.strip == "ftfy (fixes text for you), version 6.3.1")
            pinnedVersion = true;
    if (ftfyHelp.status != 0 || !pinnedVersion)
        throw new Exception("expected ftfy CLI version 6.3.1");
    auto python = buildPath(dirName(args[2]), "python");
    auto packages = execute(["uv", "pip", "freeze", "--python", python]);
    bool pinnedFtFy, pinnedWcwidth;
    foreach (line; packages.output.splitLines) {
        if (line.strip == "ftfy==6.3.1") pinnedFtFy = true;
        if (line.strip == "wcwidth==0.8.4") pinnedWcwidth = true;
    }
    if (packages.status != 0 || !pinnedFtFy || !pinnedWcwidth)
        throw new Exception("expected ftfy==6.3.1 and wcwidth==0.8.4");
    auto scrubbedHash = digest(args[1]);
    auto ftfyHash = digest(args[2]);

    auto root = buildPath(tempDir, "scrubbed-mojibake-scale-" ~ randomUUID.toString);
    mkdir(root);
    scope(exit) rmdirRecurse(root);
    auto input = buildPath(root, "input.txt");
    auto output = buildPath(root, "output.txt");
    auto damagedBuilder = appender!string();
    auto cleanBuilder = appender!string();
    foreach (_; 0 .. 131_072) {
        damagedBuilder.put("CafÃ© at noon; the sign said rÃ©sumÃ©.\n");
        cleanBuilder.put("Café at noon; the sign said résumé.\n");
    }
    auto damaged = damagedBuilder.data;
    auto clean = cleanBuilder.data;
    write(input, damaged);

    JSONValue[] samples;
    // Interleave order to reduce monotonic host drift; retain every sample.
    foreach (tool; ["scrubbed", "ftfy", "ftfy", "scrubbed", "scrubbed", "ftfy"]) {
        if (exists(output)) remove(output);
        auto command = tool == "scrubbed" ?
            [args[1], "--input", input, "--output", output,
                "--filters", "fix-mojibake", "--threads", "1"] :
            [args[2], "--preserve-entities", "-n", "none", "-o", output, input];
        auto watch = StopWatch(AutoStart.yes);
        auto result = execute(command);
        watch.stop();
        if (result.status != 0 || !exists(output) || readText(output) != clean)
            throw new Exception(tool ~ " failed exact-output gate");
        samples ~= JSONValue([
            "tool": JSONValue(tool),
            "wall_seconds": JSONValue(cast(double)watch.peek.total!"nsecs" /
                1_000_000_000),
            "exact_output": JSONValue(true),
            "output_sha256": JSONValue(digest(output))]);
    }
    if (digest(args[1]) != scrubbedHash || digest(args[2]) != ftfyHash)
        throw new Exception("benchmark executable changed during measurement");
    auto os = checked(["uname", "-s"]);
    auto report = JSONValue([
        "schema": JSONValue("scrubbed-mojibake-scale-v1"),
        "observed_checkout_sha": JSONValue(checked(["git", "rev-parse", "HEAD"])),
        "source_binary_mapping": JSONValue("UNVERIFIED; supplied binary identified by hash only"),
        "target_build_flags": JSONValue("UNVERIFIED; retain caller build log"),
        "harness_build_command": JSONValue("ldc2 -O3 -release benchmarks/mojibake_scale.d"),
        "scrubbed_command": JSONValue("<scrubbed> --input <fixture> --output <fresh-output> --filters fix-mojibake --threads 1"),
        "ftfy_command": JSONValue("<ftfy-6.3.1> --preserve-entities -n none -o <fresh-output> <fixture>"),
        "os": JSONValue(os),
        "architecture": JSONValue(checked(["uname", "-m"])),
        "cpu_model": JSONValue(cpuModel(os)),
        "compiler": JSONValue(checked(["ldc2", "--version"]).splitLines[0]),
        "python_packages": JSONValue("ftfy==6.3.1,wcwidth==0.8.4"),
        "fixture": JSONValue("131072 repeated authored mojibake lines"),
        "input_bytes": JSONValue(cast(long)damaged.length),
        "input_sha256": JSONValue(digest(input)),
        "expected_bytes": JSONValue(cast(long)clean.length),
        "scrubbed_binary_sha256": JSONValue(scrubbedHash),
        "ftfy_binary_sha256": JSONValue(ftfyHash),
        "samples": JSONValue(samples)]);
    writeln(report.toString);
}
