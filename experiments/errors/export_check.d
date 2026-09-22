/// Release-active Stage 3a export boundary check.
module experiments.errors.export_check;

import domain.document : DocumentId, SourceLocator;
import effects.local_manifest : SinkKey, LocalManifest, inputDigest, configDigest;
import effects.failure_journal : FailureJournal, createV2, copyV1ToV2;
import effects.error_export : exportV2, verifyV2Export;
import std.algorithm.searching : canFind;
import std.conv : to;
import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;
import std.file : exists, mkdir, readText, remove, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.string : indexOf, replace;
import std.uuid : randomUUID;
import std.process : execute;
import core.sys.posix.unistd : symlink, link;
import std.string : toStringz;

private void need(bool yes, string label) {
    if (!yes) throw new Exception("export check: " ~ label);
}
private void refuse(void delegate() action, string label) {
    bool failed;
    try action(); catch (Exception) failed = true;
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
private void check(string root, string executable) {
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
}

void main(string[] args) {
    if (args.length == 3 && args[1] == "export") {
        auto root = args[2];
        exportV2(buildPath(root, "journal.db"), buildPath(root, "history.jsonl"),
            buildPath(root, "outstanding.jsonl"));
        return;
    }
    auto root = buildPath(tempDir(), "scrubbed-export-" ~ randomUUID().toString);
    mkdir(root);
    scope(exit) rmdirRecurse(root);
    check(root, args[0]);
}
