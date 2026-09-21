module shards.check;

import core.thread : Thread;
import core.memory : GC;
import core.sys.posix.sys.stat : stat, stat_t;
import core.sys.posix.unistd : link;
import domain.document : OutputName, SourceLocator;
import domain.shard_format;
import effects.document_shards;
import std.algorithm.searching : canFind;
import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;
import std.exception : assertThrown;
import std.file : SpanMode, dirEntries, exists, getSize, mkdir, read, rmdirRecurse,
    symlink, tempDir, write;
import std.path : buildPath;
import std.stdio : writeln;
import std.uuid : randomUUID;
import std.string : toStringz;

private void check(bool okay, string reason) {
    if (!okay) throw new Exception(reason);
}

private string hex(const(ubyte)[] bytes) {
    return toHexString!(LetterCase.lower)(bytes).idup;
}

private ShardDocument document(string key = "r", ubyte[] content = [cast(ubyte)0xff, 0]) {
    return ShardDocument(SourceLocator("set", "source", key), OutputName("n"), content);
}

private AnnotationRecord annotation(ShardDocument source, ubyte[] value) {
    return AnnotationRecord(source.id.text, source.contentDigest,
        [AnnotationField("answer", value)]);
}

private void rejects(scope void delegate() action) {
    bool failed;
    try action(); catch (Exception) failed = true;
    check(failed, "expected rejection");
}

private ulong inode(string path) {
    stat_t info;
    check(stat(path.toStringz, &info) == 0, "stat failed");
    return cast(ulong)info.st_ino;
}

private size_t descriptorCount() {
    size_t count;
    foreach (_; dirEntries("/dev/fd", SpanMode.shallow)) ++count;
    return count;
}

private void noTemporaries(string root) {
    foreach (entry; dirEntries(root, SpanMode.shallow))
        check(!entry.name.canFind(".scrubbed-"), "temporary file leaked");
}

private void rejectDocumentFile(string root, string name, const(ubyte)[] bytes) {
    auto path = buildPath(root, name);
    write(path, bytes);
    rejects({
        auto reader = new DocumentShardReader(path);
        scope(exit) reader.closeReader();
        ShardDocument result;
        while (reader.next(result)) {}
    });
}

private void rejectOverlayFile(string root, string name, const(ubyte)[] bytes) {
    auto path = buildPath(root, name);
    write(path, bytes);
    rejects({
        auto reader = new OverlayReader(path);
        scope(exit) reader.closeReader();
        AnnotationRecord result;
        while (reader.next(result)) {}
    });
}

private void formatChecks(string root) {
    auto doc = document();
    auto payload = encodeDocument(doc);
    check(hex(payload) == "00037365740006736f7572636500017200016e00000002ff00",
        "document payload golden changed");
    check(decodeDocument(payload).id == doc.id && decodeDocument(payload).content == doc.content,
        "document payload roundtrip");
    auto record = annotation(doc, []);
    auto encoded = encodeAnnotation(record);
    check(decodeAnnotation(encoded).fields.length == 1 &&
        decodeAnnotation(encoded).fields[0].value.length == 0, "empty field lost");
    auto noFields = record;
    noFields.fields = [];
    check(decodeAnnotation(encodeAnnotation(noFields)).fields.length == 0,
        "absent field conflated with empty");
    auto fullDocument = documentMagic ~ frame(payload, maxDocumentPayload);
    auto header = OverlayHeader("analysis", "v1", sha256Of(fullDocument));
    auto headerBytes = encodeOverlayHeader(header);
    check(decodeOverlayHeader(headerBytes).analyzerKey == "analysis", "header roundtrip");
    foreach (index; [0, 8, 10, 20, 25, headerBytes.length - 1]) {
        auto broken = headerBytes.dup;
        broken[index] ^= 1;
        rejects({ decodeOverlayHeader(broken); });
    }
    auto truncated = payload[0 .. $ - 1];
    rejects({ decodeDocument(truncated); });
    auto trailing = payload ~ cast(ubyte)1;
    rejects({ decodeDocument(trailing); });
    auto invalidUtf8 = payload.dup;
    invalidUtf8[2] = 0xff;
    rejects({ decodeDocument(invalidUtf8); });
    auto invalidNfc = encodeDocument(ShardDocument(
        SourceLocator("set", "cafe\u0301", "r"), OutputName("n"), []));
    check(decodeDocument(invalidNfc).source.sourceKey == "caf\u00e9", "NFC normalization");
    auto nfdRaw = invalidNfc[0 .. 5].dup;
    nfdRaw ~= [cast(ubyte)0, 6];
    nfdRaw ~= cast(const(ubyte)[])"cafe\u0301";
    nfdRaw ~= invalidNfc[12 .. $];
    rejects({ decodeDocument(nfdRaw); });
    auto badId = record;
    badId.documentId = "child:v1:" ~ record.documentId[7 .. $];
    rejects({ encodeAnnotation(badId); });
    auto dupField = record;
    dupField.fields ~= record.fields[0];
    rejects({ encodeAnnotation(dupField); });
    auto longPayload = new ubyte[maxDocumentPayload + 1];
    rejects({ frame(longPayload, maxDocumentPayload); });
    check(hex(headerBytes ~ frame(encoded, maxAnnotationPayload)) ==
        "53435242414e4e31002e0008616e616c7973697300027631fe01ee7270ec6320d5e38a7c0c0058b53c6a974452e44150ac034fe23c34bb490234e56d99fa5214a1e09bd260563b7ab553d4d993ca082521dcc8822aece915000000770047646f633a76313a34363666623166643034363439323663343864333166376438333439336534363736623839316563366634323838303063363230613661393962373336363735ea5dbf9596d187e9500f23e9a680109475341cf4e81f7e043f7d97152c10772f00010006616e7377657200000000626d26a07271f4ba1ff6d25a554157aec63f92f9311bd3ca78aa7fd1360f498c",
        "overlay golden changed");
}

private void fileChecks(string root) {
    auto doc = document();
    auto docPath = buildPath(root, "documents.shard");
    auto writer = new DocumentShardWriter(docPath);
    writer.append(doc);
    writer.publish();
    auto sourceBytes = read(docPath);
    check(hex(cast(ubyte[])sourceBytes) ==
        "53435242444f43310000001900037365740006736f7572636500017200016e00000002ff00bf1112eadb65af3c6a39712bdb04c95043b1ca9b5cf55b077f5caedffa04eb9e",
        "document file golden changed");
    auto originalDigest = shardDigest(docPath);
    auto originalSize = getSize(docPath);
    auto originalInode = inode(docPath);
    auto steadyDescriptors = descriptorCount();
    rejects({ auto loser = new DocumentShardWriter(docPath); loser.append(doc); loser.publish(); });
    check(read(docPath) == sourceBytes && inode(docPath) == originalInode,
        "loser changed source bytes or inode");
    auto truncated = (cast(ubyte[])sourceBytes)[0 .. $ - 1];
    rejectDocumentFile(root, "truncated.shard", truncated);
    auto badHash = (cast(ubyte[])sourceBytes).dup;
    badHash[$ - 1] ^= 1;
    rejectDocumentFile(root, "bad-hash.shard", badHash);
    auto badMagic = (cast(ubyte[])sourceBytes).dup;
    badMagic[0] ^= 1;
    rejectDocumentFile(root, "bad-magic.shard", badMagic);
    auto oversized = (cast(ubyte[])sourceBytes).dup;
    oversized[8 .. 12] = [cast(ubyte)0xff, 0xff, 0xff, 0xff];
    rejectDocumentFile(root, "oversized.shard", oversized);
    rejectDocumentFile(root, "extra.shard", (cast(ubyte[])sourceBytes) ~ [cast(ubyte)1]);
    rejectDocumentFile(root, "duplicate.shard", (cast(ubyte[])sourceBytes) ~
        (cast(ubyte[])sourceBytes)[8 .. $]);
    auto aPath = buildPath(root, "a.overlay");
    auto bPath = buildPath(root, "b.overlay");
    auto a = new OverlayWriter(aPath, docPath, "a", "1");
    a.append(annotation(doc, [cast(ubyte)1]));
    a.publish();
    check(descriptorCount() == steadyDescriptors, "overlay publish leaked source descriptor");
    auto b = new OverlayWriter(bPath, docPath, "b", "1");
    b.publish();
    check(descriptorCount() == steadyDescriptors, "empty overlay leaked source descriptor");
    auto bBytes = read(bPath);
    auto corruptHeader = (cast(ubyte[])read(aPath)).dup;
    corruptHeader[13] ^= 1;
    rejectOverlayFile(root, "bad-header.overlay", corruptHeader);
    auto corruptFrame = (cast(ubyte[])read(aPath)).dup;
    corruptFrame[$ - 1] ^= 1;
    rejectOverlayFile(root, "bad-frame.overlay", corruptFrame);
    rejectOverlayFile(root, "truncated.overlay", corruptFrame[0 .. $ - 1]);
    rejectOverlayFile(root, "extra.overlay", (cast(ubyte[])read(aPath)) ~ [cast(ubyte)1]);
    string[] tooMany;
    foreach (_; 0 .. maxOverlayFanIn + 1) tooMany ~= aPath;
    rejects({ joinShards(docPath, tooMany,
        (ShardDocument d, JoinedOverlay[] o) {}); });
    foreach (chunkSize; [cast(size_t)1, 3, 7, 64 * 1024]) {
        auto docs = new DocumentShardReader(docPath, chunkSize);
        ShardDocument observed;
        check(docs.next(observed) && observed.id == doc.id && !docs.next(observed),
            "document read chunk changed result");
        docs.closeReader();
        auto overlay = new OverlayReader(aPath, chunkSize);
        AnnotationRecord result;
        check(overlay.next(result) && result.documentId == doc.id.text &&
            !overlay.next(result), "overlay read chunk changed result");
        overlay.closeReader();
    }
    GC.collect();
    auto fdBefore = descriptorCount();
    auto heapBefore = GC.stats().usedSize;
    foreach (_; 0 .. 200)
        joinShards(docPath, [aPath, bPath],
            (ShardDocument d, JoinedOverlay[] o) {});
    GC.collect();
    check(descriptorCount() == fdBefore, "join leaked descriptors");
    check(GC.stats().usedSize <= heapBefore + 16 * 1024 * 1024,
        "join retained unbounded allocations");
    size_t visited;
    joinShards(docPath, [aPath, bPath], (ShardDocument d, JoinedOverlay[] overlays) {
        ++visited;
        check(d.id == doc.id && overlays.length == 2 && overlays[0].present &&
            !overlays[1].present, "two-overlay join/missing policy");
    });
    check(visited == 1, "join count");
    auto prior = read(aPath);
    foreach (point; [PublishStep.afterWrite, PublishStep.afterFsync,
            PublishStep.beforePublish]) {
        auto replacement = new OverlayWriter(aPath, docPath, "a", "1");
        replacement.append(annotation(doc, [cast(ubyte)2]));
        rejects({ replacement.publish((PublishStep current) {
            if (current == point) throw new Exception("injected failure");
        }); });
        replacement.abort();
        check(read(aPath) == prior, "fault replaced prior overlay");
        check(descriptorCount() == steadyDescriptors, "fault leaked descriptors");
    }
    auto replacement = new OverlayWriter(aPath, docPath, "a", "1");
    replacement.append(annotation(doc, [cast(ubyte)3]));
    replacement.publish();
    check(shardDigest(docPath) == originalDigest && getSize(docPath) == originalSize &&
        inode(docPath) == originalInode && read(docPath) == sourceBytes && read(bPath) == bBytes,
        "analyzer rerun changed source or other overlay");
    auto wrong = buildPath(root, "wrong.overlay");
    write(wrong, encodeOverlayHeader(OverlayHeader("wrong", "1", ubyte[32].init)));
    rejects({ joinShards(docPath, [wrong], (ShardDocument d, JoinedOverlay[] o) {}); });
    rejects({ joinShards(docPath, [aPath, aPath],
        (ShardDocument d, JoinedOverlay[] o) {}); });
    auto versionPath = buildPath(root, "other-version.overlay");
    auto versionWriter = new OverlayWriter(versionPath, docPath, "a", "2");
    versionWriter.publish();
    rejects({ joinShards(docPath, [aPath, versionPath],
        (ShardDocument d, JoinedOverlay[] o) {}); });
    auto stalePath = buildPath(root, "stale.overlay");
    auto staleWriter = new OverlayWriter(stalePath, docPath, "stale", "1");
    auto stale = annotation(doc, []);
    stale.contentDigest[0] ^= 1;
    staleWriter.append(stale);
    staleWriter.publish();
    rejects({ joinShards(docPath, [stalePath],
        (ShardDocument d, JoinedOverlay[] o) {}); });
    auto orphanPath = buildPath(root, "orphan.overlay");
    auto orphanWriter = new OverlayWriter(orphanPath, docPath, "orphan", "1");
    orphanWriter.append(annotation(document("absent"), []));
    orphanWriter.publish();
    rejects({ joinShards(docPath, [orphanPath],
        (ShardDocument d, JoinedOverlay[] o) {}); });
    auto damaged = cast(ubyte[])read(aPath);
    damaged[$ - 1] ^= 1;
    write(aPath, damaged);
    rejects({ joinShards(docPath, [aPath], (ShardDocument d, JoinedOverlay[] o) {}); });
    auto linked = buildPath(root, "linked.overlay");
    symlink(docPath, linked);
    auto unsafe = new OverlayWriter(linked, docPath, "a", "1");
    rejects({ unsafe.publish(); });
    unsafe.abort();
    auto aliasPath = buildPath(root, "alias.overlay");
    check(link(aPath.toStringz, aliasPath.toStringz) == 0, "hardlink setup failed");
    auto aliasBytes = read(aliasPath);
    auto hardlinked = new OverlayWriter(aliasPath, docPath, "a", "1");
    rejects({ hardlinked.publish(); });
    hardlinked.abort();
    check(read(aliasPath) == aliasBytes && read(aPath) == aliasBytes,
        "hardlink rejection changed target");
    auto shardLink = buildPath(root, "source-link.shard");
    symlink(docPath, shardLink);
    auto sourceUnsafe = new DocumentShardWriter(shardLink);
    rejects({ sourceUnsafe.publish(); });
    sourceUnsafe.abort();
    noTemporaries(root);
}

private void concurrentChecks(string root) {
    auto path = buildPath(root, "race.shard");
    auto one = new DocumentShardWriter(path);
    auto two = new DocumentShardWriter(path);
    one.append(document("one"));
    two.append(document("two"));
    bool first, second;
    auto a = new Thread({ try { one.publish(); first = true; } catch (Exception) {} });
    auto b = new Thread({ try { two.publish(); second = true; } catch (Exception) {} });
    a.start(); b.start(); a.join(); b.join();
    check(first != second, "create-only race had wrong winner count");
    auto bytes = read(path);
    auto reader = new DocumentShardReader(path);
    ShardDocument winner;
    check(reader.next(winner) && !reader.next(winner), "race output invalid");
    reader.closeReader();
    check(read(path) == bytes, "loser changed winner bytes");
    one.abort(); two.abort();
    noTemporaries(root);
}

void main() {
    auto root = buildPath(tempDir(), "scrubbed-shards-" ~ randomUUID.toString);
    mkdir(root);
    scope(exit) rmdirRecurse(root);
    formatChecks(root);
    fileChecks(root);
    concurrentChecks(root);
    writeln("shard checks passed");
}
