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

    void put(scope const(char)[] value) pure {
        if (value.length > maxMarkdownBytes - bytes.length)
            throw new HtmlMarkdownOutputLimit;
        bytes ~= value;
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
}

private bool white(char c) pure {
    return c == ' ' || c == '\n' || c == '\r' || c == '\t' || c == '\f';
}

private string clean(string input, bool code = false) pure {
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
    foreach (char c; input) {
        if (white(c)) { pending = true; continue; }
        if (pending && writer.bytes.length) writer.put(" ");
        pending = false;
        writer.put(cast(string)(&c)[0 .. 1]);
    }
    return writer.finish();
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
    foreach (char c; target) {
        if (c == '&') writer.put("&amp;");
        else writer.put(cast(string)(&c)[0 .. 1]);
    }
    return writer.finish();
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

private void renderChildren(const ref HtmlTree tree, size_t parent,
    ref Writer writer, size_t depth) pure;

private void renderNode(const ref HtmlTree tree, size_t index,
    ref Writer writer, size_t depth) pure {
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
        auto src = attribute(node, "src");
        if (safeTarget(src)) {
            writer.put("![");
            writer.put(alt);
            writer.put("](<");
            writer.put(markdownTarget(src));
            writer.put(">)");
        } else writer.putText(alt);
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
                renderNode(tree, child, writer, depth + 1); continue;
            }
            if (!first) writer.put("\n");
            first = false;
            Writer item;
            renderChildren(tree, child, item, depth + 1);
            item.trim();
            size_t prefixLength = 2;
            if (name == "ul") writer.put("- ");
            else {
                auto ordinalText = to!string(ordinal);
                prefixLength += ordinalText.length;
                writer.put(ordinalText);
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
        renderChildren(tree, index, quote, depth + 1);
        quote.trim();
        writer.block();
        writer.put("> ");
        foreach (char c; quote.bytes) {
            writer.put(cast(string)(&c)[0 .. 1]);
            if (c == '\n') writer.put("> ");
        }
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
            renderChildren(tree, child, cell, depth + 1);
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
    if (name == "strong" || name == "b" || name == "em" || name == "i") {
        Writer emphasized;
        renderChildren(tree, index, emphasized, depth + 1);
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
    if (name == "a") {
        auto href = attribute(node, "href");
        const safe = safeTarget(href);
        if (safe) writer.put("[");
        renderChildren(tree, index, writer, depth + 1);
        if (safe) {
            writer.put("](<");
            writer.put(markdownTarget(href));
            writer.put(">)");
        }
    } else renderChildren(tree, index, writer, depth + 1);
    if (block) writer.block();
}

private void renderChildren(const ref HtmlTree tree, size_t parent,
    ref Writer writer, size_t depth) pure {
    for (size_t child = parent + 1; child < endOf(tree, parent);
         child = endOf(tree, child))
        if (tree.nodes[child].parentIndex == parent)
            renderNode(tree, child, writer, depth);
}

/// Convert a bounded selected tree without reading HTML or publishing output.
/// An output-cap exception exposes no partial string to the caller.
string renderMarkdown(const ref HtmlTree tree) pure {
    Writer writer;
    for (size_t i; i < tree.nodes.length; i = endOf(tree, i)) {
        if (tree.nodes[i].parentIndex == size_t.max)
            renderNode(tree, i, writer, 0);
    }
    writer.trim();
    if (writer.bytes.length) writer.put("\n");
    // Do not retain the growable buffer's spare capacity in the public result.
    return writer.bytes.idup;
}
