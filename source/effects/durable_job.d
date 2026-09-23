/// Canonical compiled-job durability for local file/tree routes.
///
/// This module owns only derived durable identity and ordered terminal-event
/// state. It deliberately does not import the job model: callers compile and
/// derive identity before opening durable state.
module effects.durable_job;

import domain.document : DocumentId;
import effects.atomic_piece_sink : OutputPolicyViolation;
import effects.local_manifest : hashFile, nowUtcMs, resolvedName,
    safeRegularOrAbsent, sameInode;
import effects.sqlite_ffi;
import std.conv : to;
import std.digest : LetterCase, toHexString;
import std.digest.sha : SHA256, sha256Of;
import std.file : exists, isFile, isSymlink, remove;
import std.path : absolutePath, buildNormalizedPath;
import std.string : fromStringz, indexOf, toStringz;
import std.uuid : UUID;
import core.sys.posix.fcntl : O_NOFOLLOW, O_RDONLY, open;
import core.sys.posix.sys.stat : fstat, lstat, stat, stat_t, S_ISLNK;
import core.sys.posix.unistd : close, pread;

enum DurableKind { manifest, journal }
enum DurableEventState : string {
    planned = "planned", committed = "committed", acknowledged = "acknowledged",
    failed = "failed", uncertain = "uncertain"
}
enum DurableAction { publish, skip }

struct DurableIdentity {
    ubyte[32] digest;
    string jobIdentity;
}

struct DurableRootKey {
    DocumentId document;
    ubyte[32] inputSha256;
    ubyte[32] configSha256;
}

struct DurableEventPlan {
    size_t ordinal;
    string kind;
    DocumentId document;
    string outputName;
    ubyte[32] reasonSha256;
    bool hasReason;
    string sink;
    string destination;
    ubyte[32] outputSha256;
    bool hasOutput;
}

struct DurableEventRecord {
    DurableEventPlan plan;
    DurableEventState state;
    long attempt;
}

private enum applicationId = 1396920898;
version (unittest) private __gshared size_t aliasRowsInspected;

private uint headerU32(const(ubyte)[] header, size_t offset) {
    return (cast(uint)header[offset] << 24) |
        (cast(uint)header[offset + 1] << 16) |
        (cast(uint)header[offset + 2] << 8) | header[offset + 3];
}

private bool pathIsSymlink(string path) {
    stat_t info;
    return lstat(path.toStringz, &info) == 0 && S_ISLNK(info.st_mode);
}

private bool needsInodeAliasScan(string path) {
    stat_t info;
    need(lstat(path.toStringz, &info) == 0, "destination-stat-failed");
    return info.st_nlink > 1;
}

// Refuse recognized predecessor formats before SQLite can perform recovery or
// checkpoint work. This deliberately reads only documented fixed header fields.
private void preflightDatabaseHeader(string path, DurableKind kind) {
    auto fd = open(path.toStringz, O_RDONLY | O_NOFOLLOW);
    need(fd >= 0, "header-open-failed");
    scope(exit) need(close(fd) == 0, "header-close-failed");
    stat_t before, after;
    ubyte[100] first, second;
    need(fstat(fd, &before) == 0 && before.st_size >= first.length,
        "invalid-database-header");
    need(pread(fd, first.ptr, first.length, 0) == first.length &&
        pread(fd, second.ptr, second.length, 0) == second.length &&
        fstat(fd, &after) == 0 && first[] == second[] &&
        before.st_dev == after.st_dev && before.st_ino == after.st_ino &&
        before.st_size == after.st_size, "unstable-database-header");
    immutable ubyte[16] magic = cast(immutable(ubyte)[])"SQLite format 3\0";
    auto pageSize = (cast(uint)first[16] << 8) | first[17];
    if (pageSize == 1) pageSize = 65_536;
    need(first[0 .. 16] == magic[] &&
        (first[18] == 1 || first[18] == 2) &&
        (first[19] == 1 || first[19] == 2) &&
        pageSize >= 512 && pageSize <= 65_536 &&
        (pageSize & (pageSize - 1)) == 0 &&
        first[20] == 0 && first[21] == 64 && first[22] == 32 && first[23] == 32 &&
        headerU32(first, 44) == 4, "invalid-database-header");
    auto application = headerU32(first, 68);
    auto version_ = headerU32(first, 60);
    if (application == applicationId && kind == DurableKind.manifest && version_ == 1)
        throw new Exception("durable job: manifest-v1-requires-fresh-v2");
    if (application == applicationId && kind == DurableKind.journal && version_ == 2)
        throw new Exception("durable job: journal-v2-requires-fresh-v3");
    need(application == applicationId && version_ ==
        (kind == DurableKind.manifest ? 2 : 3), "incompatible-database-header");
}
private enum commonSchema = `
CREATE TABLE root_state(
 document_id TEXT NOT NULL,
 input_sha256 BLOB NOT NULL CHECK(length(input_sha256)=32),
 config_sha256 BLOB NOT NULL CHECK(length(config_sha256)=32),
 job_identity TEXT NOT NULL,
 event_count INTEGER CHECK(event_count IS NULL OR event_count>0),
 event_set_sha256 BLOB CHECK(event_set_sha256 IS NULL OR length(event_set_sha256)=32),
 state TEXT NOT NULL CHECK(state IN ('planned','complete')),
 updated_utc_ms INTEGER NOT NULL,
 PRIMARY KEY(document_id,input_sha256,config_sha256),
 CHECK((event_count IS NULL)=(event_set_sha256 IS NULL))
) WITHOUT ROWID;
CREATE TABLE final_event(
 document_id TEXT NOT NULL,
 input_sha256 BLOB NOT NULL CHECK(length(input_sha256)=32),
 config_sha256 BLOB NOT NULL CHECK(length(config_sha256)=32),
 ordinal INTEGER NOT NULL CHECK(ordinal>=0),
 kind TEXT NOT NULL CHECK(kind IN ('emitted','rejected','quarantined')),
 final_document_id TEXT NOT NULL,
 output_name TEXT NOT NULL,
 reason_sha256 BLOB CHECK(reason_sha256 IS NULL OR length(reason_sha256)=32),
 sink_key TEXT NOT NULL,
 destination TEXT,
 output_sha256 BLOB CHECK(output_sha256 IS NULL OR length(output_sha256)=32),
 state TEXT NOT NULL CHECK(state IN ('planned','committed','acknowledged','failed','uncertain')),
 attempt INTEGER NOT NULL CHECK(attempt>=0),
 updated_utc_ms INTEGER NOT NULL,
 PRIMARY KEY(document_id,input_sha256,config_sha256,ordinal),
 FOREIGN KEY(document_id,input_sha256,config_sha256)
 REFERENCES root_state(document_id,input_sha256,config_sha256),
 CHECK((kind='emitted')=(destination IS NOT NULL)),
 CHECK((kind='emitted')=(output_sha256 IS NOT NULL)),
 CHECK((kind='emitted')=(reason_sha256 IS NULL))
) WITHOUT ROWID;
CREATE INDEX final_event_destination ON final_event(destination) WHERE destination IS NOT NULL;
CREATE TABLE publication_intent(
 document_id TEXT NOT NULL,
 input_sha256 BLOB NOT NULL CHECK(length(input_sha256)=32),
 config_sha256 BLOB NOT NULL CHECK(length(config_sha256)=32),
 ordinal INTEGER NOT NULL,
 started_utc_ms INTEGER NOT NULL,
 PRIMARY KEY(document_id,input_sha256,config_sha256,ordinal),
 FOREIGN KEY(document_id,input_sha256,config_sha256,ordinal)
 REFERENCES final_event(document_id,input_sha256,config_sha256,ordinal)
) WITHOUT ROWID;
`;

// The public export projection intentionally retains the v2 column contract.
// New workflow state remains in the common tables above.
private enum journalTables = `
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
 phase TEXT NOT NULL CHECK(phase IN ('read','decode','filter','sink','manifest','policy','resource','scheduler','log','inspect','retry')),
 code TEXT NOT NULL CHECK(code IN ('read-failed','decode-failed','filter-failed','sink-write-failed','manifest-failed','policy-failed','resource-failed','scheduler-failed','log-failed','inspect-invalidated','sink-publication-interrupted','retry-succeeded')),
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
 origin TEXT NOT NULL CHECK(origin='event'),
 event_id TEXT NOT NULL REFERENCES error_event(event_id),
 run_id TEXT NOT NULL,
 time_utc_ms INTEGER NOT NULL,
 PRIMARY KEY(document_id,input_sha256,config_sha256,sink_key)
) WITHOUT ROWID;
`;

private void need(bool okay, string token) {
    if (!okay) throw new Exception("durable job: " ~ token);
}

private string canonicalDestination(string path) {
    need(path.length != 0 && path.indexOf('\0') < 0, "invalid-destination");
    return buildNormalizedPath(absolutePath(path));
}

private final class Database {
    sqlite3* handle;
    this(string path, int flags) {
        if (sqlite3_open_v2(path.toStringz, &handle, flags, null) != SQLITE_OK) {
            if (handle !is null) sqlite3_close(handle);
            handle = null;
            throw new Exception("durable job: open-failed");
        }
        need(sqlite3_busy_timeout(handle, 2000) == SQLITE_OK, "busy-timeout-failed");
    }
    this(sqlite3* borrowed) { handle = borrowed; }
    void close() {
        if (handle !is null) {
            auto current = handle;
            handle = null;
            need(sqlite3_close(current) == SQLITE_OK, "close-failed");
        }
    }
    void exec(string sql) {
        need(sqlite3_exec(handle, sql.toStringz, null, null, null) == SQLITE_OK,
            "sql-failed");
    }
    sqlite3_stmt* prepare(string sql) {
        sqlite3_stmt* result;
        need(sqlite3_prepare_v2(handle, sql.toStringz, -1, &result, null) == SQLITE_OK,
            "prepare-failed");
        return result;
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
        auto text = sqlite3_column_text(s, 0);
        need(text !is null, "invalid-text");
        return text.fromStringz.idup;
    }
}

private void bindText(sqlite3_stmt* s, int at, string value) {
    need(value.indexOf('\0') < 0 && sqlite3_bind_text(s, at, value.toStringz,
        cast(int)value.length, cast(void*)-1) == SQLITE_OK, "bind-failed");
}
private void bindDigest(sqlite3_stmt* s, int at, ref const(ubyte[32]) value) {
    need(sqlite3_bind_blob(s, at, value.ptr, 32, cast(void*)-1) == SQLITE_OK,
        "bind-failed");
}
private void bindLong(sqlite3_stmt* s, int at, long value) {
    need(sqlite3_bind_int64(s, at, value) == SQLITE_OK, "bind-failed");
}
private void bindRoot(sqlite3_stmt* s, ref const(DurableRootKey) key) {
    need(key.document.text.length != 0, "invalid-root-key");
    bindText(s, 1, key.document.text);
    bindDigest(s, 2, key.inputSha256);
    bindDigest(s, 3, key.configSha256);
}
private void done(sqlite3_stmt* s) {
    need(sqlite3_step(s) == SQLITE_DONE, "write-failed");
}
private string columnText(sqlite3_stmt* s, int at) {
    auto value = sqlite3_column_text(s, at);
    need(value !is null, "invalid-text");
    return value[0 .. sqlite3_column_bytes(s, at)].idup;
}
private ubyte[32] columnDigest(sqlite3_stmt* s, int at) {
    need(sqlite3_column_bytes(s, at) == 32, "invalid-digest");
    ubyte[32] result;
    result[] = (cast(const(ubyte)*)sqlite3_column_blob(s, at))[0 .. 32];
    return result;
}
private void appendField(ref SHA256 digest, string value) {
    ulong length = value.length;
    ubyte[8] width;
    foreach_reverse (index, shift; [0, 8, 16, 24, 32, 40, 48, 56])
        width[index] = cast(ubyte)(length >> shift);
    digest.put(width[]);
    digest.put(cast(const(ubyte)[])value);
}
private void appendDigest(ref SHA256 digest, ref const(ubyte[32]) value) {
    digest.put(value[]);
}

ubyte[32] deriveDurableIdentity(string canonicalJobJson, string jobIdentity,
        string mode, string canonicalOutputRoute,
        ref const(ubyte[32]) executableSha256) {
    need(jobIdentity.length == 71 &&
        (jobIdentity[0 .. 7] == "job:v3:" || jobIdentity[0 .. 7] == "job:v4:"),
        "invalid-job-identity");
    need(mode == "file" || mode == "tree", "invalid-route-mode");
    SHA256 digest;
    digest.put(cast(const(ubyte)[])"scrubbed:durable-compiled-job:v1\0");
    appendField(digest, canonicalJobJson);
    appendField(digest, jobIdentity);
    appendField(digest, mode);
    appendField(digest, canonicalOutputRoute);
    appendField(digest, "compiled-final-events:v1");
    appendDigest(digest, executableSha256);
    return digest.finish();
}

ubyte[32] reasonDigest(string reason) {
    SHA256 digest;
    digest.put(cast(const(ubyte)[])"scrubbed:final-reason:v1\0");
    appendField(digest, reason);
    return digest.finish();
}

string derivedSink(string kind, DocumentId document, size_t ordinal) {
    SHA256 digest;
    digest.put(cast(const(ubyte)[])"scrubbed:compiled-final-sink:v1\0");
    appendField(digest, kind);
    appendField(digest, document.text);
    appendField(digest, ordinal.to!string);
    return "compiled:v1:" ~
        toHexString!(LetterCase.lower)(digest.finish()).idup;
}

ubyte[32] eventSetDigest(const(DurableEventPlan)[] events) {
    need(events.length != 0, "empty-event-set");
    SHA256 digest;
    digest.put(cast(const(ubyte)[])"scrubbed:compiled-final-events:v1\0");
    foreach (ordinal, ref event; events) {
        need(event.ordinal == ordinal, "noncanonical-event-ordinal");
        appendField(digest, event.ordinal.to!string);
        appendField(digest, event.kind);
        appendField(digest, event.document.text);
        appendField(digest, event.outputName);
        if (event.hasReason) appendDigest(digest, event.reasonSha256);
        else appendField(digest, "no-reason");
        appendField(digest, event.sink);
        appendField(digest, event.destination);
    }
    return digest.finish();
}

private extern(C) void arc4random_buf(void*, size_t);
private extern(C) int renamex_np(const(char)*, const(char)*, uint);
private enum RENAME_EXCL = 0x00000004;
private string uuid() {
    ubyte[16] bytes;
    arc4random_buf(bytes.ptr, bytes.length);
    bytes[6] = cast(ubyte)((bytes[6] & 15) | 64);
    bytes[8] = cast(ubyte)((bytes[8] & 63) | 128);
    return UUID(bytes).toString;
}

private void validateShape(Database db, DurableKind kind) {
    need(db.scalar("PRAGMA application_id") == applicationId,
        "incompatible-application");
    need(db.scalar("PRAGMA user_version") ==
        (kind == DurableKind.manifest ? 2 : 3), "incompatible-version");
    need(db.textScalar("PRAGMA integrity_check") == "ok", "integrity-failed");
    need(db.scalar("SELECT count(*) FROM pragma_foreign_key_check") == 0,
        "foreign-key-failed");
    auto expected = kind == DurableKind.manifest ? 3 : 6;
    need(db.scalar(`SELECT count(*) FROM sqlite_master WHERE type='table' AND
        name NOT GLOB 'sqlite_*'`) == expected, "invalid-schema");
    auto reference = new Database(":memory:",
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE);
    scope(exit) reference.close();
    reference.exec(commonSchema ~
        (kind == DurableKind.journal ? journalTables : ""));
    auto sql = `SELECT type,name,sql FROM sqlite_master
        WHERE name NOT GLOB 'sqlite_*' ORDER BY type,name`;
    auto actualRows = db.prepare(sql);
    auto expectedRows = reference.prepare(sql);
    scope(exit) {
        sqlite3_finalize(actualRows);
        sqlite3_finalize(expectedRows);
    }
    while (true) {
        auto actual = sqlite3_step(actualRows);
        auto wanted = sqlite3_step(expectedRows);
        need(actual == wanted, "invalid-schema");
        if (actual == SQLITE_DONE) break;
        need(actual == SQLITE_ROW, "invalid-schema");
        foreach (column; 0 .. 3)
            need(columnText(actualRows, column) ==
                columnText(expectedRows, column), "invalid-schema");
    }
}

private void createFresh(string target, DurableKind kind) {
    foreach (suffix; ["", "-wal", "-shm"]) {
        safeRegularOrAbsent(target ~ suffix);
        need(!exists(target ~ suffix), "destination-exists");
    }
    auto stage = target ~ ".stage-" ~ uuid();
    foreach (suffix; ["", "-wal", "-shm"])
        need(!exists(stage ~ suffix), "stage-collision");
    bool published;
    scope(exit) if (!published) foreach (suffix; ["", "-wal", "-shm"])
        if (exists(stage ~ suffix)) remove(stage ~ suffix);
    auto db = new Database(stage, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE);
    db.exec("PRAGMA journal_mode=WAL");
    db.exec("PRAGMA synchronous=FULL");
    db.exec("PRAGMA foreign_keys=ON");
    db.exec("BEGIN IMMEDIATE");
    try {
        db.exec(commonSchema ~
            (kind == DurableKind.journal ? journalTables : "") ~
            "PRAGMA application_id=1396920898;PRAGMA user_version=" ~
            (kind == DurableKind.journal ? "3;" : "2;"));
        db.exec("COMMIT");
    } catch (Throwable failure) {
        try db.exec("ROLLBACK"); catch (Throwable ignored) {}
        throw failure;
    }
    validateShape(db, kind);
    db.close();
    need(!exists(stage ~ "-wal") && !exists(stage ~ "-shm"),
        "stage-companion-remained");
    foreach (suffix; ["", "-wal", "-shm"])
        need(!exists(target ~ suffix), "destination-raced");
    need(renamex_np(stage.toStringz, target.toStringz, RENAME_EXCL) == 0,
        "destination-raced");
    published = true;
}

void createJournalV3(string path) {
    createFresh(resolvedName(path), DurableKind.journal);
}

/// Validate a v3 read snapshot before exporting its v2-compatible public
/// history/outstanding projection.
void validateV3ReadSnapshot(sqlite3* handle) {
    auto db = new Database(handle);
    validateShape(db, DurableKind.journal);
    db.handle = null; // borrowed
}

final class DurableJobLedger {
    private Database db;
    private string databasePath;
    private DurableKind kind;
    private DurableIdentity identity;
    private string runId;
    private bool poisoned;

    this(string path, DurableKind kind, DurableIdentity identity) {
        need(identity.jobIdentity.length != 0, "missing-identity");
        this.databasePath = resolvedName(path);
        this.kind = kind;
        this.identity = identity;
        safeRegularOrAbsent(databasePath);
        safeRegularOrAbsent(databasePath ~ "-wal");
        safeRegularOrAbsent(databasePath ~ "-shm");
        if (kind == DurableKind.journal)
            need(exists(databasePath), "journal-v3-missing-explicit-create-required");
        bool creating = !exists(databasePath);
        if (creating) {
            need(kind == DurableKind.manifest, "explicit-create-required");
            createFresh(databasePath, DurableKind.manifest);
        }
        preflightDatabaseHeader(databasePath, kind);
        db = new Database(databasePath, SQLITE_OPEN_READWRITE);
        try {
            need(sqlite3_libversion().fromStringz == "3.53.4", "wrong-sqlite-version");
            auto storedApplication = db.scalar("PRAGMA application_id");
            auto storedVersion = db.scalar("PRAGMA user_version");
            need(storedApplication == applicationId && storedVersion ==
                (kind == DurableKind.manifest ? 2 : 3),
                "database-header-changed-after-preflight");
            db.exec("PRAGMA foreign_keys=ON");
            validateShape(db, kind);
            // V3 historically permits multiple compiled configurations in one
            // store. Explicit v4 instead binds the existing store before any
            // WAL/recovery mutation, separating v3 and changed-v4 execution.
            if (identity.jobIdentity.length == 71 &&
                    identity.jobIdentity[0 .. 7] == "job:v4:")
                validateV4Binding;
            db.exec("PRAGMA journal_mode=WAL");
            db.exec("PRAGMA synchronous=FULL");
            need(db.textScalar("PRAGMA journal_mode") == "wal" &&
                db.scalar("PRAGMA synchronous") == 2,
                "durability-mode-unavailable");
            runId = uuid();
            recoverIntents();
        } catch (Throwable failure) { db.close(); throw failure; }
    }

    ~this() { if (db !is null && db.handle !is null) db.close(); }
    void close() { if (db !is null) db.close(); db = null; }
    private void live() { need(db !is null && db.handle !is null && !poisoned, "fail-stop"); }
    private void validateV4Binding() {
        auto s = db.prepare(`SELECT count(*) FROM root_state WHERE
            config_sha256<>?1 OR job_identity<>?2`);
        scope(exit) sqlite3_finalize(s);
        bindDigest(s, 1, identity.digest);
        bindText(s, 2, identity.jobIdentity);
        need(sqlite3_step(s) == SQLITE_ROW &&
            sqlite3_column_int64(s, 0) == 0, "v4-store-identity-mismatch");
    }
    private void transaction(scope void delegate() operation) {
        live();
        try {
            db.exec("BEGIN IMMEDIATE");
            operation();
            db.exec("COMMIT");
            version (FailurePolicyHarness) {
                if (exists(databasePath ~ ".fault-v3-ack") ||
                        exists(databasePath ~ ".fault-v2-ack"))
                    throw new Exception("durable job: injected-ack-failure");
            }
        } catch (Throwable failure) {
            poisoned = true;
            try db.exec("ROLLBACK"); catch (Throwable ignored) {}
            throw failure;
        }
    }
    private void recoverIntents() {
        struct Interrupted { DurableRootKey key; size_t ordinal; }
        Interrupted[] interrupted;
        auto s = db.prepare(`SELECT document_id,input_sha256,config_sha256,ordinal
            FROM publication_intent ORDER BY document_id,input_sha256,config_sha256,ordinal`);
        while (sqlite3_step(s) == SQLITE_ROW) {
            DurableRootKey key;
            key.document = DocumentId.fromCanonicalText(columnText(s, 0));
            key.inputSha256 = columnDigest(s, 1);
            key.configSha256 = columnDigest(s, 2);
            interrupted ~= Interrupted(key,
                cast(size_t)sqlite3_column_int64(s, 3));
        }
        sqlite3_finalize(s);
        foreach (item; interrupted)
            transaction({ markFailureInternal(item.key, item.ordinal, true,
                "sink", "sink-publication-interrupted"); });
    }
    private bool rootExists(DurableRootKey key) {
        auto s = db.prepare(`SELECT count(*) FROM root_state WHERE
            document_id=?1 AND input_sha256=?2 AND config_sha256=?3`);
        scope(exit) sqlite3_finalize(s);
        bindRoot(s, key);
        need(sqlite3_step(s) == SQLITE_ROW, "read-failed");
        return sqlite3_column_int64(s, 0) == 1;
    }
    void planRoot(DurableRootKey key) {
        live();
        need(key.configSha256 == identity.digest, "derived-identity-mismatch");
        if (!rootExists(key)) transaction({
            auto s = db.prepare(`INSERT INTO root_state VALUES(?1,?2,?3,?4,NULL,NULL,'planned',?5)`);
            scope(exit) sqlite3_finalize(s);
            bindRoot(s, key);
            bindText(s, 4, identity.jobIdentity);
            bindLong(s, 5, nowUtcMs());
            done(s);
        });
        auto s = db.prepare(`SELECT job_identity FROM root_state WHERE
            document_id=?1 AND input_sha256=?2 AND config_sha256=?3`);
        scope(exit) sqlite3_finalize(s);
        bindRoot(s, key);
        need(sqlite3_step(s) == SQLITE_ROW && columnText(s, 0) == identity.jobIdentity,
            "root-identity-mismatch");
    }
    private void validateEvent(ref const(DurableEventPlan) event) {
        need(event.ordinal <= long.max && event.outputName.length != 0 &&
            event.sink.length != 0 && event.sink.indexOf('\0') < 0,
            "invalid-event");
        need(event.kind == "emitted" || event.kind == "rejected" ||
            event.kind == "quarantined", "invalid-event-kind");
        need((event.kind == "emitted") == event.hasOutput &&
            (event.kind == "emitted") == !event.hasReason,
            "invalid-event-shape");
        if (event.hasOutput) {
            need(event.destination.length != 0, "missing-destination");
            need(!pathIsSymlink(event.destination), "symlink-destination");
            safeRegularOrAbsent(event.destination, true);
            auto selected = canonicalDestination(event.destination);
            need(selected == event.destination, "noncanonical-destination");
            need(selected != databasePath && selected != databasePath ~ "-wal" &&
                selected != databasePath ~ "-shm" &&
                !sameInode(selected, databasePath) &&
                !sameInode(selected, databasePath ~ "-wal") &&
                !sameInode(selected, databasePath ~ "-shm"),
                "destination-aliases-ledger");
        } else need(event.destination.length == 0, "unexpected-destination");
    }
    private long eventCount(DurableRootKey key) {
        auto s = db.prepare(`SELECT count(*) FROM final_event WHERE
            document_id=?1 AND input_sha256=?2 AND config_sha256=?3`);
        scope(exit) sqlite3_finalize(s);
        bindRoot(s, key);
        need(sqlite3_step(s) == SQLITE_ROW, "read-failed");
        return sqlite3_column_int64(s, 0);
    }
    void planEvents(DurableRootKey key, const(DurableEventPlan)[] events) {
        live();
        need(rootExists(key), "root-plan-required");
        auto setDigest = eventSetDigest(events);
        foreach (ref event; events) validateEvent(event);
        auto root = db.prepare(`SELECT event_count,event_set_sha256,state FROM root_state WHERE
            document_id=?1 AND input_sha256=?2 AND config_sha256=?3`);
        scope(exit) sqlite3_finalize(root);
        bindRoot(root, key);
        need(sqlite3_step(root) == SQLITE_ROW, "root-read-failed");
        if (sqlite3_column_type(root, 0) != SQLITE_NULL) {
            need(sqlite3_column_int64(root, 0) == events.length &&
                columnDigest(root, 1) == setDigest &&
                eventCount(key) == events.length, "event-set-mismatch");
            foreach (ref event; events) {
                auto prior = readEvent(key, event.ordinal);
                need(prior.plan.kind == event.kind &&
                    prior.plan.document == event.document &&
                    prior.plan.outputName == event.outputName &&
                    prior.plan.hasReason == event.hasReason &&
                    (!event.hasReason || prior.plan.reasonSha256 == event.reasonSha256) &&
                    prior.plan.sink == event.sink &&
                    prior.plan.destination == event.destination &&
                    prior.plan.hasOutput == event.hasOutput &&
                    (!event.hasOutput || prior.plan.outputSha256 == event.outputSha256),
                    "event-reexecution-mismatch");
            }
            return;
        }
        need(columnText(root, 2) == "planned", "root-not-planned");
        transaction({
            foreach (ref event; events) {
                if (event.hasOutput) {
                    auto owner = db.prepare(`SELECT count(*) FROM final_event WHERE
                        destination=?1 AND NOT(final_document_id=?2 AND sink_key=?3)`);
                    scope(exit) sqlite3_finalize(owner);
                    bindText(owner, 1, canonicalDestination(event.destination));
                    bindText(owner, 2, event.document.text);
                    bindText(owner, 3, event.sink);
                    need(sqlite3_step(owner) == SQLITE_ROW &&
                        sqlite3_column_int64(owner, 0) == 0,
                        "destination-owned-by-another-event");
                    if (exists(event.destination) && needsInodeAliasScan(event.destination)) {
                        auto aliases = db.prepare(`SELECT destination,final_document_id,sink_key
                            FROM final_event WHERE destination IS NOT NULL`);
                        scope(exit) sqlite3_finalize(aliases);
                        while (true) {
                            auto rc = sqlite3_step(aliases);
                            if (rc == SQLITE_DONE) break;
                            need(rc == SQLITE_ROW, "destination-owner-read-failed");
                            version (unittest) ++aliasRowsInspected;
                            auto priorDestination = columnText(aliases, 0);
                            auto sameOwner = columnText(aliases, 1) == event.document.text &&
                                columnText(aliases, 2) == event.sink;
                            need(sameOwner || !sameInode(event.destination, priorDestination),
                                "destination-owned-by-another-event");
                        }
                    }
                }
                auto sql = event.hasReason && event.hasOutput ? "" :
                    event.hasReason ? `INSERT INTO final_event VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,NULL,NULL,'planned',0,?10)` :
                    event.hasOutput ? `INSERT INTO final_event VALUES(?1,?2,?3,?4,?5,?6,?7,NULL,?8,?9,?10,'planned',0,?11)` : "";
                need(sql.length != 0, "invalid-event-shape");
                auto s = db.prepare(sql);
                scope(exit) sqlite3_finalize(s);
                bindRoot(s, key);
                bindLong(s, 4, cast(long)event.ordinal);
                bindText(s, 5, event.kind);
                bindText(s, 6, event.document.text);
                bindText(s, 7, event.outputName);
                if (event.hasReason) {
                    bindDigest(s, 8, event.reasonSha256);
                    bindText(s, 9, event.sink);
                    bindLong(s, 10, nowUtcMs());
                } else {
                    bindText(s, 8, event.sink);
                    bindText(s, 9, canonicalDestination(event.destination));
                    bindDigest(s, 10, event.outputSha256);
                    bindLong(s, 11, nowUtcMs());
                }
                done(s);
            }
            auto update = db.prepare(`UPDATE root_state SET event_count=?4,
                event_set_sha256=?5,updated_utc_ms=?6 WHERE document_id=?1 AND
                input_sha256=?2 AND config_sha256=?3 AND event_count IS NULL`);
            scope(exit) sqlite3_finalize(update);
            bindRoot(update, key);
            bindLong(update, 4, cast(long)events.length);
            bindDigest(update, 5, setDigest);
            bindLong(update, 6, nowUtcMs());
            done(update);
            need(sqlite3_changes(db.handle) == 1, "root-plan-raced");
        });
    }
    DurableEventRecord readEvent(DurableRootKey key, size_t ordinal) {
        live();
        auto s = db.prepare(`SELECT kind,final_document_id,output_name,reason_sha256,
            sink_key,destination,output_sha256,state,attempt FROM final_event WHERE
            document_id=?1 AND input_sha256=?2 AND config_sha256=?3 AND ordinal=?4`);
        scope(exit) sqlite3_finalize(s);
        bindRoot(s, key);
        bindLong(s, 4, cast(long)ordinal);
        need(sqlite3_step(s) == SQLITE_ROW, "missing-event");
        DurableEventRecord result;
        result.plan.ordinal = ordinal;
        result.plan.kind = columnText(s, 0);
        result.plan.document = DocumentId.fromCanonicalText(columnText(s, 1));
        result.plan.outputName = columnText(s, 2);
        result.plan.hasReason = sqlite3_column_type(s, 3) != SQLITE_NULL;
        if (result.plan.hasReason) result.plan.reasonSha256 = columnDigest(s, 3);
        result.plan.sink = columnText(s, 4);
        result.plan.hasOutput = sqlite3_column_type(s, 5) != SQLITE_NULL;
        if (result.plan.hasOutput) {
            result.plan.destination = columnText(s, 5);
            result.plan.outputSha256 = columnDigest(s, 6);
        }
        result.state = cast(DurableEventState)columnText(s, 7);
        result.attempt = sqlite3_column_int64(s, 8);
        return result;
    }
    DurableAction prepare(DurableRootKey key, size_t ordinal, bool retry) {
        auto row = readEvent(key, ordinal);
        if (row.plan.hasOutput) {
            need(!pathIsSymlink(row.plan.destination), "symlink-destination");
            safeRegularOrAbsent(row.plan.destination, true);
            if (exists(row.plan.destination) && needsInodeAliasScan(row.plan.destination)) {
                auto aliases = db.prepare(`SELECT destination,final_document_id,sink_key
                    FROM final_event WHERE
                    destination IS NOT NULL AND NOT(document_id=?1 AND
                    input_sha256=?2 AND config_sha256=?3 AND ordinal=?4)`);
                scope(exit) sqlite3_finalize(aliases);
                bindRoot(aliases, key); bindLong(aliases, 4, cast(long)ordinal);
                while (true) {
                    auto rc = sqlite3_step(aliases);
                    if (rc == SQLITE_DONE) break;
                    need(rc == SQLITE_ROW, "destination-owner-read-failed");
                    version (unittest) ++aliasRowsInspected;
                    auto sameOwner = columnText(aliases, 1) == row.plan.document.text &&
                        columnText(aliases, 2) == row.plan.sink;
                    need(sameOwner || !sameInode(row.plan.destination, columnText(aliases, 0)),
                        "destination-owned-by-another-event");
                }
            }
        }
        if (row.state == DurableEventState.acknowledged) return DurableAction.skip;
        if (row.state == DurableEventState.committed) {
            if (row.plan.hasOutput && exists(row.plan.destination) &&
                    !isSymlink(row.plan.destination) && isFile(row.plan.destination) &&
                    hashFile(row.plan.destination) == row.plan.outputSha256)
                return DurableAction.skip;
            transaction({ markFailureInternal(key, ordinal, true,
                "inspect", "inspect-invalidated"); });
            throw new Exception("durable job: retry-required");
        }
        if (!row.plan.hasOutput) {
            transaction({ transition(key, ordinal, DurableEventState.acknowledged); });
            return DurableAction.skip;
        }
        bool replacement = exists(row.plan.destination) ||
            row.state == DurableEventState.failed ||
            row.state == DurableEventState.uncertain;
        if (replacement && !retry) throw new Exception("durable job: retry-required");
        if (row.state != DurableEventState.planned)
            transaction({ transition(key, ordinal, DurableEventState.planned); });
        return DurableAction.publish;
    }
    private void transition(DurableRootKey key, size_t ordinal,
            DurableEventState state) {
        auto s = db.prepare(`UPDATE final_event SET state=?5,attempt=attempt+1,
            updated_utc_ms=?6 WHERE document_id=?1 AND input_sha256=?2 AND
            config_sha256=?3 AND ordinal=?4`);
        scope(exit) sqlite3_finalize(s);
        bindRoot(s, key);
        bindLong(s, 4, cast(long)ordinal);
        bindText(s, 5, cast(string)state);
        bindLong(s, 6, nowUtcMs());
        done(s);
        need(sqlite3_changes(db.handle) == 1, "missing-event");
    }
    void beginPublication(DurableRootKey key, size_t ordinal) {
        auto row = readEvent(key, ordinal);
        need(row.state == DurableEventState.planned && row.plan.hasOutput,
            "publication-not-planned");
        transaction({
            auto s = db.prepare(`INSERT INTO publication_intent VALUES(?1,?2,?3,?4,?5)`);
            scope(exit) sqlite3_finalize(s);
            bindRoot(s, key);
            bindLong(s, 4, cast(long)ordinal);
            bindLong(s, 5, nowUtcMs());
            done(s);
        });
    }
    private void deleteIntent(DurableRootKey key, size_t ordinal) {
        auto s = db.prepare(`DELETE FROM publication_intent WHERE document_id=?1 AND
            input_sha256=?2 AND config_sha256=?3 AND ordinal=?4`);
        scope(exit) sqlite3_finalize(s);
        bindRoot(s, key);
        bindLong(s, 4, cast(long)ordinal);
        done(s);
    }
    void commitPublished(DurableRootKey key, size_t ordinal) {
        auto row = readEvent(key, ordinal);
        need(row.state == DurableEventState.planned && row.plan.hasOutput,
            "commit-not-planned");
        need(exists(row.plan.destination) && !isSymlink(row.plan.destination) &&
            isFile(row.plan.destination) &&
            hashFile(row.plan.destination) == row.plan.outputSha256,
            "published-output-mismatch");
        transaction({
            transition(key, ordinal, DurableEventState.committed);
            deleteIntent(key, ordinal);
            if (kind == DurableKind.journal) {
                appendRetrySuccess(key, row.plan.sink);
                clearOutstanding(key, row.plan.sink);
            }
        });
    }
    void recordFailure(DurableRootKey key, size_t ordinal, bool touched,
            string phase, string code) {
        transaction({ markFailureInternal(key, ordinal, touched, phase, code); });
    }
    private void markFailureInternal(DurableRootKey key, size_t ordinal,
            bool touched, string phase, string code) {
        auto row = readEvent(key, ordinal);
        auto state = touched || row.state == DurableEventState.uncertain ?
            DurableEventState.uncertain : DurableEventState.failed;
        transition(key, ordinal, state);
        auto root = db.prepare(`UPDATE root_state SET state='planned',updated_utc_ms=?4
            WHERE document_id=?1 AND input_sha256=?2 AND config_sha256=?3`);
        scope(exit) sqlite3_finalize(root);
        bindRoot(root, key); bindLong(root, 4, nowUtcMs()); done(root);
        need(sqlite3_changes(db.handle) == 1, "missing-root");
        deleteIntent(key, ordinal);
        if (kind == DurableKind.journal)
            appendFailure(key, row.plan.sink, state, phase, code);
    }
    private string sinkId(string raw) {
        auto find = db.prepare("SELECT sink_id FROM sink_identity WHERE raw_sink=?1");
        scope(exit) sqlite3_finalize(find);
        bindText(find, 1, raw);
        auto rc = sqlite3_step(find);
        if (rc == SQLITE_ROW) return columnText(find, 0);
        need(rc == SQLITE_DONE, "identity-read-failed");
        auto id = uuid();
        auto add = db.prepare("INSERT INTO sink_identity VALUES(?1,?2)");
        scope(exit) sqlite3_finalize(add);
        bindText(add, 1, raw); bindText(add, 2, id); done(add);
        return id;
    }
    private void appendFailure(DurableRootKey key, string sink,
            DurableEventState state, string phase, string code) {
        auto publicId = sinkId(sink);
        auto eventId = uuid();
        auto at = nowUtcMs();
        auto e = db.prepare(`INSERT INTO error_event VALUES(NULL,?1,?2,?3,?4,?5,?6,?7,?8,?9,NULL,?10)`);
        scope(exit) sqlite3_finalize(e);
        bindText(e, 1, eventId); bindText(e, 2, runId);
        bindText(e, 3, key.document.text); bindDigest(e, 4, key.inputSha256);
        bindDigest(e, 5, key.configSha256); bindText(e, 6, publicId);
        bindText(e, 7, phase); bindText(e, 8, code);
        bindText(e, 9, cast(string)state); bindLong(e, 10, at); done(e);
        auto o = db.prepare(`INSERT INTO outstanding VALUES(?1,?2,?3,?4,?5,?6,'event',?7,?8,?9)
            ON CONFLICT(document_id,input_sha256,config_sha256,sink_key) DO UPDATE SET
            sink_id=excluded.sink_id,state=excluded.state,event_id=excluded.event_id,
            run_id=excluded.run_id,time_utc_ms=excluded.time_utc_ms`);
        scope(exit) sqlite3_finalize(o);
        bindRoot(o, key); bindText(o, 4, sink); bindText(o, 5, publicId);
        bindText(o, 6, cast(string)state); bindText(o, 7, eventId);
        bindText(o, 8, runId); bindLong(o, 9, at); done(o);
    }
    private void clearOutstanding(DurableRootKey key, string sink) {
        if (kind != DurableKind.journal) return;
        auto s = db.prepare(`DELETE FROM outstanding WHERE document_id=?1 AND
            input_sha256=?2 AND config_sha256=?3 AND sink_key=?4`);
        scope(exit) sqlite3_finalize(s);
        bindRoot(s, key); bindText(s, 4, sink); done(s);
    }
    private void appendRetrySuccess(DurableRootKey key, string sink) {
        auto prior = db.prepare(`SELECT event_id FROM outstanding WHERE
            document_id=?1 AND input_sha256=?2 AND config_sha256=?3 AND sink_key=?4`);
        scope(exit) sqlite3_finalize(prior);
        bindRoot(prior, key); bindText(prior, 4, sink);
        auto rc = sqlite3_step(prior);
        if (rc == SQLITE_DONE) return;
        need(rc == SQLITE_ROW, "outstanding-read-failed");
        auto retryOf = columnText(prior, 0);
        auto eventId = uuid();
        auto at = nowUtcMs();
        auto e = db.prepare(`INSERT INTO error_event VALUES(NULL,?1,?2,?3,?4,?5,?6,
            'retry','retry-succeeded','committed',?7,?8)`);
        scope(exit) sqlite3_finalize(e);
        bindText(e, 1, eventId); bindText(e, 2, runId);
        bindText(e, 3, key.document.text); bindDigest(e, 4, key.inputSha256);
        bindDigest(e, 5, key.configSha256); bindText(e, 6, sinkId(sink));
        bindText(e, 7, retryOf); bindLong(e, 8, at); done(e);
    }
    void completeRoot(DurableRootKey key) {
        live();
        transaction({
            auto shape = db.prepare(`SELECT state,event_count,event_set_sha256,
                (SELECT count(*) FROM final_event f WHERE f.document_id=r.document_id
                    AND f.input_sha256=r.input_sha256 AND f.config_sha256=r.config_sha256),
                (SELECT count(*) FROM final_event f WHERE f.document_id=r.document_id
                    AND f.input_sha256=r.input_sha256 AND f.config_sha256=r.config_sha256
                    AND f.state NOT IN ('committed','acknowledged'))
                FROM root_state r WHERE document_id=?1 AND input_sha256=?2 AND config_sha256=?3`);
            scope(exit) sqlite3_finalize(shape);
            bindRoot(shape, key);
            need(sqlite3_step(shape) == SQLITE_ROW, "missing-root");
            auto state = columnText(shape, 0);
            need(sqlite3_column_type(shape, 1) != SQLITE_NULL &&
                sqlite3_column_int64(shape, 1) > 0 &&
                sqlite3_column_type(shape, 2) != SQLITE_NULL &&
                sqlite3_column_int64(shape, 1) == sqlite3_column_int64(shape, 3),
                "root-event-shape-incomplete");
            need(sqlite3_column_int64(shape, 4) == 0, "root-events-incomplete");
            if (state == "complete") return;
            need(state == "planned", "root-not-planned");
            auto update = db.prepare(`UPDATE root_state SET state='complete',updated_utc_ms=?4
                WHERE document_id=?1 AND input_sha256=?2 AND config_sha256=?3
                AND state='planned' AND event_count IS NOT NULL
                AND event_set_sha256 IS NOT NULL`);
            scope(exit) sqlite3_finalize(update);
            bindRoot(update, key); bindLong(update, 4, nowUtcMs()); done(update);
            need(sqlite3_changes(db.handle) == 1, "missing-root");
            if (kind == DurableKind.journal) {
                string[] recoveredRootSinks;
                auto outstandingRows = db.prepare(`SELECT sink_key FROM outstanding WHERE
                    document_id=?1 AND input_sha256=?2 AND config_sha256=?3 AND
                    (sink_key=?4 OR sink_key IN (SELECT sink_key FROM final_event WHERE
                        document_id=?1 AND input_sha256=?2 AND config_sha256=?3))`);
                bindRoot(outstandingRows, key);
                bindText(outstandingRows, 4, derivedSink("root", key.document, 0));
                while (true) {
                    auto rc = sqlite3_step(outstandingRows);
                    if (rc == SQLITE_DONE) break;
                    need(rc == SQLITE_ROW, "outstanding-read-failed");
                    recoveredRootSinks ~= columnText(outstandingRows, 0);
                }
                sqlite3_finalize(outstandingRows);
                foreach (sink; recoveredRootSinks)
                    appendRetrySuccess(key, sink);
                foreach (sink; recoveredRootSinks) clearOutstanding(key, sink);
            }
        });
    }
    void recordRootFailure(DurableRootKey key, string phase, string code) {
        live();
        need(kind == DurableKind.journal && rootExists(key),
            "root-failure-unavailable");
        transaction({
            auto reopen = db.prepare(`UPDATE root_state SET state='planned',updated_utc_ms=?4
                WHERE document_id=?1 AND input_sha256=?2 AND config_sha256=?3`);
            scope(exit) sqlite3_finalize(reopen);
            bindRoot(reopen, key); bindLong(reopen, 4, nowUtcMs()); done(reopen);
            need(sqlite3_changes(db.handle) == 1, "missing-root");
            auto sink = derivedSink("root", key.document, 0);
            appendFailure(key, sink, DurableEventState.failed, phase, code);
        });
    }
    bool hasOutstanding(DocumentId document, ref const(ubyte[32]) config) {
        live();
        auto sql = kind == DurableKind.journal ?
            `SELECT 1 FROM outstanding WHERE document_id=?1 AND config_sha256=?2 LIMIT 1` :
            `SELECT 1 FROM final_event WHERE document_id=?1 AND config_sha256=?2
                AND state IN ('failed','uncertain') LIMIT 1`;
        auto s = db.prepare(sql);
        scope(exit) sqlite3_finalize(s);
        bindText(s, 1, document.text); bindDigest(s, 2, config);
        auto rc = sqlite3_step(s);
        need(rc == SQLITE_ROW || rc == SQLITE_DONE, "outstanding-read-failed");
        return rc == SQLITE_ROW;
    }
    bool hasOutstanding(DocumentId document) {
        live();
        need(kind == DurableKind.journal, "outstanding-unavailable");
        auto s = db.prepare(`SELECT 1 FROM outstanding WHERE document_id=?1 LIMIT 1`);
        scope(exit) sqlite3_finalize(s);
        bindText(s, 1, document.text);
        auto rc = sqlite3_step(s);
        need(rc == SQLITE_ROW || rc == SQLITE_DONE, "outstanding-read-failed");
        return rc == SQLITE_ROW;
    }
    bool hasOutstanding(DurableRootKey key) {
        live();
        need(kind == DurableKind.journal, "outstanding-unavailable");
        auto s = db.prepare(`SELECT 1 FROM outstanding WHERE document_id=?1 AND
            input_sha256=?2 AND config_sha256=?3 LIMIT 1`);
        scope(exit) sqlite3_finalize(s);
        bindRoot(s, key);
        auto rc = sqlite3_step(s);
        need(rc == SQLITE_ROW || rc == SQLITE_DONE, "outstanding-read-failed");
        return rc == SQLITE_ROW;
    }
    string publicSinkId(string sink) {
        live();
        need(kind == DurableKind.journal, "public-sink-unavailable");
        return sinkId(sink);
    }
    void checkpoint() {
        live();
        int logFrames, checkpointed;
        need(sqlite3_wal_checkpoint_v2(db.handle, "main".toStringz,
            SQLITE_CHECKPOINT_TRUNCATE, &logFrames, &checkpointed) == SQLITE_OK &&
            logFrames == 0 && checkpointed == 0, "checkpoint-failed");
    }
}

version (unittest) {
    import std.array : replicate;
    import std.exception : assertThrown;
    import std.file : exists, getAttributes, mkdir, read, remove,
        rmdirRecurse, setAttributes, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import core.sys.posix.sys.stat : stat, stat_t;
    import core.sys.posix.unistd : link;

    unittest {
        auto root = buildPath(tempDir, "durable-job-" ~ randomUUID.toString);
        mkdir(root);
        scope(exit) if (exists(root)) rmdirRecurse(root);
        DurableIdentity identity;
        identity.jobIdentity = "job:v3:" ~ replicate("0", 64);
        identity.digest = reasonDigest("identity");
        auto path = buildPath(root, "manifest.db");
        scope ledger = new DurableJobLedger(path, DurableKind.manifest, identity);
        auto document = DocumentId.fromCanonicalText("doc:v1:" ~ replicate("1", 64));
        DurableRootKey key = DurableRootKey(document,
            reasonDigest("input"), identity.digest);
        ledger.planRoot(key);
        DurableEventPlan event;
        event.ordinal = 0; event.kind = "rejected"; event.document = document;
        event.outputName = "out"; event.hasReason = true;
        event.reasonSha256 = reasonDigest("no");
        event.sink = derivedSink(event.kind, document, 0);
        ledger.planEvents(key, [event]);
        assert(ledger.prepare(key, 0, false) == DurableAction.skip);
        ledger.completeRoot(key);
        ledger.checkpoint();
        ledger.close();
        assertThrown(new DurableJobLedger(path, DurableKind.journal, identity));
    }

    unittest {
        auto root = buildPath(tempDir, "durable-split-" ~ randomUUID.toString);
        mkdir(root);
        scope(exit) if (exists(root)) rmdirRecurse(root);
        DurableIdentity identity;
        identity.jobIdentity = "job:v3:" ~ replicate("2", 64);
        identity.digest = reasonDigest("split-identity");
        auto path = buildPath(root, "manifest.db");
        auto first = buildPath(root, "first.txt");
        auto second = buildPath(root, "second.txt");
        auto document = DocumentId.fromCanonicalText("doc:v1:" ~ replicate("3", 64));
        auto child0 = DocumentId.fromCanonicalText("child:v1:" ~ replicate("4", 64));
        auto child1 = DocumentId.fromCanonicalText("child:v1:" ~ replicate("5", 64));
        DurableRootKey key = DurableRootKey(document,
            reasonDigest("split-input"), identity.digest);
        DurableEventPlan[3] events;
        foreach (ordinal; 0 .. 2) {
            events[ordinal].ordinal = ordinal;
            events[ordinal].kind = "emitted";
            events[ordinal].document = ordinal ? child1 : child0;
            events[ordinal].outputName = ordinal ? "second.txt" : "first.txt";
            events[ordinal].sink = derivedSink("emitted",
                events[ordinal].document, ordinal);
            events[ordinal].destination = ordinal ? second : first;
            events[ordinal].hasOutput = true;
            events[ordinal].outputSha256 = reasonDigest(ordinal ? "second" : "first");
        }
        events[2].ordinal = 2;
        events[2].kind = "rejected";
        events[2].document = document;
        events[2].outputName = "root.txt";
        events[2].sink = derivedSink("rejected", document, 2);
        events[2].hasReason = true;
        events[2].reasonSha256 = reasonDigest("rejected");
        // Use the exact bytes whose hashes are persisted above.
        events[0].outputSha256 = sha256Of(cast(const(ubyte)[])"first");
        events[1].outputSha256 = sha256Of(cast(const(ubyte)[])"second");
        auto ledger = new DurableJobLedger(path, DurableKind.manifest, identity);
        ledger.planRoot(key);
        ledger.planEvents(key, events[]);
        need(ledger.prepare(key, 0, false) == DurableAction.publish,
            "split-first-publish");
        ledger.beginPublication(key, 0);
        write(first, "first");
        ledger.commitPublished(key, 0);
        stat_t before;
        assert(stat(first.toStringz, &before) == 0);
        need(ledger.prepare(key, 1, false) == DurableAction.publish,
            "split-second-publish");
        ledger.beginPublication(key, 1);
        ledger.close(); // crash after intent, before event 1 publication
        ledger = new DurableJobLedger(path, DurableKind.manifest, identity);
        assert(ledger.prepare(key, 0, false) == DurableAction.skip);
        assertThrown(ledger.prepare(key, 1, false));
        assert(ledger.readEvent(key, 2).state == DurableEventState.planned);
        assert(ledger.prepare(key, 1, true) == DurableAction.publish);
        ledger.beginPublication(key, 1);
        write(second, "second");
        ledger.commitPublished(key, 1);
        assert(ledger.prepare(key, 2, true) == DurableAction.skip);
        ledger.completeRoot(key);
        stat_t after;
        assert(stat(first.toStringz, &after) == 0 &&
            before.st_dev == after.st_dev && before.st_ino == after.st_ino);
        ledger.close();
    }

    unittest { // Root-last shape and fresh-tree ownership cost.
        auto root = buildPath(tempDir, "durable-shape-" ~ randomUUID.toString);
        mkdir(root); scope(exit) if (exists(root)) rmdirRecurse(root);
        DurableIdentity identity;
        identity.jobIdentity = "job:v3:" ~ replicate("6", 64);
        identity.digest = reasonDigest("shape-identity");
        auto path = buildPath(root, "manifest.db");
        auto document = DocumentId.fromCanonicalText("doc:v1:" ~ replicate("7", 64));
        DurableRootKey key = DurableRootKey(document, reasonDigest("shape-input"), identity.digest);
        auto ledger = new DurableJobLedger(path, DurableKind.manifest, identity);
        ledger.planRoot(key);
        assertThrown(ledger.completeRoot(key));
        ledger.close(); // refusal leaves the planned root usable
        ledger = new DurableJobLedger(path, DurableKind.manifest, identity);
        DurableEventPlan[1200] events;
        foreach (ordinal, ref event; events) {
            event.ordinal = ordinal; event.kind = "emitted"; event.document = document;
            event.outputName = ordinal.to!string; event.sink = "sink:" ~ ordinal.to!string;
            event.destination = buildPath(root, "fresh-" ~ ordinal.to!string);
            event.hasOutput = true;
            event.outputSha256 = sha256Of(cast(const(ubyte)[])[]);
        }
        aliasRowsInspected = 0;
        ledger.planEvents(key, events[]);
        assert(aliasRowsInspected == 0); // absent paths do not produce N(N-1)/2 inode probes
        ledger.close();
        foreach (ref event; events) write(event.destination, cast(ubyte[])[]);
        auto committed = new Database(path, SQLITE_OPEN_READWRITE);
        committed.exec("UPDATE final_event SET state='committed'"); committed.close();
        ledger = new DurableJobLedger(path, DurableKind.manifest, identity);
        aliasRowsInspected = 0;
        foreach (ordinal; 0 .. events.length)
            assert(ledger.prepare(key, ordinal, false) == DurableAction.skip);
        assert(aliasRowsInspected == 0); // 1200 single-link replay uses no global inode scan
        remove(events[1].destination);
        assert(link(events[0].destination.toStringz,
            events[1].destination.toStringz) == 0);
        aliasRowsInspected = 0;
        assertThrown(ledger.prepare(key, 1, false));
        assert(aliasRowsInspected > 0); // hardlinks retain the bounded slow path
        ledger.close();

        auto malformed = buildPath(root, "malformed.db");
        ledger = new DurableJobLedger(malformed, DurableKind.manifest, identity);
        ledger.planRoot(key); ledger.close();
        auto raw = new Database(malformed, SQLITE_OPEN_READWRITE);
        raw.exec("UPDATE root_state SET state='complete'"); raw.close();
        ledger = new DurableJobLedger(malformed, DurableKind.manifest, identity);
        assertThrown(ledger.completeRoot(key));
        assertThrown(ledger.planEvents(key, events[0 .. 1]));
        ledger.close();
    }

    unittest { // Legacy refusal must not run SQLite recovery or checkpointing.
        foreach (kind; [DurableKind.manifest, DurableKind.journal])
        foreach (wal; [false, true]) foreach (readOnly; [false, true]) {
            auto root = buildPath(tempDir, "durable-preflight-" ~ randomUUID.toString);
            mkdir(root); scope(exit) if (exists(root)) rmdirRecurse(root);
            auto path = buildPath(root, "legacy.db");
            auto seed = new Database(path, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE);
            seed.exec("CREATE TABLE fixture(value INTEGER);INSERT INTO fixture VALUES(1);");
            seed.exec("PRAGMA application_id=1396920898;PRAGMA user_version=" ~
                (kind == DurableKind.manifest ? "1" : "2"));
            seed.close();
            auto writer = new Database(path, SQLITE_OPEN_READWRITE);
            writer.exec(wal ? "PRAGMA journal_mode=WAL" : "PRAGMA journal_mode=DELETE");
            writer.exec("BEGIN IMMEDIATE;INSERT INTO fixture VALUES(2)");
            ubyte[][string] before;
            uint[string] modes;
            auto suffixes = wal ? ["", "-wal", "-shm"] : ["", "-journal"];
            foreach (suffix; suffixes) {
                if (suffix.length && !exists(path ~ suffix)) continue;
                before[suffix] = cast(ubyte[])read(path ~ suffix);
                modes[suffix] = getAttributes(path ~ suffix);
                if (readOnly) setAttributes(path ~ suffix, modes[suffix] & ~cast(uint)146);
            }
            DurableIdentity identity;
            identity.jobIdentity = "job:v3:" ~ replicate("8", 64);
            identity.digest = reasonDigest("preflight");
            auto expected = kind == DurableKind.manifest ?
                "manifest-v1-requires-fresh-v2" : "journal-v2-requires-fresh-v3";
            bool refused;
            try new DurableJobLedger(path, kind, identity);
            catch (Exception failure) { refused = failure.msg.indexOf(expected) >= 0; }
            assert(refused);
            foreach (suffix, bytes; before) {
                assert(exists(path ~ suffix) && cast(ubyte[])read(path ~ suffix) == bytes);
                if (readOnly) setAttributes(path ~ suffix, modes[suffix]);
            }
            writer.exec("ROLLBACK"); writer.close();
        }
    }
}
