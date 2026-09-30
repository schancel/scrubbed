# Language identification: pure n-gram classifier with abstention (v1)

**Status: issue #299's slice, extending #34's two shipped Latin-script
slices (`805d7d3`/PR #291, four languages; a later slice, seven more) with
this classifier's first non-Latin script family.** This is still a pure,
repository-local seam, not a completion of #34. It is a deterministic
character-n-gram language classifier, now covering the original eleven
Latin-script languages (English, Spanish, French, German, Portuguese,
Italian, Dutch, Turkish, Vietnamese, Polish, Indonesian) plus six Brahmic-
family languages (Hindi/Devanagari, Bengali, Tamil, Telugu, Gujarati,
Punjabi/Gurmukhi) — seventeen languages total, a typed result/abstention
value, and a revision-bound identity/wire idiom. This module itself does
**not** parse HTML, expose a CLI subcommand/flag, or publish local/JSONL/
durable/overlay output, and `domain.language_id` remains self-contained:
nothing in `source/domain` or elsewhere imports it. Issue #311 added a thin,
terminal v3 stage consumer, `effects.language_id_detect_stage`
(`language-id-detect`), giving the ordinary shipping binary its first real
reachability path via the existing generic `run --stage id=language-id-detect`
composition mechanism — no dedicated subcommand, and no change to this
module's own frozen API/algorithm/thresholds. The parent issue #34 stays open
for a separately reviewed successor (`source/effects/language_overlay.d`,
persisting via the existing C01 `OverlayWriter`), for any decision to route
`domain.topical_tags`'s own caller-supplied `language` parameter from this
module's output, and for the broader ~25-language, 13-script-family roadmap
recorded in #34's own next-slice contract (Han/Chinese, Japanese, Korean,
Arabic script, Cyrillic, Thai remain untouched) — none of that is decided or
touched here. Per this slice's accepted contract, the recorded roadmap order
(script-family-detection front end before Brahmic) was deliberately skipped
in favor of doing Brahmic now, on the owner-approved grounds that these 6
scripts are fully disjoint Unicode blocks from each other and from Latin, so
the existing per-language `distanceTo` scoring already discriminates
correctly by construction — see "Notes: roadmap-sequencing deviation" in the
accepted contract on issue #299 for the full disclosure.

## Files

- `source/domain/language_id.d` — the classifier, identity, encoder/decoder,
  and `routeLanguage`.
- `experiments/language_id/generate_profiles.d` — the deterministic,
  network-free profile-table generator, also usable as a library by the
  checker.
- `experiments/language_id/check.d` — release-active D checker: provenance
  (seed-corpus digests, generator reproducibility, seed/held-out
  disjointness), goldens (including this slice's virama/nukta and
  script-gate-widening goldens below), the full 17x17 held-out confusion
  matrix (with separately surfaced Romance and Brahmic sub-tables, plus a
  disclosed cross-family confusion count), the excluded-neighbor abstention
  probes, decoder rejection, a privacy boundary, and a benchmark matrix.
- `experiments/language_id/fixtures/profiles/<lang>.txt` for
  `<lang>` in `en/es/fr/de/pt/it/nl/tr/vi/pl/id/hi/bn/ta/te/gu/pa` — the
  authored seed corpus (twenty original sentences per language) the embedded
  profile tables are generated from. The six added by this slice
  (hi/bn/ta/te/gu/pa) follow the exact same discipline as the original
  eleven.
- `experiments/language_id/fixtures/heldout/<lang>.txt` for the same
  seventeen language codes — a disjoint authored held-out set (ten original
  sentences per language, never copied from the seed corpus) used for the
  confusion-matrix report.
- `experiments/language_id/fixtures/heldout/excluded/{ro,ca-or-gl,sw}.txt` —
  authored "excluded-neighbor" probes: ten original sentences each in
  Romanian, Catalan (the accepted contract's "Catalan-or-Galician" choice —
  Catalan was picked; the file keeps the generic `ca-or-gl` name from the
  contract), and Swahili. These are close linguistic neighbors of Latin-
  script languages now in the supported set, but are themselves **not**
  supported; see "Excluded-neighbor abstention" below. Not extended by this
  slice — script-block disjointness makes an analogous excluded-neighbor
  probe unnecessary for the 6 new Brahmic languages (see "Non-goals" below).
- This document.

Rollback is deleting these files; no existing job, source shard, or other
stored state changes, and no later job references this module until a
separately authorized shipping landing exists.

## Algorithm

Cavnar & Trenkle-style out-of-place character-n-gram rank distance
(n=1..4), unchanged by this slice. Chosen over single-character frequency
(rejected: these languages share alphabets/scripts with heavily overlapping
letter-frequency distributions within their own family, giving poor
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

**This slice's required word-boundary fix.** "Maximal run of Unicode
letters" is defined by `std.uni.isAlpha`, which follows Unicode's derived
`Alphabetic` property — true for ordinary letters and, usefully, also true
for Devanagari-family dependent vowel signs (matras, e.g. Devanagari `ा`/
`ि`/`ी`), anusvara, candrabindu, and visarga, so those already tokenized
correctly with no change needed. But `isAlpha` is `false` for two mark
categories that are common inside real words in these 6 scripts: the
virama/halant sign (Devanagari `U+094D`, Bengali `U+09CD`, Gurmukhi `U+0A4D`,
Gujarati `U+0ACD`, Tamil "pulli" `U+0BCD`, Telugu `U+0C4D`), which suppresses
a consonant's inherent vowel to form a conjunct cluster, and the nukta sign
(Devanagari `U+093C`, Bengali `U+09BC`, Gurmukhi `U+0A3C`, Gujarati `U+0ABC`
— Tamil and Telugu have no nukta code point in Unicode at all, so there is
no nukta case for those two scripts), which modifies a base consonant for
loanword sounds. Without a fix, `wordsOf` treats both as word separators and
fragments real conjunct/loanword words into multiple pieces — mechanically
confirmed against the accepted contract's own example, Hindi क्षत्र
("kṣatra", 2 viramas), which fragmented into 3 pieces under the pre-fix
logic. The fix adds a private `isWordInternalJoiner` predicate (the same
hardcoded-Unicode-range/codepoint idiom `isLatinLetter` already uses) for
exactly these 10 code points, and `wordsOf`'s per-codepoint test becomes
`isAlpha(c) || isWordInternalJoiner(c)`; a joiner is appended to the current
word exactly like a letter (case-folding via `toLower` is a no-op for these
code points), so it never terminates a word and is never dropped. See the
"virama/nukta word-internal-joiner" unit test in
`source/domain/language_id.d` (all 6 scripts' virama cases and all 4
scripts' nukta cases, tested directly against the private `wordsOf`) and the
corresponding golden in `experiments/language_id/check.d` (proven through
the public
`totalNgramCount` instead, since `wordsOf` itself is private).

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
   - `hi`: `c152bc8517da47a937e7456dc1a7b1512b2102f177e32cc8ca6c50fba60c9298`
   - `bn`: `b0cdb273e478c80e85de975b25eb28540f8edab0feb8576f0bbf98d11feb9d98`
   - `ta`: `35e7e0bf89a29c7efd0f57e37ccaae8f25151f1d7c7492e89f9f0ef3c5459f63`
   - `te`: `7577c6a401a0498f73316a1949362ef2fcee0595752223fc0dd53225d94cd43d`
   - `gu`: `69544e75d7781ddb86d2cdf3214ec87b8031b43bdb87de35fafd23fd72089ccd`
   - `pa`: `12ed2f313da2a0b4d7566e62238c3cb69f9cf8e6c52553e9087ffdb65da531f3`
2. **Deterministic generator.** `experiments/language_id/generate_profiles.d`
   reads the seed corpus and calls `domain.language_id.rankedNgramProfile` —
   the exact same pure function the production module exposes — to produce
   each language's ranked n-gram table. There is only one ranking algorithm
   to drift, because the generator and the checker both call it directly
   rather than re-implementing it. The result is embedded as the
   `static immutable string[] languageProfileEn/Es/Fr/De/Pt/It/Nl/Tr/Vi/Pl/Id/
   Hi/Bn/Ta/Te/Gu/Pa` tables in `source/domain/language_id.d`, mirroring
   `effects.html_main_content`'s fixed drift-checked table idiom. `check.d`'s
   `generatorReproducibilityProof` re-runs the generator (twice, to also
   confirm run-to-run determinism) and asserts byte-identical output against
   those embedded tables — the drift-detection proof this contract requires,
   now covering all seventeen languages. `rankedNgramProfile` calls the same
   `wordsOf` this slice fixed for virama/nukta joiners, so the six new
   Brahmic tables were generated through the corrected tokenizer from the
   start, not regenerated after a separate fix. To regenerate after an
   intentional seed-corpus change:
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
   seventeen languages. `heldOutConfusionMatrix` then reports (and, per this
   codebase's usual exact-digest reproducibility convention, pins as a
   golden rather than treating as a soft/statistical assertion) the
   per-language confusion matrix and abstention counts over that held-out
   set — currently 166/170 correct, 0 misclassified, 4 abstained (2
   Portuguese and 2 Dutch held-out lines, both via `mixedOrAmbiguous`,
   unchanged from the 11-language slice; all 6 new Brahmic languages'
   held-out lines classify correctly with 0 abstentions). This is small
   authored boundary evidence only, **not** a web-scale, universal-
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

   **Brahmic sub-table (hi/bn/ta/te/gu/pa), added by this slice.** Mirroring
   the Romance precedent, the cross-confusion cells among these six new
   languages are computed and printed as their own separate 6x6 sub-table,
   even though they are new to each other (unlike the Romance case, they are
   not close linguistic relatives sharing a script — each occupies its own
   disjoint Unicode block). At the currently embedded profile tables, this
   sub-table's off-diagonal cross-Brahmic-confusion total is **0**: every
   held-out line for all 6 languages classifies correctly as its own
   language, with 0 abstentions.

   **Cross-family confusion, added by this slice.** Per the accepted
   contract's own framing, script-block disjointness is expected to fully
   discriminate the Latin and Brahmic families — a document's n-grams from
   one script trivially fail to match a profile built from a disjoint
   script's codepoints, since every one of a document's n-grams absent from
   a profile incurs `distanceTo`'s maximal out-of-place penalty. `check.d`
   computes this directly rather than asserting it from theory: of all 170
   held-out lines, **zero** Latin-family lines predict as a Brahmic language
   and zero Brahmic-family lines predict as a Latin language. This confirms
   the expected-by-design separation is real, not merely assumed.

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
`vi`/`pl`/`id`/`hi`/`bn`/`ta`/`te`/`gu`/`pa` — the six Brahmic-family
languages this slice adds (`hi`/`bn`/`ta`/`te`/`gu`/`pa`, values `11`-`16`)
are appended after the eleven Latin-script languages, so the wire byte value
of every existing supported language is unchanged) and the relative,
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
  Re-derived for a Brahmic language (Hindi) by this slice's
  `brahmicShortTextBoundaryGolden` in `experiments/language_id/check.d`,
  using the identical `4*L + 2` formula with joiner-inclusive word lengths
  (see the word-boundary fix above) — the boundary is still exact.
- `unsupportedScript` — a cheap pre-check, run before any n-gram scoring:
  if more than `nonLatinScriptBound` (30%) of the text's Unicode letters are
  outside the script ranges this module recognizes, abstain rather than
  force-fit unrecognized-script text into this classifier. The prior slice's
  required fix added Latin Extended Additional (`U+1E00`-`U+1EFF`) for
  Vietnamese, in addition to the original Basic Latin, Latin-1 Supplement,
  and Latin Extended-A/B (many of Vietnamese's precomposed tone-marked
  vowels, e.g. `ệ`, `ọ`, `ữ`, `ả`, `ạ`, `ỹ`, live in that block — see the
  "Vietnamese diacritic density" golden in
  `experiments/language_id/check.d`).

  **This slice's required second code fix (found during grooming, beyond
  the original ticket's ask).** The virama/nukta word-boundary fix above is
  necessary but not sufficient on its own: `detectLanguage`'s
  `unsupportedScript` pre-check runs *before* `wordsOf` is ever reached, and
  under the pre-fix `isLatinLetter`-only gate, every Devanagari-family
  document measured 100% non-Latin letters — far past the 30% bound — so it
  would abstain here regardless of the word-boundary fix, shipping dead
  code. The fix adds a private `isBrahmicLetter` helper (the same
  hardcoded-Unicode-range idiom `isLatinLetter` uses) covering the 6 new
  scripts' real Unicode blocks — Devanagari (`0x0900`-`0x097F`), Bengali
  (`0x0980`-`0x09FF`), Gurmukhi (`0x0A00`-`0x0A7F`), Gujarati
  (`0x0A80`-`0x0AFF`), Tamil (`0x0B80`-`0x0BFF`), Telugu
  (`0x0C00`-`0x0C7F`) — deliberately excluding the immediately adjacent
  Oriya (`0x0B00`-`0x0B7F`) and Kannada (`0x0C80`-`0x0CFF`) blocks, which are
  out of scope for this slice. `scriptCountsOf`'s per-letter test changed
  from "is Latin" to "is Latin or is recognized-Brahmic" when deciding what
  counts toward the abstention fraction. Verified directly, both ways:
  `isBrahmicLetter`'s own unit test in `source/domain/language_id.d` probes
  every recognized range's boundaries plus the adjacent Oriya/Kannada
  boundaries (both ends of each, both just-inside and just-outside), and
  `experiments/language_id/check.d`'s `brahmicScriptGateGolden` proves a
  plain Devanagari sentence now reaches scoring instead of abstaining, while
  its `scriptAbstentionGolden` re-confirms both the existing Cyrillic
  (Russian) case *and* a new authored Kannada sentence — immediately
  adjacent to Telugu's block — both still correctly abstain, proving the
  widening is additive (Latin plus exactly these 6 Brahmic scripts), not a
  general loosening.
- `mixedOrAmbiguous` — the best and second-best language's out-of-place
  distances are within the applicable margin bound of each other; the two
  top candidates are too close to call. `mixedMarginBound` (2% of the
  worst-case distance) is the default, tightened to 4% specifically when the
  winning candidate is French — see "Excluded-neighbor abstention" below
  (issue #34). This slice adds
  a mixed-*script* golden (`mixedScriptGolden` in
  `experiments/language_id/check.d`) alongside the existing mixed-*language*
  (English/Spanish) golden: an authored sentence blending an English clause
  with a roughly
  balanced Hindi/Devanagari clause abstains via `mixedOrAmbiguous`, proving
  the existing mixed-language mechanism generalizes to mixed-script text
  without a bespoke new mechanism.
- `belowConfidenceThreshold` — the best candidate clears the margin check
  above but its own relative confidence is still below the applicable
  confidence floor: `internalConfidenceFloor` (0.15) by default, or a
  tighter per-target-language override from `confidenceFloorFor` — see
  "Excluded-neighbor abstention" below (issue #34's threshold-tightening
  fix). This is an **internal** detection floor, independent of
  `routeLanguage`'s caller-supplied external threshold described next.

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
  probes not cleanly abstaining at the original single global thresholds)
  — issue #34's 2026-09-30 owner decision was to close this by tightening
  further, via per-target-language threshold overrides. Romanian and
  Swahili are now fully closed; Catalan has a disclosed, verified-
  irreducible residual. See "Excluded-neighbor abstention" immediately
  below for the full disclosure and specific numbers, flagged here per the
  same contract instruction.

`nonLatinScriptBound` (0.3), `mixedMarginBound` (0.02, the default margin
bound), and `internalConfidenceFloor` (0.15, the default confidence floor)
are ordinary implementation constants, tuned against the same small
authored fixture set described above and documented here for transparency,
but were not separately called out for sign-off by the contract. Issue #34
additionally pins three per-target-language overrides of the latter two
(`confidenceFloorFor`/`marginBoundFor` in `source/domain/language_id.d`) —
see "Excluded-neighbor abstention" below for the exact values and the
verification behind each one.

### Excluded-neighbor abstention: tightened per target language (issue #34)

This is the direct successor to the first slice's German-vs-Dutch
disclosure (that specific pair is now resolved: Dutch is supported). The
same structural problem recurred, probed deliberately, per the accepted
contract, against three close linguistic neighbors of the eleven supported
Latin-script languages that are themselves **not** supported: Romanian
(close to the Romance cluster), Catalan (very close to Spanish; the
contract's "Catalan-or-Galician" choice — Catalan was picked here; see
`experiments/language_id/fixtures/heldout/excluded/ca-or-gl.txt`), and
Swahili (probed as a more distant, non-Indo-European control).

**A single global threshold cannot fix this.** The lowest genuine
confidently-detected supported-language held-out confidence across the full
170-line held-out set is **~0.263** (Telugu), only ~0.008 above the weakest
excluded-neighbor force-classification (Swahili at 0.271 as Indonesian).
Raising either `internalConfidenceFloor` or `mixedMarginBound` globally at
all would cause regression before fixing anything — this matches the first
tuning attempt's finding from the Brahmic slice, sharpened once the full
17-language held-out set was available.

**Issue #34's owner decision (2026-09-30)** was to fix this by tightening
the confidence threshold further, explicitly choosing that over adding a
closely-related-language heuristic (detecting *which* unsupported language
the text is) or accepting the disclosed risk as-is. The mechanism:
`confidenceFloorFor`/`marginBoundFor` in `source/domain/language_id.d`
key the existing threshold checks on the already-computed winning candidate
(`scored[0].language`) instead of a single scalar, each override chosen to
sit strictly between the highest excluded-neighbor force-classification
value it must catch and the lowest genuine-correct held-out value for that
same target language — so raising it cannot regress any currently-correct
held-out classification. Verified two ways: directly, against the full
sorted per-target-language confidence/margin distributions over the 170-line
held-out set; and empirically, by confirming the held-out confusion-matrix
golden (166/170 correct, 0 misclassified, 4 abstained) is unchanged before
and after the change.

The three overrides:

- **`it` (confidence floor 0.33, default 0.15)**: catches Romanian's
  it-target force-classification (confidence 0.286). Genuine Italian
  held-out minimum confidence is 0.374 — real headroom (~0.044) on both
  sides.
- **`id` (confidence floor 0.35, default 0.15)**: catches all three of
  Swahili's id-target force-classifications (confidences 0.271, 0.279,
  0.308). Genuine Indonesian held-out minimum confidence is 0.397 — real
  headroom (~0.045-0.09) on both sides.
- **`fr` (margin bound 0.04, default 0.02)**: Romanian's fr-target
  force-classification (confidence 0.366) sits only ~0.003 below the
  genuine French held-out confidence minimum (0.369) — too thin a gap in
  confidence space to tighten robustly. Its raw margin (0.026), however,
  sits comfortably below the genuine French held-out margin minimum
  (0.051) — real headroom (~0.011-0.025) — so the margin side of the
  threshold logic, not the confidence side, is what closes this case.

Post-fix outcome, pinned by `excludedNeighborAbstentionGoldens`:

- **Romanian**: **10/10 probe lines abstain; 0/10 force-classify — full
  fix.** (Was 8/10 abstain, 2/10 force-classify: Italian at 0.286, French
  at 0.366.)
- **Swahili**: **10/10 probe lines abstain; 0/10 force-classify — full
  fix.** (Was 7/10 abstain, 3/10 force-classify: Indonesian at
  0.271-0.308.)
- **Catalan**: **unchanged — 4/10 abstain; 6/10 force-classify** (1 as
  Italian at confidence 0.400, 5 as Spanish at confidence 0.407-0.427).
  This is a disclosed, verified-irreducible residual gap, not a silently
  accepted or silently invented fix:
  - The it-target case (0.400) sits *above* the genuine Italian held-out
    minimum (0.374); no it-target confidence or margin floor can catch it
    without also newly abstaining 4 genuine Italian held-out lines
    (confidences 0.374, 0.381, 0.390, 0.394).
  - All five es-target cases (0.407-0.427) sit *above* the genuine Spanish
    held-out minimum confidence (0.351; second-lowest 0.371); no es-target
    confidence floor can catch any of them without regression. The same
    check in margin space also fails to cleanly separate: two of the five
    es-target margins (0.028, 0.035) sit below the genuine Spanish margin
    minimum (0.051) and could technically be caught, but only with a floor
    within ~0.0003-0.001 of that genuine minimum — razor-thin, and the
    other three es-target margins (0.050, 0.058, 0.060) remain uncatchable
    regardless. Forcing that fragile a partial fix would fit the specific
    residual fixture lines rather than reflect a real, robust separation,
    so it was not done.

`unsupportedScript` does not help here (all three probe languages are plain
Latin script within the recognized ranges). This Catalan residual is
flagged here for owner sign-off, the same way the original German-vs-Dutch
0.315/0.316 finding, and the pre-fix Catalan 60% finding itself, both
were.

**Not extended to the 6 new Brahmic languages by this slice.** Per the
accepted contract, the excluded-neighbor mechanism exists to catch close
*statistical* neighbors of a supported language sharing the *same*
script/alphabet (e.g. Catalan vs. Spanish, both Latin script). Script-block
disjointness is a structurally different and much stronger discriminator:
a document in an unsupported Brahmic-adjacent or altogether different
script either falls outside all 6 recognized Brahmic ranges (and abstains
via `unsupportedScript`, as confirmed for Kannada above) or, if it somehow
shared a script family with a supported language, would need its own
authored probe corpus in that language to test — not attempted here, since
no such close non-supported neighbor in these 6 specific scripts was
identified during grooming. The nearest analogous risk for this slice is
the cross-family confusion count in "Provenance" above, which is measured
at exactly 0.

## Wire format

**No shape change; the recognized `language` byte range widens.**
`encodeLanguageIdentity`/`decodeLanguageIdentity`: a canonical fixed-field
layout (domain tag, schema version, document ID, text revision, profile
table identity, algorithm version, status, language, per-mille confidence,
abstention reason) plus a whole-record SHA-256 checksum trailer, directly
mirroring `domain.topical_tags`'s `encodeTopicalTags`/`decodeTopicalTags`
idiom, unchanged by this slice. The `language` field is still a single byte;
it now additionally accepts the six new `SupportedLanguage` values
(`11`-`16`) on top of the eleven Latin-script values (`0`-`10`), with
`SupportedLanguage.max` now `16`. `decodeLanguageIdentity` binds to a
caller-supplied `expectedId`/`expectedTextRevision` obtained independently
(e.g. a future C01 join), so a record cannot silently attach to another
document or revision; it also re-validates the profile-table identity
against the currently embedded tables (which changed with this slice's six
new profiles, so a record built under the eleven-language tables is
correctly rejected as a profile-table mismatch), rejecting a record built
under a different profile version. Truncation, trailing data, and any
single-byte corruption anywhere in the record are all rejected.

## Proof (release-active checker)

`experiments/language_id/check.d`:

- **Seed-corpus digests** — pinned SHA-256 per language, all seventeen
  (above).
- **Generator reproducibility** — the byte-identical drift-detection proof
  described under Provenance, run twice for run-to-run determinism, now
  covering all seventeen embedded tables.
- **Seed/held-out disjointness** — zero exact-line overlap, both corpora
  above their expected minimum sizes, across all seventeen languages.
- **Boundary goldens** — the exact `tooShort` cutoff transition (58 vs. 60
  total n-grams) for English, plus empty/oversize/invalid-UTF-8 abstention
  (unchanged `minNgramCount == 60`); re-derived separately for Hindi (see
  next item).
- **Brahmic short-text boundary golden** — the identical 58-vs-60 `tooShort`
  transition re-derived for Hindi (`brahmicShortTextBoundaryGolden`), using
  plain short Devanagari words and the same `4*L + 2` formula, proving the
  boundary is still exact with joiner-inclusive word lengths.
- **Script-abstention golden** — an authored Russian (Cyrillic) sentence,
  and this slice's authored Kannada sentence (immediately adjacent to
  Telugu's recognized block), both abstain via `unsupportedScript` —
  confirming `isBrahmicLetter`'s widening is additive, not a general
  loosening.
- **Vietnamese diacritic-density golden** — an authored, deliberately dense
  Vietnamese sentence (~30.1% of its letters in Latin Extended Additional)
  is correctly detected as Vietnamese (unchanged from the prior slice).
- **Virama/nukta word-internal-joiner golden** (this slice's required fix
  #1) — the accepted contract's own example, Hindi क्षत्र (2 viramas),
  proven via the public `totalNgramCount` to round-trip as one 6-codepoint
  word (26 total n-grams), not the 3-fragment pre-fix count (22). All 6
  scripts' virama cases and all 4 scripts' nukta cases are additionally
  tested directly against the private `wordsOf` in
  `source/domain/language_id.d`'s own unit test.
- **Brahmic script-gate widening golden** (this slice's required fix #2,
  found during grooming) — a plain, ordinary-length Devanagari sentence must
  not abstain via `unsupportedScript` and must reach scoring, classifying
  correctly as Hindi (`brahmicScriptGateGolden`). `isBrahmicLetter`'s own
  Oriya/Kannada boundary-codepoint unit test lives in
  `source/domain/language_id.d` (private helper).
- **Mixed-language golden** — an authored English/Spanish blend abstains via
  `mixedOrAmbiguous`.
- **Mixed-script golden** (new territory this slice adds) — an authored
  English/Hindi (Latin/Devanagari) blend also abstains via
  `mixedOrAmbiguous` or `belowConfidenceThreshold` (`mixedScriptGolden`),
  proving the existing mixed-language mechanism generalizes to mixed-script
  text.
- **Excluded-neighbor abstention goldens** — the Romanian/Catalan/Swahili
  probes described above (unchanged by this slice; not extended to
  Brahmic — see "Excluded-neighbor abstention"), with the exact observed
  abstain/force-classify counts pinned per probe language and every
  force-classified line's confidence disclosed in the checker's own output.
- **Threshold-routing goldens** — `routeLanguage` at, above, and below one
  exact declared threshold, plus the always-unrouted abstained case.
- **Full 17x17 held-out confusion matrix**, with the Romance (es/fr/it/pt)
  and, added by this slice, Brahmic (hi/bn/ta/te/gu/pa) sub-tables each
  printed as their own separate, explicitly reviewed block, plus a disclosed
  cross-family (Latin vs. Brahmic) confusion count — described under
  Provenance.
- **Identity and decoder rejection** — round trip, wrong document/revision,
  truncation, trailing data, and every single byte of one fixture's encoded
  record corrupted and confirmed rejected.
- **Exhaustive `SupportedLanguage` wire round trip** — every one of the
  seventeen enum values (including the six added by this slice)
  independently round-trips through encode/decode, and a hand-constructed
  record with the language byte set to `SupportedLanguage.max + 1` (`17`,
  with an otherwise-correct checksum, isolating the range-check path from
  the checksum check) is rejected.
- **Privacy boundary** — a synthetic canary embedded in input text is
  confirmed absent from the encoded record; only the bounded language code,
  per-mille confidence, and abstention reason travel.
- **Benchmark matrix** — a D-only child-process matrix over `many-small`
  (64 documents) and `few-large` (4 documents) shapes at the same total
  512 KiB of synthetic text, now re-run at the seventeen-language embedded
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
accuracy claim — the held-out split above is 170 authored sentences across
seventeen languages. Not coverage of any script beyond these two families
(11 Latin-script languages, 6 Brahmic-family languages): no Han/Japanese/
Korean/Arabic script/Cyrillic/Thai work is included or referenced by code
here, and Kannada and Malayalam (other Brahmic-family scripts, noted as
likely-same-virama-pattern but explicitly not verified) are also out of
scope — that is a separate, not-yet-scoped future research track (see the
~25-language, 13-script-family roadmap recorded in #34's own next-slice
contract). Not a script-family-detection front-end rework — the gate
structure from the first slice (now a small closed set of recognized script
families: Latin, plus these 6 Brahmic scripts) is otherwise unchanged; see
"Status" above for the explicit, owner-approved roadmap-sequencing deviation
this slice took (Brahmic before the general front end). Not a guarantee
that the excluded-neighbor mechanism achieves zero false-classification for
languages outside the supported set — see "Excluded-neighbor abstention"
above, including why that mechanism was not extended to the 6 new Brahmic
languages. Not HTML parsing, a dedicated CLI subcommand/flag, or any
local/JSONL/durable/overlay publication path — those remain out of scope
for this module. Issue #311's `language-id-detect` terminal stage (see
"Status" above) gives the ordinary shipping binary a real, minimal
`run --stage id=language-id-detect` reachability path — a pure consumer of
this module's unmodified `buildLanguageIdentity`/`encodeLanguageIdentity`,
not a change to this module itself or to its algorithm/thresholds. Not a
change to `domain.topical_tags`'s existing `language` parameter — whether or
how a later slice wires this module's output into that parameter is an
explicitly deferred integration decision, not made here. Not a change to
`routeLanguage`, the wire record layout, or the `LanguageIdentity`/
`LanguageIdentityRecord` shapes — only `SupportedLanguage` widens.
