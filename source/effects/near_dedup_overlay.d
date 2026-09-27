/// External-memory near-duplicate resolution into revision-bound C01 overlays.
///
/// Reads `effects.similarity_buckets`'s persisted per-document band-membership
/// overlay, joins each surviving member back against its immutable C01 source
/// shard to recover a real `SimilaritySignature`, groups members by
/// `(bandIndex, bandKeyValue)` -- one already-capped bucket at a time, never a
/// full-corpus structure -- and calls the existing, unmodified
/// `domain.near_dedup_decision.nearDuplicateLinksInBucket` per bucket. The
/// resulting links are published as a new, canonically-encoded C01 overlay
/// analyzer, distinct from both `exact-dedup` and `similarity-buckets`.
///
/// `similarity_buckets.d` persists only `(bandIndex, bandKeyValue)` per
/// surviving band -- a one-way hash of four MinHash lanes, not the lanes
/// themselves -- so the real signature is not recoverable from that overlay
/// alone. `domain.similarity_signature.similaritySignatures` is a pure,
/// deterministic function of `(DocumentId, content)` (already proven
/// idempotent by its own module's unittest: folded and canonical text produce
/// identical lanes), so this module recomputes it from the immutable source
/// shard content `joinShards` already binds the overlay record to via
/// `contentDigest` -- the same "re-derive from source content" idiom
/// `exact_dedup_overlay.d` itself uses for its own digest field. Every
/// recomputed band hash is then checked against the persisted `bandKeyValue`
/// before it may contribute a candidate row: a tampered or stale bucket
/// overlay is rejected here, not silently trusted.
module effects.near_dedup_overlay;

import core.stdc.errno : errno, ENOENT;
import core.sys.posix.sys.stat : lstat, stat_t, S_ISREG;
import crypto.sha256 : sha256Of;
import domain.document : DocumentId;
import domain.near_dedup_decision : NearDedupCandidate, NearDuplicateLink,
    nearDuplicateLinksInBucket, nearDuplicateThreshold;
import domain.shard_format : AnnotationField, AnnotationRecord, ShardDocument;
import domain.similarity_signature : SimilaritySignature, SimilaritySignatures,
    signatureVersion, similarityBands, similarityLanes, similaritySignatures;
import effects.document_shards : JoinedOverlay, OverlayWriter, PublishFault,
    PublishStep, joinShards;
import effects.similarity_buckets : SimilarityBucketMember, decodeSimilarityBucketMembers,
    similarityBucketsAnalyzerKey;
import std.algorithm.sorting : sort;
import std.conv : to;
import std.exception : enforce;
import std.file : SpanMode, dirEntries, isDir, isSymlink, mkdir, remove, rmdir;
import std.path : absolutePath, buildNormalizedPath, buildPath, dirName;
import std.stdio : File;
import std.string : toStringz;
import std.uuid : randomUUID;

static assert(nearDuplicateThreshold == 0.8,
    "near dedup overlay: analyzer version string below embeds the threshold " ~
    "literal -- update it if domain.near_dedup_decision.nearDuplicateThreshold changes");

enum nearDedupAnalyzerKey = "near-dedup";
enum nearDedupAnalyzerVersion = "near-dedup:v1:signature=" ~ signatureVersion ~ ":threshold=0.80";
private enum runRecords = 32;
private enum fanIn = 8;
private enum maxScratchFrame = 8192;

/// One source C01 shard, its upstream `similarity-buckets` overlay, and this
/// analyzer's own destination overlay.
struct NearDedupShard {
    string source;
    string bucketsOverlay;
    string destination;
}

/// Decode exactly the four canonical near-dedup fields after C01's revision
/// join against `source`, the shard document `fields` names. Matches
/// `exact_dedup_overlay.decodeCanonicalDedupLink`'s rigor: exact field count,
/// exact field order, exact digest length and content, and a
/// representative-vs-duplicate-flag consistency check -- here a stronger one
/// than exact-dedup's, since this analyzer only ever persists
/// non-representative rows, so `representative.text` must be strictly less
/// than `source.id.text`, never equal.
NearDuplicateLink decodeCanonicalNearDedupLink(AnnotationField[] fields,
        ShardDocument source) {
    enum bad = "near dedup overlay: malformed canonical link";
    enforce(fields.length == 4 &&
        fields[0].key == "content_digest_sha256" &&
        fields[1].key == "duplicate" &&
        fields[2].key == "representative_id" &&
        fields[3].key == "signature_version", bad);
    enforce(fields[0].value.length == 32 &&
        fields[0].value == sha256Of(source.content)[] &&
        fields[1].value.length == 1 && fields[1].value[0] == 1 &&
        fields[3].value == cast(const(ubyte)[])signatureVersion, bad);
    auto representative = DocumentId.fromCanonicalText(cast(string)fields[2].value);
    enforce(representative.text < source.id.text, bad);
    NearDuplicateLink result;
    result.documentId = source.id;
    result.representativeId = representative;
    return result;
}

private string identity(stat_t info) {
    return info.st_dev.to!string ~ ":" ~ info.st_ino.to!string;
}

/// Explodes each shard's already-decoded, already-capped `similarity-buckets`
/// membership into per-bucket candidate rows, resolves each `(bandIndex,
/// bandKeyValue)` bucket independently through the unmodified pure decision
/// function, and publishes one strictly-ID-sorted C01 overlay per shard
/// naming every non-representative document's representative.
void writeNearDedupOverlays(const(NearDedupShard)[] inputs, PublishFault fault = null) {
    if (!inputs.length) return;

    // Canonicalize shard order by source path so output never depends on the
    // caller's array order, matching both upstream overlay writers.
    auto order = new size_t[inputs.length];
    foreach (i, ref value; order) value = i;
    order.sort!((a, b) => inputs[a].source < inputs[b].source);
    auto shards = new NearDedupShard[inputs.length];
    foreach (canonicalIndex, originalIndex; order) shards[canonicalIndex] = inputs[originalIndex];
    auto plan = PreflightPlan(shards);

    auto scratch = buildPath(plan.directory, ".near-dedup-" ~ randomUUID.toString);
    mkdir(scratch);
    scope(exit) {
        foreach (entry; dirEntries(scratch, SpanMode.shallow)) remove(entry.name);
        rmdir(scratch);
    }
    size_t serial;
    string fresh() { return buildPath(scratch, (serial++).to!string ~ ".run"); }

    // Phase A: join every shard's C01 source against its own similarity-
    // buckets overlay (joinShards already enforces the source-shard digest
    // binding and rejects a stale content revision). For every document with
    // a present bucket-membership record, recompute its real
    // SimilaritySignatures from the immutable source content -- the pure,
    // deterministic function `similarity_buckets.d` itself never calls -- and
    // verify every surviving band's recomputed hash against the persisted
    // bandKeyValue before it becomes a candidate row. This never explodes a
    // full corpus: `similarity_buckets.d` already capped and grouped what it
    // persisted, so this only iterates that already-bounded surviving set.
    auto runs = RunSet(fresh());
    CandidateRow[] batch;
    uint[string] sourceIndexOf;
    ubyte[32][string] contentDigestOf;
    string expectedBucketsVersion;
    foreach (canonicalIndex, shard; shards) {
        auto index = cast(uint)canonicalIndex;
        joinShards(shard.source, [shard.bucketsOverlay],
            (ShardDocument document, JoinedOverlay[] joined) {
                auto overlay = joined[0];
                if (!overlay.present) return;
                enforce(overlay.analyzerKey == similarityBucketsAnalyzerKey,
                    "near dedup overlay: wrong upstream analyzer key");
                if (expectedBucketsVersion.length == 0)
                    expectedBucketsVersion = overlay.analyzerVersion;
                enforce(overlay.analyzerVersion == expectedBucketsVersion,
                    "near dedup overlay: inconsistent upstream analyzer version across shards");
                auto members = decodeSimilarityBucketMembers(overlay.fields);
                if (!members.length) return;

                auto idText = document.id.text;
                if (auto existing = idText in sourceIndexOf)
                    enforce(*existing == index,
                        "near dedup overlay: document ID claimed by more than one shard");
                else
                    sourceIndexOf[idText] = index;
                contentDigestOf[idText] = document.contentDigest;

                auto signatures = similaritySignatures(document.id, document.content);
                foreach (member; members) {
                    auto signature = member.segment ?
                        segmentSignature(signatures, member.segmentOrdinal) :
                        signatures.document;
                    // similarity_buckets.d's own explode() never persists a
                    // band member for a signature lacking real content
                    // (hasKeys == false); this is a fail-closed guard against
                    // a tampered or otherwise-malformed upstream overlay, not
                    // a path this repo's real writer can reach.
                    enforce(signature.hasKeys,
                        "near dedup overlay: bucket member lacks a real signature");
                    enforce(signature.bands[member.bandIndex] == member.bandKeyValue,
                        "near dedup overlay: recomputed band key mismatch " ~
                        "(tampered or stale bucket overlay)");
                    batch ~= CandidateRow(member.bandIndex, member.bandKeyValue,
                        member.overflowed, index, signature);
                    if (batch.length == runRecords) flushRun(batch, runs, &fresh);
                }
            });
    }
    if (batch.length) flushRun(batch, runs, &fresh);
    runs = mergeRuns(runs, &fresh);

    // Phase B: a single sequential scan over the (bandIndex, bandKeyValue,
    // documentId)-sorted candidate stream groups exactly one already-capped
    // bucket into memory at a time -- never a full-corpus structure -- and
    // hands it, unmodified, to the existing pure decision function.
    OutputLink[] outputs;
    if (runs.count) {
        auto sorted = File(runs.firstPath(), "rb");
        scope(exit) sorted.close();
        CandidateRow item;
        bool hasItem = readRecord(sorted, item);
        while (hasItem) {
            auto bandIndex = item.bandIndex;
            auto bandKeyValue = item.bandKeyValue;
            NearDedupCandidate[] members;
            while (hasItem && item.bandIndex == bandIndex && item.bandKeyValue == bandKeyValue) {
                members ~= NearDedupCandidate(item.signature.segment,
                    item.signature.segmentOrdinal, item.bandIndex, item.bandKeyValue,
                    item.overflowed, item.signature);
                hasItem = readRecord(sorted, item);
            }
            foreach (link; nearDuplicateLinksInBucket(members)) {
                auto docText = link.documentId.text;
                outputs ~= OutputLink(docText, sourceIndexOf[docText], link.representativeId.text);
            }
        }
    }

    // Phase C: a document's own signature explodes into up to
    // `similarityBands` band rows, so it may be a member of more than one
    // bucket at once, and two buckets may independently reach different
    // representatives for it (full cross-bucket graph closure is explicitly
    // out of scope, same boundary the pure decision layer itself draws).
    // C01 nonetheless demands exactly one overlay record per document
    // (OverlayWriter.append requires strictly increasing IDs), so
    // conflicting per-document outcomes are resolved by taking the
    // lexicographically smallest representative across every bucket that
    // named one for that document -- the same smallest-ID rule already
    // governing representative selection itself, applied once more as a
    // deterministic, order-invariant tie-break. It makes no new pairwise
    // near-duplicate decision the pure function did not already make on its
    // own bucket.
    string[string] representativeOf;
    foreach (output; outputs) {
        auto existing = output.documentId in representativeOf;
        if (existing is null || output.representativeId < *existing)
            representativeOf[output.documentId] = output.representativeId;
    }
    OutputLink[] finalLinks;
    finalLinks.reserve(representativeOf.length);
    foreach (documentId, representativeId; representativeOf)
        finalLinks ~= OutputLink(documentId, sourceIndexOf[documentId], representativeId);
    finalLinks.sort!((a, b) => a.sourceIndex == b.sourceIndex ?
        a.documentId < b.documentId : a.sourceIndex < b.sourceIndex);

    // The one-time plan rejects every destination against all source and
    // buckets-overlay paths/inodes across the whole batch, then rechecks the
    // active shard again immediately before its writer opens and on every
    // fault-hook call while it publishes -- the same discipline both
    // upstream overlay writers already use.
    plan.validateAllDestinations();
    size_t at;
    foreach (canonicalIndex, shard; shards) {
        plan.validateSource(canonicalIndex);
        plan.validateDestination(canonicalIndex);
        auto writer = new OverlayWriter(shard.destination, shard.source,
            nearDedupAnalyzerKey, nearDedupAnalyzerVersion);
        scope(failure) writer.abort();
        while (at < finalLinks.length && finalLinks[at].sourceIndex == canonicalIndex) {
            auto link = finalLinks[at];
            writer.append(annotation(link, contentDigestOf[link.documentId]));
            ++at;
        }
        PublishFault checkedFault = (PublishStep step) {
            if (fault !is null) fault(step);
            plan.validateSource(canonicalIndex);
            plan.validateDestination(canonicalIndex);
        };
        writer.publish(checkedFault);
    }
    enforce(at == finalLinks.length, "near dedup overlay: orphan sorted link");
}

private SimilaritySignature segmentSignature(SimilaritySignatures signatures, size_t ordinal) {
    enforce(ordinal < signatures.segments.length,
        "near dedup overlay: segment ordinal out of range");
    return signatures.segments[ordinal];
}

private AnnotationRecord annotation(OutputLink link, ubyte[32] contentDigest) {
    AnnotationRecord record;
    record.documentId = link.documentId;
    record.contentDigest = contentDigest;
    record.fields = [
        AnnotationField("content_digest_sha256", contentDigest[].dup),
        AnnotationField("duplicate", [cast(ubyte)1]),
        AnnotationField("representative_id", cast(ubyte[])link.representativeId.dup),
        AnnotationField("signature_version", cast(ubyte[])signatureVersion.dup),
    ];
    return record;
}

/// Batch-wide source/destination safety, mirroring both upstream overlay
/// writers' own PreflightPlan exactly, extended to also guard the upstream
/// buckets overlay (a second read-only input this module must not clobber).
private struct PreflightPlan {
    string directory;
    string[] sources;
    string[] destinations;
    string[] sourceIdentities;
    bool[string] sourcePaths;
    bool[string] sourceInodes;
    bool[string] destinationPaths;

    this(const(NearDedupShard)[] canonicalShards) {
        foreach (shard; canonicalShards) {
            auto source = buildNormalizedPath(absolutePath(shard.source));
            auto bucketsOverlay = buildNormalizedPath(absolutePath(shard.bucketsOverlay));
            auto destination = buildNormalizedPath(absolutePath(shard.destination));
            auto parent = dirName(destination);
            enforce(isDir(parent) && !isSymlink(parent),
                "near dedup overlay: output directory is unsafe");
            if (directory.length) enforce(directory == parent,
                "near dedup overlay: destinations must share one output directory");
            directory = parent;
            enforce((destination in destinationPaths) is null,
                "near dedup overlay: duplicate near-dedup destination");
            destinationPaths[destination] = true;

            stat_t sourceInfo;
            enforce(lstat(source.toStringz, &sourceInfo) == 0 && S_ISREG(sourceInfo.st_mode),
                "near dedup overlay: source is not a regular shard");
            stat_t bucketsInfo;
            enforce(lstat(bucketsOverlay.toStringz, &bucketsInfo) == 0 &&
                S_ISREG(bucketsInfo.st_mode),
                "near dedup overlay: buckets overlay is not a regular file");

            sources ~= source;
            destinations ~= destination;
            sourceIdentities ~= identity(sourceInfo);
            sourcePaths[source] = true;
            sourcePaths[bucketsOverlay] = true;
            sourceInodes[identity(sourceInfo)] = true;
            sourceInodes[identity(bucketsInfo)] = true;
        }
        foreach (i, destination; destinations) {
            enforce((destination in sourcePaths) is null,
                "near dedup overlay: destination aliases a source or buckets-overlay path");
            validateDestination(i);
        }
    }

    void validateSource(size_t i) {
        stat_t info;
        enforce(lstat(sources[i].toStringz, &info) == 0 && S_ISREG(info.st_mode) &&
            identity(info) == sourceIdentities[i],
            "near dedup overlay: source changed during publication");
    }

    void validateAllDestinations() {
        foreach (i; 0 .. destinations.length) validateDestination(i);
    }

    void validateDestination(size_t i) {
        enforce(isDir(directory) && !isSymlink(directory),
            "near dedup overlay: output directory changed");
        stat_t target;
        if (lstat(destinations[i].toStringz, &target) != 0) {
            enforce(errno == ENOENT, "near dedup overlay: cannot inspect destination");
            return;
        }
        enforce(S_ISREG(target.st_mode) && target.st_nlink == 1,
            "near dedup overlay: destination is nonregular or hardlinked");
        enforce((identity(target) in sourceInodes) is null,
            "near dedup overlay: destination aliases a source or buckets-overlay inode");
    }
}

private struct CandidateRow {
    size_t bandIndex;
    ulong bandKeyValue;
    bool overflowed;
    uint sourceIndex;
    SimilaritySignature signature; // hasKeys is always true for a persisted row.
}
private struct OutputLink {
    string documentId;
    uint sourceIndex;
    string representativeId;
}

private bool candidateRowLess(CandidateRow a, CandidateRow b) {
    if (a.bandIndex != b.bandIndex) return a.bandIndex < b.bandIndex;
    if (a.bandKeyValue != b.bandKeyValue) return a.bandKeyValue < b.bandKeyValue;
    return a.signature.documentId.text < b.signature.documentId.text;
}

private void number(ref ubyte[] bytes, ulong value) {
    foreach_reverse (shift; [0, 8, 16, 24, 32, 40, 48, 56])
        bytes ~= cast(ubyte)(value >> shift);
}
private ulong number64(const(ubyte)[] bytes, ref size_t at) {
    enforce(at + 8 <= bytes.length, "near dedup overlay: short u64 scratch field");
    ulong value;
    foreach (_; 0 .. 8) value = (value << 8) | bytes[at++];
    return value;
}
private void appendBytes(ref ubyte[] outBytes, const(ubyte)[] value) {
    number(outBytes, value.length);
    outBytes ~= value;
}
private ubyte[] takeBytes(const(ubyte)[] bytes, ref size_t offset) {
    auto length = number64(bytes, offset);
    enforce(length <= bytes.length - offset, "near dedup overlay: short scratch field");
    auto result = bytes[offset .. offset + cast(size_t)length].dup;
    offset += cast(size_t)length;
    return result;
}

private ubyte[] encode(CandidateRow item) {
    ubyte[] bytes;
    number(bytes, item.bandIndex);
    number(bytes, item.bandKeyValue);
    bytes ~= cast(ubyte)(item.overflowed ? 1 : 0);
    number(bytes, item.sourceIndex);
    appendBytes(bytes, cast(const(ubyte)[])item.signature.documentId.text);
    bytes ~= cast(ubyte)(item.signature.segment ? 1 : 0);
    number(bytes, item.signature.segmentOrdinal);
    foreach (lane; item.signature.lanes) number(bytes, lane);
    return bytes;
}
private CandidateRow decodeCandidateRow(const(ubyte)[] bytes) {
    CandidateRow item;
    size_t at;
    item.bandIndex = cast(size_t)number64(bytes, at);
    item.bandKeyValue = number64(bytes, at);
    enforce(at < bytes.length, "near dedup overlay: short candidate row");
    item.overflowed = bytes[at++] != 0;
    item.sourceIndex = cast(uint)number64(bytes, at);
    auto idText = cast(string)takeBytes(bytes, at);
    item.signature.documentId = DocumentId.fromCanonicalText(idText);
    enforce(at < bytes.length, "near dedup overlay: short candidate row");
    item.signature.segment = bytes[at++] != 0;
    item.signature.segmentOrdinal = cast(size_t)number64(bytes, at);
    item.signature.hasKeys = true;
    foreach (ref lane; item.signature.lanes) lane = number64(bytes, at);
    enforce(at == bytes.length, "near dedup overlay: bad candidate row length");
    return item;
}

private void writeFrame(File file, const(ubyte)[] bytes) {
    enforce(bytes.length <= maxScratchFrame, "near dedup overlay: scratch frame too large");
    ubyte[] prefix;
    number(prefix, bytes.length);
    file.rawWrite(prefix);
    file.rawWrite(bytes);
}
private bool readFrame(File file, out ubyte[] bytes) {
    ubyte[8] prefix;
    auto first = file.rawRead(prefix[]);
    if (!first.length) return false;
    enforce(first.length == 8, "near dedup overlay: short scratch frame header");
    size_t at;
    auto length = number64(prefix[], at);
    enforce(length <= maxScratchFrame, "near dedup overlay: oversized scratch frame");
    bytes = new ubyte[cast(size_t)length];
    enforce(file.rawRead(bytes).length == length, "near dedup overlay: short scratch frame");
    return true;
}
private bool readRecord(File file, out CandidateRow item) {
    ubyte[] bytes;
    if (!readFrame(file, bytes)) return false;
    item = decodeCandidateRow(bytes);
    return true;
}

private struct RunSet {
    string manifest;
    size_t count;
    this(string manifest) {
        this.manifest = manifest;
        auto file = File(manifest, "wb");
        file.close();
    }
    void append(string path) {
        auto file = File(manifest, "ab");
        scope(exit) file.close();
        writeFrame(file, cast(const(ubyte)[])path);
        ++count;
    }
    string firstPath() {
        enforce(count == 1, "near dedup overlay: expected one sorted run");
        auto file = File(manifest, "rb");
        scope(exit) file.close();
        ubyte[] bytes;
        enforce(readFrame(file, bytes), "near dedup overlay: missing run path");
        return cast(string)bytes;
    }
}
private void flushRun(ref CandidateRow[] batch, ref RunSet runs, string delegate() fresh) {
    batch.sort!candidateRowLess;
    auto path = fresh();
    auto file = File(path, "wb");
    scope(exit) file.close();
    foreach (item; batch) writeFrame(file, encode(item));
    runs.append(path);
    batch.length = 0;
}
private RunSet mergeRuns(RunSet runs, string delegate() fresh) {
    while (runs.count > 1) {
        auto next = RunSet(fresh());
        auto manifest = File(runs.manifest, "rb");
        scope(exit) manifest.close();
        for (size_t start; start < runs.count; start += fanIn) {
            auto end = start + fanIn < runs.count ? start + fanIn : runs.count;
            auto output = fresh();
            auto writer = File(output, "wb");
            File[] readers;
            CandidateRow[] heads;
            bool[] present;
            scope(exit) {
                foreach (ref reader; readers) reader.close();
                writer.close();
            }
            foreach (_; start .. end) {
                ubyte[] pathBytes;
                enforce(readFrame(manifest, pathBytes), "near dedup overlay: missing run in manifest");
                auto path = cast(string)pathBytes;
                readers ~= File(path, "rb");
                CandidateRow item;
                present ~= readRecord(readers[$ - 1], item);
                heads ~= item;
            }
            while (true) {
                size_t minimum = size_t.max;
                foreach (i, active; present)
                    if (active && (minimum == size_t.max ||
                            candidateRowLess(heads[i], heads[minimum])))
                        minimum = i;
                if (minimum == size_t.max) break;
                writeFrame(writer, encode(heads[minimum]));
                present[minimum] = readRecord(readers[minimum], heads[minimum]);
            }
            next.append(output);
        }
        auto old = File(runs.manifest, "rb");
        while (true) {
            ubyte[] path;
            if (!readFrame(old, path)) break;
            remove(cast(string)path);
        }
        old.close();
        manifest.close();
        remove(runs.manifest);
        runs = next;
    }
    return runs;
}

version (unittest) {
    import domain.document : OutputName, SourceLocator;
    import effects.document_shards : DocumentShardReader, DocumentShardWriter,
        OverlayReader;
    import effects.similarity_buckets : SimilarityBatchEntry, SimilarityShard,
        defaultSimilarityBucketCap, similarityBatchReader, writeSimilarityBucketOverlays;
    import std.algorithm.searching : canFind;
    import std.file : exists, mkdirRecurse, read, rmdirRecurse, tempDir, write;

    private ShardDocument testDocument(string source, string key, string content) {
        return ShardDocument(SourceLocator("near-dedup-overlay-test", source, key),
            OutputName(key), cast(ubyte[])content.dup);
    }

    private void writeSourceShard(string path, ShardDocument[] documents) {
        documents.sort!((a, b) => a.id.text < b.id.text);
        auto writer = new DocumentShardWriter(path);
        foreach (record; documents) writer.append(record);
        writer.publish();
    }

    /// Builds a real similarity-buckets overlay (via the actual, unmodified
    /// upstream writer) for one C01 source shard's documents, then returns a
    /// `NearDedupShard` wired to a caller-chosen destination path. Exercises
    /// the true upstream persistence format end to end, not a hand-rolled
    /// stand-in for it.
    private NearDedupShard buildFixtureShard(string root, string label,
            ShardDocument[] documents, string destination) {
        auto sourcePath = buildPath(root, label ~ "-source.shard");
        writeSourceShard(sourcePath, documents);
        SimilarityBatchEntry[] entries;
        foreach (record; documents)
            entries ~= SimilarityBatchEntry(
                similaritySignatures(record.id, record.content), record.contentDigest, 0);
        auto bucketsPath = buildPath(root, label ~ "-buckets.overlay");
        writeSimilarityBucketOverlays([SimilarityShard(sourcePath, bucketsPath)],
            similarityBatchReader(entries));
        return NearDedupShard(sourcePath, bucketsPath, destination);
    }

    private AnnotationRecord[] readAllAnnotations(string path) {
        auto reader = new OverlayReader(path);
        scope(exit) reader.closeReader();
        AnnotationRecord[] records;
        AnnotationRecord record;
        while (reader.next(record)) records ~= record;
        return records;
    }

    private ShardDocument[] readAllDocuments(string path) {
        auto reader = new DocumentShardReader(path);
        scope(exit) reader.closeReader();
        ShardDocument[] records;
        ShardDocument record;
        while (reader.next(record)) records ~= record;
        return records;
    }

    private string scratchRoot(string label) {
        auto root = buildPath(tempDir(), "near-dedup-overlay-check-" ~ label ~ "-" ~
            randomUUID.toString);
        mkdirRecurse(root);
        return root;
    }
}

unittest {
    // Single-bucket clustering, zero-near-dup handling, and hasKeys==false
    // exclusion, all together in one real fixture: "a" and "b" are two
    // different documents with byte-identical content (jaccardEstimate ==
    // 1.0, well above threshold -- a clean, deterministic above-threshold
    // pair without depending on shingle-hash arithmetic), "solo" has enough
    // distinct content to receive a real signature but never collides with
    // anything (a bucket of its own, zero near-duplicates), and "short" is
    // under the 5-byte minimum shingle length so its signature never gets
    // real keys and must never appear in the output at all.
    auto root = scratchRoot("basic");
    scope(exit) rmdirRecurse(root);
    auto documents = [
        testDocument("s", "a", "the quick brown fox jumps over the lazy dog"),
        testDocument("s", "b", "the quick brown fox jumps over the lazy dog"),
        testDocument("s", "solo", "a wildly different unrelated sentence about oceans"),
        testDocument("s", "short", "hi"),
    ];
    auto destination = buildPath(root, "near-dedup.overlay");
    auto shard = buildFixtureShard(root, "basic", documents, destination);

    writeNearDedupOverlays([shard]);

    auto records = readAllAnnotations(destination);
    auto sourceDocuments = readAllDocuments(shard.source);
    ShardDocument bySourceId(string id) {
        foreach (document; sourceDocuments) if (document.id.text == id) return document;
        assert(false, "missing source document");
    }
    auto aId = testDocument("s", "a", "x").id; // identity only depends on source locator
    auto bId = testDocument("s", "b", "x").id;
    auto soloId = testDocument("s", "solo", "x").id;
    auto shortId = testDocument("s", "short", "x").id;

    // Exactly one non-representative link is published: identical content
    // makes "a" and "b" a cluster of two, and the lexicographically smaller
    // ID is the representative -- reusing exact_dedup_overlay's own rule.
    assert(records.length == 1);
    auto expectedRepresentative = aId.text < bId.text ? aId : bId;
    auto expectedLinked = expectedRepresentative == aId ? bId : aId;
    assert(records[0].documentId == expectedLinked.text);

    auto decoded = decodeCanonicalNearDedupLink(records[0].fields, bySourceId(expectedLinked.text));
    assert(decoded.documentId == expectedLinked);
    assert(decoded.representativeId == expectedRepresentative);

    // "solo" (its own zero-near-duplicate bucket) and "short" (hasKeys ==
    // false, never even exploded into a bucket by the real upstream writer)
    // never appear in the output at all.
    assert(!records.canFind!(r => r.documentId == soloId.text));
    assert(!records.canFind!(r => r.documentId == shortId.text));

    // Overlay header identifies this analyzer distinctly from both upstream
    // analyzers.
    auto reader = new OverlayReader(destination);
    scope(exit) reader.closeReader();
    assert(reader.header.analyzerKey == nearDedupAnalyzerKey);
    assert(reader.header.analyzerVersion == nearDedupAnalyzerVersion);
    assert(reader.header.analyzerKey != "exact-dedup");
    assert(reader.header.analyzerKey != "similarity-buckets");
}

unittest {
    // A real multi-member near-dup cluster: three documents with identical
    // content cluster together (connected-component grouping, not just
    // direct pairwise links), leaving exactly two non-representative records
    // naming the one lexicographically-smallest representative.
    auto root = scratchRoot("cluster");
    scope(exit) rmdirRecurse(root);
    auto content = "identical content shared by every member of this cluster";
    auto documents = [
        testDocument("s", "m1", content),
        testDocument("s", "m2", content),
        testDocument("s", "m3", content),
    ];
    auto destination = buildPath(root, "near-dedup.overlay");
    auto shard = buildFixtureShard(root, "cluster", documents, destination);

    writeNearDedupOverlays([shard]);

    auto records = readAllAnnotations(destination);
    assert(records.length == 2);
    string[] ids;
    foreach (document; documents) ids ~= document.id.text;
    ids.sort();
    auto expectedRepresentative = ids[0];
    auto sourceDocuments = readAllDocuments(shard.source);
    foreach (record; records) {
        ShardDocument matched;
        bool found;
        foreach (d; sourceDocuments) if (d.id.text == record.documentId) { matched = d; found = true; }
        assert(found);
        auto decoded = decodeCanonicalNearDedupLink(record.fields, matched);
        assert(decoded.representativeId.text == expectedRepresentative);
        assert(decoded.documentId.text != expectedRepresentative);
    }
}

unittest {
    // Deterministic, worker-order-invariant output: the same three shards,
    // supplied in every permutation of input order, publish byte-identical
    // overlay content.
    auto root = scratchRoot("order");
    scope(exit) rmdirRecurse(root);
    auto content = "shared duplicate content spanning more than one input shard";
    auto shardA = buildFixtureShard(root, "order-a",
        [testDocument("a", "x", content)], buildPath(root, "a.overlay"));
    auto shardB = buildFixtureShard(root, "order-b",
        [testDocument("b", "y", content)], buildPath(root, "b.overlay"));
    auto shardC = buildFixtureShard(root, "order-c",
        [testDocument("c", "z", "totally unrelated content about mountains and rivers")],
        buildPath(root, "c.overlay"));

    NearDedupShard[][] orderings = [
        [shardA, shardB, shardC],
        [shardC, shardB, shardA],
        [shardB, shardA, shardC],
        [shardC, shardA, shardB],
    ];
    ubyte[] baselineA, baselineB, baselineC;
    foreach (i, ordering; orderings) {
        writeNearDedupOverlays(ordering);
        auto bytesA = cast(ubyte[])read(shardA.destination);
        auto bytesB = cast(ubyte[])read(shardB.destination);
        auto bytesC = cast(ubyte[])read(shardC.destination);
        if (i == 0) { baselineA = bytesA; baselineB = bytesB; baselineC = bytesC; }
        else {
            assert(bytesA == baselineA, "shard A overlay differs by input order");
            assert(bytesB == baselineB, "shard B overlay differs by input order");
            assert(bytesC == baselineC, "shard C overlay differs by input order");
        }
        remove(shardA.destination);
        remove(shardB.destination);
        remove(shardC.destination);
    }
}

unittest {
    // Restart safety: a publish interrupted mid-flight (simulated by a fault
    // hook that throws once, after the first shard's temporary file is
    // fsynced but before it is published) leaves no destination behind. A
    // clean re-run from the same immutable inputs afterward produces exactly
    // the same final overlay bytes as an uninterrupted run.
    auto rootA = scratchRoot("restart-clean");
    scope(exit) rmdirRecurse(rootA);
    auto content = "restart-safety fixture content shared by two documents";
    auto documents = [testDocument("s", "one", content), testDocument("s", "two", content)];
    auto destinationA = buildPath(rootA, "near-dedup.overlay");
    auto cleanShard = buildFixtureShard(rootA, "restart-clean", documents, destinationA);
    writeNearDedupOverlays([cleanShard]);
    auto baseline = cast(ubyte[])read(destinationA);

    auto rootB = scratchRoot("restart-resume");
    scope(exit) rmdirRecurse(rootB);
    auto destinationB = buildPath(rootB, "near-dedup.overlay");
    auto resumedShard = buildFixtureShard(rootB, "restart-resume", documents, destinationB);
    bool fired;
    PublishFault crashOnce = (PublishStep step) {
        if (!fired && step == PublishStep.afterFsync) {
            fired = true;
            throw new Exception("simulated crash mid-publish");
        }
    };
    try { writeNearDedupOverlays([resumedShard], crashOnce); assert(false, "expected simulated crash"); }
    catch (Exception) {}
    assert(!exists(destinationB), "a crashed publish must not leave a destination behind");

    // Resume: re-run the whole call from scratch against the same immutable
    // source and buckets overlay.
    writeNearDedupOverlays([resumedShard]);
    auto resumed = cast(ubyte[])read(destinationB);
    assert(resumed == baseline, "resumed run must match an uninterrupted run byte-for-byte");
}

unittest {
    // Fail-closed decode: a tampered representative_id field is rejected,
    // and a truncated frame is rejected by the shared C01 frame checksum
    // before this analyzer's own field checks ever run.
    auto root = scratchRoot("tamper");
    scope(exit) rmdirRecurse(root);
    auto content = "tamper-detection fixture content shared by two documents";
    auto documents = [testDocument("s", "one", content), testDocument("s", "two", content)];
    auto destination = buildPath(root, "near-dedup.overlay");
    auto shard = buildFixtureShard(root, "tamper", documents, destination);
    writeNearDedupOverlays([shard]);

    auto records = readAllAnnotations(destination);
    assert(records.length == 1);
    auto sourceDocuments = readAllDocuments(shard.source);
    ShardDocument matched;
    foreach (d; sourceDocuments) if (d.id.text == records[0].documentId) matched = d;

    // A tampered representative_id (flipped to no longer be lexicographically
    // smaller than the document's own ID) violates the consistency check.
    auto tampered = records[0];
    tampered.fields = tampered.fields.dup;
    tampered.fields[2] = AnnotationField("representative_id", cast(ubyte[])matched.id.text.dup);
    bool rejected;
    try { decodeCanonicalNearDedupLink(tampered.fields, matched); }
    catch (Exception) rejected = true;
    assert(rejected, "a representative_id equal to the document's own ID must be rejected");

    // A truncated overlay file (chop the last byte of the digest trailer of
    // the last frame) is rejected outright at the shared C01 frame level.
    auto raw = cast(ubyte[])read(destination);
    write(destination, raw[0 .. $ - 1]);
    bool truncatedRejected;
    try {
        auto reader = new OverlayReader(destination);
        scope(exit) reader.closeReader();
        AnnotationRecord record;
        while (reader.next(record)) {}
    } catch (Exception) truncatedRejected = true;
    assert(truncatedRejected, "a truncated overlay file must be rejected");
}
