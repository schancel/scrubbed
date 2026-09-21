/// Release-active fault matrix for the local manifest failure boundary.
module experiments.failure_policy.check;

import effects.sqlite_ffi;
import std.algorithm.searching : canFind, startsWith;
import std.array : split;
import std.conv : to;
import std.file : exists, isSymlink, mkdir, readText, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.process : execute;
import std.stdio : writeln;
import std.string : splitLines, toStringz;
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

private string firstDocumentId(string path) {
    sqlite3* db;
    need(sqlite3_open_v2(path.toStringz, &db, 0x00000001, null) == SQLITE_OK,
        "open identity manifest");
    scope(exit) sqlite3_close(db);
    sqlite3_stmt* query;
    need(sqlite3_prepare_v2(db,
        "SELECT document_id FROM sink_state LIMIT 1".toStringz,
        -1, &query, null) == SQLITE_OK, "prepare identity");
    scope(exit) sqlite3_finalize(query);
    need(sqlite3_step(query) == SQLITE_ROW, "identity row");
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
            result.output.canFind("sink_key=\"local-primary:v1\"") &&
            result.output.canFind("document_id=\"doc:v1:"), phase ~ " exact explanation");
        need(!exists(output), phase ~ " unexpectedly published");
        writeln("ok: ", phase);
    }
    auto preMarkFolder = buildPath(root, "pre-mark");
    mkdir(preMarkFolder);
    auto preMarkInput = buildPath(preMarkFolder, "input.txt");
    auto preMarkOutput = buildPath(preMarkFolder, "output.txt");
    auto preMarkDb = buildPath(preMarkFolder, "state.db");
    write(preMarkInput, "fault");
    write(preMarkDb ~ ".fault-filter", "");
    write(preMarkDb ~ ".fault-pre-mark", "");
    auto preMarkResult = execute([args[1], "run", "--input", preMarkInput,
        "--output", preMarkOutput, "--manifest", preMarkDb,
        "--filters", "normalize-line-endings", "--explain"]);
    need(preMarkResult.status == 2 &&
        preMarkResult.output.split("EXPLAIN\tinput=").length == 2 &&
        preMarkResult.output.canFind("status=unacknowledged") &&
        !preMarkResult.output.canFind("status=failed") &&
        !preMarkResult.output.canFind("status=uncertain") &&
        countState(preMarkDb, "planned") == 1 &&
        countState(preMarkDb, "failed") == 0 &&
        countState(preMarkDb, "uncertain") == 0 &&
        !exists(preMarkOutput), "pre-mark failure stays unacknowledged");
    writeln("ok: pre-mark failure truthful EXPLAIN");
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
    foreach (spec; ["open-ENFILE", "write-ENOSPC", "fsync-EDQUOT",
            "close-EMFILE", "write-EACCES", "fsync-EIO",
            "setattrs-ENOSPC", "rename-EDQUOT",
            "setattrs-EACCES", "rename-EIO"]) {
        auto ioFolder = buildPath(root, "io-" ~ spec);
        mkdir(ioFolder);
        auto ioInput = buildPath(ioFolder, "input.txt");
        auto ioOutput = buildPath(ioFolder, "output.txt");
        auto ioDb = buildPath(ioFolder, "state.db");
        write(ioInput, "input\r\n");
        const replacing = spec.startsWith("setattrs-");
        if (replacing) write(ioOutput, "prior output");
        write(ioOutput ~ ".fault-" ~ spec, "");
        auto ioCommand = [args[1], "run", "--input", ioInput,
            "--output", ioOutput, "--manifest", ioDb,
            "--filters", "normalize-line-endings", "--explain"];
        if (replacing) ioCommand ~= "--manifest-retry";
        result = execute(ioCommand);
        const resource = !spec.canFind("EACCES") && !spec.canFind("EIO");
        need(result.status == (resource ? 2 : 1) &&
            result.output.canFind(resource ? "FATAL" : "SKIP") &&
            result.output.canFind("status=uncertain") &&
            state(ioDb) == "uncertain" &&
            (replacing ? readText(ioOutput) == "prior output" : !exists(ioOutput)),
            "injected sink errno " ~ spec);
        writeln("ok: injected sink errno ", spec);
    }
    auto cancelFolder = buildPath(root, "fatal-admission");
    mkdir(cancelFolder);
    auto cancelInput = buildPath(cancelFolder, "input");
    auto cancelOutput = buildPath(cancelFolder, "output");
    auto cancelDb = buildPath(cancelFolder, "state.db");
    mkdir(cancelInput);
    write(buildPath(cancelInput, "a.txt"), "a");
    write(buildPath(cancelInput, "b.txt"), "b");
    write(cancelDb ~ ".fault-policy-swap", "");
    result = execute([args[1], "run", "--input", cancelInput,
        "--output", cancelOutput, "--manifest", cancelDb,
        "--filters", "normalize-line-endings", "--explain"]);
    size_t aDecisions, bDecisions, uncertainDecisions, canceledDecisions;
    foreach (line; result.output.splitLines()) {
        if (!line.startsWith("EXPLAIN\tinput=")) continue;
        if (line.canFind("a.txt")) ++aDecisions;
        if (line.canFind("b.txt")) ++bDecisions;
        if (line.canFind("status=uncertain")) ++uncertainDecisions;
        if (line.canFind("status=canceled") &&
            line.canFind("reason=\"canceled after fatal processing failure\""))
            ++canceledDecisions;
    }
    need(result.status == 2 &&
        result.output.split("EXPLAIN\tinput=").length == 3 &&
        aDecisions == 1 && bDecisions == 1 &&
        uncertainDecisions == 1 && canceledDecisions == 1 &&
        countState(cancelDb, "uncertain") == 1,
        "fatal admission explains each discovered file once");
    writeln("ok: fatal admission EXPLAIN reconciliation");
    auto decisionFolder = buildPath(root, "manifest-decisions");
    mkdir(decisionFolder);
    auto decisionInput = buildPath(decisionFolder, "input.txt");
    auto decisionOutput = buildPath(decisionFolder, "output.txt");
    auto decisionDb = buildPath(decisionFolder, "state.db");
    write(decisionInput, "one\r\n");
    write(decisionOutput, "preexisting");
    auto decisionCommand = [args[1], "run", "--input", decisionInput,
        "--output", decisionOutput, "--manifest", decisionDb,
        "--filters", "normalize-line-endings", "--explain"];
    auto retryRequired = execute(decisionCommand);
    need(retryRequired.status == 1 &&
        retryRequired.output.canFind("status=retry-required"),
        "preexisting output requires retry");
    result = execute(decisionCommand ~ ["--manifest-retry"]);
    need(result.status == 0, "explicit decision retry");
    auto exactId = firstDocumentId(decisionDb);
    need(retryRequired.output.canFind("document_id=\"" ~ exactId ~ "\"") &&
        retryRequired.output.canFind("sink_key=\"local-primary:v1\""),
        "retry-required exact manifest key");
    need(result.output.canFind("status=retry") &&
        result.output.canFind("document_id=\"" ~ exactId ~ "\"") &&
        result.output.canFind("sink_key=\"local-primary:v1\"") &&
        result.output.split("EXPLAIN\tinput=").length == 2,
        "retry success exact manifest key once");
    auto skippedDecision = execute(decisionCommand);
    need(skippedDecision.status == 0 &&
        skippedDecision.output.canFind("status=skipped") &&
        skippedDecision.output.canFind("document_id=\"" ~ exactId ~ "\"") &&
        skippedDecision.output.canFind("sink_key=\"local-primary:v1\"") &&
        skippedDecision.output.split("EXPLAIN\tinput=").length == 2,
        "verified skip exact manifest key once");
    write(decisionOutput, "tampered");
    auto uncertainDecision = execute(decisionCommand);
    need(uncertainDecision.status == 1 &&
        uncertainDecision.output.canFind("status=uncertain") &&
        uncertainDecision.output.canFind("document_id=\"" ~ exactId ~ "\"") &&
        uncertainDecision.output.canFind("sink_key=\"local-primary:v1\"") &&
        state(decisionDb) == "uncertain", "uncertain exact manifest key");
    writeln("ok: exact unresolved manifest decisions");
    foreach (kind; ["changed", "unchanged"]) {
        auto positiveFolder = buildPath(root, "positive-" ~ kind);
        mkdir(positiveFolder);
        auto positiveInput = buildPath(positiveFolder, "input.txt");
        auto positiveOutput = buildPath(positiveFolder, "output.txt");
        auto positiveDb = buildPath(positiveFolder, "state.db");
        write(positiveInput, kind == "changed" ? "one\r\n" : "plain");
        auto positiveCommand = [args[1], "run", "--input", positiveInput,
            "--output", positiveOutput, "--manifest", positiveDb,
            "--filters", "normalize-line-endings", "--explain"];
        result = execute(positiveCommand);
        auto positiveId = firstDocumentId(positiveDb);
        need(result.status == 0 && result.output.canFind("status=" ~ kind) &&
            result.output.canFind("document_id=\"" ~ positiveId ~ "\"") &&
            result.output.canFind("sink_key=\"local-primary:v1\"") &&
            result.output.split("EXPLAIN\tinput=").length == 2,
            kind ~ " exact manifest key once");
        writeln("ok: positive ", kind, " exact manifest key");
    }
    foreach (spec; ["open-EMFILE", "read-ENFILE", "fstat-ENOSPC",
            "read-EDQUOT", "fstat-EIO"]) {
        auto rehashFolder = buildPath(root, "rehash-" ~ spec);
        mkdir(rehashFolder);
        auto rehashInput = buildPath(rehashFolder, "input.txt");
        auto rehashOutput = buildPath(rehashFolder, "output.txt");
        auto rehashDb = buildPath(rehashFolder, "state.db");
        write(rehashInput, "one\r\n");
        auto rehashCommand = [args[1], "run", "--input", rehashInput,
            "--output", rehashOutput, "--manifest", rehashDb,
            "--filters", "normalize-line-endings", "--explain"];
        result = execute(rehashCommand);
        need(result.status == 0 && state(rehashDb) == "committed",
            "rehash setup " ~ spec);
        write(rehashOutput ~ ".fault-rehash-" ~ spec, "");
        result = execute(rehashCommand);
        const resource = !spec.canFind("EIO");
        need(result.status == (resource ? 2 : 1) &&
            state(rehashDb) == (resource ? "committed" : "uncertain") &&
            readText(rehashOutput) == "one\n" &&
            (resource ? result.output.canFind("FATAL") :
                result.output.canFind("status=uncertain")),
            "rehash errno " ~ spec);
        writeln("ok: rehash errno ", spec);
    }
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
