/// Release-optimized behavior pin for rich structures; this chooses no V2 syntax.
module experiments.html_markdown.rich_structure_baseline;

import effects.html_markdown : HtmlMarkdownOutputLimit, maxMarkdownBytes,
    renderMarkdown;
import effects.html_tree : HtmlFailureReason, HtmlNode, HtmlNodeKind, HtmlTree,
    maxRawBytes, parseHtml;
import std.algorithm.searching : canFind;
import std.file : readText;
import std.path : buildPath;
import std.stdio : writeln;

private void need(bool condition, string label) {
    if (!condition) throw new Exception("rich Markdown baseline: " ~ label);
}

private string fixture(string root, string name, string extension) {
    return readText(buildPath(root, name ~ extension));
}

private string exactGolden(string root, string name) {
    auto html = fixture(root, name, ".html");
    auto expected = fixture(root, name, ".md");
    auto parsed = parseHtml(cast(const(ubyte)[]) html);
    need(parsed.isParsed, name ~ " did not parse");
    auto first = renderMarkdown(parsed.tree);
    need(first == expected, name ~ " exact output changed");
    need(renderMarkdown(parsed.tree) == first, name ~ " repeat changed");
    return first;
}

private void expectParserFailure(string root, string name,
        HtmlFailureReason reason) {
    auto html = fixture(root, name, ".html");
    auto first = parseHtml(cast(const(ubyte)[]) html);
    auto second = parseHtml(cast(const(ubyte)[]) html);
    need(!first.isParsed && first.failure.reason == reason,
        name ~ " parser outcome changed");
    need(!second.isParsed && second.failure.reason == reason,
        name ~ " parser outcome was not deterministic");
}

private void parserOwnershipProof(string root) {
    auto input = fixture(root, "wikipedia-like", ".html").dup;
    auto parsed = parseHtml(cast(const(ubyte)[]) input);
    need(parsed.isParsed, "ownership input did not parse");
    auto before = renderMarkdown(parsed.tree);
    input[] = 'x';
    need(renderMarkdown(parsed.tree) == before,
        "parsed tree retained or reread caller input");
}

private void capProof() {
    auto raw = new ubyte[maxRawBytes + 1];
    raw[] = 'x';
    auto rejected = parseHtml(cast(const(ubyte)[]) raw);
    need(!rejected.isParsed &&
        rejected.failure.reason == HtmlFailureReason.rawLimit,
        "raw cap+1 did not return rawLimit");

    auto expanding = new char[maxMarkdownBytes / 2 + 1];
    expanding[] = '*';
    HtmlTree tree;
    tree.nodes = [HtmlNode(HtmlNodeKind.text, size_t.max, "",
        cast(string) expanding)];
    bool outputRejected;
    try renderMarkdown(tree);
    catch (HtmlMarkdownOutputLimit) outputRejected = true;
    need(outputRejected, "escaped output cap+1 did not throw");
}

void main(string[] args) {
    need(args.length == 1 || args.length == 2,
        "usage: rich-structure-baseline [fixture-root]");
    auto root = args.length == 2 ? args[1] :
        buildPath("experiments", "html_markdown", "fixtures", "rich");

    auto wiki = exactGolden(root, "wikipedia-like");
    auto ordinary = exactGolden(root, "ordinary-page");
    auto malformed = exactGolden(root, "malformed");

    // Exact authored goldens establish that no unrecorded prose is invented.
    need(wiki.canFind("- Known for | Analytical Engine notes") &&
        malformed.canFind("- Alpha | One") &&
        !wiki.canFind("person-box") && !wiki.canFind("firstHeading") &&
        !wiki.canFind("data-file-width") && !wiki.canFind("srcset") &&
        !wiki.canFind("cite_ref-1"),
        "table or dropped rich attributes changed");
    need(wiki.canFind("Navigation template") &&
        ordinary.canFind("preliminary figures") &&
        !wiki.canFind("navbox") && !ordinary.canFind("data-kind"),
        "box-like region behavior changed");
    need(wiki.canFind("[\\[1\\]](<#cite_note-1>)") &&
        !wiki.canFind("broken-article"),
        "citation or ID behavior changed");
    need(!ordinary.canFind("javascript:") && !ordinary.canFind("data:text") &&
        ordinary.canFind("do not run") && ordinary.canFind("blocked image"),
        "unsafe URI became active or visible fallback disappeared");
    need(wiki.canFind("![Portrait of Ada](</images/ada.jpg>)") &&
        wiki.canFind("1840 portrait by") &&
        !wiki.canFind("220") && !wiki.canFind("310") &&
        !ordinary.canFind("640") && !ordinary.canFind("480"),
        "figure, caption, or image-attribute behavior changed");

    expectParserFailure(root, "mathml",
        HtmlFailureReason.unsupportedNamespace);
    expectParserFailure(root, "oversized-depth",
        HtmlFailureReason.depthLimit);
    parserOwnershipProof(root);
    capProof();

    writeln("rich Markdown baseline: 3 exact goldens, determinism, " ~
        "URI inertness, ownership, MathML/depth/raw/output caps pass");
}
