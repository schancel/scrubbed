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

/// Independently-toggleable inline structural fidelity for a Markdown
/// render: whether inline emphasis (bold/italic), link targets, and image
/// sources are preserved as real Markdown syntax, or flattened to their
/// plain inline text. Issue #477 (trafilatura-parity `--formatting`/
/// `--links`/`--images`).
///
/// All three default `true`. Unlike trafilatura -- where these flags opt a
/// stripped-by-default renderer INTO richness -- this renderer's bold/
/// italic emphasis, real `[text](<href>)` links, and `![alt](<src>)` image
/// syntax were already unconditional before this struct existed (#431/
/// #438's already-shipped behavior). Flipping the *default* to strip them
/// would regress #411's 20/20 corpus result and #438's JSON-LD-fallback
/// Markdown path, which issue #477 explicitly disallows regressing. So each
/// field here opts an already-rich-by-default renderer OUT of one dimension
/// of that richness for a caller who explicitly wants plainer output --
/// same three independent dimensions trafilatura exposes, just the opposite
/// polarity. See this module's doc comment / the issue #477 PR description
/// for the fuller tradeoff.
///
/// Disabling a dimension degrades to exactly the same fallback rendering
/// this module already used for an *unsafe* link/image target: an anchor's
/// visible text with no `[...](...)` wrapping, an image's alt text with no
/// `![...](...)` wrapping. Disabling `formatting` renders `strong`/`b`/
/// `em`/`i` as a plain (unwrapped) generic element, the same as any other
/// unrecognized inline element already unwraps.
struct MarkdownRenderOptions {
    bool formatting = true;
    bool links = true;
    bool images = true;
}

private void renderChildren(const ref HtmlTree tree, size_t parent,
    ref Writer writer, size_t depth, const ref MarkdownRenderOptions options) pure;

private void renderNode(const ref HtmlTree tree, size_t index,
    ref Writer writer, size_t depth, const ref MarkdownRenderOptions options) pure {
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
    if (name == "pre") {
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
    if (name == "code") {
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
    if (name == "ul" || name == "ol") {
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
                renderNode(tree, child, writer, depth + 1, options); continue;
            }
            if (!first) writer.put("\n");
            first = false;
            Writer item;
            renderChildren(tree, child, item, depth + 1, options);
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
    if (name == "blockquote") {
        Writer quote;
        renderChildren(tree, index, quote, depth + 1, options);
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
    if (name == "tr") {
        writer.block();
        writer.put("- ");
        bool first = true;
        for (size_t child = index + 1; child < endOf(tree, index);
             child = endOf(tree, child)) {
            if (tree.nodes[child].parentIndex != index) continue;
            if (!first) writer.put(" | ");
            first = false;
            Writer cell;
            renderChildren(tree, child, cell, depth + 1, options);
            writer.put(singleLine(cell.finish()));
        }
        writer.block();
        return;
    }
    bool heading = name.length == 2 && name[0] == 'h' &&
        name[1] >= '1' && name[1] <= '6';
    bool block = heading || name == "p" || name == "div" || name == "li" ||
        name == "table";
    if (block) writer.block();
    if (heading) {
        foreach (_; 0 .. name[1] - '0') writer.put("#");
        writer.put(" ");
    }
    if (options.formatting &&
        (name == "strong" || name == "b" || name == "em" || name == "i")) {
        Writer emphasized;
        renderChildren(tree, index, emphasized, depth + 1, options);
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
        renderChildren(tree, index, writer, depth + 1, options);
        if (safe) {
            writer.put("](<");
            writer.put(markdownTarget(href));
            writer.put(">)");
        }
    } else renderChildren(tree, index, writer, depth + 1, options);
    if (block) writer.block();
}

private void renderChildren(const ref HtmlTree tree, size_t parent,
    ref Writer writer, size_t depth, const ref MarkdownRenderOptions options) pure {
    for (size_t child = parent + 1; child < endOf(tree, parent);
         child = endOf(tree, child))
        if (tree.nodes[child].parentIndex == parent)
            renderNode(tree, child, writer, depth, options);
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
