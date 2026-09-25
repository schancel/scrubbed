/// Durable, process-local SQLite implementation of the frontier contract.
module effects.sqlite_frontier;

import domain.job_queue;
import effects.sqlite_ffi;
import std.conv : to;
import std.file : exists, isFile, isSymlink;
import std.string : fromStringz, toStringz;

private enum applicationId = 1396920902;
private enum schemaVersion = 1;
private enum maxCacheKiB = 2048;
private enum walAutoCheckpointPages = 64;
private enum sqliteDescriptor = FrontierBackendDescriptor(
    frontierContractName, currentFrontierContractVersion, true);

struct SQLiteFrontierResources {
    size_t pageCount;
    size_t pageSize;
    size_t cacheKiB;
    size_t autoCheckpointPages;
    size_t openStatements;
    bool autocommit;
}

private enum schema = `
CREATE TABLE frontier_meta(
 id INTEGER PRIMARY KEY CHECK(id=1),
 max_pages INTEGER NOT NULL CHECK(max_pages>0),
 max_pages_per_host INTEGER NOT NULL CHECK(max_pages_per_host>0),
 max_depth INTEGER NOT NULL CHECK(max_depth>=0),
 max_queued INTEGER NOT NULL CHECK(max_queued>0),
 max_active INTEGER NOT NULL CHECK(max_active>0),
 max_stored_bytes INTEGER NOT NULL CHECK(max_stored_bytes>0),
 max_provenance_bytes INTEGER NOT NULL CHECK(max_provenance_bytes>=0),
 max_discoveries INTEGER NOT NULL CHECK(max_discoveries>0),
 max_discovery_bytes INTEGER NOT NULL CHECK(max_discovery_bytes>0),
 next_order INTEGER NOT NULL CHECK(next_order>=0),
 sealed INTEGER NOT NULL CHECK(sealed IN (0,1)),
 canceled INTEGER NOT NULL CHECK(canceled IN (0,1))
);
CREATE TABLE frontier_candidate(
 policy_id TEXT NOT NULL CHECK(octet_length(policy_id)>0),
 canonical_locator TEXT NOT NULL CHECK(octet_length(canonical_locator)>0),
 host_key TEXT NOT NULL CHECK(octet_length(host_key)>0),
 depth INTEGER NOT NULL CHECK(depth>=0),
 provenance TEXT NOT NULL,
 state INTEGER NOT NULL CHECK(state BETWEEN 0 AND 5),
 generation INTEGER NOT NULL,
 deferred_retry INTEGER NOT NULL CHECK(deferred_retry IN (0,1)),
 queue_order INTEGER CHECK(queue_order IS NULL OR queue_order>=0),
 stored_bytes INTEGER NOT NULL CHECK(stored_bytes>=0),
 PRIMARY KEY(policy_id,canonical_locator),
 CHECK((state IN (0,1,4) AND queue_order IS NOT NULL) OR
       (state IN (2,3,5) AND queue_order IS NULL)),
 CHECK(state=1 OR deferred_retry=0),
 CHECK(state IN (0,1) OR generation!=0)
) WITHOUT ROWID;
CREATE INDEX frontier_pending ON frontier_candidate(state,queue_order,policy_id,canonical_locator);
CREATE INDEX frontier_host ON frontier_candidate(host_key);
PRAGMA application_id=1396920902;
PRAGMA user_version=1;
`;

class SQLiteFrontierException : Exception {
    this(string reason) { super("SQLite frontier: " ~ reason); }
}

private void need(bool okay, string reason) {
    if (!okay) throw new SQLiteFrontierException(reason);
}

private long checkedLong(size_t value, string name) {
    need(value <= cast(size_t)long.max, name ~ " exceeds SQLite integer range");
    return cast(long)value;
}

private size_t checkedSize(long value, string name) {
    need(value >= 0, "negative " ~ name);
    return cast(size_t)value;
}

// SQLite INTEGER is signed. Store the complete ulong lease-generation bit
// pattern in that signed cell so contract generation 2^63..ulong.max remains
// representable without changing the durable column shape.
private long storedGeneration(ulong value) { return cast(long)value; }
private ulong contractGeneration(long value) { return cast(ulong)value; }

private final class Database {
    sqlite3* handle;

    this(string path, int flags) {
        auto rc = sqlite3_open_v2(path.toStringz, &handle, flags, null);
        if (rc != SQLITE_OK) {
            if (handle !is null) sqlite3_close(handle);
            handle = null;
            throw new SQLiteFrontierException("open failed");
        }
        need(sqlite3_busy_timeout(handle, 2000) == SQLITE_OK,
            "busy timeout unavailable");
    }

    ~this() { close(); }

    void close() {
        if (handle is null) return;
        auto prior = handle;
        handle = null;
        need(sqlite3_close(prior) == SQLITE_OK, "close failed");
    }

    void exec(string sql) {
        need(sqlite3_exec(handle, sql.toStringz, null, null, null) == SQLITE_OK,
            "SQL failed: " ~ error);
    }

    sqlite3_stmt* prepare(string sql) const {
        sqlite3_stmt* statement;
        need(sqlite3_prepare_v2(cast(sqlite3*)handle, sql.toStringz, -1, &statement, null) == SQLITE_OK,
            "prepare failed: " ~ error);
        return statement;
    }

    long scalar(string sql) const {
        auto statement = prepare(sql);
        scope(exit) sqlite3_finalize(statement);
        need(sqlite3_step(statement) == SQLITE_ROW, "read failed: " ~ error);
        return sqlite3_column_int64(statement, 0);
    }

    string textScalar(string sql) const {
        auto statement = prepare(sql);
        scope(exit) sqlite3_finalize(statement);
        need(sqlite3_step(statement) == SQLITE_ROW, "read failed: " ~ error);
        return columnText(statement, 0);
    }

    string error() const {
        return handle is null ? "closed" :
            sqlite3_errmsg(cast(sqlite3*)handle).fromStringz.idup;
    }
}

private void bindText(sqlite3_stmt* statement, int at, string value) {
    need(value.length <= int.max, "text value exceeds SQLite bind limit");
    need(sqlite3_bind_text(statement, at, value.toStringz,
        cast(int)value.length, cast(void*)-1) == SQLITE_OK, "text bind failed");
}

private void bindLong(sqlite3_stmt* statement, int at, long value) {
    need(sqlite3_bind_int64(statement, at, value) == SQLITE_OK, "integer bind failed");
}

private void done(sqlite3_stmt* statement) {
    need(sqlite3_step(statement) == SQLITE_DONE, "write failed");
}

private string columnText(sqlite3_stmt* statement, int at) {
    auto bytes = sqlite3_column_bytes(statement, at);
    auto value = sqlite3_column_text(statement, at);
    need(bytes >= 0 && (bytes == 0 || value !is null), "invalid text column");
    return bytes == 0 ? "" : value[0 .. cast(size_t)bytes].idup;
}

private size_t inputBytes(CandidateInput input, out bool valid) {
    size_t result;
    foreach (part; [input.policyId, input.canonicalLocator, input.hostKey,
            input.provenance]) {
        if (part.length > size_t.max - result) {
            valid = false;
            return 0;
        }
        result += part.length;
    }
    valid = true;
    return result;
}

private void bindKey(sqlite3_stmt* statement, CandidateKey key, int start = 1) {
    bindText(statement, start, key.policyId);
    bindText(statement, start + 1, key.canonicalLocator);
}

private FrontierLimits readLimits(Database db) {
    auto statement = db.prepare(`SELECT max_pages,max_pages_per_host,max_depth,
        max_queued,max_active,max_stored_bytes,max_provenance_bytes,
        max_discoveries,max_discovery_bytes FROM frontier_meta WHERE id=1`);
    scope(exit) sqlite3_finalize(statement);
    need(sqlite3_step(statement) == SQLITE_ROW, "missing frontier metadata");
    FrontierLimits result;
    result.maxPages = checkedSize(sqlite3_column_int64(statement, 0), "page limit");
    result.maxPagesPerHost = checkedSize(sqlite3_column_int64(statement, 1), "host limit");
    result.maxDepth = checkedSize(sqlite3_column_int64(statement, 2), "depth limit");
    result.maxQueued = checkedSize(sqlite3_column_int64(statement, 3), "queue limit");
    result.maxActiveLeases = checkedSize(sqlite3_column_int64(statement, 4), "active limit");
    result.maxStoredBytes = checkedSize(sqlite3_column_int64(statement, 5), "stored-byte limit");
    result.maxProvenanceBytes = checkedSize(sqlite3_column_int64(statement, 6), "provenance limit");
    result.maxDiscoveriesPerFinish = checkedSize(sqlite3_column_int64(statement, 7), "discovery limit");
    result.maxDiscoveryInputBytes = checkedSize(sqlite3_column_int64(statement, 8), "discovery-byte limit");
    need(sqlite3_step(statement) == SQLITE_DONE, "duplicate frontier metadata");
    return result;
}

private void insertLimits(Database db, FrontierLimits limits) {
    auto statement = db.prepare(`INSERT INTO frontier_meta VALUES
        (1,?1,?2,?3,?4,?5,?6,?7,?8,?9,0,0,0)`);
    scope(exit) sqlite3_finalize(statement);
    bindLong(statement, 1, checkedLong(limits.maxPages, "page limit"));
    bindLong(statement, 2, checkedLong(limits.maxPagesPerHost, "host limit"));
    bindLong(statement, 3, checkedLong(limits.maxDepth, "depth limit"));
    bindLong(statement, 4, checkedLong(limits.maxQueued, "queue limit"));
    bindLong(statement, 5, checkedLong(limits.maxActiveLeases, "active limit"));
    bindLong(statement, 6, checkedLong(limits.maxStoredBytes, "stored-byte limit"));
    bindLong(statement, 7, checkedLong(limits.maxProvenanceBytes, "provenance limit"));
    bindLong(statement, 8, checkedLong(limits.maxDiscoveriesPerFinish, "discovery limit"));
    bindLong(statement, 9, checkedLong(limits.maxDiscoveryInputBytes, "discovery-byte limit"));
    done(statement);
}

private void validateLimits(FrontierLimits limits) {
    need(limits.maxPages > 0, "page limit must be positive");
    need(limits.maxPagesPerHost > 0, "host limit must be positive");
    need(limits.maxQueued > 0, "queue limit must be positive");
    need(limits.maxActiveLeases > 0, "active limit must be positive");
    need(limits.maxStoredBytes > 0, "stored-byte limit must be positive");
    need(limits.maxDiscoveriesPerFinish > 0, "discovery limit must be positive");
    need(limits.maxDiscoveryInputBytes > 0, "discovery-byte limit must be positive");
    foreach (value; [limits.maxPages, limits.maxPagesPerHost, limits.maxDepth,
            limits.maxQueued, limits.maxActiveLeases, limits.maxStoredBytes,
            limits.maxProvenanceBytes, limits.maxDiscoveriesPerFinish,
            limits.maxDiscoveryInputBytes])
        need(value <= cast(size_t)long.max, "limit exceeds SQLite integer range");
}

private void validateShape(Database db) {
    need(db.scalar("PRAGMA application_id") == applicationId &&
        db.scalar("PRAGMA user_version") == schemaVersion,
        "incompatible schema");
    need(db.textScalar("PRAGMA integrity_check") == "ok", "integrity check failed");
    auto expected = new Database(":memory:", SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE);
    scope(exit) expected.close();
    expected.exec(schema);
    auto query = `SELECT type,name,sql FROM sqlite_master
        WHERE name NOT GLOB 'sqlite_*' ORDER BY type,name`;
    auto actualRows = db.prepare(query);
    auto expectedRows = expected.prepare(query);
    scope(exit) {
        sqlite3_finalize(actualRows);
        sqlite3_finalize(expectedRows);
    }
    while (true) {
        auto actual = sqlite3_step(actualRows);
        auto wanted = sqlite3_step(expectedRows);
        need(actual == wanted, "incompatible schema shape");
        if (actual == SQLITE_DONE) break;
        need(actual == SQLITE_ROW, "schema read failed");
        foreach (column; 0 .. 3)
            need(columnText(actualRows, column) == columnText(expectedRows, column),
                "incompatible schema shape");
    }
    need(db.scalar("SELECT count(*) FROM frontier_meta") == 1,
        "invalid metadata cardinality");
    // Affinity and CHECK expressions do not guarantee the on-disk storage
    // class. Reject malformed values before any sqlite3_column_int64 coercion.
    need(db.scalar(`SELECT count(*) FROM frontier_meta WHERE
        typeof(id)!='integer' OR typeof(max_pages)!='integer' OR
        typeof(max_pages_per_host)!='integer' OR typeof(max_depth)!='integer' OR
        typeof(max_queued)!='integer' OR typeof(max_active)!='integer' OR
        typeof(max_stored_bytes)!='integer' OR
        typeof(max_provenance_bytes)!='integer' OR
        typeof(max_discoveries)!='integer' OR
        typeof(max_discovery_bytes)!='integer' OR
        typeof(next_order)!='integer' OR typeof(sealed)!='integer' OR
        typeof(canceled)!='integer'`) == 0, "invalid metadata storage class");
    need(db.scalar(`SELECT count(*) FROM frontier_candidate WHERE
        typeof(policy_id)!='text' OR typeof(canonical_locator)!='text' OR
        typeof(host_key)!='text' OR typeof(depth)!='integer' OR
        typeof(provenance)!='text' OR typeof(state)!='integer' OR
        typeof(generation)!='integer' OR typeof(deferred_retry)!='integer' OR
        (queue_order IS NOT NULL AND typeof(queue_order)!='integer') OR
        typeof(stored_bytes)!='integer'`) == 0,
        "invalid candidate storage class");
    need(db.scalar(`SELECT count(*) FROM frontier_candidate WHERE
        octet_length(policy_id)=0 OR octet_length(canonical_locator)=0 OR
        octet_length(host_key)=0`) == 0, "empty durable candidate identity");
    need(db.scalar(`SELECT count(*) FROM frontier_candidate WHERE
        (state IN (0,1,4) AND queue_order IS NULL) OR
        (state IN (2,3,5) AND queue_order IS NOT NULL) OR
        (state!=1 AND deferred_retry!=0) OR
        (queue_order IS NOT NULL AND queue_order<0) OR
        (state IN (2,3,4,5) AND generation=0)`) == 0,
        "invalid candidate state");
    need(db.scalar(`SELECT count(*) FROM (
        SELECT queue_order FROM frontier_candidate WHERE queue_order IS NOT NULL
        GROUP BY queue_order HAVING count(*)!=1)`) == 0, "duplicate queue order");
    need(db.scalar(`SELECT count(*) FROM frontier_candidate c WHERE
        stored_bytes != octet_length(policy_id)+octet_length(canonical_locator)+
        octet_length(host_key)+octet_length(provenance)`) == 0,
        "invalid stored-byte accounting");
}

/// Open a named durable local queue. A missing path is created; an existing
/// path must already be a compatible v1 frontier with exactly matching limits.
QueueOpenResult openSQLiteJobQueue(string path, FrontierLimits limits,
        FrontierRequirements requirements = FrontierRequirements()) {
    QueueOpenResult result;
    result.backend = sqliteDescriptor;
    if (!sqliteDescriptor.satisfies(requirements)) {
        result.code = QueueOpenCode.incompatibleContract;
        return result;
    }
    validateLimits(limits);
    need(path.length != 0, "database path is empty");
    auto fresh = !exists(path);
    if (!fresh) {
        need(!isSymlink(path), "database symlink refused");
        need(isFile(path), "database is not a regular file");
    }
    foreach (suffix; ["-wal", "-shm"]) {
        auto sidecar = path ~ suffix;
        if (exists(sidecar)) {
            need(!fresh, "orphan SQLite sidecar refused");
            need(!isSymlink(sidecar) && isFile(sidecar),
                "unsafe SQLite sidecar refused");
        }
    }
    auto queue = new SQLiteJobQueue(path, limits, fresh);
    result.queue = queue;
    result.code = QueueOpenCode.opened;
    return result;
}

/// The default local backend. The alias keeps callers on the backend-neutral
/// JobQueue contract and leaves remote profile selection outside this module.
QueueOpenResult openLocalJobQueue(string path, FrontierLimits limits,
        FrontierRequirements requirements = FrontierRequirements()) {
    return openSQLiteJobQueue(path, limits, requirements);
}

/// One handle owns no scheduler state outside SQLite. Multiple local handles
/// coordinate through SQLite's single-writer transactions and lease generations.
final class SQLiteJobQueue : JobQueue {
private:
    Database db;
    string path;
    FrontierLimits limits_;
    bool poisoned;

    this(string databasePath, FrontierLimits wanted, bool fresh) {
        path = databasePath.idup;
        db = new Database(path, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE);
        try {
            need(sqlite3_libversion().fromStringz == "3.53.4", "wrong SQLite version");
            db.exec("PRAGMA trusted_schema=OFF");
            db.exec("PRAGMA foreign_keys=ON");
            if (fresh) {
                db.exec("PRAGMA journal_mode=WAL");
                db.exec("PRAGMA synchronous=FULL");
                db.exec("BEGIN IMMEDIATE");
                try {
                    auto storedVersion = db.scalar("PRAGMA user_version");
                    if (storedVersion == 0) {
                        db.exec(schema);
                        insertLimits(db, wanted);
                    }
                    db.exec("COMMIT");
                } catch (Throwable failure) {
                    try db.exec("ROLLBACK"); catch (Throwable ignored) {}
                    throw failure;
                }
            }
            // Existing durable bytes are fully validated before PRAGMAs that
            // can change the database header or create WAL sidecars.
            validateShape(db);
            limits_ = readLimits(db);
            need(limits_ == wanted, "configured limits differ from durable limits");
            validateContents();
            db.exec("PRAGMA journal_mode=WAL");
            db.exec("PRAGMA synchronous=FULL");
            db.exec("PRAGMA cache_size=-" ~ maxCacheKiB.to!string);
            db.exec("PRAGMA wal_autocheckpoint=" ~ walAutoCheckpointPages.to!string);
            db.exec("PRAGMA journal_size_limit=1048576");
            need(db.textScalar("PRAGMA journal_mode") == "wal" &&
                db.scalar("PRAGMA synchronous") == 2,
                "durability mode unavailable");
        } catch (Throwable failure) {
            db.close();
            throw failure;
        }
    }

    void live() const {
        need(db !is null && db.handle !is null && !poisoned, "fail-stop handle");
    }

    void transaction(void delegate() operation) {
        live();
        bool began;
        try {
            db.exec("BEGIN IMMEDIATE");
            began = true;
            operation();
            fault("before-commit");
            db.exec("COMMIT");
            fault("after-commit");
        } catch (Throwable failure) {
            if (began) {
                poisoned = true;
                try db.exec("ROLLBACK"); catch (Throwable ignored) {}
            }
            throw failure;
        }
    }

    private void fault(string point) {
        version (SQLiteFrontierHarness) {
            if (exists(path ~ ".fault-kill-" ~ point)) {
                import core.sys.posix.unistd : _exit;
                _exit(73);
            }
        }
    }

    long countWhere(string predicate) const {
        return db.scalar("SELECT count(*) FROM frontier_candidate WHERE " ~ predicate);
    }

    long nextOrder() {
        auto value = db.scalar("SELECT next_order FROM frontier_meta WHERE id=1");
        need(value < long.max, "queue order exhausted");
        db.exec("UPDATE frontier_meta SET next_order=next_order+1 WHERE id=1");
        return value;
    }

    void setPending(CandidateKey key, bool retry) {
        auto deferred = countWhere("state=1") != 0 ||
            countWhere("state IN (0,4)") >= checkedLong(limits_.maxQueued, "queue limit");
        auto statement = db.prepare(`UPDATE frontier_candidate SET state=?3,
            deferred_retry=?4,queue_order=?5 WHERE policy_id=?1 AND canonical_locator=?2`);
        scope(exit) sqlite3_finalize(statement);
        bindKey(statement, key);
        bindLong(statement, 3, deferred ? cast(long)CandidateState.deferred :
            cast(long)(retry ? CandidateState.retryableFailed : CandidateState.queued));
        bindLong(statement, 4, deferred && retry ? 1 : 0);
        bindLong(statement, 5, nextOrder());
        done(statement);
        need(sqlite3_changes(db.handle) == 1, "pending candidate missing");
    }

    void promote() {
        while (countWhere("state IN (0,4)") < checkedLong(limits_.maxQueued, "queue limit")) {
            auto statement = db.prepare(`SELECT policy_id,canonical_locator,deferred_retry
                FROM frontier_candidate WHERE state=1 ORDER BY queue_order LIMIT 1`);
            auto rc = sqlite3_step(statement);
            if (rc == SQLITE_DONE) { sqlite3_finalize(statement); return; }
            need(rc == SQLITE_ROW, "deferred read failed");
            auto key = CandidateKey(columnText(statement, 0), columnText(statement, 1));
            auto retry = sqlite3_column_int64(statement, 2) != 0;
            sqlite3_finalize(statement);
            auto update = db.prepare(`UPDATE frontier_candidate SET state=?3,
                deferred_retry=0 WHERE policy_id=?1 AND canonical_locator=?2 AND state=1`);
            scope(exit) sqlite3_finalize(update);
            bindKey(update, key);
            bindLong(update, 3, cast(long)(retry ? CandidateState.retryableFailed :
                CandidateState.queued));
            done(update);
            need(sqlite3_changes(db.handle) == 1, "deferred promotion raced");
        }
    }

    Admission admitInside(CandidateInput input) {
        auto key = CandidateKey(input.policyId, input.canonicalLocator);
        if (db.scalar("SELECT sealed FROM frontier_meta WHERE id=1") != 0)
            return Admission(AdmissionCode.refusedSealed, key);
        if (input.policyId.length == 0 || input.canonicalLocator.length == 0)
            return Admission(AdmissionCode.refusedInvalidIdentity, key);
        auto duplicate = db.prepare(`SELECT 1 FROM frontier_candidate
            WHERE policy_id=?1 AND canonical_locator=?2`);
        bindKey(duplicate, key);
        auto duplicateRc = sqlite3_step(duplicate);
        sqlite3_finalize(duplicate);
        need(duplicateRc == SQLITE_ROW || duplicateRc == SQLITE_DONE,
            "duplicate lookup failed");
        if (duplicateRc == SQLITE_ROW) return Admission(AdmissionCode.duplicate, key);
        if (input.hostKey.length == 0)
            return Admission(AdmissionCode.refusedInvalidHost, key);
        if (input.provenance.length > limits_.maxProvenanceBytes)
            return Admission(AdmissionCode.refusedProvenanceLimit, key);
        if (input.depth > limits_.maxDepth)
            return Admission(AdmissionCode.refusedDepthLimit, key);
        if (countWhere("1") >= checkedLong(limits_.maxPages, "page limit"))
            return Admission(AdmissionCode.refusedPageLimit, key);
        auto host = db.prepare("SELECT count(*) FROM frontier_candidate WHERE host_key=?1");
        bindText(host, 1, input.hostKey);
        need(sqlite3_step(host) == SQLITE_ROW, "host count failed");
        auto hostPages = sqlite3_column_int64(host, 0);
        sqlite3_finalize(host);
        if (hostPages >= checkedLong(limits_.maxPagesPerHost, "host limit"))
            return Admission(AdmissionCode.refusedHostLimit, key);
        bool valid;
        auto bytes = inputBytes(input, valid);
        if (!valid || bytes > limits_.maxStoredBytes ||
                checkedLong(bytes, "candidate bytes") >
                checkedLong(limits_.maxStoredBytes, "stored-byte limit") -
                db.scalar("SELECT coalesce(sum(stored_bytes),0) FROM frontier_candidate"))
            return Admission(AdmissionCode.refusedStoredByteLimit, key);

        auto deferred = countWhere("state=1") != 0 ||
            countWhere("state IN (0,4)") >= checkedLong(limits_.maxQueued, "queue limit");
        auto statement = db.prepare(`INSERT INTO frontier_candidate VALUES
            (?1,?2,?3,?4,?5,?6,0,0,?7,?8)`);
        scope(exit) sqlite3_finalize(statement);
        bindText(statement, 1, input.policyId);
        bindText(statement, 2, input.canonicalLocator);
        bindText(statement, 3, input.hostKey);
        bindLong(statement, 4, checkedLong(input.depth, "candidate depth"));
        bindText(statement, 5, input.provenance);
        bindLong(statement, 6, cast(long)(deferred ? CandidateState.deferred : CandidateState.queued));
        bindLong(statement, 7, nextOrder());
        bindLong(statement, 8, checkedLong(bytes, "candidate bytes"));
        done(statement);
        return Admission(deferred ? AdmissionCode.admittedDeferred :
            AdmissionCode.admittedQueued, key);
    }

    bool readCandidate(CandidateKey key, out CandidateView result) const {
        auto statement = db.prepare(`SELECT host_key,depth,provenance,state,generation
            FROM frontier_candidate WHERE policy_id=?1 AND canonical_locator=?2`);
        scope(exit) sqlite3_finalize(statement);
        bindKey(statement, key);
        auto rc = sqlite3_step(statement);
        if (rc == SQLITE_DONE) return false;
        need(rc == SQLITE_ROW, "candidate read failed");
        result = CandidateView(CandidateInput(key.policyId.idup,
            key.canonicalLocator.idup, columnText(statement, 0),
            checkedSize(sqlite3_column_int64(statement, 1), "candidate depth"),
            columnText(statement, 2)),
            cast(CandidateState)sqlite3_column_int64(statement, 3),
            contractGeneration(sqlite3_column_int64(statement, 4)));
        return true;
    }

    void validateContents() const {
        auto counts = this.counts;
        need(counts.pages <= limits_.maxPages && counts.queued <= limits_.maxQueued &&
            counts.activeLeases <= limits_.maxActiveLeases &&
            counts.storedBytes <= limits_.maxStoredBytes,
            "durable counters exceed configured limits");
        need(db.scalar(`SELECT count(*) FROM frontier_candidate WHERE
            depth>` ~ checkedLong(limits_.maxDepth, "depth limit").to!string ~
            ` OR octet_length(provenance)>` ~
            checkedLong(limits_.maxProvenanceBytes, "provenance limit").to!string) == 0,
            "durable candidate exceeds configured limits");
        need(db.scalar(`SELECT count(*) FROM (SELECT host_key FROM frontier_candidate
            GROUP BY host_key HAVING count(*)>` ~
            checkedLong(limits_.maxPagesPerHost, "host limit").to!string ~ ")") == 0,
            "durable host count exceeds configured limit");
        auto next = db.scalar("SELECT next_order FROM frontier_meta WHERE id=1");
        need(db.scalar(`SELECT count(*) FROM frontier_candidate WHERE
            queue_order IS NOT NULL AND queue_order>=` ~ next.to!string) == 0,
            "pending order reaches durable high-water mark");
        need(counts.deferred == 0 || counts.queued == limits_.maxQueued,
            "deferred work exists without a full ready queue");
        need(db.scalar(`SELECT count(*) FROM (SELECT
            max(CASE WHEN state IN (0,4) THEN queue_order END) AS ready_order,
            min(CASE WHEN state=1 THEN queue_order END) AS deferred_order
            FROM frontier_candidate)
            WHERE ready_order>=deferred_order`) == 0,
            "ready and deferred FIFO order is unreachable");
    }

public:
    override FrontierBackendDescriptor descriptor() const { return sqliteDescriptor; }
    override FrontierLimits limits() const { return limits_; }

    override bool isSealed() const {
        live(); return db.scalar("SELECT sealed FROM frontier_meta WHERE id=1") != 0;
    }
    override bool isCanceled() const {
        live(); return db.scalar("SELECT canceled FROM frontier_meta WHERE id=1") != 0;
    }
    override bool isComplete() const {
        live();
        return isSealed && countWhere("state IN (0,1,2,4)") == 0;
    }

    override Admission admit(CandidateInput candidate) {
        Admission result;
        transaction({ result = admitInside(candidate); });
        return result;
    }

    override void seal() { transaction({ db.exec("UPDATE frontier_meta SET sealed=1 WHERE id=1"); }); }
    override void cancelLeasing() { transaction({ db.exec("UPDATE frontier_meta SET canceled=1 WHERE id=1"); }); }
    override void resumeLeasing() { transaction({ db.exec("UPDATE frontier_meta SET canceled=0 WHERE id=1"); }); }

    override FrontierCounts counts() const {
        live();
        auto statement = db.prepare(`SELECT count(*),
            coalesce(sum(state IN (0,4)),0),coalesce(sum(state=1),0),
            coalesce(sum(state=2),0),coalesce(sum(state=3),0),
            coalesce(sum(state=4),0),coalesce(sum(state=5),0),
            coalesce(sum(stored_bytes),0) FROM frontier_candidate`);
        scope(exit) sqlite3_finalize(statement);
        need(sqlite3_step(statement) == SQLITE_ROW, "counter read failed");
        FrontierCounts result;
        result.pages = checkedSize(sqlite3_column_int64(statement, 0), "page count");
        result.queued = checkedSize(sqlite3_column_int64(statement, 1), "queue count");
        result.deferred = checkedSize(sqlite3_column_int64(statement, 2), "deferred count");
        result.activeLeases = checkedSize(sqlite3_column_int64(statement, 3), "active count");
        result.completed = checkedSize(sqlite3_column_int64(statement, 4), "completed count");
        result.retryableFailed = checkedSize(sqlite3_column_int64(statement, 5), "retry count");
        result.permanentFailed = checkedSize(sqlite3_column_int64(statement, 6), "poison count");
        result.storedBytes = checkedSize(sqlite3_column_int64(statement, 7),
            "stored-byte count");
        return result;
    }

    override FrontierSnapshot snapshot(size_t maximumItems) const {
        live();
        auto mutableDb = cast(Database)db;
        mutableDb.exec("BEGIN");
        try {
            auto required = counts.pages;
            if (required > maximumItems) {
                mutableDb.exec("COMMIT");
                return FrontierSnapshot(SnapshotCode.itemLimit, required, null);
            }
            CandidateView[] candidates;
            candidates.reserve(required);
            auto statement = db.prepare(`SELECT policy_id,canonical_locator,host_key,depth,
                provenance,state,generation FROM frontier_candidate
                ORDER BY policy_id,canonical_locator LIMIT ?1`);
            scope(exit) if (statement !is null) sqlite3_finalize(statement);
            bindLong(statement, 1, checkedLong(maximumItems, "snapshot limit"));
            int rc;
            while ((rc = sqlite3_step(statement)) == SQLITE_ROW) {
                candidates ~= CandidateView(CandidateInput(columnText(statement, 0),
                    columnText(statement, 1), columnText(statement, 2),
                    checkedSize(sqlite3_column_int64(statement, 3), "candidate depth"),
                    columnText(statement, 4)),
                    cast(CandidateState)sqlite3_column_int64(statement, 5),
                    contractGeneration(sqlite3_column_int64(statement, 6)));
            }
            sqlite3_finalize(statement);
            statement = null;
            need(rc == SQLITE_DONE && candidates.length == required,
                "bounded snapshot changed during read");
            mutableDb.exec("COMMIT");
            return FrontierSnapshot(SnapshotCode.captured, required, candidates);
        } catch (Throwable failure) {
            try mutableDb.exec("ROLLBACK"); catch (Throwable ignored) {}
            throw failure;
        }
    }

    override bool lookup(CandidateKey key, out CandidateView result) const {
        live(); return readCandidate(key, result);
    }

    override LeaseAttempt takeLease() {
        LeaseAttempt result;
        transaction({
            if (db.scalar("SELECT canceled FROM frontier_meta WHERE id=1") != 0) {
                result.unavailable = LeaseUnavailable.canceled;
                return;
            }
            if (countWhere("state=2") >= checkedLong(limits_.maxActiveLeases, "active limit")) {
                result.unavailable = LeaseUnavailable.activeLimit;
                return;
            }
            auto statement = db.prepare(`SELECT policy_id,canonical_locator,host_key,
                depth,provenance,generation FROM frontier_candidate
                WHERE state IN (0,4) ORDER BY queue_order LIMIT 1`);
            auto rc = sqlite3_step(statement);
            if (rc == SQLITE_DONE) {
                sqlite3_finalize(statement);
                result.unavailable = LeaseUnavailable.noQueuedWork;
                return;
            }
            need(rc == SQLITE_ROW, "lease read failed");
            auto key = CandidateKey(columnText(statement, 0), columnText(statement, 1));
            auto candidate = CandidateInput(key.policyId.idup, key.canonicalLocator.idup,
                columnText(statement, 2), checkedSize(sqlite3_column_int64(statement, 3),
                "candidate depth"), columnText(statement, 4));
            auto generation = contractGeneration(sqlite3_column_int64(statement, 5));
            sqlite3_finalize(statement);
            if (generation == ulong.max) {
                result.unavailable = LeaseUnavailable.generationExhausted;
                return;
            }
            auto nextGeneration = generation + 1;
            auto update = db.prepare(`UPDATE frontier_candidate SET state=2,
                generation=?3,queue_order=NULL WHERE policy_id=?1 AND
                canonical_locator=?2 AND state IN (0,4)`);
            scope(exit) sqlite3_finalize(update);
            bindKey(update, key);
            bindLong(update, 3, storedGeneration(nextGeneration));
            done(update);
            need(sqlite3_changes(db.handle) == 1, "lease ownership changed");
            promote();
            result.available = true;
            result.unavailable = LeaseUnavailable.none;
            result.lease = LeaseToken(key, nextGeneration);
            result.candidate = candidate;
        });
        return result;
    }

    override FinishResult finish(LeaseToken lease, LeaseOutcome outcome,
            const(CandidateInput)[] discoveries = null) {
        FinishResult result;
        transaction({
            CandidateView producer;
            if (!readCandidate(lease.key, producer)) {
                result.code = FinishCode.unknownCandidate;
                return;
            }
            if (producer.generation != lease.generation) {
                result.code = FinishCode.staleGeneration;
                return;
            }
            if (producer.state != CandidateState.leased) {
                result.code = FinishCode.notLeased;
                return;
            }
            if (discoveries.length > limits_.maxDiscoveriesPerFinish) {
                result.code = FinishCode.discoveryCountLimit;
                return;
            }
            size_t discoveryBytes;
            foreach (discovery; discoveries) {
                bool valid;
                auto bytes = inputBytes(discovery, valid);
                if (!valid || bytes > limits_.maxDiscoveryInputBytes - discoveryBytes) {
                    result.code = FinishCode.discoveryInputByteLimit;
                    return;
                }
                discoveryBytes += bytes;
            }
            need(cast(uint)outcome <= cast(uint)LeaseOutcome.permanentFailure,
                "invalid lease outcome");
            final switch (outcome) {
            case LeaseOutcome.completed:
            case LeaseOutcome.permanentFailure:
                auto terminal = outcome == LeaseOutcome.completed ?
                    CandidateState.completed : CandidateState.permanentFailed;
                auto update = db.prepare(`UPDATE frontier_candidate SET state=?3,
                    deferred_retry=0,queue_order=NULL WHERE policy_id=?1 AND
                    canonical_locator=?2 AND state=2 AND generation=?4`);
                bindKey(update, lease.key);
                bindLong(update, 3, cast(long)terminal);
                bindLong(update, 4, storedGeneration(lease.generation));
                done(update);
                need(sqlite3_changes(db.handle) == 1, "lease completion changed");
                sqlite3_finalize(update);
                break;
            case LeaseOutcome.retryableFailure:
                setPending(lease.key, true);
                break;
            }
            foreach (discovery; discoveries)
                result.discoveries ~= admitInside(discovery);
            promote();
            result.code = FinishCode.applied;
        });
        return result;
    }

    override ReclaimCode reclaim(LeaseToken lease) {
        ReclaimCode result;
        transaction({
            CandidateView candidate;
            if (!readCandidate(lease.key, candidate)) {
                result = ReclaimCode.unknownCandidate;
                return;
            }
            if (candidate.generation != lease.generation) {
                result = ReclaimCode.staleGeneration;
                return;
            }
            if (candidate.state != CandidateState.leased) {
                result = ReclaimCode.notLeased;
                return;
            }
            need(lease.generation != ulong.max, "lease generation exhausted");
            auto invalidate = db.prepare(`UPDATE frontier_candidate SET generation=?4
                WHERE policy_id=?1 AND canonical_locator=?2 AND state=2 AND generation=?3`);
            bindKey(invalidate, lease.key);
            bindLong(invalidate, 3, storedGeneration(lease.generation));
            bindLong(invalidate, 4, storedGeneration(lease.generation + 1));
            done(invalidate);
            need(sqlite3_changes(db.handle) == 1, "lease reclaim changed");
            sqlite3_finalize(invalidate);
            setPending(lease.key, false);
            promote();
            result = ReclaimCode.reclaimed;
        });
        return result;
    }

    /// Bounded maintenance: TRUNCATE checkpoints at most the configured
    /// auto-checkpoint window because every writer uses the same cap.
    void checkpoint() {
        live();
        fault("before-checkpoint");
        int logFrames, checkpointed;
        need(sqlite3_wal_checkpoint_v2(db.handle, "main".toStringz,
            SQLITE_CHECKPOINT_TRUNCATE, &logFrames, &checkpointed) == SQLITE_OK,
            "checkpoint busy or failed");
        need(logFrames == 0 && checkpointed == 0, "checkpoint did not truncate WAL");
        fault("after-checkpoint");
    }

    SQLiteFrontierResources resourceMetrics() const {
        live();
        size_t statements;
        sqlite3_stmt* cursor;
        while ((cursor = sqlite3_next_stmt(cast(sqlite3*)db.handle, cursor)) !is null)
            ++statements;
        return SQLiteFrontierResources(
            checkedSize(db.scalar("PRAGMA page_count"), "page count"),
            checkedSize(db.scalar("PRAGMA page_size"), "page size"),
            checkedSize(-db.scalar("PRAGMA cache_size"), "cache size"),
            checkedSize(db.scalar("PRAGMA wal_autocheckpoint"), "auto checkpoint"),
            statements,
            sqlite3_get_autocommit(cast(sqlite3*)db.handle) != 0);
    }

    void close() {
        if (db !is null) db.close();
        db = null;
    }
}
