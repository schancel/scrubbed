/// Pure exact-byte duplicate grouping and deterministic document links.
module domain.exact_dedup;

import domain.document : DocumentId;
import std.algorithm.sorting : sort;
import crypto.sha256 : sha256Of;
import std.exception : enforce;

/// Exact bytes are the canonical content in exact-bytes:v1. The caller owns the
/// bytes and must keep them unchanged until this call returns. This is a batch
/// operation, not a whole-corpus memory bound or an external-memory index.
enum exactBytesVersion = "exact-bytes:v1";

struct ExactDocument {
    DocumentId id;
    const(ubyte)[] bytes;
}

struct ExactDuplicateLink {
    DocumentId documentId;
    DocumentId representativeId;
    ubyte[32] digest;
    string canonicalVersion = exactBytesVersion;
    bool duplicate;
    size_t groupCardinality;
}

/// The hash function is an index only. The injectable variant permits a forced
/// collision proof; emitted digests always use SHA-256 of the original bytes.
alias IndexHash = ubyte[32] function(const(ubyte)[]);

ExactDuplicateLink[] exactDuplicateLinks(const(ExactDocument)[] documents) {
    return exactDuplicateLinksWithIndexHash(documents, &shaIndex);
}

ExactDuplicateLink[] exactDuplicateLinksWithIndexHash(
    const(ExactDocument)[] documents, IndexHash indexHash) {
    enforce(indexHash !is null, "index hash is required");

    struct Group {
        const(ubyte)[] bytes;
        ubyte[32] digest;
        DocumentId representative;
        DocumentId[] members;
    }

    Group[] groups;
    size_t[][ubyte[32]] buckets;
    bool[string] seenIds;
    foreach (document; documents) {
        auto id = document.id.text;
        enforce(id.length != 0, "document ID is not initialized");
        enforce((id in seenIds) is null, "duplicate document ID in batch");
        seenIds[id] = true;

        auto index = indexHash(document.bytes);
        size_t groupIndex = size_t.max;
        if (auto candidates = index in buckets) {
            foreach (candidate; *candidates) {
                if (groups[candidate].bytes == document.bytes) {
                    groupIndex = candidate;
                    break;
                }
            }
        }
        if (groupIndex == size_t.max) {
            groupIndex = groups.length;
            Group group;
            group.bytes = document.bytes;
            group.digest = sha256Of(document.bytes);
            group.representative = document.id;
            groups ~= group;
            buckets[index] ~= groupIndex;
        }
        if (id < groups[groupIndex].representative.text)
            groups[groupIndex].representative = document.id;
        groups[groupIndex].members ~= document.id;
    }

    ExactDuplicateLink[] links;
    foreach (group; groups) {
        foreach (id; group.members) {
            links ~= ExactDuplicateLink(id, group.representative, group.digest,
                exactBytesVersion, id != group.representative, group.members.length);
        }
    }
    links.sort!((a, b) => a.documentId.text < b.documentId.text);
    return links;
}

private ubyte[32] shaIndex(const(ubyte)[] bytes) {
    return sha256Of(bytes);
}

unittest {
    import domain.document : SourceLocator;
    import std.exception : assertThrown;

    auto a = DocumentId.from(SourceLocator("set", "shard-a", "a"));
    auto b = DocumentId.from(SourceLocator("set", "shard-b", "b"));
    auto links = exactDuplicateLinks([ExactDocument(a, [cast(ubyte)0xff, 0]),
        ExactDocument(b, [cast(ubyte)0xff, 0])]);
    assert(links.length == 2);
    assert(links[0].representativeId.text == links[1].representativeId.text);
    assert(links[0].groupCardinality == 2 && links[1].groupCardinality == 2);
    assertThrown!Exception(exactDuplicateLinks([
        ExactDocument(a, []), ExactDocument(a, [])]));
}
