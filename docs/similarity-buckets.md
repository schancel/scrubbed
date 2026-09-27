# Similarity buckets, disk-backed successor

`effects.similarity_buckets.writeSimilarityBucketOverlays` turns
caller-supplied `domain.similarity_signature.SimilaritySignatures`
(document- and segment-level) into disk-backed, skew-capped candidate
buckets, and persists them as a durable C01 overlay analyzer.

It does **not** read C01 shards, compute signatures, decide duplicates,
select a representative, or group candidates across bands — those remain
#37's separate, still-unspecified scope.

## Inputs

The caller supplies:

- each source shard and its similarity-bucket overlay destination
- a bounded pull reader (`SimilarityBatchReader`, the same `bool
  next(out T)` shape as `DocumentShardReader.next`/`OverlayReader.next`)
  yielding one document's signatures at a time, already matched to a shard
  index and carrying that document's content digest

A convenience `similarityBatchReader` wraps an in-memory array for
small callers/tests; production callers should stream from their own
bounded source.

## Batch-wide destination preflight

`writeSimilarityBucketOverlays` takes a whole batch of `(source,
destination)` pairs in one call — the same shape as
`exact_dedup_overlay.writeExactDedupOverlays`, defended the same way via
the same `PreflightPlan` mechanism (mirrored here, not reinvented).

**Up front, before any shard is processed:** a one-time static plan
captures every source's regular-file identity (path and `dev:ino`) and
rejects any destination in the batch that lexically aliases any source
path, or whose existing inode aliases any source's inode. All destinations
must share one directory; duplicate destinations are refused.

Why this exists: `OverlayWriter.publish`'s own `checkReplaceTarget` only
guards a shard's destination against *that same shard's* paired source —
it has no visibility into the rest of the batch. Without the batch-wide
plan, a caller's off-by-one when assembling `shards[]` (say, shard A's
destination accidentally pointing at shard B's real immutable source)
would silently overwrite another shard's content, with no exception.

**That static snapshot only proves the batch was safe at the moment it was
taken.** The external sort between preflight and publication can run for a
long time, so the plan is re-checked, not just consulted once:

1. Every destination is re-validated again immediately after the sort
   completes, before any shard opens (`validateAllDestinations`).
2. The active shard's source and destination are re-validated again
   immediately before its `OverlayWriter` is constructed.
3. The caller-supplied `PublishFault` is wrapped so the same two checks
   also run on every `PublishStep` callback while that shard is
   publishing.

These are exactly the three re-validation points `exact_dedup_overlay`
uses for its own `PreflightPlan` — not an approximation of them.

**This closes a real, verified attack:** a `PublishFault` callback (the
same hook this module's own crash/restart tests use) that renames one
shard's source file to become another, not-yet-processed shard's
destination path. The static plan alone can't catch this, since that
destination legitimately didn't exist yet at preflight time.
`experiments/similarity/bucket_check.d`'s `toctouRelinkRejection`
reproduces this exact shape.

**Residual exposure:** the same one `exact_dedup_overlay` itself documents
for its identical mechanism — a hostile process racing to replace a path
in the narrow window between a re-validation check and the filesystem
operation it immediately guards (for example, between
`validateSource`/`validateDestination` and `OverlayWriter`'s own
`open`/`stat` calls) is outside this guarantee. That window is now
consistently narrow throughout the run, not a single upfront check with
exposure spanning the whole external-sort pass.

## Candidate explosion and external sort

For every signature (document or segment) with `hasKeys == true`, one
candidate record is emitted per populated band position, keyed by
`(bandIndex, bandKeyValue)` and carrying the document ID, segment flag, and
segment ordinal. An abstained signature (`hasKeys == false`) contributes
nothing.

Candidates are external-sorted by `(bandIndex, bandKeyValue, documentId,
segmentOrdinal)`, with one addition: a document's own signature and its
first segment share ordinal 0, so the segment flag (document before
segment) breaks that tie and keeps the order total and deterministic.

The sort reuses the exact external-sort/bounded-merge pattern proven in
`effects.exact_dedup_overlay`: fixed 32-record sort runs, eight-way bounded
merges, disk-spooled run manifests, and scratch cleanup after every pass
and on exit (including on failure). File-descriptor use during a merge is
a fixed `fanIn`-bounded constant, never proportional to corpus size.

## Skew handling (owner-decided)

Each `(bandIndex, bandKeyValue)` bucket has a fixed cap (`bucketCap`,
default `defaultSimilarityBucketCap = 4096`, caller-overridable).

A single sequential scan over the sorted candidate stream groups
consecutive same-key records. Only the first `bucketCap` members in that
stable sort order are kept; a bucket whose true membership exceeds the cap
is marked `overflowed` on every member it keeps — over-cap members are
truncated, never silently dropped without a trace. Memory for one group is
bounded by `bucketCap` records, never by the group's true size: a
pathologically skewed bucket with millions of members is buffered only up
to the cap, while the rest are counted and discarded.

## Versioning

The overlay's analyzer version is
`similarity-buckets:v1:signature=<signature profile>:cap=<bucketCap>` —
embedding both `byte-shingle-minhash:v1` (the frozen upstream signature
profile) and the configured cap. A future change to either is a detectable
overlay-header/version mismatch for any reader, the same mismatch
discipline every other C01 overlay uses, not silent corruption.

Every incoming signature is also validated at ingestion time against the
current `signatureVersion` and its own shape (document vs. segment
flag/ordinal consistency, document ID agreement across a document's own
segments); a mismatch is refused immediately.

## Persistence

Buckets are a durable C01 overlay: analyzer key `similarity-buckets`, the
version above, one `OverlayWriter`/`OverlayReader` per shard — exactly like
`exact_dedup_overlay` and `quality_overlay`.

- Each document that survived truncation on at least one band gets exactly
  one strictly-ID-sorted `AnnotationRecord`, with a single field
  (`members`) packing every surviving `(segment flag, segmentOrdinal,
  bandIndex, bandKeyValue, overflowed)` row for that document, sorted the
  same way.
- A document with no surviving band membership (fully abstained, or every
  band truncated away) gets no record at all — `JoinedOverlay.present ==
  false` at join time, the same "not present" state every other overlay
  supports.
- The packed encoding is compact by construction (1 byte flags + 2 bytes
  segment ordinal + 8 bytes band key per row): even a maximal single
  document (1 MiB content, ~257 segments, all 16 bands surviving at every
  segment) encodes to roughly 45 KiB — comfortably under C01's fixed 64 KiB
  per-document annotation cap, with margin. `OverlayWriter`/
  `encodeAnnotation` still enforce that cap directly, so a violation fails
  loud rather than silently truncating.

`decodeSimilarityBucketMembers` decodes that single field after the caller
has verified the overlay header's analyzer key/version — the same shape as
`decodeCanonicalDedupLink` and `decodeDecisionValue`.

Any future consumer (out of scope here — see #37) reaches this overlay
through `effects.document_shards.joinShards`, exactly the way
`effects.mix_overlay` already joins the dedup and quality overlays; no
change to `mix_overlay.d` was needed or made. `joinShards` takes an
arbitrary list of overlay paths, so this overlay is already
discoverable/joinable once a caller names its path. Extending
`mix_overlay`'s specific quality+dedup join to also consume similarity
buckets would itself be a near-duplicate decision (#37's scope), so it
wasn't done here.

## Two deferred decisions (this slice's calls)

1. **Document vs. segment bucket namespace collision.** A document's own
   signature and one of its segments can land in the same `(bandIndex,
   bandKeyValue)` bucket — most commonly the document and its first
   segment, both at ordinal 0, when the document is small enough to be
   exactly one segment. This implementation doesn't merge or deduplicate
   them: both are independent candidate rows, distinguished by the
   `segment` flag, and both count toward the same bucket's cap/overflow
   accounting. They're never collapsed into one "identity," since a
   document-level match and a segment-level match are different candidate
   signals with different downstream meaning (whole-document vs.
   partial-content similarity); conflating them would silently discard
   information a future near-duplicate decision (#37) may need.
2. **Wiring production signature computation.** This slice intentionally
   doesn't read C01 shards or call
   `domain.similarity_signature.similaritySignatures`. A thin adapter (C01
   shard → signatures → `SimilarityBatchEntry` stream) is a further
   slice's job: it means deciding how much of a document to keep resident
   while streaming its segments and how batches line up across parallel
   workers — real wiring questions, not a narrow addition — so it's left
   for its own re-groomed slice, not stubbed here.

## Proof (focused checker)

`experiments/similarity/bucket_check.d` builds a large synthetic corpus
with a deliberately skewed band-key distribution and forced collisions,
and asserts:

- exact truncation counts and the `overflowed` flag on every skewed bucket
- byte-identical overlays across input order and shard order, and identical
  decoded band membership under a different worker/shard partitioning (a
  different shard count changes each shard's C01 header digest, so only the
  decoded content — not the raw bytes — is compared there)
- convergence after a simulated crash (a publish-fault injected mid-run,
  then an unmodified re-run)
- the source shard is never mutated by a run
- scratch cleanup after both success and failure
- a held-out authored related/unrelated fixture reporting descriptive
  (non-population) band-sharing recall
- a regression that a destination aliasing another shard's real source in
  the same batch is rejected before any publication, with that other
  shard's content proven byte-identical and inode-identical afterward
- a regression that a fault-hook-triggered mid-run relink of one shard's
  source onto another, not-yet-processed shard's destination path is
  rejected before that destination is touched
- a bounded resident-set/file-descriptor observation across a large
  repeated run

```sh
ldc2 -O3 -release -d-version=SimilarityBucketsCheck -i -I=source \
    experiments/similarity/bucket_check.d \
    -of=.dub/similarity-buckets-check
.dub/similarity-buckets-check
```

Building with `-d-version=SimilarityBucketsCheck` additionally exposes
scratch-file and peak-batch-size counters that the resource-bound check
reports. The checker's own correctness checks are plain runtime
conditionals, not the language's `assert`, so they run and enforce
regardless of build flags — unlike `experiments/similarity/signature_check.d`,
which does rely on bare `assert()` throughout and therefore needs
`-enable-asserts=true` under `-release`.

## Rollback

Removes this opt-in overlay module, its checker, and this document, plus
any overlays it produced. C01 shards, C04 overlays, and
`similarity_signature.d` are untouched.
