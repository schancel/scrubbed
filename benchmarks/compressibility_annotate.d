/// Release/O3 throughput, CPU, RSS, and allocation-cost benchmark for issue
/// #168's `compressibility-annotate` stage: stage disabled (`baseline`, just
/// `document-metadata-publish`) vs stage enabled (`enabled`,
/// `[compressibility-annotate, document-metadata-publish]`), over the same
/// synthetic in-process corpus, run through the real
/// `compileJob`/`runCompiledJob` registry path -- not a placeholder, not a
/// microbenchmark of an isolated function.
///
/// Usage: this binary runs itself twice as a child process under `/usr/bin/
/// time -l` (macOS), once per mode, to get real OS-reported wall/user/sys
/// CPU time and peak resident set size for each mode in isolation, then
/// prints a comparison. Run directly with an argument (`baseline` or
/// `enabled`) to just run that one mode's in-process loop and print its own
/// throughput/allocation line (used internally by the driver, but also
/// runnable standalone).
///
/// Build and run:
/// ```sh
/// ldc2 -O3 -release -preview=dip1000 -Isource -i \
///   benchmarks/compressibility_annotate.d .dub/lexbor/liblexbor_static.a \
///   .dub/zstd/libzstd_compress.a .dub/zstd/libzstd_decompress.a \
///   third_party/sqlite/sqlite3.o -lcurl \
///   -of=/tmp/scrubbed-compressibility-bench
/// /tmp/scrubbed-compressibility-bench
/// ```
module benchmarks.compressibility_annotate;

import composition.compiler : compileJob;
import composition.job_executor : runCompiledJob;
import content.pieces : Content, ContentPiece;
import core.memory : GC;
import domain.document : Document, OutputName, SourceLocator;
import job.json : parseJobJson;
import stages.contract : EventKind, StageDocument;

// Imported only to trigger their `static this()` self-registration (see
// each module's own doc comment); neither module's symbols are otherwise
// referenced directly here. `-i` (transitive-import compile) only pulls in
// modules actually reachable via import, unlike `dub build`'s whole-
// `source/` compilation, so these two imports are required for this
// standalone benchmark binary to know either stage by name.
import effects.compressibility_annotate_stage;
import effects.document_metadata_publish_stage;
import std.conv : to;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.exception : enforce;
import std.file : thisExePath;
import std.process : executeShell;
import std.stdio : writefln, writeln;
import std.string : indexOf, splitLines, strip;

private enum documentCount = 500;

private enum baselineJobJson = `{"version":3,"stages":[` ~
    `{"id":"publish","implementation":"document-metadata-publish",` ~
    `"options":{},"filters":[]}]}`;
private enum enabledJobJson = `{"version":3,"stages":[` ~
    `{"id":"annotate","implementation":"compressibility-annotate",` ~
    `"options":{},"filters":[]},` ~
    `{"id":"publish","implementation":"document-metadata-publish",` ~
    `"options":{},"filters":[]}]}`;

/// A deterministic, non-repetitive synthetic corpus (fixed xorshift seed --
/// reproducible run over run, not `std.random`'s ambient seed): each
/// document is a natural-language-shaped paragraph, sizes ranging roughly
/// 200 bytes to 6 KiB, so the measured cost reflects real per-document
/// tokenization/hashing/compression work rather than one fixed size.
private string[] syntheticCorpus() {
    static immutable string[24] words = [
        "scrubbed", "processes", "documents", "through", "a", "pipeline",
        "of", "stages", "and", "filters", "repairing", "mojibake",
        "extracting", "metadata", "annotating", "compressibility", "before",
        "publishing", "the", "final", "side", "output", "for", "review",
    ];
    string[] corpus;
    corpus.reserve(documentCount);
    uint state = 0x9E3779B9;
    foreach (i; 0 .. documentCount) {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        auto targetWords = 20 + (state % 600); // ~120 bytes .. ~4200 bytes of words
        string document;
        foreach (w; 0 .. targetWords) {
            state ^= state << 13;
            state ^= state >> 17;
            state ^= state << 5;
            document ~= words[state % words.length];
            document ~= (w % 11 == 10) ? ". " : " ";
        }
        corpus ~= document;
    }
    return corpus;
}

private struct WorkerResult {
    size_t documents;
    size_t emitted;
    size_t totalBytes;
    double elapsedMs;
    ulong gcAllocatedDeltaBytes;
}

private WorkerResult runWorker(string mode) {
    auto jobJson = mode == "enabled" ? enabledJobJson : baselineJobJson;
    auto spec = parseJobJson(jobJson);
    auto plan = compileJob(spec);
    auto corpus = syntheticCorpus();
    size_t totalBytes;
    foreach (text; corpus) totalBytes += text.length;

    GC.collect();
    auto allocatedBefore = GC.allocatedInCurrentThread();
    auto sw = StopWatch(AutoStart.yes);
    size_t emitted;
    foreach (i, text; corpus) {
        auto document = Document(SourceLocator("bench:v1", "/bench",
            "doc" ~ i.to!string), OutputName("doc" ~ i.to!string ~ ".out"));
        auto input = StageDocument(document,
            new Content([ContentPiece.own(cast(const(ubyte)[]) text)]));
        auto events = runCompiledJob(input, plan);
        foreach (event; events)
            if (event.kind == EventKind.emitted) ++emitted;
    }
    sw.stop();
    auto allocatedAfter = GC.allocatedInCurrentThread();

    return WorkerResult(corpus.length, emitted, totalBytes,
        sw.peek.total!"nsecs" / 1_000_000.0, allocatedAfter - allocatedBefore);
}

private void printWorkerLine(WorkerResult result, string mode) {
    auto seconds = result.elapsedMs / 1000.0;
    writefln("mode=%s documents=%d emitted=%d totalBytes=%d elapsedMs=%.3f " ~
        "docsPerSec=%.1f mbPerSec=%.3f gcAllocatedDeltaBytes=%d " ~
        "gcAllocatedPerDocBytes=%.1f",
        mode, result.documents, result.emitted, result.totalBytes,
        result.elapsedMs, result.documents / seconds,
        (result.totalBytes / 1_048_576.0) / seconds,
        result.gcAllocatedDeltaBytes,
        cast(double) result.gcAllocatedDeltaBytes / result.documents);
}

/// Parses macOS `/usr/bin/time -l`'s trailer for the two lines this report
/// needs; both are always present in `-l` output regardless of workload.
private struct OsMeasurement {
    double realSeconds = double.nan;
    double userSeconds = double.nan;
    double sysSeconds = double.nan;
    long maxResidentSetSizeBytes = -1;
}

private OsMeasurement parseTimeDashL(string combinedOutput) {
    OsMeasurement result;
    foreach (line; combinedOutput.splitLines) {
        auto trimmed = line.strip;
        if (trimmed.indexOf("real") >= 0 && trimmed.indexOf("user") >= 0 &&
                trimmed.indexOf("sys") >= 0) {
            import std.array : split;
            auto fields = trimmed.split;
            // "<real> real <user> user <sys> sys"
            if (fields.length >= 6) {
                result.realSeconds = fields[0].to!double;
                result.userSeconds = fields[2].to!double;
                result.sysSeconds = fields[4].to!double;
            }
        } else if (trimmed.indexOf("maximum resident set size") >= 0) {
            import std.array : split;
            auto fields = trimmed.split;
            if (fields.length >= 1) result.maxResidentSetSizeBytes = fields[0].to!long;
        }
    }
    return result;
}

private void runDriver() {
    auto exePath = thisExePath();
    WorkerResult[string] results;
    OsMeasurement[string] osMeasurements;
    foreach (mode; ["baseline", "enabled"]) {
        auto command = "/usr/bin/time -l " ~ exePath ~ " " ~ mode ~ " 2>&1";
        auto process = executeShell(command);
        enforce(process.status == 0,
            "compressibility-annotate benchmark worker failed: " ~ process.output);
        auto os = parseTimeDashL(process.output);
        enforce(os.maxResidentSetSizeBytes >= 0,
            "could not parse /usr/bin/time -l output:\n" ~ process.output);
        osMeasurements[mode] = os;

        // Re-run the same work in-process too, to report GC allocation
        // (which the external `time` invocation cannot see).
        results[mode] = runWorker(mode);
    }

    writeln("compressibility-annotate benchmark: stage disabled vs enabled");
    writeln("---------------------------------------------------------------");
    foreach (mode; ["baseline", "enabled"]) {
        printWorkerLine(results[mode], mode);
        auto os = osMeasurements[mode];
        writefln("mode=%s osRealSec=%.3f osUserSec=%.3f osSysSec=%.3f " ~
            "osMaxRssBytes=%d osMaxRssMB=%.2f",
            mode, os.realSeconds, os.userSeconds, os.sysSeconds,
            os.maxResidentSetSizeBytes, os.maxResidentSetSizeBytes / 1_048_576.0);
    }

    auto baselineOs = osMeasurements["baseline"];
    auto enabledOs = osMeasurements["enabled"];
    auto baselineResult = results["baseline"];
    auto enabledResult = results["enabled"];
    writeln("---------------------------------------------------------------");
    writefln("delta: osRealSecPerDoc=%.6f osMaxRssDeltaBytes=%d " ~
        "gcAllocatedDeltaPerDocBytes=%.1f",
        (enabledOs.realSeconds - baselineOs.realSeconds) / enabledResult.documents,
        enabledOs.maxResidentSetSizeBytes - baselineOs.maxResidentSetSizeBytes,
        cast(double)(enabledResult.gcAllocatedDeltaBytes -
            baselineResult.gcAllocatedDeltaBytes) / enabledResult.documents);
}

void main(string[] args) {
    if (args.length == 2 && (args[1] == "baseline" || args[1] == "enabled")) {
        printWorkerLine(runWorker(args[1]), args[1]);
        return;
    }
    runDriver();
}
