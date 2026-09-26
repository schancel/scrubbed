/// External-memory band-key candidate buckets over caller-supplied signatures.
module effects.similarity_buckets;

import core.stdc.errno : errno, ENOENT;
import core.sys.posix.sys.stat : lstat, stat_t, S_ISREG;
import domain.shard_format : AnnotationField, AnnotationRecord;
import domain.similarity_signature : SimilaritySignature, SimilaritySignatures,
    signatureVersion, similarityBands;
import effects.document_shards : OverlayWriter, PublishFault, PublishStep;
import std.algorithm.sorting : sort;
import std.conv : to;
import std.exception : enforce;
import std.file : SpanMode, dirEntries, isDir, isSymlink, mkdir, remove, rmdir;
import std.path : absolutePath, buildNormalizedPath, buildPath, dirName;
import std.stdio : File;
import std.string : toStringz;
import std.uuid : randomUUID;

enum similarityBucketsAnalyzerKey = "similarity-buckets";
enum similarityBucketsFieldKey = "members";
enum defaultSimilarityBucketCap = 4096;
private enum runRecords = 32;
private enum fanIn = 8;
private enum maxScratchFrame = 128 * 1024;

/// Embeds both the bucket cap and the frozen signature profile so a change to
/// either is a detectable overlay-header mismatch, never silent corruption.
string similarityBucketsAnalyzerVersion(size_t bucketCap = defaultSimilarityBucketCap) {
    return "similarity-buckets:v1:signature=" ~ signatureVersion ~
        ":cap=" ~ bucketCap.to!string;
}

/// One source C01 shard and its similarity-bucket overlay destination.
struct SimilarityShard {
    string source;
    string destination;
}

/// One document's signatures, already matched to a shard by the caller. This
/// module never reads C01 shards or computes signatures itself.
struct SimilarityBatchEntry {
    SimilaritySignatures signatures;
    ubyte[32] contentDigest;
    uint sourceIndex; // index into the shards[] passed to the writer below
}

alias SimilarityBatchReader = bool delegate(out SimilarityBatchEntry entry);

/// Wraps an already-materialized batch as a bounded pull reader. Convenience
/// for small/test callers; production callers should stream from their own
/// bounded source instead of holding the whole corpus in one array.
SimilarityBatchReader similarityBatchReader(const(SimilarityBatchEntry)[] entries) {
    size_t at;
    return (out SimilarityBatchEntry entry) {
        if (at >= entries.length) return false;
        entry = cast(SimilarityBatchEntry) entries[at++];
        return true;
    };
}

/// One decoded band-membership row after C01's shard/revision join.
struct SimilarityBucketMember {
    bool segment;
    size_t segmentOrdinal;
    size_t bandIndex;
    ulong bandKeyValue;
    bool overflowed;
}

// Release-checker-only observation of scratch file-descriptor and batch-size
// bounds. This does not participate in production decisions or add a public
// runtime hook.
version (SimilarityBucketsCheck) {
    private __gshared size_t openScratchFilesCurrent;
    private __gshared size_t openScratchFilesPeak;
    private __gshared size_t batchPeakRecords;
    size_t similarityBucketsPeakOpenScratchFiles() { return openScratchFilesPeak; }
    size_t similarityBucketsPeakBatchRecords() { return batchPeakRecords; }
    void resetSimilarityBucketsObservations() {
        openScratchFilesCurrent = 0;
        openScratchFilesPeak = 0;
        batchPeakRecords = 0;
    }
}
private void trackOpen() {
    version (SimilarityBucketsCheck) {
        ++openScratchFilesCurrent;
        if (openScratchFilesCurrent > openScratchFilesPeak)
            openScratchFilesPeak = openScratchFilesCurrent;
    }
}
private void trackClose() {
    version (SimilarityBucketsCheck) if (openScratchFilesCurrent) --openScratchFilesCurrent;
}
private void trackBatch(size_t size) {
    version (SimilarityBucketsCheck) if (size > batchPeakRecords) batchPeakRecords = size;
}

private string identity(stat_t info) {
    return info.st_dev.to!string ~ ":" ~ info.st_ino.to!string;
}

/// Decode exactly this analyzer's single packed field after C01's join. The
/// caller must already have verified the overlay header's analyzer key and
/// version (see similarityBucketsAnalyzerKey/Version), matching every other
/// C01 overlay reader in this codebase.
SimilarityBucketMember[] decodeSimilarityBucketMembers(const(AnnotationField)[] fields) {
    enum bad = "similarity buckets: malformed member field";
    enforce(fields.length == 1 && fields[0].key == similarityBucketsFieldKey, bad);
    auto bytes = fields[0].value;
    size_t at;
    auto count = get16(bytes, at);
    SimilarityBucketMember[] result;
    result.reserve(count);
    bool haveLast;
    SimilarityBucketMember last;
    foreach (_; 0 .. count) {
        enforce(at < bytes.length, bad);
        auto flags = bytes[at++];
        enforce((flags & 0xC0) == 0, bad);
        SimilarityBucketMember member;
        member.bandIndex = flags & 0x0F;
        member.segment = (flags & 0x10) != 0;
        member.overflowed = (flags & 0x20) != 0;
        member.segmentOrdinal = get16(bytes, at);
        member.bandKeyValue = number64(bytes, at);
        enforce(member.bandIndex < similarityBands, bad);
        if (haveLast) enforce(memberOrderLess(last, member), bad ~ ": not strictly ordered");
        last = member;
        haveLast = true;
        result ~= member;
    }
    enforce(at == bytes.length, bad);
    return result;
}

/// Explodes caller-supplied signatures into per-band candidate members, keyed
/// by (bandIndex, bandKeyValue), external-sorts them into fixed skew-capped
/// buckets, and persists the surviving band memberships as a durable C01
/// overlay analyzer -- one record per document, strictly ID-sorted, exactly
/// like every other overlay writer in this codebase. No duplicate decision,
/// representative selection, or cross-band grouping happens here.
void writeSimilarityBucketOverlays(const(SimilarityShard)[] shards,
        scope SimilarityBatchReader next, size_t bucketCap = defaultSimilarityBucketCap,
        PublishFault fault = null) {
    enforce(bucketCap > 0, "similarity buckets: cap must be positive");
    enforce(next !is null, "similarity buckets: missing batch reader");
    if (!shards.length) {
        SimilarityBatchEntry unused;
        enforce(!next(unused), "similarity buckets: entries supplied without any shard");
        return;
    }

    // Canonicalize shard order by source path so output never depends on the
    // caller's array order; remap caller-supplied indices accordingly.
    auto order = new size_t[shards.length];
    foreach (i, ref value; order) value = i;
    order.sort!((a, b) => shards[a].source < shards[b].source);
    auto canonical = new SimilarityShard[shards.length];
    auto origToCanonical = new uint[shards.length];
    foreach (canonicalIndex, originalIndex; order) {
        canonical[canonicalIndex] = shards[originalIndex];
        origToCanonical[originalIndex] = cast(uint) canonicalIndex;
    }
    // Batch-wide preflight, mirroring exact_dedup_overlay's PreflightPlan: no
    // destination may alias any source across the whole batch (lexically or
    // by inode), not just its own paired source. OverlayWriter.publish only
    // guards a shard's destination against that same shard's own source, so
    // this is the only thing standing between a caller's path-list mistake
    // and silently overwriting another shard's immutable content. Because
    // the external sort below can run for a long time, the active shard's
    // source/destination are re-checked against this same static plan again
    // immediately before each OverlayWriter is opened, and again on every
    // fault-hook call while that shard is publishing -- not just once here.
    auto plan = PreflightPlan(canonical);

    auto scratch = buildPath(plan.directory, ".similarity-buckets-" ~ randomUUID.toString);
    mkdir(scratch);
    scope(exit) {
        foreach (entry; dirEntries(scratch, SpanMode.shallow)) remove(entry.name);
        rmdir(scratch);
    }
    size_t serial;
    string fresh() { return buildPath(scratch, (serial++).to!string ~ ".run"); }

    // Pass 1: explode every signature into per-band candidate members and one
    // identity row per document, in bounded runRecords batches.
    auto bandRuns = RunSet(fresh());
    auto identityRuns = RunSet(fresh());
    BandMember[] bandBatch;
    IdentityRecord[] identityBatch;
    SimilarityBatchEntry entry;
    while (next(entry)) {
        enforce(entry.sourceIndex < shards.length,
            "similarity buckets: source index out of range");
        auto canonicalIndex = origToCanonical[entry.sourceIndex];
        auto documentId = validateSignatures(entry.signatures);
        identityBatch ~= IdentityRecord(documentId, canonicalIndex, entry.contentDigest);
        if (identityBatch.length == runRecords)
            flushRun(identityBatch, identityRuns, &fresh, &identityIdLess);
        explode(entry.signatures.document, canonicalIndex, bandBatch, bandRuns, &fresh);
        foreach (segment; entry.signatures.segments)
            explode(segment, canonicalIndex, bandBatch, bandRuns, &fresh);
    }
    if (identityBatch.length) flushRun(identityBatch, identityRuns, &fresh, &identityIdLess);
    if (bandBatch.length) flushRun(bandBatch, bandRuns, &fresh, &bandMemberLess);
    bandRuns = mergeRuns!BandMember(bandRuns, &bandMemberLess, &fresh);
    identityRuns = mergeRuns!IdentityRecord(identityRuns, &identityIdLess, &fresh);

    // Pass 2: single sequential scan groups consecutive equal (bandIndex,
    // bandKeyValue) records. Only the first bucketCap members (already in
    // stable documentId/segment/segmentOrdinal order) are kept; the group's
    // true size, not the buffered prefix, decides the overflow flag. Memory
    // for one group is bounded by bucketCap, never by corpus size.
    auto assignmentRuns = RunSet(fresh());
    BucketAssignmentRecord[] assignmentBatch;
    if (bandRuns.count) {
        auto sorted = File(bandRuns.firstPath(), "rb");
        trackOpen();
        scope(exit) { sorted.close(); trackClose(); }
        BandMember item;
        bool hasItem = readRecord(sorted, item);
        BandMember[] kept;
        kept.reserve(bucketCap);
        while (hasItem) {
            kept.length = 0;
            auto bandIndex = item.bandIndex;
            auto bandKeyValue = item.bandKeyValue;
            size_t groupSize;
            while (hasItem && item.bandIndex == bandIndex && item.bandKeyValue == bandKeyValue) {
                if (groupSize < bucketCap) kept ~= item;
                enforce(groupSize < size_t.max, "similarity buckets: bucket size overflow");
                ++groupSize;
                hasItem = readRecord(sorted, item);
            }
            auto overflowed = groupSize > bucketCap;
            foreach (member; kept) {
                assignmentBatch ~= BucketAssignmentRecord(member.documentId, member.segment,
                    member.segmentOrdinal, member.bandIndex, member.bandKeyValue,
                    overflowed, member.sourceIndex);
                if (assignmentBatch.length == runRecords)
                    flushRun(assignmentBatch, assignmentRuns, &fresh, &assignmentFinalLess);
            }
        }
    }
    if (assignmentBatch.length)
        flushRun(assignmentBatch, assignmentRuns, &fresh, &assignmentFinalLess);
    assignmentRuns = mergeRuns!BucketAssignmentRecord(assignmentRuns, &assignmentFinalLess, &fresh);

    // Reject a document ID claimed by more than one batch entry (regardless
    // of shard), then re-sort the surviving identity rows into the same
    // (sourceIndex, documentId) order the shard-publication loop needs.
    auto orderedIdentityRuns = RunSet(fresh());
    IdentityRecord[] identityBatch2;
    if (identityRuns.count) {
        auto stream = File(identityRuns.firstPath(), "rb");
        trackOpen();
        scope(exit) { stream.close(); trackClose(); }
        IdentityRecord item;
        string lastDocumentId;
        while (readRecord(stream, item)) {
            enforce(lastDocumentId.length == 0 || lastDocumentId != item.documentId,
                "similarity buckets: duplicate document ID across batch entries");
            lastDocumentId = item.documentId;
            identityBatch2 ~= item;
            if (identityBatch2.length == runRecords)
                flushRun(identityBatch2, orderedIdentityRuns, &fresh, &identityFinalLess);
        }
    }
    if (identityBatch2.length)
        flushRun(identityBatch2, orderedIdentityRuns, &fresh, &identityFinalLess);
    auto orderedIdentity = mergeRuns!IdentityRecord(orderedIdentityRuns, &identityFinalLess, &fresh);

    // The one-time plan rejects every destination against all source paths,
    // inodes and other destinations. Recheck all targets after the external
    // sort above (which may run for a long time), then only the active
    // target after each fault hook: future targets are checked when their
    // turn arrives, without rescanning every pair per publication.
    plan.validateAllDestinations();

    // Pass 3: synchronized merge writes exactly one strictly-ID-sorted C01
    // overlay per shard, packing every surviving band membership for a
    // document into its single annotation field.
    File assignmentStream;
    bool hasAssignment;
    BucketAssignmentRecord assignmentHead;
    if (assignmentRuns.count) {
        assignmentStream = File(assignmentRuns.firstPath(), "rb");
        trackOpen();
        hasAssignment = readRecord(assignmentStream, assignmentHead);
    }
    scope(exit) if (assignmentRuns.count) { assignmentStream.close(); trackClose(); }
    File identityStream;
    bool hasIdentity;
    IdentityRecord identityHead;
    if (orderedIdentity.count) {
        identityStream = File(orderedIdentity.firstPath(), "rb");
        trackOpen();
        hasIdentity = readRecord(identityStream, identityHead);
    }
    scope(exit) if (orderedIdentity.count) { identityStream.close(); trackClose(); }

    foreach (canonicalIndex, shard; canonical) {
        auto index = cast(uint) canonicalIndex;
        plan.validateSource(canonicalIndex);
        plan.validateDestination(canonicalIndex);
        auto writer = new OverlayWriter(shard.destination, shard.source,
            similarityBucketsAnalyzerKey, similarityBucketsAnalyzerVersion(bucketCap));
        scope(failure) writer.abort();
        while (hasAssignment && assignmentHead.sourceIndex == index) {
            auto documentId = assignmentHead.documentId;
            BucketAssignmentRecord[] members;
            while (hasAssignment && assignmentHead.sourceIndex == index &&
                    assignmentHead.documentId == documentId) {
                members ~= assignmentHead;
                hasAssignment = readRecord(assignmentStream, assignmentHead);
            }
            while (hasIdentity && (identityHead.sourceIndex < index ||
                    (identityHead.sourceIndex == index && identityHead.documentId < documentId)))
                hasIdentity = readRecord(identityStream, identityHead);
            enforce(hasIdentity && identityHead.sourceIndex == index &&
                identityHead.documentId == documentId,
                "similarity buckets: missing identity for bucket assignment");
            writer.append(AnnotationRecord(documentId, identityHead.contentDigest,
                [AnnotationField(similarityBucketsFieldKey, encodeMembers(members))]));
        }
        PublishFault checkedFault = (PublishStep step) {
            if (fault !is null) fault(step);
            plan.validateSource(canonicalIndex);
            plan.validateDestination(canonicalIndex);
        };
        writer.publish(checkedFault);
    }
    enforce(!hasAssignment, "similarity buckets: orphan sorted bucket assignment");
}

private string validateSignature(SimilaritySignature signature, bool expectSegment,
        size_t expectOrdinal, string documentId) {
    enforce(signature.profileVersion == signatureVersion,
        "similarity buckets: signature profile version mismatch");
    enforce(signature.documentId.text == documentId,
        "similarity buckets: segment document ID mismatch");
    enforce(signature.segment == expectSegment && signature.segmentOrdinal == expectOrdinal,
        "similarity buckets: malformed signature shape");
    return documentId;
}

private string validateSignatures(SimilaritySignatures signatures) {
    auto documentId = signatures.document.documentId.text;
    enforce(documentId.length != 0, "similarity buckets: empty document ID");
    validateSignature(signatures.document, false, 0, documentId);
    foreach (i, segment; signatures.segments)
        validateSignature(segment, true, i, documentId);
    return documentId;
}

private void explode(SimilaritySignature signature, uint sourceIndex,
        ref BandMember[] batch, ref RunSet runs, string delegate() fresh) {
    if (!signature.hasKeys) return;
    foreach (band; 0 .. similarityBands) {
        batch ~= BandMember(band, signature.bands[band], signature.documentId.text,
            signature.segment, signature.segmentOrdinal, sourceIndex);
        trackBatch(batch.length);
        if (batch.length == runRecords) flushRun(batch, runs, fresh, &bandMemberLess);
    }
}

private bool memberOrderLess(SimilarityBucketMember a, SimilarityBucketMember b) {
    if (a.segment != b.segment) return !a.segment;
    if (a.segmentOrdinal != b.segmentOrdinal) return a.segmentOrdinal < b.segmentOrdinal;
    return a.bandIndex < b.bandIndex;
}

private ubyte[] encodeMembers(const(BucketAssignmentRecord)[] members) {
    enforce(members.length <= ushort.max,
        "similarity buckets: too many surviving members for one document");
    ubyte[] bytes;
    put16(bytes, members.length);
    foreach (member; members) {
        enforce(member.bandIndex < similarityBands, "similarity buckets: band index out of range");
        ubyte flags = cast(ubyte) member.bandIndex;
        if (member.segment) flags |= 0x10;
        if (member.overflowed) flags |= 0x20;
        bytes ~= flags;
        put16(bytes, member.segmentOrdinal);
        number(bytes, member.bandKeyValue);
    }
    return bytes;
}

/// Batch-wide source/destination safety, mirroring exact_dedup_overlay's
/// PreflightPlan exactly: one static snapshot of every source's identity,
/// checked once against every destination up front, then re-checked against
/// the active shard immediately before it opens and on every fault-hook call
/// while it publishes. This is what stands between a caller's path-list
/// mistake (or a source mutated/relinked mid-run) and silently overwriting
/// another shard's immutable content.
private struct PreflightPlan {
    string directory;
    string[] sources;
    string[] destinations;
    string[] sourceIdentities;
    bool[string] sourcePaths;
    bool[string] sourceInodes;
    bool[string] destinationPaths;

    this(const(SimilarityShard)[] canonicalShards) {
        foreach (shard; canonicalShards) {
            auto source = buildNormalizedPath(absolutePath(shard.source));
            auto destination = buildNormalizedPath(absolutePath(shard.destination));
            auto parent = dirName(destination);
            enforce(isDir(parent) && !isSymlink(parent),
                "similarity buckets: output directory is unsafe");
            if (directory.length) enforce(directory == parent,
                "similarity buckets: destinations must share one output directory");
            directory = parent;
            enforce((destination in destinationPaths) is null,
                "similarity buckets: duplicate similarity-bucket destination");
            destinationPaths[destination] = true;
            stat_t info;
            enforce(lstat(source.toStringz, &info) == 0 && S_ISREG(info.st_mode),
                "similarity buckets: source is not a regular shard");
            sources ~= source;
            destinations ~= destination;
            sourceIdentities ~= identity(info);
            sourcePaths[source] = true;
            sourceInodes[sourceIdentities[$ - 1]] = true;
        }
        foreach (i, destination; destinations) {
            enforce((destination in sourcePaths) is null,
                "similarity buckets: destination aliases a source shard path");
            validateDestination(i);
        }
    }

    void validateSource(size_t i) {
        stat_t info;
        enforce(lstat(sources[i].toStringz, &info) == 0 && S_ISREG(info.st_mode) &&
            identity(info) == sourceIdentities[i],
            "similarity buckets: source changed during publication");
    }

    void validateAllDestinations() {
        foreach (i; 0 .. destinations.length) validateDestination(i);
    }

    void validateDestination(size_t i) {
        enforce(isDir(directory) && !isSymlink(directory),
            "similarity buckets: output directory changed");
        stat_t target;
        if (lstat(destinations[i].toStringz, &target) != 0) {
            enforce(errno == ENOENT, "similarity buckets: cannot inspect destination");
            return;
        }
        enforce(S_ISREG(target.st_mode) && target.st_nlink == 1,
            "similarity buckets: destination is nonregular or hardlinked");
        enforce((identity(target) in sourceInodes) is null,
            "similarity buckets: destination aliases a source shard inode");
    }
}

private struct BandMember {
    size_t bandIndex;
    ulong bandKeyValue;
    string documentId;
    bool segment;
    size_t segmentOrdinal;
    uint sourceIndex;
}
private struct BucketAssignmentRecord {
    string documentId;
    bool segment;
    size_t segmentOrdinal;
    size_t bandIndex;
    ulong bandKeyValue;
    bool overflowed;
    uint sourceIndex;
}
private struct IdentityRecord {
    string documentId;
    uint sourceIndex;
    ubyte[32] contentDigest;
}

private bool bandMemberLess(BandMember a, BandMember b) {
    if (a.bandIndex != b.bandIndex) return a.bandIndex < b.bandIndex;
    if (a.bandKeyValue != b.bandKeyValue) return a.bandKeyValue < b.bandKeyValue;
    if (a.documentId != b.documentId) return a.documentId < b.documentId;
    if (a.segment != b.segment) return !a.segment;
    return a.segmentOrdinal < b.segmentOrdinal;
}
private bool assignmentFinalLess(BucketAssignmentRecord a, BucketAssignmentRecord b) {
    if (a.sourceIndex != b.sourceIndex) return a.sourceIndex < b.sourceIndex;
    if (a.documentId != b.documentId) return a.documentId < b.documentId;
    if (a.segment != b.segment) return !a.segment;
    if (a.segmentOrdinal != b.segmentOrdinal) return a.segmentOrdinal < b.segmentOrdinal;
    return a.bandIndex < b.bandIndex;
}
private bool identityIdLess(IdentityRecord a, IdentityRecord b) {
    return a.documentId < b.documentId;
}
private bool identityFinalLess(IdentityRecord a, IdentityRecord b) {
    return a.sourceIndex != b.sourceIndex ? a.sourceIndex < b.sourceIndex :
        a.documentId < b.documentId;
}

private void number(ref ubyte[] bytes, ulong value) {
    foreach_reverse (shift; [0, 8, 16, 24, 32, 40, 48, 56])
        bytes ~= cast(ubyte)(value >> shift);
}
private ulong number64(const(ubyte)[] bytes, ref size_t at) {
    enforce(at + 8 <= bytes.length, "similarity buckets: short u64 field");
    ulong value;
    foreach (_; 0 .. 8) value = (value << 8) | bytes[at++];
    return value;
}
private void put16(ref ubyte[] bytes, size_t value) {
    enforce(value <= ushort.max, "similarity buckets: u16 overflow");
    bytes ~= cast(ubyte)(value >> 8);
    bytes ~= cast(ubyte) value;
}
private size_t get16(const(ubyte)[] bytes, ref size_t at) {
    enforce(at + 2 <= bytes.length, "similarity buckets: short u16 field");
    auto value = (cast(size_t) bytes[at] << 8) | bytes[at + 1];
    at += 2;
    return value;
}
private void appendBytes(ref ubyte[] outBytes, const(ubyte)[] value) {
    number(outBytes, value.length);
    outBytes ~= value;
}
private ubyte[] takeBytes(const(ubyte)[] bytes, ref size_t offset) {
    auto length = number64(bytes, offset);
    enforce(length <= bytes.length - offset, "similarity buckets: short scratch field");
    auto result = bytes[offset .. offset + cast(size_t) length].dup;
    offset += cast(size_t) length;
    return result;
}

private ubyte[] encode(BandMember item) {
    ubyte[] bytes;
    number(bytes, item.bandIndex);
    number(bytes, item.bandKeyValue);
    appendBytes(bytes, cast(const(ubyte)[]) item.documentId);
    bytes ~= cast(ubyte)(item.segment ? 1 : 0);
    number(bytes, item.segmentOrdinal);
    number(bytes, item.sourceIndex);
    return bytes;
}
private BandMember decodeBandMember(const(ubyte)[] bytes) {
    BandMember item;
    size_t at;
    item.bandIndex = cast(size_t) number64(bytes, at);
    item.bandKeyValue = number64(bytes, at);
    item.documentId = cast(string) takeBytes(bytes, at);
    enforce(at < bytes.length, "similarity buckets: short band member");
    item.segment = bytes[at++] != 0;
    item.segmentOrdinal = cast(size_t) number64(bytes, at);
    item.sourceIndex = cast(uint) number64(bytes, at);
    enforce(at == bytes.length, "similarity buckets: bad band member length");
    return item;
}
private ubyte[] encode(BucketAssignmentRecord item) {
    ubyte[] bytes;
    appendBytes(bytes, cast(const(ubyte)[]) item.documentId);
    bytes ~= cast(ubyte)(item.segment ? 1 : 0);
    number(bytes, item.segmentOrdinal);
    number(bytes, item.bandIndex);
    number(bytes, item.bandKeyValue);
    bytes ~= cast(ubyte)(item.overflowed ? 1 : 0);
    number(bytes, item.sourceIndex);
    return bytes;
}
private BucketAssignmentRecord decodeBucketAssignment(const(ubyte)[] bytes) {
    BucketAssignmentRecord item;
    size_t at;
    item.documentId = cast(string) takeBytes(bytes, at);
    enforce(at < bytes.length, "similarity buckets: short bucket assignment");
    item.segment = bytes[at++] != 0;
    item.segmentOrdinal = cast(size_t) number64(bytes, at);
    item.bandIndex = cast(size_t) number64(bytes, at);
    item.bandKeyValue = number64(bytes, at);
    enforce(at < bytes.length, "similarity buckets: short bucket assignment");
    item.overflowed = bytes[at++] != 0;
    item.sourceIndex = cast(uint) number64(bytes, at);
    enforce(at == bytes.length, "similarity buckets: bad bucket assignment length");
    return item;
}
private ubyte[] encode(IdentityRecord item) {
    ubyte[] bytes;
    appendBytes(bytes, cast(const(ubyte)[]) item.documentId);
    number(bytes, item.sourceIndex);
    bytes ~= item.contentDigest[];
    return bytes;
}
private IdentityRecord decodeIdentity(const(ubyte)[] bytes) {
    IdentityRecord item;
    size_t at;
    item.documentId = cast(string) takeBytes(bytes, at);
    item.sourceIndex = cast(uint) number64(bytes, at);
    enforce(at + 32 == bytes.length, "similarity buckets: bad identity length");
    item.contentDigest[] = bytes[at .. $];
    return item;
}

private void writeFrame(File file, const(ubyte)[] bytes) {
    enforce(bytes.length <= maxScratchFrame, "similarity buckets: scratch frame too large");
    ubyte[] prefix;
    number(prefix, bytes.length);
    file.rawWrite(prefix);
    file.rawWrite(bytes);
}
private bool readFrame(File file, out ubyte[] bytes) {
    ubyte[8] prefix;
    auto first = file.rawRead(prefix[]);
    if (!first.length) return false;
    enforce(first.length == 8, "similarity buckets: short scratch frame header");
    size_t at;
    auto length = number64(prefix[], at);
    enforce(length <= maxScratchFrame, "similarity buckets: oversized scratch frame");
    bytes = new ubyte[cast(size_t) length];
    enforce(file.rawRead(bytes).length == length, "similarity buckets: short scratch frame");
    return true;
}
private bool readRecord(T)(File file, out T item) {
    ubyte[] bytes;
    if (!readFrame(file, bytes)) return false;
    static if (is(T == BandMember)) item = decodeBandMember(bytes);
    else static if (is(T == BucketAssignmentRecord)) item = decodeBucketAssignment(bytes);
    else item = decodeIdentity(bytes);
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
        writeFrame(file, cast(const(ubyte)[]) path);
        ++count;
    }
    string firstPath() {
        enforce(count == 1, "similarity buckets: expected one sorted run");
        auto file = File(manifest, "rb");
        scope(exit) file.close();
        ubyte[] bytes;
        enforce(readFrame(file, bytes), "similarity buckets: missing run path");
        return cast(string) bytes;
    }
}
private void flushRun(T)(ref T[] batch, ref RunSet runs, string delegate() fresh,
        bool function(T, T) less) {
    batch.sort!((a, b) => less(a, b));
    auto path = fresh();
    auto file = File(path, "wb");
    trackOpen();
    scope(exit) { file.close(); trackClose(); }
    foreach (item; batch) writeFrame(file, encode(item));
    runs.append(path);
    batch.length = 0;
}
private RunSet mergeRuns(T)(RunSet runs, bool function(T, T) less,
        string delegate() fresh) {
    while (runs.count > 1) {
        auto next = RunSet(fresh());
        {
            auto manifest = File(runs.manifest, "rb");
            trackOpen();
            scope(exit) { manifest.close(); trackClose(); }
            for (size_t start; start < runs.count; start += fanIn) {
                auto end = start + fanIn < runs.count ? start + fanIn : runs.count;
                auto output = fresh();
                auto writer = File(output, "wb");
                trackOpen();
                File[] readers;
                T[] heads;
                bool[] present;
                scope(exit) {
                    foreach (ref reader; readers) { reader.close(); trackClose(); }
                    writer.close();
                    trackClose();
                }
                foreach (_; start .. end) {
                    ubyte[] pathBytes;
                    enforce(readFrame(manifest, pathBytes),
                        "similarity buckets: missing run in manifest");
                    auto path = cast(string) pathBytes;
                    readers ~= File(path, "rb");
                    trackOpen();
                    T item;
                    present ~= readRecord(readers[$ - 1], item);
                    heads ~= item;
                }
                while (true) {
                    size_t minimum = size_t.max;
                    foreach (i, active; present)
                        if (active && (minimum == size_t.max || less(heads[i], heads[minimum])))
                            minimum = i;
                    if (minimum == size_t.max) break;
                    writeFrame(writer, encode(heads[minimum]));
                    present[minimum] = readRecord(readers[minimum], heads[minimum]);
                }
                next.append(output);
            }
        }
        auto old = File(runs.manifest, "rb");
        trackOpen();
        scope(exit) { old.close(); trackClose(); }
        while (true) {
            ubyte[] path;
            if (!readFrame(old, path)) break;
            remove(cast(string) path);
        }
        remove(runs.manifest);
        runs = next;
    }
    return runs;
}
