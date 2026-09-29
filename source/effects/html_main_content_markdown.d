/// Pure combinator pairing main-content selection (boilerplate removal) with
/// Markdown rendering (headings, paragraph breaks, etc.), so a caller gets
/// both in one pass instead of today's binary choice between
/// `html_main_content.d`'s flat, boilerplate-free text and
/// `html_markdown.d`'s structured, whole-document Markdown. Issue #335
/// Slice 2. Deliberately its own module rather than added to either
/// `html_main_content.d` or `html_markdown.d`: those two stay single-purpose
/// (selection scoring; recursive rendering) and free of a new
/// cross-dependency on each other, matching this codebase's existing
/// granularity of one small pure module per concern (mirrored by
/// `html_main_content_stage.d`/`html_markdown_stage.d` already being split
/// from their pure counterparts). `scripts/check_modules.d`'s effects-layer
/// rule permits an effects module importing other effects modules, so this
/// placement is not a layering exception -- just a fresh leaf.
///
/// No stage/CLI wiring here: this was, at the time this module was written
/// (issue #335 Slice 2), a library-level addition only, and a
/// `clean-web-document`-style Markdown-output stage was left as a
/// separate, later, real product decision. That decision has since been
/// made: `effects.html_main_content_markdown_stage` (issue #431) wires
/// this exact combinator through `extract --format=main-content-markdown`
/// and `run --stage extract=html-main-content-markdown`. This module
/// itself is unchanged -- the wiring lives entirely in that stage module.
module effects.html_main_content_markdown;

import effects.html_main_content : extractMainContent, HtmlMainContentOutputLimit,
    MainContentCandidate, MainContentStatus;
import effects.html_markdown : HtmlMarkdownOutputLimit, renderMarkdownFrom;
import effects.html_tree : HtmlTree;

/// Same status/candidate shape as `html_main_content.MainContentResult`, but
/// `.markdown` (populated only when `.status == selected`) is real Markdown
/// for the selected subtree -- rendered via `renderMarkdownFrom` -- instead
/// of `MainContentResult.text`'s flattened plain text.
struct MainContentMarkdownResult {
    MainContentStatus status;
    size_t node = size_t.max;
    double score = 0.0;
    string markdown;
    bool candidatesOverflow;
    MainContentCandidate[] candidates;
}

/// Runs `extractMainContent` completely unchanged -- same scoring, same
/// selection, same abstention rules -- and, only on a `selected` result,
/// renders the winning subtree (and only that subtree) as Markdown via
/// `renderMarkdownFrom(tree, result.node)` instead of taking
/// `extractMainContent`'s own flat-text `.text` path. An abstained result
/// carries no `.markdown` (same reasoning as `MainContentResult.text` being
/// empty on abstention: there is no selected subtree to render).
MainContentMarkdownResult extractMainContentMarkdown(const ref HtmlTree tree) pure {
    auto selection = extractMainContent(tree);
    MainContentMarkdownResult result;
    result.status = selection.status;
    result.node = selection.node;
    result.score = selection.score;
    result.candidatesOverflow = selection.candidatesOverflow;
    result.candidates = selection.candidates;
    if (selection.status == MainContentStatus.selected)
        result.markdown = renderMarkdownFrom(tree, selection.node);
    return result;
}

unittest {
    import effects.html_tree : HtmlAttribute, HtmlNode, HtmlNodeKind;

    // This ticket's own cited repro, verbatim, wrapped in an <article> the
    // real selection algorithm actually picks (identical fixture shape to
    // Slice 1's `headingThenParagraph` unittest in html_main_content.d,
    // confirming Slice 2 composes with Slice 1's already-landed behavior).
    // A <nav> sibling root is added so scoping-to-the-selected-subtree-only
    // is actually exercised, not just assumed.
    HtmlTree tree;
    tree.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "nav", null, null),
        HtmlNode(HtmlNodeKind.text, 0, null, "Home About Contact"),
        HtmlNode(HtmlNodeKind.element, size_t.max, "article", null,
            [HtmlAttribute("class", "content")]),
        HtmlNode(HtmlNodeKind.element, 2, "h1", null, null),
        HtmlNode(HtmlNodeKind.text, 3, null, "Field notes from the delta survey"),
        HtmlNode(HtmlNodeKind.element, 2, "p", null, null),
        HtmlNode(HtmlNodeKind.text, 5, null,
            "The survey team spent three weeks mapping the river delta's shifting " ~
            "sandbars, recording water depth every two hundred meters along six " ~
            "transects. The main channel has migrated nearly forty meters east " ~
            "since the last survey."),
    ];

    auto plain = extractMainContent(tree);
    auto combined = extractMainContentMarkdown(tree);

    // Selection outcome (status/node/score/candidates) must match
    // `extractMainContent` exactly -- Slice 2 changes only what happens with
    // an already-selected node's rendering, never which node gets selected.
    assert(combined.status == MainContentStatus.selected);
    assert(combined.status == plain.status);
    assert(combined.node == plain.node);
    assert(combined.node == 2, "the article wrapper, not the lone h1/p, should win");
    assert(combined.score == plain.score);
    assert(combined.candidatesOverflow == plain.candidatesOverflow);
    assert(combined.candidates == plain.candidates);

    // The key Slice 2 proof: real Markdown heading syntax, not Slice 1's
    // plain text with a blank line (`plain.text` below). `renderNode`
    // separately escapes literal `.` as `\.` (its ordinary Markdown-source
    // escaping, unrelated to this slice, exercised here exactly as it would
    // be for any other `renderMarkdown`/`renderMarkdownFrom` caller).
    assert(combined.markdown ==
        "# Field notes from the delta survey\n\n" ~
        "The survey team spent three weeks mapping the river delta's shifting " ~
        "sandbars, recording water depth every two hundred meters along six " ~
        "transects\\. The main channel has migrated nearly forty meters east " ~
        "since the last survey\\.\n",
        "expected genuine Markdown heading syntax scoped to the selected subtree");
    assert(plain.text ==
        "Field notes from the delta survey\n\n" ~
        "The survey team spent three weeks mapping the river delta's shifting " ~
        "sandbars, recording water depth every two hundred meters along six " ~
        "transects. The main channel has migrated nearly forty meters east " ~
        "since the last survey.",
        "Slice 1's flat-text path is unchanged by Slice 2's addition");

    import std.algorithm.searching : canFind;
    assert(combined.markdown.canFind("# Field notes from the delta survey"),
        "must contain real Markdown heading syntax, not just a line break");
    // Scoped to the selected <article> subtree only -- the sibling <nav>'s
    // boilerplate never appears in the rendered Markdown.
    assert(!combined.markdown.canFind("Home"));
    assert(!combined.markdown.canFind("About"));
    assert(!combined.markdown.canFind("Contact"));
}

unittest {
    // Abstention: no selected subtree, so no Markdown to render -- mirrors
    // `MainContentResult.text`'s own empty-on-abstention behavior.
    import effects.html_tree : HtmlNode, HtmlNodeKind;

    HtmlTree nav;
    nav.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "nav", null, null),
        HtmlNode(HtmlNodeKind.text, 0, null, "Home About Contact"),
    ];
    auto result = extractMainContentMarkdown(nav);
    assert(result.status == MainContentStatus.abstainedBelowThreshold);
    assert(result.markdown.length == 0);
}
