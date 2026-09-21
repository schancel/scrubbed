module manifest_runtime.check;

import content.pieces : Content, ContentPiece;
import core.memory : GC;
import core.sys.posix.signal : kill, SIGKILL;
import core.sys.posix.sys.resource : getrusage, rusage, RUSAGE_SELF;
import core.sys.posix.unistd : getpid, link;
import domain.document : DocumentId, SourceLocator;
import effects.atomic_piece_sink : writeAtomicPieces;
import effects.local_manifest : LocalManifest, SinkKey, SinkState, Inspection,
    ReplayCursor, inputDigest, configDigest, outputDigest, digestDiagnostic;
import effects.sqlite_ffi;
import std.conv : to;
import std.digest.sha : sha256Of;
import std.file : exists, getSize, mkdir, remove, rmdirRecurse, symlink, tempDir, write;
import std.path : buildPath;
import std.process : execute;
import std.stdio : writeln;
import std.uuid : randomUUID;
import std.string : toStringz;

void require(bool condition, string message) {
    if (!condition) throw new Exception(message);
}

long scalar(sqlite3* db, string sql) {
    sqlite3_stmt* query;
    require(sqlite3_prepare_v2(db, sql.toStringz, -1, &query, null) == SQLITE_OK,
        "prepare scalar");
    scope(exit) sqlite3_finalize(query);
    require(sqlite3_step(query) == SQLITE_ROW, "read scalar");
    return sqlite3_column_int64(query, 0);
}

void expectThrow(T)(lazy T operation) {
    bool caught;
    try { operation; }
    catch (Exception) { caught = true; }
    require(caught, "expected exception was not raised");
}

SinkKey key(string record, string input = "input", string config = "canonical-config",
    string sink = "clean") {
    return SinkKey(DocumentId.from(SourceLocator("manifest-test", "bundle", record)),
        inputDigest(cast(const(ubyte)[])input),
        configDigest(cast(const(ubyte)[])config), sink);
}

void publish(string path, string content) {
    auto pieces = new Content([ContentPiece.own(cast(const(ubyte)[])content)]);
    writeAtomicPieces(path, pieces.pieces());
}

void child(string dbPath, string output, string phase) {
    auto manifest = new LocalManifest(dbPath);
    auto identity = key("crash");
    if (phase == "before-publish") kill(getpid(), SIGKILL);
    publish(output, "published");
    if (phase == "after-publish") kill(getpid(), SIGKILL);
    manifest.commitPublished(identity, output, outputDigest(cast(const(ubyte)[])"published"));
    kill(getpid(), SIGKILL);
    throw new Exception("SIGKILL failed");
}

void checkCrash(string executable, string root, string phase, bool committed) {
    auto directory = buildPath(root, phase);
    mkdir(directory);
    auto dbPath = buildPath(directory, "manifest.db");
    auto output = buildPath(directory, "output");
    {
        auto manifest = new LocalManifest(dbPath);
        manifest.plan(key("crash"), output);
        manifest.close();
    }
    auto result = execute([executable, "--child", dbPath, output, phase]);
    writeln(phase, " status=", result.status);
    require(result.status == -SIGKILL, "child was not SIGKILLed at " ~ phase);
    require(exists(output) == (phase != "before-publish"),
        "crash point output existence mismatch");
    auto reopened = new LocalManifest(dbPath);
    require(reopened.inspect(key("crash")) ==
        (committed ? Inspection.verifiedCommitted : Inspection.retryRequired),
        "crash replay produced a false skip: " ~ phase);
    require(reopened.lookup(key("crash")).get.state ==
        (committed ? SinkState.committed : SinkState.planned),
        "wrong durable crash state: " ~ phase);
    reopened.checkpoint();
    reopened.close();
}

void checkMatrix(string root) {
    ubyte[] encoded = (cast(const(ubyte)[])"scrubbed:manifest-config:v1\0").dup;
    encoded ~= [cast(ubyte)0, 0, 0, 0, 0, 0, 0, 3];
    encoded ~= cast(const(ubyte)[])"cfg";
    require(configDigest(cast(const(ubyte)[])"cfg") == sha256Of(encoded),
        "config domain/length/bytes serialization mismatch");
    auto dbPath = buildPath(root, "matrix.db");
    auto outputA = buildPath(root, "a.out");
    auto outputB = buildPath(root, "b.out");
    auto manifest = new LocalManifest(dbPath);
    auto a = key("one", "input-v1", "config-v1", "sink-a");
    auto b = key("one", "input-v1", "config-v1", "sink-b");
    require(manifest.plan(a, outputA).state == SinkState.planned, "plan A");
    require(manifest.plan(a, outputA).attempt == 0, "duplicate plan changed attempt");
    manifest.plan(b, outputB);
    publish(outputA, "clean-A");
    expectThrow(manifest.commitPublished(a, outputA,
        outputDigest(cast(const(ubyte)[])"wrong")));
    require(manifest.inspect(a) == Inspection.retryRequired, "uncommitted sink skipped");
    manifest.commitPublished(a, outputA, outputDigest(cast(const(ubyte)[])"clean-A"));
    require(manifest.inspect(a) == Inspection.verifiedCommitted, "committed A did not skip");
    require(manifest.inspect(b) == Inspection.retryRequired, "B inherited A commit");
    require(manifest.inspect(key("one", "input-v2", "config-v1", "sink-a")) ==
        Inspection.absent, "input revision reused commit");
    require(manifest.inspect(key("one", "input-v1", "config-v2", "sink-a")) ==
        Inspection.absent, "config revision reused commit");
    write(outputA, "tampered");
    require(manifest.inspect(a) == Inspection.retryRequired, "tampered output skipped");
    require(manifest.lookup(a).get.state == SinkState.uncertain, "tamper not uncertain");
    expectThrow(manifest.commitPublished(a, outputA,
        outputDigest(cast(const(ubyte)[])"tampered")));
    manifest.retry(a);
    publish(outputA, "clean-A2");
    manifest.commitPublished(a, outputA, outputDigest(cast(const(ubyte)[])"clean-A2"));
    remove(outputA);
    require(manifest.inspect(a) == Inspection.retryRequired, "deleted output skipped");
    manifest.markFailed(b);
    require(manifest.lookup(b).get.state == SinkState.failed, "failed B not independent");
    sqlite3* blocker;
    require(sqlite3_open_v2(dbPath.toStringz, &blocker, SQLITE_OPEN_READWRITE,
        null) == SQLITE_OK, "open lock competitor");
    require(sqlite3_exec(blocker, "BEGIN IMMEDIATE", null, null, null) == SQLITE_OK,
        "begin lock competitor");
    auto beforeLock = manifest.lookup(b).get.attempt;
    expectThrow(manifest.retry(b));
    require(manifest.lookup(b).get.attempt == beforeLock &&
        manifest.lookup(b).get.state == SinkState.failed,
        "locked write changed durable state");
    require(sqlite3_exec(blocker, "ROLLBACK", null, null, null) == SQLITE_OK,
        "rollback lock competitor");
    require(sqlite3_close(blocker) == SQLITE_OK, "close lock competitor");
    manifest.retry(b);
    require(manifest.lookup(b).get.state == SinkState.planned,
        "explicit retry did not replan B");
    expectThrow(manifest.plan(key("db-alias-main"), dbPath));
    expectThrow(manifest.plan(key("db-alias"), dbPath ~ "-wal"));
    auto linkPath = buildPath(root, "symlink");
    symlink(outputB, linkPath);
    expectThrow(manifest.plan(key("symlink"), linkPath));
    auto hardlinkPath = buildPath(root, "hardlink.db");
    require(link(dbPath.toStringz, hardlinkPath.toStringz) == 0, "make DB hardlink");
    expectThrow(manifest.plan(key("hardlink"), hardlinkPath));
    auto dbLink = buildPath(root, "db-symlink");
    symlink(dbPath, dbLink);
    expectThrow(new LocalManifest(dbLink));
    require(digestDiagnostic(inputDigest(cast(const(ubyte)[])"")) ==
        "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "SHA-256 diagnostic format");
    auto before = GC.stats().usedSize;
    foreach (i; 0 .. 10_100) {
        auto destination = buildPath(root, "queued-" ~ i.to!string);
        manifest.plan(key("queue-" ~ i.to!string), destination);
    }
    auto page = manifest.replay(SinkState.planned, 127);
    require(page.rows.length == 127, "first replay page");
    auto second = manifest.replay(SinkState.planned, 127, page.next);
    require(second.rows.length == 127 &&
        second.rows[0].documentId > page.rows[$ - 1].documentId,
        "keyset page boundary duplicated or regressed");
    auto otherDb = new LocalManifest(buildPath(root, "other.db"));
    expectThrow(otherDb.replay(SinkState.planned, 127, page.next));
    expectThrow(manifest.replay(SinkState.failed, 127, page.next));
    expectThrow(manifest.replay(SinkState.planned, 127,
        ReplayCursor.malformedForTest()));
    otherDb.close();
    auto after = GC.stats().usedSize;
    require(after - before < 32 * 1024 * 1024, "replay memory grew unexpectedly");
    auto checkpoint = manifest.checkpoint();
    require(checkpoint.logFrames == 0 && checkpoint.checkpointedFrames == 0,
        "checkpoint did not truncate WAL");
    manifest.close();
    rusage usage;
    require(getrusage(RUSAGE_SELF, &usage) == 0, "getrusage failed");
    version (OSX) auto peakRssBytes = cast(ulong)usage.ru_opaque[0];
    else version (linux) auto peakRssBytes = cast(ulong)usage.ru_maxrss * 1024;
    else auto peakRssBytes = cast(ulong)0;
    sqlite3* raw;
    require(sqlite3_open_v2(dbPath.toStringz, &raw, SQLITE_OPEN_READWRITE,
        null) == SQLITE_OK, "open raw version test");
    sqlite3_stmt* pages;
    require(sqlite3_prepare_v2(raw, "PRAGMA page_count", -1, &pages, null) == SQLITE_OK,
        "prepare page count");
    require(sqlite3_step(pages) == SQLITE_ROW, "read page count");
    auto pageCount = sqlite3_column_int(pages, 0);
    require(sqlite3_finalize(pages) == SQLITE_OK, "finalize page count");
    require(sqlite3_prepare_v2(raw, "PRAGMA cache_size", -1, &pages, null) == SQLITE_OK,
        "prepare cache size");
    require(sqlite3_step(pages) == SQLITE_ROW, "read cache size");
    auto cacheSetting = sqlite3_column_int(pages, 0);
    require(sqlite3_finalize(pages) == SQLITE_OK, "finalize cache size");
    require(sqlite3_exec(raw, "PRAGMA user_version=2", null, null, null) == SQLITE_OK,
        "set incompatible version");
    require(sqlite3_close(raw) == SQLITE_OK, "raw close");
    expectThrow(new LocalManifest(dbPath));
    auto foreign = buildPath(root, "foreign.db");
    require(sqlite3_open_v2(foreign.toStringz, &raw,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, null) == SQLITE_OK,
        "open foreign version test");
    require(sqlite3_exec(raw,
        "CREATE TABLE sqliteXforeign(value INTEGER); INSERT INTO sqliteXforeign VALUES(7)",
        null, null, null) == SQLITE_OK,
        "create foreign table");
    require(sqlite3_close(raw) == SQLITE_OK, "foreign close");
    expectThrow(new LocalManifest(foreign));
    require(sqlite3_open_v2(foreign.toStringz, &raw, SQLITE_OPEN_READWRITE,
        null) == SQLITE_OK, "reopen refused foreign DB");
    require(scalar(raw, "PRAGMA application_id") == 0 &&
        scalar(raw, "PRAGMA user_version") == 0 &&
        scalar(raw, "SELECT count(*) FROM sqliteXforeign WHERE value=7") == 1 &&
        scalar(raw, "SELECT count(*) FROM sqlite_master WHERE name='sink_state'") == 0,
        "foreign DB was modified despite refusal");
    require(sqlite3_close(raw) == SQLITE_OK, "foreign verification close");
    writeln("rows=10102 page=127 gc_delta=", after - before,
        " peak_rss_bytes=", peakRssBytes, " checkpoint_frames=",
        checkpoint.logFrames, "/", checkpoint.checkpointedFrames,
        " db_pages=", pageCount, " db_bytes=", getSize(dbPath),
        " cache_setting=", cacheSetting);
}

void main(string[] args) {
    if (args.length == 5 && args[1] == "--child")
        child(args[2], args[3], args[4]);
    require(args.length == 1, "usage: check");
    bool negativeControl;
    try expectThrow(1 + 1);
    catch (Exception) negativeControl = true;
    require(negativeControl, "release-active exception assertion disabled");
    auto root = buildPath(tempDir(), "manifest-runtime-" ~ randomUUID.toString);
    mkdir(root);
    scope(exit) rmdirRecurse(root);
    checkMatrix(root);
    checkCrash(args[0], root, "before-publish", false);
    checkCrash(args[0], root, "after-publish", false);
    checkCrash(args[0], root, "after-commit", true);
    writeln("manifest runtime PASS");
}
