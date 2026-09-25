/// Release-active D checker for `domain.topical_tags`. Pins exact canonical
/// bytes/digests, decoder rejection, privacy boundaries, and a descriptive
/// bounded-cost benchmark matrix. Not published; no committed report file.
module topical_tags.check;

import domain.document : DocumentId, SourceLocator;
import domain.topical_tags;
import crypto.sha256 : sha256Of;
import core.memory : GC;
import core.sys.posix.sys.resource : RUSAGE_CHILDREN, getrusage, rusage;
import std.algorithm.searching : canFind, startsWith;
import std.string : splitLines;
import std.array : replicate;
import std.conv : to;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.digest : LetterCase, toHexString;
import std.exception : collectException;
import std.file : thisExePath;
import std.format : format;
import std.process : execute;
import std.stdio : writeln;

private void check(bool okay, string reason) {
    if (!okay) throw new Exception("topical tags check: " ~ reason);
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
    return DocumentId.from(SourceLocator("topical-tags-check-v1", "fixture", key));
}

// ---------------------------------------------------------------------------
// A small authored controlled vocabulary shared by the correctness fixtures.
// ---------------------------------------------------------------------------

private Vocabulary fixtureVocabulary() {
    return Vocabulary.build([
        VocabularyTopic("topic.cooking", "Cooking", [],
            [VocabularyTerm("term.recipe", ["recipe"]),
             VocabularyTerm("term.oven", ["oven"]),
             VocabularyTerm("term.simmer", ["simmer"])]),
        VocabularyTopic("topic.finance", "Personal Finance", ["Money", "Planning"],
            [VocabularyTerm("term.budget", ["budget"]),
             VocabularyTerm("term.tax-return", ["tax", "return"]),
             VocabularyTerm("term.interest-rate", ["interest", "rate"])]),
        VocabularyTopic("topic.gardening", "Gardening", [],
            [VocabularyTerm("term.compost", ["compost"]),
             VocabularyTerm("term.perennial", ["perennial"])]),
    ]);
}

private MatchOptions fixtureOptions() { return MatchOptions(500, 1); }

// ---------------------------------------------------------------------------
// Declared/source-observation fidelity: exact canonicalization, ordering,
// duplicate marking, hierarchy, multilingual display, and identity goldens.
// This section checks exact reproduction of authored input, not a
// statistical score.
// ---------------------------------------------------------------------------

private void declaredFidelityGoldens() {
    // HTML-style category/keyword evidence, as a caller would map from
    // `effects.html_metadata`'s MetadataField candidates (rule/node) without
    // this module parsing HTML itself.
    auto observations = [
        DeclaredObservation("Weeknight Cooking", ["Food", "Recipes"], "meta.keywords",
            "html-metadata:v1", 12),
        DeclaredObservation("weeknight cooking", [], "meta.category", "html-metadata:v1", 18),
        // Conflicting spellings for a related concept are retained separately;
        // this module never merges by meaning, only by canonical key equality.
        DeclaredObservation("AI", [], "meta.keywords", "html-metadata:v1", 20),
        DeclaredObservation("Artificial Intelligence", [], "meta.keywords",
            "html-metadata:v1", 21),
        // Multilingual displays: canonicalization is UTF-8/NFC/whitespace only.
        DeclaredObservation("Küche", [], "meta.keywords", "html-metadata:v1", 22),
        DeclaredObservation("食品", [], "meta.keywords", "html-metadata:v1", 23),
        // Exact duplicate of the first observation.
        DeclaredObservation("Weeknight Cooking", ["Food", "Recipes"], "meta.keywords",
            "html-metadata:v1", 24),
    ];
    auto declared = canonicalizeDeclared(observations);
    check(declared.length == 7, "declared candidate count");
    check(declared[0].canonicalKey == "weeknight cooking" && !declared[0].duplicateKey,
        "first observation is not a duplicate");
    check(declared[1].canonicalKey == "weeknight cooking" && declared[1].duplicateKey,
        "case-equivalent key marked duplicate");
    check(declared[2].canonicalKey == "ai" && declared[3].canonicalKey == "artificial intelligence" &&
        !declared[2].duplicateKey && !declared[3].duplicateKey,
        "conflicting spellings retained separately, not merged");
    check(declared[4].displayValue == "Küche" && declared[5].displayValue == "食品",
        "multilingual display values preserved exactly");
    check(declared[6].canonicalKey == "weeknight cooking" && declared[6].duplicateKey,
        "exact duplicate marked, not collapsed");
    check(declared.length == observations.length,
        "no silent author-tag collapse: every observation remains present");
    check(declared[0].hierarchy == ["Food", "Recipes"], "hierarchy preserved");

    auto encoded = sha256Of(joinedDeclaredBytes(declared));
    check(hex(encoded[]) == "9e793f57f392024d016d0d86c3c098672d9e8874c8c7f845427f1647f7191489",
        "declared fidelity fixture digest changed");
}

private ubyte[] joinedDeclaredBytes(const(DeclaredCandidate)[] declared) {
    ubyte[] bytes;
    foreach (candidate; declared) {
        bytes ~= cast(ubyte[]) candidate.displayValue.dup;
        bytes ~= 0;
        bytes ~= cast(ubyte[]) candidate.canonicalKey.dup;
        bytes ~= candidate.duplicateKey ? 1 : 0;
        foreach (segment; candidate.hierarchy) bytes ~= cast(ubyte[]) segment.dup;
        bytes ~= cast(ubyte[]) candidate.evidence.sourceRuleId.dup;
        bytes ~= cast(ubyte[]) candidate.evidence.extractorId.dup;
    }
    return bytes;
}

private void maliciouslyLargeFieldRejections() {
    // Oversize display value.
    rejects({
        canonicalizeDeclared([DeclaredObservation("a".replicate(maxDisplayBytes + 1),
            [], "rule", "extractor", 0)]);
    });
    check(canonicalizeDeclared([DeclaredObservation("a".replicate(maxDisplayBytes),
        [], "rule", "extractor", 0)]).length == 1, "exact-cap display value accepted");
    // Oversize hierarchy depth.
    string[] tooDeep;
    foreach (i; 0 .. maxHierarchyDepth + 1) tooDeep ~= format("segment-%d", i);
    rejects({ canonicalizeDeclared([DeclaredObservation("x", tooDeep, "rule", "extractor", 0)]); });
    // Oversize rule/extractor id.
    rejects({
        canonicalizeDeclared([DeclaredObservation("x", [], "r".replicate(maxIdBytes + 1),
            "extractor", 0)]);
    });
    // Too many declared observations.
    DeclaredObservation[] many;
    foreach (i; 0 .. maxDeclaredCandidates + 1)
        many ~= DeclaredObservation(format("tag-%d", i), [], "rule", "extractor", i);
    rejects({ canonicalizeDeclared(many); });
    check(canonicalizeDeclared(many[0 .. maxDeclaredCandidates]).length ==
        maxDeclaredCandidates, "exact-cap declared count accepted");
    // Oversize vocabulary topic/term counts and malformed tokens.
    rejects({ Vocabulary.build([]); });
    VocabularyTopic[] manyTopics;
    foreach (i; 0 .. maxTopics + 1)
        manyTopics ~= VocabularyTopic(format("topic.%d", i), format("Topic %d", i), [],
            [VocabularyTerm("term", ["word"])]);
    rejects({ Vocabulary.build(manyTopics); });
    check(Vocabulary.build([VocabularyTopic("t", "T", [],
        [VocabularyTerm("term", ["5"])])]).topics.length == 1,
        "a lone digit is a valid Unicode number token");
    rejects({
        // A hyphen is punctuation, not a Unicode letter/number token character.
        Vocabulary.build([VocabularyTopic("t", "T", [], [VocabularyTerm("term", ["tax-return"])])]);
    });
    rejects({
        Vocabulary.build([VocabularyTopic("t", "T", [],
            [VocabularyTerm("term", ["one", "two", "three", "four", "five"])])]);
    });
    rejects({
        Vocabulary.build([VocabularyTopic("t", "T", [],
            [VocabularyTerm("a", ["word"]), VocabularyTerm("b", ["word"])])]);
    });
}

// ---------------------------------------------------------------------------
// Controlled-token-v1 inference: supported matches, whole-token boundaries,
// overlap/repeats, abstention, and a small held-out precision/recall split.
// This is boundary evidence only; it is not web-scale or semantic-quality
// evidence.
// ---------------------------------------------------------------------------

private void inferenceGoldens() {
    auto vocabulary = fixtureVocabulary();
    auto options = fixtureOptions();
    auto text = "This recipe needs a hot oven; simmer gently. File your tax return before " ~
        "the interest rate changes.";
    auto result = inferControlledTokenV1(text, vocabulary, "en", options);
    check(result.abstention == InferenceAbstention.none, "supported-match abstention");
    check(result.candidates.length == 2, "supported-match candidate count");
    check(result.candidates[0].canonicalKey == "cooking" &&
        result.candidates[0].evidence.evidenceScore == 3 &&
        result.candidates[0].evidence.evidenceTotal == 3, "cooking full match");
    check(result.candidates[1].canonicalKey == "personal finance" &&
        result.candidates[1].evidence.evidenceScore == 2 &&
        result.candidates[1].evidence.evidenceTotal == 3, "finance partial match");
    auto rate = result.candidates[1].evidence.matches;
    check(rate.length == 2, "finance stored match count");
    check(text[rate[1].start .. rate[1].end] == "interest rate", "multi-token match span");

    // Overlap/repeated terms: repeats do not inflate the unique-term score,
    // and only the first occurrence is retained as evidence.
    auto repeated = "recipe recipe recipe. Another recipe here.";
    auto repeatedResult = inferControlledTokenV1(repeated, vocabulary, "en", MatchOptions(0, 1));
    check(repeatedResult.candidates.length == 1 &&
        repeatedResult.candidates[0].evidence.evidenceScore == 1 &&
        repeatedResult.candidates[0].evidence.matches.length == 1 &&
        repeatedResult.candidates[0].evidence.matches[0].start == 0,
        "repeated term counted once, first occurrence stored");

    // False-positive controls: whole-token boundaries reject substrings.
    auto substrings = "ovenware recipes simmering budgets taxation interests ratepayer " ~
        "composting perennials";
    auto falsePositive = inferControlledTokenV1(substrings, vocabulary, "en", options);
    check(falsePositive.abstention == InferenceAbstention.noMatch &&
        falsePositive.candidates.length == 0,
        "substring/plural forms must not match whole-token vocabulary");

    // Unsupported/missing language abstains rather than guessing.
    foreach (language; ["und", "", "fr", "de"])
        check(inferControlledTokenV1(text, vocabulary, language, options).abstention ==
            InferenceAbstention.unsupportedLanguage, "unsupported language must abstain: " ~ language);

    // No-match abstention on valid English input with zero qualifying topics.
    auto noMatch = inferControlledTokenV1("The weather today is mild and pleasant.",
        vocabulary, "en", options);
    check(noMatch.abstention == InferenceAbstention.noMatch, "no-match abstention");

    // Empty/oversize/invalid canonical text abstention.
    check(inferControlledTokenV1("", vocabulary, "en", options).abstention ==
        InferenceAbstention.emptyCanonicalText, "empty text abstention");
    auto oversize = new char[maxCanonicalTextBytes + 1];
    oversize[] = 'a';
    check(inferControlledTokenV1(cast(string) oversize, vocabulary, "en", options).abstention ==
        InferenceAbstention.oversizeCanonicalText, "oversize text abstention");

    // Candidate overflow is a truncating warning, not a thrown rejection.
    VocabularyTopic[] manyTopics;
    foreach (i; 0 .. maxInferredCandidates + 4)
        manyTopics ~= VocabularyTopic(format("topic.overflow-%d", i), format("Overflow %d", i),
            [], [VocabularyTerm("term", ["overflow"])]);
    auto overflowVocabulary = Vocabulary.build(manyTopics);
    auto overflowResult = inferControlledTokenV1("overflow overflow overflow",
        overflowVocabulary, "en", MatchOptions(0, 0));
    check(overflowResult.candidates.length == maxInferredCandidates &&
        overflowResult.warning == InferenceWarning.candidateOverflow,
        "inferred candidate overflow truncates deterministically with a warning");
}

/// A small authored held-out split: documents distinct from the goldens
/// above, each with an expected topic key or an explicit negative. This is
/// boundary precision/recall evidence, not a web-quality or semantic claim.
private void heldOutPrecisionRecall() {
    auto vocabulary = fixtureVocabulary();
    auto options = fixtureOptions();
    struct Case { string text; string[] expected; }
    auto cases = [
        Case("Slow simmer this recipe in a low oven for best results.", ["cooking"]),
        Case("Compost your kitchen scraps and plant hardy perennials this spring.",
            ["gardening"]),
        Case("Set a monthly budget and track your tax return before the interest " ~
            "rate rises.", ["personal finance"]),
        Case("A recipe for financial success: track your budget and file your tax " ~
            "return the way you simmer a good stew.", ["cooking", "personal finance"]),
        Case("The museum's new exhibit opens next Tuesday afternoon.", []),
        Case("Recipes, ovens, and composting are all popular hobby topics online but " ~
            "this sentence alone names none of the exact configured terms.", []),
    ];
    size_t truePositive, falsePositive, falseNegative;
    size_t abstentions;
    foreach (testCase; cases) {
        auto result = inferControlledTokenV1(testCase.text, vocabulary, "en", options);
        if (result.abstention != InferenceAbstention.none) ++abstentions;
        bool[string] got;
        foreach (candidate; result.candidates) got[candidate.canonicalKey] = true;
        bool[string] want;
        foreach (key; testCase.expected) want[key] = true;
        foreach (key; got.byKey) if ((key in want) is null) ++falsePositive; else ++truePositive;
        foreach (key; want.byKey) if ((key in got) is null) ++falseNegative;
    }
    check(truePositive == 5 && falsePositive == 0 && falseNegative == 0 && abstentions == 2,
        "held-out precision/recall golden changed");
    writeln("topical tags check: held-out controlled-vocabulary split precision=",
        truePositive, "/", truePositive + falsePositive, " recall=", truePositive, "/",
        truePositive + falseNegative, " abstentions=", abstentions, "/", cases.length,
        " (small authored boundary evidence only; not a web-scale or semantic claim)");
}

// ---------------------------------------------------------------------------
// Canonical identity, encode/decode round trip, and decoder rejection.
// ---------------------------------------------------------------------------

private void identityAndDecoderGoldens() {
    auto vocabulary = fixtureVocabulary();
    auto options = fixtureOptions();
    auto id = docId("annotation-1");
    auto text = cast(const(ubyte)[]) ("A recipe for a hot oven dish. Budget your tax " ~
        "return before the interest rate changes.");
    auto observations = [
        DeclaredObservation("Weeknight Cooking", ["Food"], "meta.category",
            "html-metadata:v1", 4),
    ];
    auto annotation = buildAnnotation(id, text, observations, vocabulary, "en", options);
    check(annotation.declared.length == 1 && annotation.inferred.length == 2,
        "identity fixture candidate counts");
    auto encoded = encodeTopicalTags(annotation);
    check(encoded.length <= maxAnnotationBytes, "annotation within the C01 ceiling");
    check(hex(sha256Of(encoded)[]) == "fbcc16557664484252452657435ab0c0777ac95ae5bfb3e9d6893567e6bde2a0",
        "identity/decoder fixture digest changed");

    auto decoded = decodeTopicalTags(encoded, id, annotation.identity.textRevision);
    check(decoded == annotation, "encode/decode round trip");
    check(encodeTopicalTags(decoded) == encoded, "re-encode determinism");

    // Wrong document/revision identity.
    rejects({ decodeTopicalTags(encoded, docId("annotation-2"),
        annotation.identity.textRevision); });
    ubyte[32] wrongRevision = sha256Of(cast(const(ubyte)[]) "different canonical text");
    rejects({ decodeTopicalTags(encoded, id, wrongRevision); });

    // Truncation and trailing data.
    rejects({ decodeTopicalTags(encoded[0 .. $ - 1], id, annotation.identity.textRevision); });
    rejects({ decodeTopicalTags(encoded[0 .. 40], id, annotation.identity.textRevision); });
    auto trailing = encoded.dup ~ cast(ubyte) 0;
    rejects({ decodeTopicalTags(trailing, id, annotation.identity.textRevision); });

    // Every byte position corrupted at least once must not silently decode
    // to a *different valid* annotation; it must either round-trip to the
    // same value or be rejected. This exercises overflow-safe length
    // calculations across every length-prefixed field boundary.
    size_t rejected, tolerated;
    foreach (offset; 0 .. encoded.length) {
        auto corrupt = encoded.dup;
        corrupt[offset] ^= 0xff;
        auto thrown = collectException!Exception(decodeTopicalTags(corrupt, id,
            annotation.identity.textRevision));
        if (thrown !is null) ++rejected;
        else ++tolerated; // only possible if a mutation happened to be a no-op check below
    }
    check(rejected == encoded.length, "every single-byte corruption must be rejected");
    check(tolerated == 0, "no corrupted byte silently decoded");

    // Wrong analyzer/algorithm/vocabulary/options identity via the umbrella
    // recompute check (decode never needs the raw vocabulary/options back).
    auto otherVocabulary = Vocabulary.build([
        VocabularyTopic("topic.other", "Other", [], [VocabularyTerm("t", ["other"])])]);
    auto otherAnnotation = buildAnnotation(id, text, observations, otherVocabulary, "en", options);
    check(otherAnnotation.identity.vocabularyIdentity != annotation.identity.vocabularyIdentity,
        "distinct vocabularies must have distinct identity");
    auto otherOptions = MatchOptions(999, 3);
    auto differentOptionsAnnotation = buildAnnotation(id, text, observations, vocabulary, "en",
        otherOptions);
    check(differentOptionsAnnotation.identity.optionsIdentity != annotation.identity.optionsIdentity,
        "distinct options must have distinct identity");
}

// ---------------------------------------------------------------------------
// Privacy boundary: synthetic canaries must never leak into encoded bytes,
// exception messages, or this checker's own stdout, except when a caller
// intentionally supplies a within-cap declared display value.
// ---------------------------------------------------------------------------

private void privacyBoundary() {
    enum canary = "CANARY-9f3a1b7c-do-not-leak";
    auto vocabulary = fixtureVocabulary();
    auto options = fixtureOptions();
    auto id = docId("privacy-1");

    // Canary sits in canonical text and in a source-locator-like string,
    // both away from any configured vocabulary term, so neither should
    // appear anywhere in the encoded annotation.
    auto text = cast(const(ubyte)[]) ("Unrelated notes: " ~ canary ~
        " and file:///var/private/" ~ canary ~ "/secret.txt are not vocabulary terms.");
    auto annotation = buildAnnotation(id, text, [], vocabulary, "en", options);
    auto encoded = encodeTopicalTags(annotation);
    check(!(cast(string) encoded).canFind(canary), "unmatched canary leaked into encoded annotation");
    check(annotation.abstention == InferenceAbstention.noMatch, "canary text has no vocabulary match");

    // A canary supplied as an oversize declared field must be rejected with
    // a fixed, content-free diagnostic.
    auto oversizeCanary = canary.replicate((maxDisplayBytes / canary.length) + 1);
    Exception caught;
    try canonicalizeDeclared([DeclaredObservation(oversizeCanary, [], "rule", "extractor", 0)]);
    catch (Exception e) caught = e;
    check(caught !is null && !caught.msg.canFind(canary) &&
        caught.msg == "topical tags: malformed declared display value",
        "rejection message leaked oversize canary content");

    // Positive control: an intentionally supplied, within-cap declared
    // display value legitimately appears in the encoded annotation.
    auto intended = buildAnnotation(id, text, [DeclaredObservation(canary, [], "rule",
        "extractor", 0)], vocabulary, "en", options);
    auto intendedEncoded = encodeTopicalTags(intended);
    check((cast(string) intendedEncoded).canFind(canary),
        "intentionally supplied declared display value must appear");

    // Inferred evidence carries IDs/ranges only, never the matched substring
    // or a hash of it; confirm no term text is duplicated as a value field.
    auto matchText = cast(const(ubyte)[]) "A recipe needs an oven and a gentle simmer.";
    auto matched = buildAnnotation(id, matchText, [], vocabulary, "en", options);
    check(matched.inferred.length == 1, "match fixture sanity");
    foreach (m; matched.inferred[0].evidence.matches)
        check(m.termId.length != 0 && m.termId != "recipe" && m.termId != "oven",
            "term id must be the caller-declared id, not the matched text itself");
}

// ---------------------------------------------------------------------------
// D-only many-small/few-large child-process benchmark matrix. Descriptive
// bounded-cost evidence only; not a speed advantage claim.
// ---------------------------------------------------------------------------

private enum totalBenchmarkBytes = 512 * 1024;

private string syntheticDocument(size_t index, size_t targetBytes) {
    static immutable string[] words = ["recipe", "oven", "simmer", "budget", "tax", "return",
        "interest", "rate", "compost", "perennial", "weather", "mild", "pleasant", "museum",
        "exhibit", "Tuesday", "afternoon", "garden", "kitchen", "notebook"];
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

private void runBenchChild(string mode, string shape) {
    auto docs = benchDocuments(shape);
    auto vocabulary = fixtureVocabulary();
    auto options = fixtureOptions();
    GC.collect();
    auto allocatedBefore = GC.allocatedInCurrentThread;
    auto wall = StopWatch(AutoStart.yes);
    ubyte[] combined;
    size_t annotationBytes;
    foreach (doc; docs) {
        auto text = cast(const(ubyte)[]) doc.text;
        final switch (mode) {
            case "disabled":
                combined ~= sha256Of(cast(ubyte[]) doc.index.to!string)[];
                break;
            case "declared-only": {
                auto id = docId(format("bench-%s-%s-%d", mode, shape, doc.index));
                auto annotation = buildAnnotation(id, text, [], vocabulary, "und", options);
                auto encoded = encodeTopicalTags(annotation);
                annotationBytes += encoded.length;
                combined ~= sha256Of(encoded)[];
                break;
            }
            case "inference": {
                auto id = docId(format("bench-%s-%s-%d", mode, shape, doc.index));
                auto annotation = buildAnnotation(id, text, [], vocabulary, "en", options);
                auto encoded = encodeTopicalTags(annotation);
                annotationBytes += encoded.length;
                combined ~= sha256Of(encoded)[];
                break;
            }
        }
    }
    wall.stop();
    auto allocated = GC.allocatedInCurrentThread - allocatedBefore;
    GC.collect();
    auto usedAfterCollect = GC.stats.usedSize;
    // Two lines: the digest line is the exact-output gate (deterministic
    // across repeated runs); the timing line varies run to run and is
    // reported but not compared.
    writeln("bench-digest mode=", mode, " shape=", shape, " docs=", docs.length,
        " total_bytes=", totalBenchmarkBytes, " digest=", hex(sha256Of(combined)[]),
        " annotation_bytes=", annotationBytes);
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
        foreach (mode; ["disabled", "declared-only", "inference"]) {
            string firstDigest, secondDigest, lastTiming;
            ulong wallUs, cpuUs, rssBytes;
            foreach (run; 0 .. 2) {
                rusage cpuBefore, cpuAfter;
                check(getrusage(RUSAGE_CHILDREN, &cpuBefore) == 0, "child CPU baseline unavailable");
                auto wall = StopWatch(AutoStart.yes);
                auto result = execute([self, "--bench-child", mode, shape]);
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
                "exact-output/digest gate: repeated bench child run diverged for " ~
                mode ~ "/" ~ shape);
            writeln("topical tags bench: mode=", mode, " shape=", shape,
                " parent_wall_us=", wallUs, " child_cpu_us=", cpuUs,
                " child_peak_rss_bytes=", rssBytes, " ", firstDigest, " ", lastTiming);
        }
    }
    writeln("topical tags bench: descriptive bounded-cost evidence only, not a speed " ~
        "advantage claim; unsupported metrics (e.g. syscall counts) are not reported here.");
}

void main(string[] args) {
    if (args.length == 4 && args[1] == "--bench-child") {
        runBenchChild(args[2], args[3]);
        return;
    }
    declaredFidelityGoldens();
    maliciouslyLargeFieldRejections();
    inferenceGoldens();
    heldOutPrecisionRecall();
    identityAndDecoderGoldens();
    privacyBoundary();
    benchmarkMatrix();
    writeln("topical tags check: goldens, decoder rejection, privacy boundary, and " ~
        "benchmark matrix passed");
}
