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
///
/// **Issue #480 (configurable near-duplicate pruning) adds two independent,
/// both-off-by-default capabilities on top of the above, unchanged detection
/// pipeline:**
///
/// 1. **`policy` (`domain.near_dedup_decision.PruningPolicy`)** controls
///    which cluster member `nearDuplicateLinksInBucket` names as
///    representative. Defaults to `PruningPolicy.keepFirst`, the exact
///    pre-#480 lexicographically-smallest-ID rule, so every caller that
///    does not pass a policy gets byte-identical annotation-overlay output
///    to before this issue.
/// 2. **`NearDedupShard.prunedDestination`** (empty string by default) is
///    this issue's actual *removal* capability -- distinct from the
///    annotation overlay above, which only ever links/reports and was
///    verified never to drop anything from any downstream artifact prior
///    to this issue (see this issue's own PR description for that
///    verification). When non-empty for a shard, this module additionally
///    reads that shard's immutable C01 source in full and republishes every
///    document that is *not* a non-representative member of
///    `finalPruningLinks` (computed from the exact same policy-driven
///    decision above, restricted to document-level candidates only -- see
///    issue #492's own note below) as a new, physically smaller C01
///    document shard at that path via the existing `DocumentShardWriter`
///    -- matching trafilatura's real `--deduplicate` semantics (removal),
///    not just annotation. A shard that never names a `prunedDestination`
///    gets no pruned output at all: pruning is strictly additive and
///    opt-in per shard, on top of the unchanged annotation overlay this
///    module always writes.
///
/// **Post-#480 review fix, decoupled further by issue #492.** `similarity_
/// buckets.d` persists a band membership for both a document's
/// whole-document signature and each of its per-4096-byte *segment*
/// signatures; every persisted member is still tamper/staleness-verified
/// against its recomputed band hash below, regardless of level. Round 1 of
/// #480's review found that treating a segment-vs-whole-document match as
/// equivalent to a genuine whole-document match let one shared boilerplate
/// segment cluster -- and, with pruning enabled, physically delete -- an
/// otherwise entirely unique large document, even though the two
/// documents' own whole-document jaccard estimate was well below
/// threshold. The original fix (918a0db) closed this by excluding every
/// segment-level member from becoming a `CandidateRow` at all, which also
/// (unintentionally) narrowed the always-on annotation/reporting overlay
/// below (Phase B/C) -- a capability that predates #480 (segment-level
/// clustering shipped in #37) and is unrelated to pruning.
///
/// Issue #492 decouples the two concerns instead of gating candidacy at
/// this single chokepoint: every persisted member -- segment-level or
/// document-level -- becomes a `CandidateRow` again below, restoring
/// pre-#480 annotation richness (Phase B/C cluster and publish over the
/// full per-bucket set, see `outputs`/`finalLinks`). Phase D's pruning
/// decision is nonetheless independently recomputed per bucket from
/// *only* that same bucket's document-level subset (`documentLevelMembers`
/// / `pruningOutputs` / `finalPruningLinks`) -- the exact narrower,
/// data-loss-safe set round 1's fix already established -- so the
/// blocker stays closed even though annotation is rich again. See this
/// module's own regression tests (search "segment-conflation" for the
/// still-closed pruning blocker, and "segment-richness" for restored
/// annotation candidacy).
module effects.near_dedup_overlay;

import core.stdc.errno : errno, ENOENT;
import core.sys.posix.sys.stat : lstat, stat_t, S_ISREG;
import crypto.sha256 : sha256Of;
import domain.document : DocumentId;
import domain.near_dedup_decision : NearDedupCandidate, NearDuplicateLink,
    nearDuplicateLinksInBucket, nearDuplicateThreshold, PruningPolicy;
import domain.shard_format : AnnotationField, AnnotationRecord, ShardDocument;
import domain.similarity_signature : SimilaritySignature, SimilaritySignatures,
    signatureVersion, similarityBands, similarityLanes, similaritySignatures;
import effects.document_shards : DocumentShardReader, DocumentShardWriter,
    JoinedOverlay, OverlayWriter, PublishFault, PublishStep, joinShards;
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
/// analyzer's own destination overlay. `prunedDestination` (issue #480,
/// empty by default) additionally names where this module should publish a
/// physically pruned copy of `source` -- every non-representative
/// near-duplicate document actually removed, not just annotated -- for this
/// one shard. Leaving it empty (every pre-#480 caller) means this shard
/// gets no pruned output at all.
struct NearDedupShard {
    string source;
    string bucketsOverlay;
    string destination;
    string prunedDestination = "";
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
/// bandKeyValue)` bucket independently through the pure decision function
/// (unmodified except for issue #480's additive `policy` parameter, which
/// defaults to the function's own pre-#480 default), and publishes one
/// strictly-ID-sorted C01 overlay per shard naming every non-representative
/// document's representative. When a shard names a `prunedDestination`
/// (issue #480, empty by default), this also republishes that shard's
/// source as a physically pruned C01 document shard -- see this module's
/// doc comment above for the two features' exact, independent scope.
void writeNearDedupOverlays(const(NearDedupShard)[] inputs, PublishFault fault = null,
        PruningPolicy policy = PruningPolicy.keepFirst) {
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
    size_t[string] contentLengthOf; // issue #480: only consulted by PruningPolicy.keepLongest.
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
                contentLengthOf[idText] = document.content.length;

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
                    // Issue #480 review round 1 (confirmed, fixed) / issue
                    // #492 (decoupled): every persisted member is still
                    // verified above (tamper/staleness detection stays
                    // symmetric across document- and segment-level members
                    // alike), and every member -- segment-level or
                    // document-level -- becomes a `CandidateRow` here.
                    // Segment-level rows are no longer dropped at this
                    // chokepoint; Phase B below instead resolves each
                    // bucket twice -- once over its full member set (this
                    // restores pre-#480 annotation richness) and once more
                    // over only its document-level subset (the exact
                    // narrower, data-loss-safe set round 1's fix
                    // established) -- so pruning eligibility stays
                    // document-level-only without narrowing annotation.
                    batch ~= CandidateRow(member.bandIndex, member.bandKeyValue,
                        member.overflowed, index, signature, document.content.length);
                    if (batch.length == runRecords) flushRun(batch, runs, &fresh);
                }
            });
    }
    if (batch.length) flushRun(batch, runs, &fresh);
    runs = mergeRuns(runs, &fresh);

    // Phase B: a single sequential scan over the (bandIndex, bandKeyValue,
    // documentId)-sorted candidate stream groups exactly one already-capped
    // bucket into memory at a time -- never a full-corpus structure -- and
    // hands it, unmodified, to the existing pure decision function. Issue
    // #492: every bucket is resolved *twice* against that one unmodified
    // decision function -- once over its full `members` (segment-level and
    // document-level candidates alike, restoring pre-#480 annotation
    // richness) into `outputs`, and once more over only that same bucket's
    // `documentLevelMembers` subset (round 1 of #480's own narrower,
    // data-loss-safe set) into `pruningOutputs`. Both reuse the identical
    // in-memory grouping this scan already built, so this costs one extra
    // pure-function call per bucket, never a second pass over disk.
    OutputLink[] outputs;
    OutputLink[] pruningOutputs;
    if (runs.count) {
        auto sorted = File(runs.firstPath(), "rb");
        scope(exit) sorted.close();
        CandidateRow item;
        bool hasItem = readRecord(sorted, item);
        while (hasItem) {
            auto bandIndex = item.bandIndex;
            auto bandKeyValue = item.bandKeyValue;
            NearDedupCandidate[] members;
            NearDedupCandidate[] documentLevelMembers;
            while (hasItem && item.bandIndex == bandIndex && item.bandKeyValue == bandKeyValue) {
                auto candidate = NearDedupCandidate(item.signature.segment,
                    item.signature.segmentOrdinal, item.bandIndex, item.bandKeyValue,
                    item.overflowed, item.signature, item.contentLength);
                members ~= candidate;
                if (!candidate.segment) documentLevelMembers ~= candidate;
                hasItem = readRecord(sorted, item);
            }
            foreach (link; nearDuplicateLinksInBucket(members, policy)) {
                auto docText = link.documentId.text;
                outputs ~= OutputLink(docText, sourceIndexOf[docText], link.representativeId.text);
            }
            foreach (link; nearDuplicateLinksInBucket(documentLevelMembers, policy)) {
                auto docText = link.documentId.text;
                pruningOutputs ~= OutputLink(docText, sourceIndexOf[docText], link.representativeId.text);
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
    // own bucket. Issue #492: this resolution is pure over one `OutputLink[]`
    // at a time, so it runs unchanged, independently, for both `outputs`
    // (annotation, the full per-bucket set) and `pruningOutputs`
    // (pruning eligibility, the document-level-only subset) below --
    // exactly the module doc's called-for separation of the two concerns.
    OutputLink[] resolveFinalLinks(OutputLink[] rawOutputs) {
        string[string] representativeOf;
        foreach (output; rawOutputs) {
            auto existing = output.documentId in representativeOf;
            if (existing is null || output.representativeId < *existing)
                representativeOf[output.documentId] = output.representativeId;
        }
        // Issue #480 review round 1 (secondary concern, resolved): a
        // document's chosen representative here may itself be a key in
        // this same map -- i.e. itself a non-representative entry from
        // some other bucket -- since a document's own signature can
        // explode into up to `similarityBands` independent band rows and
        // land in more than one bucket-cluster at once (the same
        // structural fact the comment above already names). Left
        // unresolved, a published `representative_id` could name a
        // document that pruning has itself physically removed.
        // `resolveRepresentativeChains` rewrites every entry to its true,
        // never-itself-a-key root before anything is published.
        representativeOf = resolveRepresentativeChains(representativeOf);
        OutputLink[] resolved;
        resolved.reserve(representativeOf.length);
        foreach (documentId, representativeId; representativeOf)
            resolved ~= OutputLink(documentId, sourceIndexOf[documentId], representativeId);
        resolved.sort!((a, b) => a.sourceIndex == b.sourceIndex ?
            a.documentId < b.documentId : a.sourceIndex < b.sourceIndex);
        return resolved;
    }
    auto finalLinks = resolveFinalLinks(outputs);
    // Issue #492: the pruning-eligible set is resolved through the exact
    // same chain-resolution/tie-break logic, independently, over
    // `pruningOutputs` (document-level candidates only) -- never over the
    // richer `outputs`/`finalLinks` above. This is what keeps pruning's
    // data-loss fix closed while annotation regains segment-level
    // richness. See `finalPruningLinks`'s one use, in Phase D below.
    auto finalPruningLinks = resolveFinalLinks(pruningOutputs);

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

    // Phase D (issue #480, decoupled from annotation by issue #492):
    // physical pruning, strictly additive and opt-in per shard. Unlike
    // `finalLinks` (just published above as the richer annotation set),
    // the drop set here is built from `finalPruningLinks` -- resolved
    // above from `pruningOutputs`, the document-level-only candidate
    // subset -- so a document is omitted from a pruned shard iff it
    // appears as `documentId` (the non-representative side) in
    // `finalPruningLinks`, never merely because a segment of it happened
    // to match something in the richer annotation set. Every other
    // document -- including one this analyzer never touched at all (no
    // bucket membership, or hasKeys == false) -- is republished
    // byte-for-byte. A shard that never named a `prunedDestination` does
    // zero extra work here.
    bool[string] droppedIds;
    foreach (link; finalPruningLinks) droppedIds[link.documentId] = true;
    foreach (canonicalIndex, shard; shards) {
        if (!shard.prunedDestination.length) continue;
        plan.validateSource(canonicalIndex);
        plan.validatePrunedDestination(canonicalIndex);
        auto reader = new DocumentShardReader(shard.source);
        scope(exit) reader.closeReader();
        auto writer = new DocumentShardWriter(shard.prunedDestination);
        scope(failure) writer.abort();
        ShardDocument document;
        while (reader.next(document))
            if ((document.id.text in droppedIds) is null) writer.append(document);
        PublishFault checkedPruneFault = (PublishStep step) {
            if (fault !is null) fault(step);
            plan.validateSource(canonicalIndex);
            plan.validatePrunedDestination(canonicalIndex);
        };
        writer.publish(checkedPruneFault);
    }
}

private SimilaritySignature segmentSignature(SimilaritySignatures signatures, size_t ordinal) {
    enforce(ordinal < signatures.segments.length,
        "near dedup overlay: segment ordinal out of range");
    return signatures.segments[ordinal];
}

/// Issue #480 review round 1: rewrites every `documentId -> representativeId`
/// entry to its true root -- a value that is never itself a key in this same
/// map -- by following each chain to its end. Pure and total over any input
/// shaped like Phase C's own `representativeOf` map.
///
/// **Termination, not just correctness.** This never checks for a cycle
/// directly; instead it relies on (and bounds-checks) a structural
/// invariant every shipped `PruningPolicy` already satisfies: representative
/// selection within one bucket always ranks documents by some fixed,
/// document-intrinsic key (`keepFirst`: the document's own canonical ID;
/// `keepLongest`: content length, ID tie-break) that never depends on which
/// other documents happen to share that bucket. Because that ranking is the
/// same total order everywhere, "X beats Y" is consistent across every
/// bucket X and Y ever co-occur in, so the induced loser-to-winner graph is
/// necessarily acyclic -- a cycle would require some document to both
/// outrank and be outranked by another under one fixed order, which a total
/// order forbids. The bounded loop below still enforces this rather than
/// trusting it blindly: a future `PruningPolicy` whose ranking is
/// bucket-dependent (and could therefore cycle) fails closed here with a
/// clear message instead of looping forever.
private string[string] resolveRepresentativeChains(const(string[string]) representativeOf) {
    auto resolved = representativeOf.dup;
    foreach (documentId; resolved.keys) {
        auto root = resolved[documentId];
        size_t hops;
        while (auto next = root in resolved) {
            root = *next;
            ++hops;
            enforce(hops <= resolved.length,
                "near dedup overlay: representative chain did not terminate -- a " ~
                "PruningPolicy's per-document ranking must be a fixed, document-intrinsic " ~
                "total order, never bucket-dependent");
        }
        resolved[documentId] = root;
    }
    return resolved;
}

unittest {
    // Issue #480 review round 1 (secondary concern): a two-hop chain
    // resolves to its true root, and the intermediate document (itself
    // both a loser and a winner) is rewritten too, not left dangling.
    string[string] input = ["b": "a", "c": "b"]; // c -> b -> a (a is the true root)
    auto resolved = resolveRepresentativeChains(input);
    assert(resolved.length == 2);
    assert(resolved["b"] == "a");
    assert(resolved["c"] == "a", "an intermediate link must resolve straight to the true root");
}

unittest {
    // A longer, three-hop chain resolves fully, and a document that never
    // appears as anyone's representative (i.e. is only ever a key, never
    // a value someone else's key points at across the whole map here)
    // still resolves correctly.
    string[string] input = ["d": "c", "c": "b", "b": "a"]; // d -> c -> b -> a
    auto resolved = resolveRepresentativeChains(input);
    assert(resolved.length == 3);
    assert(resolved["b"] == "a");
    assert(resolved["c"] == "a");
    assert(resolved["d"] == "a");
}

unittest {
    // Already-resolved input (every value already a true root, i.e. no
    // value also appears as a key) is returned unchanged -- idempotent,
    // and the common case (most batches never have a cross-bucket
    // conflict at all) costs nothing extra.
    string[string] input = ["b": "a", "d": "c", "f": "e"];
    auto resolved = resolveRepresentativeChains(input);
    assert(resolved == input);
}

unittest {
    // Two independent chains sharing no documents resolve independently;
    // one chain's resolution must never leak into the other's.
    string[string] input = ["b": "a", "e": "d", "d": "c"];
    auto resolved = resolveRepresentativeChains(input);
    assert(resolved["b"] == "a");
    assert(resolved["d"] == "c");
    assert(resolved["e"] == "c");
}

unittest {
    // A diamond: two different documents (b, c) both lose to the same
    // intermediate (d), which itself loses to the true root (a). Both
    // must resolve to a, not to d.
    string[string] input = ["b": "d", "c": "d", "d": "a"];
    auto resolved = resolveRepresentativeChains(input);
    assert(resolved["b"] == "a");
    assert(resolved["c"] == "a");
    assert(resolved["d"] == "a");
}

unittest {
    // Empty input resolves to empty output.
    string[string] empty;
    assert(resolveRepresentativeChains(empty).length == 0);
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
/// buckets overlay (a second read-only input this module must not clobber)
/// and, per shard, an optional `prunedDestination` (issue #480) -- guarded
/// with the exact same duplicate/alias/hardlink discipline as `destination`
/// itself, just skipped entirely for a shard that names none.
private struct PreflightPlan {
    string directory;
    string[] sources;
    string[] destinations;
    string[] prunedDestinations; // "" (never a real path) means "no pruning for this shard"
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

            string prunedDestination;
            if (shard.prunedDestination.length) {
                prunedDestination = buildNormalizedPath(absolutePath(shard.prunedDestination));
                enforce(dirName(prunedDestination) == parent,
                    "near dedup overlay: pruned destination must share the batch's output directory");
                enforce(prunedDestination != destination,
                    "near dedup overlay: pruned destination aliases the annotation-overlay destination");
                enforce((prunedDestination in destinationPaths) is null,
                    "near dedup overlay: duplicate near-dedup pruned destination");
                destinationPaths[prunedDestination] = true;
            }

            stat_t sourceInfo;
            enforce(lstat(source.toStringz, &sourceInfo) == 0 && S_ISREG(sourceInfo.st_mode),
                "near dedup overlay: source is not a regular shard");
            stat_t bucketsInfo;
            enforce(lstat(bucketsOverlay.toStringz, &bucketsInfo) == 0 &&
                S_ISREG(bucketsInfo.st_mode),
                "near dedup overlay: buckets overlay is not a regular file");

            sources ~= source;
            destinations ~= destination;
            prunedDestinations ~= prunedDestination;
            sourceIdentities ~= identity(sourceInfo);
            sourcePaths[source] = true;
            sourcePaths[bucketsOverlay] = true;
            sourceInodes[identity(sourceInfo)] = true;
            sourceInodes[identity(bucketsInfo)] = true;
        }
        foreach (i, destination; destinations) {
            enforce((destination in sourcePaths) is null,
                "near dedup overlay: destination aliases a source or buckets-overlay path");
            if (prunedDestinations[i].length)
                enforce((prunedDestinations[i] in sourcePaths) is null,
                    "near dedup overlay: pruned destination aliases a source or buckets-overlay path");
            validateDestination(i);
            validatePrunedDestination(i);
        }
    }

    void validateSource(size_t i) {
        stat_t info;
        enforce(lstat(sources[i].toStringz, &info) == 0 && S_ISREG(info.st_mode) &&
            identity(info) == sourceIdentities[i],
            "near dedup overlay: source changed during publication");
    }

    void validateAllDestinations() {
        foreach (i; 0 .. destinations.length) {
            validateDestination(i);
            validatePrunedDestination(i);
        }
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

    void validatePrunedDestination(size_t i) {
        if (!prunedDestinations[i].length) return;
        enforce(isDir(directory) && !isSymlink(directory),
            "near dedup overlay: output directory changed");
        stat_t target;
        if (lstat(prunedDestinations[i].toStringz, &target) != 0) {
            enforce(errno == ENOENT, "near dedup overlay: cannot inspect pruned destination");
            return;
        }
        enforce(S_ISREG(target.st_mode) && target.st_nlink == 1,
            "near dedup overlay: pruned destination is nonregular or hardlinked");
        enforce((identity(target) in sourceInodes) is null,
            "near dedup overlay: pruned destination aliases a source or buckets-overlay inode");
    }
}

private struct CandidateRow {
    size_t bandIndex;
    ulong bandKeyValue;
    bool overflowed;
    uint sourceIndex;
    SimilaritySignature signature; // hasKeys is always true for a persisted row.
    size_t contentLength; // issue #480: only consulted by PruningPolicy.keepLongest.
}
private struct OutputLink {
    string documentId;
    uint sourceIndex;
    string representativeId;
}

private bool candidateRowLess(CandidateRow a, CandidateRow b) {
    if (a.bandIndex != b.bandIndex) return a.bandIndex < b.bandIndex;
    if (a.bandKeyValue != b.bandKeyValue) return a.bandKeyValue < b.bandKeyValue;
    if (a.signature.documentId.text != b.signature.documentId.text)
        return a.signature.documentId.text < b.signature.documentId.text;
    // Issue #492 (review round 2): `nearDuplicateLinksInBucket` keeps only
    // the *first* signature it sees per document within one bucket call
    // ("Multiple members may name the same document ... only the first
    // signature seen per document participates"). A document's own
    // whole-document signature and one of its segment signatures are
    // computed from overlapping content, so they very often collide on the
    // same real LSH band for the same document. Without a deterministic
    // tie-break here, which of the two "wins" that ambiguous first-seen
    // slot would be arbitrary sort-order noise -- letting a document enter
    // the full/annotation cluster only via a segment proxy while its
    // whole-document row never gets a chance to represent it there (or the
    // reverse), which could reintroduce exactly the "annotation names a
    // representative pruning has removed" gap issue #480's round 1 closed.
    // Always ordering a document's whole-document row before any of its
    // segment rows makes the full (annotation) per-document participant
    // deterministically the same signature the document-level-only
    // (pruning) scan already uses -- the full cluster's membership for
    // every document is then a strict superset of the document-level
    // cluster's, never a divergent, order-dependent substitute for it.
    return !a.signature.segment && b.signature.segment;
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
    number(bytes, item.contentLength); // issue #480
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
    item.contentLength = cast(size_t)number64(bytes, at); // issue #480
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

    /// Issue #480 review round 1: general invariant check reused by pruning
    /// tests below -- no `representative_id` an annotation overlay names
    /// may ever be absent from the corresponding `prunedDestination`'s
    /// surviving document set (see `resolveRepresentativeChains`'s own doc
    /// comment for the structural reasoning this exists to double-check
    /// end to end, against the actually-published artifacts, not this
    /// module's internal state).
    private void assertNoRepresentativeDangles(string annotationOverlayPath, string prunedShardPath) {
        bool[string] surviving;
        foreach (document; readAllDocuments(prunedShardPath)) surviving[document.id.text] = true;
        foreach (record; readAllAnnotations(annotationOverlayPath)) {
            auto representativeIdText = cast(string) record.fields[2].value;
            assert((representativeIdText in surviving) !is null,
                "representative_id " ~ representativeIdText ~ " named by document " ~
                record.documentId ~ " must survive pruning, never be dangling");
        }
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

unittest {
    // Issue #480, no-regression proof at this module's own public API: the
    // annotation overlay this module publishes is byte-for-byte identical
    // whether a caller omits `policy` entirely (every pre-#480 call site) or
    // passes the new parameter's own default explicitly, and identical
    // again whether or not any shard names a `prunedDestination` -- pruning
    // is strictly additive, never a mutation of the pre-existing output.
    auto root = scratchRoot("no-regression");
    scope(exit) rmdirRecurse(root);
    auto content = "no-regression fixture content shared by two documents";
    auto documents = [testDocument("s", "one", content), testDocument("s", "two", content)];

    auto destinationImplicit = buildPath(root, "implicit.overlay");
    auto shardImplicit = buildFixtureShard(root, "implicit", documents, destinationImplicit);
    writeNearDedupOverlays([shardImplicit]);

    auto destinationExplicit = buildPath(root, "explicit.overlay");
    auto shardExplicit = buildFixtureShard(root, "explicit", documents, destinationExplicit);
    writeNearDedupOverlays([shardExplicit], null, PruningPolicy.keepFirst);

    assert(cast(ubyte[])read(destinationImplicit) == cast(ubyte[])read(destinationExplicit),
        "omitting policy must match passing its own default explicitly, byte-for-byte");

    // Naming a prunedDestination must not change the annotation overlay's
    // own bytes at all -- it is a wholly separate, additive output.
    auto destinationPruned = buildPath(root, "pruned-sibling.overlay");
    auto prunedOutput = buildPath(root, "pruned-sibling.shard");
    auto shardWithPruning = buildFixtureShard(root, "pruned-sibling", documents, destinationPruned);
    shardWithPruning.prunedDestination = prunedOutput;
    writeNearDedupOverlays([shardWithPruning]);
    assert(cast(ubyte[])read(destinationPruned) == cast(ubyte[])read(destinationImplicit),
        "naming a prunedDestination must not alter the annotation overlay's own bytes");
}

unittest {
    // Issue #480 review round 1 (confirmed, reproduced blocker): a document
    // that is NOT a whole-document near-duplicate of anything must never be
    // pruned just because one of its *segments* closely matches a small,
    // unrelated standalone document. `similaritySignatures` splits content
    // over 4096 bytes into independent per-segment signatures, and every
    // surviving band -- document-level or segment-level alike -- used to
    // feed the same clustering/representative-selection decision with zero
    // regard for how much of the matched document the shared content
    // actually represents. This fixture is exactly that shape: a
    // 7096-byte document made of 4096 bytes of genuinely unique prose
    // followed by a 3000-byte trailing segment that is byte-identical to a
    // small standalone document. The two documents' own *whole-document*
    // jaccard estimate is well below threshold (this is deliberately NOT a
    // document-level near-duplicate pair) -- only the large document's
    // second *segment* matches the small document at all.
    auto root = scratchRoot("segment-conflation");
    scope(exit) rmdirRecurse(root);

    string uniqueContent;
    while (uniqueContent.length < 4096)
        uniqueContent ~= "genuinely unique large document prose about distant mountain ranges. ";
    uniqueContent = uniqueContent[0 .. 4096];

    string boilerplate;
    while (boilerplate.length < 3000)
        boilerplate ~= "standard site footer boilerplate shared verbatim across many pages. ";
    boilerplate = boilerplate[0 .. 3000];

    auto largeContent = uniqueContent ~ boilerplate;
    assert(largeContent.length == 7096);

    // `DocumentId.from` hashes the source locator, so which of the two IDs
    // sorts first is not directly controllable by content; search a small,
    // fixed, deterministic sequence of record-key salts for one where the
    // small document's ID sorts *before* the large document's -- exactly
    // the ordering the reviewer's own live repro hit, and the one
    // PruningPolicy.keepFirst is least safe under (it would otherwise pick
    // the large, mostly-unique document as representative and this
    // fixture would prove nothing about the bug).
    string largeKey, smallKey;
    foreach (salt; 0 .. 64) {
        auto candidateLarge = "large-mostly-unique-" ~ salt.to!string;
        auto candidateSmall = "small-boilerplate-only-" ~ salt.to!string;
        auto largeId = testDocument("s", candidateLarge, "x").id;
        auto smallId = testDocument("s", candidateSmall, "x").id;
        if (smallId.text < largeId.text) {
            largeKey = candidateLarge;
            smallKey = candidateSmall;
            break;
        }
    }
    assert(largeKey.length != 0,
        "fixture bug: could not find a salt where the small document's ID sorts before " ~
        "the large document's within 64 tries");

    auto largeDoc = testDocument("s", largeKey, largeContent);
    auto smallDoc = testDocument("s", smallKey, boilerplate);

    // Fixture self-check, using the real pipeline's own signature/estimate
    // functions (not a hand-computed guess): confirms this really is the
    // "segment matches, whole document does not" shape before trusting any
    // conclusion drawn from it.
    auto largeSig = similaritySignatures(largeDoc.id, largeDoc.content);
    auto smallSig = similaritySignatures(smallDoc.id, smallDoc.content);
    import domain.near_dedup_decision : jaccardEstimate;
    assert(jaccardEstimate(largeSig.document, smallSig.document) < nearDuplicateThreshold,
        "fixture bug: the two whole documents must NOT be near-duplicates of each other");
    assert(largeSig.segments.length >= 2,
        "fixture bug: the large document must split into at least two segments");
    assert(jaccardEstimate(largeSig.segments[1], smallSig.document) >= nearDuplicateThreshold,
        "fixture bug: the large document's second segment must closely match the small document");

    auto documents = [largeDoc, smallDoc];
    auto destination = buildPath(root, "near-dedup.overlay");
    auto prunedShardPath = buildPath(root, "near-dedup-pruned.shard");
    auto shard = buildFixtureShard(root, "segment-conflation", documents, destination);
    shard.prunedDestination = prunedShardPath;

    writeNearDedupOverlays([shard]); // default PruningPolicy.keepFirst
    assertNoRepresentativeDangles(destination, prunedShardPath);

    auto prunedDocuments = readAllDocuments(prunedShardPath);
    bool[string] survivingIds;
    foreach (document; prunedDocuments) survivingIds[document.id.text] = true;
    assert((largeDoc.id.text in survivingIds) !is null,
        "a document that is not a whole-document near-duplicate of anything must never be " ~
        "pruned just because one of its segments matches an unrelated small document " ~
        "(segment-level candidates must never drive a pruning decision)");
}

unittest {
    // Issue #480: PruningPolicy.keepLongest, exercised end to end through
    // this module's real external-memory pipeline (not the pure decision
    // function directly). Two documents share enough 5-byte shingles to
    // cluster as a near-duplicate pair (jaccardEstimate >= 0.8) despite the
    // second being longer than the first, thanks to a distinct trailing
    // sentence appended to it -- so keepFirst and keepLongest reach
    // genuinely different, independently verified representative choices.
    auto root = scratchRoot("keep-longest");
    scope(exit) rmdirRecurse(root);
    string shortText;
    foreach (_; 0 .. 8) shortText ~= "the quick brown fox jumps over the lazy dog. ";
    // A short, distinct trailing word (independently verified via a throwaway
    // probe against the real `similaritySignatures`/`jaccardEstimate`
    // pipeline to land comfortably above the 0.8 threshold: 0.90625) is
    // enough to make the two copies genuinely different byte sequences
    // without breaking their near-duplicate clustering.
    auto longText = shortText ~ "extra.";
    assert(longText.length > shortText.length);

    auto shortDoc = testDocument("s", "short-copy", shortText);
    auto longDoc = testDocument("s", "long-copy", longText);
    auto shortSig = similaritySignatures(shortDoc.id, shortDoc.content);
    auto longSig = similaritySignatures(longDoc.id, longDoc.content);
    import domain.near_dedup_decision : jaccardEstimate;
    assert(jaccardEstimate(shortSig.document, longSig.document) >= nearDuplicateThreshold,
        "fixture bug: short/long copies must cluster as near-duplicates for this test to prove anything");

    auto documents = [shortDoc, longDoc];

    auto keepFirstDestination = buildPath(root, "keep-first.overlay");
    auto keepFirstShard = buildFixtureShard(root, "keep-first", documents, keepFirstDestination);
    writeNearDedupOverlays([keepFirstShard], null, PruningPolicy.keepFirst);
    auto keepFirstRecords = readAllAnnotations(keepFirstDestination);
    assert(keepFirstRecords.length == 1);
    auto expectedKeepFirstRepresentative =
        shortDoc.id.text < longDoc.id.text ? shortDoc.id.text : longDoc.id.text;

    auto keepLongestDestination = buildPath(root, "keep-longest.overlay");
    auto keepLongestShard = buildFixtureShard(root, "keep-longest", documents, keepLongestDestination);
    writeNearDedupOverlays([keepLongestShard], null, PruningPolicy.keepLongest);
    auto keepLongestRecords = readAllAnnotations(keepLongestDestination);
    assert(keepLongestRecords.length == 1);

    auto sourceDocuments = readAllDocuments(keepLongestShard.source);
    ShardDocument bySourceId(string id) {
        foreach (document; sourceDocuments) if (document.id.text == id) return document;
        assert(false, "missing source document");
    }
    auto keepLongestDecoded = decodeCanonicalNearDedupLink(
        keepLongestRecords[0].fields, bySourceId(keepLongestRecords[0].documentId));
    assert(keepLongestDecoded.representativeId == longDoc.id,
        "keepLongest must select the longer document as representative");
    assert(keepLongestDecoded.documentId == shortDoc.id);
    assert(keepLongestDecoded.representativeId.text != expectedKeepFirstRepresentative ||
        longDoc.id.text == expectedKeepFirstRepresentative,
        "keepLongest's choice should differ from keepFirst's whenever the longer " ~
        "document isn't already the lexicographically-first one");
}

unittest {
    // Issue #480: the actual removal capability. A prunedDestination shard
    // physically omits every non-representative near-duplicate while
    // keeping every other document byte-for-byte -- proven by reading the
    // pruned shard back as an ordinary C01 document shard, not by
    // inspecting an annotation. Mirrors the "basic" fixture above (two
    // byte-identical documents, one solo document, one too-short-to-signature
    // document) so its already-verified detection semantics carry over.
    auto root = scratchRoot("prune-basic");
    scope(exit) rmdirRecurse(root);
    auto documents = [
        testDocument("s", "a", "the quick brown fox jumps over the lazy dog"),
        testDocument("s", "b", "the quick brown fox jumps over the lazy dog"),
        testDocument("s", "solo", "a wildly different unrelated sentence about oceans"),
        testDocument("s", "short", "hi"),
    ];
    auto destination = buildPath(root, "near-dedup.overlay");
    auto prunedShardPath = buildPath(root, "near-dedup-pruned.shard");
    auto shard = buildFixtureShard(root, "prune-basic", documents, destination);
    shard.prunedDestination = prunedShardPath;

    writeNearDedupOverlays([shard]);
    assertNoRepresentativeDangles(destination, prunedShardPath);

    auto aId = testDocument("s", "a", "x").id;
    auto bId = testDocument("s", "b", "x").id;
    auto soloId = testDocument("s", "solo", "x").id;
    auto shortId = testDocument("s", "short", "x").id;
    auto expectedRepresentative = aId.text < bId.text ? aId : bId;
    auto expectedDropped = expectedRepresentative == aId ? bId : aId;

    auto prunedDocuments = readAllDocuments(prunedShardPath);
    assert(prunedDocuments.length == 3,
        "pruned shard must drop exactly the one non-representative duplicate");
    bool[string] prunedIds;
    foreach (document; prunedDocuments) prunedIds[document.id.text] = true;
    assert((expectedRepresentative.text in prunedIds) !is null,
        "the representative document must survive pruning");
    assert((expectedDropped.text in prunedIds) is null,
        "the non-representative duplicate must be physically absent from the pruned shard");
    assert((soloId.text in prunedIds) !is null, "a non-duplicate document must survive pruning");
    assert((shortId.text in prunedIds) !is null,
        "a document never signature-eligible at all must survive pruning untouched");

    // The surviving representative's content is untouched -- pruning drops
    // whole documents, it never edits a kept one.
    foreach (document; prunedDocuments)
        if (document.id == expectedRepresentative)
            assert(document.content == cast(ubyte[])"the quick brown fox jumps over the lazy dog".dup);
}

unittest {
    // Issue #480: a shard that never names a prunedDestination gets no
    // pruned output at all -- the empty default really does mean "skip
    // pruning for this shard", not "prune to an empty/degenerate path".
    auto root = scratchRoot("prune-off-default");
    scope(exit) rmdirRecurse(root);
    auto content = "prune-off-by-default fixture content shared by two documents";
    auto documents = [testDocument("s", "one", content), testDocument("s", "two", content)];
    auto destination = buildPath(root, "near-dedup.overlay");
    auto shard = buildFixtureShard(root, "prune-off-default", documents, destination);
    assert(shard.prunedDestination.length == 0, "fixture bug: prunedDestination must default empty");

    writeNearDedupOverlays([shard]);

    // No file was ever created at any plausible "would-have-been" pruned
    // path, and the annotation overlay itself still names exactly one link
    // -- pruning being off changes nothing about the existing behavior.
    assert(!exists(buildPath(root, "prune-off-default-source.shard.pruned")));
    assert(readAllAnnotations(destination).length == 1);
}

unittest {
    // Issue #480: preflight rejects an unsafe prunedDestination exactly as
    // strictly as it already rejects an unsafe `destination` -- aliasing
    // the shard's own annotation destination, and duplicating another
    // shard's destination or prunedDestination across the batch.
    auto root = scratchRoot("prune-preflight");
    scope(exit) rmdirRecurse(root);
    auto content = "preflight fixture content";
    auto documents = [testDocument("s", "one", content)];

    auto destination = buildPath(root, "near-dedup.overlay");
    auto selfAliasShard = buildFixtureShard(root, "self-alias", documents, destination);
    selfAliasShard.prunedDestination = destination;
    bool selfAliasRejected;
    try writeNearDedupOverlays([selfAliasShard]);
    catch (Exception) selfAliasRejected = true;
    assert(selfAliasRejected,
        "a prunedDestination aliasing the shard's own annotation destination must be rejected");

    auto destinationA = buildPath(root, "a.overlay");
    auto destinationB = buildPath(root, "b.overlay");
    auto sharedPrunedPath = buildPath(root, "shared.pruned.shard");
    auto shardA = buildFixtureShard(root, "dup-a", documents, destinationA);
    shardA.prunedDestination = sharedPrunedPath;
    auto shardB = buildFixtureShard(root, "dup-b",
        [testDocument("s2", "two", content)], destinationB);
    shardB.prunedDestination = sharedPrunedPath;
    bool duplicateRejected;
    try writeNearDedupOverlays([shardA, shardB]);
    catch (Exception) duplicateRejected = true;
    assert(duplicateRejected,
        "two shards naming the same prunedDestination path must be rejected");
    assert(!exists(sharedPrunedPath), "a rejected batch must not leave a partial pruned shard behind");
}

unittest {
    // Issue #492 (round 2 review): the always-on annotation/reporting
    // overlay (Phase B/C) must still report a segment-level near-dup match
    // -- the exact richness #37 shipped and #480's round-1 fix (918a0db)
    // unintentionally narrowed away by excluding every segment-level bucket
    // member from ever becoming a `CandidateRow` at all. Reuses the issue's
    // own round-2 empirical repro shape verbatim: a 7096-byte document made
    // of 4096 bytes of genuinely unique prose followed by a 3000-byte
    // trailing segment byte-identical to a small standalone document --
    // confirmed by the issue body to publish 1 link record before 918a0db
    // and 0 after. This fixture (fail-before/pass-after against that same
    // fix; see this module's own history) proves this module is back to 1.
    // The "segment-conflation" fixture above proves, independently, that
    // the large document still never gets physically pruned for it --
    // together the two prove the decoupling this issue asks for.
    auto root = scratchRoot("segment-richness");
    scope(exit) rmdirRecurse(root);

    string uniqueContent;
    while (uniqueContent.length < 4096)
        uniqueContent ~= "another distinct unrelated passage about deep sea currents. ";
    uniqueContent = uniqueContent[0 .. 4096];

    string boilerplate;
    while (boilerplate.length < 3000)
        boilerplate ~= "standard site footer boilerplate shared verbatim across many pages. ";
    boilerplate = boilerplate[0 .. 3000];

    auto largeContent = uniqueContent ~ boilerplate;
    assert(largeContent.length == 7096);

    string largeKey, smallKey;
    foreach (salt; 0 .. 64) {
        auto candidateLarge = "richness-large-" ~ salt.to!string;
        auto candidateSmall = "richness-small-" ~ salt.to!string;
        auto largeId = testDocument("s", candidateLarge, "x").id;
        auto smallId = testDocument("s", candidateSmall, "x").id;
        if (smallId.text < largeId.text) {
            largeKey = candidateLarge;
            smallKey = candidateSmall;
            break;
        }
    }
    assert(largeKey.length != 0,
        "fixture bug: could not find a salt where the small document's ID sorts before " ~
        "the large document's within 64 tries");

    auto largeDoc = testDocument("s", largeKey, largeContent);
    auto smallDoc = testDocument("s", smallKey, boilerplate);

    // Fixture self-check, using the real pipeline's own signature/estimate
    // functions: confirms this really is the "segment matches, whole
    // document does not" shape before trusting any conclusion drawn from
    // it.
    auto largeSig = similaritySignatures(largeDoc.id, largeDoc.content);
    auto smallSig = similaritySignatures(smallDoc.id, smallDoc.content);
    import domain.near_dedup_decision : jaccardEstimate;
    assert(jaccardEstimate(largeSig.document, smallSig.document) < nearDuplicateThreshold,
        "fixture bug: the two whole documents must NOT be near-duplicates of each other");
    assert(largeSig.segments.length >= 2,
        "fixture bug: the large document must split into at least two segments");
    assert(jaccardEstimate(largeSig.segments[1], smallSig.document) >= nearDuplicateThreshold,
        "fixture bug: the large document's second segment must closely match the small document");

    auto documents = [largeDoc, smallDoc];
    auto destination = buildPath(root, "near-dedup.overlay");
    auto shard = buildFixtureShard(root, "segment-richness", documents, destination);

    writeNearDedupOverlays([shard]); // default PruningPolicy.keepFirst, no prunedDestination named

    auto records = readAllAnnotations(destination);
    assert(records.length == 1,
        "issue #492: a segment-level near-dup match must still be reported by the always-on " ~
        "annotation overlay -- richness restored to pre-#480 (918a0db) levels");

    auto sourceDocuments = readAllDocuments(shard.source);
    ShardDocument bySourceId(string id) {
        foreach (document; sourceDocuments) if (document.id.text == id) return document;
        assert(false, "missing source document");
    }
    auto decoded = decodeCanonicalNearDedupLink(records[0].fields, bySourceId(records[0].documentId));
    assert(decoded.documentId == largeDoc.id,
        "the large document is the non-representative side: its own ID sorts after the small " ~
        "document's");
    assert(decoded.representativeId == smallDoc.id,
        "the small boilerplate-only document is named representative for this segment-level match");
}

unittest {
    // Issue #492 ("Also recommended"): a real end-to-end multi-bucket
    // conflict, exercised through this module's actual external-memory
    // Phase A-D pipeline -- not just the 6 pure synthetic
    // resolveRepresentativeChains unit tests above, which hand it a map
    // literal directly and never touch a real shard, bucket overlay, or C01
    // write at all. Three whole-document-level documents, no segment-level
    // candidates involved (kept orthogonal to the segment/document-level
    // decoupling proven by the two fixtures above): "q" shares a large
    // common passage with both "p" and "r", plus a small tail exclusive to
    // (passage+p) and a second small tail exclusive to (passage+r) -- so
    // q's own signature genuinely collides, on real distinct LSH bands
    // (confirmed below against the real persisted band values, not merely
    // an aggregate jaccard estimate), with p's signature in one bucket and
    // with r's signature in another. Critically (confirmed below by an
    // explicit self-check, not merely assumed), no single band collides
    // across all three documents at once, so no bucket ever unions
    // {p,q,r} directly -- each of the two exclusive buckets independently
    // computes its own local winner, and with document IDs ordered
    // p < q < r, those two buckets disagree on what q's own local winner
    // even is: bucket{p,q} names p (q loses, p < q), bucket{q,r} names q
    // (r loses, q < r). The *raw*, pre-chain-resolution representative map
    // is therefore a genuine two-hop chain (r -> q -> p), not merely two
    // buckets flatly agreeing on the same final representative: q itself
    // is both a loser (to p) and a winner (over r) at once. Verified
    // separately (see this module's own review history) that stubbing out
    // the `resolveRepresentativeChains` call entirely makes
    // `assertNoRepresentativeDangles` fail against this exact fixture --
    // i.e. chain resolution is genuinely load-bearing here, not just
    // exercised incidentally.
    auto root = scratchRoot("multi-bucket-conflict");
    scope(exit) rmdirRecurse(root);

    string repeatUnique(string prefix, size_t n) {
        string r;
        foreach (i; 0 .. n) r ~= prefix ~ i.to!string ~ " ";
        return r;
    }
    // Empirically verified (see this module's own review history) real
    // MinHash construction: a per-fixture-unique token prefix ("seed"
    // 422) avoids incidental cross-fixture shingle overlap with any other
    // unittest in this module, and this specific (base length, tail
    // length) pair was found, by exhaustive search over real
    // `similaritySignatures` output, to be one of a small number that
    // simultaneously satisfies every property this fixture's self-check
    // asserts below.
    enum seed = 422;
    auto base = repeatUnique("b" ~ seed.to!string ~ "w", 20);
    auto tailP = repeatUnique("p" ~ seed.to!string ~ "t", 6);
    auto tailR = repeatUnique("r" ~ seed.to!string ~ "t", 6);
    auto pContent = base ~ tailP;
    auto qContent = base ~ tailP ~ tailR;
    auto rContent = base ~ tailR;

    // Find three record-key salts whose hashed DocumentIds sort in exactly
    // the order this fixture needs: p < q < r. `DocumentId.from` hashes the
    // source locator, not the literal key text, so candidate salts are
    // generated and sorted by their real ID rather than assumed from the
    // key spelling.
    string[] candidates;
    foreach (salt; 0 .. 64) candidates ~= "conflict-role-" ~ salt.to!string;
    candidates.sort!((a, b) =>
        testDocument("s", a, "x").id.text < testDocument("s", b, "x").id.text);
    auto pKey = candidates[0];
    auto qKey = candidates[1];
    auto rKey = candidates[2];

    auto pDoc = testDocument("s", pKey, pContent);
    auto qDoc = testDocument("s", qKey, qContent);
    auto rDoc = testDocument("s", rKey, rContent);
    assert(pDoc.id.text < qDoc.id.text && qDoc.id.text < rDoc.id.text,
        "fixture bug: candidate ordering invariant broken");

    // Fixture self-check, using the real pipeline's own signature/estimate
    // functions: confirms the exact shape this test relies on before
    // trusting any conclusion drawn from it -- p and q are real
    // near-duplicates, q and r are real near-duplicates, but p and r
    // directly are not; p/q's collision and q/r's collision each land on
    // at least one genuinely different (bandIndex, bandKeyValue) pair the
    // other pair does not share; and -- the property that makes this a
    // real chain rather than a flat three-way tie -- no single band
    // collides across all three documents at once (no bucket ever unions
    // {p,q,r} directly).
    import domain.near_dedup_decision : jaccardEstimate;
    auto pSig = similaritySignatures(pDoc.id, pDoc.content);
    auto qSig = similaritySignatures(qDoc.id, qDoc.content);
    auto rSig = similaritySignatures(rDoc.id, rDoc.content);
    assert(jaccardEstimate(pSig.document, qSig.document) >= nearDuplicateThreshold,
        "fixture bug: p and q must be real near-duplicates");
    assert(jaccardEstimate(qSig.document, rSig.document) >= nearDuplicateThreshold,
        "fixture bug: q and r must be real near-duplicates");
    assert(jaccardEstimate(pSig.document, rSig.document) < nearDuplicateThreshold,
        "fixture bug: p and r must NOT be direct near-duplicates");
    bool pqExclusiveBand, qrExclusiveBand, tripleCollisionBand;
    foreach (b; 0 .. pSig.document.bands.length) {
        auto pv = pSig.document.bands[b], qv = qSig.document.bands[b], rv = rSig.document.bands[b];
        if (pv == qv && pv == rv) tripleCollisionBand = true;
        if (pv == qv && pv != rv) pqExclusiveBand = true;
        if (qv == rv && qv != pv) qrExclusiveBand = true;
    }
    assert(pqExclusiveBand, "fixture bug: p/q must collide on a real band r does not share");
    assert(qrExclusiveBand, "fixture bug: q/r must collide on a real band p does not share");
    assert(!tripleCollisionBand,
        "fixture bug: no band may collide across all three documents at once -- that would let " ~
        "a single bucket union {p,q,r} directly and flatten this into a one-hop tie, not the " ~
        "two-hop chain this fixture exists to exercise");

    auto documents = [pDoc, qDoc, rDoc];
    auto destination = buildPath(root, "near-dedup.overlay");
    auto prunedShardPath = buildPath(root, "near-dedup-pruned.shard");
    auto shard = buildFixtureShard(root, "multi-bucket-conflict", documents, destination);
    shard.prunedDestination = prunedShardPath;

    writeNearDedupOverlays([shard]); // default PruningPolicy.keepFirst
    assertNoRepresentativeDangles(destination, prunedShardPath);

    // q's raw, per-bucket representative is p (from the p/q-exclusive
    // bucket, where p < q wins); r's raw, per-bucket representative is q
    // (from the q/r-exclusive bucket, where q < r wins) -- q itself, not
    // p. Without `resolveRepresentativeChains` walking that second hop,
    // r's published representative would be q, which is itself dropped
    // from the pruned shard (a genuine dangling reference, exactly the
    // bug issue #480 round 1 closed). The real, published, chain-resolved
    // representative for both q and r must be p.
    auto records = readAllAnnotations(destination);
    auto sourceDocuments = readAllDocuments(shard.source);
    ShardDocument bySourceId(string id) {
        foreach (document; sourceDocuments) if (document.id.text == id) return document;
        assert(false, "missing source document");
    }
    NearDuplicateLink linkFor(string documentId) {
        foreach (record; records)
            if (record.documentId == documentId)
                return decodeCanonicalNearDedupLink(record.fields, bySourceId(documentId));
        assert(false, "missing expected link for " ~ documentId);
    }
    assert(linkFor(qDoc.id.text).representativeId == pDoc.id,
        "q's published representative must be p -- its own raw, single-bucket winner");
    assert(linkFor(rDoc.id.text).representativeId == pDoc.id,
        "r's published representative must resolve to p, not dangle at its raw, one-hop " ~
        "winner q (which is itself a non-representative pruning drops) -- this is the real " ~
        "two-hop chain resolveRepresentativeChains exists to walk");

    // Every representative named above must physically survive pruning --
    // the exact invariant assertNoRepresentativeDangles already checked
    // end to end, restated here as a direct, human-legible assertion
    // against the pruned shard.
    auto prunedDocuments = readAllDocuments(prunedShardPath);
    bool[string] survivingIds;
    foreach (document; prunedDocuments) survivingIds[document.id.text] = true;
    assert((pDoc.id.text in survivingIds) !is null, "p (the representative) must survive pruning");
    assert((qDoc.id.text in survivingIds) is null, "q is a non-representative and must be pruned");
    assert((rDoc.id.text in survivingIds) is null, "r is a non-representative and must be pruned");
}
