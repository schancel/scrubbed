/// Release-active bounded v2 outstanding-target visitor proof.
module experiments.retry_targets.check;

import domain.document : DocumentId, SourceLocator;
import effects.failure_journal : FailureJournal, createV2;
import effects.local_manifest : LocalManifest, SinkKey, SinkState, inputDigest,
    configDigest, outputDigest;
import effects.sqlite_ffi;
import std.algorithm.searching : canFind;
import std.algorithm.sorting : sort;
import std.conv : to;
import std.digest.sha : sha256Of;
import std.file : SpanMode, dirEntries, exists, mkdir, read, rmdirRecurse,
    tempDir, write;
import std.path : buildPath;
import std.process : execute;
import std.string : split, strip, toStringz;
import std.uuid : randomUUID;
import core.sys.posix.sys.resource : getrusage, rusage, RUSAGE_SELF;

private void need(bool yes, string label) {
    if (!yes) throw new Exception("retry target check: " ~ label);
}
private void reject(void delegate() action, string token, string label) {
    bool refused;
    try action();
    catch (Exception error)
        refused = error.msg.canFind(token) &&
            !error.msg.canFind("PRIVATE_SINK_LABEL");
    need(refused, label);
}
private ulong rssBytes() {
    rusage usage;
    need(getrusage(RUSAGE_SELF, &usage) == 0, "RSS sample");
    version (OSX) return cast(ulong)usage.ru_opaque[0];
    else version (linux) return cast(ulong)usage.ru_maxrss * 1024;
    else static assert(0, "RSS observation requires platform support");
}
private size_t fdCount() {
    version (OSX) enum fdRoot = "/dev/fd";
    else version (linux) enum fdRoot = "/proc/self/fd";
    else static assert(0, "FD observation requires platform support");
    size_t count;
    foreach (_; dirEntries(fdRoot, SpanMode.shallow)) ++count;
    return count;
}
private void sql(string path, string statement) {
    sqlite3* handle;
    need(sqlite3_open_v2(path.toStringz, &handle, SQLITE_OPEN_READWRITE,
        null) == SQLITE_OK, "fixture SQLite open");
    scope(exit) need(sqlite3_close(handle) == SQLITE_OK, "fixture SQLite close");
    need(sqlite3_exec(handle, statement.toStringz, null, null, null) == SQLITE_OK,
        "fixture SQL");
}
private bool before(SinkKey a, SinkKey b) {
    if (a.document.text != b.document.text)
        return a.document.text < b.document.text;
    foreach (i; 0 .. 32)
        if (a.inputSha256[i] != b.inputSha256[i])
            return a.inputSha256[i] < b.inputSha256[i];
    foreach (i; 0 .. 32)
        if (a.configSha256[i] != b.configSha256[i])
            return a.configSha256[i] < b.configSha256[i];
    return a.sink < b.sink;
}
private ubyte[32] digestFile(string path) {
    return sha256Of(cast(const(ubyte)[])read(path));
}
private void checkSmall(string root) {
    auto path = buildPath(root, "small.db");
    createV2(path);
    auto a = DocumentId.from(SourceLocator("retry", "set", "a"));
    auto b = DocumentId.from(SourceLocator("retry", "set", "b"));
    auto inA = inputDigest(cast(const(ubyte)[])"input-a");
    auto inB = inputDigest(cast(const(ubyte)[])"input-b");
    auto cfgA = configDigest(cast(const(ubyte)[])"config-a");
    auto cfgB = configDigest(cast(const(ubyte)[])"config-b");
    auto first = SinkKey(a, inA, cfgA, "PRIVATE_SINK_LABEL-a");
    auto second = SinkKey(b, inA, cfgA, "PRIVATE_SINK_LABEL-b");
    auto sibling = SinkKey(a, inA, cfgA, "PRIVATE_SINK_LABEL-c");
    auto inputRevision = SinkKey(a, inB, cfgA, first.sink);
    auto configRevision = SinkKey(a, inA, cfgB, first.sink);
    auto historyOnly = SinkKey(b, inB, cfgA, "history-only");
    auto plannedOnly = SinkKey(b, inB, cfgB, "planned-only");
    auto journal = new FailureJournal(path);
    foreach (index, key; [first, second, sibling, inputRevision,
            configRevision, historyOnly, plannedOnly])
        journal.plan(key, buildPath(root, "output-" ~ index.to!string));
    journal.recordFailure(first, "filter", "filter-failed", false);
    journal.recordFailure(second, "sink", "sink-write-failed", true);
    journal.recordFailure(sibling, "filter", "filter-failed", false);
    journal.retry(sibling); // Planned state retains its outstanding row.
    need(journal.lookup(first).get.state == SinkState.failed &&
        journal.lookup(second).get.state == SinkState.uncertain &&
        journal.lookup(sibling).get.state == SinkState.planned &&
        journal.hasOutstanding(sibling), "fixture covers failed uncertain planned");
    journal.recordFailure(inputRevision, "filter", "filter-failed", false);
    journal.recordFailure(configRevision, "filter", "filter-failed", false);
    journal.recordFailure(historyOnly, "filter", "filter-failed", false);
    journal.retry(historyOnly);
    auto historyPath = buildPath(root, "output-5");
    journal.beginPublication(historyOnly);
    write(historyPath, "published");
    journal.commitPublished(historyOnly, historyPath,
        outputDigest(cast(const(ubyte)[])"published"));
    auto tracked = [first, second, sibling, inputRevision, configRevision];
    tracked.sort!before;
    auto beforeDb = digestFile(path);
    auto beforeWal = exists(path ~ "-wal") ? digestFile(path ~ "-wal") : ubyte[32].init;
    auto beforeShm = exists(path ~ "-shm") ? digestFile(path ~ "-shm") : ubyte[32].init;
    SinkKey[] actual;
    journal.visitOutstandingTargets((SinkKey key) { actual ~= key; });
    need(actual == tracked, "canonical exact full-key order");
    size_t callbacks;
    reject({ journal.visitOutstandingTargets((SinkKey key) {
        ++callbacks;
        if (callbacks == 2) throw new Exception("callback stopped");
    }); }, "callback stopped", "callback failure did not abort");
    need(callbacks == 2, "callback continued after failure");
    reject({ journal.visitOutstandingTargets((SinkKey key) {
        journal.close();
    }); }, "target-visitor-active", "callback closed active journal");
    reject({ journal.visitOutstandingTargets((SinkKey key) {
        journal.lookup(first);
    }); }, "target-visitor-active", "callback reentered lookup");
    reject({ journal.visitOutstandingTargets((SinkKey key) {
        journal.retry(first);
    }); }, "target-visitor-active", "callback reentered mutation");
    actual.length = 0;
    journal.visitOutstandingTargets((SinkKey key) { actual ~= key; });
    need(actual == tracked && journal.lookup(first).get.state == SinkState.failed,
        "journal unusable after callback refusal");
    need(digestFile(path) == beforeDb &&
        (exists(path ~ "-wal") ? digestFile(path ~ "-wal") : ubyte[32].init) == beforeWal &&
        (exists(path ~ "-shm") ? digestFile(path ~ "-shm") : ubyte[32].init) == beforeShm,
        "visitor changed journal bytes");
    journal.close();
    auto malformed = buildPath(root, "malformed.db");
    createV2(malformed);
    // Structurally consistent legacy-v1 baseline with a noncanonical ID:
    // constructor shape checks accept it, visitor's typed parser must not.
    sql(malformed, `BEGIN; INSERT INTO sink_identity VALUES('private-bad',
        '00000000-0000-4000-8000-000000000001');
        INSERT INTO sink_state VALUES('not-a-document-id',zeroblob(32),
        zeroblob(32),'private-bad','/tmp/unused','failed',NULL,0,0);
        INSERT INTO outstanding VALUES('not-a-document-id',zeroblob(32),
        zeroblob(32),'private-bad','00000000-0000-4000-8000-000000000001',
        'failed','legacy-v1',NULL,NULL,NULL); COMMIT;`);
    auto bad = new FailureJournal(malformed);
    reject({ bad.visitOutstandingTargets((SinkKey key) {}); },
        "invalid-outstanding-target", "malformed ID accepted");
    bad.close();
    auto nulDocumentPath = buildPath(root, "nul-document.db");
    createV2(nulDocumentPath);
    auto nulDocument = "'" ~ a.text ~ "'||char(0)||'suffix'";
    sql(nulDocumentPath, `BEGIN;
        INSERT INTO sink_identity VALUES('private-nul-doc',
        '00000000-0000-4000-8000-000000000003');
        INSERT INTO sink_state VALUES(` ~ nulDocument ~ `,zeroblob(32),
        zeroblob(32),'private-nul-doc','/tmp/unused','failed',NULL,0,0);
        INSERT INTO outstanding VALUES(` ~ nulDocument ~ `,zeroblob(32),
        zeroblob(32),'private-nul-doc',
        '00000000-0000-4000-8000-000000000003',
        'failed','legacy-v1',NULL,NULL,NULL); COMMIT;`);
    auto nulDocumentJournal = new FailureJournal(nulDocumentPath);
    size_t corruptCallbacks;
    reject({ nulDocumentJournal.visitOutstandingTargets((SinkKey key) {
        ++corruptCallbacks;
    }); }, "invalid-outstanding-target", "NUL document ID accepted");
    need(corruptCallbacks == 0, "NUL document invoked callback");
    nulDocumentJournal.close();
    auto nulSinkPath = buildPath(root, "nul-sink.db");
    createV2(nulSinkPath);
    auto nulSink = "'PRIVATE_SINK_LABEL'||char(0)||'suffix'";
    sql(nulSinkPath, `BEGIN;
        INSERT INTO sink_identity VALUES(` ~ nulSink ~ `,
        '00000000-0000-4000-8000-000000000004');
        INSERT INTO sink_state VALUES('` ~ a.text ~ `',zeroblob(32),
        zeroblob(32),` ~ nulSink ~ `,'/tmp/unused','failed',NULL,0,0);
        INSERT INTO outstanding VALUES('` ~ a.text ~ `',zeroblob(32),
        zeroblob(32),` ~ nulSink ~ `,
        '00000000-0000-4000-8000-000000000004',
        'failed','legacy-v1',NULL,NULL,NULL); COMMIT;`);
    auto nulSinkJournal = new FailureJournal(nulSinkPath);
    corruptCallbacks = 0;
    reject({ nulSinkJournal.visitOutstandingTargets((SinkKey key) {
        ++corruptCallbacks;
    }); }, "invalid-outstanding-target", "NUL sink label accepted");
    need(corruptCallbacks == 0, "NUL sink invoked callback");
    nulSinkJournal.close();
    auto badDigestPath = buildPath(root, "bad-digest.db");
    createV2(badDigestPath);
    sql(badDigestPath, `PRAGMA ignore_check_constraints=ON; BEGIN;
        INSERT INTO sink_identity VALUES('private-digest',
        '00000000-0000-4000-8000-000000000002');
        INSERT INTO sink_state VALUES('` ~ a.text ~ `',x'00',zeroblob(32),
        'private-digest','/tmp/unused','failed',NULL,0,0);
        INSERT INTO outstanding VALUES('` ~ a.text ~ `',x'00',zeroblob(32),
        'private-digest','00000000-0000-4000-8000-000000000002',
        'failed','legacy-v1',NULL,NULL,NULL); COMMIT;`);
    reject({ auto badDigestJournal = new FailureJournal(badDigestPath);
        badDigestJournal.close(); },
        "integrity-failed", "malformed digest accepted");
    auto foreign = buildPath(root, "foreign.db");
    write(foreign, "foreign database");
    reject({ auto f = new FailureJournal(foreign); f.close(); },
        "failure journal:", "foreign file accepted");
    auto v1Path = buildPath(root, "v1.db");
    auto v1 = new LocalManifest(v1Path);
    v1.close();
    reject({ auto f = new FailureJournal(v1Path); f.close(); },
        "failure journal:", "v1 journal accepted");
}
private void makeLarge(string root) {
    auto path = buildPath(root, "large.db");
    createV2(path);
    auto doc = DocumentId.from(SourceLocator("retry", "large", "all"));
    auto destination = buildPath(root, "unused");
    // One transaction creates a valid 10,000-row legacy-v1 baseline without
    // 20,000 per-row fsyncs. The visitor still uses the real v2 constructor.
    string statements = "BEGIN;";
    string filler;
    foreach (_; 0 .. 248) filler ~= "x";
    foreach (i; 0 .. 10_000) {
        auto label = "s" ~ i.to!string ~ "-" ~ filler;
        need(label.length <= 256, "large sink label cap");
        auto opaque = randomUUID().toString;
        statements ~= "INSERT INTO sink_identity VALUES('" ~ label ~ "','" ~
            opaque ~ "');INSERT INTO sink_state VALUES('" ~ doc.text ~
            "',zeroblob(32),zeroblob(32),'" ~ label ~ "','" ~ destination ~
            "','failed',NULL,0,0);INSERT INTO outstanding VALUES('" ~
            doc.text ~ "',zeroblob(32),zeroblob(32),'" ~ label ~ "','" ~
            opaque ~ "','failed','legacy-v1',NULL,NULL,NULL);";
    }
    statements ~= "COMMIT;";
    sql(path, statements);
}
private void checkLargeChild(string path, bool retain) {
    auto baselineFds = fdCount();
    auto baselineRss = rssBytes();
    auto journal = new FailureJournal(path);
    size_t count;
    SinkKey[] retained;
    journal.visitOutstandingTargets((SinkKey key) {
        ++count;
        if (retain) retained ~= key;
    });
    need(count == 10_000, "large exact row count");
    auto visitedFds = fdCount();
    auto visitedRss = rssBytes();
    if (retain) need(retained.length == count &&
        retained[$ - 1].sink.length >= 250, "retaining control");
    journal.close();
    need(visitedFds <= baselineFds + 8, "large descriptor bound");
    need(fdCount() <= baselineFds, "large descriptor cleanup");
    if (!retain) need(visitedRss <= 32UL * 1024 * 1024,
        "large resident bound " ~ visitedRss.to!string);
    import std.stdio : writeln;
    writeln(visitedRss, " ", visitedFds, " ", baselineRss, " ", baselineFds);
}
void main(string[] args) {
    if (args.length == 3 && (args[1] == "--large-child" ||
        args[1] == "--large-retain-child")) {
        checkLargeChild(args[2], args[1] == "--large-retain-child");
        return;
    }
    need(args.length == 1, "unexpected arguments");
    auto root = buildPath(tempDir(), "scrubbed-retry-targets-" ~ randomUUID().toString);
    mkdir(root);
    scope(exit) rmdirRecurse(root);
    checkSmall(root);
    makeLarge(root);
    auto path = buildPath(root, "large.db");
    auto result = execute([args[0], "--large-child", path]);
    need(result.status == 0, "large stream child failed: " ~ result.output);
    auto control = execute([args[0], "--large-retain-child", path]);
    need(control.status == 0, "large control child failed: " ~ control.output);
    auto streamMetrics = result.output.strip.split(" ");
    auto controlMetrics = control.output.strip.split(" ");
    need(streamMetrics.length == 4 && controlMetrics.length == 4,
        "large resource output shape");
    auto streamRss = streamMetrics[0].to!ulong;
    auto retainedRss = controlMetrics[0].to!ulong;
    need(retainedRss >= streamRss + 2UL * 1024 * 1024,
        "retaining control did not separate from streaming RSS");
    import std.stdio : writeln;
    writeln("retry targets: 10000 streamed; RSS ", streamRss,
        " bytes, FD ", streamMetrics[1], "; retained control RSS ",
        retainedRss, " bytes");
    writeln("retry target checker passed");
}
