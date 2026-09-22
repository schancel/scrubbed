/// Strict v3 JSON parsing, canonical serialization and job identity.
module job.json;

import job.spec : JobFilterSpec, JobOption, JobOptions, JobOptionType, JobSpec,
    JobStageSpec, jobSpecVersion, validateJobKey, validateJobSpec;
import std.algorithm.sorting : sort;
import std.array : Appender, appender;
import std.conv : to;
import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;
import std.exception : enforce;
import std.json : JSONOptions, JSONType, JSONValue, parseJSON;

enum maxJobJsonBytes = 16 * 1024 * 1024;

private JSONValue.OrderedObjectMember[] members(JSONValue value, string context) {
    enforce(value.type == JSONType.object, context ~ " must be an object");
    return value.orderedObjectNoRef;
}

private JSONValue* exactMember(ref JSONValue object, const(string)[] allowed,
        string required, string context) {
    JSONValue* result;
    bool[string] seen;
    foreach (ref member; object.orderedObject) {
        enforce((member.key in seen) is null,
            "duplicate " ~ context ~ " key: " ~ member.key);
        seen[member.key] = true;
        bool known;
        foreach (key; allowed) if (member.key == key) known = true;
        enforce(known, "unknown " ~ context ~ " key: " ~ member.key);
        if (member.key == required) result = &member.value;
    }
    if (required.length) enforce(result !is null,
        "missing " ~ context ~ " key: " ~ required);
    return result;
}

private JSONValue* optionalMember(ref JSONValue object, string wanted) {
    foreach (ref member; object.orderedObject)
        if (member.key == wanted) return &member.value;
    return null;
}

private JobOptions parseOptions(ref JSONValue value, string context) {
    auto entries = members(value, context ~ " options");
    JobOptions result;
    foreach (ref entry; entries) {
        validateJobKey(entry.key, context ~ " option key");
        enforce((entry.key in result) is null,
            "duplicate " ~ context ~ " option: " ~ entry.key);
        final switch (entry.value.type) {
        case JSONType.string:
            result[entry.key] = JobOption.text(entry.value.str);
            break;
        case JSONType.integer:
            result[entry.key] = JobOption.integer(entry.value.integer);
            break;
        case JSONType.uinteger:
            enforce(entry.value.uinteger <= long.max,
                context ~ " option integer is out of range: " ~ entry.key);
            result[entry.key] = JobOption.integer(cast(long) entry.value.uinteger);
            break;
        case JSONType.true_:
            result[entry.key] = JobOption.boolean(true);
            break;
        case JSONType.false_:
            result[entry.key] = JobOption.boolean(false);
            break;
        case JSONType.null_, JSONType.float_, JSONType.array, JSONType.object:
            throw new Exception(context ~ " option must be text, integer or boolean: " ~
                entry.key);
        }
    }
    return result;
}

/// Parse RFC-8259 JSON while retaining object order long enough to reject
/// duplicate keys before constructing the order-independent typed model.
JobSpec parseJobJson(string json) {
    enforce(json.length <= maxJobJsonBytes, "job JSON exceeds byte limit");
    auto flags = JSONOptions.strictParsing | JSONOptions.preserveObjectOrder;
    auto root = parseJSON(json, 16, flags);
    auto versionValue = exactMember(root, ["version", "stages"], "version", "job");
    enforce(versionValue.type == JSONType.integer &&
        versionValue.integer == jobSpecVersion,
        "job version must be integer 3");
    auto stagesValue = optionalMember(root, "stages");
    enforce(stagesValue !is null, "missing job key: stages");
    enforce(stagesValue.type == JSONType.array, "job stages must be an array");

    JobSpec result;
    foreach (stageIndex, stageValue; stagesValue.array) {
        auto id = exactMember(stageValue,
            ["id", "implementation", "options", "filters"], "id", "stage");
        auto implementation = optionalMember(stageValue, "implementation");
        enforce(id.type == JSONType.string, "stage id must be text");
        enforce(implementation !is null && implementation.type == JSONType.string,
            "stage implementation must be text");
        JobStageSpec stage;
        stage.id = id.str;
        stage.implementation = implementation.str;
        if (auto options = optionalMember(stageValue, "options"))
            stage.options = parseOptions(*options, "stage " ~ stage.id);
        if (auto filters = optionalMember(stageValue, "filters")) {
            enforce(filters.type == JSONType.array, "stage filters must be an array");
            foreach (filterIndex, filterValue; filters.array) {
                auto name = exactMember(filterValue, ["name", "options"],
                    "name", "filter");
                enforce(name.type == JSONType.string, "filter name must be text");
                JobFilterSpec filter;
                filter.name = name.str;
                if (auto options = optionalMember(filterValue, "options"))
                    filter.options = parseOptions(*options, "filter " ~ filter.name);
                stage.filters ~= filter;
            }
        }
        result.stages ~= stage;
    }
    validateJobSpec(result);
    return result;
}

private string quote(string value) {
    return JSONValue(value).toString;
}

private void appendOptions(ref Appender!string output, const ref JobOptions options) {
    output.put('{');
    auto keys = options.keys;
    keys.sort;
    foreach (index, key; keys) {
        if (index) output.put(',');
        output.put(quote(key));
        output.put(':');
        auto value = options[key];
        final switch (value.type) {
        case JobOptionType.text: output.put(quote(value.asText)); break;
        case JobOptionType.integer: output.put(value.asInteger.to!string); break;
        case JobOptionType.boolean: output.put(value.asBoolean ? "true" : "false"); break;
        }
    }
    output.put('}');
}

/// Fixed field order, sorted option keys, no insignificant whitespace.
string canonicalJobJson(const JobSpec spec) {
    validateJobSpec(spec);
    auto output = appender!string;
    output.put(`{"version":3,"stages":[`);
    foreach (stageIndex, stage; spec.stages) {
        if (stageIndex) output.put(',');
        output.put(`{"id":`);
        output.put(quote(stage.id));
        output.put(`,"implementation":`);
        output.put(quote(stage.implementation));
        output.put(`,"options":`);
        appendOptions(output, stage.options);
        output.put(`,"filters":[`);
        foreach (filterIndex, filter; stage.filters) {
            if (filterIndex) output.put(',');
            output.put(`{"name":`);
            output.put(quote(filter.name));
            output.put(`,"options":`);
            appendOptions(output, filter.options);
            output.put('}');
        }
        output.put(`]}`);
    }
    output.put(`]}`);
    return output.data;
}

string jobIdentity(const JobSpec spec) {
    auto canonical = canonicalJobJson(spec);
    return "job:v3:" ~ toHexString!(LetterCase.lower)(
        sha256Of(cast(const(ubyte)[]) canonical)).idup;
}

unittest {
    import std.exception : assertThrown;

    auto parsed = parseJobJson(`{
      "stages":[{"filters":[{"options":{"max-passes":2,"enabled":true},
      "name":"fix-mojibake"}],"implementation":"text-transform",
      "options":{"label":"clean"},"id":"clean"}],"version":3}`);
    auto canonical = canonicalJobJson(parsed);
    assert(canonical == `{"version":3,"stages":[{"id":"clean",` ~
        `"implementation":"text-transform","options":{"label":"clean"},` ~
        `"filters":[{"name":"fix-mojibake","options":{"enabled":true,` ~
        `"max-passes":2}}]}]}`);
    assert(canonicalJobJson(parseJobJson(canonical)) == canonical);
    assert(jobIdentity(parsed) ==
        "job:v3:d901650f7a0633860298590a8b868363f1ee470f9325f046bd16a21c15593116");

    foreach (bad; [
        `{"version":2,"stages":[]}`,
        `{"version":3,"version":3,"stages":[]}`,
        `{"version":3,"stages":[],"unknown":0}`,
        `{"version":3,"stages":[{"id":"x","implementation":"text-transform","id":"y"}]}`,
        `{"version":3,"stages":[{"id":"Upper","implementation":"text-transform"}]}`,
        `{"version":3,"stages":[{"id":"x","implementation":"text-transform","options":{"x":1.5}}]}`,
        `{"version":3,"stages":[{"id":"x","implementation":"text-transform","filters":{}}]}`,
        `{"version":3,"stages":[{"id":"x","implementation":"text-transform","filters":[{"name":"f","options":{"x":null}}]}]}`
    ]) assertThrown(parseJobJson(bad));
}
