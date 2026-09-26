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
import std.array : replicate;
import std.conv : to;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.digest : LetterCase, toHexString;
import std.exception : collectException;
import std.file : readText, thisExePath;
import std.format : format;
import std.path : buildPath;
import std.process : execute;
import std.stdio : writeln;
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
    // Reproducibility, not just single-run agreement: a second independent
    // run of the generator must produce the exact same tables again.
    auto generatedAgain = generateProfiles(profilesRoot);
    check(generatedAgain.en == generated.en && generatedAgain.es == generated.es &&
        generatedAgain.fr == generated.fr && generatedAgain.de == generated.de,
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

private void disjointnessProof() {
    string[] seedLines;
    string[] heldoutLines;
    foreach (lang; ["en", "es", "fr", "de"]) {
        seedLines ~= linesOf(buildPath(profilesRoot, lang ~ ".txt"));
        heldoutLines ~= linesOf(buildPath(heldoutRoot, lang ~ ".txt"));
    }
    check(seedLines.length >= 40, "seed corpus suspiciously small");
    check(heldoutLines.length >= 20, "held-out corpus suspiciously small");
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

private void heldOutConfusionMatrix() {
    // A flat "actual|predictedOrAbstainReason" key avoids relying on nested
    // associative-array auto-vivification for the (rare) key combinations.
    size_t[string] confusion;
    size_t correct, misclassified, abstained, total;
    foreach (lang; ["en", "es", "fr", "de"]) {
        auto expected = lang == "en" ? SupportedLanguage.en : lang == "es" ? SupportedLanguage.es :
            lang == "fr" ? SupportedLanguage.fr : SupportedLanguage.de;
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
    writeln("language id check: held-out confusion matrix (actual -> predicted/abstain counts):");
    foreach (key, count; confusion) writeln("  ", key, ": ", count);
    writeln("language id check: held-out total=", total, " correct=", correct,
        " misclassified=", misclassified, " abstained=", abstained,
        " (small authored boundary evidence only; not a web-scale or universal-",
        "language-coverage claim)");
    // Pinned as an exact reproducibility golden: this small, disjoint,
    // authored held-out set classifies perfectly at the currently embedded
    // profile tables and thresholds. This is not an accuracy target this
    // checker gates future changes on; a deliberate algorithm/threshold/
    // profile change is free to move this number, as long as it is updated
    // here deliberately rather than silently drifting.
    check(total == 40, "held-out fixture size changed");
    check(correct == 40 && misclassified == 0 && abstained == 0,
        "held-out confusion matrix golden changed");
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
    mixedLanguageGolden();
    thresholdRoutingGoldens();
    heldOutConfusionMatrix();
    identityAndDecoderGoldens();
    privacyBoundary();
    benchmarkMatrix();
    writeln("language id check: provenance, goldens, confusion matrix, decoder rejection, " ~
        "privacy boundary, and benchmark matrix passed");
}
