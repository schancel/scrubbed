/// Release-active pins for v1 behavior and the effects-only v2 journal/copy.
module experiments.errors.check;

import domain.document : DocumentId, SourceLocator;
import effects.local_manifest : LocalManifest, SinkKey, SinkState, Inspection,
    inputDigest, configDigest, outputDigest;
import effects.failure_journal : FailureJournal, copyV1ToV2, createV2;
import effects.sqlite_ffi;
import std.algorithm.searching : canFind;
import std.array : split;
import std.file : exists, mkdir, remove, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.process : execute;
import std.string : toStringz;
import std.uuid : randomUUID;
import core.sys.posix.unistd : symlink, link;

private void need(bool okay, string label) {
    if (!okay) throw new Exception("errors stage 1: " ~ label);
}

private void expectRefusal(T)(lazy T operation, string label) {
    bool refused;
    try operation;
    catch (Exception) refused = true;
    need(refused, label);
}

private SinkKey key(string sink) {
    return SinkKey(DocumentId.from(SourceLocator("errors-stage1", "set", "one")),
        inputDigest(cast(const(ubyte)[]) "input"),
        configDigest(cast(const(ubyte)[]) "config"), sink);
}

private void checkV1Sinks(string root) {
    auto path = buildPath(root, "sinks.db");
    auto outputA = buildPath(root, "a.txt");
    auto outputB = buildPath(root, "b.txt");
    auto a = key("sink-a");
    auto b = key("sink-b");
    auto manifest = new LocalManifest(path);
    manifest.plan(a, outputA);
    manifest.plan(b, outputB);
    manifest.markFailed(a);
    manifest.markUncertain(b);
    need(manifest.lookup(a).get.state == SinkState.failed &&
        manifest.lookup(b).get.state == SinkState.uncertain, "two independent failure states");
    need(manifest.inspect(a) == Inspection.retryRequired &&
        manifest.inspect(b) == Inspection.retryRequired, "neither failure can skip");
    write(outputA, "recovered");
    write(outputB, "possibly-published");
    expectRefusal(manifest.commitPublished(a, outputA,
        outputDigest(cast(const(ubyte)[]) "recovered")),
        "failed sink committed without explicit retry");
    expectRefusal(manifest.commitPublished(b, outputB,
        outputDigest(cast(const(ubyte)[]) "possibly-published")),
        "uncertain sink committed without explicit retry");
    manifest.retry(a);
    manifest.commitPublished(a, outputA,
        outputDigest(cast(const(ubyte)[]) "recovered"));
    need(manifest.inspect(a) == Inspection.verifiedCommitted &&
        manifest.lookup(b).get.state == SinkState.uncertain &&
        manifest.inspect(b) == Inspection.retryRequired,
        "retry success must affect only the exact sink key");
    manifest.close();
    auto reopened = new LocalManifest(path);
    need(reopened.inspect(a) == Inspection.verifiedCommitted &&
        reopened.lookup(b).get.state == SinkState.uncertain,
        "v1 state lost across reopen");
    reopened.close();

    sqlite3* raw;
    need(sqlite3_open_v2(path.toStringz, &raw, SQLITE_OPEN_READWRITE, null) == SQLITE_OK,
        "open v1 version fixture");
    need(sqlite3_exec(raw, "PRAGMA user_version=2", null, null, null) == SQLITE_OK,
        "set incompatible version");
    need(sqlite3_close(raw) == SQLITE_OK, "close version fixture");
    expectRefusal(new LocalManifest(path), "v1 reader accepted v2 version");
}

private void checkAcknowledgment(string executable, string root) {
    auto folder = buildPath(root, "ack");
    mkdir(folder);
    auto input = buildPath(folder, "input");
    auto output = buildPath(folder, "output");
    auto db = buildPath(folder, "state.db");
    mkdir(input);
    write(buildPath(input, "a.txt"), "a\r\n");
    write(buildPath(input, "b.txt"), "b\r\n");
    write(db ~ ".fault-filter", "");
    write(db ~ ".fault-log-ack", "");
    auto result = execute([executable, "run", "--input", input, "--output", output,
        "--manifest", db, "--filters", "normalize-line-endings", "--explain"]);
    need(result.status == 2 && result.output.canFind("FATAL") &&
        result.output.split("status=unacknowledged").length == 2,
        "lost acknowledgment did not fail-stop truthfully");
    need(!exists(buildPath(output, "a.txt")) &&
        !exists(buildPath(output, "b.txt")),
        "post-ack-fault processing published an output");
    auto manifest = new LocalManifest(db);
    auto page = manifest.replay(SinkState.failed, 10);
    need(page.rows.length == 1 && page.rows[0].sink == "local-primary:v1",
        "failed v1 row missing after acknowledgment fault");
    manifest.close();
}

private long count(string path, string sql) {
    sqlite3* db;
    need(sqlite3_open_v2(path.toStringz, &db, SQLITE_OPEN_READWRITE, null) == SQLITE_OK,
        "open journal fixture");
    scope(exit) need(sqlite3_close(db) == SQLITE_OK, "close journal fixture");
    sqlite3_stmt* statement;
    need(sqlite3_prepare_v2(db, sql.toStringz, -1, &statement, null) == SQLITE_OK,
        "prepare journal fixture");
    scope(exit) sqlite3_finalize(statement);
    need(sqlite3_step(statement) == SQLITE_ROW, "read journal fixture");
    return sqlite3_column_int64(statement, 0);
}

private void rawExec(string path, string sql) {
    sqlite3* db;
    need(sqlite3_open_v2(path.toStringz, &db,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, null) == SQLITE_OK,
        "open raw fixture");
    scope(exit) need(sqlite3_close(db) == SQLITE_OK, "close raw fixture");
    need(sqlite3_exec(db, sql.toStringz, null, null, null) == SQLITE_OK,
        "write raw fixture");
}

private void checkV2(string root) {
    auto db = buildPath(root, "journal.db");
    createV2(db);
    expectRefusal(new LocalManifest(db), "v1 mutator accepted v2 handle");
    auto a = key("/private/f13-canary.txt F13_SECRET_TOKEN\nhttps://invalid.example/f13-canary");
    auto b = key("second-sink");
    auto pathA = buildPath(root, "journal-a.txt");
    auto pathB = buildPath(root, "journal-b.txt");
    auto journal = new FailureJournal(db);
    journal.plan(a, pathA);
    journal.plan(b, pathB);
    journal.recordFailure(a, "sink", "sink-write-failed", true);
    journal.recordFailure(b, "filter", "filter-failed", false);
    need(journal.lookup(a).get.state == SinkState.uncertain &&
        journal.lookup(b).get.state == SinkState.failed &&
        journal.hasOutstanding(a) && journal.hasOutstanding(b) &&
        journal.eventCount() == 2, "atomic failure/outstanding pair");
    auto id = journal.publicSinkId(a.sink);
    need(id.length == 36 && id != a.sink, "opaque public sink identity");
    journal.retry(a);
    need(journal.hasOutstanding(a), "planned retry erased outstanding");
    write(pathA, "recovered");
    journal.commitPublished(a, pathA,
        outputDigest(cast(const(ubyte)[]) "recovered"));
    need(!journal.hasOutstanding(a) && journal.hasOutstanding(b) &&
        journal.eventCount() == 3 &&
        journal.inspect(a) == Inspection.verifiedCommitted,
        "retry cleared a different sink or history");
    journal.close();
    auto reopened = new FailureJournal(db);
    need(reopened.publicSinkId(a.sink) == id &&
        reopened.hasOutstanding(b) && !reopened.hasOutstanding(a) &&
        reopened.eventCount() == 3, "reopen changed identity or journal");
    write(pathA, "tampered");
    need(reopened.inspect(a) == Inspection.retryRequired &&
        reopened.lookup(a).get.state == SinkState.uncertain &&
        reopened.hasOutstanding(a) && reopened.eventCount() == 4,
        "inspect invalidation did not journal uncertainty");
    reopened.close();
    need(count(db, "SELECT count(*) FROM error_event WHERE phase='retry' AND retry_of IS NOT NULL") == 1,
        "retry history predecessor missing");
    need(count(db, "SELECT count(*) FROM sink_identity") == 2,
        "sink identity not deduplicated");
}

private void checkCopy(string root) {
    auto v1 = buildPath(root, "copy-v1.db");
    auto v2 = buildPath(root, "copy-v2.db");
    auto failed = key("F13_SECRET_TOKEN /private/f13-canary.txt");
    auto uncertain = key("https://invalid.example/f13-canary");
    auto doneKey = key("committed");
    auto source = new LocalManifest(v1);
    auto failedOutput = buildPath(root, "copy-failed.txt");
    auto uncertainOutput = buildPath(root, "copy-uncertain.txt");
    auto doneOutput = buildPath(root, "copy-done.txt");
    source.plan(failed, failedOutput);
    source.plan(uncertain, uncertainOutput);
    source.plan(doneKey, doneOutput);
    source.markFailed(failed);
    source.markUncertain(uncertain);
    write(doneOutput, "original");
    source.commitPublished(doneKey, doneOutput,
        outputDigest(cast(const(ubyte)[]) "original"));
    source.close();
    copyV1ToV2(v1, v2);
    need(count(v1, "PRAGMA user_version") == 1 &&
        count(v2, "PRAGMA user_version") == 2,
        "copy changed source version or omitted destination");
    need(count(v2, "SELECT count(*) FROM sink_state") == 3 &&
        count(v2, "SELECT count(*) FROM outstanding WHERE origin='legacy-v1'") == 2 &&
        count(v2, "SELECT count(*) FROM error_event") == 0,
        "copy forged history or lost rows");
    auto journal = new FailureJournal(v2);
    need(journal.lookup(failed).get.state == SinkState.failed &&
        journal.lookup(uncertain).get.state == SinkState.uncertain &&
        journal.lookup(doneKey).get.state == SinkState.committed,
        "copied state changed");
    auto id = journal.publicSinkId(failed.sink);
    journal.retry(failed);
    need(journal.hasOutstanding(failed), "legacy baseline cleared before publication");
    write(failedOutput, "now-published");
    journal.commitPublished(failed, failedOutput,
        outputDigest(cast(const(ubyte)[]) "now-published"));
    need(!journal.hasOutstanding(failed) && journal.hasOutstanding(uncertain) &&
        journal.eventCount() == 1 && journal.publicSinkId(failed.sink) == id,
        "legacy retry transition changed another baseline");
    journal.close();
    expectRefusal(copyV1ToV2(v1, v2), "copy overwrote destination");
    expectRefusal(copyV1ToV2(v1, v1), "copy aliased source");
}

private void checkCopyRefusals(string root) {
    auto sourcePath = buildPath(root, "negative-v1.db");
    auto v1 = new LocalManifest(sourcePath);
    v1.plan(key("negative"), buildPath(root, "negative-output"));
    v1.close();

    auto companion = buildPath(root, "existing-companion.db");
    write(companion ~ "-wal", "occupied");
    expectRefusal(copyV1ToV2(sourcePath, companion), "existing companion accepted");
    need(!exists(companion), "companion refusal published destination");

    auto sourceLink = buildPath(root, "source-alias.db");
    need(symlink(sourcePath.toStringz, sourceLink.toStringz) == 0,
        "create symlink fixture");
    expectRefusal(copyV1ToV2(sourceLink, buildPath(root, "alias-copy.db")),
        "source symlink accepted");
    auto hardlink = buildPath(root, "source-hardlink.db");
    need(link(sourcePath.toStringz, hardlink.toStringz) == 0,
        "create hardlink fixture");
    expectRefusal(copyV1ToV2(sourcePath, hardlink),
        "existing hardlink destination accepted");
    remove(hardlink);

    auto corrupt = buildPath(root, "corrupt-v1.db");
    write(corrupt, "not a sqlite database");
    expectRefusal(copyV1ToV2(corrupt, buildPath(root, "corrupt-copy.db")),
        "corrupt source accepted");
    auto foreign = buildPath(root, "foreign-v1.db");
    rawExec(foreign, "CREATE TABLE foreign_table(value INTEGER)");
    expectRefusal(copyV1ToV2(foreign, buildPath(root, "foreign-copy.db")),
        "foreign source accepted");
    auto mismatch = buildPath(root, "version-v1.db");
    auto versioned = new LocalManifest(mismatch);
    versioned.close();
    rawExec(mismatch, "PRAGMA user_version=7");
    expectRefusal(copyV1ToV2(mismatch, buildPath(root, "version-copy.db")),
        "version mismatch accepted");

    sqlite3* held;
    need(sqlite3_open_v2(sourcePath.toStringz, &held, SQLITE_OPEN_READWRITE, null) == SQLITE_OK,
        "open busy fixture");
    need(sqlite3_exec(held, "BEGIN IMMEDIATE", null, null, null) == SQLITE_OK,
        "begin busy fixture");
    auto busyCopy = buildPath(root, "busy-copy.db");
    expectRefusal(copyV1ToV2(sourcePath, busyCopy), "active writer accepted");
    need(!exists(busyCopy), "busy refusal published destination");
    need(sqlite3_exec(held, "ROLLBACK", null, null, null) == SQLITE_OK &&
        sqlite3_close(held) == SQLITE_OK, "release busy fixture");
    need(count(sourcePath, "SELECT count(*) FROM sink_state") == 1,
        "copy refusal changed v1 rows");
}

private void checkFaults(string root) {
    foreach (point; ["begin", "write", "commit", "ack"]) {
        auto db = buildPath(root, "fault-" ~ point ~ ".db");
        createV2(db);
        auto k = key("sink-" ~ point);
        auto journal = new FailureJournal(db);
        journal.plan(k, buildPath(root, "output-" ~ point));
        write(db ~ ".fault-v2-" ~ point, "");
        expectRefusal(journal.recordFailure(k, "sink", "sink-write-failed", true),
            "journal accepted injected write fault " ~ point);
        expectRefusal(journal.plan(key("later-" ~ point), buildPath(root, "later-" ~ point)),
            "journal did not fail-stop after " ~ point);
        remove(db ~ ".fault-v2-" ~ point);
        journal.close();
        auto reopened = new FailureJournal(db);
        auto committed = point == "ack";
        need(reopened.eventCount() == (committed ? 1 : 0) &&
            reopened.hasOutstanding(k) == committed &&
            reopened.lookup(k).get.state == (committed ? SinkState.uncertain : SinkState.planned),
            "fault restart state inconsistent " ~ point);
        reopened.close();
    }
    auto uncertainDb = buildPath(root, "prior-uncertain.db");
    createV2(uncertainDb);
    auto prior = new FailureJournal(uncertainDb);
    auto k = key("prior-uncertain");
    prior.plan(k, buildPath(root, "prior-uncertain-output"));
    prior.recordFailure(k, "sink", "sink-write-failed", true);
    prior.retry(k);
    prior.recordFailure(k, "filter", "filter-failed", false);
    need(prior.lookup(k).get.state == SinkState.uncertain &&
        prior.hasOutstanding(k) && prior.eventCount() == 2,
        "prepublish retry failure erased prior sink-touched uncertainty");
    prior.close();
}

private void checkCrash(string self, string root) {
    foreach (point; ["commit", "ack"]) {
        auto db = buildPath(root, "kill-" ~ point ~ ".db");
        createV2(db);
        auto marker = db ~ ".fault-v2-kill-" ~ point;
        auto result = execute([self, "--kill-child", db,
            buildPath(root, "kill-output-" ~ point), point]);
        need(result.status == 73, "kill fixture did not exit at " ~ point);
        remove(marker);
        auto journal = new FailureJournal(db);
        auto committed = point == "ack";
        need(journal.eventCount() == (committed ? 1 : 0) &&
            journal.hasOutstanding(key("kill-sink")) == committed,
            "kill/restart boundary wrong at " ~ point);
        journal.close();
    }
}

int main(string[] args) {
    if (args.length == 5 && args[1] == "--kill-child") {
        auto journal = new FailureJournal(args[2]);
        journal.plan(key("kill-sink"), args[3]);
        write(args[2] ~ ".fault-v2-kill-" ~ args[4], "");
        journal.recordFailure(key("kill-sink"), "sink", "sink-write-failed", true);
        return 1;
    }
    need(args.length == 2, "usage: check <FailurePolicyHarness release executable>");
    auto root = buildPath(tempDir, "scrubbed-errors-stage1-" ~ randomUUID.toString);
    mkdir(root);
    scope(exit) if (exists(root)) rmdirRecurse(root);
    checkV1Sinks(root);
    checkAcknowledgment(args[1], root);
    checkV2(root);
    checkCopy(root);
    checkCopyRefusals(root);
    checkFaults(root);
    checkCrash(args[0], root);
    return 0;
}
