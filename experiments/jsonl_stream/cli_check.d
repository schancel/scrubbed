/// Release-active checks against the shipping binary's stdio boundary.
/// Run: ldc2 -O -release experiments/jsonl_stream/cli_check.d -of=/tmp/issue16-cli-check && /tmp/issue16-cli-check ./scrubbed
module experiments.jsonl_stream.cli_check;

import std.algorithm.searching : canFind;
import std.conv : to;
import core.sync.semaphore : Semaphore;
import core.thread : Thread;
import core.time : seconds;
import std.file : exists, readText, rmdirRecurse, tempDir, write;
import std.json : parseJSON;
import std.path : buildPath;
import std.process : Redirect, execute, kill, pipeProcess, wait;
import std.stdio : File, writeln;
import std.string : splitLines, toStringz;
import std.uuid : randomUUID;

private void require(bool condition, string reason) {
    if (!condition) throw new Exception(reason);
}

private struct Result {
    int code;
    string output;
    string diagnostics;
}

private string readAll(File file) {
    string result;
    foreach (line; file.byLineCopy()) result ~= line ~ "\n";
    return result;
}

private Result invoke(string[] args, string input = "") {
    auto child = pipeProcess(args, Redirect.all);
    if (input.length) child.stdin.rawWrite(cast(const(ubyte)[]) input);
    child.stdin.close();
    auto output = readAll(child.stdout);
    auto diagnostics = readAll(child.stderr);
    return Result(wait(child.pid), output, diagnostics);
}

void main(string[] args) {
    if (args.length == 3 && args[1] == "--closed-stdin") {
        version (Posix) {
            import core.sys.posix.unistd : close, execv;
            string[] command = [args[2], "run", "--input", "-", "--output", "-",
                "--jsonl-fields", "text", "--dataset-namespace", "batch",
                "--source-key", "stable-source", "--max-jsonl-line-bytes", "1024",
                "--max-jsonl-output-bytes", "2048"];
            const(char)*[] cArgs;
            foreach (part; command) cArgs ~= part.toStringz;
            cArgs ~= null;
            close(0);
            execv(command[0].toStringz, cArgs.ptr);
            throw new Exception("failed to exec closed-stdin binary");
        } else throw new Exception("closed stdin proof requires POSIX");
    }
    require(args.length == 2, "pass the release binary path");
    auto base = [args[1], "run", "--input", "-", "--output", "-",
        "--jsonl-fields", "text,title", "--dataset-namespace", "batch",
        "--source-key", "stable-source", "--max-jsonl-line-bytes", "1024",
        "--max-jsonl-output-bytes", "2048"];
    auto records = "{\"text\":\"a\\r\\nb\",\"title\":\"z\",\"keep\":[1,true,null]}\r\n" ~
        "{\"text\":\"last\",\"keep\":{\"n\":18446744073709551615}}";
    auto result = invoke(base, records);
    require(result.code == 0 && result.output.splitLines().length == 2 &&
        !result.output.canFind("filter chain:") &&
        result.diagnostics.canFind("2 records processed"),
        "record-only stdout/count: code=" ~ result.code.to!string ~
        " out=" ~ result.output ~ " err=" ~ result.diagnostics);
    auto lines = result.output.splitLines();
    require(parseJSON(lines[0])["keep"][0].integer == 1 &&
        parseJSON(lines[0])["text"].str == "a\nb" &&
        parseJSON(lines[1])["keep"]["n"].uinteger == ulong.max,
        "selected/untouched semantics and CRLF/EOF");
    require(invoke(base, records).output == result.output, "retry result changed");

    auto dry = invoke(base ~ ["--dry-run"], records);
    require(dry.code == 0 && dry.output.length == 0 &&
        dry.diagnostics.canFind("2 records processed"), "dry-run wrote stdout");
    auto valid = invoke(base ~ ["--validate"], "{not-json}\n");
    require(valid.code == 0 && valid.output.length == 0 &&
        valid.diagnostics.canFind("no stdin read"), "validate processed stdin");
    // Keep stdin open: a validator that attempts even one read cannot exit.
    auto noRead = pipeProcess(base ~ ["--validate"], Redirect.all);
    auto exited = new Semaphore(0);
    int validationStatus;
    auto waiter = new Thread({ validationStatus = wait(noRead.pid); exited.notify(); });
    waiter.start();
    auto timely = exited.wait(2.seconds);
    if (!timely) kill(noRead.pid);
    noRead.stdin.close();
    waiter.join();
    require(timely && validationStatus == 0 && readAll(noRead.stdout).length == 0,
        "validate blocked on live stdin or wrote stdout");
    foreach (bad; ["{bad}\n", "{\"text\":3}\n", "{\"text\":\"123456789\"}\n"]) {
        auto failed = invoke(base ~ (bad.canFind("123456789") ?
            ["--max-jsonl-line-bytes", "8"] : []), bad);
        require(failed.code != 0 && failed.output.length == 0 &&
            failed.diagnostics.canFind("physical line 1") &&
            failed.diagnostics.canFind("prior records fully flushed"),
            "failure boundary omitted line/completed prefix");
    }
    auto malformed = invoke(base, "{bad}\n");
    auto invalidText = invoke(base, "{\"text\":3}\n");
    require(malformed.diagnostics.canFind("malformedJson") &&
        invalidText.diagnostics.canFind("invalidText"), "failure categories collapsed");
    auto prefix = invoke(base, "{\"text\":\"ok\"}\n{bad}\n");
    require(prefix.code == 1 && prefix.output.splitLines().length == 1 &&
        prefix.diagnostics.canFind("1 prior records fully flushed") &&
        prefix.diagnostics.canFind("physical line 2, DocumentId doc:v1:") &&
        prefix.diagnostics == invoke(base, "{\"text\":\"ok\"}\n{bad}\n").diagnostics,
        "completed prefix not reported");
    auto dryFailure = invoke(base ~ ["--dry-run"],
        "{\"text\":\"ok\"}\n{bad}\n");
    require(dryFailure.code == 1 && dryFailure.output.length == 0 &&
        dryFailure.diagnostics.canFind("1 prior records processed, no stdout") &&
        !dryFailure.diagnostics.canFind("fully flushed"),
        "dry-run failure falsely claimed stdout flush");
    version (Posix) {
        auto readFault = invoke([args[0], "--closed-stdin", args[1]]);
        require(readFault.code == 1 && readFault.output.length == 0 &&
            readFault.diagnostics.canFind("JSONL reader at physical line 1, DocumentId doc:v1:") &&
            readFault.diagnostics.canFind("0 prior records fully flushed") &&
            readFault.diagnostics.canFind("current record was not written"),
            "closed stdin was not classified as record-aware processing failure: " ~
            readFault.diagnostics);
    }
    auto outputCapped = invoke(base ~ ["--max-jsonl-output-bytes", "10"],
        "{\"text\":\"a\"}\n");
    require(outputCapped.code == 1 && outputCapped.output.length == 0 &&
        outputCapped.diagnostics.canFind("outputLimit"), "output cap failed");
    require(invoke(base ~ ["--explain"], records).code == 2,
        "undefined explain accepted");
    require(invoke([args[1], "repair"] ~ base[2 .. $], records).code == 0,
        "repair route failed");
    require(invoke([args[1]] ~ base[2 .. $], records).code == 0,
        "no-verb JSONL route failed");
    require(invoke([args[1], "--input", "-", "--output", "-"]).code == 2,
        "implicit JSONL mode accepted");
    require(invoke([args[1], "--input", "-", "--output", "out",
        "--jsonl-fields", "text"]).code == 2, "one-sided dash accepted");
    auto root = buildPath(tempDir(), "scrubbed-jsonl-cli-" ~ randomUUID().toString());
    scope(exit) if (exists(root)) rmdirRecurse(root);
    import std.file : mkdir;
    mkdir(root);
    auto configPath = buildPath(root, "filters.json");
    write(configPath, "{\"filters\":[\"strip-control\"]}");
    auto configured = invoke(base ~ ["--config", configPath],
        "{\"text\":\"\\u0001clean\"}\n");
    require(configured.code == 0 &&
        parseJSON(configured.output.splitLines()[0])["text"].str == "clean",
        "JSONL did not use configured filter chain");
    require(invoke(base ~ ["--config", configPath, "--filters", "strip-control"],
        "").code == 2, "config/filter conflict accepted");
    auto fileInput = buildPath(root, "input.txt");
    auto fileOutput = buildPath(root, "output.txt");
    write(fileInput, "plain\r\ntext\r\n");
    auto legacy = invoke([args[1], "--input", fileInput, "--output", fileOutput,
        "--threads", "1"]);
    require(legacy.code == 0 && exists(fileOutput) &&
        readText(fileOutput) == "plain\ntext\n", "legacy no-verb file mode changed");
    auto legacyValidate = invoke([args[1], "run", "--input", fileInput,
        "--output", fileOutput, "--validate"]);
    require(legacyValidate.code == 0 && legacyValidate.output.canFind("valid."),
        "legacy validate changed");
    auto legacyDry = invoke([args[1], "repair", "--input", fileInput,
        "--output", buildPath(root, "dry.txt"), "--dry-run"]);
    require(legacyDry.code == 0 && !exists(buildPath(root, "dry.txt")),
        "legacy dry-run changed");
    auto legacyExplain = invoke([args[1], "run", "--input", fileInput,
        "--output", fileOutput, "--explain"]);
    require(legacyExplain.code == 0 && legacyExplain.output.canFind("EXPLAIN"),
        "legacy explain changed");
    auto help = execute([args[1], "run", "--help"]);
    require(help.status == 0 && help.output.canFind("--jsonl-fields"),
        "JSONL help absent");
    auto modeHelp = invoke(base ~ ["--help"], "{\"text\":\"unread\"}\n");
    require(modeHelp.code == 0 && modeHelp.output.canFind("--jsonl-fields") &&
        !modeHelp.output.canFind("unread") &&
        !modeHelp.output.canFind("records processed"),
        "JSONL help mixed with streamed records");
    auto broken = pipeProcess(base, Redirect.all);
    broken.stdout.close();
    broken.stdin.rawWrite(cast(const(ubyte)[]) "{\"text\":\"a\"}\n{\"text\":\"b\"}\n");
    broken.stdin.close();
    auto brokenDiagnostics = readAll(broken.stderr);
    auto brokenCode = wait(broken.pid);
    require(brokenCode != 0 && brokenDiagnostics.canFind("partial") &&
        brokenDiagnostics.canFind("0 prior records fully flushed"),
        "broken stdout omitted current-record uncertainty: " ~ brokenDiagnostics);
    auto laterFault = pipeProcess(base, Redirect.all);
    laterFault.stdin.rawWrite(cast(const(ubyte)[]) "{\"text\":\"first\"}\n");
    laterFault.stdin.flush();
    string firstLine;
    Exception firstReadError;
    auto firstReady = new Semaphore(0);
    auto firstReader = new Thread({
        try firstLine = laterFault.stdout.readln();
        catch (Exception error) firstReadError = error;
        firstReady.notify();
    });
    firstReader.start();
    auto firstTimely = firstReady.wait(2.seconds);
    if (!firstTimely) kill(laterFault.pid);
    firstReader.join();
    if (!firstTimely) { wait(laterFault.pid); throw new Exception("live pipe waited for EOF"); }
    require(firstReadError is null &&
        parseJSON(firstLine)["text"].str == "first",
        "first record was not fully emitted before consumer fault");
    laterFault.stdout.close();
    laterFault.stdin.rawWrite(cast(const(ubyte)[]) "{\"text\":\"second\"}\n");
    laterFault.stdin.close();
    auto laterDiagnostics = readAll(laterFault.stderr);
    auto laterCode = wait(laterFault.pid);
    require(laterCode == 1 &&
        laterDiagnostics.canFind("1 prior records fully flushed") &&
        laterDiagnostics.canFind("physical line 2, DocumentId doc:v1:") &&
        laterDiagnostics.canFind("current record may be partially written"),
        "writer fault after committed prefix misreported (exit " ~
        laterCode.to!string ~ "): " ~ laterDiagnostics);
    writeln("jsonl CLI release-active checks: ok");
}
