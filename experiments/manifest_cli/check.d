/// Release-active canonical manifest-v2 CLI and crash/retry matrix.
module manifest_cli.check;

import core.sys.posix.signal : SIGKILL;
import effects.local_manifest : LocalManifest;
import effects.sqlite_ffi;
import std.algorithm.searching : canFind;
import std.conv : to;
import std.digest.sha : sha256Of;
import std.file : exists, mkdir, read, readText, remove, rmdirRecurse,
    tempDir, write;
import std.path : buildPath;
import std.process : execute;
import std.stdio : writeln;
import std.string : fromStringz, toStringz;
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
private long scalar(string path, string sql) {
    sqlite3* db;
    need(sqlite3_open_v2(path.toStringz, &db, SQLITE_OPEN_READONLY, null) == SQLITE_OK,
        "open state");
    scope(exit) sqlite3_close(db);
    sqlite3_stmt* statement;
    need(sqlite3_prepare_v2(db, sql.toStringz, -1, &statement, null) == SQLITE_OK,
        "prepare scalar");
    scope(exit) sqlite3_finalize(statement);
    need(sqlite3_step(statement) == SQLITE_ROW, "read scalar");
    return sqlite3_column_int64(statement, 0);
}
private string text(string path, string sql) {
    sqlite3* db;
    need(sqlite3_open_v2(path.toStringz, &db, SQLITE_OPEN_READONLY, null) == SQLITE_OK,
        "open text state");
    scope(exit) sqlite3_close(db);
    sqlite3_stmt* statement;
    need(sqlite3_prepare_v2(db, sql.toStringz, -1, &statement, null) == SQLITE_OK,
        "prepare text");
    scope(exit) sqlite3_finalize(statement);
    need(sqlite3_step(statement) == SQLITE_ROW, "read text");
    return sqlite3_column_text(statement, 0).fromStringz.idup;
}
private ubyte[32] blob(string path, string sql) {
    sqlite3* db;
    need(sqlite3_open_v2(path.toStringz, &db, SQLITE_OPEN_READONLY, null) == SQLITE_OK,
        "open blob state");
    scope(exit) sqlite3_close(db);
    sqlite3_stmt* statement;
    need(sqlite3_prepare_v2(db, sql.toStringz, -1, &statement, null) == SQLITE_OK,
        "prepare blob");
    scope(exit) sqlite3_finalize(statement);
    need(sqlite3_step(statement) == SQLITE_ROW &&
        sqlite3_column_bytes(statement, 0) == 32, "read blob");
    ubyte[32] result;
    result[] = (cast(const(ubyte)*)sqlite3_column_blob(statement, 0))[0 .. 32];
    return result;
}
private string[] baseCommand(string executable, string input, string output,
        string db) {
    return [executable, "run", "--input", input, "--output", output,
        "--manifest", db, "--filters", "normalize-line-endings", "--explain",
        "--threads", "2", "--max-queued-docs", "2",
        "--max-open-inputs", "1", "--max-input-bytes", "1048576"];
}

private void deterministicCrashWindows(string harness, string root) {
    foreach (phase; ["after-root-plan", "after-event-plan", "after-first-intent",
            "after-first-publish", "after-first-commit", "after-root-commit"]) {
        auto folder = buildPath(root, "crash-" ~ phase);
        mkdir(folder);
        auto input = buildPath(folder, "input.txt");
        auto output = buildPath(folder, "output.txt");
        auto db = buildPath(folder, "state.db");
        write(input, "window\r\n");
        auto command = baseCommand(harness, input, output, db);
        auto marker = db ~ ".kill-" ~ phase;
        write(marker, "");
        auto killed = run(command);
        remove(marker);
        need(killed.status == -SIGKILL, phase ~ " did not SIGKILL");
        need(scalar(db, "PRAGMA user_version") == 2, phase ~ " version");
        auto uncertain = scalar(db,
            "SELECT count(*) FROM final_event WHERE state='uncertain'");
        if (phase == "after-first-intent" || phase == "after-first-publish") {
            expect(phase ~ " default refusal", command, 1, "retry-required");
            expect(phase ~ " exact retry", command ~ ["--manifest-retry"], 0,
                "done.");
        } else {
            need(uncertain == 0, phase ~ " unexpected uncertain state");
            expect(phase ~ " restart", command, 0, "done.");
        }
        need(readText(output) == "window\n" &&
            text(db, "SELECT state FROM root_state") == "complete" &&
            text(db, "SELECT state FROM final_event") == "committed",
            phase ~ " final state");
        writeln("ok: deterministic ", phase);
    }
}

int main(string[] args) {
    need(args.length == 2 || args.length == 3,
        "usage: check <release executable> [release harness executable]");
    auto executable = args[1];
    auto root = buildPath(tempDir, "scrubbed-manifest-v2-" ~ randomUUID.toString);
    mkdir(root);
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto input = buildPath(root, "input.txt");
    auto output = buildPath(root, "output.txt");
    auto db = buildPath(root, "state.db");
    write(input, "one\r\n");
    auto command = baseCommand(executable, input, output, db);
    expect("validate leaves state absent", command ~ ["--validate"], 0, "valid.");
    need(!exists(db) && !exists(output), "validate mutated state");
    expect("dry run leaves state absent", command ~ ["--dry-run"], 0,
        "status=changed");
    need(!exists(db) && !exists(output), "dry run mutated state");
    expect("first canonical publish", command, 0, "status=changed");
    need(readText(output) == "one\n" && scalar(db, "PRAGMA application_id") ==
        0x53435242 && scalar(db, "PRAGMA user_version") == 2 &&
        scalar(db, "SELECT count(*) FROM root_state") == 1 &&
        scalar(db, "SELECT count(*) FROM final_event") == 1 &&
        text(db, "SELECT state FROM root_state") == "complete" &&
        text(db, "SELECT state FROM final_event") == "committed" &&
        text(db, "PRAGMA integrity_check") == "ok" &&
        scalar(db, "SELECT count(*) FROM pragma_foreign_key_check") == 0,
        "canonical schema/state");
    expect("verified committed replay", command, 0, "done.");

    write(output, "tampered");
    expect("tampered output requires exact retry", command, 1,
        "retry-required");
    need(text(db, "SELECT state FROM root_state") == "planned" &&
        text(db, "SELECT state FROM final_event") == "uncertain",
        "tamper did not reopen only its root/event");
    write(input, "two\r\n");
    expect("new input requires replacement authority", command, 1,
        "retry-required");
    expect("new input explicit retry", command ~ ["--manifest-retry"], 0,
        "done.");
    need(readText(output) == "two\n", "retry output");

    auto equivalentDb = buildPath(root, "equivalent.db");
    auto config = buildPath(root, "job.json");
    write(config, `{"version":3,"stages":[{"id":"legacy-text",` ~
        `"implementation":"text-transform","options":{},"filters":[` ~
        `{"name":"normalize-line-endings","options":{}}]}]}`);
    auto jsonCommand = [executable, "run", "--input", input, "--output", output,
        "--manifest", equivalentDb, "--config", config, "--manifest-retry"];
    expect("v3 JSON durable route", jsonCommand, 0, "done.");
    need(blob(db, `SELECT config_sha256 FROM root_state WHERE input_sha256=(SELECT
        input_sha256 FROM root_state ORDER BY updated_utc_ms DESC LIMIT 1) LIMIT 1`) ==
        blob(equivalentDb, "SELECT config_sha256 FROM root_state"),
        "equivalent selectors changed durable identity");
    auto tokenDb = buildPath(root, "tokens.db");
    auto tokenCommand = [executable, "run", "--input", input, "--output", output,
        "--manifest", tokenDb, "--stage", "legacy-text=text-transform",
        "--filter", "normalize-line-endings", "--manifest-retry"];
    expect("token durable route", tokenCommand, 0, "done.");
    need(blob(tokenDb, "SELECT config_sha256 FROM root_state") ==
        blob(equivalentDb, "SELECT config_sha256 FROM root_state"),
        "tokens changed durable identity");

    auto preexistingInput = buildPath(root, "preexisting-input.txt");
    auto preexistingOutput = buildPath(root, "preexisting-output.txt");
    auto preexistingDb = buildPath(root, "preexisting.db");
    write(preexistingInput, "safe\r\n");
    write(preexistingOutput, "user-owned");
    auto preexisting = baseCommand(executable, preexistingInput,
        preexistingOutput, preexistingDb);
    expect("unowned destination refuses", preexisting, 1, "retry-required");
    need(readText(preexistingOutput) == "user-owned", "unowned bytes replaced");
    expect("unowned destination explicit replacement",
        preexisting ~ ["--manifest-retry"], 0, "done.");

    auto old = buildPath(root, "old-v1.db");
    { scope legacy = new LocalManifest(old); }
    auto oldBytes = sha256Of(read(old));
    auto oldOutput = buildPath(root, "old-output.txt");
    expect("v1 manifest fixed refusal", baseCommand(executable, input,
        oldOutput, old), 2, "manifest-v1-requires-fresh-v2");
    need(sha256Of(read(old)) == oldBytes && !exists(oldOutput),
        "v1 refusal mutated state/output");

    auto tree = buildPath(root, "tree");
    auto treeOut = buildPath(root, "tree-out");
    mkdir(tree);
    mkdir(buildPath(tree, "a"));
    write(buildPath(tree, "a.txt"), "first\r\n");
    write(buildPath(tree, "a", "z.txt"), "second\r\n");
    auto treeDb = buildPath(root, "tree.db");
    expect("canonical tree order", [executable, "run", "--input", tree,
        "--output", treeOut, "--manifest", treeDb, "--filters",
        "normalize-line-endings"], 0, "2 succeeded");
    need(readText(buildPath(treeOut, "a.txt")) == "first\n" &&
        readText(buildPath(treeOut, "a", "z.txt")) == "second\n",
        "tree output bytes");

    if (args.length == 3) deterministicCrashWindows(args[2], root);
    writeln("canonical manifest-v2 CLI checks passed");
    return 0;
}
