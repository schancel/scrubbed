# Corpus-level stages: a two-phase composition model (issue #564)

A per-document stage (`stages.contract.Stage`, `stages.registry
.StageRegistry`) sees exactly one document at a time, synchronously, with no
visibility into any other document. That shape is structurally wrong for a
corpus-wide decision such as near-duplicate pruning: grouping documents into
similarity buckets is inherently a batch, external-memory operation over the
whole corpus, and `source/cli.d`'s per-document publication is immediate and
ordinal -- a document's primary output is durably written before the next
document's decision is even made under concurrency. A corpus-level decision
needs to see multiple already-decided documents before it can decide any one
of them, so by construction it cannot run *between* two per-document stages
in the same streaming pass; it can only run as a **subsequent pass over
already-published output**.

This is the second, disjoint execution primitive that gives a corpus-level
stage a real, structural place in `run`'s composition model, alongside the
unchanged per-document `Stage` contract.

## Two strict phases, never interleaved

- **Phase 1 (unchanged).** Every per-document `--stage` in a composition
  runs exactly as it always has, via `stages.contract.runStage` /
  `composition.job_executor.runCompiledJob`, streaming one document at a
  time to durable output. The compiled stage list remains unchanged; its
  runtime identity is rebound to the canonical identity of the full
  two-phase composition so corpus-stage options participate in execution
  identity.
- **Phase 2 (new).** Once phase 1 has fully drained (every admitted file
  parsed, decided, and published), each corpus-level `--stage` runs once,
  in declared order, over the just-completed corpus.

A composition's `--stage id=impl` tokens name both kinds of stage through
the exact same syntax; which half a token belongs to is determined
structurally, by which registry recognizes its `implementation` key --
`stages.registry.StageRegistry` for a per-document stage, or the new
`stages.corpus_contract.CorpusStageRegistry` for a corpus-level one. The two
registries are disjoint: an implementation key present in both is a
compile-time error, never a silent preference for one over the other.

`composition.corpus_compiler.compileComposition` is the compiler that
enforces this. It partitions a composition's stages by registry membership
and **structurally requires every per-document stage to precede every
corpus-level stage** -- a per-document stage token that appears anywhere
after the first corpus-level stage token is rejected at compile time, with
an error naming both stages and the violated ordering rule. This is the
same kind of check `stages.registry.StageRegistry.validateOrder` already
does for a single stage's own named before/after ordering constraints,
extended to a whole-class constraint instead of a pairwise one.

```
run --stage clean=html-main-content \
    --stage sig=similarity-signature-annotate \
    --stage publish=document-metadata-publish \
    --stage prune=prune-near-duplicates
```

The result of compilation is `composition.corpus_compiler.CompiledComposition`,
a new top-level type wrapping both halves: `perDocument` (a `CompiledJob`,
compiled by the completely unchanged `compileJob`) and `corpusStages`
(`CompiledCorpusStage[]`, new, ordered). `source/cli.d`'s `runApp` runs
phase 1 exactly as it does today over `perDocument`, and only after that
streaming loop has returned with `failures == 0`, runs each compiled corpus
stage once, in order, over the directory `--sidecar-output` populated
during phase 1.

When both phases are nonempty, the composition must include
`document-metadata-publish` in phase 1. This is checked before filesystem
work begins; without it, phase 2 could otherwise consume stale or absent
metadata while the command appeared to succeed.

A composition that declares zero corpus-level stages -- every composition
that existed before this capability -- produces a `CompiledComposition`
whose `perDocument` is byte-for-byte what `compileJob` alone would have
produced, and whose `corpusStages` is empty; `runApp`'s new phase-2 branch
is then a no-op. This is genuinely additive, not a rework.

## The corpus-level contract

`stages.corpus_contract` declares the shape (pure types and a registry; no
I/O), mirroring `stages.contract`/`stages.registry`'s own split:

- `CorpusStageDeclaration { string key; }` -- a corpus stage's identity.
  Unlike the per-document `StageDeclaration`, there is no `PassMode` (a
  corpus stage is single-pass only in this slice -- see "Explicitly
  deferred" below) and no `ResourceDeclaration` (a corpus stage's own
  bounded-memory ceiling, e.g. a bucket cap, is a stage-specific typed
  option resolved by its own factory, not a generic cross-stage resource
  descriptor).
- `CorpusStageDecision { documentId, kind, representativeId, bucketIdentity,
  reason }` -- one decision for one document. `kind` is `keep` or `prune`;
  `prune` replaces per-document `reject`, because by the time a corpus-level
  stage decides a document, that document already has real, previously
  published output -- this is a removal/audit verdict over already-published
  state, not a pre-publication gate.
- `CorpusStageRun = void delegate(string sidecarRoot, scope CorpusStageSink
  sink)` -- the actual execution contract: a bounded, external-memory batch
  pass over the already-published sidecar tree at `sidecarRoot`, reporting
  each decision through `sink` as it is made. Implementations must hold at
  most their own declared, stage-specific bound (e.g. a bucket cap) of
  candidate rows in memory at any one time -- never a structure sized by
  corpus document count.
- `CorpusStageRegistry`/`registerCorpusStage`/`availableCorpusStages` mirror
  `StageRegistry`/`registerStage`/`availableStages` exactly, including
  typed, declared options resolved via the same `--stage-option KEY=TYPE:
  VALUE` syntax every other stage already uses (e.g. `--stage-option
  bucket-cap=integer:8192`) -- no new CLI flag syntax for a corpus stage's
  own configuration.

A corpus-level stage's decision function must be a **pure, order-invariant
function of its candidate set** -- the same discipline
`domain.near_dedup_decision.nearDuplicateLinksInBucket` already follows, and
its own "chain" unittest already proves. This is a stated design constraint
for any future corpus-level stage, not just this slice's one consumer: a
hypothetical future policy that depended on "whichever document the
scheduler happened to process first" would silently reintroduce
nondeterminism the per-document model doesn't have today. Any new
corpus-level stage's own test suite should include an order-permutation
proof, not just a single-ordering pass/fail test -- see
`effects.corpus_runner`'s own order-invariance unittest for the worked
example this slice ships.

## The first consumer: `prune-near-duplicates`

Two pieces implement issue #480's near-duplicate pruning capability as a
real, `run`-reachable corpus-level stage, per this issue's approved Option C
design.

### 1. `similarity-signature-annotate` (per-document, phase 1)

`source/effects/similarity_signature_annotate_stage.d`. Mirrors
`effects.language_id_detect_stage`'s shape almost line-for-line: calls the
existing, unmodified `domain.similarity_signature.similaritySignatures` on
each document's content (document-level only, never `.segments` -- see
"Explicitly deferred" below) and writes the result into
`StageDocument.metadata` via `DocumentMetadata.withStructuredSection`, using
section id `similarity-signature-v1` -- **not** `withExtensionField`. A
64-lane MinHash array alone is 512 bytes, exactly
`domain.document_metadata.maxExtensionValueBytes`'s scalar cap, with zero
room left for `hasKeys`, a content length, or bands; the structured-section
mechanism's 2 MiB cap is the same one `stages.pii_four_class` already
converged onto for its own large per-document payload (see
`docs/document-metadata.md`). `document-metadata-publish` needs **zero**
changes: it already picks the `document-metadata:v2` wire automatically
whenever a structured section is present.

The published payload carries the canonical lanes, `hasKeys`, content length,
and frozen algorithm-version tag. Band hashes are derived from groups of four
lanes, so phase 2 recomputes them with its version-local adapter instead of
persisting a second authority. A compatibility test pins that adapter against
the canonical domain output for real signatures; a future algorithm version
must update both sides explicitly.

### 2. `prune-near-duplicates` (corpus-level, phase 2)

`source/effects/corpus_runner.d`. Walks the completed `--sidecar-output`
tree for `*.document-metadata.json` sidecars, recovers each document's
`DocumentId` from its own wire text (`DocumentId.fromCanonicalText`,
precedented in `effects.near_dedup_overlay.d`), decodes its
`similarity-signature-v1` structured section, and replicates
`effects.similarity_buckets.d`'s external-sort/bucket-cap **algorithm
shape** -- bounded batches, disk-spilled sorted runs, a bounded fan-in
merge, then a single sequential scan that groups consecutive equal
`(bandIndex, bandKeyValue)` records and caps each group at the declared
bucket cap -- against this sidecar-sourced candidate stream. That module's
own API is shard-typed and is left **completely untouched**; only its shape
is mirrored. Corpus-sized document paths, cross-bucket links, and final
decision ordering live in a private, bounded-cache SQLite scratch database;
sorted runs are compacted incrementally with fixed merge fan-in, so neither
heap memory, open descriptors, nor simultaneously live run files scale
linearly with corpus size. The tree walk queues relative directories in that
scratch database and opens only one shallow iterator at a time, keeping
directory descriptors bounded independently of tree depth. Scratch state is
created atomically with owner-only permissions.

`domain.near_dedup_decision.nearDuplicateLinksInBucket` -- the pure decision
core -- is called **completely unmodified**, once per bucket, exactly as
`effects.near_dedup_overlay.d`'s own Phase B already does. Because one
document's signature explodes into up to `similarityBands` (16) independent
band rows, it can land in more than one bucket at once, with each bucket
possibly naming a different representative for it; cross-bucket conflicts
are resolved the same way `near_dedup_overlay.d`'s own private Phase C does
(reproduced independently here, since that logic is private to a module
this slice must not modify): the lexicographically smallest representative
wins across every bucket that named one for a document, then every entry is
resolved to its true, never-itself-a-key root.

**Mandatory decision sidecar.** For every pruned document, a
`<name>.prune-near-duplicates-decision.json` file is written next to that
document's own `.document-metadata.json`, naming the removed document's ID,
its surviving representative's ID, and the matching `(bandIndex,
bandKeyValue)` bucket identity. This is unconditional -- there is no flag
that disables it.

**Non-destructive toward corpus output.** This driver never touches
`--output` or an existing document-metadata sidecar. Decision sidecars are
derived state: current decisions are atomically replaced and stale decisions
from an earlier successful pass are removed, so the directory cannot retain
a prune verdict for a document that the current pass keeps. A follow-on
opt-in step that materializes a physically pruned corpus at a distinct
destination remains deliberately out of scope.

Decision publication and stale removal are anchored to one descriptor for
the verified sidecar root. Every parent component is reopened relative to
that descriptor with symlink following disabled, and replacement/removal is
performed relative to the resulting parent descriptor. A concurrent parent
swap therefore fails closed instead of redirecting a write outside the
corpus root.

### CLI reachability

`--stage prune=prune-near-duplicates` is invokable through the exact same
`run --stage` syntax as every other stage. It requires `--sidecar-output`
(it reads already-published sidecars, independent of whether the
per-document half of the same composition itself produces a terminal side
output) and directory input (a single file has no corpus to compare
against); both are checked and rejected with a clear error before any work
begins. It is not currently supported together with `--manifest`/
`--error-journal` (durable routes) or a dispatch v4 composition -- both
interactions are unaudited for this slice, not merely untested, so they
fail closed rather than silently proceed.

A corpus-only composition may replay an existing sidecar tree produced by
an earlier run. A combined phase-1/phase-2 composition requires a fresh
sidecar root, preventing stale metadata from a prior input generation from
joining the current corpus. Because decision sidecars are mandatory output,
corpus stages reject `--dry-run` before traversal or mutation.

## Explicitly deferred (real follow-on decisions, not this slice)

- **Segment-level signature persistence.** `effects.near_dedup_overlay.d`'s
  own pruning decision already only ever consults document-level
  candidates for eligibility; segment-level richness is a separately-gated
  future capability (issue #492), unrelated to pruning.
- **A genuinely resumable/restartable corpus-level stage** (checkpointing
  mid-bucket-scan). `CorpusStageRun` is single-pass only in this slice,
  matching `PassMode.singlePass`'s existing per-document precedent.
- **Any corpus-level stage other than near-dup pruning.** This slice proves
  the mechanism with exactly one consumer.
- **A physically-pruned copy of the corpus at a distinct destination**
  (mirroring `prunedDestination`). Decision-only for now; see above.
- **Dispatch v4 / `--manifest` / `--error-journal` interaction.** Explicitly
  out of scope and rejected with a clear error, not silently allowed.
- **Extracting a shared, general-purpose external-sort/run-merge utility**
  out of what are now three independent near-duplicate-adjacent
  implementations (`effects.similarity_buckets`, `effects.near_dedup_overlay`,
  and this capability's own `effects.corpus_runner`). A real cleanup
  opportunity, not this slice's job to take on unprompted.
