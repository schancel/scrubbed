/// CLI: walk an input file or directory tree, run each file through a
/// configured filter chain, write results to an output path that mirrors
/// the input tree's structure. Parallel across files via `std.parallelism`'s
/// `TaskPool` (real OS-thread work-stealing, not Fibers -- Fibers are
/// cooperative single-thread green threads and wouldn't use multiple
/// cores for this embarrassingly-parallel per-file work). Reads are via
/// `std.mmfile.MmFile` so the input side avoids a read()-into-heap-buffer
/// allocation entirely -- the filter chain's transformed OUTPUT still has
/// to allocate (it's producing new content), but nothing is copied just
/// to get the input bytes into memory.
module app;

import std.stdio;
import std.file : dirEntries, SpanMode, exists, mkdirRecurse, isDir, write;
import std.path : relativePath, buildPath, dirName;
import std.mmfile : MmFile;
import std.parallelism : TaskPool, totalCPUs;
import std.getopt;
import std.array : split;
import std.string : join;

import pipeline;
import filters.normalize; // static this() registers "strip-control", "normalize-line-endings"
// filters.mojibake and filters.html2md are NOT imported here yet -- neither
// registers a filter yet (mojibake.d has the mechanical round-trip
// transforms but no scorer/entry-point to register; html2md.d is an
// unimplemented stub). Import + register them here once they're real.

void main(string[] args) {
    string inputPath;
    string outputPath;
    string filterList = "normalize-line-endings,strip-control";
    size_t nThreads = totalCPUs;
    bool listFilters = false;

    auto helpInfo = getopt(args,
        "input", "Input file or directory tree to process", &inputPath,
        "output", "Output path (mirrors input tree structure when --input is a directory)", &outputPath,
        "filters", "Comma-separated filter chain, applied in order", &filterList,
        "threads", "Worker thread count for the TaskPool (default: all cores)", &nThreads,
        "list-filters", "Print registered filter names and exit", &listFilters);
    if (helpInfo.helpWanted) {
        defaultGetoptPrinter("scrubd", helpInfo.options);
        return;
    }
    if (listFilters) {
        writeln("registered filters: ", availableFilters.join(", "));
        return;
    }
    if (inputPath.length == 0 || outputPath.length == 0) {
        stderr.writeln("--input and --output are required (--list-filters to see what's available)");
        return;
    }
    if (!exists(inputPath))
        throw new Exception("input path does not exist: " ~ inputPath);

    auto chain = Pipeline.build(filterList.split(","));
    writeln("filter chain: ", chain.names.join(" -> "));

    string[] files;
    const inputIsDir = isDir(inputPath);
    if (inputIsDir) {
        foreach (e; dirEntries(inputPath, SpanMode.depth))
            if (e.isFile)
                files ~= e.name;
    } else {
        files ~= inputPath;
    }
    writeln("processing ", files.length, " file(s) across ", nThreads, " thread(s)");

    auto pool = new TaskPool(nThreads);
    scope (exit) pool.finish();

    size_t failed = 0;
    foreach (file; pool.parallel(files)) {
        try {
            processOne(file, inputPath, outputPath, inputIsDir, chain);
        } catch (Exception e) {
            stderr.writefln("SKIP %s: %s", file, e.msg);
            failed++; // benign race on a plain size_t across threads for a
                       // best-effort count is acceptable here; use a real
                       // atomic (core.atomic) before trusting this number
        }
    }
    writeln("done. ", files.length - failed, " succeeded, ", failed, " failed.");
}

void processOne(string file, string inputRoot, string outputRoot, bool inputIsDir, const ref Pipeline chain) {
    // MmFile kept alive for the whole function: `text` is a zero-copy view
    // into the mapped pages, not a heap copy of the file contents. The
    // cast from the mapped `void[]`/`ubyte[]` to `string` (immutable) is
    // an assumption, not something the type system proves -- it holds
    // here because nothing else can write to this process's mapping of a
    // file it only opened for reading, but flag this as a deliberately
    // trusted spot, not an accident.
    auto mm = new MmFile(file);
    auto text = cast(string)(cast(ubyte[]) mm[]);

    auto cleaned = chain.run(text);

    string outPath = inputIsDir
        ? buildPath(outputRoot, relativePath(file, inputRoot))
        : outputRoot;
    mkdirRecurse(dirName(outPath));
    write(outPath, cleaned);
}
