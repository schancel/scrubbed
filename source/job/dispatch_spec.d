/// Typed pure specification for the additive canonical v4 dispatch plan.
module job.dispatch_spec;

import job.spec : JobOptions, JobSpec, validateJobKey, validateJobSpec;
import std.exception : enforce;
import std.string : indexOf;
import std.utf : validate;

enum dispatchJobVersion = 4;
enum maxDispatchRoutesV1 = 256;

/// Byte-stable mirror of extraction.contracts.DetectionOutcomeV1 names.
enum DispatchOutcomeV1 : ubyte {
    unknown, plainText, html, pdf, png, jpeg, gif, ambiguous, malformed,
    encrypted, unsupported, genericZip, ooxmlWord
}

enum DispatchActionKindV1 : ubyte { route, reject, quarantine, passThrough }

struct DispatchActionSpecV1 {
    DispatchOutcomeV1 outcome;
    DispatchActionKindV1 kind;
    string target;

    static DispatchActionSpecV1 route(DispatchOutcomeV1 outcome, string routeName) {
        validateJobKey(routeName, "dispatch route action");
        return DispatchActionSpecV1(outcome, DispatchActionKindV1.route,
            routeName.idup);
    }
    static DispatchActionSpecV1 policy(DispatchOutcomeV1 outcome,
            DispatchActionKindV1 kind, string reason) {
        enforce(kind == DispatchActionKindV1.reject ||
            kind == DispatchActionKindV1.quarantine ||
            kind == DispatchActionKindV1.passThrough,
            "dispatch policy action is invalid");
        validateReason(reason);
        return DispatchActionSpecV1(outcome, kind, reason.idup);
    }
}

struct DispatchRouteSpecV1 {
    string name;
    string extractor;
    JobOptions options;
}

struct DispatchDetectorSpecV1 {
    size_t prefixBytes;
    size_t evidenceRecords;
    size_t warnings;
}

struct DispatchContainerSpecV1 {
    size_t maxPhysicalBytes;
    size_t maxExpandedBytes;
    size_t maxEntries;
    size_t maxDepth;
    ulong maxRatio;
}

struct DispatchSpecV1 {
    DispatchDetectorSpecV1 detector;
    DispatchContainerSpecV1 container;
    DispatchRouteSpecV1[] routes;
    DispatchActionSpecV1[] actions;
}

struct DispatchJobSpecV1 {
    DispatchSpecV1 dispatch;
    JobSpec common;
}

void validateDispatchJobSpecV1(const ref DispatchJobSpecV1 spec) {
    enforce(spec.dispatch.detector.prefixBytes > 0,
        "dispatch detector prefix-bytes must be positive");
    enforce(spec.dispatch.detector.evidenceRecords > 0,
        "dispatch detector evidence-records must be positive");
    enforce(spec.dispatch.detector.warnings > 0,
        "dispatch detector warnings must be positive");
    enforce(spec.dispatch.container.maxPhysicalBytes > 0 &&
        spec.dispatch.container.maxExpandedBytes > 0 &&
        spec.dispatch.container.maxEntries > 0 &&
        spec.dispatch.container.maxDepth > 0 &&
        spec.dispatch.container.maxRatio > 0,
        "dispatch container limits must be positive");
    enforce(spec.dispatch.routes.length <= maxDispatchRoutesV1,
        "too many dispatch routes");
    bool[string] routeNames;
    foreach (route; spec.dispatch.routes) {
        validateJobKey(route.name, "dispatch route name");
        validateJobKey(route.extractor, "dispatch extractor implementation");
        enforce((route.name in routeNames) is null,
            "duplicate dispatch route: " ~ route.name);
        routeNames[route.name] = true;
        enforce(route.options.length <= 1024, "too many dispatch route options");
        foreach (key, value; route.options) {
            validateJobKey(key, "dispatch route option");
            value.type;
        }
    }
    enum outcomeCount = cast(size_t) DispatchOutcomeV1.max + 1;
    enforce(spec.dispatch.actions.length == outcomeCount,
        "dispatch actions must cover every outcome exactly once");
    bool[outcomeCount] seen;
    bool[string] usedRoutes;
    foreach (action; spec.dispatch.actions) {
        auto index = cast(size_t) action.outcome;
        enforce(index < outcomeCount && !seen[index],
            "duplicate or invalid dispatch action outcome");
        seen[index] = true;
        enforce(action.kind >= DispatchActionKindV1.min &&
            action.kind <= DispatchActionKindV1.max, "invalid dispatch action");
        if (action.kind == DispatchActionKindV1.route) {
            validateJobKey(action.target, "dispatch action route");
            enforce((action.target in routeNames) !is null,
                "dispatch action names an unknown route: " ~ action.target);
            usedRoutes[action.target] = true;
        } else validateReason(action.target);
    }
    foreach (name; routeNames.byKey)
        enforce((name in usedRoutes) !is null,
            "unused dispatch route: " ~ name);
    validateJobSpec(spec.common);
}

private void validateReason(string reason) {
    enforce(reason.length > 0 && reason.length <= 256,
        "dispatch policy reason must be nonempty and bounded");
    validate(reason); enforce(reason.indexOf('\0') < 0,
        "dispatch policy reason contains NUL");
}

unittest {
    import job.spec : JobOption;
    import std.exception : assertThrown;
    DispatchActionSpecV1[] actions;
    foreach (i; 0 .. cast(size_t) DispatchOutcomeV1.max + 1) {
        auto outcome = cast(DispatchOutcomeV1) i;
        actions ~= outcome == DispatchOutcomeV1.plainText
            ? DispatchActionSpecV1.route(outcome, "text")
            : DispatchActionSpecV1.policy(outcome,
                DispatchActionKindV1.reject, "not selected");
    }
    auto spec = DispatchJobSpecV1(DispatchSpecV1(
        DispatchDetectorSpecV1(4096, 16, 8),
        DispatchContainerSpecV1(1024, 2048, 10, 2, 100),
        [DispatchRouteSpecV1("text", "identity",
            ["strict": JobOption.boolean(true)])], actions), JobSpec.init);
    validateDispatchJobSpecV1(spec);
    spec.dispatch.routes ~= spec.dispatch.routes[0];
    assertThrown(validateDispatchJobSpecV1(spec));
}
