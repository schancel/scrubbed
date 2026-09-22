/// Pure, bounded byte-shingle signatures for caller-selected UTF-8 content.
module domain.similarity_signature;

import domain.document : DocumentId;
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

/// Rejects malformed UTF-8 before normalization. The input is never mutated.
SimilaritySignatures similaritySignatures(DocumentId id, const(ubyte)[] content) {
    enforce(id.text.length != 0, "similarity signature: document ID is not initialized");
    enforce(content.length <= maxSimilarityInputBytes,
        "similarity signature: content exceeds 1 MiB");
    try validate(cast(const(char)[]) content);
    catch (Exception) throw new Exception("similarity signature: invalid UTF-8");

    // ASCII folding never increases length; one document is the memory bound.
    ubyte[] normalized;
    normalized.reserve(content.length);
    bool pendingSpace;
    foreach (value; content) {
        if (value == ' ' || (value >= '\t' && value <= '\r')) {
            pendingSpace = true;
            continue;
        }
        if (pendingSpace) {
            normalized ~= cast(ubyte) ' ';
            pendingSpace = false;
        }
        normalized ~= value >= 'A' && value <= 'Z' ?
            cast(ubyte)(value + ('a' - 'A')) : value;
    }
    if (pendingSpace) normalized ~= cast(ubyte) ' ';

    SimilaritySignatures result;
    result.document = signature(id, 0, false, normalized);
    for (size_t start = 0, ordinal = 0; start < normalized.length; ++ordinal) {
        size_t end = start + similaritySegmentBytes;
        if (end >= normalized.length) end = normalized.length;
        else while (end > start && (normalized[end] & 0xc0) == 0x80) --end;
        assert(end > start);
        result.segments ~= signature(id, ordinal, true, normalized[start .. end]);
        start = end;
    }
    return result;
}

private SimilaritySignature signature(DocumentId id, size_t ordinal, bool segment,
    const(ubyte)[] bytes) {
    SimilaritySignature result;
    result.documentId = id;
    result.segmentOrdinal = ordinal;
    result.segment = segment;
    if (bytes.length < 5) return result;
    result.hasKeys = true;
    result.lanes[] = ulong.max;
    foreach (offset; 0 .. bytes.length - 4) {
        auto shingle = bytes[offset .. offset + 5];
        foreach (lane; 0 .. similarityLanes) {
            auto hash = shingleHash(shingle, lane);
            if (hash < result.lanes[lane]) result.lanes[lane] = hash;
        }
    }
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
    return result;
}

// The domain and SplitMix64 seed schedule are frozen v1 constants; arithmetic
// deliberately wraps at 64 bits, independent of host byte order.
private ulong laneSeed(size_t lane) {
    ulong value = 0x9e3779b97f4a7c15UL * (lane + 1) + 0x243f6a8885a308d3UL;
    value = (value ^ (value >> 30)) * 0xbf58476d1ce4e5b9UL;
    value = (value ^ (value >> 27)) * 0x94d049bb133111ebUL;
    return value ^ (value >> 31);
}

private ulong shingleHash(const(ubyte)[] shingle, size_t lane) {
    ulong hash = 0xcbf29ce484222325UL ^ laneSeed(lane);
    foreach (value; shingle) hash = (hash ^ value) * 0x100000001b3UL;
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
    assertThrown!Exception(similaritySignatures(id, [cast(ubyte) 0xff]));
    assertThrown!Exception(similaritySignatures(id, new ubyte[maxSimilarityInputBytes + 1]));
}
