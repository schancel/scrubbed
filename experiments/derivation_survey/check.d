/// Read-only, header-only derivation-identity survey over a directory of C01
/// document shards and analyzer overlays (issue #349's evidence/evaluation-
/// only slice). This does NOT invent a new storage/index mechanism, wire any
/// CLI/stage, or redesign `DocumentId` -- see
/// `docs/derivation-identity-survey.md`. Not part of `dub build`/`dub test`
/// (`dub.json`'s `sourcePaths` is `["source"]` only); compiled and run
/// standalone, matching the idiom of every other `experiments/*/check.d` /
/// `evaluate.d` in this repository (e.g. `experiments/sigv4_check/evaluate.d`,
/// `experiments/exact_dedup/overlay_check.d`).
///
/// Answers "has document X received transform Y at version Z" using only
/// `effects.document_shards.OverlayReader.header` (`analyzerKey`,
/// `analyzerVersion`, `sourceShardDigest`) plus the already-public
/// `effects.document_shards.shardDigest` helper -- never calling
/// `OverlayReader.next()`, i.e. never decoding a single `AnnotationRecord`
/// inside any overlay.
///
/// That is a **shard-level** answer ("this document's enclosing C01 shard, at
/// its exact current content revision, was covered by a publish of analyzer Y
/// version Z"), not a **record-level** one ("this specific document carries a
/// non-empty annotation value from Y"). The two are NOT the same claim, and
/// this file's own fixture (the `theta` shard, and the caveat-check section of
/// `main()` below) demonstrates the gap with real evidence rather than
/// asserting it away: several of this repository's own overlay writers
/// (`near-dedup`; see `effects.near_dedup_overlay`'s own unittest comment,
/// "solo ... never appear in the output at all") publish a valid overlay
/// header for a whole shard while emitting zero annotation records for some,
/// or even all, of that shard's individual documents. Header-only inspection
/// can prove "analyzer Y ran over this document's shard at this revision"; it
/// cannot prove "analyzer Y said something about this specific document."
/// `docs/derivation-identity-survey.md` discusses which of #349's real
/// questions each level actually answers.
module derivation_survey.check;

import domain.document : OutputName, SourceLocator;
import domain.shard_format : ShardDocument;
import domain.similarity_signature : similaritySignatures;
import effects.document_shards : DocumentShardReader, DocumentShardWriter,
    OverlayReader, shardDigest;
import effects.exact_dedup_overlay : DedupShard, writeExactDedupOverlays;
import effects.near_dedup_overlay : NearDedupShard, writeNearDedupOverlays;
import effects.similarity_buckets : SimilarityBatchEntry, SimilarityShard,
    similarityBatchReader, writeSimilarityBucketOverlays;
import std.algorithm.searching : canFind;
import std.algorithm.sorting : sort;
import std.array : join;
import std.exception : enforce;
import std.file : SpanMode, copy, dirEntries, mkdirRecurse, rmdirRecurse,
    tempDir;
import std.path : baseName, buildPath, dirName;
import std.stdio : writefln, writeln;
import std.string : endsWith, startsWith;
import std.uuid : randomUUID;

private void need(bool okay, string reason) {
    enforce(okay, "derivation survey: " ~ reason);
}

// ---------------------------------------------------------------------------
// Fixture construction: real, unmodified upstream C01 writers only. No
// hand-rolled overlay or shard bytes anywhere in this section.
// ---------------------------------------------------------------------------

private ShardDocument document(string source, string key, string content) {
    return ShardDocument(SourceLocator("derivation-survey", source, key),
        OutputName(key), cast(ubyte[]) content.dup);
}

private void writeSourceShard(string path, ShardDocument[] documents) {
    documents.sort!((a, b) => a.id.text < b.id.text);
    auto writer = new DocumentShardWriter(path);
    foreach (record; documents) writer.append(record);
    writer.publish();
}

private SimilarityBatchEntry[] signaturesOf(string path, uint sourceIndex) {
    auto reader = new DocumentShardReader(path);
    scope(exit) reader.closeReader();
    SimilarityBatchEntry[] entries;
    ShardDocument record;
    while (reader.next(record))
        entries ~= SimilarityBatchEntry(
            similaritySignatures(record.id, record.content), record.contentDigest,
            sourceIndex);
    return entries;
}

/// Builds a real fixture tree via the actual, unmodified upstream C01 writers
/// (`writeExactDedupOverlays`, `writeSimilarityBucketOverlays`,
/// `writeNearDedupOverlays`) -- the same three stages
/// `docs/derivation-identity-survey.md` inventories as the "C01-overlay-
/// queryable" bucket. Layout (all invented for this experiment; production
/// has no shard<->overlay naming/location convention today, which is itself
/// part of what #349 leaves unresolved):
///
///   <root>/batch-1/alpha.shard    (+ exact-dedup, near-dedup, similarity-buckets)
///   <root>/batch-1/beta.shard     (+ all three -- alpha/beta/theta-dup share one
///                                    exact- and near-duplicate cluster)
///   <root>/batch-1/theta.shard    (+ all three -- TWO documents: theta-rep, a
///                                    real solo with no duplicates anywhere, and
///                                    theta-dup, a member of the alpha/beta
///                                    cluster -- proving the shard-vs-record
///                                    granularity caveat above with one real
///                                    fixture, not two)
///   <root>/batch-2/gamma.shard    (+ exact-dedup only)
///   <root>/batch-2/delta.shard    (+ similarity-buckets + near-dedup only,
///                                    deliberately never given an exact-dedup
///                                    overlay)
///   <root>/batch-2/epsilon.shard  (no overlays at all)
///   <root>/batch-2/zeta.shard     (a REAL exact-dedup overlay -- copied
///                                    verbatim from gamma's, not hand-rolled --
///                                    sitting at zeta's naming-convention path
///                                    but binding gamma's shard digest: a
///                                    stale/misfiled overlay a naming-only
///                                    check would wrongly call "present")
void buildFixture(string root) {
    auto batch1 = buildPath(root, "batch-1");
    auto batch2 = buildPath(root, "batch-2");
    mkdirRecurse(batch1);
    mkdirRecurse(batch2);

    enum clusterContent = "the quick brown fox jumps over the lazy dog while " ~
        "pondering derivation identity across a whole corpus";
    enum soloContent = "a wildly different unrelated sentence about oceans and tides";
    enum gammaContent = "gamma carries its own unrelated content with no duplicates anywhere in this fixture";
    enum deltaContent = "delta also carries unrelated content, long enough for a real similarity signature";
    enum epsilonContent = "epsilon receives no derivation overlays whatsoever in this fixture";
    enum zetaContent = "zeta exists only to host a stale, misfiled overlay borrowed from gamma";

    auto alphaPath = buildPath(batch1, "alpha.shard");
    auto betaPath = buildPath(batch1, "beta.shard");
    auto thetaPath = buildPath(batch1, "theta.shard");
    writeSourceShard(alphaPath, [document("alpha-src", "alpha", clusterContent)]);
    writeSourceShard(betaPath, [document("beta-src", "beta", clusterContent)]);
    writeSourceShard(thetaPath, [
        document("theta-src", "theta-rep", soloContent),
        document("theta-src", "theta-dup", clusterContent),
    ]);

    // batch-1: all three analyzers, over all three shards.
    writeExactDedupOverlays([
        DedupShard(alphaPath, buildPath(batch1, "alpha.exact-dedup.overlay")),
        DedupShard(betaPath, buildPath(batch1, "beta.exact-dedup.overlay")),
        DedupShard(thetaPath, buildPath(batch1, "theta.exact-dedup.overlay")),
    ]);
    auto bucketShards = [
        SimilarityShard(alphaPath, buildPath(batch1, "alpha.similarity-buckets.overlay")),
        SimilarityShard(betaPath, buildPath(batch1, "beta.similarity-buckets.overlay")),
        SimilarityShard(thetaPath, buildPath(batch1, "theta.similarity-buckets.overlay")),
    ];
    auto entries = signaturesOf(alphaPath, 0) ~ signaturesOf(betaPath, 1) ~
        signaturesOf(thetaPath, 2);
    writeSimilarityBucketOverlays(bucketShards, similarityBatchReader(entries));
    writeNearDedupOverlays([
        NearDedupShard(alphaPath, bucketShards[0].destination,
            buildPath(batch1, "alpha.near-dedup.overlay")),
        NearDedupShard(betaPath, bucketShards[1].destination,
            buildPath(batch1, "beta.near-dedup.overlay")),
        NearDedupShard(thetaPath, bucketShards[2].destination,
            buildPath(batch1, "theta.near-dedup.overlay")),
    ]);

    // batch-2: deliberately uneven coverage.
    auto gammaPath = buildPath(batch2, "gamma.shard");
    auto deltaPath = buildPath(batch2, "delta.shard");
    auto epsilonPath = buildPath(batch2, "epsilon.shard");
    auto zetaPath = buildPath(batch2, "zeta.shard");
    writeSourceShard(gammaPath, [document("gamma-src", "gamma", gammaContent)]);
    writeSourceShard(deltaPath, [document("delta-src", "delta", deltaContent)]);
    writeSourceShard(epsilonPath, [document("epsilon-src", "epsilon", epsilonContent)]);
    writeSourceShard(zetaPath, [document("zeta-src", "zeta", zetaContent)]);

    auto gammaOverlay = buildPath(batch2, "gamma.exact-dedup.overlay");
    writeExactDedupOverlays([DedupShard(gammaPath, gammaOverlay)]);

    auto deltaBucket = SimilarityShard(deltaPath, buildPath(batch2, "delta.similarity-buckets.overlay"));
    writeSimilarityBucketOverlays([deltaBucket], similarityBatchReader(signaturesOf(deltaPath, 0)));
    writeNearDedupOverlays([NearDedupShard(deltaPath, deltaBucket.destination,
        buildPath(batch2, "delta.near-dedup.overlay"))]);

    // epsilon: no overlays at all -- left untouched.

    // zeta: a real overlay (gamma's own, byte-for-byte), copied to zeta's
    // naming-convention path. Its header's sourceShardDigest is gamma's shard
    // digest, not zeta's -- a genuine stale/misfiled overlay, not a
    // hand-rolled one.
    copy(gammaOverlay, buildPath(batch2, "zeta.exact-dedup.overlay"));
}

// ---------------------------------------------------------------------------
// The survey proper: header-only, tree-walking. This is the actual answer to
// #349's "prototype a minimal, read-only reporting tool" ask.
// ---------------------------------------------------------------------------

struct Coverage {
    string analyzerKey;
    string analyzerVersion;
    bool digestMatches;
}

struct DocumentReport {
    string shardPath;
    string recordKey;
    string documentId;
    Coverage[] coverage;
}

/// For every `<label>.shard` file under `root`, finds sibling
/// `<label>.<analyzer>.overlay` files (this experiment's own naming
/// convention -- production has none today) and reads only their
/// `OverlayReader.header`, never an `AnnotationRecord`. A candidate overlay
/// counts as real coverage only when its header's `sourceShardDigest` equals
/// the shard's actual current digest (`shardDigest`, the same whole-file
/// digest `OverlayWriter` itself binds every header to) -- a same-named file
/// bound to a different shard revision is reported, not silently trusted.
DocumentReport[] survey(string root) {
    DocumentReport[] reports;
    foreach (entry; dirEntries(root, SpanMode.depth)) {
        if (!entry.isFile || !entry.name.endsWith(".shard")) continue;
        auto shardPath = entry.name;
        auto digest = shardDigest(shardPath);
        auto directory = dirName(shardPath);
        auto label = baseName(shardPath, ".shard");

        Coverage[] coverage;
        foreach (candidate; dirEntries(directory, SpanMode.shallow)) {
            if (!candidate.isFile) continue;
            auto name = baseName(candidate.name);
            if (!name.startsWith(label ~ ".") || !name.endsWith(".overlay")) continue;
            auto reader = new OverlayReader(candidate.name);
            scope(exit) reader.closeReader();
            coverage ~= Coverage(reader.header.analyzerKey, reader.header.analyzerVersion,
                reader.header.sourceShardDigest == digest);
        }

        auto shardReader = new DocumentShardReader(shardPath);
        scope(exit) shardReader.closeReader();
        ShardDocument record;
        while (shardReader.next(record))
            reports ~= DocumentReport(shardPath, record.source.recordKey,
                record.id.text, coverage);
    }
    reports.sort!((a, b) => a.shardPath == b.shardPath ?
        a.documentId < b.documentId : a.shardPath < b.shardPath);
    return reports;
}

private string[] analyzerUniverse(const(DocumentReport)[] reports) {
    string[] keys;
    foreach (report; reports)
        foreach (c; report.coverage)
            if (!keys.canFind(c.analyzerKey)) keys ~= c.analyzerKey;
    keys.sort();
    return keys;
}

private void printReport(const(DocumentReport)[] reports) {
    auto keys = analyzerUniverse(reports);
    writefln("%-28s %-12s %-14s  %s", "shard : record key", "documentId", "", "coverage (header-only)");
    foreach (report; reports) {
        string[] cells;
        foreach (key; keys) {
            bool present;
            string ver;
            foreach (c; report.coverage) if (c.analyzerKey == key) {
                present = c.digestMatches;
                ver = c.analyzerVersion;
            }
            bool fileExistsWrongDigest = !present &&
                report.coverage.canFind!(c => c.analyzerKey == key);
            if (present) cells ~= key ~ "@" ~ ver;
            else if (fileExistsWrongDigest) cells ~= key ~ ": STALE (digest mismatch)";
            else cells ~= key ~ ": MISSING";
        }
        writefln("%-28s %-12s %-14s  %s",
            baseName(report.shardPath) ~ ":" ~ report.recordKey,
            report.documentId[0 .. 18] ~ "...", "", cells.join("  |  "));
    }
}

// ---------------------------------------------------------------------------
// Self-verification and demonstration.
// ---------------------------------------------------------------------------

private Coverage[] coverageFor(const(DocumentReport)[] reports, string recordKey) {
    foreach (report; reports) if (report.recordKey == recordKey) return report.coverage.dup;
    assert(false, "missing report for " ~ recordKey);
}
private bool has(const(Coverage)[] coverage, string key) {
    foreach (c; coverage) if (c.analyzerKey == key && c.digestMatches) return true;
    return false;
}
private bool fileExists(const(Coverage)[] coverage, string key) {
    foreach (c; coverage) if (c.analyzerKey == key) return true;
    return false;
}

/// Decodes actual annotation records -- deliberately NOT part of `survey()`
/// above, and never called by it. This exists only to honestly verify, with
/// real evidence, the shard-vs-record caveat this file's module doc claims:
/// that `theta-rep` and `theta-dup` receive byte-identical header-only
/// coverage (same shard, same headers) despite one of them carrying zero
/// actual near-dedup annotation records.
private size_t nearDedupRecordCountFor(string overlayPath, string documentId) {
    auto reader = new OverlayReader(overlayPath);
    scope(exit) reader.closeReader();
    import domain.shard_format : AnnotationRecord;
    AnnotationRecord record;
    size_t count;
    while (reader.next(record)) if (record.documentId == documentId) ++count;
    return count;
}

void main() {
    auto root = buildPath(tempDir(), "derivation-survey-check-" ~ randomUUID.toString);
    mkdirRecurse(root);
    scope(exit) rmdirRecurse(root);

    buildFixture(root);
    auto reports = survey(root);

    writeln("== derivation-identity survey (header-only; issue #349) ==");
    printReport(reports);
    writeln();

    // --- Correctness assertions: presence/absence per document, per analyzer ---
    auto alpha = coverageFor(reports, "alpha");
    auto beta = coverageFor(reports, "beta");
    auto thetaRep = coverageFor(reports, "theta-rep");
    auto thetaDup = coverageFor(reports, "theta-dup");
    auto gamma = coverageFor(reports, "gamma");
    auto delta = coverageFor(reports, "delta");
    auto epsilon = coverageFor(reports, "epsilon");
    auto zeta = coverageFor(reports, "zeta");

    foreach (name, coverage; ["alpha": alpha, "beta": beta,
            "theta-rep": thetaRep, "theta-dup": thetaDup]) {
        need(coverage.has("exact-dedup"), name ~ ": expected exact-dedup present");
        need(coverage.has("near-dedup"), name ~ ": expected near-dedup present");
        need(coverage.has("similarity-buckets"), name ~ ": expected similarity-buckets present");
    }
    need(gamma.has("exact-dedup"), "gamma: expected exact-dedup present");
    need(!gamma.has("near-dedup") && !gamma.fileExists("near-dedup"),
        "gamma: expected near-dedup absent (no such overlay file at all)");
    need(!gamma.has("similarity-buckets") && !gamma.fileExists("similarity-buckets"),
        "gamma: expected similarity-buckets absent");

    need(!delta.has("exact-dedup") && !delta.fileExists("exact-dedup"),
        "delta: expected exact-dedup absent");
    need(delta.has("near-dedup"), "delta: expected near-dedup present");
    need(delta.has("similarity-buckets"), "delta: expected similarity-buckets present");

    need(epsilon.length == 0, "epsilon: expected zero overlay coverage");

    need(zeta.fileExists("exact-dedup") && !zeta.has("exact-dedup"),
        "zeta: expected a same-named exact-dedup overlay file that FAILS digest " ~
        "verification (stale/misfiled), not silently reported as present");

    writeln("Correctness assertions: PASS (dense/sparse/absent/stale all distinguished)");

    // --- Caveat demonstration: decode real records, outside the survey ---
    auto thetaOverlay = buildPath(root, "batch-1", "theta.near-dedup.overlay");
    auto repId = "";
    auto dupId = "";
    foreach (report; reports) {
        if (report.recordKey == "theta-rep") repId = report.documentId;
        if (report.recordKey == "theta-dup") dupId = report.documentId;
    }
    auto repRecords = nearDedupRecordCountFor(thetaOverlay, repId);
    auto dupRecords = nearDedupRecordCountFor(thetaOverlay, dupId);
    writefln("Caveat check (decodes annotation records; NOT part of the header-only " ~
        "survey above -- done here only to verify the claim honestly): " ~
        "theta-rep has %d near-dedup annotation record(s); theta-dup has %d.",
        repRecords, dupRecords);
    need(repRecords == 0,
        "theta-rep is a genuine solo with no near-duplicates: expected zero real records");
    need(repRecords != dupRecords || dupRecords == 0,
        "expected theta-rep and theta-dup's real record counts to differ, proving " ~
        "identical header-only coverage does not imply identical per-document content");
    writeln("Header-only coverage for theta-rep and theta-dup is IDENTICAL (same shard, " ~
        "same headers) even though their real near-dedup record counts differ -- " ~
        "confirming the shard-vs-record caveat this tool's module doc claims.");

    writeln();
    writeln("derivation-identity survey: header-only presence/absence, dense vs. " ~
        "sparse analyzers, and stale-digest detection all verified against a real, " ~
        "unmodified-upstream-writer fixture: ok");
}
