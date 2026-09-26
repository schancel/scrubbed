/// Disk-backed similarity bucket evidence: skew, determinism, restart, bounds.
module similarity.bucket_check;

import core.sys.posix.fcntl : fcntl, F_GETFD;
import core.sys.posix.sys.resource : getrusage, rusage, RUSAGE_SELF;
import core.sys.posix.sys.stat : stat, stat_t;
import domain.document : DocumentId, OutputName, SourceLocator;
import domain.shard_format : AnnotationRecord, ShardDocument;
import domain.similarity_signature : SimilaritySignature, SimilaritySignatures,
    similarityBands, similaritySignatures, signatureVersion;
import effects.document_shards : DocumentShardWriter, JoinedOverlay, OverlayReader,
    PublishStep, joinShards;
import effects.similarity_buckets;
import std.algorithm.mutation : reverse;
import std.algorithm.sorting : sort;
import std.algorithm.searching : canFind;
import std.conv : to;
import std.digest.sha : sha256Of;
import std.exception : enforce;
import std.file : SpanMode, dirEntries, exists, mkdir, read, rename, rmdirRecurse, tempDir,
    write;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : toStringz;
import std.uuid : randomUUID;

private void need(bool condition, string message) {
    if (!condition) throw new Exception("similarity buckets check: " ~ message);
}
private void rejects(scope void delegate() action) {
    bool failed;
    try action(); catch (Exception) failed = true;
    need(failed, "expected rejection");
}
private ulong inode(string path) {
    stat_t info;
    need(stat(path.toStringz, &info) == 0, "stat failed");
    return cast(ulong) info.st_ino;
}
private void noScratch(string directory) {
    foreach (entry; dirEntries(directory, SpanMode.shallow))
        need(!entry.name.canFind(".similarity-buckets-") &&
            !entry.name.canFind(".scrubbed-"), "scratch leaked");
}
private ShardDocument document(string source, string key, ubyte[] bytes) {
    return ShardDocument(SourceLocator("similarity-bucket-check", source, key),
        OutputName(key), bytes);
}
private void sourceFile(string path, ShardDocument[] documents) {
    documents.sort!((a, b) => a.id.text < b.id.text);
    auto writer = new DocumentShardWriter(path);
    foreach (record; documents) writer.append(record);
    writer.publish();
}

/// One document's synthetic input plus which physical shard it belongs to.
/// Kept decoupled from a numeric sourceIndex so shard-order/worker-count
/// permutations are just a different mapping to the same physical shards.
private struct EntrySpec {
    SimilaritySignatures signatures;
    ubyte[32] contentDigest;
    string shardSource;
}
private SimilarityBatchEntry[] toEntries(EntrySpec[] specs,
        const(SimilarityShard)[] shardsForCall) {
    SimilarityBatchEntry[] result;
    foreach (spec; specs) {
        uint index = uint.max;
        foreach (i, shard; shardsForCall)
            if (shard.source == spec.shardSource) { index = cast(uint) i; break; }
        need(index != uint.max, "spec references a shard outside this call");
        result ~= SimilarityBatchEntry(spec.signatures, spec.contentDigest, index);
    }
    return result;
}
private SimilarityShard[] writeShards(string root, string outDir, string label,
        ShardDocument[][] documentsByShard) {
    SimilarityShard[] shards;
    foreach (i, documents; documentsByShard) {
        auto source = buildPath(root, label ~ "-source-" ~ i.to!string ~ ".shard");
        auto destination = buildPath(outDir, label ~ "-dest-" ~ i.to!string ~ ".overlay");
        sourceFile(source, documents);
        shards ~= SimilarityShard(source, destination);
    }
    return shards;
}
private SimilarityBucketMember[][string] decodeAll(const(SimilarityShard)[] shards) {
    SimilarityBucketMember[][string] result;
    foreach (shard; shards) {
        auto reader = new OverlayReader(shard.destination);
        scope(exit) reader.closeReader();
        need(reader.header.analyzerKey == similarityBucketsAnalyzerKey,
            "overlay analyzer key");
        AnnotationRecord record;
        string previous;
        while (reader.next(record)) {
            need(previous.length == 0 || previous < record.documentId, "overlay order");
            previous = record.documentId;
            need((record.documentId in result) is null, "documentId across two shards");
            result[record.documentId] = decodeSimilarityBucketMembers(record.fields);
        }
    }
    return result;
}

/// Independent reference recomputation: explode, sort, group, cap, and mark
/// overflow exactly per the contract, but written separately from the
/// production module so agreement is a real cross-check, not a tautology.
private struct RefCandidate {
    size_t bandIndex;
    ulong bandKeyValue;
    string documentId;
    bool segment;
    size_t segmentOrdinal;
}
private bool refMemberLess(SimilarityBucketMember a, SimilarityBucketMember b) {
    if (a.segment != b.segment) return !a.segment;
    if (a.segmentOrdinal != b.segmentOrdinal) return a.segmentOrdinal < b.segmentOrdinal;
    return a.bandIndex < b.bandIndex;
}
private SimilarityBucketMember[][string] referenceBuckets(const(EntrySpec)[] specs, size_t cap) {
    RefCandidate[] all;
    void add(SimilaritySignature signature) {
        if (!signature.hasKeys) return;
        foreach (band; 0 .. similarityBands)
            all ~= RefCandidate(band, signature.bands[band], signature.documentId.text,
                signature.segment, signature.segmentOrdinal);
    }
    foreach (spec; specs) {
        add(spec.signatures.document);
        foreach (segment; spec.signatures.segments) add(segment);
    }
    all.sort!((a, b) {
        if (a.bandIndex != b.bandIndex) return a.bandIndex < b.bandIndex;
        if (a.bandKeyValue != b.bandKeyValue) return a.bandKeyValue < b.bandKeyValue;
        if (a.documentId != b.documentId) return a.documentId < b.documentId;
        if (a.segment != b.segment) return !a.segment;
        return a.segmentOrdinal < b.segmentOrdinal;
    });
    SimilarityBucketMember[][string] result;
    size_t i;
    while (i < all.length) {
        size_t j = i;
        while (j < all.length && all[j].bandIndex == all[i].bandIndex &&
                all[j].bandKeyValue == all[i].bandKeyValue) ++j;
        auto groupSize = j - i;
        auto kept = groupSize < cap ? groupSize : cap;
        auto overflowed = groupSize > cap;
        foreach (k; i .. i + kept) {
            auto c = all[k];
            result[c.documentId] ~= SimilarityBucketMember(c.segment, c.segmentOrdinal,
                c.bandIndex, c.bandKeyValue, overflowed);
        }
        i = j;
    }
    foreach (documentId, ref members; result) members.sort!((a, b) => refMemberLess(a, b));
    return result;
}
private void assertMatchesReference(SimilarityBucketMember[][string] actual,
        SimilarityBucketMember[][string] expected) {
    need(actual.length == expected.length, "document count disagrees with reference");
    foreach (documentId, members; expected) {
        auto found = documentId in actual;
        need(found !is null, "reference document missing from overlay");
        need(*found == members, "overlay members disagree with reference for " ~ documentId);
    }
}

private SimilaritySignature rawSignature(DocumentId id, ulong[16] bands) {
    SimilaritySignature result;
    result.documentId = id;
    result.hasKeys = true;
    result.bands = bands;
    return result;
}

private void basicCorrectness(string root, string outDir) {
    string[] shardSources = [buildPath(root, "basic-source-0.shard"),
        buildPath(root, "basic-source-1.shard"), buildPath(root, "basic-source-2.shard")];
    ShardDocument[][3] byShard;
    EntrySpec[] specs;
    string[] texts = [
        "The quick brown fox jumps over the lazy dog. A consistent related text.",
        "The quick brown fox jumps over the lazy dog! A consistent related text.",
        "Numbers 0123456789 and symbols xxxxxx do not describe that animal.",
        "Another entirely unrelated sentence about something else altogether today.",
        "Short",
        "",
    ];
    foreach (i, text; texts) {
        auto record = document("basic-" ~ (i % 3).to!string, "doc-" ~ i.to!string,
            cast(ubyte[]) text.dup);
        byShard[i % 3] ~= record;
        auto signatures = similaritySignatures(record.id, record.content);
        specs ~= EntrySpec(signatures, record.contentDigest, shardSources[i % 3]);
    }
    ShardDocument[][] byShardSlice = [byShard[0], byShard[1], byShard[2]];
    auto shards = writeShards(root, outDir, "basic", byShardSlice);
    need(shards[0].source == shardSources[0] && shards[1].source == shardSources[1] &&
        shards[2].source == shardSources[2], "shard construction order");

    writeSimilarityBucketOverlays(shards, similarityBatchReader(toEntries(specs, shards)),
        defaultSimilarityBucketCap);
    auto decoded = decodeAll(shards);
    assertMatchesReference(decoded, referenceBuckets(specs, defaultSimilarityBucketCap));

    // The related pair (indices 0/1) must share at least one band; join through
    // C01 the same way a downstream consumer would.
    auto relatedA = specs[0].signatures.document.documentId.text;
    auto relatedB = specs[1].signatures.document.documentId.text;
    bool sharesBand(SimilarityBucketMember[] a, SimilarityBucketMember[] b) {
        foreach (x; a) foreach (y; b)
            if (!x.segment && !y.segment && x.bandIndex == y.bandIndex &&
                x.bandKeyValue == y.bandKeyValue) return true;
        return false;
    }
    need(sharesBand(decoded[relatedA], decoded[relatedB]),
        "authored related pair did not share a band");
    auto controlId = specs[2].signatures.document.documentId.text;
    writeln("basic correctness: authored unrelated control shared band: ",
        (controlId in decoded) !is null && sharesBand(decoded[relatedA], decoded[controlId]));

    foreach (shard; shards)
        joinShards(shard.source, [shard.destination], (ShardDocument source,
                JoinedOverlay[] overlays) {
            need(overlays.length == 1, "join arity");
            auto expected = (source.id.text in decoded) !is null;
            need(overlays[0].present == expected, "join presence disagrees with decode");
        });
    writeln("similarity buckets: basic correctness ok (", specs.length, " documents)");
}

private void skewAndDeterminism(string root, string outDir) {
    enum bucketCap = 50;
    enum skewCount = 500;
    enum underCapCount = 10;
    enum normalCount = 60;
    enum skewBand = 3;
    enum skewKey = 0xF00D_F00D_F00D_F00DUL;
    enum underCapBand = 7;
    enum underCapKey = 0x00C0_FFEE_00C0_FFEEUL;

    string[] shardSources = [buildPath(root, "skew-source-0.shard"),
        buildPath(root, "skew-source-1.shard"), buildPath(root, "skew-source-2.shard")];
    ShardDocument[][3] byShard;
    EntrySpec[] specs;
    string[] skewIds;
    size_t counter;
    void addDocument(size_t globalIndex, ulong[16] bands) {
        auto shardIndex = globalIndex % 3;
        auto record = document("skew-" ~ shardIndex.to!string,
            "doc-" ~ globalIndex.to!string, cast(ubyte[]) ("payload-" ~ globalIndex.to!string));
        byShard[shardIndex] ~= record;
        auto signature = rawSignature(record.id, bands);
        specs ~= EntrySpec(SimilaritySignatures(signature, []), record.contentDigest,
            shardSources[shardIndex]);
    }
    ulong[16] uniqueBands(size_t index) {
        ulong[16] bands;
        foreach (b; 0 .. 16) bands[b] = (cast(ulong) index << 8) | b;
        return bands;
    }
    foreach (i; 0 .. skewCount) {
        auto bands = uniqueBands(counter);
        bands[skewBand] = skewKey;
        addDocument(counter, bands);
        skewIds ~= specs[$ - 1].signatures.document.documentId.text;
        ++counter;
    }
    foreach (i; 0 .. underCapCount) {
        auto bands = uniqueBands(counter + 1_000_000);
        bands[underCapBand] = underCapKey;
        addDocument(counter, bands);
        ++counter;
    }
    foreach (i; 0 .. normalCount) {
        addDocument(counter, uniqueBands(counter + 2_000_000));
        ++counter;
    }
    ShardDocument[][] byShardSlice = [byShard[0], byShard[1], byShard[2]];
    auto shards = writeShards(root, outDir, "skew", byShardSlice);

    auto baselineEntries = toEntries(specs, shards);
    writeSimilarityBucketOverlays(shards, similarityBatchReader(baselineEntries), bucketCap);
    auto decoded = decodeAll(shards);
    auto reference = referenceBuckets(specs, bucketCap);
    assertMatchesReference(decoded, reference);

    // Exact truncation count and stable order, independent of the reference
    // helper: the kept skewed members must be exactly the first `bucketCap`
    // document IDs in ascending order.
    string[] keptSkewIds;
    foreach (documentId, members; decoded)
        foreach (member; members)
            if (!member.segment && member.bandIndex == skewBand &&
                    member.bandKeyValue == skewKey) {
                need(member.overflowed, "kept skewed member must be marked overflowed");
                keptSkewIds ~= documentId;
            }
    need(keptSkewIds.length == bucketCap, "skew bucket did not truncate to the exact cap");
    need(skewCount - keptSkewIds.length == skewCount - bucketCap,
        "truncation count arithmetic");
    auto sortedSkewIds = skewIds.dup;
    sortedSkewIds.sort();
    auto expectedKept = sortedSkewIds[0 .. bucketCap].dup;
    keptSkewIds.sort();
    need(expectedKept == keptSkewIds,
        "truncation did not keep the stable-order prefix of document IDs");

    size_t underCapKept;
    foreach (documentId, members; decoded)
        foreach (member; members)
            if (!member.segment && member.bandIndex == underCapBand &&
                    member.bandKeyValue == underCapKey) {
                need(!member.overflowed, "under-cap bucket incorrectly marked overflowed");
                ++underCapKept;
            }
    need(underCapKept == underCapCount, "under-cap bucket lost members");
    writeln("similarity buckets: skew ok (", skewCount, " candidates, cap ", bucketCap,
        ", truncated ", skewCount - bucketCap, ", overflowed flag set on all ",
        bucketCap, " survivors)");

    // Byte-identical across input order and shard order permutations.
    ubyte[][] baselineBytes;
    foreach (shard; shards) baselineBytes ~= cast(ubyte[]) read(shard.destination);

    auto reversedEntries = baselineEntries.dup;
    reversedEntries.reverse();
    writeSimilarityBucketOverlays(shards, similarityBatchReader(reversedEntries), bucketCap);
    foreach (i, shard; shards)
        need(read(shard.destination) == baselineBytes[i], "input order changed overlay bytes");

    auto shuffledShards = [shards[2], shards[0], shards[1]];
    writeSimilarityBucketOverlays(shuffledShards,
        similarityBatchReader(toEntries(specs, shuffledShards)), bucketCap);
    foreach (i, shard; shards)
        need(read(shard.destination) == baselineBytes[i], "shard order changed overlay bytes");

    // Worker-count permutation: same logical documents, four shards instead
    // of three; per-document decoded content must be unchanged.
    ShardDocument[][4] repartitioned;
    string[] workerSources = [buildPath(root, "worker-source-0.shard"),
        buildPath(root, "worker-source-1.shard"), buildPath(root, "worker-source-2.shard"),
        buildPath(root, "worker-source-3.shard")];
    EntrySpec[] repartitionedSpecs;
    size_t ordinal;
    foreach (shardIndex; 0 .. 3) {
        foreach (record; byShard[shardIndex]) {
            auto worker = ordinal++ % 4;
            repartitioned[worker] ~= record;
        }
    }
    // Rebuild specs against the new shard label per document.
    string[string] labelByDocumentId;
    ordinal = 0;
    foreach (shardIndex; 0 .. 3)
        foreach (record; byShard[shardIndex])
            labelByDocumentId[record.id.text] = workerSources[ordinal++ % 4];
    foreach (spec; specs)
        repartitionedSpecs ~= EntrySpec(spec.signatures, spec.contentDigest,
            labelByDocumentId[spec.signatures.document.documentId.text]);
    ShardDocument[][] repartitionedSlice = [repartitioned[0], repartitioned[1],
        repartitioned[2], repartitioned[3]];
    auto workerShards = writeShards(root, outDir, "worker", repartitionedSlice);
    writeSimilarityBucketOverlays(workerShards,
        similarityBatchReader(toEntries(repartitionedSpecs, workerShards)), bucketCap);
    auto repartitionedDecoded = decodeAll(workerShards);
    need(repartitionedDecoded.length == decoded.length,
        "worker repartition changed document coverage");
    foreach (documentId, members; decoded)
        need(documentId in repartitionedDecoded &&
            repartitionedDecoded[documentId] == members,
            "worker repartition changed canonical bucket membership");
    writeln("similarity buckets: determinism ok (input order, shard order, worker count)");

    // Crash/restart, shape one: a fault at the first occurrence of each
    // publish step must leave every destination's prior bytes untouched
    // (the very first shard never finishes publishing).
    foreach (step; [PublishStep.afterWrite, PublishStep.afterFsync, PublishStep.beforePublish]) {
        bool tripped;
        rejects({ writeSimilarityBucketOverlays(shards,
            similarityBatchReader(toEntries(specs, shards)), bucketCap,
            (PublishStep current) {
                if (!tripped && current == step) {
                    tripped = true;
                    throw new Exception("injected prepublish fault");
                }
            }); });
        need(tripped, "fault hook was not reached");
        foreach (i, shard; shards)
            need(read(shard.destination) == baselineBytes[i], "fault changed prior overlay");
        noScratch(outDir);
    }
    // Crash/restart, shape two: C01 is per-overlay atomic, not a multi-shard
    // transaction. A fault on the second shard's beforePublish leaves the
    // first shard published and the remaining shards at their prior bytes;
    // an unmodified rerun converges every shard to the same baseline bytes.
    foreach (shard; shards) write(shard.destination, cast(ubyte[]) "prior overlay");
    size_t publications;
    rejects({ writeSimilarityBucketOverlays(shards,
        similarityBatchReader(toEntries(specs, shards)), bucketCap,
        (PublishStep step) {
            if (step == PublishStep.beforePublish && ++publications == 2)
                throw new Exception("second overlay prepublish fault");
        }); });
    need(read(shards[0].destination) == baselineBytes[0] &&
        read(shards[1].destination) == cast(ubyte[]) "prior overlay" &&
        read(shards[2].destination) == cast(ubyte[]) "prior overlay",
        "partial publication boundary");
    writeSimilarityBucketOverlays(shards, similarityBatchReader(toEntries(specs, shards)),
        bucketCap);
    foreach (i, shard; shards)
        need(read(shard.destination) == baselineBytes[i], "restart did not converge");
    noScratch(outDir);
    writeln("similarity buckets: crash/restart convergence ok");
}

private void rssAndFdBounds(string root, string outDir) {
    enum documents = 6000;
    string[] shardSources = [buildPath(root, "scale-source-0.shard"),
        buildPath(root, "scale-source-1.shard"), buildPath(root, "scale-source-2.shard")];
    ShardDocument[][3] byShard;
    EntrySpec[] specs;
    foreach (i; 0 .. documents) {
        auto shardIndex = i % 3;
        auto record = document("scale-" ~ shardIndex.to!string, "doc-" ~ i.to!string,
            cast(ubyte[]) ("payload-" ~ i.to!string));
        byShard[shardIndex] ~= record;
        ulong[16] bands;
        foreach (b; 0 .. 16) bands[b] = (cast(ulong) i << 8) | b;
        auto signature = rawSignature(record.id, bands);
        specs ~= EntrySpec(SimilaritySignatures(signature, []), record.contentDigest,
            shardSources[shardIndex]);
    }
    ShardDocument[][] byShardSlice = [byShard[0], byShard[1], byShard[2]];
    auto shards = writeShards(root, outDir, "scale", byShardSlice);
    auto entries = toEntries(specs, shards);

    auto beforeFds = fds();
    auto beforeRss = rssBytes();
    version (SimilarityBucketsCheck) resetSimilarityBucketsObservations();
    foreach (_; 0 .. 2)
        writeSimilarityBucketOverlays(shards, similarityBatchReader(entries),
            defaultSimilarityBucketCap);
    need(fds() == beforeFds, "large run leaked a file descriptor");
    auto afterRss = rssBytes();
    auto grown = afterRss - beforeRss;
    need(grown < 64UL * 1024 * 1024, "large run resident-set growth exceeded 64 MiB");
    writeln("similarity buckets: resident-set high-water mark before=", beforeRss,
        " after=", afterRss, " bytes (single local observation, not a population claim)");
    version (SimilarityBucketsCheck) {
        need(similarityBucketsPeakOpenScratchFiles() <= 32,
            "scratch file descriptors grew beyond a small fixed bound");
        need(similarityBucketsPeakBatchRecords() <= 32,
            "in-memory batch grew beyond the fixed run size");
        writeln("similarity buckets: instrumented peak open scratch files=",
            similarityBucketsPeakOpenScratchFiles(),
            " peak batch records=", similarityBucketsPeakBatchRecords());
    }
    noScratch(outDir);
    writeln("similarity buckets: bounded run ok (", documents,
        " documents, two repeated passes, fd_delta=0, rss_growth_bytes=", grown, ")");
}

private ulong rssBytes() {
    rusage usage;
    need(getrusage(RUSAGE_SELF, &usage) == 0, "RSS observation failed");
    version (OSX) return cast(ulong) usage.ru_opaque[0];
    else version (linux) return cast(ulong) usage.ru_maxrss * 1024;
    else static assert(0, "RSS observation requires platform support");
}
private size_t fds() {
    size_t count;
    foreach (fd; 0 .. 256) if (fcntl(fd, F_GETFD) >= 0) ++count;
    return count;
}

private void immutabilityAndRejections(string root, string outDir) {
    auto source = buildPath(root, "immutable-source.shard");
    auto destination = buildPath(outDir, "immutable-dest.overlay");
    auto record = document("immutable", "only", cast(ubyte[]) "payload");
    sourceFile(source, [record]);
    auto beforeBytes = cast(ubyte[]) read(source);
    auto beforeInode = inode(source);
    ulong[16] bands;
    foreach (b; 0 .. 16) bands[b] = b + 1;
    auto signature = rawSignature(record.id, bands);
    EntrySpec[] specs = [EntrySpec(SimilaritySignatures(signature, []), record.contentDigest,
        source)];
    auto shards = [SimilarityShard(source, destination)];
    writeSimilarityBucketOverlays(shards, similarityBatchReader(toEntries(specs, shards)));
    need(read(source) == beforeBytes && inode(source) == beforeInode,
        "similarity bucket write mutated its source shard");

    // Duplicate document ID across two batch entries must be rejected before
    // any publication.
    auto duplicateDest = buildPath(outDir, "duplicate-dest.overlay");
    EntrySpec[] duplicateSpecs = [
        EntrySpec(SimilaritySignatures(signature, []), record.contentDigest, source),
        EntrySpec(SimilaritySignatures(signature, []), record.contentDigest, source),
    ];
    auto duplicateShards = [SimilarityShard(source, duplicateDest)];
    rejects({ writeSimilarityBucketOverlays(duplicateShards,
        similarityBatchReader(toEntries(duplicateSpecs, duplicateShards))); });
    need(!exists(duplicateDest), "duplicate document ID published an overlay");

    // A signature carrying the wrong profile version must be refused.
    auto mismatchedSignature = signature;
    mismatchedSignature.profileVersion = "byte-shingle-minhash:v0";
    auto mismatchedDest = buildPath(outDir, "mismatched-dest.overlay");
    EntrySpec[] mismatchedSpecs = [EntrySpec(SimilaritySignatures(mismatchedSignature, []),
        record.contentDigest, source)];
    auto mismatchedShards = [SimilarityShard(source, mismatchedDest)];
    rejects({ writeSimilarityBucketOverlays(mismatchedShards,
        similarityBatchReader(toEntries(mismatchedSpecs, mismatchedShards))); });
    need(!exists(mismatchedDest), "mismatched profile version published an overlay");
    writeln("similarity buckets: immutability and rejection checks ok");
}

/// Regression for a batch-wide preflight gap: a destination that aliases
/// ANOTHER shard's source (not its own paired source) must be rejected
/// before any shard is published, exactly like exact_dedup_overlay's
/// PreflightPlan rejects the same cross-shard shape. Reproduces: shard A's
/// destination is shard B's real immutable source shard.
private void crossShardAliasRejection(string root, string outDir) {
    // All three paths share one directory (the module's existing shared-
    // directory rule would otherwise reject this batch for that unrelated
    // reason, masking whether the alias check itself is doing anything).
    auto aliasDir = buildPath(root, "alias-dir");
    mkdir(aliasDir);
    auto sourceA = buildPath(aliasDir, "alias-source-a.shard");
    auto sourceB = buildPath(aliasDir, "alias-source-b.shard");
    auto destinationC = buildPath(aliasDir, "alias-dest-c.overlay");
    auto recordA = document("alias-a", "only", cast(ubyte[]) "aaaa");
    auto recordB = document("alias-b", "only", cast(ubyte[]) "bbbbbbbbbbbbbbbbbb");
    sourceFile(sourceA, [recordA]);
    sourceFile(sourceB, [recordB]);
    auto beforeA = cast(ubyte[]) read(sourceA);
    auto beforeB = cast(ubyte[]) read(sourceB);
    auto beforeInodeA = inode(sourceA);
    auto beforeInodeB = inode(sourceB);

    ulong[16] bandsA;
    ulong[16] bandsB;
    foreach (b; 0 .. 16) { bandsA[b] = b + 100; bandsB[b] = b + 200; }
    EntrySpec[] specs = [
        EntrySpec(SimilaritySignatures(rawSignature(recordA.id, bandsA), []),
            recordA.contentDigest, sourceA),
        EntrySpec(SimilaritySignatures(rawSignature(recordB.id, bandsB), []),
            recordB.contentDigest, sourceB),
    ];
    // shard 0's destination IS shard 1's real source: exactly the reviewer's
    // repro shape (A -> B, B -> C).
    auto aliasedShards = [SimilarityShard(sourceA, sourceB), SimilarityShard(sourceB, destinationC)];
    rejects({ writeSimilarityBucketOverlays(aliasedShards,
        similarityBatchReader(toEntries(specs, aliasedShards))); });

    need(read(sourceA) == beforeA && inode(sourceA) == beforeInodeA,
        "cross-shard alias rejection still mutated source A");
    need(read(sourceB) == beforeB && inode(sourceB) == beforeInodeB,
        "cross-shard alias rejection silently overwrote source B (data loss)");
    need(!exists(destinationC), "cross-shard alias rejection still published shard 2");
    noScratch(aliasDir);
    writeln("similarity buckets: cross-shard destination/source alias rejected before publication");
}

/// TOCTOU regression: the static preflight alone cannot see a source that is
/// relinked mid-run, after preflight passed cleanly but before that shard's
/// own publish completes. Exploits the module's own tested PublishFault hook
/// (the same hook the crash/restart tests use) to rename shard 0's real
/// source to become shard 1's future destination path during shard 0's own
/// beforePublish callback. Repeated re-validation (immediately before each
/// OverlayWriter opens, and again inside every fault-hook call for the shard
/// currently publishing) must catch this; an upfront-only check cannot.
private void toctouRelinkRejection(string root) {
    auto aliasDir = buildPath(root, "toctou-dir");
    mkdir(aliasDir);
    auto victimSource = buildPath(aliasDir, "a-victim-source.shard");
    auto otherSource = buildPath(aliasDir, "b-other-source.shard");
    auto relinkedDestination = buildPath(aliasDir, "c-relinked-destination.shard");
    auto victimRecord = document("toctou-victim", "only",
        cast(ubyte[]) "victim-content-must-survive-the-attack");
    auto otherRecord = document("toctou-other", "only", cast(ubyte[]) "unrelated-content");
    sourceFile(victimSource, [victimRecord]);
    sourceFile(otherSource, [otherRecord]);
    auto victimBytesBeforeAttack = cast(ubyte[]) read(victimSource);
    need(!exists(relinkedDestination), "relinked destination must not exist before the attack");
    // Canonical shard order is by source path; victimSource must sort first
    // so its publish (and fault hook) fires before shard 1 is ever reached.
    need(victimSource < otherSource, "fixture path-ordering assumption");

    ulong[16] bandsVictim;
    ulong[16] bandsOther;
    foreach (b; 0 .. 16) { bandsVictim[b] = b + 300; bandsOther[b] = b + 400; }
    EntrySpec[] specs = [
        EntrySpec(SimilaritySignatures(rawSignature(victimRecord.id, bandsVictim), []),
            victimRecord.contentDigest, victimSource),
        EntrySpec(SimilaritySignatures(rawSignature(otherRecord.id, bandsOther), []),
            otherRecord.contentDigest, otherSource),
    ];
    auto shards = [SimilarityShard(victimSource, buildPath(aliasDir, "victim-dest.overlay")),
        SimilarityShard(otherSource, relinkedDestination)];

    bool attacked;
    rejects({ writeSimilarityBucketOverlays(shards,
        similarityBatchReader(toEntries(specs, shards)), defaultSimilarityBucketCap,
        (PublishStep step) {
            if (!attacked && step == PublishStep.beforePublish) {
                attacked = true;
                rename(victimSource, relinkedDestination);
            }
        }); });
    need(attacked, "TOCTOU fault hook was not reached");
    need(read(relinkedDestination) == victimBytesBeforeAttack,
        "TOCTOU relink allowed a later shard to overwrite the relinked victim content");
    noScratch(aliasDir);
    writeln("similarity buckets: mid-run source relink (TOCTOU) rejected before further writes");
}

void main() {
    auto root = buildPath(tempDir(), "similarity-buckets-check-" ~ randomUUID.toString);
    mkdir(root);
    scope(exit) rmdirRecurse(root);
    auto outDir = buildPath(root, "out");
    mkdir(outDir);

    basicCorrectness(root, outDir);
    skewAndDeterminism(root, outDir);
    immutabilityAndRejections(root, outDir);
    crossShardAliasRejection(root, outDir);
    toctouRelinkRejection(root);
    rssAndFdBounds(root, outDir);
    writeln("similarity buckets: all checks passed");
}
