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
import pipeline : StreamingFilter, StreamingState, maxStreamingExpansion,
    registerStreamingFilter;

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

private size_t stripControlPush(ref StreamingState, dchar input,
        dchar[maxStreamingExpansion]* output) pure {
    if (isControl(input) && input != '\n' && input != '\t' && input != '\r')
        return 0;
    (*output)[0] = input;
    return 1;
}

private size_t normalizeLineEndingsPush(ref StreamingState state, dchar input,
        dchar[maxStreamingExpansion]* output) pure {
    const hadCR = state.words[0] != 0;
    state.words[0] = 0;
    if (hadCR) {
        (*output)[0] = '\n';
        if (input == '\n') return 1;
        if (input == '\r') {
            state.words[0] = 1;
            return 1;
        }
        (*output)[1] = input;
        return 2;
    }
    if (input == '\r') {
        state.words[0] = 1;
        return 0;
    }
    (*output)[0] = input;
    return 1;
}

private size_t normalizeLineEndingsFinish(ref StreamingState state,
        dchar[maxStreamingExpansion]* output) pure {
    if (state.words[0] == 0) return 0;
    state.words[0] = 0;
    (*output)[0] = '\n';
    return 1;
}

static this() {
    registerStreamingFilter("strip-control",
        StreamingFilter(StreamingState.init, &stripControlPush, null));
    registerStreamingFilter("normalize-line-endings",
        StreamingFilter(StreamingState.init, &normalizeLineEndingsPush,
            &normalizeLineEndingsFinish));
}

unittest {
    assert("a\r\nb\rc\n".normalizeLineEndings.to!string == "a\nb\nc\n");
    // Demonstrate composition of two unnamed lazy range types with one final
    // allocation at the registry boundary.
    assert("a\r\n\0b".normalizeLineEndings.stripControlChars.to!string == "a\nb");
}
