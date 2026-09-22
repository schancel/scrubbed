/// Deterministic, bounded evidence from the selected HTML tree.
module effects.html_metadata;

import domain.document : DocumentId;
import effects.html_tree : HtmlNode, HtmlNodeKind, HtmlTree;
import std.conv : to;
import std.json : JSONValue;
import std.string : indexOf;
import std.uni : isWhite;
import std.utf : byDchar, toUTF8;

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

private string normalized(string input) {
    string result;
    bool pending;
    foreach (ch; input.byDchar) {
        if (isWhite(ch)) { if (result.length) pending = true; }
        else {
            if (pending) result ~= " ";
            result ~= toUTF8([ch]);
            pending = false;
            if (result.length > maxMetadataValueBytes) return null;
        }
    }
    return result;
}

private string attribute(const ref HtmlNode node, string name) {
    foreach (a; node.attributes) if (a.name == name) return a.value;
    return null;
}

private bool validDate(string value) {
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

private bool validUrl(string value) {
    size_t start;
    if (value.length > 8 && value[0 .. 8] == "https://") start = 8;
    else if (value.length > 7 && value[0 .. 7] == "http://") start = 7;
    else return false;
    size_t end = start;
    while (end < value.length && value[end] != '/' && value[end] != '?' && value[end] != '#') ++end;
    if (end == start || value[start .. end].indexOf('@') >= 0) return false;
    foreach (c; value) if (cast(ubyte)c <= 0x20 || c == '\\' || c == '"') return false;
    return true;
}

private void offer(ref MetadataField field, string raw, string rule,
    size_t node, int priority, bool isDate = false, bool isUrl = false) {
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

private void decide(ref MetadataField field) {
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
HtmlMetadata extractHtmlMetadata(const ref HtmlTree tree) {
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
            auto key = attribute(node, "property");
            if (!key.length) key = attribute(node, "name");
            auto content = attribute(node, "content");
            switch (key) {
            case "og:title": offer(result.title, content, key, i, 0); break;
            case "author": offer(result.author, content, key, i, 0); break;
            case "article:author": offer(result.author, content, key, i, 1); break;
            case "article:published_time": offer(result.date, content, key, i, 0, true); break;
            case "date": offer(result.date, content, key, i, 1, true); break;
            case "og:url": offer(result.url, content, key, i, 1, false, true); break;
            default: break;
            }
        }
    }
    decide(result.title); decide(result.author); decide(result.date); decide(result.url);
    return result;
}

private string quote(string value) { return JSONValue(value).toString; }

private string fieldJson(const ref MetadataField field) {
    string encoded = `{"status":` ~ quote(field.status) ~ `,"value":`;
    encoded ~= field.status == "selected" ? quote(field.value) : "null";
    encoded ~= `,"rule":` ~ (field.status == "selected" ? quote(field.rule) : "null");
    encoded ~= `,"node":` ~ (field.status == "selected" ? field.node.to!string : "null");
    encoded ~= `,"conflict":` ~ (field.conflict ? "true" : "false") ~
        `,"invalidEvidence":` ~ (field.invalidEvidence ? "true" : "false") ~
        `,"overflow":` ~ (field.overflow ? "true" : "false") ~ `,"candidates":[`;
    foreach (i, candidate; field.candidates) {
        if (i) encoded ~= ",";
        encoded ~= `{"value":` ~ quote(candidate.value) ~ `,"rule":` ~ quote(candidate.rule) ~
            `,"node":` ~ candidate.node.to!string ~ `}`;
    }
    return encoded ~ "]}";
}

class HtmlMetadataOutputLimit : Exception {
    this() { super("metadata output limit"); }
}

/// Fixed key order and one LF are metadata-json:v1's canonical wire.
string serializeHtmlMetadata(DocumentId id, const HtmlMetadata metadata) {
    auto encoded = `{"version":"metadata-json:v1","documentId":` ~ quote(id.text) ~
        `,"fields":{"title":` ~ fieldJson(metadata.title) ~
        `,"author":` ~ fieldJson(metadata.author) ~
        `,"date":` ~ fieldJson(metadata.date) ~
        `,"url":` ~ fieldJson(metadata.url) ~ "}}\n";
    if (encoded.length > maxMetadataJsonBytes) throw new HtmlMetadataOutputLimit;
    return encoded;
}
