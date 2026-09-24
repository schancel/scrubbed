/// Strict raw-byte to Unicode boundary. No charset guessing or replacement decoding.
module text.decoding;

import std.exception : enforce;

enum TextEncoding { utf8, utf16le, utf16be }
enum ByteOrderMark { none, utf8, utf16le, utf16be }
enum QuarantineReason {
    none,
    unsupportedCharset,
    ambiguousCharset,
    conflictingCharset,
    malformedUnicode,
    binaryControl,
}

/// The source label is caller-supplied provenance, not an interpreted path.
/// Raw bytes remain owned by the caller and are never retained in an outcome.
struct DecodeEvidence {
    string source;
    string declaredCharset;
    size_t rawByteCount;
    ByteOrderMark bom;
}

struct DecodedText {
    string text; // owned, valid UTF-8; a leading BOM is not text
    TextEncoding encoding;
    DecodeEvidence evidence;
    size_t consumedByteCount;
}

struct QuarantinedText {
    QuarantineReason reason;
    DecodeEvidence evidence;
    bool hasOffendingOffset;
    size_t offendingOffset; // absolute byte offset in caller input, when known
}

/// Tagged outcome; only the matching accessor may be read.
struct DecodeOutcome {
    private bool succeeded;
    private DecodedText decodedValue;
    private QuarantinedText quarantinedValue;

    bool isDecoded() const pure { return succeeded; }
    ref const(DecodedText) decoded() const pure {
        enforce(succeeded, "decode outcome is quarantined");
        return decodedValue;
    }
    ref const(QuarantinedText) quarantined() const pure {
        enforce(!succeeded, "decode outcome is decoded");
        return quarantinedValue;
    }
}

private enum Charset { absent, utf8, utf16le, utf16be, ambiguous, unsupported }

private bool asciiSpace(char c) pure nothrow @nogc {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f';
}

private bool asciiEqualIgnoreCase(string value, string expected) pure nothrow @nogc {
    if (value.length != expected.length) return false;
    foreach (i, c; value) {
        ubyte folded = cast(ubyte) c;
        if (folded >= 'A' && folded <= 'Z') folded += 'a' - 'A';
        if (folded != cast(ubyte) expected[i]) return false;
    }
    return true;
}

private Charset parseCharset(string label) pure nothrow @nogc {
    if (label is null) return Charset.absent;
    size_t start;
    size_t end = label.length;
    while (start < end && asciiSpace(label[start])) ++start;
    while (end > start && asciiSpace(label[end - 1])) --end;
    const normalized = label[start .. end];
    switch (normalized.length) {
        case 4:
            if (asciiEqualIgnoreCase(normalized, "utf8")) return Charset.utf8;
            break;
        case 5:
            if (asciiEqualIgnoreCase(normalized, "utf-8")) return Charset.utf8;
            if (asciiEqualIgnoreCase(normalized, "utf16")) return Charset.ambiguous;
            break;
        case 6:
            if (asciiEqualIgnoreCase(normalized, "utf-16")) return Charset.ambiguous;
            break;
        case 7:
            if (asciiEqualIgnoreCase(normalized, "utf16le")) return Charset.utf16le;
            if (asciiEqualIgnoreCase(normalized, "utf16be")) return Charset.utf16be;
            break;
        case 8:
            if (asciiEqualIgnoreCase(normalized, "utf-16le")) return Charset.utf16le;
            if (asciiEqualIgnoreCase(normalized, "utf-16be")) return Charset.utf16be;
            break;
        default: break;
    }
    return Charset.unsupported;
}

unittest {
    void checkCaseVariants(string spelling, Charset expected) {
        foreach (mask; 0 .. 1 << spelling.length) {
            auto variant = spelling.dup;
            foreach (i, ref c; variant) {
                if ((mask & (1 << i)) && c >= 'a' && c <= 'z') c -= 'a' - 'A';
            }
            assert(parseCharset(cast(string) variant) == expected);
            auto padded = "\t" ~ variant ~ "\r";
            assert(parseCharset(cast(string) padded) == expected);
        }
    }

    checkCaseVariants("utf8", Charset.utf8);
    checkCaseVariants("utf-8", Charset.utf8);
    checkCaseVariants("utf16le", Charset.utf16le);
    checkCaseVariants("utf-16le", Charset.utf16le);
    checkCaseVariants("utf16be", Charset.utf16be);
    checkCaseVariants("utf-16be", Charset.utf16be);
    checkCaseVariants("utf16", Charset.ambiguous);
    checkCaseVariants("utf-16", Charset.ambiguous);
    assert(parseCharset(null) == Charset.absent);
    assert(parseCharset("") == Charset.unsupported);
    assert(parseCharset("utf_8") == Charset.unsupported);
    assert(parseCharset("utf-16xx") == Charset.unsupported);
    assert(parseCharset("utf-\u00e9") == Charset.unsupported);
}

private bool matches(Charset label, TextEncoding encoding) pure {
    return (label == Charset.utf8 && encoding == TextEncoding.utf8) ||
        (label == Charset.utf16le && encoding == TextEncoding.utf16le) ||
        (label == Charset.utf16be && encoding == TextEncoding.utf16be);
}

private ByteOrderMark findBom(const(ubyte)[] raw) pure {
    if (raw.length >= 3 && raw[0] == 0xef && raw[1] == 0xbb && raw[2] == 0xbf)
        return ByteOrderMark.utf8;
    if (raw.length >= 2 && raw[0] == 0xff && raw[1] == 0xfe)
        return ByteOrderMark.utf16le;
    if (raw.length >= 2 && raw[0] == 0xfe && raw[1] == 0xff)
        return ByteOrderMark.utf16be;
    return ByteOrderMark.none;
}

private bool forbiddenControl(uint cp) pure {
    return (cp < 0x20 && cp != 0x09 && cp != 0x0a && cp != 0x0d) ||
        cp == 0x7f;
}

private void appendUtf8(ref char[] output, uint cp) pure {
    if (cp < 0x80) output ~= cast(char) cp;
    else if (cp < 0x800) {
        output ~= cast(char) (0xc0 | (cp >> 6));
        output ~= cast(char) (0x80 | (cp & 0x3f));
    } else if (cp < 0x10000) {
        output ~= cast(char) (0xe0 | (cp >> 12));
        output ~= cast(char) (0x80 | ((cp >> 6) & 0x3f));
        output ~= cast(char) (0x80 | (cp & 0x3f));
    } else {
        output ~= cast(char) (0xf0 | (cp >> 18));
        output ~= cast(char) (0x80 | ((cp >> 12) & 0x3f));
        output ~= cast(char) (0x80 | ((cp >> 6) & 0x3f));
        output ~= cast(char) (0x80 | (cp & 0x3f));
    }
}

private bool validUtf8(const(ubyte)[] raw, size_t start,
    out QuarantineReason reason, out size_t offset) pure {
    for (size_t i = start; i < raw.length;) {
        const lead = raw[i];
        const width = lead < 0x80 ? 1 : lead >= 0xc2 && lead <= 0xdf ? 2 :
            lead >= 0xe0 && lead <= 0xef ? 3 : lead >= 0xf0 && lead <= 0xf4 ? 4 : 0;
        if (width == 0 || width > raw.length - i) {
            reason = QuarantineReason.malformedUnicode; offset = i; return false;
        }
        uint cp = width == 1 ? lead : lead & (0x7f >> width);
        foreach (j; 1 .. width) {
            if ((raw[i + j] & 0xc0) != 0x80) {
                reason = QuarantineReason.malformedUnicode; offset = i + j; return false;
            }
            cp = (cp << 6) | (raw[i + j] & 0x3f);
        }
        if ((width == 2 && cp < 0x80) || (width == 3 && cp < 0x800) ||
            (width == 4 && cp < 0x10000) || cp > 0x10ffff ||
            (cp >= 0xd800 && cp <= 0xdfff)) {
            reason = QuarantineReason.malformedUnicode; offset = i; return false;
        }
        if (forbiddenControl(cp)) {
            reason = QuarantineReason.binaryControl; offset = i; return false;
        }
        i += width;
    }
    return true;
}

private uint read16(const(ubyte)[] raw, size_t i, TextEncoding encoding) pure {
    return encoding == TextEncoding.utf16le ?
        cast(uint) raw[i] | (cast(uint) raw[i + 1] << 8) :
        (cast(uint) raw[i] << 8) | raw[i + 1];
}

private bool decodeUtf16(const(ubyte)[] raw, size_t start, TextEncoding encoding,
    ref char[] output, out QuarantineReason reason, out size_t offset) pure {
    for (size_t i = start; i < raw.length;) {
        if (raw.length - i < 2) {
            reason = QuarantineReason.malformedUnicode; offset = i; return false;
        }
        uint cp = read16(raw, i, encoding);
        const first = i;
        i += 2;
        if (cp >= 0xd800 && cp <= 0xdbff) {
            if (raw.length - i < 2) {
                reason = QuarantineReason.malformedUnicode; offset = first; return false;
            }
            const low = read16(raw, i, encoding);
            if (low < 0xdc00 || low > 0xdfff) {
                reason = QuarantineReason.malformedUnicode; offset = i; return false;
            }
            cp = 0x10000 + ((cp - 0xd800) << 10) + (low - 0xdc00);
            i += 2;
        } else if (cp >= 0xdc00 && cp <= 0xdfff) {
            reason = QuarantineReason.malformedUnicode; offset = first; return false;
        }
        if (forbiddenControl(cp)) {
            reason = QuarantineReason.binaryControl; offset = first; return false;
        }
        appendUtf8(output, cp);
    }
    return true;
}

/// Decode a borrowed byte slice. The returned text is owned; quarantine
/// retains only metadata so large failed inputs are not copied or pinned.
DecodeOutcome decodeBytes(const(ubyte)[] raw, string declaredCharset = null,
    string source = "") pure {
    DecodeOutcome result;
    auto evidence = DecodeEvidence(source, declaredCharset, raw.length, findBom(raw));
    auto label = parseCharset(declaredCharset);
    QuarantineReason reason;
    size_t offset;
    bool hasOffset;
    if (label == Charset.unsupported || (label == Charset.ambiguous &&
        evidence.bom == ByteOrderMark.none)) {
        reason = label == Charset.ambiguous ? QuarantineReason.ambiguousCharset :
            QuarantineReason.unsupportedCharset;
    } else {
        TextEncoding encoding;
        size_t start;
        final switch (evidence.bom) {
            case ByteOrderMark.none: break;
            case ByteOrderMark.utf8: encoding = TextEncoding.utf8; start = 3; break;
            case ByteOrderMark.utf16le: encoding = TextEncoding.utf16le; start = 2; break;
            case ByteOrderMark.utf16be: encoding = TextEncoding.utf16be; start = 2; break;
        }
        if (evidence.bom == ByteOrderMark.none) {
            final switch (label) {
                case Charset.absent: case Charset.utf8: encoding = TextEncoding.utf8; break;
                case Charset.utf16le: encoding = TextEncoding.utf16le; break;
                case Charset.utf16be: encoding = TextEncoding.utf16be; break;
                case Charset.ambiguous: case Charset.unsupported: assert(0);
            }
        } else if (label != Charset.absent && !matches(label, encoding) &&
            !(label == Charset.ambiguous && encoding != TextEncoding.utf8)) {
            reason = QuarantineReason.conflictingCharset;
        }
        if (reason == QuarantineReason.init) {
            char[] output;
            if (encoding == TextEncoding.utf8) {
                if (validUtf8(raw, start, reason, offset))
                    output = cast(char[]) raw[start .. $].dup;
                else hasOffset = true;
            } else if (!decodeUtf16(raw, start, encoding, output, reason, offset)) {
                hasOffset = true;
            }
            if (reason == QuarantineReason.init) {
                result.succeeded = true;
                // output is freshly allocated and has no aliases after return.
                result.decodedValue = DecodedText(cast(string) output, encoding, evidence, raw.length);
                return result;
            }
        }
    }
    result.quarantinedValue = QuarantinedText(reason, evidence, hasOffset, offset);
    return result;
}

unittest {
    import std.exception : assertThrown;

    auto empty = decodeBytes(null, null, "empty-record");
    assert(empty.isDecoded && empty.decoded.text == "");
    assert(empty.decoded.evidence.declaredCharset is null);
    assert(decodeBytes(null).isDecoded); // omitted declaration
    assertThrown(empty.quarantined());
    assert(empty.decoded.consumedByteCount == 0);
    assert(empty.decoded.evidence.source == "empty-record");

    ubyte[] mutableBytes = [cast(ubyte) 'h', 0xc3, 0xa9];
    auto clean = decodeBytes(mutableBytes, null, "article-1");
    assert(clean.isDecoded && clean.decoded.text == "hé");
    assert(clean.decoded.encoding == TextEncoding.utf8);
    assert(clean.decoded.evidence.bom == ByteOrderMark.none);
    assert(clean.decoded.consumedByteCount == 3);
    mutableBytes[0] = 'x';
    assert(clean.decoded.text == "hé"); // success owns output

    auto bomOnly = decodeBytes([cast(ubyte) 0xef, 0xbb, 0xbf], "UTF8", "bom");
    assert(bomOnly.isDecoded && bomOnly.decoded.text == "");
    assert(bomOnly.decoded.evidence.bom == ByteOrderMark.utf8);
    assert(bomOnly.decoded.evidence.declaredCharset == "UTF8");
    assert(bomOnly.decoded.consumedByteCount == 3);

    auto le = decodeBytes([cast(ubyte) 0xff, 0xfe, 0x41, 0, 0x3d, 0xd8, 0x00, 0xde],
        " utf-16LE ", "le");
    assert(le.isDecoded && le.decoded.text == "A😀");
    assert(le.decoded.encoding == TextEncoding.utf16le);
    assert(le.decoded.evidence.bom == ByteOrderMark.utf16le);
    assert(le.decoded.consumedByteCount == 8);

    auto be = decodeBytes([cast(ubyte) 0xfe, 0xff, 0, 0x42], "utf-16", "be");
    assert(be.isDecoded && be.decoded.text == "B");
    assert(be.decoded.encoding == TextEncoding.utf16be);
    assert(decodeBytes([cast(ubyte) 0, 0x43], "UTF16BE").decoded.text == "C");
    assert(decodeBytes([cast(ubyte) 0x44, 0], "utf16le").decoded.text == "D");
}

unittest {
    import std.exception : assertThrown;

    assert("" !is null); // explicit literal is distinguishable from omission
    char[] ownedLabel = ['x'];
    string ownedEmpty = cast(string) ownedLabel[0 .. 0];
    assert(ownedEmpty !is null); // empty slice with owned backing

    void check(const(ubyte)[] bytes, string charset, string source,
        QuarantineReason reason, bool hasOffset, size_t offset,
        ByteOrderMark bom = ByteOrderMark.none) {
        auto result = decodeBytes(bytes, charset, source);
        assert(!result.isDecoded);
        assert(result.quarantined.reason == reason);
        assert(result.quarantined.evidence.source == source);
        assert(result.quarantined.evidence.declaredCharset == charset);
        assert(result.quarantined.evidence.declaredCharset.ptr == charset.ptr);
        assert(result.quarantined.evidence.rawByteCount == bytes.length);
        assert(result.quarantined.evidence.bom == bom);
        assert(result.quarantined.hasOffendingOffset == hasOffset);
        if (hasOffset) assert(result.quarantined.offendingOffset == offset);
    }
    check([cast(ubyte) 0xef, 0xbb, 0xbf, 0x41], "utf-16le", "conflict",
        QuarantineReason.conflictingCharset, false, 0, ByteOrderMark.utf8);
    check([cast(ubyte) 0xfe, 0xff], "utf-8", "conflict-be",
        QuarantineReason.conflictingCharset, false, 0, ByteOrderMark.utf16be);
    check([cast(ubyte) 0x41], "cp1252", "legacy",
        QuarantineReason.unsupportedCharset, false, 0);
    check([cast(ubyte) 0x41], "", "literal-blank",
        QuarantineReason.unsupportedCharset, false, 0);
    check([cast(ubyte) 0x41], ownedEmpty, "owned-blank",
        QuarantineReason.unsupportedCharset, false, 0);
    check([cast(ubyte) 0x41], " \t ", "whitespace-blank",
        QuarantineReason.unsupportedCharset, false, 0);
    check([cast(ubyte) 0xef, 0xbb, 0xbf], "", "bom-blank",
        QuarantineReason.unsupportedCharset, false, 0, ByteOrderMark.utf8);
    check([cast(ubyte) 0x41], "\u00a0utf-8", "nonascii-label",
        QuarantineReason.unsupportedCharset, false, 0);
    assertThrown(decodeBytes([cast(ubyte) 0x41], "cp1252").decoded());
    check([cast(ubyte) 0x41], "utf-16", "ambiguous",
        QuarantineReason.ambiguousCharset, false, 0);
    check([cast(ubyte) 0xe9], null, "undecidable",
        QuarantineReason.malformedUnicode, true, 0);
    check([cast(ubyte) 0xc0, 0xaf], null, "overlong",
        QuarantineReason.malformedUnicode, true, 0);
    check([cast(ubyte) 0x61, 0xe2, 0x82], null, "truncated",
        QuarantineReason.malformedUnicode, true, 1);
    check([cast(ubyte) 0xed, 0xa0, 0x80], null, "surrogate-utf8",
        QuarantineReason.malformedUnicode, true, 0);
    check([cast(ubyte) 0xf4, 0x90, 0x80, 0x80], null, "range",
        QuarantineReason.malformedUnicode, true, 0);
    check([cast(ubyte) 0x61, 0x00, 0x62], null, "nul",
        QuarantineReason.binaryControl, true, 1);
    check([cast(ubyte) 0x61, 0x1b, 0x62], null, "escape",
        QuarantineReason.binaryControl, true, 1);
    assert(decodeBytes([cast(ubyte) 0xc2, 0x85], null, "c1-text").decoded.text == "\u0085");
    check([cast(ubyte) 0xff, 0xfe, 0x00], null, "odd-utf16",
        QuarantineReason.malformedUnicode, true, 2, ByteOrderMark.utf16le);
    check([cast(ubyte) 0xff, 0xfe, 0x00, 0xd8], null, "high-surrogate",
        QuarantineReason.malformedUnicode, true, 2, ByteOrderMark.utf16le);
    check([cast(ubyte) 0xfe, 0xff, 0xdc, 0x00], null, "low-surrogate",
        QuarantineReason.malformedUnicode, true, 2, ByteOrderMark.utf16be);
    check([cast(ubyte) 0xff, 0xfe, 0x41, 0x00, 0x00, 0x00], null, "utf16-nul",
        QuarantineReason.binaryControl, true, 4, ByteOrderMark.utf16le);
    assert(decodeBytes([cast(ubyte) 0xff, 0xfe], "utf-16").decoded.text == "");
}
