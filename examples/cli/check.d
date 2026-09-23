/// Release-active executable checks: compile with ldc2 -O, then pass scrubbed.
module cli_check;

import std.algorithm.searching : canFind;
import std.array : replicate;
import std.conv : to;
import std.digest.sha : sha256Of;
import std.file : SpanMode, dirEntries, exists, mkdir, readText, rmdirRecurse,
    symlink, tempDir, write;
import std.json : parseJSON;
import std.path : baseName, buildPath;
import std.process : Redirect, execute, pipeProcess, wait;
import std.string : replace, split, splitLines, startsWith;
import std.uuid : randomUUID;

private void check(bool condition, string label) {
    if (!condition) throw new Exception("CLI golden: " ~ label);
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

private string dispatchRecord(Captured result) {
    string record;
    foreach (line; (result.output ~ result.error).splitLines()) {
        if (!line.startsWith("EXPLAIN\t{")) continue;
        check(!record.length, "exactly one dispatch explain record");
        record = line["EXPLAIN\t".length .. $];
    }
    check(record.length != 0, "dispatch explain record present");
    parseJSON(record);
    return record;
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

    foreach (shell; ["bash", "zsh", "fish"]) {
        auto setup = execute([exe, "completion", "init", "--" ~ shell]);
        check(setup.status == 0 && setup.output.canFind("complete") &&
            setup.output.canFind("scrubbed --"), shell ~ " setup");
    }
    auto commands = execute([exe, "completion", "complete", "--fish", "--", "re"]);
    check(commands.status == 0 && commands.output == "repair\n", "command candidate golden");
    auto options = execute([exe, "--fish", "--", "repair", "--th"]);
    check(options.status == 0 && options.output == "--threads\n", "option candidate golden");

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
    return 0;
}
