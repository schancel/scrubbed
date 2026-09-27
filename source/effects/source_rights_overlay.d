/// Opt-in, read-only C01 join facade proving Stage 1's frozen source-rights
/// graph/closure logic against real document-shard and overlay data.
module effects.source_rights_overlay;

import crypto.sha256 : sha256Of;
import domain.document : DocumentId;
import domain.shard_format : ShardDocument;
import domain.source_rights;
import effects.document_shards : JoinedOverlay, OverlayReader, joinShards;
import effects.exact_dedup_overlay : dedupAnalyzerKey;
import effects.quality_overlay : decisionAnalyzerKey;
import std.array : Appender, appender;
import std.digest : LetterCase, toHexString;
import std.exception : enforce;

/// Fixed, content-free diagnostic for any overlay analyzer key outside the
/// two accepted keys. It never includes the offending key, an overlay path,
/// or any annotation value.
enum unacceptedOverlayAnalyzerKeyMessage =
    "source rights overlay: unaccepted overlay analyzer key";

/// Trivial wrap: a shard/child DocumentId is already a stable rights artifact.
RightsArtifactId documentArtifact(DocumentId id) {
    return RightsArtifactId.document(id);
}

/// Deterministic, domain-separated canonical annotation-artifact ID for one
/// analyzer's annotation on one owning document. Mirrors the same idiom as
/// `DocumentId.childOf` and `RightsAuditId.fromDecisionBytes`: a fixed domain
/// tag, length-prefixed fields, SHA-256, and a versioned canonical prefix.
RightsArtifactId annotationArtifact(string analyzerKey, DocumentId owner) {
    enforce(analyzerKey.length != 0,
        "source rights overlay: analyzer key is not initialized");
    enforce(owner.text.length != 0,
        "source rights overlay: annotation owner is not initialized");
    auto bytes = appender!(ubyte[]);
    bytes.put(cast(const(ubyte)[]) "scrubbed:rights-annotation-artifact-id:v1\0");
    appendField(bytes, owner.text);
    appendField(bytes, analyzerKey);
    auto hex = toHexString!(LetterCase.lower)(sha256Of(bytes.data)).idup;
    return RightsArtifactId.annotation("annotation:v1:" ~ hex);
}

/// Join one real C01 shard and only its accepted overlay analyzers into the
/// artifact graph, then resolve Stage 1's unmodified pure policy over it.
///
/// Every document visited in `shardPath` other than `root` becomes a direct
/// derived child of `root`; every present overlay annotation on a visited
/// document becomes a derived child of that document. This slice's join does
/// not discover real parent/child structure from shard bytes -- a shard is
/// scoped by its caller to the family whose closure is being decided; see
/// docs/source-rights.md for the deferred production-discovery question.
///
/// Evidence stays entirely caller-supplied; this facade neither reads nor
/// writes an evidence store. No filesystem mutation, quarantine, or removal
/// occurs here.
RightsDecision joinCorpusForRights(DocumentId root, string shardPath,
        const(string)[] overlayPaths, const(RightsEvidence)[] evidence) {
    foreach (path; overlayPaths) {
        auto reader = new OverlayReader(path);
        scope(exit) reader.closeReader();
        enforce(reader.header.analyzerKey == decisionAnalyzerKey ||
            reader.header.analyzerKey == dedupAnalyzerKey,
            unacceptedOverlayAnalyzerKeyMessage);
    }

    DerivedArtifactRelation[] relations;
    joinShards(shardPath, overlayPaths, (ShardDocument document, JoinedOverlay[] overlays) {
        auto documentId = document.id;
        if (documentId.text != root.text)
            relations ~= DerivedArtifactRelation(documentArtifact(root),
                documentArtifact(documentId),
                documentRelationProvenance(root, documentId));
        foreach (overlay; overlays) {
            if (!overlay.present) continue;
            relations ~= DerivedArtifactRelation(documentArtifact(documentId),
                annotationArtifact(overlay.analyzerKey, documentId),
                annotationRelationProvenance(documentId, overlay.analyzerKey));
        }
    });

    return evaluateSourceRights(root, evidence, relations);
}

private ProvenanceId documentRelationProvenance(DocumentId parent, DocumentId child) {
    return derivedProvenance("scrubbed:rights-document-relation-provenance:v1\0",
        parent.text, child.text);
}

private ProvenanceId annotationRelationProvenance(DocumentId owner, string analyzerKey) {
    return derivedProvenance("scrubbed:rights-annotation-relation-provenance:v1\0",
        owner.text, analyzerKey);
}

private ProvenanceId derivedProvenance(string domainTag, string first, string second) {
    auto bytes = appender!(ubyte[]);
    bytes.put(cast(const(ubyte)[]) domainTag);
    appendField(bytes, first);
    appendField(bytes, second);
    auto hex = toHexString!(LetterCase.lower)(sha256Of(bytes.data)).idup;
    return ProvenanceId.fromCanonicalText("provenance:v1:" ~ hex);
}

private void appendField(ref Appender!(ubyte[]) bytes, string value) {
    enforce(value.length <= uint.max, "source rights overlay: field too long");
    auto length = cast(uint) value.length;
    foreach_reverse (shift; [0, 8, 16, 24])
        bytes.put(cast(ubyte) (length >> shift));
    bytes.put(cast(const(ubyte)[]) value);
}

unittest {
    import domain.document : OutputName, SourceLocator;
    import std.exception : assertThrown;

    auto root = DocumentId.from(SourceLocator("rights-overlay-unit", "source", "1"));
    auto other = DocumentId.from(SourceLocator("rights-overlay-unit", "source", "2"));
    assert(documentArtifact(root) == RightsArtifactId.document(root));

    auto annotationA = annotationArtifact("quality.decisions", root);
    auto annotationB = annotationArtifact("exact-dedup", root);
    auto annotationC = annotationArtifact("quality.decisions", other);
    assert(annotationA.kind == ArtifactKind.annotation);
    assert(annotationA.text != annotationB.text, "analyzer key participates in derivation");
    assert(annotationA.text != annotationC.text, "owner participates in derivation");
    assert(annotationA.text == annotationArtifact("quality.decisions", root).text,
        "annotation artifact derivation is deterministic");

    assertThrown!Exception(annotationArtifact("", root));
    assertThrown!Exception(annotationArtifact("quality.decisions", DocumentId.init));
}
