/// Release-active checks against the shipping Markdown extraction route.
module experiments.html_markdown.cli_check;

import std.algorithm.searching : canFind;
import std.conv : to;
import std.file : SpanMode, dirEntries, exists, getSize, mkdir, readText, rmdirRecurse,
    symlink, tempDir, write;
import std.path : buildPath;
import std.process : execute;
import std.stdio : writeln;
import std.uuid : randomUUID;
import core.sys.posix.sys.stat : chmod;
import core.sys.posix.unistd : link;
import std.string : toStringz;

private void need(bool condition, string label) {
    if (!condition) throw new Exception("Markdown CLI check: " ~ label);
}

private void expect(string executable, string input, string output, string format,
    int code, string message, string charset = null) {
    string[] command = [executable, "extract", "--input", input, "--output",
        output, "--format", format];
    if (charset !is null) command ~= ["--charset", charset];
    auto result = execute(command);
    need(result.status == code && result.output.canFind(message),
        "unexpected exit/output: " ~ result.output);
}

private void golden(string executable, string input, string output, string html,
    string expected, string label) {
    write(input, html);
    expect(executable, input, output, "markdown", 0, "1 published");
    need(readText(output) == expected, label ~ " actual=" ~ readText(output));
}

int main(string[] args) {
    need(args.length == 2, "usage: cli_check <release executable>");
    auto executable = args[1];
    auto root = buildPath(tempDir, "scrubbed-markdown-cli-" ~ randomUUID.toString);
    mkdir(root);
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto input = buildPath(root, "one.html");
    auto output = buildPath(root, "chosen.name");

    golden(executable, input, output,
        "<h1>Title</h1><p>A &amp; <strong>bold</strong> " ~
        "<em>word</em>.</p>",
        "# Title\n\nA &amp; **bold** *word*\\.\n", "structure and explicit path");
    golden(executable, input, output,
        "<ul><li>One<li>Two</ul><ol start='3'><li>A<li>B</ol>" ~
        "<table><tr><td>x|y</td><td>z</td></tr></table>",
        "- One\n- Two\n\n3. A\n4. B\n\n- x\\|y | z\n", "malformed lists and table");
    golden(executable, input, output,
        "<p><a href='javascript:alert(1)'>Click</a> " ~
        "<a href='https://example.test'>Safe</a> " ~
        "<img alt='alt' src='data:x'></p>",
        "Click [Safe](<https://example.test>) alt\n", "unsafe targets");
    golden(executable, input, output,
        "<blockquote><p>A</p><p>B</p></blockquote><pre>a```b\n&lt;raw&gt;</pre>",
        "> A\n> \n> B\n\n````\na```b\n<raw>\n````\n",
        "quote and code fences");
    ubyte[] utf16 = [0xff, 0xfe];
    foreach (c; "<p>UTF16</p>") { utf16 ~= cast(ubyte)c; utf16 ~= 0; }
    write(input, utf16);
    expect(executable, input, output, "markdown", 0, "1 published", "utf-16le");
    need(readText(output) == "UTF16\n", "declared charset");
    expect(executable, input, output, "markdown", 1, "unsupportedCharset", "shift_jis");
    need(readText(output) == "UTF16\n", "unsupported charset replaced output");
    auto prior = readText(output);

    // Many nested long ordered-list markers multiply the indentation on br.
    // The admitted raw input stays small while rendered output exceeds 4 MiB.
    string expanded;
    foreach (_; 0 .. 55) expanded ~= "<ol start='9223372036854775807'><li>";
    foreach (_; 0 .. 4_000) expanded ~= "<br>x";
    foreach (_; 0 .. 55) expanded ~= "</li></ol>";
    need(expanded.length < 64 * 1024, "output-limit input exceeded raw cap");
    write(input, expanded);
    auto expansion = execute([executable, "extract", "--input", input,
        "--output", output, "--format", "markdown"]);
    need(expansion.status == 1 && expansion.output.canFind("outputLimit"),
        "expanded input did not quarantine: " ~ expansion.output ~
        " output bytes=" ~ getSize(output).to!string);
    need(readText(output) == prior, "output limit replaced prior output");

    write(input, cast(const(ubyte)[])"<p>A\0B</p>");
    expect(executable, input, output, "markdown", 1, "binaryControl@");
    need(readText(output) == prior, "NUL quarantine replaced output");
    write(input, "<p>bad\xff</p>");
    expect(executable, input, output, "markdown", 1, "malformedUnicode@");
    need(readText(output) == prior, "decode quarantine replaced output");
    write(input, new ubyte[64 * 1024 + 1]);
    expect(executable, input, output, "markdown", 1, "rawLimit");
    need(readText(output) == prior, "raw limit replaced output");
    string deep;
    foreach (_; 0 .. 130) deep ~= "<b>";
    foreach (_; 0 .. 130) deep ~= "</b>";
    write(input, deep);
    expect(executable, input, output, "markdown", 1, "depthLimit");
    need(readText(output) == prior, "depth limit replaced output");
    expect(executable, input, output, "unknown", 2, "tree-json");
    need(readText(output) == prior, "unknown format replaced output");

    write(input, "<p>alias</p>");
    expect(executable, input, input, "markdown", 2, "aliases input");
    need(readText(input) == "<p>alias</p>", "hard alias changed input");
    auto hardAlias = buildPath(root, "hard-alias.html");
    need(link(input.toStringz, hardAlias.toStringz) == 0, "create hard link");
    expect(executable, input, hardAlias, "markdown", 2, "aliases input");
    need(readText(input) == "<p>alias</p>", "hard-linked output changed input");
    auto link = buildPath(root, "link.html");
    symlink(input, link);
    expect(executable, link, output, "markdown", 2, "plain path");
    need(readText(output) == prior, "symlink input replaced output");
    auto outputLink = buildPath(root, "out-link");
    symlink(output, outputLink);
    expect(executable, input, outputLink, "markdown", 2, "symlink");
    need(readText(output) == prior, "symlink output changed target");

    auto tree = buildPath(root, "tree");
    mkdir(tree);
    write(buildPath(tree, "a.html"), "<p>A</p>");
    write(buildPath(tree, "b.html"), "<p>B</p>");
    auto destination = buildPath(root, "markdown-tree");
    expect(executable, tree, destination, "markdown", 0, "2 published");
    need(readText(buildPath(destination, "a.html.md")) == "A\n" &&
        readText(buildPath(destination, "b.html.md")) == "B\n",
        "directory .md names/bytes");
    need(!exists(buildPath(destination, "a.html.tree.json")),
        "Markdown emitted tree-json suffix");
    write(buildPath(tree, "b.html"), new ubyte[64 * 1024 + 1]);
    expect(executable, tree, destination, "markdown", 1, "rawLimit");
    need(readText(buildPath(destination, "b.html.md")) == "B\n",
        "directory quarantine replaced prior output");

    // Preflight accepts this existing plain directory and file. The sink's
    // exclusive temporary open then fails, preserving the prior destination.
    auto blocked = buildPath(root, "blocked");
    mkdir(blocked);
    auto blockedOutput = buildPath(blocked, "prior.md");
    write(blockedOutput, "prior\n");
    write(input, "<p>new</p>");
    need(chmod(blocked.toStringz, 0x16D) == 0, "make destination read-only");
    scope(exit) chmod(blocked.toStringz, 0x1ED);
    expect(executable, input, blockedOutput, "markdown", 2,
        "cannot create atomic output temporary");
    need(readText(blockedOutput) == "prior\n", "sink-open failure replaced prior output");
    foreach (entry; dirEntries(blocked, SpanMode.shallow))
        need(!entry.name.canFind(".scrubbed-"), "sink-open failure left temporary");

    writeln("markdown CLI check: release binary structure, safety, naming, quarantine, atomicity pass");
    return 0;
}
