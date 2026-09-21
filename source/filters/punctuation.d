/// Lazy smart-punctuation normalization.
module filters.punctuation;

import pipeline : registerFilter;
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

static this() { registerFilter("uncurl-quotes", &uncurlQuotesFilter); }

unittest {
    assert("“It’s ‘fine’,” she said.".uncurlQuotes.to!string ==
        "\"It's 'fine',\" she said.");
}
