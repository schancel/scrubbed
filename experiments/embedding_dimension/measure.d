/// O3/release resource measurement for bounded embedding-dimension evaluation.
module experiments.embedding_dimension.measure;

import core.memory : GC;
import core.sys.posix.sys.resource : RUSAGE_SELF, getrusage, rusage;
import core.time : MonoTime;
import experiments.embedding_dimension.evaluation;
import std.conv : to;
import std.exception : enforce;
import std.file : getSize, readText, write;
import std.format : format;
import std.path : buildPath, dirName;
import std.string : split, splitLines;

private double cpuSeconds(ref rusage usage) {
    return usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1_000_000.0 +
        usage.ru_stime.tv_sec + usage.ru_stime.tv_usec / 1_000_000.0;
}

private ulong peakRss(ref rusage usage) {
    version (OSX) return cast(ulong) usage.ru_opaque[0];
    else version (linux) return cast(ulong) usage.ru_maxrss * 1024;
    else return 0;
}

private ulong inputBytes(string indexPath) {
    ulong result = getSize(indexPath);
    auto root = dirName(indexPath);
    foreach (line; readText(indexPath).splitLines[1 .. $])
        if (line.length) result += getSize(buildPath(root, line.split('\t')[0]));
    return result;
}

private string measure(string label, string index, Options options) {
    rusage beforeUsage;
    rusage afterUsage;
    enforce(getrusage(RUSAGE_SELF, &beforeUsage) == 0, "getrusage before");
    auto allocatedBefore = GC.allocatedInCurrentThread;
    auto started = MonoTime.currTime;
    auto result = evaluate(loadPopulation(index), options);
    auto elapsed = MonoTime.currTime - started;
    auto allocated = GC.allocatedInCurrentThread - allocatedBefore;
    enforce(getrusage(RUSAGE_SELF, &afterUsage) == 0, "getrusage after");
    auto wall = elapsed.total!"usecs" / 1_000_000.0;
    auto cpu = cpuSeconds(afterUsage) - cpuSeconds(beforeUsage);
    return label ~ "\t" ~ result.pointCount.to!string ~ "\t" ~
        result.distanceEvaluations.to!string ~ "\t" ~ format("%.6f", wall) ~ "\t" ~
        format("%.6f", cpu) ~ "\t" ~ peakRss(afterUsage).to!string ~ "\t" ~
        allocated.to!string ~ "\t" ~ inputBytes(index).to!string ~ "\t" ~
        format("%.3f", result.distanceEvaluations / wall) ~ "\t" ~
        result.peakLiveVectors.to!string ~ "\n";
}

void main(string[] args) {
    if (args.length != 3) throw new Exception("usage: measure EXPERIMENT_ROOT OUTPUT");
    Options small;
    small.population = "resource:small";
    small.modelDigest = "model:synthetic:v1";
    small.seed = 169;
    Options material = small;
    material.population = "resource:material";
    auto header = "population\tpoints\tdistance_evaluations\twall_seconds\tcpu_seconds\t" ~
        "process_peak_rss_bytes\tcurrent_thread_gc_allocated_bytes\tinput_disk_bytes\t" ~
        "distance_evaluations_per_second\tpeak_live_decoded_vectors\n";
    auto report = header ~ measure("small",
        buildPath(args[1], "fixtures", "heldout-line", "index.tsv"), small) ~
        measure("material", buildPath(args[1], "fixtures", "material", "index.tsv"), material);
    write(args[2], report);
}
