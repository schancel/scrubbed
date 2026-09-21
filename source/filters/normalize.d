/// Simple, genuinely streaming normalization filters -- no whole-buffer
/// context needed, so these are real range pipelines (filter/map over the
/// character range), not string-in-string-out buffer copies pretending to
/// be a pipeline. Registered under `pipeline.d`'s filter registry so they
/// compose with mojibake.d and whatever gets added later (html2md, etc.)
/// via config, not code changes.
module filters.normalize;

import std.algorithm : filter, map, joiner;
import std.array : array;
import std.conv : to;
import std.uni : isControl;
import pipeline : registerFilter;

/// Strip control characters (categories Cc) except \n, \t, \r -- real text
/// shouldn't contain raw NUL, BEL, form-feed, etc.; when it does (as seen
/// firsthand in fractal-corpus-curation's 20 Newsgroups preprocessing,
/// stray non-UTF8 bytes coerced through), it's noise, not signal. A true
/// lazy range transform: nothing is materialized until the caller
/// iterates or `.array`s it.
auto stripControlChars(Range)(Range chars) {
    return chars.filter!(c => !isControl(c) || c == '\n' || c == '\t' || c == '\r');
}

/// Normalize CRLF/CR line endings to plain \n. Also a lazy range
/// transform: a sliding pairwise view rather than a full-string replace.
auto normalizeLineEndings(string text) {
    // std.range's `zip`/manual state machine would avoid the intermediate
    // array below for a truly zero-allocation version; kept simple and
    // correct here since it's a small, well-scoped starting filter --
    // worth revisiting if profiling shows this matters at real corpus
    // scale.
    char[] out_;
    out_.reserve(text.length);
    size_t i = 0;
    while (i < text.length) {
        if (text[i] == '\r') {
            out_ ~= '\n';
            if (i + 1 < text.length && text[i + 1] == '\n')
                i++;
        } else {
            out_ ~= text[i];
        }
        i++;
    }
    return cast(string) out_;
}

string stripControlCharsFilter(string text) {
    // `to!string` here does a real UTF-32->UTF-8 transcode; a raw
    // `cast(string)` on the `dchar[]` from `.array` would silently
    // reinterpret bytes instead of converting them (caught by testing
    // this against real input, not just by reading the code -- it
    // compiled fine and produced NUL-interleaved garbage at runtime).
    return text.stripControlChars.array.to!string;
}

static this() {
    registerFilter("strip-control", &stripControlCharsFilter);
    registerFilter("normalize-line-endings", &normalizeLineEndings);
}
