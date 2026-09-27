# Pure annotation-driven mix policy (Stage 1)

`domain.mix_policy` chooses a document ID for inclusion using only
caller-supplied, validated C02 quality and C04 exact-dedup annotations — it
receives neither source bytes nor a source locator. The Stage 2a effects
facade joins those annotations to C01 source revisions and enforces
analyzer versions; a later stage must stream the export.

## Eligibility

Only quality `keep` and exact-dedup representatives are admitted to
sampling. `drop`, `quarantine`, and duplicates each get a distinct exclusion
reason. A missing annotation either fails with `mix policy: missing
annotation` or is excluded with a typed missing-quality/missing-dedup
reason, depending on policy.

Rejected before selection: invalid IDs, contradictory dedup evidence
(including a representative ID greater than its member ID), an invalid
disposition, and a malformed policy. The caller must supply already
validated C02 decisions and C04 links; this module rechecks their
structural and ID consistency but cannot prove their content digests belong
to a C01 revision — that proof happens at the Stage 2a join below.

## Policy and sampling

`MixPolicy` holds exactly 16 lowercase hex seed digits (8 bytes), an integer
numerator/denominator fraction in [0,1] (denominator at most 1,000,000), and
a missing-annotation mode. Canonical policy bytes — stable provenance for a
future export — are:

```
scrubbed:mix-policy:v1\0 + 8 seed bytes + BE32 numerator + BE32 denominator + 1 mode byte
```

For each eligible ID, SHA-256 hashes `scrubbed:mix-sample:v1\0` + the seed
bytes + the canonical `DocumentId` text. The first 8 digest bytes form an
unsigned big-endian value; its remainder modulo the denominator is the
bucket, and a bucket below the numerator is selected. Excluded records use
`uint.max` as their unsampled-bucket sentinel. Modulo reduction has a
bounded bias (at most one extra source value per bucket over the 2^64 hash
space) — this is reproducible selection, not a claim of statistical
representativeness. Changing the seed only affects eligible sampling, never
the C02/C04 exclusions.

`decideMix` is stateless per ID, so arrival order and worker partition never
change the answer. `decideMixBatch` is a bounded 4,096-record convenience
that rejects duplicate IDs, returns ID-sorted decisions and selected IDs,
and counts each typed reason; streaming consumers own cross-batch/
cross-shard uniqueness. A decision's canonical bytes carry only ID, include
flag, reason, and bucket — never source bytes or locators.

The pure policy and export remain opt-in with no CLI migration.

## Stage 2a: read-only C01 join

`effects.mix_overlay.visitMixDecisions` joins one immutable document shard
with one C02 quality-decision overlay and one C04 exact-dedup overlay. It
validates both analyzer headers even on an empty shard, then delegates
source-shard digest, content revision, order, and orphan checks to C01's
streaming join. C02 decision values are replay-decoded against the caller's
canonical quality policy; C04 links must carry exactly the five canonical
fields, a strict decimal cardinality, a typed representative ID, and the
SHA-256 of the joined source content. (`DocumentId.fromCanonicalText` only
parses stored IDs — it never derives new provenance or changes their
format.)

Each source record reaches the pure policy with present-or-missing
evidence. The synchronous callback receives its typed decision and
ephemeral source content — callers must not retain it or mistake it for
committed output. The returned report keeps only integer total/reason
counts. A late malformed record can follow an already-delivered callback
prefix; this API cannot undo that prefix and offers no durable or atomic
output by itself.

Stage 2a rollback removes the read-only facade, C04 decoder, and
canonical-ID parser, while preserving Stage 1.

## Stage 2b: immutable JSONL export

`effects.mix_export.publishMixGeneration` is an opt-in repository API over
the Stage 2a join. It writes exactly one canonical decision row per source
record, in typed document-ID order. Every row carries the include flag,
typed reason, sampling bucket, source-content digest, C02/C04 analyzer
versions, and the mix policy version and digest. Only included rows carry
base64-encoded selected content; excluded rows carry neither source bytes
nor source locators. Missing evidence still follows policy: the default
fails before publication, while explicit exclusion emits a typed
missing-evidence row.

A generation is three v1 records:

| Schema | Contents |
| --- | --- |
| `scrubbed-mix-decision-v1` | canonical JSONL, one row per source record |
| `scrubbed-mix-provenance-v1` | exact C01 shard + C02/C04 overlay digests, analyzer versions, canonical policy bytes/digest, reason counts, decision-file size/digest |
| `scrubbed-mix-commit-v1` | names the decision and provenance files with their exact sizes and SHA-256 digests |

The generation identity is a SHA-256 over those immutable input digests,
analyzer versions, and canonical policy bytes. Identical inputs therefore
produce byte-identical generation files; a changed input or policy gets a
different identity and is published beside the old generation.

### Publication and crash recovery

- The output directory must already exist, be user-owned, and be
  exclusively controlled.
- Generation files are created without replacement and fsynced; the
  implementation then re-reads all rows and closes the row/count/digest
  relationships.
- A fsynced same-directory temporary manifest is published by an atomic
  no-replace hard link — **that commit manifest is the sole visibility
  point.** Generation files written before it are unreferenced.
- If a process dies after linking but before removing its temporary name, a
  reader recognizes the UUID-shaped writer alias once the inode has exactly
  two links, removes it, and then applies the ordinary single-link
  validation. Readers ignore any other unreferenced files left by an
  interrupted writer.
- Readers reject: unknown schemas, noncanonical records, unsafe names,
  changed files, duplicate or unsorted IDs, inconsistent counts or digests,
  and generation identities that don't recompute from the strict-decoded
  provenance.
- Concurrent attempts for the same identity have one winner and never
  replace it.

This is not an atomic transaction across the three files, and the module
never fsyncs the parent directory — it makes no power-loss durability claim,
and does not coordinate writers across machines or defend against a hostile
actor inside the trusted directory. Orphan cleanup is deliberately outside
this API and is safe only after proving that no commit manifest references
the file.

There is no Parquet/Arrow adapter, S3 sink, cluster protocol, C01 migration,
implicit deletion, hidden re-extraction, or default CLI activation in this
stage. C09 may consume these versioned JSONL records but must not
reinterpret them as another schema.

### Rollback

Stops publishing and consuming Stage 2b manifests; already-committed
immutable generations remain inspectable.
