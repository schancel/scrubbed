/// Pure, bounded byte-shingle signatures for caller-selected UTF-8 content.
module domain.similarity_signature;

import domain.document : DocumentId;
import domain.encoding_failure : InvalidUtf8Exception;
import std.exception : enforce;
import std.utf : validate;

enum signatureVersion = "byte-shingle-minhash:v1";
enum maxSimilarityInputBytes = 1024 * 1024;
enum similaritySegmentBytes = 4096;
enum similarityLanes = 64;
enum similarityBands = 16;

/// An abstention has no keys. A candidate match is not a duplicate decision.
struct SimilaritySignature {
    DocumentId documentId;
    size_t segmentOrdinal; // 0 for the document; segments use their own ordinal.
    bool segment;
    bool hasKeys;
    ulong[similarityLanes] lanes;
    ulong[similarityBands] bands;
    string profileVersion = signatureVersion;
}

struct SimilaritySignatures {
    SimilaritySignature document;
    SimilaritySignature[] segments;
}

private ubyte[] normalize(const(ubyte)[] content) {
    ubyte[] normalized;
    normalized.reserve(content.length);
    bool pendingSpace;
    size_t runStart;
    foreach (i, value; content) {
        if (value == ' ' || (value >= '\t' && value <= '\r')) {
            if (!pendingSpace && runStart < i) normalized ~= content[runStart .. i];
            pendingSpace = true;
            continue;
        }
        if (pendingSpace) {
            normalized ~= cast(ubyte) ' ';
            pendingSpace = false;
            runStart = i;
        }
        if (value >= 'A' && value <= 'Z') {
            if (runStart < i) normalized ~= content[runStart .. i];
            normalized ~= cast(ubyte)(value + ('a' - 'A'));
            runStart = i + 1;
        }
    }
    if (pendingSpace) normalized ~= cast(ubyte) ' ';
    else if (runStart < content.length) normalized ~= content[runStart .. $];
    return normalized;
}

/// Rejects malformed UTF-8 before normalization. The input is never mutated.
SimilaritySignatures similaritySignatures(DocumentId id, const(ubyte)[] content) {
    enforce(id.text.length != 0, "similarity signature: document ID is not initialized");
    enforce(content.length <= maxSimilarityInputBytes,
        "similarity signature: content exceeds 1 MiB");
    try validate(cast(const(char)[]) content);
    catch (Exception) throw new InvalidUtf8Exception("similarity signature: invalid UTF-8");

    // ASCII folding never increases length; one document is the memory bound.
    auto normalized = normalize(content);

    SimilaritySignatures result;
    result.document = initializeSignature(id, 0, false, normalized.length);
    size_t[] segmentEnds;
    for (size_t start = 0, ordinal = 0; start < normalized.length; ++ordinal) {
        size_t end = start + similaritySegmentBytes;
        if (end >= normalized.length) end = normalized.length;
        else while (end > start && (normalized[end] & 0xc0) == 0x80) --end;
        assert(end > start);
        result.segments ~= initializeSignature(id, ordinal, true, end - start);
        segmentEnds ~= end;
        start = end;
    }

    size_t segmentIndex;
    foreach (offset; 0 .. (normalized.length >= 5 ? normalized.length - 4 : 0)) {
        while (segmentIndex < segmentEnds.length && offset >= segmentEnds[segmentIndex])
            ++segmentIndex;
        SimilaritySignature* segment;
        if (segmentIndex < segmentEnds.length && offset + 5 <= segmentEnds[segmentIndex])
            segment = &result.segments[segmentIndex];
        updateSignatures(result.document, segment, normalized[offset .. offset + 5]);
    }
    finishSignature(result.document);
    foreach (ref segment; result.segments) finishSignature(segment);
    return result;
}

private SimilaritySignature initializeSignature(DocumentId id, size_t ordinal,
        bool segment, size_t byteLength) {
    SimilaritySignature result;
    result.documentId = id;
    result.segmentOrdinal = ordinal;
    result.segment = segment;
    if (byteLength < 5) return result;
    result.hasKeys = true;
    result.lanes[] = ulong.max;
    return result;
}

private void updateSignatures(ref SimilaritySignature document,
        SimilaritySignature* segment, const(ubyte)[] shingle) {
    const b0 = shingle[0];
    const b1 = shingle[1];
    const b2 = shingle[2];
    const b3 = shingle[3];
    const b4 = shingle[4];
    if (segment is null) {
        foreach (lane; 0 .. similarityLanes) {
            auto hash = shingleHash(b0, b1, b2, b3, b4, laneInitialHashes[lane]);
            if (hash < document.lanes[lane]) document.lanes[lane] = hash;
        }
    } else {
        foreach (lane; 0 .. similarityLanes) {
            auto hash = shingleHash(b0, b1, b2, b3, b4, laneInitialHashes[lane]);
            if (hash < document.lanes[lane]) document.lanes[lane] = hash;
            if (hash < segment.lanes[lane]) segment.lanes[lane] = hash;
        }
    }
}

private void finishSignature(ref SimilaritySignature result) {
    if (!result.hasKeys) return;
    foreach (band; 0 .. similarityBands) {
        ulong hash = (0xcbf29ce484222325UL ^ cast(ubyte) band) * 0x100000001b3UL;
        foreach (lane; band * 4 .. band * 4 + 4) {
            auto value = result.lanes[lane];
            foreach (_; 0 .. 8) {
                hash = (hash ^ cast(ubyte) value) * 0x100000001b3UL;
                value >>= 8;
            }
        }
        result.bands[band] = hash;
    }
}

version (unittest) {
    private SimilaritySignature referenceSignature(DocumentId id, size_t ordinal,
            bool segment, const(ubyte)[] bytes) {
        auto result = initializeSignature(id, ordinal, segment, bytes.length);
        if (!result.hasKeys) return result;
        foreach (offset; 0 .. bytes.length - 4)
            updateSignatures(result, null, bytes[offset .. offset + 5]);
        finishSignature(result);
        return result;
    }
}

// The domain and SplitMix64 seed schedule are frozen v1 constants; arithmetic
// deliberately wraps at 64 bits, independent of host byte order.
private ulong laneSeed(size_t lane) {
    ulong value = 0x9e3779b97f4a7c15UL * (lane + 1) + 0x243f6a8885a308d3UL;
    value = (value ^ (value >> 30)) * 0xbf58476d1ce4e5b9UL;
    value = (value ^ (value >> 27)) * 0x94d049bb133111ebUL;
    return value ^ (value >> 31);
}

private ulong[similarityLanes] buildLaneInitialHashes() {
    ulong[similarityLanes] result;
    foreach (lane; 0 .. similarityLanes)
        result[lane] = 0xcbf29ce484222325UL ^ laneSeed(lane);
    return result;
}

// Preserve the frozen SplitMix64 schedule while keeping its arithmetic out of
// every lane of every shingle at runtime.
private immutable ulong[similarityLanes] laneInitialHashes =
    buildLaneInitialHashes();

private ulong shingleHash(ubyte b0, ubyte b1, ubyte b2, ubyte b3, ubyte b4,
        ulong initialHash) {
    enum prime = 0x100000001b3UL;
    ulong hash = initialHash;
    hash = (hash ^ b0) * prime;
    hash = (hash ^ b1) * prime;
    hash = (hash ^ b2) * prime;
    hash = (hash ^ b3) * prime;
    hash = (hash ^ b4) * prime;
    return hash;
}

unittest {
    import domain.document : SourceLocator;
    import std.exception : assertThrown;

    auto id = DocumentId.from(SourceLocator("test", "source", "record"));
    auto empty = similaritySignatures(id, []);
    assert(!empty.document.hasKeys && empty.segments.length == 0);
    auto shortText = similaritySignatures(id, cast(const(ubyte)[]) "abcd");
    assert(!shortText.document.hasKeys && shortText.segments.length == 1 &&
        !shortText.segments[0].hasKeys);
    auto folded = similaritySignatures(id, cast(const(ubyte)[]) "A\t BCD");
    auto canonical = similaritySignatures(id, cast(const(ubyte)[]) "a bcd");
    assert(folded.document.lanes == canonical.document.lanes);
    auto exactlyOneShingle = similaritySignatures(id,
        cast(const(ubyte)[]) "abcde");
    assert(exactlyOneShingle.document.hasKeys);
    assert(exactlyOneShingle.document.lanes ==
        referenceSignature(id, 0, false, cast(const(ubyte)[]) "abcde").lanes);
    assert(exactlyOneShingle.segments.length == 1);
    assert(exactlyOneShingle.segments[0].hasKeys);
    assert(exactlyOneShingle.segments[0].lanes == exactlyOneShingle.document.lanes);
    assertThrown!Exception(similaritySignatures(id, [cast(ubyte) 0xff]));
    assertThrown!Exception(similaritySignatures(id, new ubyte[maxSimilarityInputBytes + 1]));

    assert(normalize(cast(const(ubyte)[]) "") is null);
    assert(normalize(cast(const(ubyte)[]) " \t\r\n\f") == cast(const(ubyte)[]) " ");
    assert(normalize(cast(const(ubyte)[]) "  Alpha\tBETA\né  ") ==
        cast(const(ubyte)[]) " alpha beta é ");

    // The one-pass document/segment update must remain byte-for-byte equal
    // to computing each signature independently, including UTF-8-adjusted
    // segment boundaries and shingles that straddle those boundaries.
    auto boundaryText = new ubyte[similaritySegmentBytes + 17];
    boundaryText[] = cast(ubyte) 'a';
    boundaryText[similaritySegmentBytes - 1 .. similaritySegmentBytes + 1] =
        cast(const(ubyte)[]) "é";
    auto combined = similaritySignatures(id, boundaryText);
    auto normalizedBoundary = normalize(boundaryText);
    assert(combined.document.lanes ==
        referenceSignature(id, 0, false, normalizedBoundary).lanes);
    size_t start;
    foreach (ordinal, segment; combined.segments) {
        size_t end = start + similaritySegmentBytes;
        if (end >= normalizedBoundary.length) end = normalizedBoundary.length;
        else while (end > start && (normalizedBoundary[end] & 0xc0) == 0x80) --end;
        auto reference = referenceSignature(id, ordinal, true,
            normalizedBoundary[start .. end]);
        assert(segment.hasKeys == reference.hasKeys);
        assert(segment.lanes == reference.lanes);
        assert(segment.bands == reference.bands);
        start = end;
    }
}
