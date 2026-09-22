/// Actual shipping-binary proof for the explicit v2 management verbs.
module experiments.errors.cli_check;

import domain.document : DocumentId, SourceLocator;
import effects.local_manifest : SinkKey, LocalManifest, inputDigest, configDigest;
import effects.failure_journal : FailureJournal;
import std.algorithm.searching : canFind;
import std.conv : to;
import std.file : exists, mkdir, readText, remove, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.process : execute;
import std.uuid : randomUUID;
import core.sys.posix.unistd : symlink, link;
import std.string : toStringz;

private void need(bool okay, string label) {
    if (!okay) throw new Exception("CLI check: " ~ label);
}

private void check(string root, string binary, bool crashHarness) {
    size_t checks;
    auto call(string[] args, int expected, bool quiet = false) {
        auto result = execute([binary] ~ args);
        need(result.status == expected, "exit " ~ args[0] ~ " " ~
            result.status.to!string ~ " expected " ~ expected.to!string);
        if (quiet) need(result.output.length == 0, "noisy success " ~ args[0]);
        foreach (secret; ["F13_SECRET_TOKEN", "F13_SOURCE_BYTES",
                "F13_EXCEPTION_TEXT", "/private/f13-canary.txt",
                "https://invalid.example/f13-canary"])
            need(!result.output.canFind(secret), "diagnostic leak " ~ args[0]);
        ++checks;
        return result.output;
    }
    auto db = buildPath(root, "journal.db");
    auto h = buildPath(root, "history.jsonl");
    auto o = buildPath(root, "outstanding.jsonl");
    need(call(["--help"], 0).canFind("errors-init"), "top-level help");
    need(call(["errors-init", "--help"], 0).canFind("--journal"), "verb help");
    auto helpPath = buildPath(root, "help-only.db");
    need(call(["errors-init", "--journal", helpPath, "--help"], 0)
        .canFind("--journal") && !exists(helpPath), "help after value mutated");
    need(call(["errors-init", "--journal=" ~ helpPath, "--help"], 0)
        .canFind("--journal") && !exists(helpPath), "equals-form help mutated");
    need(call(["errors-copy", "--from-v1", "F13_SECRET_TOKEN",
        "--journal", helpPath, "-h"], 0).canFind("--from-v1") &&
        !exists(helpPath), "copy help after value mutated");
    need(call(["errors-export", "--journal", "F13_SECRET_TOKEN",
        "--help"], 0).canFind("--errors-jsonl"), "export help");
    need(call(["errors-verify", "--errors-jsonl", "F13_SECRET_TOKEN",
        "--help"], 0).canFind("--errors-jsonl"), "verify help");
    need(call(["errors-init=F13_SECRET_TOKEN"], 2) ==
        "scrubbed: errors-invalid-arguments\n", "malformed verb diagnostic");
    need(call(["completion", "complete", "--bash", "--", "errors"], 0)
        .canFind("errors-verify"), "completion verbs");
    auto source = buildPath(root, "input.txt");
    auto defaultOutput = buildPath(root, "default.txt");
    auto explicitOutput = buildPath(root, "explicit.txt");
    write(source, "normal text\n");
    auto defaultText = call(["--input", source, "--output", defaultOutput], 0);
    auto explicitText = call(["run", "--input", source,
        "--output", explicitOutput], 0);
    need(defaultText == explicitText && readText(defaultOutput) ==
        readText(explicitOutput), "v1 no-verb/run equivalence");
    call(["errors-init", "--journal", db], 0, true);
    need(exists(db), "journal not created");
    need(call(["errors-init", "--journal", db], 2) ==
        "scrubbed: errors-operation-refused\n", "existing journal diagnostic");
    need(call(["errors-init", "--journal",
        buildPath(root, "missing", "F13_SECRET_TOKEN")], 2) ==
        "scrubbed: errors-operation-refused\n", "path refusal diagnostic");
    need(call(["errors-export", "--journal", db], 2) ==
        "scrubbed: errors-invalid-arguments\n", "missing destination diagnostic");
    need(call(["errors-verify"], 2) ==
        "scrubbed: errors-invalid-arguments\n", "verify syntax diagnostic");
    need(call(["errors-verify", "--errors-jsonl", h, "--bogus",
        "F13_SECRET_TOKEN"], 2) == "scrubbed: errors-invalid-arguments\n",
        "unknown option diagnostic");

    auto doc = DocumentId.from(SourceLocator("cli", "set", "one"));
    auto input = inputDigest(cast(const(ubyte)[])"F13_SOURCE_BYTES");
    auto config = configDigest(cast(const(ubyte)[])"config");
    auto key = SinkKey(doc, input, config,
        "F13_SECRET_TOKEN /private/f13-canary.txt https://invalid.example/f13-canary F13_EXCEPTION_TEXT");
    auto journal = new FailureJournal(db);
    journal.plan(key, buildPath(root, "sink.txt"));
    journal.recordFailure(key, "sink", "sink-write-failed", true);
    journal.close();
    call(["errors-export", "--journal", db, "--errors-jsonl", h,
        "--outstanding-jsonl", o], 0, true);
    call(["errors-verify", "--errors-jsonl", h, "--outstanding-jsonl", o], 0, true);
    auto side = readText(h ~ ".sha256");
    remove(h ~ ".sha256");
    need(call(["errors-verify", "--errors-jsonl", h], 2) ==
        "scrubbed: errors-operation-refused\n", "missing sidecar diagnostic");
    write(h ~ ".sha256", side);
    foreach (path; [h, o, h ~ ".sha256", o ~ ".sha256"])
        foreach (secret; ["F13_SECRET_TOKEN", "F13_SOURCE_BYTES",
                "F13_EXCEPTION_TEXT", "/private/f13-canary.txt",
                "https://invalid.example/f13-canary"])
            need(!readText(path).canFind(secret), "export leak");
    auto originalH = readText(h);
    write(h, originalH ~ "x");
    call(["errors-verify", "--errors-jsonl", h], 2);
    write(h, originalH);
    call(["errors-verify", "--errors-jsonl", h, "--outstanding-jsonl", o], 0, true);
    if (crashHarness) {
        auto next = SinkKey(doc, input, config, "next-private-key");
        journal = new FailureJournal(db);
        journal.plan(next, buildPath(root, "next-output"));
        journal.recordFailure(next, "filter", "filter-failed", false);
        journal.close();
        auto marker = db ~ ".fault-export-kill-after-json-rename";
        write(marker, "1");
        call(["errors-export", "--journal", db, "--errors-jsonl", h,
            "--outstanding-jsonl", o], 73);
        remove(marker);
        call(["errors-verify", "--errors-jsonl", h], 2);
        call(["errors-export", "--journal", db, "--errors-jsonl", h,
            "--outstanding-jsonl", o], 0, true);
        call(["errors-verify", "--errors-jsonl", h,
            "--outstanding-jsonl", o], 0, true);
    }
    call(["errors-export", "--journal", db, "--errors-jsonl", h,
        "--outstanding-jsonl", h], 2);
    call(["errors-export", "--journal", db, "--errors-jsonl", db], 2);
    call(["errors-export", "--journal", db, "--errors-jsonl", o], 0, true);
    call(["errors-verify", "--errors-jsonl", h, "--outstanding-jsonl", o], 2);
    call(["errors-export", "--journal", db, "--errors-jsonl", h,
        "--outstanding-jsonl", o], 0, true);
    call(["errors-verify", "--errors-jsonl", h, "--outstanding-jsonl", o], 0, true);
    auto linkPath = buildPath(root, "link.jsonl");
    need(symlink(h.toStringz, linkPath.toStringz) == 0, "symlink fixture");
    call(["errors-export", "--journal", db, "--errors-jsonl", linkPath], 2);
    auto hard = buildPath(root, "hard.jsonl");
    need(link(h.toStringz, hard.toStringz) == 0, "hardlink fixture");
    call(["errors-export", "--journal", db, "--errors-jsonl", hard], 2);

    auto v1 = buildPath(root, "v1.db");
    auto legacy = new LocalManifest(v1);
    string label;
    foreach (_; 0 .. 128) label ~= "é";
    auto exact = SinkKey(doc, input, config, label);
    legacy.plan(exact, buildPath(root, "legacy-output"));
    legacy.markFailed(exact);
    legacy.close();
    auto copied = buildPath(root, "copied.db");
    call(["errors-copy", "--from-v1", v1, "--journal", copied], 0, true);
    need(exists(v1) && exists(copied), "copy changed source or lost target");
    call(["errors-copy", "--from-v1", v1, "--journal", copied], 2);
    call(["errors-copy", "--from-v1", v1, "--journal", v1], 2);
    auto longV1 = buildPath(root, "long-v1.db");
    legacy = new LocalManifest(longV1);
    auto tooLong = SinkKey(doc, input, config, label ~ "b");
    legacy.plan(tooLong, buildPath(root, "long-output"));
    legacy.close();
    auto refused = buildPath(root, "refused.db");
    need(call(["errors-copy", "--from-v1", longV1, "--journal", refused], 2)
        .canFind("v2-sink-label-too-long"), "257-byte refusal token");
    need(!exists(refused) && exists(longV1), "oversized copy published");
    auto foreign = buildPath(root, "foreign.db");
    write(foreign, "F13_EXCEPTION_TEXT");
    call(["errors-export", "--journal", foreign, "--errors-jsonl", h], 2);
    call(["errors-copy", "--from-v1", foreign, "--journal", refused], 2);
    import std.stdio : writeln;
    writeln("errors CLI check: ", checks, " actual-binary assertions");
}

void main(string[] args) {
    need(args.length == 2 || (args.length == 3 && args[2] == "--crash"),
        "expected shipping executable and optional --crash");
    auto root = buildPath(tempDir(), "scrubbed-cli-errors-" ~ randomUUID().toString);
    mkdir(root);
    scope(exit) rmdirRecurse(root);
    check(root, args[1], args.length == 3);
}
