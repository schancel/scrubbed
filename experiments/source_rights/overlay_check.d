module experiments.source_rights.overlay_check;

import domain.document : Document, DocumentId, OutputName, SourceLocator;
import domain.shard_format : AnnotationField, AnnotationRecord, ShardDocument;
import domain.source_rights;
import effects.document_shards : DocumentShardWriter, OverlayWriter, joinShards;
import effects.exact_dedup_overlay : dedupAnalyzerKey;
import effects.quality_overlay : decisionAnalyzerKey, featureAnalyzerKey;
import effects.source_rights_overlay : annotationArtifact, documentArtifact,
    joinCorpusForRights, unacceptedOverlayAnalyzerKeyMessage;
import std.algorithm.sorting : sort;
import std.array : replicate;
import std.conv : to;
import std.exception : enforce;
import std.file : mkdir, rmdirRecurse, tempDir;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : indexOf;
import std.uuid : randomUUID;

// This slice's join does not discover real parent/child structure from shard
// bytes; the shard path given to joinCorpusForRights is scoped, by this
// checker, to exactly the family whose closure is being decided (see
// docs/source-rights.md). The sibling document below is therefore built as
// its own, separate, real on-disk shard: genuinely present on disk, but
// absent from the family shard's corpus.

private size_t checks;
private string diagnostics;

private void need(bool condition, string message) {
    enforce(condition, "source-rights overlay check failed: " ~ message);
    ++checks;
}

private RightsDecision rejects(RightsDecision delegate() operation, string message) {
    try {
        auto decision = operation();
        need(!decision.closureComplete, message ~ " (closure unexpectedly complete)");
        return decision;
    } catch (Exception error) {
        diagnostics ~= error.msg ~ "\n";
        need(false, message ~ " (threw instead of returning a failed decision)");
        assert(0);
    }
}

private void rejectsWithMessage(void delegate() operation, string expectedMessage,
        string label) {
    bool rejected;
    try {
        operation();
    } catch (Exception error) {
        diagnostics ~= error.msg ~ "\n";
        need(error.msg == expectedMessage, label ~ " reports the fixed diagnostic");
        rejected = true;
    }
    need(rejected, label ~ " fails closed");
}

private string hex64(char digit) { return digit.to!string.replicate(64); }
private EvidenceId evidenceId(char digit) {
    return EvidenceId.fromCanonicalText("evidence:v1:" ~ hex64(digit));
}
private ProvenanceId provenanceId(char digit) {
    return ProvenanceId.fromCanonicalText("provenance:v1:" ~ hex64(digit));
}

private RightsArtifactId[] sortedIds(RightsArtifactId[] ids) {
    auto copy = ids.dup;
    copy.sort!((a, b) => a.text < b.text);
    return copy;
}

private void sourceFile(string path, ShardDocument[] documents) {
    documents.sort!((a, b) => a.id.text < b.id.text);
    auto writer = new DocumentShardWriter(path);
    foreach (record; documents) writer.append(record);
    writer.publish();
}

void main() {
    enum canary = "CANARY-b7f0c1a2-do-not-leak-9d4e";

    auto root_ = tempDir();
    auto root = buildPath(root_, "source-rights-overlay-check-" ~ randomUUID.toString);
    mkdir(root);
    scope(exit) rmdirRecurse(root);

    // --- Root and a real shard-resident child via Document.derivedChild ---
    auto rootLocator = SourceLocator("rights-overlay-check",
        "root-source-" ~ canary, "record-1");
    auto rootDomain = Document(rootLocator, OutputName("root"));
    auto rootShardDoc = ShardDocument(rootLocator, OutputName("root"),
        cast(ubyte[]) ("root content " ~ canary));
    auto rootId = rootShardDoc.id;
    need(rootId == rootDomain.id, "root ShardDocument identity matches domain document identity");

    // Document.derivedChild computes the genuine "child:v1:" domain identity
    // from the real, unmodified domain.document API. A C01 ShardDocument's
    // own `.id()` always hashes its SourceLocator (never a child ID), so this
    // checker embeds the real derived child identity into a fresh, distinct,
    // valid on-disk locator for the shard-resident record.
    auto childDomain = Document.derivedChild(rootDomain, "rights-check-stage", 0,
        OutputName("child"));
    need(childDomain.id.text[0 .. "child:v1:".length] == "child:v1:",
        "child identity uses the real domain child-ID namespace");
    auto childLocator = SourceLocator("rights-overlay-check",
        "root-source-" ~ canary, "derived-child:" ~ childDomain.id.text);
    auto childShardDoc = ShardDocument(childLocator,
        OutputName("child-" ~ canary), cast(ubyte[]) ("child content " ~ canary));
    auto childId = childShardDoc.id;
    need(childId.text != rootId.text, "shard-resident child has a distinct on-disk ID");

    auto familyShard = buildPath(root, "family.shard");
    sourceFile(familyShard, [rootShardDoc, childShardDoc]);

    // A sibling document, real and on-disk, but in its own shard: absent
    // from the family corpus that joinCorpusForRights is given below.
    auto siblingLocator = SourceLocator("rights-overlay-check",
        "sibling-source-" ~ canary, "record-9");
    auto siblingShardDoc = ShardDocument(siblingLocator,
        OutputName("sibling"), cast(ubyte[]) ("sibling content " ~ canary));
    auto siblingId = siblingShardDoc.id;
    auto siblingShard = buildPath(root, "sibling.shard");
    sourceFile(siblingShard, [siblingShardDoc]);

    // --- Accepted overlays: quality.decisions on both, exact-dedup only on the child ---
    auto decisionsOverlay = buildPath(root, "decisions.overlay");
    {
        auto writer = new OverlayWriter(decisionsOverlay, familyShard,
            decisionAnalyzerKey, "rights-check:v1");
        AnnotationRecord[] records = [
            AnnotationRecord(rootId.text, rootShardDoc.contentDigest,
                [AnnotationField("value", cast(ubyte[]) ("root decision " ~ canary))]),
            AnnotationRecord(childId.text, childShardDoc.contentDigest,
                [AnnotationField("value", cast(ubyte[]) ("child decision " ~ canary))]),
        ];
        records.sort!((a, b) => a.documentId < b.documentId);
        foreach (record; records) writer.append(record);
        writer.publish();
    }
    auto dedupOverlay = buildPath(root, "dedup.overlay");
    {
        auto writer = new OverlayWriter(dedupOverlay, familyShard,
            dedupAnalyzerKey, "rights-check:v1");
        writer.append(AnnotationRecord(childId.text, childShardDoc.contentDigest,
            [AnnotationField("value", cast(ubyte[]) ("child dedup " ~ canary))]));
        writer.publish();
    }
    // A real, but unaccepted, overlay analyzer key on the same family shard.
    auto unacceptedOverlay = buildPath(root, "features.overlay");
    {
        auto writer = new OverlayWriter(unacceptedOverlay, familyShard,
            featureAnalyzerKey, "features:v1:schema=1");
        writer.append(AnnotationRecord(rootId.text, rootShardDoc.contentDigest,
            [AnnotationField("value", cast(ubyte[]) ("root feature " ~ canary))]));
        writer.publish();
    }

    RightsArtifactId[] expectedAffected = sortedIds([
        documentArtifact(rootId),
        documentArtifact(childId),
        annotationArtifact(decisionAnalyzerKey, rootId),
        annotationArtifact(decisionAnalyzerKey, childId),
        annotationArtifact(dedupAnalyzerKey, childId),
    ]);
    need(expectedAffected.length == 5, "expected affected set has five distinct artifacts");

    void checkClosure(RightsDecision decision, string label) {
        need(decision.closureComplete, label ~ " closure is complete");
        need(sortedIds(decision.affectedIds()) == expectedAffected,
            label ~ " affected IDs are exactly root, child, and present annotations");
        diagnostics ~= cast(string) decision.canonicalBytes;
        diagnostics ~= decision.auditId.text;
        foreach (id; decision.affectedIds()) diagnostics ~= id.text;
    }

    // --- unknown ---
    auto unknown = joinCorpusForRights(rootId, familyShard,
        [decisionsOverlay, dedupOverlay], []);
    need(unknown.state == RightsState.unknown &&
        unknown.action == RightsAction.denyUse &&
        unknown.reason == RightsReason.unknownEvidence,
        "no evidence over a real join remains explicitly unknown");
    checkClosure(unknown, "unknown");

    // --- documentedPermission ---
    auto permission = RightsEvidence.v1(rootId, RightsState.documentedPermission,
        evidenceId('1'), provenanceId('1'));
    auto allowed = joinCorpusForRights(rootId, familyShard,
        [decisionsOverlay, dedupOverlay], [permission]);
    need(allowed.action == RightsAction.allowUse &&
        allowed.reason == RightsReason.permissionDocumented,
        "documented permission over a real join allows use");
    checkClosure(allowed, "documentedPermission");

    // --- optOut ---
    auto optOut = RightsEvidence.v1(rootId, RightsState.optOut,
        evidenceId('2'), provenanceId('2'));
    auto optedOut = joinCorpusForRights(rootId, familyShard,
        [decisionsOverlay, dedupOverlay], [optOut]);
    need(optedOut.action == RightsAction.quarantineRequired &&
        optedOut.reason == RightsReason.sourceOptedOut,
        "opt-out over a real join requires declarative quarantine");
    checkClosure(optedOut, "optOut");

    // Determinism: overlay-path argument order must not change canonical bytes.
    auto optedOutReordered = joinCorpusForRights(rootId, familyShard,
        [dedupOverlay, decisionsOverlay], [optOut]);
    need(cast(ubyte[]) optedOutReordered.canonicalBytes ==
        cast(ubyte[]) optedOut.canonicalBytes,
        "overlay-path argument order does not change canonical decision bytes");
    need(optedOutReordered.auditId.text == optedOut.auditId.text,
        "overlay-path argument order does not change the audit identifier");

    // --- takedown ---
    auto takedown = RightsEvidence.v1(rootId, RightsState.takedown,
        evidenceId('3'), provenanceId('3'));
    auto takenDown = joinCorpusForRights(rootId, familyShard,
        [decisionsOverlay, dedupOverlay], [takedown]);
    need(takenDown.action == RightsAction.removalRequired &&
        takenDown.reason == RightsReason.sourceTakenDown,
        "takedown over a real join requires declarative removal");
    checkClosure(takenDown, "takedown");

    // --- negative evidence: a document absent from the family corpus ---
    auto siblingEvidence = RightsEvidence.v1(siblingId,
        RightsState.documentedPermission, evidenceId('4'), provenanceId('4'));
    auto mismatched = rejects({
        return joinCorpusForRights(rootId, familyShard,
            [decisionsOverlay, dedupOverlay], [siblingEvidence]);
    }, "evidence for a document absent from the family corpus");
    need(mismatched.reason == RightsReason.evidenceSubjectMismatch,
        "negative evidence is rejected via the existing subject-mismatch reason code");
    diagnostics ~= cast(string) mismatched.canonicalBytes;
    foreach (id; mismatched.affectedIds()) diagnostics ~= id.text;

    // --- an unaccepted overlay-analyzer key fails closed, not silently ---
    rejectsWithMessage({
        joinCorpusForRights(rootId, familyShard,
            [decisionsOverlay, dedupOverlay, unacceptedOverlay], []);
    }, unacceptedOverlayAnalyzerKeyMessage, "unaccepted overlay analyzer key");

    // --- canary-byte test: no raw content/locator/annotation value leaks ---
    need(diagnostics.indexOf(canary) < 0,
        "no canary content, locator, or annotation byte leaks into any " ~
        "artifact ID, decision, or diagnostic string this module produces");

    writeln("source-rights overlay checks passed: ", checks);
}
