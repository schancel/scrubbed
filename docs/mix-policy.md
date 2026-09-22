# Pure annotation-driven mix policy (Stage 1)

`domain.mix_policy` chooses a document ID for inclusion using only caller-supplied,
validated C02 quality and C04 exact-dedup annotations. The Stage 2a effects
facade joins those annotations to C01 source revisions and enforces analyzer
versions; a later stage must stream export. The pure policy itself receives
neither source bytes nor a source locator.

The first policy admits only quality `keep` and exact-dedup representatives to
sampling. `drop`, `quarantine`, and duplicates get distinct exclusion reasons.
Missing annotations either fail with `mix policy: missing annotation` or are
excluded with a typed missing-quality or missing-dedup reason. Invalid IDs,
contradictory dedup evidence (including a representative ID greater than its
member ID), invalid disposition, and malformed policy fail before selection.
The caller must supply already validated C02 decisions and
C04 links; this module rechecks their structural and ID consistency but cannot
prove that their content digests belong to a C01 revision.

`MixPolicy` uses exactly 16 lowercase hexadecimal seed digits (eight bytes),
an integer numerator/denominator in [0,1] with denominator at most 1,000,000,
and a missing-annotation mode. Canonical policy bytes are
`scrubbed:mix-policy:v1\0`, then the eight seed bytes, big-endian 32-bit
numerator and denominator, then one missing-mode byte. These bytes are stable
provenance for a future export. Changing the seed only affects eligible
sampling, never C02/C04 exclusions.

For each eligible ID, SHA-256 receives `scrubbed:mix-sample:v1\0`, the eight
seed bytes, and canonical typed `DocumentId` text. The first eight digest
bytes form an unsigned big-endian integer. Its remainder modulo the denominator
is the bucket; a bucket below the numerator is selected. Excluded records use
`uint.max` as their unsampled-bucket sentinel. Modulo reduction has a bounded
bias (at most one extra source value per bucket over the 2^64 hash space);
this is reproducible selection, not a claim of statistical representativeness.

`decideMix` is stateless per ID, so arrival order and worker partition do not
affect the answer. `decideMixBatch` is a bounded 4,096-record convenience that
rejects duplicate IDs, returns ID-sorted decisions and selected IDs, and counts
each typed reason. Streaming consumers own cross-batch/cross-shard uniqueness.
The decision's canonical bytes include only ID, include flag, reason, and
bucket. They do not contain private source bytes or locators.

The pure policy remains opt-in and has no persistence or CLI migration.
Stage 2a rollback removes the read-only facade, C04 decoder, and canonical-ID
parser while preserving Stage 1. Versioned export is separate work; the parent
outcome is not complete until that integration is reviewed.

## Stage 2a read-only C01 join

`effects.mix_overlay.visitMixDecisions` joins one immutable document shard with
one C02 quality-decision overlay and one C04 exact-dedup overlay. It validates
both analyzer headers even on an empty shard, then delegates source-shard
digest, content revision, order, and orphan checks to C01's streaming join.
C02 decision values are replay-decoded against the caller's canonical quality
policy. C04 links require exactly the five canonical fields, a strict decimal
cardinality, typed representative ID, and SHA-256 of the joined source content.
The `DocumentId.fromCanonicalText` seam only parses stored IDs; it does not
derive new provenance or change their format.

Each source record reaches the pure policy with present or missing evidence.
The synchronous callback receives its typed decision and ephemeral source
content; callers must not retain source content or mistake it for committed
output. The returned report keeps only integer total/reason counts. A late
malformed record can follow an already delivered callback prefix. This API
cannot undo that prefix and offers no durable or atomic output; a later export
must stage privately and validate before publication. Stage 2b versioned
durable export is separate, and #40 remains open until it lands.
