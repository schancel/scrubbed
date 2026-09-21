// Read two untouched A00 harness reports and print quality-matched samples.
import std.file : readText;
import std.json : parseJSON;
import std.stdio : write, writeln;

void main(string[] args) {
    assert(args.length >= 3, "usage: compare_cli base.json candidate.json [more.json ...]");
    const before = parseJSON(readText(args[1]));
    const oldCase = before["cases"].array[0];
    assert(oldCase["name"].str == "mojibake/scrubbed");
    writeln("input_sha256=", oldCase["input_sha256"].str);
    writeln("expected_sha256=", oldCase["expected_sha256"].str);
    writeln("harness_sha256=", before["harness_sha256"].str);
    foreach (path; args[1 .. $]) {
        const run = parseJSON(readText(path));
        const report = run["cases"].array[0];
        assert(before["harness_sha256"].str == run["harness_sha256"].str);
        assert(report["name"].str == oldCase["name"].str);
        assert(oldCase["input_sha256"].str == report["input_sha256"].str);
        assert(oldCase["expected_sha256"].str == report["expected_sha256"].str);
        assert(report["exact_output"].boolean);
        writeln(path, " binary_sha256=", run["scrubbed_binary_sha256"].str);
        foreach (sample; report["samples"].array) {
            assert(sample["status"].integer == 0);
            assert(sample["output_sha256"].str == report["expected_sha256"].str);
            write(" wall=", sample["wall_seconds"].floating,
                " cpu=", sample["user_seconds"].floating +
                    sample["system_seconds"].floating);
        }
        writeln();
    }
}
