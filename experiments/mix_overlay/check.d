module mix_overlay.check;

import core.sys.posix.fcntl : fcntl, F_GETFD;
import core.sys.posix.sys.resource : getrusage, rusage, RUSAGE_SELF;
import domain.document : OutputName, SourceLocator;
import domain.mix_policy : MissingAnnotation, MixDecision, MixPolicy, MixReason;
import domain.quality_features : QualityPolicy, decide, measure;
import domain.shard_format : AnnotationField, AnnotationRecord, ShardDocument;
import effects.document_shards : DocumentShardWriter, OverlayReader, OverlayWriter;
import effects.exact_dedup_overlay : DedupShard, dedupAnalyzerKey,
    dedupAnalyzerVersion, writeExactDedupOverlays;
import effects.mix_overlay : MixVisitReport, visitMixDecisions;
import effects.quality_overlay : decisionAnalyzerKey, decisionAnalyzerVersion,
    decisionFieldKey, encodeDecisionValue;
import std.algorithm.sorting : sort;
import std.file : mkdir, rmdirRecurse, tempDir;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : indexOf;
import std.uuid : randomUUID;

private void check(bool okay, string reason) {
    if (!okay) throw new Exception(reason);
}

private void rejects(scope void delegate() action) {
    bool caught;
    try action(); catch (Exception error) {
        check(error.msg.indexOf("private-canary") < 0 &&
            error.msg.indexOf("@example") < 0,
            "diagnostic leaked private content");
        caught = true;
    }
    check(caught, "expected overlay refusal");
}

private ShardDocument document(string key, string content) {
    return ShardDocument(SourceLocator("mix-check", "source", key),
        OutputName(key), cast(ubyte[])content.dup);
}

private void writeShard(string path, ShardDocument[] records) {
    records.sort!((a, b) => a.id.text < b.id.text);
    auto writer = new DocumentShardWriter(path);
    foreach (record; records) writer.append(record);
    writer.publish();
}

private void writeOverlay(string path, string shard, string key, string analyzerVersion,
        AnnotationRecord[] records) {
    records.sort!((a, b) => a.documentId < b.documentId);
    auto writer = new OverlayWriter(path, shard, key, analyzerVersion);
    foreach (record; records) writer.append(record);
    writer.publish();
}

private AnnotationRecord[] readOverlay(string path) {
    auto reader = new OverlayReader(path);
    scope(exit) reader.closeReader();
    AnnotationRecord[] records;
    AnnotationRecord record;
    while (reader.next(record)) records ~= record;
    return records;
}

private void writeQuality(string path, string shard,
        ShardDocument[] records, QualityPolicy policy) {
    AnnotationRecord[] annotations;
    foreach (source; records) {
        auto decision = decide(measure(source), policy);
        annotations ~= AnnotationRecord(source.id.text, source.contentDigest,
            [AnnotationField(decisionFieldKey,
                encodeDecisionValue(decision, policy))]);
    }
    writeOverlay(path, shard, decisionAnalyzerKey,
        decisionAnalyzerVersion(policy), annotations);
}

private struct Fixture {
    string shard;
    string quality;
    string dedup;
    ShardDocument[] records;
    AnnotationRecord[] qualityRows;
    AnnotationRecord[] dedupRows;
}

private Fixture fixture(string root, ShardDocument[] unsorted,
        QualityPolicy policy, string suffix) {
    Fixture result;
    result.shard = buildPath(root, "source-" ~ suffix);
    result.quality = buildPath(root, "quality-" ~ suffix);
    result.dedup = buildPath(root, "dedup-" ~ suffix);
    result.records = unsorted.dup;
    writeShard(result.shard, result.records);
    writeQuality(result.quality, result.shard, result.records, policy);
    writeExactDedupOverlays([DedupShard(result.shard, result.dedup)]);
    result.qualityRows = readOverlay(result.quality);
    result.dedupRows = readOverlay(result.dedup);
    return result;
}

private MixVisitReport visit(Fixture source, QualityPolicy quality,
        MixPolicy mix, ref MixDecision[] decisions) {
    return visitMixDecisions(source.shard, source.quality, source.dedup,
        quality, mix, (const(ShardDocument) record, MixDecision decision) {
            check(record.id == decision.id && record.content.length != 0,
                "callback source/decision association");
            decisions ~= decision;
        });
}

private void sameDecisions(MixDecision[] first, MixDecision[] second) {
    check(first.length == second.length, "decision length drift");
    foreach (i; 0 .. first.length)
        check(first[i].canonicalBytes == second[i].canonicalBytes,
            "decision bytes drift");
}

private ulong rssBytes() {
    rusage usage;
    check(getrusage(RUSAGE_SELF, &usage) == 0, "RSS observation failed");
    version (OSX) return cast(ulong)usage.ru_opaque[0];
    else version (linux) return cast(ulong)usage.ru_maxrss * 1024;
    else static assert(0, "RSS observation requires platform support");
}

private size_t fds() {
    size_t count;
    foreach (fd; 0 .. 256) if (fcntl(fd, F_GETFD) >= 0) ++count;
    return count;
}

void main() {
    auto root = buildPath(tempDir(), "mix-overlay-check-" ~ randomUUID.toString);
    mkdir(root);
    scope(exit) rmdirRecurse(root);
    auto beforeRss = rssBytes();
    auto beforeFds = fds();
    auto quality = QualityPolicy(0, 1_000_000, 1_000_000, 1_000_000);
    auto all = MixPolicy("0123456789abcdef", 1, 1);
    auto exclude = MixPolicy("0123456789abcdef", 1, 1,
        MissingAnnotation.exclude);
    ShardDocument[] records = [document("a", "private-canary@example.com"),
        document("b", "private-canary@example.com"), document("c", "other")];
    auto base = fixture(root, records, quality, "base");
    MixDecision[] expected;
    auto report = visit(base, quality, all, expected);
    check(report.total == 3 && report.counts[MixReason.selected] == 2 &&
        report.counts[MixReason.duplicate] == 1 && expected.length == 3,
        "joined quality and duplicate decisions");
    auto shuffled = fixture(root, [records[2], records[0], records[1]],
        quality, "shuffled");
    MixDecision[] again;
    auto repeat = visit(shuffled, quality, all, again);
    check(repeat == report, "shuffled report drift");
    sameDecisions(expected, again);

    auto missingQuality = base.qualityRows[1 .. $].dup;
    writeOverlay(base.quality, base.shard, decisionAnalyzerKey,
        decisionAnalyzerVersion(quality), missingQuality);
    rejects({ MixDecision[] output; visit(base, quality, all, output); });
    MixDecision[] missingOutput;
    auto missingReport = visit(base, quality, exclude, missingOutput);
    check(missingReport.counts[MixReason.missingQuality] == 1,
        "missing quality must exclude by typed reason");
    writeOverlay(base.quality, base.shard, decisionAnalyzerKey,
        decisionAnalyzerVersion(quality), base.qualityRows);
    auto orphanQuality = base.qualityRows.dup;
    orphanQuality ~= AnnotationRecord(document("orphan-quality", "x").id.text,
        document("orphan-quality", "x").contentDigest,
        base.qualityRows[0].fields);
    writeOverlay(base.quality, base.shard, decisionAnalyzerKey,
        decisionAnalyzerVersion(quality), orphanQuality);
    rejects({ MixDecision[] output; visit(base, quality, all, output); });
    writeOverlay(base.quality, base.shard, decisionAnalyzerKey,
        decisionAnalyzerVersion(quality), base.qualityRows);

    auto staleQuality = base.qualityRows.dup;
    staleQuality[0].contentDigest[0] ^= 1;
    writeOverlay(base.quality, base.shard, decisionAnalyzerKey,
        decisionAnalyzerVersion(quality), staleQuality);
    rejects({ MixDecision[] output; visit(base, quality, all, output); });
    auto badDecision = base.qualityRows.dup;
    badDecision[0].fields = badDecision[0].fields.dup;
    badDecision[0].fields[0].value = [cast(ubyte)0];
    writeOverlay(base.quality, base.shard, decisionAnalyzerKey,
        decisionAnalyzerVersion(quality), badDecision);
    rejects({ MixDecision[] output; visit(base, quality, all, output); });
    writeOverlay(base.quality, base.shard, decisionAnalyzerKey,
        decisionAnalyzerVersion(quality), base.qualityRows);

    writeOverlay(base.dedup, base.shard, dedupAnalyzerKey,
        dedupAnalyzerVersion, base.dedupRows[1 .. $].dup);
    rejects({ MixDecision[] output; visit(base, quality, all, output); });
    MixDecision[] noDedup;
    auto noDedupReport = visit(base, quality, exclude, noDedup);
    check(noDedupReport.counts[MixReason.missingDedup] == 1,
        "missing dedup must exclude by typed reason");
    writeOverlay(base.dedup, base.shard, dedupAnalyzerKey,
        dedupAnalyzerVersion, base.dedupRows);

    auto malformedQuality = base.qualityRows.dup;
    malformedQuality[0].fields = [AnnotationField("bad", [cast(ubyte)1])];
    writeOverlay(base.quality, base.shard, decisionAnalyzerKey,
        decisionAnalyzerVersion(quality), malformedQuality);
    rejects({ MixDecision[] output; visit(base, quality, all, output); });
    writeOverlay(base.quality, base.shard, decisionAnalyzerKey,
        decisionAnalyzerVersion(quality), base.qualityRows);
    rejects({ MixDecision[] output; visit(base,
        QualityPolicy(1, 1_000_000, 1_000_000, 1_000_000), all, output); });
    writeOverlay(base.quality, base.shard, decisionAnalyzerKey,
        "wrong-version", base.qualityRows);
    rejects({ MixDecision[] output; visit(base, quality, all, output); });
    writeOverlay(base.quality, base.shard, decisionAnalyzerKey,
        decisionAnalyzerVersion(quality), base.qualityRows);

    auto malformedDedup = base.dedupRows.dup;
    malformedDedup[0].fields = malformedDedup[0].fields.dup;
    malformedDedup[0].fields[1].value = new ubyte[32];
    writeOverlay(base.dedup, base.shard, dedupAnalyzerKey,
        dedupAnalyzerVersion, malformedDedup);
    rejects({ MixDecision[] output; visit(base, quality, all, output); });
    writeOverlay(base.dedup, base.shard, dedupAnalyzerKey,
        "wrong-version", base.dedupRows);
    rejects({ MixDecision[] output; visit(base, quality, all, output); });
    writeOverlay(base.dedup, base.shard, dedupAnalyzerKey,
        dedupAnalyzerVersion, base.dedupRows);

    auto stale = base.dedupRows.dup;
    stale[0].contentDigest[0] ^= 1;
    writeOverlay(base.dedup, base.shard, dedupAnalyzerKey,
        dedupAnalyzerVersion, stale);
    rejects({ MixDecision[] output; visit(base, quality, all, output); });
    auto orphan = base.dedupRows.dup;
    orphan ~= AnnotationRecord(document("orphan", "x").id.text,
        document("orphan", "x").contentDigest, base.dedupRows[0].fields);
    writeOverlay(base.dedup, base.shard, dedupAnalyzerKey,
        dedupAnalyzerVersion, orphan);
    rejects({ MixDecision[] output; visit(base, quality, all, output); });

    auto late = base.dedupRows.dup;
    late[$ - 1].fields = late[$ - 1].fields.dup;
    late[$ - 1].fields[3].value = cast(ubyte[])"00".dup;
    writeOverlay(base.dedup, base.shard, dedupAnalyzerKey,
        dedupAnalyzerVersion, late);
    size_t delivered;
    rejects({ visitMixDecisions(base.shard, base.quality, base.dedup,
        quality, all, (const(ShardDocument), MixDecision) { ++delivered; }); });
    check(delivered == 2, "late error callback prefix contract");

    auto empty = buildPath(root, "empty-shard");
    writeShard(empty, []);
    auto emptyQuality = buildPath(root, "empty-quality");
    auto emptyDedup = buildPath(root, "empty-dedup");
    writeOverlay(emptyQuality, empty, decisionAnalyzerKey,
        decisionAnalyzerVersion(quality), []);
    writeOverlay(emptyDedup, empty, dedupAnalyzerKey, "wrong-version", []);
    rejects({ visitMixDecisions(empty, emptyQuality, emptyDedup,
        quality, all, (const(ShardDocument), MixDecision) {}); });
    writeOverlay(emptyDedup, empty, dedupAnalyzerKey,
        dedupAnalyzerVersion, []);
    writeOverlay(emptyQuality, empty, decisionAnalyzerKey,
        "wrong-version", []);
    rejects({ visitMixDecisions(empty, emptyQuality, emptyDedup,
        quality, all, (const(ShardDocument), MixDecision) {}); });
    writeOverlay(emptyQuality, empty, decisionAnalyzerKey,
        decisionAnalyzerVersion(quality), []);
    check(visitMixDecisions(empty, emptyQuality, emptyDedup,
        quality, all, (const(ShardDocument), MixDecision) {}).total == 0,
        "empty joined shard");

    check(fds() == beforeFds, "file descriptor leak");
    check(rssBytes() - beforeRss < 64UL * 1024 * 1024,
        "resident-set growth exceeded 64 MiB");
    writeln("mix overlay: joined/missing/stale/version/orphan/malformed/empty/prefix/RSS/FD passed");
}
