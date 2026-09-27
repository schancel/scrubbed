/// Pure, bounded order-0 token-frequency entropy over Unicode
/// letter/number/underscore token runs. No FFI, no vendored code -- Phobos
/// only -- and no other project-layer import, per `domain`'s own layering
/// rule (`scripts/check_modules.d`). This is one of the two independent
/// halves of #168's compressibility annotation (`effects
/// .compressibility_annotate_stage` owns the other half, the zstd
/// compression ratio); the two are computed independently and never combined
/// into a single scalar here.
///
/// **Tokenization rule (owner-confirmed, #168):** each maximal run of
/// Unicode letter (`std.uni.isAlpha`), Unicode number (`std.uni.isNumber`),
/// or ASCII underscore codepoints is one candidate token; a token is kept
/// only if it has at least `minEntropyTokenLength` codepoints. Every kept
/// token is lowercased codepoint-by-codepoint (`std.uni.toLower`) before
/// counting, so "Cooking" and "COOKING" are the same token. Digits are
/// retained -- a purely numeric run (e.g. "2024") is a valid token, not
/// discarded or normalized away. This is token-*frequency* order-0 entropy
/// (`H = -sum(p_i * log2(p_i))` over each distinct token's empirical
/// probability), deliberately not byte-frequency entropy -- the owner's
/// explicit #168 decision, chosen for stability under transliteration-
/// neutral rewording that individual byte histograms would not detect.
///
/// **Independent abstention, never a sentinel value.** `EntropyStatus
/// .computed`'s `entropy` can legitimately be exactly `0.0` (a document
/// reduced to one single repeated token has zero token-frequency entropy);
/// that must stay distinguishable from "nothing was measured," so this
/// module returns a typed status instead of overloading the numeric field.
/// `invalidUtf8` means tokenization never ran at all (the input bytes are
/// not valid UTF-8 -- this module's only hard input requirement, see the
/// caller's own doc comment for why zstd compression ratio deliberately has
/// no equivalent requirement). `noTokens` means tokenization *did* run over
/// valid UTF-8 but found zero qualifying runs (empty input, or content made
/// only of punctuation/whitespace/single-codepoint runs) -- a real,
/// independent abstention, never conflated with `invalidUtf8`.
module domain.token_entropy;

import std.math : log2;
import std.uni : isAlpha, isNumber, toLower;
import std.utf : UTFException, validate;

/// Bumped whenever the tokenization/casing/min-length rule itself changes;
/// bound into `compressibility-annotate`'s own schema-versioned extension
/// field for provenance, independent of that field's own schema version.
enum tokenEntropyTokenizerVersion = "token-entropy-unicode-lc-min2:v1";

/// A token shorter than this many codepoints (after casefolding) is dropped
/// before frequency counting -- single-letter runs are common punctuation-
/// adjacent noise ("a", "I") that would otherwise dominate short documents.
enum size_t minEntropyTokenLength = 2;

enum EntropyStatus { computed, invalidUtf8, noTokens }

struct TokenEntropyResult {
    EntropyStatus status;
    double entropy = 0.0;
    size_t tokenCount;
    size_t distinctTokenCount;
}

private bool isEntropyTokenChar(dchar c) pure @safe {
    return isAlpha(c) || isNumber(c) || c == '_';
}

/// Splits already-UTF-8-validated `text` into lowercased token runs, per the
/// module doc's tokenization rule. Each token is rebuilt codepoint-by-
/// codepoint through `toLower`, so a token's byte length can differ from its
/// source run's byte length (casefolding is not always length-preserving).
private string[] tokenizeForEntropy(const(char)[] text) pure @safe {
    string[] tokens;
    char[] current;
    size_t currentCodepoints;

    void flush() {
        if (currentCodepoints >= minEntropyTokenLength) tokens ~= current.idup;
        current = null;
        currentCodepoints = 0;
    }

    foreach (dchar c; text) {
        if (isEntropyTokenChar(c)) {
            current ~= toLower(c);
            ++currentCodepoints;
        } else {
            flush();
        }
    }
    flush();
    return tokens;
}

/// Order-0 Shannon entropy in bits over `tokens`' empirical frequency
/// distribution. `tokens` must be nonempty (the caller handles the
/// `noTokens` abstention before calling this).
private double shannonEntropyBits(const(string[]) tokens) pure @safe {
    size_t[string] counts;
    foreach (token; tokens) {
        auto existing = token in counts;
        if (existing) ++(*existing);
        else counts[token] = 1;
    }
    immutable double total = cast(double) tokens.length;
    double entropy = 0.0;
    foreach (count; counts.byValue) {
        immutable double p = cast(double) count / total;
        entropy -= p * log2(p);
    }
    return entropy;
}

/// Computes order-0 token-frequency entropy over `bytes`. Requires valid
/// UTF-8; see the module doc for the documented, deliberate asymmetry with
/// `compressibility-annotate`'s zstd compression ratio, which does not.
TokenEntropyResult tokenEntropy(const(ubyte)[] bytes) pure @trusted {
    auto text = cast(const(char)[]) bytes;
    try validate(text);
    catch (UTFException) return TokenEntropyResult(EntropyStatus.invalidUtf8);

    auto tokens = tokenizeForEntropy(text);
    if (tokens.length == 0) return TokenEntropyResult(EntropyStatus.noTokens);

    bool[string] distinct;
    foreach (token; tokens) distinct[token] = true;
    return TokenEntropyResult(EntropyStatus.computed, shannonEntropyBits(tokens),
        tokens.length, distinct.length);
}

unittest {
    import std.math : abs;

    // Empty input: valid (trivial) UTF-8, zero tokens -- `noTokens`, not
    // `invalidUtf8`.
    auto empty = tokenEntropy(cast(const(ubyte)[]) "");
    assert(empty.status == EntropyStatus.noTokens);
    assert(empty.tokenCount == 0 && empty.distinctTokenCount == 0);

    // Content with codepoints but no qualifying token runs (only
    // punctuation/whitespace and single-letter runs below the min length).
    auto noTokens = tokenEntropy(cast(const(ubyte)[]) "! . , a I ; -- ...");
    assert(noTokens.status == EntropyStatus.noTokens);

    // Invalid UTF-8: a lone continuation byte.
    auto invalid = tokenEntropy([cast(ubyte) 0xff, cast(ubyte) 0xfe]);
    assert(invalid.status == EntropyStatus.invalidUtf8);
    assert(invalid.tokenCount == 0 && invalid.distinctTokenCount == 0);

    // A single repeated token: entropy is exactly 0.0 -- a real, valid,
    // computed value, not "nothing to measure."
    auto repeated = tokenEntropy(cast(const(ubyte)[]) "ha ha ha ha ha");
    assert(repeated.status == EntropyStatus.computed);
    assert(repeated.tokenCount == 5 && repeated.distinctTokenCount == 1);
    assert(abs(repeated.entropy - 0.0) < 1e-9);

    // Two equally frequent distinct tokens: exactly 1.0 bit of entropy.
    auto twoEven = tokenEntropy(cast(const(ubyte)[]) "cat dog cat dog");
    assert(twoEven.status == EntropyStatus.computed);
    assert(twoEven.tokenCount == 4 && twoEven.distinctTokenCount == 2);
    assert(abs(twoEven.entropy - 1.0) < 1e-9);

    // Case-insensitivity: "Cooking"/"COOKING"/"cooking" collapse to one
    // token, so this is the same zero-entropy, one-distinct-token shape.
    auto cased = tokenEntropy(cast(const(ubyte)[]) "Cooking COOKING cooking");
    assert(cased.status == EntropyStatus.computed);
    assert(cased.tokenCount == 3 && cased.distinctTokenCount == 1);
    assert(abs(cased.entropy - 0.0) < 1e-9);

    // Digits are retained as valid tokens, not discarded.
    auto digits = tokenEntropy(cast(const(ubyte)[]) "2024 2024 2025");
    assert(digits.status == EntropyStatus.computed);
    assert(digits.tokenCount == 3 && digits.distinctTokenCount == 2);

    // Underscore continues a token (identifier-style runs stay one token).
    auto underscored = tokenEntropy(cast(const(ubyte)[]) "max_input_bytes max_input_bytes");
    assert(underscored.status == EntropyStatus.computed);
    assert(underscored.tokenCount == 2 && underscored.distinctTokenCount == 1);

    // Multilingual: non-Latin scripts are real letters under `std.uni
    // .isAlpha` and tokenize/casefold like any other script.
    auto multilingual = tokenEntropy(cast(const(ubyte)[]) "こんにちは 世界 こんにちは");
    assert(multilingual.status == EntropyStatus.computed);
    assert(multilingual.tokenCount == 3 && multilingual.distinctTokenCount == 2);

    // Higher, non-uniform-but-nontrivial entropy on natural-language-shaped
    // text: strictly between 0 and log2(distinct token count), pinned to a
    // concrete computed range rather than merely "is a double."
    auto natural = tokenEntropy(cast(const(ubyte)[])
        "the quick brown fox jumps over the lazy dog the fox runs");
    assert(natural.status == EntropyStatus.computed);
    assert(natural.tokenCount == 12);
    assert(natural.entropy > 2.8 && natural.entropy < 3.3);
}
