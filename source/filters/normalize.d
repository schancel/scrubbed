/// Simple, genuinely streaming normalization filters -- no whole-buffer
/// context needed, so these are real range pipelines (filter/map over the
/// character range), not string-in-string-out buffer copies pretending to
/// be a pipeline. Registered under `pipeline.d`'s filter registry so they
/// compose with mojibake.d and whatever gets added later (html2md, etc.)
/// via config, not code changes.
module filters.normalize;

import std.algorithm : filter;
import std.array : array;
import std.conv : to;
import std.range.primitives : ElementType, empty, front, isInputRange, popFront;
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

/// Normalize CRLF/CR line endings lazily. The function-local range is a D
/// "Voldemort type": callers compose it through `auto` without being able to
/// name its implementation type. No output storage exists until materialized.
auto normalizeLineEndings(Range)(Range input)
if (isInputRange!Range && is(ElementType!Range : dchar)) {
    struct NormalizedLineEndings {
        private Range source;

        @property bool empty() const { return source.empty; }

        @property dchar front() const {
            assert(!empty);
            return source.front == '\r' ? '\n' : source.front;
        }

        void popFront() {
            assert(!empty);
            const wasCR = source.front == '\r';
            source.popFront();
            if (wasCR && !source.empty && source.front == '\n')
                source.popFront();
        }
    }
    return NormalizedLineEndings(input);
}

string stripControlCharsFilter(string text) {
    // `to!string` here does a real UTF-32->UTF-8 transcode; a raw
    // `cast(string)` on the `dchar[]` from `.array` would silently
    // reinterpret bytes instead of converting them (caught by testing
    // this against real input, not just by reading the code -- it
    // compiled fine and produced NUL-interleaved garbage at runtime).
    return text.stripControlChars.array.to!string;
}

string normalizeLineEndingsFilter(string text) {
    return text.normalizeLineEndings.to!string;
}

static this() {
    registerFilter("strip-control", &stripControlCharsFilter);
    registerFilter("normalize-line-endings", &normalizeLineEndingsFilter);
}

unittest {
    assert("a\r\nb\rc\n".normalizeLineEndings.to!string == "a\nb\nc\n");
    // Demonstrate composition of two unnamed lazy range types with one final
    // allocation at the registry boundary.
    assert("a\r\n\0b".normalizeLineEndings.stripControlChars.to!string == "a\nb");
}
