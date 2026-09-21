/// Standalone decoding of numeric references and a documented useful subset
/// of common HTML named character references. This is not a full HTML parser.
module filters.entities;

import filters.mojibake : cp1252ToUnicode;
import pipeline : registerFilter;
import std.array : appender;
import std.conv : ConvException, to;
import std.utf : encode;

private string namedEntity(string name) {
    switch (name) {
        case "amp": return "&";
        case "lt": return "<";
        case "gt": return ">";
        case "quot": return "\"";
        case "apos": return "'";
        case "nbsp": return " ";
        case "copy": return "©";
        case "reg": return "®";
        case "hellip": return "…";
        case "ndash": return "–";
        case "mdash": return "—";
        case "lsquo": return "‘";
        case "rsquo": return "’";
        case "ldquo": return "“";
        case "rdquo": return "”";
        default: return null;
    }
}

private string numericEntity(string body) {
    if (body.length < 2 || body[0] != '#') return null;
    uint radix = 10;
    size_t start = 1;
    if (start < body.length && (body[start] == 'x' || body[start] == 'X')) {
        radix = 16;
        start++;
    }
    if (start == body.length) return null;
    try {
        auto value = body[start .. $].to!uint(radix);
        dchar c;
        if (value >= 0x80 && value <= 0x9F) {
            c = cp1252ToUnicode(cast(ubyte) value);
            if (c == dchar.init) c = 0xFFFD;
        } else if (value == 0 || value > 0x10FFFF ||
                   (value >= 0xD800 && value <= 0xDFFF)) {
            c = 0xFFFD;
        } else {
            c = cast(dchar) value;
        }
        char[4] encoded;
        return encoded[0 .. encode(encoded, c)].idup;
    } catch (ConvException) {
        return null;
    }
}

string decodeHtmlEntities(string text) {
    auto output = appender!string;
    output.reserve(text.length);
    size_t position;
    while (position < text.length) {
        if (text[position] != '&') {
            output.put(text[position++]);
            continue;
        }
        size_t end = position + 1;
        while (end < text.length && end - position <= 32 && text[end] != ';') end++;
        if (end >= text.length || text[end] != ';') {
            output.put(text[position++]);
            continue;
        }
        const body = text[position + 1 .. end];
        auto replacement = body.length && body[0] == '#'
            ? numericEntity(body) : namedEntity(body);
        if (replacement is null) {
            output.put(text[position .. end + 1]);
        } else {
            output.put(replacement);
        }
        position = end + 1;
    }
    return output.data;
}

private string decodeHtmlEntitiesFilter(string text) {
    return decodeHtmlEntities(text);
}

static this() { registerFilter("decode-html-entities", &decodeHtmlEntitiesFilter); }

unittest {
    assert(decodeHtmlEntities("Tom &amp; Jerry &lt;3 &#x1F600;") == "Tom & Jerry <3 😀");
    assert(decodeHtmlEntities("&#128; &#x80;") == "€ €");
    assert(decodeHtmlEntities("keep &unknown; and &amp without semicolon") ==
        "keep &unknown; and &amp without semicolon");
}
