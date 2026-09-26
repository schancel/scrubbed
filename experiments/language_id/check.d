/// Release-active D checker for `domain.language_id`. Pins seed-corpus
/// provenance, profile-generator reproducibility, seed/held-out
/// disjointness, a held-out confusion matrix, boundary/script/mixed/
/// threshold-routing goldens, wire round-trip and decoder rejection, a
/// privacy boundary, and a descriptive bounded-cost benchmark matrix. Only
/// reads files under experiments/language_id/fixtures/** (authored,
/// synthetic, no third-party bytes). Not published; no committed report
/// file.
module experiments.language_id.check;

import domain.document : DocumentId, SourceLocator;
import domain.language_id;
import experiments.language_id.generate_profiles : generateProfiles;
import crypto.sha256 : sha256Of;
import core.memory : GC;
import core.sys.posix.sys.resource : RUSAGE_CHILDREN, getrusage, rusage;
import std.algorithm.searching : canFind, startsWith;
import std.array : appender, replicate;
import std.conv : to;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.digest : LetterCase, toHexString;
import std.exception : collectException;
import std.file : readText, thisExePath;
import std.format : format;
import std.path : buildPath;
import std.process : execute;
import std.stdio : writefln, writeln;
import std.string : splitLines, strip;

private void check(bool okay, string reason) {
    if (!okay) throw new Exception("language id check: " ~ reason);
}

private string hex(const(ubyte)[] bytes) {
    return toHexString!(LetterCase.lower)(bytes).idup;
}

private void rejects(scope void delegate() action) {
    bool rejected;
    try action(); catch (Exception) rejected = true;
    check(rejected, "expected rejection");
}

private DocumentId docId(string key) {
    return DocumentId.from(SourceLocator("language-id-check-v1", "fixture", key));
}

private enum fixturesRoot = buildPath("experiments", "language_id", "fixtures");
private enum profilesRoot = buildPath(fixturesRoot, "profiles");
private enum heldoutRoot = buildPath(fixturesRoot, "heldout");

// ---------------------------------------------------------------------------
// Provenance step 1: the authored seed corpus, pinned by exact SHA-256. Any
// edit to a seed file — intentional or not — changes this digest before it
// can silently change the embedded profile tables below.
// ---------------------------------------------------------------------------

private void seedCorpusDigestGoldens() {
    static immutable string[string] expected = [
        "en": "954da4ffee2e892640beee2156fcdf360cdf2337f8942c1b905f1266c32c5c4d",
        "es": "6e214c192b097d8256f903f629d015c8c44e4c6f48238e9863e0716a8073eb1a",
        "fr": "2a2a9acdabe731c4de0f8d2b1c422c91c00b64c1040915443939027086113bd4",
        "de": "9d6809f05bce2a3177cf452ee3a4dc885e47137c18fe8ed3d81355dc4b903bf3",
        "pt": "f55d793d4195f602b868a2073e95c8861e42ba421759b1ec8df33bec4b1cedd6",
        "it": "515835c6504354ec6cbcf5f6ef5b2d45f52649058eb6ec8b4602c6b59bd6cab5",
        "nl": "7a3088dcd30178260a0d5312eb8c50ac9c37f79ba1d0866a4cd3b8fc76d0c6c1",
        "tr": "f1153bf5eff5f4a94eb0a54918c02ff3070962581221e3a5a06e7f7b45b3a190",
        "vi": "5678ca971c0618768b2ed9fe1148bae04c53b326f473cefab2c624e8f01f7dbb",
        "pl": "f092baf804251c945dfd46147f47beb013cc84d1cbda5c32ad2f8196ca236fbc",
        "id": "1dea1af4e267f318badb549428904a3c6a4ea9b2c4f40f13074dcc97994c32b8",
    ];
    foreach (lang, digest; expected) {
        auto bytes = cast(const(ubyte)[]) readText(buildPath(profilesRoot, lang ~ ".txt"));
        check(hex(sha256Of(bytes)) == digest, "seed corpus digest drifted for " ~ lang);
    }
}

// ---------------------------------------------------------------------------
// Provenance step 2: the drift-detection proof. Re-running the deterministic
// generator against the checked-in seed corpus must reproduce, byte for
// byte, the tables embedded in `source/domain/language_id.d`.
// ---------------------------------------------------------------------------

private void generatorReproducibilityProof() {
    auto generated = generateProfiles(profilesRoot);
    check(generated.en == languageProfileEn, "embedded English profile drifted from the generator");
    check(generated.es == languageProfileEs, "embedded Spanish profile drifted from the generator");
    check(generated.fr == languageProfileFr, "embedded French profile drifted from the generator");
    check(generated.de == languageProfileDe, "embedded German profile drifted from the generator");
    check(generated.pt == languageProfilePt, "embedded Portuguese profile drifted from the generator");
    check(generated.it == languageProfileIt, "embedded Italian profile drifted from the generator");
    check(generated.nl == languageProfileNl, "embedded Dutch profile drifted from the generator");
    check(generated.tr == languageProfileTr, "embedded Turkish profile drifted from the generator");
    check(generated.vi == languageProfileVi, "embedded Vietnamese profile drifted from the generator");
    check(generated.pl == languageProfilePl, "embedded Polish profile drifted from the generator");
    check(generated.id == languageProfileId, "embedded Indonesian profile drifted from the generator");
    // Reproducibility, not just single-run agreement: a second independent
    // run of the generator must produce the exact same tables again.
    auto generatedAgain = generateProfiles(profilesRoot);
    check(generatedAgain.en == generated.en && generatedAgain.es == generated.es &&
        generatedAgain.fr == generated.fr && generatedAgain.de == generated.de &&
        generatedAgain.pt == generated.pt && generatedAgain.it == generated.it &&
        generatedAgain.nl == generated.nl && generatedAgain.tr == generated.tr &&
        generatedAgain.vi == generated.vi && generatedAgain.pl == generated.pl &&
        generatedAgain.id == generated.id,
        "generator is not deterministic across repeated runs");
}

// ---------------------------------------------------------------------------
// Provenance step 3: the held-out set is disjoint from the seed corpus —
// zero exact-string (line) overlap in either direction, checked globally
// across all four languages.
// ---------------------------------------------------------------------------

private string[] linesOf(string path) {
    string[] lines;
    foreach (line; readText(path).splitLines()) {
        auto trimmed = line.strip();
        if (trimmed.length != 0) lines ~= trimmed;
    }
    return lines;
}

private enum supportedLangCodes = ["en", "es", "fr", "de", "pt", "it", "nl", "tr", "vi", "pl", "id"];

private SupportedLanguage langCodeToEnum(string code) {
    switch (code) {
        case "en": return SupportedLanguage.en;
        case "es": return SupportedLanguage.es;
        case "fr": return SupportedLanguage.fr;
        case "de": return SupportedLanguage.de;
        case "pt": return SupportedLanguage.pt;
        case "it": return SupportedLanguage.it;
        case "nl": return SupportedLanguage.nl;
        case "tr": return SupportedLanguage.tr;
        case "vi": return SupportedLanguage.vi;
        case "pl": return SupportedLanguage.pl;
        case "id": return SupportedLanguage.id;
        default: assert(0, "unknown supported language code: " ~ code);
    }
}

private void disjointnessProof() {
    string[] seedLines;
    string[] heldoutLines;
    foreach (lang; supportedLangCodes) {
        seedLines ~= linesOf(buildPath(profilesRoot, lang ~ ".txt"));
        heldoutLines ~= linesOf(buildPath(heldoutRoot, lang ~ ".txt"));
    }
    check(seedLines.length >= 220, "seed corpus suspiciously small");
    check(heldoutLines.length >= 110, "held-out corpus suspiciously small");
    size_t overlap;
    foreach (seedLine; seedLines) foreach (heldoutLine; heldoutLines)
        if (seedLine == heldoutLine) ++overlap;
    check(overlap == 0, "seed corpus and held-out set share at least one exact sentence");
}

// ---------------------------------------------------------------------------
// Short-text boundary goldens at the pinned `tooShort` cutoff
// (`minNgramCount == 60`). Both fixtures are ordinary short English word
// sequences, not degenerate repeated characters, so the transition is
// driven purely by the pinned count, not by an unrelated ambiguity/
// confidence abstention firing first. `totalNgramCount` (also exposed by
// the production module) proves the exact n-gram count each fixture
// produces, rather than asserting the boundary text by construction alone.
// ---------------------------------------------------------------------------

private void boundaryGoldens() {
    check(minNgramCount == 60, "tooShort cutoff golden assumes the pinned value 60");

    enum belowCutoff = "the cat dog to a"; // 58 total n-grams: 14+14+14+10+6
    enum atCutoff = "the cat dog wolf";    // 60 total n-grams: 14+14+14+18
    check(totalNgramCount(belowCutoff) == minNgramCount - 2,
        "below-cutoff fixture must land exactly 2 below the pinned cutoff " ~
        "(n-gram occurrence totals are always even)");
    check(totalNgramCount(atCutoff) == minNgramCount,
        "at-cutoff fixture must land exactly on the pinned cutoff");

    auto below = detectLanguage(cast(const(ubyte)[]) belowCutoff);
    check(below.status == LanguageDetectionStatus.abstained &&
        below.reason == LanguageAbstentionReason.tooShort,
        "text one increment below the pinned tooShort cutoff must abstain via tooShort");

    auto at = detectLanguage(cast(const(ubyte)[]) atCutoff);
    check(at.status != LanguageDetectionStatus.abstained ||
        at.reason != LanguageAbstentionReason.tooShort,
        "text exactly at the pinned tooShort cutoff must not abstain via tooShort");
    check(at.status == LanguageDetectionStatus.detected && at.language == SupportedLanguage.en,
        "at-cutoff fixture golden changed");

    // Empty/oversize/invalid-UTF-8 abstention.
    check(detectLanguage([]).reason == LanguageAbstentionReason.emptyText, "empty text abstention");
    auto oversized = new ubyte[maxLanguageIdTextBytes + 1];
    oversized[] = cast(ubyte) 'a';
    check(detectLanguage(oversized).reason == LanguageAbstentionReason.oversizeText,
        "oversize text abstention");
    check(detectLanguage(cast(const(ubyte)[]) [0xff, 0xfe, 0xfd]).reason ==
        LanguageAbstentionReason.invalidUtf8, "invalid UTF-8 abstention");
}

// ---------------------------------------------------------------------------
// Script-abstention golden: an authored non-Latin (Russian) sentence must
// abstain via `unsupportedScript`, never get force-fit into en/es/fr/de.
// ---------------------------------------------------------------------------

private void scriptAbstentionGolden() {
    // Original, authored-for-this-checker Russian sentence (Cyrillic
    // script), unrelated to any topic elsewhere in this fixture set.
    enum russian = "Сегодня хорошая погода, и мы гуляем в парке рядом с рекой каждое утро.";
    auto result = detectLanguage(cast(const(ubyte)[]) russian);
    check(result.status == LanguageDetectionStatus.abstained &&
        result.reason == LanguageAbstentionReason.unsupportedScript,
        "non-Latin script text must abstain via unsupportedScript, got " ~ result.reason.to!string);
}

// ---------------------------------------------------------------------------
// Vietnamese diacritic-density golden: proves the `isLatinLetter` Latin
// Extended Additional (U+1E00-U+1EFF) range fix required by the accepted
// contract actually works on real Vietnamese text. This authored sentence
// (a short list of intensified adjectives, "rất X" = "very X", a natural
// terse Vietnamese construction) is deliberately dense in precomposed
// tone-marked vowels: 22 of its 73 letters (a fraction of ~0.301, just over
// the pinned `nonLatinScriptBound` of 0.3) fall in U+1E00-U+1EFF and would
// NOT be recognized as Latin letters without the fix, which was confirmed
// by testing this exact sentence against the pre-fix range list: it
// false-abstained via `unsupportedScript`. With the fix, every one of those
// 22 letters is recognized, so the non-Latin fraction (counting only
// genuinely non-Latin scripts, e.g. Cyrillic in the golden above) is 0, and
// the text is correctly detected as Vietnamese.
// ---------------------------------------------------------------------------

private void vietnameseDiacriticDensityGolden() {
    enum vietnamese = "Rất mệt, rất sợ, rất tệ, rất dữ, rất khổ, rất chán, rất giận, rất buồn, " ~
        "rất nhớ, rất kém, rất gấp, rất chật.";
    auto result = detectLanguage(cast(const(ubyte)[]) vietnamese);
    check(result.status == LanguageDetectionStatus.detected && result.language == SupportedLanguage.vi,
        "dense Vietnamese diacritic text must be detected as Vietnamese via the isLatinLetter " ~
        "Latin Extended Additional fix, got status=" ~ result.status.to!string ~
        " reason=" ~ result.reason.to!string);
}

// ---------------------------------------------------------------------------
// Mixed-language golden: text blending two supported languages roughly
// evenly must abstain via `mixedOrAmbiguous`, never arbitrarily pick one.
// ---------------------------------------------------------------------------

private void mixedLanguageGolden() {
    // Authored blend of English and Spanish clauses, deliberately balanced
    // so neither profile clearly wins.
    enum mixed = "The cat sat quietly pero el perro corrio muy rapido.";
    auto result = detectLanguage(cast(const(ubyte)[]) mixed);
    check(result.status == LanguageDetectionStatus.abstained &&
        result.reason == LanguageAbstentionReason.mixedOrAmbiguous,
        "balanced bilingual text must abstain via mixedOrAmbiguous, got " ~ result.reason.to!string);
}

// ---------------------------------------------------------------------------
// Excluded-neighbor abstention probes: Romanian, Catalan (of the accepted
// Catalan-or-Galician choice — see docs/language-id.md), and Swahili are all
// close linguistic neighbors of languages now in the supported 11-language
// set, but are themselves NOT supported. Per the accepted contract, the
// implementation path was: first try tightening via existing constants only
// (`internalConfidenceFloor`, `mixedMarginBound`) validated against these
// probes, before considering any other option.
//
// That tuning attempt was made and is disclosed here rather than silently
// skipped. Sweeping both constants against the actual observed distances
// shows the two distributions structurally overlap and cannot be cleanly
// separated by either constant:
//   - `internalConfidenceFloor` (currently 0.15): the lowest genuine
//     confidently-detected supported-language held-out confidence is 0.273
//     (Vietnamese). A Swahili probe line force-classifies as Indonesian at
//     confidence 0.271 — BELOW that genuine floor. No single confidence
//     floor value separates the two groups without also abstaining genuine
//     held-out text that is currently correctly classified.
//   - `mixedMarginBound` (currently 0.02): the lowest genuine
//     supported-language margin fraction observed is ~0.0264 (Portuguese/
//     Italian). Excluded-probe margin fractions range from ~0.0213 up to
//     ~0.0603, overlapping that genuine distribution throughout; raising
//     the bound enough to catch the higher excluded-probe margins would
//     also newly abstain most of the genuine low-margin held-out lines
//     above.
// Neither existing constant admits a value that cleanly separates these
// probes from genuine supported-language text, so this checker does not
// force a passing "always abstains" golden here — that would either be
// false or would require inventing a new bespoke mechanism, both excluded
// by the accepted contract. Instead, exactly as the original slice's
// German-vs-Dutch 0.315/0.316 disclosure did, this golden discloses the
// specific observed per-line outcome (abstained vs. force-classified, with
// confidence) and pins the current exact counts as a reproducibility
// golden, for owner sign-off: Romanian 8/10 lines abstain (2/10 force-
// classify: Italian at 0.286, French at 0.366); Catalan 4/10 lines abstain
// (6/10 force-classify, all as Spanish or Italian, confidence 0.400-0.427,
// the worst case observed of the three); Swahili 7/10 lines abstain (3/10
// force-classify as Indonesian, confidence 0.271-0.308).
// ---------------------------------------------------------------------------

private enum excludedNeighborRoot = buildPath(heldoutRoot, "excluded");

private void excludedNeighborAbstentionProbe(string code, string languageName,
        size_t expectedAbstained, size_t expectedForced) {
    size_t abstained, forced;
    writeln("language id check: excluded-neighbor probe ", code, " (", languageName, "):");
    foreach (line; linesOf(buildPath(excludedNeighborRoot, code ~ ".txt"))) {
        auto result = detectLanguage(cast(const(ubyte)[]) line);
        if (result.status == LanguageDetectionStatus.abstained) {
            check(result.reason == LanguageAbstentionReason.mixedOrAmbiguous ||
                result.reason == LanguageAbstentionReason.belowConfidenceThreshold,
                "excluded-neighbor probe abstained via an unexpected reason: " ~ result.reason.to!string);
            ++abstained;
            writeln("  abstain reason=", result.reason, " line=", line);
        } else {
            ++forced;
            writefln("  FORCE-CLASSIFIED lang=%s conf=%.3f line=%s (disclosed, not silently accepted)",
                result.language, result.confidence, line);
        }
    }
    writeln("  ", code, ": abstained=", abstained, " force-classified=", forced,
        " (disclosed for owner sign-off; not gated to full abstention per the accepted contract's ",
        "explicit allowance for this outcome)");
    check(abstained == expectedAbstained && forced == expectedForced,
        "excluded-neighbor probe " ~ code ~ " golden changed");
}

private void excludedNeighborAbstentionGoldens() {
    excludedNeighborAbstentionProbe("ro", "Romanian", 8, 2);
    excludedNeighborAbstentionProbe("ca-or-gl", "Catalan", 4, 6);
    excludedNeighborAbstentionProbe("sw", "Swahili", 7, 3);
}

// ---------------------------------------------------------------------------
// Threshold-routing goldens: `routeLanguage` is exercised directly against
// literal `LanguageDetectionResult` values, at/above/below one exact
// declared threshold, plus the abstained/below-threshold non-routing paths.
// ---------------------------------------------------------------------------

private void thresholdRoutingGoldens() {
    LanguageDetectionResult detected;
    detected.status = LanguageDetectionStatus.detected;
    detected.language = SupportedLanguage.de;
    detected.confidence = 0.5;

    auto atThreshold = routeLanguage(detected, 0.5f);
    check(atThreshold.routed && atThreshold.language == SupportedLanguage.de,
        "a result exactly at the declared threshold must route");

    LanguageDetectionResult above = detected;
    above.confidence = 0.6;
    auto aboveResult = routeLanguage(above, 0.5f);
    check(aboveResult.routed && aboveResult.language == SupportedLanguage.de,
        "a result above the declared threshold must route");

    LanguageDetectionResult below = detected;
    below.confidence = 0.4;
    auto belowResult = routeLanguage(below, 0.5f);
    check(!belowResult.routed, "a result below the declared threshold must not route");

    LanguageDetectionResult abstained;
    abstained.status = LanguageDetectionStatus.abstained;
    abstained.reason = LanguageAbstentionReason.tooShort;
    check(!routeLanguage(abstained, 0.0f).routed,
        "an abstained result must never route, regardless of threshold");
}

// ---------------------------------------------------------------------------
// Held-out confusion matrix and abstention counts. Reported (and pinned as
// an exact reproducibility golden, per this codebase's usual exact-digest
// convention) rather than gated on any externally unaccepted target
// accuracy number. This is small authored boundary evidence, not a
// web-scale or universal-language-coverage claim.
// ---------------------------------------------------------------------------

/// Romance languages most likely to confuse each other, per the accepted
/// next-slice contract: their cross-confusion cells must be explicitly
/// surfaced as their own reviewed sub-table, not folded into the aggregate
/// headline above.
private enum romanceLangCodes = ["es", "fr", "it", "pt"];

private void heldOutConfusionMatrix() {
    // A flat "actual|predictedOrAbstainReason" key avoids relying on nested
    // associative-array auto-vivification for the (rare) key combinations.
    size_t[string] confusion;
    size_t correct, misclassified, abstained, total;
    foreach (lang; supportedLangCodes) {
        auto expected = langCodeToEnum(lang);
        foreach (line; linesOf(buildPath(heldoutRoot, lang ~ ".txt"))) {
            ++total;
            auto result = detectLanguage(cast(const(ubyte)[]) line);
            string predicted;
            if (result.status == LanguageDetectionStatus.detected) {
                predicted = result.language.to!string;
                if (result.language == expected) ++correct; else ++misclassified;
            } else {
                predicted = "abstain:" ~ result.reason.to!string;
                ++abstained;
            }
            auto key = lang ~ "|" ~ predicted;
            if (auto existing = key in confusion) ++(*existing);
            else confusion[key] = 1;
        }
    }
    writeln("language id check: full 11x11 held-out confusion matrix (actual -> predicted/abstain counts):");
    foreach (key, count; confusion) writeln("  ", key, ": ", count);
    writeln("language id check: held-out total=", total, " correct=", correct,
        " misclassified=", misclassified, " abstained=", abstained,
        " (small authored boundary evidence only; not a web-scale or universal-",
        "language-coverage claim)");

    // Romance cross-confusion sub-table (es/fr/it/pt), surfaced separately
    // and explicitly per the accepted contract, not folded into the
    // aggregate above: these four Romance languages are close relatives and
    // the most likely pair to confuse each other. Printed as a full 4x4
    // grid, including zero cells, so every actual x predicted combination is
    // visible even when it never occurred; plus, separately, each Romance
    // language's own abstention count on its held-out set (an abstention is
    // not a cross-Romance misclassification, but is disclosed alongside it
    // for completeness).
    writeln("language id check: Romance sub-table (es/fr/it/pt actual -> es/fr/it/pt predicted; ",
        "own-language diagonal is correct classification, off-diagonal is cross-Romance confusion):");
    size_t romanceCrossConfusion;
    foreach (actual; romanceLangCodes) {
        string row = "  " ~ actual ~ " -> [";
        foreach (predicted; romanceLangCodes) {
            auto count = confusion.get(actual ~ "|" ~ predicted, 0);
            if (predicted != actual) romanceCrossConfusion += count;
            row ~= " " ~ predicted ~ "=" ~ count.to!string;
        }
        size_t romanceAbstained;
        foreach (key, count; confusion)
            if (key.startsWith(actual ~ "|abstain:")) romanceAbstained += count;
        row ~= " ] abstained=" ~ romanceAbstained.to!string;
        writeln(row);
    }
    writeln("language id check: Romance sub-table cross-confusion total (off-diagonal es/fr/it/pt ",
        "misclassified as another es/fr/it/pt language) = ", romanceCrossConfusion,
        " (disclosed for owner attention, not gated to an unaccepted target number)");

    // Pinned as an exact reproducibility golden: the currently embedded
    // profile tables and thresholds produce this exact outcome on this
    // small, disjoint, authored 11-language held-out set. This is not an
    // accuracy target this checker gates future changes on; a deliberate
    // algorithm/threshold/profile change is free to move these numbers, as
    // long as they are updated here deliberately rather than silently
    // drifting. Disclosure: 106/110 correct, 0 misclassified (including 0
    // cross-Romance misclassification), 4 abstained (2 Portuguese, 2 Dutch,
    // both via mixedOrAmbiguous) at the currently embedded profile tables.
    check(total == 110, "held-out fixture size changed");
    check(correct == 106 && misclassified == 0 && abstained == 4,
        "held-out confusion matrix golden changed");
    check(romanceCrossConfusion == 0, "Romance sub-table cross-confusion golden changed");
}

// ---------------------------------------------------------------------------
// Identity, wire round trip, and decoder rejection.
// ---------------------------------------------------------------------------

private void identityAndDecoderGoldens() {
    auto id = docId("record-1");
    auto text = cast(const(ubyte)[]) "This is a plain authored English sentence used for identity testing.";
    auto record = buildLanguageIdentity(id, text);
    check(record.result.status == LanguageDetectionStatus.detected &&
        record.result.language == SupportedLanguage.en, "identity fixture classification changed");

    auto encoded = encodeLanguageIdentity(record);
    auto decoded = decodeLanguageIdentity(encoded, id, record.identity.textRevision);
    check(decoded == record, "encode/decode round trip");
    check(encodeLanguageIdentity(decoded) == encoded, "re-encode determinism");

    // Wrong document/revision identity.
    rejects({ decodeLanguageIdentity(encoded, docId("record-2"), record.identity.textRevision); });
    ubyte[32] wrongRevision = sha256Of(cast(const(ubyte)[]) "different text entirely");
    rejects({ decodeLanguageIdentity(encoded, id, wrongRevision); });

    // Truncation and trailing data.
    rejects({ decodeLanguageIdentity(encoded[0 .. $ - 1], id, record.identity.textRevision); });
    rejects({ decodeLanguageIdentity(encoded[0 .. 10], id, record.identity.textRevision); });
    auto trailing = encoded.dup ~ cast(ubyte) 0;
    rejects({ decodeLanguageIdentity(trailing, id, record.identity.textRevision); });

    // Every byte position corrupted at least once must either round-trip to
    // the same value or be rejected — never silently decode to a
    // *different* valid record.
    size_t rejectedCount, toleratedCount;
    foreach (offset; 0 .. encoded.length) {
        auto corrupt = encoded.dup;
        corrupt[offset] ^= 0xff;
        auto thrown = collectException!Exception(decodeLanguageIdentity(corrupt, id,
            record.identity.textRevision));
        if (thrown !is null) ++rejectedCount; else ++toleratedCount;
    }
    check(rejectedCount == encoded.length, "every single-byte corruption must be rejected");
    check(toleratedCount == 0, "no corrupted byte silently decoded");

    // A record built against a different (but still valid) text has a
    // different text revision and, since abstained results carry no
    // language-specific structure to vary, at least confirms independent
    // identity per document.
    auto otherText = cast(const(ubyte)[]) "Une autre phrase franchement differente pour ce test.";
    auto otherRecord = buildLanguageIdentity(docId("record-3"), otherText);
    check(otherRecord.identity.textRevision != record.identity.textRevision,
        "distinct texts must have distinct text revisions");
}

// ---------------------------------------------------------------------------
// Exhaustive `SupportedLanguage` wire round trip: every one of the eleven
// enum values (including the seven added by this slice) must independently
// round-trip through encode/decode, and the first byte value past the new
// max (eleven) must still be rejected as malformed.
// ---------------------------------------------------------------------------

private void exhaustiveLanguageValueRoundTrip() {
    static immutable SupportedLanguage[] allLanguages = [
        SupportedLanguage.en, SupportedLanguage.es, SupportedLanguage.fr, SupportedLanguage.de,
        SupportedLanguage.pt, SupportedLanguage.it, SupportedLanguage.nl, SupportedLanguage.tr,
        SupportedLanguage.vi, SupportedLanguage.pl, SupportedLanguage.id,
    ];
    check(allLanguages.length == 11, "exhaustive language list golden assumes eleven languages");
    check(SupportedLanguage.max == SupportedLanguage.id, "SupportedLanguage.max golden changed");
    foreach (lang; allLanguages) {
        LanguageDetectionResult result;
        result.status = LanguageDetectionStatus.detected;
        result.language = lang;
        result.confidence = 0.5;
        LanguageIdentityRecord record;
        record.identity.documentId = docId("exhaustive-" ~ lang.to!string);
        record.identity.textRevision = sha256Of(cast(const(ubyte)[]) ("probe text for " ~ lang.to!string));
        record.identity.profileTableIdentity = currentProfileTableIdentity();
        record.identity.algorithmVersion = languageIdAlgorithmVersion;
        record.result = result;
        auto encoded = encodeLanguageIdentity(record);
        auto decoded = decodeLanguageIdentity(encoded, record.identity.documentId,
            record.identity.textRevision);
        check(decoded == record, "exhaustive round trip failed for language " ~ lang.to!string);
    }

    // The byte value one past the new max (`SupportedLanguage.max + 1 == 11`)
    // must still be rejected as a malformed language value. The decoder
    // checks the whole-record checksum before the language-range check, so
    // a raw single-byte corruption of an otherwise-valid encoded record
    // would be caught by the checksum mismatch first, never reaching the
    // range check this golden targets. Instead, the record is built by hand
    // at the exact wire layout `encodeLanguageIdentity` uses, with the
    // language byte set to the invalid value 11 from the start, and a
    // correct checksum computed over that payload — isolating the
    // malformed-language-value rejection path specifically.
    auto overflowId = docId("exhaustive-overflow");
    auto overflowRevision = sha256Of(cast(const(ubyte)[]) "overflow probe text");
    auto payload = appender!(ubyte[]);
    payload.put(cast(const(ubyte)[]) "scrubbed:language-id:v1\0");
    foreach_reverse (shift; [0, 8, 16, 24]) payload.put(cast(ubyte)(languageIdSchema >> shift));
    foreach_reverse (shift; [0, 8, 16, 24]) payload.put(cast(ubyte)(overflowId.text.length >> shift));
    payload.put(cast(const(ubyte)[]) overflowId.text);
    payload.put(overflowRevision[]);
    payload.put(currentProfileTableIdentity()[]);
    foreach_reverse (shift; [0, 8, 16, 24]) payload.put(cast(ubyte)(languageIdAlgorithmVersion >> shift));
    payload.put(cast(ubyte) LanguageDetectionStatus.detected);
    payload.put(cast(ubyte)(SupportedLanguage.max + 1)); // 11: one past the new valid range
    foreach_reverse (shift; [0, 8, 16, 24]) payload.put(cast(ubyte)(500 >> shift));
    payload.put(cast(ubyte) LanguageAbstentionReason.none);
    auto overflowRecordBytes = payload.data ~ sha256Of(payload.data)[];
    rejects({ decodeLanguageIdentity(overflowRecordBytes, overflowId, overflowRevision); });
}

// ---------------------------------------------------------------------------
// Privacy boundary: a distinctive canary string placed in the input text
// must never appear in the encoded wire bytes — only the bounded language
// code, confidence, and abstention reason travel.
// ---------------------------------------------------------------------------

private void privacyBoundary() {
    enum canary = "CANARY-4a2f9d61-do-not-leak";
    auto id = docId("privacy-1");
    auto text = cast(const(ubyte)[]) ("This sentence carries a marker token " ~ canary ~
        " embedded in otherwise plain English prose for a leak scan.");
    auto record = buildLanguageIdentity(id, text);
    auto encoded = encodeLanguageIdentity(record);
    check(!(cast(string) encoded).canFind(canary), "canary text leaked into encoded record");
    check(record.result.status == LanguageDetectionStatus.detected &&
        record.result.language == SupportedLanguage.en, "privacy fixture classification changed");
}

// ---------------------------------------------------------------------------
// D-only many-small/few-large child-process benchmark matrix. Descriptive
// bounded-cost evidence only; not a speed advantage claim.
// ---------------------------------------------------------------------------

private enum totalBenchmarkBytes = 512 * 1024;

private string syntheticDocument(size_t index, size_t targetBytes) {
    static immutable string[] words = ["the", "quick", "brown", "fox", "jumps", "over", "lazy",
        "dog", "river", "mountain", "village", "morning", "evening", "garden", "market",
        "bridge", "forest", "kitchen", "window", "library"];
    char[] result;
    size_t i;
    while (result.length < targetBytes) {
        result ~= words[(index + i) % words.length];
        result ~= ' ';
        ++i;
    }
    return cast(string) result[0 .. targetBytes];
}

private struct BenchDoc { size_t index; string text; }

private BenchDoc[] benchDocuments(string shape) {
    size_t count = shape == "many-small" ? 64 : 4;
    auto perDocument = totalBenchmarkBytes / count;
    BenchDoc[] docs;
    foreach (i; 0 .. count) docs ~= BenchDoc(i, syntheticDocument(i, perDocument));
    return docs;
}

private void runBenchChild(string shape) {
    auto docs = benchDocuments(shape);
    GC.collect();
    auto allocatedBefore = GC.allocatedInCurrentThread;
    auto wall = StopWatch(AutoStart.yes);
    ubyte[] combined;
    size_t recordBytes;
    foreach (doc; docs) {
        auto text = cast(const(ubyte)[]) doc.text;
        auto id = docId(format("bench-%s-%d", shape, doc.index));
        auto record = buildLanguageIdentity(id, text);
        auto encoded = encodeLanguageIdentity(record);
        recordBytes += encoded.length;
        combined ~= sha256Of(encoded)[];
    }
    wall.stop();
    auto allocated = GC.allocatedInCurrentThread - allocatedBefore;
    GC.collect();
    auto usedAfterCollect = GC.stats.usedSize;
    writeln("bench-digest shape=", shape, " docs=", docs.length,
        " total_bytes=", totalBenchmarkBytes, " digest=", hex(sha256Of(combined)[]),
        " record_bytes=", recordBytes);
    writeln("bench-timing child_wall_us=", wall.peek.total!"usecs",
        " child_gc_allocated_bytes=", allocated, " child_gc_used_after_collect_bytes=",
        usedAfterCollect);
}

private ulong childPeakRssBytes() {
    rusage usage;
    check(getrusage(RUSAGE_CHILDREN, &usage) == 0, "getrusage failed");
    version (OSX) return cast(ulong) usage.ru_opaque[0];
    else version (linux) return cast(ulong) usage.ru_maxrss * 1024;
    else static assert(0, "resource observation requires Darwin or Linux");
}

private ulong childCpuMicros(const ref rusage usage) {
    return (cast(ulong) usage.ru_utime.tv_sec + cast(ulong) usage.ru_stime.tv_sec) * 1_000_000UL +
        cast(ulong) usage.ru_utime.tv_usec + cast(ulong) usage.ru_stime.tv_usec;
}

private string digestLine(string output) {
    foreach (line; output.splitLines) if (line.startsWith("bench-digest")) return line;
    return null;
}

private string timingLine(string output) {
    foreach (line; output.splitLines) if (line.startsWith("bench-timing")) return line;
    return null;
}

private void benchmarkMatrix() {
    auto self = thisExePath();
    foreach (shape; ["many-small", "few-large"]) {
        string firstDigest, secondDigest, lastTiming;
        ulong wallUs, cpuUs, rssBytes;
        foreach (run; 0 .. 2) {
            rusage cpuBefore, cpuAfter;
            check(getrusage(RUSAGE_CHILDREN, &cpuBefore) == 0, "child CPU baseline unavailable");
            auto wall = StopWatch(AutoStart.yes);
            auto result = execute([self, "--bench-child", shape]);
            wall.stop();
            check(getrusage(RUSAGE_CHILDREN, &cpuAfter) == 0, "child CPU observation unavailable");
            check(result.status == 0, "bench child exited nonzero: " ~ result.output);
            if (run == 0) { firstDigest = digestLine(result.output); wallUs = wall.peek.total!"usecs"; }
            else secondDigest = digestLine(result.output);
            lastTiming = timingLine(result.output);
            cpuUs = childCpuMicros(cpuAfter) - childCpuMicros(cpuBefore);
            rssBytes = childPeakRssBytes();
        }
        check(firstDigest !is null && firstDigest == secondDigest,
            "exact-output/digest gate: repeated bench child run diverged for " ~ shape);
        writeln("language id bench: shape=", shape, " parent_wall_us=", wallUs,
            " child_cpu_us=", cpuUs, " child_peak_rss_bytes=", rssBytes, " ", firstDigest, " ",
            lastTiming);
    }
    writeln("language id bench: descriptive bounded-cost evidence only, not a speed " ~
        "advantage claim.");
}

void main(string[] args) {
    if (args.length == 3 && args[1] == "--bench-child") {
        runBenchChild(args[2]);
        return;
    }
    seedCorpusDigestGoldens();
    generatorReproducibilityProof();
    disjointnessProof();
    boundaryGoldens();
    scriptAbstentionGolden();
    vietnameseDiacriticDensityGolden();
    mixedLanguageGolden();
    excludedNeighborAbstentionGoldens();
    thresholdRoutingGoldens();
    heldOutConfusionMatrix();
    identityAndDecoderGoldens();
    exhaustiveLanguageValueRoundTrip();
    privacyBoundary();
    benchmarkMatrix();
    writeln("language id check: provenance, goldens, confusion matrix, decoder rejection, " ~
        "privacy boundary, and benchmark matrix passed");
}
