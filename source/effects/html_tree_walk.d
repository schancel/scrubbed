/// Shared low-level `HtmlTree` walking and text primitives used by both
/// `effects.html_markdown` and `effects.extract_formats` (issue #497).
///
/// Scope is deliberately narrow: subtree bounds, attribute lookup, element
/// classification (hidden/heading), link-target safety policy, and ASCII
/// whitespace collapsing. The Markdown table/list/string-flattening
/// renderers (issue #493's territory) stay in `html_markdown.d` and must
/// never move here -- `extract_formats.d` depends on this module precisely
/// so it can share these primitives without inheriting those renderers.
module effects.html_tree_walk;

import effects.html_tree : HtmlNode, HtmlTree;
import std.uni : isControl, isFormat, isSpace;
import std.utf : UTFException;

/// End (exclusive) of `index`'s subtree in the flat pre-order node array.
package size_t endOf(const ref HtmlTree tree, size_t index) pure {
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

/// Value of the first attribute named `name`, or null when absent.
package string attribute(const ref HtmlNode node, string name) pure {
    foreach (ref const attr; node.attributes)
        if (attr.name == name) return attr.value;
    return null;
}

/// Elements whose whole subtree is never rendered as content.
package bool hiddenTag(string name) pure {
    return name == "script" || name == "style" || name == "template" || name == "head";
}

/// True for `h1`..`h6`, setting `level` to 1..6.
package bool headingLevel(string name, out int level) pure {
    if (name.length != 2 || name[0] != 'h' || name[1] < '1' || name[1] > '6') return false;
    level = name[1] - '0';
    return true;
}

package bool asciiEqualIgnoreCase(string value, string expected) pure nothrow @nogc {
    if (value.length != expected.length) return false;
    foreach (i, c; value) {
        ubyte folded = cast(ubyte) c;
        if (folded >= 'A' && folded <= 'Z') folded += 'a' - 'A';
        if (folded != cast(ubyte) expected[i]) return false;
    }
    return true;
}

package bool safeScheme(string scheme) pure nothrow @nogc {
    switch (scheme.length) {
        case 4: return asciiEqualIgnoreCase(scheme, "http");
        case 5: return asciiEqualIgnoreCase(scheme, "https");
        case 6: return asciiEqualIgnoreCase(scheme, "mailto");
        default: return false;
    }
}

/// Link/image target policy: only a same-page relative reference or an
/// explicit http(s)/mailto scheme is emitted as a real target; anything else
/// (javascript:, data:, a protocol-relative `//host/...`, control/format/
/// space characters) is rejected, so an untrusted page can never inject an
/// unexpected URI scheme into rendered output.
package bool safeTarget(string target) pure {
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
    assert(!safeTarget("hétp:x"));
}

/// ASCII HTML whitespace (space, LF, CR, tab, form feed).
package bool white(char c) pure {
    return c == ' ' || c == '\n' || c == '\r' || c == '\t' || c == '\f';
}

/// Collapse every ASCII whitespace run to one space and trim both ends;
/// returns null for an empty or all-whitespace input. The result is never
/// longer than `input`, so callers' own output-size limits (enforced when
/// they built `input`) already bound it -- no separate limit is needed here.
package string singleLine(string input) pure {
    import std.exception : assumeUnique;
    char[] bytes;
    bool pending;
    size_t runStart;
    foreach (i, c; input) {
        if (white(c)) {
            if (!pending) bytes ~= input[runStart .. i];
            pending = true;
        } else if (pending) {
            if (bytes.length) bytes ~= ' ';
            pending = false;
            runStart = i;
        }
    }
    if (!pending) bytes ~= input[runStart .. $];
    if (!bytes.length) return null;
    return assumeUnique(bytes);
}

unittest {
    assert(singleLine("") is null);
    assert(singleLine(" \t\r\n\f") is null);
    assert(singleLine("  alpha \t beta\r\n gamma  ") == "alpha beta gamma");
    assert(singleLine("é\t界") == "é 界");
    assert(singleLine("plain") == "plain");
    assert(singleLine(" x ") == " x ",
        "only ASCII whitespace collapses; NBSP is content");
}

unittest {
    int level;
    assert(headingLevel("h1", level) && level == 1);
    assert(headingLevel("h6", level) && level == 6);
    assert(!headingLevel("h0", level));
    assert(!headingLevel("h7", level));
    assert(!headingLevel("hr", level));
    assert(!headingLevel("h10", level));
    foreach (name; ["script", "style", "template", "head"]) assert(hiddenTag(name));
    assert(!hiddenTag("body"));
    assert(!hiddenTag("noscript"));
}
