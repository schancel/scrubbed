/// Release-active end-user manifest smoke and restart matrix.
module manifest_cli.check;

import core.sys.posix.signal : kill, SIGKILL;
import core.thread : Thread;
import effects.local_manifest : LocalManifest, SinkState;
import effects.sqlite_ffi;
import std.algorithm.searching : canFind;
import std.array : split;
import std.conv : to;
import std.datetime : dur;
import std.file : copy, exists, getAttributes, getSize, mkdir, readText, remove,
    rmdirRecurse, setAttributes, tempDir, write;
import std.path : buildPath;
import std.process : execute, spawnProcess, wait;
import std.stdio : File, writeln;
import std.string : toStringz;
import std.uuid : randomUUID;

private void need(bool okay, string label) {
    if (!okay) throw new Exception("manifest CLI check: " ~ label);
}

private struct Result { int status; string output; }

private Result run(string[] args) {
    auto result = execute(args);
    return Result(result.status, result.output);
}

private void expect(string label, string[] args, int status, string fragment) {
    auto result = run(args);
    need(result.status == status && result.output.canFind(fragment),
        label ~ ": exit " ~ result.status.to!string ~ ", output " ~ result.output);
    writeln("ok: ", label);
}

private void expectOneDecision(string label, string[] args, int exitStatus,
        string decision, string detail = "") {
    auto result = run(args);
    need(result.status == exitStatus &&
        result.output.canFind("status=" ~ decision) &&
        (!detail.length || result.output.canFind("detail=\"" ~ detail ~ "\"")) &&
        result.output.split("EXPLAIN\tinput=").length == 2,
        label ~ ": expected one " ~ decision ~ " record, got " ~ result.output);
    writeln("ok: ", label);
}

private bool hasPlanned(string path) {
    if (!exists(path)) return false;
    sqlite3* db;
    if (sqlite3_open_v2(path.toStringz, &db, 0x00000001, null) != SQLITE_OK) {
        if (db !is null) sqlite3_close(db);
        return false;
    }
    scope(exit) sqlite3_close(db);
    sqlite3_stmt* query;
    if (sqlite3_prepare_v2(db, "SELECT 1 FROM sink_state WHERE state='planned' LIMIT 1".toStringz,
        -1, &query, null) != SQLITE_OK) return false;
    scope(exit) sqlite3_finalize(query);
    return sqlite3_step(query) == SQLITE_ROW;
}

private void crashAfterPlan(string executable, string root) {
    auto input = buildPath(root, "crash-input.txt");
    auto output = buildPath(root, "crash-output.txt");
    auto db = buildPath(root, "crash.db");
    {
        auto file = File(input, "wb");
        auto chunk = new char[1024 * 1024];
        chunk[] = 'x';
        foreach (_; 0 .. 16) file.rawWrite(chunk);
    }
    auto command = [executable, "run", "--input", input, "--output", output,
        "--manifest", db, "--filters", "normalize-line-endings",
        "--max-input-bytes", "134217728", "--threads", "1"];
    auto child = spawnProcess(command);
    bool planned;
    foreach (_; 0 .. 250) {
        if (hasPlanned(db)) { planned = true; break; }
        Thread.sleep(dur!"msecs"(4));
    }
    need(kill(child.processID, SIGKILL) == 0, "kill exact child PID");
    need(wait(child) == -SIGKILL, "SIGKILL child result");
    need(planned, "live process did not expose a planned row");
    auto manifest = new LocalManifest(db);
    need(manifest.replay(SinkState.planned, 2).rows.length == 1,
        "killed CLI had no durable planned row");
    manifest.close();
    if (exists(output)) {
        expect("crash with output requires explicit retry", command, 1,
            "--manifest-retry");
        expect("crash reconcile", command ~ ["--manifest-retry"], 0, "done.");
    } else {
        expect("crash with no output safely restarts", command, 0, "done.");
    }
    need(getSize(output) == 16UL * 1024 * 1024, "crash recovery output size");
    expect("crash recovery committed skip", command ~ ["--explain"], 0,
        "status=skipped");
    writeln("ok: live-process SIGKILL after durable plan");
}

private void deterministicCrashWindows(string hookExecutable, string root) {
    foreach (phase; ["after-plan", "before-publish", "after-publish",
                     "after-commit"]) {
        auto folder = buildPath(root, "window-" ~ phase);
        mkdir(folder);
        auto input = buildPath(folder, "input.txt");
        auto output = buildPath(folder, "output.txt");
        auto db = buildPath(folder, "state.db");
        write(input, "window\r\n");
        auto command = [hookExecutable, "run", "--input", input, "--output",
            output, "--manifest", db, "--filters", "normalize-line-endings",
            "--explain"];
        auto marker = db ~ ".kill-" ~ phase;
        write(marker, "");
        auto killed = run(command);
        remove(marker);
        need(killed.status == -SIGKILL, phase ~ " did not SIGKILL at checkpoint");
        need(exists(output) == (phase == "after-publish" || phase == "after-commit"),
            phase ~ " output existence");
        auto ledger = new LocalManifest(db);
        need(ledger.replay(SinkState.planned, 2).rows.length ==
            (phase == "after-commit" ? 0 : 1), phase ~ " durable state");
        ledger.close();
        if (phase == "after-publish") {
            expectOneDecision(phase ~ " default refuses", command, 1,
                "retry-required");
            expectOneDecision(phase ~ " explicit reconcile",
                command ~ ["--manifest-retry"], 0, "retry", "changed");
        } else if (phase == "after-commit") {
            expect(phase ~ " verified skip", command, 0, "status=skipped");
        } else {
            expect(phase ~ " restart", command, 0, "status=changed");
        }
        need(readText(output) == "window\n", phase ~ " final bytes");
        writeln("ok: deterministic ", phase);
    }
}

int main(string[] args) {
    need(args.length == 2 || args.length == 3,
        "usage: check <release executable> [release harness executable]");
    auto executable = args[1];
    auto root = buildPath(tempDir, "scrubbed-manifest-cli-" ~ randomUUID.toString);
    mkdir(root);
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto input = buildPath(root, "input.txt");
    auto output = buildPath(root, "output.txt");
    auto db = buildPath(root, "state.db");
    write(input, "one\r\n");
    auto command = [executable, "run", "--input", input, "--output", output,
        "--manifest", db, "--filters", "normalize-line-endings", "--explain",
        "--threads", "2", "--max-queued-docs", "2", "--max-open-inputs", "1",
        "--max-input-bytes", "1048576"];
    expect("validate leaves DB absent", command ~ ["--validate"], 0, "valid.");
    need(!exists(db) && !exists(output), "validate mutated state");
    expect("dry run leaves DB absent", command ~ ["--dry-run"], 0,
        "dry-run-changed");
    need(!exists(db) && !exists(output), "dry run mutated state");
    auto preexistingInput = buildPath(root, "preexisting-input.txt");
    auto preexistingOutput = buildPath(root, "preexisting-output.txt");
    auto preexistingDb = buildPath(root, "preexisting.db");
    write(preexistingInput, "preexisting\r\n");
    write(preexistingOutput, "user-owned output");
    auto preexistingCommand = [executable, "run", "--input", preexistingInput,
        "--output", preexistingOutput, "--manifest", preexistingDb,
        "--filters", "normalize-line-endings", "--explain"];
    expectOneDecision("unrecorded destination refuses by default",
        preexistingCommand, 1, "retry-required");
    need(readText(preexistingOutput) == "user-owned output",
        "unrecorded destination was replaced without authorization");
    auto preexistingLedger = new LocalManifest(preexistingDb);
    need(preexistingLedger.replay(SinkState.planned, 2).rows.length == 0,
        "unrecorded destination was planned before rejection");
    preexistingLedger.close();
    expectOneDecision("unrecorded destination explicit reconcile",
        preexistingCommand ~ ["--manifest-retry"], 0, "retry", "changed");
    need(readText(preexistingOutput) == "preexisting\n",
        "explicit reconcile did not publish expected output");
    expect("retry control excluded from output identity", preexistingCommand,
        0, "status=skipped");
    auto unchangedInput = buildPath(root, "unchanged-input.txt");
    auto unchangedOutput = buildPath(root, "unchanged-output.txt");
    write(unchangedInput, "already clean");
    write(unchangedOutput, "unrecorded bytes");
    expectOneDecision("retry preserves unchanged detail", [executable,
        "run", "--input", unchangedInput, "--output", unchangedOutput,
        "--manifest", buildPath(root, "unchanged.db"), "--filters",
        "normalize-line-endings", "--explain", "--manifest-retry"],
        0, "retry", "unchanged");
    expect("first publish", command, 0, "status=changed");
    need(readText(output) == "one\n", "first output bytes");
    expect("exact committed skip", command, 0, "status=skipped");
    write(output, "tampered");
    expectOneDecision("tampered output refuses", command, 1, "uncertain");
    need(readText(output) == "tampered", "tamper overwritten without retry");
    expectOneDecision("explicit reconcile", command ~ ["--manifest-retry"],
        0, "retry", "changed");
    need(readText(output) == "one\n", "reconcile output");
    write(input, "two\r\n");
    expect("changed input refuses existing output", command, 1, "--manifest-retry");
    expectOneDecision("changed input explicit retry", command ~ ["--manifest-retry"],
        0, "retry", "changed");
    need(readText(output) == "two\n", "changed input output");
    write(input, "abc\r\n");
    expect("same-size mutation refuses", command, 1, "--manifest-retry");
    need(readText(output) == "two\n", "same-size mutation overwrote output");
    write(input, "expanded\r\n");
    expect("growth refuses prior output", command, 1, "--manifest-retry");
    write(input, "x");
    expect("shrink refuses prior output", command, 1, "--manifest-retry");
    write(input, "abc\r\n");
    auto config = buildPath(root, "filters.json");
    write(config, `{"filters":["normalize-line-endings"]}`);
    auto configured = [executable, "run", "--input", input, "--output", output,
        "--manifest", db, "--config", config, "--explain"];
    expect("config bytes change identity", configured, 1, "--manifest-retry");
    expectOneDecision("new config explicit retry", configured ~ ["--manifest-retry"],
        0, "retry", "changed");
    write(config, `{"filters": ["normalize-line-endings"]}`);
    expect("same filter with changed config bytes", configured, 1,
        "--manifest-retry");
    auto movedOutput = buildPath(root, "moved.txt");
    auto differentRoute = [executable, "run", "--input", input, "--output",
        movedOutput, "--manifest", db, "--filters", "normalize-line-endings",
        "--explain"];
    expect("new output route publishes separately", differentRoute, 0,
        "status=changed");
    need(readText(movedOutput) == "abc\n", "new output route bytes");
    auto rebuilt = buildPath(root, "different-executable");
    copy(executable, rebuilt);
    { auto file = File(rebuilt, "ab"); file.write("\n"); }
    setAttributes(rebuilt, getAttributes(executable));
    auto changedExecutable = [rebuilt, "run", "--input", input, "--output",
        movedOutput, "--manifest", db, "--filters", "normalize-line-endings"];
    expect("changed executable refuses existing sink", changedExecutable, 1,
        "--manifest-retry");
    need(readText(movedOutput) == "abc\n", "binary change overwrote sink");
    auto insideDb = buildPath(root, "input-tree");
    mkdir(insideDb);
    auto treeFile = buildPath(insideDb, "a.txt");
    write(treeFile, "tree\r\n");
    auto treeOut = buildPath(root, "output-tree");
    expect("manifest inside input tree rejected", [executable, "run", "--input",
        insideDb, "--output", treeOut, "--manifest", buildPath(insideDb, "db")],
        2, "outside input and output");
    expect("manifest inside output tree rejected", [executable, "run", "--input",
        insideDb, "--output", treeOut, "--manifest", buildPath(treeOut, "db")],
        2, "outside input and output");
    auto second = buildPath(insideDb, "b.txt");
    write(second, "other\r\n");
    auto treeCommand = [executable, "run", "--input", insideDb, "--output",
        treeOut, "--manifest", buildPath(root, "tree.db"), "--explain",
        "--max-input-bytes", "1048576", "--threads", "4", "--max-queued-docs",
        "1", "--max-open-inputs", "1"];
    expect("two independent tree files", treeCommand, 0, "2 succeeded");
    expect("tree restart both skip", treeCommand, 0, "status=skipped");
    write(second, "alter\r\n");
    auto mixed = run(treeCommand);
    need(mixed.status == 1 && mixed.output.canFind("status=skipped") &&
        mixed.output.canFind("--manifest-retry"), "one changed record blocked independently");
    expect("tree explicit retry", treeCommand ~ ["--manifest-retry"], 0,
        "status=retry");
    need(readText(buildPath(treeOut, "a.txt")) == "tree\n" &&
        readText(buildPath(treeOut, "b.txt")) == "alter\n",
        "independent tree output bytes");
    auto linkedDb = buildPath(root, "linked-state.db");
    import core.sys.posix.unistd : link;
    need(link(db.toStringz, linkedDb.toStringz) == 0, "create DB hardlink fixture");
    expect("DB hardlink rejected", [executable, "run", "--input", input,
        "--output", buildPath(root, "alias-output.txt"), "--manifest", linkedDb],
        2, "hard-link alias");
    remove(linkedDb);
    auto inputLink = buildPath(insideDb, "linked.txt");
    import std.file : symlink;
    symlink(treeFile, inputLink);
    expect("symlink tree input rejected", treeCommand, 2, "refusing symlink");
    remove(inputLink);
    expect("input byte cap breach is fatal", [executable, "run", "--input", input,
        "--output", buildPath(root, "cap-output"), "--manifest",
        buildPath(root, "cap.db"), "--max-input-bytes", "1"],
        2, "exceeds --max-input-bytes");
    expect("manifest JSONL rejected", [executable, "run", "--input", "-", "--output",
        "-", "--manifest", db], 2, "unavailable in JSONL");
    expect("empty manifest path rejected", [executable, "run", "--input", input,
        "--output", buildPath(root, "empty-manifest-output"), "--manifest", ""],
        2, "Missing value for argument --manifest");
    expect("no-manifest legacy", [executable, "run", "--input", input,
        "--output", buildPath(root, "legacy.txt")], 0, "done.");
    crashAfterPlan(executable, root);
    if (args.length == 3) deterministicCrashWindows(args[2], root);
    writeln("manifest CLI checks passed");
    return 0;
}
