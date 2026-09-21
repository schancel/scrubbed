/// Incremental, uncompressed WARC/1.1 record reader. See docs/warc-reader.md.
module effects.warc_reader;

import std.string : indexOf, split;
import std.utf : validate;

enum size_t warcHeaderLimit = 4096;
enum size_t warcBlockLimit = 65536;
enum size_t warcRecordLimit = 131072;

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
        auto value = cast(string) block;
        try validate(value);
        catch (Exception) { throw new WarcError("invalid UTF-8 conversion"); }
        return value.idup;
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
    private string key;
    private WarcVisit visit;

    this(string sourceKey, WarcVisit onRecord) {
        if (sourceKey.length == 0 || onRecord is null)
            throw new WarcError("source key and callback required");
        try validate(sourceKey);
        catch (Exception) { throw new WarcError("invalid UTF-8 source key"); }
        foreach (c; sourceKey)
            if (c == 0) throw new WarcError("NUL source key");
        key = sourceKey.idup;
        visit = onRecord;
    }

    size_t completedRecords() const { return completed; }

    void feed(const(ubyte)[] bytes) {
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
        if (stopped) throw new WarcError("reader stopped");
        if (phase != Phase.header || header.length != 0 || completed == 0) {
            stopped = true;
            throw new WarcError(completed == 0 && header.length == 0 ?
                "empty archive" : "truncated record");
        }
        stopped = true;
    }

    private void emit() {
        if (current.isConversionText()) current.conversionText();
        auto record = current;
        current = WarcRecord.init;
        header = null;
        separatorAt = 0;
        phase = Phase.header;
        if (!visit(record)) fail("callback cancelled");
        ++completed;
    }

    private void parseHeader() {
        if (header.length + 4 > warcRecordLimit) fail("record cap");
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
                if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                    (c >= '0' && c <= '9') || c == '-')) fail("invalid field name");
            auto raw = line[colon + 1 .. $];
            if (raw.indexOf('\r') >= 0 || raw.indexOf('\n') >= 0)
                fail("invalid field line ending");
            auto value = trimSpace(raw);
            if (value.indexOf("=?") >= 0) fail("encoded-word fields unsupported");
            try validate(value);
            catch (Exception) { fail("invalid UTF-8 header value"); }
            auto lower = asciiLower(name);
            // Own strings: no emitted field aliases the mutable header buffer.
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
        if (header.length + declared + 4 > warcRecordLimit) fail("record cap");
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
