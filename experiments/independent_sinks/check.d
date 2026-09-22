module independent_sinks.check;

import content.pieces : Content, ContentPiece;
import domain.document : Document, DocumentViewOwner, OutputName, SourceLocator;
import effects.independent_sinks : IndependentLocalSinks, IndependentPayloads,
    contentSinkKey, metadataSinkKey, independentSinksFault;
import effects.local_manifest : LocalManifest, SinkKey, SinkState,
    configDigest, inputDigest;
import effects.runner : Parser, Source, SourceRecord, runEffects;
import stages.contract : PassMode, ResourceDeclaration, StageDeclaration,
    StageDecision, StageDocument, StageEvent;
import core.sys.posix.sys.wait : waitpid;
import core.sys.posix.unistd : _exit, fork, link;
import std.file : exists, mkdir, read, rmdir, rmdirRecurse, symlink, tempDir, write;
import std.path : buildPath;
import std.string : toStringz;
import std.uuid : randomUUID;

private void require(bool yes, string message) {
    if (!yes) throw new Exception(message);
}

private void expectFailure(scope void delegate() action) {
    bool failed;
    try action();
    catch (Exception) failed = true;
    require(failed, "expected failure");
}

private class OneSource : Source {
    SourceRecord record;
    bool served;
    override bool next(out SourceRecord value) {
        if (served) return false;
        served = true;
        value = record;
        return true;
    }
}

private class BorrowParser : Parser {
    override Content parse(SourceRecord record) {
        return new Content([ContentPiece.borrow(record.owner.view(0, 1))]);
    }
}

private struct Paths {
    string db;
    string contentRoot;
    string metadataRoot;
    string contentFile;
    string metadataFile;
}

private Paths paths(string root) {
    Paths p;
    p.db = buildPath(root, "manifest.db");
    p.contentRoot = buildPath(root, "content");
    p.metadataRoot = buildPath(root, "metadata");
    p.contentFile = buildPath(p.contentRoot, "record");
    p.metadataFile = buildPath(p.metadataRoot, "record");
    mkdir(p.contentRoot);
    mkdir(p.metadataRoot);
    return p;
}

private Document document() {
    return Document(SourceLocator("independent-check", "fixture", "1"), OutputName("record"));
}

private SinkKey key(string sink) {
    return SinkKey(document().id, inputDigest(cast(const(ubyte)[]) "x"),
        configDigest(cast(const(ubyte)[]) sink), sink);
}

private void run(Paths p, bool retry, string faultSink = "", string faultPhase = "",
    bool crash = false, string providerAlias = "") {
    scope manifest = new LocalManifest(p.db);
    auto source = new OneSource;
    source.record = SourceRecord(document(), new DocumentViewOwner([cast(ubyte)'x']));
    scope(exit) expectFailure({ source.record.owner.view(0, 0); });
    auto adapter = new IndependentLocalSinks(manifest, p.contentRoot, p.metadataRoot,
        key(contentSinkKey).inputSha256, key(contentSinkKey).configSha256,
        key(metadataSinkKey).configSha256,
        (StageEvent event) {
            require(event.payload.document.id == document().id, "identity changed");
            require(event.payload.document.outputName.text == "record", "name changed");
            if (providerAlias == "hardlink") {
                write(p.contentFile, "prior");
                require(link(p.contentFile.toStringz, p.metadataFile.toStringz) == 0,
                    "provider hardlink fixture failed");
            } else if (providerAlias == "root-symlink") {
                rmdir(p.metadataRoot);
                symlink(p.contentRoot, p.metadataRoot);
            }
            return IndependentPayloads(event.payload.content,
                new Content([ContentPiece.own(cast(const(ubyte)[]) "metadata") ]));
        }, retry);
    independentSinksFault = (string sink, string phase) {
        if (sink == faultSink && phase == faultPhase) {
            if (crash) _exit(73);
            throw new Exception("injected " ~ phase);
        }
    };
    scope(exit) independentSinksFault = null;
    auto stage = StageDeclaration("pass", PassMode.singlePass, ResourceDeclaration(1, 0));
    runEffects(source, new BorrowParser, adapter, stage,
        (StageDocument input) { return StageDecision.map(input); });
}

private void checkCrash(string root, string crashSink) {
    auto p = paths(root);
    auto child = fork();
    require(child >= 0, "fork failed");
    if (child == 0) {
        run(p, false, crashSink, "after-publish", true);
        _exit(90);
    }
    int status;
    require(waitpid(child, &status, 0) == child && status == (73 << 8),
        "child did not crash at publication cutpoint");
    scope manifest = new LocalManifest(p.db);
    auto crashedPath = crashSink == contentSinkKey ? p.contentFile : p.metadataFile;
    require(exists(crashedPath), "crash cutpoint did not publish output");
    require(manifest.lookup(key(crashSink)).get.state == SinkState.planned,
        "crash unexpectedly committed output");
    manifest.close();
    expectFailure({ run(p, false); });
    run(p, true);
    scope reopened = new LocalManifest(p.db);
    require(reopened.lookup(key(contentSinkKey)).get.state == SinkState.committed &&
        reopened.lookup(key(metadataSinkKey)).get.state == SinkState.committed,
        "crashed route did not recover both outputs");
}

private void checkFailure(string root, string failedSink, string phase) {
    auto p = paths(root);
    expectFailure({ run(p, false, failedSink, phase); });
    scope manifest = new LocalManifest(p.db);
    auto goodSink = failedSink == contentSinkKey ? metadataSinkKey : contentSinkKey;
    auto goodPath = failedSink == contentSinkKey ? p.metadataFile : p.contentFile;
    auto badPath = failedSink == contentSinkKey ? p.contentFile : p.metadataFile;
    require(manifest.lookup(key(goodSink)).get.state == SinkState.committed,
        "other sink did not commit");
    require(manifest.lookup(key(failedSink)).get.state ==
        (phase == "after-publish" ? SinkState.uncertain : SinkState.failed),
        "failed sink state incorrect");
    require(exists(goodPath), "good output absent");
    require(exists(badPath) == (phase == "after-publish"), "bad publication boundary");
    auto priorGood = cast(const(ubyte)[]) read(goodPath);
    auto priorAttempt = manifest.lookup(key(goodSink)).get.attempt;
    manifest.close();
    expectFailure({ run(p, false); }); // explicit retry is required
    run(p, true);
    scope reopened = new LocalManifest(p.db);
    require(reopened.lookup(key(goodSink)).get.attempt == priorAttempt,
        "verified sink was rewritten");
    require(reopened.lookup(key(failedSink)).get.state == SinkState.committed,
        "failed sink did not recover");
    require(cast(const(ubyte)[]) read(goodPath) == priorGood,
        "good output changed");
    require(cast(const(ubyte)[]) read(p.contentFile) == cast(const(ubyte)[]) "x",
        "content bytes changed");
    require(cast(const(ubyte)[]) read(p.metadataFile) == cast(const(ubyte)[]) "metadata",
        "metadata bytes changed");
}

void main() {
    auto root = buildPath(tempDir(), "independent-sinks-" ~ randomUUID.toString);
    mkdir(root);
    scope(exit) rmdirRecurse(root);
    foreach (sink; [contentSinkKey, metadataSinkKey])
        foreach (phase; ["before-write", "after-publish"]) {
            auto caseRoot = buildPath(root, sink ~ "-" ~ phase);
            mkdir(caseRoot);
            checkFailure(caseRoot, sink, phase);
        }
    foreach (sink; [contentSinkKey, metadataSinkKey]) {
        auto caseRoot = buildPath(root, sink ~ "-crash");
        mkdir(caseRoot);
        checkCrash(caseRoot, sink);
    }
    auto aliasRoot = buildPath(root, "alias");
    mkdir(aliasRoot);
    auto p = paths(aliasRoot);
    auto aliasPath = buildPath(aliasRoot, "same-root");
    symlink(p.contentRoot, aliasPath);
    scope manifest = new LocalManifest(p.db);
    expectFailure({ new IndependentLocalSinks(manifest, p.contentRoot, aliasPath,
        key(contentSinkKey).inputSha256, key(contentSinkKey).configSha256,
        key(metadataSinkKey).configSha256,
        (StageEvent event) { return IndependentPayloads(event.payload.content,
            event.payload.content); }); });
    require(!exists(p.contentFile) && !exists(p.metadataFile),
        "alias check published output");
    auto collisionRoot = buildPath(root, "hardlink");
    mkdir(collisionRoot);
    auto collision = paths(collisionRoot);
    write(collision.contentFile, "prior");
    require(link(collision.contentFile.toStringz,
        collision.metadataFile.toStringz) == 0, "hardlink fixture failed");
    expectFailure({ run(collision, true); });
    require(cast(const(ubyte)[]) read(collision.contentFile) ==
        cast(const(ubyte)[]) "prior", "collision replaced an output");
    auto providerHardlinkRoot = buildPath(root, "provider-hardlink");
    mkdir(providerHardlinkRoot);
    auto providerHardlink = paths(providerHardlinkRoot);
    expectFailure({ run(providerHardlink, true, "", "", false, "hardlink"); });
    require(cast(const(ubyte)[]) read(providerHardlink.contentFile) ==
        cast(const(ubyte)[]) "prior", "provider hardlink replaced output");
    auto providerSymlinkRoot = buildPath(root, "provider-symlink");
    mkdir(providerSymlinkRoot);
    auto providerSymlink = paths(providerSymlinkRoot);
    expectFailure({ run(providerSymlink, true, "", "", false, "root-symlink"); });
    require(!exists(providerSymlink.contentFile), "provider root alias published output");
    import std.stdio : writeln;
    writeln("independent sinks release checks passed");
}
