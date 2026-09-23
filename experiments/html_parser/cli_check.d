/// Release-active checks against the shipping executable; no project fixture generator.
module experiments.html_parser.cli_check;

import domain.document : Document, OutputName, SourceLocator;
import composition.compiler : compileJob;
import effects.html_tree_json_stage;
import effects.html_tree : HtmlNode, HtmlNodeKind, HtmlTree;
import effects.html_tree_export : HtmlTreeOutputLimit, serializeTreeJson;
import job.json : parseJobJson;
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
    auto fixtureSpec = parseJobJson(`{"version":3,"stages":[{"id":"extract",` ~
        `"implementation":"html-tree-json","options":{},"filters":[]}]}`);
    need(compileJob(fixtureSpec).stages.length == 1,
        "registered stage did not resolve through canonical compiler");
    bool unknownRejected;
    auto unknownSpec = parseJobJson(`{"version":3,"stages":[{"id":"extract",` ~
        `"implementation":"unknown-html-stage","options":{},"filters":[]}]}`);
    try compileJob(unknownSpec);
    catch (Exception) unknownRejected = true;
    need(unknownRejected, "unknown stage resolved");
    auto syntheticDocument = Document(SourceLocator("local-html:v1", "/tmp", "synthetic"),
        OutputName("synthetic.tree.json"));
    auto controls = new char[700_000];
    controls[] = '\u0001';
    HtmlTree syntheticTree;
    syntheticTree.nodes = [HtmlNode(HtmlNodeKind.text, size_t.max, "",
        controls.idup)];
    syntheticTree.observedBytes = controls.length + HtmlNode.sizeof;
    need(syntheticTree.observedBytes < 1024 * 1024,
        "serializer test observation exceeds parser budget");
    bool outputLimitRejected;
    try serializeTreeJson(syntheticDocument, syntheticTree);
    catch (HtmlTreeOutputLimit) outputLimitRejected = true;
    need(outputLimitRejected, "defensive serializer output cap accepted expanded data");
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
        "--format", "unknown"], 2, "tree-json");
    need(readText(output) == escapedOutput, "unsupported format changed prior output");
    expect(executable, ["extract", "--input", input, "--output", output,
        "--format", "tree-json", "--manifest", buildPath(root, "state.db")],
        2, "Unrecognized");
    need(!exists(buildPath(root, "state.db")), "manifest was created");
    write(input, new ubyte[1024 * 1024 + 1]);
    expect(executable, ["extract", "--input", input, "--output", output,
        "--format", "tree-json"], 1, "rawLimit");
    need(readText(output) == escapedOutput, "quarantine changed prior output");
    auto largeText = new char[70 * 1024];
    largeText[] = 'x';
    write(input, "<p>" ~ largeText.idup ~ "</p>");
    expect(executable, ["extract", "--input", input, "--output", output,
        "--format", "tree-json"], 0, "1 published");
    need(parseJSON(readText(output))["nodes"].array[$ - 1]["text"].str == largeText,
        "1 MiB default rejected an ordinary larger page");
    auto defaultOutput = readText(output);
    expect(executable, ["extract", "--input", input, "--output", output,
        "--format", "tree-json", "--max-html-bytes", "1024"], 1, "rawLimit");
    need(readText(output) == defaultOutput, "lowered limit replaced prior output");
    auto comment = new char[1_100_000];
    comment[] = 'x';
    write(input, "<!--" ~ comment.idup ~ "--><p>Hi</p>");
    expect(executable, ["extract", "--input", input, "--output", output,
        "--format", "tree-json"], 1, "rawLimit");
    need(readText(output) == defaultOutput, "default cap replaced prior output");
    expect(executable, ["extract", "--input", input, "--output", output,
        "--format", "tree-json", "--max-html-bytes", "2097152"], 0, "1 published");
    auto raisedOutput = readText(output);
    need(parseJSON(raisedOutput)["nodes"].array[$ - 1]["text"].str == "Hi",
        "raised CLI limit did not preserve HTML text");
    auto htmlConfig = buildPath(root, "html-config.json");
    write(htmlConfig, `{"version":3,"stages":[{"id":"extract",` ~
        `"implementation":"html-tree-json","options":` ~
        `{"max-html-bytes":2097152},"filters":[]}]}`);
    expect(executable, ["extract", "--input", input, "--output", output,
        "--format", "tree-json", "--config", htmlConfig], 0, "1 published");
    need(readText(output) == raisedOutput, "JSON and CLI HTML limits differ");
    expect(executable, ["extract", "--input", input, "--output", output,
        "--format", "tree-json", "--max-html-bytes", "0"], 2, "max-html-bytes");
    expect(executable, ["extract", "--input", input, "--output", output,
        "--format", "tree-json", "--max-html-bytes", "8388609"], 2, "limit");
    expect(executable, ["extract", "--input", input, "--output", output,
        "--format", "tree-json", "--config", htmlConfig,
        "--max-html-bytes", "2097152"], 2, "cannot be combined");
    expect(executable, ["extract", "--input", input, "--output", output,
        "--format", "tree-json", "--config="], 2, "nonempty path");
    expect(executable, ["extract", "--input", input, "--output", output,
        "--format", "tree-json", "--config=", "--max-html-bytes", "2097152"],
        2, "nonempty path");
    write(htmlConfig, `{"version":3,"stages":[{"id":"extract",` ~
        `"implementation":"html-tree-json","options":` ~
        `{"max-html-bytes":8388609},"filters":[]}]}`);
    expect(executable, ["extract", "--input", input, "--output", output,
        "--format", "tree-json", "--config", htmlConfig], 2, "limit");
    write(htmlConfig, `{"version":3,"stages":[{"id":"extract",` ~
        `"implementation":"html-markdown","options":` ~
        `{"max-html-bytes":2097152},"filters":[]}]}`);
    expect(executable, ["extract", "--input", input, "--output", output,
        "--format", "tree-json", "--config", htmlConfig], 2, "exactly one");
    need(readText(output) == raisedOutput, "invalid limit changed prior output");
    expect(executable, ["extract", "--input", input, "--output", output,
        "--format", "markdown", "--max-html-bytes", "2097152"], 0, "1 published");
    need(readText(output) == "Hi\n",
        "Markdown route did not use raised limit");
    expect(executable, ["extract", "--input", input, "--output", output,
        "--format", "markdown", "--config", htmlConfig], 0, "1 published");
    need(readText(output) == "Hi\n",
        "Markdown JSON limit differed from CLI");
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
    foreach (c; "<!--") { expanded ~= cast(ubyte)c; expanded ~= 0; }
    foreach (_; 0 .. 350_000) { expanded ~= 0x00; expanded ~= 0x4e; }
    foreach (c; "--><p>Hi</p>") { expanded ~= cast(ubyte)c; expanded ~= 0; }
    write(input, expanded);
    expect(executable, ["extract", "--input", input, "--output", output,
        "--format", "tree-json"], 1, "decodedLimit");
    need(readText(output) == utf16Output, "decoded cap replaced prior file");
    auto expandedOutput = buildPath(root, "expanded.json");
    expect(executable, ["extract", "--input", input, "--output", expandedOutput,
        "--format", "tree-json", "--charset", "utf-16le",
        "--max-html-bytes", "2097152"], 0, "1 published");
    auto expandedResult = readText(expandedOutput);
    need(parseJSON(expandedResult)["nodes"].array[$ - 1]["text"].str == "Hi",
        "raised decoded cap did not publish the page");
    write(htmlConfig, `{"version":3,"stages":[{"id":"extract",` ~
        `"implementation":"html-tree-json","options":` ~
        `{"max-html-bytes":2097152,"charset":"utf-16le"},"filters":[]}]}`);
    expect(executable, ["extract", "--input", input, "--output", expandedOutput,
        "--format", "tree-json", "--config", htmlConfig], 0, "1 published");
    need(readText(expandedOutput) == expandedResult,
        "JSON and CLI decoded HTML limits differ");
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
    string observed;
    foreach (_; 0 .. 4_000) observed ~= "<br a b c d e>";
    need(observed.length == 56_000, "observation positive fixture size");
    write(input, observed);
    expect(executable, ["extract", "--input", input, "--output", output,
        "--format", "tree-json"], 0, "1 published");
    auto withinObservation = readText(output);
    foreach (_; 4_000 .. 4_600) observed ~= "<br a b c d e>";
    need(observed.length == 64_400, "observation negative fixture size");
    write(input, observed);
    expect(executable, ["extract", "--input", input, "--output", output,
        "--format", "tree-json"], 1, "observationLimit");
    need(readText(output) == withinObservation,
        "observation cap replaced prior completed output");
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
    write(buildPath(tree, "b.html"), new ubyte[1024 * 1024 + 1]);
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
