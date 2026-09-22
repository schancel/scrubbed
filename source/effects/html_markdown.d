/// Bounded mechanical Markdown rendering of the D-owned selected HTML tree.
module effects.html_markdown;

import effects.html_tree : HtmlNode, HtmlNodeKind, HtmlTree;
import std.ascii : toLower;
import std.conv : to;
import std.uni : isControl, isFormat, isSpace;
import std.utf : UTFException, encode;

enum size_t maxMarkdownBytes = 4 * 1024 * 1024;

class HtmlMarkdownOutputLimit : Exception {
    this() { super("Markdown output exceeds 4 MiB"); }
}

private struct Writer {
    char[] bytes;

    void put(string value) {
        if (value.length > maxMarkdownBytes - bytes.length)
            throw new HtmlMarkdownOutputLimit;
        bytes ~= value;
    }

    void putText(string value) {
        if (value.length && bytes.length && bytes[$ - 1] == ' ' &&
            value[0] == ' ') put(value[1 .. $]);
        else put(value);
    }

    void trim() {
        while (bytes.length && (bytes[$ - 1] == ' ' || bytes[$ - 1] == '\n'))
            bytes.length--;
    }

    void block() {
        trim();
        if (bytes.length) put("\n\n");
    }

    string result() { return bytes.idup; }
}

private bool white(char c) {
    return c == ' ' || c == '\n' || c == '\r' || c == '\t' || c == '\f';
}

private string clean(string input, bool code = false) {
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
    return writer.result();
}

private string singleLine(string input) {
    Writer writer;
    bool pending;
    foreach (char c; input) {
        if (white(c)) { pending = true; continue; }
        if (pending && writer.bytes.length) writer.put(" ");
        pending = false;
        writer.put(cast(string)(&c)[0 .. 1]);
    }
    return writer.result();
}

private string attribute(const ref HtmlNode node, string name) {
    foreach (ref const attr; node.attributes)
        if (attr.name == name) return attr.value;
    return null;
}

private bool safeTarget(string target) {
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
    if (colon < target.length && target[colon] == ':') {
        auto scheme = target[0 .. colon];
        foreach (char c; scheme)
            if ((c < 'A' || c > 'Z') && (c < 'a' || c > 'z')) return false;
        char[] lowered;
        foreach (char c; scheme) lowered ~= toLower(c);
        return lowered == "http" || lowered == "https" || lowered == "mailto";
    }
    return true;
}

private string markdownTarget(string target) {
    Writer writer;
    foreach (char c; target) {
        if (c == '&') writer.put("&amp;");
        else writer.put(cast(string)(&c)[0 .. 1]);
    }
    return writer.result();
}

private size_t endOf(const ref HtmlTree tree, size_t index) {
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

private string nodeText(const ref HtmlTree tree, size_t index) {
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
    return writer.result();
}

private size_t longestRun(string value, char marker) {
    size_t current, longest;
    foreach (char c; value) {
        current = c == marker ? current + 1 : 0;
        if (current > longest) longest = current;
    }
    return longest;
}

private void renderChildren(const ref HtmlTree tree, size_t parent,
    ref Writer writer, size_t depth);

private void renderNode(const ref HtmlTree tree, size_t index,
    ref Writer writer, size_t depth) {
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
        if (safeTarget(src)) writer.put("![" ~ alt ~ "](<" ~
            markdownTarget(src) ~ ">)");
        else writer.putText(alt);
        return;
    }
    if (name == "pre") {
        auto content = clean(nodeText(tree, index), true);
        auto fence = new char[longestRun(content, '`') + 1 > 3 ?
            longestRun(content, '`') + 1 : 3];
        fence[] = '`';
        writer.block();
        writer.put(fence.idup ~ "\n" ~ content);
        if (!content.length || content[$ - 1] != '\n') writer.put("\n");
        writer.put(fence.idup);
        writer.block();
        return;
    }
    if (name == "code") {
        auto content = singleLine(clean(nodeText(tree, index), true));
        if (!content.length) return;
        auto ticks = new char[longestRun(content, '`') + 1];
        ticks[] = '`';
        auto delimiter = ticks.idup;
        if (content[0] == '`' || content[$ - 1] == '`')
            writer.put(delimiter ~ " " ~ content ~ " " ~ delimiter);
        else writer.put(delimiter ~ content ~ delimiter);
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
            auto prefix = name == "ul" ? "- " : to!string(ordinal) ~ ". ";
            if (ordinal < long.max) ++ordinal;
            writer.put(prefix);
            auto itemValue = item.result();
            foreach (char c; itemValue) {
                writer.put(cast(string)(&c)[0 .. 1]);
                if (c == '\n') {
                    foreach (_; 0 .. prefix.length) writer.put(" ");
                }
            }
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
            writer.put(singleLine(cell.result()));
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
        auto content = emphasized.result();
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
        if (safeTarget(href)) writer.put("[");
        renderChildren(tree, index, writer, depth + 1);
        if (safeTarget(href)) writer.put("](<" ~ markdownTarget(href) ~ ">)");
    } else renderChildren(tree, index, writer, depth + 1);
    if (block) writer.block();
}

private void renderChildren(const ref HtmlTree tree, size_t parent,
    ref Writer writer, size_t depth) {
    for (size_t child = parent + 1; child < endOf(tree, parent);
         child = endOf(tree, child))
        if (tree.nodes[child].parentIndex == parent)
            renderNode(tree, child, writer, depth);
}

/// Convert a bounded selected tree without reading HTML or publishing output.
/// An output-cap exception exposes no partial string to the caller.
string renderMarkdown(const ref HtmlTree tree) {
    Writer writer;
    for (size_t i; i < tree.nodes.length; i = endOf(tree, i)) {
        if (tree.nodes[i].parentIndex == size_t.max)
            renderNode(tree, i, writer, 0);
    }
    writer.trim();
    if (writer.bytes.length) writer.put("\n");
    return writer.result();
}
