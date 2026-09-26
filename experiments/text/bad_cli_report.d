// Create one deliberately corrupted scrubbed-external-comparator-v1 JSON
// report for a release-mode negative-control probe. This targets the
// current external comparator report shape, not the retired
// scrubbed-cli-baseline-v1 (A00) shape.
import std.exception : enforce;
import std.file : readText, write;
import std.json : JSONValue, parseJSON;

void main(string[] args) {
    enforce(args.length == 4,
        "usage: bad_cli_report good.json bad.json harness|fixture|expected|case|exact|" ~
        "count|status|output|tool-order|acquisition-order|duplicate-case");
    auto report = parseJSON(readText(args[1]));
    auto cases = report["cases"].array;
    size_t index;
    while (index < cases.length && cases[index]["name"].str != "mojibake/scrubbed-vs-ftfy")
        index++;
    enforce(index < cases.length, "missing mojibake/scrubbed-vs-ftfy case in " ~ args[1]);
    auto first = cases[index];
    auto samples = first["samples"].array;
    final switch (args[3]) {
        case "harness": report["harness_sha256"] = "wrong"; break;
        case "fixture": first["fixture_sha256"] = "wrong"; break;
        case "expected": first["expected_sha256"] = "wrong"; break;
        case "case": first["name"] = "wrong"; break;
        case "exact":
            samples[0]["exact_output"] = false;
            first["samples"] = JSONValue(samples);
            break;
        case "count": first["samples"] = JSONValue(samples[0 .. 3]); break;
        case "status":
            samples[0]["status"] = 7;
            first["samples"] = JSONValue(samples);
            break;
        case "output":
            samples[0]["output_sha256"] = "wrong";
            first["samples"] = JSONValue(samples);
            break;
        case "tool-order":
            samples[0]["tool"] = "ftfy";
            samples[1]["tool"] = "scrubbed";
            first["samples"] = JSONValue(samples);
            break;
        case "acquisition-order":
            first["python_packages_acquisition_order"] =
                JSONValue(["wcwidth==0.8.4", "ftfy==6.3.1"]);
            break;
        case "duplicate-case":
            cases ~= first;
            report["cases"] = JSONValue(cases);
            write(args[2], report.toString);
            return;
    }
    cases[index] = first;
    report["cases"] = JSONValue(cases);
    write(args[2], report.toString);
}
