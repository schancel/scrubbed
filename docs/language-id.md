# Language identification: pure n-gram classifier with abstention (v1)

**Status: next slice of issue #34 (C03), extending the shipped first slice
(`805d7d3`, PR #291) from four to eleven Latin-script languages.** This is
still a pure, repository-local seam, not a completion of #34. It is a
deterministic character-n-gram language classifier, now covering eleven
Latin-script languages (English, Spanish, French, German, Portuguese,
Italian, Dutch, Turkish, Vietnamese, Polish, Indonesian), a typed
result/abstention value, and a revision-bound identity/wire idiom. It does
**not** parse HTML, register a pipeline stage, expose CLI/config, or publish
local/JSONL/durable/overlay output. `domain.language_id` is self-contained:
nothing else in `source/` imports it, and the ordinary shipping binary has
no language-id stage/CLI/config reachability. The parent issue #34 stays
open for a separately reviewed successor
(`source/effects/language_overlay.d`, persisting via the existing C01
`OverlayWriter`), for any decision to
route `domain.topical_tags`'s own caller-supplied `language` parameter from
this module's output, and for the broader ~25-language, 13-script-family
roadmap this slice's contract recorded (Han/Chinese, Japanese, Korean,
Devanagari, Bengali, Arabic script, Cyrillic, Tamil, Telugu, Gujarati,
Gurmukhi, Thai) — none of that is decided or touched here; this slice stays
within the Latin script family the first slice already handled.

## Files

- `source/domain/language_id.d` — the classifier, identity, encoder/decoder,
  and `routeLanguage`.
- `experiments/language_id/generate_profiles.d` — the deterministic,
  network-free profile-table generator, also usable as a library by the
  checker.
- `experiments/language_id/check.d` — release-active D checker: provenance
  (seed-corpus digests, generator reproducibility, seed/held-out
  disjointness), goldens, the full 11x11 held-out confusion matrix (with a
  separately surfaced Romance sub-table), the excluded-neighbor abstention
  probes, decoder rejection, a privacy boundary, and a benchmark matrix.
- `experiments/language_id/fixtures/profiles/<lang>.txt` for
  `<lang>` in `en/es/fr/de/pt/it/nl/tr/vi/pl/id` — the authored seed corpus
  (twenty original sentences per language) the embedded profile tables are
  generated from. The seven added by this slice (pt/it/nl/tr/vi/pl/id)
  follow the exact same discipline as the original four.
- `experiments/language_id/fixtures/heldout/<lang>.txt` for the same eleven
  language codes — a disjoint authored held-out set (ten original sentences
  per language, never copied from the seed corpus) used for the
  confusion-matrix report.
- `experiments/language_id/fixtures/heldout/excluded/{ro,ca-or-gl,sw}.txt` —
  authored "excluded-neighbor" probes: ten original sentences each in
  Romanian, Catalan (the accepted contract's "Catalan-or-Galician" choice —
  Catalan was picked; the file keeps the generic `ca-or-gl` name from the
  contract), and Swahili. These are close linguistic neighbors of languages
  now in the supported eleven, but are themselves **not** supported; see
  "Excluded-neighbor abstention" below.
- This document.

Rollback is deleting these files; no existing job, source shard, or other
stored state changes, and no later job references this module until a
separately authorized shipping landing exists.

## Algorithm

Cavnar & Trenkle-style out-of-place character-n-gram rank distance
(n=1..4), unchanged by this slice. Chosen over single-character frequency
(rejected: these Latin-script languages share the Latin alphabet with
heavily overlapping letter-frequency distributions, giving poor
discrimination) and stopword/tokenizer approaches (rejected: they require
word-boundary assumptions and degrade sharply on short or malformed text).
No embedded ML/statistical model and no network/model-download dependency.

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
   - `pt`: `f55d793d4195f602b868a2073e95c8861e42ba421759b1ec8df33bec4b1cedd6`
   - `it`: `515835c6504354ec6cbcf5f6ef5b2d45f52649058eb6ec8b4602c6b59bd6cab5`
   - `nl`: `7a3088dcd30178260a0d5312eb8c50ac9c37f79ba1d0866a4cd3b8fc76d0c6c1`
   - `tr`: `f1153bf5eff5f4a94eb0a54918c02ff3070962581221e3a5a06e7f7b45b3a190`
   - `vi`: `5678ca971c0618768b2ed9fe1148bae04c53b326f473cefab2c624e8f01f7dbb`
   - `pl`: `f092baf804251c945dfd46147f47beb013cc84d1cbda5c32ad2f8196ca236fbc`
   - `id`: `1dea1af4e267f318badb549428904a3c6a4ea9b2c4f40f13074dcc97994c32b8`
2. **Deterministic generator.** `experiments/language_id/generate_profiles.d`
   reads the seed corpus and calls `domain.language_id.rankedNgramProfile` —
   the exact same pure function the production module exposes — to produce
   each language's ranked n-gram table. There is only one ranking algorithm
   to drift, because the generator and the checker both call it directly
   rather than re-implementing it. The result is embedded as the
   `static immutable string[] languageProfileEn/Es/Fr/De/Pt/It/Nl/Tr/Vi/Pl/Id`
   tables in `source/domain/language_id.d`, mirroring
   `effects.html_main_content`'s fixed drift-checked table idiom. `check.d`'s
   `generatorReproducibilityProof` re-runs the generator (twice, to also
   confirm run-to-run determinism) and asserts byte-identical output against
   those embedded tables — the drift-detection proof this contract requires,
   now covering all eleven languages. To regenerate after an intentional
   seed-corpus change:
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
   between every seed sentence and every held-out sentence, across all
   eleven languages. `heldOutConfusionMatrix` then reports (and, per this
   codebase's usual exact-digest reproducibility convention, pins as a
   golden rather than treating as a soft/statistical assertion) the
   per-language confusion matrix and abstention counts over that held-out
   set — currently 106/110 correct, 0 misclassified, 4 abstained (2
   Portuguese and 2 Dutch held-out lines, both via `mixedOrAmbiguous`). This
   is small authored boundary evidence only, **not** a web-scale, universal-
   language-coverage, or accuracy-target claim; a deliberate future
   algorithm/threshold/profile change is free to move this number as long as
   the golden is updated deliberately rather than silently drifting.

   **Romance sub-table (es/fr/it/pt).** Per the accepted contract, the
   cross-confusion cells among these four close Romance relatives are
   computed and printed as their own separate, explicitly reviewed 4x4
   sub-table (`heldOutConfusionMatrix` in `check.d`), not folded into the
   aggregate above. At the currently embedded profile tables, this
   sub-table's off-diagonal cross-Romance-confusion total is **0**: every
   Spanish, French, and Italian held-out line classifies correctly as its
   own language, and Portuguese's two abstentions (via `mixedOrAmbiguous`)
   are abstentions, not misclassifications into another Romance language.
   This is disclosed as the current observed result, not gated to an
   externally accepted target number.

## Result type and abstention

`LanguageIdentity` binds the typed `DocumentId`, the exact 32-byte SHA-256
revision of the scored text, a digest identifying the exact embedded profile
table content (`currentProfileTableIdentity`), and the algorithm version.
`LanguageIdentityRecord` pairs that identity with a `LanguageDetectionResult`
— the bound, wire-encodable value, mirroring how `domain.topical_tags`
separates its `TopicalTagsIdentity` from the full
`TopicalTagsAnnotation` it is embedded in.

`LanguageDetectionResult` carries a status (`detected`/`abstained`); if
`detected`, a `SupportedLanguage` (`en`/`es`/`fr`/`de`/`pt`/`it`/`nl`/`tr`/
`vi`/`pl`/`id` — the seven added by this slice appended after the original
four, so the wire byte value of every existing supported language is
unchanged) and the relative, uncalibrated confidence described above; if
`abstained`, one typed reason (unchanged by this slice):

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
  outside the Latin script ranges this module recognizes, abstain rather
  than force-fit non-Latin text into a Latin-script classifier. **This
  slice's required code fix**: the recognized ranges now also include Latin
  Extended Additional (`U+1E00`-`U+1EFF`), in addition to the original Basic
  Latin, Latin-1 Supplement, and Latin Extended-A/B. This was necessary for
  Vietnamese: many of its precomposed tone-marked vowels (e.g. `ệ`, `ọ`,
  `ữ`, and, as it turns out, several plain hook-above/dot-below/tilde-y
  tone marks with no circumflex/breve at all, e.g. `ả`, `ạ`, `ỹ`) live in
  this block, not in the ranges the first slice recognized. Verified against
  real, dense Vietnamese text: without the fix, an authored sentence with a
  non-Latin-under-the-old-ranges letter fraction of ~30.1% (22 of 73
  letters) false-abstained via `unsupportedScript`; with the fix, the same
  sentence correctly detects as Vietnamese (see the "Vietnamese diacritic
  density" golden in `experiments/language_id/check.d`, and the "Excluded-
  neighbor abstention" section below for what this fix does *not* change).
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
- **The excluded-neighbor abstention gap** (Romanian/Catalan/Swahili
  probes not cleanly abstaining after reasonable tuning attempts within
  existing constants) — see "Excluded-neighbor abstention" immediately
  below for the full disclosure and specific observed numbers, flagged here
  per the same contract instruction.

`nonLatinScriptBound` (0.3), `mixedMarginBound` (0.02), and
`internalConfidenceFloor` (0.15) are ordinary implementation constants,
tuned against the same small authored fixture set described above and
documented here for transparency, but were not separately called out for
sign-off by the contract.

### Excluded-neighbor abstention: a disclosed, not fully closed, gap

This is the direct successor to the first slice's German-vs-Dutch
disclosure (that specific pair is now resolved: Dutch is supported). The
same structural problem recurs, now probed deliberately, per the
accepted contract, against three close linguistic neighbors of the eleven
supported languages that are themselves **not** supported: Romanian (close
to the Romance cluster), Catalan (very close to Spanish; the contract's
"Catalan-or-Galician" choice — Catalan was picked here; see
`experiments/language_id/fixtures/heldout/excluded/ca-or-gl.txt`), and
Swahili (probed as a more distant, non-Indo-European control).

The accepted contract's implementation path was: first try tightening via
the existing `internalConfidenceFloor`/`mixedMarginBound` constants,
validated against ten authored held-out probe sentences per excluded
language, before considering any other option. That tuning attempt was made
(`experiments/language_id/check.d`'s `excludedNeighborAbstentionGoldens`
doc comment has the full sweep) and is disclosed here rather than silently
skipped or forced to a false "clean pass":

- The lowest genuine confidently-detected supported-language held-out
  confidence observed is **0.273** (Vietnamese). A Swahili probe line
  force-classifies as Indonesian at confidence **0.271** — *below* that
  genuine floor. No single `internalConfidenceFloor` value separates
  excluded-neighbor false positives from genuine supported-language text
  without also abstaining currently-correct held-out text.
- The lowest genuine supported-language margin fraction observed is
  **~0.0264** (Portuguese/Italian). Excluded-neighbor margin fractions range
  from **~0.0213 to ~0.0603**, overlapping that genuine distribution
  throughout; no single `mixedMarginBound` value separates them either.

Neither existing constant admits a value that cleanly separates these three
probes from genuine supported-language text, so no bespoke new mechanism
was invented and no false "always abstains" claim is made. The observed
outcome, exactly as pinned and disclosed by `excludedNeighborAbstentionGoldens`:

- **Romanian**: 8/10 probe lines abstain (`mixedOrAmbiguous`); 2/10
  force-classify (Italian at confidence 0.286, French at 0.366).
- **Catalan**: 4/10 abstain; 6/10 force-classify (all as Spanish or Italian,
  confidence 0.400-0.427 — the worst case of the three, as expected given
  how close Catalan is to Spanish).
- **Swahili**: 7/10 abstain; 3/10 force-classify (Indonesian, confidence
  0.271-0.308).

`unsupportedScript` does not help here (all three probe languages are
plain Latin script within the recognized ranges). `mixedOrAmbiguous` and
`belowConfidenceThreshold` catch a majority but not all probe lines. This
is consistent with the contract's explicit allowance ("no guarantee the
excluded-neighbor mechanism achieves zero false-classification — only that
it's tested and any residual gap is disclosed"), and is flagged here for
owner sign-off, the same way the original German-vs-Dutch 0.315/0.316
finding was.

## Wire format

**Unchanged by this slice.** `encodeLanguageIdentity`/
`decodeLanguageIdentity`: a canonical fixed-field layout (domain tag, schema
version, document ID, text revision, profile table identity, algorithm
version, status, language, per-mille confidence, abstention reason) plus a
whole-record SHA-256 checksum trailer, directly mirroring
`domain.topical_tags`'s `encodeTopicalTags`/`decodeTopicalTags` idiom. The
`language` field is still a single byte; it now accepts the seven new
`SupportedLanguage` values (`4`-`10`) in addition to the original four
(`0`-`3`), with `SupportedLanguage.max` now `10`. `decodeLanguageIdentity`
binds to a caller-supplied `expectedId`/`expectedTextRevision` obtained
independently (e.g. a future C01 join), so a record cannot silently attach
to another document or revision; it also re-validates the profile-table
identity against the currently embedded tables (which changed with this
slice's seven new profiles, so a record built under the four-language
tables is correctly rejected as a profile-table mismatch), rejecting a
record built under a different profile version. Truncation, trailing data,
and any single-byte corruption anywhere in the record are all rejected.

## Proof (release-active checker)

`experiments/language_id/check.d`:

- **Seed-corpus digests** — pinned SHA-256 per language, all eleven (above).
- **Generator reproducibility** — the byte-identical drift-detection proof
  described under Provenance, run twice for run-to-run determinism, now
  covering all eleven embedded tables.
- **Seed/held-out disjointness** — zero exact-line overlap, both corpora
  above their expected minimum sizes, across all eleven languages.
- **Boundary goldens** — the exact `tooShort` cutoff transition (58 vs. 60
  total n-grams), plus empty/oversize/invalid-UTF-8 abstention (unchanged
  `minNgramCount == 60`).
- **Script-abstention golden** — an authored Russian (Cyrillic) sentence
  abstains via `unsupportedScript` (unchanged non-Latin case).
- **Vietnamese diacritic-density golden** — an authored, deliberately dense
  Vietnamese sentence (~30.1% of its letters in Latin Extended Additional)
  is correctly detected as Vietnamese, proving the `isLatinLetter` range fix
  required by this slice actually works; verified against the pre-fix
  behavior (false-abstains via `unsupportedScript` without it).
- **Mixed-language golden** — an authored English/Spanish blend abstains via
  `mixedOrAmbiguous`.
- **Excluded-neighbor abstention goldens** — the Romanian/Catalan/Swahili
  probes described above, with the exact observed abstain/force-classify
  counts pinned per probe language and every force-classified line's
  confidence disclosed in the checker's own output.
- **Threshold-routing goldens** — `routeLanguage` at, above, and below one
  exact declared threshold, plus the always-unrouted abstained case.
- **Full 11x11 held-out confusion matrix**, with the Romance (es/fr/it/pt)
  sub-table printed as its own separate, explicitly reviewed block —
  described under Provenance.
- **Identity and decoder rejection** — round trip, wrong document/revision,
  truncation, trailing data, and every single byte of one fixture's encoded
  record corrupted and confirmed rejected.
- **Exhaustive `SupportedLanguage` wire round trip** — every one of the
  eleven enum values (including the seven added by this slice)
  independently round-trips through encode/decode, and a hand-constructed
  record with the language byte set to `SupportedLanguage.max + 1` (with an
  otherwise-correct checksum, isolating the range-check path from the
  checksum check) is rejected.
- **Privacy boundary** — a synthetic canary embedded in input text is
  confirmed absent from the encoded record; only the bounded language code,
  per-mille confidence, and abstention reason travel.
- **Benchmark matrix** — a D-only child-process matrix over `many-small`
  (64 documents) and `few-large` (4 documents) shapes at the same total
  512 KiB of synthetic text, now re-run at the eleven-language embedded
  table size. Each shape runs twice as a separate child process; an exact
  digest line must match byte-for-byte across the two runs before the
  parent reports wall time, `RUSAGE_CHILDREN` CPU and peak RSS, and the
  child's own wall time and GC stats. Descriptive bounded-cost evidence
  only, not a speed advantage claim.

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
accuracy claim — the held-out split above is 110 authored sentences across
eleven languages. Not coverage of any script beyond these eleven
Latin-script languages: no Han/Japanese/Korean/Devanagari/Bengali/Arabic
script/Cyrillic/Thai work is included or referenced by code here — that is
a separate, not-yet-scoped future research track (see the "Notes" recorded
in this slice's accepted contract on issue #34). Not a script-family-
detection front-end rework — the single binary Latin/non-Latin gate
structure from the first slice is unchanged; only its recognized ranges
were widened. Not a guarantee that the excluded-neighbor mechanism achieves
zero false-classification for languages outside the supported set — see
"Excluded-neighbor abstention" above. Not HTML parsing, a pipeline stage,
CLI/config surface, or any local/JSONL/durable/overlay publication path;
those are explicitly out of scope for this slice and belong to a separately
groomed successor. Not a change to `domain.topical_tags`'s existing
`language` parameter — whether or how a later slice wires this module's
output into that parameter is an explicitly deferred integration decision,
not made here.
