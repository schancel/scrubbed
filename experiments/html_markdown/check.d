/// Release-active structural and safety check for the pure Markdown converter.
module experiments.html_markdown.check;

import effects.html_markdown : HtmlMarkdownOutputLimit, maxMarkdownBytes,
    renderMarkdown;
import effects.html_tree : HtmlNode, HtmlNodeKind, HtmlTree, parseHtml;
import std.algorithm.searching : canFind;
import std.file : remove, tempDir, write;
import std.path : buildPath;
import std.process : execute;
import std.stdio : writeln;
import std.uuid : randomUUID;

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

private void commonmarkProof() {
    auto path = buildPath(tempDir, "scrubbed-markdown-" ~ randomUUID.toString ~ ".md");
    scope(exit) remove(path);
    write(path, convert("<code>[evil](javascript:alert(1))\n\n" ~
        "&lt;img src=x onerror=alert(1)&gt;</code>"));
    auto parsed = execute(["pandoc", "--from=commonmark", "--to=html", path]);
    need(parsed.status == 0 && parsed.output.canFind("<code>") &&
        !parsed.output.canFind("href=\"javascript:") &&
        !parsed.output.canFind("<img"),
        "CommonMark inline code activated link or raw HTML");
}

void main(string[] args) {
    need(args.length == 1 || args.length == 2 && args[1] == "--commonmark",
        "usage: check [--commonmark]");
    golden("<h1>Title</h1><p>A &amp; <strong>bold</strong> " ~
        "<em>word</em>.</p>",
        "# Title\n\nA &amp; **bold** *word*\\.\n", "headings/emphasis/entities");
    golden("<p><a href='https://example.test/a?q=1&amp;x=2'>Go</a> " ~
        "<img alt='A [cat]' src='/img/cat.png'></p>",
        "[Go](<https://example.test/a?q=1&amp;x=2>) ![A \\[cat\\]](</img/cat.png>)\n",
        "links/images");
    golden("<a href='javascript&amp;colon;alert(1)'>x</a> " ~
        "<a href='&amp;sol;&amp;sol;evil.test'>relative</a> " ~
        "<a href='/foo&amp;copy;bar'>literal</a> " ~
        "<img alt='image' src='/foo&amp;copy;bar'>",
        "[x](<javascript&amp;colon;alert(1)>) " ~
        "[relative](<&amp;sol;&amp;sol;evil.test>) " ~
        "[literal](</foo&amp;copy;bar>) " ~
        "![image](</foo&amp;copy;bar>)\n",
        "destination entity escaping");
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
        "Before ``a`b`` after\n\n````\na```b\n<raw>\n````\n", "code delimiters");
    golden("<p><code>[evil](javascript:alert(1))\n\n" ~
        "&lt;img src=x onerror=alert(1)&gt;</code></p>",
        "`[evil](javascript:alert(1)) <img src=x onerror=alert(1)>`\n",
        "inline code cannot break into active Markdown");
    golden("<p>A<code></code>B<code>   </code>C</p>",
        "ABC\n", "empty code invents no padding");
    golden("<table><tr><th>A|B</th><th>C</th></tr><tr><td>x</td>" ~
        "<td>y&amp;z</td></tr></table>",
        "- A\\|B | C\n\n- x | y&amp;z\n", "plain table rows");
    golden("<table><tr><td><p>A</p><p>B</p></td><td>C</td></tr></table>",
        "- A B | C\n", "nested table cell blocks stay in row");
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
    golden("<a href='x\u2066y'>isolate</a> " ~
        "<a href='x\u061Cy'>mark</a> " ~
        "<img alt='joiner' src='x\u2060y'>",
        "isolate mark joiner\n", "Unicode-format targets");
    golden("<ol start='oops'><li>A</li></ol>", "1. A\n",
        "invalid ordered start");
    golden("<ol start='-2'><li>A</li></ol>", "1. A\n",
        "negative ordered start");
    golden("<p>A<br>B</p>", "A  \nB\n", "line break");
    golden("<ul><li>Outer<ul><li>Inner</li></ul></li></ul>",
        "- Outer\n  \n  - Inner\n", "nested list");
    golden("<ol start='100'><li>Outer<ul><li>Inner</li></ul></li>" ~
        "<li>Next</li></ol>",
        "100. Outer\n     \n     - Inner\n101. Next\n",
        "multi-digit ordered nested list");
    golden("<ul><li><p>First</p><p>Second</p></li></ul>",
        "- First\n  \n  Second\n", "two paragraphs in list item");
    golden("<p>Before <strong> bold </strong> and <em> word </em> after</p>",
        "Before **bold** and *word* after\n",
        "emphasis boundary spaces");
    golden("<p>A\u202eB</p><pre>C\u202eD</pre>" ~
        "<p><code>E\u202eF</code><img alt='G\u202eH' src='/image'></p>",
        "AB\n\n```\nCD\n```\n\n`EF`![GH](</image>)\n",
        "Unicode format controls absent from prose code and alt");
    golden("<pre>a<br>b</pre>", "```\na\nb\n```\n",
        "pre line break retained");

    HtmlTree synthetic;
    synthetic.nodes = [HtmlNode(HtmlNodeKind.text, size_t.max, "", "A\0B")];
    need(renderMarkdown(synthetic) == "AB\n", "NUL escaped from owned tree");
    synthetic.nodes[0].text = "A\u0085B\u2028C";
    need(renderMarkdown(synthetic) == "AB C\n",
        "Unicode controls escaped actual=" ~ renderMarkdown(synthetic));
    auto longText = new char[maxMarkdownBytes / 2 + 1];
    longText[] = '*';
    synthetic.nodes = [HtmlNode(HtmlNodeKind.text, size_t.max, "", longText.idup)];
    bool rejected;
    try renderMarkdown(synthetic);
    catch (HtmlMarkdownOutputLimit) rejected = true;
    need(rejected, "output cap did not reject expansion");
    need(!convert("<script>secret</script>").canFind("secret"),
        "hidden prose leaked");
    if (args.length == 2) commonmarkProof();
    writeln("html markdown check: exact structure, malformed, safety, cap pass");
}
