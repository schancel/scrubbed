module mix_export.check;

import core.memory : GC;
import core.sys.posix.fcntl : fcntl, F_GETFD;
import core.sys.posix.sys.resource : getrusage, rusage, RUSAGE_SELF;
import core.sys.posix.sys.stat : chmod, lstat, stat_t, S_IRUSR, S_IWUSR;
import core.sys.posix.unistd : _exit, link;
import domain.document : OutputName, SourceLocator;
import domain.mix_policy : MissingAnnotation, MixDecision, MixPolicy, MixReason;
import domain.quality_features : QualityPolicy, decide, measure;
import domain.shard_format : AnnotationField, AnnotationRecord, ShardDocument;
import effects.document_shards : DocumentShardWriter, OverlayReader, OverlayWriter;
import effects.exact_dedup_overlay : DedupShard, dedupAnalyzerKey,
    dedupAnalyzerVersion, writeExactDedupOverlays;
import effects.mix_export : MixExportRow, MixExportStep, publishMixGeneration,
    readMixGeneration;
import effects.mix_overlay : visitMixDecisions;
import effects.quality_overlay : decisionAnalyzerKey, decisionAnalyzerVersion,
    decisionFieldKey, encodeDecisionValue;
import std.algorithm.sorting : sort;
import std.array : replace;
import std.base64 : Base64;
import std.conv : to;
import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;
import std.file : SpanMode, dirEntries, exists, mkdir, read, rmdirRecurse,
    remove, tempDir, thisExePath, write;
import std.path : baseName, buildPath;
import std.process : execute;
import std.stdio : writeln;
import std.string : indexOf, split, startsWith, strip, toStringz;
import std.uuid : randomUUID;

private void check(bool okay, string reason) {
    if (!okay) throw new Exception(reason);
}

private void rejects(scope void delegate() action) {
    bool caught;
    try action(); catch (Exception error) {
        check(error.msg.indexOf("private-canary") < 0 &&
            error.msg.indexOf("@example") < 0,
            "diagnostic leaked private source content");
        caught = true;
    }
    check(caught, "expected mix export refusal");
}

private ShardDocument document(string key, const(ubyte)[] content) {
    return ShardDocument(SourceLocator("mix-export-check", "source", key),
        OutputName(key), content.dup);
}

private void writeShard(string path, ShardDocument[] records) {
    records.sort!((a, b) => a.id.text < b.id.text);
    auto writer = new DocumentShardWriter(path);
    foreach (record; records) writer.append(record);
    writer.publish();
}

private void writeOverlay(string path, string shard, string key,
        string analyzerVersion, AnnotationRecord[] records) {
    records.sort!((a, b) => a.documentId < b.documentId);
    auto writer = new OverlayWriter(path, shard, key, analyzerVersion);
    foreach (record; records) writer.append(record);
    writer.publish();
}

private AnnotationRecord[] readOverlay(string path) {
    auto reader = new OverlayReader(path);
    scope(exit) reader.closeReader();
    AnnotationRecord[] records;
    AnnotationRecord record;
    while (reader.next(record)) records ~= record;
    return records;
}

private void writeQuality(string path, string shard,
        ShardDocument[] records, QualityPolicy policy) {
    AnnotationRecord[] annotations;
    foreach (source; records) {
        auto decision = decide(measure(source), policy);
        annotations ~= AnnotationRecord(source.id.text, source.contentDigest,
            [AnnotationField(decisionFieldKey,
                encodeDecisionValue(decision, policy))]);
    }
    writeOverlay(path, shard, decisionAnalyzerKey,
        decisionAnalyzerVersion(policy), annotations);
}

private struct Fixture {
    string shard;
    string quality;
    string dedup;
    ShardDocument[] records;
    AnnotationRecord[] qualityRows;
    AnnotationRecord[] dedupRows;
}

private Fixture fixture(string root, ShardDocument[] records,
        QualityPolicy policy, string suffix) {
    Fixture result;
    result.shard = buildPath(root, suffix ~ ".source");
    result.quality = buildPath(root, suffix ~ ".quality");
    result.dedup = buildPath(root, suffix ~ ".dedup");
    result.records = records.dup;
    writeShard(result.shard, result.records);
    writeQuality(result.quality, result.shard, result.records, policy);
    writeExactDedupOverlays([DedupShard(result.shard, result.dedup)]);
    result.qualityRows = readOverlay(result.quality);
    result.dedupRows = readOverlay(result.dedup);
    return result;
}

private string onlyFile(string root, string pattern) {
    string result;
    foreach (entry; dirEntries(root, pattern, SpanMode.shallow)) {
        check(result.length == 0, "expected one matching generation file");
        result = entry.name;
    }
    check(result.length != 0, "missing generation file " ~ pattern);
    return result;
}

private string slurp(string path) { return cast(string)read(path); }

private string digest(string value) {
    return toHexString!(LetterCase.lower)(sha256Of(value)).idup;
}

private MixExportRow own(const(MixExportRow) row) {
    MixExportRow result;
    result.id = row.id;
    result.include = row.include;
    result.reason = row.reason;
    result.sampleBucket = row.sampleBucket;
    result.sourceContentSha256 = row.sourceContentSha256.idup;
    result.selectedContent = row.selectedContent.dup;
    return result;
}

private ulong rssBytes() {
    rusage usage;
    check(getrusage(RUSAGE_SELF, &usage) == 0, "RSS observation failed");
    version (OSX) return cast(ulong)usage.ru_opaque[0];
    else version (linux) return cast(ulong)usage.ru_maxrss * 1024;
    else static assert(0, "RSS observation requires platform support");
}

private size_t fds() {
    size_t count;
    foreach (fd; 0 .. 256) if (fcntl(fd, F_GETFD) >= 0) ++count;
    return count;
}

private void childRead(string mode, string manifest) {
    GC.collect();
    auto fdStart = fds();
    auto fdPeak = fdStart;
    ulong checksum = 14_695_981_039_346_656_037UL;
    ubyte[][] retained;
    auto generation = readMixGeneration(manifest, (const(MixExportRow) row) {
        foreach (ch; row.id.text) {
            checksum ^= cast(ubyte)ch;
            checksum *= 1_099_511_628_211UL;
        }
        if (mode == "--buffer" && row.include)
            retained ~= row.selectedContent.dup;
        auto current = fds();
        if (current > fdPeak) fdPeak = current;
    });
    auto fdEnd = fds();
    if (mode == "--buffer")
        check(retained.length == generation.included,
            "buffering control did not retain selected content");
    writeln(rssBytes(), " ", fdStart, " ", fdPeak, " ", fdEnd, " ",
        generation.total, " ", generation.included, " ", checksum);
}

private struct ChildStats {
    ulong rss;
    size_t fdStart;
    size_t fdPeak;
    size_t fdEnd;
    ulong total;
    ulong included;
    ulong checksum;
}

private ChildStats childStats(string mode, string manifest) {
    auto process = execute([thisExePath(), mode, manifest]);
    check(process.status == 0, "reader child failed: " ~ process.output);
    auto values = process.output.split;
    check(values.length == 7, "reader child output shape");
    ChildStats result;
    result.rss = values[0].to!ulong;
    result.fdStart = values[1].to!size_t;
    result.fdPeak = values[2].to!size_t;
    result.fdEnd = values[3].to!size_t;
    result.total = values[4].to!ulong;
    result.included = values[5].to!ulong;
    result.checksum = values[6].to!ulong;
    return result;
}

private void faultChecks(string root, Fixture source, QualityPolicy quality,
        MixPolicy mix) {
    foreach (raw; 0 .. 8) {
        auto target = cast(MixExportStep)raw;
        auto output = buildPath(root, "fault-" ~ raw.to!string);
        mkdir(output);
        rejects({
            publishMixGeneration(output, source.shard, source.quality,
                source.dedup, quality, mix, (MixExportStep step) {
                    if (step == target) throw new Exception("injected fault");
                });
        });
        string manifest;
        foreach (entry; dirEntries(output, "*.commit.json", SpanMode.shallow))
            manifest = entry.name;
        if (target == MixExportStep.manifestAfterPublish) {
            check(manifest.length != 0,
                "post-publication fault lost complete manifest");
            check(readMixGeneration(manifest).total == source.records.length,
                "post-publication fault exposed incomplete generation");
        } else check(manifest.length == 0,
            "pre-publication fault exposed a commit manifest");
    }
}

private void postLinkCrashCheck(string root, Fixture source) {
    auto output = buildPath(root, "post-link-crash");
    mkdir(output);
    auto child = execute([thisExePath(), "--crash-after-link", output,
        source.shard, source.quality, source.dedup]);
    check(child.status == 86,
        "post-link crash child did not exit at publication boundary");
    auto manifest = onlyFile(output, "*.commit.json");
    string temporary;
    foreach (entry; dirEntries(output, ".*.tmp", SpanMode.shallow)) {
        check(temporary.length == 0, "multiple post-link temporary aliases");
        temporary = entry.name;
    }
    check(temporary.length != 0, "post-link crash did not preserve alias window");
    stat_t finalInfo, temporaryInfo;
    check(lstat(manifest.toStringz, &finalInfo) == 0 &&
        lstat(temporary.toStringz, &temporaryInfo) == 0 &&
        finalInfo.st_dev == temporaryInfo.st_dev &&
        finalInfo.st_ino == temporaryInfo.st_ino && finalInfo.st_nlink == 2,
        "post-link crash fixture is not the two-link publication state");
    auto recovered = readMixGeneration(manifest);
    check(recovered.total == source.records.length && !exists(temporary),
        "restart did not recover the linked commit manifest");
}

private void rebindNegative(string root, string output,
        string generation, string manifestPath) {
    auto rebound = buildPath(root, "rebound-generation");
    mkdir(rebound);
    enum badHex =
        "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
    auto oldHex = generation["mixgen:v1:".length .. $];
    auto badGeneration = "mixgen:v1:" ~ badHex;
    auto originalDecision = slurp(onlyFile(output, "*.decisions.jsonl"));
    auto originalProvenance = slurp(onlyFile(output, "*.provenance.json"));
    auto originalManifest = slurp(manifestPath);
    auto decision = originalDecision.replace(generation, badGeneration);
    auto provenance = originalProvenance
        .replace(generation, badGeneration)
        .replace(digest(originalDecision), digest(decision));
    auto manifest = originalManifest
        .replace(generation, badGeneration)
        .replace(oldHex, badHex)
        .replace(digest(originalDecision), digest(decision))
        .replace(digest(originalProvenance), digest(provenance));
    write(buildPath(rebound, "mix-" ~ badHex ~ ".decisions.jsonl"), decision);
    write(buildPath(rebound, "mix-" ~ badHex ~ ".provenance.json"), provenance);
    auto reboundManifest = buildPath(rebound,
        "mix-" ~ badHex ~ ".commit.json");
    write(reboundManifest, manifest);
    size_t visited;
    rejects({ readMixGeneration(reboundManifest,
        (const(MixExportRow)) { ++visited; }); });
    check(visited == 0,
        "rebound generation delivered rows before identity rejection");
}

private void unsafeAliasNegative(string root, Fixture source,
        QualityPolicy quality, MixPolicy mix) {
    auto output = buildPath(root, "unsafe-manifest-alias");
    mkdir(output);
    auto generation = publishMixGeneration(output, source.shard,
        source.quality, source.dedup, quality, mix);
    auto aliasPath = buildPath(output, "not-a-writer-temporary.alias");
    check(link(generation.manifestPath.toStringz, aliasPath.toStringz) == 0,
        "cannot create unsafe manifest alias negative");
    rejects({ readMixGeneration(generation.manifestPath); });
    check(exists(aliasPath), "reader removed an unrecognized alias");
    remove(aliasPath);
    check(readMixGeneration(generation.manifestPath).total ==
        source.records.length, "single-link manifest did not recover");
}

private void resourceProof(string root, QualityPolicy quality, MixPolicy mix) {
    enum count = 96;
    enum bytesPerRecord = 256 * 1024;
    ShardDocument[] records;
    foreach (number; 0 .. count) {
        auto content = new ubyte[bytesPerRecord];
        content[] = cast(ubyte)('a' + number % 20);
        auto suffix = number.to!string;
        foreach (i, ch; suffix)
            content[$ - suffix.length + i] = cast(ubyte)ch;
        records ~= document("resource-" ~ suffix, content);
    }
    auto source = fixture(root, records, quality, "resource");
    auto output = buildPath(root, "resource-output");
    mkdir(output);
    auto generation = publishMixGeneration(output, source.shard,
        source.quality, source.dedup, quality, mix);
    auto first = childStats("--stream", generation.manifestPath);
    auto second = childStats("--stream", generation.manifestPath);
    auto buffered = childStats("--buffer", generation.manifestPath);
    check(first.total == count && first.included == count &&
        second.total == count && second.included == count &&
        buffered.total == count && buffered.included == count &&
        first.checksum == second.checksum && first.checksum == buffered.checksum,
        "resource fixture semantic drift");
    check(first.fdEnd == first.fdStart && second.fdEnd == second.fdStart &&
        buffered.fdEnd == buffered.fdStart &&
        first.fdPeak <= first.fdStart + 2 &&
        second.fdPeak <= second.fdStart + 2,
        "reader FD bound or leak");
    check(first.rss < 64UL * 1024 * 1024 &&
        second.rss < 64UL * 1024 * 1024 &&
        buffered.rss > first.rss + 16UL * 1024 * 1024 &&
        buffered.rss > second.rss + 16UL * 1024 * 1024,
        "reader RSS proof lacks buffering sensitivity");
    writeln("mix export resources: stream=", first.rss, "/", second.rss,
        " buffered=", buffered.rss, " fd=", first.fdStart, "/",
        first.fdPeak, "/", first.fdEnd);
}

void main(string[] args) {
    if (args.length == 6 && args[1] == "--crash-after-link") {
        auto quality = QualityPolicy(0, 1_000_000, 1_000_000, 1_000_000);
        auto all = MixPolicy("0123456789abcdef", 1, 1);
        publishMixGeneration(args[2], args[3], args[4], args[5], quality, all,
            (MixExportStep step) {
                if (step == MixExportStep.manifestAfterPublish) _exit(86);
            });
        _exit(87);
    }
    if (args.length == 3 &&
            (args[1] == "--stream" || args[1] == "--buffer")) {
        childRead(args[1], args[2]);
        return;
    }
    check(args.length == 1, "unsupported checker mode");
    auto root = buildPath(tempDir(), "mix-export-check-" ~ randomUUID.toString);
    mkdir(root);
    scope(exit) rmdirRecurse(root);
    auto quality = QualityPolicy(0, 1_000_000, 1_000_000, 1_000_000);
    auto all = MixPolicy("0123456789abcdef", 1, 1);
    ShardDocument[] records = [
        document("a", cast(ubyte[])"alpha"),
        document("b", cast(ubyte[])"alpha"),
        document("c", cast(ubyte[])"charlie")];
    auto source = fixture(root, records, quality, "base");
    auto output = buildPath(root, "output");
    auto repeatOutput = buildPath(root, "repeat-output");
    size_t stage2aVisited;
    auto stage2a = visitMixDecisions(source.shard, source.quality, source.dedup,
        quality, all, (const(ShardDocument), MixDecision) { ++stage2aVisited; });
    check(stage2a.total == 3 && stage2aVisited == 3 && !exists(output),
        "Stage 2a unexpectedly published an artifact before export");
    mkdir(output);
    mkdir(repeatOutput);
    auto generation = publishMixGeneration(output, source.shard,
        source.quality, source.dedup, quality, all);
    MixExportRow[] rows;
    auto readBack = readMixGeneration(generation.manifestPath,
        (const(MixExportRow) row) { rows ~= own(row); });
    check(readBack.total == 3 && readBack.included == 2 && rows.length == 3 &&
        readBack.counts[MixReason.selected] == 2 &&
        readBack.counts[MixReason.duplicate] == 1,
        "published count closure");
    foreach (i; 1 .. rows.length)
        check(rows[i - 1].id.text < rows[i].id.text,
            "published rows not strictly sorted");
    foreach (row; rows) {
        check(row.include == (row.reason == MixReason.selected),
            "published typed reason mismatch");
        if (row.include)
            check(row.selectedContent.length != 0,
                "selected content missing from included row");
        else check(row.selectedContent.length == 0,
            "excluded row disclosed content");
    }

    auto repeated = publishMixGeneration(repeatOutput, source.shard,
        source.quality, source.dedup, quality, all);
    check(repeated.generation == generation.generation &&
        slurp(repeated.manifestPath) == slurp(generation.manifestPath) &&
        slurp(onlyFile(repeatOutput, "*.decisions.jsonl")) ==
            slurp(onlyFile(output, "*.decisions.jsonl")) &&
        slurp(onlyFile(repeatOutput, "*.provenance.json")) ==
            slurp(onlyFile(output, "*.provenance.json")),
        "same inputs did not produce byte-identical generation");

    rebindNegative(root, output, generation.generation,
        generation.manifestPath);

    // Literal wire-schema goldens pin key order, null/typed values, and the
    // absence of selected-content keys on excluded decisions.
    auto manifestText = slurp(generation.manifestPath);
    auto provenanceText = slurp(onlyFile(output, "*.provenance.json"));
    auto decisionsText = slurp(onlyFile(output, "*.decisions.jsonl"));
    check(toHexString(sha256Of(manifestText)) ==
            "4B58798FB24BFE1EBE1CDD93E79EE0C99F1A2E9B58F9EC9342F35D60878B1A67" &&
        toHexString(sha256Of(provenanceText)) ==
            "C154ADC16C0CAF3CC9F45EA86662760ABEA03DCFCE4EE3F376B93ABAF7016D27" &&
        toHexString(sha256Of(decisionsText)) ==
            "DCCEF250596C9711A03C9A123BC2E4CD3D7F4E7B2CA23CE50E0507BBDF3F731D",
        "literal generation golden drift");
    check(manifestText.startsWith(
        `{"schema":"scrubbed-mix-commit-v1","generation":`),
        "commit manifest literal golden drift");
    check(provenanceText.startsWith(
        `{"schema":"scrubbed-mix-provenance-v1","generation":`),
        "provenance literal golden drift");
    check(decisionsText.indexOf(
        `{"schema":"scrubbed-mix-decision-v1","generation":`) == 0 &&
        decisionsText.indexOf(`"reason":"selected","sample_bucket":null`) < 0 &&
        decisionsText.indexOf(`"reason":"duplicate","sample_bucket":null`) >= 0,
        "decision literal golden drift");

    // Missing annotations fail by default; explicit exclusion produces a
    // typed row while the private source bytes remain absent even as base64.
    auto privateRecord = document("private", cast(ubyte[])
        "private-canary@example.invalid");
    auto privateSource = fixture(root, [privateRecord], quality, "private");
    writeOverlay(privateSource.quality, privateSource.shard,
        decisionAnalyzerKey, decisionAnalyzerVersion(quality), []);
    auto missingFail = buildPath(root, "missing-fail");
    mkdir(missingFail);
    rejects({ publishMixGeneration(missingFail, privateSource.shard,
        privateSource.quality, privateSource.dedup, quality, all); });
    check(!exists(buildPath(missingFail, "published.commit.json")),
        "missing failure unexpectedly published");
    foreach (entry; dirEntries(missingFail, "*.commit.json", SpanMode.shallow))
        check(false, "missing failure exposed manifest");
    auto excludeOutput = buildPath(root, "missing-exclude");
    mkdir(excludeOutput);
    auto exclude = MixPolicy("0123456789abcdef", 1, 1,
        MissingAnnotation.exclude);
    auto excluded = publishMixGeneration(excludeOutput, privateSource.shard,
        privateSource.quality, privateSource.dedup, quality, exclude);
    MixExportRow excludedRow;
    readMixGeneration(excluded.manifestPath,
        (const(MixExportRow) row) { excludedRow = own(row); });
    auto excludedWire = slurp(onlyFile(excludeOutput, "*.decisions.jsonl"));
    auto encodedCanary = Base64.encode(privateRecord.content).idup;
    check(excludedRow.reason == MixReason.missingQuality &&
        !excludedRow.include && excludedRow.selectedContent.length == 0 &&
        excludedWire.indexOf("private-canary") < 0 &&
        excludedWire.indexOf(encodedCanary) < 0,
        "explicit exclusion disclosed private source content");

    // A malformed final annotation leaves only unreferenced private files.
    auto late = source.dedupRows.dup;
    late[$ - 1].fields = late[$ - 1].fields.dup;
    late[$ - 1].fields[3].value = cast(ubyte[])"00".dup;
    writeOverlay(source.dedup, source.shard, dedupAnalyzerKey,
        dedupAnalyzerVersion, late);
    auto malformedOutput = buildPath(root, "late-malformed");
    mkdir(malformedOutput);
    rejects({ publishMixGeneration(malformedOutput, source.shard,
        source.quality, source.dedup, quality, all); });
    foreach (entry; dirEntries(malformedOutput, "*.commit.json", SpanMode.shallow))
        check(false, "late malformed input exposed manifest");
    writeOverlay(source.dedup, source.shard, dedupAnalyzerKey,
        dedupAnalyzerVersion, source.dedupRows);

    faultChecks(root, source, quality, all);
    postLinkCrashCheck(root, source);
    unsafeAliasNegative(root, source, quality, all);

    // A changed policy publishes beside, never replaces, the prior generation.
    auto none = MixPolicy("fedcba9876543210", 0, 1);
    auto second = publishMixGeneration(output, source.shard, source.quality,
        source.dedup, quality, none);
    check(second.generation != generation.generation &&
        readMixGeneration(generation.manifestPath).included == 2 &&
        readMixGeneration(second.manifestPath).included == 0,
        "immutable old-generation retention");
    write(buildPath(output, "ignored.orphan"), "not a manifest");
    check(readMixGeneration(generation.manifestPath).total == 3,
        "unreferenced orphan affected reader");

    // Digest validation rejects a changed referenced file.
    auto tamperOutput = buildPath(root, "tamper-output");
    mkdir(tamperOutput);
    auto tampered = publishMixGeneration(tamperOutput, source.shard,
        source.quality, source.dedup, quality, all);
    auto tamperedDecisions = onlyFile(tamperOutput, "*.decisions.jsonl");
    check(chmod(tamperedDecisions.toStringz, S_IRUSR | S_IWUSR) == 0,
        "cannot prepare tamper negative");
    write(tamperedDecisions, slurp(tamperedDecisions) ~ "x");
    rejects({ readMixGeneration(tampered.manifestPath); });

    resourceProof(root, quality, all);
    writeln("mix export: schema/determinism/privacy/fault/restart/reader/resource passed");
}
