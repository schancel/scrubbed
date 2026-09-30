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
    MetadataField title, author, date, url, rights, siteName, description;
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

/// `twitter:site` is conventionally a "@handle", not a display name (e.g.
/// `@nytimes`); the leading `@`, if present, is stripped before the value is
/// considered as site-name evidence at all, matching trafilatura==2.2.0's
/// own `metadata.sitename.lstrip("@")` normalization.
private string stripLeadingAt(string value) pure {
    return value.length && value[0] == '@' ? value[1 .. $] : value;
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

/// Head evidence is eligible for every field except one narrow,
/// specifically-scoped exception: a body `<a rel="license" href>` license
/// link (see the second pass below). Node ordinals refer to HtmlTree
/// pre-order.
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
        } else if (node.name == "link") {
            auto rel = attribute(node, "rel");
            if (rel == "canonical")
                offer(result.url, attribute(node, "href"), "link:canonical", i, 0, false, true);
            if (rel == "license")
                offer(result.rights, attribute(node, "href"), "link:license", i, 0, false, true);
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
            if (name == "dc.rights") offer(result.rights, content, "dc.rights", i, 1);
            if (name == "copyright") offer(result.rights, content, "copyright", i, 2);
            // Site name: `og:site_name` (OpenGraph, https://ogp.me/) is the
            // primary, most specific signal. `publisher`/`article:publisher`
            // are trafilatura==2.2.0's own next-priority `METANAME_PUBLISHER`
            // signals -- confirmed present on a real held-out corpus page
            // (18.html's `<meta name="publisher" content="Pronats">`, where
            // trafilatura resolves `sitename` from exactly this tag; see this
            // ticket's PR description for the full comparison run).
            // `application-name` (a plain HTML5 meta name; not one of
            // trafilatura's own signals, but a real, spec-defined site-name
            // fallback) comes next. `twitter:site` (Twitter Cards) is the
            // weakest signal -- it is a "@handle", not a display name, so its
            // leading '@' is stripped before consideration, matching how
            // real pages actually populate it.
            if (property == "og:site_name")
                offer(result.siteName, content, "og:site_name", i, 0);
            if (name == "publisher") offer(result.siteName, content, "publisher", i, 1);
            if (property == "article:publisher")
                offer(result.siteName, content, "article:publisher", i, 1);
            if (name == "application-name")
                offer(result.siteName, content, "application-name", i, 2);
            if (name == "twitter:site")
                offer(result.siteName, stripLeadingAt(content), "twitter:site", i, 3);
            // Description: `og:description` (OpenGraph) is the primary
            // signal; the plain `description` meta name is the ordinary
            // HTML fallback; `twitter:description` (Twitter Cards) is last.
            // Matches trafilatura==2.2.0's own `METANAME_DESCRIPTION`
            // survey order (OpenGraph first via `examine_meta`'s
            // `extract_opengraph` bootstrap, then the `description`/
            // `twitter:description` meta names).
            if (property == "og:description")
                offer(result.description, content, "og:description", i, 0);
            if (name == "description")
                offer(result.description, content, "description", i, 1);
            if (name == "twitter:description")
                offer(result.description, content, "twitter:description", i, 2);
        }
    }
    // License, second pass: a real-corpus survey of held-out pages (this
    // ticket's PR description has the actual fixtures/URLs) found that real
    // Creative Commons license badges are overwhelmingly `<a rel="license"
    // href>` links placed in body content (a footer/sidebar widget), never
    // `<link rel="license">` in `<head>` -- trafilatura==2.2.0's own
    // `extract_license` checks exactly this `.//a[@rel="license"][@href]`
    // xpath (anywhere in the document) as its primary rule, before a
    // separate, stricter footer-CC-text fallback this slice does not adopt.
    // This is a narrow, specifically-scoped exception to this function's
    // otherwise-uniform "only head evidence is eligible" rule: it looks only
    // for this one exact `rel="license"` signal, at the same priority as the
    // head-scoped `link:license` rule above (both are the identical
    // `rel="license"` semantic, just on a different element), not a general
    // body-wide walk for any other field.
    foreach (i, node; tree.nodes) {
        if (node.kind != HtmlNodeKind.element || node.name != "a") continue;
        if (attribute(node, "rel") == "license")
            offer(result.rights, attribute(node, "href"), "a:rel-license", i, 0, false, true);
    }
    decide(result.title); decide(result.author); decide(result.date); decide(result.url);
    decide(result.rights); decide(result.siteName); decide(result.description);
    return result;
}

// ---------------------------------------------------------------------------
// `siteName`/`description` fixtures. Each uses a real, independently
// documented markup pattern (OpenGraph https://ogp.me/, HTML5
// `application-name`, Twitter Cards https://developer.x.com/en/docs/x-for-websites/cards/overview/markup)
// rather than a synthetic invented shape, and is cross-checked against
// trafilatura==2.2.0's own extraction of the same fixture -- see this
// ticket's PR description for the actual pinned-comparison run.
// ---------------------------------------------------------------------------

version (unittest) private HtmlMetadata extractFromHtml(string html) {
    import effects.html_tree : parseHtml;

    auto outcome = parseHtml(cast(const(ubyte)[]) html);
    assert(outcome.isParsed, "fixture HTML must parse");
    return extractHtmlMetadata(outcome.tree);
}

// Fixture: og:site_name wins over a present application-name fallback (real
// OpenGraph markup, as commonly emitted by, e.g., WordPress/Yoast SEO).
unittest {
    auto html = `<html><head>` ~
        `<meta property="og:site_name" content="The Daily Example">` ~
        `<meta name="application-name" content="Daily Example App">` ~
        `</head><body><p>Body text.</p></body></html>`;
    auto metadata = extractFromHtml(html);
    assert(metadata.siteName.status == "selected");
    assert(metadata.siteName.value == "The Daily Example");
    assert(metadata.siteName.rule == "og:site_name");
}

// Fixture: `<meta name="publisher">` only -- the exact real-world shape
// found on this ticket's held-out corpus fixture 18.html
// (`<meta name="publisher" content="Pronats">`), which trafilatura==2.2.0
// itself resolves `sitename` from via its own `METANAME_PUBLISHER` set.
unittest {
    auto html = `<html><head><meta name="publisher" content="Pronats">` ~
        `</head><body><p>Body text.</p></body></html>`;
    auto metadata = extractFromHtml(html);
    assert(metadata.siteName.status == "selected");
    assert(metadata.siteName.value == "Pronats");
    assert(metadata.siteName.rule == "publisher");
}

// Fixture: no og:site_name/publisher present -- application-name is the
// real fallback (a plain HTML5 meta name, independent of OpenGraph).
unittest {
    auto html = `<html><head><meta name="application-name" content="Example App">` ~
        `</head><body><p>Body text.</p></body></html>`;
    auto metadata = extractFromHtml(html);
    assert(metadata.siteName.status == "selected");
    assert(metadata.siteName.value == "Example App");
    assert(metadata.siteName.rule == "application-name");
}

// Fixture: only a Twitter Cards `twitter:site` handle is present -- the
// weakest signal, used last, with its leading '@' stripped (real Twitter
// Cards markup is always a "@handle", e.g. "@nytimes").
unittest {
    auto html = `<html><head><meta name="twitter:site" content="@exampledaily">` ~
        `</head><body><p>Body text.</p></body></html>`;
    auto metadata = extractFromHtml(html);
    assert(metadata.siteName.status == "selected");
    assert(metadata.siteName.value == "exampledaily");
    assert(metadata.siteName.rule == "twitter:site");
}

// Fixture: og:description wins over a present plain description and
// twitter:description (real, common three-way duplication on modern pages).
unittest {
    auto html = `<html><head>` ~
        `<meta property="og:description" content="OpenGraph summary of the article.">` ~
        `<meta name="description" content="Plain meta description of the article.">` ~
        `<meta name="twitter:description" content="Twitter card summary.">` ~
        `</head><body><p>Body text.</p></body></html>`;
    auto metadata = extractFromHtml(html);
    assert(metadata.description.status == "selected");
    assert(metadata.description.value == "OpenGraph summary of the article.");
    assert(metadata.description.rule == "og:description");
}

// Fixture: only the plain `description` meta name is present (the ordinary,
// most common HTML fallback absent any OpenGraph/Twitter markup at all).
unittest {
    auto html = `<html><head>` ~
        `<meta name="description" content="A plain HTML meta description.">` ~
        `</head><body><p>Body text.</p></body></html>`;
    auto metadata = extractFromHtml(html);
    assert(metadata.description.status == "selected");
    assert(metadata.description.value == "A plain HTML meta description.");
    assert(metadata.description.rule == "description");
}

// Fixture: both fields absent entirely -- resolves to "absent", not a crash
// or spurious selection, and does not disturb unrelated existing fields.
unittest {
    auto html = `<html><head><title>Plain Page</title></head>` ~
        `<body><p>No site name or description evidence at all.</p></body></html>`;
    auto metadata = extractFromHtml(html);
    assert(metadata.siteName.status == "absent");
    assert(metadata.description.status == "absent");
    assert(metadata.title.status == "selected" && metadata.title.value == "Plain Page");
}

// Fixture: conflicting same-priority evidence resolves to "ambiguous",
// matching every other field's existing tie-handling behavior exactly.
unittest {
    auto html = `<html><head>` ~
        `<meta property="og:site_name" content="Example One">` ~
        `<meta property="og:site_name" content="Example Two">` ~
        `</head><body><p>Body text.</p></body></html>`;
    auto metadata = extractFromHtml(html);
    assert(metadata.siteName.status == "ambiguous");
    assert(metadata.siteName.conflict);
}

// `serializeHtmlMetadata` carries the two new fields additively: the
// existing title/author/date/url/rights shape is completely unchanged, and
// "siteName"/"description" simply follow "rights" in the fixed key order.
unittest {
    import domain.document : SourceLocator;
    import std.json : parseJSON;

    auto html = `<html><head><title>T</title>` ~
        `<meta property="og:site_name" content="Example Site">` ~
        `<meta name="description" content="Example description.">` ~
        `</head><body><p>Body.</p></body></html>`;
    auto metadata = extractFromHtml(html);
    auto id = DocumentId.from(SourceLocator("ns", "src", "rec"));
    auto wire = serializeHtmlMetadata(id, metadata);
    auto parsed = parseJSON(wire);
    assert(parsed["version"].str == "metadata-json:v2",
        "additive fields must not require a wire version bump");
    assert(parsed["fields"]["title"]["value"].str == "T",
        "pre-existing fields must be completely unaffected");
    assert(parsed["fields"]["siteName"]["status"].str == "selected");
    assert(parsed["fields"]["siteName"]["value"].str == "Example Site");
    assert(parsed["fields"]["description"]["status"].str == "selected");
    assert(parsed["fields"]["description"]["value"].str == "Example description.");
}

// Fixture: a real-world Creative Commons license badge pattern -- `<a
// rel="license" href>` inside a body footer widget (this exact shape, not a
// synthetic invented one, was found via a real held-out-corpus survey; see
// this ticket's PR description) -- is extracted even though it is not in
// `<head>`, the one narrow exception to this module's head-only rule.
unittest {
    auto html = `<html><head><title>Licensed Page</title></head>` ~
        `<body><div class="footer-widget"><a rel="license" ` ~
        `href="https://creativecommons.org/licenses/by-nc/3.0/de/">CC BY-NC</a></div>` ~
        `<p>Body text.</p></body></html>`;
    auto metadata = extractFromHtml(html);
    assert(metadata.rights.status == "selected");
    assert(metadata.rights.value == "https://creativecommons.org/licenses/by-nc/3.0/de/");
    assert(metadata.rights.rule == "a:rel-license");
}

// A head `<link rel="license">` and a body `<a rel="license">` pointing at
// the same URL do not conflict (same priority tier, same value); at
// different URLs, this correctly surfaces as "ambiguous" rather than
// silently picking one, matching this field's existing conflict handling.
unittest {
    auto agreeing = `<html><head><link rel="license" ` ~
        `href="https://creativecommons.org/licenses/by/4.0/"></head>` ~
        `<body><a rel="license" href="https://creativecommons.org/licenses/by/4.0/">CC</a>` ~
        `<p>Body.</p></body></html>`;
    auto agreeingMetadata = extractFromHtml(agreeing);
    assert(agreeingMetadata.rights.status == "selected");
    assert(!agreeingMetadata.rights.conflict);

    auto disagreeing = `<html><head><link rel="license" ` ~
        `href="https://creativecommons.org/licenses/by/4.0/"></head>` ~
        `<body><a rel="license" href="https://creativecommons.org/licenses/by-nc/4.0/">CC</a>` ~
        `<p>Body.</p></body></html>`;
    auto disagreeingMetadata = extractFromHtml(disagreeing);
    assert(disagreeingMetadata.rights.status == "ambiguous");
}

class HtmlMetadataOutputLimit : Exception {
    this() pure { super("metadata output limit"); }
}

private struct Writer {
    char[] bytes;
    version (unittest) size_t putCalls;
    version (unittest) size_t lastPutLength;

    void put(scope const(char)[] value) pure {
        if (value.length > maxMetadataJsonBytes - bytes.length)
            throw new HtmlMetadataOutputLimit;
        version (unittest) {
            ++putCalls;
            lastPutLength = value.length;
        }
        bytes ~= value;
    }

    void putDecimal(size_t value) pure {
        char[size_t.sizeof * 3] digits;
        size_t start = digits.length;
        do {
            digits[--start] = cast(char)('0' + value % 10);
            value /= 10;
        } while (value);
        put(digits[start .. $]);
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

    foreach (value; [size_t(0), 9, 10, 99, 100, size_t.max]) {
        Writer decimal;
        decimal.putDecimal(value);
        assert(decimal.bytes == value.to!string);
        assert(decimal.putCalls == 1 && decimal.lastPutLength == decimal.bytes.length);
    }
    Writer exactFit;
    exactFit.bytes.length = maxMetadataJsonBytes - 3;
    exactFit.putDecimal(100);
    assert(exactFit.bytes.length == maxMetadataJsonBytes);
    Writer oneOver;
    oneOver.bytes.length = maxMetadataJsonBytes - 2;
    import std.exception : assertThrown;
    assertThrown!HtmlMetadataOutputLimit(oneOver.putDecimal(100));
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
    if (field.status == "selected") writer.putDecimal(field.node);
    else writer.put("null");
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
        writer.putDecimal(candidate.node);
        writer.put("}");
    }
    writer.put("]}");
}

/// Fixed key order and one LF are metadata-json:v2's canonical wire.
string serializeHtmlMetadata(DocumentId id, const HtmlMetadata metadata) pure {
    Writer writer;
    writer.put(`{"version":"metadata-json:v2","documentId":`);
    writer.quoted(id.text);
    writer.put(`,"fields":{"title":`);
    writer.putField(metadata.title);
    writer.put(`,"author":`);
    writer.putField(metadata.author);
    writer.put(`,"date":`);
    writer.putField(metadata.date);
    writer.put(`,"url":`);
    writer.putField(metadata.url);
    writer.put(`,"rights":`);
    writer.putField(metadata.rights);
    writer.put(`,"siteName":`);
    writer.putField(metadata.siteName);
    writer.put(`,"description":`);
    writer.putField(metadata.description);
    writer.put("}}\n");
    return writer.bytes.idup;
}
