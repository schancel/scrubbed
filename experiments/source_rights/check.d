module experiments.source_rights.check;

import domain.document : DocumentId, SourceLocator;
import domain.source_rights;
import std.algorithm.comparison : equal;
import std.array : replicate;
import std.conv : to;
import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;
import std.exception : enforce;
import std.stdio : writeln;
import std.string : indexOf;

private size_t checks;

private void need(bool condition, string message) {
    enforce(condition, "source-rights check failed: " ~ message);
    ++checks;
}

private void rejects(void delegate() operation, string message) {
    bool rejected;
    try {
        operation();
    } catch (Exception) {
        rejected = true;
    }
    need(rejected, message);
}

private string hex64(char digit) {
    return digit.to!string.replicate(64);
}

private EvidenceId evidenceId(char digit) {
    return EvidenceId.fromCanonicalText("evidence:v1:" ~ hex64(digit));
}

private ProvenanceId provenanceId(char digit) {
    return ProvenanceId.fromCanonicalText("provenance:v1:" ~ hex64(digit));
}

private string snapshot(const(RightsEvidence)[] evidence,
    const(DerivedArtifactRelation)[] relations) {
    string result;
    foreach (record; evidence)
        result ~= record.schemaVersion ~ "|" ~ record.subject.text ~ "|" ~
            record.state.to!string ~ "|" ~ record.evidenceId.text ~ "|" ~
            record.provenanceId.text ~ "\n";
    foreach (relation; relations)
        result ~= relation.parent.kind.to!string ~ "|" ~ relation.parent.text ~
            "|" ~ relation.child.kind.to!string ~ "|" ~ relation.child.text ~
            "|" ~ relation.provenanceId.text ~ "\n";
    return result;
}

private void needFailure(RightsDecision decision, RightsReason reason,
    string label) {
    need(decision.action == RightsAction.denyUse, label ~ " denies use");
    need(!decision.closureComplete, label ~ " marks closure incomplete");
    need(decision.reason == reason, label ~ " reports its fail-closed reason");
}

void main() {
    enum secretLocator =
        "s3://private-rights-bucket/customer@example.test/contracts/record-17";
    auto root = DocumentId.from(SourceLocator("rights-fixture", secretLocator,
        "private-record-key"));
    auto otherRoot = DocumentId.from(SourceLocator("rights-fixture",
        "different-source", "different-record"));
    auto rootArtifact = RightsArtifactId.document(root);
    auto child = RightsArtifactId.document(DocumentId.fromCanonicalText(
        "child:v1:" ~ hex64('1')));
    auto annotationA = RightsArtifactId.annotation(
        "annotation:v1:" ~ hex64('2'));
    auto annotationB = RightsArtifactId.annotation(
        "annotation:v1:" ~ hex64('3'));
    auto exportReference = RightsArtifactId.exportReference(
        "export:v1:" ~ hex64('4'));

    auto relations = [
        DerivedArtifactRelation(rootArtifact, child, provenanceId('a')),
        DerivedArtifactRelation(child, annotationA, provenanceId('b')),
        DerivedArtifactRelation(child, annotationB, provenanceId('c')),
        DerivedArtifactRelation(annotationA, exportReference, provenanceId('d')),
    ];
    auto permission = RightsEvidence.v1(root,
        RightsState.documentedPermission, evidenceId('5'), provenanceId('e'));
    auto restriction = RightsEvidence.v1(root, RightsState.restriction,
        evidenceId('6'), provenanceId('f'));
    auto optOut = RightsEvidence.v1(root, RightsState.optOut,
        evidenceId('7'), provenanceId('0'));
    auto takedown = RightsEvidence.v1(root, RightsState.takedown,
        evidenceId('8'), provenanceId('1'));

    const inputBefore = snapshot([permission, optOut], relations);
    ubyte[] upstreamBytes = [0x00, 0x45, 0xff, 0x10];
    const upstreamBefore = upstreamBytes.dup;

    auto unknown = evaluateSourceRights(root, [], relations);
    need(unknown.state == RightsState.unknown,
        "absence of evidence remains explicitly unknown");
    need(unknown.action == RightsAction.denyUse,
        "unknown rights never grant use");
    need(unknown.reason == RightsReason.unknownEvidence &&
        unknown.closureComplete, "valid unknown decision retains complete closure");
    need(unknown.affectedIds.length == 5,
        "closure covers source, child, annotations, and export reference");

    auto allowed = evaluateSourceRights(root, [permission], relations);
    need(allowed.action == RightsAction.allowUse &&
        allowed.reason == RightsReason.permissionDocumented,
        "only documented permission grants use");

    auto restricted = evaluateSourceRights(root, [permission, restriction],
        relations);
    need(restricted.action == RightsAction.restrictUse &&
        restricted.state == RightsState.restriction,
        "restriction overrides documented permission");

    auto optedOut = evaluateSourceRights(root, [permission, optOut], relations);
    need(optedOut.action == RightsAction.quarantineRequired &&
        optedOut.reason == RightsReason.sourceOptedOut,
        "opt-out returns declarative quarantine requirement");
    need(optedOut.affectedIds.length == 5,
        "opt-out reaches every supplied derived artifact");

    auto takenDown = evaluateSourceRights(root, [permission, optOut, takedown],
        relations);
    need(takenDown.action == RightsAction.removalRequired &&
        takenDown.reason == RightsReason.sourceTakenDown,
        "takedown returns declarative removal requirement");

    auto reversedRelations = [relations[3], relations[2], relations[1],
        relations[0]];
    auto reordered = evaluateSourceRights(root, [optOut, permission],
        reversedRelations);
    need(reordered.canonicalBytes.equal(optedOut.canonicalBytes),
        "caller ordering does not change canonical decision bytes");
    need(reordered.auditId.text == optedOut.auditId.text,
        "caller ordering does not change the audit identifier");

    auto canonical = optedOut.canonicalBytes;
    const canonicalHash = toHexString!(LetterCase.lower)(sha256Of(canonical));
    need(canonicalHash ==
        "045204abd8053ec076bdd07e4929220013084991c9c46bbe463446a5b559b9c5",
        "canonical decision bytes match the frozen version-1 vector");
    need((cast(string) canonical).indexOf(secretLocator) < 0,
        "canonical bytes do not reveal the raw source locator");
    need(optedOut.auditId.text.indexOf(secretLocator) < 0,
        "audit identifier does not reveal the raw source locator");
    need(snapshot([permission, optOut], relations) == inputBefore,
        "evaluation does not mutate caller evidence or relations");
    need(upstreamBytes.equal(upstreamBefore),
        "pure evaluation leaves unrelated upstream content bytes unchanged");

    needFailure(evaluateSourceRights(root, [], [relations[0], relations[0]]),
        RightsReason.duplicateRelation, "duplicate relation");
    needFailure(evaluateSourceRights(root, [permission, permission], relations),
        RightsReason.duplicateEvidence, "duplicate evidence");

    auto cycleA = RightsArtifactId.annotation("annotation:v1:" ~ hex64('9'));
    auto cycleB = RightsArtifactId.exportReference("export:v1:" ~ hex64('a'));
    auto cyclic = relations ~ [
        DerivedArtifactRelation(cycleA, cycleB, provenanceId('2')),
        DerivedArtifactRelation(cycleB, cycleA, provenanceId('3')),
    ];
    needFailure(evaluateSourceRights(root, [], cyclic),
        RightsReason.relationCycle, "cycle");

    auto orphan = relations ~ [DerivedArtifactRelation(cycleA, cycleB,
        provenanceId('2'))];
    needFailure(evaluateSourceRights(root, [], orphan),
        RightsReason.orphanRelation, "orphan relation");

    auto inconsistentParent = relations ~ [DerivedArtifactRelation(
        annotationB, exportReference, provenanceId('2'))];
    needFailure(evaluateSourceRights(root, [], inconsistentParent),
        RightsReason.inconsistentProvenance, "multiple parents");

    auto reusedEvidenceProvenance = [DerivedArtifactRelation(rootArtifact,
        child, permission.provenanceId)];
    needFailure(evaluateSourceRights(root, [permission],
        reusedEvidenceProvenance), RightsReason.inconsistentProvenance,
        "reused evidence provenance");

    auto wrongSubject = RightsEvidence.v1(otherRoot,
        RightsState.documentedPermission, evidenceId('9'), provenanceId('2'));
    needFailure(evaluateSourceRights(root, [wrongSubject], relations),
        RightsReason.evidenceSubjectMismatch, "wrong evidence subject");

    DocumentId invalidRoot;
    needFailure(evaluateSourceRights(invalidRoot, [], relations),
        RightsReason.invalidRoot, "uninitialized root");
    rejects({ EvidenceId.fromCanonicalText(secretLocator); },
        "raw locator cannot be used as an evidence identifier");
    rejects({ ProvenanceId.fromCanonicalText("provenance:v1:NOT-A-DIGEST"); },
        "malformed provenance identifier is rejected");
    rejects({ RightsArtifactId.annotation("annotation:v1:" ~ hex64('g')); },
        "non-hex artifact identifier is rejected");

    writeln("source-rights release checks passed: ", checks);
    writeln("frozen canonical SHA-256: ", canonicalHash);
}
