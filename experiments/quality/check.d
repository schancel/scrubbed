module quality.check;

import domain.document : OutputName, SourceLocator;
import domain.quality_features;
import domain.shard_format : ShardDocument, decodeDocument, encodeDocument,
    AnnotationField, AnnotationRecord, maxDocumentPayload;
import effects.document_shards : DocumentShardWriter, OverlayWriter, OverlayReader,
    PublishStep, shardDigest;
import effects.quality_overlay;
import quality.fixtures : heldOut;
import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;
import std.exception : assertThrown;
import std.stdio : writeln;
import std.file : mkdir, read, rmdirRecurse, tempDir;
import std.path : buildPath;
import std.uuid : randomUUID;

private void check(bool okay, string reason) {
    if (!okay) throw new Exception(reason);
}

private string hex(const(ubyte)[] bytes) {
    return toHexString!(LetterCase.lower)(bytes).idup;
}

private void rejects(scope void delegate() action) {
    bool rejected;
    try action(); catch (Exception) rejected = true;
    check(rejected, "expected rejection");
}

private void featureGoldens() {
    auto corpus = heldOut();
    check(corpus.length == 6, "held-out split size");
    ubyte[] fixtureBytes;
    foreach (source; corpus) fixtureBytes ~= encodeDocument(source);
    check(hex(sha256Of(fixtureBytes)[]) ==
        "87f2910dbba6e1921f9e9f48b7dc3f405d051f90ccbe65f76c44f2f06a558fc2",
        "held-out fixture digest changed");
    uint[6][7] expected = [
        [0, 5, 6, 2, 4, 8],
        [0, 5, 3, 0, 4, 8],
        [0, 3, 1, 0, 1, 2],
        [0, 3, 1, 0, 2, 6],
        [0, 2, 1, 0, 2, 2],
        [0, 0, 1, 0, 0, 0],
        [0, 1, 0, 0, 0, 1],
    ];
    // Rows: bytes, scalars, lines, letters, controls, replacements, duplicates.
    foreach (index, source; corpus) {
        auto value = measure(decodeDocument(encodeDocument(source)));
        check(value.documentId == source.id && value.contentDigest == source.contentDigest,
            "measurement revision binding");
        check(value.byteLength == expected[0][index] &&
            value.scalarCount == expected[1][index] &&
            value.lineCount == expected[2][index] &&
            value.letterCount == expected[3][index] &&
            value.controlCount == expected[4][index] &&
            value.replacementCount == expected[5][index] &&
            value.duplicateLineCount == expected[6][index],
            "held-out feature golden changed");
        check(decodeMeasured(encodeMeasured(value), source.id, source.contentDigest) == value,
            "stored measured feature roundtrip");
    }
    check(measure(corpus[3]).status == FeatureStatus.invalidUtf8,
        "malformed UTF-8 must be typed");
    ubyte[][] badInputs = [[0xc0, 0x80], [0xe2, 0x82], [0xed, 0xa0, 0x80]];
    foreach (bad; badInputs) {
        auto source = corpus[3];
        source.content = bad;
        check(measure(source).status == FeatureStatus.invalidUtf8,
            "malformed UTF-8 variant was accepted");
    }
    auto oversized = corpus[0];
    oversized.content = new ubyte[maxDocumentPayload + 1];
    rejects({ measure(oversized); });
    auto combining = ShardDocument(SourceLocator("quality-heldout-v1", "negative", "mark"),
        OutputName("mark"), cast(ubyte[])"\u0345".dup);
    check(measure(combining).scalarCount == 1 && measure(combining).letterCount == 0,
        "Alphabetic combining mark is not a Unicode General Category letter");
}

private void policyAndReplay() {
    auto corpus = heldOut();
    auto baseline = QualityPolicy(0, partsPerMillion, partsPerMillion, partsPerMillion);
    auto selective = QualityPolicy(8, 250_000, 0, 500_000);
    auto bytes = selective.canonicalBytes;
    check(hex(selective.digest[]) ==
        "9db8d4483275abf0c0bfc2bc73fa3c8010fe11e7095f769bf96ae4f945a39edd",
        "policy identity golden changed");
    check(QualityPolicy.fromCanonicalBytes(bytes).digest == selective.digest,
        "policy canonical roundtrip");
    check(hex(selective.digest[]) != hex(baseline.digest[]), "policy collision");
    auto changed = bytes.dup;
    changed[$ - 1] ^= 1;
    check(QualityPolicy.fromCanonicalBytes(changed).digest != selective.digest,
        "threshold mutation retained policy identity");
    rejects({ QualityPolicy.fromCanonicalBytes(bytes[0 .. $ - 1]); });
    changed = bytes.dup;
    changed[0] ^= 1;
    rejects({ QualityPolicy.fromCanonicalBytes(changed); });
    changed = bytes.dup;
    changed[$ - 1] = 0xff;
    changed[$ - 2] = 0xff;
    changed[$ - 3] = 0xff;
    changed[$ - 4] = 0xff;
    rejects({ QualityPolicy.fromCanonicalBytes(changed); });
    rejects({ QualityPolicy(0, partsPerMillion + 1, 0, 0); });
    rejects({ QualityPolicy.init.canonicalBytes(); });

    auto measured = measure(corpus[5]);
    auto originalContent = corpus[5].content.dup;
    auto stored = encodeMeasured(measured).dup;
    auto replayed = decodeMeasured(stored, corpus[5].id, corpus[5].contentDigest);
    // Both decisions consume exactly the same stored bytes; source is not passed.
    auto a = decide(replayed, baseline);
    auto b = decide(replayed, selective);
    check(a.disposition == Disposition.keep && a.reasons.length == 0,
        "baseline boundary decision");
    check(b.disposition == Disposition.keep && b.reasons.length == 0,
        "inclusive threshold boundary");
    auto strict = QualityPolicy(9, 249_999, 0, 499_999);
    auto c = decide(decodeMeasured(stored, corpus[5].id, corpus[5].contentDigest), strict);
    check(c.disposition == Disposition.drop &&
        c.reasons == [Reason.tooShort, Reason.tooManyControls,
            Reason.tooManyDuplicateLines], "ordered threshold reasons");
    check(c.analyzerIdentity != a.analyzerIdentity && c.policyDigest != a.policyDigest,
        "decision identity failed to bind policy");
    check(corpus[5].content == originalContent &&
        corpus[5].contentDigest == sha256Of(originalContent),
        "replay mutated source content");
    auto unicodeDecision = decide(measure(corpus[2]), selective);
    check(unicodeDecision.reasons == [Reason.tooShort, Reason.tooManyControls,
        Reason.tooManyReplacements], "replacement and ordered reasons");
    check(decide(measure(corpus[3]), strict).disposition == Disposition.quarantine &&
        decide(measure(corpus[3]), strict).reasons == [Reason.invalidUtf8],
        "malformed UTF-8 quarantine precedence");
    auto revision = corpus[5];
    revision.content ~= cast(ubyte)'x';
    rejects({ decodeMeasured(stored, revision.id, revision.contentDigest); });
    auto foreign = corpus[4];
    rejects({ decodeMeasured(stored, foreign.id, corpus[5].contentDigest); });
    auto corrupt = stored.dup;
    corrupt[$ - 1] = 0xff;
    rejects({ decodeMeasured(corrupt, corpus[5].id, corpus[5].contentDigest); });
    corrupt = stored.dup;
    corrupt[$ - 33] ^= 1; // feature schema
    rejects({ decodeMeasured(corrupt, corpus[5].id, corpus[5].contentDigest); });

    // A forged valid measurement for one space cannot claim zero decoded scalars.
    auto space = ShardDocument(SourceLocator("quality-heldout-v1", "negative", "space"),
        OutputName("space"), cast(ubyte[])" ".dup);
    auto impossible = measure(space);
    impossible.scalarCount = 0;
    rejects({ decide(impossible, baseline); });
    rejects({ encodeMeasured(impossible); });
    auto forged = encodeMeasured(measure(space));
    forged[$ - 24 .. $ - 20] = [cast(ubyte)0, 0, 0, 0];
    rejects({ decodeMeasured(forged, space.id, space.contentDigest); });

    // Letter, Cc control, and replacement are disjoint scalar categories.
    auto letter = ShardDocument(SourceLocator("quality-heldout-v1", "negative", "overlap"),
        OutputName("overlap"), cast(ubyte[])"a".dup);
    auto overlap = measure(letter);
    overlap.controlCount = 1;
    overlap.replacementCount = 1;
    auto zeroControls = QualityPolicy(0, 0, partsPerMillion, partsPerMillion);
    rejects({ decide(overlap, zeroControls); });
    rejects({ encodeMeasured(overlap); });
    forged = encodeMeasured(measure(letter));
    forged[$ - 12 .. $ - 8] = [cast(ubyte)0, 0, 0, 1];
    forged[$ - 8 .. $ - 4] = [cast(ubyte)0, 0, 0, 1];
    rejects({ decodeMeasured(forged, letter.id, letter.contentDigest); });
}

private ShardDocument[] overlayCorpus() {
    // Authored independently of the pure-API fixtures. Train examples 0-1;
    // held-out verification examples 2-5. All content is synthetic.
    return [
        ShardDocument(SourceLocator("quality-overlay-v1", "train", "empty"),
            OutputName("empty"), []),
        ShardDocument(SourceLocator("quality-overlay-v1", "train", "plain"),
            OutputName("plain"), cast(ubyte[])"abcd".dup),
        ShardDocument(SourceLocator("quality-overlay-v1", "heldout", "repeat"),
            OutputName("repeat"), cast(ubyte[])"a\na\n".dup),
        ShardDocument(SourceLocator("quality-overlay-v1", "heldout", "invalid"),
            OutputName("invalid"), [cast(ubyte)0xc0, 0x80]),
        ShardDocument(SourceLocator("quality-overlay-v1", "heldout", "control"),
            OutputName("control"), cast(ubyte[])"a\0b".dup),
        ShardDocument(SourceLocator("quality-overlay-v1", "heldout", "replacement"),
            OutputName("replacement"), cast(ubyte[])"\uFFFD".dup),
    ];
}

private void overlayGoldens() {
    auto root = buildPath(tempDir(), "scrubbed-quality-" ~ randomUUID.toString);
    mkdir(root);
    scope(exit) rmdirRecurse(root);
    auto shardPath = buildPath(root, "source.shard");
    auto featurePath = buildPath(root, "features.overlay");
    auto decisionPath = buildPath(root, "decisions.overlay");
    auto unrelatedPath = buildPath(root, "unrelated.overlay");
    auto missingPath = buildPath(root, "missing.overlay");
    auto wrongVersionPath = buildPath(root, "wrong-version.overlay");
    auto stalePath = buildPath(root, "stale.overlay");
    auto corpus = overlayCorpus();
    // C01 requires canonical sorted IDs, not source-key order.
    import std.algorithm : sort;
    corpus.sort!((a, b) => a.id.text < b.id.text);
    ubyte[] authoredBytes;
    auto sourceWriter = new DocumentShardWriter(shardPath);
    foreach (doc; corpus) {
        authoredBytes ~= encodeDocument(doc);
        sourceWriter.append(doc);
    }
    sourceWriter.publish();
    check(hex(sha256Of(authoredBytes)[]) ==
        "e49f8e9ca1dc7633fb33fcc7fbe6ea5a077cc2f3dd5f1ca9e9d90aea6f10fba7",
        "authored overlay corpus changed");
    auto sourceBytes = cast(ubyte[])read(shardPath);
    auto sourceDigest = shardDigest(shardPath);
    import core.sys.posix.sys.stat : stat, stat_t;
    import std.string : toStringz;
    stat_t beforeInfo;
    check(stat(shardPath.toStringz, &beforeInfo) == 0,
        "cannot inspect source inode");
    auto unrelated = new OverlayWriter(unrelatedPath, shardPath, "other", "v1");
    foreach (doc; corpus)
        unrelated.append(AnnotationRecord(doc.id.text, doc.contentDigest,
            [AnnotationField("note", [cast(ubyte)1])]));
    unrelated.publish();
    auto unrelatedBytes = cast(ubyte[])read(unrelatedPath);

    publishMeasurements(shardPath, featurePath);
    auto featureBytes = cast(ubyte[])read(featurePath);
    rejects({ publishMeasurements(shardPath, featurePath,
        (PublishStep step) { if (step == PublishStep.beforePublish)
            throw new Exception("injected feature prepublish failure"); }); });
    check(cast(ubyte[])read(featurePath) == featureBytes,
        "feature prepublish fault replaced prior overlay");
    auto featureReader = new OverlayReader(featurePath);
    check(featureReader.header.analyzerKey == featureAnalyzerKey &&
        featureReader.header.analyzerVersion == featureAnalyzerVersion(),
        "feature header identity");
    featureReader.closeReader();
    auto permissive = QualityPolicy(0, partsPerMillion, partsPerMillion,
        partsPerMillion);
    auto selective = QualityPolicy(4, 0, 0, 0);
    auto base = dryRun(shardPath, featurePath, permissive);
    auto strict = dryRun(shardPath, featurePath, selective);
    check(base.documents == 6 && base.dispositions == [cast(ulong)5, 0, 1] &&
        base.reasons == [cast(ulong)1, 0, 0, 0, 0],
        "permissive disposition/reason partitions");
    check(strict.documents == 6 && strict.dispositions == [cast(ulong)1, 4, 1] &&
        strict.reasons == [cast(ulong)1, 3, 2, 1, 1],
        "strict overlapping reason counts");
    check(strict.byteLength.bins == [cast(ulong)1, 5, 0, 0, 0] &&
        strict.byteLength.unavailable == 0 &&
        strict.scalarCount.bins == [cast(ulong)1, 4, 0, 0, 0] &&
        strict.scalarCount.unavailable == 1 &&
        strict.lineCount.bins == [cast(ulong)1, 4, 0, 0, 0] &&
        strict.lineCount.unavailable == 1 &&
        strict.letterCount.bins == [cast(ulong)2, 3, 0, 0, 0] &&
        strict.letterCount.unavailable == 1 &&
        strict.controlCount.bins == [cast(ulong)3, 2, 0, 0, 0] &&
        strict.controlCount.unavailable == 1 &&
        strict.replacementCount.bins == [cast(ulong)4, 1, 0, 0, 0] &&
        strict.replacementCount.unavailable == 1 &&
        strict.duplicateLineCount.bins == [cast(ulong)4, 1, 0, 0, 0] &&
        strict.duplicateLineCount.unavailable == 1,
        "fixed-bin distribution goldens");
    check(cast(ubyte[])read(featurePath) == featureBytes &&
        cast(ubyte[])read(shardPath) == sourceBytes &&
        shardDigest(shardPath) == sourceDigest &&
        cast(ubyte[])read(unrelatedPath) == unrelatedBytes,
        "dry run wrote source or overlays");
    publishDecisions(shardPath, featurePath, decisionPath, permissive);
    auto firstDecisionBytes = cast(ubyte[])read(decisionPath);
    publishDecisions(shardPath, featurePath, decisionPath, selective);
    check(cast(ubyte[])read(decisionPath) != firstDecisionBytes &&
        cast(ubyte[])read(featurePath) == featureBytes,
        "two-policy replay did not reuse stored bytes");
    auto decisions = new OverlayReader(decisionPath);
    check(decisions.header.analyzerKey == decisionAnalyzerKey &&
        decisions.header.analyzerVersion == decisionAnalyzerVersion(selective),
        "decision overlay header identity");
    AnnotationRecord record;
    ubyte[] lastDecisionValue;
    size_t index;
    while (decisions.next(record)) {
        check(record.documentId == corpus[index].id.text &&
            record.fields.length == 1 && record.fields[0].key == decisionFieldKey,
            "decision record identity");
        auto value = decodeDecisionValue(record.fields[0].value,
            corpus[index], selective);
        lastDecisionValue = record.fields[0].value.dup;
        check(value.measured.documentId == corpus[index].id &&
            value.analyzerIdentity == decide(measure(corpus[index]), selective).analyzerIdentity,
            "per-document decision value identity");
        auto corrupt = record.fields[0].value.dup;
        corrupt[$ - 1] ^= 1;
        rejects({ decodeDecisionValue(corrupt, corpus[index], selective); });
        corrupt = record.fields[0].value.dup;
        corrupt[corrupt.length - 33] ^= 1; // reason byte (or disposition)
        rejects({ decodeDecisionValue(corrupt, corpus[index], selective); });
        auto differentRevision = corpus[index];
        differentRevision.content ~= cast(ubyte)'x';
        rejects({ decodeDecisionValue(record.fields[0].value,
            differentRevision, selective); });
        ++index;
    }
    check(index == corpus.length, "decision record count");
    decisions.closeReader();
    rejects({ decodeDecisionValue(lastDecisionValue, corpus[$ - 1], permissive); });
    auto prior = cast(ubyte[])read(decisionPath);
    rejects({ publishDecisions(shardPath, featurePath, decisionPath, permissive,
        (PublishStep step) { if (step == PublishStep.beforePublish)
            throw new Exception("injected prepublish failure"); }); });
    check(cast(ubyte[])read(decisionPath) == prior,
        "prepublish fault replaced prior overlay");
    // A decision target must never consume and replace its feature source.
    import core.sys.posix.unistd : link, symlink;
    rejects({ publishDecisions(shardPath, featurePath, featurePath, selective); });
    rejects({ publishDecisions(shardPath, featurePath,
        root ~ "/./features.overlay", selective); });
    auto hardlinkPath = buildPath(root, "features-hardlink.overlay");
    check(link(featurePath.toStringz, hardlinkPath.toStringz) == 0,
        "cannot create hardlink alias fixture");
    rejects({ publishDecisions(shardPath, featurePath, hardlinkPath, selective); });
    auto symlinkPath = buildPath(root, "features-symlink.overlay");
    check(symlink(featurePath.toStringz, symlinkPath.toStringz) == 0,
        "cannot create symlink alias fixture");
    rejects({ publishDecisions(shardPath, featurePath, symlinkPath, selective); });
    check(cast(ubyte[])read(featurePath) == featureBytes &&
        dryRun(shardPath, featurePath, selective).documents == corpus.length,
        "alias refusal lost stored measurements");
    publishDecisions(shardPath, featurePath, decisionPath, permissive);
    check(cast(ubyte[])read(featurePath) == featureBytes &&
        cast(ubyte[])read(decisionPath) != prior,
        "alias refusal prevented subsequent two-policy replay");
    auto missing = new OverlayWriter(missingPath, shardPath, featureAnalyzerKey,
        featureAnalyzerVersion());
    missing.publish();
    rejects({ dryRun(shardPath, missingPath, selective); });
    auto wrongVersion = new OverlayWriter(wrongVersionPath, shardPath,
        featureAnalyzerKey, "features:v0");
    wrongVersion.publish();
    rejects({ dryRun(shardPath, wrongVersionPath, selective); });
    auto stale = new OverlayWriter(stalePath, shardPath, featureAnalyzerKey,
        featureAnalyzerVersion());
    foreach (doc; corpus) {
        auto digest = doc.contentDigest;
        digest[0] ^= 1;
        stale.append(AnnotationRecord(doc.id.text, digest,
            [AnnotationField(featureFieldKey, encodeMeasured(measure(doc)))]));
    }
    stale.publish();
    rejects({ dryRun(shardPath, stalePath, selective); });
    auto malformedPath = buildPath(root, "malformed.overlay");
    auto malformed = new OverlayWriter(malformedPath, shardPath,
        featureAnalyzerKey, featureAnalyzerVersion());
    foreach (doc; corpus) {
        auto value = encodeMeasured(measure(doc));
        value[0] ^= 1;
        malformed.append(AnnotationRecord(doc.id.text, doc.contentDigest,
            [AnnotationField(featureFieldKey, value)]));
    }
    malformed.publish();
    rejects({ dryRun(shardPath, malformedPath, selective); });
    auto wrongFieldPath = buildPath(root, "wrong-field.overlay");
    auto wrongField = new OverlayWriter(wrongFieldPath, shardPath,
        featureAnalyzerKey, featureAnalyzerVersion());
    foreach (doc; corpus)
        wrongField.append(AnnotationRecord(doc.id.text, doc.contentDigest,
            [AnnotationField("unexpected", encodeMeasured(measure(doc)))]));
    wrongField.publish();
    rejects({ dryRun(shardPath, wrongFieldPath, selective); });
    stat_t afterInfo;
    check(stat(shardPath.toStringz, &afterInfo) == 0 &&
        beforeInfo.st_ino == afterInfo.st_ino &&
        beforeInfo.st_dev == afterInfo.st_dev,
        "source inode changed");
    check(cast(ubyte[])read(shardPath) == sourceBytes &&
        cast(ubyte[])read(unrelatedPath) == unrelatedBytes,
        "publication mutated source or unrelated overlay");

    // The held-out split is independently materialized as a C01 shard and
    // reported without the train rows.
    auto heldShard = buildPath(root, "heldout.shard");
    auto heldFeatures = buildPath(root, "heldout.features");
    auto heldWriter = new DocumentShardWriter(heldShard);
    ubyte[] heldBytes;
    foreach (doc; corpus)
        if (doc.source.sourceKey == "heldout") {
            heldBytes ~= encodeDocument(doc);
            heldWriter.append(doc);
        }
    heldWriter.publish();
    check(hex(sha256Of(heldBytes)[]) ==
        "f0ceced0dfee7bee2b5d270bdc8a0b2d7d084877868d8dda54775dcad61aeba8",
        "held-out shard payload digest changed");
    publishMeasurements(heldShard, heldFeatures);
    auto held = dryRun(heldShard, heldFeatures, selective);
    check(held.documents == 4 &&
        held.dispositions == [cast(ulong)0, 3, 1] &&
        held.reasons == [cast(ulong)1, 2, 2, 1, 1] &&
        held.byteLength.bins == [cast(ulong)0, 4, 0, 0, 0] &&
        held.scalarCount.bins == [cast(ulong)0, 3, 0, 0, 0] &&
        held.lineCount.bins == [cast(ulong)0, 3, 0, 0, 0] &&
        held.letterCount.bins == [cast(ulong)1, 2, 0, 0, 0] &&
        held.controlCount.bins == [cast(ulong)1, 2, 0, 0, 0] &&
        held.replacementCount.bins == [cast(ulong)2, 1, 0, 0, 0] &&
        held.duplicateLineCount.bins == [cast(ulong)2, 1, 0, 0, 0] &&
        held.scalarCount.unavailable == 1 &&
        held.lineCount.unavailable == 1 &&
        held.letterCount.unavailable == 1 &&
        held.controlCount.unavailable == 1 &&
        held.replacementCount.unavailable == 1 &&
        held.duplicateLineCount.unavailable == 1,
        "held-out-only fixed-bin/reason goldens");
}

private void boundedReplay() {
    import core.memory : GC;
    import std.file : dirEntries, SpanMode;
    size_t fds() {
        size_t count;
        foreach (_; dirEntries("/dev/fd", SpanMode.shallow)) ++count;
        return count;
    }
    auto root = buildPath(tempDir(), "scrubbed-quality-bound-" ~ randomUUID.toString);
    mkdir(root);
    scope(exit) rmdirRecurse(root);
    auto shard = buildPath(root, "source.shard");
    auto features = buildPath(root, "features.overlay");
    auto decisions = buildPath(root, "decisions.overlay");
    ShardDocument[] corpus;
    foreach (i; 0 .. 1024) {
        import std.format : format;
        auto key = format("%08d", i);
        corpus ~= ShardDocument(SourceLocator("quality-resource-v1", "heldout", key),
            OutputName(key), cast(ubyte[])"small text".dup);
    }
    import std.algorithm : sort;
    corpus.sort!((a, b) => a.id.text < b.id.text);
    auto writer = new DocumentShardWriter(shard);
    foreach (doc; corpus) writer.append(doc);
    writer.publish();
    publishMeasurements(shard, features);
    GC.collect();
    auto usedBefore = GC.stats.usedSize;
    auto fdsBefore = fds();
    auto policy = QualityPolicy(0, partsPerMillion, partsPerMillion,
        partsPerMillion);
    foreach (_; 0 .. 4) {
        auto report = dryRun(shard, features, policy);
        check(report.documents == 1024 && report.dispositions[0] == 1024,
            "bounded replay document count");
        publishDecisions(shard, features, decisions, policy);
    }
    GC.collect();
    check(GC.stats.usedSize <= usedBefore + 16 * 1024 * 1024 &&
        fds() <= fdsBefore + 2,
        "replay retained corpus memory or file descriptors");
}

void main() {
    featureGoldens();
    policyAndReplay();
    overlayGoldens();
    boundedReplay();
    writeln("quality feature/policy/replay and overlay goldens: ok");
}
