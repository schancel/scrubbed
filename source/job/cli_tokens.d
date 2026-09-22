/// Ordered CLI composition-token lowering into the shared v3 job model.
module job.cli_tokens;

import job.spec : JobFilterSpec, JobOption, JobOptions, JobSpec, JobStageSpec,
    validateJobKey, validateJobSpec;
import std.conv : ConvException, to;
import std.exception : enforce;
import std.string : indexOf;

private string afterEquals(string value, out string key, string context) {
    auto separator = value.indexOf('=');
    enforce(separator > 0 && separator + 1 < value.length,
        context ~ " must be KEY=VALUE");
    key = value[0 .. separator];
    validateJobKey(key, context ~ " key");
    return value[separator + 1 .. $];
}

private JobOption typedOption(string value, string context) {
    auto separator = value.indexOf(':');
    enforce(separator > 0, context ~ " must be TYPE:VALUE");
    auto type = value[0 .. separator];
    auto raw = value[separator + 1 .. $];
    if (type == "text") return JobOption.text(raw);
    if (type == "boolean") {
        enforce(raw == "true" || raw == "false",
            context ~ " boolean must be true or false");
        return JobOption.boolean(raw == "true");
    }
    if (type == "integer") {
        long parsed;
        try parsed = raw.to!long;
        catch (ConvException) throw new Exception(context ~ " integer is invalid");
        enforce(parsed.to!string == raw, context ~ " integer must be canonical decimal");
        return JobOption.integer(parsed);
    }
    throw new Exception(context ~ " type must be text, integer or boolean");
}

private void addOption(ref JobOptions options, string token, string context) {
    string key;
    auto encoded = afterEquals(token, key, context);
    enforce((key in options) is null, "duplicate " ~ context ~ ": " ~ key);
    options[key] = typedOption(encoded, context ~ " " ~ key);
}

/// Parse composition-only tokens in declaration order. The shipping argparse
/// surface is switched to this pure boundary in a later reviewed slice.
JobSpec parseJobTokens(const string[] tokens) {
    JobSpec result;
    size_t index;
    while (index < tokens.length) {
        auto flag = tokens[index++];
        enforce(index < tokens.length, "missing value for " ~ flag);
        auto value = tokens[index++];
        if (flag == "--stage") {
            string id;
            auto implementation = afterEquals(value, id, "stage");
            validateJobKey(implementation, "stage implementation");
            result.stages ~= JobStageSpec(id, implementation);
        } else if (flag == "--stage-option") {
            enforce(result.stages.length != 0, "stage option requires a preceding stage");
            enforce(result.stages[$ - 1].filters.length == 0,
                "stage options must precede that stage's filters");
            addOption(result.stages[$ - 1].options, value, "stage option");
        } else if (flag == "--filter") {
            enforce(result.stages.length != 0, "filter requires a preceding stage");
            validateJobKey(value, "filter name");
            result.stages[$ - 1].filters ~= JobFilterSpec(value);
        } else if (flag == "--filter-option") {
            enforce(result.stages.length != 0 &&
                result.stages[$ - 1].filters.length != 0,
                "filter option requires a preceding filter");
            addOption(result.stages[$ - 1].filters[$ - 1].options,
                value, "filter option");
        } else {
            throw new Exception("unknown composition token: " ~ flag);
        }
    }
    validateJobSpec(result);
    return result;
}

unittest {
    import job.json : canonicalJobJson, jobIdentity, parseJobJson;
    import std.exception : assertThrown;

    auto parsed = parseJobTokens([
        "--stage", "clean=text-transform",
        "--stage-option", "label=text:primary",
        "--filter", "fix-mojibake",
        "--filter-option", "max-passes=integer:2",
        "--filter-option", "enabled=boolean:true",
        "--stage", "extract=html-main"
    ]);
    assert(parsed.stages.length == 2);
    assert(parsed.stages[0].filters[0].options["max-passes"].asInteger == 2);
    assert(canonicalJobJson(parsed).length != 0);
    auto equivalentJson = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"clean","implementation":"text-transform",` ~
        `"options":{"label":"primary"},"filters":[` ~
        `{"name":"fix-mojibake","options":{"enabled":true,"max-passes":2}}]},` ~
        `{"id":"extract","implementation":"html-main","options":{},"filters":[]}]}`);
    assert(canonicalJobJson(parsed) == canonicalJobJson(equivalentJson));
    assert(jobIdentity(parsed) == jobIdentity(equivalentJson));

    foreach (bad; [
        ["--filter", "fix-mojibake"],
        ["--stage-option", "x=text:y"],
        ["--filter-option", "x=text:y"],
        ["--stage", "clean=text-transform", "--filter", "f", "--stage-option", "x=text:y"],
        ["--stage", "clean=text-transform", "--stage", "clean=html-main"],
        ["--stage", "clean=text-transform", "--stage-option", "x=integer:01"],
        ["--stage", "clean=text-transform", "--stage-option", "x=boolean:yes"],
        ["--stage", "clean=text-transform", "--stage-option", "x=text:a", "--stage-option", "x=text:b"],
        ["--unknown", "x"]
    ]) assertThrown(parseJobTokens(bad));
}
