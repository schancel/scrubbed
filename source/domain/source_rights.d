/// Pure source-rights policy and derived-artifact reachability.
module domain.source_rights;

import domain.document : DocumentId;
import std.algorithm.sorting : sort;
import std.array : Appender, appender;
import std.conv : to;
import std.digest : LetterCase, toHexString;
import crypto.sha256 : sha256Of;
import std.exception : enforce;
import std.string : representation;

enum sourceRightsSchemaVersion = "source-rights:v1";

enum RightsState : ubyte {
    unknown,
    documentedPermission,
    restriction,
    optOut,
    takedown,
}

enum RightsAction : ubyte {
    denyUse,
    allowUse,
    restrictUse,
    quarantineRequired,
    removalRequired,
}

enum RightsReason : ubyte {
    unknownEvidence,
    permissionDocumented,
    sourceRestricted,
    sourceOptedOut,
    sourceTakenDown,
    invalidRoot,
    duplicateEvidence,
    evidenceSubjectMismatch,
    duplicateRelation,
    inconsistentProvenance,
    relationCycle,
    orphanRelation,
}

enum ArtifactKind : ubyte {
    document,
    annotation,
    exportReference,
}

/// Opaque, content-free identifier for an evidence record.
struct EvidenceId {
    private string value;

    static EvidenceId fromCanonicalText(string text) {
        enforceCanonicalId(text, "evidence:v1:", "evidence ID");
        return EvidenceId(text.idup);
    }

    string text() const { return value; }
}

/// Opaque, content-free identifier for a provenance assertion.
struct ProvenanceId {
    private string value;

    static ProvenanceId fromCanonicalText(string text) {
        enforceCanonicalId(text, "provenance:v1:", "provenance ID");
        return ProvenanceId(text.idup);
    }

    string text() const { return value; }
}

/// Content-free digest of the complete canonical decision.
struct RightsAuditId {
    private string value;

    private static RightsAuditId fromDecisionBytes(const(ubyte)[] bytes) {
        return RightsAuditId("rights-audit:v1:" ~
            toHexString!(LetterCase.lower)(sha256Of(bytes)).idup);
    }

    string text() const { return value; }
}

/// Stable identifier for a source/child document, annotation, or export link.
struct RightsArtifactId {
    private ArtifactKind kindValue;
    private string value;

    static RightsArtifactId document(DocumentId id) {
        enforce(id.text.length != 0, "rights artifact: document ID is not initialized");
        return RightsArtifactId(ArtifactKind.document, id.text.idup);
    }

    static RightsArtifactId annotation(string text) {
        enforceCanonicalId(text, "annotation:v1:", "annotation ID");
        return RightsArtifactId(ArtifactKind.annotation, text.idup);
    }

    static RightsArtifactId exportReference(string text) {
        enforceCanonicalId(text, "export:v1:", "export reference ID");
        return RightsArtifactId(ArtifactKind.exportReference, text.idup);
    }

    ArtifactKind kind() const { return kindValue; }
    string text() const { return value; }
}

/// Version-1 evidence about one stable source document.
struct RightsEvidence {
    private string schemaValue;
    private DocumentId subjectValue;
    private RightsState stateValue;
    private EvidenceId evidenceValue;
    private ProvenanceId provenanceValue;

    static RightsEvidence v1(DocumentId subject, RightsState state,
        EvidenceId evidence, ProvenanceId provenance) {
        enforce(subject.text.length != 0, "rights evidence: subject is not initialized");
        enforce(state >= RightsState.unknown && state <= RightsState.takedown,
            "rights evidence: invalid state");
        enforce(evidence.text.length != 0 && provenance.text.length != 0,
            "rights evidence: audit IDs are not initialized");
        return RightsEvidence(sourceRightsSchemaVersion, subject, state,
            evidence, provenance);
    }

    string schemaVersion() const { return schemaValue; }
    DocumentId subject() const { return subjectValue; }
    RightsState state() const { return stateValue; }
    EvidenceId evidenceId() const { return evidenceValue; }
    ProvenanceId provenanceId() const { return provenanceValue; }
}

/// Caller-supplied statement that one stable artifact was derived from another.
struct DerivedArtifactRelation {
    private RightsArtifactId parentValue;
    private RightsArtifactId childValue;
    private ProvenanceId provenanceValue;

    this(RightsArtifactId parent, RightsArtifactId child,
        ProvenanceId provenance) {
        enforce(parent.text.length != 0 && child.text.length != 0 &&
            provenance.text.length != 0,
            "rights relation: IDs are not initialized");
        parentValue = parent;
        childValue = child;
        provenanceValue = provenance;
    }

    RightsArtifactId parent() const { return parentValue; }
    RightsArtifactId child() const { return childValue; }
    ProvenanceId provenanceId() const { return provenanceValue; }
}

/// Immutable value result. It describes required policy; it performs no effect.
struct RightsDecision {
    private string schemaValue;
    private RightsState stateValue;
    private RightsAction actionValue;
    private RightsReason reasonValue;
    private bool closureCompleteValue;
    private RightsArtifactId[] affectedValue;
    private EvidenceId[] evidenceValue;
    private ProvenanceId[] provenanceValue;

    string schemaVersion() const { return schemaValue; }
    RightsState state() const { return stateValue; }
    RightsAction action() const { return actionValue; }
    RightsReason reason() const { return reasonValue; }
    bool closureComplete() const { return closureCompleteValue; }
    RightsArtifactId[] affectedIds() const { return affectedValue.dup; }
    EvidenceId[] evidenceIds() const { return evidenceValue.dup; }
    ProvenanceId[] provenanceIds() const { return provenanceValue.dup; }

    ubyte[] canonicalBytes() const {
        enforce(schemaValue == sourceRightsSchemaVersion,
            "source rights decision: unsupported schema");
        auto bytes = appender!(ubyte[]);
        bytes.put(cast(const(ubyte)[]) "scrubbed:source-rights-decision:v1\0");
        bytes.put(cast(ubyte) stateValue);
        bytes.put(cast(ubyte) actionValue);
        bytes.put(cast(ubyte) reasonValue);
        bytes.put(cast(ubyte) (closureCompleteValue ? 1 : 0));
        appendIdentifiers(bytes, affectedValue);
        appendIdentifiers(bytes, evidenceValue);
        appendIdentifiers(bytes, provenanceValue);
        return bytes.data;
    }

    RightsAuditId auditId() const {
        auto bytes = canonicalBytes;
        return RightsAuditId.fromDecisionBytes(bytes);
    }
}

private struct GraphValidationWork {
    size_t relationInspections;
    size_t cycleNodeVisits;
    size_t cycleParentSteps;
    size_t reachabilityNodeVisits;
    size_t reachabilityEdgeSteps;
}

version (SourceRightsScaleCheck) {
    /// Deterministic graph-work evidence exposed only to the release checker.
    struct SourceRightsGraphWork {
        size_t relationInspections;
        size_t cycleNodeVisits;
        size_t cycleParentSteps;
        size_t reachabilityNodeVisits;
        size_t reachabilityEdgeSteps;
    }

    RightsDecision evaluateSourceRightsWithGraphWork(DocumentId root,
            const(RightsEvidence)[] evidence,
            const(DerivedArtifactRelation)[] relations,
            out SourceRightsGraphWork work) {
        GraphValidationWork measured;
        auto decision = evaluateSourceRightsImpl(root, evidence, relations,
            &measured);
        work = SourceRightsGraphWork(measured.relationInspections,
            measured.cycleNodeVisits, measured.cycleParentSteps,
            measured.reachabilityNodeVisits,
            measured.reachabilityEdgeSteps);
        return decision;
    }
}

/// Resolve policy and graph closure without reading content or performing I/O.
RightsDecision evaluateSourceRights(DocumentId root,
        const(RightsEvidence)[] evidence,
        const(DerivedArtifactRelation)[] relations) {
    return evaluateSourceRightsImpl(root, evidence, relations, null);
}

private RightsDecision evaluateSourceRightsImpl(DocumentId root,
    const(RightsEvidence)[] evidence,
    const(DerivedArtifactRelation)[] relations,
    GraphValidationWork* work) {
    RightsArtifactId[] known;
    if (root.text.length != 0)
        known ~= RightsArtifactId.document(root);
    foreach (relation; relations) {
        known ~= relation.parent;
        known ~= relation.child;
    }
    known = sortedUniqueArtifacts(known);

    EvidenceId[] evidenceIds;
    ProvenanceId[] evidenceProvenance;
    foreach (record; evidence) {
        if (record.evidenceId.text.length != 0)
            evidenceIds ~= record.evidenceId;
        if (record.provenanceId.text.length != 0)
            evidenceProvenance ~= record.provenanceId;
    }
    evidenceIds.sort!((left, right) => left.text < right.text);
    evidenceProvenance.sort!((left, right) => left.text < right.text);

    ProvenanceId[] allProvenance = evidenceProvenance.dup;
    foreach (relation; relations)
        if (relation.provenanceId.text.length != 0)
            allProvenance ~= relation.provenanceId;
    allProvenance.sort!((left, right) => left.text < right.text);

    if (root.text.length == 0)
        return failedDecision(RightsReason.invalidRoot, known, evidenceIds,
            allProvenance);

    foreach (index; 1 .. evidenceIds.length)
        if (evidenceIds[index - 1].text == evidenceIds[index].text)
            return failedDecision(RightsReason.duplicateEvidence, known,
                evidenceIds, allProvenance);
    foreach (index; 1 .. evidenceProvenance.length)
        if (evidenceProvenance[index - 1].text == evidenceProvenance[index].text)
            return failedDecision(RightsReason.inconsistentProvenance, known,
                evidenceIds, allProvenance);
    foreach (record; evidence)
        if (record.schemaVersion != sourceRightsSchemaVersion ||
            record.subject.text != root.text)
            return failedDecision(RightsReason.evidenceSubjectMismatch, known,
                evidenceIds, allProvenance);

    auto graph = validateGraph(root, relations, known, evidenceIds,
        evidenceProvenance, allProvenance, work);
    if (!graph.closureComplete)
        return graph;

    RightsState state = RightsState.unknown;
    foreach (record; evidence)
        if (stateRank(record.state) > stateRank(state))
            state = record.state;

    final switch (state) {
        case RightsState.unknown:
            return makeDecision(state, RightsAction.denyUse,
                RightsReason.unknownEvidence, true, graph.affectedIds,
                evidenceIds, graph.provenanceIds);
        case RightsState.documentedPermission:
            return makeDecision(state, RightsAction.allowUse,
                RightsReason.permissionDocumented, true, graph.affectedIds,
                evidenceIds, graph.provenanceIds);
        case RightsState.restriction:
            return makeDecision(state, RightsAction.restrictUse,
                RightsReason.sourceRestricted, true, graph.affectedIds,
                evidenceIds, graph.provenanceIds);
        case RightsState.optOut:
            return makeDecision(state, RightsAction.quarantineRequired,
                RightsReason.sourceOptedOut, true, graph.affectedIds,
                evidenceIds, graph.provenanceIds);
        case RightsState.takedown:
            return makeDecision(state, RightsAction.removalRequired,
                RightsReason.sourceTakenDown, true, graph.affectedIds,
                evidenceIds, graph.provenanceIds);
    }
}

private RightsDecision validateGraph(DocumentId root,
    const(DerivedArtifactRelation)[] relations, RightsArtifactId[] known,
    EvidenceId[] evidenceIds, ProvenanceId[] evidenceProvenance,
    ProvenanceId[] allProvenance, GraphValidationWork* work) {
    auto rootId = RightsArtifactId.document(root);
    bool[string] evidenceProvenanceIds;
    foreach (provenance; evidenceProvenance)
        evidenceProvenanceIds[provenance.text] = true;

    bool[string] edges;
    bool duplicateRelation;
    foreach (relation; relations) {
        if (work !is null)
            ++work.relationInspections;
        const edge = relation.parent.text ~ "\0" ~ relation.child.text;
        if (edge in edges)
            duplicateRelation = true;
        else
            edges[edge] = true;
    }
    if (duplicateRelation)
        return failedDecision(RightsReason.duplicateRelation, known,
            evidenceIds, allProvenance);

    string[string] parentByChild;
    string[string] relationByProvenance;
    string[][string] children;

    foreach (relation; relations) {
        if (work !is null)
            ++work.relationInspections;
        const edge = relation.parent.text ~ "\0" ~ relation.child.text;
        if (relation.provenanceId.text in evidenceProvenanceIds)
            return failedDecision(RightsReason.inconsistentProvenance,
                known, evidenceIds, allProvenance);
        if (auto priorParent = relation.child.text in parentByChild) {
            if (*priorParent != relation.parent.text)
                return failedDecision(RightsReason.inconsistentProvenance,
                    known, evidenceIds, allProvenance);
            return failedDecision(RightsReason.duplicateRelation, known,
                evidenceIds, allProvenance);
        }
        if (auto priorEdge = relation.provenanceId.text in relationByProvenance)
            if (*priorEdge != edge)
                return failedDecision(RightsReason.inconsistentProvenance,
                    known, evidenceIds, allProvenance);
        parentByChild[relation.child.text] = relation.parent.text;
        relationByProvenance[relation.provenanceId.text] = edge;
        children[relation.parent.text] ~= relation.child.text;
    }

    if (rootId.text in parentByChild)
        return failedDecision(RightsReason.inconsistentProvenance, known,
            evidenceIds, allProvenance);

    // A single-parent graph is a set of parent chains. Global three-state
    // visitation finishes each node once, including disconnected components,
    // so cycles are diagnosed before the separate orphan check.
    ubyte[string] visitState;
    foreach (artifact; known) {
        ubyte state;
        if (auto recorded = artifact.text in visitState)
            state = *recorded;
        if (state == 2)
            continue;

        string[] path;
        auto cursor = artifact.text;
        while (true) {
            state = 0;
            if (auto recorded = cursor in visitState)
                state = *recorded;
            if (state == 2)
                break;
            if (state == 1)
                return failedDecision(RightsReason.relationCycle, known,
                    evidenceIds, allProvenance);
            visitState[cursor] = 1;
            path ~= cursor;
            if (work !is null)
                ++work.cycleNodeVisits;
            if (auto parent = cursor in parentByChild) {
                if (work !is null)
                    ++work.cycleParentSteps;
                cursor = *parent;
            }
            else
                break;
        }
        foreach (node; path)
            visitState[node] = 2;
    }

    bool[string] reached;
    string[] pending = [rootId.text];
    while (pending.length) {
        auto current = pending[$ - 1];
        pending.length--;
        if (current in reached)
            continue;
        reached[current] = true;
        if (work !is null)
            ++work.reachabilityNodeVisits;
        if (auto next = current in children) {
            if (work !is null)
                work.reachabilityEdgeSteps += next.length;
            pending ~= *next;
        }
    }
    foreach (artifact; known)
        if (!(artifact.text in reached))
            return failedDecision(RightsReason.orphanRelation, known,
                evidenceIds, allProvenance);

    return makeDecision(RightsState.unknown, RightsAction.denyUse,
        RightsReason.unknownEvidence, true, known, evidenceIds,
        allProvenance);
}

private RightsDecision failedDecision(RightsReason reason,
    RightsArtifactId[] known, EvidenceId[] evidenceIds,
    ProvenanceId[] provenanceIds) {
    provenanceIds.sort!((left, right) => left.text < right.text);
    return makeDecision(RightsState.unknown, RightsAction.denyUse, reason,
        false, sortedUniqueArtifacts(known), evidenceIds, provenanceIds);
}

private RightsDecision makeDecision(RightsState state, RightsAction action,
    RightsReason reason, bool closureComplete, RightsArtifactId[] affected,
    EvidenceId[] evidenceIds, ProvenanceId[] provenanceIds) {
    return RightsDecision(sourceRightsSchemaVersion, state, action, reason,
        closureComplete, affected.dup, evidenceIds.dup, provenanceIds.dup);
}

private RightsArtifactId[] sortedUniqueArtifacts(RightsArtifactId[] values) {
    values.sort!((left, right) => left.text < right.text);
    RightsArtifactId[] unique;
    foreach (value; values)
        if (!unique.length || unique[$ - 1].text != value.text)
            unique ~= value;
    return unique;
}

private int stateRank(RightsState state) {
    return cast(int) state;
}

private void enforceCanonicalId(string text, string prefix, string label) {
    bool canonical = text.length == prefix.length + 64 &&
        text[0 .. prefix.length] == prefix;
    if (canonical)
        foreach (character; text[prefix.length .. $])
            if (!((character >= '0' && character <= '9') ||
                (character >= 'a' && character <= 'f'))) {
                canonical = false;
                break;
            }
    enforce(canonical, label ~ ": invalid canonical text");
}

private void appendField(ref Appender!(ubyte[]) bytes, string value) {
    enforce(value.length <= uint.max, "source rights field is too long");
    auto length = cast(uint) value.length;
    foreach_reverse (shift; [0, 8, 16, 24])
        bytes.put(cast(ubyte) (length >> shift));
    bytes.put(value.representation);
}

private void appendIdentifiers(T)(ref Appender!(ubyte[]) bytes,
    const(T)[] values) {
    appendField(bytes, values.length.to!string);
    foreach (value; values)
        appendField(bytes, value.text);
}

unittest {
    import domain.document : SourceLocator;
    import std.array : replicate;
    import std.exception : assertThrown;

    auto root = DocumentId.from(SourceLocator("rights-test", "source", "1"));
    auto child = RightsArtifactId.document(DocumentId.fromCanonicalText(
        "child:v1:" ~ "1".replicate(64)));
    auto annotation = RightsArtifactId.annotation("annotation:v1:" ~ "2".replicate(64));
    auto exportId = RightsArtifactId.exportReference("export:v1:" ~ "3".replicate(64));
    auto evidenceId = EvidenceId.fromCanonicalText("evidence:v1:" ~ "4".replicate(64));
    auto evidenceProvenance = ProvenanceId.fromCanonicalText(
        "provenance:v1:" ~ "5".replicate(64));
    auto relations = [
        DerivedArtifactRelation(RightsArtifactId.document(root), child,
            ProvenanceId.fromCanonicalText("provenance:v1:" ~ "6".replicate(64))),
        DerivedArtifactRelation(child, annotation,
            ProvenanceId.fromCanonicalText("provenance:v1:" ~ "7".replicate(64))),
        DerivedArtifactRelation(annotation, exportId,
            ProvenanceId.fromCanonicalText("provenance:v1:" ~ "8".replicate(64))),
    ];

    auto unknown = evaluateSourceRights(root, [], relations);
    assert(unknown.action == RightsAction.denyUse &&
        unknown.reason == RightsReason.unknownEvidence &&
        unknown.closureComplete && unknown.affectedIds.length == 4);

    auto permission = evaluateSourceRights(root, [RightsEvidence.v1(root,
        RightsState.documentedPermission, evidenceId, evidenceProvenance)],
        relations);
    assert(permission.action == RightsAction.allowUse &&
        permission.reason == RightsReason.permissionDocumented);

    auto duplicate = evaluateSourceRights(root, [], [relations[0], relations[0]]);
    assert(duplicate.action == RightsAction.denyUse &&
        !duplicate.closureComplete &&
        duplicate.reason == RightsReason.duplicateRelation);

    assertThrown!Exception(EvidenceId.fromCanonicalText("raw locator"));
    assert(permission.auditId.text.length == "rights-audit:v1:".length + 64);
}
