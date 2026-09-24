/// One-pass HTML character-reference decoding in text or attribute-value context.
/// This is not an HTML tokenizer: callers must select the context themselves.
module filters.entities;

import filters.entities_data : findNamedEntity;
import filters.mojibake : cp1252ToUnicode;
import pipeline : registerSafeFilter;
import std.array : appender;
import std.utf : encode;

enum EntityContext { text, attribute }

private bool asciiAlphaNumeric(char c) pure {
    return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') ||
           (c >= 'a' && c <= 'z');
}

private int digitValue(char c, bool hex) pure {
    if (c >= '0' && c <= '9') return c - '0';
    if (hex && c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (hex && c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

private string codePointString(dchar c) pure {
    char[4] encoded;
    return encoded[0 .. encode(encoded, c)].idup;
}

private string numericReference(string text, ref size_t end) pure {
    size_t cursor = end + 1; // end initially points at '#'
    bool hex;
    if (cursor < text.length && (text[cursor] == 'x' || text[cursor] == 'X')) {
        hex = true;
        cursor++;
    }
    const start = cursor;
    ulong value;
    const radix = hex ? 16u : 10u;
    while (cursor < text.length) {
        const digit = digitValue(text[cursor], hex);
        if (digit < 0) break;
        // All larger values become U+FFFD; saturate rather than overflow.
        if (value <= 0x10FFFF) value = value * radix + digit;
        cursor++;
    }
    if (cursor == start) return null;
    end = cursor + (cursor < text.length && text[cursor] == ';' ? 1 : 0);
    if (value == 0 || value > 0x10FFFF ||
        (value >= 0xD800 && value <= 0xDFFF)) return codePointString(0xFFFD);
    if (value >= 0x80 && value <= 0x9F) {
        const mapped = cp1252ToUnicode(cast(ubyte) value);
        if (mapped != dchar.init) value = mapped;
    }
    return codePointString(cast(dchar) value);
}

/// Decode exactly once. The registered filter uses text context. For an HTML
/// attribute value, call this overload after tokenization with attribute context.
/// RAWTEXT, script, comments and other tokenizer states are not supported.
string decodeHtmlEntities(string text, EntityContext context = EntityContext.text) pure {
    auto output = appender!string;
    size_t copiedUntil;
    size_t position;
    while (position < text.length) {
        if (text[position] != '&') {
            position++;
            continue;
        }
        const start = position;
        size_t cursor = start + 1;
        string replacement;
        size_t replacementEnd;
        if (cursor < text.length && text[cursor] == '#') {
            replacement = numericReference(text, cursor);
            if (replacement !is null) {
                replacementEnd = cursor;
            }
        } else {
            string longest;
            size_t longestEnd;
            // WHATWG names consist of ASCII alphanumerics, optionally followed
            // by ';'. Retain the last valid prefix for the longest-match rule.
            // The pinned table's longest key is 33 bytes including '&'.
            while (cursor < text.length && cursor - start < 33 &&
                   asciiAlphaNumeric(text[cursor])) {
                cursor++;
                auto match = findNamedEntity(text[start .. cursor]);
                if (match !is null) {
                    longest = match;
                    longestEnd = cursor;
                }
            }
            if (cursor < text.length && text[cursor] == ';') {
                auto match = findNamedEntity(text[start .. cursor + 1]);
                if (match !is null) {
                    longest = match;
                    longestEnd = cursor + 1;
                }
            }
            if (longest !is null &&
                !(context == EntityContext.attribute && text[longestEnd - 1] != ';' &&
                  longestEnd < text.length &&
                  (asciiAlphaNumeric(text[longestEnd]) || text[longestEnd] == '='))) {
                replacement = longest;
                replacementEnd = longestEnd;
            }
        }
        if (replacement is null) {
            position = start + 1;
            continue;
        }
        if (copiedUntil == 0) output.reserve(text.length);
        output.put(text[copiedUntil .. start]);
        output.put(replacement);
        copiedUntil = replacementEnd;
        position = replacementEnd;
    }
    if (copiedUntil == 0) return text;
    output.put(text[copiedUntil .. $]);
    return output.data;
}

// The implementation uses only checked slices and GC-owned appenders; this
// wrapper is the explicit lifetime assertion required by the filter ABI.
private string decodeHtmlEntitiesFilter(string text) pure @trusted {
    return decodeHtmlEntities(text);
}

static this() {
    registerSafeFilter("decode-html-entities", &decodeHtmlEntitiesFilter);
}

unittest {
    // Differential cases pinned to the WHATWG entities.json digest recorded in
    // THIRD_PARTY_NOTICES.md, plus the HTML character-reference parse rules.
    assert(decodeHtmlEntities("Tom &amp; Jerry &lt;3 &#x1F600;") == "Tom & Jerry <3 😀");
    assert(decodeHtmlEntities("&notin; &notit; &NotEqualTilde;") == "∉ ¬it; ≂̸");
    assert(decodeHtmlEntities("&CounterClockwiseContourIntegral;") == "∳");
    assert(decodeHtmlEntities("&copy &amp= &unknown;") == "© &= &unknown;");
    assert(decodeHtmlEntities("&copy= &amp=", EntityContext.attribute) == "&copy= &amp=");
    assert(decodeHtmlEntities("&copy! &amp;", EntityContext.attribute) == "©! &");
    assert(decodeHtmlEntities("&notit; &notin;", EntityContext.attribute) == "&notit; ∉");
    assert(decodeHtmlEntities("&#0; &#xD800; &#1114112; &#128; &#x81;") ==
        "� � � € \u0081");
    assert(decodeHtmlEntities("&#65x &#x41Z &#x; &#99999999999999999;") ==
        "Ax AZ &#x; �");
    assert(decodeHtmlEntities("&#x41= &#128") == "A= €");
    assert(decodeHtmlEntities("&amp;lt;") == "&lt;");
    assert(decodeHtmlEntities(decodeHtmlEntities("&amp;lt;")) == "<"); // caller-requested second pass only
    assert(decodeHtmlEntities("left &unknown; &amp; &bogus; right") ==
        "left &unknown; & &bogus; right");
    assert(decodeHtmlEntities("&amp;&lt;") == "&<");

    auto clean = "plain café text";
    auto invalidOnly = "fish & chips &unknown; &#x;";
    assert(decodeHtmlEntities(clean).ptr is clean.ptr);
    assert(decodeHtmlEntities(invalidOnly).ptr is invalidOnly.ptr);
}
