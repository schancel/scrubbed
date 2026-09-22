/// Pure typed model for one versioned, linear scrubbed job.
module job.spec;

import std.exception : enforce;
import std.string : indexOf;
import std.utf : validate;

enum jobSpecVersion = 3;
enum maxJobStages = 4_096;
enum maxStageFilters = 4_096;
enum maxOwnerOptions = 1_024;

enum JobOptionType { text, integer, boolean }

/// One scalar option with an explicit, non-coercible type.
struct JobOption {
    private JobOptionType optionType;
    private string textValue;
    private long integerValue;
    private bool booleanValue;

    static JobOption text(string value) {
        validateText(value, "option text");
        JobOption result;
        result.optionType = JobOptionType.text;
        result.textValue = value.idup;
        return result;
    }

    static JobOption integer(long value) {
        JobOption result;
        result.optionType = JobOptionType.integer;
        result.integerValue = value;
        return result;
    }

    static JobOption boolean(bool value) {
        JobOption result;
        result.optionType = JobOptionType.boolean;
        result.booleanValue = value;
        return result;
    }

    JobOptionType type() const { return optionType; }

    string asText() const {
        enforce(optionType == JobOptionType.text, "job option is not text");
        return textValue;
    }

    long asInteger() const {
        enforce(optionType == JobOptionType.integer, "job option is not an integer");
        return integerValue;
    }

    bool asBoolean() const {
        enforce(optionType == JobOptionType.boolean, "job option is not boolean");
        return booleanValue;
    }
}

alias JobOptions = JobOption[string];

/// One registered text filter and its typed options.
struct JobFilterSpec {
    string name;
    JobOptions options;
}

/// One stable stage instance. `id` is identity; `implementation` is registry lookup.
struct JobStageSpec {
    string id;
    string implementation;
    JobOptions options;
    JobFilterSpec[] filters;
}

/// Canonical data model shared by every accepted configuration surface.
struct JobSpec {
    JobStageSpec[] stages;
}

/// Stage IDs, implementation names, filter names and option keys use one
/// shell-friendly canonical alphabet. Option text remains arbitrary UTF-8.
void validateJobKey(string value, string context) {
    enforce(value.length > 0 && value.length <= 128,
        context ~ " must contain 1..128 bytes");
    foreach (index, ch; value) {
        const first = ch >= 'a' && ch <= 'z' || ch >= '0' && ch <= '9';
        const later = first || ch == '-' || ch == '_' || ch == '.';
        enforce(index == 0 ? first : later,
            context ~ " must use lowercase ASCII letters, digits, '.', '_' or '-'");
    }
}

private void validateText(string value, string context) {
    validate(value);
    enforce(value.indexOf('\0') < 0, context ~ " must not contain NUL");
}

private void validateOptions(const ref JobOptions options, string context) {
    enforce(options.length <= maxOwnerOptions, context ~ " has too many options");
    foreach (key, value; options) {
        validateJobKey(key, context ~ " option key");
        final switch (value.type) {
        case JobOptionType.text:
            validateText(value.asText, context ~ " option text");
            break;
        case JobOptionType.integer:
            value.asInteger;
            break;
        case JobOptionType.boolean:
            value.asBoolean;
            break;
        }
    }
}

/// Revalidate public value fields at every trust boundary.
void validateJobSpec(const ref JobSpec spec) {
    enforce(spec.stages.length <= maxJobStages, "job has too many stages");
    bool[string] ids;
    foreach (stageIndex, stage; spec.stages) {
        validateJobKey(stage.id, "stage id");
        enforce((stage.id in ids) is null, "duplicate stage id: " ~ stage.id);
        ids[stage.id] = true;
        validateJobKey(stage.implementation, "stage implementation");
        validateOptions(stage.options, "stage " ~ stage.id);
        enforce(stage.filters.length <= maxStageFilters,
            "stage " ~ stage.id ~ " has too many filters");
        foreach (filterIndex, filter; stage.filters) {
            validateJobKey(filter.name, "filter name");
            validateOptions(filter.options, "filter " ~ filter.name);
        }
    }
}

unittest {
    import std.exception : assertThrown;

    auto spec = JobSpec([JobStageSpec("clean", "text-transform",
        ["enabled": JobOption.boolean(true)],
        [JobFilterSpec("fix-mojibake", ["max-passes": JobOption.integer(2)])])]);
    validateJobSpec(spec);
    assert(spec.stages[0].options["enabled"].asBoolean);
    assert(spec.stages[0].filters[0].options["max-passes"].asInteger == 2);
    assertThrown(spec.stages[0].options["enabled"].asText);
    spec.stages ~= spec.stages[0];
    assertThrown(validateJobSpec(spec));
    assertThrown(validateJobKey("Upper", "test key"));
    assertThrown(JobOption.text("bad\0text"));
}
