/// Read-only C01 join of C02/C04 evidence for pure mix selection.
module effects.mix_overlay;

import domain.mix_policy : MixDecision, MixInput, MixPolicy, MixReason, decideMix;
import domain.quality_features : QualityDecision, QualityPolicy;
import domain.exact_dedup : ExactDuplicateLink;
import domain.shard_format : ShardDocument;
import effects.document_shards : JoinedOverlay, OverlayReader, joinShards;
import effects.exact_dedup_overlay : decodeCanonicalDedupLink, dedupAnalyzerKey,
    dedupAnalyzerVersion;
import effects.quality_overlay : decodeDecisionValue, decisionAnalyzerKey,
    decisionAnalyzerVersion, decisionFieldKey;
import std.exception : enforce;

struct MixVisitReport {
    ulong total;
    ulong[7] counts;
}

private void verifyHeader(string path, string expectedKey,
        string expectedVersion) {
    auto reader = new OverlayReader(path);
    scope(exit) reader.closeReader();
    enforce(reader.header.analyzerKey == expectedKey &&
        reader.header.analyzerVersion == expectedVersion,
        "mix overlay: wrong analyzer header");
}

/// Callback sees source content only for this call. A late error can leave a
/// callback prefix delivered; this API does not publish or roll back output.
MixVisitReport visitMixDecisions(string shardPath, string qualityPath,
        string dedupPath, QualityPolicy qualityPolicy, MixPolicy mixPolicy,
        scope void delegate(const(ShardDocument), MixDecision) visit) {
    qualityPolicy.canonicalBytes();
    mixPolicy.canonicalBytes();
    enforce(visit !is null, "mix overlay: missing visitor");
    verifyHeader(qualityPath, decisionAnalyzerKey,
        decisionAnalyzerVersion(qualityPolicy));
    verifyHeader(dedupPath, dedupAnalyzerKey, dedupAnalyzerVersion);
    MixVisitReport report;
    joinShards(shardPath, [qualityPath, dedupPath],
            (ShardDocument source, JoinedOverlay[] overlays) {
        enforce(overlays.length == 2 &&
            overlays[0].analyzerKey == decisionAnalyzerKey &&
            overlays[0].analyzerVersion == decisionAnalyzerVersion(qualityPolicy) &&
            overlays[1].analyzerKey == dedupAnalyzerKey &&
            overlays[1].analyzerVersion == dedupAnalyzerVersion,
            "mix overlay: wrong analyzer header");
        QualityDecision quality;
        ExactDuplicateLink dedup;
        const(QualityDecision)* qualityPointer;
        const(ExactDuplicateLink)* dedupPointer;
        if (overlays[0].present) {
            enforce(overlays[0].fields.length == 1 &&
                overlays[0].fields[0].key == decisionFieldKey,
                "mix overlay: malformed quality fields");
            quality = decodeDecisionValue(overlays[0].fields[0].value,
                source, qualityPolicy);
            qualityPointer = &quality;
        }
        if (overlays[1].present) {
            dedup = decodeCanonicalDedupLink(overlays[1].fields, source);
            dedupPointer = &dedup;
        }
        auto decision = decideMix(MixInput(source.id, qualityPointer,
            dedupPointer), mixPolicy);
        enforce(report.total < ulong.max &&
            report.counts[cast(size_t)decision.reason] < ulong.max,
            "mix overlay: count overflow");
        ++report.total;
        ++report.counts[cast(size_t)decision.reason];
        visit(source, decision);
    });
    return report;
}
