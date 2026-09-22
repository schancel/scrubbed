/// Explicit v2 local failure journal. This handle never opens or upgrades v1.
module effects.failure_journal;

import effects.sqlite_ffi;
import effects.local_manifest : SinkKey, SinkState, SinkRecord, Inspection,
    validateKey, resolvedName, safeRegularOrAbsent, sameInode, hashFile, nowUtcMs,
    v1Schema;
import effects.atomic_piece_sink : OutputPolicyViolation;
import std.file : exists, isFile, isSymlink, remove;
import std.string : fromStringz, toStringz, indexOf;
import std.uuid : UUID;
import core.sys.posix.sys.stat : stat, lstat, stat_t;
import core.sys.posix.fcntl : open, O_WRONLY, O_CREAT, O_EXCL;
import core.sys.posix.unistd : close;
import core.stdc.errno : errno, EEXIST, ENOENT;
import std.typecons : Nullable, nullable;

private enum applicationId = 1396920898;
private enum v2Schema = `
CREATE TABLE sink_state(
 document_id TEXT NOT NULL,
 input_sha256 BLOB NOT NULL CHECK(length(input_sha256)=32),
 config_sha256 BLOB NOT NULL CHECK(length(config_sha256)=32),
 sink_key TEXT NOT NULL,
 destination TEXT NOT NULL,
 state TEXT NOT NULL CHECK(state IN ('planned','committed','failed','uncertain')),
 output_sha256 BLOB CHECK(output_sha256 IS NULL OR length(output_sha256)=32),
 attempt INTEGER NOT NULL CHECK(attempt>=0),
 updated_utc_ms INTEGER NOT NULL,
 PRIMARY KEY(document_id,input_sha256,config_sha256,sink_key)
) WITHOUT ROWID;
CREATE INDEX sink_state_replay ON sink_state(state,document_id,input_sha256,config_sha256,sink_key);
CREATE TABLE sink_identity(
 raw_sink TEXT PRIMARY KEY NOT NULL,
 sink_id TEXT NOT NULL UNIQUE
) WITHOUT ROWID;
CREATE TABLE error_event(
 sequence INTEGER PRIMARY KEY AUTOINCREMENT,
 event_id TEXT NOT NULL UNIQUE,
 run_id TEXT NOT NULL,
 document_id TEXT NOT NULL,
 input_sha256 BLOB NOT NULL CHECK(length(input_sha256)=32),
 config_sha256 BLOB NOT NULL CHECK(length(config_sha256)=32),
 sink_id TEXT NOT NULL REFERENCES sink_identity(sink_id),
 phase TEXT NOT NULL CHECK(phase IN ('read','decode','filter','sink','manifest',
    'policy','resource','scheduler','log','inspect','retry')),
 code TEXT NOT NULL CHECK(code IN ('read-failed','decode-failed','filter-failed',
    'sink-write-failed','manifest-failed','policy-failed','resource-failed',
    'scheduler-failed','log-failed','inspect-invalidated',
    'sink-publication-interrupted','retry-succeeded')),
 state TEXT NOT NULL CHECK(state IN ('failed','uncertain','committed')),
 retry_of TEXT REFERENCES error_event(event_id),
 time_utc_ms INTEGER NOT NULL
);
CREATE TABLE outstanding(
 document_id TEXT NOT NULL,
 input_sha256 BLOB NOT NULL CHECK(length(input_sha256)=32),
 config_sha256 BLOB NOT NULL CHECK(length(config_sha256)=32),
 sink_key TEXT NOT NULL,
 sink_id TEXT NOT NULL REFERENCES sink_identity(sink_id),
 state TEXT NOT NULL CHECK(state IN ('failed','uncertain')),
 origin TEXT NOT NULL CHECK(origin IN ('event','legacy-v1')),
 event_id TEXT REFERENCES error_event(event_id),
 run_id TEXT,
 time_utc_ms INTEGER,
 PRIMARY KEY(document_id,input_sha256,config_sha256,sink_key),
 CHECK((origin='legacy-v1' AND event_id IS NULL AND run_id IS NULL AND time_utc_ms IS NULL) OR
       (origin='event' AND event_id IS NOT NULL AND run_id IS NOT NULL AND time_utc_ms IS NOT NULL))
) WITHOUT ROWID;
CREATE TABLE publication_intent(
 document_id TEXT NOT NULL,
 input_sha256 BLOB NOT NULL CHECK(length(input_sha256)=32),
 config_sha256 BLOB NOT NULL CHECK(length(config_sha256)=32),
 sink_key TEXT NOT NULL,
 started_utc_ms INTEGER NOT NULL,
 PRIMARY KEY(document_id,input_sha256,config_sha256,sink_key),
 FOREIGN KEY(document_id,input_sha256,config_sha256,sink_key)
 REFERENCES sink_state(document_id,input_sha256,config_sha256,sink_key)
) WITHOUT ROWID;
PRAGMA application_id=1396920898;
PRAGMA user_version=2;
`;

private void need(bool okay, string token) {
    if (!okay) throw new Exception("failure journal: " ~ token);
}

private final class Database {
    sqlite3* handle;
    this(string path, int flags) {
        if (sqlite3_open_v2(path.toStringz, &handle, flags, null) != SQLITE_OK) {
            if (handle !is null) sqlite3_close(handle);
            handle = null;
            throw new Exception("failure journal: open-failed");
        }
        need(sqlite3_busy_timeout(handle, 0) == SQLITE_OK, "busy-timeout-failed");
    }
    ~this() { close(); }
    void close() {
        if (handle !is null) {
            auto prior = handle;
            handle = null;
            need(sqlite3_close(prior) == SQLITE_OK, "close-failed");
        }
    }
    void exec(string sql) {
        need(sqlite3_exec(handle, sql.toStringz, null, null, null) == SQLITE_OK,
            "sql-failed");
    }
    sqlite3_stmt* prepare(string sql) {
        sqlite3_stmt* s;
        need(sqlite3_prepare_v2(handle, sql.toStringz, -1, &s, null) == SQLITE_OK,
            "prepare-failed");
        return s;
    }
    long scalar(string sql) {
        auto s = prepare(sql);
        scope(exit) sqlite3_finalize(s);
        need(sqlite3_step(s) == SQLITE_ROW, "read-failed");
        return sqlite3_column_int64(s, 0);
    }
    string textScalar(string sql) {
        auto s = prepare(sql);
        scope(exit) sqlite3_finalize(s);
        need(sqlite3_step(s) == SQLITE_ROW, "read-failed");
        return sqlite3_column_text(s, 0).fromStringz.idup;
    }
}

private void bindText(sqlite3_stmt* s, int at, string value) {
    need(sqlite3_bind_text(s, at, value.toStringz, cast(int)value.length,
        cast(void*)-1) == SQLITE_OK, "bind-failed");
}
private void bindDigest(sqlite3_stmt* s, int at, ref const(ubyte[32]) value) {
    need(sqlite3_bind_blob(s, at, value.ptr, 32, cast(void*)-1) == SQLITE_OK,
        "bind-failed");
}
private void bindKey(sqlite3_stmt* s, ref const(SinkKey) key) {
    validateKey(key);
    bindText(s, 1, key.document.text);
    bindDigest(s, 2, key.inputSha256);
    bindDigest(s, 3, key.configSha256);
    bindText(s, 4, key.sink);
}
private void bindLong(sqlite3_stmt* s, int at, long value) {
    need(sqlite3_bind_int64(s, at, value) == SQLITE_OK, "bind-failed");
}
private void done(sqlite3_stmt* s) {
    need(sqlite3_step(s) == SQLITE_DONE, "write-failed");
}
private string columnText(sqlite3_stmt* s, int at) {
    auto value = sqlite3_column_text(s, at);
    need(value !is null, "invalid-text");
    return value.fromStringz.idup;
}
private ubyte[32] columnDigest(sqlite3_stmt* s, int at) {
    need(sqlite3_column_bytes(s, at) == 32, "invalid-digest");
    ubyte[32] value;
    value[] = (cast(const(ubyte)*)sqlite3_column_blob(s, at))[0 .. 32];
    return value;
}
private extern(C) void arc4random_buf(void*, size_t);
private extern(C) int renamex_np(const(char)*, const(char)*, uint);
private enum RENAME_EXCL = 0x00000004;
private string uuid() {
    ubyte[16] bytes;
    arc4random_buf(bytes.ptr, bytes.length);
    bytes[6] = cast(ubyte)((bytes[6] & 0x0f) | 0x40);
    bytes[8] = cast(ubyte)((bytes[8] & 0x3f) | 0x80);
    return UUID(bytes).toString;
}

private bool canonicalUuid4(string value) {
    if (value.length != 36 || value[8] != '-' || value[13] != '-' ||
        value[18] != '-' || value[23] != '-' || value[14] != '4' ||
        (value[19] != '8' && value[19] != '9' && value[19] != 'a' &&
         value[19] != 'b')) return false;
    foreach (i, digit; value) {
        if (i == 8 || i == 13 || i == 18 || i == 23) continue;
        if (!((digit >= '0' && digit <= '9') ||
            (digit >= 'a' && digit <= 'f'))) return false;
    }
    return true;
}

private string ensureSinkId(Database db, string raw) {
    auto lookup = db.prepare("SELECT sink_id FROM sink_identity WHERE raw_sink=?1");
    scope(exit) sqlite3_finalize(lookup);
    bindText(lookup, 1, raw);
    auto rc = sqlite3_step(lookup);
    if (rc == SQLITE_ROW) {
        auto id = columnText(lookup, 0);
        need(canonicalUuid4(id) && id != raw, "repair-needed");
        return id;
    }
    need(rc == SQLITE_DONE, "identity-read-failed");
    foreach (_; 0 .. 16) {
        auto candidate = uuid();
        if (candidate == raw) continue;
        auto add = db.prepare("INSERT OR IGNORE INTO sink_identity VALUES(?1,?2)");
        scope(exit) sqlite3_finalize(add);
        bindText(add, 1, raw);
        bindText(add, 2, candidate);
        done(add);
        if (sqlite3_changes(db.handle) == 1) return candidate;
    }
    throw new Exception("failure journal: identity-collision-limit");
}

private void checkVersion(Database db, int wanted) {
    need(db.scalar("PRAGMA application_id") == applicationId &&
        db.scalar("PRAGMA user_version") == wanted, "incompatible-version");
    need(db.textScalar("PRAGMA integrity_check") == "ok", "integrity-failed");
}

private void checkSchema(Database db, string schema, string token) {
    auto expected = new Database(":memory:", SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE);
    scope(exit) expected.close();
    expected.exec(schema);
    auto query = `SELECT type,name,sql FROM sqlite_master
        WHERE name NOT GLOB 'sqlite_*' ORDER BY type,name`;
    auto actualRows = db.prepare(query);
    auto expectedRows = expected.prepare(query);
    scope(exit) { sqlite3_finalize(actualRows); sqlite3_finalize(expectedRows); }
    while (true) {
        auto actual = sqlite3_step(actualRows);
        auto wanted = sqlite3_step(expectedRows);
        need(actual == wanted, token);
        if (actual == SQLITE_DONE) return;
        need(actual == SQLITE_ROW, token);
        foreach (i; 0 .. 3)
            need(columnText(actualRows, i) == columnText(expectedRows, i),
                token);
    }
}

private void rejectHardlink(string path) {
    stat_t info;
    need(stat(path.toStringz, &info) == 0 && info.st_nlink == 1,
        "database-hardlink-refused");
}

private bool pathPresent(string path) {
    stat_t info;
    if (lstat(path.toStringz, &info) == 0) return true;
    need(errno == ENOENT, "path-check-failed");
    return false;
}

private string reserveStage(string target) {
    foreach (_; 0 .. 16) {
        auto stage = target ~ ".stage-" ~ uuid();
        auto fd = open(stage.toStringz, O_WRONLY | O_CREAT | O_EXCL, 384);
        if (fd >= 0) {
            need(close(fd) == 0, "stage-close-failed");
            if (pathPresent(stage ~ "-wal") || pathPresent(stage ~ "-shm")) {
                remove(stage);
                continue;
            }
            return stage;
        }
        if (errno != EEXIST) break;
    }
    throw new Exception("failure journal: stage-create-failed");
}

private void checkV2Shape(Database db) {
    checkSchema(db, v2Schema, "invalid-v2-schema");
    need(db.scalar(`SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN
        ('sink_state','sink_identity','error_event','outstanding',
         'publication_intent')`) == 5,
        "missing-v2-table");
    need(db.scalar(`SELECT count(*) FROM sqlite_master WHERE type='trigger'`) == 0,
        "unexpected-trigger");
    need(db.scalar(`SELECT count(*) FROM sink_state s LEFT JOIN outstanding o USING
        (document_id,input_sha256,config_sha256,sink_key)
        WHERE (s.state IN ('failed','uncertain') AND o.document_id IS NULL)
           OR (o.document_id IS NOT NULL AND
               (s.state='committed' OR
                (s.state IN ('failed','uncertain') AND s.state!=o.state)))`) == 0,
        "repair-needed");
    need(db.scalar(`SELECT count(*) FROM outstanding o LEFT JOIN sink_state s USING
        (document_id,input_sha256,config_sha256,sink_key) WHERE s.document_id IS NULL`) == 0,
        "repair-needed");
    need(db.scalar(`SELECT count(*) FROM outstanding o LEFT JOIN sink_identity i
        ON o.sink_key=i.raw_sink WHERE i.sink_id IS NULL OR i.sink_id!=o.sink_id`) == 0,
        "repair-needed");
    need(db.scalar(`SELECT count(*) FROM sink_state s LEFT JOIN sink_identity i
        ON s.sink_key=i.raw_sink WHERE i.sink_id IS NULL`) == 0,
        "repair-needed");
    need(db.scalar(`SELECT count(*) FROM outstanding o LEFT JOIN error_event e
        ON o.event_id=e.event_id WHERE o.origin='event' AND
        (e.event_id IS NULL OR e.document_id!=o.document_id OR
         e.input_sha256!=o.input_sha256 OR e.config_sha256!=o.config_sha256 OR
         e.sink_id!=o.sink_id OR e.state!=o.state)`) == 0,
        "repair-needed");
    need(db.scalar(`SELECT count(*) FROM error_event e LEFT JOIN sink_identity i
        ON e.sink_id=i.sink_id WHERE i.raw_sink IS NULL`) == 0,
        "repair-needed");
    need(db.scalar("SELECT count(*) FROM pragma_foreign_key_check") == 0,
        "repair-needed");
    need(db.scalar(`SELECT count(*) FROM publication_intent p LEFT JOIN sink_state s USING
        (document_id,input_sha256,config_sha256,sink_key)
        WHERE s.document_id IS NULL OR s.state!='planned'`) == 0,
        "repair-needed");
    auto identities = db.prepare("SELECT raw_sink,sink_id FROM sink_identity");
    scope(exit) sqlite3_finalize(identities);
    int rc;
    while ((rc = sqlite3_step(identities)) == SQLITE_ROW)
        need(canonicalUuid4(columnText(identities, 1)) &&
            columnText(identities, 0) != columnText(identities, 1),
            "repair-needed");
    need(rc == SQLITE_DONE, "identity-read-failed");
}

/// Create a fresh v2 database explicitly. Neither constructor nor v1 reader
/// silently creates or upgrades one.
void createV2(string newPath) {
    auto target = resolvedName(newPath);
    foreach (suffix; ["", "-wal", "-shm"]) {
        safeRegularOrAbsent(target ~ suffix);
        need(!exists(target ~ suffix), "destination-exists");
    }
    auto stage = reserveStage(target);
    bool published;
    scope(exit) if (!published) foreach (suffix; ["", "-wal", "-shm"])
        if (exists(stage ~ suffix)) remove(stage ~ suffix);
    auto db = new Database(stage, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE);
    db.exec("PRAGMA journal_mode=WAL");
    db.exec("PRAGMA synchronous=FULL");
    db.exec("PRAGMA foreign_keys=ON");
    db.exec("BEGIN IMMEDIATE");
    db.exec(v2Schema);
    db.exec("COMMIT");
    checkVersion(db, 2);
    checkV2Shape(db);
    db.close();
    need(!exists(target) && !exists(target ~ "-wal") && !exists(target ~ "-shm"),
        "destination-raced");
    need(renamex_np(stage.toStringz, target.toStringz, RENAME_EXCL) == 0,
        "destination-raced");
    published = true;
}

/// The v2 handle is the only mutator of its sink_state table. A v1 LocalManifest
/// rejects its version, so the old unjournaled mutators cannot bypass it.
final class FailureJournal {
    private Database db;
    private string databasePath;
    private bool poisoned;
    private string runId;

    this(string path) {
        databasePath = resolvedName(path);
        safeRegularOrAbsent(databasePath);
        safeRegularOrAbsent(databasePath ~ "-wal");
        safeRegularOrAbsent(databasePath ~ "-shm");
        need(exists(databasePath), "v2-missing-explicit-create-required");
        rejectHardlink(databasePath);
        db = new Database(databasePath, SQLITE_OPEN_READWRITE);
        try {
            need(sqlite3_libversion().fromStringz == "3.53.4", "wrong-sqlite-version");
            checkVersion(db, 2);
            db.exec("PRAGMA foreign_keys=ON");
            checkV2Shape(db);
            db.exec("PRAGMA journal_mode=WAL");
            db.exec("PRAGMA synchronous=FULL");
            need(db.textScalar("PRAGMA journal_mode") == "wal" &&
                db.scalar("PRAGMA synchronous") == 2, "durability-mode-unavailable");
            this.runId = uuid();
            recoverIntents();
        } catch (Throwable failure) { db.close(); throw failure; }
    }
    void close() { if (db !is null) db.close(); db = null; }
    private void live() { need(db !is null && !poisoned, "fail-stop"); }
    private void transaction(void delegate() operation) {
        live();
        try {
            fault("begin");
            db.exec("BEGIN IMMEDIATE");
            operation();
            fault("write");
            fault("commit");
            db.exec("COMMIT");
            fault("ack");
        } catch (Throwable failure) {
            poisoned = true;
            try db.exec("ROLLBACK"); catch (Throwable ignored) {}
            throw failure;
        }
    }
    private void fault(string point) {
        version (FailurePolicyHarness) {
            if (exists(databasePath ~ ".fault-v2-kill-" ~ point)) {
                import core.sys.posix.unistd : _exit;
                _exit(73);
            }
            need(!exists(databasePath ~ ".fault-v2-" ~ point), "injected-" ~ point);
        }
    }
    private string sinkId(string raw) {
        return ensureSinkId(db, raw);
    }
    private string existingSinkId(string raw) {
        auto s = db.prepare("SELECT sink_id FROM sink_identity WHERE raw_sink=?1");
        scope(exit) sqlite3_finalize(s);
        bindText(s, 1, raw);
        need(sqlite3_step(s) == SQLITE_ROW, "repair-needed");
        auto id = columnText(s, 0);
        need(canonicalUuid4(id) && id != raw, "repair-needed");
        return id;
    }
    private void safeDestination(string destination) {
        auto selected = resolvedName(destination);
        safeRegularOrAbsent(selected, true);
        foreach (suffix; ["", "-wal", "-shm"])
            if (selected == databasePath ~ suffix ||
                sameInode(selected, databasePath ~ suffix))
                throw new OutputPolicyViolation("failure journal: destination aliases database");
    }
    Nullable!SinkRecord lookup(SinkKey key) {
        live();
        auto s = db.prepare(`SELECT destination,state,output_sha256,attempt,updated_utc_ms
            FROM sink_state WHERE document_id=?1 AND input_sha256=?2 AND config_sha256=?3 AND sink_key=?4`);
        scope(exit) sqlite3_finalize(s);
        bindKey(s, key);
        auto rc = sqlite3_step(s);
        if (rc == SQLITE_DONE) return Nullable!SinkRecord.init;
        need(rc == SQLITE_ROW, "lookup-failed");
        SinkRecord row;
        row.key = key;
        row.destination = columnText(s, 0);
        row.state = cast(SinkState)columnText(s, 1);
        row.hasOutput = sqlite3_column_type(s, 2) != SQLITE_NULL;
        if (row.hasOutput) row.outputSha256 = columnDigest(s, 2);
        row.attempt = sqlite3_column_int64(s, 3);
        row.updatedUtcMs = sqlite3_column_int64(s, 4);
        return nullable(row);
    }
    void plan(SinkKey key, string destination) {
        live();
        safeDestination(destination);
        auto previous = lookup(key);
        if (!previous.isNull) {
            need(previous.get.destination == resolvedName(destination), "destination-changed");
            return;
        }
        transaction({
            sinkId(key.sink);
            auto s = db.prepare(`INSERT INTO sink_state VALUES(?1,?2,?3,?4,?5,'planned',NULL,0,?6)`);
            scope(exit) sqlite3_finalize(s);
            bindKey(s, key);
            bindText(s, 5, resolvedName(destination));
            bindLong(s, 6, nowUtcMs());
            done(s);
        });
        try { need(!lookup(key).isNull, "ack-failed"); }
        catch (Throwable failure) { poisoned = true; throw failure; }
    }
    private void updateState(SinkKey key, SinkState state, bool output, ubyte[32] digest) {
        auto s = db.prepare(`UPDATE sink_state SET state=?5,output_sha256=?6,
            attempt=attempt+1,updated_utc_ms=?7 WHERE document_id=?1 AND
            input_sha256=?2 AND config_sha256=?3 AND sink_key=?4`);
        scope(exit) sqlite3_finalize(s);
        bindKey(s, key);
        bindText(s, 5, cast(string)state);
        if (output) bindDigest(s, 6, digest);
        bindLong(s, 7, nowUtcMs());
        done(s);
        need(sqlite3_changes(db.handle) == 1, "missing-sink-state");
    }
    private bool hasIntent(SinkKey key) {
        auto s = db.prepare(`SELECT count(*) FROM publication_intent WHERE document_id=?1 AND
            input_sha256=?2 AND config_sha256=?3 AND sink_key=?4`);
        scope(exit) sqlite3_finalize(s);
        bindKey(s, key);
        need(sqlite3_step(s) == SQLITE_ROW, "intent-read-failed");
        return sqlite3_column_int64(s, 0) == 1;
    }
    private void deleteIntent(SinkKey key) {
        auto s = db.prepare(`DELETE FROM publication_intent WHERE document_id=?1 AND
            input_sha256=?2 AND config_sha256=?3 AND sink_key=?4`);
        scope(exit) sqlite3_finalize(s);
        bindKey(s, key);
        done(s);
    }
    /// Call and acknowledge before writing any output bytes. Until success is
    /// committed, a restart conservatively treats this intent as uncertainty.
    void beginPublication(SinkKey key) {
        live();
        auto row = lookup(key);
        need(!row.isNull && row.get.state == SinkState.planned && !hasIntent(key),
            "publication-requires-plan");
        safeDestination(row.get.destination);
        transaction({
            auto s = db.prepare(`INSERT INTO publication_intent VALUES(?1,?2,?3,?4,?5)`);
            scope(exit) sqlite3_finalize(s);
            bindKey(s, key);
            bindLong(s, 5, nowUtcMs());
            done(s);
        });
        try { need(hasIntent(key), "ack-failed"); }
        catch (Throwable failure) { poisoned = true; throw failure; }
    }
    private void recoverIntents() {
        while (true) {
            string document, raw;
            ubyte[32] input, config;
            bool finished;
            {
                auto s = db.prepare(`SELECT document_id,input_sha256,config_sha256,sink_key
                    FROM publication_intent LIMIT 1`);
                scope(exit) sqlite3_finalize(s);
                auto rc = sqlite3_step(s);
                finished = rc == SQLITE_DONE;
                if (!finished) {
                    need(rc == SQLITE_ROW, "intent-read-failed");
                    document = columnText(s, 0);
                    input = columnDigest(s, 1);
                    config = columnDigest(s, 2);
                    raw = columnText(s, 3);
                }
            }
            if (finished) { checkV2Shape(db); return; }
            auto eventId = uuid();
            auto at = nowUtcMs();
            transaction({
                auto event = db.prepare(`INSERT INTO error_event(event_id,run_id,document_id,
                    input_sha256,config_sha256,sink_id,phase,code,state,retry_of,time_utc_ms)
                    SELECT ?1,?2,?3,?4,?5,i.sink_id,'sink',
                    'sink-publication-interrupted','uncertain',NULL,?7
                    FROM sink_identity i WHERE i.raw_sink=?6`);
                scope(exit) sqlite3_finalize(event);
                bindText(event, 1, eventId);
                bindText(event, 2, runId);
                bindText(event, 3, document);
                bindDigest(event, 4, input);
                bindDigest(event, 5, config);
                bindText(event, 6, raw);
                bindLong(event, 7, at);
                done(event);
                need(sqlite3_changes(db.handle) == 1, "repair-needed");
                auto state = db.prepare(`UPDATE sink_state SET state='uncertain',
                    output_sha256=NULL,attempt=attempt+1,updated_utc_ms=?5
                    WHERE document_id=?1 AND input_sha256=?2 AND config_sha256=?3
                    AND sink_key=?4 AND state='planned'`);
                scope(exit) sqlite3_finalize(state);
                bindText(state, 1, document);
                bindDigest(state, 2, input);
                bindDigest(state, 3, config);
                bindText(state, 4, raw);
                bindLong(state, 5, at);
                done(state);
                need(sqlite3_changes(db.handle) == 1, "repair-needed");
                auto outstanding = db.prepare(`INSERT INTO outstanding VALUES(
                    ?1,?2,?3,?4,(SELECT sink_id FROM sink_identity WHERE raw_sink=?4),
                    'uncertain','event',?5,?6,?7)
                    ON CONFLICT(document_id,input_sha256,config_sha256,sink_key)
                    DO UPDATE SET state='uncertain',origin='event',
                    event_id=excluded.event_id,run_id=excluded.run_id,
                    time_utc_ms=excluded.time_utc_ms`);
                scope(exit) sqlite3_finalize(outstanding);
                bindText(outstanding, 1, document);
                bindDigest(outstanding, 2, input);
                bindDigest(outstanding, 3, config);
                bindText(outstanding, 4, raw);
                bindText(outstanding, 5, eventId);
                bindText(outstanding, 6, runId);
                bindLong(outstanding, 7, at);
                done(outstanding);
                auto clear = db.prepare(`DELETE FROM publication_intent WHERE
                    document_id=?1 AND input_sha256=?2 AND config_sha256=?3 AND sink_key=?4`);
                scope(exit) sqlite3_finalize(clear);
                bindText(clear, 1, document);
                bindDigest(clear, 2, input);
                bindDigest(clear, 3, config);
                bindText(clear, 4, raw);
                done(clear);
                need(sqlite3_changes(db.handle) == 1, "repair-needed");
            });
        }
    }
    private string outstandingEvent(SinkKey key) {
        auto s = db.prepare(`SELECT event_id FROM outstanding WHERE document_id=?1 AND
            input_sha256=?2 AND config_sha256=?3 AND sink_key=?4`);
        scope(exit) sqlite3_finalize(s);
        bindKey(s, key);
        auto rc = sqlite3_step(s);
        if (rc == SQLITE_DONE) return "";
        need(rc == SQLITE_ROW, "outstanding-read-failed");
        return sqlite3_column_type(s, 0) == SQLITE_NULL ? "" : columnText(s, 0);
    }
    private string outstandingState(SinkKey key) {
        auto s = db.prepare(`SELECT state FROM outstanding WHERE document_id=?1 AND
            input_sha256=?2 AND config_sha256=?3 AND sink_key=?4`);
        scope(exit) sqlite3_finalize(s);
        bindKey(s, key);
        auto rc = sqlite3_step(s);
        if (rc == SQLITE_DONE) return "";
        need(rc == SQLITE_ROW, "outstanding-read-failed");
        return columnText(s, 0);
    }
    private void append(SinkKey key, string sinkId, string eventId,
            string phase, string code, SinkState state, string prior, long at) {
        auto s = db.prepare(`INSERT INTO error_event(event_id,run_id,document_id,input_sha256,
            config_sha256,sink_id,phase,code,state,retry_of,time_utc_ms)
            VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)`);
        scope(exit) sqlite3_finalize(s);
        bindText(s, 1, eventId);
        bindText(s, 2, runId);
        bindText(s, 3, key.document.text);
        bindDigest(s, 4, key.inputSha256);
        bindDigest(s, 5, key.configSha256);
        bindText(s, 6, sinkId);
        bindText(s, 7, phase);
        bindText(s, 8, code);
        bindText(s, 9, cast(string)state);
        if (prior.length) bindText(s, 10, prior);
        bindLong(s, 11, at);
        done(s);
    }
    /// One fixed-code event and exact-key state transition, acknowledged as a unit.
    void recordFailure(SinkKey key, string phase, string code, bool sinkTouched) {
        need(phase != "inspect", "inspect-event-reserved");
        recordFailureInternal(key, phase, code, sinkTouched);
    }
    private void recordFailureInternal(SinkKey key, string phase, string code,
            bool sinkTouched) {
        live();
        bool generic = phase == "read" || phase == "decode" || phase == "filter" ||
            phase == "manifest" || phase == "policy" || phase == "resource" ||
            phase == "scheduler" || phase == "log";
        need((generic && code == phase ~ "-failed") ||
            (phase == "sink" && code == "sink-write-failed") ||
            (phase == "inspect" && code == "inspect-invalidated"),
            "invalid-event-code");
        auto prior = lookup(key);
        need(!prior.isNull, "plan-required");
        need(prior.get.state != SinkState.committed || phase == "inspect",
            "committed-requires-inspect");
        // A previous possibly published output is still uncertain even when
        // the current attempt fails before touching the sink.
        auto state = sinkTouched || hasIntent(key) ||
            prior.get.state == SinkState.uncertain ||
            outstandingState(key) == "uncertain" ?
            SinkState.uncertain : SinkState.failed;
        auto eventId = uuid();
        transaction({
            auto id = sinkId(key.sink);
            auto at = nowUtcMs();
            append(key, id, eventId, phase, code, state, "", at);
            updateState(key, state, false, ubyte[32].init);
            auto s = db.prepare(`INSERT INTO outstanding VALUES(?1,?2,?3,?4,?5,?6,
                'event',?7,?8,?9) ON CONFLICT(document_id,input_sha256,config_sha256,sink_key)
                DO UPDATE SET sink_id=excluded.sink_id,state=excluded.state,origin='event',
                event_id=excluded.event_id,run_id=excluded.run_id,time_utc_ms=excluded.time_utc_ms`);
            scope(exit) sqlite3_finalize(s);
            bindKey(s, key);
            bindText(s, 5, id);
            bindText(s, 6, cast(string)state);
            bindText(s, 7, eventId);
            bindText(s, 8, runId);
            bindLong(s, 9, at);
            done(s);
            deleteIntent(key);
        });
        try {
            need(lookup(key).get.state == state && outstandingEvent(key) == eventId,
                "ack-failed");
        } catch (Throwable failure) { poisoned = true; throw failure; }
    }
    /// Planning a retry leaves the outstanding row in place until publication.
    void retry(SinkKey key) {
        live();
        auto prior = lookup(key);
        need(!prior.isNull && prior.get.state != SinkState.committed,
            "retry-invalid-state");
        need(!hasIntent(key), "publication-in-progress");
        safeDestination(prior.get.destination);
        auto hadOutstanding = hasOutstanding(key);
        transaction({ updateState(key, SinkState.planned, false, ubyte[32].init); });
        try { need(lookup(key).get.state == SinkState.planned &&
            hasOutstanding(key) == hadOutstanding, "ack-failed"); }
        catch (Throwable failure) { poisoned = true; throw failure; }
    }
    /// The output is rehashed before its success event clears the exact key.
    void commitPublished(SinkKey key, string destination, ubyte[32] expected) {
        live();
        auto prior = lookup(key);
        need(!prior.isNull && prior.get.state == SinkState.planned,
            "commit-requires-plan");
        need(hasIntent(key), "publication-intent-required");
        need(prior.get.destination == resolvedName(destination), "destination-changed");
        safeDestination(destination);
        need(exists(destination) && hashFile(destination) == expected,
            "published-output-mismatch");
        auto hadOutstanding = hasOutstanding(key);
        string successEvent;
        transaction({
            if (hadOutstanding) {
                auto priorEvent = outstandingEvent(key);
                successEvent = uuid();
                append(key, existingSinkId(key.sink), successEvent, "retry",
                    "retry-succeeded", SinkState.committed, priorEvent, nowUtcMs());
            }
            updateState(key, SinkState.committed, true, expected);
            auto s = db.prepare(`DELETE FROM outstanding WHERE document_id=?1 AND
                input_sha256=?2 AND config_sha256=?3 AND sink_key=?4`);
            scope(exit) sqlite3_finalize(s);
            bindKey(s, key);
            done(s);
            need(sqlite3_changes(db.handle) == (hadOutstanding ? 1 : 0),
                "outstanding-mismatch");
            deleteIntent(key);
        });
        try {
            need(lookup(key).get.state == SinkState.committed &&
                !hasOutstanding(key) && !hasIntent(key),
                "ack-failed");
            if (hadOutstanding) {
                auto s = db.prepare("SELECT count(*) FROM error_event WHERE event_id=?1");
                scope(exit) sqlite3_finalize(s);
                bindText(s, 1, successEvent);
                need(sqlite3_step(s) == SQLITE_ROW && sqlite3_column_int64(s, 0) == 1,
                    "ack-failed");
            }
        } catch (Throwable failure) { poisoned = true; throw failure; }
    }
    bool hasOutstanding(SinkKey key) {
        live();
        auto s = db.prepare(`SELECT count(*) FROM outstanding WHERE document_id=?1 AND
            input_sha256=?2 AND config_sha256=?3 AND sink_key=?4`);
        scope(exit) sqlite3_finalize(s);
        bindKey(s, key);
        need(sqlite3_step(s) == SQLITE_ROW, "outstanding-read-failed");
        return sqlite3_column_int64(s, 0) == 1;
    }
    Inspection inspect(SinkKey key) {
        live();
        auto prior = lookup(key);
        if (prior.isNull) return Inspection.absent;
        if (prior.get.state != SinkState.committed) return Inspection.retryRequired;
        auto row = prior.get;
        if (row.hasOutput && exists(row.destination) &&
            !isSymlink(row.destination) && isFile(row.destination) &&
            hashFile(row.destination) == row.outputSha256)
            return Inspection.verifiedCommitted;
        recordFailureInternal(key, "inspect", "inspect-invalidated", true);
        return Inspection.retryRequired;
    }
    long eventCount() { live(); return db.scalar("SELECT count(*) FROM error_event"); }
    string publicSinkId(string raw) { live(); return existingSinkId(raw); }
}

/// Explicit offline copy. The destination is first built under a new sibling
/// name, field-compared, then published by rename; v1 is never mutated.
void copyV1ToV2(string sourcePath, string newPath) {
    auto source = resolvedName(sourcePath);
    auto target = resolvedName(newPath);
    need(exists(source), "v1-missing");
    safeRegularOrAbsent(source);
    safeRegularOrAbsent(source ~ "-wal");
    safeRegularOrAbsent(source ~ "-shm");
    rejectHardlink(source);
    foreach (suffix; ["-wal", "-shm"])
        if (exists(source ~ suffix)) rejectHardlink(source ~ suffix);
    foreach (suffix; ["", "-wal", "-shm"]) {
        safeRegularOrAbsent(target ~ suffix);
        need(!exists(target ~ suffix), "destination-exists");
        need(target ~ suffix != source && target ~ suffix != source ~ "-wal" &&
            target ~ suffix != source ~ "-shm", "destination-alias");
    }
    need(!sameInode(source, target), "destination-alias");
    auto stage = reserveStage(target);
    Database src;
    Database dst;
    bool published;
    scope(exit) {
        if (dst !is null) dst.close();
        if (src !is null) src.close();
        if (!published) foreach (suffix; ["", "-wal", "-shm"])
            if (exists(stage ~ suffix)) remove(stage ~ suffix);
    }
    src = new Database(source, SQLITE_OPEN_READWRITE);
    checkVersion(src, 1);
    checkSchema(src, v1Schema, "invalid-v1-schema");
    src.exec("PRAGMA journal_mode=WAL");
    src.exec("PRAGMA synchronous=FULL");
    int logFrames, checkpointed;
    need(sqlite3_wal_checkpoint_v2(src.handle, "main".toStringz,
        SQLITE_CHECKPOINT_TRUNCATE, &logFrames, &checkpointed) == SQLITE_OK &&
        logFrames == 0 && checkpointed == 0, "v1-busy-or-checkpoint-failed");
    src.exec("BEGIN IMMEDIATE");
    dst = new Database(stage, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE);
    dst.exec("PRAGMA journal_mode=WAL");
    dst.exec("PRAGMA synchronous=FULL");
    dst.exec("PRAGMA foreign_keys=ON");
    dst.exec("BEGIN IMMEDIATE");
    dst.exec(v2Schema);
    auto rows = src.prepare(`SELECT document_id,input_sha256,config_sha256,sink_key,
        destination,state,output_sha256,attempt,updated_utc_ms FROM sink_state
        ORDER BY document_id,input_sha256,config_sha256,sink_key`);
    scope(exit) sqlite3_finalize(rows);
    long copied;
    int rc;
    while ((rc = sqlite3_step(rows)) == SQLITE_ROW) {
        auto document = columnText(rows, 0);
        need(((document.length == 71 && document[0 .. 7] == "doc:v1:") ||
            (document.length == 73 && document[0 .. 9] == "child:v1:")),
            "invalid-v1-key");
        foreach (digit; document[$ - 64 .. $])
            need((digit >= '0' && digit <= '9') || (digit >= 'a' && digit <= 'f'),
                "invalid-v1-key");
        auto input = columnDigest(rows, 1);
        auto config = columnDigest(rows, 2);
        auto raw = columnText(rows, 3);
        need(raw.length && raw.indexOf('\0') < 0, "invalid-v1-key");
        auto destination = columnText(rows, 4);
        need(destination.length && destination.indexOf('\0') < 0,
            "invalid-v1-destination");
        auto state = columnText(rows, 5);
        need(state == "planned" || state == "committed" ||
            state == "failed" || state == "uncertain", "invalid-v1-state");
        bool hasOutput = sqlite3_column_type(rows, 6) != SQLITE_NULL;
        ubyte[32] output;
        if (hasOutput) output = columnDigest(rows, 6);
        need((state == "committed") == hasOutput, "invalid-v1-output-state");
        auto attempt = sqlite3_column_int64(rows, 7);
        auto updated = sqlite3_column_int64(rows, 8);
        need(attempt >= 0, "invalid-v1-attempt");
        auto insert = dst.prepare(`INSERT INTO sink_state VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)`);
        bindText(insert, 1, document);
        bindDigest(insert, 2, input);
        bindDigest(insert, 3, config);
        bindText(insert, 4, raw);
        bindText(insert, 5, destination);
        bindText(insert, 6, state);
        if (hasOutput) bindDigest(insert, 7, output);
        bindLong(insert, 8, attempt);
        bindLong(insert, 9, updated);
        done(insert);
        sqlite3_finalize(insert);
        auto publicId = ensureSinkId(dst, raw);
        if (state == "failed" || state == "uncertain") {
            auto add = dst.prepare(`INSERT INTO outstanding(document_id,input_sha256,
                config_sha256,sink_key,sink_id,state,origin) VALUES(?1,?2,?3,?4,?5,?6,'legacy-v1')`);
            bindText(add, 1, document);
            bindDigest(add, 2, input);
            bindDigest(add, 3, config);
            bindText(add, 4, raw);
            bindText(add, 5, publicId);
            bindText(add, 6, state);
            done(add);
            sqlite3_finalize(add);
        }
        ++copied;
    }
    need(rc == SQLITE_DONE, "v1-read-failed");
    need(sqlite3_finalize(rows) == SQLITE_OK, "v1-read-finalize-failed");
    rows = null;
    need(copied == src.scalar("SELECT count(*) FROM sink_state") &&
        copied == dst.scalar("SELECT count(*) FROM sink_state") &&
        dst.scalar("SELECT count(*) FROM error_event") == 0,
        "copy-count-mismatch");
    // Compare every v1 field through the locked source and staged v2 cursors.
    auto verify = dst.prepare(`SELECT document_id,input_sha256,config_sha256,sink_key,
        destination,state,output_sha256,attempt,updated_utc_ms FROM sink_state
        ORDER BY document_id,input_sha256,config_sha256,sink_key`);
    auto original = src.prepare(`SELECT document_id,input_sha256,config_sha256,sink_key,
        destination,state,output_sha256,attempt,updated_utc_ms FROM sink_state
        ORDER BY document_id,input_sha256,config_sha256,sink_key`);
    scope(exit) { sqlite3_finalize(verify); sqlite3_finalize(original); }
    while (true) {
        auto a = sqlite3_step(original);
        auto b = sqlite3_step(verify);
        need(a == b, "copy-field-mismatch");
        if (a == SQLITE_DONE) break;
        need(a == SQLITE_ROW, "copy-verify-failed");
        foreach (i; 0 .. 9) {
            need(sqlite3_column_type(original, i) == sqlite3_column_type(verify, i) &&
                sqlite3_column_bytes(original, i) == sqlite3_column_bytes(verify, i),
                "copy-field-mismatch");
            auto n = sqlite3_column_bytes(original, i);
            if (n) {
                auto left = sqlite3_column_blob(original, i);
                auto right = sqlite3_column_blob(verify, i);
                need((cast(const(ubyte)*)left)[0 .. n] ==
                    (cast(const(ubyte)*)right)[0 .. n], "copy-field-mismatch");
            }
        }
    }
    need(sqlite3_finalize(verify) == SQLITE_OK &&
        sqlite3_finalize(original) == SQLITE_OK, "copy-verify-finalize-failed");
    verify = null;
    original = null;
    checkV2Shape(dst);
    dst.exec("COMMIT");
    dst.close(); dst = null;
    src.exec("COMMIT");
    src.close(); src = null;
    need(!exists(target) && !exists(target ~ "-wal") && !exists(target ~ "-shm"),
        "destination-raced");
    need(renamex_np(stage.toStringz, target.toStringz, RENAME_EXCL) == 0,
        "destination-raced");
    published = true;
}
