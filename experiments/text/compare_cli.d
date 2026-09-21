// Read two untouched A00 harness reports and print quality-matched samples.
import std.file : readText;
import std.json : parseJSON;
import std.stdio : write, writeln;

void main(string[] args) {
    assert(args.length == 3, "usage: compare_cli before.json after.json");
    const before = parseJSON(readText(args[1]));
    const after = parseJSON(readText(args[2]));
    assert(before["harness_sha256"].str == after["harness_sha256"].str);
    const oldCase = before["cases"].array[0];
    const newCase = after["cases"].array[0];
    assert(oldCase["name"].str == "mojibake/scrubbed");
    assert(newCase["name"].str == oldCase["name"].str);
    assert(oldCase["input_sha256"].str == newCase["input_sha256"].str);
    assert(oldCase["expected_sha256"].str == newCase["expected_sha256"].str);
    assert(oldCase["exact_output"].boolean && newCase["exact_output"].boolean);
    writeln("input_sha256=", oldCase["input_sha256"].str);
    writeln("expected_sha256=", oldCase["expected_sha256"].str);
    foreach (label, report; [oldCase, newCase]) {
        write(label == 0 ? "base" : "candidate", " wall_seconds=");
        foreach (sample; report["samples"].array) {
            assert(sample["status"].integer == 0);
            assert(sample["output_sha256"].str == report["expected_sha256"].str);
            write(" ", sample["wall_seconds"].floating);
        }
        writeln();
    }
}
