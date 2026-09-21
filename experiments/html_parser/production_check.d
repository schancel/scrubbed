// Release-active contract checks for the restricted production Lexbor wrapper.
module experiments.html_parser.production_check;

import effects.html_tree;
import text.decoding : QuarantineReason;
import std.conv : to;
import std.digest.sha : sha256Of;
import std.file : read;
import std.format : format;
import std.stdio : writeln;
import core.memory : GC;
import core.sys.posix.sys.resource : getrusage, rusage, RUSAGE_SELF;
import core.thread : Thread;

private void require(bool condition, string message) {
    if (!condition) throw new Exception(message);
}

private void expectFailure(const(ubyte)[] raw, HtmlFailureReason reason,
    string charset = null) {
    auto result = parseHtml(raw, charset, "production-check");
    require(!result.isParsed && result.failure.reason == reason,
        "wrong failure: " ~ to!string(reason));
}

private bool hasText(ref const(HtmlTree) tree, string text) {
    foreach (ref const node; tree.nodes)
        if (node.kind == HtmlNodeKind.text && node.text == text) return true;
    return false;
}

private Thread independentTreeWorker(size_t index, bool[] passed) {
    return new Thread(() {
        foreach (_; 0 .. 100) {
            auto parsed = parseHtml(cast(const(ubyte)[])
                "<x-note data-id='a&amp;b'>Hi</x-note>");
            if (!parsed.isParsed || !hasText(parsed.tree, "Hi")) return;
        }
        passed[index] = true;
    });
}

void main(string[] args) {
    require(args.length <= 2, "usage: production_check [pinned-WPT-file]");
    // Exact selected observation checks every accessor used by the wrapper:
    // qualified element name, first/next attribute, attribute name/value,
    // and text bytes. The returned bytes survive native destroy and mutation
    // of the caller-owned raw input.
    ubyte[] input = cast(ubyte[]) "<x-note data-id='a&amp;b' disabled>Hi</x-note>".dup;
    auto result = parseHtml(input, null, "golden");
    require(result.isParsed, "golden parse failed");
    auto tree = result.tree;
    require(tree.nodes.length == 5, "unexpected selected tree size");
    require(tree.nodes[0].name == "html" && tree.nodes[0].parentIndex == size_t.max,
        "html root mismatch");
    require(tree.nodes[1].name == "head" && tree.nodes[1].parentIndex == 0,
        "head mismatch");
    require(tree.nodes[2].name == "body" && tree.nodes[2].parentIndex == 0,
        "body mismatch");
    require(tree.nodes[3].name == "x-note" && tree.nodes[3].parentIndex == 2,
        "custom element mismatch");
    require(tree.nodes[3].attributes == [HtmlAttribute("data-id", "a&b"),
        HtmlAttribute("disabled", "")], "attribute name/value/order mismatch");
    require(tree.nodes[4].kind == HtmlNodeKind.text &&
        tree.nodes[4].parentIndex == 3 && tree.nodes[4].text == "Hi",
        "text accessor mismatch");
    input[] = 0;
    require(tree.nodes[3].name == "x-note" &&
        tree.nodes[3].attributes[0].value == "a&b" && tree.nodes[4].text == "Hi",
        "native/input alias escaped");
    require(tree.observedBytes <= maxObservationBytes, "observation exceeds cap");
    bool badGoldenRejected;
    try expectFailure(cast(const(ubyte)[]) "<p>valid</p>",
        HtmlFailureReason.rawLimit);
    catch (Exception) badGoldenRejected = true;
    require(badGoldenRejected, "deliberately wrong golden was accepted");

    auto list = parseHtml(cast(const(ubyte)[]) "<ul><li>A<li>B</ul>");
    require(list.isParsed && list.tree.nodes.length == 8, "malformed list size");
    require(list.tree.nodes[3].name == "ul" &&
        list.tree.nodes[4].name == "li" && list.tree.nodes[4].parentIndex == 3 &&
        list.tree.nodes[5].text == "A" && list.tree.nodes[5].parentIndex == 4 &&
        list.tree.nodes[6].name == "li" && list.tree.nodes[6].parentIndex == 3 &&
        list.tree.nodes[7].text == "B" && list.tree.nodes[7].parentIndex == 6,
        "malformed list exact tree mismatch");

    if (args.length == 2) {
        auto wpt = cast(ubyte[]) read(args[1]);
        require(format("%(%02x%)", sha256Of(wpt)) ==
            "c10358bda1648db3138d1a20c5bc21961cef0eee0f613f8718a317650240efe1",
            "pinned WPT bytes changed");
        auto selected = parseHtml(wpt, "utf-8", "wpt-ambiguous-ampersand");
        require(selected.isParsed, "WPT selected parse failed");
        bool title, anchor, paragraph;
        foreach (ref const node; selected.tree.nodes) {
            if (node.name == "title") title = true;
            if (node.name == "a") {
                require(node.attributes == [HtmlAttribute("href",
                    "?a=b&c=d&a0b=c&copy=1&noti=n&not=in&notin=∉¬&;& &")],
                    "WPT anchor attribute mismatch");
                anchor = true;
            }
            if (node.name == "p") paragraph = true;
        }
        require(title && anchor && paragraph &&
            hasText(selected.tree, "Ambiguous ampersand") &&
            hasText(selected.tree, "Link") &&
            hasText(selected.tree, "Text: ?a=b&c=d&a0b=c©=1¬i=n¬=in¬in=∉¬&;& &"),
            "WPT selected names/text mismatch");
    }

    // Existing decoding policy, including source/quarantine reason, is honored.
    auto bad = parseHtml([cast(ubyte) 0xe9], null, "bad-utf8");
    require(!bad.isParsed && bad.failure.reason == HtmlFailureReason.decode &&
        bad.failure.decodeReason == QuarantineReason.malformedUnicode &&
        bad.failure.hasOffendingOffset && bad.failure.offendingOffset == 0,
        "decode quarantine reason lost");
    expectFailure(cast(const(ubyte)[]) "a", HtmlFailureReason.decode, "latin1");
    expectFailure(new ubyte[maxRawBytes + 1], HtmlFailureReason.rawLimit);

    // UTF-16 CJK expands beyond the decoded UTF-8 cap without exceeding raw cap.
    ubyte[] expanded;
    foreach (_; 0 .. 22_000) expanded ~= [cast(ubyte) 0x2d, 0x4e];
    expectFailure(expanded, HtmlFailureReason.decodedLimit, "utf-16le");

    string nested;
    foreach (_; 0 .. maxDepth + 2) nested ~= "<div>";
    expectFailure(cast(const(ubyte)[]) nested, HtmlFailureReason.depthLimit);

    string wide;
    foreach (_; 0 .. maxNodes + 2) wide ~= "<i></i>";
    expectFailure(cast(const(ubyte)[]) wide, HtmlFailureReason.nodeLimit);

    string manyAttrs = "<p";
    foreach (i; 0 .. maxAttributesPerNode + 1)
        manyAttrs ~= " a" ~ to!string(i) ~ "='x'";
    manyAttrs ~= ">";
    expectFailure(cast(const(ubyte)[]) manyAttrs, HtmlFailureReason.attributeLimit);

    auto foreign = parseHtml(cast(const(ubyte)[]) "<svg><circle/></svg>");
    require(!foreign.isParsed &&
        foreign.failure.reason == HtmlFailureReason.unsupportedNamespace,
        "foreign namespace was not quarantined");

    verifyHtmlFaults(); // Includes during-traversal observation-cap negative.

    // Independent trees only; this records process high-water memory, not a
    // strict native RSS guarantee or a corpus-throughput claim.
    foreach (_; 0 .. 100) {
        auto parsed = parseHtml(cast(const(ubyte)[]) "<article><p>small</p></article>");
        require(parsed.isParsed && hasText(parsed.tree, "small"),
            "repeat parse mismatch");
    }
    bool[] passed = new bool[](8);
    Thread[8] workers;
    foreach (index; 0 .. workers.length) {
        workers[index] = independentTreeWorker(index, passed);
        workers[index].start();
    }
    foreach (worker; workers) worker.join();
    foreach (ok; passed) require(ok, "independent native tree thread mismatch");
    rusage usage;
    require(getrusage(RUSAGE_SELF, &usage) == 0, "getrusage failed");
    writeln("html production check: goldens, caps, decode, ownership, faults, ",
        "independent threads pass; ",
        "peak_rss_bytes=", usage.ru_opaque[0],
        " gc_used_bytes=", GC.stats.usedSize);
}
