/// Restricted, D-owned HTML tree boundary for validated, bounded input.
module effects.html_tree;

import effects.lexbor_ffi;
import text.decoding : decodeBytes, QuarantineReason;
import std.exception : enforce;
import std.utf : validate, UTFException;

enum size_t maxRawBytes = 64 * 1024;
enum size_t maxDecodedBytes = 64 * 1024;
enum size_t defaultExtractHtmlBytes = 1024 * 1024;
enum size_t maxConfigurableHtmlBytes = 8 * 1024 * 1024;
enum size_t maxDepth = 128;
// Issue #411 (scienceblogs-de.html): `maxNodes`/`maxObservationBytes` were
// both introduced (`ebae4ed`) alongside the original 64 KiB `maxRawBytes`
// admission bound and never revisited when a later, separate commit
// (`68e1b1c`) raised extraction's own effective raw-byte admission to 1 MiB
// by default and up to 8 MiB configurable via `--max-html-bytes` -- that
// commit's own TODO.md entry explicitly notes "other tree/output limits...
// remain unchanged", i.e. this was a known, not a hidden, gap, just never
// closed. The result: a real page comfortably inside the *documented*
// 1 MiB default admission bound could still be rejected by a *node* cap
// still sized for the original, 16x-smaller 64 KiB budget -- exactly what
// scienceblogs-de.html (397,702 raw bytes, its own 10,798-node true count,
// confirmed by temporarily raising both caps and observing a successful
// `selected` real-page parse) hit. Real trafilatura 2.2.0 extracts this
// exact page's real content directly in 0.46s with no special handling
// (confirmed by running it, not assumed) -- this is scrubbed's own admitted
// internal representation cost catching up to a page a real tool finds
// unremarkable, not a pathological/adversarial input this cap exists to
// reject.
//
// Raised, not removed, and still a fixed bound (not scaled to whatever
// raw-byte limit a caller configures via `--max-html-bytes`, which remains
// the pre-existing, separately documented "other limits do not scale with
// the configured raw cap" behavior -- out of this ticket's scope): the new
// values are sized against this repo's own real 20-page corpus
// (examples/pipeline-benchmark/corpus/), not just the one page that
// motivated them. Real per-page node and observed-byte density (measured
// by temporarily raising both caps and running every corpus page through
// `parseHtml`) ranges from roughly 2.3 to 27.9 nodes and 0.89x to 3.17x
// observed-vs-raw bytes per raw KiB across all 20 pages; `maxNodes` is set
// to comfortably clear the corpus's own densest real page (27.9 nodes/KiB,
// tofugu) at a full 1 MiB (the *default* extract admission bound) with
// roughly 2x headroom beyond that, and `maxObservationBytes` similarly
// clears the corpus's own highest observed-byte ratio (3.17x, tofugu) at a
// full 1 MiB raw with headroom -- not an unbounded or unexamined increase.
enum size_t maxNodes = 65536;
enum size_t maxAttributesPerNode = 256;
enum size_t maxObservationBytes = 4 * 1024 * 1024;

enum HtmlFailureReason {
    none, rawLimit, decode, decodedLimit, invalidUtf8, nativeCreate,
    nativeParse, nativeData, unsupportedNamespace, depthLimit, nodeLimit,
    attributeLimit, observationLimit, injectedFault,
}

struct HtmlFailure {
    HtmlFailureReason reason;
    QuarantineReason decodeReason;
    bool hasOffendingOffset;
    size_t offendingOffset;
    int nativeStatus;
}

struct HtmlAttribute {
    string name;
    string value;
}

enum HtmlNodeKind { element, text }

/// Flat pre-order tree: parentIndex is size_t.max for a top-level node.
/// All strings and arrays are D-owned and have no native or raw-input aliases.
struct HtmlNode {
    HtmlNodeKind kind;
    size_t parentIndex;
    string name;
    string text;
    HtmlAttribute[] attributes;
}

struct HtmlTree {
    HtmlNode[] nodes;
    size_t observedBytes; // logical payload + node/attribute struct bytes
}

struct HtmlOutcome {
    private bool succeeded;
    private HtmlTree treeValue;
    private HtmlFailure failureValue;

    bool isParsed() const pure { return succeeded; }
    ref const(HtmlTree) tree() const pure {
        enforce(succeeded, "HTML outcome is quarantined");
        return treeValue;
    }
    ref const(HtmlFailure) failure() const pure {
        enforce(!succeeded, "HTML outcome is parsed");
        return failureValue;
    }
}

private enum Fault { none, beforeCreate, afterCreate, beforeParse,
    nativeStatus, duringTraversal, beforeCleanup, observationLimit }

private struct Accounting { size_t created, destroyed; }

private class BoundaryFault : Exception {
    HtmlFailureReason reason;
    this(HtmlFailureReason reason) pure {
        super("restricted HTML boundary failed");
        this.reason = reason;
    }
}

private HtmlOutcome failed(HtmlFailureReason reason,
    QuarantineReason decodeReason = QuarantineReason.none,
    bool hasOffendingOffset = false, size_t offendingOffset = 0,
    int nativeStatus = 0) pure {
    HtmlOutcome outcome;
    outcome.failureValue = HtmlFailure(reason, decodeReason,
        hasOffendingOffset, offendingOffset, nativeStatus);
    return outcome;
}

private void charge(ref HtmlTree tree, size_t bytes) pure {
    if (bytes > maxObservationBytes - tree.observedBytes)
        throw new BoundaryFault(HtmlFailureReason.observationLimit);
    tree.observedBytes += bytes;
}

private string copyNative(const(ubyte)* value, size_t length,
        ref HtmlTree tree) pure {
    if (length != 0 && value is null)
        throw new BoundaryFault(HtmlFailureReason.nativeData);
    charge(tree, length);
    if (length == 0) return "";
    // Native bytes never escape: the slice is copied before document destroy.
    auto copied = cast(const(char)[]) value[0 .. length].idup;
    try validate(copied);
    catch (UTFException) throw new BoundaryFault(HtmlFailureReason.nativeData);
    return cast(string) copied;
}

private void observe(NativeNode* first, size_t parent, size_t depth,
    ref size_t visited, ref HtmlTree tree, Fault fault) pure {
    for (auto node = first; node !is null; node = node.next) {
        if (depth > maxDepth) throw new BoundaryFault(HtmlFailureReason.depthLimit);
        if (++visited > maxNodes) throw new BoundaryFault(HtmlFailureReason.nodeLimit);
        if (fault == Fault.duringTraversal && visited == 3)
            throw new BoundaryFault(HtmlFailureReason.injectedFault);
        // Foreign-namespace elements (e.g. inline <svg>/<math>) are pruned:
        // neither the element nor its subtree is observed, but traversal
        // continues over its siblings. This mirrors how hiddenTag content
        // is excluded downstream, but at tree-construction time so every
        // consumer of the parsed tree benefits.
        if (node.type == elementNode && node.ns != 2)
            continue;
        size_t childParent = parent;
        if (node.type == elementNode || node.type == textNode) {
            charge(tree, HtmlNode.sizeof);
            const index = tree.nodes.length;
            tree.nodes ~= HtmlNode(node.type == elementNode ? HtmlNodeKind.element :
                HtmlNodeKind.text, parent);
            childParent = index;
            if (node.type == elementNode) {
                size_t length;
                auto name = lxb_dom_element_qualified_name(node, &length);
                tree.nodes[index].name = copyNative(name, length, tree);
                size_t attributes;
                for (auto attr = lxb_dom_element_first_attribute_noi(node);
                     attr !is null; attr = lxb_dom_element_next_attribute_noi(attr)) {
                    if (++attributes > maxAttributesPerNode)
                        throw new BoundaryFault(HtmlFailureReason.attributeLimit);
                    charge(tree, HtmlAttribute.sizeof);
                    auto attrName = lxb_dom_attr_qualified_name(attr, &length);
                    auto copiedName = copyNative(attrName, length, tree);
                    auto attrValue = lxb_dom_attr_value_noi(attr, &length);
                    auto copiedValue = copyNative(attrValue, length, tree);
                    tree.nodes[index].attributes ~= HtmlAttribute(copiedName, copiedValue);
                }
            } else {
                auto nativeText = cast(NativeText*) node;
                tree.nodes[index].text = copyNative(nativeText.data.data,
                    nativeText.data.length, tree);
            }
        }
        if (node.firstChild !is null)
            observe(node.firstChild, childParent, depth + 1, visited, tree, fault);
    }
}

size_t checkedHtmlByteLimit(ulong limit) pure {
    enforce(limit > 0 && limit <= maxConfigurableHtmlBytes,
        "HTML byte limit must be between 1 and 8388608");
    return cast(size_t)limit;
}

private HtmlOutcome parseImpl(const(ubyte)[] raw, string charset, string source,
    Fault fault, Accounting* accounting, size_t byteLimit = maxRawBytes) pure {
    checkedHtmlByteLimit(byteLimit);
    // This check runs before decodeBytes or any native allocation.
    if (raw.length > byteLimit) return failed(HtmlFailureReason.rawLimit);
    auto decoded = decodeBytes(raw, charset, source);
    if (!decoded.isDecoded) {
        auto quarantine = decoded.quarantined;
        return failed(HtmlFailureReason.decode, quarantine.reason,
            quarantine.hasOffendingOffset, quarantine.offendingOffset);
    }
    if (decoded.decoded.text.length > byteLimit)
        return failed(HtmlFailureReason.decodedLimit);
    // DecodedText is publicly constructible; this boundary owns and validates
    // a fresh copy rather than treating the type as provenance proof.
    string utf8 = decoded.decoded.text.idup;
    try validate(utf8);
    catch (UTFException) return failed(HtmlFailureReason.invalidUtf8);

    if (fault == Fault.beforeCreate) return failed(HtmlFailureReason.injectedFault);
    auto document = lxb_html_document_create();
    if (document is null) return failed(HtmlFailureReason.nativeCreate);
    if (accounting !is null) ++accounting.created;
    scope(exit) {
        lxb_html_document_destroy(document);
        if (accounting !is null) ++accounting.destroyed;
    }
    try {
        if (fault == Fault.afterCreate || fault == Fault.beforeParse)
            throw new BoundaryFault(HtmlFailureReason.injectedFault);
        const status = fault == Fault.nativeStatus ? -1 :
            lxb_html_document_parse(document, cast(const(ubyte)*) utf8.ptr, utf8.length);
        if (status != 0) return failed(HtmlFailureReason.nativeParse,
            QuarantineReason.none, false, 0, status);
        HtmlTree tree;
        if (fault == Fault.observationLimit)
            tree.observedBytes = maxObservationBytes;
        size_t visited;
        observe((cast(NativeNode*) document).firstChild, size_t.max, 0,
            visited, tree, fault);
        if (fault == Fault.beforeCleanup)
            throw new BoundaryFault(HtmlFailureReason.injectedFault);
        HtmlOutcome outcome;
        outcome.succeeded = true;
        outcome.treeValue = tree;
        return outcome;
    } catch (BoundaryFault error) {
        return failed(error.reason);
    }
}

/// Parse only the selected HTML element names, ordered decoded attributes,
/// and text nodes. No HTML encoding sniffing or unrestricted DOM semantics.
HtmlOutcome parseHtml(const(ubyte)[] raw, string declaredCharset = null,
    string source = "", size_t byteLimit = maxRawBytes) pure {
    return parseImpl(raw, declaredCharset, source, Fault.none, null, byteLimit);
}

unittest {
    import std.algorithm.searching : canFind;
    auto outcome = parseHtml(cast(const(ubyte)[]) "<x-note data-id='a&amp;b'>Hi</x-note>");
    assert(outcome.isParsed);
    bool found;
    foreach (node; outcome.tree.nodes) if (node.name == "x-note") {
        assert(node.attributes.length == 1);
        assert(node.attributes[0] == HtmlAttribute("data-id", "a&b"));
        found = true;
    }
    assert(found);
    assert(outcome.tree.nodes.canFind!(n => n.text == "Hi"));
}

unittest {
    // A foreign-namespace element (e.g. a decorative inline <svg> icon) is
    // pruned as a whole subtree rather than aborting the entire parse; its
    // siblings, including later siblings under the same parent, still
    // observe normally.
    import std.algorithm.searching : canFind;
    auto outcome = parseHtml(cast(const(ubyte)[]) (
        "<nav><svg viewBox='0 0 10 10'><circle cx='5' cy='5' r='4'/></svg>" ~
        "<a href='/'>Home</a></nav><article><p>Real content</p></article>"));
    assert(outcome.isParsed);
    auto nodes = outcome.tree.nodes;
    // The svg subtree, including its child, is excluded entirely.
    assert(!nodes.canFind!(n => n.name == "svg"));
    assert(!nodes.canFind!(n => n.name == "circle"));
    // Sibling content before and after the pruned subtree is preserved.
    assert(nodes.canFind!(n => n.text == "Home"));
    assert(nodes.canFind!(n => n.text == "Real content"));
    size_t navIndex = size_t.max;
    foreach (i, node; nodes) if (node.name == "nav") navIndex = i;
    assert(navIndex != size_t.max);
    bool anchorUnderNav;
    foreach (node; nodes)
        if (node.name == "a" && node.parentIndex == navIndex) anchorUnderNav = true;
    assert(anchorUnderNav);
}

version (htmlTreeProductionCheck) {
    /// Test-only failure injection. Never compiled into the shipping binary.
    void verifyHtmlFaults() {
        foreach (fault; [Fault.beforeCreate, Fault.afterCreate,
                 Fault.beforeParse, Fault.nativeStatus, Fault.duringTraversal,
                 Fault.beforeCleanup, Fault.observationLimit]) {
            Accounting accounting;
            auto result = parseImpl(cast(const(ubyte)[])
                "<p data-x='v'>Hi</p>", null, "fault", fault, &accounting);
            if (result.isParsed) throw new Exception("fault was not rejected");
            if (fault == Fault.nativeStatus &&
                result.failure.reason != HtmlFailureReason.nativeParse)
                throw new Exception("native status was not typed");
            if (fault == Fault.observationLimit &&
                result.failure.reason != HtmlFailureReason.observationLimit)
                throw new Exception("observation cap was not typed");
            const expected = fault == Fault.beforeCreate ? 0 : 1;
            if (accounting.created != expected || accounting.destroyed != expected)
                throw new Exception("native document lifecycle mismatch");
        }
    }
}
