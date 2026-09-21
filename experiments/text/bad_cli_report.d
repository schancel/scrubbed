// Create one deliberately corrupted A00 JSON report for a release-mode probe.
import std.exception : enforce;
import std.file : readText, write;
import std.json : JSONValue, parseJSON;

void main(string[] args) {
    enforce(args.length == 4,
        "usage: bad_cli_report good.json bad.json harness|input|expected|case|exact|count|status|output");
    auto report = parseJSON(readText(args[1]));
    auto cases = report["cases"].array;
    auto first = cases[0];
    auto samples = first["samples"].array;
    final switch (args[3]) {
        case "harness": report["harness_sha256"] = "wrong"; break;
        case "input": first["input_sha256"] = "wrong"; break;
        case "expected": first["expected_sha256"] = "wrong"; break;
        case "case": first["name"] = "wrong"; break;
        case "exact": first["exact_output"] = false; break;
        case "count": first["samples"] = JSONValue(samples[0 .. 4]); break;
        case "status":
            samples[0]["status"] = 7;
            first["samples"] = JSONValue(samples);
            break;
        case "output":
            samples[0]["output_sha256"] = "wrong";
            first["samples"] = JSONValue(samples);
            break;
    }
    cases[0] = first;
    report["cases"] = JSONValue(cases);
    write(args[2], report.toString);
}
