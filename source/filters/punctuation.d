/// Lazy smart-punctuation normalization.
module filters.punctuation;

import pipeline : StreamingFilter, StreamingState, maxStreamingExpansion,
    registerStreamingFilter;
import std.algorithm : map;
import std.conv : to;

private dchar straightenQuote(dchar c) {
    switch (c) {
        case '‘', '’', '‚', '‛', 'ʼ': return '\'';
        case '“', '”', '„', '‟': return '"';
        default: return c;
    }
}

/// Return a composable lazy range (a Phobos-generated Voldemort type).
auto uncurlQuotes(Range)(Range input) {
    return input.map!straightenQuote;
}

string uncurlQuotesFilter(string text) {
    return text.uncurlQuotes.to!string;
}

private size_t uncurlQuotesPush(ref StreamingState, dchar input,
    dchar[maxStreamingExpansion]* output) {
    (*output)[0] = straightenQuote(input);
    return 1;
}

static this() {
    registerStreamingFilter("uncurl-quotes",
        StreamingFilter(StreamingState.init, &uncurlQuotesPush, null));
}

unittest {
    assert("“It’s ‘fine’,” she said.".uncurlQuotes.to!string ==
        "\"It's 'fine',\" she said.");
}
