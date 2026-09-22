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
import core.stdc.stdlib : free;
import core.sys.posix.sys.wait : waitpid;
import core.sys.posix.sys.stat : stat, stat_t;
import core.sys.posix.unistd : _exit, fork, link;
import std.file : exists, mkdir, read, rmdir, rmdirRecurse, symlink, tempDir, write;
import std.path : buildPath;
import std.string : endsWith, fromStringz, toStringz;
import std.uuid : randomUUID;

private void require(bool yes, string message) {
    if (!yes) throw new Exception(message);
}

private extern(C) char* realpath(const(char)*, char*);

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

private Document document(string recordKey = "1", string outputName = "record") {
    return Document(SourceLocator("independent-check", "fixture", recordKey),
        OutputName(outputName));
}

private SinkKey key(string sink, string recordKey = "1", ubyte sourceByte = 'x',
    string revision = "") {
    return SinkKey(document(recordKey).id, inputDigest([sourceByte]),
        configDigest(cast(const(ubyte)[]) (sink ~ revision)), sink);
}

private void run(Paths p, bool retry, string faultSink = "", string faultPhase = "",
    bool crash = false, string providerAlias = "", string recordKey = "1",
    ubyte sourceByte = 'x', string revision = "", string outputName = "record") {
    scope manifest = new LocalManifest(p.db);
    auto source = new OneSource;
    source.record = SourceRecord(document(recordKey, outputName),
        new DocumentViewOwner([sourceByte]));
    scope(exit) expectFailure({ source.record.owner.view(0, 0); });
    auto adapter = new IndependentLocalSinks(manifest, p.contentRoot, p.metadataRoot,
        key(contentSinkKey, recordKey, sourceByte, revision).inputSha256,
        key(contentSinkKey, recordKey, sourceByte, revision).configSha256,
        key(metadataSinkKey, recordKey, sourceByte, revision).configSha256,
        (StageEvent event) {
            require(event.payload.document.id == document(recordKey).id, "identity changed");
            require(event.payload.document.outputName.text == outputName, "name changed");
            if (providerAlias == "hardlink") {
                write(p.contentFile, "prior");
                require(link(p.contentFile.toStringz, p.metadataFile.toStringz) == 0,
                    "provider hardlink fixture failed");
            } else if (providerAlias == "root-symlink") {
                rmdir(p.metadataRoot);
                symlink(p.contentRoot, p.metadataRoot);
            } else if (providerAlias == "ancestor-symlink") {
                rmdir(buildPath(p.metadataRoot, "chapter"));
                symlink(buildPath(p.contentRoot, "chapter"),
                    buildPath(p.metadataRoot, "chapter"));
            }
            return IndependentPayloads(event.payload.content,
                new Content([ContentPiece.own(cast(const(ubyte)[])
                    (sourceByte == 'x' ? "metadata" : "metadata-y"))]));
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

private Paths nestedPaths(string root) {
    auto p = paths(root);
    mkdir(buildPath(p.contentRoot, "chapter"));
    mkdir(buildPath(p.metadataRoot, "chapter"));
    p.contentFile = buildPath(p.contentRoot, "chapter", "page.txt");
    p.metadataFile = buildPath(p.metadataRoot, "chapter", "page.txt");
    return p;
}

private void checkNested(string root) {
    auto p = nestedPaths(root);
    expectFailure({ run(p, false, metadataSinkKey, "before-write", false,
        "", "1", 'x', "", "chapter/page.txt"); });
    scope manifest = new LocalManifest(p.db);
    auto contentRow = manifest.lookup(key(contentSinkKey)).get;
    auto metadataRow = manifest.lookup(key(metadataSinkKey)).get;
    require(contentRow.key.document == metadataRow.key.document &&
        contentRow.key.document == document().id &&
        contentRow.destination.endsWith("/content/chapter/page.txt") &&
        metadataRow.destination.endsWith("/metadata/chapter/page.txt") &&
        contentRow.state == SinkState.committed &&
        metadataRow.state == SinkState.failed,
        "nested route lost identity, relative path, or independent state");
    auto contentInode = inode(p.contentFile);
    manifest.close();
    expectFailure({ run(p, false, "", "", false,
        "", "1", 'x', "", "chapter/page.txt"); });
    run(p, true, "", "", false, "", "1", 'x', "", "chapter/page.txt");
    scope recovered = new LocalManifest(p.db);
    require(recovered.lookup(key(contentSinkKey)).get.attempt == contentRow.attempt &&
        recovered.lookup(key(metadataSinkKey)).get.state == SinkState.committed &&
        inode(p.contentFile) == contentInode &&
        cast(const(ubyte)[]) read(p.metadataFile) == cast(const(ubyte)[]) "metadata",
        "nested retry did not preserve committed sibling");
    auto metadataInode = inode(p.metadataFile);
    recovered.close();
    expectFailure({ run(p, true, "", "", false, "", "2", 'y', "",
        "chapter/page.txt"); });
    scope protectedManifest = new LocalManifest(p.db);
    require(protectedManifest.lookup(key(contentSinkKey, "2", 'y')).isNull &&
        protectedManifest.lookup(key(metadataSinkKey, "2", 'y')).isNull &&
        inode(p.contentFile) == contentInode && inode(p.metadataFile) == metadataInode &&
        cast(const(ubyte)[]) read(p.contentFile) == cast(const(ubyte)[]) "x" &&
        cast(const(ubyte)[]) read(p.metadataFile) == cast(const(ubyte)[]) "metadata",
        "duplicate nested name changed original owner");
}

private void checkRejectedName(string root, string name) {
    auto p = paths(root);
    expectFailure({ run(p, true, "", "", false, "", "1", 'x', "", name); });
    scope manifest = new LocalManifest(p.db);
    require(manifest.lookup(key(contentSinkKey)).isNull &&
        manifest.lookup(key(metadataSinkKey)).isNull &&
        !exists(p.contentFile) && !exists(p.metadataFile),
        "unsafe name planned or published a sink");
}

private void checkNestedHazard(string root, string hazard) {
    auto p = nestedPaths(root);
    if (hazard == "ancestor-symlink") {
        rmdir(buildPath(p.metadataRoot, "chapter"));
        symlink(buildPath(p.contentRoot, "chapter"),
            buildPath(p.metadataRoot, "chapter"));
    } else if (hazard == "destination-hardlink") {
        write(p.contentFile, "prior");
        require(link(p.contentFile.toStringz, p.metadataFile.toStringz) == 0,
            "nested hardlink fixture failed");
    } else if (hazard == "destination-symlink") {
        write(p.contentFile, "prior");
        symlink(p.contentFile, p.metadataFile);
    } else if (hazard == "missing-parent") {
        rmdir(buildPath(p.metadataRoot, "chapter"));
    }
    auto priorInode = exists(p.contentFile) ? inode(p.contentFile) : 0;
    expectFailure({ run(p, true, "", "", false, "", "1", 'x', "",
        "chapter/page.txt"); });
    scope manifest = new LocalManifest(p.db);
    require(manifest.lookup(key(contentSinkKey)).isNull &&
        manifest.lookup(key(metadataSinkKey)).isNull &&
        (priorInode == 0 ? !exists(p.contentFile) :
            inode(p.contentFile) == priorInode &&
            cast(const(ubyte)[]) read(p.contentFile) == cast(const(ubyte)[]) "prior"),
        "nested hazard changed output or manifest before publication");
}

private void checkRootAncestorSymlink(string root) {
    auto safe = buildPath(root, "safe");
    auto outside = buildPath(root, "outside");
    mkdir(safe);
    mkdir(outside);
    auto rootAlias = buildPath(safe, "link");
    symlink(outside, rootAlias);
    auto contentRoot = buildPath(outside, "content");
    auto metadataRoot = buildPath(outside, "metadata");
    mkdir(contentRoot);
    mkdir(metadataRoot);
    auto contentFile = buildPath(contentRoot, "prior");
    auto metadataFile = buildPath(metadataRoot, "prior");
    write(contentFile, "content-prior");
    write(metadataFile, "metadata-prior");
    auto contentInode = inode(contentFile);
    auto metadataInode = inode(metadataFile);
    auto db = buildPath(root, "manifest.db");
    scope manifest = new LocalManifest(db);
    bool providerCalled;
    expectFailure({ new IndependentLocalSinks(manifest,
        buildPath(rootAlias, "content"), buildPath(rootAlias, "metadata"),
        key(contentSinkKey).inputSha256, key(contentSinkKey).configSha256,
        key(metadataSinkKey).configSha256,
        (StageEvent event) {
            providerCalled = true;
            return IndependentPayloads(event.payload.content, event.payload.content);
        }); });
    require(!providerCalled && manifest.lookup(key(contentSinkKey)).isNull &&
        manifest.lookup(key(metadataSinkKey)).isNull &&
        inode(contentFile) == contentInode && inode(metadataFile) == metadataInode &&
        cast(const(ubyte)[]) read(contentFile) == cast(const(ubyte)[]) "content-prior" &&
        cast(const(ubyte)[]) read(metadataFile) == cast(const(ubyte)[]) "metadata-prior",
        "symlinked root ancestor reached provider, manifest, or outside outputs");
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

private ulong inode(string path) {
    stat_t info;
    require(stat(path.toStringz, &info) == 0, "cannot stat output fixture");
    return cast(ulong) info.st_ino;
}

private void checkDifferentDocument(string root) {
    auto p = paths(root);
    run(p, false);
    auto contentBytes = cast(const(ubyte)[]) read(p.contentFile);
    auto metadataBytes = cast(const(ubyte)[]) read(p.metadataFile);
    auto contentInode = inode(p.contentFile);
    auto metadataInode = inode(p.metadataFile);
    scope manifest = new LocalManifest(p.db);
    auto contentRow = manifest.lookup(key(contentSinkKey)).get;
    auto metadataRow = manifest.lookup(key(metadataSinkKey)).get;
    manifest.close();
    expectFailure({ run(p, true, "", "", false, "", "2", 'y'); });
    scope reopened = new LocalManifest(p.db);
    require(reopened.lookup(key(contentSinkKey)).get.state == contentRow.state &&
        reopened.lookup(key(contentSinkKey)).get.attempt == contentRow.attempt &&
        reopened.lookup(key(metadataSinkKey)).get.state == metadataRow.state &&
        reopened.lookup(key(metadataSinkKey)).get.attempt == metadataRow.attempt,
        "prior owner rows changed");
    require(reopened.lookup(key(contentSinkKey, "2", 'y')).isNull &&
        reopened.lookup(key(metadataSinkKey, "2", 'y')).isNull,
        "second document was planned");
    require(cast(const(ubyte)[]) read(p.contentFile) == contentBytes &&
        cast(const(ubyte)[]) read(p.metadataFile) == metadataBytes &&
        inode(p.contentFile) == contentInode && inode(p.metadataFile) == metadataInode,
        "second document changed first owner's outputs");
    reopened.close();
    run(p, true, "", "", false, "", "1", 'y', ":revision-2");
    scope revised = new LocalManifest(p.db);
    require(revised.lookup(key(contentSinkKey, "1", 'y', ":revision-2")).get.state ==
        SinkState.committed &&
        revised.lookup(key(metadataSinkKey, "1", 'y', ":revision-2")).get.state ==
        SinkState.committed, "same-document revision did not commit");
    require(cast(const(ubyte)[]) read(p.contentFile) == cast(const(ubyte)[]) "y" &&
        cast(const(ubyte)[]) read(p.metadataFile) ==
        cast(const(ubyte)[]) "metadata-y", "same-document revision bytes wrong");
}

private void checkUnresolvedOwner(string root, bool uncertain) {
    auto p = paths(root);
    scope manifest = new LocalManifest(p.db);
    manifest.plan(key(contentSinkKey), p.contentFile);
    if (uncertain) manifest.markUncertain(key(contentSinkKey));
    else manifest.markFailed(key(contentSinkKey));
    auto prior = manifest.lookup(key(contentSinkKey)).get;
    manifest.close();
    expectFailure({ run(p, true, "", "", false, "", "2", 'y'); });
    scope reopened = new LocalManifest(p.db);
    require(reopened.lookup(key(contentSinkKey)).get.state == prior.state &&
        reopened.lookup(key(contentSinkKey)).get.attempt == prior.attempt &&
        reopened.lookup(key(contentSinkKey, "2", 'y')).isNull &&
        !exists(p.contentFile) && !exists(p.metadataFile),
        "unresolved owner did not reserve destination");
}

private void checkHistoricalHardlink(string root) {
    auto p = paths(root);
    auto elsewhere = buildPath(root, "elsewhere");
    scope manifest = new LocalManifest(p.db);
    manifest.plan(key(contentSinkKey, "other"), elsewhere);
    write(elsewhere, "owned");
    require(link(elsewhere.toStringz, p.contentFile.toStringz) == 0,
        "historical hardlink fixture failed");
    manifest.close();
    expectFailure({ run(p, true); });
    scope reopened = new LocalManifest(p.db);
    require(reopened.lookup(key(contentSinkKey)).isNull &&
        cast(const(ubyte)[]) read(elsewhere) == cast(const(ubyte)[]) "owned" &&
        !exists(p.metadataFile), "historical inode owner was not protected");
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
    expectFailure({ document("1", ""); });
    expectFailure({ document("1", "chapter\0page.txt"); });
    auto canonicalTemp = realpath(tempDir().toStringz, null);
    require(canonicalTemp !is null, "cannot resolve test temp directory");
    scope(exit) free(canonicalTemp);
    auto root = buildPath(canonicalTemp.fromStringz.idup,
        "independent-sinks-" ~ randomUUID.toString);
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
    auto differentRoot = buildPath(root, "different-document");
    mkdir(differentRoot);
    checkDifferentDocument(differentRoot);
    auto nestedRoot = buildPath(root, "nested");
    mkdir(nestedRoot);
    checkNested(nestedRoot);
    auto rootAncestor = buildPath(root, "root-ancestor-symlink");
    mkdir(rootAncestor);
    checkRootAncestorSymlink(rootAncestor);
    foreach (index, name; ["/absolute", "./page.txt", "chapter/../page.txt",
            "chapter//page.txt", "chapter/page.txt/", "chapter\\page.txt", ".", ".."]) {
        auto invalidRoot = buildPath(root, "invalid-" ~ cast(char)('a' + index));
        mkdir(invalidRoot);
        checkRejectedName(invalidRoot, name);
    }
    foreach (hazard; ["ancestor-symlink", "destination-hardlink",
            "destination-symlink", "missing-parent"]) {
        auto hazardRoot = buildPath(root, hazard);
        mkdir(hazardRoot);
        checkNestedHazard(hazardRoot, hazard);
    }
    auto providerAncestorRoot = buildPath(root, "provider-ancestor");
    mkdir(providerAncestorRoot);
    auto providerAncestor = nestedPaths(providerAncestorRoot);
    expectFailure({ run(providerAncestor, true, "", "", false,
        "ancestor-symlink", "1", 'x', "", "chapter/page.txt"); });
    scope providerManifest = new LocalManifest(providerAncestor.db);
    require(providerManifest.lookup(key(contentSinkKey)).isNull &&
        providerManifest.lookup(key(metadataSinkKey)).isNull &&
        !exists(providerAncestor.contentFile),
        "provider-created ancestor alias planned or published output");
    foreach (uncertain; [false, true]) {
        auto unresolvedRoot = buildPath(root,
            uncertain ? "uncertain-owner" : "failed-owner");
        mkdir(unresolvedRoot);
        checkUnresolvedOwner(unresolvedRoot, uncertain);
    }
    auto historicalAliasRoot = buildPath(root, "historical-hardlink");
    mkdir(historicalAliasRoot);
    checkHistoricalHardlink(historicalAliasRoot);
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
