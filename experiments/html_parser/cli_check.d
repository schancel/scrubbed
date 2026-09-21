/// Release-active checks against the shipping executable; no project fixture generator.
module experiments.html_parser.cli_check;

import domain.document : Document, OutputName, SourceLocator;
import effects.html_tree_json_stage : htmlTreeJsonPlan;
import stages.config : buildConfigV2;
import stages.registry : availableStages;
import core.stdc.stdlib : free;
import core.sys.posix.stdlib : realpath;
import core.sys.posix.sys.resource : getrusage, rusage, RUSAGE_CHILDREN;
import std.algorithm.searching : canFind;
import std.conv : to;
import std.file : exists, mkdir, readText, rmdirRecurse, symlink, tempDir, write;
import std.json : parseJSON;
import std.path : buildPath;
import std.process : execute;
import std.stdio : writeln;
import std.string : fromStringz, toStringz;
import std.uuid : randomUUID;

private void need(bool condition, string label) {
    if (!condition) throw new Exception("HTML CLI check: " ~ label);
}

private void expect(string executable, string[] args, int code, string text) {
    auto result = execute([executable] ~ args);
    need(result.status == code && result.output.canFind(text),
        "unexpected exit/output for " ~ args[0] ~ ": " ~ result.output);
}

private string canonical(string path) {
    auto resolved = realpath(path.toStringz, null);
    need(resolved !is null, "realpath");
    scope(exit) free(resolved);
    return fromStringz(resolved).idup;
}

int main(string[] args) {
    need(args.length == 2, "usage: cli_check <release executable>");
    need(availableStages().find("html-tree-json") !is null,
        "concrete effects module failed self-registration");
    need(htmlTreeJsonPlan().stages.length == 1,
        "registered stage did not resolve through buildConfigV2");
    bool unknownRejected;
    try buildConfigV2(`{"version":2,"stages":[{"name":"unknown-html-stage"}]}`);
    catch (Exception) unknownRejected = true;
    need(unknownRejected, "unknown stage resolved");
    auto executable = args[1];
    auto root = buildPath(tempDir, "scrubbed-html-cli-" ~ randomUUID.toString);
    mkdir(root);
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto input = buildPath(root, "one.html");
    auto output = buildPath(root, "one.json");
    write(input, "<p title='a&amp;b'>Hi</p>");
    expect(executable, ["extract", "--input", input, "--output", output,
        "--format", "tree-json"], 0, "1 published");
    auto sourceRoot = canonical(root);
    auto document = Document(SourceLocator("local-html:v1", sourceRoot, "one.html"),
        OutputName("one.html.tree.json"));
    auto expected = `{"version":"tree-json:v1","documentId":"` ~ document.id.text ~
        `","source":{"namespace":"local-html:v1","sourceKey":"` ~ sourceRoot ~
        `","recordKey":"one.html"},"outputName":"one.html.tree.json","nodes":[` ~
        `{"kind":"element","parent":null,"name":"html","attributes":[],"text":""},` ~
        `{"kind":"element","parent":0,"name":"head","attributes":[],"text":""},` ~
        `{"kind":"element","parent":0,"name":"body","attributes":[],"text":""},` ~
        `{"kind":"element","parent":2,"name":"p","attributes":[{"name":"title","value":"a&b"}],"text":""},` ~
        `{"kind":"text","parent":3,"name":"","attributes":[],"text":"Hi"}]}` ~ "\n";
    need(readText(output) == expected,
        "exact normal golden\nexpected: " ~ expected ~ "actual: " ~ readText(output));
    write(input, "<p>Hi<div>x");
    expect(executable, ["extract", "--input", input, "--output", output,
        "--format", "tree-json"], 0, "1 published");
    auto malformed = `{"version":"tree-json:v1","documentId":"` ~
        document.id.text ~ `","source":{"namespace":"local-html:v1","sourceKey":"` ~
        sourceRoot ~ `","recordKey":"one.html"},"outputName":"one.html.tree.json","nodes":[` ~
        `{"kind":"element","parent":null,"name":"html","attributes":[],"text":""},` ~
        `{"kind":"element","parent":0,"name":"head","attributes":[],"text":""},` ~
        `{"kind":"element","parent":0,"name":"body","attributes":[],"text":""},` ~
        `{"kind":"element","parent":2,"name":"p","attributes":[],"text":""},` ~
        `{"kind":"text","parent":3,"name":"","attributes":[],"text":"Hi"},` ~
        `{"kind":"element","parent":2,"name":"div","attributes":[],"text":""},` ~
        `{"kind":"text","parent":5,"name":"","attributes":[],"text":"x"}]}` ~ "\n";
    need(readText(output) == malformed,
        "exact malformed golden\nactual: " ~ readText(output));
    write(input, "<p>A\"\\B</p>");
    expect(executable, ["extract", "--input", input, "--output", output,
        "--format", "tree-json"], 0, "1 published");
    auto escapedOutput = readText(output);
    need(parseJSON(escapedOutput)["nodes"].array[$ - 1]["text"].str == "A\"\\B" &&
        escapedOutput.canFind(`"text":"A\"\\B"`), "text JSON escaping");
    write(input, cast(const(ubyte)[])"<p>A\0B</p>");
    expect(executable, ["extract", "--input", input, "--output", output,
        "--format", "tree-json"], 1, "binaryControl@");
    need(readText(output) == escapedOutput, "NUL quarantine replaced prior output");
    expect(executable, ["extract", "--input", input, "--output", output,
        "--format", "markdown"], 2, "tree-json");
    need(readText(output) == escapedOutput, "unsupported format changed prior output");
    expect(executable, ["extract", "--input", input, "--output", output,
        "--format", "tree-json", "--manifest", buildPath(root, "state.db")],
        2, "Unrecognized");
    need(!exists(buildPath(root, "state.db")), "manifest was created");
    write(input, new ubyte[64 * 1024 + 1]);
    expect(executable, ["extract", "--input", input, "--output", output,
        "--format", "tree-json"], 1, "rawLimit");
    need(readText(output) == escapedOutput, "quarantine changed prior output");
    write(input, cast(const(ubyte)[])"\xef\xbb\xbf<p>BOM</p>");
    expect(executable, ["extract", "--input", input, "--output", output,
        "--format", "tree-json"], 0, "1 published");
    need(readText(output).canFind(`"text":"BOM"`), "UTF-8 BOM text");
    ubyte[] utf16 = [0xff, 0xfe];
    foreach (c; "<p>UTF16</p>") { utf16 ~= cast(ubyte)c; utf16 ~= 0; }
    write(input, utf16);
    expect(executable, ["extract", "--input", input, "--output", output,
        "--format", "tree-json", "--charset", "utf-16le"], 0, "1 published");
    auto utf16Output = readText(output);
    need(utf16Output.canFind(`"text":"UTF16"`), "UTF-16LE declared text");
    expect(executable, ["extract", "--input", input, "--output", output,
        "--format", "tree-json", "--charset", "shift_jis"], 1,
        "unsupportedCharset");
    need(readText(output) == utf16Output, "unsupported charset replaced prior file");
    write(input, "<p>bad\xff</p>");
    expect(executable, ["extract", "--input", input, "--output", output,
        "--format", "tree-json"], 1, "malformedUnicode@");
    need(readText(output) == utf16Output, "invalid UTF-8 replaced prior file");
    auto link = buildPath(root, "link.html");
    symlink(input, link);
    expect(executable, ["extract", "--input", link, "--output", output,
        "--format", "tree-json"], 2, "plain path");
    need(readText(output) == utf16Output, "input symlink replaced prior file");
    ubyte[] expanded = [0xff, 0xfe];
    foreach (_; 0 .. 22_000) { expanded ~= 0x00; expanded ~= 0x4e; }
    write(input, expanded);
    expect(executable, ["extract", "--input", input, "--output", output,
        "--format", "tree-json"], 1, "decodedLimit");
    need(readText(output) == utf16Output, "decoded cap replaced prior file");
    string deep;
    foreach (_; 0 .. 130) deep ~= "<b>";
    foreach (_; 0 .. 130) deep ~= "</b>";
    write(input, deep);
    expect(executable, ["extract", "--input", input, "--output", output,
        "--format", "tree-json"], 1, "depthLimit");
    string wide;
    foreach (_; 0 .. 8192) wide ~= "<br>";
    write(input, wide);
    expect(executable, ["extract", "--input", input, "--output", output,
        "--format", "tree-json"], 1, "nodeLimit");
    string attributed = "<p";
    foreach (i; 0 .. 257) attributed ~= " a" ~ i.to!string ~ "='x'";
    attributed ~= ">hi</p>";
    write(input, attributed);
    expect(executable, ["extract", "--input", input, "--output", output,
        "--format", "tree-json"], 1, "attributeLimit");
    need(readText(output) == utf16Output, "native cap replaced prior file");
    auto tree = buildPath(root, "tree");
    mkdir(tree);
    write(buildPath(tree, "a.html"), "<p>A</p>");
    write(buildPath(tree, "b.html"), "<p>B</p>");
    auto treeOutput = buildPath(root, "tree-output");
    expect(executable, ["extract", "--input", tree, "--output", treeOutput,
        "--format", "tree-json"], 0, "2 published");
    need(readText(buildPath(treeOutput, "a.html.tree.json")).canFind(`"text":"A"`),
        "tree first output");
    need(readText(buildPath(treeOutput, "b.html.tree.json")).canFind(`"text":"B"`),
        "tree second output");
    auto priorA = readText(buildPath(treeOutput, "a.html.tree.json"));
    auto priorB = readText(buildPath(treeOutput, "b.html.tree.json"));
    write(buildPath(tree, "b.html"), new ubyte[64 * 1024 + 1]);
    expect(executable, ["extract", "--input", tree, "--output", treeOutput,
        "--format", "tree-json"], 1, "rawLimit");
    need(readText(buildPath(treeOutput, "a.html.tree.json")) == priorA &&
        readText(buildPath(treeOutput, "b.html.tree.json")) == priorB,
        "incomplete tree changed prior completed/quarantined outputs");
    auto outputLink = buildPath(root, "output-link");
    symlink(treeOutput, outputLink);
    expect(executable, ["extract", "--input", tree, "--output", outputLink,
        "--format", "tree-json"], 2, "must not be a symlink");
    expect(executable, ["extract", "--input", tree,
        "--output", buildPath(tree, "inside"), "--format", "tree-json"],
        2, "inside input tree");
    need(!exists(buildPath(tree, "inside")), "inside-tree output created");
    auto same = buildPath(root, "same.html");
    write(same, "<p>same</p>");
    expect(executable, ["extract", "--input", same, "--output", same,
        "--format", "tree-json"], 2, "aliases input");
    need(readText(same) == "<p>same</p>", "alias changed input");
    rusage usage;
    need(getrusage(RUSAGE_CHILDREN, &usage) == 0, "child RSS measurement");
    // LDC's Darwin rusage names the post-timeval fields ru_opaque; index 0
    // is the ABI's ru_maxrss, in bytes on macOS.
    writeln("HTML CLI checks passed; child peak RSS ", usage.ru_opaque[0], " bytes");
    return 0;
}
