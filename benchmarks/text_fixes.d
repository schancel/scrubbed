/// Authored, held-out exact-output evidence for the shipped text filters.
/// This is a standalone benchmark, not an alternate production pipeline.
import filters.entities : decodeHtmlEntities, EntityContext;
import filters.mojibake : fixMojibake;
import filters.normalize : normalizeLineEndingsFilter, stripControlCharsFilter;
import filters.punctuation : uncurlQuotesFilter;
import std.digest : toHexString;
import std.digest.sha : sha256Of;
import std.file : dirEntries, readText, SpanMode;
import std.path : extension;
import std.algorithm.searching : canFind;
import std.conv : to;
import std.json;
import std.stdio : stderr, writeln;
import std.string : toLower;
import std.utf : UTFException, validate;

enum Kind { positive, negative, unsupported, invalidInput }
enum Fix { mojibake, entitiesText, entitiesAttribute, quotes, control, newlines }

struct Case {
    string id;
    Fix fix;
    Kind kind;
    string input;
    string expected;
    string pair;
}

// Synthetic cases are original to this repository; no upstream bytes are copied.
// A positive's pair names its adversarial clean negative, and vice versa.
private immutable Case[] cases = [
    Case("m01", Fix.mojibake, Kind.positive, "FranÃ§ais", "Français", "m02"),
    Case("m02", Fix.mojibake, Kind.negative, "Français", "Français", "m01"),
    Case("m03", Fix.mojibake, Kind.positive, "jalapeÃ±o kettle", "jalapeño kettle", "m04"),
    Case("m04", Fix.mojibake, Kind.negative, "jalapeño kettle", "jalapeño kettle", "m03"),
    Case("e01", Fix.entitiesText, Kind.positive, "fish &amp; chips", "fish & chips", "e02"),
    Case("e02", Fix.entitiesText, Kind.negative, "fish & chips", "fish & chips", "e01"),
    Case("e03", Fix.entitiesText, Kind.positive, "&#x1F9ED;", "🧭", "e04"),
    Case("e04", Fix.entitiesText, Kind.negative, "🧭", "🧭", "e03"),
    Case("a01", Fix.entitiesAttribute, Kind.positive, "Tom &amp; Jane", "Tom & Jane", "a02"),
    Case("a02", Fix.entitiesAttribute, Kind.negative, "Tom & Jane", "Tom & Jane", "a01"),
    Case("a03", Fix.entitiesAttribute, Kind.positive, "x=&amp;y", "x=&y", "a04"),
    Case("a04", Fix.entitiesAttribute, Kind.negative, "x=&ampx", "x=&ampx", "a03"),
    Case("q01", Fix.quotes, Kind.positive, "“Hello”", "\"Hello\"", "q02"),
    Case("q02", Fix.quotes, Kind.negative, "\"Hello\"", "\"Hello\"", "q01"),
    Case("q03", Fix.quotes, Kind.positive, "It’s fine", "It's fine", "q04"),
    Case("q04", Fix.quotes, Kind.negative, "It's fine", "It's fine", "q03"),
    Case("c01", Fix.control, Kind.positive, "a\0b", "ab", "c02"),
    Case("c02", Fix.control, Kind.negative, "ab", "ab", "c01"),
    Case("c03", Fix.control, Kind.positive, "a\f b", "a b", "c04"),
    Case("c04", Fix.control, Kind.negative, "a\t b", "a\t b", "c03"),
    Case("n01", Fix.newlines, Kind.positive, "north\r\nsouth", "north\nsouth", "n02"),
    Case("n02", Fix.newlines, Kind.negative, "north\nsouth", "north\nsouth", "n01"),
    Case("n03", Fix.newlines, Kind.positive, "west\reast", "west\neast", "n04"),
    Case("n04", Fix.newlines, Kind.negative, "west\neast\n", "west\neast\n", "n03"),
    Case("mu", Fix.mojibake, Kind.unsupported, "Beyonc�", "", ""),
    Case("eu", Fix.entitiesText, Kind.unsupported, "<script>const x='&amp;';</script>", "", ""),
    Case("au", Fix.entitiesAttribute, Kind.unsupported, "<a title='a&amp;b'>", "", ""),
    Case("qu", Fix.quotes, Kind.unsupported, "« Bonjour »", "", ""),
    Case("cu", Fix.control, Kind.unsupported, "a\u200Bb", "", ""),
    Case("nu", Fix.newlines, Kind.unsupported, "a\u2028b", "", ""),
    Case("mi", Fix.mojibake, Kind.invalidInput, "\xFF", "", ""),
];

private string applyFix(Fix fix, string input) {
    final switch (fix) {
        case Fix.mojibake: return fixMojibake(input);
        case Fix.entitiesText: return decodeHtmlEntities(input, EntityContext.text);
        case Fix.entitiesAttribute: return decodeHtmlEntities(input, EntityContext.attribute);
        case Fix.quotes: return uncurlQuotesFilter(input);
        case Fix.control: return stripControlCharsFilter(input);
        case Fix.newlines: return normalizeLineEndingsFilter(input);
    }
}

private string name(Fix fix) {
    final switch (fix) {
        case Fix.mojibake: return "fix-mojibake";
        case Fix.entitiesText: return "decode-entities/text";
        case Fix.entitiesAttribute: return "decode-entities/attribute";
        case Fix.quotes: return "uncurl-quotes";
        case Fix.control: return "strip-control";
        case Fix.newlines: return "normalize-line-endings";
    }
}

private string corpusDigest(const(Case)[] selected) {
    string material;
    foreach (c; selected) {
        // Length prefixes make the serialization unambiguous, including NULs.
        foreach (field; [c.id, name(c.fix), c.kind.to!string, c.input, c.expected, c.pair])
            material ~= field.length.to!string ~ ":" ~ field;
    }
    return toHexString(sha256Of(cast(const(ubyte)[]) material))[].toLower;
}

private string bytesDigest(string value) {
    return toHexString(sha256Of(cast(const(ubyte)[]) value))[].toLower;
}

private enum pinnedDigest = "b95399c0ab5f65785af8d89adda240e7b067564a0fffc34cf86222d3b49048ca";

private void require(bool condition, string message) {
    if (!condition) throw new Exception("self-test failed: " ~ message);
}

private JSONValue score(const(Case)[] selected, string function(Fix, string) transform) {
    JSONValue report;
    JSONValue[] rows;
    JSONValue[] fixtures;
    foreach (c; selected) {
        JSONValue fixture;
        fixture["id"] = c.id;
        fixture["fix"] = name(c.fix);
        fixture["class"] = c.kind.to!string;
        fixture["input_sha256"] = bytesDigest(c.input);
        fixture["expected_sha256"] = c.kind == Kind.positive || c.kind == Kind.negative
            ? JSONValue(bytesDigest(c.expected)) : JSONValue(null);
        fixture["pair"] = c.pair;
        fixtures ~= fixture;
    }
    foreach (fix; [Fix.mojibake, Fix.entitiesText, Fix.entitiesAttribute,
                   Fix.quotes, Fix.control, Fix.newlines]) {
        long eligible, correct, clean, unchanged, unsupported, invalid;
        foreach (c; selected) {
            if (c.fix != fix) continue;
            if (c.kind == Kind.unsupported) { unsupported++; continue; }
            if (c.kind == Kind.invalidInput) { invalid++; continue; }
            if (c.kind == Kind.positive) {
                eligible++;
                if (transform(fix, c.input) == c.expected) correct++;
            } else {
                clean++;
                if (transform(fix, c.input) == c.input) unchanged++;
            }
        }
        JSONValue row;
        row["fix"] = name(fix);
        row["fix_eligible"] = eligible;
        row["fix_correct"] = correct;
        row["fix_recall"] = eligible ? JSONValue(cast(double) correct / eligible) : JSONValue(null);
        row["clean_eligible"] = clean;
        row["clean_unchanged"] = unchanged;
        row["clean_false_positives"] = clean - unchanged;
        row["clean_false_positive_rate"] = clean ? JSONValue(cast(double)(clean - unchanged) / clean) : JSONValue(null);
        row["unsupported"] = unsupported;
        row["invalid_input"] = invalid;
        row["gate_passed"] = correct == eligible && unchanged == clean;
        rows ~= row;
    }
    report["schema"] = "scrubbed-held-out-text-v1";
    report["origin"] = "scrubbed-authored-synthetic";
    report["revision"] = "issue-22-v1";
    report["license"] = "MIT";
    report["sha256"] = corpusDigest(selected);
    report["cases"] = cast(long) selected.length;
    report["fixtures"] = JSONValue(fixtures);
    report["fixes"] = JSONValue(rows);
    bool passed = true;
    foreach (row; rows) if (!row["gate_passed"].boolean) passed = false;
    report["gate_passed"] = passed;
    return report;
}

private void validateCorpus(const(Case)[] selected, string expectedDigest) {
    if (corpusDigest(selected) != expectedDigest) throw new Exception("fixture hash mismatch");
    foreach (i, c; selected) {
        foreach (prior; selected[0 .. i]) if (prior.id == c.id) throw new Exception("duplicate case id");
        bool validUtf8 = true;
        try validate(c.input); catch (UTFException) validUtf8 = false;
        if ((c.kind == Kind.invalidInput) == validUtf8)
            throw new Exception("wrong input-validity class: " ~ c.id);
        if (c.kind == Kind.positive || c.kind == Kind.negative) {
            validate(c.expected);
            if ((c.kind == Kind.positive) == (c.input == c.expected))
                throw new Exception("wrong expected-change class: " ~ c.id);
            bool paired;
            foreach (other; selected) if (other.id == c.pair && other.fix == c.fix &&
                other.pair == c.id && other.kind != c.kind &&
                other.kind != Kind.unsupported && other.kind != Kind.invalidInput)
                paired = true;
            if (!paired) throw new Exception("missing opposite-class pair: " ~ c.id);
        } else if (c.expected.length || c.pair.length) {
            throw new Exception("unscored case has expected output or pair: " ~ c.id);
        }
    }
}

private void selfTest() {
    auto identity = (Fix f, string s) => s;
    auto altered = (Fix f, string s) => s == "Français" ? "edited" : applyFix(f, s);
    auto one = [Case("p", Fix.mojibake, Kind.positive, "bad", "good", "n"),
                Case("n", Fix.mojibake, Kind.negative, "good", "good", "p"),
                Case("u", Fix.mojibake, Kind.unsupported, "x", "", "")];
    auto miss = score(one, identity);
    require(!miss["gate_passed"].boolean, "recall miss gate");
    require(miss["fixes"].array[0]["fix_eligible"].integer == 1, "positive denominator");
    require(miss["fixes"].array[0]["fix_correct"].integer == 0, "recall miss count");
    require(miss["fixes"].array[0]["unsupported"].integer == 1, "unsupported exclusion");
    require(miss["fixes"].array[1]["fix_recall"].type == JSONValue(null).type,
        "zero recall denominator");
    require(miss["fixes"].array[1]["clean_false_positive_rate"].type == JSONValue(null).type,
        "zero clean denominator");
    auto falsePositive = score(cases, altered);
    require(!falsePositive["gate_passed"].boolean, "false-positive gate");
    require(falsePositive["fixes"].array[0]["clean_false_positives"].integer == 1,
        "false-positive count");
    require(falsePositive["fixes"].array[0]["invalid_input"].integer == 1,
        "invalid-input exclusion");
    bool rejected;
    try validateCorpus(cases, "0000"); catch (Exception) rejected = true;
    require(rejected, "hash mismatch rejection");
    validateCorpus(cases, pinnedDigest);
}

// Read-only lexical audit: exact quoted D literals in source/tests and exact
// JSON string values in the pinned F01 files. Findings require human review:
// a common short literal is not necessarily a reused tuning case.
private JSONValue auditOverlap(string sourceRoot, string testRoot, string[] upstream) {
    string[] localFiles;
    foreach (root; [sourceRoot, testRoot])
        foreach (entry; dirEntries(root, SpanMode.depth))
            if (entry.isFile && extension(entry.name) == ".d") localFiles ~= entry.name;
    JSONValue[] rows;
    long overlapCount;
    foreach (c; cases) {
        JSONValue row;
        row["id"] = c.id;
        JSONValue[] local, reference;
        const literal = JSONValue(c.input).toString();
        foreach (path; localFiles)
            if (readText(path).canFind(literal)) local ~= JSONValue(path);
        foreach (path; upstream) {
            foreach (item; parseJSON(readText(path)).array) {
                foreach (key, value; item.object) {
                    if (value.type == JSONType.string && value.str == c.input) {
                        JSONValue hit;
                        hit["file"] = path;
                        hit["field"] = key;
                        reference ~= hit;
                    }
                }
            }
        }
        row["local_literal_matches"] = JSONValue(local);
        row["f01_input_matches"] = JSONValue(reference);
        overlapCount += cast(long)(local.length + reference.length);
        rows ~= row;
    }
    JSONValue result;
    result["schema"] = "scrubbed-held-out-overlap-audit-v1";
    result["cases_checked"] = cast(long) cases.length;
    result["overlap_count"] = overlapCount;
    result["gate_passed"] = overlapCount == 0;
    result["rows"] = JSONValue(rows);
    return result;
}

int main(string[] args) {
    try {
        if (args.length == 2 && args[1] == "--digest") {
            writeln(corpusDigest(cases));
            return 0;
        }
        if (args.length == 8 && args[1] == "--audit-overlap") {
            auto report = auditOverlap(args[2], args[3], args[4 .. $]);
            writeln(report.toString());
            return report["gate_passed"].boolean ? 0 : 1;
        }
        if (args.length == 2 && args[1] == "--self-test") {
            selfTest();
            writeln("self-test passed");
            return 0;
        }
        if (args.length == 2 && args[1] == "--inject-hash-mismatch") {
            validateCorpus(cases, "0000");
            return 0;
        }
        if (args.length == 2 && args[1] == "--inject-miss") {
            validateCorpus(cases, pinnedDigest);
            auto report = score(cases, (Fix f, string s) => s);
            writeln(report.toString());
            return report["gate_passed"].boolean ? 0 : 1;
        }
        if (args.length == 2 && args[1] == "--inject-false-positive") {
            validateCorpus(cases, pinnedDigest);
            auto report = score(cases, (Fix f, string s) => s == "Français" ? "edited" : applyFix(f, s));
            writeln(report.toString());
            return report["gate_passed"].boolean ? 0 : 1;
        }
        if (args.length != 1) return 2;
        validateCorpus(cases, pinnedDigest);
        auto report = score(cases, (Fix f, string s) => applyFix(f, s));
        writeln(report.toString());
        return report["gate_passed"].boolean ? 0 : 1;
    } catch (Exception error) {
        stderr.writeln(error.msg);
        return 2;
    }
}
