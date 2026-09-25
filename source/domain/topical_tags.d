/// Pure, bounded topical-tag annotation: declared-evidence candidates kept
/// separate from controlled-vocabulary inferred candidates, with explicit
/// abstention. This is a repository-local seam: it does not parse HTML,
/// register a pipeline stage, expose CLI/config, or publish durable output.
/// Tags never alter `DocumentId`, canonical text bytes, stage decisions, or
/// extraction provenance; this module only observes already-extracted
/// canonical text and caller-supplied evidence.
module domain.topical_tags;

import domain.document : DocumentId;
import crypto.sha256 : sha256Of;
import std.array : Appender, appender;
import std.exception : enforce;
import std.uni : normalize, toLower, unicode, isWhite;
import std.utf : UTFException, validate;

enum uint topicalTagsSchema = 1;
enum uint topicalNormalizationVersion = 1;
enum string controlledTokenV1 = "controlled-token-v1";

enum size_t maxCanonicalTextBytes = 1024 * 1024;
enum size_t maxDeclaredCandidates = 64;
enum size_t maxInferredCandidates = 32;
enum size_t maxDisplayBytes = 256;
enum size_t maxKeyBytes = 256;
enum size_t maxHierarchyDepth = 8;
enum size_t maxIdBytes = 128;
enum size_t maxTopics = 64;
enum size_t maxTermsPerTopic = 16;
enum size_t maxTokensPerTerm = 4;
enum size_t maxStoredMatches = 16;
enum size_t maxAnnotationBytes = 64 * 1024;

enum CandidateOrigin : ubyte { declared, inferred }

/// Named per the contract: empty/invalid/oversize/unsupported-language/
/// no-match. `none` means inference produced at least one candidate.
enum InferenceAbstention : ubyte {
    none,
    emptyCanonicalText,
    invalidCanonicalText,
    oversizeCanonicalText,
    unsupportedLanguage,
    noMatch,
}

/// Candidate-overflow is a runtime outcome of matching, not caller-input
/// validation, so it is a truncating warning rather than a thrown rejection.
enum InferenceWarning : ubyte { none, candidateOverflow }

enum SelectionPolicy : ubyte { none, sourceOnly, inferredOnly, union_ }

private void fail(string message) pure {
    throw new Exception("topical tags: " ~ message);
}

// ---------------------------------------------------------------------------
// Canonicalization: UTF-8 validation, NFC, Unicode-whitespace collapse/trim,
// and (for keys only) Unicode default-mapping case fold. No stemming,
// transliteration, accent stripping, locale guessing, or synonym expansion.
// Separators are literal; a flat string never invents hierarchy.
// ---------------------------------------------------------------------------

private string collapseWhitespace(string input) {
    string result;
    size_t runStart;
    bool whitespace = true; // leading whitespace is trimmed, not collapsed to a space
    size_t at;
    while (at < input.length) {
        auto start = at;
        dchar ch;
        try ch = decodeOne(input, at);
        catch (UTFException) fail("invalid UTF-8 in canonicalized text");
        if (isWhite(ch)) {
            if (!whitespace && runStart < start) result ~= input[runStart .. start];
            whitespace = true;
            continue;
        }
        if (whitespace) {
            if (result.length) result ~= " ";
            whitespace = false;
            runStart = start;
        }
    }
    if (!whitespace && runStart < input.length) result ~= input[runStart .. $];
    return result;
}

private dchar decodeOne(string input, ref size_t at) {
    import std.utf : decode;
    return decode(input, at);
}

/// Canonical display text: valid UTF-8, NFC, Unicode-whitespace collapsed
/// and edge-trimmed. Never stems, transliterates, or strips accents.
string canonicalDisplay(string raw) {
    validate(raw); // throws UTFException -> caller wraps with a fixed message
    return collapseWhitespace(normalize(raw)).idup;
}

/// Canonical comparison/storage key: canonical display plus Unicode default
/// case mapping (this toolchain's available approximation of full case fold).
string canonicalKeyOf(string canonicalDisplayValue) {
    return toLower(canonicalDisplayValue).idup;
}

unittest {
    assert(canonicalDisplay("  alpha \t β\n gamma  ") == "alpha β gamma");
    assert(canonicalDisplay("café") == canonicalDisplay("café"));
    // This toolchain exposes Unicode simple lowercase mapping, not full
    // case fold, so a sharp S stays a sharp S rather than expanding to "ss".
    assert(canonicalKeyOf(canonicalDisplay("Straße")) == "straße");
    assert(canonicalKeyOf(canonicalDisplay("ABC")) == canonicalKeyOf(canonicalDisplay("abc")));
}

// ---------------------------------------------------------------------------
// Declared (source-observed) evidence and candidates.
// ---------------------------------------------------------------------------

/// Caller-supplied raw declared observation. No source path/locator, no
/// algorithm confidence. `hierarchy`, if supplied, is an explicit ordered
/// path — never derived by splitting `displayValue` on a separator.
struct DeclaredObservation {
    string displayValue;
    string[] hierarchy;
    string sourceRuleId;
    string extractorId;
    size_t sourceNode;
}

struct DeclaredEvidence {
    string sourceRuleId;
    string extractorId;
    size_t sourceNode;
}

struct DeclaredCandidate {
    string displayValue;
    string canonicalKey;
    string[] hierarchy;
    CandidateOrigin origin = CandidateOrigin.declared;
    bool duplicateKey;
    DeclaredEvidence evidence;
}

private string canonicalId(string raw, string field) {
    try validate(raw);
    catch (UTFException) fail("malformed " ~ field);
    enforce(raw.length != 0 && raw.length <= maxIdBytes, "topical tags: malformed " ~ field);
    foreach (c; raw) enforce(c != 0, "topical tags: malformed " ~ field);
    return raw;
}

private string[] canonicalHierarchy(const(string)[] raw) {
    enforce(raw.length <= maxHierarchyDepth, "topical tags: hierarchy too deep");
    string[] result;
    foreach (segment; raw) {
        string canonical;
        try canonical = canonicalDisplay(segment);
        catch (Exception) fail("malformed hierarchy segment");
        enforce(canonical.length != 0 && canonical.length <= maxDisplayBytes,
            "topical tags: malformed hierarchy segment");
        result ~= canonical;
    }
    return result;
}

/// Canonicalizes and bounds-checks declared observations, preserving input
/// order. Case/whitespace-equivalent keys are marked duplicates but every
/// distinct observation remains present: there is no silent collapse or
/// last-wins rule. Malformed caller evidence throws a fixed, content-free
/// diagnostic.
DeclaredCandidate[] canonicalizeDeclared(const(DeclaredObservation)[] observations) {
    enforce(observations.length <= maxDeclaredCandidates,
        "topical tags: too many declared observations");
    DeclaredCandidate[] result;
    bool[string] seenKeys;
    foreach (observation; observations) {
        string display;
        try display = canonicalDisplay(observation.displayValue);
        catch (Exception) fail("malformed declared display value");
        enforce(display.length != 0 && display.length <= maxDisplayBytes,
            "topical tags: malformed declared display value");
        auto key = canonicalKeyOf(display);
        enforce(key.length <= maxKeyBytes, "topical tags: malformed declared key");
        auto hierarchy = canonicalHierarchy(observation.hierarchy);
        auto ruleId = canonicalId(observation.sourceRuleId, "declared source rule id");
        auto extractorId = canonicalId(observation.extractorId, "declared extractor id");
        enforce(observation.sourceNode <= uint.max, "topical tags: declared source node out of range");
        bool duplicate = (key in seenKeys) !is null;
        seenKeys[key] = true;
        result ~= DeclaredCandidate(display, key, hierarchy, CandidateOrigin.declared, duplicate,
            DeclaredEvidence(ruleId, extractorId, observation.sourceNode));
    }
    return result;
}

// ---------------------------------------------------------------------------
// Controlled-vocabulary inference: `controlled-token-v1`.
// ---------------------------------------------------------------------------

/// A vocabulary term is an ordered sequence of 1-4 whole canonical Unicode
/// letter/number tokens that must appear as adjacent document tokens.
struct VocabularyTerm {
    string termId;
    string[] tokens;
}

struct VocabularyTopic {
    string topicId;
    string displayValue;
    string[] hierarchy;
    VocabularyTerm[] terms;
}

/// Caller-supplied, canonically encoded, bounded, duplicate-free controlled
/// vocabulary. Construction rejects malformed entries eagerly.
struct Vocabulary {
    private VocabularyTopic[] topicsValue;
    private bool built;

    static Vocabulary build(const(VocabularyTopic)[] rawTopics) {
        enforce(rawTopics.length != 0 && rawTopics.length <= maxTopics,
            "topical tags: vocabulary topic count out of range");
        Vocabulary result;
        bool[string] seenTopicKeys;
        foreach (topic; rawTopics) {
            auto topicId = canonicalId(topic.topicId, "vocabulary topic id");
            auto display = canonicalDisplay(topic.displayValue);
            enforce(display.length != 0 && display.length <= maxDisplayBytes,
                "topical tags: malformed vocabulary display value");
            auto key = canonicalKeyOf(display);
            enforce((key in seenTopicKeys) is null, "topical tags: duplicate vocabulary topic");
            seenTopicKeys[key] = true;
            auto hierarchy = canonicalHierarchy(topic.hierarchy);
            enforce(topic.terms.length != 0 && topic.terms.length <= maxTermsPerTopic,
                "topical tags: vocabulary term count out of range");
            VocabularyTerm[] terms;
            bool[string] seenTermKeys;
            foreach (term; topic.terms) {
                auto termId = canonicalId(term.termId, "vocabulary term id");
                enforce(term.tokens.length != 0 && term.tokens.length <= maxTokensPerTerm,
                    "topical tags: vocabulary term token count out of range");
                string[] tokens;
                string joined;
                foreach (token; term.tokens) {
                    auto canonical = canonicalTokenOf(token);
                    enforce(canonical.length != 0, "topical tags: malformed vocabulary token");
                    tokens ~= canonical;
                    joined ~= "\0" ~ canonical;
                }
                enforce((joined in seenTermKeys) is null, "topical tags: duplicate vocabulary term");
                seenTermKeys[joined] = true;
                terms ~= VocabularyTerm(termId, tokens);
            }
            result.topicsValue ~= VocabularyTopic(topicId, display, hierarchy, terms);
        }
        result.built = true;
        return result;
    }

    const(VocabularyTopic)[] topics() const { return topicsValue; }

    /// Deterministic digest of the exact canonical vocabulary content.
    ubyte[32] identity() const {
        enforce(built, "topical tags: vocabulary is not built");
        return sha256Of(canonicalVocabularyBytes(topicsValue));
    }
}

private bool isTokenChar(dchar c) {
    static immutable letters = unicode("Letter");
    static immutable numbers = unicode("Number");
    return (c in letters) || (c in numbers);
}

private string canonicalTokenOf(string raw) {
    string canonical;
    try canonical = canonicalKeyOf(canonicalDisplay(raw));
    catch (Exception) return null;
    foreach (dchar c; canonical) if (!isTokenChar(c)) return null;
    return canonical;
}

private ubyte[] canonicalVocabularyBytes(const(VocabularyTopic)[] topics) {
    auto bytes = appender!(ubyte[]);
    bytes.put(cast(const(ubyte)[]) "scrubbed:topical-tags:vocabulary:v1\0");
    appendU32(bytes, cast(uint) topics.length);
    foreach (topic; topics) {
        appendField(bytes, topic.topicId);
        appendField(bytes, topic.displayValue);
        appendU8(bytes, cast(ubyte) topic.hierarchy.length);
        foreach (segment; topic.hierarchy) appendField(bytes, segment);
        appendU32(bytes, cast(uint) topic.terms.length);
        foreach (term; topic.terms) {
            appendField(bytes, term.termId);
            appendU8(bytes, cast(ubyte) term.tokens.length);
            foreach (token; term.tokens) appendField(bytes, token);
        }
    }
    return bytes.data;
}

struct MatchOptions {
    uint thresholdPerMille; // 0..1000; inclusive minimum matched-fraction
    uint minimumMatches;    // minimum distinct terms regardless of fraction

    void check() const {
        enforce(thresholdPerMille <= 1000, "topical tags: threshold out of range");
    }

    ubyte[32] identity() const {
        check();
        auto bytes = appender!(ubyte[]);
        bytes.put(cast(const(ubyte)[]) "scrubbed:topical-tags:options:v1\0");
        appendU32(bytes, thresholdPerMille);
        appendU32(bytes, minimumMatches);
        return sha256Of(bytes.data);
    }
}

struct TermMatch {
    string termId;
    size_t start;
    size_t end; // exclusive, original canonical-text byte offsets
}

struct InferredEvidence {
    string algorithmId;
    string vocabularyId;
    uint evidenceScore;  // distinct configured terms observed
    uint evidenceTotal;  // configured unique terms for this topic
    uint threshold;      // thresholdPerMille applied at evaluation
    uint minimumMatches; // minimumMatches applied at evaluation
    TermMatch[] matches;
}

struct InferredCandidate {
    string displayValue;
    string canonicalKey;
    string[] hierarchy;
    CandidateOrigin origin = CandidateOrigin.inferred;
    bool duplicateKey;
    InferredEvidence evidence;
}

private struct DocToken {
    string text;
    size_t start;
    size_t end;
}

private DocToken[] tokenize(string text) {
    DocToken[] tokens;
    size_t tokenStart = size_t.max;
    size_t at;
    while (at < text.length) {
        auto start = at;
        dchar c;
        try c = decodeOne(text, at);
        catch (UTFException) fail("invalid UTF-8 in canonical text");
        if (isTokenChar(c)) {
            if (tokenStart == size_t.max) tokenStart = start;
        } else if (tokenStart != size_t.max) {
            tokens ~= DocToken(canonicalKeyOf(normalize(text[tokenStart .. start])),
                tokenStart, start);
            tokenStart = size_t.max;
        }
    }
    if (tokenStart != size_t.max)
        tokens ~= DocToken(canonicalKeyOf(normalize(text[tokenStart .. $])),
            tokenStart, text.length);
    return tokens;
}

/// Result of one controlled-token-v1 inference pass.
struct InferenceResult {
    InferredCandidate[] candidates;
    InferenceAbstention abstention;
    InferenceWarning warning;
}

/// The only first-slice inference algorithm. Deterministic, bounded,
/// language-gated to explicit `en`; no free-tag generation, embedding/model
/// inference, network access, or runtime plugin. Threshold/minimum-match
/// options participate in identity via `MatchOptions.identity`.
InferenceResult inferControlledTokenV1(string canonicalText, Vocabulary vocabulary,
    string language, MatchOptions options) {
    options.check();
    InferenceResult result;
    if (canonicalText.length == 0) {
        result.abstention = InferenceAbstention.emptyCanonicalText;
        return result;
    }
    if (canonicalText.length > maxCanonicalTextBytes) {
        result.abstention = InferenceAbstention.oversizeCanonicalText;
        return result;
    }
    try validate(canonicalText);
    catch (UTFException) {
        result.abstention = InferenceAbstention.invalidCanonicalText;
        return result;
    }
    if (language != "en") {
        result.abstention = InferenceAbstention.unsupportedLanguage;
        return result;
    }
    auto tokens = tokenize(canonicalText);
    size_t[][string] positions;
    foreach (i, token; tokens) positions[token.text] ~= i;
    foreach (topic; vocabulary.topics) {
        TermMatch[] matches;
        uint matched;
        foreach (term; topic.terms) {
            auto starts = term.tokens[0] in positions;
            bool found;
            size_t matchStart, matchEnd;
            if (starts !is null) foreach (idx; *starts) {
                if (idx + term.tokens.length > tokens.length) continue;
                bool ok = true;
                foreach (k; 1 .. term.tokens.length)
                    if (tokens[idx + k].text != term.tokens[k]) { ok = false; break; }
                if (ok) {
                    found = true;
                    matchStart = tokens[idx].start;
                    matchEnd = tokens[idx + term.tokens.length - 1].end;
                    break;
                }
            }
            if (found) {
                ++matched;
                if (matches.length < maxStoredMatches)
                    matches ~= TermMatch(term.termId, matchStart, matchEnd);
            }
        }
        auto total = cast(uint) topic.terms.length;
        bool meetsThreshold = cast(ulong) matched * 1000 >= cast(ulong) options.thresholdPerMille * total;
        bool meetsMinimum = matched >= options.minimumMatches;
        if (!meetsThreshold || !meetsMinimum) continue;
        if (result.candidates.length >= maxInferredCandidates) {
            result.warning = InferenceWarning.candidateOverflow;
            continue;
        }
        result.candidates ~= InferredCandidate(topic.displayValue, canonicalKeyOf(topic.displayValue),
            topic.hierarchy.dup, CandidateOrigin.inferred, false,
            InferredEvidence(controlledTokenV1, topic.topicId, matched, total,
                options.thresholdPerMille, options.minimumMatches, matches));
    }
    if (result.candidates.length == 0 && result.warning == InferenceWarning.none)
        result.abstention = InferenceAbstention.noMatch;
    return result;
}

// ---------------------------------------------------------------------------
// The bound annotation value.
// ---------------------------------------------------------------------------

struct TopicalTagsIdentity {
    DocumentId documentId;
    ubyte[32] textRevision;
    bool hasEvidence;
    ubyte[32] evidenceDigest;
    uint normalizationVersion = topicalNormalizationVersion;
    ubyte[32] analyzerIdentity;
    ubyte[32] algorithmIdentity;
    ubyte[32] vocabularyIdentity;
    string language;
    ubyte[32] optionsIdentity;
}

struct TopicalTagsAnnotation {
    TopicalTagsIdentity identity;
    DeclaredCandidate[] declared;
    InferredCandidate[] inferred;
    InferenceAbstention abstention;
    InferenceWarning warning;
}

ubyte[32] algorithmIdentityFor(string algorithmName) {
    auto bytes = appender!(ubyte[]);
    bytes.put(cast(const(ubyte)[]) "scrubbed:topical-tags:algorithm:v1\0");
    appendField(bytes, algorithmName);
    return sha256Of(bytes.data);
}

private ubyte[32] computeAnalyzerIdentity(ubyte[32] algorithmIdentity, ubyte[32] vocabularyIdentity,
    ubyte[32] optionsIdentity, string language, uint normalizationVersion) {
    auto bytes = appender!(ubyte[]);
    bytes.put(cast(const(ubyte)[]) "scrubbed:topical-tags:analyzer:v1\0");
    bytes.put(algorithmIdentity[]);
    bytes.put(vocabularyIdentity[]);
    bytes.put(optionsIdentity[]);
    appendField(bytes, language);
    appendU32(bytes, normalizationVersion);
    return sha256Of(bytes.data);
}

private ubyte[] canonicalDeclaredBytes(const(DeclaredCandidate)[] declared) {
    auto bytes = appender!(ubyte[]);
    bytes.put(cast(const(ubyte)[]) "scrubbed:topical-tags:declared:v1\0");
    appendU32(bytes, cast(uint) declared.length);
    foreach (candidate; declared) {
        appendField(bytes, candidate.displayValue);
        appendField(bytes, candidate.canonicalKey);
        appendU8(bytes, cast(ubyte) candidate.hierarchy.length);
        foreach (segment; candidate.hierarchy) appendField(bytes, segment);
        appendU8(bytes, candidate.duplicateKey ? 1 : 0);
        appendField(bytes, candidate.evidence.sourceRuleId);
        appendField(bytes, candidate.evidence.extractorId);
        appendU32(bytes, cast(uint) candidate.evidence.sourceNode);
    }
    return bytes.data;
}

/// Build a bound, checked annotation. `canonicalText` must already be the
/// canonical UTF-8 extracted text this module treats as authoritative; its
/// exact SHA-256 becomes the binding revision. Revision/config/vocabulary/
/// analyzer drift is caught by `checkTopicalTags`/`decodeTopicalTags`, not
/// by re-deriving text canonicalization here.
TopicalTagsAnnotation buildAnnotation(DocumentId documentId, const(ubyte)[] canonicalText,
    const(DeclaredObservation)[] declaredObservations, Vocabulary vocabulary,
    string language, MatchOptions options) {
    TopicalTagsAnnotation result;
    result.identity.documentId = documentId;
    result.identity.textRevision = sha256Of(canonicalText);
    result.declared = canonicalizeDeclared(declaredObservations);
    result.identity.hasEvidence = result.declared.length != 0;
    result.identity.evidenceDigest = result.identity.hasEvidence ?
        sha256Of(canonicalDeclaredBytes(result.declared)) : (ubyte[32]).init;
    result.identity.normalizationVersion = topicalNormalizationVersion;
    result.identity.algorithmIdentity = algorithmIdentityFor(controlledTokenV1);
    result.identity.vocabularyIdentity = vocabulary.identity;
    result.identity.language = language;
    result.identity.optionsIdentity = options.identity;
    result.identity.analyzerIdentity = computeAnalyzerIdentity(result.identity.algorithmIdentity,
        result.identity.vocabularyIdentity, result.identity.optionsIdentity, language,
        result.identity.normalizationVersion);
    string text;
    bool validUtf8 = true;
    try { validate(cast(string) canonicalText); text = cast(string) canonicalText; }
    catch (UTFException) validUtf8 = false;
    if (validUtf8) {
        auto inference = inferControlledTokenV1(text, vocabulary, language, options);
        result.inferred = inference.candidates;
        result.abstention = inference.abstention;
        result.warning = inference.warning;
    } else {
        result.abstention = InferenceAbstention.invalidCanonicalText;
    }
    checkTopicalTags(result);
    return result;
}

/// Refuse malformed, oversize, or internally inconsistent annotations.
/// Mutation controls here must be effective with assertions disabled, so
/// every check uses `enforce`, never `assert`.
void checkTopicalTags(ref const TopicalTagsAnnotation value) {
    enforce(value.identity.normalizationVersion == topicalNormalizationVersion,
        "topical tags: unsupported normalization version");
    enforce(value.identity.documentId.text.length != 0, "topical tags: unbound document id");
    enforce(value.identity.language.length <= maxIdBytes, "topical tags: malformed language");
    enforce(value.declared.length <= maxDeclaredCandidates, "topical tags: declared candidate overflow");
    enforce(value.inferred.length <= maxInferredCandidates, "topical tags: inferred candidate overflow");
    enforce(value.identity.hasEvidence == (value.declared.length != 0),
        "topical tags: evidence flag mismatch");
    if (value.identity.hasEvidence)
        enforce(value.identity.evidenceDigest == sha256Of(canonicalDeclaredBytes(value.declared)),
            "topical tags: evidence digest mismatch");
    else
        enforce(value.identity.evidenceDigest == (ubyte[32]).init,
            "topical tags: evidence digest present without evidence");
    auto recomputedAnalyzer = computeAnalyzerIdentity(value.identity.algorithmIdentity,
        value.identity.vocabularyIdentity, value.identity.optionsIdentity, value.identity.language,
        value.identity.normalizationVersion);
    enforce(recomputedAnalyzer == value.identity.analyzerIdentity,
        "topical tags: analyzer identity mismatch");
    bool[string] seenDeclaredKeys;
    foreach (candidate; value.declared) {
        enforce(candidate.displayValue.length != 0 && candidate.displayValue.length <= maxDisplayBytes,
            "topical tags: malformed declared display value");
        enforce(candidate.canonicalKey.length <= maxKeyBytes, "topical tags: malformed declared key");
        enforce(candidate.hierarchy.length <= maxHierarchyDepth, "topical tags: declared hierarchy too deep");
        foreach (segment; candidate.hierarchy)
            enforce(segment.length != 0 && segment.length <= maxDisplayBytes,
                "topical tags: malformed declared hierarchy segment");
        enforce(candidate.origin == CandidateOrigin.declared, "topical tags: declared origin mismatch");
        enforce(candidate.evidence.sourceRuleId.length != 0 &&
            candidate.evidence.sourceRuleId.length <= maxIdBytes,
            "topical tags: malformed declared source rule id");
        enforce(candidate.evidence.extractorId.length != 0 &&
            candidate.evidence.extractorId.length <= maxIdBytes,
            "topical tags: malformed declared extractor id");
        enforce(candidate.evidence.sourceNode <= uint.max, "topical tags: declared source node out of range");
        bool expectedDuplicate = (candidate.canonicalKey in seenDeclaredKeys) !is null;
        enforce(candidate.duplicateKey == expectedDuplicate, "topical tags: declared duplicate flag mismatch");
        seenDeclaredKeys[candidate.canonicalKey] = true;
    }
    uint sharedThreshold, sharedMinimum;
    bool haveShared;
    foreach (candidate; value.inferred) {
        enforce(candidate.displayValue.length != 0 && candidate.displayValue.length <= maxDisplayBytes,
            "topical tags: malformed inferred display value");
        enforce(candidate.canonicalKey.length <= maxKeyBytes, "topical tags: malformed inferred key");
        enforce(candidate.hierarchy.length <= maxHierarchyDepth, "topical tags: inferred hierarchy too deep");
        foreach (segment; candidate.hierarchy)
            enforce(segment.length != 0 && segment.length <= maxDisplayBytes,
                "topical tags: malformed inferred hierarchy segment");
        enforce(candidate.origin == CandidateOrigin.inferred, "topical tags: inferred origin mismatch");
        enforce(candidate.evidence.algorithmId.length != 0 &&
            candidate.evidence.algorithmId.length <= maxIdBytes,
            "topical tags: malformed inferred algorithm id");
        enforce(candidate.evidence.vocabularyId.length != 0 &&
            candidate.evidence.vocabularyId.length <= maxIdBytes,
            "topical tags: malformed inferred vocabulary id");
        enforce(candidate.evidence.evidenceTotal != 0 &&
            candidate.evidence.evidenceScore <= candidate.evidence.evidenceTotal,
            "topical tags: inconsistent inferred evidence score");
        enforce(candidate.evidence.threshold <= 1000, "topical tags: inferred threshold out of range");
        enforce(candidate.evidence.matches.length <= maxStoredMatches,
            "topical tags: inferred match overflow");
        foreach (match; candidate.evidence.matches) {
            enforce(match.termId.length != 0 && match.termId.length <= maxIdBytes,
                "topical tags: malformed inferred term id");
            enforce(match.start <= match.end && match.end <= maxCanonicalTextBytes,
                "topical tags: inferred match range out of range");
        }
        if (!haveShared) {
            sharedThreshold = candidate.evidence.threshold;
            sharedMinimum = candidate.evidence.minimumMatches;
            haveShared = true;
        } else {
            enforce(candidate.evidence.threshold == sharedThreshold &&
                candidate.evidence.minimumMatches == sharedMinimum,
                "topical tags: inferred candidates disagree on options");
        }
    }
    if (haveShared) {
        MatchOptions recomputed = MatchOptions(sharedThreshold, sharedMinimum);
        enforce(recomputed.identity == value.identity.optionsIdentity,
            "topical tags: options identity mismatch");
    }
}

// ---------------------------------------------------------------------------
// Canonical encode/decode wire.
// ---------------------------------------------------------------------------

private void appendU8(ref Appender!(ubyte[]) bytes, ubyte value) { bytes.put(value); }

private void appendU32(ref Appender!(ubyte[]) bytes, uint value) {
    foreach_reverse (shift; [0, 8, 16, 24]) bytes.put(cast(ubyte)(value >> shift));
}

private void appendDigest(ref Appender!(ubyte[]) bytes, ubyte[32] value) { bytes.put(value[]); }

private void appendField(ref Appender!(ubyte[]) bytes, string value) {
    enforce(value.length <= uint.max, "topical tags: field too long");
    appendU32(bytes, cast(uint) value.length);
    bytes.put(cast(const(ubyte)[]) value);
}

private ubyte readU8(const(ubyte)[] bytes, ref size_t at) {
    enforce(at < bytes.length, "topical tags: truncated record");
    return bytes[at++];
}

private uint readU32(const(ubyte)[] bytes, ref size_t at) {
    enforce(bytes.length - at >= 4, "topical tags: truncated record");
    uint value;
    foreach (_; 0 .. 4) value = (value << 8) | bytes[at++];
    return value;
}

private ubyte[32] readDigest(const(ubyte)[] bytes, ref size_t at) {
    enforce(bytes.length - at >= 32, "topical tags: truncated record");
    ubyte[32] value = bytes[at .. at + 32];
    at += 32;
    return value;
}

private string readField(const(ubyte)[] bytes, ref size_t at, size_t cap) {
    auto length = readU32(bytes, at);
    enforce(length <= cap && length <= bytes.length - at, "topical tags: truncated or oversize field");
    auto value = cast(string) bytes[at .. at + length].idup;
    at += length;
    return value;
}

/// Canonical wire encoding. Duplicate flags, ordering, and every identity
/// field travel with the record so `decodeTopicalTags` can catch drift.
ubyte[] encodeTopicalTags(TopicalTagsAnnotation value) {
    checkTopicalTags(value);
    auto bytes = appender!(ubyte[]);
    bytes.put(cast(const(ubyte)[]) "scrubbed:topical-tags:v1\0");
    appendU32(bytes, topicalTagsSchema);
    appendField(bytes, value.identity.documentId.text);
    appendDigest(bytes, value.identity.textRevision);
    appendU8(bytes, value.identity.hasEvidence ? 1 : 0);
    appendDigest(bytes, value.identity.evidenceDigest);
    appendU32(bytes, value.identity.normalizationVersion);
    appendDigest(bytes, value.identity.analyzerIdentity);
    appendDigest(bytes, value.identity.algorithmIdentity);
    appendDigest(bytes, value.identity.vocabularyIdentity);
    appendField(bytes, value.identity.language);
    appendDigest(bytes, value.identity.optionsIdentity);
    appendU8(bytes, cast(ubyte) value.abstention);
    appendU8(bytes, cast(ubyte) value.warning);
    appendU32(bytes, cast(uint) value.declared.length);
    foreach (candidate; value.declared) {
        appendField(bytes, candidate.displayValue);
        appendField(bytes, candidate.canonicalKey);
        appendU8(bytes, cast(ubyte) candidate.hierarchy.length);
        foreach (segment; candidate.hierarchy) appendField(bytes, segment);
        appendU8(bytes, candidate.duplicateKey ? 1 : 0);
        appendField(bytes, candidate.evidence.sourceRuleId);
        appendField(bytes, candidate.evidence.extractorId);
        appendU32(bytes, cast(uint) candidate.evidence.sourceNode);
    }
    appendU32(bytes, cast(uint) value.inferred.length);
    foreach (candidate; value.inferred) {
        appendField(bytes, candidate.displayValue);
        appendField(bytes, candidate.canonicalKey);
        appendU8(bytes, cast(ubyte) candidate.hierarchy.length);
        foreach (segment; candidate.hierarchy) appendField(bytes, segment);
        appendU8(bytes, candidate.duplicateKey ? 1 : 0);
        appendField(bytes, candidate.evidence.algorithmId);
        appendField(bytes, candidate.evidence.vocabularyId);
        appendU32(bytes, candidate.evidence.evidenceScore);
        appendU32(bytes, candidate.evidence.evidenceTotal);
        appendU32(bytes, candidate.evidence.threshold);
        appendU32(bytes, candidate.evidence.minimumMatches);
        appendU8(bytes, cast(ubyte) candidate.evidence.matches.length);
        foreach (match; candidate.evidence.matches) {
            appendField(bytes, match.termId);
            appendU32(bytes, cast(uint) match.start);
            appendU32(bytes, cast(uint) match.end);
        }
    }
    auto payload = bytes.data;
    // A whole-record checksum trailer, independent of the per-field identity
    // digests above, gives exhaustive single-byte tamper evidence across
    // every field (including inferred score/threshold/range/term bytes that
    // no narrower identity check covers).
    auto result = payload ~ sha256Of(payload)[];
    enforce(result.length <= maxAnnotationBytes, "topical tags: annotation exceeds ceiling");
    return result;
}

/// Decode and fully re-validate a stored annotation, binding it to the
/// caller-supplied `expectedId`/`expectedTextRevision` (obtained
/// independently, e.g. from a C01 join). Any wrong document, revision,
/// evidence, analyzer, algorithm, vocabulary, or options identity;
/// malformed UTF-8/NFC/key/hierarchy/order/duplicates; changed
/// score/threshold/range/term; truncation; or trailing data is rejected.
TopicalTagsAnnotation decodeTopicalTags(const(ubyte)[] wireBytes, DocumentId expectedId,
    ubyte[32] expectedTextRevision) {
    enforce(wireBytes.length <= maxAnnotationBytes, "topical tags: annotation exceeds ceiling");
    enforce(wireBytes.length >= 32, "topical tags: truncated record");
    auto bytes = wireBytes[0 .. $ - 32];
    auto trailer = wireBytes[$ - 32 .. $];
    enforce(sha256Of(bytes)[] == trailer, "topical tags: record checksum mismatch");
    auto prefix = cast(const(ubyte)[]) "scrubbed:topical-tags:v1\0";
    enforce(bytes.length >= prefix.length && bytes[0 .. prefix.length] == prefix,
        "topical tags: malformed domain tag");
    size_t at = prefix.length;
    TopicalTagsAnnotation result;
    enforce(readU32(bytes, at) == topicalTagsSchema, "topical tags: unsupported schema");
    auto idText = readField(bytes, at, 128);
    result.identity.documentId = DocumentId.fromCanonicalText(idText);
    enforce(result.identity.documentId == expectedId, "topical tags: document id mismatch");
    result.identity.textRevision = readDigest(bytes, at);
    enforce(result.identity.textRevision == expectedTextRevision,
        "topical tags: text revision mismatch");
    result.identity.hasEvidence = readU8(bytes, at) != 0;
    result.identity.evidenceDigest = readDigest(bytes, at);
    result.identity.normalizationVersion = readU32(bytes, at);
    result.identity.analyzerIdentity = readDigest(bytes, at);
    result.identity.algorithmIdentity = readDigest(bytes, at);
    result.identity.vocabularyIdentity = readDigest(bytes, at);
    result.identity.language = readField(bytes, at, maxIdBytes);
    result.identity.optionsIdentity = readDigest(bytes, at);
    auto abstentionValue = readU8(bytes, at);
    enforce(abstentionValue <= InferenceAbstention.max, "topical tags: malformed abstention");
    result.abstention = cast(InferenceAbstention) abstentionValue;
    auto warningValue = readU8(bytes, at);
    enforce(warningValue <= InferenceWarning.max, "topical tags: malformed warning");
    result.warning = cast(InferenceWarning) warningValue;
    auto declaredCount = readU32(bytes, at);
    enforce(declaredCount <= maxDeclaredCandidates, "topical tags: declared candidate overflow");
    foreach (_; 0 .. declaredCount) {
        auto display = readField(bytes, at, maxDisplayBytes);
        auto key = readField(bytes, at, maxKeyBytes);
        auto hierarchyCount = readU8(bytes, at);
        enforce(hierarchyCount <= maxHierarchyDepth, "topical tags: declared hierarchy too deep");
        string[] hierarchy;
        foreach (__; 0 .. hierarchyCount) hierarchy ~= readField(bytes, at, maxDisplayBytes);
        auto duplicate = readU8(bytes, at) != 0;
        auto ruleId = readField(bytes, at, maxIdBytes);
        auto extractorId = readField(bytes, at, maxIdBytes);
        auto node = readU32(bytes, at);
        result.declared ~= DeclaredCandidate(display, key, hierarchy, CandidateOrigin.declared,
            duplicate, DeclaredEvidence(ruleId, extractorId, node));
    }
    auto inferredCount = readU32(bytes, at);
    enforce(inferredCount <= maxInferredCandidates, "topical tags: inferred candidate overflow");
    foreach (_; 0 .. inferredCount) {
        auto display = readField(bytes, at, maxDisplayBytes);
        auto key = readField(bytes, at, maxKeyBytes);
        auto hierarchyCount = readU8(bytes, at);
        enforce(hierarchyCount <= maxHierarchyDepth, "topical tags: inferred hierarchy too deep");
        string[] hierarchy;
        foreach (__; 0 .. hierarchyCount) hierarchy ~= readField(bytes, at, maxDisplayBytes);
        auto duplicate = readU8(bytes, at) != 0;
        auto algorithmId = readField(bytes, at, maxIdBytes);
        auto vocabularyId = readField(bytes, at, maxIdBytes);
        auto score = readU32(bytes, at);
        auto total = readU32(bytes, at);
        auto threshold = readU32(bytes, at);
        auto minimumMatches = readU32(bytes, at);
        auto matchCount = readU8(bytes, at);
        enforce(matchCount <= maxStoredMatches, "topical tags: inferred match overflow");
        TermMatch[] matches;
        foreach (__; 0 .. matchCount) {
            auto termId = readField(bytes, at, maxIdBytes);
            auto start = readU32(bytes, at);
            auto end = readU32(bytes, at);
            matches ~= TermMatch(termId, start, end);
        }
        result.inferred ~= InferredCandidate(display, key, hierarchy, CandidateOrigin.inferred,
            duplicate, InferredEvidence(algorithmId, vocabularyId, score, total, threshold,
                minimumMatches, matches));
    }
    enforce(at == bytes.length, "topical tags: trailing data");
    checkTopicalTags(result);
    return result;
}

/// Deterministic identity of an exact encoded annotation, for later
/// idempotent-skip/retry bookkeeping by a durable sink outside this slice.
ubyte[32] annotationDigest(const(ubyte)[] encoded) { return sha256Of(encoded); }

// ---------------------------------------------------------------------------
// Selection: a pure, explicit read that never mutates the annotation and is
// never applied implicitly by construction.
// ---------------------------------------------------------------------------

struct SelectedTopic {
    CandidateOrigin origin;
    DeclaredCandidate declared;
    InferredCandidate inferred;
}

/// `none` selects nothing. `union_` retains origin/evidence on every
/// selected reference and never rewrites inferred data as declared/author
/// metadata.
SelectedTopic[] select(TopicalTagsAnnotation annotation, SelectionPolicy policy) {
    SelectedTopic[] result;
    if (policy == SelectionPolicy.sourceOnly || policy == SelectionPolicy.union_)
        foreach (candidate; annotation.declared)
            result ~= SelectedTopic(CandidateOrigin.declared, candidate, InferredCandidate.init);
    if (policy == SelectionPolicy.inferredOnly || policy == SelectionPolicy.union_)
        foreach (candidate; annotation.inferred)
            result ~= SelectedTopic(CandidateOrigin.inferred, DeclaredCandidate.init, candidate);
    return result;
}

// ---------------------------------------------------------------------------
// Unit tests.
// ---------------------------------------------------------------------------

version (unittest) {
    import domain.document : SourceLocator;

    private DocumentId testDocumentId() {
        return DocumentId.from(SourceLocator("topical-tags-unit", "source", "doc-1"));
    }

    private Vocabulary testVocabulary() {
        return Vocabulary.build([
            VocabularyTopic("topic.cooking", "Cooking", [],
                [VocabularyTerm("term.recipe", ["recipe"]),
                 VocabularyTerm("term.oven", ["oven"])]),
            VocabularyTopic("topic.finance", "Personal Finance", ["money"],
                [VocabularyTerm("term.budget", ["budget"]),
                 VocabularyTerm("term.tax-return", ["tax", "return"])]),
        ]);
    }
}

unittest {
    auto observations = [
        DeclaredObservation("Cooking", [], "meta.keywords", "html-metadata:v1", 3),
        DeclaredObservation("cooking", [], "meta.category", "html-metadata:v1", 7),
        DeclaredObservation("Café Culture", ["Lifestyle", "Food"], "meta.category",
            "html-metadata:v1", 9),
    ];
    auto declared = canonicalizeDeclared(observations);
    assert(declared.length == 3);
    assert(declared[0].canonicalKey == "cooking" && !declared[0].duplicateKey);
    assert(declared[1].canonicalKey == "cooking" && declared[1].duplicateKey);
    assert(declared[2].hierarchy == ["Lifestyle", "Food"]);
    assert(declared[2].displayValue == "Café Culture");
}

unittest {
    auto vocabulary = testVocabulary();
    auto options = MatchOptions(500, 1); // >=50% of a topic's terms, at least one match
    auto text = "This recipe needs a hot oven. File your tax return early.";
    auto inference = inferControlledTokenV1(text, vocabulary, "en", options);
    assert(inference.abstention == InferenceAbstention.none);
    assert(inference.candidates.length == 2);
    assert(inference.candidates[0].canonicalKey == "cooking");
    assert(inference.candidates[0].evidence.evidenceScore == 2 &&
        inference.candidates[0].evidence.evidenceTotal == 2);
    assert(inference.candidates[1].canonicalKey == "personal finance");
    assert(inference.candidates[1].evidence.evidenceScore == 1 &&
        inference.candidates[1].evidence.evidenceTotal == 2);
    auto taxMatch = inference.candidates[1].evidence.matches;
    assert(taxMatch.length == 1 && taxMatch[0].termId == "term.tax-return");
    assert(text[taxMatch[0].start .. taxMatch[0].end] == "tax return");

    auto noMatch = inferControlledTokenV1("nothing relevant here", vocabulary, "en", options);
    assert(noMatch.abstention == InferenceAbstention.noMatch && noMatch.candidates.length == 0);

    auto unsupported = inferControlledTokenV1(text, vocabulary, "und", options);
    assert(unsupported.abstention == InferenceAbstention.unsupportedLanguage);
    auto missingLanguage = inferControlledTokenV1(text, vocabulary, "fr", options);
    assert(missingLanguage.abstention == InferenceAbstention.unsupportedLanguage);

    auto empty = inferControlledTokenV1("", vocabulary, "en", options);
    assert(empty.abstention == InferenceAbstention.emptyCanonicalText);

    auto oversized = new char[maxCanonicalTextBytes + 1];
    oversized[] = 'a';
    auto tooBig = inferControlledTokenV1(cast(string) oversized, vocabulary, "en", options);
    assert(tooBig.abstention == InferenceAbstention.oversizeCanonicalText);
}

unittest {
    import std.exception : assertThrown;

    auto id = testDocumentId();
    auto text = cast(const(ubyte)[]) "A recipe for a hot oven dish, plus a tax return note.";
    auto observations = [
        DeclaredObservation("Weeknight Cooking", ["Food"], "meta.category", "html-metadata:v1", 2),
    ];
    auto annotation = buildAnnotation(id, text, observations, testVocabulary(), "en",
        MatchOptions(500, 1));
    assert(annotation.identity.hasEvidence);
    assert(annotation.declared.length == 1 && annotation.inferred.length == 2);
    assert(annotation.identity.textRevision == sha256Of(text));

    auto encoded = encodeTopicalTags(annotation);
    auto decoded = decodeTopicalTags(encoded, id, annotation.identity.textRevision);
    assert(decoded == annotation);
    assert(encodeTopicalTags(decoded) == encoded);

    // Wrong document/revision identity is rejected.
    auto otherId = DocumentId.from(SourceLocator("topical-tags-unit", "source", "doc-2"));
    assertThrown(decodeTopicalTags(encoded, otherId, annotation.identity.textRevision));
    ubyte[32] wrongRevision = sha256Of(cast(const(ubyte)[]) "different text");
    assertThrown(decodeTopicalTags(encoded, id, wrongRevision));

    // Truncation and trailing data are rejected.
    assertThrown(decodeTopicalTags(encoded[0 .. $ - 1], id, annotation.identity.textRevision));
    auto trailing = encoded.dup ~ cast(ubyte) 0;
    assertThrown(decodeTopicalTags(trailing, id, annotation.identity.textRevision));

    // Flipping any embedded identity digest is caught by the analyzer-identity
    // umbrella recompute, without decode() needing those raw values back.
    foreach (offset; [prefixOffset("analyzerIdentity", encoded),
            prefixOffset("algorithmIdentity", encoded), prefixOffset("vocabularyIdentity", encoded),
            prefixOffset("optionsIdentity", encoded)]) {
        auto corrupt = encoded.dup;
        corrupt[offset] ^= 1;
        assertThrown(decodeTopicalTags(corrupt, id, annotation.identity.textRevision));
    }

    // Corrupting a declared candidate byte invalidates the evidence digest.
    auto declaredOffset = declaredFieldOffset(encoded);
    auto corruptEvidence = encoded.dup;
    corruptEvidence[declaredOffset] ^= 1;
    assertThrown(decodeTopicalTags(corruptEvidence, id, annotation.identity.textRevision));
}

// Locates a fixed-offset digest field within the encoded record by replaying
// the same encoder layout, so identity-mutation tests do not hardcode
// brittle byte offsets across module edits.
version (unittest) private size_t prefixOffset(string field, const(ubyte)[] encoded) {
    size_t at = "scrubbed:topical-tags:v1\0".length;
    at += 4; // schema
    auto idLength = readU32(encoded, at);
    at += idLength; // documentId field body
    at += 32; // textRevision
    at += 1; // hasEvidence
    at += 32; // evidenceDigest
    at += 4; // normalizationVersion
    if (field == "analyzerIdentity") return at;
    at += 32;
    if (field == "algorithmIdentity") return at;
    at += 32;
    if (field == "vocabularyIdentity") return at;
    at += 32;
    auto languageLength = readU32(encoded, at);
    at += languageLength;
    if (field == "optionsIdentity") return at;
    assert(0, "unknown field");
}

version (unittest) private size_t declaredFieldOffset(const(ubyte)[] encoded) {
    size_t at = prefixOffset("optionsIdentity", encoded) + 32;
    at += 1; // abstention
    at += 1; // warning
    at += 4; // declared count (must be >= 1 for the caller's fixture)
    return at; // first byte of the first declared candidate's display-value length
}
