module exact_dedup.overlay_check;

import core.sys.posix.sys.stat : stat, stat_t;
import core.sys.posix.unistd : link;
import domain.document : OutputName, SourceLocator;
import domain.exact_dedup : ExactDocument, exactDuplicateLinks;
import domain.shard_format : AnnotationRecord, ShardDocument, encodeAnnotation;
import effects.document_shards : DocumentShardWriter, OverlayReader, PublishStep,
    JoinedOverlay, joinShards;
import effects.exact_dedup_overlay : DedupShard, dedupAnalyzerKey,
    dedupAnalyzerVersion, dedupPreflightInspections,
    resetDedupPreflightInspections, writeExactDedupOverlays;
import std.algorithm.sorting : sort;
import std.algorithm.searching : canFind;
import std.conv : to;
import std.digest.sha : sha256Of;
import std.exception : enforce;
import std.file : SpanMode, dirEntries, exists, mkdir, read, remove, rmdirRecurse,
    tempDir, write;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : toStringz;
import std.uuid : randomUUID;

private void need(bool okay, string reason) { enforce(okay, reason); }
private void rejects(scope void delegate() action) {
    bool failed;
    try action(); catch (Exception) failed = true;
    need(failed, "expected rejection");
}
private ulong inode(string path) {
    stat_t info;
    need(stat(path.toStringz, &info) == 0, "stat failed");
    return cast(ulong)info.st_ino;
}
private ubyte[32] collide(const(ubyte)[]) { return ubyte[32].init; }
private ubyte[] value(AnnotationRecord record, string key) {
    foreach (field; record.fields) if (field.key == key) return field.value;
    throw new Exception("missing field: " ~ key);
}
private void noScratch(string directory) {
    foreach (entry; dirEntries(directory, SpanMode.shallow))
        need(!entry.name.canFind(".exact-dedup-") &&
            !entry.name.canFind(".scrubbed-"), "scratch leaked");
}
private ShardDocument document(string source, string key, ubyte[] bytes) {
    return ShardDocument(SourceLocator("dedup-check", source, key),
        OutputName(key), bytes);
}
private void sourceFile(string path, ShardDocument[] documents) {
    documents.sort!((a, b) => a.id.text < b.id.text);
    auto writer = new DocumentShardWriter(path);
    foreach (record; documents) writer.append(record);
    writer.publish();
}

void main() {
    auto root = buildPath(tempDir(), "exact-dedup-check-" ~ randomUUID.toString);
    mkdir(root);
    scope(exit) rmdirRecurse(root);
    auto output = buildPath(root, "out");
    mkdir(output);
    ShardDocument[][3] records;
    // More than two 32-record runs in a single group exercises disk spooling
    // and a bounded-fan-in merge, even under a forced hash-index collision.
    foreach (i; 0 .. 300)
        records[i % 3] ~= document("s" ~ (i % 3).to!string,
            "equal-" ~ i.to!string, cast(ubyte[])"same\xff".dup);
    records[0] ~= document("s0", "different", cast(ubyte[])"different".dup);
    records[1] ~= document("s1", "empty", []);
    records[2] ~= document("s2", "unicode", cast(ubyte[])"caf\xc3\xa9".dup);
    DedupShard[] shards;
    ExactDocument[] pureInput;
    foreach (i; 0 .. 3) {
        auto source = buildPath(root, "source-" ~ i.to!string ~ ".shard");
        auto destination = buildPath(output, "dedup-" ~ i.to!string ~ ".overlay");
        sourceFile(source, records[i]);
        shards ~= DedupShard(source, destination);
        foreach (record; records[i]) pureInput ~= ExactDocument(record.id, record.content);
    }
    auto expectedLinks = exactDuplicateLinks(pureInput);
    need(expectedLinks.length == 303, "pure links count");
    foreach (i; 1 .. expectedLinks.length)
        need(expectedLinks[i - 1].documentId.text < expectedLinks[i].documentId.text,
            "pure API links are not strictly ascending");
    auto unrelated = buildPath(output, "unrelated.overlay");
    write(unrelated, cast(ubyte[])"untouched");
    auto unrelatedBytes = read(unrelated);
    auto unrelatedInode = inode(unrelated);
    ubyte[][] sourceBytes;
    ulong[] sourceInodes;
    foreach (shard; shards) {
        sourceBytes ~= cast(ubyte[])read(shard.source);
        sourceInodes ~= inode(shard.source);
    }

    writeExactDedupOverlays(shards, &collide);
    ubyte[][] baseline;
    ubyte[][string] canonicalLinks;
    foreach (i, shard; shards) {
        auto reader = new OverlayReader(shard.destination);
        scope(exit) reader.closeReader();
        need(reader.header.analyzerKey == dedupAnalyzerKey &&
            reader.header.analyzerVersion == dedupAnalyzerVersion &&
            reader.header.sourceShardDigest == sha256Of(sourceBytes[i]),
            "overlay header revision binding");
        AnnotationRecord annotation;
        string previous;
        size_t count;
        while (reader.next(annotation)) {
            need(previous.length == 0 || previous < annotation.documentId,
                "overlay order");
            previous = annotation.documentId;
            bool found;
            foreach (link; expectedLinks) if (link.documentId.text == annotation.documentId) {
                found = true;
                need(annotation.contentDigest == link.digest &&
                    value(annotation, "digest_sha256") == link.digest[] &&
                    value(annotation, "representative_id") ==
                        cast(const(ubyte)[])link.representativeId.text &&
                    value(annotation, "group_cardinality") ==
                        cast(const(ubyte)[])link.groupCardinality.to!string &&
                    value(annotation, "canonical_version") ==
                        cast(const(ubyte)[])link.canonicalVersion &&
                    value(annotation, "duplicate") ==
                        [cast(ubyte)link.duplicate], "overlay link disagrees with pure API");
                break;
            }
            need(found, "overlay orphan link");
            canonicalLinks[annotation.documentId] = encodeAnnotation(annotation);
            ++count;
        }
        need(count == records[i].length, "overlay record count");
        baseline ~= cast(ubyte[])read(shard.destination);
        joinShards(shard.source, [shard.destination],
            (ShardDocument source, JoinedOverlay[] overlays) {
                need(overlays.length == 1 && overlays[0].present,
                    "C01 join missing dedup annotation");
            });
    }
    DedupShard[] shuffled = [shards[2], shards[0], shards[1]];
    writeExactDedupOverlays(shuffled);
    foreach (i, shard; shards)
        need(read(shard.destination) == baseline[i], "restart/order changed overlay bytes");
    // Repartition identical logical records across a different worker/shard
    // layout: link values remain identical even though source digests differ.
    ShardDocument[][4] repartitioned;
    size_t ordinal;
    foreach (group; records)
        foreach (record; group) repartitioned[ordinal++ % 4] ~= record;
    DedupShard[] alternate;
    foreach (i; 0 .. 4) {
        auto source = buildPath(root, "worker-" ~ i.to!string ~ ".shard");
        auto destination = buildPath(output, "worker-" ~ i.to!string ~ ".overlay");
        sourceFile(source, repartitioned[i]);
        alternate ~= DedupShard(source, destination);
    }
    writeExactDedupOverlays(alternate, &collide);
    size_t matched;
    foreach (shard; alternate) {
        auto reader = new OverlayReader(shard.destination);
        scope(exit) reader.closeReader();
        AnnotationRecord record;
        while (reader.next(record)) {
            auto expected = record.documentId in canonicalLinks;
            need(expected !is null && *expected == encodeAnnotation(record),
                "worker repartition changed canonical link");
            ++matched;
        }
    }
    need(matched == canonicalLinks.length, "worker repartition lost link");

    foreach (step; [PublishStep.afterWrite, PublishStep.afterFsync,
            PublishStep.beforePublish]) {
        bool tripped;
        rejects({ writeExactDedupOverlays(shuffled, &collide,
            (PublishStep current) {
                if (!tripped && current == step) {
                    tripped = true;
                    throw new Exception("injected prepublish fault");
                }
            }); });
        need(tripped, "fault hook was not reached");
        foreach (i, shard; shards)
            need(read(shard.destination) == baseline[i], "fault changed prior overlay");
        noScratch(output);
    }
    // C01 is per-overlay atomic, not a three-shard transaction. A failure on
    // shard two may leave shard one published; restart converges all three.
    foreach (shard; shards) write(shard.destination, cast(ubyte[])"prior overlay");
    size_t publications;
    rejects({ writeExactDedupOverlays(shards, null, (PublishStep step) {
        if (step == PublishStep.beforePublish && ++publications == 2)
            throw new Exception("second overlay prepublish fault");
    }); });
    need(read(shards[0].destination) == baseline[0] &&
        read(shards[1].destination) == cast(ubyte[])"prior overlay" &&
        read(shards[2].destination) == cast(ubyte[])"prior overlay",
        "partial publication boundary");
    writeExactDedupOverlays(shards);
    foreach (i, shard; shards)
        need(read(shard.destination) == baseline[i], "partial restart did not converge");
    // Preflight all sources and all destinations, not just each paired source.
    DedupShard[] duplicateDest = [shards[0], DedupShard(shards[1].source,
        shards[0].destination)];
    rejects({ writeExactDedupOverlays(duplicateDest); });
    auto directAlias = [shards[0], DedupShard(shards[1].source, shards[0].source)];
    rejects({ writeExactDedupOverlays(directAlias); });
    auto crossAlias = buildPath(output, "cross-alias.overlay");
    need(link(shards[1].source.toStringz, crossAlias.toStringz) == 0,
        "hardlink alias fixture");
    rejects({ writeExactDedupOverlays([shards[0],
        DedupShard(shards[1].source, crossAlias)]); });
    remove(crossAlias);
    auto lateAlias = buildPath(output, "late-alias.overlay");
    bool planted;
    rejects({ writeExactDedupOverlays([DedupShard(shards[0].source, lateAlias),
        shards[1]], null, (PublishStep step) {
            if (!planted && step == PublishStep.beforePublish) {
                planted = true;
                need(link(shards[1].source.toStringz, lateAlias.toStringz) == 0,
                    "late alias fixture");
            }
        }); });
    need(planted && read(lateAlias) == sourceBytes[1],
        "callback alias refusal changed source");
    remove(lateAlias);
    // Same logical source in two shards must fail before any publication.
    auto repeated = buildPath(root, "repeated.shard");
    sourceFile(repeated, [records[0][0]]);
    auto repeatedOutput = buildPath(output, "repeated.overlay");
    rejects({ writeExactDedupOverlays([shards[0],
        DedupShard(repeated, repeatedOutput)]); });
    need(!exists(repeatedOutput), "duplicate ID published a new overlay");
    foreach (i, shard; shards)
        need(read(shard.source) == sourceBytes[i] &&
            inode(shard.source) == sourceInodes[i] &&
            read(shard.destination) == baseline[i], "source or overlay mutated");
    need(read(unrelated) == unrelatedBytes && inode(unrelated) == unrelatedInode,
        "unrelated overlay changed");
    // 48 empty shards isolate metadata/preflight work from document sorting.
    // A pairwise scan on every callback grows cubically and fails this bound.
    DedupShard[] many;
    foreach (i; 0 .. 48) {
        auto source = buildPath(root, "scale-source-" ~ i.to!string ~ ".shard");
        auto destination = buildPath(output, "scale-" ~ i.to!string ~ ".overlay");
        sourceFile(source, []);
        many ~= DedupShard(source, destination);
    }
    resetDedupPreflightInspections();
    writeExactDedupOverlays(many);
    need(dedupPreflightInspections() <= 15 * many.length,
        "preflight path inspections grew beyond linear per publication");
    noScratch(output);
    writeln("exact-dedup overlays: external group, forced collision, restart, faults, aliases: ok");
}
