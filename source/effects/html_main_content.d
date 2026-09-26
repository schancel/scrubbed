/// Deterministic main-content-vs-boilerplate selection over the selected HTML tree.
module effects.html_main_content;

import effects.html_tree : HtmlNode, HtmlNodeKind, HtmlTree;
import std.uni : isControl, isFormat, isWhite;
import std.utf : UseReplacementDchar, decode, encode;

enum size_t maxMainContentCandidates = 16;
enum size_t maxMainContentTextBytes = 4 * 1024 * 1024;

// Threshold below which a top-scoring subtree is an explicit abstention
// rather than a best-effort guess.
private enum size_t minSelectableTextBytes = 200;
private enum double minSelectableScore = 150.0;

// A direct <p> child needs at least this much of its own cumulative text to
// count toward its parent's paragraph-sibling clustering signal.
private enum size_t minParagraphTextBytes = 40;
private enum size_t maxParagraphClusterBonusCount = 12;
private enum double paragraphClusterUnit = 40.0;

private enum double positiveTagWeight = 300.0;
private enum double negativeTagWeight = 300.0;
private enum double keywordWeightUnit = 150.0;

/// Fixed content-vs-boilerplate tag-name table. `check.d` pins these exact
/// lists so an accidental edit is caught as a golden drift.
immutable string[] positiveContentTags = ["article", "main", "section", "p"];
immutable string[] negativeContentTags = ["nav", "aside", "footer", "header",
    "form", "button", "figure"];

/// Fixed class/id keyword table, matched as an ASCII case-insensitive
/// substring of the node's `class` or `id` attribute value.
immutable string[] positiveKeywords = ["content", "article", "main", "post",
    "body", "entry"];
immutable string[] negativeKeywords = ["nav", "sidebar", "footer", "header",
    "comment", "menu", "ad", "advert", "promo", "share", "social", "related",
    "widget", "breadcrumb"];

enum MainContentStatus {
    selected,
    abstainedNoCandidate,
    abstainedBelowThreshold,
    abstainedTie,
}

/// One scored subtree root, bounded and text-free for safe audit/reporting
/// (nav/ad/footer-failure inspection never needs to echo raw page text).
struct MainContentCandidate {
    size_t node;
    double score;
    size_t textLength;
    string tag;
}

/// `MetadataField`-style typed decision: a status, the winning node/score
/// when selected, and a bounded top-N candidate list for audit.
struct MainContentResult {
    MainContentStatus status;
    size_t node = size_t.max;
    double score = 0.0;
    string text;
    bool candidatesOverflow;
    MainContentCandidate[] candidates;
}

class HtmlMainContentOutputLimit : Exception {
    this() pure { super("main content output exceeds 4 MiB"); }
}

private bool hiddenTag(string name) pure nothrow @nogc {
    return name == "script" || name == "style" || name == "template" || name == "head";
}

private string attributeValue(const ref HtmlNode node, string name) pure {
    foreach (ref const attr; node.attributes) if (attr.name == name) return attr.value;
    return null;
}

private bool asciiFoldEq(char a, char b) pure nothrow @nogc {
    ubyte fa = cast(ubyte) a;
    if (fa >= 'A' && fa <= 'Z') fa += 'a' - 'A';
    ubyte fb = cast(ubyte) b;
    if (fb >= 'A' && fb <= 'Z') fb += 'a' - 'A';
    return fa == fb;
}

private bool containsCaseInsensitive(string haystack, string needle) pure nothrow @nogc {
    if (needle.length == 0) return true;
    if (needle.length > haystack.length) return false;
    outer: for (size_t i; i + needle.length <= haystack.length; ++i) {
        foreach (j, nc; needle) if (!asciiFoldEq(haystack[i + j], nc)) continue outer;
        return true;
    }
    return false;
}

private double tagWeightFor(string name) pure nothrow @nogc {
    foreach (tag; positiveContentTags) if (tag == name) return positiveTagWeight;
    foreach (tag; negativeContentTags) if (tag == name) return -negativeTagWeight;
    return 0.0;
}

private double keywordScoreFor(const ref HtmlNode node) pure {
    double total = 0.0;
    auto classValue = attributeValue(node, "class");
    auto idValue = attributeValue(node, "id");
    foreach (kw; positiveKeywords)
        if ((classValue.length && containsCaseInsensitive(classValue, kw)) ||
            (idValue.length && containsCaseInsensitive(idValue, kw)))
            total += keywordWeightUnit;
    foreach (kw; negativeKeywords)
        if ((classValue.length && containsCaseInsensitive(classValue, kw)) ||
            (idValue.length && containsCaseInsensitive(idValue, kw)))
            total -= keywordWeightUnit;
    return total;
}

private void insertCandidate(ref MainContentCandidate[maxMainContentCandidates] top,
        ref size_t topCount, ref bool overflow, MainContentCandidate candidate) pure {
    size_t position = topCount;
    foreach (i; 0 .. topCount) if (candidate.score > top[i].score) { position = i; break; }
    if (topCount < maxMainContentCandidates) {
        for (size_t i = topCount; i > position; --i) top[i] = top[i - 1];
        top[position] = candidate;
        ++topCount;
    } else if (position < maxMainContentCandidates) {
        overflow = true;
        for (size_t i = maxMainContentCandidates - 1; i > position; --i) top[i] = top[i - 1];
        top[position] = candidate;
    } else {
        overflow = true;
    }
}

// Subtree end index: pre-order means every descendant of `index` is a
// contiguous run of higher indices, so a forward scan with an ancestor
// check (never recursion) finds where that run stops.
private size_t endOf(const ref HtmlTree tree, size_t index) pure {
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

private struct Writer {
    char[] bytes;

    void put(scope const(char)[] value) pure {
        if (value.length > maxMainContentTextBytes - bytes.length)
            throw new HtmlMainContentOutputLimit;
        bytes ~= value;
    }
}

// Collapses whitespace runs (including across text-node boundaries) to a
// single space, dropping leading/trailing whitespace and control/format
// characters, while enforcing the bounded output cap before any partial
// text can be observed by the caller.
private struct CollapsingWriter {
    Writer writer;
    private bool pendingSpace;
    private bool any;

    void feed(string chunk) pure {
        size_t at;
        while (at < chunk.length) {
            dchar ch = decode!(UseReplacementDchar.yes)(chunk, at);
            if (isControl(ch) || isFormat(ch)) continue;
            if (isWhite(ch)) { if (any) pendingSpace = true; continue; }
            if (pendingSpace) { writer.put(" "); pendingSpace = false; }
            char[4] encoded;
            writer.put(cast(string) encoded[0 .. encode(encoded, ch)]);
            any = true;
        }
    }
}

// Visible text of one selected subtree, skipping the non-visible
// script/style/template/head descendants exactly as html_markdown.d's
// nodeText does (a bounded ancestor walk, not recursion).
private void collectText(const ref HtmlTree tree, size_t index, ref CollapsingWriter cw) pure {
    foreach (i; index + 1 .. endOf(tree, index)) {
        if (tree.nodes[i].kind != HtmlNodeKind.text) continue;
        bool hidden;
        for (size_t parent = tree.nodes[i].parentIndex;
             parent != index && parent != size_t.max && parent < i;
             parent = tree.nodes[parent].parentIndex) {
            if (hiddenTag(tree.nodes[parent].name)) { hidden = true; break; }
        }
        if (!hidden) cw.feed(tree.nodes[i].text);
    }
}

/// Select the highest-scoring content subtree, or abstain explicitly.
///
/// One bounded bottom-up pass walks `tree.nodes` in reverse pre-order index
/// order (no recursion): because a node's descendants are always the
/// contiguous run of higher indices immediately following it, every child
/// is fully scored and has pushed its totals into its parent's accumulators
/// before that parent's own turn in the loop. Per element node this pass
/// tracks: cumulative subtree text length, cumulative link (`<a>`) text
/// length for link-density, the element's own direct text (from immediate
/// text-node children only), and paragraph-sibling clustering (the summed
/// text of direct `<p>` children that individually clear
/// `minParagraphTextBytes`). A fixed tag-name table and a fixed class/id
/// keyword table add bounded bonuses/penalties. The final per-node score is
/// `(ownDirectText + paragraphClusterText + clusterBonus + tagWeight +
/// keywordWeight) * (1 - linkDensity)` — link density is the strongest
/// established deterministic boilerplate signal, so it discounts everything
/// else rather than being an independent term.
///
/// Selection is a single rule: the highest-scoring node wins. Below
/// `minSelectableTextBytes`/`minSelectableScore`, having no element
/// candidate at all, or an exact tie for the top score are each an explicit
/// abstention (`abstainedBelowThreshold`/`abstainedNoCandidate`/
/// `abstainedTie`) — never a best-effort guess. Only `HtmlTree`'s own
/// bounded, already-capped node data is read; this performs no parsing and
/// makes no native/native-adjacent calls.
///
/// Throws `HtmlMainContentOutputLimit` before returning any result if the
/// selected node's whitespace-collapsed UTF-8 text would exceed 4 MiB.
MainContentResult extractMainContent(const ref HtmlTree tree) pure {
    MainContentResult result;
    const n = tree.nodes.length;
    if (n == 0) {
        result.status = MainContentStatus.abstainedNoCandidate;
        return result;
    }

    auto cumulativeText = new size_t[n];
    auto cumulativeLinkText = new size_t[n];
    auto ownDirectText = new size_t[n];
    auto paragraphAccum = new size_t[n];
    auto paragraphCount = new size_t[n];

    MainContentCandidate[maxMainContentCandidates] top;
    size_t topCount;
    size_t elementCandidates;

    for (size_t i = n; i-- > 0;) {
        ref const node = tree.nodes[i];
        if (node.kind == HtmlNodeKind.text) {
            bool hidden = node.parentIndex != size_t.max &&
                hiddenTag(tree.nodes[node.parentIndex].name);
            cumulativeText[i] = hidden ? 0 : node.text.length;
        } else {
            if (node.name == "a") cumulativeLinkText[i] = cumulativeText[i];

            ++elementCandidates;
            double clusterBonus = (paragraphCount[i] > maxParagraphClusterBonusCount ?
                maxParagraphClusterBonusCount : paragraphCount[i]) * paragraphClusterUnit;
            double base = cast(double) ownDirectText[i] + cast(double) paragraphAccum[i] +
                clusterBonus + tagWeightFor(node.name) + keywordScoreFor(node);
            double score = base;
            if (cumulativeText[i] > 0) {
                double density = cast(double) cumulativeLinkText[i] / cast(double) cumulativeText[i];
                if (density > 1.0) density = 1.0;
                score = base * (1.0 - density);
            }
            insertCandidate(top, topCount, result.candidatesOverflow,
                MainContentCandidate(i, score, cumulativeText[i], node.name));
        }

        if (node.parentIndex != size_t.max) {
            auto p = node.parentIndex;
            cumulativeText[p] += cumulativeText[i];
            cumulativeLinkText[p] += cumulativeLinkText[i];
            if (node.kind == HtmlNodeKind.text)
                ownDirectText[p] += cumulativeText[i];
            else if (node.name == "p" && cumulativeText[i] >= minParagraphTextBytes) {
                paragraphAccum[p] += cumulativeText[i];
                ++paragraphCount[p];
            }
        }
    }

    if (elementCandidates > maxMainContentCandidates) result.candidatesOverflow = true;
    result.candidates = top[0 .. topCount].dup;

    if (topCount == 0) {
        result.status = MainContentStatus.abstainedNoCandidate;
        return result;
    }

    auto best = top[0];
    if (best.textLength < minSelectableTextBytes || best.score < minSelectableScore) {
        result.status = MainContentStatus.abstainedBelowThreshold;
        return result;
    }
    if (topCount >= 2 && top[1].score == best.score) {
        result.status = MainContentStatus.abstainedTie;
        return result;
    }

    CollapsingWriter collapsing;
    collectText(tree, best.node, collapsing);
    result.status = MainContentStatus.selected;
    result.node = best.node;
    result.score = best.score;
    result.text = collapsing.writer.bytes.idup;
    return result;
}

unittest {
    // Hand-built trees exercise the scoring/selection/abstention rules
    // directly, independent of the native HTML parser.
    HtmlTree empty;
    auto emptyResult = extractMainContent(empty);
    assert(emptyResult.status == MainContentStatus.abstainedNoCandidate);
    assert(emptyResult.node == size_t.max);

    // <article><p>...long enough paragraph text to clear both floors...</p></article>
    string longParagraph;
    foreach (_; 0 .. 25) longParagraph ~= "Article body sentence. ";
    HtmlTree article;
    article.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "article", null, null),
        HtmlNode(HtmlNodeKind.element, 0, "p", null, null),
        HtmlNode(HtmlNodeKind.text, 1, null, longParagraph),
    ];
    auto selected = extractMainContent(article);
    assert(selected.status == MainContentStatus.selected);
    assert(selected.node == 0, "the article wrapper, not the lone p, should win");
    assert(selected.text.length > 0 && selected.text[0] != ' ' &&
        selected.text[$ - 1] != ' ', "collapsed text has no leading/trailing space");

    // A nav-only tree with no real content abstains for lack of a candidate
    // that clears the floor (short nav text, negative tag/keyword weight).
    HtmlTree nav;
    nav.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "nav", null, null),
        HtmlNode(HtmlNodeKind.text, 0, null, "Home About Contact"),
    ];
    auto navResult = extractMainContent(nav);
    assert(navResult.status == MainContentStatus.abstainedBelowThreshold);

    // Two structurally identical article blocks tie for the top score.
    HtmlTree tie;
    tie.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "article", null, null),
        HtmlNode(HtmlNodeKind.element, 0, "p", null, null),
        HtmlNode(HtmlNodeKind.text, 1, null, longParagraph),
        HtmlNode(HtmlNodeKind.element, size_t.max, "article", null, null),
        HtmlNode(HtmlNodeKind.element, 3, "p", null, null),
        HtmlNode(HtmlNodeKind.text, 4, null, longParagraph),
    ];
    auto tieResult = extractMainContent(tie);
    assert(tieResult.status == MainContentStatus.abstainedTie);

    // The output cap throws before any partial text is observable.
    auto longText = new char[maxMainContentTextBytes + 1];
    longText[] = 'x';
    HtmlTree oversized;
    oversized.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "article", null, null),
        HtmlNode(HtmlNodeKind.text, 0, null, cast(string) longText.idup),
    ];
    bool rejected;
    try extractMainContent(oversized);
    catch (HtmlMainContentOutputLimit) rejected = true;
    assert(rejected, "output cap did not reject expansion");

    // script/style content never contributes to scoring or extracted text.
    HtmlTree scripted;
    scripted.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "article", null, null),
        HtmlNode(HtmlNodeKind.element, 0, "p", null, null),
        HtmlNode(HtmlNodeKind.text, 1, null, longParagraph),
        HtmlNode(HtmlNodeKind.element, 0, "script", null, null),
        HtmlNode(HtmlNodeKind.text, 3, null, "var secretPayload = 1;"),
    ];
    auto scriptedResult = extractMainContent(scripted);
    assert(scriptedResult.status == MainContentStatus.selected);
    import std.algorithm.searching : canFind;
    assert(!scriptedResult.text.canFind("secretPayload"), "hidden script text leaked");
}
