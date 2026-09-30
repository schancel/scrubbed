/// Bounded mechanical Markdown rendering of the D-owned selected HTML tree.
module effects.html_markdown;

import effects.html_tree : HtmlNode, HtmlNodeKind, HtmlTree;
import std.conv : to;
import std.exception : assumeUnique;
import std.uni : isControl, isFormat, isSpace;
import std.utf : UTFException, encode;

enum size_t maxMarkdownBytes = 4 * 1024 * 1024;
private enum string maxListIndent = "                     "; // 19 digits plus ". "

class HtmlMarkdownOutputLimit : Exception {
    this() pure { super("Markdown output exceeds 4 MiB"); }
}

private struct Writer {
    char[] bytes;
    version (unittest) size_t putCalls;
    version (unittest) size_t lastPutLength;

    void put(scope const(char)[] value) pure {
        if (value.length > maxMarkdownBytes - bytes.length)
            throw new HtmlMarkdownOutputLimit;
        version (unittest) {
            ++putCalls;
            lastPutLength = value.length;
        }
        bytes ~= value;
    }

    size_t putDecimal(ulong value) pure {
        char[ulong.sizeof * 3] digits;
        size_t start = digits.length;
        do {
            digits[--start] = cast(char)('0' + value % 10);
            value /= 10;
        } while (value);
        auto length = digits.length - start;
        put(digits[start .. $]);
        return length;
    }

    void putText(string value) pure {
        if (value.length && bytes.length && bytes[$ - 1] == ' ' &&
            value[0] == ' ') put(value[1 .. $]);
        else put(value);
    }

    void trim() pure {
        while (bytes.length && (bytes[$ - 1] == ' ' || bytes[$ - 1] == '\n'))
            bytes.length--;
    }

    void block() pure {
        trim();
        if (bytes.length) put("\n\n");
    }

    // bytes starts empty, is only grown internally, and is consumed here.
    string finish() pure nothrow {
        if (!bytes.length) {
            bytes = null;
            return null;
        }
        return assumeUnique(bytes);
    }
}

unittest {
    Writer writer;
    writer.put("complete");
    auto storage = writer.bytes.ptr;
    auto finished = writer.finish();
    assert(finished == "complete");
    assert(finished.ptr == storage);
    assert(writer.bytes is null);
    writer.put("new");
    assert(finished == "complete");

    writer.bytes.length = 0;
    assert(writer.finish() is null);
    assert(writer.bytes is null);

    foreach (value; [ulong(0), 9, 10, 99, 100, cast(ulong)long.max]) {
        Writer decimal;
        auto length = decimal.putDecimal(value);
        assert(decimal.bytes == value.to!string);
        assert(length == decimal.bytes.length && decimal.putCalls == 1 &&
            decimal.lastPutLength == decimal.bytes.length);
    }
    Writer exactFit;
    exactFit.bytes.length = maxMarkdownBytes - 3;
    assert(exactFit.putDecimal(100) == 3);
    assert(exactFit.bytes.length == maxMarkdownBytes);
    Writer oneOver;
    oneOver.bytes.length = maxMarkdownBytes - 2;
    import std.exception : assertThrown;
    assertThrown!HtmlMarkdownOutputLimit(oneOver.putDecimal(100));
}

private bool white(char c) pure {
    return c == ' ' || c == '\n' || c == '\r' || c == '\t' || c == '\f';
}

// Exported (not just module-private) so `html_main_content_markdown.d` can
// apply this exact same literal-character escaping (backslash-escaping
// Markdown-significant punctuation, `&`/`<`/`>` entity-escaping, whitespace
// collapsing) to `selectedStructuredData`'s recovered plain text -- text
// that never passes through `renderNode`/`renderMarkdownFrom` at all
// (issue #411's JSON-LD fallback has no tree node to render from). Using
// this same helper, rather than a second hand-written equivalent, is what
// keeps escaping identical between the two Markdown-producing paths; see
// `html_main_content_markdown.d`'s own doc comment for that decision.
// Behavior is completely unchanged -- only the access modifier moved.
string clean(string input, bool code = false) pure {
    Writer writer;
    bool pending;
    foreach (dchar c; input) {
        if (code) {
            if (c == '\r') c = '\n';
            if (c == '\n' || c == '\t' || c == 0x2028 || c == 0x2029) {
                writer.put(c == '\t' ? "\t" : "\n");
                continue;
            }
            if (isControl(c) || isFormat(c)) continue;
            char[4] encoded;
            writer.put(cast(string)encoded[0 .. encode(encoded, c)]);
            continue;
        }
        if (isControl(c) || isFormat(c)) continue;
        if (isSpace(c) || c == 0x2028 || c == 0x2029) {
            pending = true;
            continue;
        }
        if (pending) writer.put(" ");
        pending = false;
        switch (c) {
        case '\\': case '`': case '*': case '_': case '{': case '}':
        case '[': case ']': case '(': case ')': case '#': case '+':
        case '-': case '.': case '!': case '|': case '~':
            writer.put("\\"); break;
        case '&': writer.put("&amp;"); continue;
        case '<': writer.put("&lt;"); continue;
        case '>': writer.put("&gt;"); continue;
        default: break;
        }
        char[4] encoded;
        writer.put(cast(string)encoded[0 .. encode(encoded, c)]);
    }
    if (pending) writer.put(" ");
    return writer.finish();
}

private string singleLine(string input) pure {
    Writer writer;
    bool pending;
    size_t runStart;
    foreach (i, c; input) {
        if (white(c)) {
            if (!pending) writer.put(input[runStart .. i]);
            pending = true;
        } else if (pending) {
            if (writer.bytes.length) writer.put(" ");
            pending = false;
            runStart = i;
        }
    }
    if (!pending) writer.put(input[runStart .. $]);
    return writer.finish();
}

unittest {
    assert(singleLine("") is null);
    assert(singleLine(" \t\r\n\f") is null);
    assert(singleLine("  alpha \t beta\r\n gamma  ") == "alpha beta gamma");
    assert(singleLine("é\t界") == "é 界");
}

private string attribute(const ref HtmlNode node, string name) pure {
    foreach (ref const attr; node.attributes)
        if (attr.name == name) return attr.value;
    return null;
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

private bool safeScheme(string scheme) pure nothrow @nogc {
    switch (scheme.length) {
        case 4: return asciiEqualIgnoreCase(scheme, "http");
        case 5: return asciiEqualIgnoreCase(scheme, "https");
        case 6: return asciiEqualIgnoreCase(scheme, "mailto");
        default: return false;
    }
}

private bool safeTarget(string target) pure {
    if (!target.length || target.length > 4096 || target.length >= 2 &&
        (target[0 .. 2] == "//" || target[0 .. 2] == "\\\\")) return false;
    if (target[0] == '\\') return false;
    try {
        foreach (dchar c; target)
            if (isControl(c) || isFormat(c) || isSpace(c) ||
                c == '<' || c == '>' || c == '\\') return false;
    } catch (UTFException) return false;
    size_t colon;
    while (colon < target.length && target[colon] != ':' &&
        target[colon] != '/' && target[colon] != '?' && target[colon] != '#') ++colon;
    if (colon < target.length && target[colon] == ':')
        return safeScheme(target[0 .. colon]);
    return true;
}

unittest {
    void checkSchemeCaseVariants(string spelling) {
        foreach (mask; 0 .. 1 << spelling.length) {
            auto variant = spelling.dup;
            foreach (i, ref c; variant)
                if (mask & (1 << i)) c -= 'a' - 'A';
            auto target = variant ~ ":x";
            assert(safeTarget(cast(string) target));
        }
    }

    checkSchemeCaseVariants("http");
    checkSchemeCaseVariants("https");
    checkSchemeCaseVariants("mailto");
    assert(!safeTarget("httq:x"));
    assert(!safeTarget("httpss:x"));
    assert(!safeTarget("http1:x"));
    assert(!safeTarget("h\u00e9tp:x"));
}

private string markdownTarget(string target) pure {
    Writer writer;
    size_t runStart;
    foreach (i, c; target) {
        if (c != '&') continue;
        if (runStart < i) writer.put(target[runStart .. i]);
        writer.put("&amp;");
        runStart = i + 1;
    }
    if (runStart < target.length) writer.put(target[runStart .. $]);
    return writer.finish();
}

unittest {
    assert(markdownTarget("") is null);
    assert(markdownTarget("plain/é") == "plain/é");
    assert(markdownTarget("&a&&b&") == "&amp;a&amp;&amp;b&amp;");
}

private size_t endOf(const ref HtmlTree tree, size_t index) pure {
    size_t end = index + 1;
    while (end < tree.nodes.length) {
        size_t parent = tree.nodes[end].parentIndex;
        bool descendant;
        while (parent != size_t.max && parent < end) {
            if (parent == index) { descendant = true; break; }
            parent = tree.nodes[parent].parentIndex;
        }
        if (!descendant) break;
        ++end;
    }
    return end;
}

private string nodeText(const ref HtmlTree tree, size_t index) pure {
    Writer writer;
    foreach (i; index + 1 .. endOf(tree, index)) {
        bool breakNode = tree.nodes[i].kind == HtmlNodeKind.element &&
            tree.nodes[i].name == "br";
        if (tree.nodes[i].kind != HtmlNodeKind.text && !breakNode) continue;
        bool hidden;
        for (size_t parent = tree.nodes[i].parentIndex;
             parent != index && parent != size_t.max && parent < i;
             parent = tree.nodes[parent].parentIndex) {
            auto name = tree.nodes[parent].name;
            if (name == "script" || name == "style" || name == "template" ||
                name == "head") { hidden = true; break; }
        }
        if (!hidden) writer.put(breakNode ? "\n" : tree.nodes[i].text);
    }
    return writer.finish();
}

private size_t longestRun(string value, char marker) pure {
    size_t current, longest;
    foreach (char c; value) {
        current = c == marker ? current + 1 : 0;
        if (current > longest) longest = current;
    }
    return longest;
}

/// Independently-toggleable structural fidelity for a Markdown render:
/// whether inline emphasis (bold/italic), link targets, image sources,
/// tables, lists, blockquotes, and code blocks are preserved as real
/// Markdown syntax, or flattened to plain text/prose. Issue #477
/// (trafilatura-parity `--formatting`/`--links`/`--images`) added the first
/// three fields; issue #478 (trafilatura-parity `--no-tables`-shaped
/// block-level fidelity) added `tables`/`lists`/`quotes`/`code`.
///
/// All seven default `true`. Unlike trafilatura -- where `--formatting`/
/// `--links`/`--images` opt a stripped-by-default renderer INTO richness,
/// and `--no-tables` is the only block-level opt-OUT it exposes at all (it
/// has no equivalent `--no-lists`/`--no-quotes`/`--no-code`) -- every field
/// here opts an already-rich-by-default renderer OUT of one dimension of
/// fidelity, matching this struct's own pre-existing (#477) polarity for
/// consistency: a caller who explicitly wants plainer output flips a field
/// off, rather than a second, differently-polarized options mechanism
/// existing alongside this one. See this module's doc comment / the issue
/// #477 PR description for the fuller inline-fidelity tradeoff.
///
/// Disabling a dimension degrades to a plain-text/prose fallback that keeps
/// the real content and loses only the Markdown syntax marking its
/// structure -- never drops text outright. This mirrors trafilatura's own
/// opt-out *shape* (`--no-tables`), not its exact opt-out *semantics*:
/// trafilatura's `--no-tables` discards table content at extraction time
/// (confirmed against pinned trafilatura==2.2.0 -- see this module's table
/// fixture), whereas every field here is a rendering-only degrade, matching
/// this struct's own pre-existing `formatting`/`links`/`images` precedent
/// (an unsafe link/image target already degrades to plain visible text with
/// no `[...](...)`/`![...](...)` wrapping; `formatting=false` unwraps
/// `strong`/`b`/`em`/`i` the same way any other unrecognized inline element
/// already unwraps). Concretely: `tables=false` renders each row as a
/// plain `- cell | cell` line (this renderer's pre-#478 table behavior,
/// kept as the graceful degrade rather than trafilatura's outright drop);
/// `lists=false` renders each (possibly nested) list item as its own plain
/// paragraph with no bullet/number marker; `quotes=false` renders a
/// blockquote's content as a plain paragraph with no `> ` marker;
/// `code=false` renders `pre`/`code` content as ordinary prose text (normal
/// whitespace collapsing and literal-character escaping), with no fence or
/// backtick delimiters.
struct MarkdownRenderOptions {
    bool formatting = true;
    bool links = true;
    bool images = true;
    bool tables = true;
    bool lists = true;
    bool quotes = true;
    bool code = true;
}

private void renderChildren(const ref HtmlTree tree, size_t parent,
    ref Writer writer, size_t depth, const ref MarkdownRenderOptions options,
    bool inCell = false) pure;

private void renderTable(const ref HtmlTree tree, size_t tableIndex,
    ref Writer writer, size_t depth, const ref MarkdownRenderOptions options) pure;

// `inCell` marks that `writer` is accumulating content that a caller further
// up the stack (a `renderTable` data/header cell, or an already-flattened
// nested table/row reached via this same flag) will pass through
// `singleLine()` and fold into ONE GFM table cell. `singleLine()` only
// collapses whitespace/newlines -- it does not escape `|`/`-`, so any real
// pipe-table syntax (`renderTable`'s own `| ... |` / `|---|` literals, or
// the plain-bullet-row bare `- `/` | ` literals below) written into that
// Writer would land as an unescaped, structurally-significant fragment
// inside the OUTER cell, corrupting its GFM (issue #493: a nested `<table>`
// produced exactly this -- a stray `|---|` delimiter-row fragment bleeding
// into the outer table's data cell). Ordinary text content is unaffected:
// `clean()` already backslash-escapes a literal `|`/`-` in real text, so
// only the renderer's OWN literal structural characters are the hazard.
// While `inCell` is set, `table` and `tr` nodes take a degraded, inert path
// (see their branches below) instead of emitting that literal syntax, and
// every recursive call propagates `inCell` unchanged so a table nested
// arbitrarily deep inside a cell (e.g. `<td><div><table>...`) degrades the
// same way rather than reverting to real table syntax one level down.
private void renderNode(const ref HtmlTree tree, size_t index,
    ref Writer writer, size_t depth, const ref MarkdownRenderOptions options,
    bool inCell = false) pure {
    if (depth > 128) throw new HtmlMarkdownOutputLimit;
    ref const node = tree.nodes[index];
    if (node.kind == HtmlNodeKind.text) {
        writer.putText(clean(node.text));
        return;
    }
    string name = node.name;
    if (name == "script" || name == "style" || name == "template" ||
        name == "head") return;
    if (name == "br") { writer.put("  \n"); return; }
    if (name == "img") {
        auto alt = clean(attribute(node, "alt"));
        if (options.images) {
            auto src = attribute(node, "src");
            if (safeTarget(src)) {
                writer.put("![");
                writer.put(alt);
                writer.put("](<");
                writer.put(markdownTarget(src));
                writer.put(">)");
                return;
            }
        }
        writer.putText(alt);
        return;
    }
    if (name == "pre" && options.code) {
        auto content = clean(nodeText(tree, index), true);
        auto fenceLength = longestRun(content, '`') + 1;
        if (fenceLength < 3) fenceLength = 3;
        auto fence = new char[fenceLength];
        fence[] = '`';
        writer.block();
        writer.put(fence);
        writer.put("\n");
        writer.put(content);
        if (!content.length || content[$ - 1] != '\n') writer.put("\n");
        writer.put(fence);
        writer.block();
        return;
    }
    if (name == "code" && options.code) {
        auto content = singleLine(clean(nodeText(tree, index), true));
        if (!content.length) return;
        auto ticks = new char[longestRun(content, '`') + 1];
        ticks[] = '`';
        const padded = content[0] == '`' || content[$ - 1] == '`';
        writer.put(ticks);
        if (padded) writer.put(" ");
        writer.put(content);
        if (padded) writer.put(" ");
        writer.put(ticks);
        return;
    }
    if ((name == "ul" || name == "ol") && options.lists) {
        writer.block();
        long ordinal = 1;
        if (name == "ol") {
            try { ordinal = to!long(attribute(node, "start")); }
            catch (Exception) { ordinal = 1; }
            if (ordinal < 1) ordinal = 1;
        }
        bool first = true;
        for (size_t child = index + 1; child < endOf(tree, index);
             child = endOf(tree, child)) {
            if (tree.nodes[child].parentIndex != index) continue;
            if (tree.nodes[child].name != "li") {
                renderNode(tree, child, writer, depth + 1, options, inCell); continue;
            }
            if (!first) writer.put("\n");
            first = false;
            Writer item;
            renderChildren(tree, child, item, depth + 1, options, inCell);
            item.trim();
            size_t prefixLength = 2;
            if (name == "ul") writer.put("- ");
            else {
                prefixLength += writer.putDecimal(cast(ulong)ordinal);
                writer.put(". ");
            }
            if (ordinal < long.max) ++ordinal;
            auto itemValue = item.finish();
            size_t lineStart;
            foreach (i, c; itemValue) {
                if (c != '\n') continue;
                writer.put(itemValue[lineStart .. i + 1]);
                assert(prefixLength <= maxListIndent.length);
                writer.put(maxListIndent[0 .. prefixLength]);
                lineStart = i + 1;
            }
            writer.put(itemValue[lineStart .. $]);
        }
        writer.block();
        return;
    }
    if (name == "blockquote" && options.quotes) {
        Writer quote;
        renderChildren(tree, index, quote, depth + 1, options, inCell);
        quote.trim();
        writer.block();
        writer.put("> ");
        size_t lineStart;
        foreach (i, c; quote.bytes) {
            if (c != '\n') continue;
            writer.put(quote.bytes[lineStart .. i + 1]);
            writer.put("> ");
            lineStart = i + 1;
        }
        writer.put(quote.bytes[lineStart .. $]);
        writer.block();
        return;
    }
    if (name == "table" && options.tables) {
        if (inCell) {
            // Flatten a table nested inside a cell to inert prose instead
            // of recursing into `renderTable`'s real `| ... |` / `|---|`
            // syntax -- see this function's own doc comment (`inCell`)
            // above for why. Walking its children with `inCell` still set
            // reaches this same `table`/`tr` degrade for anything nested
            // deeper, and every real cell's text still survives (only the
            // pipe/dash structure marking it as a table is lost).
            renderChildren(tree, index, writer, depth + 1, options, true);
            return;
        }
        renderTable(tree, index, writer, depth, options);
        return;
    }
    if (name == "tr") {
        if (inCell) {
            // Same rationale as the `table` branch above: the plain
            // bullet-row degrade below writes a literal leading "- " and
            // " | " cell separators, which is exactly the same unescaped-
            // structural-pipe hazard one level down. Render each real
            // td/th cell's own content directly, joined by a plain space
            // (never a pipe), keeping `inCell` set throughout.
            writer.block();
            bool firstCell = true;
            for (size_t child = index + 1; child < endOf(tree, index);
                 child = endOf(tree, child)) {
                if (tree.nodes[child].parentIndex != index) continue;
                if (tree.nodes[child].name != "td" && tree.nodes[child].name != "th")
                    continue;
                if (!firstCell) writer.put(" ");
                firstCell = false;
                renderChildren(tree, child, writer, depth + 1, options, true);
            }
            writer.block();
            return;
        }
        writer.block();
        writer.put("- ");
        bool first = true;
        for (size_t child = index + 1; child < endOf(tree, index);
             child = endOf(tree, child)) {
            if (tree.nodes[child].parentIndex != index) continue;
            if (!first) writer.put(" | ");
            first = false;
            Writer cell;
            renderChildren(tree, child, cell, depth + 1, options, true);
            writer.put(singleLine(cell.finish()));
        }
        writer.block();
        return;
    }
    bool heading = name.length == 2 && name[0] == 'h' &&
        name[1] >= '1' && name[1] <= '6';
    // "pre" and "blockquote" only ever reach here when their own dedicated,
    // real-syntax branch above was skipped because `options.code`/
    // `options.quotes` is false (that branch always `return`s before this
    // point when the option is on) -- this is exactly the graceful
    // plain-paragraph degrade `MarkdownRenderOptions`'s doc comment
    // describes: same blank-line block separation, no fence/`> ` marker.
    bool block = heading || name == "p" || name == "div" || name == "li" ||
        name == "table" || name == "pre" || name == "blockquote";
    if (block) writer.block();
    if (heading) {
        foreach (_; 0 .. name[1] - '0') writer.put("#");
        writer.put(" ");
    }
    if (options.formatting &&
        (name == "strong" || name == "b" || name == "em" || name == "i")) {
        Writer emphasized;
        renderChildren(tree, index, emphasized, depth + 1, options, inCell);
        auto content = emphasized.finish();
        size_t left, right = content.length;
        while (left < right && content[left] == ' ') ++left;
        while (right > left && content[right - 1] == ' ') --right;
        writer.putText(content[0 .. left]);
        if (left < right) {
            auto marker = name == "strong" || name == "b" ? "**" : "*";
            writer.put(marker);
            writer.put(content[left .. right]);
            writer.put(marker);
        }
        writer.putText(content[right .. $]);
        if (block) writer.block();
        return;
    }
    if (name == "a" && options.links) {
        auto href = attribute(node, "href");
        const safe = safeTarget(href);
        if (safe) writer.put("[");
        renderChildren(tree, index, writer, depth + 1, options, inCell);
        if (safe) {
            writer.put("](<");
            writer.put(markdownTarget(href));
            writer.put(">)");
        }
    } else renderChildren(tree, index, writer, depth + 1, options, inCell);
    if (block) writer.block();
}

private void renderChildren(const ref HtmlTree tree, size_t parent,
    ref Writer writer, size_t depth, const ref MarkdownRenderOptions options,
    bool inCell = false) pure {
    for (size_t child = parent + 1; child < endOf(tree, parent);
         child = endOf(tree, child))
        if (tree.nodes[child].parentIndex == parent)
            renderNode(tree, child, writer, depth, options, inCell);
}

// Issue #478 real GFM-shaped pipe table, modeled on pinned trafilatura==
// 2.2.0's own `--output-format markdown` table syntax (confirmed by running
// it, not guessed): `| cell | cell | \n`, a `|---|---|\n` delimiter row
// (present only when a header row was found, dash count matching the
// widest row's column count, no per-column width/alignment), and every row
// -- header and data alike -- right-padded with empty cells to that same
// widest-row column count. `colspan`/`rowspan` are deliberately not
// interpreted (matching this renderer's own pre-existing, already-
// documented policy in docs/html-markdown.md's "Tables" section, and
// matching trafilatura's own observed behavior: a `colspan="2")` header
// cell still occupies exactly one column slot, confirmed against pinned
// trafilatura==2.2.0). Only rows and cells belonging to THIS table (not a
// nested `<table>` inside one of its cells) are gathered into the grid --
// a nested table's own rows/cells are rendered separately, recursively, by
// the ordinary per-cell `renderChildren` call below (which is a normal
// `renderNode` recursion and so re-enters this same function for a nested
// `<table>` reached that way).
//
// Header-row detection: the table's structurally-first `<tr>` (whether
// inside a `<thead>` or not) is treated as a header, and gets the
// delimiter row beneath it, iff it contains at least one `<th>` cell --
// confirmed against pinned trafilatura==2.2.0, which emits no delimiter
// row at all for an all-`<td>` first row (even when a later row happens to
// contain a `<th>`), and which does emit one for a first row that is a mix
// of `<th>`/`<td>` cells (a real, common shape: a leading `<th scope="row">`
// row-label cell alongside ordinary `<td>` data cells in the same row).
//
// Caption: a direct `<caption>` child's content is rendered as its own
// plain text line immediately before the grid, not folded into the grid as
// a pseudo-row. This is a deliberate divergence from pinned trafilatura==
// 2.2.0's own caption handling (confirmed by running it): it renders a
// caption as an entirely separate one-cell "table" (its own delimiter row
// padded out to the real table's column count, immediately followed by the
// real header's own second delimiter row) -- a second invented rectangular
// grid for non-tabular content that this renderer chooses not to
// replicate, in keeping with this module's existing "never synthesize
// structure that was not there" posture (see `docs/html-markdown.md`).
// Preserving the caption's real text (rather than trafilatura's own
// apparent drop-on-`--no-tables` semantics, and rather than silently
// discarding it the way a naive tr-only tree walk would) keeps this
// addition data-preserving, matching every other dimension in
// `MarkdownRenderOptions`.
private void renderTable(const ref HtmlTree tree, size_t tableIndex,
    ref Writer writer, size_t depth, const ref MarkdownRenderOptions options) pure {
    if (depth > 128) throw new HtmlMarkdownOutputLimit;
    string captionText;
    bool hasCaption;
    string[][] rows;
    bool[] rowHasHeaderCell;
    size_t maxCols;
    size_t tableEnd = endOf(tree, tableIndex);
    for (size_t i = tableIndex + 1; i < tableEnd; ++i) {
        ref const candidate = tree.nodes[i];
        if (candidate.kind != HtmlNodeKind.element) continue;
        if (candidate.name == "caption" && candidate.parentIndex == tableIndex &&
            !hasCaption) {
            Writer caption;
            renderChildren(tree, i, caption, depth + 1, options);
            captionText = singleLine(caption.finish());
            hasCaption = true;
            continue;
        }
        if (candidate.name != "tr") continue;
        // Walk up to the nearest ancestor `<table>`; only a row whose
        // nearest table ancestor is this exact table belongs in this
        // table's own grid -- a row that belongs to a table nested inside
        // one of this table's cells does not (it is rendered separately,
        // recursively, when that cell's own content is rendered below).
        size_t parent = candidate.parentIndex;
        bool ownRow;
        while (parent != size_t.max) {
            if (tree.nodes[parent].name == "table") {
                ownRow = parent == tableIndex;
                break;
            }
            parent = tree.nodes[parent].parentIndex;
        }
        if (!ownRow) continue;
        string[] cells;
        bool hasHeaderCell;
        for (size_t child = i + 1; child < endOf(tree, i); child = endOf(tree, child)) {
            if (tree.nodes[child].parentIndex != i) continue;
            if (tree.nodes[child].name != "td" && tree.nodes[child].name != "th") continue;
            if (tree.nodes[child].name == "th") hasHeaderCell = true;
            Writer cell;
            // `inCell: true` -- this cell's content is about to be flattened
            // by `singleLine()` and folded into ONE cell of THIS table's own
            // grid; a nested `<table>` (or its `tr`) reached from here must
            // degrade to inert prose rather than emit its own real pipe-
            // table syntax into this same Writer (issue #493; see
            // `renderNode`'s `inCell` doc comment for the full mechanism).
            renderChildren(tree, child, cell, depth + 1, options, true);
            cells ~= singleLine(cell.finish());
        }
        if (cells.length > maxCols) maxCols = cells.length;
        rows ~= cells;
        rowHasHeaderCell ~= hasHeaderCell;
    }
    if (!hasCaption && !rows.length) return;
    writer.block();
    if (hasCaption) {
        writer.put(captionText);
        if (rows.length) writer.block();
    }
    bool hasHeader = rows.length && rowHasHeaderCell[0];
    foreach (rowIndex, row; rows) {
        writer.put("| ");
        foreach (col; 0 .. maxCols) {
            if (col) writer.put(" | ");
            if (col < row.length) writer.put(row[col]);
        }
        writer.put(" | \n");
        if (rowIndex == 0 && hasHeader) {
            writer.put("|");
            foreach (_; 0 .. maxCols) writer.put("---|");
            writer.put("\n");
        }
    }
    writer.block();
}

/// Convert a bounded selected tree without reading HTML or publishing output.
/// An output-cap exception exposes no partial string to the caller. `options`
/// defaults to full inline structural fidelity (formatting/links/images all
/// preserved) -- the renderer's already-shipped #431/#438 behavior, so every
/// existing caller that does not pass `options` sees byte-identical output
/// to before issue #477.
string renderMarkdown(const ref HtmlTree tree,
    const MarkdownRenderOptions options = MarkdownRenderOptions.init) pure {
    Writer writer;
    for (size_t i; i < tree.nodes.length; i = endOf(tree, i)) {
        if (tree.nodes[i].parentIndex == size_t.max)
            renderNode(tree, i, writer, 0, options);
    }
    writer.trim();
    if (writer.bytes.length) writer.put("\n");
    // Do not retain the growable buffer's spare capacity in the public result.
    return writer.bytes.idup;
}

/// Same finalization as `renderMarkdown`, but rooted at a single caller-chosen
/// node instead of iterating every root -- lets a caller (e.g. main-content
/// selection) render Markdown for just one selected subtree. `renderNode`
/// itself is untouched; this only changes which node(s) it is invoked from.
/// `options` defaults exactly as `renderMarkdown`'s does (see its own doc
/// comment) -- byte-identical to before issue #477 for every caller that
/// does not pass one.
string renderMarkdownFrom(const ref HtmlTree tree, size_t startIndex,
    const MarkdownRenderOptions options = MarkdownRenderOptions.init) pure {
    Writer writer;
    renderNode(tree, startIndex, writer, 0, options);
    writer.trim();
    if (writer.bytes.length) writer.put("\n");
    // Do not retain the growable buffer's spare capacity in the public result.
    return writer.bytes.idup;
}

unittest {
    // Regression proof: for a tree with exactly one root, rendering from
    // that root via `renderMarkdownFrom` must be byte-identical to
    // `renderMarkdown`'s own whole-document iteration -- proving the
    // extraction changed neither `renderNode`'s behavior nor the shared
    // finalization (trim + trailing newline).
    import effects.html_tree : parseHtml;

    auto outcome = parseHtml(cast(const(ubyte)[]) (
        "<article><h1>Field notes from the delta survey</h1>" ~
        "<p>The survey team spent three weeks mapping the delta.</p></article>"));
    assert(outcome.isParsed);
    auto tree = outcome.tree;

    size_t rootIndex = size_t.max;
    size_t rootCount;
    foreach (i, node; tree.nodes)
        if (node.parentIndex == size_t.max) { rootIndex = i; ++rootCount; }
    assert(rootCount == 1, "fixture must have exactly one root for this proof");

    auto whole = renderMarkdown(tree);
    auto fromRoot = renderMarkdownFrom(tree, rootIndex);
    assert(fromRoot == whole);
    // `renderNode` escapes literal `.` as `\.` (its ordinary Markdown-source
    // escaping, unrelated to this slice) -- the exact same escaping applies
    // whether reached via `renderMarkdown` or `renderMarkdownFrom`.
    assert(whole == "# Field notes from the delta survey\n\n" ~
        "The survey team spent three weeks mapping the delta\\.\n");
}

unittest {
    // `renderMarkdownFrom` scoped to a non-root subtree renders only that
    // subtree's real Markdown structure, not sibling/boilerplate content
    // that sits outside it.
    import effects.html_tree : parseHtml;

    auto outcome = parseHtml(cast(const(ubyte)[]) (
        "<nav>Home About</nav>" ~
        "<article><h1>Delta survey</h1><p>Three weeks of fieldwork.</p></article>" ~
        "<footer>Copyright</footer>"));
    assert(outcome.isParsed);
    auto tree = outcome.tree;

    size_t articleIndex = size_t.max;
    foreach (i, node; tree.nodes)
        if (node.name == "article") articleIndex = i;
    assert(articleIndex != size_t.max);

    auto scoped = renderMarkdownFrom(tree, articleIndex);
    assert(scoped == "# Delta survey\n\nThree weeks of fieldwork\\.\n");
    import std.algorithm.searching : canFind;
    assert(!scoped.canFind("Home"));
    assert(!scoped.canFind("Copyright"));
}

// Issue #477 regression: before `MarkdownRenderOptions` existed, neither
// `renderMarkdown` nor `renderMarkdownFrom` took a second argument at all --
// a call passing one (as every test below does) is a compile error on base
// commit 608196a, not merely a wrong-output failure. That is this ticket's
// fail-on-base/pass-on-tip proof for genuinely new API surface: there is no
// prior behavior to regress-test against, only a capability to prove exists
// and behaves correctly.
//
// Default-param proof: omitting `options` entirely must resolve to exactly
// `MarkdownRenderOptions.init` (all three fields `true`) -- byte-identical
// to #431/#438's already-shipped unconditional formatting/links/images
// behavior, so every existing caller (`html_markdown_stage.d`,
// `html_main_content_markdown.d`, both `*_stage.d` modules) that has never
// heard of this option struct keeps seeing exactly the output it always
// has. This is what makes issue #477's "default (off) must not regress
// #411/#438" requirement true by construction here: the *default* stays
// full fidelity; a caller opts a field *out*, the reverse of trafilatura's
// own opt-*in* polarity (see `MarkdownRenderOptions`'s doc comment for why).
unittest {
    import effects.html_tree : parseHtml;

    auto outcome = parseHtml(cast(const(ubyte)[]) (
        "<p><strong>bold</strong> and <a href=\"http://example.com/x\">a link</a> " ~
        "and <img src=\"http://example.com/y.png\" alt=\"alt text\"></p>"));
    assert(outcome.isParsed);
    auto tree = outcome.tree;

    auto omitted = renderMarkdown(tree);
    auto explicitDefault = renderMarkdown(tree, MarkdownRenderOptions.init);
    MarkdownRenderOptions allTrue = MarkdownRenderOptions(true, true, true);
    auto explicitAllTrue = renderMarkdown(tree, allTrue);
    assert(omitted == explicitDefault);
    assert(omitted == explicitAllTrue);
    assert(omitted == "**bold** and [a link](<http://example.com/x>) and " ~
        "![alt text](<http://example.com/y.png>)\n");
}

// Issue #477 real fixture 1/3 -- formatting (`--formatting`). Verbatim
// excerpt (heading text plus the following paragraph, trimmed at a
// sentence boundary) from pronats.de's "Kindheit und Arbeit" page, resolved
// via `experiments/html_main_content/fetch_held_out.sh --emit-corpus-dir`
// from adbar/trafilatura's own pinned real-page eval corpus (fixture 18 of
// the 20-URL held-out selection) -- real third-party page content, test-
// only and never shipped in the release binary (see this repository's
// existing `docs/html-parser-evaluation.md`-adjacent test-fixture policy:
// real third-party content is acceptable for non-shipped test/comparator
// fixtures). The `<strong>` wraps a genuine page heading, not authored
// text, proving `formatting` against real inline markup rather than a
// synthetic bold tag.
unittest {
    import effects.html_tree : parseHtml;

    string html =
        "<h3><strong>Arbeit ist wichtig für das Selbstwertgefühl</strong></h3>" ~
        "<p>Wenn wir von „kritischer Wertschätzung“ der Arbeit der " ~
        "Kinder sprechen, achten wir auf beides: auf die problematische Form und die " ~
        "Bedingungen der Arbeit, die der körperlichen und geistigen Entwicklung " ~
        "entgegenstehen, aber eben auch auf die Möglichkeiten, die sich aus der " ~
        "Arbeitserfahrung für Kinder ergeben.</p>";
    auto outcome = parseHtml(cast(const(ubyte)[]) html);
    assert(outcome.isParsed);
    auto tree = outcome.tree;

    auto formattingOn = renderMarkdown(tree, MarkdownRenderOptions(true, true, true));
    assert(formattingOn ==
        "### **Arbeit ist wichtig für das Selbstwertgefühl**\n\n" ~
        "Wenn wir von „kritischer Wertschätzung“ der Arbeit der Kinder sprechen, " ~
        "achten wir auf beides: auf die problematische Form und die Bedingungen " ~
        "der Arbeit, die der körperlichen und geistigen Entwicklung entgegenstehen, " ~
        "aber eben auch auf die Möglichkeiten, die sich aus der Arbeitserfahrung " ~
        "für Kinder ergeben\\.\n",
        "formatting=true must preserve real ** emphasis around the page's own heading text");

    auto formattingOff = renderMarkdown(tree, MarkdownRenderOptions(false, true, true));
    assert(formattingOff ==
        "### Arbeit ist wichtig für das Selbstwertgefühl\n\n" ~
        "Wenn wir von „kritischer Wertschätzung“ der Arbeit der Kinder sprechen, " ~
        "achten wir auf beides: auf die problematische Form und die Bedingungen " ~
        "der Arbeit, die der körperlichen und geistigen Entwicklung entgegenstehen, " ~
        "aber eben auch auf die Möglichkeiten, die sich aus der Arbeitserfahrung " ~
        "für Kinder ergeben\\.\n",
        "formatting=false must drop ** but keep the same heading structure and text");
}

// Issue #477 real fixtures 2/3 and 3/3 -- links and images
// (`--links`/`--images`), combined in one fixture because the real page
// itself combines them: a genuine linked thumbnail (`<a>` wrapping `<img>`,
// pronats.de's real "gallery" widget markup) plus, deliberately alongside
// it, a real `javascript:` "Print" link from the very same page --
// proving the pre-existing unsafe-target fallback (already covered by
// `safeTarget`'s own tests) composes correctly with these new independent
// toggles rather than being bypassed by them. Same corpus/provenance and
// test-only-fixture policy as the formatting fixture above.
unittest {
    import effects.html_tree : parseHtml;

    string html =
        `<div class="image">` ~
        `<a href="/assets/Uploads/burkina-appleseller.jpg" title="Äpfelverkäuferin in Burkina Faso - (c) Philip Meade" class="gallery">` ~
        `<img src="/assets/Uploads/burkina-appleseller.jpg" alt="Äpfelverkäuferin in Burkina Faso - (c) Philip Meade" />` ~
        `</a></div>` ~
        `<p class="imageDescription">Kinder identifizieren sich auch über ihre Arbeit, so wie bei diese ` ~
        `Äpfelverkäuferin aus Burkina Faso. Die Arbeit kann ihnen Möglichkeiten zur ` ~
        `gesellschaftlichen Teilhabe eröffnen.</p>` ~
        `<div class="printButton" id="printButton"><a href="javascript:window.print()">Print</a></div>`;
    auto outcome = parseHtml(cast(const(ubyte)[]) html);
    assert(outcome.isParsed);
    auto tree = outcome.tree;

    auto allOn = renderMarkdown(tree, MarkdownRenderOptions(true, true, true));
    assert(allOn ==
        "[![Äpfelverkäuferin in Burkina Faso \\- \\(c\\) Philip Meade]" ~
        "(</assets/Uploads/burkina-appleseller.jpg>)]" ~
        "(</assets/Uploads/burkina-appleseller.jpg>)\n\n" ~
        "Kinder identifizieren sich auch über ihre Arbeit, so wie bei diese " ~
        "Äpfelverkäuferin aus Burkina Faso\\. Die Arbeit kann ihnen Möglichkeiten " ~
        "zur gesellschaftlichen Teilhabe eröffnen\\.\n\n" ~
        "Print\n",
        "links=true, images=true must render the real linked thumbnail as " ~
        "nested Markdown image-inside-link syntax");

    auto linksOff = renderMarkdown(tree, MarkdownRenderOptions(true, false, true));
    assert(linksOff ==
        "![Äpfelverkäuferin in Burkina Faso \\- \\(c\\) Philip Meade]" ~
        "(</assets/Uploads/burkina-appleseller.jpg>)\n\n" ~
        "Kinder identifizieren sich auch über ihre Arbeit, so wie bei diese " ~
        "Äpfelverkäuferin aus Burkina Faso\\. Die Arbeit kann ihnen Möglichkeiten " ~
        "zur gesellschaftlichen Teilhabe eröffnen\\.\n\n" ~
        "Print\n",
        "links=false must drop only the outer [...](...) wrapping -- the real " ~
        "image markup underneath is untouched, and the already-unsafe " ~
        "javascript: \"Print\" link (never wrapped even with links=true) is " ~
        "unaffected either way");

    auto imagesOff = renderMarkdown(tree, MarkdownRenderOptions(true, true, false));
    assert(imagesOff ==
        "[Äpfelverkäuferin in Burkina Faso \\- \\(c\\) Philip Meade]" ~
        "(</assets/Uploads/burkina-appleseller.jpg>)\n\n" ~
        "Kinder identifizieren sich auch über ihre Arbeit, so wie bei diese " ~
        "Äpfelverkäuferin aus Burkina Faso\\. Die Arbeit kann ihnen Möglichkeiten " ~
        "zur gesellschaftlichen Teilhabe eröffnen\\.\n\n" ~
        "Print\n",
        "images=false must fall back to the real alt text (the same fallback " ~
        "already used for an unsafe image target) while the outer real link " ~
        "still wraps it");

    auto allOff = renderMarkdown(tree, MarkdownRenderOptions(false, false, false));
    assert(allOff ==
        "Äpfelverkäuferin in Burkina Faso \\- \\(c\\) Philip Meade\n\n" ~
        "Kinder identifizieren sich auch über ihre Arbeit, so wie bei diese " ~
        "Äpfelverkäuferin aus Burkina Faso\\. Die Arbeit kann ihnen Möglichkeiten " ~
        "zur gesellschaftlichen Teilhabe eröffnen\\.\n\n" ~
        "Print\n",
        "all three off must reduce to plain real text with no Markdown link or " ~
        "image syntax anywhere");
}

// Issue #477: a second, independent real `links` fixture with a genuine
// absolute http(s) target (rather than the relative target above), from a
// different held-out page (archiv.krimiblog.de, fixture 01 of the same
// pinned corpus) -- proves the toggle against `safeTarget`'s other allowed
// scheme shape, not just a relative reference.
unittest {
    import effects.html_tree : parseHtml;

    auto outcome = parseHtml(cast(const(ubyte)[])
        `<p><a href="http://www.cjdmusic.com/">Christopher Dallman</a></p>`);
    assert(outcome.isParsed);
    auto tree = outcome.tree;

    auto linksOn = renderMarkdown(tree, MarkdownRenderOptions(true, true, true));
    assert(linksOn == "[Christopher Dallman](<http://www.cjdmusic.com/>)\n");

    auto linksOff = renderMarkdown(tree, MarkdownRenderOptions(true, false, true));
    assert(linksOff == "Christopher Dallman\n",
        "links=false must fall back to the real anchor's visible text only");
}

// Issue #478 regression: before `tables`/`lists`/`quotes`/`code` existed on
// `MarkdownRenderOptions`, a 4-, 5-, 6-, or 7-argument construction of it
// (as every test below uses, via named fields) was a compile error on base
// commit fa5e18e (the struct had only 3 fields) -- a compile-time failure,
// not merely a wrong-output one, exactly mirroring #477's own "new API
// surface" fail-on-base/pass-on-tip proof one struct generation up. Named-
// field construction (`MarkdownRenderOptions(tables: false, ...)`) is used
// throughout this ticket's new tests rather than positional, per this
// ticket's own explicit instruction: a 7-field all-`bool` struct makes
// positional transposition a real, silent risk that named fields rule out
// by construction.
//
// Default-param proof: omitting `options` (or passing `.init`) must still
// resolve to every field `true`, byte-identical to before these four fields
// existed -- the #411/#438 non-regression guarantee this struct's own
// doc comment describes, now covering all seven fields, not just the
// original three.
unittest {
    import effects.html_tree : parseHtml;

    auto outcome = parseHtml(cast(const(ubyte)[]) (
        `<p>Plain paragraph with <strong>bold</strong> text.</p>` ~
        `<ul><li>one</li><li>two</li></ul>` ~
        `<blockquote><p>a real quotation</p></blockquote>` ~
        `<pre><code>fn();</code></pre>` ~
        `<table><tr><th>H</th></tr><tr><td>D</td></tr></table>`));
    assert(outcome.isParsed);
    auto tree = outcome.tree;

    auto omitted = renderMarkdown(tree);
    auto explicitDefault = renderMarkdown(tree, MarkdownRenderOptions.init);
    auto explicitAllTrue = renderMarkdown(tree, MarkdownRenderOptions(
        formatting: true, links: true, images: true,
        tables: true, lists: true, quotes: true, code: true));
    assert(omitted == explicitDefault);
    assert(omitted == explicitAllTrue);
    import std.algorithm.searching : canFind;
    assert(omitted.canFind("- one"), "lists default true");
    assert(omitted.canFind("> a real quotation"), "quotes default true");
    assert(omitted.canFind("```"), "code default true");
    assert(omitted.canFind("|---|"), "tables default true");
}

// Issue #478 real fixture 1/4 -- tables (trafilatura-parity `--no-tables`
// polarity). Verbatim excerpt (the real "ISOCALENDAR" template table, header
// row plus its first two real data rows, trimmed for fixture size) from
// Wikipedia's "ISO 8601" article (en.wikipedia.org/wiki/ISO_8601, CC BY-SA
// 4.0 -- real third-party content, test-only and never shipped, per this
// repository's existing test-fixture policy), resolved by fetching that
// real page directly (the 20-page adbar/trafilatura held-out corpus this
// ticket's other three fixtures draw from has exactly one real `<table>`
// across all 20 pages -- a single-cell search-form layout table, confirmed
// by inspection -- not a genuine multi-column data table, so this fixture
// draws on a different, separately fetched real page instead, per this
// issue's own explicit allowance for that when the held-out corpus lacks a
// good example of a structure type). A genuine multi-column (8-column)
// real table: `<th>` column headers (Week/Mon/.../Sun) plus real `<caption>`
// and real per-day `<td>` data, exercising the header/separator-row
// detection, the real `<caption>`, and real multi-column width together --
// not a synthetic 2x2 grid invented for this test.
unittest {
    import effects.html_tree : parseHtml;

    string html = `<article><h2>September 2026</h2>` ~
        `<p>The ISO week calendar arranges each week from Monday through ` ~
        `Sunday and numbers each week of the year, as shown in the ` ~
        `following excerpt of a September 2026 calendar table.</p>` ~
        `<table class="wikitable floatright" style="text-align:center;">` ~
        `<caption>September 2026</caption><tbody><tr>` ~
        `<th width="%" scope="column" style="font-family: monospace;">Week</th>` ~
        `<th width="%" scope="column" style="font-family: monospace;" title="Monday">Mon</th>` ~
        `<th width="%" scope="column" style="font-family: monospace;" title="Tuesday">Tue</th>` ~
        `<th width="%" scope="column" style="font-family: monospace;" title="Wednesday">Wed</th>` ~
        `<th width="%" scope="column" style="font-family: monospace;" title="Thursday">Thu</th>` ~
        `<th width="%" scope="column" style="font-family: monospace;" title="Friday">Fri</th>` ~
        `<th width="%" scope="column" style="font-family: monospace;" title="Saturday">Sat</th>` ~
        `<th width="%" scope="column" style="font-family: monospace;" title="Sunday">Sun</th></tr>` ~
        `<tr><th scope="row" title="days in calendar week number 36">` ~
        `<span style="opacity:0.7;">W36</span></th>` ~
        `<td style="opacity:0.3; " title="2026-08-31">31</td><td title="2026-09-01">01</td>` ~
        `<td title="2026-09-02">02</td><td title="2026-09-03">03</td><td title="2026-09-04">04</td>` ~
        `<td title="2026-09-05">05</td><td title="2026-09-06">06</td></tr>` ~
        `<tr><th scope="row" title="days in calendar week number 37">` ~
        `<span style="opacity:0.7;">W37</span></th>` ~
        `<td title="2026-09-07">07</td><td title="2026-09-08">08</td><td title="2026-09-09">09</td>` ~
        `<td title="2026-09-10">10</td><td title="2026-09-11">11</td><td title="2026-09-12">12</td>` ~
        `<td title="2026-09-13">13</td></tr></tbody></table>` ~
        `<p>Numbering each week from 01 through 52 or 53 lets applications ` ~
        `sort dates lexicographically without ambiguity across year ` ~
        `boundaries in most practical cases.</p></article>`;
    auto outcome = parseHtml(cast(const(ubyte)[]) html);
    assert(outcome.isParsed);
    auto tree = outcome.tree;

    auto tablesOn = renderMarkdown(tree, MarkdownRenderOptions(tables: true));
    assert(tablesOn ==
        "## September 2026\n\n" ~
        "The ISO week calendar arranges each week from Monday through Sunday " ~
        "and numbers each week of the year, as shown in the following " ~
        "excerpt of a September 2026 calendar table\\.\n\n" ~
        "September 2026\n\n" ~
        "| Week | Mon | Tue | Wed | Thu | Fri | Sat | Sun | \n" ~
        "|---|---|---|---|---|---|---|---|\n" ~
        "| W36 | 31 | 01 | 02 | 03 | 04 | 05 | 06 | \n" ~
        "| W37 | 07 | 08 | 09 | 10 | 11 | 12 | 13 |\n\n" ~
        "Numbering each week from 01 through 52 or 53 lets applications " ~
        "sort dates lexicographically without ambiguity across year " ~
        "boundaries in most practical cases\\.\n",
        "tables=true must render a real GFM-shaped pipe table, matching " ~
        "pinned trafilatura==2.2.0's own row/delimiter syntax (confirmed by " ~
        "running it), plus the real caption as its own preceding line");

    auto tablesOff = renderMarkdown(tree, MarkdownRenderOptions(tables: false));
    assert(tablesOff ==
        "## September 2026\n\n" ~
        "The ISO week calendar arranges each week from Monday through Sunday " ~
        "and numbers each week of the year, as shown in the following " ~
        "excerpt of a September 2026 calendar table\\.\n\n" ~
        "September 2026\n\n" ~
        "- Week | Mon | Tue | Wed | Thu | Fri | Sat | Sun\n\n" ~
        "- W36 | 31 | 01 | 02 | 03 | 04 | 05 | 06\n\n" ~
        "- W37 | 07 | 08 | 09 | 10 | 11 | 12 | 13\n\n" ~
        "Numbering each week from 01 through 52 or 53 lets applications " ~
        "sort dates lexicographically without ambiguity across year " ~
        "boundaries in most practical cases\\.\n",
        "tables=false must fall back to this renderer's own pre-#478 plain " ~
        "bullet-row form -- a graceful rendering degrade that still keeps " ~
        "every real cell's text, unlike pinned trafilatura==2.2.0's own " ~
        "--no-tables (confirmed by running it: it drops table content " ~
        "outright rather than degrading it -- a deliberate divergence, see " ~
        "MarkdownRenderOptions's own doc comment)");
}

// Issue #493 regression: the exact synthetic nested-table repro from the
// ticket. Before this fix, `renderTable`'s per-cell content collection
// recursed into a nested `<table>`'s own `renderTable` call using the SAME
// `Writer` that becomes the outer cell's content; that inner call wrote its
// own real `| ... |` / `|---|` pipe-table syntax as literal characters
// (bypassing `clean()`'s escaping, and `singleLine()` does not escape `|`/
// `-` either), so the outer table's second data row came out as
// `| before | Inner | |---| | innerdata | after |` -- a stray, literal
// `|---|` delimiter-row fragment bled into a data cell of a table that
// declares only 1 column via its header, genuinely malformed GFM. The fix
// (`renderNode`'s `inCell` flag) flattens a nested table reached from
// inside a cell to plain prose instead: this test asserts both the exact
// fixed output AND, defensively, that no data row contains a stray
// delimiter-row fragment or a pipe count exceeding the table's own declared
// column width -- so a future regression reintroducing the bug (even with
// different literal spacing) still fails this test, not just an exact-
// string diff.
unittest {
    import effects.html_tree : parseHtml;
    import std.algorithm.searching : canFind, count;
    import std.array : split;

    string html = "<table><tr><th>Outer</th></tr>" ~
        "<tr><td>before<table><tr><th>Inner</th></tr>" ~
        "<tr><td>innerdata</td></tr></table>after</td></tr></table>";
    auto outcome = parseHtml(cast(const(ubyte)[]) html);
    assert(outcome.isParsed);
    auto tree = outcome.tree;

    auto markdown = renderMarkdown(tree, MarkdownRenderOptions(tables: true));
    assert(markdown ==
        "| Outer | \n" ~
        "|---|\n" ~
        "| before Inner innerdata after |\n",
        "a nested table's real content must survive, flattened to plain " ~
        "prose inside the outer cell, with no pipe-table syntax of its own");

    // Defensive structural check, independent of the exact fixed string
    // above: no stray `|---|`-shaped delimiter-row fragment appears
    // anywhere except the outer table's own single real delimiter row, and
    // no data row has more pipe-delimited segments than the 1-column width
    // the header itself declares.
    assert(markdown.split("\n").count!(line => line.canFind("|---|")) == 1,
        "exactly one real delimiter row -- the outer table's own -- may " ~
        "contain a `|---|`-shaped run; a nested table's own delimiter row " ~
        "must never survive as a second, stray occurrence");
    foreach (line; markdown.split("\n")) {
        if (!line.length || line == "|---|") continue;
        // A well-formed 1-column data/header row looks like "| cell | ",
        // i.e. exactly 2 pipes; a corrupted row (the inner table's own
        // pipes bleeding through) would have more.
        assert(line.count('|') == 2,
            "a data row must have exactly as many pipes as the declared " ~
            "1-column width implies (2, for the leading/trailing pipes) " ~
            "-- more would mean a nested table's own pipe syntax leaked " ~
            "into this row: " ~ line);
    }
}

// Issue #493 regression, second shape: the same nested-table hazard when
// the OUTER table itself is rendered via the pre-#478 plain bullet-row
// degrade (`tables: false`) rather than real pipe-table syntax -- the
// ticket's own root-cause note that "base's pre-existing bullet-row `tr`
// handling has the same latent weakness". Before this fix, the nested
// table's real `renderTable` call (triggered because `options.tables` is a
// single flag applying to the whole render, and a NESTED table reached
// while collecting a bullet-row's cell is still real syntax on base) wrote
// its own `| ... |` / `|---|` literals into the same flattened bullet line.
unittest {
    import effects.html_tree : parseHtml;
    import std.algorithm.searching : canFind;

    string html = "<table><tr><th>Outer</th></tr>" ~
        "<tr><td>before<table><tr><th>Inner</th></tr>" ~
        "<tr><td>innerdata</td></tr></table>after</td></tr></table>";
    auto outcome = parseHtml(cast(const(ubyte)[]) html);
    assert(outcome.isParsed);
    auto tree = outcome.tree;

    auto markdown = renderMarkdown(tree, MarkdownRenderOptions(tables: false));
    assert(markdown ==
        "- Outer\n\n" ~
        "- before Inner innerdata after\n",
        "tables=false's own plain bullet-row degrade must also flatten a " ~
        "nested table to inert prose, not bleed its real pipe syntax into " ~
        "the bullet line");
    assert(!markdown.canFind("|---|"),
        "no real pipe-table delimiter syntax may appear anywhere once " ~
        "tables=false has degraded every row to a plain bullet line");
}

// Issue #494 gap 1: `renderTable`'s header-row detection
// (`hasHeader = rows.length && rowHasHeaderCell[0]`) is scoped to whether
// the structurally-first `<tr>` specifically contains a real `<th>`, not
// "does any row anywhere contain a `<th>`". Every existing fixture's first
// row already has a real `<th>`, so a mutant that widens the guard to
// `hasHeader = rows.length > 0` (header row detected unconditionally,
// ignoring `<th>` presence entirely) passes the full suite unchanged. This
// fixture's first row is all `<td>` (no header) and its SECOND row has a
// real `<th>`, so it proves two things a `<th>`-in-row-0 fixture cannot:
// (1) no `|---|` delimiter row is emitted at all (false-positive direction),
// and (2) the later real `<th>` row still renders as an ordinary data row,
// not specially -- because header detection only ever looks at row 0.
//
// Mutation-tested per this ticket: temporarily changing the guard to
// `hasHeader = rows.length > 0` makes this test fail (a `|---|` line
// appears after row 0, which no assertion below allows); reverting to the
// shipped guard makes it pass again.
unittest {
    import effects.html_tree : parseHtml;
    import std.algorithm.searching : canFind;

    string html = "<table><tr><td>a1</td><td>b1</td></tr>" ~
        "<tr><th>a2</th><td>b2</td></tr></table>";
    auto outcome = parseHtml(cast(const(ubyte)[]) html);
    assert(outcome.isParsed);
    auto tree = outcome.tree;

    auto markdown = renderMarkdown(tree, MarkdownRenderOptions(tables: true));
    assert(markdown ==
        "| a1 | b1 | \n" ~
        "| a2 | b2 |\n",
        "a table whose first row is all `<td>` must never emit a `|---|` " ~
        "delimiter row -- header detection looks only at row 0 -- and a " ~
        "real `<th>` appearing in a LATER row must still render as an " ~
        "ordinary data row, not trigger header treatment: " ~ markdown);
    assert(!markdown.canFind("|---|"),
        "no delimiter row may appear when the first row contains no real " ~
        "`<th>` cell, regardless of `<th>` cells appearing later");
}

// Issue #494 gap 2: `renderTable`'s doc comment states ragged rows
// (differing column counts) are padded out to the widest row's column
// count, but the #478 fixture is accidentally uniform-width throughout, so
// that claim has zero test coverage. This fixture is genuinely ragged (1,
// then 3, then 2 columns) AND deliberately makes the widest row a later
// DATA row rather than row 0, so the test also proves `maxCols` is tracked
// across every row, not assumed from the first row's width. No `<th>`
// appears anywhere, so no delimiter row complicates the padding proof.
//
// Mutation-tested per this ticket: temporarily changing the render loop's
// `foreach (col; 0 .. maxCols)` to `foreach (col; 0 .. row.length)` (each
// row renders only its own actual cells, no padding to the table's widest
// row) makes this test fail (the short rows come out narrower, with no
// trailing empty cells); reverting to the shipped `maxCols` loop makes it
// pass again.
unittest {
    import effects.html_tree : parseHtml;

    string html = "<table><tr><td>a</td></tr>" ~
        "<tr><td>b</td><td>c</td><td>d</td></tr>" ~
        "<tr><td>e</td><td>f</td></tr></table>";
    auto outcome = parseHtml(cast(const(ubyte)[]) html);
    assert(outcome.isParsed);
    auto tree = outcome.tree;

    auto markdown = renderMarkdown(tree, MarkdownRenderOptions(tables: true));
    assert(markdown ==
        "| a |  |  | \n" ~
        "| b | c | d | \n" ~
        "| e | f |  |\n",
        "every row must pad out to the WIDEST row's column count (3, from " ~
        "the second, non-first data row) -- the 1-column first row and the " ~
        "2-column third row must each gain trailing empty cells rather " ~
        "than rendering at their own narrower width: " ~ markdown);
}

// Issue #478 real fixture 2/4 -- lists (nested, ordered/unordered). Verbatim
// excerpt (the real "Durations" section's designator list, real <i> emphasis
// kept as-is) from the same Wikipedia "ISO 8601" article as the table
// fixture above (en.wikipedia.org/wiki/ISO_8601, CC BY-SA 4.0), for the same
// reason: none of the held-out corpus's 20 real pages have a genuine nested
// list inside actual article content (every `<ul>`/`<ol>` found by direct
// inspection across all 20 pages is navigation/menu/footer chrome -- e.g.
// `class="sub-menu"`, `class="menu_2depth_list"`, `id="menu-main-menu"` --
// not article prose), so this fixture draws on a different, separately
// fetched real page, per this issue's own explicit allowance for that case.
// A genuinely two-level-nested real `<ul>`: an outer list item's own prose
// text followed immediately by a nested `<ul>`, twice, each nested list
// itself holding several real `<li>` items -- not a synthetic one-level
// list invented for this test.
unittest {
    import effects.html_tree : parseHtml;

    string html = `<article><h2>Durations</h2>` ~
        `<p>Durations define the amount of intervening time in a time ` ~
        `interval and are represented by the format P[n]Y[n]M[n]DT[n]H[n]M[n]S ` ~
        `or P[n]W as shown on the aside. The capital letters are designators ` ~
        `for each of the date and time elements and are not replaced.</p>` ~
        `<ul><li><i>P</i> is the duration designator (for <i>period</i>) ` ~
        `placed at the start of the duration representation.` ~
        `<ul><li><i>Y</i> is the year designator that follows the value ` ~
        `for the number of calendar years.</li>` ~
        `<li><i>M</i> is the month designator that follows the value for ` ~
        `the number of calendar months.</li>` ~
        `<li><i>W</i> is the week designator that follows the value for ` ~
        `the number of weeks.</li>` ~
        `<li><i>D</i> is the day designator that follows the value for ` ~
        `the number of calendar days.</li></ul></li>` ~
        `<li><i>T</i> is the time designator that precedes the time ` ~
        `components of the duration representation.` ~
        `<ul><li><i>H</i> is the hour designator that follows the value ` ~
        `for the number of hours.</li>` ~
        `<li><i>M</i> is the minute designator that follows the value for ` ~
        `the number of minutes.</li>` ~
        `<li><i>S</i> is the second designator that follows the value for ` ~
        `the number of seconds.</li></ul></li></ul>` ~
        `<p>For example, "P3Y6M4DT12H30M5S" represents a duration of three ` ~
        `years, six months, four days, twelve hours, thirty minutes, and ` ~
        `five seconds.</p></article>`;
    auto outcome = parseHtml(cast(const(ubyte)[]) html);
    assert(outcome.isParsed);
    auto tree = outcome.tree;

    auto listsOn = renderMarkdown(tree, MarkdownRenderOptions(lists: true));
    assert(listsOn ==
        "## Durations\n\n" ~
        "Durations define the amount of intervening time in a time interval " ~
        "and are represented by the format P\\[n\\]Y\\[n\\]M\\[n\\]DT\\[n\\]H\\[n\\]M\\[n\\]S " ~
        "or P\\[n\\]W as shown on the aside\\. The capital letters are " ~
        "designators for each of the date and time elements and are not " ~
        "replaced\\.\n\n" ~
        "- *P* is the duration designator \\(for *period*\\) placed at the " ~
        "start of the duration representation\\.\n" ~
        "  \n" ~
        "  - *Y* is the year designator that follows the value for the " ~
        "number of calendar years\\.\n" ~
        "  - *M* is the month designator that follows the value for the " ~
        "number of calendar months\\.\n" ~
        "  - *W* is the week designator that follows the value for the " ~
        "number of weeks\\.\n" ~
        "  - *D* is the day designator that follows the value for the " ~
        "number of calendar days\\.\n" ~
        "- *T* is the time designator that precedes the time components " ~
        "of the duration representation\\.\n" ~
        "  \n" ~
        "  - *H* is the hour designator that follows the value for the " ~
        "number of hours\\.\n" ~
        "  - *M* is the minute designator that follows the value for the " ~
        "number of minutes\\.\n" ~
        "  - *S* is the second designator that follows the value for the " ~
        "number of seconds\\.\n\n" ~
        "For example, \"P3Y6M4DT12H30M5S\" represents a duration of three " ~
        "years, six months, four days, twelve hours, thirty minutes, and " ~
        "five seconds\\.\n",
        "lists=true must render the real two-level nesting as indented " ~
        "Markdown sub-bullets under their real parent item, preserving the " ~
        "real inline <i> emphasis in every item's text");

    auto listsOff = renderMarkdown(tree, MarkdownRenderOptions(lists: false));
    assert(listsOff ==
        "## Durations\n\n" ~
        "Durations define the amount of intervening time in a time interval " ~
        "and are represented by the format P\\[n\\]Y\\[n\\]M\\[n\\]DT\\[n\\]H\\[n\\]M\\[n\\]S " ~
        "or P\\[n\\]W as shown on the aside\\. The capital letters are " ~
        "designators for each of the date and time elements and are not " ~
        "replaced\\.\n\n" ~
        "*P* is the duration designator \\(for *period*\\) placed at the " ~
        "start of the duration representation\\.\n\n" ~
        "*Y* is the year designator that follows the value for the number " ~
        "of calendar years\\.\n\n" ~
        "*M* is the month designator that follows the value for the number " ~
        "of calendar months\\.\n\n" ~
        "*W* is the week designator that follows the value for the number " ~
        "of weeks\\.\n\n" ~
        "*D* is the day designator that follows the value for the number " ~
        "of calendar days\\.\n\n" ~
        "*T* is the time designator that precedes the time components of " ~
        "the duration representation\\.\n\n" ~
        "*H* is the hour designator that follows the value for the number " ~
        "of hours\\.\n\n" ~
        "*M* is the minute designator that follows the value for the " ~
        "number of minutes\\.\n\n" ~
        "*S* is the second designator that follows the value for the " ~
        "number of seconds\\.\n\n" ~
        "For example, \"P3Y6M4DT12H30M5S\" represents a duration of three " ~
        "years, six months, four days, twelve hours, thirty minutes, and " ~
        "five seconds\\.\n",
        "lists=false must flatten every (possibly nested) real item to its " ~
        "own plain paragraph with no bullet/number marker, keeping the " ~
        "real text and real inline emphasis");
}

// Issue #478 real fixture 3/4 -- quotations. Verbatim excerpt from
// archiv-related German blog fixture 08 of the pinned adbar/trafilatura
// held-out corpus (fetched via `experiments/html_main_content/
// fetch_held_out.sh --emit-corpus-dir`, same real-page provenance already
// used by #477's own fixtures) -- one of the corpus's 20 real pages
// (fixture 08) has exactly one real `<blockquote>`, a genuine quoted
// newspaper excerpt about coin-toss physics ("Im Fall des Münzwurfs...")
// embedded in the article's own real prose, not a synthetic quotation
// invented for this test.
unittest {
    import effects.html_tree : parseHtml;

    string html = `<article><h1>Warum die Münze nicht fair ist</h1>` ~
        `<p>Ein letzte Woche in der Süddeutschen erschienener Artikel ` ~
        `erklärt es so:</p>` ~
        `<blockquote><p>Im Fall des Münzwurfs kommt es zur Präzession, ` ~
        `wenn die Münze nicht genau mittig geschnippt wird. Dann eiert sie ` ~
        `in der Flugphase, und das führt dazu, dass sie etwas mehr Zeit in ` ~
        `der ursprünglichen Ausrichtung verbringt und demzufolge häufiger ` ~
        `so landet, wie sie geschnipst wurde. Das Eiern der Münze ist mit ` ~
        `bloßem Auge kaum zu sehen &#8211; was von Zauberern und ` ~
        `Trickbetrügern ausgenutzt wird, die eine Münze so schnipsen ` ~
        `können, dass sie sich überhaupt nicht um sich selbst dreht, ` ~
        `sondern nur wackelt.</p></blockquote>` ~
        `<p>Das bestätigt experimentell eine Vorhersage aus der 2007 in ` ~
        `SIAM Reviews erschienenen Arbeit &#8220;Dynamical bias in the ` ~
        `coin toss&#8221; von Persi Diaconis, Susan Holmes und Richard ` ~
        `Montgomery.</p></article>`;
    auto outcome = parseHtml(cast(const(ubyte)[]) html);
    assert(outcome.isParsed);
    auto tree = outcome.tree;

    auto quotesOn = renderMarkdown(tree, MarkdownRenderOptions(quotes: true));
    assert(quotesOn ==
        "# Warum die Münze nicht fair ist\n\n" ~
        "Ein letzte Woche in der Süddeutschen erschienener Artikel erklärt " ~
        "es so:\n\n" ~
        "> Im Fall des Münzwurfs kommt es zur Präzession, wenn die Münze " ~
        "nicht genau mittig geschnippt wird\\. Dann eiert sie in der " ~
        "Flugphase, und das führt dazu, dass sie etwas mehr Zeit in der " ~
        "ursprünglichen Ausrichtung verbringt und demzufolge häufiger so " ~
        "landet, wie sie geschnipst wurde\\. Das Eiern der Münze ist mit " ~
        "bloßem Auge kaum zu sehen – was von Zauberern und Trickbetrügern " ~
        "ausgenutzt wird, die eine Münze so schnipsen können, dass sie " ~
        "sich überhaupt nicht um sich selbst dreht, sondern nur wackelt\\." ~
        "\n\n" ~
        "Das bestätigt experimentell eine Vorhersage aus der 2007 in SIAM " ~
        "Reviews erschienenen Arbeit “Dynamical bias in the coin toss” von " ~
        "Persi Diaconis, Susan Holmes und Richard Montgomery\\.\n",
        "quotes=true must render the real blockquote with a real `> ` " ~
        "marker on every wrapped line");

    auto quotesOff = renderMarkdown(tree, MarkdownRenderOptions(quotes: false));
    assert(quotesOff ==
        "# Warum die Münze nicht fair ist\n\n" ~
        "Ein letzte Woche in der Süddeutschen erschienener Artikel erklärt " ~
        "es so:\n\n" ~
        "Im Fall des Münzwurfs kommt es zur Präzession, wenn die Münze " ~
        "nicht genau mittig geschnippt wird\\. Dann eiert sie in der " ~
        "Flugphase, und das führt dazu, dass sie etwas mehr Zeit in der " ~
        "ursprünglichen Ausrichtung verbringt und demzufolge häufiger so " ~
        "landet, wie sie geschnipst wurde\\. Das Eiern der Münze ist mit " ~
        "bloßem Auge kaum zu sehen – was von Zauberern und Trickbetrügern " ~
        "ausgenutzt wird, die eine Münze so schnipsen können, dass sie " ~
        "sich überhaupt nicht um sich selbst dreht, sondern nur wackelt\\." ~
        "\n\n" ~
        "Das bestätigt experimentell eine Vorhersage aus der 2007 in SIAM " ~
        "Reviews erschienenen Arbeit “Dynamical bias in the coin toss” von " ~
        "Persi Diaconis, Susan Holmes und Richard Montgomery\\.\n",
        "quotes=false must render the real quoted text as a plain " ~
        "paragraph with no `> ` marker, keeping the real text");
}

// Issue #478 real fixture 4/4 -- code (fenced `pre` and inline `code`).
// Verbatim excerpt from the official Python documentation's "Virtual
// Environments and Packages" tutorial (docs.python.org/3/tutorial/
// venv.html, Python Software Foundation license -- real third-party
// content, test-only and never shipped, per this repository's existing
// test-fixture policy), fetched directly (the held-out corpus has *no*
// `<pre>`/`<code>` at all across any of its 20 real pages, confirmed by
// grepping every fetched page, so this fixture necessarily draws on a
// different real page). Confirmed against pinned trafilatura==2.2.0
// (`--output-format markdown`, run directly): it renders this exact real
// `<pre>` as a bare ``` fence with **no** language hint, even though the
// genuine page markup around it (`<div class="highlight-python3">`) does
// carry language information one level up from the `<pre>` -- and,
// separately, a second synthetic probe with the more common
// `<code class="language-python">` convention also produced no hint from
// trafilatura. Two different real/realistic language-hint conventions, one
// answer both times: pinned trafilatura's Markdown code output never
// includes a language hint, so this renderer's own pre-#478 bare-fence
// (no hint) behavior is kept unchanged rather than adding hint support
// this issue's own reference tool does not itself have.
unittest {
    import effects.html_tree : parseHtml;

    string html = `<article><h2>Creating Virtual Environments</h2>` ~
        `<p>The module used to create and manage virtual environments is ` ~
        `called <code class="xref py py-mod docutils literal notranslate">venv</code>. ` ~
        `<code class="xref py py-mod docutils literal notranslate">venv</code> ` ~
        `will install the Python version from which the command was run.</p>` ~
        `<p>To create a virtual environment, decide upon a directory where ` ~
        `you want to place it, and run the venv module as a script with ` ~
        `the directory path:</p>` ~
        `<div class="highlight-python3 notranslate"><div class="highlight">` ~
        `<pre>python -m venv tutorial-env</pre></div></div>` ~
        `<p>This will create the ` ~
        `<code class="docutils literal notranslate">tutorial-env</code> ` ~
        `directory if it doesn&#8217;t exist, and also create directories ` ~
        `inside it containing a copy of the Python interpreter and various ` ~
        `supporting files.</p></article>`;
    auto outcome = parseHtml(cast(const(ubyte)[]) html);
    assert(outcome.isParsed);
    auto tree = outcome.tree;

    auto codeOn = renderMarkdown(tree, MarkdownRenderOptions(code: true));
    assert(codeOn ==
        "## Creating Virtual Environments\n\n" ~
        "The module used to create and manage virtual environments is " ~
        "called `venv`\\. `venv` will install the Python version from " ~
        "which the command was run\\.\n\n" ~
        "To create a virtual environment, decide upon a directory where " ~
        "you want to place it, and run the venv module as a script with " ~
        "the directory path:\n\n" ~
        "```\n" ~
        "python -m venv tutorial-env\n" ~
        "```\n\n" ~
        "This will create the `tutorial-env` directory if it doesn’t " ~
        "exist, and also create directories inside it containing a copy " ~
        "of the Python interpreter and various supporting files\\.\n",
        "code=true must render the real inline <code> mentions with real " ~
        "backticks and the real <pre> as a real bare fenced block, matching " ~
        "pinned trafilatura==2.2.0's own no-language-hint fence syntax");

    auto codeOff = renderMarkdown(tree, MarkdownRenderOptions(code: false));
    assert(codeOff ==
        "## Creating Virtual Environments\n\n" ~
        "The module used to create and manage virtual environments is " ~
        "called venv\\. venv will install the Python version from which " ~
        "the command was run\\.\n\n" ~
        "To create a virtual environment, decide upon a directory where " ~
        "you want to place it, and run the venv module as a script with " ~
        "the directory path:\n\n" ~
        "python \\-m venv tutorial\\-env\n\n" ~
        "This will create the tutorial\\-env directory if it doesn’t " ~
        "exist, and also create directories inside it containing a copy " ~
        "of the Python interpreter and various supporting files\\.\n",
        "code=false must render both the real inline mentions and the real " ~
        "pre block as ordinary prose text -- no backticks, no fence -- " ~
        "keeping the real text");
}
