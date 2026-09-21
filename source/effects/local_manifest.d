/// Versioned, single-writer local sink ledger. CLI orchestration is separate.
module effects.local_manifest;

import domain.document : DocumentId;
import effects.sqlite_ffi;
import std.datetime.systime : Clock;
import std.conv : to;
import std.digest.sha : sha256Of, SHA256;
import std.digest : LetterCase, toHexString;
import core.stdc.stdlib : free;
import core.stdc.errno : errno, EINTR, ENOENT, EIO, EACCES, EPERM, ELOOP,
    ENOSPC, EDQUOT, EMFILE, ENFILE;
import effects.atomic_piece_sink : OutputPolicyViolation, ResourceExhaustion;
import core.sys.posix.fcntl : open, O_RDONLY, O_NOFOLLOW;
import core.sys.posix.sys.stat : fstat, lstat, stat, stat_t,
    S_ISDIR, S_ISLNK, S_ISREG;
import core.sys.posix.unistd : close, read;
import std.file : FileException, exists, isFile, isSymlink;
import std.path : absolutePath, baseName, buildPath, dirName;
import std.string : fromStringz, indexOf, toStringz;
import std.typecons : Nullable, nullable;

enum SinkState : string { planned = "planned", committed = "committed",
    failed = "failed", uncertain = "uncertain" }

struct SinkKey {
    DocumentId document;
    ubyte[32] inputSha256;
    ubyte[32] configSha256;
    string sink;
}

struct SinkRecord {
    SinkKey key;
    string destination;
    SinkState state;
    bool hasOutput;
    ubyte[32] outputSha256;
    long attempt;
    long updatedUtcMs;
}

/// Durable replay cursor, not a newly constructible DocumentId. The caller
/// resolves the textual ID against its source records before taking action.
struct ReplayRecord {
    string documentId;
    ubyte[32] inputSha256;
    ubyte[32] configSha256;
    string sink;
    string destination;
    SinkState state;
    long attempt;
    long updatedUtcMs;
}

struct ReplayCursor {
    private string databasePath;
    private ulong databaseDevice;
    private ulong databaseInode;
    private SinkState state;
    private string documentId;
    private ubyte[32] inputSha256;
    private ubyte[32] configSha256;
    private string sink;

    version (ManifestHarness) static ReplayCursor malformedForTest() {
        return ReplayCursor("/foreign/manifest.db", 0, 0, SinkState.planned,
            "invalid", ubyte[32].init, ubyte[32].init, "sink");
    }
}

struct ReplayPage {
    ReplayRecord[] rows;
    ReplayCursor next;
}

struct CheckpointStats {
    int logFrames;
    int checkpointedFrames;
}

/// Only verified committed records may be skipped. All other outcomes require
/// the caller to decide whether replacing a possibly published sink is safe.
enum Inspection { absent, retryRequired, verifiedCommitted }

ubyte[32] inputDigest(const(ubyte)[] bytes) { return sha256Of(bytes); }
ubyte[32] outputDigest(const(ubyte)[] bytes) { return sha256Of(bytes); }

ubyte[32] configDigest(const(ubyte)[] canonicalBytes) {
    SHA256 digest;
    digest.put(cast(const(ubyte)[]) "scrubbed:manifest-config:v1\0");
    ulong length = canonicalBytes.length;
    ubyte[8] width;
    size_t index;
    foreach_reverse (shift; [0, 8, 16, 24, 32, 40, 48, 56])
        width[index++] = cast(ubyte)(length >> shift);
    digest.put(width[]);
    digest.put(canonicalBytes);
    return digest.finish();
}

string digestDiagnostic(ubyte[32] digest) {
    return "sha256:" ~ toHexString!(LetterCase.lower)(digest).idup;
}

private enum schema = `
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
PRAGMA application_id=1396920898;
PRAGMA user_version=1;
`;

private void require(bool okay, string message) {
    if (!okay) throw new Exception("local manifest: " ~ message);
}

private long nowUtcMs() {
    auto now = Clock.currTime;
    return now.toUnixTime * 1000 + now.fracSecs.total!"msecs";
}

private void validateKey(ref const(SinkKey) key) {
    auto id = key.document.text;
    bool prefix = (id.length == 71 && id[0 .. 7] == "doc:v1:") ||
        (id.length == 73 && id[0 .. 9] == "child:v1:");
    require(prefix, "uninitialized or incompatible DocumentId");
    foreach (c; id[$ - 64 .. $])
        require((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'),
            "invalid DocumentId hex");
    require(key.sink.length != 0 && key.sink.indexOf('\0') < 0,
        "sink key must be nonempty and NUL-free");
}

private string resolvedName(string path) {
    require(path.length != 0 && path.indexOf('\0') < 0, "invalid path");
    auto absolute = absolutePath(path);
    require(exists(dirName(absolute)), "path parent missing");
    auto parent = realpath(dirName(absolute).toStringz, null);
    require(parent !is null, "cannot resolve path parent");
    scope(exit) free(parent);
    return buildPath(parent.fromStringz.idup, baseName(absolute));
}

private extern(C) char* realpath(const(char)*, char*);

private void safeRegularOrAbsent(string path, bool outputDestination = false) {
    bool link;
    try link = isSymlink(path);
    catch (FileException failure) {
        if (exists(path)) throw failure;
    }
    if (outputDestination && link)
        throw new OutputPolicyViolation("local manifest: symlink path refused: " ~ path);
    require(!link, "symlink path refused: " ~ path);
    if (exists(path)) {
        const regular = isFile(path);
        if (outputDestination && !regular)
            throw new OutputPolicyViolation("local manifest: non-regular path refused: " ~ path);
        require(regular, "non-regular path refused: " ~ path);
    }
}

private bool sameInode(string left, string right) {
    if (!exists(left) || !exists(right)) return false;
    stat_t a, b;
    require(stat(left.toStringz, &a) == 0 && stat(right.toStringz, &b) == 0,
        "cannot stat path");
    return a.st_dev == b.st_dev && a.st_ino == b.st_ino;
}

private void failRehashResource(string message, int errorCode) {
    if (errorCode == ENOSPC || errorCode == EDQUOT ||
        errorCode == EMFILE || errorCode == ENFILE)
        throw new ResourceExhaustion("local manifest: " ~ message, errorCode);
}

/// A non-resource output rehash syscall failure is not evidence of changed output.
class OutputRehashIoFailure : Exception {
    int errorCode;
    this(string message, int errorCode) {
        super("local manifest: " ~ message ~ " (errno=" ~ errorCode.to!string ~ ")");
        this.errorCode = errorCode;
    }
}

private void failRehashIo(string message, int errorCode) {
    failRehashResource(message, errorCode);
    throw new OutputRehashIoFailure(message, errorCode);
}

private string resolvedNameAllowMissingParent(string path) {
    require(path.length != 0 && path.indexOf('\0') < 0, "invalid path");
    auto absolute = absolutePath(path);
    auto cursor = dirName(absolute);
    string[] missing;
    while (true) {
        stat_t info;
        if (lstat(cursor.toStringz, &info) == 0) {
            if (S_ISLNK(info.st_mode)) {
                stat_t target;
                if (stat(cursor.toStringz, &target) != 0) {
                    const savedErrno = errno;
                    if (savedErrno == ENOENT)
                        throw new OutputPolicyViolation(
                            "local manifest: dangling output parent symlink: " ~ cursor);
                    failRehashIo("cannot stat output parent symlink target", savedErrno);
                }
                if (!S_ISDIR(target.st_mode))
                    throw new OutputPolicyViolation(
                        "local manifest: output parent is not a directory: " ~ cursor);
            } else if (!S_ISDIR(info.st_mode))
                throw new OutputPolicyViolation(
                    "local manifest: output parent is not a directory: " ~ cursor);
            auto resolved = realpath(cursor.toStringz, null);
            if (resolved is null) {
                const savedErrno = errno;
                failRehashIo("cannot resolve observed output parent", savedErrno);
            }
            scope(exit) free(resolved);
            auto parent = resolved.fromStringz.idup;
            foreach_reverse (part; missing) parent = buildPath(parent, part);
            return buildPath(parent, baseName(absolute));
        }
        const savedErrno = errno;
        if (savedErrno != ENOENT)
            failRehashIo("cannot stat observed output parent", savedErrno);
        missing ~= baseName(cursor);
        auto parent = dirName(cursor);
        require(parent != cursor, "cannot resolve missing output parent");
        cursor = parent;
    }
}

private bool observedPathExists(string path, string message) {
    stat_t info;
    if (stat(path.toStringz, &info) == 0) return true;
    const savedErrno = errno;
    if (savedErrno == ENOENT) return false;
    failRehashIo(message, savedErrno);
    assert(0);
}

version (FailurePolicyHarness) {
    private void injectedRehashFault(string path, string phase) {
        struct Fault { string name; int code; }
        foreach (spec; [Fault("EMFILE", EMFILE), Fault("ENFILE", ENFILE),
                Fault("ENOSPC", ENOSPC), Fault("EDQUOT", EDQUOT),
                Fault("EIO", EIO), Fault("EACCES", EACCES),
                Fault("EPERM", EPERM), Fault("ELOOP", ELOOP)]) {
            if (exists(path ~ ".fault-rehash-" ~ phase ~ "-" ~ spec.name)) {
                failRehashIo("injected output rehash " ~ phase ~ " failure", spec.code);
                throw new Exception("local manifest: injected output rehash " ~ phase ~ " failure");
            }
        }
    }
}

private ubyte[32] hashFile(string path) {
    version (FailurePolicyHarness) injectedRehashFault(path, "open");
    auto fd = open(path.toStringz, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) {
        const savedErrno = errno;
        failRehashIo("cannot open observed output", savedErrno);
    }
    require(fd >= 0, "cannot open observed output without following symlink");
    scope(exit) close(fd);
    stat_t info;
    version (FailurePolicyHarness) injectedRehashFault(path, "fstat");
    const statResult = fstat(fd, &info);
    if (statResult != 0) {
        const savedErrno = errno;
        failRehashIo("cannot stat observed output", savedErrno);
    }
    require(statResult == 0 && S_ISREG(info.st_mode), "observed output is not regular");
    SHA256 digest;
    ubyte[64 * 1024] buffer;
    while (true) {
        version (FailurePolicyHarness) injectedRehashFault(path, "read");
        auto amount = read(fd, buffer.ptr, buffer.length);
        if (amount < 0) {
            const savedErrno = errno;
            if (savedErrno == EINTR) continue;
            failRehashIo("observed output read failed", savedErrno);
        }
        require(amount >= 0, "observed output read failed");
        if (amount == 0) break;
        digest.put(buffer[0 .. cast(size_t)amount]);
    }
    return digest.finish();
}

final class LocalManifest {
    private sqlite3* db;
    private string databasePath;
    private ulong databaseDevice;
    private ulong databaseInode;

    this(string path) {
        databasePath = resolvedName(path);
        safeRegularOrAbsent(databasePath);
        safeRegularOrAbsent(databasePath ~ "-wal");
        safeRegularOrAbsent(databasePath ~ "-shm");
        auto rc = sqlite3_open_v2(databasePath.toStringz, &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, null);
        if (rc != SQLITE_OK) {
            auto reason = error;
            close();
            throw new Exception("local manifest: open failed: " ~ reason);
        }
        try {
            require(sqlite3_libversion().fromStringz == "3.53.4", "wrong SQLite version");
            require(sqlite3_busy_timeout(db, 2000) == SQLITE_OK, "busy timeout");
            auto application = scalar("PRAGMA application_id");
            auto schemaVersion = scalar("PRAGMA user_version");
            if (application == 0 && schemaVersion == 0) {
                require(scalar("SELECT count(*) FROM sqlite_master WHERE name NOT GLOB 'sqlite_*'") == 0,
                    "foreign unversioned database");
                exec("PRAGMA journal_mode=WAL");
                exec("PRAGMA synchronous=FULL");
                exec("BEGIN IMMEDIATE");
                try { exec(schema); exec("COMMIT"); }
                catch (Throwable failure) { exec("ROLLBACK"); throw failure; }
            } else {
                require(application == 1396920898 && schemaVersion == 1,
                    "incompatible application or schema version");
                require(scalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='sink_state'") == 1,
                    "missing sink_state table");
                exec("PRAGMA journal_mode=WAL");
                exec("PRAGMA synchronous=FULL");
            }
            require(textScalar("PRAGMA journal_mode") == "wal", "WAL unavailable");
            require(scalar("PRAGMA synchronous") == 2, "FULL synchronous unavailable");
            stat_t info;
            require(stat(databasePath.toStringz, &info) == 0, "cannot stat database");
            databaseDevice = cast(ulong)info.st_dev;
            databaseInode = cast(ulong)info.st_ino;
        } catch (Throwable failure) { close(); throw failure; }
    }

    ~this() { close(); }
    void close() {
        if (db !is null) {
            auto current = db;
            db = null;
            require(sqlite3_close(current) == SQLITE_OK, "close failed");
        }
    }
    private string error() { return db is null ? "null handle" : sqlite3_errmsg(db).fromStringz.idup; }
    private void exec(string sql) {
        require(db !is null && sqlite3_exec(db, sql.toStringz, null, null, null) == SQLITE_OK,
            "SQLite exec failed: " ~ error);
    }
    private long scalar(string sql) {
        auto statement = prepare(sql);
        scope(exit) sqlite3_finalize(statement);
        require(sqlite3_step(statement) == SQLITE_ROW, "scalar failed: " ~ error);
        return sqlite3_column_int64(statement, 0);
    }
    private string textScalar(string sql) {
        auto statement = prepare(sql);
        scope(exit) sqlite3_finalize(statement);
        require(sqlite3_step(statement) == SQLITE_ROW, "text scalar failed: " ~ error);
        return sqlite3_column_text(statement, 0).fromStringz.idup;
    }
    private sqlite3_stmt* prepare(string sql) {
        sqlite3_stmt* statement;
        require(sqlite3_prepare_v2(db, sql.toStringz, -1, &statement, null) == SQLITE_OK,
            "prepare failed: " ~ error);
        return statement;
    }
    private void bindText(sqlite3_stmt* statement, int column, string value) {
        require(sqlite3_bind_text(statement, column, value.toStringz,
            cast(int)value.length, cast(void*)-1) == SQLITE_OK, "bind text failed");
    }
    private void bindDigest(sqlite3_stmt* statement, int column, ref const(ubyte[32]) value) {
        require(sqlite3_bind_blob(statement, column, value.ptr, 32,
            cast(void*)-1) == SQLITE_OK, "bind digest failed");
    }
    private void bindKey(sqlite3_stmt* statement, ref const(SinkKey) key) {
        validateKey(key);
        bindText(statement, 1, key.document.text);
        bindDigest(statement, 2, key.inputSha256);
        bindDigest(statement, 3, key.configSha256);
        bindText(statement, 4, key.sink);
    }
    private void stepDone(sqlite3_stmt* statement) {
        require(sqlite3_step(statement) == SQLITE_DONE, "SQLite write failed: " ~ error);
    }
    private void safeDestination(string destination) {
        auto resolved = resolvedName(destination);
        safeRegularOrAbsent(resolved, true);
        if (resolved == databasePath || resolved == databasePath ~ "-wal" ||
            resolved == databasePath ~ "-shm")
            throw new OutputPolicyViolation("local manifest: destination aliases manifest file");
        if (sameInode(resolved, databasePath) ||
            sameInode(resolved, databasePath ~ "-wal") ||
            sameInode(resolved, databasePath ~ "-shm"))
            throw new OutputPolicyViolation("local manifest: destination hard-links manifest file");
    }

    /// Planning never upgrades an existing failed, uncertain or committed row.
    /// It rejects a different destination for the same immutable key.
    SinkRecord plan(SinkKey key, string destination) {
        validateKey(key);
        safeDestination(destination);
        auto old = lookup(key);
        if (!old.isNull) {
            require(old.get.destination == resolvedName(destination),
                "same sink key has a different destination");
            if (old.get.state == SinkState.committed) inspect(key);
            return lookup(key).get;
        }
        auto statement = prepare(`INSERT INTO sink_state VALUES(?1,?2,?3,?4,?5,'planned',NULL,0,?6)`);
        scope(exit) sqlite3_finalize(statement);
        bindKey(statement, key);
        bindText(statement, 5, resolvedName(destination));
        require(sqlite3_bind_int64(statement, 6, nowUtcMs()) == SQLITE_OK,
            "bind time failed");
        stepDone(statement);
        return lookup(key).get;
    }

    Nullable!SinkRecord lookup(SinkKey key) {
        auto statement = prepare(`SELECT destination,state,output_sha256,attempt,updated_utc_ms
            FROM sink_state WHERE document_id=?1 AND input_sha256=?2 AND config_sha256=?3 AND sink_key=?4`);
        scope(exit) sqlite3_finalize(statement);
        bindKey(statement, key);
        auto rc = sqlite3_step(statement);
        if (rc == SQLITE_DONE) return Nullable!SinkRecord.init;
        require(rc == SQLITE_ROW, "lookup failed: " ~ error);
        SinkRecord result;
        result.key = key;
        result.destination = sqlite3_column_text(statement, 0).fromStringz.idup;
        result.state = cast(SinkState)sqlite3_column_text(statement, 1).fromStringz.idup;
        result.hasOutput = sqlite3_column_type(statement, 2) != SQLITE_NULL;
        if (result.hasOutput) {
            require(sqlite3_column_bytes(statement, 2) == 32, "invalid stored digest");
            result.outputSha256[] = (cast(const(ubyte)*)sqlite3_column_blob(statement, 2))[0 .. 32];
        }
        result.attempt = sqlite3_column_int64(statement, 3);
        result.updatedUtcMs = sqlite3_column_int64(statement, 4);
        return nullable(result);
    }

    /// Hashes observed destination independently. A previously committed row
    /// is invalidated on deletion, path hazard, or mismatched bytes.
    Inspection inspect(SinkKey key, string intendedDestination = "") {
        auto prior = lookup(key);
        if (prior.isNull) return Inspection.absent;
        auto row = prior.get;
        if (row.state != SinkState.committed) return Inspection.retryRequired;
        if (!observedPathExists(dirName(row.destination),
                "cannot stat observed output parent")) {
            auto storedRoute = resolvedNameAllowMissingParent(row.destination);
            if (intendedDestination.length &&
                storedRoute != resolvedNameAllowMissingParent(intendedDestination))
                throw new OutputPolicyViolation(
                    "local manifest: committed destination differs from selected output");
            transition(key, SinkState.uncertain, false, row.outputSha256);
            return Inspection.retryRequired;
        }
        safeDestination(row.destination);
        if (intendedDestination.length &&
            row.destination != resolvedName(intendedDestination))
            throw new OutputPolicyViolation(
                "local manifest: committed destination differs from selected output");
        if (observedPathExists(row.destination, "cannot stat observed output")) {
            require(row.hasOutput, "committed row is missing output digest");
            if (hashFile(row.destination) == row.outputSha256)
                return Inspection.verifiedCommitted;
        }
        transition(key, SinkState.uncertain, false, row.outputSha256);
        return Inspection.retryRequired;
    }

    /// Call only after the sink has published. The observed file is read and
    /// hashed here; an expected digest cannot bless absent or modified bytes.
    void commitPublished(SinkKey key, string destination, ubyte[32] expectedOutput) {
        auto prior = lookup(key);
        require(!prior.isNull, "commit requires a planned record");
        require(prior.get.destination == resolvedName(destination), "destination changed");
        require(prior.get.state == SinkState.planned,
            "explicit retry is required before committing failed or uncertain state");
        safeDestination(destination);
        require(exists(destination) && hashFile(destination) == expectedOutput,
            "published output missing or digest mismatch");
        transition(key, SinkState.committed, true, expectedOutput);
    }

    void markFailed(SinkKey key) { transition(key, SinkState.failed, false, ubyte[32].init); }
    void markUncertain(SinkKey key) { transition(key, SinkState.uncertain, false, ubyte[32].init); }

    /// Caller has inspected the destination and accepted replacement risk.
    void retry(SinkKey key) {
        auto prior = lookup(key);
        require(!prior.isNull && prior.get.state != SinkState.committed,
            "retry requires planned, failed or uncertain state");
        safeDestination(prior.get.destination);
        transition(key, SinkState.planned, false, ubyte[32].init);
    }

    private void transition(SinkKey key, SinkState state, bool hasDigest, ubyte[32] digest) {
        auto statement = prepare(`UPDATE sink_state SET state=?5,output_sha256=?6,
            attempt=attempt+1,updated_utc_ms=?7
            WHERE document_id=?1 AND input_sha256=?2 AND config_sha256=?3 AND sink_key=?4`);
        scope(exit) sqlite3_finalize(statement);
        bindKey(statement, key);
        bindText(statement, 5, cast(string)state);
        if (hasDigest) bindDigest(statement, 6, digest);
        require(sqlite3_bind_int64(statement, 7, nowUtcMs()) == SQLITE_OK,
            "bind time failed");
        stepDone(statement);
        require(sqlite3_changes(db) == 1, "state transition found no record");
    }

    /// Bounded state/keyset replay. Cursor is produced by this manifest only.
    ReplayPage replay(SinkState state, size_t limit, ReplayCursor after = ReplayCursor.init) {
        require(state == SinkState.planned || state == SinkState.failed ||
            state == SinkState.uncertain, "invalid recovery state");
        require(limit > 0 && limit <= 1024, "replay limit outside 1..1024");
        bool continued = after.databasePath.length != 0;
        if (continued)
            require(after.databasePath == databasePath &&
                after.databaseDevice == databaseDevice &&
                after.databaseInode == databaseInode && after.state == state &&
                after.documentId.length != 0 && after.sink.length != 0,
                "foreign or malformed replay cursor");
        auto sql = `SELECT document_id,input_sha256,config_sha256,sink_key,destination,state,
            output_sha256,attempt,updated_utc_ms FROM sink_state WHERE state=?1`;
        if (continued) sql ~= ` AND (document_id,input_sha256,config_sha256,sink_key)>(?2,?3,?4,?5)`;
        sql ~= ` ORDER BY document_id,input_sha256,config_sha256,sink_key LIMIT ?6`;
        auto statement = prepare(sql);
        scope(exit) sqlite3_finalize(statement);
        bindText(statement, 1, cast(string)state);
        if (continued) {
            bindText(statement, 2, after.documentId);
            bindDigest(statement, 3, after.inputSha256);
            bindDigest(statement, 4, after.configSha256);
            bindText(statement, 5, after.sink);
        }
        require(sqlite3_bind_int64(statement, 6, cast(long)limit) == SQLITE_OK,
            "bind limit failed");
        ReplayRecord[] result;
        int rc;
        while ((rc = sqlite3_step(statement)) == SQLITE_ROW) {
            ReplayRecord row;
            row.documentId = sqlite3_column_text(statement, 0).fromStringz.idup;
            require(sqlite3_column_bytes(statement, 1) == 32 &&
                sqlite3_column_bytes(statement, 2) == 32, "invalid replay digest");
            row.inputSha256[] = (cast(const(ubyte)*)sqlite3_column_blob(statement, 1))[0 .. 32];
            row.configSha256[] = (cast(const(ubyte)*)sqlite3_column_blob(statement, 2))[0 .. 32];
            row.sink = sqlite3_column_text(statement, 3).fromStringz.idup;
            row.destination = sqlite3_column_text(statement, 4).fromStringz.idup;
            row.state = cast(SinkState)sqlite3_column_text(statement, 5).fromStringz.idup;
            row.attempt = sqlite3_column_int64(statement, 7);
            row.updatedUtcMs = sqlite3_column_int64(statement, 8);
            result ~= row;
        }
        require(rc == SQLITE_DONE, "replay failed: " ~ error);
        ReplayPage page;
        page.rows = result;
        if (result.length) {
            auto last = result[$ - 1];
            page.next = ReplayCursor(databasePath, databaseDevice, databaseInode,
                state, last.documentId,
                last.inputSha256, last.configSha256, last.sink);
        }
        return page;
    }

    CheckpointStats checkpoint() {
        int logFrames, checkpointed;
        require(sqlite3_wal_checkpoint_v2(db, "main".toStringz,
            SQLITE_CHECKPOINT_TRUNCATE, &logFrames, &checkpointed) == SQLITE_OK,
            "checkpoint failed: " ~ error);
        require(logFrames == 0 && checkpointed == 0, "checkpoint was not complete");
        return CheckpointStats(logFrames, checkpointed);
    }
}
