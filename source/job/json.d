/// Strict v3 JSON parsing, canonical serialization and job identity.
module job.json;

import job.spec : JobFilterSpec, JobOption, JobOptions, JobOptionType, JobSpec,
    JobStageSpec, jobSpecVersion, validateJobKey, validateJobSpec;
import std.algorithm.sorting : sort;
import std.array : Appender, appender;
import std.digest : LetterCase, toHexString;
import crypto.sha256 : sha256Of;
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

/// Writes `value` as a quoted, escaped JSON string straight into `output`
/// using Phobos' output-sink JSON quoting (`JSONValue.toString(sink)`),
/// avoiding the temporary string that `JSONValue.toString` (no sink)
/// would otherwise allocate.
private void putQuoted(ref Appender!string output, string value) {
    JSONValue(value).toString(output);
}

/// Fixed-stack unsigned decimal emitter: no heap allocation, no `to!string`.
private void putUnsignedDecimal(ref Appender!string output, ulong value) {
    char[20] digits; // ulong.max ("18446744073709551615") is 20 digits.
    size_t index = digits.length;
    do {
        digits[--index] = cast(char)('0' + (value % 10));
        value /= 10;
    } while (value != 0);
    foreach (i; index .. digits.length) output.put(digits[i]);
}

/// Fixed-stack signed decimal emitter: no heap allocation, no `to!string`.
/// Handles `long.min` via unsigned two's-complement negation, avoiding
/// signed overflow on the naive `-value`.
private void putSignedDecimal(ref Appender!string output, long value) {
    if (value < 0) {
        output.put('-');
        putUnsignedDecimal(output, -(cast(ulong) value));
    } else {
        putUnsignedDecimal(output, cast(ulong) value);
    }
}

private void appendOptions(ref Appender!string output, const ref JobOptions options) {
    output.put('{');
    auto keys = options.keys;
    keys.sort;
    foreach (index, key; keys) {
        if (index) output.put(',');
        putQuoted(output, key);
        output.put(':');
        auto value = options[key];
        final switch (value.type) {
        case JobOptionType.text: putQuoted(output, value.asText); break;
        case JobOptionType.integer: putSignedDecimal(output, value.asInteger); break;
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
        putQuoted(output, stage.id);
        output.put(`,"implementation":`);
        putQuoted(output, stage.implementation);
        output.put(`,"options":`);
        appendOptions(output, stage.options);
        output.put(`,"filters":[`);
        foreach (filterIndex, filter; stage.filters) {
            if (filterIndex) output.put(',');
            output.put(`{"name":`);
            putQuoted(output, filter.name);
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

// Golden coverage for the streamed quote/decimal call sites: quotes,
// backslash, slash, named and numeric controls, non-ASCII, empty text,
// booleans, zero, digit-count transitions and the long boundaries. The
// literal is both valid input and its own expected canonical output.
unittest {
    auto golden = `{"version":3,"stages":[{"id":"golden",` ~
        `"implementation":"text-transform","options":{` ~
        `"a-bool-false":false,"b-bool-true":true,"c-empty":"","d-zero":0,` ~
        `"e-nine":9,"f-ten":10,"g-ninety-nine":99,"h-hundred":100,` ~
        `"i-neg-one":-1,"j-neg-nine":-9,"k-neg-ten":-10,"l-neg-hundred":-100,` ~
        `"m-long-max":9223372036854775807,"n-long-min":-9223372036854775808,` ~
        `"o-quote":"a\"b","p-backslash":"a\\b","q-slash":"a\/b",` ~
        `"r-controls":"\n\t\r\b\f\u001F","s-nonascii":"café 测试 🎉"` ~
        `},"filters":[]}]}`;
    auto parsed = parseJobJson(golden);
    auto canonical = canonicalJobJson(parsed);
    assert(canonical == golden, canonical);
    assert(canonicalJobJson(parseJobJson(canonical)) == canonical);
    assert(jobIdentity(parsed) ==
        "job:v3:98d0cb8dbfa0b7dd1a2f0f35219b7a5f13723c3a1124ce4598aaf16eff941855",
        jobIdentity(parsed));
}
