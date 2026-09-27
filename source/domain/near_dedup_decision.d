/// Pure, bounded near-duplicate decisions over caller-supplied MinHash
/// signatures within a single similarity-bucket candidate set. No I/O, no
/// C01 shard reading, no `effects`-layer dependency: this module takes
/// already-computed `SimilaritySignature`s and bucket-membership metadata as
/// plain arguments and returns plain values, matching #36's own established
/// idiom (`effects.similarity_buckets`'s module doc, line ~141-142: "No
/// duplicate decision, representative selection, or cross-band grouping
/// happens here"). Scoped to one shared `(bandIndex, bandKeyValue)` bucket;
/// cross-bucket/full-corpus graph closure is explicitly out of scope for
/// this slice.
module domain.near_dedup_decision;

import domain.document : DocumentId;
import domain.similarity_signature : SimilaritySignature, similarityLanes;
import std.algorithm.sorting : sort;
import std.exception : enforce;

/// Estimated Jaccard similarity between two 64-lane MinHash signatures: the
/// fraction of lanes whose minimum-hash value agrees. A signature that never
/// received real content (`SimilaritySignature.hasKeys == false`) carries
/// its zero-value default lanes rather than a real MinHash, so callers must
/// exclude those from clustering -- see `nearDuplicateLinksInBucket`, which
/// does exactly that.
double jaccardEstimate(SimilaritySignature a, SimilaritySignature b) {
    size_t matches;
    foreach (i; 0 .. similarityLanes)
        if (a.lanes[i] == b.lanes[i]) ++matches;
    return cast(double) matches / similarityLanes;
}

/// First-slice near-duplicate threshold: 0.8 matching-lane fraction.
///
/// This codebase's real LSH banding parameters (`similarity_signature.d`:
/// `similarityBands = 16` bands of `similarityLanes / similarityBands = 4`
/// rows each -- a standard MinHash-LSH configuration) collide roughly 50%
/// of the time at the banding boundary. 0.8 sits meaningfully above that
/// ~0.5 midpoint, giving real margin against false-positive near-dup
/// grouping from band-collision noise alone. It is a reasoned starting
/// point, not an empirically validated final answer: no labeled near-dup
/// corpus exists in this repository yet, so expect this constant to move
/// once one does.
enum double nearDuplicateThreshold = 0.8;

/// One decoded bucket member paired with its caller-supplied signature.
/// Mirrors `effects.similarity_buckets.SimilarityBucketMember`'s field
/// shape without importing it: domain modules must stay independent of
/// every other project layer, including `effects`
/// (`scripts/check_modules.d`). Keep this in sync if that shape changes.
/// The signature is caller-supplied, never computed here -- the same
/// idiom `similarity_buckets.d` already established for bucket membership
/// itself.
struct NearDedupCandidate {
    bool segment;
    size_t segmentOrdinal;
    size_t bandIndex;
    ulong bandKeyValue;
    bool overflowed;
    SimilaritySignature signature;
}

/// One non-representative document's near-duplicate link to its cluster's
/// representative. Mirrors `domain.exact_dedup.ExactDuplicateLink`'s
/// minimal idiom (one record per non-representative document, naming its
/// representative) but deliberately omits `ExactDuplicateLink`'s
/// content-identity fields (`digest`, `canonicalVersion`,
/// `groupCardinality`): those bind exact-byte identity, which has no
/// near-duplicate analogue in this first slice. A later slice may add
/// overlay-bound fields when this wires into a real C01 writer.
struct NearDuplicateLink {
    DocumentId documentId;
    DocumentId representativeId;
}

/// Resolves near-duplicate decisions within one similarity bucket: computes
/// pairwise `jaccardEstimate` over every pair of distinct documents in
/// `members`, unions documents whose estimate is at least
/// `nearDuplicateThreshold` into connected components, and for every
/// component with more than one document selects the
/// lexicographically-smallest canonical `DocumentId.text` as its
/// representative -- the exact rule `effects.exact_dedup_overlay` already
/// uses for exact duplicates (`exact_dedup_overlay.d:55-56,164`:
/// `representative.text <= source.id.text`, "sorted by canonical ID within
/// equal bytes"), extended to near-duplicates rather than inventing a
/// second representative-selection policy. Connected-component grouping
/// (not just direct pairwise links) means a transitive chain clusters
/// together even where the endpoints' own direct estimate falls below
/// threshold.
///
/// A document whose signature never received real content
/// (`signature.hasKeys == false`) is excluded from every comparison: its
/// zero-value default lanes are not a real MinHash and must never
/// contribute a spurious match. Multiple `members` may name the same
/// document (e.g. one row per surviving band); only the first signature
/// seen per document participates.
///
/// Output is one `NearDuplicateLink` per non-representative document,
/// sorted by `documentId.text` for deterministic, restart/worker-order-
/// invariant output regardless of `members`' input order.
NearDuplicateLink[] nearDuplicateLinksInBucket(const(NearDedupCandidate)[] members) {
    DocumentId[] ids;
    SimilaritySignature[] signatures;
    size_t[string] indexOf;
    foreach (member; members) {
        auto id = member.signature.documentId;
        enforce(id.text.length != 0, "near dedup decision: empty document id");
        if ((id.text in indexOf) !is null) continue;
        indexOf[id.text] = ids.length;
        ids ~= id;
        signatures ~= member.signature;
    }

    auto parent = new size_t[ids.length];
    foreach (i, ref p; parent) p = i;
    size_t find(size_t x) {
        while (parent[x] != x) {
            parent[x] = parent[parent[x]];
            x = parent[x];
        }
        return x;
    }
    void unite(size_t a, size_t b) {
        auto ra = find(a);
        auto rb = find(b);
        if (ra != rb) parent[ra] = rb;
    }

    foreach (i; 0 .. ids.length) {
        if (!signatures[i].hasKeys) continue;
        foreach (j; i + 1 .. ids.length) {
            if (!signatures[j].hasKeys) continue;
            if (jaccardEstimate(signatures[i], signatures[j]) >= nearDuplicateThreshold)
                unite(i, j);
        }
    }

    DocumentId[][size_t] groups;
    foreach (i; 0 .. ids.length) groups[find(i)] ~= ids[i];

    NearDuplicateLink[] links;
    foreach (root, groupIds; groups) {
        if (groupIds.length < 2) continue;
        auto representative = groupIds[0];
        foreach (id; groupIds[1 .. $])
            if (id.text < representative.text) representative = id;
        foreach (id; groupIds)
            if (id != representative) links ~= NearDuplicateLink(id, representative);
    }
    links.sort!((a, b) => a.documentId.text < b.documentId.text);
    return links;
}

version (unittest) {
    import domain.document : SourceLocator;

    private DocumentId testId(string recordKey) {
        return DocumentId.from(SourceLocator("near-dedup-unit", "source", recordKey));
    }

    /// Builds a signature with directly-controlled lane values so a test can
    /// pin an exact, computable `jaccardEstimate` between fixtures instead
    /// of relying on real MinHash content hashing.
    private SimilaritySignature testSignature(string recordKey, ulong[similarityLanes] lanes) {
        SimilaritySignature signature;
        signature.documentId = testId(recordKey);
        signature.hasKeys = true;
        signature.lanes = lanes;
        return signature;
    }

    private NearDedupCandidate testMember(SimilaritySignature signature) {
        return NearDedupCandidate(false, 0, 0, 0, false, signature);
    }
}

unittest {
    // jaccardEstimate is exactly matching-lane-count / 64.
    ulong[similarityLanes] baseLanes;
    foreach (i; 0 .. similarityLanes) baseLanes[i] = i;
    auto identical = baseLanes;
    assert(jaccardEstimate(testSignature("a", baseLanes), testSignature("b", identical)) == 1.0);

    ulong[similarityLanes] noneMatch;
    foreach (i; 0 .. similarityLanes) noneMatch[i] = 5000 + i;
    assert(jaccardEstimate(testSignature("a", baseLanes), testSignature("c", noneMatch)) == 0.0);

    ulong[similarityLanes] halfMatch = baseLanes;
    foreach (i; 32 .. similarityLanes) halfMatch[i] = 9000 + i;
    assert(jaccardEstimate(testSignature("a", baseLanes), testSignature("d", halfMatch)) == 32.0 / 64);
}

unittest {
    // Above-threshold pairs (>=0.8 matching-lane fraction) link into the
    // same cluster, naming the lexicographically-smaller ID as
    // representative.
    ulong[similarityLanes] aLanes;
    foreach (i; 0 .. similarityLanes) aLanes[i] = i;
    auto bLanes = aLanes;
    foreach (i; 52 .. similarityLanes) bLanes[i] = 7000 + i; // 52/64 = 0.8125 match

    auto a = testSignature("above-a", aLanes);
    auto b = testSignature("above-b", bLanes);
    assert(jaccardEstimate(a, b) >= nearDuplicateThreshold);

    auto links = nearDuplicateLinksInBucket([testMember(a), testMember(b)]);
    assert(links.length == 1);
    auto expectedRepresentative = a.documentId.text < b.documentId.text ?
        a.documentId : b.documentId;
    auto expectedLinked = expectedRepresentative == a.documentId ? b.documentId : a.documentId;
    assert(links[0].documentId == expectedLinked);
    assert(links[0].representativeId == expectedRepresentative);
}

unittest {
    // Below-threshold pairs (<0.8 matching-lane fraction) do not link.
    ulong[similarityLanes] aLanes;
    foreach (i; 0 .. similarityLanes) aLanes[i] = i;
    auto cLanes = aLanes;
    foreach (i; 40 .. similarityLanes) cLanes[i] = 8000 + i; // 40/64 = 0.625 match

    auto a = testSignature("below-a", aLanes);
    auto c = testSignature("below-c", cLanes);
    assert(jaccardEstimate(a, c) < nearDuplicateThreshold);

    auto links = nearDuplicateLinksInBucket([testMember(a), testMember(c)]);
    assert(links.length == 0);
}

unittest {
    // Transitive chain: A~B and B~C are each above threshold, but A~C
    // computed directly is below threshold. Connected-component grouping
    // still clusters all three together, not just direct pairwise links.
    // Representative selection is proven order-invariant: the same
    // lexicographically-smallest ID wins regardless of the members[] input
    // order (a structural proof of restart/worker-order invariance).
    // Lanes 0..55 ("S"): A and B agree (value = lane index).
    // Lanes 56..63 ("D"): A and B disagree (A = lane index, B = 1000 + index).
    ulong[similarityLanes] aLanes;
    foreach (i; 0 .. similarityLanes) aLanes[i] = i;

    ulong[similarityLanes] bLanes;
    foreach (i; 0 .. 56) bLanes[i] = i;
    foreach (i; 56 .. similarityLanes) bLanes[i] = 1000 + i;

    // C agrees with both A and B on the first 48 of S's lanes, disagrees
    // with both on the remaining 8 of S, and agrees only with B's D tail:
    //   match(A,C) = 48 (S prefix) + 0 (S suffix) + 0 (D)  = 48 -> 0.75 (below)
    //   match(B,C) = 48 (S prefix) + 0 (S suffix) + 8 (D)  = 56 -> 0.875 (above)
    ulong[similarityLanes] cLanes;
    foreach (i; 0 .. 48) cLanes[i] = i;
    foreach (i; 48 .. 56) cLanes[i] = 2000 + i;
    foreach (i; 56 .. similarityLanes) cLanes[i] = 1000 + i;

    auto a = testSignature("chain-a", aLanes);
    auto b = testSignature("chain-b", bLanes);
    auto c = testSignature("chain-c", cLanes);

    auto ab = jaccardEstimate(a, b);
    auto bc = jaccardEstimate(b, c);
    auto ac = jaccardEstimate(a, c);
    assert(ab >= nearDuplicateThreshold, "fixture bug: A~B must be above threshold");
    assert(bc >= nearDuplicateThreshold, "fixture bug: B~C must be above threshold");
    assert(ac < nearDuplicateThreshold, "fixture bug: A~C direct must be below threshold");

    string[] ids = [a.documentId.text, b.documentId.text, c.documentId.text];
    ids.sort();
    auto expectedRepresentative = ids[0];

    auto orderings = [
        [testMember(a), testMember(b), testMember(c)],
        [testMember(c), testMember(b), testMember(a)],
        [testMember(b), testMember(a), testMember(c)],
        [testMember(c), testMember(a), testMember(b)],
    ];
    foreach (ordering; orderings) {
        auto links = nearDuplicateLinksInBucket(ordering);
        // All three documents in one cluster: two non-representative links.
        assert(links.length == 2);
        foreach (link; links) {
            assert(link.representativeId.text == expectedRepresentative);
            assert(link.documentId.text != expectedRepresentative);
        }
        auto linkedIds = [links[0].documentId.text, links[1].documentId.text];
        linkedIds.sort();
        auto remaining = ids[1 .. $];
        assert(linkedIds == remaining);
    }
}

unittest {
    // A signature that never received real content (`hasKeys == false`)
    // carries all-zero default lanes. Two such abstained signatures must
    // not spuriously cluster just because their zero lanes trivially agree.
    SimilaritySignature abstainedOne;
    abstainedOne.documentId = testId("abstain-1");
    abstainedOne.hasKeys = false;

    SimilaritySignature abstainedTwo;
    abstainedTwo.documentId = testId("abstain-2");
    abstainedTwo.hasKeys = false;

    // The raw lane comparison would report a perfect match on zero lanes...
    assert(jaccardEstimate(abstainedOne, abstainedTwo) == 1.0);
    // ...but nearDuplicateLinksInBucket excludes hasKeys == false entirely.
    auto links = nearDuplicateLinksInBucket(
        [testMember(abstainedOne), testMember(abstainedTwo)]);
    assert(links.length == 0);
}

unittest {
    // A single document (no pair to compare against) never links, and an
    // empty bucket returns no links.
    ulong[similarityLanes] lanes;
    auto solo = testSignature("solo", lanes);
    assert(nearDuplicateLinksInBucket([testMember(solo)]).length == 0);
    assert(nearDuplicateLinksInBucket([]).length == 0);
}

unittest {
    // Repeated members naming the same document (e.g. one row per
    // surviving band) collapse to a single node: the document does not
    // spuriously link to itself.
    ulong[similarityLanes] lanes;
    foreach (i; 0 .. similarityLanes) lanes[i] = i;
    auto solo = testSignature("repeated", lanes);
    auto links = nearDuplicateLinksInBucket(
        [testMember(solo), testMember(solo), testMember(solo)]);
    assert(links.length == 0);
}
