# Topical tags: pure annotation and controlled-vocabulary inference (v1)

**Status: two landed slices of issue #167, neither a completion of it.**

- **First slice** — `domain.topical_tags`: a pure, repository-local value
  type plus a deterministic controlled-vocabulary inference API and
  release-active evidence. It accepts already-extracted source observations
  and canonical UTF-8 text; it does not parse HTML itself, and does not
  publish local/JSONL/durable output on its own. Tags never alter
  `DocumentId`, canonical text bytes, stage decisions, or extraction
  provenance.
- **Next slice** — `topical-tags-extract` (see below): a real,
  self-registering, terminal v3 stage that parses a document's HTML,
  extracts declared candidates, and calls into `domain.topical_tags` to
  build and publish the annotation. This gives the ordinary shipping binary
  real reachability today, via `run --stage id=topical-tags-extract` — the
  same generic stage-composition mechanism every other stage uses. As of
  this slice, `domain.topical_tags` is no longer import-free: this stage is
  its one caller in `source/`.

Controlled-vocabulary inference is not wired into the shipped stage (see
"Reused, frozen `buildAnnotation`, deliberately inert" below) — the stage is
declared-extraction only. The parent issue #167 stays open for that and for
further shipping/publication integration, separately groomed and mutexed
with or dependent on the then-integrated #180/#28 shapes.

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

## What `domain.topical_tags` itself is not

Not an ontology, ranking, quality score, or author-intent signal. Not a
statement about web-scale precision/recall — the held-out split above is a
handful of authored sentences. The value type itself does not parse HTML or
publish output; `topical-tags-extract`, documented next, is the stage that
does both. Controlled-vocabulary inference and a durable/local/JSONL
publication path beyond the one terminal side output below remain
explicitly out of scope, dependent on the integrated #180 generic
side-output shape.

## `topical-tags-extract`: declared-extraction stage (next-slice, additive)

**Status: next-slice of issue #167**, accepted per the "Strong Tier-3
next-slice solution contract" recorded on the issue. This wires the frozen
declared-candidate shape above into a real, self-registering, TERMINAL v3
stage, `source/effects/topical_tags_extract_stage.d` (stage key
`topical-tags-extract`), matching `stages.pii_four_class`'s single-shot
terminal shape rather than the two-phase `html-metadata-annotate` +
`html-main-content` shape. It is **declared-extraction only**: no
controlled-vocabulary inference is wired in this slice, and nothing above
this section changes except the one additive schema bump below.

### Extraction sources

The stage parses a document's HTML exactly once (`effects.html_tree.parseHtml`)
and extracts declared candidates from three sources, all feeding the
unmodified `canonicalizeDeclared`:

1. **`<meta name="keywords" content="...">`** (head-scoped). `content` is
   split on `,`/`;`; each nonempty, normalized piece becomes one
   `DeclaredObservation` with `sourceRuleId = "meta.keywords"`.
2. **The `rel="tag"` microformat**: `<a rel="tag">` (anchor text is the
   display candidate) and `<link rel="tag">` (no text: falls back to a
   display candidate derived from the `href`'s last path segment, with
   `-`/`_` loosened to spaces). Both use
   `sourceRuleId = "microformat.rel-tag"`. Visible category/tag navigation
   *without* an explicit `rel="tag"` attribute is not extracted: no bounded,
   deterministic detection rule exists for that.
3. **JSON-LD `<script type="application/ld+json">` schema.org `Article`**:
   scoped narrowly to `@type` exactly `"Article"` (string or array
   containing it), never `NewsArticle`/`BlogPosting`/etc. Reads `keywords`
   (string, comma/semicolon-split, or a JSON array of strings;
   `sourceRuleId = "ldjson.article.keywords"`) and `about` (array of JSON
   string or `Thing` object with `name`; `sourceRuleId =
   "ldjson.article.about"`). Parsed with `std.json.parseJSON` +
   `JSONOptions.strictParsing` and an explicit depth cap of 32, bounded to
   128 KiB of aggregate ld+json bytes scanned per document.

`extractorId = "topical-tags-extract:v1"` uniformly. The stage caps its own
extraction at 64 candidates (`maxDeclaredCandidates`) before calling
`canonicalizeDeclared`, truncating extras in document order, rather than
letting `canonicalizeDeclared`'s own cap `enforce` throw over a routine
"too many meta keywords" case.

### Content-support signal: `DeclaredEvidence` schema 1 → 2

Raw `<meta name="keywords">` extraction surfaces SEO spam — keyword-stuffed
tags that are never actually about the page. Because this stage is terminal
and self-parsing (it can never be sandwiched between `html-metadata-annotate`
and `html-main-content` in one job; see below), the only text available to
check a candidate against is the whole page's own visible text, concatenated
from every `HtmlNodeKind.text` node in the parsed tree (nav/boilerplate
included, head and body alike). This is named `pageTextSupport` rather than
"canonical-text support" to avoid conflating it with the narrower
main-content-only text this document's own "encode/decode" section refers to.

This is the one owner-approved additive touch to `source/domain/topical_tags.d`
since the first slice: `topicalTagsSchema` bumps 1 → 2, and `DeclaredEvidence`
gains two additive fields:

- `DeclaredContentSupport support` — a tri-state enum: `unchecked` (no page
  text was ever checked — the zero-value default `canonicalizeDeclared`
  itself produces, since it has no page text; kept because that function is
  a public API any future non-HTML caller could use without page text
  available), `unsupported` (checked, not found), `supported` (checked,
  found at least once).
- `uint contentMatchCount` — a bounded, plain raw occurrence count of the
  candidate's canonical token sequence in the checked text (adjacent-token
  matching, not a substring search), always `0` unless `support ==
  supported`. This is deliberately **not** a BM25/TF-IDF/relevance score:
  both would need a corpus-relative term-rarity signal this codebase has no
  shipped, provenance-clean source for.

Both fields thread additively through `checkTopicalTags` (internal
consistency between `support`/`contentMatchCount`, plus the bounded-count
cap), `encodeTopicalTags`, and `decodeTopicalTags`. They are deliberately
**excluded** from `evidenceDigest`'s input bytes: that digest binds the
source-declared observation identity (rule/extractor/node plus the
canonicalized display/key/hierarchy), which is fully known at
`canonicalizeDeclared` time — before any later content-support check can
run. This is what lets the stage call the frozen, unmodified `buildAnnotation`
exactly as documented and then attach `support`/`contentMatchCount` to its
own copy of the resulting candidates afterward, without invalidating
`evidenceDigest`. Nothing durably publishes the schema-1 wire anywhere in
this repository, so this bump has zero migration cost.

### Reused, frozen `buildAnnotation`, deliberately inert

`buildAnnotation` is `domain.topical_tags`'s only construction entry point,
and it unconditionally also runs `controlled-token-v1` inference. Since this
slice defers inferred-tag wiring, the stage calls it with a fixed, inert
placeholder `Vocabulary` (one topic, required only because `Vocabulary.build`
rejects zero topics) and `language = "und"`, which deterministically abstains
inference via `InferenceAbstention.unsupportedLanguage` before the vocabulary
is ever consulted (the language gate precedes vocabulary iteration in
`inferControlledTokenV1`) whenever the page text is itself nonempty,
appropriately sized, and valid UTF-8; otherwise one of the other typed
abstentions applies instead. Controlled-vocabulary/inferred-tag stage wiring
is out of scope here and left to its own future contract.

### Architecture: why this is one terminal stage, not two phases

The rich `TopicalTagsAnnotation` payload cannot travel through
`StageDocument.metadata` (the `html-metadata-annotate` →
`document-metadata-publish` two-phase shape used elsewhere): that path's
extension-field cap is 512 bytes, and this annotation's own identity/digest
overhead alone is already close to that before any candidate. Separately,
`composition.compiler`'s `compileJob` admits at most one
`SideOutputCapability.terminal`-producing stage per compiled job, which must
be last. So `topical-tags-extract` is single, self-contained, and terminal —
parsing its own full HTML independent of any prior stage's transform, the
same shape as `stages.pii_four_class`. Being terminal, it can only ever be
the pipeline's last stage, so "must run before html-main-content" holds by
construction.

**Inherited, not resolved:** a single job cannot currently produce both
topical-tags output and PII-audit/document-metadata output at once — the
same limitation `pii-four-class` vs. `document-metadata-publish` already has
today. This is the "multiple optional terminal annotations coexist" gap the
first slice above already named and deferred to a future generic multi-sink
redesign; this stage inherits, not resolves, that gap.

A `SideOutputCapability.terminal` registration also means
`composition.executor.validateCapabilities` requires *every* event —
quarantined ones included — to carry exactly one `TerminalSideOutput`. On
quarantine, the stage attaches a placeholder side output with an empty
payload (never read once a caller branches on quarantine), mirroring
`effects.html_metadata_stage`'s own `quarantinedMetadataSideOutput` idiom for
the same, already-precedented reason.

### Abstention/quarantine behavior

- HTML parse failure or raw-bytes-over-limit → quarantine, the same
  reason-mapping idiom as `html-metadata-annotate`/`html-main-content`.
- No declared candidates found across all three sources is **not** an
  error: the stage emits a well-formed annotation with `declared.length ==
  0` and `identity.hasEvidence == false`.
- A single malformed evidence item (unparseable JSON in one ld+json block, a
  non-string/non-object `about` entry, a candidate failing canonicalization
  or its size bound, an oversize ld+json block beyond the 128 KiB aggregate
  cap) is skipped; the rest of the document's evidence is still extracted.
  The whole document is never quarantined over one bad source.
- A genuine internal-invariant failure in the stage's own mapping code
  defensively quarantines with the fixed, content-free reason
  `annotationBuildFailure`, mirroring `html-main-content`'s
  `catch (HtmlMainContentOutputLimit)` pattern.

### Files added in this slice

- `source/effects/topical_tags_extract_stage.d` — the stage, its local
  meta-keyword/rel-tag/JSON-LD extraction code, and co-located unit tests
  covering each evidence source alone and combined, cross-source duplicate
  marking, conflicting casing, malformed/oversize/wrong-type JSON-LD,
  absent evidence, SEO-spam and genuine content-support cases, the
  rel-tag-empty-text slug fallback, deterministic re-run byte-identical
  output, and the 64-candidate cap.
- The one additive edit to `source/domain/topical_tags.d` described above.
- This section.
