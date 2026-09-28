/// Incremental, uncompressed WARC/1.1 record reader.
///
/// Ported unchanged from scrubbed's `source/effects/warc_reader.d` (see
/// https://github.com/schancel/scrubbed, `docs/warc-reader.md`) as a
/// standalone, zero-dependency package. This module reads only
/// **uncompressed** WARC/1.1 byte streams: gzip/zstd-compressed WARC
/// support and local-file transport are deliberately not included here --
/// see this package's README for scope and rationale.
module warc_reader.reader;

import std.string : indexOf, split;
import std.utf : validate;

enum size_t warcHeaderLimit = 4096;
enum size_t warcBlockLimit = 65536;
enum size_t warcRecordLimit = 131072;
enum size_t warcSourceKeyLimit = 4096;
enum size_t warcFieldLimit = 128;

final class WarcError : Exception {
    this(string reason) { super(reason); }
}

struct WarcField {
    string name;
    string value;
}

/// The record owns its header strings and block. Retaining it retains only this record.
struct WarcRecord {
    string sourceKey;
    size_t ordinal;
    string recordId;
    string date;
    string type;
    string targetUri;
    bool hasTargetUri;
    string contentType;
    WarcField[] fields;
    ubyte[] block;

    /// Only a UTF-8, text/plain conversion block is WET-style text.
    bool isConversionText() const {
        return type == "conversion" && contentType == "text/plain";
    }

    string conversionText() const {
        if (!isConversionText()) throw new WarcError("not a text/plain conversion");
        validateConversionText();
        return (cast(string) block).idup;
    }

    private void validateConversionText() const {
        try validate(cast(string) block);
        catch (Exception) { throw new WarcError("invalid UTF-8 conversion"); }
    }
}

alias WarcVisit = bool delegate(WarcRecord record);

/// Callbacks run only after a complete, validated record. Returning false cancels.
/// Any failure/cancellation poisons this reader; completed callbacks are not rolled back.
final class WarcReader {
    private enum Phase { header, block, separator }
    private Phase phase;
    private ubyte[] header;
    private WarcRecord current;
    private size_t declared;
    private size_t separatorAt;
    private size_t completed;
    private bool stopped;
    private bool inCallback;
    private string key;
    private WarcVisit visit;

    this(string sourceKey, WarcVisit onRecord) {
        if (sourceKey.length == 0 || sourceKey.length > warcSourceKeyLimit ||
            onRecord is null)
            throw new WarcError("source key byte cap and callback required");
        try validate(sourceKey);
        catch (Exception) { throw new WarcError("invalid UTF-8 source key"); }
        foreach (c; sourceKey)
            if (c == 0) throw new WarcError("NUL source key");
        key = sourceKey.idup;
        visit = onRecord;
    }

    size_t completedRecords() const { return completed; }

    void feed(const(ubyte)[] bytes) {
        if (inCallback) throw new WarcError("reentrant reader call");
        if (stopped) throw new WarcError("reader stopped");
        try {
            size_t at;
            while (at < bytes.length) {
                final switch (phase) {
                    case Phase.header:
                        if (header.length >= warcHeaderLimit) fail("header cap");
                        header ~= bytes[at++];
                        if (header.length >= 4 && header[$ - 4 .. $] ==
                            cast(const(ubyte)[]) "\r\n\r\n") {
                            parseHeader();
                            phase = declared == 0 ? Phase.separator : Phase.block;
                        }
                        break;
                    case Phase.block:
                        auto remaining = declared - current.block.length;
                        auto count = bytes.length - at < remaining ? bytes.length - at : remaining;
                        current.block ~= bytes[at .. at + count];
                        at += count;
                        if (current.block.length == declared) phase = Phase.separator;
                        break;
                    case Phase.separator:
                        immutable terminator = "\r\n\r\n";
                        if (bytes[at++] != terminator[separatorAt++]) fail("record terminator");
                        if (separatorAt == 4) emit();
                        break;
                }
            }
        } catch (Exception error) {
            stopped = true;
            throw error;
        }
    }

    void finish() {
        if (inCallback) throw new WarcError("reentrant reader call");
        if (stopped) throw new WarcError("reader stopped");
        if (phase != Phase.header || header.length != 0 || completed == 0) {
            stopped = true;
            throw new WarcError(completed == 0 && header.length == 0 ?
                "empty archive" : "truncated record");
        }
        stopped = true;
    }

    private void emit() {
        if (current.isConversionText()) current.validateConversionText();
        auto record = current;
        current = WarcRecord.init;
        header = null;
        separatorAt = 0;
        phase = Phase.header;
        inCallback = true;
        scope(exit) inCallback = false;
        if (!visit(record)) fail("callback cancelled");
        ++completed;
    }

    private void parseHeader() {
        if (key.length + header.length + 4 > warcRecordLimit) fail("record cap");
        auto text = cast(string) header;
        if (text.length < 14 || text[0 .. 10] != "WARC/1.1\r\n")
            fail("unsupported WARC version or line ending");
        auto lines = text[0 .. $ - 4].split("\r\n");
        current = WarcRecord.init;
        current.sourceKey = key;
        current.ordinal = completed + 1;
        bool idSeen, dateSeen, typeSeen, lengthSeen, uriSeen, contentTypeSeen;
        foreach (line; lines[1 .. $]) {
            if (line.length == 0 || line[0] == ' ' || line[0] == '\t')
                fail("folded or empty header field unsupported");
            auto colon = line.indexOf(':');
            if (colon <= 0) fail("invalid header field");
            auto name = line[0 .. colon];
            foreach (c; name)
                if (c < 33 || c > 126 ||
                    ("()<>@,;:/[]?={} " ~ "\x22\x5c").indexOf(c) >= 0)
                    fail("invalid field name");
            auto raw = line[colon + 1 .. $];
            foreach (c; raw)
                if ((c < 32 && c != '\t') || c == 127)
                    fail("control character in header value");
            auto value = trimSpace(raw);
            auto lower = asciiLower(name);
            if (!uriStructuredField(lower) && containsEncodedWord(value))
                fail("encoded-word fields unsupported");
            try validate(value);
            catch (Exception) { fail("invalid UTF-8 header value"); }
            // Own strings: no emitted field aliases the mutable header buffer.
            if (current.fields.length >= warcFieldLimit) fail("header field cap");
            current.fields ~= WarcField(name.idup, raw.idup);
            switch (lower) {
                case "warc-record-id":
                    if (idSeen) fail("duplicate record ID");
                    idSeen = true; current.recordId = value.idup; break;
                case "warc-date":
                    if (dateSeen) fail("duplicate date");
                    dateSeen = true; current.date = value.idup; break;
                case "warc-type":
                    if (typeSeen) fail("duplicate type");
                    typeSeen = true; current.type = value.idup; break;
                case "warc-target-uri":
                    if (uriSeen) fail("duplicate target URI");
                    uriSeen = true; current.hasTargetUri = true;
                    current.targetUri = value.idup; break;
                case "content-type":
                    if (contentTypeSeen) fail("duplicate content type");
                    contentTypeSeen = true; current.contentType = value.idup; break;
                case "content-length":
                    if (lengthSeen) fail("duplicate length");
                    lengthSeen = true; declared = parseLength(value); break;
                case "warc-segment-number":
                case "warc-segment-origin-id":
                case "warc-segment-total-length":
                    fail("segmented records unsupported");
                    break;
                default: break;
            }
        }
        if (!idSeen || !dateSeen || !typeSeen || !lengthSeen)
            fail("missing required field");
        if (!uriShape(current.recordId, true) || current.date.length == 0 ||
            current.type.length == 0) fail("invalid required field");
        if (current.type == "warcinfo") {
            if (uriSeen) fail("warcinfo target URI forbidden");
        } else if (current.type == "metadata") {
            if (uriSeen && !uriShape(current.targetUri, false)) fail("invalid target URI");
        } else if (!uriSeen || !uriShape(current.targetUri, false)) {
            fail("target URI required");
        }
        if (current.type == "continuation") fail("segmented records unsupported");
        if (key.length + header.length + declared + 4 > warcRecordLimit)
            fail("record cap");
        current.block.reserve(declared);
    }

    private static size_t parseLength(string value) {
        if (value.length == 0) fail("empty content length");
        size_t result;
        foreach (c; value) {
            if (c < '0' || c > '9') fail("invalid content length");
            auto digit = cast(size_t)(c - '0');
            if (result > (warcBlockLimit - digit) / 10) fail("block cap or overflow");
            result = result * 10 + digit;
        }
        return result;
    }

    // RFC 2047's complete =?charset?[BQ]?encoded-text?= shape. A bare
    // "=?" is ordinary text (and can occur in a legal query URI).
    private static bool containsEncodedWord(string value) {
        foreach (start; 0 .. value.length) {
            if (value[start] != '=' || start + 1 >= value.length ||
                value[start + 1] != '?') continue;
            size_t at = start + 2;
            auto charsetStart = at;
            while (at < value.length && rfc2047Token(value[at])) ++at;
            if (at == charsetStart || at >= value.length || value[at] != '?') continue;
            ++at;
            if (at + 1 >= value.length ||
                (value[at] != 'B' && value[at] != 'b' &&
                 value[at] != 'Q' && value[at] != 'q') || value[at + 1] != '?')
                continue;
            at += 2;
            auto textStart = at;
            while (at < value.length && value[at] >= '!' && value[at] <= '~' &&
                value[at] != '?') ++at;
            if (at > textStart && at + 1 < value.length && value[at] == '?' &&
                value[at + 1] == '=' && at + 2 - start <= 75) return true;
        }
        return false;
    }

    private static bool rfc2047Token(char c) {
        return c >= '!' && c <= '~' &&
            ("()<>@,;:/[]?.= " ~ "\x22\x5c").indexOf(c) < 0;
    }

    private static bool uriStructuredField(string name) {
        switch (name) {
            case "warc-record-id":
            case "warc-target-uri":
            case "warc-concurrent-to":
            case "warc-refers-to":
            case "warc-refers-to-target-uri":
            case "warc-warcinfo-id":
            case "warc-profile":
            case "warc-segment-origin-id":
                return true;
            default:
                return false;
        }
    }

    private static bool uriShape(string value, bool bracketed) {
        if (bracketed) {
            if (value.length < 4 || value[0] != '<' || value[$ - 1] != '>') return false;
            value = value[1 .. $ - 1];
        }
        auto colon = value.indexOf(':');
        if (colon <= 0) return false;
        foreach (i, c; value) {
            if (c <= ' ' || c >= 127 || c == '<' || c == '>') return false;
            if (i < colon && !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                (i > 0 && ((c >= '0' && c <= '9') || c == '+' || c == '-' || c == '.'))))
                return false;
        }
        return true;
    }

    private static string trimSpace(string value) {
        size_t first, last = value.length;
        while (first < last && (value[first] == ' ' || value[first] == '\t')) ++first;
        while (last > first && (value[last - 1] == ' ' || value[last - 1] == '\t')) --last;
        return value[first .. last];
    }

    private static string asciiLower(string value) {
        char[] copy = value.dup;
        foreach (ref c; copy) if (c >= 'A' && c <= 'Z') c = cast(char)(c + 32);
        return cast(string) copy;
    }

    private static void fail(string reason) { throw new WarcError(reason); }
}

// ---------------------------------------------------------------------------
// Test suite, ported unchanged in behavior from scrubbed's
// `experiments/warc_reader/production_check.d` (the release-active
// integration check for `effects.warc_reader`, which imports nothing but
// that module). The only changes from that source are mechanical: the
// standalone `void main()` / `need`/`rejects` assertion helpers are
// restructured into `unittest {}` blocks so `dub test` runs them, and the
// final `writeln` summary (a diagnostic, not a behavioral assertion) is
// dropped. Every fixture, chunking pattern, and assertion is unchanged:
// chunk-invariant bounding (1-byte/127-byte/whole-feed/irregular chunking
// equivalence), record-type recognition (warcinfo/metadata/response/
// conversion/revisit URI-shape rules), and WARC-Record-ID handling
// (ownership, duplicate rejection, angle-bracket preservation) all still
// apply to the exact same fixtures.
version (unittest) {
    import core.memory : GC;
    import std.conv : to;
    import std.digest.sha : sha256Of, toHexString;
    import std.string : replace;

    private void need(bool condition, string reason) {
        assert(condition, reason);
    }

    private void rejects(void delegate() action, string reason) {
        bool rejected;
        try action();
        catch (WarcError) { rejected = true; }
        need(rejected, "accepted " ~ reason);
    }

    private ubyte[] record(string id, string kind, const(ubyte)[] block, string extra = "",
        string uri = "https://example.org/a", string length = "") {
        auto header = "WARC/1.1\r\nWARC-Type: " ~ kind ~
            "\r\nWARC-Record-ID: <urn:uuid:" ~ id ~ ">\r\n" ~
            (uri.length ? "WARC-Target-URI: " ~ uri ~ "\r\n" : "") ~
            "WARC-Date: 2026-09-21T00:00:00Z\r\n" ~ extra ~
            "Content-Length: " ~ (length.length ? length : block.length.to!string) ~
            "\r\n\r\n";
        return (cast(ubyte[]) header.dup ~ block ~ cast(ubyte[]) "\r\n\r\n").dup;
    }

    private string fingerprint(WarcRecord r) {
        auto value = r.sourceKey ~ "|" ~ r.ordinal.to!string ~ "|" ~ r.recordId ~ "|" ~
            r.date ~ "|" ~ r.type ~ "|" ~ r.targetUri ~ "|" ~
            toHexString(sha256Of(r.block)).idup;
        foreach (field; r.fields) value ~= "|" ~ field.name ~ ":" ~ field.value;
        return value;
    }

    private string[] decode(const(ubyte)[] bytes, size_t step) {
        string[] output;
        auto parser = new WarcReader("dataset/archive-key", (WarcRecord r) {
            output ~= fingerprint(r);
            return true;
        });
        for (size_t at; at < bytes.length; at += step) {
            auto end = at + step < bytes.length ? at + step : bytes.length;
            parser.feed(bytes[at .. end]);
        }
        parser.finish();
        return output;
    }
}

// Source-key boundary and cap handling.
unittest {
    auto boundaryKeyBytes = new char[4096];
    boundaryKeyBytes[] = 'k';
    auto boundaryKey = cast(string) boundaryKeyBytes;
    size_t keyBoundaryRecords;
    auto boundaryReader = new WarcReader(boundaryKey, (WarcRecord r) {
        need(r.sourceKey == boundaryKey, "boundary source key preserved");
        ++keyBoundaryRecords; return true;
    });
    boundaryReader.feed(record("boundary", "response", new ubyte[65536]));
    boundaryReader.finish();
    need(keyBoundaryRecords == 1, "source-key boundary rejected");
    rejects({ new WarcReader(boundaryKey ~ "x", (WarcRecord r) => true); },
        "source key one byte over cap");
    {
        auto hugeKeyBytes = new char[1024 * 1024];
        hugeKeyBytes[] = 'k';
        auto hugeKey = cast(string) hugeKeyBytes;
        GC.collect();
        GC.disable();
        scope(exit) GC.enable();
        auto beforeHugeKey = GC.stats.usedSize;
        rejects({ new WarcReader(hugeKey, (WarcRecord r) => true); },
            "one MiB source key");
        auto hugeKeyDelta = GC.stats.usedSize - beforeHugeKey;
        need(hugeKeyDelta < 8192, "oversized source key copied before rejection");
    }
}

// Chunk-invariant bounding: 1-byte, 127-byte, whole-feed, and a
// deterministic irregular chunk sequence all yield identical record
// fingerprints across a two-record, >128KiB aggregate archive.
unittest {
    auto a = record("one", "conversion", cast(const(ubyte)[]) "caf\xc3\xa9\n" ~
        new ubyte[65400], "Content-Type: text/plain\r\nX-Unknown: retained\r\n");
    auto b = record("two", "response", new ubyte[65400],
        "Content-Type: application/http\r\n");
    auto archive = a ~ b;
    need(archive.length > 131072, "aggregate fixture too small");
    auto expected = decode(archive, 1);
    need(expected.length == 2, "two records");
    need(expected == decode(archive, 127), "127-byte equivalence");
    need(expected == decode(archive, archive.length), "whole-feed equivalence");
    // Deterministic irregular chunk sequence.
    string[] irregular;
    auto parser = new WarcReader("dataset/archive-key", (WarcRecord r) {
        irregular ~= fingerprint(r); return true;
    });
    size_t at, seed = 17;
    while (at < archive.length) {
        seed = (seed * 37 + 11) % 997;
        auto n = 1 + seed;
        auto end = at + n < archive.length ? at + n : archive.length;
        parser.feed(archive[at .. end]);
        at = end;
    }
    parser.finish();
    need(expected == irregular, "irregular equivalence");
}

// Record ownership, warcinfo/metadata target-URI rules, literal "=?" in a
// query, and encoded-word-shaped bytes preserved in structured URI fields.
unittest {
    WarcRecord saved;
    auto ownership = new WarcReader("key", (WarcRecord r) { saved = r; return true; });
    auto info = record("info", "warcinfo", cast(const(ubyte)[]) "software: test",
        "X-Unknown: retained\r\n", "");
    ownership.feed(info);
    ownership.finish();
    info[] = 0;
    need(!saved.hasTargetUri && saved.fields[3].name == "X-Unknown" &&
        saved.fields[3].value == " retained" && saved.block == cast(ubyte[]) "software: test",
        "owned warcinfo and ordered extension header");
    need(decode(record("meta", "metadata", [], "", ""), 127).length == 1,
        "metadata without URI");
    need(decode(record("meta", "metadata", [], "", "https://example.org/m"), 127).length == 1,
        "metadata with URI");
    WarcRecord queryRecord;
    auto queryReader = new WarcReader("key", (WarcRecord r) {
        queryRecord = r; return true;
    });
    queryReader.feed(record("query", "response", [], "",
        "https://example.org/?q=?value"));
    queryReader.finish();
    need(queryRecord.targetUri == "https://example.org/?q=?value",
        "literal =? in target URI");
    auto encodedShapeUri = "https://example.org/?q==?utf-8?B?QQ==?=";
    WarcRecord structuredUri;
    auto uriReader = new WarcReader("key", (WarcRecord r) {
        structuredUri = r; return true;
    });
    uriReader.feed(record("uri", "revisit", [],
        "WARC-Refers-To-Target-URI: " ~ encodedShapeUri ~ "\r\n" ~
        "WARC-Profile: " ~ encodedShapeUri ~ "\r\n",
        encodedShapeUri));
    uriReader.finish();
    need(structuredUri.targetUri == encodedShapeUri &&
        structuredUri.fields[4].value == " " ~ encodedShapeUri &&
        structuredUri.fields[5].value == " " ~ encodedShapeUri,
        "encoded-word-shaped bytes in structured URI fields");
}

// Zero-length blocks, IIPC token extension field names, case-insensitive
// field names, and binary vs. WET-style conversion text classification.
unittest {
    need(decode(record("zero", "response", []), 1).length == 1,
        "zero-length block");
    WarcRecord tokenField;
    auto tokenReader = new WarcReader("key", (WarcRecord r) {
        tokenField = r; return true;
    });
    tokenReader.feed(record("token", "response", [],
        "X_Trace: caf\xc3\xa9\tvalue\r\n"));
    tokenReader.finish();
    need(tokenField.fields[4].name == "X_Trace" &&
        tokenField.fields[4].value == " caf\xc3\xa9\tvalue",
        "IIPC token extension and UTF-8/HT value");
    auto mixedCase = record("case", "response", [], "X-Mixed: value\r\n");
    auto changed = cast(string) mixedCase;
    need(decode(cast(const(ubyte)[]) changed.replace("WARC-Type", "wArC-tYpE"), 127).length == 1,
        "case-insensitive field name");

    auto binary = record("binary", "response", cast(const(ubyte)[]) [0, 255, 13, 10],
        "Content-Type: application/http\r\n");
    auto binaryReader = new WarcReader("key", (WarcRecord r) {
        need(!r.isConversionText(), "binary misclassified");
        rejects({ r.conversionText(); }, "response conversion");
        need(r.block == cast(ubyte[]) [0, 255, 13, 10], "binary bytes");
        return true;
    });
    binaryReader.feed(binary); binaryReader.finish();
    auto textReader = new WarcReader("key", (WarcRecord r) {
        need(r.isConversionText() && r.conversionText() == "caf\xc3\xa9\n", "UTF-8 view");
        return true;
    });
    textReader.feed(record("text", "conversion", cast(const(ubyte)[]) "caf\xc3\xa9\n",
        "Content-Type: text/plain\r\n")); textReader.finish();
}

// Rejection surface: empties, truncation, malformed/overflowing lengths,
// duplicate/missing required fields, corrupt terminators, control
// characters, folded fields, invalid UTF-8, encoded-word fields,
// segmentation, and header/field caps.
unittest {
    auto a = record("one", "conversion", cast(const(ubyte)[]) "caf\xc3\xa9\n" ~
        new ubyte[65400], "Content-Type: text/plain\r\nX-Unknown: retained\r\n");
    rejects({ auto p = new WarcReader("k", (WarcRecord r) => true); p.finish(); }, "empty");
    rejects({ auto p = new WarcReader("k", (WarcRecord r) => true);
        p.feed(a[0 .. $ - 1]); p.finish(); }, "truncated");
    rejects({ auto p = new WarcReader("k", (WarcRecord r) => true);
        auto bad = record("bad", "response", [], "", "https://example.org", "65537");
        p.feed(bad); }, "oversized block");
    rejects({ auto p = new WarcReader("k", (WarcRecord r) => true);
        p.feed(record("bad", "response", [], "", "https://example.org", "999999999999999999999999"));
        }, "overflow length");
    rejects({ auto p = new WarcReader("k", (WarcRecord r) => true);
        p.feed(record("bad", "response", [], "", "https://example.org", "x"));
        }, "nondigit length");
    rejects({ auto p = new WarcReader("k", (WarcRecord r) => true);
        p.feed(record("bad", "response", [], "WARC-Date: duplicate\r\n"));
        }, "duplicate required field");
    rejects({ auto p = new WarcReader("k", (WarcRecord r) => true);
        auto bad = record("bad", "response", []);
        bad[$ - 1] = 'X'; p.feed(bad);
        }, "corrupt terminator");
    rejects({ auto p = new WarcReader("k", (WarcRecord r) => true);
        auto bad = record("bad", "response", []);
        auto text = (cast(string) bad).replace("WARC-Date: 2026-09-21T00:00:00Z\r\n", "");
        p.feed(cast(const(ubyte)[]) text);
        }, "missing date");
    rejects({ auto p = new WarcReader("k", (WarcRecord r) => true);
        p.feed(record("bad", "warcinfo", [], "", "https://example.org"));
        }, "warcinfo URI");
    rejects({ auto p = new WarcReader("k", (WarcRecord r) => true);
        p.feed(record("bad", "conversion", cast(const(ubyte)[]) [255],
            "Content-Type: text/plain\r\n")); }, "invalid UTF-8");
    rejects({ auto p = new WarcReader("k", (WarcRecord r) => true);
        p.feed(record("bad", "response", [], " X: fold\r\n")); }, "folded field");
    rejects({ auto p = new WarcReader("k", (WarcRecord r) => true);
        p.feed(record("bad", "response", [], "X-Test: a\0b\r\n"));
        }, "NUL header value");
    rejects({ auto p = new WarcReader("k", (WarcRecord r) => true);
        p.feed(record("bad", "response", [], "X-Test: a\x7fb\r\n"));
        }, "DEL header value");
    rejects({ auto p = new WarcReader("k", (WarcRecord r) => true);
        p.feed(record("bad", "response", [], "X@Trace: value\r\n"));
        }, "separator in field name");
    rejects({ auto p = new WarcReader("k", (WarcRecord r) => true);
        p.feed(record("bad", "response", [], "X-Test: =?utf-8?B?QQ==?=\r\n"));
        }, "encoded word");
    need(decode(record("literal", "response", [], "X-Test: =?value\r\n"), 127).length == 1,
        "literal encoded-word prefix in extension value");
    rejects({ auto p = new WarcReader("k", (WarcRecord r) => true);
        p.feed(record("bad", "response", [], "WARC-Segment-Number: 1\r\n"));
        }, "segmentation");
    rejects({ auto p = new WarcReader("k", (WarcRecord r) => true);
        p.feed(cast(const(ubyte)[]) ("WARC/1.1\r\nX: " ~ new char[4096]));
        }, "header cap");
    string manyFields;
    foreach (_; 0 .. 129) manyFields ~= "X: a\r\n";
    rejects({ auto p = new WarcReader("k", (WarcRecord r) => true);
        p.feed(record("bad", "response", [], manyFields));
        }, "header field cap");
}

// Late truncation after a good record, reentrancy denial from within a
// callback, cancellation, and callback-exception propagation/poisoning.
unittest {
    size_t earlier;
    auto late = new WarcReader("k", (WarcRecord r) { ++earlier; return true; });
    late.feed(record("good", "response", []));
    rejects({ late.feed(record("bad", "response", [cast(ubyte) 1])[0 .. $ - 2]);
        late.finish(); }, "late truncation");
    need(earlier == 1 && late.completedRecords == 1, "late failure emitted failed record");
    WarcReader reentrant;
    size_t[] ordinals;
    size_t deniedCalls;
    bool attemptedReentry;
    reentrant = new WarcReader("k", (WarcRecord r) {
        ordinals ~= r.ordinal;
        if (!attemptedReentry) {
            attemptedReentry = true;
            rejects({ reentrant.feed(record("nested", "response", [])); },
                "reentrant feed");
            rejects({ reentrant.finish(); }, "reentrant finish");
            deniedCalls += 2;
        }
        return true;
    });
    reentrant.feed(record("first", "response", []) ~
        record("second", "response", []));
    reentrant.finish();
    need(ordinals == [1, 2] && deniedCalls == 2 &&
        reentrant.completedRecords == 2, "reentrant calls changed emission state");
    auto cancelled = new WarcReader("k", (WarcRecord r) { return false; });
    rejects({ cancelled.feed(record("cancel", "response", [])); }, "callback cancellation");
    rejects({ cancelled.feed(record("again", "response", [])); }, "cancelled reader reuse");
    bool thrown;
    auto callback = new WarcReader("k", (WarcRecord r) { throw new Exception("callback"); return true; });
    try callback.feed(record("throw", "response", []));
    catch (Exception e) { thrown = e.msg == "callback"; }
    need(thrown, "callback exception propagation");
    rejects({ callback.finish(); }, "thrown reader reuse");
}

// Conversion-text validation does not allocate a second full-block copy;
// an explicit `conversionText()` call does allocate its own independent copy.
unittest {
    auto largeText = record("large-text", "conversion", new ubyte[65536],
        "Content-Type: text/plain\r\n");
    size_t validationAllocation;
    GC.collect();
    GC.disable();
    scope(exit) GC.enable();
    auto beforeValidation = GC.stats.usedSize;
    auto bounded = new WarcReader("key", (WarcRecord r) {
        validationAllocation = GC.stats.usedSize - beforeValidation;
        auto explicitCopy = r.conversionText();
        need(explicitCopy.length == 65536 &&
            cast(const(void)*) explicitCopy.ptr != cast(const(void)*) r.block.ptr,
            "explicit conversion text copy");
        return true;
    });
    bounded.feed(largeText); bounded.finish();
    need(validationAllocation < 131072,
        "implicit conversion validation allocated a second full block");
}
