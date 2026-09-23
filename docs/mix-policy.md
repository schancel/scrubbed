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

The pure policy and export remain opt-in with no CLI migration. Stage 2a
rollback removes the read-only facade, C04 decoder, and canonical-ID parser
while preserving Stage 1.

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
cannot undo that prefix and offers no durable or atomic output by itself.

## Stage 2b immutable JSONL export

`effects.mix_export.publishMixGeneration` is an opt-in repository API over the
Stage 2a join. It writes exactly one canonical decision row per source record
in typed document-ID order. Every row carries the include flag, typed reason,
sampling bucket, source-content digest, C02/C04 analyzer versions, and mix
policy version and digest. Only included rows carry selected source content,
encoded as base64; excluded rows carry neither source bytes nor source
locators. Missing evidence still follows the policy: the default fails before
publication, while explicit exclusion emits a typed missing-evidence row.

Three v1 records form a generation. `scrubbed-mix-decision-v1` is canonical
JSONL. `scrubbed-mix-provenance-v1` binds the exact C01 shard and C02/C04
overlay digests, analyzer versions, canonical policy bytes and digest, reason
counts, and decision-file size and digest. `scrubbed-mix-commit-v1` names the
decision and provenance files with their exact sizes and SHA-256 digests. The
generation identity is SHA-256 over those immutable input digests, analyzer
versions, and canonical policy bytes. Identical inputs therefore produce
byte-identical generation files; a changed input or policy has a different
identity and is published beside the old generation.

The output directory must already exist and be user-owned and exclusively
controlled. Generation files are created without replacement and fsynced,
then the implementation re-reads all rows and closes the row/count/digest
relationships. A fsynced same-directory temporary manifest is published by an
atomic no-replace hard link. That commit manifest is the sole visibility
point. If a process dies after linking but before removing its temporary name,
a reader in the trusted exclusive directory recognizes only the exact
UUID-shaped writer alias when the inode has exactly two links, removes it, and
then applies the ordinary single-link validation. Readers ignore other
unreferenced files left by an interrupted writer and reject unknown schemas,
noncanonical records, unsafe names, changed files, duplicate or unsorted IDs,
inconsistent counts or digests, and generation identities that do not
recompute from the strict-decoded provenance. Concurrent attempts for the same
identity have one winner and do not replace it.

This is not an atomic transaction across the three files. The module does not
fsync the parent directory, so it makes no power-loss durability claim, and it
does not coordinate writers across machines or defend against a hostile actor
inside the trusted directory. Orphan cleanup is deliberately outside this API
and is safe only after proving that no commit manifest references the file.
Rollback stops publishing and consuming Stage 2b manifests; already committed
immutable generations remain inspectable. C09 may consume these versioned
JSONL records but must not reinterpret them as another schema. There is no
Parquet/Arrow adapter, S3 sink, cluster protocol, C01 migration, implicit
deletion, hidden re-extraction, or default CLI activation in this stage.
