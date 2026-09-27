/// Evidence harness for issue #233: does the `span.path.to!string` /
/// `span.path[0 .. $ - 1].to!string` pair in
/// `source/domain/structured_chunks.d`'s per-span validation loop
/// (duplicate-path and sibling-ordinal-monotonicity checks, lines ~153-186)
/// cost a repeatable, material amount of allocation/CPU, and would a
/// bounded structural key avoid it?
//
// Two measurements, both following this codebase's established
// GC.allocatedInCurrentThread()-delta idiom from
// experiments/dispatch_record_reservation/check.d:
//
//   (A) Full pipeline, PRODUCTION CODE ONLY: calls the real, unmodified
//       public `chunkStructured` end to end (this file never duplicates
//       its internals) on an "ordinary" fixture and a "maximum-span"
//       (65,536-span) fixture, plus a "maximum-span, maximum-depth"
//       fixture (2,048 chains of depth 32 -- the deepest paths the
//       existing `path.length <= 32` bound allows). This is the real,
//       total, end-to-end cost including everything else the function
//       does (SHA-256 chunk IDs, output-array growth, metadata
//       inheritance, etc.), not just the validation loop.
//
//   (B) Isolated microbenchmark: a local, clearly-separate reimplementation
//       of ONLY the three-associative-array validation block (duplicate +
//       sibling-order check), run two ways over the exact same path
//       sequences used to build the (A) fixtures:
//         - "string-key" -- byte-for-byte the same approach as production:
//           `bool[string]` / `uint[string]` keyed by `path.to!string`.
//         - "array-key" -- a candidate: `bool[const(uint)[]]` /
//           `uint[const(uint)[]]` keyed directly by the `uint[]` path
//           slice, using D's built-in structural array hashing/equality.
//           No string is ever allocated; no encoding is invented, since
//           the AA's own array-key hash/equals already reads path
//           length and contents directly.
//       This isolates the validation-loop cost specifically, since (A)'s
//       totals are dominated by other allocations (SHA-256 chunk IDs,
//       output structs) once span counts get large. Both variants here
//       are duplicates written for comparison only -- NOT calls into
//       private production internals (there is no way to call those
//       directly; they are private to structured_chunks.d) -- and are
//       not proposed as-is for production; see
//       docs/structured-chunk-path-validation-evaluation.md for the
//       write-up and the honest caveats about this duplication.
//
// This file makes NO production change. source/domain/structured_chunks.d
// is untouched.
module experiments.structured_chunk_validation.check;

import core.memory : GC;
import core.sys.posix.sys.resource : RUSAGE_SELF, getrusage, rusage, timeval;
import domain.document : DocumentId, SourceLocator;
import domain.structured_chunks : ChunkMetadata, SpanKind, StructuredChunk,
    StructuredSpan, chunkStructured, maxChunkBytes, maxStructuredTextBytes;
import std.array : replicate;
import std.conv : to;
import std.exception : enforce;
import std.stdio : writefln, writeln;

// ---------------------------------------------------------------------
// Fixture construction. Each builder returns (text, spans) satisfying
// chunkStructured's real nesting/coverage rules: every non-root span's
// path is its parent's path plus exactly one trailing ordinal (`prefix`
// in structured_chunks.d), each container's byte range exactly wraps its
// children's, and paragraphs alone consume text bytes contiguously.
// Spans are emitted in real preorder (parent immediately followed by its
// children) since that's what the validation loop's stack-based nesting
// check requires.
// ---------------------------------------------------------------------

private struct Fixture {
    string name;
    immutable(char)[] text;
    StructuredSpan[] spans;
    uint[][] paths; // spans[].path, in the same order -- for the (B) microbenchmark
}

/// "Ordinary": a modest, realistic document -- 8 sections x 6 pages x
/// 5 paragraphs/page, depth 3, 20 bytes/paragraph. 8 + 48 + 240 = 296 spans.
private Fixture ordinaryFixture() {
    return nestedFixture("ordinary", 8, 6, 5, 20);
}

/// "Maximum-span, shallow": 65,536 top-level paragraphs (depth 1, the
/// widest possible sibling run under one parent), 1 byte each -- the
/// worst case for the `seen`/`hasOrdinal`/`lastOrdinal` associative
/// arrays' raw entry count at the existing spans.length <= 65_536 cap.
private Fixture maxSpanShallowFixture() {
    enum n = 65_536;
    auto text = cast(immutable(char)[]) "x".replicate(n);
    StructuredSpan[] spans;
    uint[][] paths;
    spans.reserve(n);
    paths.reserve(n);
    foreach (uint i; 0 .. n) {
        auto path = [i];
        spans ~= StructuredSpan(SpanKind.paragraph, i, i + 1, path, ChunkMetadata.init);
        paths ~= path;
    }
    return Fixture("maximum-span-shallow", text, spans, paths);
}

/// "Maximum-span, maximum-depth": 2,048 independent chains, each 32 spans
/// deep (31 containers + 1 leaf paragraph) -- the existing
/// `path.length <= 32` bound saturated on every chain. 2,048 * 32 =
/// 65,536 spans total, exactly at the spans.length cap, while also
/// maximizing per-span key length (`path.to!string` on a 32-element
/// array vs. a 1-element array).
private Fixture maxSpanDeepFixture() {
    enum chains = 2_048;
    enum depth = 32; // existing bound: span.path.length <= 32
    auto text = cast(immutable(char)[]) "x".replicate(chains);
    StructuredSpan[] spans;
    uint[][] paths;
    spans.reserve(chains * depth);
    paths.reserve(chains * depth);
    foreach (uint c; 0 .. chains) {
        uint[] path = [c];
        foreach (level; 1 .. depth) {
            auto kind = (level % 2 == 0) ? SpanKind.section : SpanKind.page;
            spans ~= StructuredSpan(kind, c, c + 1, path, ChunkMetadata.init);
            paths ~= path;
            path = path ~ 0u;
        }
        spans ~= StructuredSpan(SpanKind.paragraph, c, c + 1, path, ChunkMetadata.init);
        paths ~= path;
    }
    return Fixture("maximum-span-deep", text, spans, paths);
}

private Fixture nestedFixture(string name, uint sectionCount, uint pagesPerSection,
        uint paragraphsPerPage, size_t paragraphBytes) {
    auto pageBytes = paragraphsPerPage * paragraphBytes;
    auto sectionBytes = pagesPerSection * pageBytes;
    auto totalBytes = sectionCount * sectionBytes;
    auto text = cast(immutable(char)[]) "x".replicate(totalBytes);
    StructuredSpan[] spans;
    uint[][] paths;
    size_t covered;
    foreach (uint s; 0 .. sectionCount) {
        auto sectionStart = covered;
        auto sectionPath = [s];
        spans ~= StructuredSpan(SpanKind.section, sectionStart,
            sectionStart + sectionBytes, sectionPath, ChunkMetadata.init);
        paths ~= sectionPath;
        foreach (uint p; 0 .. pagesPerSection) {
            auto pageStart = covered;
            auto pagePath = [s, p];
            spans ~= StructuredSpan(SpanKind.page, pageStart,
                pageStart + pageBytes, pagePath, ChunkMetadata.init);
            paths ~= pagePath;
            foreach (uint q; 0 .. paragraphsPerPage) {
                auto paraStart = covered;
                covered += paragraphBytes;
                auto paraPath = [s, p, q];
                spans ~= StructuredSpan(SpanKind.paragraph, paraStart, covered,
                    paraPath, ChunkMetadata.init);
                paths ~= paraPath;
            }
        }
    }
    enforce(covered == totalBytes, name ~ ": fixture arithmetic drifted");
    return Fixture(name, text, spans, paths);
}

// ---------------------------------------------------------------------
// (A) Full pipeline measurement, real chunkStructured, unmodified.
// ---------------------------------------------------------------------

private timeval subtract(timeval a, timeval b) {
    auto usec = a.tv_usec - b.tv_usec;
    auto sec = a.tv_sec - b.tv_sec;
    if (usec < 0) { usec += 1_000_000; sec -= 1; }
    return timeval(sec, usec);
}

private double seconds(timeval t) {
    return cast(double) t.tv_sec + cast(double) t.tv_usec / 1_000_000.0;
}

private rusage selfUsage() {
    rusage usage;
    enforce(getrusage(RUSAGE_SELF, &usage) == 0, "getrusage failed");
    return usage;
}

private struct PipelineResult {
    string name;
    size_t spanCount;
    size_t chunkCount;
    double bytesPerCallFirstHalf;
    double bytesPerCallSecondHalf;
    double cpuSecondsPerCall;
    size_t iterations;
}

private PipelineResult measurePipeline(Fixture fixture, size_t iterations) {
    auto id = DocumentId.from(SourceLocator("experiments",
        "structured-chunk-validation", fixture.name));
    size_t chunkCount;
    void delegate() produce = () {
        auto result = chunkStructured(id, "rev-1", fixture.text, fixture.spans);
        chunkCount = result.length;
    };
    produce();
    auto firstChunkCount = chunkCount;
    produce();
    enforce(chunkCount == firstChunkCount, fixture.name ~ ": nondeterministic chunk count");

    GC.collect();
    GC.disable();
    scope (exit) GC.enable();
    auto half = iterations / 2;
    auto cpuBefore = selfUsage();
    auto before = GC.allocatedInCurrentThread();
    foreach (_; 0 .. half) produce();
    auto afterFirstHalf = GC.allocatedInCurrentThread();
    foreach (_; 0 .. iterations - half) produce();
    auto afterSecondHalf = GC.allocatedInCurrentThread();
    auto cpuAfter = selfUsage();
    auto cpu = subtract(cpuAfter.ru_utime, cpuBefore.ru_utime).seconds +
        subtract(cpuAfter.ru_stime, cpuBefore.ru_stime).seconds;

    PipelineResult r;
    r.name = fixture.name;
    r.spanCount = fixture.spans.length;
    r.chunkCount = chunkCount;
    r.bytesPerCallFirstHalf = (cast(double)(afterFirstHalf - before)) / half;
    r.bytesPerCallSecondHalf =
        (cast(double)(afterSecondHalf - afterFirstHalf)) / (iterations - half);
    r.cpuSecondsPerCall = cpu / iterations;
    r.iterations = iterations;
    return r;
}

private void reportPipeline(PipelineResult r) {
    writefln("[A pipeline] name=%-22s spans=%6d chunks=%6d " ~
        "bytes_per_call_1st=%12.1f bytes_per_call_2nd=%12.1f " ~
        "cpu_seconds_per_call=%10.6f iters=%5d",
        r.name, r.spanCount, r.chunkCount, r.bytesPerCallFirstHalf,
        r.bytesPerCallSecondHalf, r.cpuSecondsPerCall, r.iterations);
    if (r.bytesPerCallFirstHalf > 0) {
        auto ratio = r.bytesPerCallSecondHalf / r.bytesPerCallFirstHalf;
        enforce(ratio > 0.4 && ratio < 2.5,
            r.name ~ ": allocation footprint drifted between halves " ~
            "(possible leak or warm-up artifact)");
    }
}

// ---------------------------------------------------------------------
// (B) Isolated microbenchmark: duplicated validation-block logic only.
// Both variants below are hand-written for THIS comparison; neither is
// production code and neither is called by anything in source/.
// ---------------------------------------------------------------------

/// Byte-for-byte the same approach as structured_chunks.d lines 153-186.
private void validateStringKey(const(uint[])[] paths) {
    bool[string] seen;
    uint[string] lastOrdinal;
    bool[string] hasOrdinal;
    foreach (path; paths) {
        auto key = path.to!string;
        enforce((key in seen) is null, "duplicate path");
        seen[key] = true;
        auto parentKey = path[0 .. $ - 1].to!string;
        auto ordinal = path[$ - 1];
        enforce((parentKey in hasOrdinal) is null || ordinal > lastOrdinal[parentKey],
            "unordered sibling path");
        hasOrdinal[parentKey] = true;
        lastOrdinal[parentKey] = ordinal;
    }
}

/// Candidate: the uint[] path slice itself as the associative-array key.
/// D's default array TypeInfo hashes/compares by length + contents, so
/// this needs no invented encoding and no string allocation at all. Path
/// data outlives the call (owned by the caller-supplied fixture), so no
/// .dup is needed to keep the key valid for the AA's lifetime here.
private void validateArrayKey(const(uint[])[] paths) {
    bool[const(uint)[]] seen;
    uint[const(uint)[]] lastOrdinal;
    bool[const(uint)[]] hasOrdinal;
    foreach (path; paths) {
        enforce((path in seen) is null, "duplicate path");
        seen[path] = true;
        auto parentKey = path[0 .. $ - 1];
        auto ordinal = path[$ - 1];
        enforce((parentKey in hasOrdinal) is null || ordinal > lastOrdinal[parentKey],
            "unordered sibling path");
        hasOrdinal[parentKey] = true;
        lastOrdinal[parentKey] = ordinal;
    }
}

private struct MicroResult {
    string name;
    string variant;
    size_t pathCount;
    double bytesPerCallFirstHalf;
    double bytesPerCallSecondHalf;
    double cpuSecondsPerCall;
    size_t iterations;
}

private MicroResult measureMicro(string fixtureName, string variant,
        void delegate() produce, size_t pathCount, size_t iterations) {
    produce();
    produce();

    GC.collect();
    GC.disable();
    scope (exit) GC.enable();
    auto half = iterations / 2;
    auto cpuBefore = selfUsage();
    auto before = GC.allocatedInCurrentThread();
    foreach (_; 0 .. half) produce();
    auto afterFirstHalf = GC.allocatedInCurrentThread();
    foreach (_; 0 .. iterations - half) produce();
    auto afterSecondHalf = GC.allocatedInCurrentThread();
    auto cpuAfter = selfUsage();
    auto cpu = subtract(cpuAfter.ru_utime, cpuBefore.ru_utime).seconds +
        subtract(cpuAfter.ru_stime, cpuBefore.ru_stime).seconds;

    MicroResult r;
    r.name = fixtureName;
    r.variant = variant;
    r.pathCount = pathCount;
    r.bytesPerCallFirstHalf = (cast(double)(afterFirstHalf - before)) / half;
    r.bytesPerCallSecondHalf =
        (cast(double)(afterSecondHalf - afterFirstHalf)) / (iterations - half);
    r.cpuSecondsPerCall = cpu / iterations;
    r.iterations = iterations;
    return r;
}

private void reportMicro(MicroResult r) {
    writefln("[B micro]    name=%-22s variant=%-10s paths=%6d " ~
        "bytes_per_call_1st=%12.1f bytes_per_call_2nd=%12.1f " ~
        "cpu_seconds_per_call=%10.6f iters=%5d",
        r.name, r.variant, r.pathCount, r.bytesPerCallFirstHalf,
        r.bytesPerCallSecondHalf, r.cpuSecondsPerCall, r.iterations);
    if (r.bytesPerCallFirstHalf > 0) {
        auto ratio = r.bytesPerCallSecondHalf / r.bytesPerCallFirstHalf;
        enforce(ratio > 0.4 && ratio < 2.5,
            r.name ~ "/" ~ r.variant ~ ": allocation footprint drifted between " ~
            "halves (possible leak or warm-up artifact)");
    }
}

// ---------------------------------------------------------------------
// Minimal semantic-agreement checks between the two (B) variants -- not
// a full correctness suite (this is an evidence-only slice; see the
// ticket), just enough to support the write-up's claim that the
// candidate key doesn't change accept/reject behavior on the cases it's
// most likely to get wrong.
// ---------------------------------------------------------------------

private bool rejects(void delegate() action) {
    try { action(); return false; }
    catch (Exception) return true;
}

private void checkAgreement() {
    // Valid: distinct siblings, ascending order.
    uint[][] valid = [[0], [1], [1, 0], [1, 1], [2]];
    enforce(!rejects(() => validateStringKey(valid)) &&
        !rejects(() => validateArrayKey(valid)), "valid path set disagreement");

    // Duplicate path.
    uint[][] duplicate = [[0], [1], [1]];
    enforce(rejects(() => validateStringKey(duplicate)) &&
        rejects(() => validateArrayKey(duplicate)), "duplicate path disagreement");

    // Unordered siblings.
    uint[][] unordered = [[1], [0]];
    enforce(rejects(() => validateStringKey(unordered)) &&
        rejects(() => validateArrayKey(unordered)), "unordered sibling disagreement");

    // uint.max ordinal, both as a leaf and as a path element mid-array --
    // exercises the D built-in array hash on the boundary value the
    // decimal-string approach also has to format correctly.
    uint[][] maxOrdinal = [[0u], [uint.max], [uint.max, 0u], [uint.max, uint.max]];
    enforce(!rejects(() => validateStringKey(maxOrdinal)) &&
        !rejects(() => validateArrayKey(maxOrdinal)), "uint.max disagreement");

    // Prefix-related paths: [1] is a container, [1,0] its child, [1,0,0]
    // its grandchild -- exercises that a path and one of its own prefixes
    // are never treated as equal keys (both encodings are length-aware).
    uint[][] prefixChain = [[1], [1, 0], [1, 0, 0]];
    enforce(!rejects(() => validateStringKey(prefixChain)) &&
        !rejects(() => validateArrayKey(prefixChain)), "prefix-chain disagreement");

    // Repeated parents at different depths: [2,0] and [3,0] share ordinal
    // 0 under different parents -- must not collide in either keying
    // scheme (this is exactly the "distinct parents, same trailing
    // ordinal" case a naive encoding could get wrong).
    uint[][] repeatedParents = [[2], [2, 0], [3], [3, 0]];
    enforce(!rejects(() => validateStringKey(repeatedParents)) &&
        !rejects(() => validateArrayKey(repeatedParents)), "repeated-parent disagreement");

    writeln("[B agreement] string-key and array-key variants agree on all " ~
        "6 semantic probes (valid, duplicate, unordered, uint.max, " ~
        "prefix-chain, repeated-parents)");
}

void main() {
    checkAgreement();

    auto ordinary = ordinaryFixture();
    auto maxShallow = maxSpanShallowFixture();
    auto maxDeep = maxSpanDeepFixture();

    enforce(ordinary.spans.length <= 65_536 && maxShallow.spans.length == 65_536 &&
        maxDeep.spans.length == 65_536, "fixture span-count bound drifted");
    foreach (path; maxDeep.paths)
        enforce(path.length <= 32, "fixture path-length bound drifted");

    writeln("-- (A) full pipeline: real, unmodified chunkStructured --");
    reportPipeline(measurePipeline(ordinary, 2_000));
    reportPipeline(measurePipeline(maxShallow, 30));
    reportPipeline(measurePipeline(maxDeep, 30));

    writeln("-- (B) isolated validation-block microbenchmark --");
    foreach (fixture; [ordinary, maxShallow, maxDeep]) {
        auto iterations = fixture.paths.length <= 1000 ? 5_000 : 100;
        reportMicro(measureMicro(fixture.name, "string-key",
            () => validateStringKey(fixture.paths), fixture.paths.length, iterations));
        reportMicro(measureMicro(fixture.name, "array-key",
            () => validateArrayKey(fixture.paths), fixture.paths.length, iterations));
    }

    writeln("structured chunk path validation: evidence-only, no production change");
}
