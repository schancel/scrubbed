/// Read-only, bounded v2 journal materialization. SQLite remains authoritative.
module effects.error_export;

import effects.sqlite_ffi;
import effects.failure_journal : validateV2ReadSnapshot;
import effects.durable_job : validateV3ReadSnapshot;
import effects.local_manifest : resolvedName, safeRegularOrAbsent, sameInode;
import std.conv : to;
import std.algorithm.searching : canFind;
import std.digest : LetterCase, toHexString;
import std.digest.sha : SHA256;
import std.file : exists, remove;
import std.json : parseJSON;
import std.string : fromStringz, toStringz;
import std.uuid : UUID;
import core.sys.posix.fcntl : open, O_RDONLY, O_WRONLY, O_CREAT, O_EXCL, O_NOFOLLOW;
import core.sys.posix.sys.stat : fstat, stat_t, S_ISREG;
import core.sys.posix.unistd : read, write, close, fsync;

private enum recordLimit = 4096;
private enum sidecarLimit = 256;
private enum byteLimit = 1_073_741_824L;
private enum rowLimit = 2_000_000L;
private enum publicPrefixGroupLimit = 4096L;
private extern(C) void arc4random_buf(void*, size_t);
private extern(C) int rename(const(char)*, const(char)*);

private void need(bool okay, string token) {
    if (!okay) throw new Exception("error export: " ~ token);
}
private string uuid() {
    ubyte[16] bytes;
    arc4random_buf(bytes.ptr, bytes.length);
    bytes[6] = cast(ubyte)((bytes[6] & 15) | 64);
    bytes[8] = cast(ubyte)((bytes[8] & 63) | 128);
    return UUID(bytes).toString;
}
private bool uuid4(string s) {
    if (s.length != 36 || s[8] != '-' || s[13] != '-' || s[18] != '-' ||
        s[23] != '-' || s[14] != '4' || !("89ab".canFind(s[19]))) return false;
    foreach (i, c; s) {
        if (i == 8 || i == 13 || i == 18 || i == 23) continue;
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
    }
    return true;
}
private bool hex64(string s) {
    if (s.length != 64) return false;
    foreach (c; s) if (!((c >= '0' && c <= '9') ||
        (c >= 'a' && c <= 'f'))) return false;
    return true;
}
private string hexColumn(sqlite3_stmt* s, int n) {
    need(sqlite3_column_type(s, n) != SQLITE_NULL &&
        sqlite3_column_bytes(s, n) == 32, "invalid-digest");
    auto b = (cast(const(ubyte)*)sqlite3_column_blob(s, n))[0 .. 32];
    return toHexString!(LetterCase.lower)(b).idup;
}
private string textColumn(sqlite3_stmt* s, int n) {
    need(sqlite3_column_type(s, n) != SQLITE_NULL, "invalid-text");
    auto count = sqlite3_column_bytes(s, n);
    need(count >= 0 && count <= recordLimit, "record-limit");
    auto p = sqlite3_column_text(s, n);
    need(p !is null, "invalid-text");
    auto v = p[0 .. count].idup;
    foreach (c; v) need(c >= 32 && c <= 126, "invalid-text");
    return v;
}
private string nullableText(sqlite3_stmt* s, int n) {
    return sqlite3_column_type(s, n) == SQLITE_NULL ? "null" :
        `"` ~ textColumn(s, n) ~ `"`;
}
private bool documentId(string s) {
    return (s.length == 71 && s[0 .. 7] == "doc:v1:" && hex64(s[7 .. $])) ||
        (s.length == 73 && s[0 .. 9] == "child:v1:" && hex64(s[9 .. $]));
}
private string historyLine(sqlite3_stmt* s) {
    auto eventId = textColumn(s, 0);
    auto sequence = sqlite3_column_int64(s, 1);
    auto runId = textColumn(s, 2);
    auto doc = textColumn(s, 4);
    auto sink = textColumn(s, 7);
    auto phase = textColumn(s, 8);
    auto code = textColumn(s, 9);
    auto state = textColumn(s, 10);
    auto retry = nullableText(s, 11);
    auto at = sqlite3_column_int64(s, 12);
    need(uuid4(eventId) && sequence > 0 && uuid4(runId) && documentId(doc) &&
        uuid4(sink) && at >= 0, "invalid-event");
    need((phase == "read" && code == "read-failed") ||
        (phase == "decode" && code == "decode-failed") ||
        (phase == "filter" && code == "filter-failed") ||
        (phase == "sink" && (code == "sink-write-failed" || code == "sink-publication-interrupted")) ||
        (phase == "manifest" && code == "manifest-failed") ||
        (phase == "policy" && code == "policy-failed") ||
        (phase == "resource" && code == "resource-failed") ||
        (phase == "scheduler" && code == "scheduler-failed") ||
        (phase == "log" && code == "log-failed") ||
        (phase == "inspect" && code == "inspect-invalidated") ||
        (phase == "retry" && code == "retry-succeeded"), "invalid-event");
    need(state == "failed" || state == "uncertain" || state == "committed", "invalid-event");
    if (retry != "null") need(uuid4(textColumn(s, 11)), "invalid-event");
    return `{"schema":"scrubbed.error-event.v1","event_id":"` ~ eventId ~
        `","sequence":` ~ to!string(sequence) ~ `,"run_id":"` ~ runId ~
        `","config_sha256":"` ~ hexColumn(s, 6) ~ `","document_id":"` ~ doc ~
        `","input_sha256":"` ~ hexColumn(s, 5) ~ `","sink_id":"` ~ sink ~
        `","phase":"` ~ phase ~ `","code":"` ~ code ~ `","state":"` ~
        state ~ `","retry_of":` ~ retry ~ `,"time_utc_ms":` ~ to!string(at) ~ "}\n";
}
private string outstandingLine(sqlite3_stmt* s) {
    auto doc = textColumn(s, 0);
    auto sink = textColumn(s, 3);
    auto state = textColumn(s, 4);
    auto origin = textColumn(s, 5);
    auto eventId = nullableText(s, 6);
    auto runId = nullableText(s, 7);
    auto at = sqlite3_column_type(s, 8) == SQLITE_NULL ? "null" :
        to!string(sqlite3_column_int64(s, 8));
    need(documentId(doc) && uuid4(sink) &&
        (state == "failed" || state == "uncertain"), "invalid-outstanding");
    need((origin == "legacy-v1" && eventId == "null" && runId == "null" && at == "null") ||
        (origin == "event" && eventId != "null" && runId != "null" && at != "null" &&
         uuid4(textColumn(s, 6)) && uuid4(textColumn(s, 7)) &&
         sqlite3_column_int64(s, 8) >= 0), "invalid-outstanding");
    return `{"schema":"scrubbed.outstanding.v1","document_id":"` ~ doc ~
        `","input_sha256":"` ~ hexColumn(s, 1) ~ `","config_sha256":"` ~
        hexColumn(s, 2) ~ `","sink_id":"` ~ sink ~ `","state":"` ~ state ~
        `","origin":"` ~ origin ~ `","event_id":` ~ eventId ~
        `,"run_id":` ~ runId ~ `,"time_utc_ms":` ~ at ~ "}\n";
}
private enum historySql = `SELECT event_id,sequence,run_id,0,document_id,input_sha256,
    config_sha256,sink_id,phase,code,state,retry_of,time_utc_ms
    FROM error_event ORDER BY sequence`;
private enum outstandingSql = `SELECT document_id,input_sha256,config_sha256,sink_id,
    state,origin,event_id,run_id,time_utc_ms FROM outstanding
    ORDER BY document_id,input_sha256,config_sha256,sink_id`;

private void validateReadSnapshot(sqlite3* db) {
    sqlite3_stmt* versionStatement;
    need(sqlite3_prepare_v2(db, "PRAGMA user_version".toStringz,
        -1, &versionStatement, null) == SQLITE_OK, "prepare-failed");
    scope(exit) sqlite3_finalize(versionStatement);
    need(sqlite3_step(versionStatement) == SQLITE_ROW, "read-failed");
    auto value = sqlite3_column_int64(versionStatement, 0);
    if (value == 2) validateV2ReadSnapshot(db);
    else if (value == 3) validateV3ReadSnapshot(db);
    else need(false, "incompatible-version");
}

private void preflightOutstandingSort(sqlite3* db) {
    // The v2 PK ends in private sink_key. SQLite sorts sink_id within each
    // public three-field prefix. Refuse an oversized group before preparing
    // the ORDER BY cursor, so its temporary B-tree remains bounded.
    version (FailurePolicyHarness) enum groupCap = 8L;
    else enum groupCap = publicPrefixGroupLimit;
    sqlite3_stmt* count;
    need(sqlite3_prepare_v2(db, "SELECT count(*) FROM outstanding".toStringz,
        -1, &count, null) == SQLITE_OK, "prepare-failed");
    scope(exit) sqlite3_finalize(count);
    need(sqlite3_step(count) == SQLITE_ROW &&
        sqlite3_column_int64(count, 0) <= rowLimit, "row-limit");
    sqlite3_stmt* groups;
    auto sql = `SELECT count(*) FROM outstanding GROUP BY
        document_id,input_sha256,config_sha256 HAVING count(*) > ` ~
        to!string(groupCap) ~ ` LIMIT 1`;
    need(sqlite3_prepare_v2(db, sql.toStringz, -1, &groups, null) == SQLITE_OK,
        "prepare-failed");
    scope(exit) sqlite3_finalize(groups);
    need(sqlite3_step(groups) == SQLITE_DONE, "public-prefix-group-limit");
}

private void writeAll(int fd, const(ubyte)[] bytes) {
    while (bytes.length) {
        auto n = write(fd, bytes.ptr, bytes.length);
        need(n > 0, "write-failed");
        bytes = bytes[n .. $];
    }
}
private int stableOpen(string path) {
    auto fd = open(path.toStringz, O_RDONLY | O_NOFOLLOW);
    need(fd >= 0, "missing-or-unsafe-file");
    stat_t st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_nlink != 1) {
        close(fd);
        throw new Exception("error export: unsafe-file");
    }
    return fd;
}
private string sidecar(string kind, string sha, long bytes, string id) {
    return `{"schema":"scrubbed.error-export-digest.v1","kind":"` ~ kind ~
        `","sha256":"` ~ sha ~ `","bytes":` ~ to!string(bytes) ~
        `,"snapshot_id":"` ~ id ~ `"}` ~ "\n";
}
private string digest(SHA256* hash) {
    return toHexString!(LetterCase.lower)(hash.finish()).idup;
}
private void fault(string dbPath, string point) {
    version (FailurePolicyHarness) {
        if (exists(dbPath ~ ".fault-export-kill-" ~ point)) {
            import core.sys.posix.unistd : _exit;
            _exit(73);
        }
        need(!exists(dbPath ~ ".fault-export-" ~ point), "injected-" ~ point);
    }
}
private struct Stage {
    string target, temporary, sideTarget, sideTemporary, kind;
    bool published, sidePublished;
}
private void preflight(string dbPath, string inputPath, ref Stage[] stages) {
    string[] paths = [dbPath, dbPath ~ "-wal", dbPath ~ "-shm"];
    if (inputPath.length) paths ~= resolvedName(inputPath);
    foreach (ref stage; stages) {
        stage.target = resolvedName(stage.target);
        stage.sideTarget = stage.target ~ ".sha256";
        paths ~= [stage.target, stage.sideTarget];
    }
    foreach (i, path; paths) {
        safeRegularOrAbsent(path);
        if (exists(path)) {
            auto fd = stableOpen(path);
            close(fd);
        }
        foreach (other; paths[0 .. i])
            need(path != other && !sameInode(path, other), "destination-alias");
    }
}
private void stageRows(sqlite3* db, ref Stage stage, string id, string dbPath) {
    if (stage.kind == "outstanding") preflightOutstandingSort(db);
    auto sql = stage.kind == "history" ? historySql : outstandingSql;
    sqlite3_stmt* cursor;
    need(sqlite3_prepare_v2(db, sql.toStringz, -1, &cursor, null) == SQLITE_OK,
        "prepare-failed");
    scope(exit) sqlite3_finalize(cursor);
    stage.temporary = stage.target ~ ".stage-" ~ uuid();
    auto fd = open(stage.temporary.toStringz, O_WRONLY | O_CREAT | O_EXCL, 384);
    need(fd >= 0, "stage-create-failed");
    scope(exit) close(fd);
    SHA256 hash;
    long bytes, rows;
    int rc;
    while ((rc = sqlite3_step(cursor)) == SQLITE_ROW) {
        need(++rows <= rowLimit, "row-limit");
        auto line = stage.kind == "history" ? historyLine(cursor) : outstandingLine(cursor);
        need(line.length <= recordLimit && bytes + line.length <= byteLimit,
            "byte-limit");
        auto chunk = cast(const(ubyte)[])line;
        writeAll(fd, chunk);
        hash.put(chunk);
        bytes += line.length;
        fault(dbPath, "write");
        fault(dbPath, stage.kind ~ "-write");
    }
    need(rc == SQLITE_DONE, "read-failed");
    need(fsync(fd) == 0, "sync-failed");
    fault(dbPath, "sync");
    fault(dbPath, stage.kind ~ "-sync");
    stage.sideTemporary = stage.sideTarget ~ ".stage-" ~ uuid();
    auto sf = open(stage.sideTemporary.toStringz, O_WRONLY | O_CREAT | O_EXCL, 384);
    need(sf >= 0, "stage-create-failed");
    scope(exit) close(sf);
    auto line = sidecar(stage.kind, digest(&hash), bytes, id);
    need(line.length <= sidecarLimit, "sidecar-limit");
    writeAll(sf, cast(const(ubyte)[])line);
    need(fsync(sf) == 0, "sync-failed");
    fault(dbPath, "side-sync");
    fault(dbPath, stage.kind ~ "-side-sync");
}

/// Empty destination means that export is not requested. Sidecars use .sha256.
/// The caller must serialize exports with other writers to the destination directory.
private void exportImpl(string database, string historyDestination,
    string outstandingDestination = "", string inputPath = "") {
    need(historyDestination.length || outstandingDestination.length, "no-destination");
    auto dbPath = resolvedName(database);
    Stage[] stages;
    if (historyDestination.length) stages ~= Stage(historyDestination, "", "", "", "history");
    if (outstandingDestination.length) stages ~= Stage(outstandingDestination, "", "", "", "outstanding");
    preflight(dbPath, inputPath, stages);
    sqlite3* db;
    need(sqlite3_open_v2(dbPath.toStringz, &db, SQLITE_OPEN_READONLY, null) == SQLITE_OK,
        "open-failed");
    scope(exit) sqlite3_close(db);
    scope(exit) foreach (ref stage; stages) {
        if (stage.temporary.length && exists(stage.temporary)) remove(stage.temporary);
        if (stage.sideTemporary.length && exists(stage.sideTemporary)) remove(stage.sideTemporary);
    }
    need(sqlite3_exec(db, "BEGIN", null, null, null) == SQLITE_OK, "snapshot-failed");
    validateReadSnapshot(db);
    auto id = uuid();
    foreach (ref stage; stages) stageRows(db, stage, id, dbPath);
    need(sqlite3_exec(db, "COMMIT", null, null, null) == SQLITE_OK, "snapshot-failed");
    foreach (ref stage; stages) {
        fault(dbPath, "before-json-rename");
        fault(dbPath, stage.kind ~ "-before-json-rename");
        need(rename(stage.temporary.toStringz, stage.target.toStringz) == 0,
            "publish-failed");
        stage.published = true;
        fault(dbPath, "after-json-rename");
        fault(dbPath, stage.kind ~ "-after-json-rename");
        need(rename(stage.sideTemporary.toStringz, stage.sideTarget.toStringz) == 0,
            "publish-failed");
        stage.sidePublished = true;
        fault(dbPath, "after-side-rename");
        fault(dbPath, stage.kind ~ "-after-side-rename");
    }
}

void exportV2(string database, string historyDestination = "",
    string outstandingDestination = "", string inputPath = "") {
    try exportImpl(database, historyDestination, outstandingDestination, inputPath);
    catch (Exception failure) {
        if (failure.msg == "failure journal: v2-sink-label-too-long")
            throw new Exception("error export: v2-sink-label-too-long");
        throw new Exception("error export: refused");
    }
}

private string verifyOne(string path, string kind) {
    auto data = resolvedName(path);
    auto side = data ~ ".sha256";
    need(data != side && !sameInode(data, side), "destination-alias");
    auto fd = stableOpen(data);
    scope(exit) close(fd);
    auto sf = stableOpen(side);
    scope(exit) close(sf);
    ubyte[sidecarLimit + 1] small;
    auto sn = read(sf, small.ptr, small.length);
    need(sn > 0 && sn <= sidecarLimit && read(sf, small.ptr, 1) == 0,
        "invalid-sidecar");
    auto raw = cast(string)small[0 .. sn].idup;
    string sha, id;
    long count;
    try {
        auto parsed = parseJSON(raw);
        need(parsed["schema"].str == "scrubbed.error-export-digest.v1" &&
            parsed["kind"].str == kind, "invalid-sidecar");
        sha = parsed["sha256"].str;
        id = parsed["snapshot_id"].str;
        count = parsed["bytes"].integer;
    } catch (Exception) { throw new Exception("error export: invalid-sidecar"); }
    need(hex64(sha) && uuid4(id) && count >= 0 && count <= byteLimit &&
        raw == sidecar(kind, sha, count, id), "invalid-sidecar");
    SHA256 hash;
    ubyte[65536] buffer;
    long total;
    while (true) {
        auto n = read(fd, buffer.ptr, buffer.length);
        need(n >= 0, "read-failed");
        if (n == 0) break;
        total += n;
        need(total <= byteLimit, "byte-limit");
        hash.put(buffer[0 .. n]);
    }
    need(total == count && digest(&hash) == sha, "digest-mismatch");
    return id;
}

/// Verify exact bytes on stable descriptors. For joint use, IDs must agree.
private void verifyImpl(string historyPath, string outstandingPath) {
    need(historyPath.length || outstandingPath.length, "no-destination");
    string first;
    if (historyPath.length) first = verifyOne(historyPath, "history");
    if (outstandingPath.length) {
        auto second = verifyOne(outstandingPath, "outstanding");
        if (historyPath.length) need(first == second, "snapshot-mismatch");
    }
}

void verifyV2Export(string historyPath = "", string outstandingPath = "") {
    try verifyImpl(historyPath, outstandingPath);
    catch (Exception) { throw new Exception("error export: verify-refused"); }
}
