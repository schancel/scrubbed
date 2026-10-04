/// The two XML operations S3's small, flat response bodies need: finding
/// one element's text, and decoding character references. Neither
/// allocates; output goes to a caller-supplied sink or back into the input.
/// This is deliberately not a general XML parser -- see `s3lite.xml_error`
/// and `s3lite.xml_list` for the two shapes it serves.
module s3lite.xml_text;

import s3lite.fixed : indexOf;

@nogc nothrow pure:

/// The raw (still-encoded) text of the first `<tag>...</tag>` lying wholly
/// inside `xml[from .. limit]`. `found` is false when there is none.
inout(char)[] elementText(return scope inout(char)[] xml, scope const(char)[] tag,
        size_t from, size_t limit, out bool found) {
    found = false;
    if (limit > xml.length) limit = xml.length;
    size_t at = from;
    while (true) {
        immutable lt = indexOf(xml, '<', at);
        if (lt < 0 || lt + 1 + tag.length + 1 > limit) return null;
        immutable nameEnd = lt + 1 + tag.length;
        if (xml[lt + 1 .. nameEnd] == tag && xml[nameEnd] == '>') {
            immutable start = nameEnd + 1;
            // The matching close tag: "</" tag ">".
            size_t search = start;
            while (true) {
                immutable close = indexOf(xml, "</", search);
                if (close < 0 || close + 2 + tag.length + 1 > limit) return null;
                if (xml[close + 2 .. close + 2 + tag.length] == tag && xml[close + 2 + tag.length] == '>') {
                    found = true;
                    return xml[start .. close];
                }
                search = close + 2;
            }
        }
        at = lt + 1;
    }
}

private void putUtf8(Sink)(ref Sink sink, uint cp) {
    if (cp < 0x80) sink.put(cast(char) cp);
    else if (cp < 0x800) {
        sink.put(cast(char)(0xC0 | (cp >> 6)));
        sink.put(cast(char)(0x80 | (cp & 0x3F)));
    } else if (cp < 0x1_0000) {
        sink.put(cast(char)(0xE0 | (cp >> 12)));
        sink.put(cast(char)(0x80 | ((cp >> 6) & 0x3F)));
        sink.put(cast(char)(0x80 | (cp & 0x3F)));
    } else {
        sink.put(cast(char)(0xF0 | (cp >> 18)));
        sink.put(cast(char)(0x80 | ((cp >> 12) & 0x3F)));
        sink.put(cast(char)(0x80 | ((cp >> 6) & 0x3F)));
        sink.put(cast(char)(0x80 | (cp & 0x3F)));
    }
}

/// Length of the character reference at the start of `s` and the code
/// point it names, or 0 if `s` does not start with a recognised one.
private size_t referenceAt(scope const(char)[] s, out uint codePoint) {
    static struct Named { string text; char value; }
    static immutable Named[5] named = [Named("&lt;", '<'), Named("&gt;", '>'),
        Named("&amp;", '&'), Named("&quot;", '"'), Named("&apos;", '\'')];
    foreach (n; named)
        if (s.length >= n.text.length && s[0 .. n.text.length] == n.text) {
            codePoint = n.value;
            return n.text.length;
        }
    if (s.length < 4 || s[1] != '#') return 0;
    immutable hex = s[2] == 'x';
    uint value = 0;
    size_t i = hex ? 3 : 2;
    immutable first = i;
    for (; i < s.length && s[i] != ';'; i++) {
        immutable c = s[i];
        uint digit;
        if (c >= '0' && c <= '9') digit = c - '0';
        else if (hex && c >= 'a' && c <= 'f') digit = c - 'a' + 10;
        else if (hex && c >= 'A' && c <= 'F') digit = c - 'A' + 10;
        else return 0;
        value = value * (hex ? 16 : 10) + digit;
        if (value > 0x10_FFFF) return 0;
    }
    if (i == first || i == s.length) return 0;
    codePoint = value;
    return i + 1;
}

/// Writes `src` to `sink` (anything with `put(char)`) with the five named
/// entities and numeric character references decoded. Anything that is not
/// a well-formed reference is copied through unchanged.
void decodeEntitiesTo(Sink)(scope const(char)[] src, ref Sink sink) {
    size_t i = 0;
    while (i < src.length) {
        if (src[i] == '&') {
            uint cp;
            immutable n = referenceAt(src[i .. $], cp);
            if (n) { putUtf8(sink, cp); i += n; continue; }
        }
        sink.put(src[i]);
        i++;
    }
}

/// Decodes `text` over itself and returns the (never longer) result. A
/// decoded reference is never longer than its encoded form, so this cannot
/// overrun.
char[] decodeEntitiesInPlace(return scope char[] text) {
    static struct InPlace {
        char[] buf;
        size_t n;
        void put(char c) @nogc nothrow pure { buf[n++] = c; }
    }
    auto sink = InPlace(text);
    decodeEntitiesTo(text, sink);
    return text[0 .. sink.n];
}

unittest {
    static immutable source = "&quot;a&amp;b&quot; &#65;&#x1F600;&#xe9; &bogus; &#;";
    char[source.length] text = source;
    assert(decodeEntitiesInPlace(text[]) == "\"a&b\" A\U0001F600é &bogus; &#;");
}

unittest {
    // The last code point decodes; anything above it is not a character
    // reference and is copied through as written.
    static immutable source = "&#x10FFFF;|&#1114111;|&#x110000;|&#1114112;|&#xFFFFFFFFF;|&#99999999999;";
    char[source.length] text = source;
    assert(decodeEntitiesInPlace(text[]) ==
        "\U0010FFFF|\U0010FFFF|&#x110000;|&#1114112;|&#xFFFFFFFFF;|&#99999999999;");
}

unittest {
    bool found;
    auto xml = "<A><Key>k1</Key><Keys>no</Keys></A><Key>k2</Key>";
    assert(elementText(xml, "Key", 0, xml.length, found) == "k1" && found);
    assert(elementText(xml, "Keys", 0, xml.length, found) == "no" && found);
    assert(elementText(xml, "Key", 16, xml.length, found) == "k2" && found);
    assert(elementText(xml, "Key", 16, xml.length - 1, found) is null && !found);
    assert(elementText(xml, "Missing", 0, xml.length, found) is null && !found);
}
