# Language identification: pure four-language n-gram classifier with abstention (v1)

**Status: first slice of issue #34 (C03).** This is a pure, repository-local
seam, not a completion of #34. It adds a deterministic character-n-gram
language classifier for an explicit four-language set (English, Spanish,
French, German), a typed result/abstention value, and a revision-bound
identity/wire idiom. It does **not** parse HTML, register a pipeline stage,
expose CLI/config, or publish local/JSONL/durable/overlay output.
`domain.language_id` is self-contained: nothing else in `source/` imports it,
and the ordinary shipping binary has no language-id stage/CLI/config
reachability. The parent issue #34 stays open for a separately reviewed
successor (`source/effects/language_overlay.d`, persisting via the existing
C01 `OverlayWriter`) and for any decision to route `domain.topical_tags`'s
own caller-supplied `language` parameter from this module's output — neither
is decided here.

## Files

- `source/domain/language_id.d` — the classifier, identity, encoder/decoder,
  and `routeLanguage`.
- `experiments/language_id/generate_profiles.d` — the deterministic,
  network-free profile-table generator, also usable as a library by the
  checker.
- `experiments/language_id/check.d` — release-active D checker: provenance
  (seed-corpus digests, generator reproducibility, seed/held-out
  disjointness), goldens, a held-out confusion matrix, decoder rejection, a
  privacy boundary, and a benchmark matrix.
- `experiments/language_id/fixtures/profiles/{en,es,fr,de}.txt` — the
  authored seed corpus (twenty original sentences per language) the embedded
  profile tables are generated from.
- `experiments/language_id/fixtures/heldout/{en,es,fr,de}.txt` — a disjoint
  authored held-out set (ten original sentences per language, never copied
  from the seed corpus) used only for the confusion-matrix report.
- This document.

Rollback is deleting these files; no existing job, source shard, or other
stored state changes, and no later job references this module until a
separately authorized shipping landing exists.

## Algorithm

Cavnar & Trenkle-style out-of-place character-n-gram rank distance
(n=1..4). Chosen over single-character frequency (rejected: English,
Spanish, French, and German share the Latin alphabet with heavily
overlapping letter-frequency distributions, giving poor discrimination) and
stopword/tokenizer approaches (rejected: they require word-boundary
assumptions and degrade sharply on short or malformed text). No embedded
ML/statistical model and no network/model-download dependency.

For each maximal run of Unicode letters (a "word"; all other characters are
separators and are dropped), the word is lowercased and padded with one
leading and trailing space, and every n=1..4 substring of that padded,
codepoint-aware window is counted. Ranking is by descending count, with ties
broken by ascending n-gram string (UTF-8 byte order) — a fully deterministic
total order that never depends on hash-table iteration order. Each
language's profile keeps the top `profileCap` (300) ranked n-grams; a scored
document's own text is ranked the same way and also capped at 300.

The out-of-place distance from a document to a language profile sums, for
every one of the document's ranked n-grams, the absolute difference between
its rank in the document and its rank in that language's profile — or a
fixed penalty (that profile's own length) when the n-gram is entirely
absent from the profile. The best (lowest-distance) language wins, subject
to the abstention checks below. `confidence` is `1 - bestDistance /
(profileCap * documentNgramCount)`, clamped to `[0, 1]` and quantized to
whole per-mille (so it round-trips exactly through the wire encoding). It is
an explicitly **relative, uncalibrated** score — not a probability, and not
comparable across differently sized documents in any absolute sense.

## Provenance (the specification gap that previously stalled this ticket)

1. **Seed corpus.** `experiments/language_id/fixtures/profiles/<lang>.txt`
   holds twenty short, original, plainly authored UTF-8 sentences per
   language — everyday topics (weather, food, work, nature), no licensing
   question, no ambiguity. Each file's exact SHA-256 is pinned in
   `experiments/language_id/check.d`:
   - `en`: `954da4ffee2e892640beee2156fcdf360cdf2337f8942c1b905f1266c32c5c4d`
   - `es`: `6e214c192b097d8256f903f629d015c8c44e4c6f48238e9863e0716a8073eb1a`
   - `fr`: `2a2a9acdabe731c4de0f8d2b1c422c91c00b64c1040915443939027086113bd4`
   - `de`: `9d6809f05bce2a3177cf452ee3a4dc885e47137c18fe8ed3d81355dc4b903bf3`
2. **Deterministic generator.** `experiments/language_id/generate_profiles.d`
   reads the seed corpus and calls `domain.language_id.rankedNgramProfile` —
   the exact same pure function the production module exposes — to produce
   each language's ranked n-gram table. There is only one ranking algorithm
   to drift, because the generator and the checker both call it directly
   rather than re-implementing it. The result is embedded as the
   `static immutable string[] languageProfileEn/Es/Fr/De` tables in
   `source/domain/language_id.d`, mirroring `effects.html_main_content`'s
   fixed drift-checked table idiom. `check.d`'s
   `generatorReproducibilityProof` re-runs the generator (twice, to also
   confirm run-to-run determinism) and asserts byte-identical output against
   those embedded tables — the drift-detection proof this contract requires.
   To regenerate after an intentional seed-corpus change:
   ```sh
   ldc2 -O3 -release -Isource -Iexperiments -d-version=LanguageIdGenerateProfilesMain \
     -of=/tmp/language-id-generate-profiles \
     experiments/language_id/generate_profiles.d source/domain/language_id.d \
     source/domain/document.d source/crypto/sha256.d source/crypto/sha256_arm64.d \
     source/crypto/sha256_x86_64.d
   /tmp/language-id-generate-profiles
   ```
   then paste the printed arrays over the embedded tables by hand.
3. **Disjoint held-out set.**
   `experiments/language_id/fixtures/heldout/<lang>.txt` holds ten different
   original sentences per language, never copied or derived from the seed
   corpus. `check.d`'s `disjointnessProof` asserts zero exact-line overlap
   between every seed sentence and every held-out sentence, across all four
   languages. `heldOutConfusionMatrix` then reports (and, per this
   codebase's usual exact-digest reproducibility convention, pins as a
   golden rather than treating as a soft/statistical assertion) the
   per-language confusion matrix and abstention counts over that held-out
   set — currently 40/40 correct, 0 misclassified, 0 abstained. This is
   small authored boundary evidence only, **not** a web-scale, universal-
   language-coverage, or accuracy-target claim; a deliberate future
   algorithm/threshold/profile change is free to move this number as long as
   the golden is updated deliberately rather than silently drifting.

## Result type and abstention

`LanguageIdentity` binds the typed `DocumentId`, the exact 32-byte SHA-256
revision of the scored text, a digest identifying the exact embedded profile
table content (`currentProfileTableIdentity`), and the algorithm version.
`LanguageIdentityRecord` pairs that identity with a `LanguageDetectionResult`
— the bound, wire-encodable value, mirroring how `domain.topical_tags`
separates its `TopicalTagsIdentity` from the full
`TopicalTagsAnnotation` it is embedded in.

`LanguageDetectionResult` carries a status (`detected`/`abstained`); if
`detected`, a `SupportedLanguage` (`en`/`es`/`fr`/`de`) and the relative,
uncalibrated confidence described above; if `abstained`, one typed reason:

- `emptyText` — zero-byte input.
- `invalidUtf8` — the bytes do not decode as UTF-8.
- `oversizeText` — larger than `maxLanguageIdTextBytes` (`1024 * 1024`,
  reusing the existing C01 bounded-document byte cap — the same numeric
  value as `domain.shard_format.maxDocumentPayload` and
  `domain.topical_tags.maxCanonicalTextBytes`; this module keeps its own
  locally named constant of that value, following this codebase's existing
  per-module-cap convention rather than cross-importing another domain
  module's constant).
- `tooShort` — fewer than `minNgramCount` (**60**, pinned; see "Flagged for
  owner sign-off" below) total n-gram occurrences (n=1..4 combined, i.e. the
  sum of every n-gram's count, not the count of distinct n-gram types).
- `unsupportedScript` — a cheap pre-check, run before any n-gram scoring:
  if more than `nonLatinScriptBound` (30%) of the text's Unicode letters are
  outside the Latin script ranges this module recognizes (Basic Latin,
  Latin-1 Supplement, Latin Extended-A/B), abstain rather than force-fit
  non-Latin text into a Latin-script classifier.
- `mixedOrAmbiguous` — the best and second-best language's out-of-place
  distances are within `mixedMarginBound` (2% of the worst-case distance) of
  each other; the two top candidates are too close to call.
- `belowConfidenceThreshold` — the best candidate clears the margin check
  above but its own relative confidence is still below
  `internalConfidenceFloor` (0.15). This is an **internal** detection floor,
  independent of `routeLanguage`'s caller-supplied external threshold
  described next.

`routeLanguage(result, threshold)` is a separate pure function: only a
`detected` result at or above the caller-supplied `threshold` routes to a
usable `SupportedLanguage`; every abstained or below-threshold result stays
explicitly unclassified (`RoutedLanguage.routed == false`). **No default
threshold is pinned in this slice** — every caller must supply one
explicitly.

### Flagged for owner sign-off

Per the accepted contract's explicit instruction not to silently bake in a
number:

- **`minNgramCount == 60`** (the `tooShort` cutoff) was pinned by the
  implementer via the boundary goldens in `experiments/language_id/check.d`
  (`"the cat dog to a"`, 58 total n-grams, abstains; `"the cat dog wolf"`,
  60 total n-grams, detects as English), not independently validated
  against a wider corpus than this module's own twenty-sentence-per-language
  seed set. Every whole word of letter-length `L` contributes exactly
  `4*L + 2` n-gram occurrences (from its one-space-padded n=1..4 window
  count), so this total is always even for any input text — the boundary
  goldens above are built to exactly `minNgramCount` and `minNgramCount - 2`
  for that reason, not `minNgramCount - 1`.
- **`routeLanguage` has no default threshold** — every caller must supply
  one explicitly. No default is proposed here; a future CLI/config-exposing
  successor must pick and justify one.

`nonLatinScriptBound` (0.3), `mixedMarginBound` (0.02), and
`internalConfidenceFloor` (0.15) are ordinary implementation constants,
tuned against the same small authored fixture set described above and
documented here for transparency, but were not separately called out for
sign-off by the contract.

### A known, undocumented-elsewhere limitation

This classifier's four profiles were tuned only against English, Spanish,
French, and German. Text in a fifth Latin-script language this module does
not claim to support (Italian, Portuguese, and Dutch were checked during
tuning) is **not guaranteed** to abstain: it can be force-classified into
one of the four supported languages at a moderate (not high) confidence,
because that confidence range overlaps genuine low-confidence-but-correct
results for the supported set (observed as low as 0.315 for legitimate
German held-out text, versus 0.316 for out-of-set Dutch text in informal
testing) — there is no threshold that cleanly separates them without also
rejecting genuine supported-language text. `unsupportedScript` only
protects against non-Latin script; `mixedOrAmbiguous` only protects against
genuinely balanced bilingual blends of the four supported languages. This is
consistent with the contract's stated non-goal ("no coverage beyond the four
confirmed languages"), but is called out explicitly here since it is not a
golden this checker enforces.

## Wire format

`encodeLanguageIdentity`/`decodeLanguageIdentity`: a canonical fixed-field
layout (domain tag, schema version, document ID, text revision, profile
table identity, algorithm version, status, language, per-mille confidence,
abstention reason) plus a whole-record SHA-256 checksum trailer, directly
mirroring `domain.topical_tags`'s `encodeTopicalTags`/`decodeTopicalTags`
idiom. `decodeLanguageIdentity` binds to a caller-supplied
`expectedId`/`expectedTextRevision` obtained independently (e.g. a future
C01 join), so a record cannot silently attach to another document or
revision; it also re-validates the profile-table identity against the
currently embedded tables, rejecting a record built under a different
profile version. Truncation, trailing data, and any single-byte corruption
anywhere in the record are all rejected.

## Proof (release-active checker)

`experiments/language_id/check.d`:

- **Seed-corpus digests** — pinned SHA-256 per language (above).
- **Generator reproducibility** — the byte-identical drift-detection proof
  described under Provenance, run twice for run-to-run determinism.
- **Seed/held-out disjointness** — zero exact-line overlap, both corpora
  above their expected minimum sizes.
- **Boundary goldens** — the exact `tooShort` cutoff transition (58 vs. 60
  total n-grams), plus empty/oversize/invalid-UTF-8 abstention.
- **Script-abstention golden** — an authored Russian (Cyrillic) sentence
  abstains via `unsupportedScript`.
- **Mixed-language golden** — an authored English/Spanish blend abstains via
  `mixedOrAmbiguous`.
- **Threshold-routing goldens** — `routeLanguage` at, above, and below one
  exact declared threshold, plus the always-unrouted abstained case.
- **Held-out confusion matrix** — described under Provenance.
- **Identity and decoder rejection** — round trip, wrong document/revision,
  truncation, trailing data, and every single byte of one fixture's encoded
  record corrupted and confirmed rejected.
- **Privacy boundary** — a synthetic canary embedded in input text is
  confirmed absent from the encoded record; only the bounded language code,
  per-mille confidence, and abstention reason travel.
- **Benchmark matrix** — a D-only child-process matrix over `many-small`
  (64 documents) and `few-large` (4 documents) shapes at the same total
  512 KiB of synthetic text. Each shape runs twice as a separate child
  process; an exact digest line must match byte-for-byte across the two
  runs before the parent reports wall time, `RUSAGE_CHILDREN` CPU and peak
  RSS, and the child's own wall time and GC stats. Descriptive bounded-cost
  evidence only, not a speed advantage claim.

Run:

```sh
ldc2 -O3 -release -Isource -Iexperiments -of=.dub/language-id-check \
  experiments/language_id/check.d experiments/language_id/generate_profiles.d \
  source/domain/language_id.d source/domain/document.d source/crypto/sha256.d \
  source/crypto/sha256_arm64.d source/crypto/sha256_x86_64.d
.dub/language-id-check
```

The domain module's own `unittest` blocks (`ldc2 -unittest -Isource -main \
-of=... source/domain/language_id.d source/domain/document.d \
source/crypto/sha256.d source/crypto/sha256_arm64.d \
source/crypto/sha256_x86_64.d`) exercise empty/oversize/invalid-UTF-8
abstention, the wire round trip and one decoder rejection, and
`routeLanguage`'s threshold behavior as fast in-process regression coverage;
the release-active checker above is the pinned, release/O3-built proof with
provenance, the confusion matrix, and the benchmark matrix.

## What this is not

Not a calibrated-probability, universal-language-coverage, or web-scale
accuracy claim — the held-out split above is forty authored sentences. Not
HTML parsing, a pipeline stage, CLI/config surface, or any local/JSONL/
durable/overlay publication path; those are explicitly out of scope for
this slice and belong to a separately groomed successor. Not a change to
`domain.topical_tags`'s existing `language` parameter — whether or how a
later slice wires this module's output into that parameter is an explicitly
deferred integration decision, not made here.
