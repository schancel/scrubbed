/// Release-active fault matrix for the local manifest failure boundary.
module experiments.failure_policy.check;

import effects.sqlite_ffi;
import std.algorithm.searching : canFind;
import std.conv : to;
import std.file : exists, isSymlink, mkdir, readText, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.process : execute;
import std.stdio : writeln;
import std.string : toStringz;
import std.uuid : randomUUID;

private void need(bool okay, string label) {
    if (!okay) throw new Exception("failure policy: " ~ label);
}

private string state(string path) {
    sqlite3* db;
    need(sqlite3_open_v2(path.toStringz, &db, 0x00000001, null) == SQLITE_OK,
        "open manifest");
    scope(exit) sqlite3_close(db);
    sqlite3_stmt* query;
    need(sqlite3_prepare_v2(db,
        "SELECT state FROM sink_state LIMIT 1".toStringz, -1, &query, null) == SQLITE_OK,
        "prepare state");
    scope(exit) sqlite3_finalize(query);
    need(sqlite3_step(query) == SQLITE_ROW, "one state row");
    import std.string : fromStringz;
    return sqlite3_column_text(query, 0).fromStringz.idup;
}

private long countState(string path, string wanted) {
    sqlite3* db;
    need(sqlite3_open_v2(path.toStringz, &db, 0x00000001, null) == SQLITE_OK,
        "open count manifest");
    scope(exit) sqlite3_close(db);
    sqlite3_stmt* query;
    auto sql = "SELECT count(*) FROM sink_state WHERE state='" ~ wanted ~ "'";
    need(sqlite3_prepare_v2(db, sql.toStringz, -1, &query, null) == SQLITE_OK,
        "prepare count");
    scope(exit) sqlite3_finalize(query);
    need(sqlite3_step(query) == SQLITE_ROW, "count row");
    return sqlite3_column_int64(query, 0);
}

int main(string[] args) {
    need(args.length == 2, "usage: check <release harness executable>");
    auto root = buildPath(tempDir, "scrubbed-failure-" ~ randomUUID.toString);
    mkdir(root);
    scope(exit) if (exists(root)) rmdirRecurse(root);
    foreach (phase; ["read", "decode", "filter", "sink", "log-ack"]) {
        auto folder = buildPath(root, phase);
        mkdir(folder);
        auto input = buildPath(folder, "input.txt");
        auto output = buildPath(folder, "output.txt");
        auto db = buildPath(folder, "state.db");
        write(input, "one\r\n");
        write(db ~ ".fault-" ~ phase, "");
        if (phase == "log-ack") write(db ~ ".fault-filter", "");
        auto result = execute([args[1], "run", "--input", input, "--output", output,
            "--manifest", db, "--filters", "normalize-line-endings", "--explain"]);
        auto expected = phase == "log-ack" ? 2 : 1;
        need(result.status == expected, phase ~ " exit " ~ result.status.to!string);
        need(state(db) == (phase == "sink" ? "uncertain" : "failed"),
            phase ~ " manifest state");
        need(result.output.canFind(phase == "log-ack" ? "FATAL" : "SKIP"),
            phase ~ " classification");
        need(result.output.canFind("EXPLAIN") &&
            result.output.canFind("sink=local-primary:v1") &&
            result.output.canFind("id=doc:v1:"), phase ~ " exact explanation");
        need(!exists(output), phase ~ " unexpectedly published");
        writeln("ok: ", phase);
    }
    auto folder = buildPath(root, "continuation");
    mkdir(folder);
    auto input = buildPath(folder, "input");
    auto output = buildPath(folder, "output");
    auto db = buildPath(folder, "state.db");
    mkdir(input);
    write(buildPath(input, "bad.txt"), "bad\r\n");
    write(buildPath(input, "good.txt"), "good\r\n");
    write(db ~ ".fault-filter", "bad.txt");
    auto result = execute([args[1], "run", "--input", input, "--output", output,
        "--manifest", db, "--filters", "normalize-line-endings", "--explain"]);
    need(result.status == 1 && result.output.canFind("1 succeeded, 1 failed") &&
        result.output.canFind("status=failed") &&
        result.output.canFind("status=changed") &&
        countState(db, "failed") == 1 && countState(db, "committed") == 1 &&
        readText(buildPath(output, "good.txt")) == "good\n" &&
        !exists(buildPath(output, "bad.txt")), "second-document continuation");
    writeln("ok: second-document continuation");
    auto twoFolder = buildPath(root, "two-failures");
    mkdir(twoFolder);
    auto twoInput = buildPath(twoFolder, "input");
    auto twoOutput = buildPath(twoFolder, "output");
    auto twoDb = buildPath(twoFolder, "state.db");
    mkdir(twoInput);
    write(buildPath(twoInput, "a.txt"), "a");
    write(buildPath(twoInput, "b.txt"), "b");
    write(twoDb ~ ".fault-filter", "");
    result = execute([args[1], "run", "--input", twoInput, "--output", twoOutput,
        "--manifest", twoDb, "--filters", "normalize-line-endings", "--explain"]);
    need(result.status == 1 && result.output.canFind("0 succeeded, 2 failed") &&
        result.output.canFind("completed-prefix=0") &&
        result.output.canFind("completed-prefix=1") &&
        countState(twoDb, "failed") == 2, "two acknowledged failure prefixes");
    writeln("ok: two acknowledged failure prefixes");
    auto policyFolder = buildPath(root, "policy-swap");
    mkdir(policyFolder);
    auto policyInput = buildPath(policyFolder, "input.txt");
    auto policyOutput = buildPath(policyFolder, "output.txt");
    auto policyDb = buildPath(policyFolder, "state.db");
    write(policyInput, "original");
    write(policyDb ~ ".fault-policy-swap", "");
    result = execute([args[1], "run", "--input", policyInput,
        "--output", policyOutput, "--manifest", policyDb,
        "--filters", "normalize-line-endings", "--explain"]);
    need(result.status == 2 && result.output.canFind("FATAL") &&
        result.output.canFind("status=uncertain") &&
        state(policyDb) == "uncertain" && isSymlink(policyOutput) &&
        readText(policyInput) == "original", "post-preflight policy swap fatal");
    writeln("ok: post-preflight policy swap fatal");
    auto fatalFolder = buildPath(root, "fatal");
    mkdir(fatalFolder);
    auto fatalInput = buildPath(fatalFolder, "input.txt");
    write(fatalInput, "larger than limit");
    auto fatalOutput = buildPath(fatalFolder, "output.txt");
    auto fatalDb = buildPath(fatalFolder, "state.db");
    auto base = [args[1], "run", "--input", fatalInput, "--output", fatalOutput,
        "--manifest", fatalDb, "--filters", "normalize-line-endings"];
    result = execute(base ~ ["--max-input-bytes", "1"]);
    need(result.status == 2 && !exists(fatalOutput), "resource limit fatal");
    result = execute(base ~ ["--filters", "unknown-filter"]);
    need(result.status == 2 && !exists(fatalOutput), "config fatal");
    write(fatalDb, "not SQLite");
    result = execute(base);
    need(result.status == 2 && !exists(fatalOutput), "manifest corruption fatal");
    writeln("ok: resource/config/manifest fatal");
    return 0;
}
