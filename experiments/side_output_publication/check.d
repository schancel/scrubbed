/// Release-binary proof for generic terminal side-output publication.
module experiments.side_output_publication.check;

import std.algorithm.searching : canFind;
import std.conv : to;
import std.exception : enforce;
import std.file : SpanMode, dirEntries, exists, mkdir, mkdirRecurse, read,
    readText, remove, symlink, write;
import std.path : buildPath;
import std.process : execute, spawnProcess, wait;
import std.stdio : File, writeln;
import std.string : splitLines;
import std.uuid : randomUUID;

version (Posix) {
    import core.sys.posix.unistd : link;
    import std.string : toStringz;
}

private string[] stageArgs() {
    return ["--stage", "pii=pii-four-class", "--stage-option",
        "policy=text:mask"];
}

private void runOkay(string binary, string[] args) {
    auto result = execute([binary, "run"] ~ args ~ stageArgs());
    enforce(result.status == 0, result.output);
}

private void fileAndRefusalProof(string binary, string root) {
    auto input = buildPath(root, "file-input.txt");
    auto primary = buildPath(root, "file-output.txt");
    auto side = buildPath(root, "file-audit.json");
    enum secret = "alice@example.com";
    write(input, "Contact " ~ secret ~ ".\n");
    runOkay(binary, ["--input", input, "--output", primary,
        "--sidecar-output", side, "--threads", "1"]);
    enforce(exists(primary) && exists(side), "file sinks were not published");
    enforce(!readText(primary).canFind(secret) &&
        !readText(side).canFind(secret), "published diagnostics leaked content");

    auto missingPrimary = buildPath(root, "missing-side-primary.txt");
    auto missing = execute([binary, "run", "--input", input, "--output",
        missingPrimary, "--threads", "1"] ~ stageArgs());
    enforce(missing.status != 0 && !exists(missingPrimary),
        "missing side destination did not fail before publication");

    auto aliasPrimary = buildPath(root, "alias-primary.txt");
    auto aliasResult = execute([binary, "run", "--input", input, "--output",
        aliasPrimary, "--sidecar-output", aliasPrimary, "--threads", "1"] ~
        stageArgs());
    enforce(aliasResult.status != 0 && !exists(aliasPrimary),
        "colliding destinations were accepted");

    version (Posix) {
        auto symlinkPath = buildPath(root, "audit-link.json");
        symlink(side, symlinkPath);
        auto linkPrimary = buildPath(root, "link-primary.txt");
        auto refused = execute([binary, "run", "--input", input, "--output",
            linkPrimary, "--sidecar-output", symlinkPath, "--threads", "1"] ~
            stageArgs());
        enforce(refused.status != 0 && !exists(linkPrimary),
            "symlink side destination was accepted");

        auto hardSource = buildPath(root, "hard-source.json");
        auto hardSide = buildPath(root, "hard-side.json");
        write(hardSource, "prior");
        enforce(link(hardSource.toStringz, hardSide.toStringz) == 0,
            "hard-link fixture failed");
        auto hardPrimary = buildPath(root, "hard-primary.txt");
        auto hardRefused = execute([binary, "run", "--input", input,
            "--output", hardPrimary, "--sidecar-output", hardSide,
            "--threads", "1"] ~ stageArgs());
        enforce(hardRefused.status != 0 && !exists(hardPrimary),
            "hard-linked side destination was accepted");
    }
}

private void treeIdentityProof(string binary, string root) {
    auto input = buildPath(root, "tree-input");
    mkdir(input);
    foreach (ordinal; 0 .. 8)
        write(buildPath(input, ordinal.to!string ~ ".txt"),
            "record " ~ ordinal.to!string ~ " user" ~ ordinal.to!string ~
            "@example.com\n");
    foreach (threads; [1, 4]) {
        auto primary = buildPath(root, "tree-primary-" ~ threads.to!string);
        auto side = buildPath(root, "tree-side-" ~ threads.to!string);
        runOkay(binary, ["--input", input, "--output", primary,
            "--sidecar-output", side, "--threads", threads.to!string]);
        foreach (ordinal; 0 .. 8) {
            auto name = ordinal.to!string ~ ".txt";
            enforce(read(buildPath(primary, name)) == read(buildPath(root,
                "tree-primary-1", name)), "thread count changed primary bytes");
            enforce(read(buildPath(side, name ~ ".pii-audit.json")) ==
                read(buildPath(root, "tree-side-1",
                    name ~ ".pii-audit.json")),
                "thread count changed side-output bytes");
        }
    }

    auto nestedSide = buildPath(input, "side-inside-input");
    auto nestedRefusal = execute([binary, "run", "--input", input,
        "--output", buildPath(root, "nested-primary"), "--sidecar-output",
        nestedSide, "--threads", "1"] ~ stageArgs());
    enforce(nestedRefusal.status != 0 && !exists(nestedSide),
        "side root inside input was accepted");

    auto enclosing = buildPath(root, "enclosing-side");
    auto enclosedInput = buildPath(enclosing, "input");
    mkdirRecurse(enclosedInput);
    write(buildPath(enclosedInput, "one.txt"), "alice@example.com\n");
    auto enclosingRefusal = execute([binary, "run", "--input", enclosedInput,
        "--output", buildPath(root, "enclosing-primary"),
        "--sidecar-output", enclosing, "--threads", "1"] ~ stageArgs());
    enforce(enclosingRefusal.status != 0 &&
        !exists(buildPath(root, "enclosing-primary")),
        "input inside side root was accepted");
}

private void jsonlProof(string binary, string root) {
    auto inputPath = buildPath(root, "input.jsonl");
    auto outputPath = buildPath(root, "output.jsonl");
    auto diagnosticsPath = buildPath(root, "diagnostics.txt");
    auto sidePath = buildPath(root, "audit.jsonl");
    write(inputPath, `{"text":"alice@example.com","title":"clean"}` ~
        "\n" ~ `{"text":"bob@example.com","title":"1.2.3.4"}` ~ "\n");
    scope input = File(inputPath, "rb");
    scope output = File(outputPath, "wb");
    scope diagnostics = File(diagnosticsPath, "wb");
    auto child = spawnProcess([binary, "run", "--input", "-", "--output",
        "-", "--sidecar-output", sidePath, "--jsonl-fields", "text,title",
        "--dataset-namespace", "synthetic", "--source-key", "proof",
        "--max-jsonl-line-bytes", "4096", "--max-jsonl-output-bytes",
        "1048576"] ~ stageArgs(), input, output, diagnostics);
    enforce(wait(child) == 0, "JSONL side-output run failed");
    enforce(readText(outputPath).splitLines.length == 2 &&
        readText(sidePath).splitLines.length == 4,
        "JSONL input/field order or cardinality changed");
    enforce(!readText(sidePath).canFind("alice@example.com"),
        "JSONL side output leaked selected content");

    auto boundedInput = buildPath(root, "bounded-input.jsonl");
    string records;
    foreach (ordinal; 0 .. 40)
        records ~= `{"text":"user` ~ ordinal.to!string ~
            `@example.com"}` ~ "\n";
    write(boundedInput, records);
    auto boundedOutput = buildPath(root, "bounded-output.jsonl");
    auto boundedDiagnostics = buildPath(root, "bounded-diagnostics.txt");
    auto boundedSide = buildPath(root, "bounded-audit.jsonl");
    {
        scope boundedSource = File(boundedInput, "rb");
        scope boundedSink = File(boundedOutput, "wb");
        scope boundedErrors = File(boundedDiagnostics, "wb");
        auto boundedChild = spawnProcess([binary, "run", "--input", "-",
            "--output", "-", "--sidecar-output", boundedSide,
            "--jsonl-fields", "text", "--dataset-namespace", "synthetic",
            "--source-key", "bounded", "--max-jsonl-line-bytes", "1024",
            "--max-jsonl-output-bytes", "1024",
            "--max-jsonl-sidecar-bytes", "1024"] ~ stageArgs(),
            boundedSource, boundedSink, boundedErrors);
        enforce(wait(boundedChild) == 1,
            "aggregate side-output cap did not fail cleanly");
    }
    enforce(readText(boundedOutput).splitLines.length > 0 &&
        readText(boundedOutput).splitLines.length < 40,
        "aggregate cap did not preserve a complete primary prefix");
    enforce(!exists(boundedSide),
        "aggregate overflow committed a side destination");
    foreach (entry; dirEntries(root, SpanMode.shallow, false))
        enforce(!entry.name.canFind(".bounded-audit.jsonl.scrubbed-sidecar-"),
            "aggregate overflow retained its spool");
}

private void durableProof(string binary, string root) {
    auto input = buildPath(root, "durable-input.txt");
    auto primary = buildPath(root, "durable-output.txt");
    auto side = buildPath(root, "durable-audit.json");
    auto manifest = buildPath(root, "manifest.db");
    write(input, "Contact alice@example.com.\n");
    auto args = ["--input", input, "--output", primary,
        "--sidecar-output", side, "--manifest", manifest, "--threads", "1"];
    runOkay(binary, args);
    auto primaryBytes = read(primary);
    auto sideBytes = read(side);
    runOkay(binary, args);
    enforce(read(primary) == primaryBytes && read(side) == sideBytes,
        "verified durable replay changed a sink");

    write(side, "tampered");
    auto detected = execute([binary, "run"] ~ args ~ stageArgs());
    enforce(detected.status == 1 && read(primary) == primaryBytes,
        "durable side tamper was skipped or changed its verified peer");
    runOkay(binary, args ~ ["--manifest-retry"]);
    enforce(read(primary) == primaryBytes && read(side) == sideBytes,
        "durable side retry did not restore only the invalidated sink");

    auto changedOptions = execute([binary, "run"] ~ args ~
        ["--stage", "pii=pii-four-class", "--stage-option",
            "policy=text:report"]);
    enforce(changedOptions.status != 0 && read(primary) == primaryBytes &&
        read(side) == sideBytes, "changed options verified-skipped old sinks");
    write(input, "Contact changed@example.com.\n");
    auto changedInput = execute([binary, "run"] ~ args ~ stageArgs());
    enforce(changedInput.status != 0 && read(primary) == primaryBytes &&
        read(side) == sideBytes, "changed input verified-skipped old sinks");
}

private void durableIndependentFailureProof(string binary, string root) {
    foreach (route; ["manifest", "journal"]) {
        auto folder = buildPath(root, "failure-" ~ route);
        mkdir(folder);
        auto input = buildPath(folder, "input.txt");
        auto primary = buildPath(folder, "primary.txt");
        auto side = buildPath(folder, "audit.json");
        auto ledger = buildPath(folder, "ledger.db");
        write(input, "Contact alice@example.com.\n");
        if (route == "journal") {
            auto initialized = execute([binary, "errors-init", "--journal",
                ledger]);
            enforce(initialized.status == 0, "journal initialization failed");
        }
        auto routeArgs = route == "manifest" ?
            ["--manifest", ledger] : ["--error-journal", ledger];
        auto retryFlag = route == "manifest" ?
            "--manifest-retry" : "--error-retry";
        auto args = ["--input", input, "--output", primary,
            "--sidecar-output", side, "--threads", "1"] ~ routeArgs;
        write(ledger ~ ".fault-sink-0", "");
        auto failed = execute([binary, "run"] ~ args ~ stageArgs());
        enforce(failed.status == 1 && !exists(primary) && exists(side) &&
            !failed.output.canFind("alice@example.com"),
            route ~ " primary failure did not commit only the side sink");
        auto committedSide = read(side);
        remove(ledger ~ ".fault-sink-0");
        auto refused = execute([binary, "run"] ~ args ~ stageArgs());
        enforce(refused.status == 1 && read(side) == committedSide,
            route ~ " restart did not preserve the verified side sink");
        auto retried = execute([binary, "run"] ~ args ~ [retryFlag] ~
            stageArgs());
        enforce(retried.status == 0 && exists(primary) &&
            read(side) == committedSide,
            route ~ " retry did not publish only the unresolved primary");
    }
}

int main(string[] args) {
    enforce(args.length == 2 || args.length == 3,
        "usage: side-output-check SCRUBBED [FAILURE-HARNESS]");
    auto root = buildPath("/tmp", "scrubbed-side-output-" ~
        randomUUID.toString);
    mkdirRecurse(root);
    fileAndRefusalProof(args[1], root);
    treeIdentityProof(args[1], root);
    jsonlProof(args[1], root);
    durableProof(args[1], root);
    if (args.length == 3) durableIndependentFailureProof(args[2], root);
    writeln("side-output publication release-binary checks passed");
    return 0;
}
