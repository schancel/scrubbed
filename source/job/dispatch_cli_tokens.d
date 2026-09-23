/// Ordered pure token lowering for the additive v4 dispatch specification.
module job.dispatch_cli_tokens;

import job.cli_tokens : parseJobTokens;
import job.dispatch_json : outcomeName;
import job.dispatch_spec : DispatchActionKindV1, DispatchActionSpecV1,
    DispatchContainerSpecV1, DispatchDetectorSpecV1, DispatchJobSpecV1,
    DispatchOutcomeV1, DispatchRouteSpecV1, DispatchSpecV1,
    validateDispatchJobSpecV1;
import job.spec : JobOption, JobOptions, validateJobKey;
import std.conv : ConvException, to;
import std.exception : enforce;
import std.string : indexOf;

DispatchJobSpecV1 parseDispatchJobTokensV1(const string[] tokens) {
    DispatchJobSpecV1 result;
    string[string] limits;
    size_t index;
    while (index < tokens.length && tokens[index] != "--common") {
        auto flag = tokens[index++];
        enforce(index < tokens.length, "missing value for " ~ flag);
        auto value = tokens[index++];
        if (flag == "--dispatch-option") {
            string key; auto encoded = splitEquals(value, key, "dispatch option");
            enforce((key in limits) is null, "duplicate dispatch option: " ~ key);
            limits[key] = encoded;
        } else if (flag == "--route") {
            string name; auto extractor = splitEquals(value, name, "route");
            validateJobKey(extractor, "route extractor");
            result.dispatch.routes ~= DispatchRouteSpecV1(name, extractor, null);
        } else if (flag == "--route-option") {
            enforce(result.dispatch.routes.length, "route option needs a preceding route");
            string key; auto encoded = splitEquals(value, key, "route option");
            enforce((key in result.dispatch.routes[$ - 1].options) is null,
                "duplicate route option: " ~ key);
            result.dispatch.routes[$ - 1].options[key] = typedOption(encoded);
        } else if (flag == "--action") {
            string outcomeText; auto encoded = splitEquals(value, outcomeText, "action");
            auto outcome = parsedOutcome(outcomeText);
            auto separator = encoded.indexOf(':');
            enforce(separator > 0 && separator + 1 < encoded.length,
                "action must be KIND:TARGET");
            auto kind = encoded[0 .. separator];
            auto target = encoded[separator + 1 .. $];
            if (kind == "route")
                result.dispatch.actions ~= DispatchActionSpecV1.route(outcome, target);
            else if (kind == "reject")
                result.dispatch.actions ~= DispatchActionSpecV1.policy(outcome,
                    DispatchActionKindV1.reject, target);
            else if (kind == "quarantine")
                result.dispatch.actions ~= DispatchActionSpecV1.policy(outcome,
                    DispatchActionKindV1.quarantine, target);
            else if (kind == "pass")
                result.dispatch.actions ~= DispatchActionSpecV1.policy(outcome,
                    DispatchActionKindV1.passThrough, target);
            else throw new Exception("unknown dispatch action kind: " ~ kind);
        } else throw new Exception("unknown dispatch token: " ~ flag);
    }
    enforce(index < tokens.length && tokens[index] == "--common",
        "dispatch tokens need --common before shared stages");
    ++index;
    result.common = parseJobTokens(tokens[index .. $]);
    result.dispatch.detector = DispatchDetectorSpecV1(
        limit(limits, "detector-prefix-bytes"),
        limit(limits, "detector-evidence-records"),
        limit(limits, "detector-warnings"));
    result.dispatch.container = DispatchContainerSpecV1(
        limit(limits, "container-max-physical-bytes"),
        limit(limits, "container-max-expanded-bytes"),
        limit(limits, "container-max-entries"),
        limit(limits, "container-max-depth"),
        limit(limits, "container-max-ratio"));
    enforce(limits.length == 8, "unknown or missing dispatch options");
    validateDispatchJobSpecV1(result);
    return result;
}

private string splitEquals(string value, out string key, string context) {
    auto separator = value.indexOf('=');
    enforce(separator > 0 && separator + 1 < value.length,
        context ~ " must be KEY=VALUE");
    key = value[0 .. separator]; validateJobKey(key, context ~ " key");
    return value[separator + 1 .. $];
}
private size_t limit(ref string[string] values, string key) {
    auto value = key in values; enforce(value !is null, "missing dispatch option: " ~ key);
    size_t parsed;
    try parsed = (*value).to!size_t;
    catch (ConvException) throw new Exception("invalid dispatch option: " ~ key);
    enforce(parsed > 0 && parsed.to!string == *value,
        "dispatch option must be canonical positive decimal: " ~ key);
    return parsed;
}
private JobOption typedOption(string encoded) {
    auto separator = encoded.indexOf(':');
    enforce(separator > 0, "route option must be TYPE:VALUE");
    auto type = encoded[0 .. separator]; auto value = encoded[separator + 1 .. $];
    if (type == "text") return JobOption.text(value);
    if (type == "boolean") {
        enforce(value == "true" || value == "false", "invalid boolean route option");
        return JobOption.boolean(value == "true");
    }
    if (type == "integer") {
        long number; try number = value.to!long;
        catch (ConvException) throw new Exception("invalid integer route option");
        enforce(number.to!string == value, "route integer must be canonical decimal");
        return JobOption.integer(number);
    }
    throw new Exception("unknown route option type: " ~ type);
}
private DispatchOutcomeV1 parsedOutcome(string name) {
    foreach (i; 0 .. cast(size_t) DispatchOutcomeV1.max + 1) {
        auto outcome = cast(DispatchOutcomeV1) i;
        if (outcomeName(outcome) == name) return outcome;
    }
    throw new Exception("unknown dispatch outcome: " ~ name);
}

unittest {
    import job.dispatch_json : canonicalDispatchJobJsonV1,
        dispatchJobIdentityV1;
    import std.exception : assertThrown;
    string[] tokens = [
        "--dispatch-option", "detector-prefix-bytes=4096",
        "--dispatch-option", "detector-evidence-records=16",
        "--dispatch-option", "detector-warnings=8",
        "--dispatch-option", "container-max-physical-bytes=1024",
        "--dispatch-option", "container-max-expanded-bytes=2048",
        "--dispatch-option", "container-max-entries=10",
        "--dispatch-option", "container-max-depth=2",
        "--dispatch-option", "container-max-ratio=100",
        "--route", "text=identity", "--route-option", "z=integer:1",
        "--route-option", "strict=boolean:true",
        "--action", "unknown=reject:not selected",
        "--action", "plain-text=route:text",
        "--action", "html=reject:not selected",
        "--action", "pdf=reject:not selected",
        "--action", "png=reject:not selected",
        "--action", "jpeg=reject:not selected",
        "--action", "gif=reject:not selected",
        "--action", "ambiguous=reject:not selected",
        "--action", "malformed=reject:not selected",
        "--action", "encrypted=reject:not selected",
        "--action", "unsupported=reject:not selected",
        "--action", "generic-zip=reject:not selected",
        "--action", "ooxml-word=reject:not selected",
        "--common"
    ];
    auto parsed = parseDispatchJobTokensV1(tokens);
    auto canonical = canonicalDispatchJobJsonV1(parsed);
    assert(parsed.dispatch.routes[0].options["strict"].asBoolean);
    assert(canonical == `{"version":4,"dispatch":{"detector":` ~
        `{"prefix-bytes":4096,"evidence-records":16,"warnings":8},` ~
        `"container":{"max-physical-bytes":1024,"max-expanded-bytes":2048,` ~
        `"max-entries":10,"max-depth":2,"max-ratio":100},` ~
        `"routes":[{"name":"text","extractor":"identity",` ~
        `"options":{"strict":true,"z":1}}],"actions":[` ~
        `{"outcome":"unknown","action":"reject","reason":"not selected"},` ~
        `{"outcome":"plain-text","action":"route","route":"text"},` ~
        `{"outcome":"html","action":"reject","reason":"not selected"},` ~
        `{"outcome":"pdf","action":"reject","reason":"not selected"},` ~
        `{"outcome":"png","action":"reject","reason":"not selected"},` ~
        `{"outcome":"jpeg","action":"reject","reason":"not selected"},` ~
        `{"outcome":"gif","action":"reject","reason":"not selected"},` ~
        `{"outcome":"ambiguous","action":"reject","reason":"not selected"},` ~
        `{"outcome":"malformed","action":"reject","reason":"not selected"},` ~
        `{"outcome":"encrypted","action":"reject","reason":"not selected"},` ~
        `{"outcome":"unsupported","action":"reject","reason":"not selected"},` ~
        `{"outcome":"generic-zip","action":"reject","reason":"not selected"},` ~
        `{"outcome":"ooxml-word","action":"reject","reason":"not selected"}` ~
        `]},"common":{"version":3,"stages":[]}}`);
    assert(dispatchJobIdentityV1(parsed) ==
        "job:v4:eaa685ab62a19bfa65dcefe34834adf14450670c8bf4cd1fbfa7910cedaf8627");

    string[][] bad;
    auto noncanonicalInteger = tokens.dup;
    noncanonicalInteger[1] = "detector-prefix-bytes=04096";
    bad ~= noncanonicalInteger;
    auto caseOutcome = tokens.dup;
    caseOutcome[23] = "Unknown=reject:not selected";
    bad ~= caseOutcome;
    auto caseBoolean = tokens.dup;
    caseBoolean[21] = "strict=Boolean:True";
    bad ~= caseBoolean;
    auto duplicateLimit = tokens[0 .. $ - 1].dup;
    duplicateLimit ~= ["--dispatch-option", "detector-prefix-bytes=4096", "--common"];
    bad ~= duplicateLimit;
    auto duplicateAction = tokens[0 .. $ - 1].dup;
    duplicateAction ~= ["--action", "unknown=reject:again", "--common"];
    bad ~= duplicateAction;
    auto misplacedStage = tokens[0 .. 2].dup;
    misplacedStage ~= ["--stage", "x=text-transform", "--common"];
    bad ~= misplacedStage;
    foreach (candidate; bad) assertThrown(parseDispatchJobTokensV1(candidate));
}
