# Topical tags: pure annotation and controlled-vocabulary inference (v1)

**Status: first slice of issue #167.** This is a pure, repository-local seam,
not a completion of #167. It adds a bounded canonical topical-annotation
value plus a deterministic controlled-vocabulary inference API and
release-active evidence. It accepts already-extracted source observations
and canonical UTF-8 text. It does **not** parse HTML, register a pipeline
stage, expose CLI/config, or publish local/JSONL/durable output. Tags never
alter `DocumentId`, canonical text bytes, stage decisions, or extraction
provenance. `domain.topical_tags` is self-contained: nothing else in
`source/` imports it, and the ordinary shipping binary has no topical
stage/CLI/config reachability. The parent issue #167 stays open; source
extraction and shipping/publication integration are separately groomed
successor work, mutexed with or dependent on the then-integrated #180/#28
shapes.

## Files

- `source/domain/topical_tags.d` — the annotation value, canonicalization,
  `controlled-token-v1` inference, encoder/decoder, and selection.
- `experiments/topical_tags/check.d` — release-active D checker: goldens,
  decoder rejection, a privacy boundary, and a benchmark matrix.
- This document.

Rollback is deleting these three files; no existing job, source shard, or
other stored state changes, and no later job references this stage until a
separately authorized shipping landing exists.

## The annotation value

`TopicalTagsAnnotation` binds the typed `DocumentId`, the exact 32-byte
SHA-256 revision of the canonical extracted text, an exact source-evidence
digest when declared observations are present, a normalization version, and
four analyzer-configuration identities (`analyzerIdentity`, `algorithmIdentity`,
`vocabularyIdentity`, `optionsIdentity`) plus the explicit language. It keeps
`declared` and `inferred` candidate collections distinct in both the type and
the wire, per the `metadata-json:v1`-adjacent HTML evidence shape but as a
separate record — this module does not mutate `metadata-json:v1` or claim any
of its fields.

Every candidate retains a normalized display value, a canonical key, explicit
hierarchy segments (an ordered, caller-supplied, maximum-eight-segment path —
a flat string never invents hierarchy), an origin enum, and bounded
provenance:

- **Declared evidence** (`DeclaredEvidence`): a finite source-rule ID,
  extractor/version ID, and source node/ordinal. No algorithm confidence, no
  source path/locator, no raw source, no arbitrary diagnostic text.
- **Inferred evidence** (`InferredEvidence`): the algorithm/vocabulary
  identities, an integer evidence score and its exact documented meaning (the
  count of distinct configured terms observed for that topic), the total
  configured terms, the threshold/minimum-match options applied, and up to 16
  stored matched term IDs plus original canonical-text byte ranges. No
  snippet or hash of matched text is ever stored.

Case/whitespace-equivalent keys are marked `duplicateKey`, but every distinct
declared observation remains present in order — there is no silent
author-tag collapse or last-wins rule. Output ordering is the input order for
declared candidates and vocabulary order for inferred candidates; this is
separate from duplicate-key marking.

### Canonicalization

UTF-8 validation, Unicode NFC, and Unicode-whitespace collapse/edge-trim for
display text; for canonical keys, this toolchain's available Unicode
lowercase mapping is used as the approximation of full case fold (Phobos
exposes no separate case-fold table on this LDC/Phobos version — see the
`canonicalKeyOf` doc comment). There is no stemming, transliteration, accent
stripping, locale guessing, or English synonym expansion. Separators are
literal.

### Bounds (v1 identity; checked before copying)

Canonical text ≤ 1 MiB; ≤ 64 declared and ≤ 32 inferred candidates;
display/key ≤ 256 UTF-8 bytes; hierarchy depth ≤ 8; source rule/extractor/
algorithm/vocabulary/term IDs ≤ 128 bytes each; ≤ 64 vocabulary topics, ≤ 16
terms per topic, ≤ 4 tokens per term, ≤ 16 stored matches per candidate;
canonical annotation ≤ the existing 64 KiB C01 annotation ceiling. Malformed
caller evidence is rejected with fixed, content-free diagnostics (never
interpolating caller content into an exception message).

## `controlled-token-v1`: the only first-slice inference

Caller-supplied, canonically encoded vocabulary entries (`Vocabulary.build`)
are bounded and duplicate-free by construction. A term is an ordered sequence
of 1–4 whole canonical Unicode letter/number tokens; terms are matched as
whole tokens against one canonical-text document — a plural or an adjoining
prefix/suffix (`"recipes"`, `"ovenware"`) is a different token and does not
match. The analyzer supports only an explicitly supplied `en` language;
missing, `und`, or any other language abstains rather than guessing. A
topic's per-candidate evidence score is the documented integer count of
distinct configured terms observed (repeat occurrences of one term count once);
a topic is selected when that count meets both an inclusive threshold
fraction (`thresholdPerMille`, 0–1000) and a minimum absolute match count
(`minimumMatches`) — both participate in `optionsIdentity`. There is no
free-tag generation, embedding/model inference, network access, implicit
model/vocabulary download, or runtime plugin.

Finite typed abstention (`InferenceAbstention`): `emptyCanonicalText`,
`invalidCanonicalText`, `oversizeCanonicalText`, `unsupportedLanguage`,
`noMatch`. Finite typed warning (`InferenceWarning`): `candidateOverflow`,
which truncates matched topics deterministically at the 32-candidate cap
(first-matched-in-vocabulary-order kept) rather than throwing, because
overflow is a runtime outcome of matching a caller's vocabulary/threshold
combination, not caller-input validation. Inference uncertainty never
fabricates a candidate.

## Selection is external and inert by default

`select(annotation, SelectionPolicy)` is a separate pure read. `none`
(the default a caller must still choose) selects nothing; `sourceOnly` and
`inferredOnly` select one collection; `union_` selects both while retaining
origin/evidence on every reference — it never rewrites inferred data as
declared/author metadata. No policy is applied implicitly by constructing an
annotation.

## Encode/decode and identity binding

`encodeTopicalTags`/`decodeTopicalTags` are the canonical wire. `decodeTopicalTags`
binds to a caller-supplied `expectedId`/`expectedTextRevision` obtained
independently (e.g. a future C01 join), so a record cannot silently attach to
another document or revision. `analyzerIdentity` is a stored umbrella digest
recomputed from `algorithmIdentity`/`vocabularyIdentity`/`optionsIdentity`/
`language`/`normalizationVersion`, so corrupting any one of those four
identities is caught without the decoder needing the raw vocabulary or
options back. `evidenceDigest` is recomputed from the decoded `declared`
collection. Beyond those semantic checks, the wire carries a final 32-byte
SHA-256 checksum over every preceding byte, so **any** single-byte
corruption anywhere in the record — including inferred score/threshold/
range/term bytes that no narrower identity field covers — is rejected.
Truncation and trailing data are both rejected. `annotationDigest(bytes)` is
the deterministic identity of one exact encoded annotation, for a later
durable sink's idempotent-skip/retry bookkeeping outside this slice.

Revision/config/vocabulary/analyzer drift all fail closed.

## Proof (release-active checker)

`experiments/topical_tags/check.d`:

- **Declared/source-observation fidelity** — exact canonicalization,
  ordering, duplicate marking, hierarchy, and multilingual display, pinned by
  SHA-256 `9e793f57f392024d016d0d86c3c098672d9e8874c8c7f845427f1647f7191489`
  over an authored fixture covering HTML-style category/keyword evidence
  (the shape a caller would map from `effects.html_metadata`'s `rule`/`node`
  candidates, without this module parsing HTML), conflicting spellings,
  exact duplicates, and hierarchy. This is exact-reproduction evidence, not a
  statistical score.
- **Maliciously large fields** — every cap rejected at `+1` and accepted at
  exactly the cap, for declared fields, hierarchy depth, IDs, declared
  candidate count, vocabulary topic/term counts, and malformed (punctuation)
  vocabulary tokens.
- **`controlled-token-v1` goldens** — supported English matches, multi-token
  spans, overlap/repeated terms (counted once, first occurrence stored),
  false-positive controls (plural/adjoining forms must not match), missing/
  `und`/other-language abstention, no-match abstention, empty/oversize/
  invalid-text abstention, and deterministic candidate-overflow truncation.
- **Held-out precision/recall** — a small authored split distinct from the
  goldens above, with expected topics or explicit negatives, reporting exact
  precision/recall/abstention counts. This is small authored boundary
  evidence only — no live-web, universal-topic, author-intent,
  semantic-understanding, multilingual-quality, model-parity, or ontology
  claim.
- **Identity and decoder rejection** — round trip, wrong document/revision,
  truncation, trailing data, every single byte of one fixture's encoded
  record corrupted and confirmed rejected, and wrong analyzer/algorithm/
  vocabulary/options identity via the umbrella-recompute path, pinned by
  SHA-256 `fbcc16557664484252452657435ab0c0777ac95ae5bfb3e9d6893567e6bde2a0`.
- **Privacy boundary** — synthetic canaries placed in canonical text and in a
  source-locator-like string, both away from any vocabulary term, are
  confirmed absent from the encoded annotation bytes; an oversize declared
  field containing a canary is rejected with the fixed diagnostic only (no
  content leak); an intentionally supplied within-cap declared display value
  is confirmed present (a positive control showing the leak scan is not
  vacuous); inferred evidence is confirmed to carry only IDs/ranges, never
  the matched text.
- **Benchmark matrix** — a D-only child-process matrix over `many-small`
  (64 documents) and `few-large` (4 documents) shapes at the same total
  512 KiB of authored canonical text, crossed with `disabled`,
  `declared-only` (unsupported-language inference path), and `inference`
  modes. Each mode/shape pair runs twice as a separate child process; an
  exact digest line must match byte-for-byte across the two runs (the
  exact-output/digest gate) before the parent reports parent-observed wall
  time, `RUSAGE_CHILDREN` user+system CPU and peak RSS, and the child's own
  wall time, GC-allocated bytes, and post-collection GC-used bytes, plus
  total encoded annotation bytes where applicable. This is descriptive
  bounded-cost evidence, not a speed advantage claim; unsupported metrics
  (e.g. syscall counts) are not reported.

Run:

```sh
ldc2 -O3 -release -Isource -Iexperiments -of=.dub/topical-tags-check \
  experiments/topical_tags/check.d source/domain/topical_tags.d \
  source/domain/document.d source/crypto/sha256.d source/crypto/sha256_arm64.d \
  source/crypto/sha256_x86_64.d
.dub/topical-tags-check
```

The domain module's own `unittest` blocks (`ldc2 -unittest -Isource -main -of=... \
source/domain/topical_tags.d source/domain/document.d source/crypto/sha256.d \
source/crypto/sha256_arm64.d source/crypto/sha256_x86_64.d`) exercise the same
canonicalization, inference, and encode/decode/corruption paths as fast
in-process regression coverage; the release-active checker above is the
pinned, release/O3-built proof with the benchmark matrix and privacy scan.

## What this is not

Not an ontology, ranking, quality score, or author-intent signal. Not a
statement about web-scale precision/recall — the held-out split above is a
handful of authored sentences. Not HTML parsing, a pipeline stage, CLI/config
surface, or any local/JSONL/durable publication path; those are explicitly
out of scope for this slice and belong to a separately groomed successor
that must re-groom against the integrated #180 generic side-output shape.
