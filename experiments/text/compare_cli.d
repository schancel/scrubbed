// Read untouched benchmarks/external_comparator.d reports and print
// quality-matched samples for the pinned mojibake/scrubbed-vs-ftfy case.
// This targets the scrubbed-external-comparator-v1 report shape; it does
// not read the retired scrubbed-cli-baseline-v1 (A00) shape, which this
// report format intentionally does not stay compatible with.
import std.exception : enforce;
import std.file : readText;
import std.json : JSONValue, parseJSON;
import std.stdio : write, writeln;

void main(string[] args) {
    enforce(args.length >= 3, "usage: compare_cli base.json candidate.json [more.json ...]");
    const before = parseJSON(readText(args[1]));
    enforce(before["schema"].str == "scrubbed-external-comparator-v1",
        "unexpected schema; this reads the current external comparator report only");
    JSONValue oldCase = findCase(before, "mojibake/scrubbed-vs-ftfy");
    writeln("fixture_sha256=", oldCase["fixture_sha256"].str);
    writeln("expected_sha256=", oldCase["expected_sha256"].str);
    writeln("harness_sha256=", before["harness_sha256"].str);
    foreach (path; args[1 .. $]) {
        const run = parseJSON(readText(path));
        enforce(run["schema"].str == "scrubbed-external-comparator-v1",
            path ~ ": unexpected schema");
        auto report = findCase(run, "mojibake/scrubbed-vs-ftfy");
        enforce(before["harness_sha256"].str == run["harness_sha256"].str,
            path ~ ": harness hash mismatch");
        enforce(oldCase["fixture_sha256"].str == report["fixture_sha256"].str,
            path ~ ": fixture hash mismatch");
        enforce(oldCase["expected_sha256"].str == report["expected_sha256"].str,
            path ~ ": expected hash mismatch");
        enforce(report["samples"].array.length == 4, path ~ ": expected four A/B/A/B samples");
        writeln(path, " scrubbed_binary_sha256=", report["scrubbed_binary_sha256"].str,
            " ftfy_binary_sha256=", report["ftfy_binary_sha256"].str);
        foreach (sample; report["samples"].array) {
            enforce(sample["status"].integer == 0, path ~ ": subprocess failed or was signaled");
            enforce(sample["exact_output"].boolean, path ~ ": exact-output gate failed");
            enforce(sample["output_sha256"].str == report["expected_sha256"].str,
                path ~ ": output hash mismatch");
            write(" tool=", sample["tool"].str, " wall=", sample["wall_seconds"].floating,
                " cpu=", sample["user_seconds"].floating +
                    sample["system_seconds"].floating);
        }
        writeln();
    }
}

private JSONValue findCase(JSONValue report, string name) {
    foreach (c; report["cases"].array)
        if (c["name"].str == name) return c;
    throw new Exception("missing case: " ~ name);
}
