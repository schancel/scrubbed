/// CSV, generic XML, and TEI-conformant XML serialization of the selected
/// main-content HTML subtree. Issue #481, the last of #471's seven
/// trafilatura-parity slices: `extract --format=...` already covers
/// `tree-json`/`markdown`/`main-content-markdown` (see `html_tree_json_
/// stage.d`/`html_markdown_stage.d`/`html_main_content_markdown_stage.d`);
/// this module adds `csv`/`xml`/`xml-tei`.
///
/// **Deliberately independent of `html_markdown.d`.** Every renderer here
/// walks the D-owned `HtmlTree` (`effects.html_tree`) directly -- the same
/// boundary `html_markdown.d` and `html_main_content.d` already consume --
/// and never calls into `html_markdown.d`'s `renderMarkdown`/`renderTable`/
/// `clean()` or reads their already-rendered Markdown text. The only code
/// shared with `html_markdown.d` is the low-level tree-walking primitives
/// in `effects.html_tree_walk` (`endOf`, `attribute`, `hiddenTag`,
/// `headingLevel`, `safeTarget`, `singleLine`; issue #497), none of which
/// touches the table/list string-flattening renderers.
/// This is a real, disclosed judgment call (see issue #481's own handoff
/// instructions): issue #493 (nested tables corrupt an outer cell with
/// stray unescaped GFM delimiter syntax, `| Outer | \n |---| \n | before |
/// Inner | |---| | innerdata | after |`) is a defect specific to
/// `renderTable`'s GFM pipe-table text serialization -- flattening a
/// recursively-rendered inner table's own real `|`/`-` syntax characters
/// into one flat string cell with no escaping. XML has no such problem by
/// construction: a nested `<table>` inside a `<cell>` is ordinary,
/// unambiguous, well-formed XML nesting, and CSV here never re-derives
/// table structure from rendered Markdown text either (see `csvRow`'s own
/// doc comment). #493 therefore does not reach this module at all -- not
/// because it was fixed, but because this module never shares the code
/// path that has the bug. `html_markdown.d` is untouched by this ticket.
module effects.extract_formats;

import effects.html_main_content : extractMainContent, HtmlMainContentOutputLimit,
    MainContentResult, MainContentStatus;
import effects.html_tree : HtmlAttribute, HtmlNodeKind, HtmlTree;
import effects.html_tree_walk : attribute, endOf, headingLevel, hiddenTag,
    safeTarget, singleLine, white;
import std.array : split;
import std.uni : isControl, isFormat;
import std.utf : encode;

enum size_t maxExtractFormatBytes = 4 * 1024 * 1024;

class ExtractFormatOutputLimit : Exception {
    this() pure { super("extract-format output exceeds 4 MiB"); }
}

// ---- Module-local low-level helpers (the tree-walking primitives shared
// with html_markdown.d live in effects.html_tree_walk -- see this module's
// doc comment). ----

private struct Writer {
    char[] bytes;

    void put(scope const(char)[] value) pure {
        if (value.length > maxExtractFormatBytes - bytes.length)
            throw new ExtractFormatOutputLimit;
        bytes ~= value;
    }

    // bytes starts empty, is only grown internally, and is consumed here.
    string finish() pure nothrow {
        import std.exception : assumeUnique;
        if (!bytes.length) { bytes = null; return null; }
        return assumeUnique(bytes);
    }
}

/// XML-escape ordinary element text content: `&`/`<`/`>` only (`>` is not
/// strictly required by the XML spec but is escaped anyway, matching every
/// other real XML serializer's conservative default). Control/format
/// characters are dropped (never emitted raw into XML text, where a raw
/// C0 control byte other than tab/newline/CR is not well-formed).
private string xmlText(string input) pure {
    Writer writer;
    foreach (dchar c; input) {
        if (c != '\t' && c != '\n' && c != '\r' && (isControl(c) || isFormat(c))) continue;
        switch (c) {
            case '&': writer.put("&amp;"); continue;
            case '<': writer.put("&lt;"); continue;
            case '>': writer.put("&gt;"); continue;
            default: break;
        }
        char[4] encoded;
        writer.put(cast(string) encoded[0 .. encode(encoded, c)]);
    }
    return writer.finish();
}

/// XML-escape an attribute value: the same three characters as `xmlText`,
/// plus the double quote (every attribute value emitted by this module is
/// double-quoted).
private string xmlAttr(string input) pure {
    Writer writer;
    foreach (dchar c; input) {
        if (c != '\t' && c != '\n' && (isControl(c) || isFormat(c))) continue;
        switch (c) {
            case '&': writer.put("&amp;"); continue;
            case '<': writer.put("&lt;"); continue;
            case '>': writer.put("&gt;"); continue;
            case '"': writer.put("&quot;"); continue;
            default: break;
        }
        char[4] encoded;
        writer.put(cast(string) encoded[0 .. encode(encoded, c)]);
    }
    return writer.finish();
}

/// First `<title>` element's raw text anywhere in the whole parsed tree
/// (`html_tree.d` keeps `<head>` content in the tree even though
/// `html_markdown.d`/this module's own content renderers skip it as a
/// hidden tag when walking body content) -- a real, cheap, independently
/// available page title signal for `csvRow`'s `title` column, distinct from
/// and not dependent on `html_metadata.d` (out of this ticket's file scope;
/// see the module doc comment).
private string documentTitle(const ref HtmlTree tree) pure {
    foreach (i, ref const node; tree.nodes) {
        if (node.kind != HtmlNodeKind.element || node.name != "title") continue;
        Writer text;
        foreach (j; i + 1 .. endOf(tree, i))
            if (tree.nodes[j].kind == HtmlNodeKind.text) text.put(tree.nodes[j].text);
        auto flattened = singleLine(text.finish());
        if (flattened.length) return flattened;
    }
    return null;
}

// ==== Generic XML =========================================================

/// Well-formed, self-describing generic XML -- this module's own schema
/// (design latitude explicitly left to this ticket), not a reuse of any
/// third-party vocabulary. Root `<document>`, with `<main>` holding the
/// selected content and an optional sibling `<comments>`. Block elements:
/// `<heading level="1".."6">`, `<paragraph>`, `<list ordered="true|false">`/
/// `<item>`, `<quote>`, `<code>` (block, from `<pre>`), `<table>`/`<row>`/
/// `<cell header="true">` (with a real `<caption>` preserved, and a nested
/// `<table>` inside a `<cell>` simply nesting as ordinary child XML -- see
/// this module's doc comment on why issue #493 cannot reach this path).
/// Inline content inside a block: escaped text, `<link href="...">`,
/// `<image src="..." alt="..."/>`, `<bold>`/`<italic>`, and a literal
/// newline for `<br>`.
string renderXml(const ref HtmlTree tree) pure {
    auto selection = extractMainContent(tree);
    Writer w;
    w.put("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<document>\n");
    w.put("  <main>\n");
    if (selection.status == MainContentStatus.selected)
        renderXmlContainer(tree, selection.node, w, 2, false);
    else if (selection.status == MainContentStatus.selectedStructuredData)
        renderFlatParagraphsXml(selection.text, w, 2, "paragraph");
    w.put("  </main>\n");
    if (selection.commentsExtracted) {
        w.put("  <comments>\n");
        renderFlatParagraphsXml(selection.comments, w, 2, "paragraph");
        w.put("  </comments>\n");
    }
    w.put("</document>\n");
    return w.finish();
}

private void renderFlatParagraphsXml(string text, ref Writer w, size_t indent, string tag) pure {
    if (!text.length) return;
    string pad; foreach (_; 0 .. indent) pad ~= "  ";
    foreach (paragraph; text.split("\n\n")) {
        auto trimmed = singleLine(paragraph);
        if (!trimmed.length) continue;
        w.put(pad); w.put("<"); w.put(tag); w.put(">");
        w.put(xmlText(trimmed));
        w.put("</"); w.put(tag); w.put(">\n");
    }
}

/// True iff `content` (already-rendered inline XML) has at least one
/// non-whitespace character outside of markup -- a crude but adequate test
/// here since the only markup this module ever emits inline is a handful of
/// short, known tag names with no whitespace-only attribute values. Used to
/// drop a real page's genuinely empty `<p></p>`/ad-script-only paragraph
/// noise (confirmed present on real pages via this ticket's own held-out
/// corpus run) rather than emitting a meaningless empty element for it --
/// matching trafilatura's own real observed behavior of dropping empty
/// paragraphs, not guessed.
private bool hasNonWhitespace(string content) pure {
    import std.algorithm.searching : canFind;
    // A self-closing image/graphic/line-break carries real meaning with no
    // text content at all -- never treated as empty.
    if (content.canFind("<image") || content.canFind("<graphic") || content.canFind("<lb/>"))
        return true;
    bool inTag;
    foreach (c; content) {
        if (c == '<') { inTag = true; continue; }
        if (c == '>') { inTag = false; continue; }
        if (inTag) continue;
        if (!white(c)) return true;
    }
    return false;
}

private bool inlineLeafTag(string name) pure {
    return name == "br" || name == "img" || name == "code" ||
        name == "strong" || name == "b" || name == "em" || name == "i" || name == "a";
}

/// Scans `containerIndex`'s subtree (not including the container node
/// itself) for recognized block-level elements (heading/p/ul/ol/blockquote/
/// table/pre) in document order, non-overlapping: once matched, that
/// element's own subtree is skipped (so a block nested inside an already-
/// emitted block -- e.g. a `<p>` inside a `<blockquote>` -- is rendered once,
/// by the outer block's own recursive call, never twice). An element that
/// is not itself a recognized block tag is transparent: the scan simply
/// continues into its children, so real content nested inside a wrapper
/// `<div>`/`<article>`/`<section>` is still found. Text and recognized
/// inline leaves (`br`/`img`/`code`/`strong`/`b`/`em`/`i`/`a`) found
/// directly in the scan -- not wrapped in any block-level element, e.g. a
/// bare text run alongside a nested `<table>` inside a table cell -- are
/// never dropped: they accumulate into a pending inline buffer that is
/// flushed (in document order, ahead of the next real block, or at the end
/// of the subtree) as its own `<paragraph>` when `inlineIsBare` is false, or
/// as bare inline content with no wrapper when `inlineIsBare` is true (list
/// items and table cells with nested block content -- see their own call
/// sites). This is what keeps a page's real content from ever silently
/// disappearing, matching this module's own "no text loss" bar (see this
/// module's doc comment on issue #493, which -- unlike this renderer --
/// never lost real text either, only corrupted its own delimiter syntax).
private void renderXmlContainer(const ref HtmlTree tree, size_t containerIndex,
        ref Writer w, size_t indent, bool inlineIsBare) pure {
    if (indent > 256) throw new ExtractFormatOutputLimit;
    string pad; foreach (_; 0 .. indent) pad ~= "  ";
    Writer pending;
    void flush() {
        if (!pending.bytes.length) return;
        auto content = pending.finish();
        if (!hasNonWhitespace(content)) return;
        if (inlineIsBare) w.put(content);
        else { w.put(pad); w.put("<paragraph>"); w.put(content); w.put("</paragraph>\n"); }
    }
    size_t containerEnd = endOf(tree, containerIndex);
    for (size_t i = containerIndex + 1; i < containerEnd; ) {
        ref const node = tree.nodes[i];
        if (node.kind == HtmlNodeKind.text || (node.kind == HtmlNodeKind.element &&
                inlineLeafTag(node.name))) {
            renderXmlInlineNode(tree, i, pending);
            i = endOf(tree, i);
            continue;
        }
        if (node.kind != HtmlNodeKind.element) { ++i; continue; }
        if (hiddenTag(node.name)) { i = endOf(tree, i); continue; }
        int level;
        if (headingLevel(node.name, level)) {
            flush();
            auto headingText = xmlText(singleLine(plainInlineText(tree, i)));
            if (headingText.length) {
                w.put(pad); w.put("<heading level=\""); w.put(cast(string)[cast(char)('0' + level)]);
                w.put("\">"); w.put(headingText); w.put("</heading>\n");
            }
            i = endOf(tree, i);
            continue;
        }
        if (node.name == "p") {
            flush();
            auto paragraph = renderXmlInlineToString(tree, i);
            if (hasNonWhitespace(paragraph)) {
                w.put(pad); w.put("<paragraph>"); w.put(paragraph); w.put("</paragraph>\n");
            }
            i = endOf(tree, i);
            continue;
        }
        if (node.name == "ul" || node.name == "ol") {
            flush();
            renderXmlList(tree, i, w, indent);
            i = endOf(tree, i);
            continue;
        }
        if (node.name == "blockquote") {
            flush();
            w.put(pad); w.put("<quote>\n");
            renderXmlContainer(tree, i, w, indent + 1, false);
            w.put(pad); w.put("</quote>\n");
            i = endOf(tree, i);
            continue;
        }
        if (node.name == "table") {
            flush();
            renderXmlTable(tree, i, w, indent);
            i = endOf(tree, i);
            continue;
        }
        if (node.name == "pre") {
            flush();
            w.put(pad); w.put("<code>");
            w.put(xmlText(plainInlineText(tree, i)));
            w.put("</code>\n");
            i = endOf(tree, i);
            continue;
        }
        ++i; // transparent container: keep descending
    }
    flush();
}

private void renderXmlList(const ref HtmlTree tree, size_t listIndex, ref Writer w, size_t indent) pure {
    string pad; foreach (_; 0 .. indent) pad ~= "  ";
    bool ordered = tree.nodes[listIndex].name == "ol";
    w.put(pad); w.put("<list ordered=\""); w.put(ordered ? "true" : "false"); w.put("\">\n");
    size_t listEnd = endOf(tree, listIndex);
    for (size_t child = listIndex + 1; child < listEnd; child = endOf(tree, child)) {
        if (tree.nodes[child].parentIndex != listIndex) continue;
        if (tree.nodes[child].name != "li") continue;
        string itemPad; foreach (_; 0 .. indent + 1) itemPad ~= "  ";
        w.put(itemPad); w.put("<item>");
        bool hadNestedBlock;
        // A list item's own nested block content (a sub-list, a nested
        // table/blockquote/paragraph) is real structure worth preserving as
        // real child elements rather than flattening to inline text; a
        // plain text-only item (the overwhelmingly common real shape)
        // stays a single flat `<item>text</item>` line.
        size_t itemEnd = endOf(tree, child);
        foreach (j; child + 1 .. itemEnd)
            if (tree.nodes[j].kind == HtmlNodeKind.element &&
                (tree.nodes[j].name == "ul" || tree.nodes[j].name == "ol" ||
                 tree.nodes[j].name == "p" || tree.nodes[j].name == "table" ||
                 tree.nodes[j].name == "blockquote")) { hadNestedBlock = true; break; }
        if (hadNestedBlock) {
            w.put("\n");
            renderXmlContainer(tree, child, w, indent + 2, true);
            w.put(itemPad);
        } else {
            renderXmlInline(tree, child, w);
        }
        w.put("</item>\n");
    }
    w.put(pad); w.put("</list>\n");
}

/// Only a row/caption whose nearest `<table>` ancestor is exactly
/// `tableIndex` belongs to this table's own grid -- identical policy to
/// `html_markdown.d`'s own `renderTable` (a nested table's rows are its
/// own, rendered separately when that cell's content is rendered). Because
/// this emits a real nested `<table>` XML element for that inner table
/// (via `renderXmlContainer`'s block scan over the cell's own subtree),
/// rather than flattening it into a shared string buffer, nested tables of
/// any depth are unambiguous, well-formed XML -- issue #493's failure mode
/// (a flattened, unescaped inner delimiter-row fragment corrupting the
/// outer cell) has no equivalent here.
private void renderXmlTable(const ref HtmlTree tree, size_t tableIndex, ref Writer w, size_t indent) pure {
    string pad; foreach (_; 0 .. indent) pad ~= "  ";
    string rowPad; foreach (_; 0 .. indent + 1) rowPad ~= "  ";
    string cellPad; foreach (_; 0 .. indent + 2) cellPad ~= "  ";
    w.put(pad); w.put("<table>\n");
    size_t tableEnd = endOf(tree, tableIndex);
    for (size_t i = tableIndex + 1; i < tableEnd; ++i) {
        ref const candidate = tree.nodes[i];
        if (candidate.kind != HtmlNodeKind.element) continue;
        if (candidate.name == "caption" && candidate.parentIndex == tableIndex) {
            w.put(rowPad); w.put("<caption>");
            renderXmlInline(tree, i, w);
            w.put("</caption>\n");
            continue;
        }
        if (candidate.name != "tr") continue;
        size_t parent = candidate.parentIndex;
        bool ownRow;
        while (parent != size_t.max) {
            if (tree.nodes[parent].name == "table") { ownRow = parent == tableIndex; break; }
            parent = tree.nodes[parent].parentIndex;
        }
        if (!ownRow) continue;
        w.put(rowPad); w.put("<row>\n");
        for (size_t child = i + 1; child < endOf(tree, i); child = endOf(tree, child)) {
            if (tree.nodes[child].parentIndex != i) continue;
            bool header = tree.nodes[child].name == "th";
            if (!header && tree.nodes[child].name != "td") continue;
            w.put(cellPad); w.put("<cell");
            if (header) w.put(" header=\"true\"");
            w.put(">");
            bool hadBlock;
            size_t cellEnd = endOf(tree, child);
            foreach (j; child + 1 .. cellEnd)
                if (tree.nodes[j].kind == HtmlNodeKind.element &&
                    (tree.nodes[j].name == "table" || tree.nodes[j].name == "ul" ||
                     tree.nodes[j].name == "ol" || tree.nodes[j].name == "p" ||
                     tree.nodes[j].name == "blockquote")) { hadBlock = true; break; }
            if (hadBlock) {
                w.put("\n");
                renderXmlContainer(tree, child, w, indent + 3, true);
                w.put(cellPad);
            } else {
                renderXmlInline(tree, child, w);
            }
            w.put("</cell>\n");
        }
        w.put(rowPad); w.put("</row>\n");
    }
    w.put(pad); w.put("</table>\n");
}

/// Raw (unescaped) concatenation of every descendant text node's real text,
/// skipping a hidden-tag subtree (`script`/`style`/`template`/`head`) --
/// used only where the caller applies its own escaping/collapsing
/// afterward (heading text, `<pre>` code content).
private string plainInlineText(const ref HtmlTree tree, size_t index) pure {
    Writer writer;
    size_t end = endOf(tree, index);
    for (size_t i = index + 1; i < end; ++i) {
        bool breakNode = tree.nodes[i].kind == HtmlNodeKind.element && tree.nodes[i].name == "br";
        if (tree.nodes[i].kind != HtmlNodeKind.text && !breakNode) continue;
        bool hidden;
        for (size_t parent = tree.nodes[i].parentIndex; parent != index &&
             parent != size_t.max && parent < i; parent = tree.nodes[parent].parentIndex)
            if (hiddenTag(tree.nodes[parent].name)) { hidden = true; break; }
        if (!hidden) writer.put(breakNode ? "\n" : tree.nodes[i].text);
    }
    return writer.finish();
}

private string renderXmlInlineToString(const ref HtmlTree tree, size_t index) pure {
    Writer w;
    renderXmlInline(tree, index, w);
    return w.finish();
}

/// Inline content of a block (paragraph/heading/list item/table cell):
/// escaped text, `<link href="...">`, `<image .../>`, `<bold>`/`<italic>`,
/// inline `<code>`, and a literal newline for `<br>`. An element that is
/// none of these (span, sup, small, ...) is transparent: only its children
/// are walked. A nested block-level element (e.g. a `<p>` accidentally
/// reached from `renderXmlContainer`'s bare-inline fallback) still renders
/// its own text rather than being silently dropped.
private void renderXmlInline(const ref HtmlTree tree, size_t parent, ref Writer w) pure {
    for (size_t child = parent + 1; child < endOf(tree, parent); child = endOf(tree, child)) {
        if (tree.nodes[child].parentIndex != parent) continue;
        renderXmlInlineNode(tree, child, w);
    }
}

private void renderXmlInlineNode(const ref HtmlTree tree, size_t index, ref Writer w) pure {
    ref const node = tree.nodes[index];
    if (node.kind == HtmlNodeKind.text) { w.put(xmlText(node.text)); return; }
    if (hiddenTag(node.name)) return;
    if (node.name == "br") { w.put("\n"); return; }
    if (node.name == "img") {
        auto src = attribute(node, "src");
        auto alt = xmlAttr(attribute(node, "alt"));
        w.put("<image");
        if (safeTarget(src)) { w.put(" src=\""); w.put(xmlAttr(src)); w.put("\""); }
        if (alt.length) { w.put(" alt=\""); w.put(alt); w.put("\""); }
        w.put("/>");
        return;
    }
    if (node.name == "code") {
        w.put("<code>"); w.put(xmlText(singleLine(plainInlineText(tree, index)))); w.put("</code>");
        return;
    }
    if (node.name == "strong" || node.name == "b") {
        w.put("<bold>"); renderXmlInline(tree, index, w); w.put("</bold>");
        return;
    }
    if (node.name == "em" || node.name == "i") {
        w.put("<italic>"); renderXmlInline(tree, index, w); w.put("</italic>");
        return;
    }
    if (node.name == "a") {
        auto href = attribute(node, "href");
        const safe = safeTarget(href);
        if (safe) { w.put("<link href=\""); w.put(xmlAttr(href)); w.put("\">"); }
        renderXmlInline(tree, index, w);
        if (safe) w.put("</link>");
        return;
    }
    // Transparent inline wrapper (span, sup, small, ...): render children only.
    renderXmlInline(tree, index, w);
}

// ==== TEI-conformant XML ===================================================

/// TEI P5 output. Tag/attribute vocabulary deliberately mirrors pinned
/// trafilatura==2.2.0's own real, DTD-validated `--output-format xmltei`
/// shape (confirmed empirically against that exact pinned version -- see
/// `experiments/html_main_content/compare_trafilatura_extract_formats.sh`),
/// not guessed: `<div type="entry">`/`<div type="comments">`, `<p>`,
/// `<list rend="ul"|"ol">`/`<item>`, `<quote><p>...</p></quote>`, `<table>`/
/// `<row>`/`<cell role="head">` for a header cell, `<code>` (block, raw
/// text), `<ref target="...">`, `<lb/>` for a line break, and -- the one
/// piece that is *not* optional to get right -- a heading anywhere in the
/// body becomes `<ab rend="hN" type="header">`, never a body `<head>`: the
/// real TEI `div` content model permits a `<head>` only as the single first
/// child of a `div`, never repeated mid-content, which is exactly why
/// trafilatura's own converter uses `<ab>` for every heading it meets after
/// the first (confirmed by running the pinned CLI on a real multi-heading
/// page and reading its own emitted markup, not by reading trafilatura's
/// source alone). Only the attributes trafilatura's own TEI_VALID_ATTRS
/// allow (`rend`/`rendition`/`role`/`target`/`type`) are ever emitted here,
/// for the same reason: this is what a real run against the pinned tool
/// proved acceptable, not an assumption.
string renderXmlTei(const ref HtmlTree tree) pure {
    auto selection = extractMainContent(tree);
    Writer w;
    w.put("<TEI xmlns=\"http://www.tei-c.org/ns/1.0\">\n");
    w.put("  <teiHeader>\n");
    w.put("    <fileDesc>\n");
    w.put("      <titleStmt>\n        <title type=\"main\">");
    auto title = documentTitle(tree);
    w.put(title.length ? xmlText(title) : "Untitled document");
    w.put("</title>\n      </titleStmt>\n");
    w.put("      <publicationStmt>\n        <p/>\n      </publicationStmt>\n");
    w.put("      <sourceDesc>\n        <p/>\n      </sourceDesc>\n");
    w.put("    </fileDesc>\n");
    w.put("  </teiHeader>\n");
    w.put("  <text>\n    <body>\n");
    w.put("      <div type=\"entry\">\n");
    if (selection.status == MainContentStatus.selected)
        renderTeiContainer(tree, selection.node, w, 4, false);
    else if (selection.status == MainContentStatus.selectedStructuredData)
        renderFlatParagraphsXml(selection.text, w, 4, "p");
    w.put("      </div>\n");
    if (selection.commentsExtracted) {
        w.put("      <div type=\"comments\">\n");
        renderFlatParagraphsXml(selection.comments, w, 4, "p");
        w.put("      </div>\n");
    }
    w.put("    </body>\n  </text>\n</TEI>\n");
    return w.finish();
}

/// Same loose-content-preserving scan as `renderXmlContainer` (see its own
/// doc comment for the full rationale); TEI's `<p>` plays the role generic
/// XML's `<paragraph>` does for a flushed run of otherwise-unwrapped inline
/// content.
private void renderTeiContainer(const ref HtmlTree tree, size_t containerIndex,
        ref Writer w, size_t indent, bool inlineIsBare) pure {
    if (indent > 256) throw new ExtractFormatOutputLimit;
    string pad; foreach (_; 0 .. indent) pad ~= "  ";
    Writer pending;
    void flush() {
        if (!pending.bytes.length) return;
        auto content = pending.finish();
        if (!hasNonWhitespace(content)) return;
        if (inlineIsBare) w.put(content);
        else { w.put(pad); w.put("<p>"); w.put(content); w.put("</p>\n"); }
    }
    size_t containerEnd = endOf(tree, containerIndex);
    for (size_t i = containerIndex + 1; i < containerEnd; ) {
        ref const node = tree.nodes[i];
        if (node.kind == HtmlNodeKind.text || (node.kind == HtmlNodeKind.element &&
                inlineLeafTag(node.name))) {
            renderTeiInlineNode(tree, i, pending);
            i = endOf(tree, i);
            continue;
        }
        if (node.kind != HtmlNodeKind.element) { ++i; continue; }
        if (hiddenTag(node.name)) { i = endOf(tree, i); continue; }
        int level;
        if (headingLevel(node.name, level)) {
            flush();
            auto headingText = xmlText(singleLine(plainInlineText(tree, i)));
            if (headingText.length) {
                w.put(pad); w.put("<ab rend=\"h"); w.put(cast(string)[cast(char)('0' + level)]);
                w.put("\" type=\"header\">"); w.put(headingText); w.put("</ab>\n");
            }
            i = endOf(tree, i);
            continue;
        }
        if (node.name == "p") {
            flush();
            auto paragraph = renderTeiInlineToString(tree, i);
            if (hasNonWhitespace(paragraph)) {
                w.put(pad); w.put("<p>"); w.put(paragraph); w.put("</p>\n");
            }
            i = endOf(tree, i);
            continue;
        }
        if (node.name == "ul" || node.name == "ol") {
            flush();
            renderTeiList(tree, i, w, indent);
            i = endOf(tree, i);
            continue;
        }
        if (node.name == "blockquote") {
            flush();
            w.put(pad); w.put("<quote>\n");
            renderTeiContainer(tree, i, w, indent + 1, false);
            w.put(pad); w.put("</quote>\n");
            i = endOf(tree, i);
            continue;
        }
        if (node.name == "table") {
            flush();
            renderTeiTable(tree, i, w, indent);
            i = endOf(tree, i);
            continue;
        }
        if (node.name == "pre") {
            flush();
            // `<code>` is, like `<table>`/`<row>`/`<cell>` (see
            // `renderTeiTable`'s own doc comment), not declared at all in
            // this ticket's pinned trafilatura==2.2.0's bundled TEI DTD --
            // confirmed the same way: pinned trafilatura's own real
            // `<code>` output for a real `<pre>`-bearing page (this
            // ticket's own `venv.html` comparator fixture) fails its own
            // `validate_tei()`. `<hi rend="code">`, wrapped in a `<p>` so a
            // block-level code sample is still valid directly under
            // `<div>`, is real, DTD-declared, already-proven-valid markup
            // (this module's bold/italic `<hi>` already validates) that
            // keeps every real character of the code sample without
            // claiming an element this schema does not have.
            w.put(pad); w.put("<p><hi rend=\"code\">");
            w.put(xmlText(plainInlineText(tree, i)));
            w.put("</hi></p>\n");
            i = endOf(tree, i);
            continue;
        }
        ++i;
    }
    flush();
}

private void renderTeiList(const ref HtmlTree tree, size_t listIndex, ref Writer w, size_t indent) pure {
    string pad; foreach (_; 0 .. indent) pad ~= "  ";
    bool ordered = tree.nodes[listIndex].name == "ol";
    w.put(pad); w.put("<list rend=\""); w.put(ordered ? "ol" : "ul"); w.put("\">\n");
    size_t listEnd = endOf(tree, listIndex);
    for (size_t child = listIndex + 1; child < listEnd; child = endOf(tree, child)) {
        if (tree.nodes[child].parentIndex != listIndex) continue;
        if (tree.nodes[child].name != "li") continue;
        string itemPad; foreach (_; 0 .. indent + 1) itemPad ~= "  ";
        w.put(itemPad); w.put("<item>");
        bool hadNestedBlock;
        size_t itemEnd = endOf(tree, child);
        foreach (j; child + 1 .. itemEnd)
            if (tree.nodes[j].kind == HtmlNodeKind.element &&
                (tree.nodes[j].name == "ul" || tree.nodes[j].name == "ol" ||
                 tree.nodes[j].name == "p" || tree.nodes[j].name == "table" ||
                 tree.nodes[j].name == "blockquote")) { hadNestedBlock = true; break; }
        if (hadNestedBlock) {
            w.put("\n");
            renderTeiContainer(tree, child, w, indent + 2, true);
            w.put(itemPad);
        } else {
            renderTeiInline(tree, child, w);
        }
        w.put("</item>\n");
    }
    w.put(pad); w.put("</list>\n");
}

/// A real page's `<table>` degrades to `<list rend="table"><item>` (one
/// item per row, cells joined by " | ", a header cell wrapped in `<hi
/// rend="bold">`) rather than `<table>`/`<row>`/`<cell>`, on real, verified
/// evidence that this ticket's own pinned trafilatura==2.2.0's bundled TEI
/// schema (`tei_corpus.dtd`, the exact schema this module's own XML-TEI
/// output validates against -- see this module's own doc comment) has no
/// `<!ELEMENT table>`/`row`/`cell` declaration at all: a real table run
/// through pinned trafilatura's own `--output-format xmltei` emits exactly
/// those three tags, and pinned trafilatura's own `--validate-tei` (backed
/// by that same bundled DTD) then reports the result invalid --
/// `DTD_UNKNOWN_ELEM`/`DTD_CONTENT_MODEL` for `table`/`row`/`cell` --
/// confirmed by running the pinned CLI and its own `validate_tei()`
/// directly against a real table-bearing page, not assumed. That is a real,
/// pre-existing gap in trafilatura==2.2.0 itself (its own TEI_VALID_TAGS
/// whitelist accepts those tags at the application level; its own bundled
/// schema does not declare them at all), not something this ticket
/// introduces. Per this ticket's acceptance criterion 2 ("do not ship a
/// mode that claims TEI-conformance without having actually run a real
/// validator against it"), reproducing trafilatura's own tag choice here
/// would ship exactly that non-conforming mode for any table-bearing page
/// -- a real, common shape (see this ticket's own comparator evidence on
/// the ISO 8601 Wikipedia page). `<list>`/`<item>` are both real,
/// DTD-declared, already-proven-valid elements (this module's own list
/// rendering already validates), so this degrade keeps every real cell's
/// text (via the ordinary "no text loss" bar the rest of this module
/// holds), stays honest about the row/column grid it no longer represents
/// structurally in this one format, and -- unlike trafilatura's own
/// approach -- is real, verified TEI-conformant output. Generic XML
/// (`renderXmlTable`) is unaffected: it has no DTD to satisfy and keeps
/// full `<table>`/`<row>`/`<cell>` structure.
private void renderTeiTable(const ref HtmlTree tree, size_t tableIndex, ref Writer w, size_t indent) pure {
    string pad; foreach (_; 0 .. indent) pad ~= "  ";
    string itemPad; foreach (_; 0 .. indent + 1) itemPad ~= "  ";
    Writer body;
    bool anyRow;
    size_t tableEnd = endOf(tree, tableIndex);
    for (size_t i = tableIndex + 1; i < tableEnd; ++i) {
        ref const candidate = tree.nodes[i];
        if (candidate.kind != HtmlNodeKind.element) continue;
        if (candidate.name == "caption" && candidate.parentIndex == tableIndex) {
            auto captionText = renderTeiInlineToString(tree, i);
            if (hasNonWhitespace(captionText)) {
                body.put(itemPad); body.put("<item><hi rend=\"italic\">");
                body.put(captionText); body.put("</hi></item>\n");
                anyRow = true;
            }
            continue;
        }
        if (candidate.name != "tr") continue;
        size_t parent = candidate.parentIndex;
        bool ownRow;
        while (parent != size_t.max) {
            if (tree.nodes[parent].name == "table") { ownRow = parent == tableIndex; break; }
            parent = tree.nodes[parent].parentIndex;
        }
        if (!ownRow) continue;
        Writer row;
        bool firstCell = true;
        for (size_t child = i + 1; child < endOf(tree, i); child = endOf(tree, child)) {
            if (tree.nodes[child].parentIndex != i) continue;
            bool header = tree.nodes[child].name == "th";
            if (!header && tree.nodes[child].name != "td") continue;
            if (!firstCell) row.put(" | ");
            firstCell = false;
            bool hadBlock;
            size_t cellEnd = endOf(tree, child);
            foreach (j; child + 1 .. cellEnd)
                if (tree.nodes[j].kind == HtmlNodeKind.element &&
                    (tree.nodes[j].name == "table" || tree.nodes[j].name == "ul" ||
                     tree.nodes[j].name == "ol" || tree.nodes[j].name == "p" ||
                     tree.nodes[j].name == "blockquote")) { hadBlock = true; break; }
            // A cell with its own nested block content (most commonly a
            // nested table) is flattened to plain escaped text here rather
            // than nested `<list>`/`<quote>`/etc. inside this row's single
            // `<item>` -- an accepted, disclosed degrade one step below
            // this module's ordinary "keep real structure" bar, scoped
            // narrowly to the rare real shape of a block nested inside a
            // TEI table cell that itself had to degrade out of `<table>`/
            // `<row>`/`<cell>` already (see this function's own doc
            // comment); no real cell text is ever dropped either way.
            auto cellContent = hadBlock ? xmlText(singleLine(plainInlineText(tree, child))) :
                renderTeiInlineToString(tree, child);
            if (header) { row.put("<hi rend=\"bold\">"); row.put(cellContent); row.put("</hi>"); }
            else row.put(cellContent);
        }
        auto rowContent = row.finish();
        if (hasNonWhitespace(rowContent)) {
            body.put(itemPad); body.put("<item>"); body.put(rowContent); body.put("</item>\n");
            anyRow = true;
        }
    }
    if (!anyRow) return;
    w.put(pad); w.put("<list rend=\"table\">\n");
    w.put(body.finish());
    w.put(pad); w.put("</list>\n");
}

private string renderTeiInlineToString(const ref HtmlTree tree, size_t index) pure {
    Writer w;
    renderTeiInline(tree, index, w);
    return w.finish();
}

private void renderTeiInline(const ref HtmlTree tree, size_t parent, ref Writer w) pure {
    for (size_t child = parent + 1; child < endOf(tree, parent); child = endOf(tree, child)) {
        if (tree.nodes[child].parentIndex != parent) continue;
        renderTeiInlineNode(tree, child, w);
    }
}

private void renderTeiInlineNode(const ref HtmlTree tree, size_t index, ref Writer w) pure {
    ref const node = tree.nodes[index];
    if (node.kind == HtmlNodeKind.text) { w.put(xmlText(node.text)); return; }
    if (hiddenTag(node.name)) return;
    if (node.name == "br") { w.put("<lb/>"); return; }
    if (node.name == "img") {
        // The real TEI DTD declares `@url` as `#REQUIRED` on `<graphic>`
        // (`att.resourced.attribute.url`, confirmed by reading the pinned
        // trafilatura==2.2.0 package's own bundled `tei_corpus.dtd` and by
        // running the real DTD validator against a candidate `<graphic
        // target="...">` -- rejected with `DTD_MISSING_ATTRIBUTE`/
        // `DTD_UNKNOWN_ATTRIBUTE` -- before landing on `url`, which
        // validates; see this ticket's own comparator evidence). Unlike
        // `<ref target="...">`, there is no valid-attribute fallback that
        // preserves an unsafe/missing source: a `<graphic>` with no `url`
        // is not valid TEI at all, so this element is simply omitted
        // (rather than emitted invalid, or emitted with an unsafe target)
        // when there is no safe image source, an accepted, disclosed
        // degrade for that one real shape.
        auto src = attribute(node, "src");
        if (safeTarget(src)) { w.put("<graphic url=\""); w.put(xmlAttr(src)); w.put("\"/>"); }
        return;
    }
    if (node.name == "code") {
        // Not declared in this ticket's pinned trafilatura==2.2.0's own
        // bundled TEI DTD either -- see `renderTeiContainer`'s block `pre`
        // handling for the confirming evidence; `<hi rend="code">` is the
        // same real, DTD-valid degrade, used here for inline code.
        w.put("<hi rend=\"code\">"); w.put(xmlText(singleLine(plainInlineText(tree, index)))); w.put("</hi>");
        return;
    }
    if (node.name == "strong" || node.name == "b") {
        w.put("<hi rend=\"bold\">"); renderTeiInline(tree, index, w); w.put("</hi>");
        return;
    }
    if (node.name == "em" || node.name == "i") {
        w.put("<hi rend=\"italic\">"); renderTeiInline(tree, index, w); w.put("</hi>");
        return;
    }
    if (node.name == "a") {
        auto href = attribute(node, "href");
        const safe = safeTarget(href);
        if (safe) { w.put("<ref target=\""); w.put(xmlAttr(href)); w.put("\">"); }
        renderTeiInline(tree, index, w);
        if (safe) w.put("</ref>");
        return;
    }
    renderTeiInline(tree, index, w);
}

// ==== CSV ==================================================================

/// One metadata/content row per document, columns and tab delimiter
/// matching pinned trafilatura==2.2.0's own real `--output-format csv`
/// shape exactly (`trafilatura.xml.xmltocsv`: `url, id, fingerprint,
/// hostname, title, image, date, text, comments, license, pagetype`,
/// `\t`-delimited, `"null"` for an absent field -- confirmed by reading
/// that exact pinned version's installed source and by running its CLI
/// against real pages, not guessed; see this module's own doc comment and
/// `compare_trafilatura_extract_formats.sh`). `text`/`comments` reuse
/// `extractMainContent`'s already-tested flat plain text/comment fields
/// directly (the same boundary `main-content-markdown` and plain
/// `html-main-content` both already depend on) rather than re-deriving
/// them from a tree walk here -- deliberately the simplest, most reused,
/// least-new-surface-area path to a correct `text` column, and (like the
/// rest of this module) never touches `html_markdown.d`'s rendered
/// Markdown text at all, so issue #493 cannot reach it.
///
/// A page's `<table>`s are not separately re-encoded into their own CSV
/// rows/columns: `extractMainContent`'s flat text already folds a table's
/// cell text into the same whitespace-collapsed prose as everything else
/// in the selected subtree, and that text -- however it reads -- is what
/// actually round-trips: quoted per RFC 4180 whenever it contains this
/// format's own delimiter (a literal tab), a double quote, or a newline,
/// and recoverable byte-for-byte by a real CSV parser (verified with
/// Python's `csv` module against a real page with a real multi-row/
/// multi-column table plus quote/newline-bearing cell text -- see this
/// ticket's own round-trip evidence). A one-table-becomes-N-CSV-rows
/// design was considered and rejected: pinned trafilatura's own real CSV
/// output does not do this either (it is a document-metadata export
/// format, not a per-table tabular dump), a page can have more than one
/// table with no well-defined "the" table to promote to top-level rows,
/// and the chosen design still round-trips every real character a table
/// contributes -- just as one already-tested flat-text field, not as a
/// second, harder-to-get-right serialization this ticket does not require.
string csvRow(const ref HtmlTree tree) pure {
    auto selection = extractMainContent(tree);
    string title = documentTitle(tree);
    string[] fields = [
        null, // url: not available from a local-file `extract` invocation
        null, // id
        null, // fingerprint
        null, // hostname
        title,
        null, // image
        null, // date
        selection.text,
        selection.commentsExtracted ? selection.comments : null,
        null, // license
        null, // pagetype
    ];
    Writer w;
    foreach (i, field; fields) {
        if (i) w.put("\t");
        w.put(csvField(field));
    }
    w.put("\n");
    return w.finish();
}

version (unittest) {
    /// Well-formedness proof for this module's own unittests: fully
    /// consumes `xml` with dxml's real streaming parser (already a pinned
    /// dependency of this repository -- `dxml==0.4.5` in `dub.json`, used
    /// elsewhere by `source/extraction/ooxml_document.d`) rather than
    /// hand-rolling a bespoke well-formedness check; `parseXML` throws
    /// `dxml.parser.XMLParsingException` on anything malformed, which
    /// surfaces as an ordinary failed unittest.
    private void assertWellFormedXml(string xml) {
        import dxml.parser : parseXML, simpleXML;
        foreach (node; parseXML!simpleXML(xml)) {}
    }
}

private bool csvNeedsQuoting(string field) pure {
    foreach (c; field)
        if (c == '\t' || c == '"' || c == '\n' || c == '\r') return true;
    return false;
}

private string csvField(string field) pure {
    if (!field.length) return "null";
    if (!csvNeedsQuoting(field)) return field;
    Writer w;
    w.put("\"");
    size_t runStart;
    foreach (i, c; field) {
        if (c != '"') continue;
        w.put(field[runStart .. i + 1]);
        w.put("\""); // double an embedded quote (RFC 4180)
        runStart = i + 1;
    }
    w.put(field[runStart .. $]);
    w.put("\"");
    return w.finish();
}

unittest {
    // A page's real, structural content (headings/paragraphs/lists/tables/
    // quotes/links/images/code) round-trips into well-formed generic XML
    // with the schema this module documents.
    import effects.html_tree : parseHtml;
    import std.algorithm.searching : canFind;

    auto outcome = parseHtml(cast(const(ubyte)[]) (
        "<nav>Home About Contact</nav><article><h1>Field notes</h1>" ~
        "<p>The survey team spent three weeks mapping the delta with " ~
        "<a href=\"https://example.com/survey\">real instruments</a> and " ~
        "<strong>careful</strong> notes, recording every transect in detail.</p>" ~
        "<ul><li>First observation about the delta survey work.</li>" ~
        "<li>Second observation about the delta survey work.</li></ul>" ~
        "<blockquote><p>A quoted remark about the delta survey team.</p></blockquote>" ~
        "<table><caption>Transect data</caption><tr><th>Transect</th><th>Depth</th></tr>" ~
        "<tr><td>1</td><td>2m</td></tr></table>" ~
        "<pre>plain code text</pre></article>"));
    assert(outcome.isParsed);
    auto tree = outcome.tree;

    auto xml = renderXml(tree);
    assert(xml.canFind("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"));
    assert(xml.canFind("<heading level=\"1\">Field notes</heading>"));
    assert(xml.canFind("<link href=\"https://example.com/survey\">real instruments</link>"));
    assert(xml.canFind("<bold>careful</bold>"));
    assert(xml.canFind("<list ordered=\"false\">"));
    assert(xml.canFind("<item>First observation about the delta survey work.</item>"));
    assert(xml.canFind("<quote>"));
    assert(xml.canFind("A quoted remark about the delta survey team."));
    assert(xml.canFind("<caption>Transect data</caption>"));
    assert(xml.canFind("<cell header=\"true\">Transect</cell>"));
    assert(xml.canFind("<cell>1</cell>"));
    assert(xml.canFind("<code>plain code text</code>"));
    assert(!xml.canFind("Home") && !xml.canFind("Contact"),
        "boilerplate nav must not leak into the selected content");

    assertWellFormedXml(xml);
}

unittest {
    // Nested table: a real, well-formed nested `<table>` element inside a
    // `<cell>`, never a flattened/escaped string -- the structural argument
    // for why issue #493 cannot reach this module, made concrete.
    import effects.html_tree : parseHtml;
    import std.algorithm.searching : canFind;

    string longParagraph;
    foreach (_; 0 .. 25) longParagraph ~= "Article body sentence. ";
    auto outcome = parseHtml(cast(const(ubyte)[]) (
        "<article><h1>Nested table page</h1><p>" ~ longParagraph ~ "</p>" ~
        "<table><tr><th>Outer</th></tr>" ~
        "<tr><td>before<table><tr><th>Inner</th></tr>" ~
        "<tr><td>innerdata</td></tr></table>after</td></tr></table></article>"));
    assert(outcome.isParsed);
    auto tree = outcome.tree;
    auto xml = renderXml(tree);
    assertWellFormedXml(xml);
    assert(xml.canFind("<cell header=\"true\">Outer</cell>"));
    assert(xml.canFind("<table>\n"));
    // The inner table is a real nested <table> child of the outer <cell>,
    // not a flattened string -- no stray delimiter syntax of any kind is
    // possible in XML, so there is nothing analogous to #493's `|---|`
    // fragment to assert the absence of; instead assert the real structural
    // property #493 broke: every one of the four distinct real text pieces
    // is present exactly once, and the inner table's own real nested
    // `<table>` element is present as a child, not merged into the outer
    // cell's text.
    assert(xml.canFind("<cell header=\"true\">Inner</cell>"));
    assert(xml.canFind("<cell>innerdata</cell>"));
    assert(xml.canFind("before"), "loose text alongside a nested table must not be dropped");
    assert(xml.canFind("after"), "loose text alongside a nested table must not be dropped");
}

unittest {
    // XML-TEI: the fixed, DTD-required shape (teiHeader/text/body/div) plus
    // the same structural richness, using trafilatura's own confirmed-real
    // tag vocabulary (`ab`/`p`/`list`/`item`/`quote`/`table`/`row`/`cell`/
    // `ref`/`hi`/`code`). Real DTD validation itself is exercised by
    // `experiments/html_main_content/compare_trafilatura_extract_formats.sh`
    // (a `pure` D unittest cannot shell out to the pinned Python validator);
    // this proves the D-side shape and escaping this module controls.
    import effects.html_tree : parseHtml;
    import std.algorithm.searching : canFind;

    string longParagraph;
    foreach (_; 0 .. 25) longParagraph ~= "Article body sentence. ";
    auto outcome = parseHtml(cast(const(ubyte)[]) (
        "<nav>Home About Contact</nav><article><h1>Field notes</h1>" ~
        "<p>" ~ longParagraph ~ "Survey text with " ~
        "<a href=\"https://example.com/x\">a link</a>.</p>" ~
        "<h2>Sub-section</h2><ul><li>One</li><li>Two</li></ul>" ~
        "<table><tr><th>A</th></tr><tr><td>1</td></tr></table></article>"));
    assert(outcome.isParsed);
    auto tree = outcome.tree;
    auto tei = renderXmlTei(tree);
    assert(tei.canFind("<TEI xmlns=\"http://www.tei-c.org/ns/1.0\">"));
    assert(tei.canFind("<div type=\"entry\">"));
    assert(tei.canFind("<ab rend=\"h1\" type=\"header\">Field notes</ab>"));
    assert(tei.canFind("<ab rend=\"h2\" type=\"header\">Sub-section</ab>"),
        "every heading, not only the first, must use <ab>, never a body <head>");
    assert(tei.canFind("<ref target=\"https://example.com/x\">a link</ref>"));
    assert(tei.canFind("<list rend=\"ul\">"));
    // A table degrades to `<list rend="table">` in TEI, never `<table>`/
    // `<row>`/`<cell>` (this ticket's pinned trafilatura==2.2.0's own
    // bundled TEI DTD has no declaration for those three elements at all --
    // see `renderTeiTable`'s own doc comment).
    assert(tei.canFind("<list rend=\"table\">"));
    assert(!tei.canFind("<table>") && !tei.canFind("<row>") && !tei.canFind("<cell"));
    assert(tei.canFind("<hi rend=\"bold\">A</hi>"), "a header cell keeps its real text, bolded");
    assert(tei.canFind("<item>1</item>"), "a data-only row keeps its real cell text");
    assert(!tei.canFind("Home") && !tei.canFind("Contact"));

    assertWellFormedXml(tei);
}

unittest {
    // Regression guard for issue #496: mutation testing found that breaking
    // `xmlText`'s `&`/`<`/`>` escaping of real body text is caught by
    // neither this module's other unittests above nor the pinned-trafilatura
    // held-out corpus evidence script, because none of those 20 real pages'
    // selected body text happens to contain a literal `<`/`>` character.
    // This fixture's heading and paragraph carry all three characters (via
    // real HTML entities in the source, which `parseHtml` decodes to the
    // literal characters `xmlText` must then re-escape) so both `renderXml`
    // and `renderXmlTei` are forced through that path. `assertWellFormedXml`
    // alone already makes this mutation-testable: a raw, un-escaped `<` or
    // `>` emitted into XML text content is not well-formed XML, so
    // `dxml.parser.parseXML` throws and the unittest fails -- but the
    // `canFind` assertions below additionally pin the exact expected
    // escaped substrings, so a *double*-escaping mutation (e.g. reordering
    // the `&` case to run after `<`/`>`, escaping the `&` inside an
    // already-emitted `&lt;`/`&gt;` a second time) is also caught even
    // though its output would still be well-formed XML.
    import effects.html_tree : parseHtml;
    import std.algorithm.searching : canFind;

    string longParagraph;
    foreach (_; 0 .. 25) longParagraph ~= "Article body sentence. ";
    auto outcome = parseHtml(cast(const(ubyte)[]) (
        "<article><h1>Rules &amp; Regulations &lt;Draft&gt;</h1><p>" ~ longParagraph ~
        "The final comparison showed 5 &lt; 10 and 10 &gt; 3, and the committee " ~
        "reviewed rules &amp; regulations before closing the discussion.</p></article>"));
    assert(outcome.isParsed);
    auto tree = outcome.tree;

    auto xml = renderXml(tree);
    assert(xml.canFind("<heading level=\"1\">Rules &amp; Regulations &lt;Draft&gt;</heading>"),
        "heading text must be XML-escaped, not left with raw &/</>");
    assert(xml.canFind("5 &lt; 10 and 10 &gt; 3"),
        "paragraph text's numeric comparisons must be XML-escaped");
    assert(xml.canFind("reviewed rules &amp; regulations"),
        "paragraph text's literal & must be XML-escaped");
    assertWellFormedXml(xml);

    auto tei = renderXmlTei(tree);
    assert(tei.canFind("<ab rend=\"h1\" type=\"header\">Rules &amp; Regulations &lt;Draft&gt;</ab>"),
        "TEI heading text must be XML-escaped, not left with raw &/</>");
    assert(tei.canFind("5 &lt; 10 and 10 &gt; 3"),
        "TEI paragraph text's numeric comparisons must be XML-escaped");
    assert(tei.canFind("reviewed rules &amp; regulations"),
        "TEI paragraph text's literal & must be XML-escaped");
    assertWellFormedXml(tei);
}

unittest {
    // Regression guard for issue #533: a hidden `<script>`/`<style>` element
    // encountered mid-container by `renderXmlContainer` (XML) /
    // `renderTeiContainer` (XML-TEI) must be skipped by its *entire subtree*
    // via `endOf(tree, i)`, not merely its own node via `++i`. The bug
    // (`++i`) only advances past the `<script>`/`<style>` element node
    // itself; the loop's very next iteration then lands on that element's
    // own text-node child and, since a bare text node is ordinary loose
    // inline content as far as the scan is concerned, folds it straight into
    // the surrounding `<paragraph>`/`<p>` -- leaking script/style text into
    // the extracted body. This fixture places a `<script>` and a `<style>`
    // between two real paragraphs (mirroring the ticket's adversarial
    // `links.html` reproduction) so both the "hidden element followed by
    // more real content" shape and both element names are covered, for both
    // the XML and the XML-TEI code paths (two distinct `renderXmlContainer`
    // and `renderTeiContainer` call sites, hence two separate assertion
    // groups below rather than one).
    import effects.html_tree : parseHtml;
    import std.algorithm.searching : canFind;

    string longParagraph;
    foreach (_; 0 .. 25) longParagraph ~= "Article body sentence. ";
    auto outcome = parseHtml(cast(const(ubyte)[]) (
        "<article><h1>Field notes</h1><p>" ~ longParagraph ~ "</p>" ~
        "<script>var s=\"SCRIPT\";.x{}</script>" ~
        "<p>" ~ longParagraph ~ "</p>" ~
        "<style>.y{color:red}</style></article>"));
    assert(outcome.isParsed);
    auto tree = outcome.tree;

    auto xml = renderXml(tree);
    assertWellFormedXml(xml);
    assert(!xml.canFind("SCRIPT"), "script element text must not leak into XML output");
    assert(!xml.canFind(".x{}"), "script element text must not leak into XML output");
    assert(!xml.canFind(".y{color:red}"), "style element text must not leak into XML output");

    auto tei = renderXmlTei(tree);
    assertWellFormedXml(tei);
    assert(!tei.canFind("SCRIPT"), "script element text must not leak into TEI output");
    assert(!tei.canFind(".x{}"), "script element text must not leak into TEI output");
    assert(!tei.canFind(".y{color:red}"), "style element text must not leak into TEI output");
}

unittest {
    // Abstention: no selectable content, so `<main>`/`<div type="entry">`
    // stay empty rather than fabricating structure -- mirrors
    // `MainContentResult.text`'s own empty-on-abstention behavior.
    import effects.html_tree : HtmlNode, HtmlNodeKind;
    import std.algorithm.searching : canFind;

    HtmlTree nav;
    nav.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "nav", null, null),
        HtmlNode(HtmlNodeKind.text, 0, null, "Home About Contact"),
    ];
    auto xml = renderXml(nav);
    assert(xml.canFind("<main>\n  </main>"));
    auto tei = renderXmlTei(nav);
    assert(tei.canFind("<div type=\"entry\">\n      </div>"));
}

unittest {
    // CSV: real column order/delimiter/null-convention match, `text`/
    // `comments` reuse `extractMainContent` verbatim, and a real CSV
    // round-trip (Phobos has no CSV parser; this module's own bounded
    // `csvField` quoting is exercised directly and independently by a real
    // Python `csv` module round-trip in `compare_trafilatura_extract_
    // formats.sh` and `check.d`'s own comparator evidence).
    import effects.html_tree : parseHtml;
    import std.algorithm.searching : canFind, count;
    import std.string : split;

    string longParagraph;
    foreach (_; 0 .. 25) longParagraph ~= "Article body sentence. ";
    auto outcome = parseHtml(cast(const(ubyte)[]) (
        "<html><head><title>A Real Title</title></head><body><nav>Home</nav>" ~
        "<article><h1>Heading</h1><p>" ~ longParagraph ~ "</p></article></body></html>"));
    assert(outcome.isParsed);
    auto tree = outcome.tree;
    auto row = csvRow(tree);
    auto columns = row[0 .. $ - 1].split("\t"); // strip the trailing "\n"
    assert(columns.length == 11, "must match trafilatura's own real 11-column schema");
    assert(columns[0] == "null" && columns[1] == "null" && columns[2] == "null" &&
        columns[3] == "null", "url/id/fingerprint/hostname are unavailable in local extract");
    assert(columns[4] == "A Real Title", "a real <title> must populate the title column");
    assert(columns[5] == "null" && columns[6] == "null");
    assert(columns[7].canFind("Article body sentence"), "text column carries the real flat content");
    assert(columns[8] == "null", "no comment section on this fixture");
    assert(columns[9] == "null" && columns[10] == "null");

    // Round-trip stress: a field containing a literal double quote and this
    // format's own tab delimiter must be quoted, with the quote doubled,
    // exactly per RFC 4180, so a real parser recovers it byte-for-byte.
    auto quoted = csvField("has\ttab and a \"quote\" inside");
    assert(quoted == "\"has\ttab and a \"\"quote\"\" inside\"");
    assert(csvField("plain") == "plain");
    assert(csvField(null) == "null");
}
