/// Mojibake repair (ftfy's core case: UTF-8 text that was mis-decoded
/// through a single-byte legacy encoding, then re-encoded to UTF-8 --
/// e.g. "schön" corrupted to "schÃ¶n"). This is REVERSIBLE and exact for
/// the mechanical half of the problem: re-encode the (corrupted) text as
/// bytes in a candidate legacy encoding, then try decoding those bytes as
/// UTF-8. If that succeeds and produces more plausible text, it's very
/// likely the original.
///
/// TWO things are needed for a correct fixer and only the first is done
/// here -- see TODO below:
///   1. The mechanical round-trip transform for each candidate encoding
///      (DONE: latin1RoundTrip, cp1252RoundTrip).
///   2. A plausibility scorer to decide WHICH candidate (including "no
///      change") is actually the best fix -- ftfy's real value is in this
///      scoring heuristic, tuned over years against huge amounts of real
///      corrupted text (their own docs report <1 false positive per
///      million tweets). NOT implemented here -- this is the main
///      substantive work item, not a detail to bolt on at the end.
///
/// CP1252 table verified directly against the Unicode Consortium's own
/// mapping file (unicode.org/Public/MAPPINGS/VENDORS/MICSFT/WINDOWS/CP1252.TXT),
/// not from memory -- the 0x80-0x9F range is where CP1252 diverges from
/// plain Latin-1 (ISO-8859-1), which is identity (byte value == codepoint)
/// for the full 0x00-0xFF range and needs no table at all.
module filters.mojibake;

import std.utf : encode, decode, UTFException;
import std.array : appender;

/// CP1252's 0x80-0x9F range -> Unicode codepoint. 0 = undefined in CP1252
/// (bytes 0x81, 0x8D, 0x8F, 0x90, 0x9D have no assigned character).
immutable dchar[32] cp1252HighRange = [
    0x20AC, 0,      0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, // 80-87
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0,      0x017D, 0,      // 88-8F
    0,      0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, // 90-97
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0,      0x017E, 0x0178, // 98-9F
];

dchar cp1252ToUnicode(ubyte b) {
    if (b >= 0x80 && b <= 0x9F) {
        const c = cp1252HighRange[b - 0x80];
        return c == 0 ? dchar.init : c; // dchar.init (0xFFFF) signals "undefined"
    }
    return cast(dchar) b; // 0x00-0x7F and 0xA0-0xFF are identical to Latin-1
}

/// Re-encode `text` as single-byte Latin-1 (ISO-8859-1) -- identity
/// mapping, byte value == codepoint -- then try decoding those bytes as
/// UTF-8. Returns null if any character is outside Latin-1's range
/// (can't have been produced by this corruption path) or the bytes
/// aren't valid UTF-8 (also rules out this path).
string latin1RoundTrip(string text) {
    ubyte[] bytes;
    bytes.reserve(text.length);
    foreach (dchar c; text) {
        if (c > 0xFF)
            return null;
        bytes ~= cast(ubyte) c;
    }
    return tryDecodeUtf8(bytes);
}

/// Same idea via CP1252 instead of plain Latin-1 -- the more common
/// real-world case, since Windows-authored text mislabeled as Latin-1 is
/// actually CP1252 far more often than genuine ISO-8859-1.
string cp1252RoundTrip(string text) {
    ubyte[] bytes;
    bytes.reserve(text.length);
    foreach (dchar c; text) {
        if (c <= 0x7F || (c >= 0xA0 && c <= 0xFF)) {
            bytes ~= cast(ubyte) c;
            continue;
        }
        bool matched = false;
        foreach (i, mapped; cp1252HighRange) {
            if (mapped == c) {
                bytes ~= cast(ubyte)(0x80 + i);
                matched = true;
                break;
            }
        }
        if (!matched)
            return null; // codepoint can't have come from a CP1252 byte
    }
    return tryDecodeUtf8(bytes);
}

private string tryDecodeUtf8(const(ubyte)[] bytes) {
    try {
        auto s = cast(string) bytes.idup;
        import std.utf : validate;
        validate(s); // throws UTFException on invalid sequences
        return s;
    } catch (UTFException) {
        return null;
    }
}

// TODO (main work item for whoever picks this up): implement the
// plausibility scorer and the fixMojibake() entry point that ties it
// together:
//
//   string fixMojibake(string text) {
//       auto candidates = [text, latin1RoundTrip(text), cp1252RoundTrip(text)]
//           .filter!(c => c !is null);
//       return candidates.maxElement!(c => plausibilityScore(c));
//   }
//
// The scorer needs to distinguish "this repair produced normal text" from
// "this repair produced garbage" -- rough starting heuristics (verify
// against real corrupted-text fixtures, don't just trust intuition):
//   - penalize control characters (codepoint < 0x20, excluding \n\t\r)
//   - penalize U+FFFD (replacement character) and unassigned/private-use
//     codepoints
//   - penalize a HIGH proportion of non-ASCII characters in the "fixed"
//     candidate if the ORIGINAL was mostly ASCII (over-fixing already-
//     correct text is the main failure mode to guard against)
//   - reward common Latin-1-supplement letters (accented Latin) and the
//     CP1252 punctuation set (curly quotes, em-dash, ellipsis) appearing
//     in contexts consistent with normal prose (surrounded by letters,
//     not repeated nonsensically)
//
// Test against real known cases before trusting this, e.g.:
//   "schÃ¶n"        -> "schön"      (latin1/cp1252 round-trip of "schön")
//   "donâ€™t"       -> "don't"      (cp1252 round-trip; â€™ is CP1252's
//                                    encoding of U+2019 RIGHT SINGLE QUOTE,
//                                    double-mangled through UTF-8)
//   "café"          -> "café"       (already correct -- must NOT be "fixed")
