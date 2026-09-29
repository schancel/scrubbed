/// Deterministic main-content-vs-boilerplate selection over the selected HTML tree.
module lexcontent.html_main_content;

import lexbor_d.html_tree : HtmlAttribute, HtmlNode, HtmlNodeKind, HtmlTree;
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
    "widget", "breadcrumb", "registration-banner"];

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

// Same block-tag idiom html_markdown.d's renderNode already established
// (`heading || name == "p" || name == "div" || name == "li" || name ==
// "table"`), extended with `blockquote` per issue #335's own examples --
// html_markdown.d treats blockquote as block-level too (it calls
// `writer.block()` around its own dedicated quoting branch), it's just
// handled in a separate code path there because of its "> " line-prefix
// formatting, which has no bearing on this boundary-detection use.
private bool blockTag(string name) pure nothrow @nogc {
    bool heading = name.length == 2 && name[0] == 'h' &&
        name[1] >= '1' && name[1] <= '6';
    return heading || name == "p" || name == "div" || name == "li" ||
        name == "table" || name == "blockquote";
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

// A text node's raw bytes only count as real "own text" if at least one
// decoded character is non-whitespace; pretty-printed indentation/newlines
// between element siblings (e.g. a <select>'s many <option> children) are
// otherwise indistinguishable from prose by byte length alone. Uses the
// same replacement-on-invalid-UTF-8 decoding as `CollapsingWriter.feed` so
// malformed text can never throw here.
private bool isWhitespaceOnly(string text) pure {
    size_t at;
    while (at < text.length) {
        dchar ch = decode!(UseReplacementDchar.yes)(text, at);
        if (!isWhite(ch)) return false;
    }
    return true;
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

// Issue #27 Case 1 (france.attac.org): a boilerplate <p> (a mailing-list
// signup form's own legal/explanatory text, class="explication", no keyword
// match either way) nested inside a <form> was outscoring the real, much
// shorter article lede purely on its own direct-text length plus the flat
// positive tag bonus every <p> gets. A negative-tag container (`nav`/
// `aside`/`footer`/`header`/`form`/`button`/`figure`) already scores itself
// down, but that penalty never reached a descendant candidate scored on its
// own terms -- language-independent (no keyword table involved at all), so
// it also generalizes to the French-language page that motivated it, unlike
// a keyword-table entry would. Walks from `index`'s parent to the tree
// root; safe from infinite loops because `parentIndex` is always strictly
// less than a node's own index (the same invariant `endOf`'s ancestor walk
// above already relies on).
private bool hasNegativeTagAncestor(const ref HtmlTree tree, size_t index) pure nothrow @nogc {
    size_t parent = tree.nodes[index].parentIndex;
    while (parent != size_t.max) {
        if (tagWeightFor(tree.nodes[parent].name) < 0.0) return true;
        parent = tree.nodes[parent].parentIndex;
    }
    return false;
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
// text can be observed by the caller. `paragraphBreak` marks a block-level
// boundary the same way ordinary whitespace marks a word boundary: it's
// deferred (`pendingParagraphBreak`) rather than written immediately, and
// only flushed -- as "\n\n" in place of the ordinary single-space collapse
// -- once real (non-whitespace) content is next fed. That mirrors
// `pendingSpace`'s own deferred-flush idiom and, for the same reason,
// guarantees no break before the first real content and no doubled/trailing
// blank lines: a boundary into or out of an empty/whitespace-only block
// never itself emits anything, it only ever sets a flag that a later real
// character may or may not go on to flush.
private struct CollapsingWriter {
    Writer writer;
    private bool pendingSpace;
    private bool pendingParagraphBreak;
    private bool any;

    // Called once per detected change of nearest block-level ancestor
    // between consecutive text nodes. A no-op before any real content has
    // been written (`any` is still false), so the very first block never
    // produces a leading break.
    void paragraphBreak() pure nothrow @nogc {
        if (any) pendingParagraphBreak = true;
    }

    void feed(string chunk) pure {
        size_t at;
        while (at < chunk.length) {
            dchar ch = decode!(UseReplacementDchar.yes)(chunk, at);
            if (isControl(ch) || isFormat(ch)) continue;
            if (isWhite(ch)) { if (any) pendingSpace = true; continue; }
            if (pendingParagraphBreak) {
                writer.put("\n\n");
                pendingParagraphBreak = false;
                pendingSpace = false;
            } else if (pendingSpace) {
                writer.put(" ");
                pendingSpace = false;
            }
            char[4] encoded;
            writer.put(cast(string) encoded[0 .. encode(encoded, ch)]);
            any = true;
        }
    }
}

// Issue #27 Case 2 (for-me-online.de-pubertaet.html): a
// `registration-banner`/`registration-banner__text`/`registration-banner__button`
// -classed promotional run is embedded as direct <p> siblings inside the
// very same <li> as real article text (a malformed-markup CMS insertion,
// not a separate sidebar/footer chrome block), so it wins as the top
// candidate's own subtree text regardless of any per-node score. A node
// with its own negative keyword match (now including `registration-banner`)
// is excluded outright; a keyword-neutral node (e.g. the promo's own bare,
// unclassed `<p>Werden Sie Mitglied...</p>`) is excluded only when BOTH its
// immediate previous and next siblings under the same parent independently
// carry a negative keyword match -- a real, observed structural pattern
// (a plain paragraph sandwiched directly between two `registration-banner*`
// siblings), not a guess, and narrow enough that an ordinary paragraph
// standing next to a single unrelated ad/share element is never caught.
private bool excludedFromText(const ref HtmlTree tree, const size_t[] prevSibling,
        const size_t[] nextSibling, size_t index) pure {
    double keyword = keywordScoreFor(tree.nodes[index]);
    if (keyword < 0.0) return true;
    if (keyword > 0.0) return false;
    auto prev = prevSibling[index];
    auto next = nextSibling[index];
    if (prev == size_t.max || next == size_t.max) return false;
    if (tree.nodes[prev].kind != HtmlNodeKind.element ||
        tree.nodes[next].kind != HtmlNodeKind.element) return false;
    return keywordScoreFor(tree.nodes[prev]) < 0.0 && keywordScoreFor(tree.nodes[next]) < 0.0;
}

// Visible text of one selected subtree, skipping the non-visible
// script/style/template/head descendants exactly as html_markdown.d's
// nodeText does (a bounded ancestor walk, not recursion), plus any
// descendant `excludedFromText` marks as boilerplate (issue #27 Case 2).
// Also tracks each text node's nearest block-level ancestor (same walk,
// same bound) so a change of block ancestor between one text node and the
// next -- e.g. an `</h1>` followed by a `<p>`, or one `<li>` followed by the
// next -- emits an explicit paragraph break instead of the ordinary
// whitespace collapse. `blockAncestor` defaults to `index` itself (the
// selected subtree root) when no block-tag ancestor is found closer than
// the root, so two text nodes that are both direct, unwrapped children of
// the root (or of the same non-block wrapper) still group as one paragraph.
private void collectText(const ref HtmlTree tree, const size_t[] prevSibling,
        const size_t[] nextSibling, size_t index, ref CollapsingWriter cw) pure {
    size_t lastBlockAncestor = size_t.max; // unset: index is always < size_t.max
    foreach (i; index + 1 .. endOf(tree, index)) {
        if (tree.nodes[i].kind != HtmlNodeKind.text) continue;
        bool hidden;
        size_t blockAncestor = index;
        bool foundBlock;
        for (size_t parent = tree.nodes[i].parentIndex;
             parent != index && parent != size_t.max && parent < i;
             parent = tree.nodes[parent].parentIndex) {
            if (hiddenTag(tree.nodes[parent].name)) { hidden = true; break; }
            if (excludedFromText(tree, prevSibling, nextSibling, parent)) { hidden = true; break; }
            if (!foundBlock && blockTag(tree.nodes[parent].name)) {
                blockAncestor = parent;
                foundBlock = true;
            }
        }
        if (hidden) continue;
        if (blockAncestor != lastBlockAncestor) cw.paragraphBreak();
        cw.feed(tree.nodes[i].text);
        lastBlockAncestor = blockAncestor;
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
/// text-node children only, excluding whitespace-only text nodes so
/// pretty-printed indentation between siblings can't inflate a score), and
/// paragraph-sibling clustering (the summed non-whitespace text of direct
/// `<p>` children that individually clear `minParagraphTextBytes`). A fixed
/// tag-name table and a fixed class/id
/// keyword table add bounded bonuses/penalties -- except that a node nested
/// at any depth inside a negative-tag container (`nav`/`aside`/`footer`/
/// `header`/`form`/`button`/`figure`) never collects its own positive tag or
/// keyword bonus (`hasNegativeTagAncestor`; issue #27). The final per-node
/// score is `(ownDirectText + paragraphClusterText + clusterBonus + tagWeight
/// + keywordWeight) * (1 - linkDensity)` — link density is the strongest
/// established deterministic boilerplate signal, so it discounts everything
/// else rather than being an independent term. Once a node is selected,
/// collecting its text (`collectText`) additionally skips any descendant
/// whose class/id matches a negative keyword, plus a keyword-neutral
/// descendant sandwiched directly between two such matches (`excludedFromText`;
/// issue #27) -- a boilerplate exclusion distinct from scoring itself, since
/// a large winning container can still have a small embedded promotional
/// block that never had to win a scoring contest to leak into the output.
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
    // Same subtree byte totals as `cumulativeText`, but excluding
    // whitespace-only text nodes. `cumulativeText` itself stays
    // whitespace-inclusive because link density and reported `textLength`
    // describe the true extent of a subtree's text, not just its scoring
    // signal; only the two accumulators below (which *are* the scoring
    // signal) need the whitespace-only bytes excluded.
    auto cumulativeVisibleText = new size_t[n];
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
            // A leaf text node's own raw text is known directly here (unlike
            // at an element, where cumulativeText[i] is already an
            // aggregated multi-descendant sum with no single string left to
            // inspect), so whitespace-only-ness must be decided now and
            // carried forward as a byte count.
            cumulativeVisibleText[i] = (hidden || isWhitespaceOnly(node.text)) ?
                0 : node.text.length;
        } else {
            if (node.name == "a") cumulativeLinkText[i] = cumulativeText[i];

            ++elementCandidates;
            double clusterBonus = (paragraphCount[i] > maxParagraphClusterBonusCount ?
                maxParagraphClusterBonusCount : paragraphCount[i]) * paragraphClusterUnit;
            double ownTagWeight = tagWeightFor(node.name);
            double ownKeywordScore = keywordScoreFor(node);
            // A node nested (at any depth) inside a negative-tag container
            // never gets credit for its own positive tag/keyword match --
            // see hasNegativeTagAncestor's own comment (issue #27 Case 1).
            // The negative-tag container's own penalty and any genuinely
            // negative keyword/tag match on this node itself are untouched.
            if ((ownTagWeight > 0.0 || ownKeywordScore > 0.0) &&
                    hasNegativeTagAncestor(tree, i)) {
                if (ownTagWeight > 0.0) ownTagWeight = 0.0;
                if (ownKeywordScore > 0.0) ownKeywordScore = 0.0;
            }
            double base = cast(double) ownDirectText[i] + cast(double) paragraphAccum[i] +
                clusterBonus + ownTagWeight + ownKeywordScore;
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
            cumulativeVisibleText[p] += cumulativeVisibleText[i];
            cumulativeLinkText[p] += cumulativeLinkText[i];
            if (node.kind == HtmlNodeKind.text)
                ownDirectText[p] += cumulativeVisibleText[i];
            else if (node.name == "p" && cumulativeVisibleText[i] >= minParagraphTextBytes) {
                paragraphAccum[p] += cumulativeVisibleText[i];
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

    // Sibling links for `excludedFromText`'s sandwich rule (issue #27 Case
    // 2), computed only once selection is final. A single forward pass:
    // because pre-order means one node's whole subtree is a contiguous run
    // of higher indices before its next sibling begins, the last child seen
    // so far for a given parent is always that child's true immediate
    // previous sibling by the time the next one is reached.
    auto prevSibling = new size_t[n];
    auto nextSibling = new size_t[n];
    prevSibling[] = size_t.max;
    nextSibling[] = size_t.max;
    // Only element nodes participate: pretty-printed whitespace between two
    // sibling elements is its own intervening text node in the flat tree
    // (e.g. "...</p>\n    <p>...", the exact shape between the real
    // for-me-online.de promo <p>s), and it must not break "immediate
    // sibling" into "immediate non-whitespace-text sibling" -- excludedFromText
    // only ever queries an element's siblings, so a text node is simply
    // skipped rather than recorded here.
    auto lastChildOfParent = new size_t[n];
    lastChildOfParent[] = size_t.max;
    size_t lastRootChild = size_t.max;
    foreach (i; 0 .. n) {
        if (tree.nodes[i].kind != HtmlNodeKind.element) continue;
        auto p = tree.nodes[i].parentIndex;
        if (p == size_t.max) {
            if (lastRootChild != size_t.max) {
                nextSibling[lastRootChild] = i;
                prevSibling[i] = lastRootChild;
            }
            lastRootChild = i;
        } else {
            if (lastChildOfParent[p] != size_t.max) {
                nextSibling[lastChildOfParent[p]] = i;
                prevSibling[i] = lastChildOfParent[p];
            }
            lastChildOfParent[p] = i;
        }
    }

    CollapsingWriter collapsing;
    collectText(tree, prevSibling, nextSibling, best.node, collapsing);
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

    // Regression for issue #309: a <select> with many <option> children
    // separated only by pretty-printed indentation/newline whitespace (the
    // exact france.attac.org country-picker shape that outscored a real
    // article by ~30x) must not accumulate any of that whitespace into its
    // score. Each of the 6 whitespace runs below is 200 bytes -- 1200 bytes
    // total, comfortably more than the real article/p's few-hundred-byte
    // scores would be if whitespace were still (wrongly) counted.
    string wsChunk;
    foreach (_; 0 .. 40) wsChunk ~= "\n    "; // 40 * 5 bytes = 200 bytes, all whitespace
    HtmlNode[] whitespaceHeavy;
    whitespaceHeavy ~= HtmlNode(HtmlNodeKind.element, size_t.max, "select", null, null);
    enum optionCount = 5;
    foreach (_; 0 .. optionCount) {
        whitespaceHeavy ~= HtmlNode(HtmlNodeKind.text, 0, null, wsChunk);
        whitespaceHeavy ~= HtmlNode(HtmlNodeKind.element, 0, "option", null, null);
    }
    whitespaceHeavy ~= HtmlNode(HtmlNodeKind.text, 0, null, wsChunk);
    size_t articleIndex = whitespaceHeavy.length;
    whitespaceHeavy ~= HtmlNode(HtmlNodeKind.element, size_t.max, "article", null, null);
    whitespaceHeavy ~= HtmlNode(HtmlNodeKind.element, articleIndex, "p", null, null);
    whitespaceHeavy ~= HtmlNode(HtmlNodeKind.text, articleIndex + 1, null, longParagraph);

    HtmlTree whitespaceVsArticle;
    whitespaceVsArticle.nodes = whitespaceHeavy;
    auto whitespaceResult = extractMainContent(whitespaceVsArticle);
    assert(whitespaceResult.status == MainContentStatus.selected);
    assert(whitespaceResult.node == articleIndex,
        "whitespace-only <option> siblings must not outscore the real article");

    bool foundSelectCandidate;
    double selectScore;
    foreach (candidate; whitespaceResult.candidates)
        if (candidate.node == 0) { foundSelectCandidate = true; selectScore = candidate.score; }
    assert(foundSelectCandidate, "the <select> should still be a scored candidate");
    assert(selectScore < 50.0,
        "whitespace-only text must not inflate the <select>'s score (was pure formatting)");
}

// Issue #335 Slice 1: block-level boundaries in the selected subtree must
// produce an explicit paragraph break ("\n\n") in `.text` instead of
// collapsing to an ordinary single space, while scoring/selection itself
// (which candidate wins, and why) stays exactly as tested above.
unittest {
    string longParagraph;
    foreach (_; 0 .. 25) longParagraph ~= "Article body sentence. ";
    // `CollapsingWriter` never flushes a trailing pending space with nothing
    // after it, so a lone paragraph's own trailing space never appears in
    // `.text` either -- this is the same content minus that final space.
    string paragraph = longParagraph[0 .. $ - 1];

    // The ticket's own cited repro, verbatim: a heading immediately followed
    // by a paragraph must land on separate lines in the final output.
    HtmlTree headingThenParagraph;
    headingThenParagraph.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "article", null,
            [HtmlAttribute("class", "content")]),
        HtmlNode(HtmlNodeKind.element, 0, "h1", null, null),
        HtmlNode(HtmlNodeKind.text, 1, null, "Field notes from the delta survey"),
        HtmlNode(HtmlNodeKind.element, 0, "p", null, null),
        HtmlNode(HtmlNodeKind.text, 3, null,
            "The survey team spent three weeks mapping the river delta's shifting " ~
            "sandbars, recording water depth every two hundred meters along six " ~
            "transects. The main channel has migrated nearly forty meters east " ~
            "since the last survey."),
    ];
    auto headingResult = extractMainContent(headingThenParagraph);
    assert(headingResult.status == MainContentStatus.selected);
    assert(headingResult.node == 0, "the article wrapper should win, same as other fixtures");
    assert(headingResult.text ==
        "Field notes from the delta survey\n\n" ~
        "The survey team spent three weeks mapping the river delta's shifting " ~
        "sandbars, recording water depth every two hundred meters along six " ~
        "transects. The main channel has migrated nearly forty meters east " ~
        "since the last survey.",
        "heading and following paragraph must land on separate lines");

    // paragraph-then-paragraph: a plain <p><p> boundary also gets a break.
    HtmlTree paragraphThenParagraph;
    paragraphThenParagraph.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "article", null,
            [HtmlAttribute("class", "content")]),
        HtmlNode(HtmlNodeKind.element, 0, "p", null, null),
        HtmlNode(HtmlNodeKind.text, 1, null, longParagraph),
        HtmlNode(HtmlNodeKind.element, 0, "p", null, null),
        HtmlNode(HtmlNodeKind.text, 3, null, longParagraph),
    ];
    auto ppResult = extractMainContent(paragraphThenParagraph);
    assert(ppResult.status == MainContentStatus.selected);
    assert(ppResult.node == 0);
    assert(ppResult.text == paragraph ~ "\n\n" ~ paragraph,
        "two sibling <p>s must be separated by exactly one blank line");

    // Nested block elements: each <li> is its own block, so consecutive
    // items break, and the following sibling <p> also breaks from the list.
    HtmlTree listItems;
    listItems.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "article", null,
            [HtmlAttribute("class", "content")]),
        HtmlNode(HtmlNodeKind.element, 0, "ul", null, null),
        HtmlNode(HtmlNodeKind.element, 1, "li", null, null),
        HtmlNode(HtmlNodeKind.text, 2, null, "First item"),
        HtmlNode(HtmlNodeKind.element, 1, "li", null, null),
        HtmlNode(HtmlNodeKind.text, 4, null, "Second item"),
        HtmlNode(HtmlNodeKind.element, 0, "p", null, null),
        HtmlNode(HtmlNodeKind.text, 6, null, longParagraph),
    ];
    auto listResult = extractMainContent(listItems);
    assert(listResult.status == MainContentStatus.selected);
    assert(listResult.node == 0);
    assert(listResult.text == "First item\n\nSecond item\n\n" ~ paragraph,
        "nested <li>s and the following <p> must each be their own paragraph");

    // A <div> boundary also breaks, same as the other block tags.
    HtmlTree divBoundary;
    divBoundary.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "article", null,
            [HtmlAttribute("class", "content")]),
        HtmlNode(HtmlNodeKind.element, 0, "div", null, null),
        HtmlNode(HtmlNodeKind.text, 1, null, "Notice inside a div."),
        HtmlNode(HtmlNodeKind.element, 0, "p", null, null),
        HtmlNode(HtmlNodeKind.text, 3, null, longParagraph),
    ];
    auto divResult = extractMainContent(divBoundary);
    assert(divResult.status == MainContentStatus.selected);
    assert(divResult.node == 0);
    assert(divResult.text == "Notice inside a div.\n\n" ~ paragraph,
        "a <div> boundary must break the same as other block tags");

    // Edge case: a whitespace-only block sandwiched between two real ones
    // (e.g. pretty-printed indentation living directly in a <div>) must not
    // produce a double blank line, and the very first/last block must never
    // produce a leading/trailing blank line.
    HtmlTree blankBoundary;
    blankBoundary.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "article", null,
            [HtmlAttribute("class", "content")]),
        HtmlNode(HtmlNodeKind.element, 0, "p", null, null),
        HtmlNode(HtmlNodeKind.text, 1, null, longParagraph),
        HtmlNode(HtmlNodeKind.element, 0, "div", null, null),
        HtmlNode(HtmlNodeKind.text, 3, null, "   \n   "),
        HtmlNode(HtmlNodeKind.element, 0, "p", null, null),
        HtmlNode(HtmlNodeKind.text, 5, null, longParagraph),
    ];
    auto blankResult = extractMainContent(blankBoundary);
    assert(blankResult.status == MainContentStatus.selected);
    assert(blankResult.node == 0);
    assert(blankResult.text == paragraph ~ "\n\n" ~ paragraph,
        "a whitespace-only block between two real ones must not double the blank line, " ~
        "and there must be no leading/trailing blank line either");
}
