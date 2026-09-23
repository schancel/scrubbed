/// Release-active fault matrix for the local manifest failure boundary.
module experiments.failure_policy.check;

import effects.sqlite_ffi;
import core.stdc.errno : EACCES;
import std.algorithm.searching : canFind, startsWith;
import std.algorithm.sorting : sort;
import std.array : split;
import std.conv : to;
import std.digest.sha : sha256Of;
import std.file : SpanMode, dirEntries, exists, getAttributes, isSymlink,
    mkdir, readText, remove, rmdir, rmdirRecurse, setAttributes, symlink,
    tempDir, write;
import std.path : baseName, buildPath;
import std.process : Redirect, execute, pipeProcess, wait;
import std.stdio : writeln;
import std.string : splitLines, toStringz;
import std.uuid : randomUUID;

private void need(bool okay, string label) {
    if (!okay) throw new Exception("failure policy: " ~ label);
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

private string state(string path) {
    sqlite3* db;
    need(sqlite3_open_v2(path.toStringz, &db, 0x00000001, null) == SQLITE_OK,
        "open manifest");
    scope(exit) sqlite3_close(db);
    sqlite3_stmt* query;
    need(sqlite3_prepare_v2(db,
        `SELECT state FROM final_event UNION ALL
         SELECT state FROM root_state WHERE NOT EXISTS(SELECT 1 FROM final_event)
         LIMIT 1`.toStringz, -1, &query, null) == SQLITE_OK,
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
        `SELECT document_id FROM final_event UNION ALL
         SELECT document_id FROM root_state WHERE NOT EXISTS(SELECT 1 FROM final_event)
         LIMIT 1`.toStringz,
        -1, &query, null) == SQLITE_OK, "prepare identity");
    scope(exit) sqlite3_finalize(query);
    need(sqlite3_step(query) == SQLITE_ROW, "identity row");
    import std.string : fromStringz;
    return sqlite3_column_text(query, 0).fromStringz.idup;
}

private string documentIdForInput(string path, string input) {
    sqlite3* db;
    need(sqlite3_open_v2(path.toStringz, &db, 0x00000001, null) == SQLITE_OK,
        "open keyed manifest");
    scope(exit) sqlite3_close(db);
    sqlite3_stmt* query;
    need(sqlite3_prepare_v2(db,
        `SELECT document_id FROM final_event WHERE input_sha256=?1 UNION ALL
         SELECT document_id FROM root_state WHERE input_sha256=?1 AND
         NOT EXISTS(SELECT 1 FROM final_event WHERE input_sha256=?1)`.toStringz,
        -1, &query, null) == SQLITE_OK, "prepare keyed identity");
    scope(exit) sqlite3_finalize(query);
    auto digest = sha256Of(cast(const(ubyte)[])readText(input));
    need(sqlite3_bind_blob(query, 1, digest.ptr, 32, null) == SQLITE_OK &&
        sqlite3_step(query) == SQLITE_ROW, "keyed identity row");
    import std.string : fromStringz;
    return sqlite3_column_text(query, 0).fromStringz.idup;
}

private long countState(string path, string wanted) {
    sqlite3* db;
    need(sqlite3_open_v2(path.toStringz, &db, 0x00000001, null) == SQLITE_OK,
        "open count manifest");
    scope(exit) sqlite3_close(db);
    sqlite3_stmt* query;
    auto sql = "SELECT count(*) FROM final_event WHERE state='" ~ wanted ~
        "' UNION ALL SELECT count(*) FROM root_state WHERE state='" ~ wanted ~
        "' AND NOT EXISTS(SELECT 1 FROM final_event WHERE final_event.document_id=" ~
        "root_state.document_id AND final_event.input_sha256=root_state.input_sha256 " ~
        "AND final_event.config_sha256=root_state.config_sha256)";
    need(sqlite3_prepare_v2(db, sql.toStringz, -1, &query, null) == SQLITE_OK,
        "prepare count");
    scope(exit) sqlite3_finalize(query);
    need(sqlite3_step(query) == SQLITE_ROW, "count row");
    auto result = sqlite3_column_int64(query, 0);
    need(sqlite3_step(query) == SQLITE_ROW, "root count row");
    return result + sqlite3_column_int64(query, 0);
}

private void changeDestination(string path, string destination) {
    sqlite3* db;
    need(sqlite3_open_v2(path.toStringz, &db, SQLITE_OPEN_READWRITE, null) == SQLITE_OK,
        "open manifest for destination fixture");
    scope(exit) sqlite3_close(db);
    sqlite3_stmt* update;
    need(sqlite3_prepare_v2(db, "UPDATE final_event SET destination=?1".toStringz,
        -1, &update, null) == SQLITE_OK, "prepare destination fixture");
    scope(exit) sqlite3_finalize(update);
    need(sqlite3_bind_text(update, 1, destination.toStringz, -1, null) == SQLITE_OK &&
        sqlite3_step(update) == SQLITE_DONE && sqlite3_changes(db) == 1,
        "change one destination fixture row");
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
        need(state(db) == (phase == "sink" ? "uncertain" : "planned"),
            phase ~ " manifest state");
        need(result.output.canFind(phase == "log-ack" ? "FATAL" : "SKIP"),
            phase ~ " classification");
        need(result.output.canFind("EXPLAIN") && (phase == "log-ack" ||
            (result.output.canFind(phase == "sink" ?
                "sink_key=\"local-primary:v1\"" : "sink_key=\"compiled:v1:") &&
             result.output.canFind("document_id=\"doc:v1:"))), phase ~
             " exact explanation output=" ~ result.output);
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
    need(preMarkResult.status == 1 &&
        preMarkResult.output.split("EXPLAIN\tinput=").length == 2 &&
        preMarkResult.output.canFind("status=failed") &&
        !preMarkResult.output.canFind("status=unacknowledged") &&
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
        countState(db, "planned") == 1 && countState(db, "committed") == 1 &&
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
        countState(twoDb, "planned") == 2, "two acknowledged failure prefixes");
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
        readText(policyInput) == "original", "post-preflight policy swap fatal output=" ~
        result.output ~ " state=" ~ state(policyDb));
    writeln("ok: post-preflight policy swap fatal");
    foreach (phase; ["policy", "content-own"]) {
        auto plannedFolder = buildPath(root, "pre-sink-" ~ phase);
        mkdir(plannedFolder);
        auto plannedInput = buildPath(plannedFolder, "input.txt");
        auto plannedOutput = buildPath(plannedFolder, "output.txt");
        auto plannedDb = buildPath(plannedFolder, "state.db");
        write(plannedInput, "original");
        write(plannedDb ~ ".fault-" ~ phase, "");
        result = execute([args[1], "run", "--input", plannedInput,
            "--output", plannedOutput, "--manifest", plannedDb,
            "--filters", "normalize-line-endings", "--explain"]);
        auto plannedId = firstDocumentId(plannedDb);
        need(result.status == 2 && result.output.canFind("FATAL") &&
            result.output.canFind("status=failed") &&
            result.output.canFind("document_id=\"" ~ plannedId ~ "\"") &&
            result.output.canFind("sink_key=\"local-primary:v1\"") &&
            result.output.split("EXPLAIN\tinput=").length == 2 &&
            state(plannedDb) == "failed" && !exists(plannedOutput),
            "post-plan pre-sink " ~ phase ~ " fault is durably failed with exact key");
        writeln("ok: post-plan pre-sink ", phase, " identity");
    }
    auto prefilterFolder = buildPath(root, "pre-filter-manifest");
    mkdir(prefilterFolder);
    auto prefilterInput = buildPath(prefilterFolder, "input.txt");
    auto prefilterOutput = buildPath(prefilterFolder, "output.txt");
    auto prefilterDb = buildPath(prefilterFolder, "state.db");
    write(prefilterInput, "original");
    write(prefilterDb ~ ".fault-policy", "");
    auto prefilterCommand = [args[1], "run", "--input", prefilterInput,
        "--output", prefilterOutput, "--manifest", prefilterDb,
        "--filters", "normalize-line-endings", "--explain"];
    result = execute(prefilterCommand);
    need(result.status == 2 && state(prefilterDb) == "failed",
        "pre-filter manifest setup failed");
    auto prefilterId = firstDocumentId(prefilterDb);
    changeDestination(prefilterDb, buildPath(prefilterFolder, "different.txt"));
    result = execute(prefilterCommand ~ ["--manifest-retry"]);
    need(result.status == 2 && result.output.canFind("FATAL") &&
        result.output.canFind("status=failure") &&
        result.output.canFind("event-reexecution-mismatch") &&
        result.output.canFind("document_id=\"" ~ prefilterId ~ "\"") &&
        result.output.canFind("sink_key=\"local-primary:v1\"") &&
        result.output.split("EXPLAIN\tinput=").length == 2 &&
        state(prefilterDb) == "failed" && !exists(prefilterOutput),
        "pre-filter manifest plan rejection keeps exact key and failed row output=" ~
        result.output);
    writeln("ok: pre-filter manifest fatal identity");
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
    write(buildPath(cancelInput, "b.txt"), "b");
    write(buildPath(cancelInput, "a.txt"), "a");
    string[] cancelPaths;
    foreach (entry; dirEntries(cancelInput, SpanMode.depth, false))
        if (entry.isFile) cancelPaths ~= entry.name;
    need(cancelPaths.length == 2, "fatal admission setup has two files");
    write(cancelPaths[1], "oversized");
    write(cancelDb ~ ".fault-policy-swap", "");
    result = execute([args[1], "run", "--input", cancelInput,
        "--output", cancelOutput, "--manifest", cancelDb,
        "--filters", "normalize-line-endings", "--explain",
        "--max-input-bytes", "1"]);
    size_t aDecisions, bDecisions, uncertainDecisions, canceledDecisions;
    foreach (line; result.output.splitLines()) {
        if (!line.startsWith("EXPLAIN\tinput=")) continue;
        if (line.canFind("a.txt")) ++aDecisions;
        if (line.canFind("b.txt")) ++bDecisions;
        if (line.canFind("status=uncertain")) ++uncertainDecisions;
        if (line.canFind(baseName(cancelPaths[1])) &&
            line.canFind("status=canceled") &&
            line.canFind("reason=\"canceled after fatal processing failure\""))
            ++canceledDecisions;
    }
    need(result.status == 2 &&
        result.output.split("EXPLAIN\tinput=").length == 2 &&
        aDecisions + bDecisions == 1 && uncertainDecisions == 0 &&
        canceledDecisions == 0 &&
        result.output.canFind("input exceeds --max-input-bytes") &&
        countState(cancelDb, "uncertain") == 0,
        "lexical fatal admission stops before later publication: " ~ result.output);
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
        uncertainDecision.output.canFind("status=retry-required") &&
        uncertainDecision.output.canFind("document_id=\"" ~ exactId ~ "\"") &&
        uncertainDecision.output.canFind("sink_key=\"local-primary:v1\"") &&
        state(decisionDb) == "uncertain", "uncertain exact manifest key");
    writeln("ok: exact unresolved manifest decisions");
    auto aliasFolder = buildPath(root, "stored-destination-alias");
    mkdir(aliasFolder);
    auto aliasInput = buildPath(aliasFolder, "input.txt");
    auto aliasOutput = buildPath(aliasFolder, "output.txt");
    auto aliasDb = buildPath(aliasFolder, "state.db");
    write(aliasInput, "one\r\n");
    auto aliasCommand = [args[1], "run", "--input", aliasInput,
        "--output", aliasOutput, "--manifest", aliasDb,
        "--filters", "normalize-line-endings", "--explain"];
    result = execute(aliasCommand);
    need(result.status == 0 && state(aliasDb) == "committed" &&
        readText(aliasOutput) == "one\n", "stored alias setup committed");
    auto aliasId = firstDocumentId(aliasDb);
    changeDestination(aliasDb, aliasDb);
    result = execute(aliasCommand);
    need(result.status == 2 && result.output.canFind("FATAL") &&
        result.output.canFind("status=failure") &&
        result.output.canFind("event-reexecution-mismatch") &&
        result.output.canFind("document_id=\"" ~ aliasId ~ "\"") &&
        result.output.canFind("sink_key=\"local-primary:v1\"") &&
        result.output.split("EXPLAIN\tinput=").length == 2 &&
        state(aliasDb) == "committed" && readText(aliasOutput) == "one\n",
        "stored manifest alias is fatal without overwriting DB or output");
    writeln("ok: stored manifest alias policy fatal");
    auto routeFolder = buildPath(root, "stored-destination-route");
    mkdir(routeFolder);
    auto routeInput = buildPath(routeFolder, "input.txt");
    auto routeOutput = buildPath(routeFolder, "output.txt");
    auto alternateOutput = buildPath(routeFolder, "alternate.txt");
    auto routeDb = buildPath(routeFolder, "state.db");
    write(routeInput, "one\r\n");
    auto routeCommand = [args[1], "run", "--input", routeInput,
        "--output", routeOutput, "--manifest", routeDb,
        "--filters", "normalize-line-endings", "--explain"];
    result = execute(routeCommand);
    need(result.status == 0 && state(routeDb) == "committed" &&
        readText(routeOutput) == "one\n", "stored route setup committed");
    auto routeId = firstDocumentId(routeDb);
    write(alternateOutput, "one\n");
    changeDestination(routeDb, alternateOutput);
    remove(routeOutput);
    result = execute(routeCommand);
    need(result.status == 2 && result.output.canFind("FATAL") &&
        result.output.canFind("status=failure") &&
        result.output.canFind("event-reexecution-mismatch") &&
        result.output.canFind("document_id=\"" ~ routeId ~ "\"") &&
        result.output.canFind("sink_key=\"local-primary:v1\"") &&
        result.output.split("EXPLAIN\tinput=").length == 2 &&
        state(routeDb) == "committed" && !exists(routeOutput) &&
        readText(alternateOutput) == "one\n",
        "same-byte alternate stored route cannot falsely skip intended output");
    writeln("ok: stored destination route mismatch fatal");
    auto nestedFolder = buildPath(root, "nested-parent-inspection");
    mkdir(nestedFolder);
    auto nestedInput = buildPath(nestedFolder, "input");
    auto nestedOutput = buildPath(nestedFolder, "output");
    auto nestedDb = buildPath(nestedFolder, "state.db");
    mkdir(nestedInput);
    mkdir(nestedOutput);
    auto nestedInputParent = buildPath(nestedInput, "sub");
    auto nestedOutputParent = buildPath(nestedOutput, "sub");
    mkdir(nestedInputParent);
    mkdir(nestedOutputParent);
    auto nestedInputFile = buildPath(nestedInputParent, "document.txt");
    auto nestedOutputFile = buildPath(nestedOutputParent, "document.txt");
    write(nestedInputFile, "one\r\n");
    auto nestedCommand = [args[1], "run", "--input", nestedInput,
        "--output", nestedOutput, "--manifest", nestedDb,
        "--filters", "normalize-line-endings", "--explain"];
    result = execute(nestedCommand);
    need(result.status == 0 && state(nestedDb) == "committed" &&
        readText(nestedOutputFile) == "one\n", "nested parent setup committed");
    auto nestedId = firstDocumentId(nestedDb);
    remove(nestedOutputFile);
    rmdir(nestedOutputParent);
    symlink(buildPath(nestedFolder, "missing-target"), nestedOutputParent);
    result = execute(nestedCommand);
    need(result.status == 2 && result.output.canFind("FATAL") &&
        result.output.canFind("status=failure") &&
        result.output.canFind("output path component is not a plain directory") &&
        result.output.canFind("document_id=\"" ~ nestedId ~ "\"") &&
        result.output.canFind("sink_key=\"local-primary:v1\"") &&
        result.output.split("EXPLAIN\tinput=").length == 2 &&
        state(nestedDb) == "committed" && !exists(nestedOutputFile),
        "dangling nested output parent remains keyed fatal: " ~ result.output);
    remove(nestedOutputParent);
    result = execute(nestedCommand);
    need(result.status == 1 && result.output.canFind("status=retry-required") &&
        result.output.canFind("document_id=\"" ~ nestedId ~ "\"") &&
        result.output.canFind("sink_key=\"local-primary:v1\"") &&
        result.output.split("EXPLAIN\tinput=").length == 2 &&
        state(nestedDb) == "uncertain" && !exists(nestedOutputParent),
        "genuinely missing nested parent becomes uncertain retry output=" ~
        result.output ~ " state=" ~ state(nestedDb));
    writeln("ok: nested parent absence versus dangling symlink");
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
        if (kind == "changed") {
            remove(positiveOutput);
            result = execute(positiveCommand);
            need(result.status == 1 && result.output.canFind("status=retry-required") &&
                result.output.canFind("document_id=\"" ~ positiveId ~ "\"") &&
                result.output.canFind("sink_key=\"local-primary:v1\"") &&
                state(positiveDb) == "uncertain",
                "ordinary deleted output remains uncertain retry");
        }
        writeln("ok: positive ", kind, " exact manifest key");
    }
    foreach (spec; ["open-EMFILE", "read-ENFILE", "fstat-ENOSPC",
            "read-EDQUOT", "open-EIO", "fstat-EIO", "read-EIO",
            "open-EPERM", "open-ELOOP"]) {
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
        auto rehashId = firstDocumentId(rehashDb);
        write(rehashOutput ~ ".fault-rehash-" ~ spec, "");
        result = execute(rehashCommand);
        need(result.status == 2 && state(rehashDb) == "committed" &&
            readText(rehashOutput) == "one\n" &&
            result.output.canFind("document_id=\"" ~ rehashId ~ "\"") &&
            result.output.canFind("sink_key=\"local-primary:v1\"") &&
            result.output.split("EXPLAIN\tinput=").length == 2 &&
            result.output.canFind("FATAL") &&
            result.output.canFind("status=failure") &&
            result.output.canFind("injected output rehash"),
            "rehash errno " ~ spec);
        writeln("ok: rehash errno ", spec);
    }
    auto eioFolder = buildPath(root, "rehash-eio-stops-tree");
    mkdir(eioFolder);
    auto eioInput = buildPath(eioFolder, "input");
    auto eioOutput = buildPath(eioFolder, "output");
    auto eioDb = buildPath(eioFolder, "state.db");
    mkdir(eioInput);
    write(buildPath(eioInput, "a.txt"), "alpha\r\n");
    write(buildPath(eioInput, "b.txt"), "beta\r\n");
    string[] eioPaths;
    foreach (entry; dirEntries(eioInput, SpanMode.depth, false))
        if (entry.isFile) eioPaths ~= entry.name;
    eioPaths.sort();
    need(eioPaths.length == 2, "rehash EIO setup has two files");
    auto eioCommand = [args[1], "run", "--input", eioInput,
        "--output", eioOutput, "--manifest", eioDb,
        "--filters", "normalize-line-endings", "--explain"];
    result = execute(eioCommand);
    need(result.status == 0 && countState(eioDb, "committed") == 2,
        "rehash EIO tree setup committed");
    auto eioId = documentIdForInput(eioDb, eioPaths[0]);
    auto firstEioOutput = buildPath(eioOutput, baseName(eioPaths[0]));
    auto secondEioOutput = buildPath(eioOutput, baseName(eioPaths[1]));
    auto firstOutputBytes = readText(firstEioOutput);
    auto secondOutputBytes = readText(secondEioOutput);
    auto priorAttributes = getAttributes(firstEioOutput);
    setAttributes(firstEioOutput, 0);
    auto deniedResult = separately(eioCommand);
    setAttributes(firstEioOutput, priorAttributes);
    size_t deniedDecisions, deniedCanceled;
    foreach (line; deniedResult.output.splitLines()) {
        if (!line.startsWith("EXPLAIN\tinput=")) continue;
        if (line.canFind(baseName(eioPaths[0])) &&
            line.canFind("status=failure") &&
            line.canFind("cannot open observed output") &&
            line.canFind("document_id=\"" ~ eioId ~ "\"") &&
            line.canFind("sink_key=\"local-primary:v1\""))
            ++deniedDecisions;
        if (line.canFind(baseName(eioPaths[1])) &&
            line.canFind("status=canceled") &&
            line.canFind("canceled after fatal processing failure"))
            ++deniedCanceled;
    }
    need(deniedResult.status == 2 && deniedResult.error.canFind("FATAL") &&
        deniedResult.error.canFind("errno=" ~ EACCES.to!string) &&
        deniedResult.output.split("EXPLAIN\tinput=").length == 3 &&
        deniedDecisions == 1 && deniedCanceled == 1 &&
        countState(eioDb, "committed") == 2 &&
        readText(firstEioOutput) == firstOutputBytes &&
        readText(secondEioOutput) == secondOutputBytes,
        "output rehash EACCES stops tree without changing committed rows");
    writeln("ok: real output rehash EACCES fatal cancellation");
    write(firstEioOutput ~ ".fault-rehash-read-EIO", "");
    auto eioResult = separately(eioCommand);
    size_t fatalEioDecisions, canceledEioDecisions;
    foreach (line; eioResult.output.splitLines()) {
        if (!line.startsWith("EXPLAIN\tinput=")) continue;
        if (line.canFind(baseName(eioPaths[0])) &&
            line.canFind("status=failure") &&
            line.canFind("injected output rehash read failure") &&
            line.canFind("document_id=\"" ~ eioId ~ "\"") &&
            line.canFind("sink_key=\"local-primary:v1\""))
            ++fatalEioDecisions;
        if (line.canFind(baseName(eioPaths[1])) &&
            line.canFind("status=canceled") &&
            line.canFind("canceled after fatal processing failure"))
            ++canceledEioDecisions;
    }
    need(eioResult.status == 2 && eioResult.error.canFind("FATAL") &&
        eioResult.error.canFind("injected output rehash read failure") &&
        eioResult.output.split("EXPLAIN\tinput=").length == 3 &&
        fatalEioDecisions == 1 && canceledEioDecisions == 1 &&
        countState(eioDb, "committed") == 2 &&
        readText(firstEioOutput) == firstOutputBytes &&
        readText(secondEioOutput) == secondOutputBytes,
        "rehash EIO stops later tree work without changing committed rows");
    writeln("ok: rehash EIO fatal cancellation reconciliation");
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
