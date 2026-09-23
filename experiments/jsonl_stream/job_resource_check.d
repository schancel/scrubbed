/// Fresh-process Stage 5b observation; not a general performance claim.
module experiments.jsonl_stream.job_resource_check;

import core.sys.posix.sys.resource : rusage;
import core.sys.posix.sys.wait : WEXITSTATUS, WIFEXITED;
import core.stdc.errno : EINTR, errno;
import effects.jsonl_stream : JsonlLimits;
import effects.stdio_stream : processFileJsonl;
import domain.document : DocumentId;
import filters.normalize;
import pipeline : Pipeline, TypedFilterSpec;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.conv : to;
import std.file : exists, mkdir, read, rmdirRecurse, tempDir, write;
import std.path : absolutePath, buildPath;
import std.process : spawnProcess;
import std.stdio : File, writeln;
import std.uuid : randomUUID;

extern (C) int wait4(int pid, int* status, int options, rusage* usage);

private void need(bool condition, string message) {
    if (!condition) throw new Exception("JSONL job resources: " ~ message);
}

private ulong cpuMicros(const ref rusage usage) {
    return (cast(ulong) usage.ru_utime.tv_sec +
        cast(ulong) usage.ru_stime.tv_sec) * 1_000_000UL +
        cast(ulong) usage.ru_utime.tv_usec +
        cast(ulong) usage.ru_stime.tv_usec;
}

private ulong peakRss(const ref rusage usage) {
    version (OSX) return cast(ulong) usage.ru_opaque[0];
    else version (linux) return cast(ulong) usage.ru_maxrss * 1024;
    else static assert(0, "resource observation requires Darwin or Linux");
}

private struct Observation {
    long wallMicros;
    ulong cpuMicros;
    ulong peakRssBytes;
}

private Observation runChild(string[] command, string inputPath,
        string outputPath, string diagnosticsPath) {
    auto input = File(inputPath, "rb");
    auto output = File(outputPath, "wb");
    auto diagnostics = File(diagnosticsPath, "wb");
    auto wall = StopWatch(AutoStart.yes);
    auto child = spawnProcess(command, input, output, diagnostics);
    input.close();
    output.close();
    diagnostics.close();
    int status;
    rusage usage;
    int waited;
    do waited = wait4(child.processID, &status, 0, &usage);
    while (waited < 0 && errno == EINTR);
    need(waited == child.processID, "wait4 failed");
    wall.stop();
    need(WIFEXITED(status) && WEXITSTATUS(status) == 0,
        "child failed: " ~ cast(string) read(diagnosticsPath));
    return Observation(wall.peek.total!"usecs", cpuMicros(usage),
        peakRss(usage));
}

private void predecessor(string inputPath, string outputPath) {
    auto input = File(inputPath, "rb");
    auto output = File(outputPath, "wb");
    auto chain = Pipeline.buildTyped([
        TypedFilterSpec("normalize-line-endings")]);
    auto completed = processFileJsonl(input, output, "resource", "fixture",
        ["text"], (string field, string text, DocumentId id) => chain.run(text),
        JsonlLimits(1024, 2048));
    need(completed > 0, "predecessor processed no records");
}

private void observe(string self, string executable, string root,
        string label, size_t records) {
    auto input = buildPath(root, label ~ "-input.jsonl");
    auto predecessorOutput = buildPath(root, label ~ "-predecessor.jsonl");
    auto canonicalOutput = buildPath(root, label ~ "-canonical.jsonl");
    auto predecessorDiagnostics = buildPath(root, label ~ "-predecessor.err");
    auto canonicalDiagnostics = buildPath(root, label ~ "-canonical.err");
    string fixture;
    foreach (i; 0 .. records)
        fixture ~= "{\"text\":\"line\\r\\n" ~ i.to!string ~
            "\",\"keep\":[1,true,null]}\n";
    write(input, fixture);

    auto before = runChild([self, "--predecessor", input, predecessorOutput],
        input, predecessorOutput, predecessorDiagnostics);
    auto canonical = runChild([executable, "run", "--input", "-", "--output",
        "-", "--jsonl-fields", "text", "--dataset-namespace", "resource",
        "--source-key", "fixture", "--max-jsonl-line-bytes", "1024",
        "--max-jsonl-output-bytes", "2048", "--stage",
        "clean=text-transform", "--filter", "normalize-line-endings"],
        input, canonicalOutput, canonicalDiagnostics);
    need(read(predecessorOutput) == read(canonicalOutput),
        label ~ " predecessor/canonical bytes diverged");
    writeln("JSONL job resources: fixture=", label,
        " records=", records,
        " predecessor_wall_us=", before.wallMicros,
        " predecessor_child_cpu_us=", before.cpuMicros,
        " predecessor_child_peak_rss_bytes=", before.peakRssBytes,
        " canonical_wall_us=", canonical.wallMicros,
        " canonical_child_cpu_us=", canonical.cpuMicros,
        " canonical_child_peak_rss_bytes=", canonical.peakRssBytes,
        " (single local observations; opaque stage allocations are not bounded)");
}

void main(string[] args) {
    if (args.length == 4 && args[1] == "--predecessor") {
        predecessor(args[2], args[3]);
        return;
    }
    need(args.length == 2, "usage: job_resource_check <release executable>");
    auto root = buildPath(tempDir, "scrubbed-jsonl-job-resource-" ~
        randomUUID.toString);
    mkdir(root);
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto self = absolutePath(args[0]);
    observe(self, args[1], root, "small", 16);
    observe(self, args[1], root, "material", 20_000);
}
