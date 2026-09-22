module pii_patterns.overlay_check;

import core.sys.posix.sys.stat : stat, stat_t;
import core.sys.posix.unistd : link;
import domain.document : OutputName, SourceLocator;
import domain.pii_patterns;
import domain.shard_format : AnnotationField, AnnotationRecord, ShardDocument,
    encodeDocument;
import effects.document_shards : DocumentShardWriter, OverlayReader, OverlayWriter,
    PublishStep, shardDigest;
import effects.pii_overlay;
import std.algorithm.sorting : sort;
import std.algorithm.searching : canFind;
import std.digest.sha : sha256Of;
import std.digest : LetterCase, toHexString;
import std.file : SpanMode, dirEntries, mkdir, read, rmdirRecurse, tempDir;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : toStringz;
import std.uuid : randomUUID;

private void check(bool okay, string reason) {
    if (!okay) throw new Exception(reason);
}

private string hex(const(ubyte)[] bytes) {
    return toHexString!(LetterCase.lower)(bytes).idup;
}

private void rejects(scope void delegate() action) {
    bool rejected;
    try action(); catch (Exception error) {
        rejected = true;
        foreach (canary; ["secret@example.net", "4111 1111 1111 1111",
                "202-555-0142", "192.0.2.9"])
            check(!error.msg.canFind(canary), "diagnostic leaked content");
    }
    check(rejected, "expected rejection");
}

private ShardDocument[] heldOut() {
    // New synthetic overlay-only corpus; train examples intentionally absent.
    auto docs = [
        ShardDocument(SourceLocator("pii-overlay-v1", "heldout", "mixed"),
            OutputName("mixed"), cast(ubyte[])"é secret@example.net; +1-202-555-0142; 4111 1111 1111 1111; 192.0.2.9".dup),
        ShardDocument(SourceLocator("pii-overlay-v1", "heldout", "overlap"),
            OutputName("overlap"), cast(ubyte[])"202-555-0142@example.net".dup),
        ShardDocument(SourceLocator("pii-overlay-v1", "heldout", "plain"),
            OutputName("plain"), cast(ubyte[])"nothing private".dup),
    ];
    docs.sort!((a, b) => a.id.text < b.id.text);
    return docs;
}

private stat_t info(string path) {
    stat_t value;
    check(stat(path.toStringz, &value) == 0, "cannot stat fixture");
    return value;
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

private void run() {
    auto root = buildPath(tempDir(), "scrubbed-pii-overlay-" ~ randomUUID.toString);
    mkdir(root);
    scope(exit) rmdirRecurse(root);
    auto sourcePath = buildPath(root, "source.shard");
    auto overlayPath = buildPath(root, "pii.overlay");
    auto otherPath = buildPath(root, "other.overlay");
    auto documents = heldOut();
    ubyte[] authored;
    auto sourceWriter = new DocumentShardWriter(sourcePath);
    foreach (doc; documents) {
        authored ~= encodeDocument(doc);
        sourceWriter.append(doc);
    }
    sourceWriter.publish();
    // Frozen SHA makes the independently authored held-out split explicit.
    check(hex(sha256Of(authored)[]) ==
        "3908aac7dbe24ad6db53e0bf65b69e1c07aac6ee4648bf2fd8cc424f1ada25f8",
        "fixture SHA changed");
    auto sourceBytes = cast(ubyte[])read(sourcePath);
    auto sourceDigest = shardDigest(sourcePath);
    auto sourceInfo = info(sourcePath);
    auto steadyDescriptors = descriptorCount();
    auto otherWriter = new OverlayWriter(otherPath, sourcePath, "unrelated", "v1");
    foreach (doc; documents)
        otherWriter.append(AnnotationRecord(doc.id.text, doc.contentDigest,
            [AnnotationField("note", [cast(ubyte)1])]));
    otherWriter.publish();
    auto otherBytes = cast(ubyte[])read(otherPath);
    auto otherInfo = info(otherPath);

    publishPiiFindings(sourcePath, overlayPath, "US");
    check(descriptorCount() == steadyDescriptors, "publish leaked descriptors");
    auto first = cast(ubyte[])read(overlayPath);
    auto reader = new OverlayReader(overlayPath);
    check(reader.header.analyzerKey == piiAnalyzerKey &&
        reader.header.analyzerVersion == piiAnalyzerVersion("US"), "header identity");
    AnnotationRecord record;
    check(reader.next(record), "missing first annotation");
    check(hex(record.fields[0].value) ==
        "50494931010002000000000000000c02000000000000001801",
        "value encoding golden");
    reader.closeReader();
    size_t visited;
    visitPiiFindings(sourcePath, overlayPath, "US", (string id, PiiFinding[] findings) {
        check(id == documents[visited].id.text, "replay identity");
        auto expected = scanPii(documents[visited].content, "US");
        check(findings == expected, "ordered typed findings or Unicode byte span");
        ++visited;
    });
    check(visited == documents.length, "missing replay document");
    check(descriptorCount() == steadyDescriptors, "replay leaked descriptors");
    publishPiiFindings(sourcePath, overlayPath, "US");
    check(cast(ubyte[])read(overlayPath) == first, "nondeterministic rerun");
    foreach (canary; ["secret@example.net", "4111 1111 1111 1111",
            "202-555-0142", "192.0.2.9"])
        check(!(cast(string)first).canFind(canary), "overlay leaked raw finding");
    rejects({ visitPiiFindings(sourcePath, overlayPath, "GB",
        (string id, PiiFinding[] findings) {}); });
    rejects({ publishPiiFindings(sourcePath, overlayPath, "FR"); });
    foreach (step; [PublishStep.afterWrite, PublishStep.afterFsync,
            PublishStep.beforePublish]) {
        rejects({ publishPiiFindings(sourcePath, overlayPath, "US",
            (PublishStep hit) { if (hit == step) throw new Exception("fault"); }); });
        check(cast(ubyte[])read(overlayPath) == first, "fault replaced prior overlay");
        check(descriptorCount() == steadyDescriptors, "fault leaked descriptors");
        noTemporaries(root);
    }
    check(cast(ubyte[])read(sourcePath) == sourceBytes &&
        shardDigest(sourcePath) == sourceDigest &&
        info(sourcePath).st_ino == sourceInfo.st_ino &&
        cast(ubyte[])read(otherPath) == otherBytes &&
        info(otherPath).st_ino == otherInfo.st_ino, "unrelated or source mutation");
    rejects({ publishPiiFindings(sourcePath, sourcePath, "US"); });
    rejects({ publishPiiFindings(sourcePath, root ~ "/./source.shard", "US"); });
    auto aliasPath = buildPath(root, "source-hardlink.shard");
    check(link(sourcePath.toStringz, aliasPath.toStringz) == 0, "cannot link fixture");
    rejects({ publishPiiFindings(sourcePath, aliasPath, "US"); });
    check(cast(ubyte[])read(sourcePath) == sourceBytes, "source alias mutation");

    auto malformed = record.fields[0].value.dup;
    malformed[$ - 1] = 0xff;
    rejects({ decodePiiFindings(malformed, "US", documents[0].content.length); });
    rejects({ decodePiiFindings(record.fields[0].value[0 .. $ - 1], "US",
        documents[0].content.length); });
    rejects({ decodePiiFindings(record.fields[0].value, "GB",
        documents[0].content.length); });
    PiiFinding[] maximum;
    foreach (index; 0 .. maxPiiFindings)
        maximum ~= PiiFinding(index, index + 1, PiiCategory.email,
            "email.ascii-domain.v1", "US", PiiConfidence.high);
    auto full = encodePiiFindings(maximum, "US", maxPiiFindings);
    check(decodePiiFindings(full, "US", maxPiiFindings) == maximum,
        "maximum bounded finding count");
    maximum ~= PiiFinding(maxPiiFindings, maxPiiFindings + 1,
        PiiCategory.email, "email.ascii-domain.v1", "US", PiiConfidence.high);
    rejects({ encodePiiFindings(maximum, "US", maxPiiFindings + 1); });
    auto reversed = record.fields[0].value.dup;
    reversed[7 .. 16] = record.fields[0].value[16 .. 25];
    reversed[16 .. 25] = record.fields[0].value[7 .. 16];
    rejects({ decodePiiFindings(reversed, "US", documents[0].content.length); });
    auto stalePath = buildPath(root, "stale.overlay");
    auto staleWriter = new OverlayWriter(stalePath, sourcePath,
        piiAnalyzerKey, piiAnalyzerVersion("US"));
    foreach (doc; documents) {
        auto digest = doc.contentDigest;
        digest[0] ^= 1;
        staleWriter.append(AnnotationRecord(doc.id.text, digest,
            [AnnotationField(piiFieldKey,
                encodePiiFindings(scanPii(doc.content, "US"), "US", doc.content.length))]));
    }
    staleWriter.publish();
    rejects({ visitPiiFindings(sourcePath, stalePath, "US",
        (string id, PiiFinding[] findings) {}); });
    auto wrongVersionPath = buildPath(root, "wrong-version.overlay");
    auto wrongVersionWriter = new OverlayWriter(wrongVersionPath, sourcePath,
        piiAnalyzerKey, "four-class:v2:locale=US");
    wrongVersionWriter.publish();
    rejects({ visitPiiFindings(sourcePath, wrongVersionPath, "US",
        (string id, PiiFinding[] findings) {}); });
    auto invalidPath = buildPath(root, "invalid.shard");
    auto invalidWriter = new DocumentShardWriter(invalidPath);
    invalidWriter.append(ShardDocument(SourceLocator("pii-overlay-v1", "bad", "utf8"),
        OutputName("bad"), [cast(ubyte)0xc0, 0x80]));
    invalidWriter.publish();
    rejects({ publishPiiFindings(invalidPath, overlayPath, "US"); });
    check(cast(ubyte[])read(overlayPath) == first, "scan failure replaced overlay");
    noTemporaries(root);
    auto cappedPath = buildPath(root, "capped.shard");
    auto cappedWriter = new DocumentShardWriter(cappedPath);
    ubyte[] repeated;
    foreach (_; 0 .. maxPiiFindings + 1) repeated ~= cast(ubyte[])"192.0.2.9;";
    cappedWriter.append(ShardDocument(SourceLocator("pii-overlay-v1", "bad", "cap"),
        OutputName("cap"), repeated));
    cappedWriter.publish();
    rejects({ publishPiiFindings(cappedPath, overlayPath, "US"); });
    check(cast(ubyte[])read(overlayPath) == first, "cap failure replaced overlay");
    noTemporaries(root);

    auto emptyPath = buildPath(root, "empty.shard");
    auto emptyWriter = new DocumentShardWriter(emptyPath);
    emptyWriter.publish();
    auto emptyOverlay = buildPath(root, "empty.overlay");
    publishPiiFindings(emptyPath, emptyOverlay, "GB");
    rejects({ visitPiiFindings(emptyPath, emptyOverlay, "US",
        (string id, PiiFinding[] findings) {}); });
    rejects({ visitPiiFindings(emptyPath, overlayPath, "US",
        (string id, PiiFinding[] findings) {}); });
    auto gbPath = buildPath(root, "gb.shard");
    auto gbWriter = new DocumentShardWriter(gbPath);
    auto gbDoc = ShardDocument(SourceLocator("pii-overlay-v1", "heldout", "gb"),
        OutputName("gb"), cast(ubyte[])"é +44 20 7946 0958; 020 7946 0958".dup);
    gbWriter.append(gbDoc);
    gbWriter.publish();
    auto gbOverlay = buildPath(root, "gb.overlay");
    publishPiiFindings(gbPath, gbOverlay, "GB");
    size_t gbCount;
    visitPiiFindings(gbPath, gbOverlay, "GB", (string id, PiiFinding[] findings) {
        check(id == gbDoc.id.text && findings.length == 2 &&
            findings[0].start == 3 && findings[0].confidence == PiiConfidence.high &&
            findings[1].confidence == PiiConfidence.ambiguous,
            "GB locale binding or Unicode span");
        ++gbCount;
    });
    check(gbCount == 1, "GB record missing");
    check(descriptorCount() == steadyDescriptors, "empty shard leaked descriptors");
    writeln("PII overlay checks passed");
}

void main() { run(); }
