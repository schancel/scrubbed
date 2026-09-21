// Read untouched A00 harness reports and print quality-matched samples.
import std.exception : enforce;
import std.file : readText;
import std.json : parseJSON;
import std.stdio : write, writeln;

void main(string[] args) {
    enforce(args.length >= 3, "usage: compare_cli base.json candidate.json [more.json ...]");
    const before = parseJSON(readText(args[1]));
    const oldCase = before["cases"].array[0];
    enforce(oldCase["name"].str == "mojibake/scrubbed", "unexpected base case");
    writeln("input_sha256=", oldCase["input_sha256"].str);
    writeln("expected_sha256=", oldCase["expected_sha256"].str);
    writeln("harness_sha256=", before["harness_sha256"].str);
    foreach (path; args[1 .. $]) {
        const run = parseJSON(readText(path));
        const report = run["cases"].array[0];
        enforce(before["harness_sha256"].str == run["harness_sha256"].str,
            path ~ ": harness hash mismatch");
        enforce(report["name"].str == oldCase["name"].str, path ~ ": case mismatch");
        enforce(oldCase["input_sha256"].str == report["input_sha256"].str,
            path ~ ": input hash mismatch");
        enforce(oldCase["expected_sha256"].str == report["expected_sha256"].str,
            path ~ ": expected hash mismatch");
        enforce(report["exact_output"].boolean, path ~ ": exact-output gate failed");
        enforce(report["samples"].array.length == 5, path ~ ": expected five samples");
        writeln(path, " binary_sha256=", run["scrubbed_binary_sha256"].str);
        foreach (sample; report["samples"].array) {
            enforce(sample["status"].integer == 0, path ~ ": subprocess failed");
            enforce(sample["output_sha256"].str == report["expected_sha256"].str,
                path ~ ": output hash mismatch");
            write(" wall=", sample["wall_seconds"].floating,
                " cpu=", sample["user_seconds"].floating +
                    sample["system_seconds"].floating);
        }
        writeln();
    }
}
