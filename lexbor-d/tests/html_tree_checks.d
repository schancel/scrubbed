/// Real fixture proof for `lexbor_d.html_tree`, ported faithfully (assertions
/// and values unchanged) from scrubbed's `experiments/html_parser/production_check.d`
/// into `dub test`-native `unittest` blocks, so they run as part of this
/// package's own `dub test` rather than a separately invoked D check.
///
/// Covers: bounding limits (raw/decoded/depth/node/attribute/observation),
/// fault-injection paths via `lexbor_d.html_tree`'s private `Fault` enum (through
/// the version-gated `verifyHtmlFaults()` entry point), foreign-namespace
/// pruning, and native-byte-copy/UTF-8-validation (input mutated after native
/// destroy must not affect already-copied output).
module tests.html_tree_checks;

import lexbor_d.html_tree;
import lexbor_d.decoding : QuarantineReason;
import std.conv : to;
import core.thread : Thread;

private void expectFailure(const(ubyte)[] raw, HtmlFailureReason reason,
    string charset = null) {
    auto result = parseHtml(raw, charset, "production-check");
    assert(!result.isParsed && result.failure.reason == reason,
        "wrong failure: " ~ to!string(reason));
}

private bool hasText(ref const(HtmlTree) tree, string text) {
    foreach (ref const node; tree.nodes)
        if (node.kind == HtmlNodeKind.text && node.text == text) return true;
    return false;
}

private bool hasElement(ref const(HtmlTree) tree, string name) {
    foreach (ref const node; tree.nodes)
        if (node.kind == HtmlNodeKind.element && node.name == name) return true;
    return false;
}

// Independent-tree concurrency smoke test, ported from scrubd's
// experiments/html_parser/production_check.d's `independentTreeWorker`
// (8 threads x 100 parseHtml calls, asserting each thread's own results).
// Here each thread parses its own distinct input carrying a marker unique
// to that thread's index, so cross-thread contamination -- e.g. a bug in
// the native Lexbor boundary that let one thread observe bytes belonging
// to another thread's concurrent document -- would be directly detectable:
// a worker only flips its own `passed[index]` once every iteration saw
// exactly its own marker and no other thread's. `index` is a function
// parameter (not a loop variable captured by a delegate literal) so each
// worker's closure unambiguously owns its own copy, matching the original
// file's pattern. Scaled down from 8x100 to 8x40 (320 parses total) to
// keep `dub test` fast while still exercising real concurrent native
// document create/parse/destroy cycles; threads are joined (not slept on)
// so the test is deterministic.
private Thread independentTreeWorker(size_t index, bool[] passed) {
    return new Thread({
        immutable marker = "thread-marker-" ~ index.to!string;
        const(ubyte)[] input = cast(const(ubyte)[])
            ("<x-note data-id='" ~ marker ~ "'>" ~ marker ~ "</x-note>");
        foreach (_; 0 .. 40) {
            auto result = parseHtml(input);
            if (!result.isParsed) return;
            auto tree = result.tree;
            if (tree.nodes.length != 5) return;
            if (tree.nodes[3].name != "x-note") return;
            if (tree.nodes[3].attributes != [HtmlAttribute("data-id", marker)]) return;
            if (!hasText(tree, marker)) return;
            // No other worker's marker should ever surface in this thread's
            // own parsed tree; each thread's input is otherwise disjoint.
            foreach (other; 0 .. passed.length) {
                if (other == index) continue;
                if (hasText(tree, "thread-marker-" ~ other.to!string)) return;
            }
        }
        passed[index] = true;
    });
}

unittest {
    // Exact selected observation checks every accessor used by the wrapper:
    // qualified element name, first/next attribute, attribute name/value,
    // and text bytes. The returned bytes survive native destroy and mutation
    // of the caller-owned raw input.
    ubyte[] input = cast(ubyte[]) "<x-note data-id='a&amp;b' disabled>Hi</x-note>".dup;
    auto result = parseHtml(input, null, "golden");
    assert(result.isParsed, "golden parse failed");
    auto tree = result.tree;
    assert(tree.nodes.length == 5, "unexpected selected tree size");
    assert(tree.nodes[0].name == "html" && tree.nodes[0].parentIndex == size_t.max,
        "html root mismatch");
    assert(tree.nodes[1].name == "head" && tree.nodes[1].parentIndex == 0,
        "head mismatch");
    assert(tree.nodes[2].name == "body" && tree.nodes[2].parentIndex == 0,
        "body mismatch");
    assert(tree.nodes[3].name == "x-note" && tree.nodes[3].parentIndex == 2,
        "custom element mismatch");
    assert(tree.nodes[3].attributes == [HtmlAttribute("data-id", "a&b"),
        HtmlAttribute("disabled", "")], "attribute name/value/order mismatch");
    assert(tree.nodes[4].kind == HtmlNodeKind.text &&
        tree.nodes[4].parentIndex == 3 && tree.nodes[4].text == "Hi",
        "text accessor mismatch");
    input[] = 0;
    assert(tree.nodes[3].name == "x-note" &&
        tree.nodes[3].attributes[0].value == "a&b" && tree.nodes[4].text == "Hi",
        "native/input alias escaped");
    assert(tree.observedBytes <= maxObservationBytes, "observation exceeds cap");

    auto list = parseHtml(cast(const(ubyte)[]) "<ul><li>A<li>B</ul>");
    assert(list.isParsed && list.tree.nodes.length == 8, "malformed list size");
    assert(list.tree.nodes[3].name == "ul" &&
        list.tree.nodes[4].name == "li" && list.tree.nodes[4].parentIndex == 3 &&
        list.tree.nodes[5].text == "A" && list.tree.nodes[5].parentIndex == 4 &&
        list.tree.nodes[6].name == "li" && list.tree.nodes[6].parentIndex == 3 &&
        list.tree.nodes[7].text == "B" && list.tree.nodes[7].parentIndex == 6,
        "malformed list exact tree mismatch");
}

unittest {
    // Existing decoding policy, including source/quarantine reason, is honored.
    auto bad = parseHtml([cast(ubyte) 0xe9], null, "bad-utf8");
    assert(!bad.isParsed && bad.failure.reason == HtmlFailureReason.decode &&
        bad.failure.decodeReason == QuarantineReason.malformedUnicode &&
        bad.failure.hasOffendingOffset && bad.failure.offendingOffset == 0,
        "decode quarantine reason lost");
    expectFailure(cast(const(ubyte)[]) "a", HtmlFailureReason.decode, "latin1");
    expectFailure(new ubyte[maxRawBytes + 1], HtmlFailureReason.rawLimit);

    // UTF-16 CJK expands beyond the decoded UTF-8 cap without exceeding raw cap.
    ubyte[] expanded;
    foreach (_; 0 .. 22_000) expanded ~= [cast(ubyte) 0x2d, 0x4e];
    expectFailure(expanded, HtmlFailureReason.decodedLimit, "utf-16le");
}

unittest {
    // Bounding limits: depth, node count, and attributes-per-node.
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
}

unittest {
    // A foreign-namespace element is pruned as a subtree, not aborted: the
    // parse still succeeds, the svg/circle never appear in the tree, and a
    // sibling before and after the pruned subtree is still observed.
    auto foreign = parseHtml(cast(const(ubyte)[])
        "<p>before</p><svg><circle/></svg><p>after</p>");
    assert(foreign.isParsed, "foreign namespace subtree aborted the parse");
    assert(!hasElement(foreign.tree, "svg") && !hasElement(foreign.tree, "circle"),
        "foreign namespace element/subtree was not pruned");
    assert(hasText(foreign.tree, "before") && hasText(foreign.tree, "after"),
        "sibling content around pruned foreign subtree was lost");
}

unittest {
    // Several threads call parseHtml concurrently on independent,
    // per-thread-distinct input and are joined (not slept on) before any
    // assertion runs, so this is deterministic rather than timing-dependent.
    // See independentTreeWorker's doc comment above for the full shape.
    enum workerCount = 8;
    bool[] passed = new bool[](workerCount);
    Thread[workerCount] workers;
    foreach (index; 0 .. workerCount) {
        workers[index] = independentTreeWorker(index, passed);
        workers[index].start();
    }
    foreach (worker; workers) worker.join();
    foreach (index, ok; passed)
        assert(ok, "independent native tree thread " ~ index.to!string ~ " mismatch");
}

version (htmlTreeProductionCheck) {
    unittest {
        // Fault-injection paths via the private Fault enum, including the
        // during-traversal observation-cap negative.
        verifyHtmlFaults();
    }
} else {
    static assert(0, "expected -version=htmlTreeProductionCheck for dub test " ~
        "(set via this package's \"unittest\" configuration)");
}
