/// Process-level Stage 5a RSS observation; not a universal memory claim.
module experiments.pipeline_config.resource_check;

import core.memory : GC;
import core.sys.posix.sys.resource : RUSAGE_CHILDREN, getrusage, rusage;
import filters.normalize;
import pipeline : Pipeline;
import std.array : replicate;
import std.conv : to;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.file : exists, mkdir, readText, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.process : execute;
import std.stdio : writeln;
import std.uuid : randomUUID;

private void need(bool condition, string message) {
    if (!condition) throw new Exception("shipping resources: " ~ message);
}

private ulong peakRss() {
    rusage usage;
    need(getrusage(RUSAGE_CHILDREN, &usage) == 0, "getrusage failed");
    version (OSX) return cast(ulong) usage.ru_opaque[0];
    else version (linux) return cast(ulong) usage.ru_maxrss * 1024;
    else static assert(0, "resource observation requires Darwin or Linux");
}

private ulong cpuMicros(const ref rusage usage) {
    return (cast(ulong)usage.ru_utime.tv_sec +
        cast(ulong)usage.ru_stime.tv_sec) * 1_000_000UL +
        cast(ulong)usage.ru_utime.tv_usec +
        cast(ulong)usage.ru_stime.tv_usec;
}

private void observe(string executable, string root, string label,
        size_t repeats) {
    auto input = buildPath(root, label ~ "-input.txt");
    auto output = buildPath(root, label ~ "-output.txt");
    auto fixture = "line\r\n".replicate(repeats);
    write(input, fixture);

    GC.collect();
    auto allocatedBefore = GC.allocatedInCurrentThread;
    auto usedBefore = GC.stats.usedSize;
    auto predecessorWall = StopWatch(AutoStart.yes);
    auto expected = Pipeline.build(["normalize-line-endings"]).run(fixture);
    predecessorWall.stop();
    auto predecessorAllocated = GC.allocatedInCurrentThread - allocatedBefore;
    GC.collect();
    auto usedAfter = GC.stats.usedSize;
    auto predecessorRetained = usedAfter >= usedBefore ?
        usedAfter - usedBefore : 0;

    rusage cpuBefore, cpuAfter;
    need(getrusage(RUSAGE_CHILDREN, &cpuBefore) == 0,
        "child CPU baseline unavailable");
    auto integratedWall = StopWatch(AutoStart.yes);
    auto result = execute([executable, "run", "--input", input, "--output",
        output, "--threads", "1", "--stage", "clean=text-transform",
        "--filter", "normalize-line-endings"]);
    integratedWall.stop();
    need(getrusage(RUSAGE_CHILDREN, &cpuAfter) == 0,
        "child CPU observation unavailable");
    need(result.status == 0 && exists(output) && readText(output) == expected,
        label ~ " integrated/predecessor output diverged");
    auto beforeCpu = cpuMicros(cpuBefore);
    auto afterCpu = cpuMicros(cpuAfter);
    need(afterCpu >= beforeCpu, "child CPU observation regressed");
    writeln("shipping resources: fixture=", label,
        " bytes=", fixture.length,
        " integrated_wall_us=", integratedWall.peek.total!"usecs",
        " integrated_child_cpu_us=", afterCpu - beforeCpu,
        " child_peak_rss_bytes=", peakRss(),
        " predecessor_wall_us=", predecessorWall.peek.total!"usecs",
        " predecessor_gc_allocated_bytes=", predecessorAllocated,
        " predecessor_gc_retained_bytes=", predecessorRetained,
        " (GC counters cover only the current-thread predecessor helper and " ~
        "are incomplete allocator evidence)");
}

void main(string[] args) {
    need(args.length == 2, "usage: resource_check <release executable>");
    auto root = buildPath(tempDir, "scrubbed-shipping-resource-" ~
        randomUUID.toString);
    mkdir(root);
    scope(exit) if (exists(root)) rmdirRecurse(root);
    observe(args[1], root, "small", 16);
    observe(args[1], root, "material", 1_000_000);
}
