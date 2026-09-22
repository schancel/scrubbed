/// Compatibility lowering from the predecessor filter-only configuration.
module job.legacy;

import job.spec : JobFilterSpec, JobOption, JobSpec, JobStageSpec, validateJobSpec;
import std.conv : to;
import std.exception : enforce;
import std.json : JSONOptions, JSONType, JSONValue, parseJSON;

enum legacyStageId = "legacy-text";
enum legacyStageImplementation = "text-transform";
immutable string[] defaultLegacyFilters = ["normalize-line-endings", "strip-control"];

JobSpec lowerLegacyNames(const string[] names) {
    JobStageSpec stage;
    stage.id = legacyStageId;
    stage.implementation = legacyStageImplementation;
    foreach (name; names) stage.filters ~= JobFilterSpec(name);
    auto result = JobSpec([stage]);
    validateJobSpec(result);
    return result;
}

JobSpec lowerLegacyDefault() {
    return lowerLegacyNames(defaultLegacyFilters);
}

private JSONValue* field(ref JSONValue object, string wanted, string context,
        const(string)[] allowed, bool required = false) {
    JSONValue* result;
    bool[string] seen;
    foreach (ref member; object.orderedObject) {
        enforce((member.key in seen) is null,
            "duplicate " ~ context ~ " key: " ~ member.key);
        seen[member.key] = true;
        bool known;
        foreach (key; allowed) if (member.key == key) known = true;
        enforce(known, "unknown " ~ context ~ " key: " ~ member.key);
        if (member.key == wanted) result = &member.value;
    }
    if (required) enforce(result !is null, "missing " ~ context ~ " key: " ~ wanted);
    return result;
}

/// Parse legacy v1 JSON once at the compatibility edge, retaining scalar
/// option types that the predecessor parser previously coerced to strings.
JobSpec lowerLegacyJson(string json) {
    auto flags = JSONOptions.strictParsing | JSONOptions.preserveObjectOrder;
    auto root = parseJSON(json, 8, flags);
    enforce(root.type == JSONType.object, "legacy config must be an object");
    auto filters = field(root, "filters", "legacy config", ["filters"], true);
    enforce(filters.type == JSONType.array, "legacy filters must be an array");
    JobStageSpec stage;
    stage.id = legacyStageId;
    stage.implementation = legacyStageImplementation;
    foreach (entry; filters.array) {
        JobFilterSpec filter;
        if (entry.type == JSONType.string) {
            filter.name = entry.str;
        } else {
            enforce(entry.type == JSONType.object,
                "legacy filter must be a name or object");
            auto name = field(entry, "name", "legacy filter",
                ["name", "options"], true);
            enforce(name.type == JSONType.string, "legacy filter name must be text");
            filter.name = name.str;
            if (auto options = field(entry, "options", "legacy filter",
                    ["name", "options"])) {
                enforce(options.type == JSONType.object,
                    "legacy filter options must be an object");
                bool[string] seen;
                foreach (ref option; options.orderedObject) {
                    enforce((option.key in seen) is null,
                        "duplicate legacy option: " ~ option.key);
                    seen[option.key] = true;
                    final switch (option.value.type) {
                    case JSONType.string:
                        filter.options[option.key] = JobOption.text(option.value.str);
                        break;
                    case JSONType.integer:
                        filter.options[option.key] = JobOption.integer(option.value.integer);
                        break;
                    case JSONType.uinteger:
                        enforce(option.value.uinteger <= long.max,
                            "legacy option integer is out of range");
                        filter.options[option.key] =
                            JobOption.integer(cast(long) option.value.uinteger);
                        break;
                    case JSONType.true_:
                        filter.options[option.key] = JobOption.boolean(true);
                        break;
                    case JSONType.false_:
                        filter.options[option.key] = JobOption.boolean(false);
                        break;
                    case JSONType.null_, JSONType.float_, JSONType.array, JSONType.object:
                        throw new Exception("legacy option must be text, integer or boolean: " ~
                            option.key);
                    }
                }
            }
        }
        stage.filters ~= filter;
    }
    auto result = JobSpec([stage]);
    validateJobSpec(result);
    return result;
}

unittest {
    import job.json : canonicalJobJson;
    import std.exception : assertThrown;

    auto names = lowerLegacyNames(["fix-mojibake", "strip-control"]);
    auto json = lowerLegacyJson(`{"filters":[{"name":"fix-mojibake"},"strip-control"]}`);
    assert(canonicalJobJson(names) == canonicalJobJson(json));
    auto configured = lowerLegacyJson(`{"filters":[{"name":"fix-mojibake",` ~
        `"options":{"max-passes":2,"enabled":false}}]}`);
    assert(configured.stages[0].filters[0].options["max-passes"].asInteger == 2);
    assert(!configured.stages[0].filters[0].options["enabled"].asBoolean);
    assert(lowerLegacyDefault.stages[0].filters.length == 2);
    foreach (bad; [
        `{"filters":[],"unknown":0}`,
        `{"filters":[],"filters":[]}`,
        `{"filters":[{"name":"f","name":"g"}]}`,
        `{"filters":[{"name":"f","options":{"x":1.5}}]}`
    ]) assertThrown(lowerLegacyJson(bad));
}
