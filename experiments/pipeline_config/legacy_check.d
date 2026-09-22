/// Actual-binary compatibility pins for the pre-v3 filter configuration edge.
module experiments.pipeline_config.legacy_check;

import std.file : exists, mkdir, readText, rmdirRecurse, tempDir, write;
import std.json : JSONValue;
import std.path : buildPath;
import std.process : execute;
import std.stdio : writeln;
import std.uuid : randomUUID;

private void need(bool condition, string message) {
    if (!condition) throw new Exception("legacy pipeline config: " ~ message);
}

private int invoke(string executable, string verb, string input, string output,
        string[] selection = null) {
    return execute([executable, verb, "--input", input, "--output", output,
        "--threads", "1"] ~ selection).status;
}

private int run(string executable, string input, string output,
        string[] selection = null) {
    return invoke(executable, "run", input, output, selection);
}

private string filterConfig(string[] entries) {
    JSONValue[] filters;
    foreach (entry; entries) filters ~= JSONValue(entry);
    return JSONValue(["filters": JSONValue(filters)]).toString;
}

void main(string[] args) {
    need(args.length == 2, "usage: legacy_check <release executable>");
    auto executable = args[1];
    auto root = buildPath(tempDir(), "scrubbed-pipeline-config-" ~
        randomUUID().toString);
    mkdir(root);
    scope(exit) if (exists(root)) rmdirRecurse(root);

    auto input = buildPath(root, "input.txt");
    auto cliOutput = buildPath(root, "cli.txt");
    auto jsonOutput = buildPath(root, "json.txt");
    auto config = buildPath(root, "filters.json");

    // Omitting both selectors is a distinct, supported compatibility form.
    // Pin it through both shipping command names rather than relying on the
    // in-process parser tests.
    auto defaultRunOutput = buildPath(root, "default-run.txt");
    auto defaultRepairOutput = buildPath(root, "default-repair.txt");
    write(input, "A\r\nB\0\n");
    need(run(executable, input, defaultRunOutput) == 0 &&
        readText(defaultRunOutput) == "A\nB\n",
        "run default filter chain changed");
    need(invoke(executable, "repair", input, defaultRepairOutput) == 0 &&
        readText(defaultRepairOutput) == readText(defaultRunOutput),
        "repair default filter chain changed");

    write(input, "l’humanitÃ©\r\nA\0&amp;\n");
    auto names = ["uncurl-quotes", "fix-mojibake", "decode-html-entities",
        "normalize-line-endings", "strip-control"];
    need(run(executable, input, cliOutput, ["--filters", names.join(",")]) == 0,
        "ordered CLI chain failed");
    write(config, filterConfig(names));
    need(run(executable, input, jsonOutput, ["--config", config]) == 0,
        "ordered v1 JSON chain failed");
    need(readText(cliOutput) == "l'humanité\nA&\n" &&
        readText(jsonOutput) == readText(cliOutput),
        "CLI and JSON exact output diverged");

    // Ordering is semantic: entity decoding exposes mojibake evidence only
    // when it precedes repair.
    write(input, "&Atilde;&copy;");
    write(config, filterConfig(["decode-html-entities", "fix-mojibake"]));
    need(run(executable, input, jsonOutput, ["--config", config]) == 0 &&
        readText(jsonOutput) == "é", "declared forward order changed");
    write(config, filterConfig(["fix-mojibake", "decode-html-entities"]));
    need(run(executable, input, jsonOutput, ["--config", config]) == 0 &&
        readText(jsonOutput) == "Ã©", "declared reverse order changed");

    // Numeric option values are accepted at the v1 JSON edge and converted
    // for the registry-owned option factory.
    write(input, "FranÃƒÂ§ais");
    write(config, `{"filters":[{"name":"fix-mojibake","options":` ~
        `{"encodings":"latin1,cp1252","max-passes":1}}]}`);
    need(run(executable, input, jsonOutput, ["--config", config]) == 0 &&
        readText(jsonOutput) == "FranÃ§ais", "max-passes=1 behavior changed");
    write(config, `{"filters":[{"name":"fix-mojibake","options":` ~
        `{"encodings":"latin1,cp1252","max-passes":2}}]}`);
    need(run(executable, input, jsonOutput, ["--config", config]) == 0 &&
        readText(jsonOutput) == "Français", "max-passes=2 behavior changed");

    // `encodings` changes candidate eligibility; it is not merely accepted.
    write(input, "donâ€™t");
    write(config, `{"filters":[{"name":"fix-mojibake","options":` ~
        `{"encodings":"latin1"}}]}`);
    need(run(executable, input, jsonOutput, ["--config", config]) == 0 &&
        readText(jsonOutput) == "donâ€™t", "latin1-only behavior changed");
    write(config, `{"filters":[{"name":"fix-mojibake","options":` ~
        `{"encodings":"cp1252"}}]}`);
    need(run(executable, input, jsonOutput, ["--config", config]) == 0 &&
        readText(jsonOutput) == "don’t", "cp1252-only behavior changed");

    // Invalid configuration must fail before destination mutation. Cover an
    // existing destination and a destination that does not yet exist.
    auto prior = buildPath(root, "prior.txt");
    auto absent = buildPath(root, "absent.txt");
    write(prior, "sentinel");
    write(config, `{"filters":[{"name":"fix-mojibake",` ~
        `"options":{"unknown":1}}]}`);
    need(run(executable, input, prior, ["--config", config]) == 2 &&
        readText(prior) == "sentinel", "unknown option mutated destination");
    need(run(executable, input, absent, ["--config", config]) == 2 &&
        !exists(absent), "unknown option created destination");
    write(config, `{"filters":[{"name":"fix-mojibake",` ~
        `"options":{"max-passes":"bad"}}]}`);
    need(run(executable, input, prior, ["--config", config]) == 2 &&
        readText(prior) == "sentinel", "malformed option mutated destination");
    need(run(executable, input, absent, ["--config", config]) == 2 &&
        !exists(absent), "malformed option created destination");
    write(config, `{"filters":[{"name":"missing-filter"}]}`);
    need(run(executable, input, prior, ["--config", config]) == 2 &&
        readText(prior) == "sentinel", "unknown filter mutated destination");
    write(config, `{"filters":[],"unexpected":true}`);
    need(run(executable, input, prior, ["--config", config]) == 2 &&
        readText(prior) == "sentinel", "unknown root key mutated destination");
    write(config, `{"filters":[{"name":"strip-control","unexpected":true}]}`);
    need(run(executable, input, absent, ["--config", config]) == 2 &&
        !exists(absent), "unknown entry key created destination");
    write(config, `{"filters":[`);
    need(run(executable, input, prior, ["--config", config]) == 2 &&
        readText(prior) == "sentinel", "malformed JSON mutated destination");
    write(config, filterConfig(["strip-control"]));
    need(run(executable, input, prior,
        ["--config", config, "--filters", "strip-control"]) == 2 &&
        readText(prior) == "sentinel", "ambiguous selectors mutated destination");

    writeln("legacy pipeline config: defaults, order, options, and rejection pins passed");
}

private import std.array : join;
