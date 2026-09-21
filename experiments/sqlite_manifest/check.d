module sqlite_manifest.check;

// Evidence-only FFI. The matching upstream sqlite3.c is compiled into this
// executable by the commands in README.md; no system SQLite is linked.
import content.pieces : Content, ContentPiece;
import effects.atomic_piece_sink : writeAtomicPieces;
import core.memory : GC;
import core.stdc.stdlib : _Exit;
import std.conv : to;
import std.algorithm.searching : canFind;
import std.file : exists, mkdir, readText, rmdirRecurse, tempDir;
import std.path : buildPath;
import std.process : execute;
import std.stdio : writeln;
import std.string : fromStringz, toStringz;
import std.uuid : randomUUID;

extern(C) {
    struct sqlite3;
    struct sqlite3_stmt;
    int sqlite3_open_v2(const(char)*, sqlite3**, int, const(char)*);
    int sqlite3_close(sqlite3*);
    int sqlite3_exec(sqlite3*, const(char)*, void*, void*, char**);
    int sqlite3_busy_timeout(sqlite3*, int);
    const(char)* sqlite3_errmsg(sqlite3*);
    int sqlite3_prepare_v2(sqlite3*, const(char)*, int, sqlite3_stmt**, const(char)**);
    int sqlite3_bind_text(sqlite3_stmt*, int, const(char)*, int, void*);
    int sqlite3_step(sqlite3_stmt*);
    int sqlite3_finalize(sqlite3_stmt*);
    const(ubyte)* sqlite3_column_text(sqlite3_stmt*, int);
    int sqlite3_column_int(sqlite3_stmt*, int);
    int sqlite3_wal_checkpoint_v2(sqlite3*, const(char)*, int, int*, int*);
    const(char)* sqlite3_libversion();
}

enum SQLITE_OK = 0, SQLITE_ROW = 100, SQLITE_DONE = 101;
enum schema = `
    PRAGMA journal_mode=WAL;
    BEGIN IMMEDIATE;
    CREATE TABLE IF NOT EXISTS manifest (
      document_id TEXT NOT NULL, input_digest TEXT NOT NULL,
      config_digest TEXT NOT NULL, sink_key TEXT NOT NULL,
      state TEXT NOT NULL CHECK(state IN ('planned','committed','failed','uncertain')),
      PRIMARY KEY(document_id,input_digest,config_digest,sink_key)
    ) WITHOUT ROWID;
    CREATE INDEX IF NOT EXISTS manifest_replay ON manifest(state,document_id,input_digest,config_digest,sink_key);
    PRAGMA user_version=1;
    COMMIT;
`;

void require(bool yes, string why) { if (!yes) throw new Exception(why); }

struct Db {
    sqlite3* raw;
    this(string path) {
        auto rc = sqlite3_open_v2(path.toStringz, &raw, 2 | 4, null);
        require(rc == SQLITE_OK, "sqlite open: " ~ error);
        require(sqlite3_busy_timeout(raw, 2000) == SQLITE_OK, "busy timeout");
        // synchronous is connection-local; every writer, including crash children,
        // must set it rather than relying on the creator connection's PRAGMA.
        exec("PRAGMA synchronous=FULL");
    }
    ~this() { if (raw !is null) require(sqlite3_close(raw) == SQLITE_OK, "sqlite close"); }
    @property string error() { return raw is null ? "no handle" : sqlite3_errmsg(raw).fromStringz.idup; }
    void exec(string sql) {
        auto rc = sqlite3_exec(raw, sql.toStringz, null, null, null);
        require(rc == SQLITE_OK, "sqlite exec: " ~ error ~ " SQL=" ~ sql);
    }
    void init() {
        auto schemaVersion = scalar("PRAGMA user_version");
        if (schemaVersion == "0") exec(schema);
        else require(schemaVersion == "1", "unsupported manifest schema version " ~ schemaVersion);
    }
    string scalar(string sql) {
        auto statement = prepare(sql);
        scope(exit) sqlite3_finalize(statement);
        require(sqlite3_step(statement) == SQLITE_ROW, "sqlite scalar: " ~ error);
        auto value = cast(const(char)*) sqlite3_column_text(statement, 0);
        require(value !is null, "sqlite scalar null");
        return value.fromStringz.idup;
    }
    string plan(string sql) {
        auto statement = prepare("EXPLAIN QUERY PLAN " ~ sql);
        scope(exit) sqlite3_finalize(statement);
        require(sqlite3_step(statement) == SQLITE_ROW, "explain query plan");
        auto detail = cast(const(char)*) sqlite3_column_text(statement, 3);
        return detail.fromStringz.idup;
    }
    sqlite3_stmt* prepare(string sql) {
        sqlite3_stmt* statement;
        require(sqlite3_prepare_v2(raw, sql.toStringz, -1, &statement, null) == SQLITE_OK,
            "sqlite prepare: " ~ error);
        return statement;
    }
    void bind(sqlite3_stmt* statement, string[] fields) {
        foreach (i, field; fields)
            require(sqlite3_bind_text(statement, cast(int)i + 1, field.toStringz,
                cast(int)field.length, cast(void*) -1) == SQLITE_OK, "sqlite bind: " ~ error);
    }
    void set(string documentId, string input, string config, string sink, string state) {
        auto statement = prepare(`
            INSERT INTO manifest VALUES (?1,?2,?3,?4,?5)
            ON CONFLICT(document_id,input_digest,config_digest,sink_key)
            DO UPDATE SET state=excluded.state
        `);
        scope(exit) sqlite3_finalize(statement);
        bind(statement, [documentId, input, config, sink, state]);
        require(sqlite3_step(statement) == SQLITE_DONE, "sqlite upsert: " ~ error);
    }
    string get(string documentId, string input, string config, string sink) {
        auto statement = prepare(`
            SELECT state FROM manifest WHERE document_id=?1 AND input_digest=?2
              AND config_digest=?3 AND sink_key=?4
        `);
        scope(exit) sqlite3_finalize(statement);
        bind(statement, [documentId, input, config, sink]);
        auto rc = sqlite3_step(statement);
        if (rc == SQLITE_DONE) return "absent";
        require(rc == SQLITE_ROW, "sqlite lookup: " ~ error);
        auto result = cast(const(char)*) sqlite3_column_text(statement, 0);
        return result.fromStringz.idup;
    }
    int replayCount() {
        auto statement = prepare(`
            SELECT state FROM manifest WHERE state IN ('planned','failed','uncertain')
            ORDER BY state,document_id,input_digest,config_digest,sink_key LIMIT 16
        `);
        scope(exit) sqlite3_finalize(statement);
        int count;
        int rc;
        while ((rc = sqlite3_step(statement)) == SQLITE_ROW) ++count;
        require(rc == SQLITE_DONE && count <= 16, "bounded replay");
        return count;
    }
    void checkpoint() {
        int logFrames, checkpointed;
        require(sqlite3_wal_checkpoint_v2(raw, null, 3, &logFrames, &checkpointed) == SQLITE_OK,
            "truncate checkpoint: " ~ error);
        require(logFrames == checkpointed, "checkpoint left frames");
    }
}

void publish(string destination, string bytes) {
    auto content = new Content([ContentPiece.own(cast(const(ubyte)[]) bytes)]);
    writeAtomicPieces(destination, content.pieces());
}

void child(string dbPath, string destination, string phase) {
    auto db = Db(dbPath);
    if (phase == "before_publish") _Exit(77);
    publish(destination, "output-v1");
    if (phase == "after_publish") _Exit(77);
    db.exec("BEGIN IMMEDIATE");
    db.set("doc-A", "input-A", "config-A", "sink-A", "committed");
    if (phase == "before_db_commit") _Exit(77);
    require(phase == "after_db_commit", "unknown phase");
    db.exec("COMMIT");
    _Exit(77);
}

void checkCrash(string executable, string root, string phase, string expected) {
    auto directory = buildPath(root, phase);
    mkdir(directory);
    auto dbPath = buildPath(directory, "manifest.db");
    auto destination = buildPath(directory, "sink-A");
    {
        auto db = Db(dbPath);
        db.init();
        db.set("doc-A", "input-A", "config-A", "sink-A", "planned");
    }
    auto result = execute([executable, "--child", dbPath, destination, phase]);
    require(result.status == 77, "child did not interrupt at " ~ phase ~ ": " ~ result.output);
    auto db = Db(dbPath);
    require(db.get("doc-A", "input-A", "config-A", "sink-A") == expected,
        "durable state mismatch after " ~ phase);
    if (phase == "before_publish") require(!exists(destination), "premature sink");
    else require(exists(destination) && readText(destination) == "output-v1", "sink publish");
    if (expected == "planned" && exists(destination)) {
        // A published sink cannot be re-labelled committed from the old DB row.
        // It must first enter a state that forces digest/state reconciliation.
        db.set("doc-A", "input-A", "config-A", "sink-A", "uncertain");
        require(db.get("doc-A", "input-A", "config-A", "sink-A") == "uncertain",
            "published/no DB commit must be uncertain");
    }
    db.checkpoint();
    writeln(phase, ": state=", expected,
        expected == "planned" && exists(destination) ? " -> uncertain" : "");
}

void checkMatrix(string root) {
    auto dbPath = buildPath(root, "matrix.db");
    auto db = Db(dbPath);
    db.init();
    require(sqlite3_libversion().fromStringz == "3.53.4", "wrong SQLite source");
    require(db.scalar("PRAGMA journal_mode") == "wal", "WAL not active");
    require(db.scalar("PRAGMA synchronous") == "2", "synchronous FULL not active");
    require(db.scalar("PRAGMA user_version") == "1", "schema version mismatch");
    require(db.scalar("SELECT name FROM sqlite_master WHERE type='index' AND name='manifest_replay'")
        == "manifest_replay", "replay index absent");
    require(db.plan("SELECT state FROM manifest WHERE document_id='a' AND input_digest='b' " ~
        "AND config_digest='c' AND sink_key='d'").canFind("PRIMARY KEY"),
        "exact lookup did not use primary key");
    require(db.plan("SELECT state FROM manifest WHERE state IN ('planned','failed','uncertain') " ~
        "ORDER BY state,document_id,input_digest,config_digest,sink_key LIMIT 16")
        .canFind("manifest_replay"), "replay did not use state index");
    db.exec("BEGIN IMMEDIATE");
    {
        auto competitor = Db(dbPath);
        require(sqlite3_busy_timeout(competitor.raw, 10) == SQLITE_OK, "competitor timeout");
        bool blocked;
        try competitor.exec("BEGIN IMMEDIATE");
        catch (Exception) blocked = true;
        require(blocked, "second writer was not excluded");
    }
    db.exec("ROLLBACK");
    bool badStateRejected;
    try db.set("doc-A", "input-A", "config-A", "sink-X", "completed");
    catch (Exception) badStateRejected = true;
    require(badStateRejected, "invalid manifest state accepted in release mode");
    db.set("doc-A", "input-A", "config-A", "sink-A", "committed");
    db.set("doc-A", "input-A", "config-A", "sink-B", "failed");
    require(db.get("doc-A", "input-A", "config-A", "sink-A") == "committed",
        "unchanged input/config and committed sink skips");
    require(db.get("doc-A", "input-A", "config-A", "sink-B") == "failed",
        "failed sink retries independently");
    require(db.get("doc-A", "input-B", "config-A", "sink-A") == "absent",
        "changed input must not reuse commit");
    require(db.get("doc-A", "input-A", "config-B", "sink-A") == "absent",
        "changed config must not reuse commit");
    require(db.get("doc-B", "input-A", "config-A", "sink-A") == "absent",
        "DocumentId separates equal digests");
    auto before = GC.stats().usedSize;
    foreach (i; 0 .. 10_000)
        db.set("doc-" ~ i.to!string, "input-A", "config-A", "sink-A", "failed");
    auto after = GC.stats().usedSize;
    require(db.replayCount() == 16, "replay limit");
    require(db.get("doc-9999", "input-A", "config-A", "sink-A") == "failed",
        "indexed lookup at scale");
    db.checkpoint();
    db.exec("PRAGMA user_version=2");
    bool futureVersionRejected;
    try db.init();
    catch (Exception) futureVersionRejected = true;
    require(futureVersionRejected, "unknown future schema version accepted");
    writeln("rows=10002 replay_limit=16 gc_used_before=", before,
        " gc_used_after=", after, " gc_delta=", after - before);
}

void main(string[] args) {
    if (args.length == 5 && args[1] == "--child") child(args[2], args[3], args[4]);
    require(args.length == 1, "usage: check");
    auto root = buildPath(tempDir(), "sqlite-manifest-" ~ randomUUID().toString());
    mkdir(root);
    scope(exit) rmdirRecurse(root);
    checkMatrix(root);
    checkCrash(args[0], root, "before_publish", "planned");
    checkCrash(args[0], root, "after_publish", "planned");
    checkCrash(args[0], root, "before_db_commit", "planned");
    checkCrash(args[0], root, "after_db_commit", "committed");
    writeln("sqlite manifest evidence PASS");
}
