# Quality-ratios annotation (issue #347)

**Status: opt-in v3 stage, `quality-ratios-annotate`.** Not wired into any
default chain -- a caller must name it explicitly in a job's `stages` list.
It never makes a keep/reject/quarantine decision and never feeds the
separate, pre-existing `quality_features`/`quality_overlay` gate
(`docs/quality-annotations.md`, an unrelated, already-shipped C01 overlay
system -- see "Relationship to `docs/quality-annotations.md`" below for why
this is a sibling document rather than an addition to that one).

## What this is, and what it is not

This stage measures six independent, named, versioned Gopher/C4-style
deterministic heuristic ratios over a document's raw content bytes, and
writes them into one compact `quality-ratios` extension field via #285's
`StageDocument.metadata` API, to be published later by the existing,
unmodified `document-metadata-publish` terminal stage:

1. **Word count** -- whitespace-delimited (`std.uni.isWhite` run
   boundaries).
2. **Mean word length** -- mean Unicode-codepoint length across those words.
3. **Symbol-to-word ratios** -- two separate named sub-fields, never merged:
   hash (`#`) count / word count, and non-overlapping `"..."` count / word
   count.
4. **Alphabetic-word fraction** -- fraction of words containing at least one
   `std.uni.isAlpha` codepoint.
5. **Stop-word presence** -- count (0-8) of a fixed 8-word list present at
   least once (presence, not frequency).
6. **Multi-scale repetition fractions** -- duplicate-line fraction and
   character fraction, duplicate-paragraph fraction and character fraction,
   top-n-gram character fraction (n=2,3,4), duplicate-n-gram character
   fraction (n=5..10).

This is issue #347's direct sibling of #168's `compressibility-annotate`
(`docs/compressibility-annotate.md`), same shape exactly: opt-in,
non-terminal, one extension field, `max-input-bytes`-style resource bound,
"feature-vector-not-opaque-score" philosophy. **No threshold, pass/fail, or
accept/reject decision logic exists anywhere in this stage or its pure
computation module** (`domain.quality_ratios`) -- every value below is a raw
number, never gated or combined into a score. The only quarantine this
stage ever raises is `rawLimit` (the `max-input-bytes` resource bound) or
`annotationBuildFailure` (a genuine internal-invariant failure, e.g. the
extension-field capacity already exhausted by a prior stage) -- never a
"feature could not be computed" case.

## Sourcing: verified vs. approximated

Issue #347's accepted contract required verifying the stop-word list and
repetition formulas against a real, citable, independently-sourced secondary
reference before hard-coding them, rather than trusting memory. Both were
found and verified during this slice's implementation:

- **Stop-word list**: fetched and read directly from HuggingFace
  `datatrove`'s `GopherQualityFilter`
  (`src/datatrove/pipeline/filters/gopher_quality_filter.py`,
  https://github.com/huggingface/datatrove), a real, open-source, checkable
  reference implementation of Rae et al. 2021, "Scaling Language Models:
  Methods, Analysis & Insights from Training Gopher" (DeepMind,
  arXiv:2112.11446), Appendix A.1. Its exact literal source:
  `STOP_WORDS = ["the", "be", "to", "of", "and", "that", "have", "with"]`.
  `domain.quality_ratios.stopWordListV1` is that exact 8-word list,
  unmodified. `datatrove`'s own filter checks presence case-sensitively
  against this lowercase-only list (a capitalized sentence-initial "The"
  does not count); this stage matches that exactly.
- **Repetition formulas**: fetched and read directly from `datatrove`'s
  `GopherRepetitionFilter`
  (`src/datatrove/pipeline/filters/gopher_repetition_filter.py`) and its
  module-level `find_duplicates`/`find_top_duplicate`/`find_all_duplicate`/
  `get_n_grams` helper functions. That file's own header comment cites its
  source directly: "Table A1 from https://arxiv.org/pdf/2112.11446.pdf".
  `domain.quality_ratios`'s `findDuplicates`, `topNGramCharCount`, and
  `duplicateNGramCharCount` reproduce those four functions' exact
  algorithms: duplicate-element/duplicate-character counting via a seen-set
  (first occurrence of a repeated value is never itself counted); the "top"
  n-gram found via frequency counting over overlapping, space-joined,
  slide-by-1 n-grams (ties broken by first occurrence); the "duplicate"
  n-gram found via a concatenated (no separator), skip-ahead-on-match
  sliding window. Line splitting uses `\n+` run boundaries and paragraph
  splitting uses `\n{2,}` run boundaries over already-`strip()`-ed text,
  both matching `datatrove`'s own regexes exactly, including their edge
  behavior (e.g. `re.split(r"\n+", "")` == `[""]`, so line/paragraph
  duplicate *fraction* denominators are never zero -- see "Abstention"
  below).

**Deliberate, disclosed deviations from the verified `datatrove` reference**
(#347's own contract fixes the feature list, not bit-for-bit `datatrove`
parity -- every deviation below is intentional, not an unverified
reconstruction):

1. **Word tokenization is whitespace-only**, per #347's own contract text
   ("whitespace-delimited word count"), not `datatrove`'s language-aware
   `split_into_words` (which also separately strips attached punctuation for
   word-count/mean-length purposes via its own `PUNCTUATION_SET`-based
   `non_symbol_words` filter). A word like `"dog."` is one word including
   its trailing period in this stage, not `"dog"`.
2. **Stop-word matching strips leading/trailing ASCII punctuation**
   (`std.ascii.isPunctuation`) from each whitespace-delimited word before
   matching. `datatrove`'s own tokenizer already yields punctuation-free
   tokens, so it needs no such trimming; this stage's simpler
   whitespace-only tokenizer does, or ordinary prose punctuation ("with,",
   "and.") would almost never match, defeating the feature entirely.
3. **Ellipsis counting is `"..."` (three literal ASCII periods) only.**
   `datatrove` additionally counts the single-codepoint Unicode ellipsis
   `"…"`; #347's own finalized feature list names only `"..."`, so that is
   all this stage counts, non-overlapping, left to right.
4. **No bullet-line ratio, end-of-line-ellipsis ratio, digit ratio, or
   min/max word-count thresholds.** Real fields in `datatrove`'s
   `GopherQualityFilter`, but not part of #347's finalized six-group feature
   list -- not computed here.
5. **"Character" always means Unicode codepoint count**, matching Python
   `len(str)` semantics (which every verified formula above is expressed
   in), never UTF-8 byte length or grapheme-cluster count.
6. **Top-n-gram character fractions can legitimately exceed 1.0.** The
   verified `find_top_duplicate` formula counts every overlapping
   occurrence's full character span; overlapping windows of the same
   repeated gram can cover the same source characters more than once (e.g.
   `"a b a b a b"`'s top 4-gram: two overlapping `"a b a b"` occurrences,
   numerator 14 over 11 total characters -> fraction > 1.0). This is an
   inherent property of the verified reference algorithm, not a bug.

## Abstention, never quarantine, for any feature

Every feature here operates on decoded text (words, lines, paragraphs), so
**invalid UTF-8 abstains every field in this stage's extension field at
once** (`utf8Status = invalidUtf8`) -- unlike `compressibility-annotate`'s
deliberate entropy/ratio asymmetry, where only one of its two metrics
requires valid UTF-8. `rawBytes` is still recorded truthfully even then.

Given valid UTF-8:

- **`wordStatus` abstains as `noWords`** only when `wordCount == 0` (empty
  or all-whitespace content). This gates mean word length, both
  symbol-to-word ratios, and alphabetic-word fraction. `wordCount` and
  `stopWordPresentCount` are always real counts -- `0` is a legitimate
  value, never a sentinel.
- **Duplicate-line and duplicate-paragraph *fraction*** (not the *character*
  fraction) are **always computed**, even for empty content: splitting on
  `\n+`/`\n{2,}` always yields at least one element (matching Python's own
  `re.split` edge behavior), so the denominator is never zero.
- **Duplicate-line and duplicate-paragraph *character* fraction abstain**
  (`null`) iff `rawBytes == 0` -- the only way their shared `rawChars`
  denominator can be zero. Note this is genuinely independent of
  `wordStatus`: all-whitespace content (`"   "`) has `wordCount == 0` but
  `rawChars == 3`, so these char fractions still compute as a real `0.0`,
  not abstain -- proven directly by a dedicated `domain.quality_ratios`
  unittest.
- **Each top-n-gram/duplicate-n-gram field abstains** (`null`) iff
  `wordCount < n` for that field's own `n` -- too few words to form even one
  n-gram of that size, matching `datatrove`'s own `if not n_grams: continue`
  skip.

## `max-input-bytes`

The stage's one caller-tunable option, declared and read inline exactly as
`compressibility-annotate`'s own option -- no separate CLI-wiring file.
Content larger than this bound quarantines with reason `rawLimit` before any
feature runs. Default: 1 MiB. Configurable range: 1 byte to 8 MiB
(`qualityRatiosMaxConfigurableInputBytes`), the same default/ceiling pair as
`compressibility-annotate`.

## The extension field

Schema `scrubbed-quality-ratios-v1`, one field named `quality-ratios`,
written via #285's `DocumentMetadata.withExtensionField`. Field names in the
wire JSON are deliberately short (this stage has far more sub-fields than
`compressibility`'s two metrics, and every extension field is capped at 512
bytes -- `domain.document_metadata.maxExtensionValueBytes`); the mapping is:

| Wire key | Feature |
| --- | --- |
| `schema` | schema version string |
| `u8` | `Utf8Status`: `computed` / `invalidUtf8` |
| `rb` | raw content bytes |
| `rc` | raw content Unicode codepoints |
| `ws` | `WordStatus`: `computed` / `noWords` |
| `wc` | word count |
| `mwl` | mean word length |
| `hashR` | hash-to-word ratio |
| `ellR` | ellipsis-to-word ratio |
| `alphaF` | alphabetic-word fraction |
| `stopN` | stop words present (0-8) |
| `dupLnF` | duplicate-line fraction |
| `dupLnCF` | duplicate-line character fraction |
| `dupParaF` | duplicate-paragraph fraction |
| `dupParaCF` | duplicate-paragraph character fraction |
| `top2`/`top3`/`top4` | top-n-gram character fraction, n=2,3,4 |
| `dup5`..`dup10` | duplicate-n-gram character fraction, n=5..10 |
| `rev` | sha256 of the exact raw content bytes measured (hex) |

Every field that can abstain is JSON `null` exactly when its status/gating
condition (documented above and in `domain.quality_ratios`'s own doc
comments) says so -- never a bare `0.0` sentinel. A dedicated unittest in
`source/effects/quality_ratios_annotate_stage.d` pins the worst-case encoded
length (longest status names, maximal digit counts at the 8 MiB configurable
ceiling) under the 512-byte extension-field cap.
`source/effects/quality_ratios_annotate_stage.encodeQualityRatiosV1`/
`decodeQualityRatiosV1` are the encode/decode pair (decode is test-only --
the field is opaque to every other module, `document-metadata-publish`
included).

## Pipeline placement

Non-terminal v3 stage (`SideOutputCapability.none`,
`StageCardinality.oneToOne`), the same shape as `compressibility-annotate`.
It reads whatever `StageDocument.content` bytes it receives at its position
in the compiled chain. `content` passes through this stage completely
unmodified. It routes through the existing, unmodified
`document-metadata-publish` terminal stage -- no new plumbing was added for
this slice.

## Determinism

Two runs over the same input bytes produce byte-identical extension-field
bytes: fixed `%.4f` numeric formatting, no ambient/system randomness
anywhere, and deterministic tie-breaking (first occurrence order) in the
top-n-gram computation.

## Golden fixtures (real computed numbers)

Proven with real, computed values in
`source/effects/quality_ratios_annotate_stage.d`'s unittests (not merely
type-correctness), and printed directly by `dub test --build=release-unittest`:

- **Fixture A -- normal, well-formed prose** (a short paragraph about a
  coastal town's history): `wordCount=72`, `meanWordLength=4.7917`,
  `hashToWordRatio=0.0000`, `ellipsisToWordRatio=0.0000`,
  `alphabeticWordFraction=1.0000`, `stopWordPresentCount=5`,
  `dupLineFraction=0.0000`, `dupParaFraction=0.0000`.
- **Fixture B -- keyword-stuffed/SEO-spam-like text** (16 distinct hashtag-
  style keyword phrases, no verbatim-repeated phrase, deliberately fluent-
  looking enough that neither `compressibility-annotate`'s order-0 token
  entropy nor its zstd compression ratio would necessarily flag it as
  degenerate): `wordCount=16`, `meanWordLength=14.9375`,
  `hashToWordRatio=1.0000`, `ellipsisToWordRatio=0.0000`,
  `alphabeticWordFraction=1.0000`, **`stopWordPresentCount=0`**,
  `dupLineFraction=0.0000`, `dupParaFraction=0.0000`.
- **Fixture C -- highly repetitive text** (one sentence repeated verbatim 8
  times, one per line): `wordCount=72`, `dupLineFraction=0.7778`,
  `dupLineCharFraction=0.8599`, `dup5GramCharFraction=0.7091`,
  `dup10GramCharFraction=0.7091`.

**The coverage-gap proof these three fixtures demonstrate** (the real gap
issue #347 names): fixture B is fluent, non-repetitive, low-entropy-neutral
text -- exactly the shape that reads as "statistically normal" to entropy or
compression-ratio alone -- yet `stopWordPresentCount` (0 vs. fixture A's 5)
and `hashToWordRatio` (1.0 vs. fixture A's 0.0) catch it sharply. Fixture C
is caught by an entirely different, complementary signal:
`dupLineFraction`/`dup5GramCharFraction` (0.78/0.71 vs. fixture A's exact
0.0), the multi-scale repetition family, distinct from and complementary to
`compressibility-annotate`'s own zstd-ratio-based repetition signal (see
that stage's own "highly repetitive text" fixture, where zstd ratio catches
verbatim repetition that order-0 entropy misses entirely -- this stage adds
a third, independent lens on the same broad phenomenon).

Also proven directly: empty input (`noWords`, but line/paragraph
*fractions* still compute as `0.0`); all-whitespace nonempty input (proving
`wordStatus == noWords` and `rawBytes == 0` are genuinely independent
abstention gates); invalid UTF-8 (every field abstains at once, still
emits, never quarantines); exceeding `max-input-bytes` (quarantines
`rawLimit`, the only "could not measure at all" case); determinism;
content-revision sha256 binding; and full reachability through
`[quality-ratios-annotate, document-metadata-publish]` via
`compileJob`/`runCompiledJob`. `source/domain/quality_ratios.d` additionally
carries its own independent, hand-computed-and-verified unittests for every
formula (word stats, symbol ratios, alphabetic fraction, stop words,
duplicate-line/-paragraph, top-n-gram, duplicate-n-gram) against small,
manually-traced fixtures.

## Estimator limitations

- Every feature requires valid UTF-8; there is no asymmetric fallback like
  `compressibility-annotate`'s zstd half.
- Word/line/paragraph/n-gram definitions are this stage's own
  whitespace-only simplifications of the verified `datatrove` reference --
  see "Deliberate, disclosed deviations" above. Values are not expected to
  match `datatrove`'s own numeric output bit-for-bit on the same input.
- Top-n-gram character fractions can exceed 1.0 on highly self-overlapping
  repeated text (see deviation 6 above) -- a property of the verified
  formula, not a bug.
- This stage makes no keep/reject/quarantine decision from any feature. A
  future, separate, owner-approved policy slice (mirroring
  `docs/quality-annotations.md`'s existing feature/decision-overlay split)
  would decide what to do with these numbers, if anything.

## Relationship to `docs/quality-annotations.md`

`docs/quality-annotations.md` documents an unrelated, already-shipped
system: `effects.quality_overlay`'s C01 `quality.features`/
`quality.decisions` overlay pair (byte-length/scalar/line/letter/control/
replacement/duplicate-line-count bucketed counts, plus a separate policy-
decision overlay). This document is a new sibling rather than an addition
to that one because the two systems are structurally unrelated: this
stage's output is a #285 `StageDocument.metadata` extension field inside the
v3 stage/job pipeline (exactly `compressibility-annotate`'s own shape),
while `quality_overlay` is a standalone C01 shard-overlay API with its own
publish/replay/dry-run lifecycle, invoked outside the stage pipeline
entirely. Grafting this stage's docs into `quality-annotations.md` would
conflate two independent mechanisms that happen to share the word
"quality."

## Rollback

Stop naming `quality-ratios-annotate` in any job's `stages` list. No other
module depends on this stage or its extension field; `document-metadata-
publish` and every other stage are unaffected. `domain.quality_ratios` is
also unwired from anything else and can be removed independently.
