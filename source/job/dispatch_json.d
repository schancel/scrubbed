/// Strict parsing, canonical JSON and identity for v4 dispatch plans.
module job.dispatch_json;

import job.dispatch_spec : DispatchActionKindV1, DispatchActionSpecV1,
    DispatchContainerSpecV1, DispatchDetectorSpecV1, DispatchJobSpecV1,
    DispatchOutcomeV1, DispatchRouteSpecV1, DispatchSpecV1,
    dispatchJobVersion, validateDispatchJobSpecV1;
import job.json : canonicalJobJson, parseJobJson;
import job.spec : JobOption, JobOptions, JobOptionType, validateJobKey;
import std.algorithm.sorting : sort;
import std.array : Appender, appender;
import std.conv : to;
import std.digest : LetterCase, toHexString;
import crypto.sha256 : sha256Of;
import std.exception : enforce;
import std.json : JSONOptions, JSONType, JSONValue, parseJSON;
import std.string : indexOf;

enum maxDispatchJsonBytesV1 = 16 * 1024 * 1024;

DispatchJobSpecV1 parseDispatchJobJsonV1(string json) {
    enforce(json.length <= maxDispatchJsonBytesV1,
        "dispatch job JSON exceeds byte limit");
    auto root = parseJSON(json, 24,
        JSONOptions.strictParsing | JSONOptions.preserveObjectOrder);
    auto versionValue = exact(root, ["version", "dispatch", "common"], "version", "job");
    enforce(versionValue.type == JSONType.integer && versionValue.integer == dispatchJobVersion,
        "dispatch job version must be integer 4");
    auto dispatch = exact(root, ["version", "dispatch", "common"], "dispatch", "job");
    auto common = exact(root, ["version", "dispatch", "common"], "common", "job");
    auto detector = exact(dispatch, ["detector", "container", "routes", "actions"],
        "detector", "dispatch");
    auto container = exact(dispatch, ["detector", "container", "routes", "actions"],
        "container", "dispatch");
    auto routes = exact(dispatch, ["detector", "container", "routes", "actions"],
        "routes", "dispatch");
    auto actions = exact(dispatch, ["detector", "container", "routes", "actions"],
        "actions", "dispatch");

    DispatchJobSpecV1 result;
    result.dispatch.detector = DispatchDetectorSpecV1(
        positiveSize(exact(detector, ["prefix-bytes", "evidence-records", "warnings"],
            "prefix-bytes", "detector"), "detector prefix-bytes"),
        positiveSize(exact(detector, ["prefix-bytes", "evidence-records", "warnings"],
            "evidence-records", "detector"), "detector evidence-records"),
        positiveSize(exact(detector, ["prefix-bytes", "evidence-records", "warnings"],
            "warnings", "detector"), "detector warnings"));
    result.dispatch.container = DispatchContainerSpecV1(
        positiveSize(exact(container, ["max-physical-bytes", "max-expanded-bytes",
            "max-entries", "max-depth", "max-ratio"], "max-physical-bytes",
            "container"), "container max-physical-bytes"),
        positiveSize(exact(container, ["max-physical-bytes", "max-expanded-bytes",
            "max-entries", "max-depth", "max-ratio"], "max-expanded-bytes",
            "container"), "container max-expanded-bytes"),
        positiveSize(exact(container, ["max-physical-bytes", "max-expanded-bytes",
            "max-entries", "max-depth", "max-ratio"], "max-entries",
            "container"), "container max-entries"),
        positiveSize(exact(container, ["max-physical-bytes", "max-expanded-bytes",
            "max-entries", "max-depth", "max-ratio"], "max-depth",
            "container"), "container max-depth"),
        positiveUlong(exact(container, ["max-physical-bytes", "max-expanded-bytes",
            "max-entries", "max-depth", "max-ratio"], "max-ratio",
            "container"), "container max-ratio"));

    enforce(routes.type == JSONType.array, "dispatch routes must be an array");
    foreach (routeValue; routes.array) {
        auto name = exact(routeValue, ["name", "extractor", "options"],
            "name", "route");
        auto extractor = exact(routeValue, ["name", "extractor", "options"],
            "extractor", "route");
        auto options = exact(routeValue, ["name", "extractor", "options"],
            "options", "route");
        enforce(name.type == JSONType.string && extractor.type == JSONType.string,
            "route name and extractor must be text");
        result.dispatch.routes ~= DispatchRouteSpecV1(name.str.idup,
            extractor.str.idup, parseOptions(options, "route " ~ name.str));
    }
    enforce(actions.type == JSONType.array, "dispatch actions must be an array");
    foreach (actionValue; actions.array) {
        auto outcomeValue = exact(actionValue,
            ["outcome", "action", "route", "reason"], "outcome", "action");
        auto kindValue = member(actionValue, "action");
        enforce(kindValue !is null && outcomeValue.type == JSONType.string &&
            kindValue.type == JSONType.string,
            "action outcome and action must be text");
        auto outcome = parseOutcome(outcomeValue.str);
        if (kindValue.str == "route") {
            auto route = member(actionValue, "route");
            enforce(route !is null && route.type == JSONType.string &&
                member(actionValue, "reason") is null,
                "route action needs only route");
            result.dispatch.actions ~= DispatchActionSpecV1.route(outcome, route.str);
        } else {
            auto reason = member(actionValue, "reason");
            enforce(reason !is null && reason.type == JSONType.string &&
                member(actionValue, "route") is null,
                "policy action needs only reason");
            result.dispatch.actions ~= DispatchActionSpecV1.policy(outcome,
                parseAction(kindValue.str), reason.str);
        }
    }
    result.common = parseJobJson(common.toString);
    validateDispatchJobSpecV1(result);
    return result;
}

string canonicalDispatchJobJsonV1(const ref DispatchJobSpecV1 spec) {
    validateDispatchJobSpecV1(spec);
    auto output = appender!string;
    output.put(`{"version":4,"dispatch":{"detector":{"prefix-bytes":`);
    output.put(spec.dispatch.detector.prefixBytes.to!string);
    output.put(`,"evidence-records":`); output.put(spec.dispatch.detector.evidenceRecords.to!string);
    output.put(`,"warnings":`); output.put(spec.dispatch.detector.warnings.to!string);
    output.put(`},"container":{"max-physical-bytes":`);
    output.put(spec.dispatch.container.maxPhysicalBytes.to!string);
    output.put(`,"max-expanded-bytes":`); output.put(spec.dispatch.container.maxExpandedBytes.to!string);
    output.put(`,"max-entries":`); output.put(spec.dispatch.container.maxEntries.to!string);
    output.put(`,"max-depth":`); output.put(spec.dispatch.container.maxDepth.to!string);
    output.put(`,"max-ratio":`); output.put(spec.dispatch.container.maxRatio.to!string);
    output.put(`},"routes":[`);
    auto routeNames = new string[spec.dispatch.routes.length];
    foreach (index, route; spec.dispatch.routes) routeNames[index] = route.name;
    routeNames.sort;
    foreach (index, name; routeNames) {
        const(DispatchRouteSpecV1)* selected;
        foreach (ref route; spec.dispatch.routes) if (route.name == name) selected = &route;
        auto route = *selected;
        if (index) output.put(',');
        output.put(`{"name":`); output.put(quote(route.name));
        output.put(`,"extractor":`); output.put(quote(route.extractor));
        output.put(`,"options":`); appendOptions(output, route.options);
        output.put('}');
    }
    output.put(`],"actions":[`);
    foreach (index; 0 .. cast(size_t) DispatchOutcomeV1.max + 1) {
        const(DispatchActionSpecV1)* selected;
        foreach (ref action; spec.dispatch.actions)
            if (cast(size_t) action.outcome == index) selected = &action;
        auto action = *selected;
        if (index) output.put(',');
        output.put(`{"outcome":`); output.put(quote(outcomeName(action.outcome)));
        output.put(`,"action":`); output.put(quote(actionName(action.kind)));
        if (action.kind == DispatchActionKindV1.route) {
            output.put(`,"route":`); output.put(quote(action.target));
        } else {
            output.put(`,"reason":`); output.put(quote(action.target));
        }
        output.put('}');
    }
    output.put(`]},"common":`); output.put(canonicalJobJson(spec.common));
    output.put('}');
    return output.data;
}

string dispatchJobIdentityV1(const ref DispatchJobSpecV1 spec) {
    auto canonical = canonicalDispatchJobJsonV1(spec);
    return "job:v4:" ~ toHexString!(LetterCase.lower)(
        sha256Of(cast(const(ubyte)[]) canonical)).idup;
}

private JSONValue exact(ref JSONValue object, const(string)[] allowed,
        string required, string context) {
    enforce(object.type == JSONType.object, context ~ " must be an object");
    JSONValue* result;
    bool[string] seen;
    foreach (ref item; object.orderedObject) {
        enforce((item.key in seen) is null, "duplicate " ~ context ~ " key: " ~ item.key);
        seen[item.key] = true;
        bool known;
        foreach (key; allowed) if (item.key == key) known = true;
        enforce(known, "unknown " ~ context ~ " key: " ~ item.key);
        if (item.key == required) result = &item.value;
    }
    enforce(result !is null, "missing " ~ context ~ " key: " ~ required);
    return *result;
}

private JSONValue* member(ref JSONValue object, string key) {
    foreach (ref item; object.orderedObject) if (item.key == key) return &item.value;
    return null;
}

private size_t positiveSize(JSONValue value, string field) {
    auto number = positiveUlong(value, field);
    enforce(number <= size_t.max, field ~ " is out of range");
    return cast(size_t) number;
}
private ulong positiveUlong(JSONValue value, string field) {
    ulong number;
    if (value.type == JSONType.integer) {
        enforce(value.integer > 0, field ~ " must be positive");
        number = cast(ulong) value.integer;
    } else if (value.type == JSONType.uinteger) number = value.uinteger;
    else enforce(false, field ~ " must be an integer");
    enforce(number > 0, field ~ " must be positive");
    return number;
}

private JobOptions parseOptions(ref JSONValue value, string context) {
    enforce(value.type == JSONType.object, context ~ " options must be an object");
    JobOptions result;
    foreach (ref item; value.orderedObject) {
        validateJobKey(item.key, context ~ " option key");
        enforce((item.key in result) is null, "duplicate " ~ context ~ " option");
        final switch (item.value.type) {
        case JSONType.string: result[item.key] = JobOption.text(item.value.str); break;
        case JSONType.integer: result[item.key] = JobOption.integer(item.value.integer); break;
        case JSONType.uinteger:
            enforce(item.value.uinteger <= long.max, "option integer is out of range");
            result[item.key] = JobOption.integer(cast(long) item.value.uinteger); break;
        case JSONType.true_: result[item.key] = JobOption.boolean(true); break;
        case JSONType.false_: result[item.key] = JobOption.boolean(false); break;
        case JSONType.null_, JSONType.float_, JSONType.array, JSONType.object:
            enforce(false, context ~ " option must be scalar");
        }
    }
    return result;
}

private string quote(string value) { return JSONValue(value).toString; }
private void appendOptions(ref Appender!string output, const ref JobOptions options) {
    output.put('{'); auto keys = options.keys; keys.sort;
    foreach (index, key; keys) {
        if (index) output.put(','); output.put(quote(key)); output.put(':');
        auto value = options[key];
        final switch (value.type) {
        case JobOptionType.text: output.put(quote(value.asText)); break;
        case JobOptionType.integer: output.put(value.asInteger.to!string); break;
        case JobOptionType.boolean: output.put(value.asBoolean ? "true" : "false"); break;
        }
    } output.put('}');
}

string outcomeName(DispatchOutcomeV1 outcome) pure {
    final switch (outcome) {
    case DispatchOutcomeV1.unknown: return "unknown";
    case DispatchOutcomeV1.plainText: return "plain-text";
    case DispatchOutcomeV1.html: return "html";
    case DispatchOutcomeV1.pdf: return "pdf";
    case DispatchOutcomeV1.png: return "png";
    case DispatchOutcomeV1.jpeg: return "jpeg";
    case DispatchOutcomeV1.gif: return "gif";
    case DispatchOutcomeV1.ambiguous: return "ambiguous";
    case DispatchOutcomeV1.malformed: return "malformed";
    case DispatchOutcomeV1.encrypted: return "encrypted";
    case DispatchOutcomeV1.unsupported: return "unsupported";
    case DispatchOutcomeV1.genericZip: return "generic-zip";
    case DispatchOutcomeV1.ooxmlWord: return "ooxml-word";
    }
}
private DispatchOutcomeV1 parseOutcome(string name) {
    foreach (i; 0 .. cast(size_t) DispatchOutcomeV1.max + 1) {
        auto outcome = cast(DispatchOutcomeV1) i;
        if (outcomeName(outcome) == name) return outcome;
    }
    throw new Exception("unknown dispatch outcome: " ~ name);
}
private string actionName(DispatchActionKindV1 kind) pure {
    final switch (kind) {
    case DispatchActionKindV1.route: return "route";
    case DispatchActionKindV1.reject: return "reject";
    case DispatchActionKindV1.quarantine: return "quarantine";
    case DispatchActionKindV1.passThrough: return "pass";
    }
}
private DispatchActionKindV1 parseAction(string name) {
    foreach (i; 0 .. cast(size_t) DispatchActionKindV1.max + 1) {
        auto kind = cast(DispatchActionKindV1) i;
        if (actionName(kind) == name) return kind;
    }
    throw new Exception("unknown dispatch action: " ~ name);
}

unittest {
    import std.exception : assertThrown;
    import std.string : replace;
    string actions;
    foreach (i; 0 .. cast(size_t) DispatchOutcomeV1.max + 1) {
        if (i) actions ~= ",";
        auto outcome = cast(DispatchOutcomeV1) i;
        actions ~= `{"outcome":` ~ quote(outcomeName(outcome)) ~
            (outcome == DispatchOutcomeV1.plainText
                ? `,"action":"route","route":"text"}`
                : `,"action":"reject","reason":"not selected"}`);
    }
    auto json = `{"version":4,"dispatch":{"detector":{"prefix-bytes":4096,` ~
        `"evidence-records":16,"warnings":8},"container":{` ~
        `"max-physical-bytes":1024,"max-expanded-bytes":2048,"max-entries":10,` ~
        `"max-depth":2,"max-ratio":100},"routes":[{"name":"text",` ~
        `"extractor":"identity","options":{"z":1,"strict":true}}],"actions":[` ~
        actions ~ `]},"common":{"version":3,"stages":[]}}`;
    auto parsed = parseDispatchJobJsonV1(json);
    auto canonical = canonicalDispatchJobJsonV1(parsed);
    auto reparsed = parseDispatchJobJsonV1(canonical);
    assert(canonicalDispatchJobJsonV1(reparsed) == canonical);
    assert(canonical.indexOf(`"options":{"strict":true,"z":1}`) >= 0);
    assert(dispatchJobIdentityV1(parsed) ==
        "job:v4:eaa685ab62a19bfa65dcefe34834adf14450670c8bf4cd1fbfa7910cedaf8627");
    assertThrown(parseDispatchJobJsonV1(json.replace(`"version":4`,
        `"version":4,"version":4`)));
    assertThrown(parseDispatchJobJsonV1(json.replace(`"common":`, `"stages":[],"common":`)));
    assertThrown(parseDispatchJobJsonV1(json.replace(
        `"prefix-bytes":4096`, `"prefix-bytes":"4096"`)));
    assertThrown(parseDispatchJobJsonV1(json.replace(
        `"z":1,"strict":true`, `"z":1,"strict":true,"strict":false`)));
    assertThrown(parseDispatchJobJsonV1(json.replace(
        `"route":"text"}`, `"route":"text","reason":"mixed"}`)));
    assertThrown(parseDispatchJobJsonV1(json.replace(
        `}],"actions":[`, `},{"name":"unused","extractor":"identity","options":{}}],"actions":[`)));
}
