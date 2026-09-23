/// Actual-release-binary equivalence checks for the Stage 5a local switch.
module experiments.pipeline_config.shipping_check;

import std.file : exists, mkdir, readText, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.process : Redirect, execute, pipeProcess, wait;
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

    write(config, "");
    write(prior, "sentinel");
    need(run(executable, input, prior, ["--config", config]) == 2 &&
        readText(prior) == "sentinel",
        "explicit empty config selected defaults or mutated destination");

    // A directory sorts at its normalized relative prefix, not merely before
    // every sibling. `a.txt` must fail before traversal can publish `a/z.txt`.
    auto lexicalInput = buildPath(root, "lexical-input");
    auto lexicalDirectory = buildPath(lexicalInput, "a");
    auto lexicalOutput = buildPath(root, "lexical-output");
    mkdir(lexicalInput);
    mkdir(lexicalDirectory);
    write(buildPath(lexicalDirectory, "z.txt"), "valid\r\n");
    write(buildPath(lexicalInput, "a.txt"), [cast(ubyte) 0xff]);
    auto lexical = execute([executable, "run", "--input", lexicalInput,
        "--output", lexicalOutput, "--threads", "1"]);
    need(lexical.status == 2 &&
        !exists(buildPath(lexicalOutput, "a", "z.txt")),
        "tree publication did not follow global relative lexical order");

    // A later fast fatal root must wait behind the same canonical committed
    // prefix regardless of worker count.
    auto orderedInput = buildPath(root, "ordered-input");
    auto serialOutput = buildPath(root, "ordered-serial");
    auto parallelOutput = buildPath(root, "ordered-parallel");
    mkdir(orderedInput);
    auto large = new char[6 * 1024 * 1024];
    large[] = 'x';
    write(buildPath(orderedInput, "a.txt"), large);
    write(buildPath(orderedInput, "z.txt"), [cast(ubyte) 0xff]);
    write(buildPath(orderedInput, "zz.txt"), "later");
    write(buildPath(orderedInput, "zzz.txt"), "later still");
    auto serial = execute([executable, "run", "--input", orderedInput,
        "--output", serialOutput, "--threads", "1", "--max-open-inputs", "4",
        "--explain"]);
    auto parallel = execute([executable, "run", "--input", orderedInput,
        "--output", parallelOutput, "--threads", "4", "--max-open-inputs", "4",
        "--explain"]);
    need(serial.status == 2 && parallel.status == 2 &&
        exists(buildPath(serialOutput, "a.txt")) &&
        exists(buildPath(parallelOutput, "a.txt")) &&
        readText(buildPath(serialOutput, "a.txt")) ==
            readText(buildPath(parallelOutput, "a.txt")) &&
        serial.output.canFind("effect stage failure") &&
        parallel.output.canFind("effect stage failure") &&
        serial.output.canFind("status=canceled") &&
        parallel.output.canFind("status=canceled") &&
        !serial.output.canFind("input admission canceled") &&
        !parallel.output.canFind("input admission canceled"),
        "fatal publication prefix changed with worker count");

    auto jsonl = pipeProcess([executable, "run", "--input", "-", "--output", "-",
        "--jsonl-fields", "text", "--dataset-namespace", "d", "--source-key", "s",
        "--max-jsonl-line-bytes", "1024", "--max-jsonl-output-bytes", "2048"] ~
        tokens, Redirect.stdin | Redirect.stdout);
    jsonl.stdin.rawWrite(cast(const(ubyte)[])
        "{\"text\":\"l’humanitÃ©\\r\\nA\\u0000&amp;\"}\n");
    jsonl.stdin.close();
    string jsonlOutput;
    foreach (line; jsonl.stdout.byLineCopy()) jsonlOutput ~= line ~ "\n";
    need(wait(jsonl.pid) == 0 &&
        jsonlOutput == "{\"text\":\"l'humanité\\nA&\"}\n",
        "v3 JSONL exact output diverged");

    writeln("shipping pipeline config: CLI/JSON, preflight, and ordered failure passed");
}

private import std.algorithm.searching : canFind;
