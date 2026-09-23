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
    import extraction.contracts : RouteActionKindV1, RouteRuleV1,
        isConcreteMediaV1;
    import std.algorithm.mutation : reverse;

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

    foreach (index; 0 .. cast(size_t) DetectionOutcomeV1.max + 1) {
        auto outcome = cast(DetectionOutcomeV1) index;
        auto each = selectDispatchV1(DetectionResultV1(outcome, null,
            "test:v1", null, 0), first);
        assert(each.outcome == outcome);
        if (isConcreteMediaV1(outcome))
            assert(each.action.kind == RouteActionKindV1.route);
        else if (outcome == DetectionOutcomeV1.unknown)
            assert(each.action.kind == RouteActionKindV1.reject);
        else
            assert(each.action.kind == RouteActionKindV1.quarantine);
    }

    auto detection = DetectionResultV1(DetectionOutcomeV1.unknown, null,
        "test:v1", ["no evidence"], 4);
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
