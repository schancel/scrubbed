module pii_policy.overlay_check;

import core.sys.posix.sys.stat : stat, stat_t;
import core.sys.posix.unistd : link;
import domain.document : OutputName, SourceLocator;
import domain.pii_patterns : PiiFinding, PiiCategory, PiiConfidence,
    maxPiiFindings, scanPii;
import domain.pii_policy : PiiPolicy, PiiPolicyResult, applyPiiPolicy;
import domain.shard_format : AnnotationField, AnnotationRecord, ShardDocument;
import effects.document_shards : DocumentShardWriter, OverlayReader,
    OverlayWriter, PublishStep;
import effects.pii_overlay : encodePiiFindings, piiAnalyzerKey,
    piiAnalyzerVersion, piiFieldKey, publishPiiFindings;
import effects.pii_policy_overlay;
import std.algorithm.sorting : sort;
import std.algorithm.searching : canFind;
import std.digest.sha : sha256Of;
import std.digest : LetterCase, toHexString;
import std.file : SpanMode, dirEntries, mkdir, read, rmdirRecurse, symlink, tempDir;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : toStringz;
import std.uuid : randomUUID;

private size_t assertions;
private void check(bool okay, string reason) {
    ++assertions;
    if (!okay) throw new Exception(reason);
}
private void rejects(scope void delegate() action) {
    bool failed;
    try action(); catch (Exception error) {
        failed = true;
        foreach (canary; ["secret@example.net", "4111 1111 1111 1111",
                "202-555-0142", "192.0.2.9"])
            check(!error.msg.canFind(canary), "exception leaked content");
    }
    check(failed, "expected refusal");
}
private stat_t info(string path) {
    stat_t value;
    check(stat(path.toStringz, &value) == 0, "stat fixture");
    return value;
}
private size_t descriptors() {
    size_t n;
    foreach (_; dirEntries("/dev/fd", SpanMode.shallow)) ++n;
    return n;
}
private void valueGoldens() {
    auto plain = applyPiiPolicy(cast(ubyte[])"plain text",
        [], PiiPolicy.report);
    check(toHexString!(LetterCase.lower)(
        encodePiiPolicyValue(plain, "US")).idup ==
        "504950310101c9ecf5e54c7b3f2640ecca21f96d4c3625a2b7935104f41c5ede29935a9e52c90000",
        "empty-audit byte golden");
    auto source = cast(ubyte[])"secret@example.net";
    auto finding = PiiFinding(0, source.length, PiiCategory.email,
        "email.ascii-domain.v1", "US", PiiConfidence.high);
    auto result = applyPiiPolicy(source, [finding], PiiPolicy.report);
    auto encoded = encodePiiPolicyValue(result, "US");
    check(toHexString!(LetterCase.lower)(encoded).idup ==
        "504950310101bf36acee076710ea5e88bc7f3dbd5121e5a40a214ef77e3d95c041efaf8b3a78000100000000000000120001000000000000001201",
        "typed-audit byte golden");
    auto decoded = decodePiiPolicyValue(encoded);
    check(decoded.audit == result.audit &&
        decoded.outputDigest == sha256Of(result.output),
        "golden typed audit round-trip");
}
private void noTemps(string root) {
    foreach (entry; dirEntries(root, SpanMode.shallow))
        check(!entry.name.canFind(".scrubbed-"), "leaked temporary file");
}
private ShardDocument[] corpus() {
    auto docs = [
        ShardDocument(SourceLocator("pii-policy-overlay", "held", "mixed"),
            OutputName("mixed"), cast(ubyte[])"é secret@example.net +1-202-555-0142 4111 1111 1111 1111 192.0.2.9".dup),
        ShardDocument(SourceLocator("pii-policy-overlay", "held", "overlap"),
            OutputName("overlap"), cast(ubyte[])"202-555-0142@example.net".dup),
        ShardDocument(SourceLocator("pii-policy-overlay", "held", "plain"),
            OutputName("plain"), cast(ubyte[])"plain text".dup),
    ];
    docs.sort!((a, b) => a.id.text < b.id.text);
    return docs;
}

private void run() {
    valueGoldens();
    auto root = buildPath(tempDir(), "scrubbed-pii-policy-overlay-" ~ randomUUID.toString);
    mkdir(root);
    scope(exit) rmdirRecurse(root);
    auto source = buildPath(root, "source.shard");
    auto findings = buildPath(root, "findings.overlay");
    auto policyFile = buildPath(root, "policy.overlay");
    auto unrelated = buildPath(root, "unrelated.overlay");
    auto docs = corpus();
    auto writer = new DocumentShardWriter(source);
    foreach (doc; docs) writer.append(doc);
    writer.publish();
    publishPiiFindings(source, findings, "US");
    auto other = new OverlayWriter(unrelated, source, "unrelated", "v1");
    foreach (doc; docs) other.append(AnnotationRecord(doc.id.text,
        doc.contentDigest, [AnnotationField("note", [cast(ubyte)1])]));
    other.publish();
    auto sourceBytes = cast(ubyte[])read(source);
    auto findingsBytes = cast(ubyte[])read(findings);
    auto otherBytes = cast(ubyte[])read(unrelated);
    auto sourceInode = info(source).st_ino;
    auto findingsInode = info(findings).st_ino;
    auto otherInode = info(unrelated).st_ino;
    auto steadyFd = descriptors();

    foreach (policy; [PiiPolicy.report, PiiPolicy.mask, PiiPolicy.redact]) {
        auto target = buildPath(root, "policy-" ~
            (policy == PiiPolicy.report ? "report" :
             policy == PiiPolicy.mask ? "mask" : "redact") ~ ".overlay");
        if (policy == PiiPolicy.redact)
            rejects({ publishPiiPolicy(source, findings, target, "US", policy); });
        publishPiiPolicy(source, findings, target, "US", policy,
            policy == PiiPolicy.redact);
        auto bytes = cast(ubyte[])read(target);
        check(!(cast(string)bytes).canFind("secret@example.net") &&
            !(cast(string)bytes).canFind("[REDACTED]") &&
            !(cast(string)bytes).canFind("********"), "policy bytes leaked payload");
        auto reader = new OverlayReader(target);
        check(reader.header.analyzerKey == piiPolicyAnalyzerKey &&
            reader.header.analyzerVersion == piiPolicyAnalyzerVersion("US", policy),
            "header identity");
        AnnotationRecord first;
        check(reader.next(first) && first.fields.length == 1 &&
            first.fields[0].key == piiPolicyFieldKey, "canonical record field");
        auto value = decodePiiPolicyValue(first.fields[0].value);
        check(value.policy == policy && value.audit.length ==
            applyPiiPolicy(docs[0].content, scanPii(docs[0].content, "US"),
                policy, policy == PiiPolicy.redact).audit.length,
            "typed audit persisted");
        reader.closeReader();
        size_t seen;
        visitPiiPolicy(source, findings, target, "US", policy,
            policy == PiiPolicy.redact, (string id, PiiPolicyResult result) {
                check(id == docs[seen].id.text &&
                    result == applyPiiPolicy(docs[seen].content,
                        scanPii(docs[seen].content, "US"), policy,
                        policy == PiiPolicy.redact), "policy replay result");
                ++seen;
            });
        check(seen == docs.length, "missing replay documents");
        if (policy == PiiPolicy.redact)
            rejects({ visitPiiPolicy(source, findings, target, "US", policy,
                false, (string id, PiiPolicyResult result) {}); });
        rejects({ visitPiiPolicy(source, findings, target, "GB", policy,
            true, (string id, PiiPolicyResult result) {}); });
        publishPiiPolicy(source, findings, target, "US", policy,
            policy == PiiPolicy.redact);
        check(cast(ubyte[])read(target) == bytes, "nondeterministic publish");
        check(descriptors() == steadyFd, "descriptor leak");
    }

    publishPiiPolicy(source, findings, policyFile, "US", PiiPolicy.mask);
    auto prior = cast(ubyte[])read(policyFile);
    auto priorInode = info(policyFile).st_ino;
    foreach (step; [PublishStep.afterWrite, PublishStep.afterFsync,
            PublishStep.beforePublish]) {
        rejects({ publishPiiPolicy(source, findings, policyFile, "US",
            PiiPolicy.mask, false, (PublishStep current) {
                if (current == step) throw new Exception("fault");
            }); });
        check(cast(ubyte[])read(policyFile) == prior &&
            info(policyFile).st_ino == priorInode, "fault altered old policy");
        noTemps(root);
    }
    rejects({ publishPiiPolicy(source, findings, policyFile, "US",
        PiiPolicy.report); });
    rejects({ publishPiiPolicy(source, findings, unrelated, "US",
        PiiPolicy.mask); });
    rejects({ publishPiiPolicy(source, findings, source, "US", PiiPolicy.mask); });
    rejects({ publishPiiPolicy(source, findings, findings, "US", PiiPolicy.mask); });
    auto aliasPath = buildPath(root, "findings-hardlink.overlay");
    check(link(findings.toStringz, aliasPath.toStringz) == 0, "hardlink fixture");
    rejects({ publishPiiPolicy(source, findings, aliasPath, "US", PiiPolicy.mask); });
    auto symlinkPath = buildPath(root, "policy-symlink.overlay");
    symlink(source, symlinkPath);
    rejects({ publishPiiPolicy(source, findings, symlinkPath, "US", PiiPolicy.mask); });
    check(cast(ubyte[])read(source) == sourceBytes &&
        cast(ubyte[])read(findings) == findingsBytes &&
        cast(ubyte[])read(unrelated) == otherBytes &&
        info(source).st_ino == sourceInode &&
        info(findings).st_ino == findingsInode &&
        info(unrelated).st_ino == otherInode, "unrelated input mutated");
    noTemps(root);

    auto invalid = buildPath(root, "invalid-findings.overlay");
    auto forged = new OverlayWriter(invalid, source,
        piiAnalyzerKey, piiAnalyzerVersion("US"));
    foreach (doc; docs) forged.append(AnnotationRecord(doc.id.text,
        doc.contentDigest, [AnnotationField(piiFieldKey, [cast(ubyte)0])]));
    forged.publish();
    rejects({ publishPiiPolicy(source, invalid, policyFile, "US", PiiPolicy.mask); });
    check(cast(ubyte[])read(policyFile) == prior &&
        info(policyFile).st_ino == priorInode, "corruption altered destination");
    auto wrong = buildPath(root, "wrong-findings.overlay");
    auto wrongWriter = new OverlayWriter(wrong, source,
        piiAnalyzerKey, "four-class:v2:locale=US");
    wrongWriter.publish();
    rejects({ publishPiiPolicy(source, wrong, policyFile, "US", PiiPolicy.mask); });

    foreach (kind; 0 .. 3) {
        auto malformedPath = buildPath(root,
            "shape-" ~ randomUUID.toString ~ ".overlay");
        AnnotationRecord[] records;
        foreach (index, doc; docs) {
            if (kind == 0 && index == 0) continue; // missing document
            auto digest = doc.contentDigest;
            if (kind == 1 && index == 0) digest[0] ^= 1; // stale revision
            records ~= AnnotationRecord(doc.id.text, digest,
                [AnnotationField(piiFieldKey,
                    encodePiiFindings(scanPii(doc.content, "US"), "US",
                        doc.content.length))]);
        }
        if (kind == 2) {
            auto orphan = ShardDocument(SourceLocator("pii-policy-overlay",
                "orphan", "not-in-source"), OutputName("orphan"),
                cast(ubyte[])"orphan".dup);
            records ~= AnnotationRecord(orphan.id.text, orphan.contentDigest,
                [AnnotationField(piiFieldKey,
                    encodePiiFindings([], "US", orphan.content.length))]);
        }
        records.sort!((a, b) => a.documentId < b.documentId);
        auto shapeWriter = new OverlayWriter(malformedPath, source,
            piiAnalyzerKey, piiAnalyzerVersion("US"));
        foreach (record; records) shapeWriter.append(record);
        shapeWriter.publish();
        rejects({ publishPiiPolicy(source, malformedPath, policyFile, "US",
            PiiPolicy.mask); });
        check(cast(ubyte[])read(policyFile) == prior &&
            info(policyFile).st_ino == priorInode,
            "bad findings altered destination");
    }

    foreach (kind; 0 .. 3) {
        auto tampered = buildPath(root, "tampered-" ~ randomUUID.toString ~ ".overlay");
        auto forgedPolicy = new OverlayWriter(tampered, source,
            piiPolicyAnalyzerKey, piiPolicyAnalyzerVersion("US", PiiPolicy.mask));
        foreach (index, doc; docs) {
            auto expected = applyPiiPolicy(doc.content, scanPii(doc.content, "US"),
                PiiPolicy.mask);
            auto encoded = encodePiiPolicyValue(expected, "US");
            if (index == 0) {
                if (kind == 0) encoded[6] ^= 1; // output digest
                if (kind == 1) encoded[4] = 1; // policy code
                if (kind == 2) encoded[$ - 1] ^= 1; // audit rule/count tail
            }
            forgedPolicy.append(AnnotationRecord(doc.id.text, doc.contentDigest,
                [AnnotationField(piiPolicyFieldKey, encoded)]));
        }
        forgedPolicy.publish();
        rejects({ visitPiiPolicy(source, findings, tampered, "US", PiiPolicy.mask,
            false, (string id, PiiPolicyResult result) {}); });
    }

    auto empty = buildPath(root, "empty.shard");
    auto emptyWriter = new DocumentShardWriter(empty);
    emptyWriter.publish();
    auto emptyFindings = buildPath(root, "empty-findings.overlay");
    publishPiiFindings(empty, emptyFindings, "GB");
    auto emptyPolicy = buildPath(root, "empty-policy.overlay");
    publishPiiPolicy(empty, emptyFindings, emptyPolicy, "GB", PiiPolicy.report);
    rejects({ publishPiiPolicy(empty, emptyFindings, emptyPolicy, "US",
        PiiPolicy.report); });
    rejects({ visitPiiPolicy(empty, emptyFindings, emptyPolicy, "US",
        PiiPolicy.report, false, (string id, PiiPolicyResult result) {}); });

    auto capped = buildPath(root, "capped.shard");
    auto cappedWriter = new DocumentShardWriter(capped);
    ubyte[] many;
    foreach (_; 0 .. maxPiiFindings) many ~= cast(ubyte[])"192.0.2.9;";
    auto capDoc = ShardDocument(SourceLocator("pii-policy-overlay", "cap", "many"),
        OutputName("many"), many);
    cappedWriter.append(capDoc);
    cappedWriter.publish();
    auto cappedFindings = buildPath(root, "capped-findings.overlay");
    publishPiiFindings(capped, cappedFindings, "US");
    auto cappedPolicy = buildPath(root, "capped-policy.overlay");
    auto cappedPrior = new OverlayWriter(cappedPolicy, capped,
        piiPolicyAnalyzerKey, piiPolicyAnalyzerVersion("US", PiiPolicy.report));
    cappedPrior.publish();
    auto cappedPriorBytes = cast(ubyte[])read(cappedPolicy);
    auto cappedPriorInode = info(cappedPolicy).st_ino;
    rejects({ publishPiiPolicy(capped, cappedFindings, cappedPolicy, "US",
        PiiPolicy.report); });
    check(cast(ubyte[])read(cappedPolicy) == cappedPriorBytes &&
        info(cappedPolicy).st_ino == cappedPriorInode,
        "oversize altered destination");
    check(descriptors() == steadyFd, "final descriptor leak");
    noTemps(root);
}

void main() {
    run();
    writeln("pii policy overlay: ", assertions, " assertions passed");
}
