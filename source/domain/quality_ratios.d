/// Pure, bounded Gopher/C4-style deterministic quality-ratio features over
/// whitespace-delimited text. No FFI, no vendored code -- Phobos only -- and
/// no other project-layer import, per `domain`'s own layering rule
/// (`scripts/check_modules.d`). This is the pure computational half of
/// issue #347's `quality-ratios-annotate` stage
/// (`effects.quality_ratios_annotate_stage` owns wiring/encoding); every
/// function here is independently unit-tested against hand-computed
/// fixtures, not merely type-correctness.
///
/// **Six independent feature groups, deliberately never combined into one
/// score** (the same "feature-vector-not-opaque-score" philosophy
/// `effects.compressibility_annotate_stage` already established for #168):
/// word count, mean word length, symbol-to-word ratios, alphabetic-word
/// fraction, stop-word presence, and multi-scale repetition fractions.
///
/// **Sourcing discipline (owner-mandated for #347): verify before hard-
/// coding, disclose plainly when verification isn't possible.**
///
/// - **Stop-word list**: independently verified against HuggingFace
///   `datatrove`'s `GopherQualityFilter`
///   (`src/datatrove/pipeline/filters/gopher_quality_filter.py`,
///   `STOP_WORDS = ["the", "be", "to", "of", "and", "that", "have", "with"]`,
///   fetched and read directly from
///   https://github.com/huggingface/datatrove during this slice's
///   implementation), a real, open-source, checkable reference
///   implementation of Rae et al. 2021, "Scaling Language Models: Methods,
///   Analysis & Insights from Training Gopher" (DeepMind, arXiv:2112.11446),
///   Appendix A.1 / Table A1. `stopWordListV1` below is that exact 8-word
///   list, unmodified.
/// - **Repetition formulas**: independently verified against `datatrove`'s
///   `GopherRepetitionFilter`
///   (`src/datatrove/pipeline/filters/gopher_repetition_filter.py`) and its
///   module-level `find_duplicates`/`find_top_duplicate`/`find_all_duplicate`
///   /`get_n_grams` helpers, fetched and read directly from the same
///   repository. That file's own header comment cites the exact source:
///   "Table A1 from https://arxiv.org/pdf/2112.11446.pdf". This module's
///   `findDuplicates`, `topNGramCharFraction`, and `duplicateNGramCharFraction`
///   below reproduce those four functions' exact algorithms (duplicate-
///   element/duplicate-character counting via a seen-set; the "top" n-gram
///   found via `Counter`-style frequency counting over space-joined,
///   overlapping-by-1 n-grams; the "duplicate" n-gram found via a
///   concatenated, skip-ahead-on-match sliding window) -- not a
///   reconstruction from memory.
///
/// **Deliberate, disclosed deviations from the verified `datatrove`
/// reference** (owner's #347 contract fixes the feature list, not bit-for-
/// bit `datatrove` parity):
///
/// 1. **Word tokenization.** The accepted #347 contract's own text specifies
///    "whitespace-delimited word count," not `datatrove`'s language-aware
///    `split_into_words` (which also strips attached punctuation via a
///    separate `PUNCTUATION_SET`-based `non_symbol_words` filter for word-
///    count/mean-length purposes only). This module instead splits on runs
///    of `std.uni.isWhite` codepoints for every word-based feature
///    (word count, mean word length, hash/ellipsis ratio denominators,
///    alphabetic-word fraction, and the words fed into the repetition
///    n-gram features), uniformly. A word such as `"dog."` is one word
///    including its trailing period, not `"dog"` -- this is a real,
///    intentional simplification, not an oversight.
/// 2. **Stop-word matching strips leading/trailing ASCII punctuation**
///    (`std.ascii.isPunctuation`) from each whitespace-delimited word before
///    exact-matching against `stopWordListV1`. `datatrove`'s own
///    `split_into_words` already yields punctuation-free tokens, so its
///    literal `set(words) & self.stop_words` needs no such trimming; this
///    module's simpler whitespace-only tokenizer does, or ordinary prose
///    punctuation ("with,", "and.") would almost never match at all,
///    defeating the feature. Matching stays case-sensitive against the
///    lowercase-only list, exactly as `datatrove` does (a capitalized
///    sentence-initial "The" does not count as a match).
/// 3. **Ellipsis counting is `"..."` (three literal ASCII periods) only.**
///    `datatrove` additionally counts the single-codepoint Unicode ellipsis
///    `"…"` (`text.count("...") + text.count("…")`); the accepted #347
///    contract's own finalized feature list names only `"..."`, so this
///    module counts only that, non-overlapping, left to right (matching
///    Python `str.count`'s own non-overlapping semantics).
/// 4. **No bullet-line or end-of-line-ellipsis ratios, no digit ratio, no
///    min/max word-count thresholds.** These are real fields in
///    `datatrove`'s `GopherQualityFilter` but are not part of #347's
///    finalized six-group feature list; this module does not compute them.
/// 5. **"Character" always means Unicode codepoint count** (matching
///    Python's `len(str)` semantics that every verified formula above is
///    expressed in), never UTF-8 byte length or grapheme-cluster count.
///
/// **No threshold, pass/fail, or accept/reject decision logic anywhere in
/// this module.** Every value is a raw, named, versioned numeric field.
/// `computeQualityRatios` never throws for any input byte sequence; invalid
/// UTF-8 is a typed abstention (`Utf8Status.invalidUtf8`), never an
/// exception.
module domain.quality_ratios;

import std.algorithm.searching : canFind;
import std.ascii : isPunctuation;
import std.string : strip;
import std.typecons : Nullable, nullable;
import std.uni : isAlpha, isWhite;
import std.utf : UTFException, validate;

/// Bumped whenever the wire shape *or* any computation rule in this module
/// changes (word-splitting rule, stop-word list, repetition formulas).
/// Deliberately one combined version, unlike `compressibility-annotate`'s
/// separate `schema`/`tokenizerVersion` pair -- this module's word-splitter
/// is private and not independently reused/versioned elsewhere.
enum qualityRatiosSchemaV1 = "scrubbed-quality-ratios-v1";

/// The exact 8-word Gopher stop-word list, verified against `datatrove`'s
/// `GopherQualityFilter.STOP_WORDS` -- see the module doc's sourcing
/// section. Fixed size for schema v1: exactly 8 words, order-independent for
/// matching purposes (order only affects nothing observable here).
static immutable string[8] stopWordListV1 = [
    "the", "be", "to", "of", "and", "that", "have", "with",
];

enum Utf8Status : ubyte { computed, invalidUtf8 }
enum WordStatus : ubyte { computed, noWords }

/// The full, decoded shape of one `quality-ratios` extension field's worth
/// of computed features. `Nullable!double.isNull` is this module's typed
/// abstention for the two field groups whose single abstention reason is
/// fully determined by another already-reported field (documented per
/// field below) -- never a bare `0.0` sentinel.
struct QualityRatiosResult {
    Utf8Status utf8Status;
    size_t rawBytes;
    size_t rawChars; // Unicode codepoint count; 0 whenever rawBytes == 0 or utf8Status != computed.

    WordStatus wordStatus;
    size_t wordCount; // whitespace-delimited word count; always a real count, 0 is a real value.

    /// Null iff `wordStatus == noWords` (wordCount == 0) -- mean word length
    /// is undefined with zero words, not a real zero.
    Nullable!double meanWordLength;
    /// `#` count / wordCount. Null iff `wordStatus == noWords`.
    Nullable!double hashToWordRatio;
    /// Non-overlapping `"..."` count / wordCount. Null iff `wordStatus == noWords`.
    Nullable!double ellipsisToWordRatio;
    /// Fraction of words containing >=1 `std.uni.isAlpha` codepoint. Null
    /// iff `wordStatus == noWords`.
    Nullable!double alphabeticWordFraction;
    /// Count of `stopWordListV1` entries present at least once (presence,
    /// not frequency); always a real count in `[0, 8]`, 0 is a real value.
    size_t stopWordPresentCount;

    /// Always computed: splitting on `\n+` always yields >=1 line, even for
    /// empty content (matching Python `re.split(r"\n+", "")` == [""]), so
    /// the denominator is never zero.
    double duplicateLineFraction = 0.0;
    /// Null iff `rawBytes == 0` (the only way the shared `rawChars`
    /// denominator can be zero).
    Nullable!double duplicateLineCharFraction;
    /// Always computed, same reasoning as `duplicateLineFraction`.
    double duplicateParagraphFraction = 0.0;
    /// Null iff `rawBytes == 0`, same reasoning as `duplicateLineCharFraction`.
    Nullable!double duplicateParagraphCharFraction;

    /// Top-n-gram character fraction for n = 2, 3, 4 (index 0, 1, 2). Null
    /// at index i iff `wordCount < (i + 2)` -- too few words to form even
    /// one n-gram of that size (matching `datatrove`'s own
    /// `if not n_grams: continue` skip). **Can legitimately exceed 1.0**:
    /// the verified reference formula counts every overlapping occurrence's
    /// full character span, and overlapping windows of the same repeated
    /// gram can cover the same source characters more than once (e.g. `"a b
    /// a b a b"`'s top 4-gram: two overlapping `"a b a b"` occurrences,
    /// numerator 14 over 11 total characters) -- this is an inherent
    /// property of the verified `find_top_duplicate` algorithm, not a bug.
    Nullable!double[3] topNGramCharFraction;
    /// Duplicate-n-gram character fraction for n = 5..10 (index 0..5). Null
    /// at index i iff `wordCount < (i + 5)`, same reasoning.
    Nullable!double[6] duplicateNGramCharFraction;
}

private size_t codepointLength(const(char)[] s) pure @safe {
    size_t n = 0;
    // All callers operate on text already validated by
    // computeQualityRatios. Every UTF-8 scalar has exactly one leading byte,
    // so counting non-continuation bytes avoids decoding the same text again.
    foreach (c; s)
        if ((cast(ubyte) c & 0xC0) != 0x80) ++n;
    return n;
}

private bool isQualityWhite(dchar c) pure @safe {
    if (c <= 0x7F)
        return c == ' ' || (c >= '\t' && c <= '\r');
    return isWhite(c);
}

private bool isQualityAlpha(dchar c) pure @safe {
    if (c <= 0x7F)
        return c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z';
    return isAlpha(c);
}

private size_t countChar(const(char)[] text, char target) pure @safe {
    size_t n = 0;
    foreach (c; text) if (c == target) ++n;
    return n;
}

/// Non-overlapping substring count, matching Python `str.count`'s own
/// left-to-right, non-overlapping semantics.
private size_t countNonOverlapping(const(char)[] text, string needle) pure @safe {
    size_t n = 0;
    size_t i = 0;
    while (i + needle.length <= text.length) {
        if (text[i .. i + needle.length] == needle) {
            ++n;
            i += needle.length;
        } else {
            ++i;
        }
    }
    return n;
}

private struct WordStats {
    size_t wordCount;
    size_t totalWordChars;
    size_t alphaWordCount;
    string[] words;
}

/// Splits `text` on runs of `std.uni.isWhite` codepoints, collecting every
/// per-word statistic in one pass: this module's "whitespace-delimited
/// word" definition, per the #347 contract's own text (see module doc
/// deviation 1).
private WordStats collectWordStats(const(char)[] text) pure @safe {
    WordStats stats;
    char[] current;
    size_t currentChars;
    bool currentHasAlpha;

    void flush() {
        if (current.length) {
            stats.words ~= current.idup;
            stats.totalWordChars += currentChars;
            if (currentHasAlpha) ++stats.alphaWordCount;
            ++stats.wordCount;
        }
        current = null;
        currentChars = 0;
        currentHasAlpha = false;
    }

    foreach (dchar c; text) {
        if (isQualityWhite(c)) {
            flush();
        } else {
            current ~= c;
            ++currentChars;
            if (isQualityAlpha(c)) currentHasAlpha = true;
        }
    }
    flush();
    return stats;
}

/// Trims leading/trailing ASCII punctuation before stop-word matching only
/// -- see module doc deviation 2. Word-count/mean-length/n-gram features
/// never trim; they use the raw whitespace-delimited word verbatim.
private string trimPunctuationForStopWordMatch(string word) pure @safe {
    size_t start = 0;
    size_t end = word.length;
    while (start < end && isPunctuation(word[start])) ++start;
    while (end > start && isPunctuation(word[end - 1])) --end;
    return word[start .. end];
}

private size_t countStopWordsPresent(const(string[]) words) pure @safe {
    bool[string] present;
    foreach (word; words) {
        auto trimmed = trimPunctuationForStopWordMatch(word);
        if (stopWordListV1[].canFind(trimmed)) present[trimmed] = true;
    }
    return present.length;
}

/// Splits on runs of one or more `'\n'`, matching Python
/// `re.split(r"\n+", text)` exactly, including its trailing-empty-string
/// behavior when `text` ends with `'\n'`.
private string[] splitLinesByNewlineRuns(const(char)[] text) pure @safe {
    string[] lines;
    size_t start = 0;
    size_t i = 0;
    while (i < text.length) {
        if (text[i] == '\n') {
            lines ~= text[start .. i].idup;
            while (i < text.length && text[i] == '\n') ++i;
            start = i;
        } else {
            ++i;
        }
    }
    lines ~= text[start .. $].idup;
    return lines;
}

/// Splits on runs of two or more `'\n'`, matching Python
/// `re.split(r"\n{2,}", text)` exactly: a single `'\n'` never splits a
/// paragraph. Caller passes already-stripped text, matching `datatrove`'s
/// own `text.strip()` before this split.
private string[] splitParagraphsByBlankLines(const(char)[] strippedText) pure @safe {
    string[] paragraphs;
    size_t start = 0;
    size_t i = 0;
    while (i < strippedText.length) {
        if (strippedText[i] == '\n') {
            size_t runStart = i;
            while (i < strippedText.length && strippedText[i] == '\n') ++i;
            if (i - runStart >= 2) {
                paragraphs ~= strippedText[start .. runStart].idup;
                start = i;
            }
        } else {
            ++i;
        }
    }
    paragraphs ~= strippedText[start .. $].idup;
    return paragraphs;
}

/// Reproduces `datatrove`'s `find_duplicates`: for each element that has
/// already been seen earlier in `items`, count it (and its codepoint
/// length) as a duplicate. The *first* occurrence of a repeated value is
/// never itself counted as a duplicate.
private void findDuplicates(const(string[]) items, out size_t duplicateElements,
        out size_t duplicateChars) pure @safe {
    bool[string] seen;
    foreach (item; items) {
        if (item in seen) {
            ++duplicateElements;
            duplicateChars += codepointLength(item);
        } else {
            seen[item] = true;
        }
    }
}

/// Reproduces `datatrove`'s `get_n_grams` + `find_top_duplicate`: every
/// overlapping (slide-by-1) space-joined `n`-word gram is frequency-counted;
/// the most frequent gram's `(codepoint length) * (occurrence count)` is the
/// numerator. Ties are broken by first occurrence, deterministically.
/// Caller guarantees `words.length >= n`.
private struct WordNgramIndex {
    const(string)[] words;
    ulong[] hashes;
    ulong[] powers;

    static WordNgramIndex build(const(string[]) words) pure @safe {
        enum prime = 0x100000001b3UL;
        WordNgramIndex result;
        result.words = words;
        result.hashes.reserve(words.length);
        result.powers.reserve(words.length);
        foreach (word; words) {
            ulong hash;
            ulong power = 1;
            foreach (value; word) {
                hash = hash * prime + cast(ubyte) value;
                power *= prime;
            }
            result.hashes ~= hash;
            result.powers ~= power;
        }
        return result;
    }
}

private ulong ngramHash(const ref WordNgramIndex index, size_t start,
        size_t n, bool spaces) pure @safe {
    enum prime = 0x100000001b3UL;
    ulong hash;
    foreach (wordOffset; 0 .. n) {
        if (spaces && wordOffset != 0)
            hash = hash * prime + cast(ubyte) ' ';
        const wordIndex = start + wordOffset;
        hash = hash * index.powers[wordIndex] + index.hashes[wordIndex];
    }
    return hash;
}

private bool sameSpacedNgram(const(string)[] words, size_t left,
        size_t right, size_t n) pure @safe {
    foreach (offset; 0 .. n)
        if (words[left + offset] != words[right + offset]) return false;
    return true;
}

private bool sameConcatenatedNgram(const(string)[] words, size_t left,
        size_t right, size_t n) pure @safe {
    size_t leftWord, leftByte, rightWord, rightByte;
    while (leftWord < n && rightWord < n) {
        if (words[left + leftWord][leftByte] != words[right + rightWord][rightByte])
            return false;
        if (++leftByte == words[left + leftWord].length) {
            ++leftWord;
            leftByte = 0;
        }
        if (++rightByte == words[right + rightWord].length) {
            ++rightWord;
            rightByte = 0;
        }
    }
    return leftWord == n && rightWord == n;
}

private size_t ngramCodepointLength(const(string)[] words, size_t start,
        size_t n, bool spaces) pure @safe {
    size_t length = spaces ? n - 1 : 0;
    foreach (offset; 0 .. n) length += codepointLength(words[start + offset]);
    return length;
}

private struct CountedNgram {
    size_t start;
    size_t count;
}

private size_t topNGramCharCount(const ref WordNgramIndex index,
        size_t n) pure @safe {
    CountedNgram[] entries;
    size_t[][ulong] buckets;
    for (size_t i = 0; i + n <= index.words.length; ++i) {
        auto hash = ngramHash(index, i, n, true);
        auto bucket = hash in buckets;
        bool found;
        if (bucket !is null) {
            foreach (entryIndex; *bucket) {
                if (sameSpacedNgram(index.words, entries[entryIndex].start, i, n)) {
                    ++entries[entryIndex].count;
                    found = true;
                    break;
                }
            }
        }
        if (!found) {
            const entryIndex = entries.length;
            entries ~= CountedNgram(i, 1);
            buckets[hash] ~= entryIndex;
        }
    }
    size_t bestStart;
    size_t bestCount = 0;
    foreach (entry; entries) {
        if (entry.count > bestCount) {
            bestCount = entry.count;
            bestStart = entry.start;
        }
    }
    return ngramCodepointLength(index.words, bestStart, n, true) * bestCount;
}

/// Reproduces `datatrove`'s `find_all_duplicate`: a sliding window over
/// concatenated (no separator) `n`-word grams; on a repeat, count its
/// codepoint length and skip the window ahead by `n` (non-overlapping past a
/// match); otherwise advance by 1. Caller guarantees `words.length >= n`.
private size_t duplicateNGramCharCount(const ref WordNgramIndex index,
        size_t n) pure @safe {
    size_t[][ulong] seen;
    size_t repeatedChars = 0;
    size_t idx = 0;
    immutable size_t total = index.words.length;
    while (idx + n <= total) {
        auto hash = ngramHash(index, idx, n, false);
        auto bucket = hash in seen;
        bool repeated;
        if (bucket !is null)
            foreach (prior; *bucket)
                if (sameConcatenatedNgram(index.words, prior, idx, n)) {
                    repeated = true;
                    break;
                }
        if (repeated) {
            repeatedChars += ngramCodepointLength(index.words, idx, n, false);
            idx += n;
        } else {
            seen[hash] ~= idx;
            ++idx;
        }
    }
    return repeatedChars;
}

/// Computes every #347 feature group over `bytes`. Requires valid UTF-8 for
/// every feature (unlike `compressibility-annotate`'s deliberate asymmetry
/// -- every feature here operates on decoded text: words, lines,
/// paragraphs), so invalid UTF-8 abstains every field at once. Never
/// throws.
QualityRatiosResult computeQualityRatios(const(ubyte)[] bytes) pure @trusted {
    QualityRatiosResult result;
    result.rawBytes = bytes.length;

    auto text = cast(const(char)[]) bytes;
    try validate(text);
    catch (UTFException) {
        result.utf8Status = Utf8Status.invalidUtf8;
        return result;
    }
    result.utf8Status = Utf8Status.computed;
    result.rawChars = codepointLength(text);

    auto wordStats = collectWordStats(text);
    auto ngramIndex = WordNgramIndex.build(wordStats.words);
    result.wordCount = wordStats.wordCount;
    result.stopWordPresentCount = countStopWordsPresent(wordStats.words);

    if (wordStats.wordCount == 0) {
        result.wordStatus = WordStatus.noWords;
    } else {
        result.wordStatus = WordStatus.computed;
        result.meanWordLength = nullable(
            cast(double) wordStats.totalWordChars / cast(double) wordStats.wordCount);
        auto hashCount = countChar(text, '#');
        auto ellipsisCount = countNonOverlapping(text, "...");
        result.hashToWordRatio = nullable(cast(double) hashCount / cast(double) wordStats.wordCount);
        result.ellipsisToWordRatio = nullable(
            cast(double) ellipsisCount / cast(double) wordStats.wordCount);
        result.alphabeticWordFraction = nullable(
            cast(double) wordStats.alphaWordCount / cast(double) wordStats.wordCount);
    }

    auto lines = splitLinesByNewlineRuns(text);
    size_t lineDuplicateElements, lineDuplicateChars;
    findDuplicates(lines, lineDuplicateElements, lineDuplicateChars);
    result.duplicateLineFraction = cast(double) lineDuplicateElements / cast(double) lines.length;

    auto strippedText = strip(text);
    auto paragraphs = splitParagraphsByBlankLines(strippedText);
    size_t paraDuplicateElements, paraDuplicateChars;
    findDuplicates(paragraphs, paraDuplicateElements, paraDuplicateChars);
    result.duplicateParagraphFraction = cast(double) paraDuplicateElements / cast(double) paragraphs.length;

    if (result.rawBytes > 0) {
        result.duplicateLineCharFraction = nullable(
            cast(double) lineDuplicateChars / cast(double) result.rawChars);
        result.duplicateParagraphCharFraction = nullable(
            cast(double) paraDuplicateChars / cast(double) result.rawChars);
    }

    static immutable size_t[3] topNs = [2, 3, 4];
    foreach (i, n; topNs) {
        if (wordStats.wordCount >= n) {
            auto topChars = topNGramCharCount(ngramIndex, n);
            result.topNGramCharFraction[i] = nullable(
                cast(double) topChars / cast(double) result.rawChars);
        }
    }

    static immutable size_t[6] dupNs = [5, 6, 7, 8, 9, 10];
    foreach (i, n; dupNs) {
        if (wordStats.wordCount >= n) {
            auto dupChars = duplicateNGramCharCount(ngramIndex, n);
            result.duplicateNGramCharFraction[i] = nullable(
                cast(double) dupChars / cast(double) result.rawChars);
        }
    }

    return result;
}

unittest {
    import std.conv : to;
    import std.math : abs;

    // Empty input: valid (trivial) UTF-8, zero words -- `noWords`. Line and
    // paragraph splits each still yield exactly one (empty) element, so
    // both duplicate fractions are a real, computed 0.0, not abstained.
    auto empty = computeQualityRatios([]);
    assert(empty.utf8Status == Utf8Status.computed);
    assert(empty.rawBytes == 0 && empty.rawChars == 0);
    assert(empty.wordStatus == WordStatus.noWords);
    assert(empty.wordCount == 0);
    assert(empty.meanWordLength.isNull);
    assert(empty.stopWordPresentCount == 0);
    assert(empty.duplicateLineFraction == 0.0);
    assert(empty.duplicateParagraphFraction == 0.0);
    assert(empty.duplicateLineCharFraction.isNull, "rawBytes==0 must abstain char fractions");
    assert(empty.duplicateParagraphCharFraction.isNull);
    foreach (v; empty.topNGramCharFraction) assert(v.isNull);
    foreach (v; empty.duplicateNGramCharFraction) assert(v.isNull);

    foreach (value; 0 .. 0x80) {
        auto c = cast(dchar) value;
        assert(isQualityWhite(c) == isWhite(c));
        assert(isQualityAlpha(c) == isAlpha(c));
    }

    // Invalid UTF-8: every field abstains except the always-real rawBytes.
    auto invalid = computeQualityRatios([0xff, 0xfe]);
    assert(invalid.utf8Status == Utf8Status.invalidUtf8);
    assert(invalid.rawBytes == 2);
    assert(invalid.rawChars == 0);
    assert(invalid.wordStatus == WordStatus.computed && invalid.wordCount == 0,
        "wordStatus/wordCount default to their computed/zero .init values under invalidUtf8; " ~
        "callers must gate on utf8Status first, exactly as documented");

    // All-whitespace, nonempty content: zero words (noWords), but rawChars
    // is nonzero, so line/paragraph char fractions still compute (as 0.0,
    // one line/one paragraph, no duplicates) rather than abstaining --
    // proving `wordStatus == noWords` and `rawBytes == 0` are genuinely
    // independent gates, not the same condition.
    auto whitespaceOnly = computeQualityRatios(cast(const(ubyte)[]) "   ");
    assert(whitespaceOnly.wordStatus == WordStatus.noWords);
    assert(whitespaceOnly.rawBytes == 3 && whitespaceOnly.rawChars == 3);
    assert(!whitespaceOnly.duplicateLineCharFraction.isNull);
    assert(whitespaceOnly.duplicateLineCharFraction.get == 0.0);
    assert(!whitespaceOnly.duplicateParagraphCharFraction.isNull);

    // rawChars is Unicode scalar count, not UTF-8 byte count.
    auto nonAscii = computeQualityRatios(cast(const(ubyte)[]) "é 界 😀");
    assert(nonAscii.rawBytes == 11);
    assert(nonAscii.rawChars == 5);

    // Hand-computed word stats: "The cat sat on the mat." -- 6 words,
    // whitespace-delimited (the trailing period stays attached to "mat.").
    auto sentence = computeQualityRatios(cast(const(ubyte)[]) "The cat sat on the mat.");
    assert(sentence.wordStatus == WordStatus.computed);
    assert(sentence.wordCount == 6, "word count: " ~ sentence.wordCount.to!string);
    // Word char lengths: The(3) cat(3) sat(3) on(2) the(3) mat.(4) = 18 / 6 = 3.0
    assert(abs(sentence.meanWordLength.get - 3.0) < 1e-9,
        "mean word length: " ~ sentence.meanWordLength.get.to!string);
    // Stop words present (case-sensitive, punctuation-trimmed): "the" (both
    // "The" capitalized does NOT match, but lowercase "the" does) -- exactly
    // one distinct stop word present.
    assert(sentence.stopWordPresentCount == 1,
        "stop word count: " ~ sentence.stopWordPresentCount.to!string);
    assert(sentence.hashToWordRatio.get == 0.0);
    assert(sentence.ellipsisToWordRatio.get == 0.0);
    assert(sentence.alphabeticWordFraction.get == 1.0);

    // Hand-computed hash/ellipsis ratios: "#tag #tag ... text" -- 4 words,
    // 2 hashes, 1 non-overlapping ellipsis.
    auto symbols = computeQualityRatios(cast(const(ubyte)[]) "#tag #tag ... text");
    assert(symbols.wordCount == 4);
    assert(abs(symbols.hashToWordRatio.get - 0.5) < 1e-9);
    assert(abs(symbols.ellipsisToWordRatio.get - 0.25) < 1e-9);

    // Alphabetic-word fraction: "cat 123 dog456 789" -- 4 words, 3 contain
    // at least one alphabetic codepoint ("cat", "dog456"; "123" and "789"
    // wait -- "789" has none). Recount: cat(alpha) 123(no) dog456(alpha)
    // 789(no) -> 2/4 = 0.5.
    auto alpha = computeQualityRatios(cast(const(ubyte)[]) "cat 123 dog456 789");
    assert(alpha.wordCount == 4);
    assert(abs(alpha.alphabeticWordFraction.get - 0.5) < 1e-9,
        "alphabetic word fraction: " ~ alpha.alphabeticWordFraction.get.to!string);
}

unittest {
    import std.conv : to;
    import std.math : abs;

    // Duplicate-line fraction: 4 lines, one repeated (2nd occurrence of
    // "same line" is the single duplicate element).
    auto text = "same line\nunique one\nsame line\nunique two";
    auto result = computeQualityRatios(cast(const(ubyte)[]) text);
    assert(result.duplicateLineFraction == 0.25, "dup line fraction: " ~
        result.duplicateLineFraction.to!string);
    // "same line" is 9 chars; duplicateLineChars=9, rawChars=len(text)=41.
    assert(!result.duplicateLineCharFraction.isNull);
    assert(abs(result.duplicateLineCharFraction.get - (9.0 / 41.0)) < 1e-9,
        "dup line char fraction: " ~ result.duplicateLineCharFraction.get.to!string);

    // Duplicate-paragraph fraction: two paragraphs separated by a blank
    // line, both identical -- 1 duplicate out of 2 paragraphs.
    auto paraText = "alpha bravo\n\nalpha bravo";
    auto paraResult = computeQualityRatios(cast(const(ubyte)[]) paraText);
    assert(paraResult.duplicateParagraphFraction == 0.5, "dup para fraction: " ~
        paraResult.duplicateParagraphFraction.to!string);

    // A single internal newline never splits a paragraph (needs >=2).
    auto singleNewline = computeQualityRatios(cast(const(ubyte)[]) "alpha\nbravo");
    assert(singleNewline.duplicateParagraphFraction == 0.0);
}

unittest {
    import std.conv : to;
    import std.math : abs;

    // Top-n-gram / duplicate-n-gram fixtures, hand-verified against the
    // verified `datatrove` algorithm.
    //
    // "a b a b a b" -> words = [a,b,a,b,a,b] (6 words, rawChars = 11).
    // Top-2-gram: overlapping 2-grams = ["a b","b a","a b","b a","a b"];
    // "a b" appears 3 times (3 chars each) = 9 chars; "b a" appears 2 times.
    // topCharLength = 3*3 = 9; fraction = 9/11.
    auto text = "a b a b a b";
    auto result = computeQualityRatios(cast(const(ubyte)[]) text);
    assert(result.wordCount == 6);
    assert(result.rawChars == 11);
    assert(!result.topNGramCharFraction[0].isNull); // n=2
    assert(abs(result.topNGramCharFraction[0].get - (9.0 / 11.0)) < 1e-9,
        "top-2-gram char fraction: " ~ result.topNGramCharFraction[0].get.to!string);

    // Too few words for n=3,4 top-n-grams? 6 words >= 4, so all three
    // top-n-gram slots (n=2,3,4) are computed, not null, for this fixture.
    assert(!result.topNGramCharFraction[1].isNull);
    assert(!result.topNGramCharFraction[2].isNull);

    // Fewer than 2 words: n=2 top-gram must abstain (null).
    auto oneWord = computeQualityRatios(cast(const(ubyte)[]) "solo");
    assert(oneWord.wordCount == 1);
    assert(oneWord.topNGramCharFraction[0].isNull);
    assert(oneWord.duplicateNGramCharFraction[0].isNull); // n=5, needs >=5 words

    // Duplicate-5-gram fixture: 10 identical one-letter words "x" separated
    // by single spaces -> words=[x,x,x,x,x,x,x,x,x,x] (10 words, rawChars=19:
    // ten "x" plus nine spaces). find_all_duplicate concatenates words with
    // NO separator (unlike the space-joined top-n-gram helper), so it
    // operates purely on the word list; rawChars is only the fraction's
    // shared denominator. With n=5: idx=0 gram="xxxxx" (5 chars) not seen ->
    // add, idx=1; idx=1 gram="xxxxx" (same concatenation!) seen ->
    // repeatedChars+=5, idx=6; idx=6: idx+n=11>10=words.length -> loop ends.
    // repeatedChars=5, fraction = 5/19.
    auto tenX = computeQualityRatios(cast(const(ubyte)[]) "x x x x x x x x x x");
    assert(tenX.wordCount == 10);
    assert(tenX.rawChars == 19, "rawChars: " ~ tenX.rawChars.to!string);
    assert(!tenX.duplicateNGramCharFraction[0].isNull); // n=5
    assert(abs(tenX.duplicateNGramCharFraction[0].get - (5.0 / 19.0)) < 1e-9,
        "duplicate-5-gram char fraction: " ~ tenX.duplicateNGramCharFraction[0].get.to!string);

    // Concatenated n-gram identity intentionally ignores word boundaries:
    // ["ab", "c", ...] and ["a", "bc", ...] both materialize as the
    // exact same byte string under the frozen reference algorithm.
    auto boundaryAmbiguous = WordNgramIndex.build(
        ["ab", "c", "d", "e", "f", "a", "bc", "d", "e", "f"]);
    assert(duplicateNGramCharCount(boundaryAmbiguous, 5) == 6);
}
