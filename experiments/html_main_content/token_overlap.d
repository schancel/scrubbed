/// Shared, pure word-level tokenized-overlap scoring for real-page held-out
/// main-content comparisons (issue #26's own metric). Extracted verbatim
/// (same formula, same normalization, same multiset semantics) out of
/// `fetch_held_out.sh`'s previously-embedded bash heredoc driver so the
/// metric has exactly one implementation, imported both by that script's
/// generated driver and by `benchmarks/external_comparator.d`'s
/// `main-content/scrubbed-vs-trafilatura` case (issue #229's next-slice
/// contract) -- never a second, parallel reimplementation.
///
/// Metric: word-level, case-normalized, whitespace-tokenized multiset
/// overlap. `precision = |overlap| / |extracted tokens|`,
/// `recall = |overlap| / |gold tokens|` -- the same family trafilatura's own
/// benchmark script uses. This module performs no I/O and holds no mutable
/// state; every function is a pure computation over its arguments.
module experiments.html_main_content.token_overlap;

import std.algorithm.iteration : splitter;
import std.string : indexOf, toLower;
import std.uni : isWhite;
import std.utf : encode;

/// ASCII/Unicode case fold plus whitespace-run collapse, matching the same
/// normalization family used on both sides of every comparison so
/// formatting differences between a corpus's annotation strings and any
/// extractor's own whitespace-collapsed text don't cost precision or recall.
string normalized(string value) pure {
    char[] result;
    bool pending;
    foreach (dchar c; value.toLower) {
        if (isWhite(c)) { if (result.length) pending = true; continue; }
        if (pending) { result ~= ' '; pending = false; }
        char[4] buf;
        result ~= buf[0 .. encode(buf, c)];
    }
    return result.idup;
}

/// Splits an already-`normalized` string on single spaces into a word
/// multiset (count per distinct token).
int[string] tokenCounts(string normalizedText) pure {
    int[string] counts;
    foreach (word; normalizedText.splitter(' '))
        if (word.length) counts[word] = counts.get(word, 0) + 1;
    return counts;
}

/// Merges token multiset `addition` into `accumulator` in place. Used to
/// accumulate gold tokens across several short probe-phrase chunks one at a
/// time, matching `tokenCounts`'s own per-chunk accumulation exactly (as
/// opposed to concatenating chunks into one string before tokenizing, which
/// would risk merging tokens across a chunk boundary that has no whitespace
/// of its own).
void mergeTokenCounts(ref int[string] accumulator, const int[string] addition) pure {
    foreach (word, n; addition) accumulator[word] = accumulator.get(word, 0) + n;
}

/// Result of scoring one extracted-text multiset against one gold multiset.
struct TokenOverlapScore {
    double precision = 0.0;
    double recall = 0.0;
    size_t overlap;
    size_t extractedTotal;
    size_t goldTotal;
}

/// Word-level, case-normalized, whitespace-tokenized multiset overlap:
/// `precision = |overlap| / |extracted tokens|`,
/// `recall = |overlap| / |gold tokens|`. Both inputs are already-merged
/// multisets (see `tokenCounts`/`mergeTokenCounts`); this function performs
/// no normalization or tokenization of its own.
TokenOverlapScore scoreTokenOverlap(const int[string] extractedTokens,
                                    const int[string] goldTokens) pure {
    size_t overlap;
    foreach (word, n; goldTokens) {
        auto found = word in extractedTokens;
        overlap += found ? (n < *found ? n : *found) : 0;
    }
    size_t extractedTotal;
    foreach (_, n; extractedTokens) extractedTotal += n;
    size_t goldTotal;
    foreach (_, n; goldTokens) goldTotal += n;
    TokenOverlapScore score;
    score.overlap = overlap;
    score.extractedTotal = extractedTotal;
    score.goldTotal = goldTotal;
    score.precision = extractedTotal ? cast(double) overlap / extractedTotal : 0.0;
    score.recall = goldTotal ? cast(double) overlap / goldTotal : 0.0;
    return score;
}

/// True when `needle`, after the same normalization applied to
/// `normalizedHaystack`, appears anywhere inside it as a substring -- used
/// for the "without" probe-phrase leak check (chrome text that should never
/// appear in a correct selection).
bool containsNormalized(string normalizedHaystack, string needle) pure {
    return normalizedHaystack.indexOf(normalized(needle)) >= 0;
}

unittest {
    assert(normalized("  Café   noon\n\tTest  ") == "café noon test");
    assert(normalized("") == "");

    auto counts = tokenCounts(normalized("the cat sat on the mat"));
    assert(counts["the"] == 2 && counts["cat"] == 1 && counts["mat"] == 1);

    int[string] gold;
    mergeTokenCounts(gold, tokenCounts(normalized("the cat")));
    mergeTokenCounts(gold, tokenCounts(normalized("the mat")));
    assert(gold["the"] == 2 && gold["cat"] == 1 && gold["mat"] == 1);

    auto extracted = tokenCounts(normalized("the cat sat on the mat"));
    auto score = scoreTokenOverlap(extracted, gold);
    // overlap: "the" min(2,2)=2, "cat" min(1,1)=1, "mat" min(1,1)=1 -> 4
    assert(score.overlap == 4);
    assert(score.extractedTotal == 6);
    assert(score.goldTotal == 4);
    assert(score.precision == 4.0 / 6.0);
    assert(score.recall == 4.0 / 4.0);

    // Empty gold/extracted must not divide by zero.
    TokenOverlapScore emptyGold = scoreTokenOverlap(extracted, null);
    assert(emptyGold.recall == 0.0);
    TokenOverlapScore emptyExtracted = scoreTokenOverlap(null, gold);
    assert(emptyExtracted.precision == 0.0);

    assert(containsNormalized(normalized("Home About Contact"), "about"));
    assert(!containsNormalized(normalized("Home About Contact"), "pricing"));
}
