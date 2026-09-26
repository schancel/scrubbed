/// Pure, bounded, deterministic character-n-gram language identification for
/// an explicit four-language set (English, Spanish, French, German), with a
/// typed result/abstention shape and a revision-bound identity/wire idiom
/// mirroring `domain.topical_tags`. This module does not parse HTML,
/// register a pipeline stage, expose CLI/config, or publish durable/overlay
/// output; classification is a Cavnar & Trenkle-style out-of-place
/// character-n-gram rank distance over a small authored, checked-in profile
/// table — no embedded ML/statistical model, no network/model-download
/// dependency, and no calibrated-probability claim.
module domain.language_id;

import domain.document : DocumentId;
import crypto.sha256 : sha256Of;
import std.algorithm.sorting : sort;
import std.array : Appender, appender;
import std.conv : to;
import std.exception : enforce;
import std.math : lround;
import std.uni : isAlpha, toLower;
import std.utf : UTFException, decode, validate;

enum uint languageIdSchema = 1;
enum uint languageIdAlgorithmVersion = 1;

/// Reuses the existing C01 bounded-document byte cap value (see
/// `domain.shard_format.maxDocumentPayload` / `domain.topical_tags
/// .maxCanonicalTextBytes`, both `1024 * 1024`); this module keeps its own
/// locally named constant of the same value, following this codebase's
/// existing per-module-cap convention, rather than cross-importing another
/// domain module's constant.
enum size_t maxLanguageIdTextBytes = 1024 * 1024;

enum size_t ngramMinOrder = 1;
enum size_t ngramMaxOrder = 4;

/// Top-N ranked n-grams retained per language profile and per scored
/// document, per the accepted contract's "top ~300, capped" instruction.
enum size_t profileCap = 300;

// ---------------------------------------------------------------------------
// Pinned cutoffs. Two of these are explicitly flagged for owner sign-off in
// the implementation handoff, per the accepted contract's instruction not to
// silently bake in a number: `minNgramCount` (the `tooShort` cutoff) and the
// absence of any default for `routeLanguage`'s threshold parameter. The
// others below are ordinary implementation constants, documented here and in
// docs/language-id.md, but not separately flagged.
// ---------------------------------------------------------------------------

/// Minimum total n-gram occurrence count (n=1..4 combined, i.e. sum of all
/// per-n-gram counts, not distinct n-gram types) before a text carries a
/// meaningful character-n-gram signal. Below this, abstain via `tooShort`
/// rather than classify from too little evidence. **Pinned by the
/// implementer via the boundary goldens in
/// `experiments/language_id/check.d`; flagged explicitly for owner
/// sign-off** — it has not been independently validated against a wider
/// corpus than this module's own small authored fixtures.
enum size_t minNgramCount = 60;

/// Cheap pre-check bound: texts whose letters are more than this fraction
/// non-Latin-script abstain via `unsupportedScript` before any n-gram
/// scoring runs, protecting against forcing non-Latin text into this
/// four-language Latin-script classifier.
enum double nonLatinScriptBound = 0.3;

/// Best-vs-second-best relative margin floor, normalized against the
/// worst-case out-of-place distance. Below this the top two candidates are
/// too close to call and the result abstains via `mixedOrAmbiguous` rather
/// than arbitrarily picking one.
enum double mixedMarginBound = 0.02;

/// Absolute relative-confidence floor below which the best candidate is
/// abstained via `belowConfidenceThreshold`, even when it is not a close
/// race against the second-best candidate (e.g. no supported language
/// matches the text well at all). This is an internal detection floor,
/// independent of `routeLanguage`'s caller-supplied external threshold; no
/// default is pinned for that one in this slice.
enum double internalConfidenceFloor = 0.15;

enum SupportedLanguage : ubyte { en, es, fr, de }

enum LanguageDetectionStatus : ubyte { detected, abstained }

/// Named per the contract. `none` means a `detected` result.
enum LanguageAbstentionReason : ubyte {
    none,
    emptyText,
    invalidUtf8,
    oversizeText,
    tooShort,
    unsupportedScript,
    mixedOrAmbiguous,
    belowConfidenceThreshold,
}

/// A relative (NOT a calibrated probability), bounded-precision confidence
/// in `[0, 1]`, quantized to whole per-mille so the value returned here
/// round-trips exactly through `encodeLanguageIdentity`/
/// `decodeLanguageIdentity`.
struct LanguageDetectionResult {
    LanguageDetectionStatus status;
    SupportedLanguage language;
    double confidence = 0.0;
    LanguageAbstentionReason reason;
}

/// Binds the typed `DocumentId`, the exact 32-byte SHA-256 revision of the
/// scored text, a digest identifying the exact embedded profile table
/// content, and the algorithm version.
struct LanguageIdentity {
    DocumentId documentId;
    ubyte[32] textRevision;
    ubyte[32] profileTableIdentity;
    uint algorithmVersion = languageIdAlgorithmVersion;
}

/// The bound, wire-encodable value: identity plus the detection result.
struct LanguageIdentityRecord {
    LanguageIdentity identity;
    LanguageDetectionResult result;
}

/// A separate pure routing decision: only a `detected`, at-or-above-
/// `threshold` result routes to a usable language. Everything else
/// (abstained, or detected-but-below-threshold) stays explicitly
/// unclassified. No default threshold is pinned in this slice — every
/// caller must supply one explicitly.
struct RoutedLanguage {
    bool routed;
    SupportedLanguage language;
}

RoutedLanguage routeLanguage(LanguageDetectionResult result, float threshold) pure nothrow @nogc {
    if (result.status == LanguageDetectionStatus.detected && result.confidence >= threshold)
        return RoutedLanguage(true, result.language);
    return RoutedLanguage(false, SupportedLanguage.init);
}

// ---------------------------------------------------------------------------
// Character-n-gram extraction. Shared by profile generation (called from
// `experiments/language_id/generate_profiles.d` against the checked-in seed
// corpora) and by document scoring below, so both paths run byte-for-byte
// the same deterministic algorithm.
// ---------------------------------------------------------------------------

private bool isLatinLetter(dchar c) pure nothrow @nogc {
    return (c >= 0x0041 && c <= 0x005A) || (c >= 0x0061 && c <= 0x007A) ||
        (c >= 0x00C0 && c <= 0x00FF) || (c >= 0x0100 && c <= 0x017F) ||
        (c >= 0x0180 && c <= 0x024F);
}

private struct ScriptCounts { size_t letters; size_t nonLatinLetters; }

private ScriptCounts scriptCountsOf(string text) {
    ScriptCounts counts;
    size_t at;
    while (at < text.length) {
        dchar c = decode(text, at); // text is already UTF-8 validated by the caller
        if (isAlpha(c)) {
            ++counts.letters;
            if (!isLatinLetter(c)) ++counts.nonLatinLetters;
        }
    }
    return counts;
}

/// Maximal runs of Unicode letters, lowercased, with all other characters
/// (whitespace, digits, punctuation) treated as separators and dropped.
private dchar[][] wordsOf(string text) {
    dchar[][] words;
    dchar[] current;
    size_t at;
    while (at < text.length) {
        dchar c = decode(text, at);
        if (isAlpha(c)) current ~= toLower(c);
        else if (current.length) { words ~= current; current = null; }
    }
    if (current.length) words ~= current;
    return words;
}

/// Pads each word with one leading/trailing space and slides an n=1..4
/// window across the padded codepoints, so n-grams capture word-boundary
/// context exactly as Cavnar & Trenkle's original algorithm does.
private void countNgramsInto(ref size_t[string] counts, const(dchar[])[] words) {
    foreach (word; words) {
        dchar[] padded = [cast(dchar) ' '] ~ word.dup ~ [cast(dchar) ' '];
        foreach (n; ngramMinOrder .. ngramMaxOrder + 1) {
            if (padded.length < n) continue;
            foreach (start; 0 .. padded.length - n + 1) {
                auto ngram = to!string(padded[start .. start + n]);
                if (auto existing = ngram in counts) ++(*existing);
                else counts[ngram] = 1;
            }
        }
    }
}

private struct NgramCount { string ngram; size_t count; }

/// Deterministic total order: count descending, then n-gram ascending
/// (UTF-8 byte order) breaks ties without depending on hash-table iteration
/// order, which D does not guarantee to be stable across runs/versions.
private NgramCount[] rankedFromCounts(const(size_t[string]) counts, size_t cap) {
    NgramCount[] all;
    foreach (ngram, count; counts) all ~= NgramCount(ngram, count);
    sort!((a, b) => a.count != b.count ? a.count > b.count : a.ngram < b.ngram)(all);
    return all.length > cap ? all[0 .. cap] : all;
}

/// Deterministic ranked n-gram profile (n=1..4, Cavnar & Trenkle
/// out-of-place style, top `profileCap` entries, ties broken by ascending
/// n-gram string) computed from raw authored corpus text. Exposed publicly
/// so `experiments/language_id/generate_profiles.d` can recompute the exact
/// embedded tables below from the checked-in seed corpus, and
/// `experiments/language_id/check.d` can assert byte-identical
/// reproduction (the drift-detection proof required by the contract).
string[] rankedNgramProfile(string corpusText) {
    validate(corpusText); // throws UTFException on malformed input
    auto words = wordsOf(corpusText);
    size_t[string] counts;
    countNgramsInto(counts, words);
    string[] result;
    foreach (entry; rankedFromCounts(counts, profileCap)) result ~= entry.ngram;
    return result;
}

/// Total n-gram occurrence count (n=1..4 combined, i.e. sum of all
/// per-n-gram counts, not distinct n-gram types) that `detectLanguage` would
/// compute for `text` at its `tooShort` check. Exposed so callers, and
/// `experiments/language_id/check.d`'s boundary goldens, can construct or
/// verify text at an exact `minNgramCount` boundary without duplicating the
/// counting logic. Every whole word of letter-length `L` contributes exactly
/// `4*L + 2` to this total (from its one-space-padded n=1..4 window count),
/// so this total is always even for any input text.
size_t totalNgramCount(string text) {
    validate(text);
    auto words = wordsOf(text);
    size_t[string] counts;
    countNgramsInto(counts, words);
    size_t total;
    foreach (count; counts.byValue) total += count;
    return total;
}

// ---------------------------------------------------------------------------
// Embedded profile tables. GENERATED by
// `experiments/language_id/generate_profiles.d` from the checked-in seed
// corpora under `experiments/language_id/fixtures/profiles/`; do not hand-
// edit. `experiments/language_id/check.d` re-runs the generator and asserts
// byte-identical output against these exact tables.
// ---------------------------------------------------------------------------

static immutable string[] languageProfileEn = [
    " ",
    "e",
    "t",
    "r",
    "s",
    "a",
    "n",
    "o",
    "i",
    "h",
    "l",
    " t",
    "e ",
    "he",
    "d",
    " th",
    "th",
    "he ",
    " the",
    "the",
    "the ",
    "s ",
    "u",
    "m",
    "c",
    "y",
    "in",
    " s",
    "f",
    "g",
    "d ",
    "n ",
    "y ",
    "p",
    "w",
    "b",
    "er",
    "v",
    " a",
    " o",
    "re",
    "ed",
    " b",
    "ar",
    "en",
    "ng",
    "r ",
    "t ",
    "ve",
    " c",
    " m",
    " w",
    "ea",
    "ed ",
    "es",
    "k",
    "or",
    "ing",
    "nt",
    "ri",
    "st",
    " f",
    "g ",
    "il",
    "l ",
    "le",
    "ng ",
    "on",
    "on ",
    " a ",
    " e",
    " n",
    " r",
    "a ",
    "ai",
    "an",
    "ch",
    "ing ",
    "la",
    "ne",
    "ou",
    "ti",
    " l",
    " p",
    "ee",
    "er ",
    "es ",
    "ly",
    "ly ",
    "se",
    " ne",
    " v",
    "ain",
    "al",
    "at",
    "br",
    "che",
    "ent",
    "ge",
    "ie",
    "in ",
    "ke",
    "ld",
    "ll",
    "m ",
    "nd",
    "pa",
    "pl",
    "ra",
    "ro",
    "ry",
    "ry ",
    "sh",
    "te",
    "to",
    "tr",
    "un",
    " br",
    " i",
    " mo",
    " of",
    " on",
    " on ",
    " re",
    " st",
    " to",
    " to ",
    " tr",
    "ac",
    "as",
    "di",
    "ds",
    "ds ",
    "el",
    "ery",
    "ery ",
    "et",
    "f ",
    "is",
    "k ",
    "le ",
    "ma",
    "me",
    "mo",
    "ni",
    "o ",
    "of",
    "oo",
    "pla",
    "rn",
    "si",
    "su",
    "to ",
    "ts",
    "ts ",
    "ur",
    "us",
    "ver",
    "w ",
    " ch",
    " d",
    " ev",
    " eve",
    " fr",
    " h",
    " in",
    " in ",
    " ma",
    " of ",
    " pa",
    " sh",
    " su",
    " tra",
    " wa",
    " wo",
    "ad",
    "ast",
    "bo",
    "ca",
    "co",
    "de",
    "ead",
    "ear",
    "en ",
    "ep",
    "ers",
    "ers ",
    "et ",
    "ev",
    "eve",
    "ew",
    "ew ",
    "fe",
    "fr",
    "h ",
    "hed",
    "hi",
    "ho",
    "io",
    "ir",
    "ld ",
    "lo",
    "ls",
    "ls ",
    "nin",
    "ning",
    "no",
    "nti",
    "ny",
    "ny ",
    "of ",
    "ol",
    "orn",
    "ov",
    "ove",
    "ow",
    "rai",
    "rd",
    "rk",
    "rm",
    "rs",
    "rs ",
    "she",
    "st ",
    "ta",
    "ter",
    "tra",
    "tu",
    "ud",
    "ul",
    "uri",
    "wa",
    "wo",
    "ys",
    " af",
    " aft",
    " ar",
    " bi",
    " bir",
    " bre",
    " bri",
    " bu",
    " che",
    " cl",
    " co",
    " di",
    " ex",
    " fa",
    " fro",
    " la",
    " lo",
    " man",
    " mor",
    " nea",
    " new",
    " no",
    " ol",
    " old",
    " pl",
    " pla",
    " sc",
    " se",
    " she",
    " stu",
    " sun",
    " u",
    " va",
    " vi",
    " wi",
    " win",
    " wor",
    "ach",
    "ad ",
    "af",
    "aft",
    "afte",
    "ain ",
    "al ",
    "all",
    "and",
    "ang",
    "any",
    "any ",
    "ar ",
    "ark",
    "arm",
    "ast ",
    "at ",
    "ati",
    "atio",
    "ay",
    "bi",
    "bir",
    "bird",
    "boo",
    "book",
    "bre",
    "bri",
    "brid",
    "bu",
];
static immutable string[] languageProfileEs = [
    " ",
    "a",
    "e",
    "s",
    "l",
    "r",
    "o",
    "n",
    "a ",
    "i",
    "c",
    "t",
    "s ",
    "d",
    "u",
    " l",
    " e",
    "e ",
    "m",
    "es",
    "p",
    "de",
    "en",
    "la",
    " c",
    "er",
    "o ",
    "v",
    "os",
    "n ",
    " p",
    "el",
    "nt",
    "ar",
    "l ",
    "os ",
    "ta",
    " d",
    " la",
    "an",
    "la ",
    "as",
    "b",
    " de",
    " la ",
    "el ",
    "na",
    "ra",
    "te",
    " a",
    " el",
    "ca",
    "es ",
    "re",
    " m",
    " v",
    "as ",
    "de ",
    "st",
    " el ",
    " s",
    "ent",
    "lo",
    "ad",
    "co",
    "le",
    "na ",
    "nte",
    "ue",
    " de ",
    " lo",
    "los",
    "los ",
    "pa",
    "ro",
    "ve",
    " co",
    "da",
    "en ",
    "f",
    "g",
    "r ",
    "se",
    "un",
    " en",
    " los",
    " pa",
    " t",
    " u",
    " un",
    "ci",
    "da ",
    "ie",
    "in",
    "li",
    "ll",
    "ma",
    "mi",
    "on",
    "ra ",
    "ta ",
    "vi",
    "ó",
    " ca",
    " en ",
    " n",
    "br",
    "ce",
    "ente",
    "h",
    "io",
    "j",
    "las",
    "no",
    "par",
    "ri",
    "sta",
    "te ",
    "tr",
    " a ",
    " se",
    " una",
    " ve",
    " vi",
    "al",
    "ana",
    "ant",
    "ec",
    "est",
    "ev",
    "il",
    "is",
    "las ",
    "nta",
    "nte ",
    "ntes",
    "pr",
    "q",
    "qu",
    "so",
    "tes",
    "tes ",
    "to",
    "una",
    "va",
    "ñ",
    "ó ",
    " b",
    " es",
    " f",
    " g",
    " le",
    " ma",
    " mu",
    " par",
    "ac",
    "ada",
    "ada ",
    "am",
    "ana ",
    "ante",
    "aro",
    "ca ",
    "cad",
    "cer",
    "der",
    "em",
    "erc",
    "erca",
    "ic",
    "ina",
    "ja",
    "me",
    "mu",
    "nd",
    "ol",
    "on ",
    "or",
    "ran",
    "rc",
    "rca",
    "rd",
    "ros",
    "ros ",
    "sa",
    "sta ",
    "una ",
    "ur",
    "ña",
    " cad",
    " ce",
    " cer",
    " con",
    " del",
    " est",
    " ex",
    " nu",
    " nue",
    " o",
    " pr",
    " r",
    "ab",
    "ade",
    "ader",
    "an ",
    "ar ",
    "ara",
    "ara ",
    "ard",
    "añ",
    "aña",
    "bre",
    "cada",
    "cerc",
    "ch",
    "con",
    "cu",
    "del",
    "del ",
    "di",
    "do",
    "end",
    "ende",
    "enta",
    "era",
    "ero",
    "ex",
    "ia",
    "ib",
    "id",
    "ist",
    "jar",
    "les",
    "les ",
    "lla",
    "men",
    "ment",
    "mil",
    "nde",
    "no ",
    "nu",
    "nue",
    "ob",
    "oc",
    "om",
    "para",
    "po",
    "pre",
    "pu",
    "que",
    "rca ",
    "ren",
    "res",
    "rm",
    "ro ",
    "si",
    "so ",
    "str",
    "su",
    "tra",
    "ua",
    "ues",
    "ui",
    "ura",
    "us",
    "ver",
    "vis",
    "x",
    "á",
    "é",
    "í",
    " al",
    " an",
    " br",
    " cl",
    " cla",
    " com",
    " cu",
    " des",
    " gu",
    " h",
    " las",
    " ll",
    " mañ",
    " mi",
    " muc",
    " no",
    " ob",
    " pan",
    " po",
    " por",
    " pre",
    " pu",
    " pue",
    " pá",
    " páj",
    " re",
    " sem",
    " sen",
    " si",
];
static immutable string[] languageProfileFr = [
    " ",
    "e",
    "a",
    "s",
    "l",
    "r",
    "n",
    "u",
    "i",
    "e ",
    "t",
    "s ",
    "o",
    " l",
    "d",
    "p",
    "c",
    "es",
    "es ",
    " d",
    "le",
    "nt",
    "m",
    "v",
    "re",
    "é",
    " le",
    " p",
    "de",
    "en",
    "t ",
    "la",
    " a",
    " c",
    "a ",
    " de",
    "an",
    "te",
    " la",
    "ou",
    "se",
    " la ",
    "er",
    "la ",
    "le ",
    "nt ",
    " s",
    "f",
    "ie",
    "in",
    "ur",
    "g",
    "h",
    "les",
    "les ",
    "r ",
    "u ",
    "b",
    "de ",
    "ent",
    "is",
    "n ",
    "re ",
    "ai",
    "ar",
    "au",
    "ch",
    "è",
    " de ",
    " e",
    " le ",
    " les",
    " m",
    " v",
    "ll",
    "ne",
    "q",
    "qu",
    "ri",
    "x",
    " o",
    "ant",
    "on",
    "pr",
    "te ",
    "ue",
    "é ",
    " f",
    "des",
    "des ",
    "em",
    "ent ",
    "eu",
    "il",
    "li",
    "ma",
    "po",
    "ré",
    "tr",
    "ue ",
    "ur ",
    "ve",
    " b",
    " ch",
    " cha",
    " des",
    " du",
    " du ",
    " po",
    " r",
    " u",
    " un",
    "cha",
    "co",
    "da",
    "du",
    "du ",
    "ha",
    "in ",
    "l ",
    "lle",
    "me",
    "ns",
    "oi",
    "pa",
    "ti",
    "un",
    "ux",
    "ux ",
    "x ",
    " co",
    " n",
    " no",
    " pr",
    " t",
    "ag",
    "at",
    "dan",
    "ei",
    "er ",
    "ier",
    "ne ",
    "no",
    "ont",
    "our",
    "que",
    "que ",
    "ra",
    "rs",
    "se ",
    "si",
    "us",
    "uv",
    "vi",
    " a ",
    " au",
    " da",
    " j",
    " ma",
    " pe",
    " se",
    " é",
    "ain",
    "ans",
    "ans ",
    "au ",
    "cl",
    "ea",
    "eau",
    "eme",
    "emen",
    "ers",
    "et",
    "he",
    "ill",
    "ir",
    "is ",
    "j",
    "lle ",
    "men",
    "ment",
    "nd",
    "ns ",
    "nte",
    "ois",
    "ol",
    "ont ",
    "our ",
    "ouv",
    "pe",
    "pl",
    "prè",
    "près",
    "res",
    "res ",
    "rie",
    "rs ",
    "rè",
    "rès",
    "rès ",
    "su",
    "ta",
    "tem",
    "ts",
    "ts ",
    "ui",
    "va",
    "ès",
    "ès ",
    " ap",
    " au ",
    " cl",
    " dan",
    " en",
    " ex",
    " g",
    " l ",
    " pou",
    " so",
    " su",
    " sur",
    " tr",
    " tra",
    " un ",
    " une",
    " vi",
    " à",
    " à ",
    " ét",
    "ac",
    "ant ",
    "ap",
    "aq",
    "aqu",
    "aque",
    "arc",
    "aux",
    "aux ",
    "av",
    "bo",
    "br",
    "ca",
    "chaq",
    "che",
    "cou",
    "cu",
    "d ",
    "dans",
    "di",
    "eil",
    "el",
    "ell",
    "elle",
    "end",
    "ers ",
    "eux",
    "eux ",
    "ex",
    "fr",
    "ge",
    "haq",
    "haqu",
    "iers",
    "ieu",
    "il ",
    "ille",
    "ine",
    "ire",
    "ise",
    "isi",
    "it",
    "iv",
    "iè",
    "lan",
    "mi",
    "mp",
    "ni",
    "nts",
    "nts ",
    "om",
    "ot",
    "ouve",
    "par",
    "pou",
    "pour",
    "rai",
    "rc",
    "rt",
    "so",
    "sur",
    "sur ",
    "tra",
    "tre",
    "tre ",
    "tu",
    "uc",
    "ul",
    "un ",
    "une",
    "une ",
];
static immutable string[] languageProfileDe = [
    " ",
    "e",
    "n",
    "r",
    "i",
    "a",
    "t",
    "e ",
    "s",
    "d",
    "n ",
    "en",
    "u",
    "er",
    "h",
    "l",
    "en ",
    " d",
    "m",
    "b",
    "c",
    "de",
    "g",
    "k",
    "ie",
    "r ",
    "te",
    " b",
    "ne",
    "ch",
    "f",
    "o",
    "er ",
    "in",
    "z",
    " de",
    "ei",
    "m ",
    "ie ",
    " di",
    "di",
    "ge",
    "t ",
    " a",
    " die",
    " e",
    " s",
    "die",
    "die ",
    " k",
    "an",
    "au",
    "der",
    "se",
    "ü",
    " n",
    "be",
    "der ",
    "le",
    "s ",
    "te ",
    " der",
    " z",
    "ein",
    "he",
    "ne ",
    "re",
    " ei",
    " ein",
    " f",
    " l",
    " v",
    "ck",
    "den",
    "eine",
    "ine",
    "p",
    "st",
    "v",
    "ze",
    " be",
    "ch ",
    "el",
    "et",
    "h ",
    "is",
    "li",
    "nen",
    "ri",
    "ä",
    " g",
    " i",
    " m",
    " zu",
    "ac",
    "ach",
    "ah",
    "al",
    "am",
    "ar",
    "che",
    "cke",
    "den ",
    "em",
    "es",
    "it",
    "ke",
    "la",
    "nd",
    "nen ",
    "um",
    "w",
    "zu",
    " u",
    " w",
    "ba",
    "br",
    "eu",
    "g ",
    "hr",
    "ic",
    "in ",
    "ine ",
    "j",
    "ka",
    "na",
    "nde",
    "ns",
    "rg",
    "rt",
    "sc",
    "sch",
    "se ",
    "ten",
    "ten ",
    "um ",
    "un",
    "us",
    "ö",
    " br",
    " ge",
    " in",
    " in ",
    " j",
    " le",
    " na",
    " r",
    "am ",
    "an ",
    "as",
    "ber",
    "cke ",
    "ed",
    "ede",
    "eit",
    "em ",
    "ens",
    "ern",
    "es ",
    "ete",
    "fe",
    "fen",
    "gen",
    "he ",
    "ke ",
    "l ",
    "lic",
    "lt",
    "me",
    "mi",
    "ng",
    "ot",
    "rk",
    "rn",
    "rte",
    "sa",
    "ss",
    "sse",
    "ter",
    "ti",
    "u ",
    "ur",
    "üc",
    " an",
    " an ",
    " au",
    " ba",
    " ber",
    " bi",
    " da",
    " das",
    " den",
    " er",
    " fr",
    " je",
    " jed",
    " ka",
    " nac",
    " ne",
    " neu",
    " p",
    " re",
    " sa",
    " st",
    " zu ",
    "ahr",
    "ang",
    "as ",
    "auf",
    "aus",
    "bi",
    "bä",
    "da",
    "das",
    "das ",
    "eden",
    "eg",
    "el ",
    "end",
    "ende",
    "ere",
    "erei",
    "erg",
    "eri",
    "erne",
    "ert",
    "erte",
    "fa",
    "fr",
    "ft",
    "ga",
    "gel",
    "gel ",
    "gen ",
    "ht",
    "ich",
    "ich ",
    "iel",
    "ier",
    "ig",
    "je",
    "jed",
    "jede",
    "k ",
    "kl",
    "kt",
    "lan",
    "lich",
    "lte",
    "ma",
    "nac",
    "nach",
    "neu",
    "om",
    "on",
    "or",
    "rei",
    "rge",
    "ris",
    "rne",
    "rte ",
    "rü",
    "sen",
    "so",
    "ste",
    "ta",
    "tet",
    "tl",
    "ue",
    "uf",
    "zei",
    "zen",
    "zen ",
    "zu ",
    "ück",
    "ücke",
    " al",
    " alt",
    " am",
    " am ",
    " aus",
    " bau",
    " brü",
    " bä",
    " dem",
    " fe",
    " fen",
    " gem",
    " h",
    " kl",
    " la",
    " ma",
    " mo",
    " mor",
    " no",
    " not",
    " reg",
    " san",
    " so",
    " sp",
];

// ---------------------------------------------------------------------------
// Detection.
// ---------------------------------------------------------------------------

private size_t rankOf(const(string)[] ngrams, string ngram) pure nothrow {
    foreach (i, candidate; ngrams) if (candidate == ngram) return i;
    return size_t.max;
}

private size_t distanceTo(const(string)[] docNgrams, const(string)[] profileNgrams) pure nothrow {
    size_t total;
    auto penaltyForMiss = profileNgrams.length;
    foreach (i, ngram; docNgrams) {
        auto rank = rankOf(profileNgrams, ngram);
        total += rank == size_t.max ? penaltyForMiss : (rank > i ? rank - i : i - rank);
    }
    return total;
}

struct LanguageScore { SupportedLanguage language; size_t distance; }

/// Raw Cavnar & Trenkle out-of-place distance from `text`'s own top
/// `profileCap` ranked n-grams to each of the four supported language
/// profiles, sorted ascending (best match first, i.e. `[0]` is the
/// candidate `detectLanguage` would pick before any abstention check).
/// Exposed for diagnostics/reporting (e.g.
/// `experiments/language_id/check.d`'s confusion-matrix golden and
/// threshold tuning); this raw score is not itself part of the typed
/// `LanguageDetectionResult` abstention contract, which is `detectLanguage`
/// alone. `text` must already be non-empty, within the size cap, and valid
/// UTF-8, exactly the same as `detectLanguage`'s own preconditions past its
/// early abstention checks.
LanguageScore[4] scoreLanguages(string text) {
    validate(text);
    auto words = wordsOf(text);
    size_t[string] counts;
    countNgramsInto(counts, words);
    string[] docNgrams;
    foreach (entry; rankedFromCounts(counts, profileCap)) docNgrams ~= entry.ngram;
    LanguageScore[4] scored = [
        LanguageScore(SupportedLanguage.en, distanceTo(docNgrams, languageProfileEn)),
        LanguageScore(SupportedLanguage.es, distanceTo(docNgrams, languageProfileEs)),
        LanguageScore(SupportedLanguage.fr, distanceTo(docNgrams, languageProfileFr)),
        LanguageScore(SupportedLanguage.de, distanceTo(docNgrams, languageProfileDe)),
    ];
    sort!((a, b) => a.distance < b.distance)(scored[]);
    return scored;
}

private LanguageDetectionResult abstain(LanguageAbstentionReason reason) pure nothrow @nogc {
    LanguageDetectionResult result;
    result.status = LanguageDetectionStatus.abstained;
    result.reason = reason;
    return result;
}

private uint confidenceToPerMille(double confidence) {
    if (confidence < 0.0) confidence = 0.0;
    if (confidence > 1.0) confidence = 1.0;
    return cast(uint) lround(confidence * 1000.0);
}

/// Classify `text` (raw bytes, expected UTF-8) into one supported language
/// or a typed abstention. Deterministic and side-effect free.
LanguageDetectionResult detectLanguage(const(ubyte)[] text) {
    if (text.length == 0) return abstain(LanguageAbstentionReason.emptyText);
    if (text.length > maxLanguageIdTextBytes) return abstain(LanguageAbstentionReason.oversizeText);
    string canonical;
    try { validate(cast(string) text); canonical = cast(string) text; }
    catch (UTFException) return abstain(LanguageAbstentionReason.invalidUtf8);

    auto script = scriptCountsOf(canonical);
    if (script.letters > 0) {
        double nonLatinFraction = cast(double) script.nonLatinLetters / cast(double) script.letters;
        if (nonLatinFraction > nonLatinScriptBound)
            return abstain(LanguageAbstentionReason.unsupportedScript);
    }

    auto words = wordsOf(canonical);
    size_t[string] counts;
    countNgramsInto(counts, words);
    size_t totalOccurrences;
    foreach (count; counts.byValue) totalOccurrences += count;
    if (totalOccurrences < minNgramCount) return abstain(LanguageAbstentionReason.tooShort);

    auto docNgramCount = rankedFromCounts(counts, profileCap).length;
    auto scored = scoreLanguages(canonical);

    double worstCase = cast(double) docNgramCount * cast(double) profileCap;
    double rawConfidence = worstCase > 0.0 ? 1.0 - (cast(double) scored[0].distance / worstCase) : 0.0;
    if (rawConfidence < 0.0) rawConfidence = 0.0;
    if (rawConfidence > 1.0) rawConfidence = 1.0;
    double margin = worstCase > 0.0 ?
        cast(double)(scored[1].distance - scored[0].distance) / worstCase : 0.0;

    if (margin < mixedMarginBound) return abstain(LanguageAbstentionReason.mixedOrAmbiguous);
    if (rawConfidence < internalConfidenceFloor)
        return abstain(LanguageAbstentionReason.belowConfidenceThreshold);

    LanguageDetectionResult result;
    result.status = LanguageDetectionStatus.detected;
    result.language = scored[0].language;
    result.confidence = confidenceToPerMille(rawConfidence) / 1000.0;
    return result;
}

// ---------------------------------------------------------------------------
// Identity, wire encode/decode.
// ---------------------------------------------------------------------------

ubyte[32] currentProfileTableIdentity() {
    auto bytes = appender!(ubyte[]);
    bytes.put(cast(const(ubyte)[]) "scrubbed:language-id:profiles:v1\0");
    foreach (table; [languageProfileEn, languageProfileEs, languageProfileFr, languageProfileDe]) {
        appendU32(bytes, cast(uint) table.length);
        foreach (ngram; table) appendField(bytes, ngram);
    }
    return sha256Of(bytes.data);
}

/// Build a bound identity+result record for `text` against `documentId`.
LanguageIdentityRecord buildLanguageIdentity(DocumentId documentId, const(ubyte)[] text) {
    LanguageIdentityRecord record;
    record.identity.documentId = documentId;
    record.identity.textRevision = sha256Of(text);
    record.identity.profileTableIdentity = currentProfileTableIdentity();
    record.identity.algorithmVersion = languageIdAlgorithmVersion;
    record.result = detectLanguage(text);
    return record;
}

/// Refuse malformed or internally inconsistent records.
void checkLanguageIdentity(ref const LanguageIdentityRecord value) {
    enforce(value.identity.algorithmVersion == languageIdAlgorithmVersion,
        "language id: unsupported algorithm version");
    enforce(value.identity.documentId.text.length != 0, "language id: unbound document id");
    enforce(value.identity.profileTableIdentity == currentProfileTableIdentity(),
        "language id: profile table identity mismatch");
    if (value.result.status == LanguageDetectionStatus.detected) {
        enforce(value.result.reason == LanguageAbstentionReason.none,
            "language id: detected result must carry no abstention reason");
        enforce(value.result.confidence >= 0.0 && value.result.confidence <= 1.0,
            "language id: confidence out of range");
    } else {
        enforce(value.result.reason != LanguageAbstentionReason.none,
            "language id: abstained result must carry a reason");
        enforce(value.result.confidence == 0.0,
            "language id: abstained result must not carry a confidence value");
    }
}

private void appendU8(ref Appender!(ubyte[]) bytes, ubyte value) { bytes.put(value); }

private void appendU32(ref Appender!(ubyte[]) bytes, uint value) {
    foreach_reverse (shift; [0, 8, 16, 24]) bytes.put(cast(ubyte)(value >> shift));
}

private void appendDigest(ref Appender!(ubyte[]) bytes, ubyte[32] value) { bytes.put(value[]); }

private void appendField(ref Appender!(ubyte[]) bytes, string value) {
    enforce(value.length <= uint.max, "language id: field too long");
    appendU32(bytes, cast(uint) value.length);
    bytes.put(cast(const(ubyte)[]) value);
}

private ubyte readU8(const(ubyte)[] bytes, ref size_t at) {
    enforce(at < bytes.length, "language id: truncated record");
    return bytes[at++];
}

private uint readU32(const(ubyte)[] bytes, ref size_t at) {
    enforce(bytes.length - at >= 4, "language id: truncated record");
    uint value;
    foreach (_; 0 .. 4) value = (value << 8) | bytes[at++];
    return value;
}

private ubyte[32] readDigest(const(ubyte)[] bytes, ref size_t at) {
    enforce(bytes.length - at >= 32, "language id: truncated record");
    ubyte[32] value = bytes[at .. at + 32];
    at += 32;
    return value;
}

private string readField(const(ubyte)[] bytes, ref size_t at, size_t cap) {
    auto length = readU32(bytes, at);
    enforce(length <= cap && length <= bytes.length - at, "language id: truncated or oversize field");
    auto value = cast(string) bytes[at .. at + length].idup;
    at += length;
    return value;
}

/// Canonical wire encoding: fixed-field layout plus a whole-record SHA-256
/// checksum trailer, mirroring `domain.topical_tags`'s
/// `encodeTopicalTags`/`decodeTopicalTags` idiom directly.
ubyte[] encodeLanguageIdentity(LanguageIdentityRecord value) {
    checkLanguageIdentity(value);
    auto bytes = appender!(ubyte[]);
    bytes.put(cast(const(ubyte)[]) "scrubbed:language-id:v1\0");
    appendU32(bytes, languageIdSchema);
    appendField(bytes, value.identity.documentId.text);
    appendDigest(bytes, value.identity.textRevision);
    appendDigest(bytes, value.identity.profileTableIdentity);
    appendU32(bytes, value.identity.algorithmVersion);
    appendU8(bytes, cast(ubyte) value.result.status);
    appendU8(bytes, cast(ubyte) value.result.language);
    appendU32(bytes, confidenceToPerMille(value.result.confidence));
    appendU8(bytes, cast(ubyte) value.result.reason);
    auto payload = bytes.data;
    return payload ~ sha256Of(payload)[];
}

/// Decode and fully re-validate a stored record, binding it to the
/// caller-supplied `expectedId`/`expectedTextRevision` (obtained
/// independently, e.g. from a C01 join). Any wrong document, revision, or
/// profile-table identity; malformed status/language/reason; out-of-range
/// confidence; truncation; or trailing data is rejected.
LanguageIdentityRecord decodeLanguageIdentity(const(ubyte)[] wireBytes, DocumentId expectedId,
        ubyte[32] expectedTextRevision) {
    enforce(wireBytes.length >= 32, "language id: truncated record");
    auto bytes = wireBytes[0 .. $ - 32];
    auto trailer = wireBytes[$ - 32 .. $];
    enforce(sha256Of(bytes)[] == trailer, "language id: record checksum mismatch");
    auto prefix = cast(const(ubyte)[]) "scrubbed:language-id:v1\0";
    enforce(bytes.length >= prefix.length && bytes[0 .. prefix.length] == prefix,
        "language id: malformed domain tag");
    size_t at = prefix.length;
    LanguageIdentityRecord result;
    enforce(readU32(bytes, at) == languageIdSchema, "language id: unsupported schema");
    auto idText = readField(bytes, at, 128);
    result.identity.documentId = DocumentId.fromCanonicalText(idText);
    enforce(result.identity.documentId == expectedId, "language id: document id mismatch");
    result.identity.textRevision = readDigest(bytes, at);
    enforce(result.identity.textRevision == expectedTextRevision,
        "language id: text revision mismatch");
    result.identity.profileTableIdentity = readDigest(bytes, at);
    result.identity.algorithmVersion = readU32(bytes, at);
    auto statusValue = readU8(bytes, at);
    enforce(statusValue <= LanguageDetectionStatus.max, "language id: malformed status");
    result.result.status = cast(LanguageDetectionStatus) statusValue;
    auto languageValue = readU8(bytes, at);
    enforce(languageValue <= SupportedLanguage.max, "language id: malformed language");
    result.result.language = cast(SupportedLanguage) languageValue;
    auto confidenceRaw = readU32(bytes, at);
    enforce(confidenceRaw <= 1000, "language id: confidence out of range");
    result.result.confidence = confidenceRaw / 1000.0;
    auto reasonValue = readU8(bytes, at);
    enforce(reasonValue <= LanguageAbstentionReason.max, "language id: malformed abstention reason");
    result.result.reason = cast(LanguageAbstentionReason) reasonValue;
    enforce(at == bytes.length, "language id: trailing data");
    checkLanguageIdentity(result);
    return result;
}

// ---------------------------------------------------------------------------
// Unit tests.
// ---------------------------------------------------------------------------

version (unittest) {
    import domain.document : SourceLocator;

    private DocumentId testDocumentId() {
        return DocumentId.from(SourceLocator("language-id-unit", "source", "doc-1"));
    }
}

unittest {
    assert(detectLanguage([]).reason == LanguageAbstentionReason.emptyText);
    auto oversized = new ubyte[maxLanguageIdTextBytes + 1];
    oversized[] = cast(ubyte) 'a';
    assert(detectLanguage(oversized).reason == LanguageAbstentionReason.oversizeText);
    ubyte[3] invalid = [0xff, 0xfe, 0xfd];
    assert(detectLanguage(invalid[]).reason == LanguageAbstentionReason.invalidUtf8);
}

unittest {
    auto id = testDocumentId();
    auto text = cast(const(ubyte)[]) "This is a short but plain example sentence for testing purposes today.";
    auto record = buildLanguageIdentity(id, text);
    auto encoded = encodeLanguageIdentity(record);
    auto decoded = decodeLanguageIdentity(encoded, id, record.identity.textRevision);
    assert(decoded == record);
    assert(encodeLanguageIdentity(decoded) == encoded);

    auto otherId = DocumentId.from(SourceLocator("language-id-unit", "source", "doc-2"));
    bool rejected;
    try decodeLanguageIdentity(encoded, otherId, record.identity.textRevision);
    catch (Exception) rejected = true;
    assert(rejected);
}

unittest {
    // routeLanguage never routes an abstained result, and only routes a
    // detected result at or above the caller-supplied threshold.
    LanguageDetectionResult detected;
    detected.status = LanguageDetectionStatus.detected;
    detected.language = SupportedLanguage.fr;
    detected.confidence = 0.5;
    assert(routeLanguage(detected, 0.5f).routed);
    assert(routeLanguage(detected, 0.6f).routed == false);
    assert(routeLanguage(abstain(LanguageAbstentionReason.tooShort), 0.0f).routed == false);
}
