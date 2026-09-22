/// Conservative repair of UTF-8 text mis-decoded through Latin-1/CP1252.
/// The byte transforms are exact; a badness model decides whether applying
/// one is safer than leaving the input alone. See THIRD_PARTY_NOTICES.md.
module filters.mojibake;

import pipeline : ConfiguredFilter, FilterOptions, registerFilterFactory;
import std.array : appender;
import std.conv : ConvException, to;
import std.range.primitives : empty, front, isForwardRange, isInputRange, popFront, save;
import std.string : split;
import std.typecons : No;
import std.utf : UTFException, byUTF, toUTF32;

/// CP1252 bytes 0x80..0x9F mapped to Unicode. Zero means undefined.
/// Verified against Unicode's VENDORS/MICSFT/WINDOWS/CP1252.TXT.
immutable dchar[32] cp1252HighRange = [
    0x20AC, 0,      0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0,      0x017D, 0,
    0,      0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0,      0x017E, 0x0178,
];

dchar cp1252ToUnicode(ubyte b) {
    if (b >= 0x80 && b <= 0x9F) {
        const c = cp1252HighRange[b - 0x80];
        return c == 0 ? dchar.init : c;
    }
    return cast(dchar) b;
}

private enum LegacyEncoding { latin1, cp1252 }

private bool legacyByte(dchar c, LegacyEncoding encoding, out ubyte result) {
    if (c <= 0xFF && (encoding == LegacyEncoding.latin1 || c <= 0x7F || c >= 0xA0)) {
        result = cast(ubyte) c;
        return true;
    }
    if (encoding == LegacyEncoding.cp1252) {
        foreach (i, mapped; cp1252HighRange) {
            if (mapped == c) {
                result = cast(ubyte)(0x80 + i);
                return true;
            }
        }
    }
    return false;
}

private bool canEncodeLegacy(string text, LegacyEncoding encoding) {
    foreach (dchar c; text) {
        ubyte ignored;
        if (!legacyByte(c, encoding, ignored)) return false;
    }
    return true;
}

/// Lazily expose each Unicode codepoint as its legacy byte. The function-local
/// result is a Voldemort range; callers compose it without naming its type.
/// Call `canEncodeLegacy` first, so `front` cannot encounter an unmappable
/// character.
private auto legacyBytes(string text, LegacyEncoding encoding) {
    struct LegacyBytes {
        private string source;
        private LegacyEncoding encoding;

        @property bool empty() const { return source.length == 0; }

        @property char front() const {
            assert(!empty);
            ubyte result;
            const mapped = legacyByte(source.front, encoding, result);
            assert(mapped);
            return cast(char) result;
        }

        void popFront() {
            assert(!empty);
            source.popFront();
        }

        @property LegacyBytes save() { return this; }
    }
    return LegacyBytes(text, encoding);
}

/// Compose the legacy-byte view with Phobos's strict, lazy UTF-8 decoder.
private auto decodedCandidate(string text, LegacyEncoding encoding) {
    return legacyBytes(text, encoding).byUTF!(dchar, No.useReplacementDchar);
}

/// Materialize a candidate that has already passed strict lazy UTF-8 decoding.
/// The decoded text's UTF-8 bytes are exactly the legacy-byte range, so do not
/// decode those bytes to dchar and encode them a second time. The public
/// string boundary still needs owned storage; reserve its known upper bound.
private string materializeValidatedCandidate(string text, LegacyEncoding encoding) {
    auto output = appender!string();
    output.reserve(text.length);
    foreach (char byteValue; legacyBytes(text, encoding)) output.put(byteValue);
    return output.data;
}

private string roundTrip(string text, LegacyEncoding encoding) {
    if (!canEncodeLegacy(text, encoding)) return null;
    try {
        return decodedCandidate(text, encoding).to!string;
    } catch (UTFException) {
        return null;
    }
}

string latin1RoundTrip(string text) { return roundTrip(text, LegacyEncoding.latin1); }
string cp1252RoundTrip(string text) { return roundTrip(text, LegacyEncoding.cp1252); }

private bool oneOf(string members)(dchar c) {
    // The scorer's sets are compile-time non-ASCII literals. Keep the hot
    // ASCII rejection sound, and compare Unicode scalars without repeatedly
    // decoding the UTF-8 membership string at runtime.
    static foreach (dchar member; toUTF32(members))
        static assert(member >= 0x80, "mojibake scorer set contains ASCII");
    if (c < 0x80) return false;
    static foreach (dchar member; toUTF32(members))
        if (c == member) return true;
    return false;
}
static assert(oneOf!"ÂÃÎÐ"('Ã'));
static assert(!oneOf!"ÂÃÎÐ"('A'));

private bool isBad(dchar c) { return oneOf!"¦¤¨¬¯¸ƒˆˇ˘˛˜†‡‰⌐◊�ªº"(c); }
private bool isLaw(dchar c) { return c == '¶' || c == '§'; }
private bool isCurrency(dchar c) { return oneOf!"¢£¥₧€"(c); }
private bool isStartPunctuation(dchar c) { return oneOf!"¡«¿΄΅‘‚“„•‹©"(c); }
private bool isEndPunctuation(dchar c) { return oneOf!"®»˝”›™"(c); }
private bool isNumericSymbol(dchar c) { return oneOf!"²³¹±¼½¾×µ÷⁄∂∆∏∑√∞∩∫≈≠≡≤≥№"(c); }
private bool isBox(dchar c) {
    return oneOf!"│┌┐┘├┤┬┼═║╒╓╔╕╖╗╘╙╚╛╜╝╞╟╠╡╢╣╤╥╦╧╨╩╪╫╬▀▄█▌▐░▒▓"(c);
}
private bool isUpperAccented(dchar c) {
    return (c >= 0xC0 && c <= 0xD1) ||
        oneOf!"ØÜÝĂĀĄĆČĎĐĘĚĒĖĞĢİĪĶĹĽŁĻŃŇŅŒŘŚŞŠŢŤŮŰŸŹŻŽҔ"(c);
}
private bool isLowerAccented(dchar c) {
    return c == 'ß' || (c >= 0xE0 && c <= 0xF1) ||
        oneOf!"ăąāćčďđęěēėğģįīķĺľłļœŕśşšťüźżžҕﬁﬂ"(c);
}
private bool isUpperCommon(dchar c) {
    return c == 'Þ' || (c >= 0x391 && c <= 0x3A9) ||
        (c >= 0x410 && c <= 0x42F) || oneOf!"ΆΈΉΊΌΎΏΪΫЁ"(c);
}
private bool isLowerCommon(dchar c) {
    return (c >= 0x3B1 && c <= 0x3C9) || (c >= 0x430 && c <= 0x45F) ||
        oneOf!"άέήίΰόύώϊϋ"(c);
}
private bool isKaomoji(dchar c) {
    return (c >= 0xD2 && c <= 0xD6) || (c >= 0xD9 && c <= 0xDC) ||
        (c >= 0xF2 && c <= 0xF6) || (c >= 0xF8 && c <= 0xFC) || oneOf!"ŐŌŪŲ°"(c);
}
private bool asciiLetter(dchar c) {
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
}
private bool whitespace(dchar c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r'; }

private enum : uint {
    catBad = 1 << 0,
    catLaw = 1 << 1,
    catCurrency = 1 << 2,
    catStart = 1 << 3,
    catEnd = 1 << 4,
    catNumeric = 1 << 5,
    catBox = 1 << 6,
    catUpperAccented = 1 << 7,
    catLowerAccented = 1 << 8,
    catUpperCommon = 1 << 9,
    catLowerCommon = 1 << 10,
    catKaomoji = 1 << 11,
}

private uint categories(dchar c) {
    if (c < 0x80) return 0;
    uint result;
    if (isBad(c)) result |= catBad;
    if (isLaw(c)) result |= catLaw;
    if (isCurrency(c)) result |= catCurrency;
    if (isStartPunctuation(c)) result |= catStart;
    if (isEndPunctuation(c)) result |= catEnd;
    if (isNumericSymbol(c)) result |= catNumeric;
    if (isBox(c)) result |= catBox;
    if (isUpperAccented(c)) result |= catUpperAccented;
    if (isLowerAccented(c)) result |= catLowerAccented;
    if (isUpperCommon(c)) result |= catUpperCommon;
    if (isLowerCommon(c)) result |= catLowerCommon;
    if (isKaomoji(c)) result |= catKaomoji;
    return result;
}

private bool has(uint value, uint category) { return (value & category) != 0; }
private bool broad(uint value) {
    return has(value, catBad | catLowerAccented | catUpperAccented | catBox |
        catStart | catEnd | catCurrency | catNumeric | catLaw);
}
private bool lowerish(uint value) {
    return has(value, catLowerAccented | catLowerCommon | catBox | catEnd |
        catCurrency | catNumeric);
}

private struct PlausibilityAnalysis {
    size_t badness;
    long penalties;
}

/// Traverse the decoded scalars once. `includePenalties` lets the public
/// badness-only entry point compile out the unrelated plausibility checks,
/// while full candidate scoring no longer decodes every scalar twice.
private PlausibilityAnalysis analyzePlausibility(bool includePenalties, Range)(Range text)
if (isInputRange!Range) {
    dchar previous = dchar.init;
    dchar current = dchar.init;
    uint previousCategories;
    uint currentCategories;
    size_t seen;
    PlausibilityAnalysis result;

    // Consume the UTF-8 string as a range without materializing UTF-32.
    foreach (dchar next; text) {
        const nextCategories = categories(next);
        if (next >= 0x80 && next <= 0x9F) result.badness++;
        static if (includePenalties) {
            if ((next < 0x20 && next != '\n' && next != '\r' && next != '\t') ||
                next == 0x7F) result.penalties -= 20;
            // A replacement character is damaged text, but a characteristic
            // three-character UTF-8 rendering of it is worse and can be
            // repaired without inventing any additional information.
            if (next == 0xFFFD) result.penalties -= 50;
            if ((next >= 0xE000 && next <= 0xF8FF) ||
                (next >= 0xF0000 && next <= 0xFFFFD) ||
                (next >= 0x100000 && next <= 0x10FFFD))
                result.penalties -= 20;
        }
        // Every adjacency/trigram rule needs a non-ASCII current or next
        // character. Skip the expensive Unicode membership predicates for
        // the overwhelmingly common ASCII-to-ASCII transitions.
        if (seen >= 1 && (current >= 0x80 || next >= 0x80)) {
            const c = current;
            const n = next;
            if ((c == 'œ' || c == 'Œ') && !asciiLetter(n)) result.badness++;
            if ((broad(currentCategories) && has(nextCategories, catBad)) ||
                (has(currentCategories, catBad) && broad(nextCategories)) ||
                (lowerish(currentCategories) && has(nextCategories, catUpperAccented)) ||
                (has(currentCategories, catBox | catEnd | catCurrency | catNumeric) &&
                    has(nextCategories, catLowerAccented)) ||
                (has(currentCategories, catLowerAccented | catBox | catEnd) &&
                    has(nextCategories, catCurrency)) ||
                (has(currentCategories, catUpperAccented) &&
                    has(nextCategories, catNumeric | catLaw)) ||
                (has(currentCategories, catCurrency | catNumeric | catBox) &&
                    has(nextCategories, catStart)) ||
                (has(currentCategories, catBox) && has(nextCategories, catKaomoji)) ||
                (broad(currentCategories) && has(nextCategories, catBox)) ||
                (has(currentCategories, catBox) && has(nextCategories, catEnd)))
                result.badness++;

            if (oneOf!"ÂÃÎÐ"(c) && oneOf!"€œŠš¢£Ÿž ­®©°·»‘‚“„•‹”›™–—´"(n)) result.badness++;
            if (c == '×' && oneOf!"²³"(n)) result.badness++;
            if (c == 'à' && oneOf!"²µ¹¼½¾"(n)) result.badness++;
            if (c == 'Ã' && (n == 0xA0 || n == '¡')) result.badness++;
            if ((c == 'Ã' || c == 'Â') && n == ' ' &&
                (seen == 1 || asciiLetter(previous) || whitespace(previous))) result.badness++;
            if (has(currentCategories, catUpperAccented) && n == '°') result.badness++;

            if (seen >= 2) {
                const p = previous;
                if (asciiLetter(p) &&
                    has(currentCategories, catLowerCommon | catUpperCommon) &&
                    has(nextCategories, catBad)) result.badness++;
                if (oneOf!"ØÙ"(p) && broad(currentCategories) && oneOf!"ØÙ"(n)) result.badness++;
                if (oneOf!"ВГРС"(p) && broad(currentCategories) && oneOf!"ВГРС"(n)) result.badness++;
                if (oneOf!"ΒΓΞΟ"(p) && broad(currentCategories) && oneOf!"ΒΓΞΟ"(n)) result.badness++;
                if (p >= 'a' && p <= 'z' && has(currentCategories, catUpperAccented) &&
                    has(nextCategories, catStart | catCurrency)) result.badness++;
                if (has(previousCategories, catUpperAccented | catLowerAccented) &&
                    has(currentCategories, catStart | catEnd) && asciiLetter(n)) result.badness++;
                if (has(previousCategories, catLowerAccented | catUpperAccented |
                        catCurrency | catNumeric | catBox | catLaw) &&
                    has(currentCategories, catEnd) && has(nextCategories, catStart))
                    result.badness++;
                if (has(previousCategories, catLowerAccented | catUpperAccented |
                        catCurrency | catNumeric | catBox | catLaw) &&
                    has(currentCategories, catStart) && has(nextCategories, catNumeric))
                    result.badness++;
            }
        }
        previous = current;
        previousCategories = currentCategories;
        current = next;
        currentCategories = nextCategories;
        seen++;
    }
    if (seen > 0 && (current == 'œ' || current == 'Œ')) result.badness++;
    return result;
}

/// Count unlikely character juxtapositions. This is a conservative subset of
/// ftfy's badness model, restricted to the encodings scrubbed supports.
size_t mojibakeBadness(Range)(Range text)
if (isInputRange!Range) {
    return analyzePlausibility!false(text).badness;
}

/// Higher means more plausible. Mojibake evidence dominates; unsafe controls,
/// replacement characters, and private-use codepoints receive extra penalties.
long plausibilityScore(Range)(Range text)
if (isInputRange!Range) {
    const analysis = analyzePlausibility!true(text);
    return -100L * cast(long) analysis.badness + analysis.penalties;
}

private struct MojibakeOptions {
    size_t maxPasses = 4;
    bool useLatin1 = true;
    bool useCp1252 = true;
}

private MojibakeOptions parseOptions(const ref FilterOptions options) {
    MojibakeOptions result;
    foreach (key; options.keys)
        if (key != "max-passes" && key != "encodings")
            throw new Exception("unknown option '" ~ key ~ "' for filter 'fix-mojibake'");
    if (auto value = "max-passes" in options) {
        try result.maxPasses = (*value).to!size_t;
        catch (ConvException) throw new Exception("fix-mojibake max-passes must be an integer");
    }
    if (auto value = "encodings" in options) {
        result.useLatin1 = false;
        result.useCp1252 = false;
        foreach (name; (*value).split(',')) {
            if (name == "latin1") result.useLatin1 = true;
            else if (name == "cp1252") result.useCp1252 = true;
            else throw new Exception("fix-mojibake unknown encoding: " ~ name);
        }
    }
    return result;
}

private bool scoreCandidate(string text, LegacyEncoding encoding, out long score) {
    if (!canEncodeLegacy(text, encoding)) return false;
    try {
        score = plausibilityScore(decodedCandidate(text, encoding));
        return true;
    } catch (UTFException) {
        return false;
    }
}

/// Return the end byte offset of one exact UTF-8 sequence represented by
/// legacy codepoints. An invalid or incomplete sequence is not a candidate.
private size_t legacySequenceEnd(string text, size_t start, LegacyEncoding encoding) {
    auto rest = text[start .. $];
    ubyte lead;
    if (!legacyByte(rest.front, encoding, lead)) return start;
    const width = lead >= 0xC2 && lead <= 0xDF ? 2 :
        lead >= 0xE0 && lead <= 0xEF ? 3 :
        lead >= 0xF0 && lead <= 0xF4 ? 4 : 0;
    if (width == 0) return start;
    rest.popFront();
    foreach (_; 1 .. width) {
        if (rest.empty) return start;
        ubyte next;
        if (!legacyByte(rest.front, encoding, next) || next < 0x80 || next > 0xBF)
            return start;
        rest.popFront();
    }
    const end = text.length - rest.length;
    long ignored;
    return scoreCandidate(text[start .. end], encoding, ignored) ? end : start;
}

/// Scan only exact legacy-encoded UTF-8 sequences. Unmatched slices are
/// appended directly from the original buffer, never decoded or re-encoded.
private string repairLocal(string text, MojibakeOptions options, size_t remainingPasses) {
    auto output = appender!string();
    size_t copiedUntil;
    size_t at;
    while (at < text.length) {
        size_t bestEnd;
        LegacyEncoding bestEncoding;
        long bestGain;
        foreach (encoding; [LegacyEncoding.latin1, LegacyEncoding.cp1252]) {
            if ((encoding == LegacyEncoding.latin1 && !options.useLatin1) ||
                (encoding == LegacyEncoding.cp1252 && !options.useCp1252)) continue;
            auto end = legacySequenceEnd(text, at, encoding);
            if (end == at) continue;
            // Standalone C2 pairs are ambiguous; permit one only when joined
            // to a preceding higher-byte sequence in the same local island.
            ubyte lead;
            legacyByte(text[at .. $].front, encoding, lead);
            if (lead == 0xC2) continue;
            // Score the minimal complete sequence first. A positive score
            // here must not carry an adjacent ambiguous C2 sequence along.
            const atom = text[at .. end];
            long decodedScore;
            if (!scoreCandidate(atom, encoding, decodedScore)) continue;
            const atomicGain = decodedScore - plausibilityScore(atom);
            if (atomicGain > bestGain) {
                bestGain = atomicGain;
                bestEnd = end;
                bestEncoding = encoding;
            }
            // Only exact second-pass improvement can justify grouping
            // adjacent sequences for double-mangled text. Capping
            // this at four sequences keeps long lookalike runs linear-time.
            if (remainingPasses < 2) continue;
            foreach (_; 1 .. 4) {
                const next = end < text.length ? legacySequenceEnd(text, end, encoding) : end;
                if (next == end) break;
                end = next;
                const span = text[at .. end];
                if (!scoreCandidate(span, encoding, decodedScore)) continue;
                const intermediate = materializeValidatedCandidate(span, encoding);
                foreach (nextEncoding; [LegacyEncoding.latin1, LegacyEncoding.cp1252]) {
                    if ((nextEncoding == LegacyEncoding.latin1 && !options.useLatin1) ||
                        (nextEncoding == LegacyEncoding.cp1252 && !options.useCp1252)) continue;
                    long nextScore;
                    if (scoreCandidate(intermediate, nextEncoding, nextScore)) {
                        const improvement = nextScore - plausibilityScore(span);
                        if (improvement > 0 && nextScore > decodedScore &&
                            improvement >= bestGain) {
                            bestGain = improvement;
                            bestEnd = end;
                            bestEncoding = encoding;
                        }
                    }
                }
            }
        }
        if (bestGain > 0) {
            // Preserve the allocation-free unchanged path, but give the first
            // real repair enough capacity for the overwhelmingly common case
            // where UTF-8 mojibake shrinks or retains the input byte length.
            if (copiedUntil == 0) output.reserve(text.length);
            output.put(text[copiedUntil .. at]);
            output.put(materializeValidatedCandidate(text[at .. bestEnd], bestEncoding));
            copiedUntil = bestEnd;
            at = bestEnd;
        } else {
            auto rest = text[at .. $];
            rest.popFront();
            at = text.length - rest.length;
        }
    }
    if (copiedUntil == 0) return text;
    output.put(text[copiedUntil .. $]);
    return output.data;
}

private bool allASCII(string text) {
    // Byte iteration is sufficient: every non-ASCII UTF-8 sequence has at
    // least one high bit. Keep this admission scan out of the variable-width
    // Unicode decoder; compiler/codegen choices are measured separately.
    foreach (char byteValue; text)
        if ((cast(ubyte) byteValue & 0x80) != 0) return false;
    return true;
}

private string repairMojibake(string text, MojibakeOptions options) {
    // An ASCII buffer is already an exact fixed point for both supported
    // round trips. This also keeps ordinary mmap-backed documents borrowed.
    if (allASCII(text)) return text;
    foreach (pass; 0 .. options.maxPasses) {
        LegacyEncoding winner;
        bool haveWinner;
        long bestScore = plausibilityScore(text);
        // Scores cannot exceed zero. Avoid constructing or decoding either
        // candidate for the overwhelmingly common already-clean case.
        if (bestScore == 0) break;

        foreach (encoding; [LegacyEncoding.latin1, LegacyEncoding.cp1252]) {
            if ((encoding == LegacyEncoding.latin1 && !options.useLatin1) ||
                (encoding == LegacyEncoding.cp1252 && !options.useCp1252)) continue;
            long candidateScore;
            if (scoreCandidate(text, encoding, candidateScore) && candidateScore > bestScore) {
                winner = encoding;
                haveWinner = true;
                bestScore = candidateScore;
            }
        }
        if (!haveWinner) {
            // Preserve the old whole-string decision for its original
            // repertoire. Local repair is for an unmappable surrounding
            // codepoint that prevented that decision from being made.
            if ((options.useLatin1 && canEncodeLegacy(text, LegacyEncoding.latin1)) ||
                (options.useCp1252 && canEncodeLegacy(text, LegacyEncoding.cp1252))) break;
            const local = repairLocal(text, options, options.maxPasses - pass);
            if (local == text) break;
            text = local;
            continue;
        }

        // Candidate scoring above is lazy and does not allocate candidate
        // output buffers. Materialize only the winner for the next pass.
        text = materializeValidatedCandidate(text, winner);
    }
    return text;
}

/// Iteration repairs double/triple mangling. Ties preserve the current text:
/// reversibility by itself is never evidence that text is corrupt.
string fixMojibake(string text) {
    return repairMojibake(text, MojibakeOptions());
}

private ConfiguredFilter configureMojibake(const ref FilterOptions options) {
    const parsed = parseOptions(options);
    return (string text) => repairMojibake(text, parsed);
}

static this() {
    registerFilterFactory("fix-mojibake", &configureMojibake);
}

unittest {
    import std.exception : enforce;
    enforce(mojibakeBadness("CafÃ© at noon; the sign said rÃ©sumÃ©.\n") == 7,
        "mojibake scorer rule weights changed on the benchmark fixture");
    auto bytes = legacyBytes("schÃ¶n", LegacyEncoding.cp1252);
    static assert(isInputRange!(typeof(bytes)));
    static assert(isForwardRange!(typeof(bytes)));
    auto decoded = decodedCandidate("schÃ¶n", LegacyEncoding.cp1252);
    static assert(isInputRange!(typeof(decoded)));
    static assert(isForwardRange!(typeof(decoded)));
    assert(decoded.to!string == "schön");
}

unittest {
    immutable fixes = [
        "schÃ¶n" : "schön", "donâ€™t" : "don’t", "âœ” No problems" : "✔ No problems",
        "HÄ±rsÄ±zÄ± BÃ¼yÃ¼ Korkuttu" : "Hırsızı Büyü Korkuttu",
        "Ä°stanbul" : "İstanbul", "RUF MICH ZURÃœCK" : "RUF MICH ZURÜCK",
        "RÄ«ga" : "Rīga", "Ø±Ø³Ø§Ù„Ø©" : "رسالة",
        "Engkau masih yg terindah, indah di dalam hatikuâ™«~" :
            "Engkau masih yg terindah, indah di dalam hatiku♫~",
        "Some comments ï¿½ email addresses" : "Some comments � email addresses",
        "The Mona Lisa doesnÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢t have eyebrows." :
            "The Mona Lisa doesn’t have eyebrows.",
    ];
    foreach (broken, repaired; fixes) assert(fixMojibake(broken) == repaired, broken);
}

unittest {
    immutable clean = [
        "café", "IL Y MARQUÉ…", "I'm not such a fan of Charlotte Brontë…”",
        "AHÅ™, the new sofa from IKEA", "higher values (“+” and “×” curves)",
        "Η ¨ανατροφή¨ δυστυχώς από τους προπονητές", "4288×…",
        "RETWEET SE VOCÊ…", "TEM QUE SEGUIR, SDV SÓ…", "Join ZZAJÉ’s Official Fan List",
        "L’épisode 8 est trop fou ouahh", "Ôôô VIDA MINHA", "2012—∞",
        "NESTLÉ® requiere contratar personal", "(-1/2)! = √π",
        "日本語 Ελληνικά русский العربية",
    ];
    foreach (text; clean) assert(fixMojibake(text) == text, text);
}

unittest {
    // A damaged island must not make adjacent unmappable Unicode an obstacle.
    assert(fixMojibake("🙂日本語 Ελληνικά العربية schÃ¶n 🐈") ==
        "🙂日本語 Ελληνικά العربية schön 🐈");
    assert(fixMojibake("🐈schÃ¶n🐈 donâ€™t 東京") ==
        "🐈schön🐈 don’t 東京");
    assert(fixMojibake("東京 schÃ¶n Αθήνα donâ€™t العربية") ==
        "東京 schön Αθήνα don’t العربية");
    assert(fixMojibake("🙂 ÃƒÂ¶ 🙂") == "🙂 ö 🙂");
    assert(fixMojibake("日本語 Ã¶ �🐈") == "日本語 ö �🐈");
    assert(fixMojibake("🐈 Ã©Â© 🐈") == "🐈 éÂ© 🐈");

    // Plausible legacy-looking text and an incomplete UTF-8 sequence abstain.
    foreach (text; ["🙂 café Â© Ω", "東京 Ãx🙂", "🙂 Ã 🐈", "العربية § ½ Ελληνικά"])
        assert(fixMojibake(text) == text, text);

    MojibakeOptions onePass;
    onePass.maxPasses = 1;
    assert(repairMojibake("🙂 ÃƒÂ¶ 🐈", onePass) != "🙂 ö 🐈");
}
