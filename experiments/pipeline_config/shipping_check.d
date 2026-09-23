/// Actual-release-binary equivalence checks for the Stage 5a local switch.
module experiments.pipeline_config.shipping_check;

import std.file : exists, mkdir, readText, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.process : execute;
import std.stdio : writeln;
import std.uuid : randomUUID;

private void need(bool condition, string message) {
    if (!condition) throw new Exception("shipping pipeline config: " ~ message);
}

private int run(string executable, string input, string output, string[] selected) {
    return execute([executable, "run", "--input", input, "--output", output,
        "--threads", "2"] ~ selected).status;
}

void main(string[] args) {
    need(args.length == 2, "usage: shipping_check <release executable>");
    auto executable = args[1];
    auto root = buildPath(tempDir, "scrubbed-shipping-" ~ randomUUID.toString);
    mkdir(root);
    scope(exit) if (exists(root)) rmdirRecurse(root);

    auto input = buildPath(root, "input.txt");
    auto cliOutput = buildPath(root, "cli.txt");
    auto jsonOutput = buildPath(root, "json.txt");
    auto same = buildPath(root, "same.txt");
    auto config = buildPath(root, "job.json");
    write(input, "l’humanitÃ©\r\nA\0&amp;\n");
    auto tokens = [
        "--stage", "clean=text-transform",
        "--filter", "uncurl-quotes",
        "--filter", "fix-mojibake",
        "--filter", "decode-html-entities",
        "--filter", "normalize-line-endings",
        "--filter", "strip-control"
    ];
    write(config, `{"version":3,"stages":[{"id":"clean",` ~
        `"implementation":"text-transform","options":{},"filters":[` ~
        `{"name":"uncurl-quotes","options":{}},` ~
        `{"name":"fix-mojibake","options":{}},` ~
        `{"name":"decode-html-entities","options":{}},` ~
        `{"name":"normalize-line-endings","options":{}},` ~
        `{"name":"strip-control","options":{}}]}]}`);
    need(run(executable, input, cliOutput, tokens) == 0,
        "ordered CLI job failed");
    need(run(executable, input, jsonOutput, ["--config", config]) == 0,
        "v3 JSON job failed");
    need(readText(cliOutput) == "l'humanité\nA&\n" &&
        readText(cliOutput) == readText(jsonOutput),
        "CLI/JSON exact output diverged");

    write(same, "same\r\n");
    need(run(executable, same, same,
        ["--stage", "clean=text-transform", "--filter",
         "normalize-line-endings"]) == 0 && readText(same) == "same\n",
        "same-file compiled publication failed");

    auto prior = buildPath(root, "prior.txt");
    write(prior, "sentinel");
    write(config, `{"version":3,"stages":[{"id":"bad",` ~
        `"implementation":"missing","options":{},"filters":[]}]}`);
    need(run(executable, input, prior, ["--config", config]) == 2 &&
        readText(prior) == "sentinel", "compile failure mutated destination");
    need(run(executable, input, prior,
        ["--stage-option", "x=text:y"]) == 2 &&
        readText(prior) == "sentinel", "orphan option mutated destination");

    auto jsonl = execute([executable, "run", "--input", "-", "--output", "-",
        "--jsonl-fields", "text", "--dataset-namespace", "d", "--source-key", "s",
        "--max-jsonl-line-bytes", "10", "--max-jsonl-output-bytes", "20"] ~ tokens);
    need(jsonl.status == 2 && jsonl.output.canFind("not migrated"),
        "v3 JSONL route was not refused");

    writeln("shipping pipeline config: CLI/JSON, same-file, and preflight passed");
}

private import std.algorithm.searching : canFind;
