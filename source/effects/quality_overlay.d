/// Opt-in C01 effects facade for revision-bound quality measurements and replay.
module effects.quality_overlay;

import domain.quality_features;
import domain.shard_format : AnnotationField, AnnotationRecord, ShardDocument;
import effects.document_shards : DocumentShardReader, JoinedOverlay, OverlayReader,
    OverlayWriter, PublishFault, joinShards;
import core.stdc.errno : errno, ENOENT;
import core.sys.posix.sys.stat : stat, stat_t;
import std.digest : LetterCase, toHexString;
import std.exception : enforce;
import std.path : absolutePath, buildNormalizedPath;
import std.string : toStringz;

enum featureAnalyzerKey = "quality.features";
enum decisionAnalyzerKey = "quality.decisions";
enum featureFieldKey = "measurement";
enum decisionFieldKey = "decision";
enum decisionValueSchema = 1;

/// These are exact integer count bins, inclusive at both ends.
enum uint[4] binCeilings = [0, 4, 15, 63];
enum size_t numericBins = binCeilings.length + 1;

string featureAnalyzerVersion() {
    return "features:v1:schema=" ~ decimal(featureSchema);
}

string decisionAnalyzerVersion(QualityPolicy policy) {
    return "decisions:v1:feature=" ~ decimal(featureSchema) ~
        ":decision=" ~ decimal(decisionValueSchema) ~ ":policy=" ~
        toHexString!(LetterCase.lower)(policy.digest[]).idup;
}

private string decimal(uint value) {
    import std.conv : to;
    return to!string(value);
}

/// A text feature's unavailable count is the invalid-UTF8 bucket.
struct FeatureDistribution {
    ulong[numericBins] bins;
    ulong unavailable;
    void add(uint value) {
        size_t index;
        while (index < binCeilings.length && value > binCeilings[index]) ++index;
        ++bins[index];
    }
}

struct DryRunReport {
    ulong documents;
    FeatureDistribution byteLength;
    FeatureDistribution scalarCount;
    FeatureDistribution lineCount;
    FeatureDistribution letterCount;
    FeatureDistribution controlCount;
    FeatureDistribution replacementCount;
    FeatureDistribution duplicateLineCount;
    ulong[3] dispositions; // keep, drop, quarantine
    ulong[5] reasons; // Reason enum order; reasons may overlap.

    void add(QualityDecision decision) {
        auto measured = decision.measured;
        ++documents;
        byteLength.add(measured.byteLength);
        if (measured.status == FeatureStatus.invalidUtf8) {
            ++scalarCount.unavailable;
            ++lineCount.unavailable;
            ++letterCount.unavailable;
            ++controlCount.unavailable;
            ++replacementCount.unavailable;
            ++duplicateLineCount.unavailable;
        } else {
            scalarCount.add(measured.scalarCount);
            lineCount.add(measured.lineCount);
            letterCount.add(measured.letterCount);
            controlCount.add(measured.controlCount);
            replacementCount.add(measured.replacementCount);
            duplicateLineCount.add(measured.duplicateLineCount);
        }
        ++dispositions[cast(size_t)decision.disposition];
        foreach (reason; decision.reasons) ++reasons[cast(size_t)reason];
    }
}

/// The only effects operation that extracts content features. The writer's
/// per-overlay rename is the publication boundary; failures leave old bytes.
void publishMeasurements(string shardPath, string overlayPath,
        PublishFault fault = null) {
    auto reader = new DocumentShardReader(shardPath);
    scope(exit) reader.closeReader();
    auto writer = new OverlayWriter(overlayPath, shardPath,
        featureAnalyzerKey, featureAnalyzerVersion());
    scope(failure) writer.abort();
    ShardDocument source;
    while (reader.next(source)) {
        auto encoded = encodeMeasured(measure(source));
        writer.append(AnnotationRecord(source.id.text, source.contentDigest,
            [AnnotationField(featureFieldKey, encoded)]));
    }
    writer.publish(fault);
}

/// Parse exactly one C01 feature field after C01's shard/revision join.
private MeasuredFeatures stored(ShardDocument source, JoinedOverlay overlay) {
    enforce(overlay.analyzerKey == featureAnalyzerKey &&
        overlay.analyzerVersion == featureAnalyzerVersion(),
        "quality overlay: conflicting feature analyzer version");
    enforce(overlay.present && overlay.fields.length == 1 &&
        overlay.fields[0].key == featureFieldKey,
        "quality overlay: missing or malformed feature annotation");
    return decodeMeasured(overlay.fields[0].value, source.id, source.contentDigest);
}

/// Replay uses only C01-joined stored measurements, never measure().
void visitStoredDecisions(string shardPath, string featureOverlayPath,
        QualityPolicy policy, scope void delegate(QualityDecision) visit) {
    // No decide() call occurs for an empty shard, so validate policy here.
    policy.canonicalBytes();
    // Validate at overlay-open time: an empty shard yields no stored() calls.
    auto features = new OverlayReader(featureOverlayPath);
    scope(exit) features.closeReader();
    enforce(features.header.analyzerKey == featureAnalyzerKey &&
        features.header.analyzerVersion == featureAnalyzerVersion(),
        "quality overlay: conflicting feature analyzer version");
    features.closeReader();
    joinShards(shardPath, [featureOverlayPath], (ShardDocument source,
            JoinedOverlay[] overlays) {
        enforce(overlays.length == 1, "quality overlay: missing feature overlay");
        visit(decide(stored(source, overlays[0]), policy));
    });
}

DryRunReport dryRun(string shardPath, string featureOverlayPath,
        QualityPolicy policy) {
    DryRunReport report;
    visitStoredDecisions(shardPath, featureOverlayPath, policy,
        (QualityDecision decision) { report.add(decision); });
    return report;
}

private void put32(ref ubyte[] bytes, uint value) {
    bytes ~= cast(ubyte)(value >> 24);
    bytes ~= cast(ubyte)(value >> 16);
    bytes ~= cast(ubyte)(value >> 8);
    bytes ~= cast(ubyte)value;
}

private uint get32(const(ubyte)[] bytes, ref size_t at) {
    enforce(bytes.length - at >= 4, "quality overlay: truncated decision value");
    uint value;
    foreach (_; 0 .. 4) value = (value << 8) | bytes[at++];
    return value;
}

/// Canonical decision value includes policy and per-document identity; the
/// overlay-wide version deliberately contains no document-specific data.
ubyte[] encodeDecisionValue(QualityDecision decision, QualityPolicy policy) {
    auto measured = encodeMeasured(decision.measured);
    auto expected = decide(decision.measured, policy);
    enforce(decision == expected, "quality overlay: decision/policy mismatch");
    auto policyBytes = policy.canonicalBytes();
    ubyte[] result = cast(ubyte[])"scrubbed:quality-overlay-decision:v1\0".dup;
    put32(result, decisionValueSchema);
    put32(result, cast(uint)policyBytes.length);
    result ~= policyBytes;
    result ~= decision.policyDigest[];
    put32(result, cast(uint)measured.length);
    result ~= measured;
    result ~= cast(ubyte)decision.disposition;
    result ~= cast(ubyte)decision.reasons.length;
    foreach (reason; decision.reasons) result ~= cast(ubyte)reason;
    result ~= decision.analyzerIdentity[];
    return result;
}

/// Decode defensively: all stored fields must equal pure replay for the
/// supplied source revision and canonical policy, not merely be parseable.
QualityDecision decodeDecisionValue(const(ubyte)[] bytes, ShardDocument source,
        QualityPolicy expectedPolicy) {
    auto prefix = cast(const(ubyte)[])"scrubbed:quality-overlay-decision:v1\0";
    enforce(bytes.length >= prefix.length + 4 && bytes[0 .. prefix.length] == prefix,
        "quality overlay: bad decision value tag");
    size_t at = prefix.length;
    enforce(get32(bytes, at) == decisionValueSchema,
        "quality overlay: unsupported decision schema");
    auto policyLength = get32(bytes, at);
    enforce(policyLength <= bytes.length - at, "quality overlay: truncated policy");
    auto policy = QualityPolicy.fromCanonicalBytes(bytes[at .. at + policyLength]);
    at += policyLength;
    enforce(policy.canonicalBytes == expectedPolicy.canonicalBytes &&
        bytes.length - at >= 32, "quality overlay: policy identity mismatch");
    auto digest = policy.digest;
    enforce(bytes[at .. at + 32] == digest[], "quality overlay: policy digest mismatch");
    at += 32;
    auto measuredLength = get32(bytes, at);
    enforce(measuredLength <= bytes.length - at,
        "quality overlay: truncated measurement");
    auto measured = decodeMeasured(bytes[at .. at + measuredLength], source.id,
        source.contentDigest);
    at += measuredLength;
    auto expected = decide(measured, policy);
    enforce(bytes.length - at == 2 + expected.reasons.length + 32 &&
        bytes[at++] == cast(ubyte)expected.disposition &&
        bytes[at++] == expected.reasons.length,
        "quality overlay: decision disposition or reason length mismatch");
    foreach (reason; expected.reasons)
        enforce(bytes[at++] == cast(ubyte)reason,
            "quality overlay: ordered reasons mismatch");
    enforce(bytes[at .. $] == expected.analyzerIdentity[],
        "quality overlay: analyzer identity mismatch");
    return expected;
}

/// Replaces only the named decision overlay after all records validate.
void publishDecisions(string shardPath, string featureOverlayPath,
        string decisionOverlayPath, QualityPolicy policy, PublishFault fault = null) {
    // C01 guards source-shard aliases; this facade must also guard its own
    // replay input. Reject lexical aliases and existing inode aliases before
    // opening the destination writer. C01 still owns symlink/hardlink target
    // safety at publication, and no hostile directory-race guarantee is made.
    enforce(buildNormalizedPath(absolutePath(featureOverlayPath)) !=
        buildNormalizedPath(absolutePath(decisionOverlayPath)),
        "quality overlay: decision target aliases feature overlay");
    stat_t featureInfo;
    enforce(stat(featureOverlayPath.toStringz, &featureInfo) == 0,
        "quality overlay: cannot inspect feature overlay");
    stat_t targetInfo;
    if (stat(decisionOverlayPath.toStringz, &targetInfo) == 0) {
        enforce(featureInfo.st_dev != targetInfo.st_dev ||
            featureInfo.st_ino != targetInfo.st_ino,
            "quality overlay: decision target aliases feature overlay");
    } else {
        enforce(errno == ENOENT, "quality overlay: cannot inspect decision target");
    }
    auto writer = new OverlayWriter(decisionOverlayPath, shardPath,
        decisionAnalyzerKey, decisionAnalyzerVersion(policy));
    scope(failure) writer.abort();
    visitStoredDecisions(shardPath, featureOverlayPath, policy,
        (QualityDecision decision) {
            writer.append(AnnotationRecord(decision.measured.documentId.text,
                decision.measured.contentDigest,
                [AnnotationField(decisionFieldKey,
                    encodeDecisionValue(decision, policy))]));
        });
    writer.publish(fault);
}
