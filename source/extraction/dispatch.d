/// Exactly-one finite route or policy selection for normalized detection.
module extraction.dispatch;

import extraction.contracts : DetectionOutcomeV1, DetectionResultV1,
    RouteActionV1, RouteDeclarationV1;

/// The sole action selected for one normalized detector result.
struct DispatchSelectionV1 {
    DetectionOutcomeV1 outcome;
    RouteActionV1 action;
    string detectorVersion;
}

DispatchSelectionV1 selectDispatchV1(DetectionResultV1 detection,
        const RouteDeclarationV1 declaration) {
    detection.validateResult;
    return DispatchSelectionV1(detection.outcome,
        declaration.actionFor(detection.outcome), detection.detectorVersion);
}

unittest {
    import extraction.contracts : EvidenceKindV1, MediaEvidenceV1,
        RouteActionKindV1, RouteRuleV1, TextContentV1, isConcreteMediaV1;
    import std.algorithm.mutation : reverse;

    static assert(!__traits(compiles, {
        auto invalid = DetectionResultV1(DetectionOutcomeV1.unknown, null,
            "raw:v1", null, 0, 1, 0);
    }));
    static assert(!__traits(compiles, {
        TextContentV1 text;
        text.replace(0, 0);
    }));
    static assert(!__traits(compiles, {
        TextContentV1 text;
        auto mutableAlias = text.snapshot;
    }));

    RouteRuleV1[] rules;
    foreach (index; 0 .. cast(size_t) DetectionOutcomeV1.max + 1) {
        auto outcome = cast(DetectionOutcomeV1) index;
        RouteActionV1 action;
        if (isConcreteMediaV1(outcome)) action = RouteActionV1.route("extract");
        else if (outcome == DetectionOutcomeV1.unknown)
            action = RouteActionV1.reject("unknown media");
        else action = RouteActionV1.quarantine("unsafe media");
        rules ~= RouteRuleV1(outcome, action);
    }
    auto first = RouteDeclarationV1(rules);
    rules.reverse;
    auto second = RouteDeclarationV1(rules);

    DetectionResultV1 resultFor(DetectionOutcomeV1 outcome) {
        if (isConcreteMediaV1(outcome))
            return DetectionResultV1.detected(outcome,
                [MediaEvidenceV1(EvidenceKindV1.signature, outcome, "test")],
                "test:v1", null, 1, 1, 1);
        if (outcome == DetectionOutcomeV1.unknown)
            return DetectionResultV1.detected(outcome, null,
                "test:v1", null, 0, 1, 0);
        if (outcome == DetectionOutcomeV1.ambiguous)
            return DetectionResultV1.detected(outcome, [
                MediaEvidenceV1(EvidenceKindV1.signature,
                    DetectionOutcomeV1.pdf, "pdf"),
                MediaEvidenceV1(EvidenceKindV1.textualContent,
                    DetectionOutcomeV1.html, "html")],
                "test:v1", null, 1, 1, 1);
        if (outcome == DetectionOutcomeV1.malformed)
            return DetectionResultV1.malformed(null, "test:v1", null, 1, 1, 1);
        if (outcome == DetectionOutcomeV1.encrypted)
            return DetectionResultV1.encrypted(null, "test:v1", null, 1, 1, 1);
        return DetectionResultV1.unsupported(null, "test:v1", null, 1, 1, 1);
    }

    foreach (index; 0 .. cast(size_t) DetectionOutcomeV1.max + 1) {
        auto outcome = cast(DetectionOutcomeV1) index;
        auto each = selectDispatchV1(resultFor(outcome), first);
        assert(each.outcome == outcome);
        if (isConcreteMediaV1(outcome))
            assert(each.action.kind == RouteActionKindV1.route);
        else if (outcome == DetectionOutcomeV1.unknown)
            assert(each.action.kind == RouteActionKindV1.reject);
        else
            assert(each.action.kind == RouteActionKindV1.quarantine);
    }

    auto detection = DetectionResultV1.detected(DetectionOutcomeV1.unknown,
        null, "test:v1", ["no evidence"], 4, 4, 4);
    auto selected = selectDispatchV1(detection, first);
    auto reordered = selectDispatchV1(detection, second);
    assert(selected.action.kind == RouteActionKindV1.reject);
    assert(selected.action.reason == "unknown media");
    assert(reordered.action.kind == selected.action.kind);
    assert(reordered.action.reason == selected.action.reason);
    assert(selected.detectorVersion == "test:v1");

    auto passRules = first.canonicalRules;
    passRules[cast(size_t) DetectionOutcomeV1.unknown] = RouteRuleV1(
        DetectionOutcomeV1.unknown, RouteActionV1.passThrough("retain original"));
    auto passed = selectDispatchV1(detection, RouteDeclarationV1(passRules));
    assert(passed.action.kind == RouteActionKindV1.passThrough);
    assert(passed.action.reason == "retain original");

    import std.exception : assertThrown;
    assertThrown(selectDispatchV1(DetectionResultV1.init, first));
}
