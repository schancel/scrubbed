# Derivation-identity survey (evidence and evaluation only)

Status: isolated evidence/evaluation slice for issue #349's grooming-pass
scope ("Grooming pass (2026-09-27): real evidence gathered, evaluation-first
slice found"). This document does not commit to a storage/index mechanism,
does not wire anything into the CLI or the stage pipeline, and does not
redesign `domain.document.DocumentId`. It also does not resolve #349 itself
-- the full cross-transform derivation-cache design named there remains
`NEEDS_SPECIFICATION`, pending @schancel's own scope decision. It matches the
posture of this repository's other evaluation docs (`docs/pdfium-evaluation
.md`, `docs/llama-inference-evaluation.md`, `docs/sigv4-evaluation.md`):
real evidence, real reproduction steps, and honest disclosure of what is and
isn't settled.

## Summary of outcome

#349's grooming note correctly identified two disjoint existing mechanisms
that carry partial derivation-identity information: C01 overlay headers
(`effects.document_shards.OverlayReader`/`OverlayWriter`) and
`LocalManifest`'s job-scoped `SinkKey`. Verifying that claim against the real
codebase (not just the three analyzers the grooming note named) turned up
**more C01-overlay analyzers than the grooming note's own inventory
listed** -- seven distinct `(analyzerKey, analyzerVersion)` producers across
five files, not three -- which makes the "already-queryable-in-principle"
side of the ledger real, broader, and independently reproducible. A new
read-only survey tool (`experiments/derivation_survey/check.d`) confirms,
against a real fixture built exclusively with unmodified upstream C01
writers, that header-only inspection genuinely answers "has this document's
shard received transform Y at version Z" -- but also surfaces a real
granularity limit that a naive reading of #349's phrasing would miss: C01
overlays bind to a whole *shard* file, not to an individual document inside
it, so "present" at the header level does not always mean "this document
carries a substantive annotation value." Both findings are demonstrated with
real tool output below, not asserted.

## The two mechanisms, verified

**1. C01 overlay headers.** `effects.document_shards.OverlayReader` opens an
overlay file, validates its magic/length/digest, and decodes a header
(`OverlayHeader{analyzerKey, analyzerVersion, sourceShardDigest}`,
`source/domain/shard_format.d:37-41`) into a public field
(`OverlayReader.header`, `source/effects/document_shards.d:128-165`)
*before* any per-document `AnnotationRecord` is read. Reading that header
never calls `OverlayReader.next()`, so it never decodes a single annotation
record. `OverlayWriter`'s constructor (`document_shards.d:263-280`) digests
the *entire* source shard file (`digestDescriptor`) and binds that digest
into the header at open time -- the same digest `effects.document_shards
.shardDigest(path)` computes on demand, which is what lets a reader verify a
header is bound to a shard's *current* bytes rather than trust a same-named
file blindly.

**2. `LocalManifest`'s `SinkKey`.** `SinkKey{DocumentId, inputSha256,
configSha256, sink}` (`source/effects/local_manifest.d:26-31`) requires a
`configSha256` that, per `docs/local-manifest.md:8-12`, "binds canonical v3
job JSON and the readable `job:v3:` identity, or the explicit canonical v4
plan and `job:v4:` identity, plus file/tree mode, canonical output route,
`compiled-final-events:v1`, and the exact executable digest." An external
caller cannot construct this key without replicating scrubbed's own internal
job-compilation and hashing logic; it can only ask "did the exact job I
already ran produce this row," not "does document X have transform Y at
version Z" in the abstract.

## Real inventory: which stages fall into which bucket

Every module in `source/` that calls `new OverlayWriter(...)` was located and
read (`grep -rn "new OverlayWriter(" source/`), not just the three the
grooming note named:

| `(analyzerKey, analyzerVersion)` | Producing module | Citation |
| --- | --- | --- |
| `exact-dedup` / `exact-bytes:v1` | `effects.exact_dedup_overlay` | `source/effects/exact_dedup_overlay.d:21-22,212-213` |
| `near-dedup` / `near-dedup:v1:signature=...:threshold=0.80` | `effects.near_dedup_overlay` | `source/effects/near_dedup_overlay.d:53-54,251-252` |
| `similarity-buckets` / `similarity-buckets:v1:signature=...:cap=...` | `effects.similarity_buckets` | `source/effects/similarity_buckets.d:19,28-31,307-308` |
| `pii.four-class` / `four-class:v1:locale=...` | `effects.pii_overlay` | `source/effects/pii_overlay.d:15,29-31` (`OverlayWriter` call site further in the same file) |
| `pii.policy` / `policy:v1:findings=...:decision=...` | `effects.pii_policy_overlay` | `source/effects/pii_policy_overlay.d:21,227-231,306-307` |
| `quality.features` / `features:v1:schema=...` | `effects.quality_overlay` | `source/effects/quality_overlay.d:15,25-27` |
| `quality.decisions` / `decisions:v1:feature=...:decision=...:policy=...` | `effects.quality_overlay` | `source/effects/quality_overlay.d:16,29-33` |

All seven are genuinely **C01-overlay-queryable in principle**: any caller
holding the shard path and a candidate overlay path can open the overlay,
read its header, and compare `sourceShardDigest` against `shardDigest(shard)`
-- exactly what this survey's tool does, and exactly what two existing
*consumer* modules already do today as a smaller-scale precedent:
`effects.mix_overlay` (`source/effects/mix_overlay.d:22,37-46`) and
`effects.source_rights_overlay`
(`source/effects/source_rights_overlay.d:60-64`) both open overlays with
`OverlayReader` purely to check `header.analyzerKey`/`analyzerVersion`
against an expected value before trusting or composing their contents.
Header-only inspection is not a new idea this survey invents; it is already
this codebase's own idiom for exactly this kind of check, just not yet
generalized into a standalone reporting tool.

**A real caveat on the grooming note's framing, found while verifying it:**
the note listed `pii-four-class` and (via `html-metadata`) implied a single
PII/quality identity each. In fact there are **two separate PII code paths**
and **two separate quality code paths** in this codebase today, serving two
different pipelines:

- `source/effects/pii_overlay.d` (`pii.four-class`) and
  `source/effects/pii_policy_overlay.d` (`pii.policy`) are the C01-overlay
  versions above.
- `source/stages/pii_four_class.d` is a *different* module: the CLI-wired
  v3/v4 stage-pipeline version, registering its own `TerminalSideOutput`
  keyed `pii-audit` (`piiAuditKeyV1`, `source/stages/pii_four_class.d:22,373`)
  and tracked only through `LocalManifest`'s job-scoped `SinkKey`.
- Symmetrically, `source/effects/quality_overlay.d` (`quality.features`/
  `quality.decisions`, C01-overlay) is unrelated code to
  `source/effects/quality_ratios_annotate_stage.d` (`quality-ratios-annotate`,
  manifest-scoped, described below).

Neither PII/quality pair imports the other. This is a real architectural
seam this survey did not create and does not resolve, only reports: two
independently-verified derivation-identity mechanisms already coexist for
the *same domain logic* (PII classification, quality scoring), reached
through two different pipelines.

**None of the seven C01-overlay producers above, nor their two consumer
modules, are imported from `source/cli.d`, `source/cli_commands.d`,
`source/job/presets.d`, or `source/effects/metadata_route_cli.d`** (checked
directly, not assumed). This whole family is effects-layer library code,
exercised today only by its own unittests (and now this survey's fixture),
consistent with `docs/local-manifest.md`'s and #338's framing of a
still-being-assembled, not-yet-CLI-wired corpus/batch pipeline -- not a
gap this slice introduces or is scoped to close.

### The manifest-job-scoped-only bucket, with one further real split

The stages #349's grooming note grouped together as "manifest-job-scoped-only"
are not all the same shape either, once read directly:

| Stage | Has its own `TerminalSideOutput`/manifest sink? | Citation |
| --- | --- | --- |
| `document-metadata-publish` | Yes -- `document-metadata` | `source/effects/document_metadata_publish_stage.d:20-22,27-29` |
| `pii-four-class` (stage-pipeline version) | Yes -- `pii-audit` | `source/stages/pii_four_class.d:22,373` |
| `topical-tags-extract` | Yes -- `topical-tags` | `source/effects/topical_tags_extract_stage.d:90,465` |
| `html-metadata` (#284, the older, standalone stage) | Yes -- `html-metadata` | `source/effects/html_metadata_stage.d:16,60` |
| `html-metadata-annotate` (#285, the newer, non-terminal stage) | **No** -- writes into the shared in-flight accumulator | `source/effects/html_metadata_annotate_stage.d:1-8,16` |
| `compressibility-annotate` | **No** -- `SideOutputCapability.none` | `source/effects/compressibility_annotate_stage.d:4-7,91-92,306` |
| `quality-ratios-annotate` | **No** -- `SideOutputCapability.none` | `source/effects/quality_ratios_annotate_stage.d:75-76,258` |
| `language-id-detect` | **No** -- explicitly documented as folded in | `source/effects/language_id_detect_stage.d:13-18` |

The four stages marked "No" write a named extension field directly into
`StageDocument.metadata` (`source/stages/contract.d:20-24`'s in-flight
accumulator struct) and have **no independent manifest sink of their own at
all** -- they are invisible to `LocalManifest` except insofar as their
fields ride along inside whichever later `document-metadata-publish` run
folds them into its single combined `document-metadata` `TerminalSideOutput`
(`document_metadata_publish_stage.d:1-10`: "encodes whatever
`StageDocument.metadata` a job has accumulated by the time this stage runs").
So within the manifest-scoped bucket itself there is a further split: stages
with their own queryable-by-manifest-row identity, and stages with *no*
row of their own, queryable only by decoding whatever `document-metadata`
happened to capture that run. This is a sharper distinction than "manifest-
job-scoped-only" as one bucket implies, and matters for the convergence
discussion below.

## What was built

`experiments/derivation_survey/check.d` (not part of `dub build`/`dub test`
-- `dub.json`'s `sourcePaths` is `["source"]` only; verified below, not
assumed):

1. **`buildFixture(root)`** constructs a real, multi-shard, multi-analyzer
   fixture using only the actual, unmodified upstream writers
   (`writeExactDedupOverlays`, `writeSimilarityBucketOverlays`,
   `writeNearDedupOverlays`, `DocumentShardWriter`) -- the exact same helper
   idiom (`document()`/`writeSourceShard()`) `effects.near_dedup_overlay`'s
   own unittests use (`source/effects/near_dedup_overlay.d:554-564`). No
   overlay or shard byte is hand-rolled anywhere in this file. Layout:

   | Shard | Documents | Overlays actually written |
   | --- | --- | --- |
   | `batch-1/alpha.shard` | `alpha` | exact-dedup, near-dedup, similarity-buckets (all three) |
   | `batch-1/beta.shard` | `beta` (byte-identical content to `alpha`) | all three |
   | `batch-1/theta.shard` | `theta-rep` (unique, no duplicates anywhere), `theta-dup` (byte-identical to `alpha`/`beta`) | all three |
   | `batch-2/gamma.shard` | `gamma` | exact-dedup only |
   | `batch-2/delta.shard` | `delta` | similarity-buckets + near-dedup only (exact-dedup deliberately never run) |
   | `batch-2/epsilon.shard` | `epsilon` | none at all |
   | `batch-2/zeta.shard` | `zeta` | a **real** exact-dedup overlay, copied byte-for-byte from `gamma`'s (not hand-rolled), placed at `zeta`'s naming-convention path -- its header binds `gamma`'s shard digest, not `zeta`'s: a genuine stale/misfiled overlay |

2. **`survey(root)`** is the actual read-only reporting tool: it walks the
   tree (`std.file.dirEntries(root, SpanMode.depth)`), and for every
   `<label>.shard` file, opens every sibling `<label>.<analyzer>.overlay`
   file (this experiment's own naming convention -- **production has no
   such shard-to-overlay association convention today**, which is itself
   part of the gap #349 leaves open) and reads only `OverlayReader.header`.
   It never calls `OverlayReader.next()` anywhere. A candidate overlay only
   counts as real coverage when its header's `sourceShardDigest` matches the
   shard's current `shardDigest()` -- a same-named-but-stale overlay is
   reported as missing/stale, not silently trusted.

3. A caveat-verification helper (`nearDedupRecordCountFor`), used **only**
   from `main()`'s demonstration section, deliberately *does* decode real
   `AnnotationRecord`s -- clearly separated from, and never called by,
   `survey()` -- solely to honestly verify the shard-vs-record granularity
   claim below with real counts rather than assert it away.

Reproduce:

```sh
ldc2 -i -I=source -O -release experiments/derivation_survey/check.d \
    -of=/tmp/derivation-survey-check
/tmp/derivation-survey-check
```

### Real output

```
== derivation-identity survey (header-only; issue #349) ==
shard : record key           documentId                   coverage (header-only)
alpha.shard:alpha            doc:v1:bccfc04a68b...                 exact-dedup@exact-bytes:v1  |  near-dedup@near-dedup:v1:signature=byte-shingle-minhash:v1:threshold=0.80  |  similarity-buckets@similarity-buckets:v1:signature=byte-shingle-minhash:v1:cap=4096
beta.shard:beta              doc:v1:2c68463eda0...                 exact-dedup@exact-bytes:v1  |  near-dedup@near-dedup:v1:signature=byte-shingle-minhash:v1:threshold=0.80  |  similarity-buckets@similarity-buckets:v1:signature=byte-shingle-minhash:v1:cap=4096
theta.shard:theta-dup        doc:v1:7420998fc78...                 exact-dedup@exact-bytes:v1  |  near-dedup@near-dedup:v1:signature=byte-shingle-minhash:v1:threshold=0.80  |  similarity-buckets@similarity-buckets:v1:signature=byte-shingle-minhash:v1:cap=4096
theta.shard:theta-rep        doc:v1:9b8f8eadfcc...                 exact-dedup@exact-bytes:v1  |  near-dedup@near-dedup:v1:signature=byte-shingle-minhash:v1:threshold=0.80  |  similarity-buckets@similarity-buckets:v1:signature=byte-shingle-minhash:v1:cap=4096
delta.shard:delta            doc:v1:56221441e2c...                 exact-dedup: MISSING  |  near-dedup@near-dedup:v1:signature=byte-shingle-minhash:v1:threshold=0.80  |  similarity-buckets@similarity-buckets:v1:signature=byte-shingle-minhash:v1:cap=4096
epsilon.shard:epsilon        doc:v1:714a4021726...                 exact-dedup: MISSING  |  near-dedup: MISSING  |  similarity-buckets: MISSING
gamma.shard:gamma            doc:v1:d1ed3d1e679...                 exact-dedup@exact-bytes:v1  |  near-dedup: MISSING  |  similarity-buckets: MISSING
zeta.shard:zeta              doc:v1:31760197838...                 exact-dedup: STALE (digest mismatch)  |  near-dedup: MISSING  |  similarity-buckets: MISSING

Correctness assertions: PASS (dense/sparse/absent/stale all distinguished)
Caveat check (decodes annotation records; NOT part of the header-only survey above -- done here only to verify the claim honestly): theta-rep has 0 near-dedup annotation record(s); theta-dup has 1.
Header-only coverage for theta-rep and theta-dup is IDENTICAL (same shard, same headers) even though their real near-dedup record counts differ -- confirming the shard-vs-record caveat this tool's module doc claims.

derivation-identity survey: header-only presence/absence, dense vs. sparse analyzers, and stale-digest detection all verified against a real, unmodified-upstream-writer fixture: ok
```

This is the real stdout of one run against a freshly-built temp fixture
(document IDs are truncated to 20 characters above for line width; the tool
itself prints the full canonical ID).

## What header-only actually proves, and what it does not

The output above demonstrates four distinct claims with one fixture, not
four separate hand-picked examples:

1. **Dense presence**: `alpha`/`beta`/`theta-dup` genuinely received all
   three analyzers, and the tool reports exactly that.
2. **Partial presence, correctly distinguished from total absence**: `gamma`
   (exact-dedup only) and `delta` (similarity-buckets + near-dedup, no
   exact-dedup) show two different partial patterns, and `epsilon` (zero
   overlays at all) shows the tool does not fabricate coverage when none
   exists.
3. **Stale detection, not filename matching**: `zeta` has a same-named,
   well-formed, real `exact-dedup.overlay` file on disk, and the tool
   correctly reports it as **not** present, because its header's
   `sourceShardDigest` is `gamma`'s digest, not `zeta`'s. A naming-only
   survey (no digest check) would have wrongly reported `zeta` as covered.
4. **The shard-vs-record granularity limit**: `theta-rep` and `theta-dup`
   live in the same shard and therefore get byte-identical header-only
   coverage rows. Decoding the real annotation records (done once, outside
   `survey()`, purely to check this) shows `theta-rep` has **zero** real
   near-dedup records (it is a genuine solo -- see
   `effects.near_dedup_overlay`'s own unittest comment, "solo ... never
   appear in the output at all") while `theta-dup` has one. Header-only
   inspection answers "was this shard covered by analyzer Y at version Z,"
   which is a real and useful question, but it is **not** the same claim as
   "does this specific document carry a value from Y" -- for any analyzer
   whose overlay is sparse (near-dedup and, in a different way,
   similarity-buckets both omit records for documents below their content
   thresholds), those two questions genuinely diverge, and this survey's
   fixture proves it rather than assumes it away.

Whether that distinction matters depends entirely on which of #349's real
questions an eventual index needs to answer -- "did analyzer Y run over this
corpus slice" (shard-level, header-only answers this today) versus "what did
analyzer Y conclude about this exact document" (record-level, requires
decoding). That is a scope question for @schancel, not something this
evidence slice decides.

## Convergence-path evaluation (adopt/defer guidance, not a decision)

#349 asks, without committing to it: could the manifest-tracked stages
(`document-metadata-publish`, `pii-four-class`, `topical-tags-extract`,
`html-metadata`, and the four accumulator-only stages) start writing a
parallel, lightweight "I did transform X at version Y" marker via the same
`OverlayWriter` mechanism, purely for discoverability, separate from their
actual output?

**What is mechanically true, verified against real code:**

- `OverlayWriter`'s constructor (`document_shards.d:269-280`) needs exactly
  two things: a `documentPath` that is a real, readable, regular C01
  document-shard file (it opens and digests it directly), and a destination
  path in the same trusted directory as that shard. It does not care what
  domain the annotations describe -- `pii_overlay.d`, `quality_overlay.d`,
  and the three original analyzers all reuse it unmodified for entirely
  different payloads. Mechanically, nothing in `OverlayWriter` itself
  prevents any of the manifest-tracked stages from *also* emitting a
  same-shaped, near-empty overlay (e.g. a header with zero annotation
  records, exactly like `writeNearDedupOverlays` already does for shards
  with no near-duplicates) purely as a discoverability marker.
- **But this only works at all if the manifest-tracked stage's input is
  already a C01 shard file.** That was not re-verified in this slice --
  the v3/v4 stage pipeline (`stages.contract.StageDocument`,
  `source/stages/contract.d:20-24`) operates on an in-memory
  `Document`/`Content`/`DocumentMetadata` triple per document, and this
  survey did not trace whether or how that pipeline's input corpus is
  represented as C01 shards on disk versus some other file-per-document or
  streaming representation. If it is not C01 shards today, "just add an
  `OverlayWriter` call alongside the real output" is not the small change it
  sounds like -- it would first need the stage pipeline's document source to
  be (or be adaptable to) a real, digestible, immutable shard file, which is
  a materially larger question this slice explicitly did not investigate.
- The further split found above matters here too: `document-metadata-publish`,
  `pii-four-class`, `topical-tags-extract`, and `html-metadata` each already
  have their own named identity (a `TerminalSideOutput` key) that a marker
  overlay could mirror one-to-one. The four accumulator-only stages
  (`html-metadata-annotate`, `compressibility-annotate`,
  `quality-ratios-annotate`, `language-id-detect`) have **no output of their
  own to mirror** -- their real result only exists once folded into a later
  `document-metadata-publish` run's single blob. A marker overlay for one of
  these would have to represent "this stage ran and wrote its field into the
  accumulator this job instance," which is a different, weaker claim than
  what a C01 overlay header asserts for exact-dedup/near-dedup/similarity-
  buckets today (that the referenced shard's *actual persisted output* for
  that analyzer exists at that revision) -- for these four stages, the
  overlay would attest to an intermediate step, not the durable, independently-
  readable product `document-metadata-publish` alone produces.
- The granularity mismatch cuts the other way too: C01 overlays are
  fundamentally shard-scoped (one overlay file, one header, covering
  however many documents share that shard) with the caveat demonstrated
  above, while `LocalManifest`'s `SinkKey` is fundamentally per-document
  (`DocumentId`-keyed). A marker overlay generalizing the C01 shape would
  inherit the same "present-at-the-shard-level, not necessarily meaningful-
  at-the-document-level" ambiguity this survey found for near-dedup/
  similarity-buckets, for every manifest-tracked stage it was extended to --
  it is not obviously a strictly better answer to "has document X received
  transform Y," only a differently-shaped one with its own new sharp edge.

**Verdict: genuinely plausible, not obviously right, and not this repo's
decision to make in this slice.** The C01-overlay pattern's mechanics
(header-only, digest-bound, reusable across arbitrary annotation payloads)
transfer cleanly to any stage whose input is already a C01 shard and whose
output is a durable, independently-named artifact -- that covers
`document-metadata-publish`, `pii-four-class`, `topical-tags-extract`, and
`html-metadata` plausibly, on the mechanical evidence gathered here. It
transfers much less cleanly to the four accumulator-only stages, whose real
completion is not independently observable at all today outside of
`document-metadata-publish`'s combined blob, and it does not resolve the
C01-shard-vs-document granularity ambiguity this survey's own fixture
surfaced -- it would carry that ambiguity forward, not fix it. Whether that
tradeoff is worth a new marker-overlay mechanism, versus some other design,
versus accepting the current split as permanent, is squarely
@schancel's scope decision, informed by this evidence, not concluded by it.

## What this does not resolve

- Whether the v3/v4 stage pipeline's document representation is, or could
  cheaply become, a real C01 shard file -- not investigated here, and load-
  bearing for the convergence-path question above.
- Any actual query protocol an external orchestrator would use (explicitly
  out of scope per #349's own non-goals).
- Whether a marker-overlay mechanism, if built, should live in
  `effects.document_shards` itself, a new sibling module, or somewhere else
  entirely.
- The two independent PII/quality architectural forks found while verifying
  this ticket's own inventory (`effects.pii_overlay`/`pii_policy_overlay` vs.
  `stages.pii_four_class`; `effects.quality_overlay` vs.
  `effects.quality_ratios_annotate_stage`) are reported here as evidence,
  not diagnosed or recommended for consolidation -- that is a distinct
  question from #349's derivation-identity scope.
