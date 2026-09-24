/// Deterministic, bounded evidence from the selected HTML tree.
module effects.html_metadata;

import domain.document : DocumentId;
import effects.html_tree : HtmlNode, HtmlNodeKind, HtmlTree;
import std.conv : to;
import std.json : JSONValue;
import std.string : indexOf;
import std.uni : isWhite;
import std.utf : decode, replacementDchar, UseReplacementDchar;

enum size_t maxMetadataCandidates = 16;
enum size_t maxMetadataValueBytes = 512;
enum size_t maxMetadataJsonBytes = 32 * 1024;

struct MetadataCandidate {
    string value;
    string rule;
    size_t node;
    int priority;
}

struct MetadataField {
    string status; // selected, absent, invalid, ambiguous
    string value;
    string rule;
    size_t node;
    bool conflict;
    bool invalidEvidence;
    bool overflow;
    MetadataCandidate[] candidates;
}

struct HtmlMetadata {
    MetadataField title, author, date, url;
}

private string normalized(string input) pure {
    string result;
    size_t outputLength, runStart;
    bool whitespace;
    size_t at;
    while (at < input.length) {
        auto start = at;
        auto ch = decode!(UseReplacementDchar.yes)(input, at);
        if (isWhite(ch)) {
            if (!whitespace && runStart < start) result ~= input[runStart .. start];
            whitespace = true;
            continue;
        }
        if (whitespace) {
            if (outputLength) {
                ++outputLength;
                if (outputLength <= maxMetadataValueBytes) result ~= " ";
            }
            whitespace = false;
            runStart = start;
        }
        auto width = ch <= 0x7f ? 1 : ch <= 0x7ff ? 2 : ch <= 0xffff ? 3 : 4;
        outputLength += width;
        if (outputLength > maxMetadataValueBytes) return null;
        if (ch == replacementDchar && input[start .. at] != "�") {
            if (runStart < start) result ~= input[runStart .. start];
            result ~= "�";
            runStart = at;
        }
    }
    if (!whitespace && runStart < input.length) result ~= input[runStart .. $];
    return result;
}

unittest {
    import std.array : replicate;

    assert(normalized("") is null);
    assert(normalized(" \t\r\n\f") is null);
    assert(normalized("  alpha \t β\n gamma  ") == "alpha β gamma");
    auto exact = replicate("a", maxMetadataValueBytes);
    assert(normalized(exact) == exact);
    assert(normalized(exact ~ "b") is null);
    auto spacedExact = replicate("a", maxMetadataValueBytes - 2) ~ " b";
    assert(normalized(spacedExact) == spacedExact);
    assert(normalized(replicate("a", maxMetadataValueBytes - 1) ~ " b") is null);
    auto utf8Exact = replicate("a", maxMetadataValueBytes - 2) ~ "é";
    assert(normalized(utf8Exact) == utf8Exact);
    auto malformed = cast(string) [cast(char) 0xff];
    assert(normalized(malformed) == "�");
    assert(normalized("a" ~ malformed ~ " b") == "a�b");
    assert(normalized(replicate("a", maxMetadataValueBytes - 3) ~ malformed) ==
        replicate("a", maxMetadataValueBytes - 3) ~ "�");
    assert(normalized(replicate("a", maxMetadataValueBytes - 2) ~ malformed) is null);
}

private string attribute(const ref HtmlNode node, string name) pure {
    foreach (a; node.attributes) if (a.name == name) return a.value;
    return null;
}

private bool validDate(string value) pure {
    if (value.length < 10 || (value.length != 10 &&
        (value.length < 20 || value[10] != 'T')) ||
        value[4] != '-' || value[7] != '-') return false;
    foreach (i; [0, 1, 2, 3, 5, 6, 8, 9])
        if (value[i] < '0' || value[i] > '9') return false;
    auto year = to!int(value[0 .. 4]);
    auto month = to!int(value[5 .. 7]);
    auto day = to!int(value[8 .. 10]);
    if (year == 0 || month < 1 || month > 12) return false;
    int[] days = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    if (month == 2 && year % 4 == 0 && (year % 100 != 0 || year % 400 == 0))
        days[1] = 29;
    if (day < 1 || day > days[month - 1]) return false;
    if (value.length > 10) {
        foreach (i; [11, 12, 14, 15, 17, 18])
            if (value[i] < '0' || value[i] > '9') return false;
        if (value[13] != ':' || value[16] != ':' ||
            to!int(value[11 .. 13]) > 23 || to!int(value[14 .. 16]) > 59 ||
            to!int(value[17 .. 19]) > 59) return false;
        if (value.length == 20) return value[19] == 'Z';
        if (value.length != 25 || (value[19] != '+' && value[19] != '-') ||
            value[22] != ':') return false;
        foreach (i; [20, 21, 23, 24])
            if (value[i] < '0' || value[i] > '9') return false;
        return to!int(value[20 .. 22]) <= 23 && to!int(value[23 .. 25]) <= 59;
    }
    return true;
}

private bool validUrl(string value) pure {
    size_t start;
    if (value.length > 8 && value[0 .. 8] == "https://") start = 8;
    else if (value.length > 7 && value[0 .. 7] == "http://") start = 7;
    else return false;
    size_t end = start;
    while (end < value.length && value[end] != '/' && value[end] != '?' && value[end] != '#') ++end;
    if (end == start) return false;
    auto authority = value[start .. end];
    if (authority.indexOf('@') >= 0) return false;
    // IP-literal validation is deliberately out of scope for this slice.
    if (authority.indexOf('[') >= 0 || authority.indexOf(']') >= 0) return false;
    auto colon = authority.indexOf(':');
    auto host = colon < 0 ? authority : authority[0 .. colon];
    auto port = colon < 0 ? "" : authority[colon + 1 .. $];
    foreach (c; host) if (!((c >= '0' && c <= '9') ||
        (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
        c == '.' || c == '-')) return false;
    if (!host.length) return false;
    if (authority[$ - 1] == ':') return false;
    if (port.length) {
        if (port.length > 5) return false;
        foreach (c; port) if (c < '0' || c > '9') return false;
        auto number = to!int(port);
        if (number < 1 || number > 65535) return false;
    }
    foreach (c; value) if (cast(ubyte)c <= 0x20 || c == '\\' || c == '"') return false;
    return true;
}

private void offer(ref MetadataField field, string raw, string rule,
    size_t node, int priority, bool isDate = false, bool isUrl = false) pure {
    auto value = normalized(raw);
    if (value.length == 0 || (isDate && !validDate(value)) ||
        (isUrl && !validUrl(value))) {
        if (raw.length) field.invalidEvidence = true;
        return;
    }
    if (isDate) value = value[0 .. 10];
    if (field.candidates.length < maxMetadataCandidates)
        field.candidates ~= MetadataCandidate(value, rule, node, priority);
    else field.overflow = true;
}

private void decide(ref MetadataField field) pure {
    if (!field.candidates.length) {
        field.status = field.invalidEvidence ? "invalid" : "absent";
        return;
    }
    if (field.overflow) { field.status = "overflow"; return; }
    int best = int.max;
    foreach (candidate; field.candidates) if (candidate.priority < best) best = candidate.priority;
    string winner;
    bool tie;
    foreach (candidate; field.candidates) if (candidate.priority == best) {
        if (winner.length == 0) winner = candidate.value;
        else if (winner != candidate.value) tie = true;
    }
    field.conflict = tie;
    foreach (candidate; field.candidates) if (candidate.value != winner) field.conflict = true;
    if (tie) { field.status = "ambiguous"; return; }
    field.status = "selected";
    foreach (candidate; field.candidates) if (candidate.priority == best) {
        field.value = candidate.value;
        field.rule = candidate.rule;
        field.node = candidate.node;
        break;
    }
}

/// Only head evidence is eligible. Node ordinals refer to HtmlTree pre-order.
HtmlMetadata extractHtmlMetadata(const ref HtmlTree tree) pure {
    HtmlMetadata result;
    size_t head = size_t.max;
    foreach (i, node; tree.nodes) if (node.kind == HtmlNodeKind.element && node.name == "head") {
        head = i;
        break;
    }
    if (head != size_t.max) foreach (i, node; tree.nodes) {
        bool inHead = i == head;
        for (size_t parent = node.parentIndex; !inHead && parent != size_t.max;
             parent = tree.nodes[parent].parentIndex) inHead = parent == head;
        if (!inHead || node.kind != HtmlNodeKind.element) continue;
        if (node.name == "title") {
            string title;
            foreach (child; tree.nodes) if (child.parentIndex == i && child.kind == HtmlNodeKind.text)
                title ~= child.text;
            offer(result.title, title, "title", i, 1);
        } else if (node.name == "link" && attribute(node, "rel") == "canonical") {
            offer(result.url, attribute(node, "href"), "link:canonical", i, 0, false, true);
        } else if (node.name == "meta") {
            auto property = attribute(node, "property");
            auto name = attribute(node, "name");
            auto content = attribute(node, "content");
            if (property == "og:title") offer(result.title, content, "og:title", i, 0);
            if (name == "author") offer(result.author, content, "author", i, 0);
            if (property == "article:author")
                offer(result.author, content, "article:author", i, 1);
            if (property == "article:published_time")
                offer(result.date, content, "article:published_time", i, 0, true);
            if (name == "date") offer(result.date, content, "date", i, 1, true);
            if (property == "og:url")
                offer(result.url, content, "og:url", i, 1, false, true);
        }
    }
    decide(result.title); decide(result.author); decide(result.date); decide(result.url);
    return result;
}

class HtmlMetadataOutputLimit : Exception {
    this() pure { super("metadata output limit"); }
}

private struct Writer {
    char[] bytes;

    void put(scope const(char)[] value) pure {
        if (value.length > maxMetadataJsonBytes - bytes.length)
            throw new HtmlMetadataOutputLimit;
        bytes ~= value;
    }

    void quoted(string value) pure {
        enum hex = "0123456789abcdef";
        put("\"");
        size_t runStart;
        foreach (i, c; value) {
            if (cast(ubyte)c >= 0x20 && c != '"' && c != '\\') continue;
            if (runStart < i) put(value[runStart .. i]);
            switch (c) {
                case '"': put(`\"`); break;
                case '\\': put(`\\`); break;
                case '\b': put(`\b`); break;
                case '\f': put(`\f`); break;
                case '\n': put(`\n`); break;
                case '\r': put(`\r`); break;
                case '\t': put(`\t`); break;
                default:
                    auto byteValue = cast(ubyte)c;
                    char[6] escaped = ['\\', 'u', '0', '0',
                        hex[byteValue >> 4], hex[byteValue & 0xf]];
                    put(escaped[]);
            }
            runStart = i + 1;
        }
        if (runStart < value.length) put(value[runStart .. $]);
        put("\"");
    }
}

unittest {
    Writer writer;
    writer.quoted("");
    assert(writer.bytes == `""`);
    writer.bytes.length = 0;
    writer.quoted("plain/é");
    assert(writer.bytes == `"plain/é"`);
    writer.bytes.length = 0;
    writer.quoted("\"\\\b\f\n\r\t\0\x1f");
    assert(writer.bytes == `"\"\\\b\f\n\r\t\u0000\u001f"`);
}

private void putField(ref Writer writer, const ref MetadataField field) pure {
    writer.put(`{"status":`);
    writer.quoted(field.status);
    writer.put(`,"value":`);
    if (field.status == "selected") writer.quoted(field.value);
    else writer.put("null");
    writer.put(`,"rule":`);
    if (field.status == "selected") writer.quoted(field.rule);
    else writer.put("null");
    writer.put(`,"node":`);
    writer.put(field.status == "selected" ? field.node.to!string : "null");
    writer.put(`,"conflict":`);
    writer.put(field.conflict ? "true" : "false");
    writer.put(`,"invalidEvidence":`);
    writer.put(field.invalidEvidence ? "true" : "false");
    writer.put(`,"overflow":`);
    writer.put(field.overflow ? "true" : "false");
    writer.put(`,"candidates":[`);
    foreach (i, candidate; field.candidates) {
        if (i) writer.put(",");
        writer.put(`{"value":`);
        writer.quoted(candidate.value);
        writer.put(`,"rule":`);
        writer.quoted(candidate.rule);
        writer.put(`,"node":`);
        writer.put(candidate.node.to!string);
        writer.put("}");
    }
    writer.put("]}");
}

/// Fixed key order and one LF are metadata-json:v1's canonical wire.
string serializeHtmlMetadata(DocumentId id, const HtmlMetadata metadata) pure {
    Writer writer;
    writer.put(`{"version":"metadata-json:v1","documentId":`);
    writer.quoted(id.text);
    writer.put(`,"fields":{"title":`);
    writer.putField(metadata.title);
    writer.put(`,"author":`);
    writer.putField(metadata.author);
    writer.put(`,"date":`);
    writer.putField(metadata.date);
    writer.put(`,"url":`);
    writer.putField(metadata.url);
    writer.put("}}\n");
    return writer.bytes.idup;
}
