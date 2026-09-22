/// Release-active Stage 3a export boundary check.
module experiments.errors.export_check;

import domain.document : DocumentId, SourceLocator;
import effects.local_manifest : SinkKey, LocalManifest, inputDigest, configDigest;
import effects.failure_journal : FailureJournal, createV2, copyV1ToV2;
import effects.error_export : exportV2, verifyV2Export;
import effects.sqlite_ffi;
import std.algorithm.searching : canFind;
import std.conv : to;
import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;
import std.file : SpanMode, dirEntries, exists, mkdir, readText, remove,
    rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.string : indexOf, replace;
import std.uuid : randomUUID;
import std.process : execute;
import core.sys.posix.unistd : symlink, link;
import core.sys.posix.sys.resource : getrusage, rusage, RUSAGE_SELF;
import std.string : toStringz;

private void need(bool yes, string label) {
    if (!yes) throw new Exception("export check: " ~ label);
}
private void refuse(void delegate() action, string label) {
    bool failed;
    try action(); catch (Exception) failed = true;
    need(failed, label);
}
private void refuseToken(void delegate() action, string token, string label) {
    bool failed;
    try action();
    catch (Exception error) {
        failed = error.msg.canFind(token) &&
            !error.msg.canFind("F13_SECRET_TOKEN") &&
            !error.msg.canFind("/private/f13-canary.txt");
    }
    need(failed, label);
}
private string sidecar(string kind, string bytes, string id) {
    return `{"schema":"scrubbed.error-export-digest.v1","kind":"` ~ kind ~
        `","sha256":"` ~ toHexString!(LetterCase.lower)(sha256Of(bytes)).idup ~
        `","bytes":` ~ bytes.length.to!string ~ `,"snapshot_id":"` ~ id ~ `"}` ~ "\n";
}
private string snapshotId(string side) {
    auto marker = `"snapshot_id":"`;
    auto at = side.indexOf(marker);
    need(at >= 0, "missing snapshot ID");
    return side[at + marker.length .. at + marker.length + 36];
}
private string record(string schema, string id, long sequence, string run,
    string doc, string input, string config, string sink, string phase,
    string code, string state, string retry, long at) {
    return `{"schema":"` ~ schema ~ `","event_id":"` ~ id ~
        `","sequence":` ~ sequence.to!string ~ `,"run_id":"` ~ run ~
        `","config_sha256":"` ~ config ~ `","document_id":"` ~ doc ~
        `","input_sha256":"` ~ input ~ `","sink_id":"` ~ sink ~
        `","phase":"` ~ phase ~ `","code":"` ~ code ~ `","state":"` ~
        state ~ `","retry_of":` ~ retry ~ `,"time_utc_ms":` ~ at.to!string ~ "}\n";
}
private size_t fdCount() {
    size_t n;
    foreach (_; dirEntries("/dev/fd", SpanMode.shallow)) ++n;
    return n;
}
private long rssBytes() {
    rusage usage;
    need(getrusage(RUSAGE_SELF, &usage) == 0, "RSS observation");
    version (OSX) return usage.ru_opaque[0];
    else version (linux) return usage.ru_maxrss * 1024;
    else static assert(0, "RSS observation requires platform support");
}
private void checkLabelLimit(string root) {
    auto path = buildPath(root, "label-limit.db");
    createV2(path);
    char[256] ascii;
    ascii[] = 'a';
    auto exactly = ascii[].idup;
    string multibyte;
    foreach (_; 0 .. 128) multibyte ~= "é";
    need(exactly.length == 256 && multibyte.length == 256,
        "label boundary fixture");
    auto doc = DocumentId.from(SourceLocator("label", "set", "one"));
    auto input = inputDigest(cast(const(ubyte)[])"label-input");
    auto config = configDigest(cast(const(ubyte)[])"label-config");
    auto journal = new FailureJournal(path);
    foreach (i, label; [exactly, multibyte]) {
        auto key = SinkKey(doc, input, config, label);
        journal.plan(key, buildPath(root, "label-output-" ~ i.to!string));
        need(!journal.lookup(key).isNull, "256-byte label refused");
    }
    foreach (label; [exactly ~ "b", multibyte ~ "b"]) {
        auto key = SinkKey(doc, input, config, label);
        refuseToken({ journal.plan(key, buildPath(root, "over-label")); },
            "v2-sink-label-too-long", "257-byte label accepted");
        need(journal.lookup(key).isNull, "rejected label persisted");
    }
    journal.close();
    journal = new FailureJournal(path);
    need(!journal.lookup(SinkKey(doc, input, config, exactly)).isNull &&
        !journal.lookup(SinkKey(doc, input, config, multibyte)).isNull,
        "boundary labels changed on reopen");
    journal.close();

    auto v1Path = buildPath(root, "long-label-v1.db");
    auto v1 = new LocalManifest(v1Path);
    auto old = SinkKey(doc, input, config, exactly ~ "b");
    v1.plan(old, buildPath(root, "old-label-output"));
    v1.markFailed(old);
    need(!v1.lookup(old).isNull, "v1 oversized label changed");
    v1.close();
    auto copyPath = buildPath(root, "oversized-copy.db");
    refuseToken({ copyV1ToV2(v1Path, copyPath); },
        "v2-sink-label-too-long", "oversized v1 copy accepted");
    need(!exists(copyPath), "oversized v1 copy published destination");
    v1 = new LocalManifest(v1Path);
    need(!v1.lookup(old).isNull, "v1 source changed after copy refusal");
    v1.close();
}
private void check(string root, string executable) {
    checkLabelLimit(root);
    auto db = buildPath(root, "journal.db");
    auto history = buildPath(root, "history.jsonl");
    auto outstanding = buildPath(root, "outstanding.jsonl");
    createV2(db);
    auto doc = DocumentId.from(SourceLocator("export", "set", "one"));
    auto a = SinkKey(doc, inputDigest(cast(const(ubyte)[])"input"),
        configDigest(cast(const(ubyte)[])"config"),
        "F13_SECRET_TOKEN /private/f13-canary.txt https://invalid.example/f13-canary F13_SOURCE_BYTES F13_EXCEPTION_TEXT");
    auto journal = new FailureJournal(db);
    journal.plan(a, buildPath(root, "sink.txt"));
    journal.recordFailure(a, "sink", "sink-write-failed", true);
    auto sink = journal.publicSinkId(a.sink);
    journal.close();
    exportV2(db, history, outstanding);
    verifyV2Export(history, outstanding);
    auto h = readText(history);
    auto o = readText(outstanding);
    auto hs = readText(history ~ ".sha256");
    auto os = readText(outstanding ~ ".sha256");
    foreach (canary; ["F13_SECRET_TOKEN", "/private/f13-canary.txt",
            "https://invalid.example/f13-canary", "F13_SOURCE_BYTES", "F13_EXCEPTION_TEXT"])
        need(!h.canFind(canary) && !o.canFind(canary) &&
            !hs.canFind(canary) && !os.canFind(canary), "privacy canary");
    auto id = snapshotId(hs);
    need(id == snapshotId(os) && hs == sidecar("history", h, id) &&
        os == sidecar("outstanding", o, id), "sidecar golden");
    auto eventId = h[h.indexOf(`"event_id":"`) + 12 .. h.indexOf(`"event_id":"`) + 48];
    auto runAt = h.indexOf(`"run_id":"`) + 10;
    auto runId = h[runAt .. runAt + 36];
    auto input = toHexString!(LetterCase.lower)(a.inputSha256[]).idup;
    auto config = toHexString!(LetterCase.lower)(a.configSha256[]).idup;
    auto atMarker = `"time_utc_ms":`;
    auto at = h[h.indexOf(atMarker) + atMarker.length .. $ - 2].to!long;
    need(h == record("scrubbed.error-event.v1", eventId, 1, runId,
        doc.text, input, config, sink, "sink", "sink-write-failed",
        "uncertain", "null", at), "history golden");
    auto expectedO = `{"schema":"scrubbed.outstanding.v1","document_id":"` ~
        doc.text ~ `","input_sha256":"` ~ input ~ `","config_sha256":"` ~
        config ~ `","sink_id":"` ~ sink ~ `","state":"uncertain","origin":"event","event_id":"` ~
        eventId ~ `","run_id":"` ~ runId ~ `","time_utc_ms":` ~ at.to!string ~ "}\n";
    need(o == expectedO, "outstanding golden");
    write(history ~ ".sha256", hs[0 .. $ - 1]);
    refuse({ verifyV2Export(history); }, "truncated sidecar accepted");
    write(history ~ ".sha256", hs.replace(`"kind":"history"`,
        `"kind":"outstanding"`));
    refuse({ verifyV2Export(history); }, "wrong sidecar kind accepted");
    remove(history ~ ".sha256");
    refuse({ verifyV2Export(history); }, "missing sidecar accepted");
    write(history ~ ".sha256", hs);
    write(history, h ~ "x");
    refuse({ verifyV2Export(history); }, "tampered JSONL accepted");
    write(history, h);
    verifyV2Export(history, outstanding);
    exportV2(db, "", outstanding);
    verifyV2Export("", outstanding);
    refuse({ verifyV2Export(history, outstanding); }, "mixed snapshots accepted");
    refuse({ exportV2(db, db, ""); }, "database alias accepted");
    refuse({ exportV2(db, history, history); }, "destination alias accepted");
    auto foreign = buildPath(root, "foreign.db");
    write(foreign, "not a database");
    refuse({ exportV2(foreign, history); }, "foreign database accepted");
    auto v1Path = buildPath(root, "v1.db");
    auto v1 = new LocalManifest(v1Path);
    v1.plan(a, buildPath(root, "legacy-sink.txt"));
    v1.markFailed(a);
    v1.close();
    refuse({ exportV2(v1Path, history); }, "v1 database accepted");
    auto copied = buildPath(root, "copied.db");
    copyV1ToV2(v1Path, copied);
    auto legacyH = buildPath(root, "legacy-history.jsonl");
    auto legacyO = buildPath(root, "legacy-outstanding.jsonl");
    exportV2(copied, legacyH, legacyO);
    verifyV2Export(legacyH, legacyO);
    need(readText(legacyH).length == 0 &&
        readText(legacyH ~ ".sha256") ==
            sidecar("history", "", snapshotId(readText(legacyH ~ ".sha256"))) &&
        readText(legacyO).canFind(`"origin":"legacy-v1","event_id":null,"run_id":null,"time_utc_ms":null`),
        "legacy and empty golden");
    auto linkPath = buildPath(root, "alias.jsonl");
    need(symlink(history.toStringz, linkPath.toStringz) == 0, "symlink fixture");
    refuse({ exportV2(db, linkPath); }, "symlink accepted");
    auto hard = buildPath(root, "hard.jsonl");
    need(link(history.toStringz, hard.toStringz) == 0, "hardlink fixture");
    refuse({ exportV2(db, hard); }, "hardlink accepted");
    remove(hard);

    // Establish a changed DB snapshot, then kill at each publication boundary.
    auto b = SinkKey(doc, a.inputSha256, a.configSha256, "another-private-sink");
    journal = new FailureJournal(db);
    journal.plan(b, buildPath(root, "sink-b.txt"));
    journal.recordFailure(b, "filter", "filter-failed", false);
    journal.close();
    foreach (i, point; ["write", "sync", "side-sync", "before-json-rename",
            "after-json-rename", "after-side-rename"]) {
        exportV2(db, history, outstanding);
        auto prior = readText(history);
        auto priorSide = readText(history ~ ".sha256");
        auto next = SinkKey(doc, a.inputSha256, a.configSha256,
            "fault-private-" ~ i.to!string);
        journal = new FailureJournal(db);
        journal.plan(next, buildPath(root, "fault-output-" ~ i.to!string));
        journal.recordFailure(next, "filter", "filter-failed", false);
        journal.close();
        auto marker = db ~ ".fault-export-kill-" ~ point;
        write(marker, "1");
        auto child = execute([executable, "export", root]);
        remove(marker);
        need(child.status == 73 && !child.output.canFind("F13_SECRET_TOKEN") &&
            !child.output.canFind("F13_EXCEPTION_TEXT"), "fault process result");
        if (point == "after-json-rename") {
            need(readText(history ~ ".sha256") == priorSide,
                "sidecar changed before its rename");
            refuse({ verifyV2Export(history); }, "new JSONL with old digest accepted");
        } else if (point == "after-side-rename") {
            verifyV2Export(history);
            refuse({ verifyV2Export(history, outstanding); },
                "partially published joint snapshot accepted");
        } else {
            need(readText(history) == prior &&
                readText(history ~ ".sha256") == priorSide,
                "pre-publish crash changed pair");
            verifyV2Export(history, outstanding);
        }
    }
    foreach (point; ["write", "sync", "side-sync", "before-json-rename",
            "after-json-rename", "after-side-rename"]) {
        exportV2(db, history, outstanding);
        auto oldHistory = readText(history);
        auto oldOutstanding = readText(outstanding);
        journal = new FailureJournal(db);
        journal.recordFailure(b, "filter", "filter-failed", false);
        journal.close();
        auto marker = db ~ ".fault-export-kill-outstanding-" ~ point;
        write(marker, "1");
        auto child = execute([executable, "export", root]);
        remove(marker);
        need(child.status == 73 && !child.output.canFind("F13_SECRET_TOKEN"),
            "outstanding fault process result");
        verifyV2Export(history);
        if (point == "write" || point == "sync" || point == "side-sync") {
            need(readText(history) == oldHistory &&
                readText(outstanding) == oldOutstanding,
                "pre-publish outstanding fault changed JSONL");
            verifyV2Export(history, outstanding);
            continue;
        }
        if (point == "after-json-rename")
            refuse({ verifyV2Export("", outstanding); },
                "new outstanding with old sidecar accepted");
        else verifyV2Export("", outstanding);
        if (point == "after-side-rename") verifyV2Export(history, outstanding);
        else refuse({ verifyV2Export(history, outstanding); },
            "mixed export snapshots accepted at " ~ point);
    }
    // A growing history must not become an in-memory collection or leak
    // SQLite/file descriptors across repeated materializations.
    journal = new FailureJournal(db);
    foreach (_; 0 .. 2048)
        journal.recordFailure(b, "filter", "filter-failed", false);
    journal.close();
    auto beforeFd = fdCount();
    auto beforeRss = rssBytes();
    foreach (_; 0 .. 3) {
        exportV2(db, history, outstanding);
        verifyV2Export(history, outstanding);
    }
    need(fdCount() <= beforeFd + 1 && rssBytes() - beforeRss < 64 * 1024 * 1024,
        "long-log RSS/FD bound");
    auto priorOutstanding = readText(outstanding);
    auto ninth = SinkKey(doc, a.inputSha256, a.configSha256, "ninth-private-sink");
    journal = new FailureJournal(db);
    journal.plan(ninth, buildPath(root, "ninth-output"));
    journal.recordFailure(ninth, "filter", "filter-failed", false);
    journal.close();
    refuse({ exportV2(db, "", outstanding); }, "oversized public-prefix group accepted");
    need(readText(outstanding) == priorOutstanding,
        "group refusal changed prior export");

    // Construct a valid enormous private key in another process so its
    // allocation cannot mask an export-side RSS spike in this process.
    auto fixture = execute([executable, "large-fixture", root]);
    need(fixture.status == 0, "large fixture creation");
    auto large = buildPath(root, "large.db");
    auto largeH = buildPath(root, "large-history.jsonl");
    auto largeO = buildPath(root, "large-outstanding.jsonl");
    beforeFd = fdCount();
    beforeRss = rssBytes();
    refuseToken({ new FailureJournal(large); }, "v2-sink-label-too-long",
        "oversized v2 reopen accepted");
    refuseToken({ exportV2(large, largeH, largeO); }, "v2-sink-label-too-long",
        "oversized private key accepted without a bound");
    auto rssGrowth = rssBytes() - beforeRss;
    need(fdCount() <= beforeFd + 1 && rssGrowth < 24 * 1024 * 1024,
        "large private key materialized during export: " ~ rssGrowth.to!string);
    need(!exists(largeH) && !exists(largeO), "large key published partial export");
    beforeFd = fdCount();
    beforeRss = rssBytes();
    auto largeCopy = buildPath(root, "large-copy.db");
    refuseToken({ copyV1ToV2(buildPath(root, "large-v1.db"), largeCopy); },
        "v2-sink-label-too-long", "large v1 copy accepted");
    need(!exists(largeCopy) && fdCount() <= beforeFd + 1 &&
        rssBytes() - beforeRss < 24 * 1024 * 1024,
        "large v1 copy refusal unbounded or published");
}

void main(string[] args) {
    if (args.length == 3 && args[1] == "export") {
        auto root = args[2];
        exportV2(buildPath(root, "journal.db"), buildPath(root, "history.jsonl"),
            buildPath(root, "outstanding.jsonl"));
        return;
    }
    if (args.length == 3 && args[1] == "large-fixture") {
        auto root = args[2];
        auto path = buildPath(root, "large.db");
        createV2(path);
        char[] huge;
        huge.length = 32 * 1024 * 1024;
        huge[] = 'x';
        auto raw = "F13_SECRET_TOKEN" ~ huge.idup;
        sqlite3* db;
        need(sqlite3_open_v2(path.toStringz, &db, SQLITE_OPEN_READWRITE, null) == SQLITE_OK,
            "large fixture open");
        sqlite3_stmt* insert;
        auto sql = "INSERT INTO sink_identity(raw_sink,sink_id) VALUES(?1,'00000000-0000-4000-8000-000000000001')";
        need(sqlite3_prepare_v2(db, sql.toStringz, -1, &insert, null) == SQLITE_OK &&
            sqlite3_bind_text(insert, 1, raw.toStringz, cast(int)raw.length,
                cast(void*)-1) == SQLITE_OK && sqlite3_step(insert) == SQLITE_DONE,
            "large fixture insert");
        sqlite3_finalize(insert);
        need(sqlite3_close(db) == SQLITE_OK, "large fixture close");
        auto v1 = new LocalManifest(buildPath(root, "large-v1.db"));
        auto key = SinkKey(DocumentId.from(SourceLocator("large", "set", "one")),
            inputDigest(cast(const(ubyte)[])"large-input"),
            configDigest(cast(const(ubyte)[])"large-config"), raw);
        v1.plan(key, buildPath(root, "large-v1-sink"));
        v1.markFailed(key);
        v1.close();
        return;
    }
    auto root = buildPath(tempDir(), "scrubbed-export-" ~ randomUUID().toString);
    mkdir(root);
    scope(exit) rmdirRecurse(root);
    check(root, args[0]);
}
