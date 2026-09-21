/// Release-active structural and safety check for the pure Markdown converter.
module experiments.html_markdown.check;

import effects.html_markdown : HtmlMarkdownOutputLimit, maxMarkdownBytes,
    renderMarkdown;
import effects.html_tree : HtmlNode, HtmlNodeKind, HtmlTree, parseHtml;
import std.algorithm.searching : canFind;
import std.stdio : writeln;

private void need(bool condition, string label) {
    if (!condition) throw new Exception("HTML Markdown check: " ~ label);
}

private string convert(string html) {
    auto parsed = parseHtml(cast(const(ubyte)[]) html);
    need(parsed.isParsed, "parse failed");
    return renderMarkdown(parsed.tree);
}

private void golden(string html, string expected, string label) {
    auto actual = convert(html);
    need(actual == expected, label ~ " expected=" ~ expected ~ " actual=" ~ actual);
    need(convert(html) == actual, label ~ " nondeterministic");
}

void main() {
    golden("<h1>Title</h1><p>A &amp; <strong>bold</strong> " ~
        "<em>word</em>.</p>",
        "# Title\n\nA &amp; **bold** *word*\\.\n", "headings/emphasis/entities");
    golden("<p><a href='https://example.test/a?q=1&amp;x=2'>Go</a> " ~
        "<img alt='A [cat]' src='/img/cat.png'></p>",
        "[Go](<https://example.test/a?q=1&x=2>) ![A \\[cat\\]](</img/cat.png>)\n",
        "links/images");
    golden("<p><a href='javascript:alert(1)'>Click</a> " ~
        "<a href='//evil.test'>bad</a> " ~
        "<img alt='safe alt' src='data:x'>" ~
        "<a href='JaVaScRiPt:x'>mixed</a></p>",
        "Click bad safe altmixed\n", "unsafe targets");
    golden("<p>&lt;script&gt;# x | y &amp; z</p>" ~
        "<script>not visible</script><style>also hidden</style>",
        "&lt;script&gt;\\# x \\| y &amp; z\n", "raw HTML and hidden text");
    golden("<ul><li>One<li>Two</ul><ol start='3'><li>A<li>B</ol>",
        "- One\n- Two\n\n3. A\n4. B\n", "malformed lists/start");
    golden("<blockquote><p>A</p><p>B</p></blockquote>",
        "> A\n> \n> B\n", "quote");
    golden("<p>Before <code>a`b</code> after</p><pre>a```b\n&lt;raw&gt;</pre>",
        "Before `` a`b `` after\n\n````\na```b\n<raw>\n````\n", "code delimiters");
    golden("<table><tr><th>A|B</th><th>C</th></tr><tr><td>x</td>" ~
        "<td>y&amp;z</td></tr></table>",
        "- A\\|B | C\n\n- x | y&amp;z\n", "plain table rows");
    golden("<p>Hi<div>there", "Hi\n\nthere\n", "malformed flow");
    golden("<p>x-[] # * _ &lt;b&gt;</p>",
        "x\\-\\[\\] \\# \\* \\_ &lt;b&gt;\n", "syntax escaping");
    golden("<a href='mailto:x@example.test'>mail</a> " ~
        "<a href='../note'>relative</a>",
        "[mail](<mailto:x@example.test>) [relative](<../note>)\n",
        "safe target allowlist");
    golden("<a href='custom:x'>custom</a> " ~
        "<a href='a b'>space</a> <a href='\\evil'>slash</a>",
        "custom space slash\n", "unsafe target forms");
    golden("<a href='x\u0085y'>control</a>", "control\n",
        "Unicode-control target");
    golden("<ol start='oops'><li>A</li></ol>", "1. A\n",
        "invalid ordered start");
    golden("<ol start='-2'><li>A</li></ol>", "1. A\n",
        "negative ordered start");
    golden("<p>A<br>B</p>", "A  \nB\n", "line break");
    golden("<ul><li>Outer<ul><li>Inner</li></ul></li></ul>",
        "- Outer\n  - Inner\n", "nested list");

    HtmlTree synthetic;
    synthetic.nodes = [HtmlNode(HtmlNodeKind.text, size_t.max, "", "A\0B")];
    need(renderMarkdown(synthetic) == "AB\n", "NUL escaped from owned tree");
    synthetic.nodes[0].text = "A\u0085B\u2028C";
    need(renderMarkdown(synthetic) == "AB C\n", "Unicode controls escaped");
    auto longText = new char[maxMarkdownBytes / 2 + 1];
    longText[] = '*';
    synthetic.nodes = [HtmlNode(HtmlNodeKind.text, size_t.max, "", longText.idup)];
    bool rejected;
    try renderMarkdown(synthetic);
    catch (HtmlMarkdownOutputLimit) rejected = true;
    need(rejected, "output cap did not reject expansion");
    need(!convert("<script>secret</script>").canFind("secret"),
        "hidden prose leaked");
    writeln("html markdown check: exact structure, malformed, safety, cap pass");
}
