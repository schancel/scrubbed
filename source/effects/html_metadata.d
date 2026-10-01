/// Deterministic, bounded evidence from the selected HTML tree.
module effects.html_metadata;

import domain.document : DocumentId;
import effects.html_tree : HtmlNode, HtmlNodeKind, HtmlTree;
import effects.html_tree_walk : endOf;
import std.array : join;
import std.conv : to;
import std.json : JSONOptions, JSONType, JSONValue, parseJSON;
import std.string : indexOf;
import std.uni : isWhite;
import std.utf : decode, replacementDchar, UseReplacementDchar;

/// Aggregate ld+json bytes scanned per document, and JSON parse depth cap,
/// for the author JSON-LD signal below -- the same bound shape (and same
/// values) `effects.topical_tags_extract_stage`'s own ld+json handling
/// already established as this codebase's precedent for bounding untrusted
/// per-document JSON-LD parsing.
enum size_t maxAuthorLdJsonAggregateBytes = 128 * 1024;
enum int maxAuthorLdJsonParseDepth = 32;

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

/// Concatenates every text-node descendant of `nodeIndex` (any depth),
/// walking each text node's ancestor chain -- the same ancestor-walk idiom
/// this file's own head-membership check uses, and the same shape
/// `effects.topical_tags_extract_stage`'s own `descendantText` helper
/// already established as this codebase's precedent for pulling an
/// element's full visible text out of the flat pre-order tree (used there
/// for `rel="tag"` `<a>` text; used here for `rel="author"` `<a>` text and
/// hCard/hAtom name text, both of which may be wrapped in a nested `<a>` or
/// `<span>` rather than sitting as a direct child).
private string descendantText(const ref HtmlTree tree, size_t nodeIndex) pure {
    string result;
    const end = endOf(tree, nodeIndex);
    foreach (node; tree.nodes[nodeIndex + 1 .. end])
        if (node.kind == HtmlNodeKind.text) result ~= node.text;
    return result;
}

/// Direct (non-recursive) child text, for `<script>` bodies -- the same
/// helper shape `effects.topical_tags_extract_stage`'s own `directChildText`
/// already established.
private string directChildText(const ref HtmlTree tree, size_t nodeIndex) pure {
    string result;
    const end = endOf(tree, nodeIndex);
    foreach (node; tree.nodes[nodeIndex + 1 .. end])
        if (node.parentIndex == nodeIndex && node.kind == HtmlNodeKind.text)
            result ~= node.text;
    return result;
}

private bool isAsciiWhitespace(char c) pure {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f';
}

/// Real whitespace-tokenized `class` attribute matching: splits on ASCII
/// whitespace (the HTML spec's own definition of a "set of space-separated
/// tokens") and compares each token for exact equality, never a substring
/// check. A page with, e.g., `class="post-authorized-badge"` does NOT match
/// token `"author"` under this function -- a real false positive a naive
/// `indexOf` substring check was confirmed (during this ticket's own
/// investigation) to produce.
private bool hasClassToken(string classValue, string token) pure {
    size_t at;
    while (at < classValue.length) {
        while (at < classValue.length && isAsciiWhitespace(classValue[at])) ++at;
        auto start = at;
        while (at < classValue.length && !isAsciiWhitespace(classValue[at])) ++at;
        if (at > start && classValue[start .. at] == token) return true;
    }
    return false;
}

unittest {
    assert(hasClassToken("author", "author"));
    assert(hasClassToken("vcard author", "author"));
    assert(hasClassToken("  vcard   author  ", "author"));
    assert(hasClassToken("author\tvcard", "author"));
    assert(!hasClassToken("post-authorized-badge", "author"));
    assert(!hasClassToken("authors-list", "author"));
    assert(!hasClassToken("", "author"));
    assert(!hasClassToken("vcard", "author"));
}

// ---------------------------------------------------------------------------
// JSON-LD `Article`/`NewsArticle` `author` extraction. Owned locally (not
// imported from `effects.topical_tags_extract_stage`, which owns its own
// ld+json parsing for a different field per that stage's own scope note) --
// mirrors that module's established `@graph`/`@id` back-reference resolution
// approach (the Yoast SEO split-node pattern: a `Person` node with its own
// `@id` living alongside the `Article`/`NewsArticle` node in one `@graph`
// array, with the article's own `author` field being only `{"@id": "..."}`)
// for a different field (`author` instead of `keywords`/`about`).
// ---------------------------------------------------------------------------

private bool isArticleAuthorType(JSONValue entry) pure {
    if (entry.type != JSONType.object) return false;
    auto typeField = "@type" in entry.object;
    if (typeField is null) return false;
    if (typeField.type == JSONType.string)
        return typeField.str == "Article" || typeField.str == "NewsArticle";
    if (typeField.type == JSONType.array) {
        foreach (entry2; typeField.array)
            if (entry2.type == JSONType.string &&
                (entry2.str == "Article" || entry2.str == "NewsArticle")) return true;
    }
    return false;
}

/// `@id` -> `name` for every object in `entries` that carries both a string
/// `@id` and a string `name` -- built once per ld+json document (which may
/// be a bare `{...}` object, an `@graph` array, or a top-level array of
/// nodes) and consulted when an `author` field is itself only `{"@id":
/// "..."}`, the Yoast-style split-node back-reference.
private string[string] ldJsonIdMap(JSONValue[] entries) pure {
    string[string] map;
    foreach (entry; entries) {
        if (entry.type != JSONType.object) continue;
        auto idField = "@id" in entry.object;
        auto nameField = "name" in entry.object;
        if (idField !is null && idField.type == JSONType.string &&
            nameField !is null && nameField.type == JSONType.string)
            map[idField.str] = nameField.str;
    }
    return map;
}

/// Resolves one author entry -- a plain string, or a `Person`-shaped object
/// (a direct `name` string, or only an `@id` requiring `idMap` lookup) --
/// to a display name, or `null` if this entry has no usable name at all.
private string resolvePersonName(JSONValue entry, const string[string] idMap) pure {
    if (entry.type == JSONType.string) return entry.str;
    if (entry.type != JSONType.object) return null;
    auto nameField = "name" in entry.object;
    if (nameField !is null && nameField.type == JSONType.string) return nameField.str;
    auto idField = "@id" in entry.object;
    if (idField !is null && idField.type == JSONType.string) {
        auto resolved = idField.str in idMap;
        if (resolved !is null) return *resolved;
    }
    return null;
}

/// Resolves an `author` field's full value -- a plain string, a single
/// `Person`-shaped object, or an array of either -- to one display string.
/// Multiple resolved names (a genuine multi-byline array) are joined with
/// `"; "`, matching trafilatura's own `tests/eval_authors.py` multi-author
/// join convention that this ticket's own held-out scoring already mirrors
/// (see `experiments/metadata/fetch_held_out.sh`'s driver), so a correctly
/// extracted multi-author byline can still exact-match that convention's
/// gold value.
private string ldJsonAuthorValue(JSONValue authorField, const string[string] idMap) pure {
    if (authorField.type == JSONType.array) {
        string[] names;
        foreach (entry; authorField.array) {
            auto name = resolvePersonName(entry, idMap);
            if (name.length) names ~= name;
        }
        return names.length ? names.join("; ") : null;
    }
    return resolvePersonName(authorField, idMap);
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

/// Head evidence is eligible for every field except a few narrow,
/// specifically-scoped exceptions (see the second pass below): a body
/// `<a rel="license" href>` license link, and three author signals --
/// `rel="author"` link text, JSON-LD `Article`/`NewsArticle` `author`, and
/// hCard/hAtom `class`-based author markup -- any of which may legitimately
/// appear in `<head>` or `<body>` alike, so all are scanned document-wide
/// rather than being restricted to one or the other. Node ordinals refer to
/// HtmlTree pre-order.
HtmlMetadata extractHtmlMetadata(const ref HtmlTree tree) pure {
    HtmlMetadata result;
    size_t head = size_t.max;
    foreach (i, node; tree.nodes) if (node.kind == HtmlNodeKind.element && node.name == "head") {
        head = i;
        break;
    }
    if (head != size_t.max) foreach (i, node; tree.nodes[head .. endOf(tree, head)]) {
        i += head;
        if (node.kind != HtmlNodeKind.element) continue;
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
    // Author, second pass (issue #525): three additional, deterministic,
    // bounded signals, all lower priority than the head-scoped
    // `meta[name=author]`/`meta[property=article:author]` signals above
    // (priority 0/1), in real-world-reliability order:
    //   - JSON-LD `Article`/`NewsArticle` `author` (priority 2) is explicit
    //     structured data, the same general precedent
    //     `effects.topical_tags_extract_stage`'s own JSON-LD handling
    //     already established for a different field (see the JSON-LD
    //     helpers above), including `@graph`/`@id` back-reference
    //     resolution for the real Yoast-SEO split-node pattern.
    //   - hCard/hAtom `class`-based author markup (priority 3) is explicit,
    //     deliberate author markup, but slightly weaker: a real held-out
    //     page's `class="post-authorized-badge"` would be a false positive
    //     under a naive substring check, which real whitespace-tokenized
    //     `class` matching (`hasClassToken`) correctly excludes.
    //   - `<a rel="author">`/`<link rel="author">` link text (priority 4)
    //     is this section's lowest-priority, weakest tier, checked last: a
    //     `rel="author"` link's visible text is frequently a bio-page label
    //     ("About the author") rather than the author's actual name, unlike
    //     `rel="license"`'s href (used at the same priority as the
    //     head-scoped `link:license` rule, since it is the identical
    //     `rel="license"` semantic on a different element) -- this is the
    //     one signal here that actually mirrors the license second pass's
    //     narrow "eligible anywhere in the document" exception shape, just
    //     scored as the weakest of the four author signals rather than
    //     tied with an existing head rule.
    // All three are scanned in one combined forward pass alongside the
    // existing license pass above, since they are likewise narrow,
    // specifically-scoped exceptions to this function's otherwise-uniform
    // "only head evidence is eligible" rule -- not a general body-wide walk
    // for any other field.
    size_t ldJsonBytesScanned;
    foreach (i, node; tree.nodes) {
        if (node.kind != HtmlNodeKind.element) continue;
        if (node.name == "script" && attribute(node, "type") == "application/ld+json") {
            auto scriptText = directChildText(tree, i);
            if (scriptText.length == 0) continue;
            if (ldJsonBytesScanned + scriptText.length > maxAuthorLdJsonAggregateBytes) continue;
            ldJsonBytesScanned += scriptText.length;
            JSONValue root;
            try root = parseJSON(scriptText, maxAuthorLdJsonParseDepth, JSONOptions.strictParsing);
            catch (Exception) continue; // invalid JSON syntax: skip this block only
            JSONValue[] entries;
            if (root.type == JSONType.array) entries = root.array;
            else if (root.type == JSONType.object) {
                auto graphField = "@graph" in root.object;
                entries = (graphField !is null && graphField.type == JSONType.array) ?
                    graphField.array : [root];
            }
            if (entries.length == 0) continue;
            auto idMap = ldJsonIdMap(entries);
            foreach (entry; entries) {
                if (!isArticleAuthorType(entry)) continue;
                auto authorField = "author" in entry.object;
                if (authorField is null) continue;
                offer(result.author, ldJsonAuthorValue(*authorField, idMap), "ldjson:author", i, 2);
            }
            continue;
        }
        if ((node.name == "a" || node.name == "link") && attribute(node, "rel") == "author") {
            offer(result.author, descendantText(tree, i), "a:rel-author", i, 4);
            continue;
        }
        auto classValue = attribute(node, "class");
        if (classValue.length == 0 || !hasClassToken(classValue, "author")) continue;
        size_t fnNode = size_t.max;
        const authorEnd = endOf(tree, i);
        foreach (j, candidate; tree.nodes[i + 1 .. authorEnd]) {
            j += i + 1;
            if (fnNode != size_t.max || candidate.kind != HtmlNodeKind.element) continue;
            auto candidateClass = attribute(candidate, "class");
            if (candidateClass.length && hasClassToken(candidateClass, "fn")) fnNode = j;
        }
        auto name = fnNode != size_t.max ?
            descendantText(tree, fnNode) : descendantText(tree, i);
        offer(result.author, name, fnNode != size_t.max ? "hcard:fn" : "hcard:author", i, 3);
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

// ---------------------------------------------------------------------------
// Issue #525: three additional author signals -- `rel="author"` link text,
// JSON-LD `Article`/`NewsArticle` `author` (including `@graph`/`@id`
// back-reference resolution), and hCard/hAtom `class`-based author markup.
// ---------------------------------------------------------------------------

// Fixture: a head `meta[name=author]` still wins over all three new,
// lower-priority body signals -- meta tags remain highest priority.
unittest {
    auto html = `<html><head><meta name="author" content="Meta Author"></head>` ~
        `<body>` ~
        `<div class="author"><span class="fn">HCard Author</span></div>` ~
        `<script type="application/ld+json">{"@type":"Article","author":"JsonLd Author"}</script>` ~
        `<a rel="author" href="/authors/x">Rel Author</a>` ~
        `<p>Body text.</p></body></html>`;
    auto metadata = extractFromHtml(html);
    assert(metadata.author.status == "selected");
    assert(metadata.author.value == "Meta Author");
    assert(metadata.author.rule == "author");
}

// Fixture: real-world `<a rel="author">` byline link, body-positioned (the
// same narrow "eligible anywhere in the document" exception shape as the
// existing `rel="license"` precedent), no other author evidence present.
unittest {
    auto html = `<html><head><title>A Post</title></head>` ~
        `<body><p class="byline">By <a rel="author" href="/authors/jane-doe">` ~
        `Jane Doe</a></p><p>Body text.</p></body></html>`;
    auto metadata = extractFromHtml(html);
    assert(metadata.author.status == "selected");
    assert(metadata.author.value == "Jane Doe");
    assert(metadata.author.rule == "a:rel-author");
}

// Fixture: `<link rel="author">` (a void element -- no possible link text)
// contributes no candidate at all, rather than a spurious empty match.
unittest {
    auto html = `<html><head><link rel="author" href="mailto:jane@example.com"></head>` ~
        `<body><p>Body text with no other author evidence.</p></body></html>`;
    auto metadata = extractFromHtml(html);
    assert(metadata.author.status == "absent");
}

// Fixture: JSON-LD `Article.author` as a plain string -- the simplest real
// shape.
unittest {
    auto html = `<html><head><script type="application/ld+json">` ~
        `{"@context":"https://schema.org","@type":"Article","author":"Jane Doe"}` ~
        `</script></head><body><p>Body text.</p></body></html>`;
    auto metadata = extractFromHtml(html);
    assert(metadata.author.status == "selected");
    assert(metadata.author.value == "Jane Doe");
    assert(metadata.author.rule == "ldjson:author");
}

// Fixture: JSON-LD `NewsArticle.author` as a `Person` object with a `name`
// field (no `@graph`/`@id` indirection) -- also proves `NewsArticle`, not
// just `Article`, is recognized.
unittest {
    auto html = `<html><head><script type="application/ld+json">` ~
        `{"@type":"NewsArticle","author":{"@type":"Person","name":"Jane Doe"}}` ~
        `</script></head><body><p>Body text.</p></body></html>`;
    auto metadata = extractFromHtml(html);
    assert(metadata.author.status == "selected");
    assert(metadata.author.value == "Jane Doe");
    assert(metadata.author.rule == "ldjson:author");
}

// Fixture: JSON-LD `author` as an array of `Person` objects/strings -- a
// genuine multi-byline page -- joined with "; ", matching trafilatura's own
// `tests/eval_authors.py` multi-author join convention (the same convention
// `experiments/metadata/fetch_held_out.sh`'s own driver already scores
// against).
unittest {
    auto html = `<html><head><script type="application/ld+json">` ~
        `{"@type":"Article","author":[{"@type":"Person","name":"Jane Doe"},"John Smith"]}` ~
        `</script></head><body><p>Body text.</p></body></html>`;
    auto metadata = extractFromHtml(html);
    assert(metadata.author.status == "selected");
    assert(metadata.author.value == "Jane Doe; John Smith");
}

// Fixture: the real Yoast-SEO `@graph`/`@id` split-node pattern -- the
// `Article` node's own `author` field is only `{"@id": "..."}`, and the
// actual `Person` node with a `name` lives elsewhere in the same `@graph`
// array, identified by a matching `@id`.
unittest {
    auto html = `<html><head><script type="application/ld+json">` ~
        `{"@context":"https://schema.org","@graph":[` ~
        `{"@type":"Person","@id":"https://example.com/#/schema/person/abc123",` ~
        `"name":"Jane Doe"},` ~
        `{"@type":"Article","@id":"https://example.com/#article",` ~
        `"author":{"@id":"https://example.com/#/schema/person/abc123"},` ~
        `"headline":"A Post"}` ~
        `]}</script></head><body><p>Body text.</p></body></html>`;
    auto metadata = extractFromHtml(html);
    assert(metadata.author.status == "selected");
    assert(metadata.author.value == "Jane Doe");
    assert(metadata.author.rule == "ldjson:author");
}

// Fixture: malformed JSON-LD (invalid syntax, and a `BlogPosting` `@type`
// this slice does not recognize) does not quarantine and does not produce a
// spurious author candidate.
unittest {
    auto html = `<html><head>` ~
        `<script type="application/ld+json">{not valid json at all</script>` ~
        `<script type="application/ld+json">{"@type":"BlogPosting","author":"Nobody"}</script>` ~
        `</head><body><p>Body text.</p></body></html>`;
    auto metadata = extractFromHtml(html);
    assert(metadata.author.status == "absent");
}

// Fixture: hCard/hAtom `class="vcard author"` container with a nested
// `class="fn"` descendant (itself wrapped in an `<a>`, the common real
// shape) -- name is read from the `.fn` descendant's own text, not the
// whole container's text.
unittest {
    auto html = `<html><head><title>A Post</title></head>` ~
        `<body><div class="vcard author">By <a class="url fn" ` ~
        `href="/authors/jane-doe">Jane Doe</a>, staff writer</div>` ~
        `<p>Body text.</p></body></html>`;
    auto metadata = extractFromHtml(html);
    assert(metadata.author.status == "selected");
    assert(metadata.author.value == "Jane Doe");
    assert(metadata.author.rule == "hcard:fn");
}

// Fixture: hCard-style `class="author"` container with no `.fn` descendant
// at all -- falls back to the container's own (full descendant) text.
unittest {
    auto html = `<html><head><title>A Post</title></head>` ~
        `<body><span class="author">Jane Doe</span>` ~
        `<p>Body text.</p></body></html>`;
    auto metadata = extractFromHtml(html);
    assert(metadata.author.status == "selected");
    assert(metadata.author.value == "Jane Doe");
    assert(metadata.author.rule == "hcard:author");
}

// Fixture: the real false positive a naive `class` substring check (e.g.
// `indexOf("author") >= 0`) would produce, confirmed during this ticket's
// own investigation -- `class="post-authorized-badge"` contains the
// substring "author" but is NOT the whitespace-tokenized class token
// "author", so real tokenized matching correctly excludes it and no author
// candidate is produced at all.
unittest {
    auto html = `<html><head><title>A Post</title></head>` ~
        `<body><span class="post-authorized-badge">Verified</span>` ~
        `<p>Body text with no real author markup at all.</p></body></html>`;
    auto metadata = extractFromHtml(html);
    assert(metadata.author.status == "absent");
}

// Fixture: `class="authors-list"` (a distinct, longer token, not the exact
// token "author") is likewise correctly excluded by real tokenized
// matching.
unittest {
    auto html = `<html><body><div class="authors-list">Our Team</div>` ~
        `<p>Body text.</p></body></html>`;
    auto metadata = extractFromHtml(html);
    assert(metadata.author.status == "absent");
}

// Fixture: priority ordering among the three new signals themselves (all
// lower priority than meta tags, per the earlier fixture above) --
// JSON-LD (2) beats hCard (3) beats `rel="author"` (4) when more than one
// is present on the same page with no meta-tag evidence at all.
unittest {
    auto html = `<html><head><title>A Post</title>` ~
        `<script type="application/ld+json">{"@type":"Article","author":"JsonLd Author"}</script>` ~
        `</head><body>` ~
        `<div class="author"><span class="fn">HCard Author</span></div>` ~
        `<a rel="author" href="/authors/x">Rel Author</a>` ~
        `<p>Body text.</p></body></html>`;
    auto metadata = extractFromHtml(html);
    assert(metadata.author.status == "selected");
    assert(metadata.author.value == "JsonLd Author");
    assert(metadata.author.rule == "ldjson:author");

    auto htmlNoJsonLd = `<html><head><title>A Post</title></head><body>` ~
        `<div class="author"><span class="fn">HCard Author</span></div>` ~
        `<a rel="author" href="/authors/x">Rel Author</a>` ~
        `<p>Body text.</p></body></html>`;
    auto metadataNoJsonLd = extractFromHtml(htmlNoJsonLd);
    assert(metadataNoJsonLd.author.status == "selected");
    assert(metadataNoJsonLd.author.value == "HCard Author");
    assert(metadataNoJsonLd.author.rule == "hcard:fn");
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
