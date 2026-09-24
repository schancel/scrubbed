/// Release-active executable checks: compile with ldc2 -O, then pass scrubbed.
module cli_check;

import std.algorithm.searching : canFind;
import std.array : replicate;
import std.conv : to;
import std.digest : LetterCase, toHexString;
import std.digest.sha : SHA256, sha256Of;
import std.file : SpanMode, copy, dirEntries, exists, getAttributes, mkdir,
    mkdirRecurse, readText, rmdirRecurse, setAttributes, symlink, tempDir, write;
import std.json : parseJSON;
import std.path : absolutePath, baseName, buildNormalizedPath, buildPath;
import std.process : Redirect, execute, pipeProcess, wait;
import std.string : replace, split, splitLines, startsWith;
import std.uuid : randomUUID;

private void check(bool condition, string label) {
    if (!condition) throw new Exception("CLI golden: " ~ label);
}

private string posixQuoted(string value) {
    string quoted = "'";
    foreach (character; value) {
        if (character == '\'') quoted ~= "'\\''";
        else quoted ~= character;
    }
    return quoted ~ "'";
}

private string fishQuoted(string value) {
    string quoted = "'";
    foreach (character; value) {
        if (character == '\'' || character == '\\') quoted ~= '\\';
        quoted ~= character;
    }
    return quoted ~ "'";
}

private struct Captured {
    int status;
    string output;
    string error;
}

private Captured separately(string[] command) {
    auto pipes = pipeProcess(command, Redirect.stdout | Redirect.stderr);
    Captured result;
    foreach (line; pipes.stdout.byLineCopy) result.output ~= line ~ "\n";
    foreach (line; pipes.stderr.byLineCopy) result.error ~= line ~ "\n";
    result.status = pipes.pid.wait();
    return result;
}

private Captured withInput(string[] command, string input) {
    auto pipes = pipeProcess(command, Redirect.all);
    pipes.stdin.write(input);
    pipes.stdin.close();
    Captured result;
    foreach (line; pipes.stdout.byLineCopy) result.output ~= line ~ "\n";
    foreach (line; pipes.stderr.byLineCopy) result.error ~= line ~ "\n";
    result.status = pipes.pid.wait();
    return result;
}

private string[] dispatchRecords(Captured result) {
    string[] records;
    foreach (line; (result.output ~ result.error).splitLines()) {
        if (!line.startsWith("EXPLAIN\t{")) continue;
        auto record = line["EXPLAIN\t".length .. $];
        parseJSON(record);
        records ~= record;
    }
    return records;
}

private string dispatchRecord(Captured result) {
    auto records = dispatchRecords(result);
    check(records.length == 1, "exactly one dispatch explain record");
    return records[0];
}

private string expectedJsonlUnit(string documentId, size_t ordinal) {
    SHA256 digest;
    digest.put(cast(const(ubyte)[]) "scrubbed.dispatch.unit.v1\0");
    digest.put(cast(const(ubyte)[]) documentId);
    digest.put([cast(ubyte) 0]);
    digest.put(cast(const(ubyte)[]) "jsonl-field:v1:");
    digest.put(cast(const(ubyte)[]) ordinal.to!string);
    return "unit:v1:" ~ toHexString!(LetterCase.lower)(digest.finish()).idup;
}

private string rawNameDictionaryGuess(string documentId, string field) {
    SHA256 digest;
    digest.put(cast(const(ubyte)[]) "scrubbed.dispatch.unit.v1\0");
    digest.put(cast(const(ubyte)[]) documentId);
    digest.put([cast(ubyte) 0]);
    digest.put(cast(const(ubyte)[]) field);
    return "unit:v1:" ~ toHexString!(LetterCase.lower)(digest.finish()).idup;
}

int main(string[] args) {
    check(args.length == 2, "usage: check <release executable>");
    auto exe = args[1];
    auto root = buildPath(tempDir, "scrubbed-commands-" ~ randomUUID.toString);
    mkdir(root);
    scope(exit) if (exists(root)) rmdirRecurse(root);

    auto rootHelp = execute([exe, "--help"]);
    check(rootHelp.status == 0, "root help exit");
    check(rootHelp.output ==
        "Usage: scrubbed [-h] <command> [<args>]\n\n" ~
        "Sanitize text through a bounded filter pipeline.\n\n" ~
        "Available commands:\n" ~
        "  run,clean         Run the bounded filter pipeline (also the no-verb default).\n" ~
        "  repair,fix        Repair text with the existing filter pipeline.\n" ~
        "  extract,x         Export a bounded selected HTML parse tree or Markdown.\n" ~
        "  completion        Generate shell setup or command/option-name candidates; use\n" ~
        "                    completion init --bash, --zsh or --fish.\n" ~
        "  errors-init       Create a new opt-in v3 error journal.\n" ~
        "  errors-copy       Copy an existing v1 journal to a new v2 journal.\n" ~
        "  errors-export     Export a bounded v2 or v3 journal snapshot.\n" ~
        "  errors-verify     Verify exported JSONL and digest sidecars.\n" ~
        "  route-metadata    Route local HTML content and stage metadata to independent\n" ~
        "                    sinks.\n\n" ~
        "Optional arguments:\n" ~
        "  -h, --help        Show this help message and exit\n\n", "root help golden");
    foreach (verb; ["run", "clean", "repair", "fix", "extract", "x", "completion"]) {
        auto help = execute([exe, verb, "--help"]);
        auto canonical = verb == "clean" ? "run" : verb == "fix" ? "repair" :
            verb == "x" ? "extract" : verb;
        check(help.status == 0 && help.output.startsWith("Usage: scrubbed " ~ canonical ~ " "),
            verb ~ " help");
    }
    auto completionHelp = execute([exe, "completion", "--help"]);
    check(completionHelp.status == 0 && completionHelp.output ==
        "Usage: scrubbed completion [-h] <operation> [<args>]\n\n" ~
        "Generate shell setup or command/option-name candidates.\n\n" ~
        "Operations:\n" ~
        "  init --bash|--zsh|--fish\n" ~
        "      Print initialization script for the selected shell.\n" ~
        "  complete --bash|--zsh|--fish -- <tokens>\n" ~
        "      Print command and option name candidates.\n\n" ~
        "Optional arguments:\n" ~
        "  -h, --help    Show this help message and exit\n\n",
        "completion help golden");
    auto list = execute([exe, "--list-filters"]);
    check(list.status == 0 && list.output ==
        "registered filters: fix-mojibake, strip-control, decode-html-entities, uncurl-quotes, normalize-line-endings\n",
        "legacy list golden");
    auto missing = execute([exe]);
    check(missing.status == 2 &&
        missing.output == "--input and --output are required (--list-filters to see what's available)\n",
        "legacy missing paths golden");
    foreach (bad; [["--unknown"], ["--FILTERS", "x"], ["run", "--threads", "bad"],
                   ["repair", "--max-open-inputs", "bad"], ["completion", "bogus"]]) {
        auto result = execute([exe] ~ bad);
        check(result.status == 2 && result.output.length != 0,
            "invalid/typed option " ~ bad[0]);
    }

    auto input = buildPath(root, "input.txt");
    auto output = buildPath(root, "output.txt");
    write(input, "line\r\n");
    foreach (verb; ["", "run", "clean", "repair", "fix"]) {
        string[] command = [exe];
        if (verb.length) command ~= verb;
        command ~= ["--input", input, "--output", output,
            "--threads", "1", "--filters", "normalize-line-endings"];
        auto result = execute(command);
        check(result.status == 0 && result.output.canFind("done. 1 succeeded, 0 failed."),
            verb ~ " processing");
        check(readText(output) == "line\n", verb ~ " output");
    }
    auto conflict = execute([exe, "run", "--input", input, "--output", output,
        "--config", "x.json", "--filters", "normalize-line-endings"]);
    check(conflict.status == 2 && conflict.output.canFind("mutually exclusive"),
        "config/filter exclusivity");
    foreach (limit; [["--threads", "0"], ["--max-queued-docs", "0"],
                     ["--max-input-bytes", "0"], ["--max-open-inputs", "0"]]) {
        auto result = execute([exe, "run", "--input", input, "--output", output] ~ limit);
        check(result.status == 2, "resource guard " ~ limit[0]);
    }
    auto linkedInput = buildPath(root, "linked-input.txt");
    symlink(input, linkedInput);
    auto linkedResult = execute([exe, "repair", "--input", linkedInput,
        "--output", output]);
    check(linkedResult.status == 2 && linkedResult.output.canFind("symlink input root"),
        "input symlink guard");
    auto invalid = buildPath(root, "invalid.bin");
    auto invalidOutput = buildPath(root, "invalid-output.txt");
    write(invalid, [cast(ubyte) 0xFF]);
    auto failedFile = execute([exe, "run", "--input", invalid,
        "--output", invalidOutput, "--threads", "1"]);
    check(failedFile.status == 2 && failedFile.output.canFind("FATAL") &&
        !exists(invalidOutput), "no-manifest worker failure exits fatal 2");
    auto dryOutput = buildPath(root, "dry", "output.txt");
    auto dry = execute([exe, "repair", "--input", input, "--output", dryOutput,
        "--dry-run", "--explain", "--threads", "1"]);
    check(dry.status == 0 && dry.output.canFind("EXPLAIN\t") &&
        !exists(dryOutput), "dry-run/explain no output");
    auto validate = execute([exe, "run", "--input", input, "--output", dryOutput,
        "--validate"]);
    check(validate.status == 0 && validate.output.canFind("valid. No files processed.") &&
        !exists(dryOutput), "validate no output");
    auto dispatchOutput = buildPath(root, "dispatch.txt");
    auto dispatch = separately([exe, "run", "--input", input,
        "--output", dispatchOutput, "--threads", "1", "--explain",
        "--config", "scrubbed.dispatch.example.json"]);
    check(dispatch.status == 0 && readText(dispatchOutput) == "line\r\n" &&
        dispatch.output.canFind("job: job:v4:") &&
        dispatch.output.canFind("EXPLAIN\t{\"schema\":\"scrubbed.dispatch.v1\"") &&
        !dispatch.output.canFind(input), "shipping dispatch v4 config/explain");

    // Both local transports must expose the same structured dispatch failure,
    // even though a non-durable worker failure remains exit 2 and a recorded
    // durable root failure remains exit 1.
    auto cappedConfig = buildPath(root, "dispatch-cap4.json");
    write(cappedConfig, readText("scrubbed.dispatch.example.json").replace(
        `"max-output-bytes":268435456`, `"max-output-bytes":4`));
    auto cappedInput = buildPath(root, "capped.txt");
    write(cappedInput, "hello");
    auto cappedDirectOutput = buildPath(root, "capped-direct.txt");
    auto cappedDirect = separately([exe, "run", "--input", cappedInput,
        "--output", cappedDirectOutput, "--threads", "1", "--explain",
        "--config", cappedConfig]);
    auto cappedDurableOutput = buildPath(root, "capped-durable.txt");
    auto cappedDurable = separately([exe, "run", "--input", cappedInput,
        "--output", cappedDurableOutput, "--threads", "1", "--explain",
        "--config", cappedConfig, "--manifest",
        buildPath(root, "capped.db")]);
    auto directFailureRecord = dispatchRecord(cappedDirect);
    auto durableFailureRecord = dispatchRecord(cappedDurable);
    check(cappedDirect.status == 2 && cappedDurable.status == 1 &&
        directFailureRecord == durableFailureRecord &&
        parseJSON(directFailureRecord)["outcome"].str == "plain-text" &&
        parseJSON(directFailureRecord)["phase"].str == "decode" &&
        parseJSON(directFailureRecord)["code"].str == "decode-failed" &&
        !exists(cappedDirectOutput) && !exists(cappedDurableOutput),
        "durable/direct dispatch failure record parity and exits");
    auto cappedJsonl = withInput([exe, "run", "--input", "-", "--output", "-",
        "--jsonl-fields", "text", "--dataset-namespace", "example",
        "--source-key", "cap4", "--max-jsonl-line-bytes", "1024",
        "--max-jsonl-output-bytes", "1024", "--config", cappedConfig,
        "--explain"], `{"text":"hello"}` ~ "\n");
    auto jsonlFailureRecord = dispatchRecord(cappedJsonl);
    auto directFailure = parseJSON(directFailureRecord);
    auto jsonlFailure = parseJSON(jsonlFailureRecord);
    foreach (field; ["job_identity", "status", "outcome", "action", "phase",
            "code", "reason_hash"])
        check(directFailure[field].str == jsonlFailure[field].str,
            "three-transport dispatch failure parity field " ~ field);
    check(cappedJsonl.status == 1 && cappedJsonl.output.length == 0,
        "JSONL dispatch failure has no current-record output");

    auto outputCappedJsonl = withInput([exe, "run", "--input", "-",
        "--output", "-", "--jsonl-fields",
        "alpha-secret-field,beta-secret-field", "--dataset-namespace",
        "example", "--source-key", "cap8", "--max-jsonl-line-bytes", "1024",
        "--max-jsonl-output-bytes", "8", "--config",
        "scrubbed.dispatch.example.json", "--explain"],
        `{"alpha-secret-field":"a","beta-secret-field":"b"}` ~ "\n");
    auto outputCappedRecord = parseJSON(dispatchRecord(outputCappedJsonl));
    check(outputCappedJsonl.status == 1 && outputCappedJsonl.output.length == 0 &&
        outputCappedRecord["status"].str == "failure" &&
        outputCappedRecord["phase"].str == "resource" &&
        outputCappedRecord["code"].str == "resource-failed",
        "JSONL output cap after two decisions emits one failure only");

    auto cardinalityArgs = [exe, "run", "--input", "-", "--output", "-",
        "--jsonl-fields", "alpha-secret-field,beta-secret-field",
        "--dataset-namespace", "example", "--source-key", "cardinality",
        "--max-jsonl-line-bytes", "1024", "--max-jsonl-output-bytes", "1024",
        "--config", "scrubbed.dispatch.example.json", "--explain"];
    auto noFields = withInput(cardinalityArgs, `{"other":"x"}` ~ "\n");
    auto oneField = withInput(cardinalityArgs,
        `{"alpha-secret-field":"a"}` ~ "\n");
    auto twoFields = withInput(cardinalityArgs,
        `{"alpha-secret-field":"a","beta-secret-field":"b"}` ~ "\n");
    auto oneRecords = dispatchRecords(oneField);
    auto twoRecords = dispatchRecords(twoFields);
    check(noFields.status == 0 && dispatchRecords(noFields).length == 0 &&
        oneField.status == 0 && oneRecords.length == 1 &&
        twoFields.status == 0 && twoRecords.length == 2,
        "JSONL absent/one/two selected-field record cardinality");
    auto firstUnit = parseJSON(twoRecords[0]);
    auto secondUnit = parseJSON(twoRecords[1]);
    check(firstUnit["document_id"].str == secondUnit["document_id"].str &&
        firstUnit["unit_id"].str != secondUnit["unit_id"].str &&
        firstUnit["unit_id"].str == expectedJsonlUnit(
            firstUnit["document_id"].str, 0) &&
        secondUnit["unit_id"].str == expectedJsonlUnit(
            secondUnit["document_id"].str, 1) &&
        firstUnit["unit_id"].str.startsWith("unit:v1:") &&
        !twoRecords[0].canFind("alpha-secret-field") &&
        !twoRecords[0].canFind("beta-secret-field") &&
        !twoRecords[1].canFind("alpha-secret-field") &&
        !twoRecords[1].canFind("beta-secret-field"),
        "JSONL unit IDs distinguish fields without leaking names");
    check(firstUnit["unit_id"].str != rawNameDictionaryGuess(
            firstUnit["document_id"].str, "alpha-secret-field") &&
        secondUnit["unit_id"].str != rawNameDictionaryGuess(
            secondUnit["document_id"].str, "beta-secret-field"),
        "JSONL field-name dictionary guesses cannot reproduce unit IDs");
    auto replayRecords = dispatchRecords(withInput(cardinalityArgs,
        `{"alpha-secret-field":"a","beta-secret-field":"b"}` ~ "\n"));
    check(replayRecords.length == 2 &&
        parseJSON(replayRecords[0])["unit_id"].str == firstUnit["unit_id"].str &&
        parseJSON(replayRecords[1])["unit_id"].str == secondUnit["unit_id"].str,
        "JSONL unit IDs are deterministic and replay-stable");
    auto reorderedArgs = cardinalityArgs.dup;
    foreach (ref argument; reorderedArgs)
        if (argument == "alpha-secret-field,beta-secret-field")
            argument = "beta-secret-field,alpha-secret-field";
    auto reordered = dispatchRecords(withInput(reorderedArgs,
        `{"alpha-secret-field":"a","beta-secret-field":"b"}` ~ "\n"));
    check(reordered.length == 2 &&
        parseJSON(reordered[0])["unit_id"].str == firstUnit["unit_id"].str &&
        parseJSON(reordered[1])["unit_id"].str == secondUnit["unit_id"].str &&
        parseJSON(reordered[1])["unit_id"].str != firstUnit["unit_id"].str,
        "JSONL configured reordering follows ordinal unit semantics");

    auto mixedArgs = [exe, "run", "--input", "-", "--output", "-",
        "--jsonl-fields", "alpha-secret-field,beta-secret-field",
        "--dataset-namespace", "example", "--source-key", "mixed",
        "--max-jsonl-line-bytes", "1024", "--max-jsonl-output-bytes", "1024",
        "--config", cappedConfig, "--explain"];
    auto secondFailed = withInput(mixedArgs,
        `{"alpha-secret-field":"hey","beta-secret-field":"hello"}` ~ "\n");
    auto secondFailure = parseJSON(dispatchRecord(secondFailed));
    auto secondOnly = withInput([exe, "run", "--input", "-", "--output", "-",
        "--jsonl-fields", "beta-secret-field", "--dataset-namespace", "example",
        "--source-key", "mixed", "--max-jsonl-line-bytes", "1024",
        "--max-jsonl-output-bytes", "1024", "--config", cappedConfig,
        "--explain"], `{"beta-secret-field":"hello"}` ~ "\n");
    check(secondFailed.status == 1 && secondFailed.output.length == 0 &&
        secondFailure["unit_id"].str == expectedJsonlUnit(
            secondFailure["document_id"].str, 1) &&
        secondFailure["unit_id"].str !=
            parseJSON(dispatchRecord(secondOnly))["unit_id"].str &&
        secondFailure["outcome"].str == "plain-text" &&
        secondFailure["code"].str == "decode-failed",
        "JSONL second-field failure suppresses first speculative success");

    // Filename hints are non-authoritative, but must reach detection through
    // both local transports so warnings and all other explain metadata agree.
    auto hintedInput = buildPath(root, "hinted.html");
    write(hintedInput, "hello");
    auto hintedDirectOutput = buildPath(root, "hinted-direct.txt");
    auto hintedDirect = separately([exe, "run", "--input", hintedInput,
        "--output", hintedDirectOutput, "--threads", "1", "--explain",
        "--config", "scrubbed.dispatch.example.json"]);
    auto hintedDurableOutput = buildPath(root, "hinted-durable.txt");
    auto hintedDurable = separately([exe, "run", "--input", hintedInput,
        "--output", hintedDurableOutput, "--threads", "1", "--explain",
        "--config", "scrubbed.dispatch.example.json", "--manifest",
        buildPath(root, "hinted.db")]);
    auto hintedRecord = dispatchRecord(hintedDirect);
    check(hintedDirect.status == 0 && hintedDurable.status == 0 &&
        hintedRecord == dispatchRecord(hintedDurable) &&
        hintedRecord.canFind(`"warning_codes":["untrusted-hint-conflicts-with-content"]`) &&
        sha256Of(cast(const(ubyte)[])readText(hintedDirectOutput)) ==
            sha256Of(cast(const(ubyte)[])readText(hintedDurableOutput)),
        "durable/direct misleading HTML hint and output hash parity");

    auto textControl = buildPath(root, "control.txt");
    write(textControl, "hello");
    auto textDirect = separately([exe, "run", "--input", textControl,
        "--output", buildPath(root, "text-direct.txt"), "--threads", "1",
        "--explain", "--config", "scrubbed.dispatch.example.json"]);
    auto textDurable = separately([exe, "run", "--input", textControl,
        "--output", buildPath(root, "text-durable.txt"), "--threads", "1",
        "--explain", "--config", "scrubbed.dispatch.example.json",
        "--manifest", buildPath(root, "text.db")]);
    auto textRecord = dispatchRecord(textDirect);
    check(textDirect.status == 0 && textDurable.status == 0 &&
        textRecord == dispatchRecord(textDurable) &&
        textRecord.canFind(`"warning_codes":[]`),
        "durable/direct text hint control parity");

    auto htmlControl = buildPath(root, "genuine.html");
    write(htmlControl, "<!doctype html><html><body>hello</body></html>");
    auto htmlDirectOutput = buildPath(root, "html-direct.txt");
    auto htmlDirect = separately([exe, "run", "--input", htmlControl,
        "--output", htmlDirectOutput, "--threads", "1", "--explain",
        "--config", "scrubbed.dispatch.example.json"]);
    auto htmlDurableOutput = buildPath(root, "html-durable.txt");
    auto htmlDurable = separately([exe, "run", "--input", htmlControl,
        "--output", htmlDurableOutput, "--threads", "1", "--explain",
        "--config", "scrubbed.dispatch.example.json", "--manifest",
        buildPath(root, "html.db")]);
    auto htmlRecord = dispatchRecord(htmlDirect);
    check(htmlDirect.status == 1 && htmlDurable.status == 1 &&
        htmlRecord == dispatchRecord(htmlDurable) &&
        parseJSON(htmlRecord)["outcome"].str == "html" &&
        htmlRecord.canFind(`"warning_codes":[]`) &&
        !exists(htmlDirectOutput) && !exists(htmlDurableOutput),
        "durable/direct genuine HTML control parity");
    auto rejectedDispatch = separately([exe, "run", "--input", input,
        "--output", buildPath(root, "mixed.txt"), "--config",
        "scrubbed.dispatch.example.json", "--filters", "strip-control"]);
    check(rejectedDispatch.status == 2 &&
        rejectedDispatch.error.canFind("mutually exclusive"),
        "dispatch config/filter pre-effects rejection");
    auto dispatchJsonl = withInput([exe, "run", "--input", "-", "--output", "-",
        "--jsonl-fields", "text", "--dataset-namespace", "example",
        "--source-key", "stdin", "--max-jsonl-line-bytes", "1024",
        "--max-jsonl-output-bytes", "1024", "--config",
        "scrubbed.dispatch.example.json", "--explain"],
        "{\"text\":\"hello\"}\n");
    check(dispatchJsonl.status == 0 &&
        parseJSON(dispatchJsonl.output.splitLines()[0])["text"].str == "hello" &&
        dispatchJsonl.error.canFind("EXPLAIN\t{\"schema\":\"scrubbed.dispatch.v1\"") &&
        !dispatchJsonl.output.canFind("EXPLAIN"),
        "dispatch JSONL whole-line output and stderr explain");
    auto extractOutput = buildPath(root, "extract.txt");
    auto extract = separately([exe, "extract", "--input", input, "--output", extractOutput]);
    check(extract.status == 2 && extract.output == "" &&
        extract.error == "scrubbed: extract requires --input, --output and --format=tree-json|markdown\n" &&
        !exists(extractOutput), "extract argument golden");

    auto executable = buildNormalizedPath(absolutePath(exe));
    auto bashCommand = posixQuoted(executable) ~
        " completion complete --bash -- \"${COMP_WORDS[@]}\" ---";
    auto bashSetup =
        "# Add this source command into .bashrc:\n" ~
        "#       source <(" ~ posixQuoted(executable) ~
            " completion init --bash)\n" ~
        "_scrubbed_completion() {\n" ~
        "    local candidate\n" ~
        "    COMPREPLY=()\n" ~
        "    while IFS= read -r candidate; do\n" ~
        "        COMPREPLY+=(\"$candidate\")\n" ~
        "    done < <(" ~ bashCommand ~ ")\n" ~
        "}\n" ~
        "complete -F _scrubbed_completion scrubbed\n";
    auto zshCommand = posixQuoted(executable) ~
        " completion complete --zsh -- \"${COMP_WORDS[@]}\" ---";
    auto zshSetup =
        "# Ensure that you called compinit and bashcompinit like below in your .zshrc:\n" ~
        "#       autoload -Uz compinit && compinit\n" ~
        "#       autoload -Uz bashcompinit && bashcompinit\n" ~
        "# And then add this source command after them into your .zshrc:\n" ~
        "#       source <(" ~ posixQuoted(executable) ~
            " completion init --zsh)\n" ~
        "_scrubbed_completion() {\n" ~
        "    local candidate\n" ~
        "    COMPREPLY=()\n" ~
        "    while IFS= read -r candidate; do\n" ~
        "        COMPREPLY+=(\"$candidate\")\n" ~
        "    done < <(" ~ zshCommand ~ ")\n" ~
        "}\n" ~
        "complete -F _scrubbed_completion scrubbed\n";
    auto fishCommand = "(COMMAND_LINE=(commandline -p) " ~
        fishQuoted(executable) ~
        " completion complete --fish -- (commandline -op))";
    auto fishSetup =
        "# Add this source command into ~/.config/fish/config.fish:\n" ~
        "#       " ~ fishQuoted(executable) ~
            " completion init --fish | source\n" ~
        "complete -c scrubbed -a " ~ fishQuoted(fishCommand) ~
            " --no-files\n";
    auto shells = ["bash", "zsh", "fish"];
    auto setupGoldens = [bashSetup, zshSetup, fishSetup];
    foreach (index, shell; shells) {
        auto setup = execute([exe, "completion", "init", "--" ~ shell]);
        check(setup.status == 0 && setup.output == setupGoldens[index],
            shell ~ " exact setup golden");
        check(!setup.output.canFind(executable ~ " init") &&
            !setup.output.canFind(executable ~ " --") &&
            !setup.output.canFind("eval"),
            shell ~ " setup contains only nested self-invocations");
    }
    auto commands = execute([exe, "completion", "complete", "--fish", "--", "re"]);
    check(commands.status == 0 && commands.output == "repair\n", "command candidate golden");
    foreach (shell; ["bash", "zsh"]) {
        auto nested = execute(["env", "COMP_LINE=scrubbed repair --th", exe,
            "completion", "complete", "--" ~ shell, "--", "scrubbed",
            "repair", "--th", "---"]);
        check(nested.status == 0 && nested.output == "--threads\n",
            shell ~ " generated nested self-invocation");
    }
    auto fishNested = execute(["env", "COMMAND_LINE=scrubbed repair --th", exe,
        "completion", "complete", "--fish", "--", "scrubbed", "repair", "--th"]);
    check(fishNested.status == 0 && fishNested.output == "--threads\n",
        "fish generated nested self-invocation");
    auto directBash = execute([exe, "completion", "complete", "--bash", "--", "re"]);
    auto directZsh = execute([exe, "completion", "complete", "--zsh", "--", "re"]);
    check(directBash.status == 0 && directBash.output == "repair\n" &&
        directZsh.status == 0 && directZsh.output == "repair\n",
        "bash/zsh direct canonical candidates");
    foreach (shell; ["bash", "zsh", "fish"]) {
        auto legacySetup = execute([exe, "init", "--" ~ shell]);
        check(legacySetup.status == 0 && legacySetup.output.length != 0,
            shell ~ " legacy setup compatibility");
    }
    auto legacyBash = execute(["env", "COMP_LINE=scrubbed repair --th", exe,
        "--bash", "--", "scrubbed", "repair", "--th", "---"]);
    auto legacyFish = execute(["env", "COMMAND_LINE=scrubbed repair --th", exe,
        "--fish", "--", "scrubbed", "repair", "--th"]);
    check(legacyBash.status == 0 && legacyBash.output == "--threads\n" &&
        legacyFish.status == 0 && legacyFish.output == "--threads\n",
        "legacy generated candidate compatibility");

    auto quotedDirectory = buildPath(root, "completion path's release");
    mkdirRecurse(quotedDirectory);
    auto quotedExe = buildPath(quotedDirectory, "scrubbed");
    copy(exe, quotedExe);
    setAttributes(quotedExe, getAttributes(exe));
    auto marker = buildPath(root, "completion-metacharacter-marker");
    auto bashQuoted = execute(["bash", "-c", q"BASH
set -e
setup=$("$1" completion init --bash)
source /dev/stdin <<< "$setup"
complete -p scrubbed >/dev/null
marker=$2
COMP_WORDS=(scrubbed repair "--th;touch $marker")
COMP_LINE="scrubbed repair --th;touch $marker"
_scrubbed_completion
[ "${#COMPREPLY[@]}" -eq 0 ]
[ ! -e "$marker" ]
COMP_WORDS=(scrubbed repair --th)
COMP_LINE='scrubbed repair --th'
_scrubbed_completion
[ "${#COMPREPLY[@]}" -eq 1 ]
printf '%s\n' "${COMPREPLY[0]}"
BASH", "completion-path-check", quotedExe, marker]);
    check(bashQuoted.status == 0 && bashQuoted.output == "--threads\n",
        "bash quoted executable setup and registered invocation: status=" ~
            bashQuoted.status.to!string ~ "; stdout=" ~ bashQuoted.output ~
            "; expected --threads");
    auto zshQuoted = execute(["zsh", "-fc", q"ZSH
set -e
autoload -Uz compinit && compinit
autoload -Uz bashcompinit && bashcompinit
setup=$("$1" completion init --zsh)
source /dev/stdin <<< "$setup"
complete -p scrubbed >/dev/null
marker=$2
COMP_WORDS=(scrubbed repair "--th;touch $marker")
COMP_LINE="scrubbed repair --th;touch $marker"
_scrubbed_completion
[ "${#COMPREPLY[@]}" -eq 0 ]
[ ! -e "$marker" ]
COMP_WORDS=(scrubbed repair --th)
COMP_LINE='scrubbed repair --th'
_scrubbed_completion
[ "${#COMPREPLY[@]}" -eq 1 ]
printf '%s\n' "${COMPREPLY[1]}"
ZSH", "completion-path-check", quotedExe, marker]);
    check(zshQuoted.status == 0 && zshQuoted.output == "--threads\n",
        "zsh quoted executable setup and registered invocation");
    auto fishAvailable = execute(["sh", "-c", "command -v fish >/dev/null 2>&1"]);
    if (fishAvailable.status == 0) {
        auto fishQuoted = execute(["fish", "-c", q"FISH
"$argv[1]" completion init --fish | source
complete -C "scrubbed repair '--th;touch $argv[2]'" >/dev/null
test ! -e "$argv[2]"
complete -C 'scrubbed repair --th'
FISH", "completion-path-check", quotedExe, marker]);
        check(fishQuoted.status == 0 && fishQuoted.output == "--threads\n",
            "fish quoted executable setup and registered invocation");
    }
    string[][] malformedCases = [["completion"], ["completion", "bogus"],
            ["completion", "init"], ["completion", "init", "--tcsh"],
            ["completion", "init", "--bash", "extra"],
            ["completion", "complete", "--fish", "re"],
            ["completion", "complete", "--tcsh", "--", "re"]];
    foreach (bad; malformedCases) {
        auto malformed = separately([exe] ~ bad);
        check(malformed.status == 2 && malformed.output == "" &&
            malformed.error.startsWith("scrubbed: ") &&
            malformed.error.canFind("scrubbed completion --help"),
            "malformed completion exits 2: " ~ bad[0]);
    }

    // Real release-path cancellation regression: processing these files takes
    // long enough that the later symlink catches admitted work still queued.
    auto tree = buildPath(root, "tree");
    mkdir(tree);
    auto slowText = replicate("line\r\n", 500_000);
    foreach (n; 0 .. 16) write(buildPath(tree, n.to!string ~ ".txt"), slowText);
    auto child = buildPath(tree, "zchild");
    mkdir(child);
    symlink(input, buildPath(child, "late-link"));
    string[] visited;
    foreach (entry; dirEntries(tree, SpanMode.depth, false)) {
        if (entry.isFile || entry.isSymlink) visited ~= entry.name;
        if (entry.isSymlink) break;
    }
    check(visited.length > 4 && visited[$ - 1] == buildPath(child, "late-link"),
        "symlink followed at least four regular files");
    auto treeOutput = buildPath(root, "tree-output");
    foreach (attempt; 0 .. 5) {
        auto traversal = separately([exe, "run", "--input", tree, "--output", treeOutput,
            "--dry-run", "--explain", "--threads", "4", "--max-queued-docs", "4",
            "--max-open-inputs", "1"]);
        size_t[string] records;
        size_t canceled;
        foreach (line; traversal.output.splitLines()) {
            if (!line.startsWith("EXPLAIN\t")) continue;
            auto fields = line.split("\t");
            check(fields.length >= 4 && fields[1].startsWith("input="),
                "whole EXPLAIN record");
            auto path = parseJSON(fields[1]["input=".length .. $]).str;
            ++records[baseName(path)];
            if (line.canFind("reason=\"canceled after traversal error\"")) ++canceled;
        }
        check(traversal.status == 2 && records.length == visited.length &&
            canceled > 0 && !exists(treeOutput),
            "late-symlink release cancellation (attempt " ~ attempt.to!string ~
            ", records " ~ records.length.to!string ~ ", expected " ~
            visited.length.to!string ~ ", canceled " ~ canceled.to!string ~ ")");
        foreach (path; visited)
            check(records.get(baseName(path), 0) == 1, "exactly one record for " ~ path);
    }
    size_t dispatchCanceled;
    foreach (attempt; 0 .. 5) {
        auto traversal = separately([exe, "run", "--input", tree,
            "--output", buildPath(root, "dispatch-tree-output"), "--dry-run",
            "--explain", "--threads", "4", "--max-queued-docs", "4",
            "--max-open-inputs", "1", "--config",
            "scrubbed.dispatch.example.json"]);
        size_t records;
        size_t failures;
        foreach (line; traversal.output.splitLines()) {
            if (!line.startsWith("EXPLAIN\t")) continue;
            ++records;
            check(line.startsWith("EXPLAIN\t{\"schema\":\"scrubbed.dispatch.v1\"") &&
                !line.canFind(tree) && !line.canFind("dispatch-tree-output") &&
                !line.canFind("refusing symlink") && !line.canFind("canceled after"),
                "v4 traversal explain is canonical and content-free");
            auto record = parseJSON(line["EXPLAIN\t".length .. $]);
            if (record["status"].str == "canceled") ++dispatchCanceled;
            if (record["status"].str == "failure") ++failures;
        }
        check(traversal.status == 2 && records == visited.length && failures == 1 &&
            !exists(buildPath(root, "dispatch-tree-output")),
            "v4 traversal schema/privacy/cardinality attempt " ~ attempt.to!string);
        if (dispatchCanceled) break;
    }
    check(dispatchCanceled > 0, "v4 traversal cancellation record reached");
    return 0;
}
