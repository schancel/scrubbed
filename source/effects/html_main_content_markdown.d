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
///
/// Issue #438: `extractMainContent` has a second success status,
/// `MainContentStatus.selectedStructuredData` (issue #411) -- content
/// recovered from a `<script type="application/ld+json">` schema.org block
/// when the ordinary DOM candidate pass abstained. That status has no
/// selected tree node at all (`.node` stays `size_t.max`; the text was
/// synthesized from JSON, never selected from a subtree), so it cannot go
/// through `renderMarkdownFrom(tree, node)` the way `selected` does -- there
/// is no node to walk. Rather than quarantine already-recovered content
/// (indistinguishable, by reason string, from a genuine abstention -- the
/// bug this issue reports), `.markdown` is now populated for this status
/// too: `selection.text` (already whitespace-collapsed, with "\n\n" marking
/// paragraph breaks -- see `structuredDataFallbackText`'s doc comment in
/// `html_main_content.d`) is split on those paragraph breaks and each
/// paragraph is run through `html_markdown.d`'s own `clean()` escaping
/// helper (Markdown-significant punctuation, `&`/`<`/`>`), then rejoined
/// with blank lines. That is deliberately the *same* escaping
/// `renderNode`/`renderMarkdownFrom` apply to ordinary text nodes --
/// reusing `clean()` (exported from `html_markdown.d` for this) rather than
/// writing a second copy is what keeps a literal `.` (say) escaping
/// identically to `\.` whichever path recovered it, instead of silently
/// diverging. No heading/list/emphasis structure is synthesized: JSON-LD
/// content has no DOM to derive that structure from, so the result is flat
/// Markdown paragraphs only -- never a lossy re-guess at structure that was
/// never there.
module effects.html_main_content_markdown;

import effects.html_main_content : extractMainContent, HtmlMainContentOutputLimit,
    MainContentCandidate, MainContentStatus;
import effects.html_markdown : clean, HtmlMarkdownOutputLimit, renderMarkdownFrom;
import effects.html_tree : HtmlTree;
import std.array : split;

/// Same status/candidate shape as `html_main_content.MainContentResult`, but
/// `.markdown` (populated for both success statuses, `selected` and
/// `selectedStructuredData`) is real Markdown instead of
/// `MainContentResult.text`'s flattened plain text: for `selected`, the
/// selected subtree rendered via `renderMarkdownFrom`; for
/// `selectedStructuredData`, `selection.text` escaped and reflowed as flat
/// paragraphs (see this module's doc comment -- there is no tree node for
/// that status to render from).
struct MainContentMarkdownResult {
    MainContentStatus status;
    size_t node = size_t.max;
    double score = 0.0;
    string markdown;
    bool candidatesOverflow;
    MainContentCandidate[] candidates;
}

// `selection.text` for `selectedStructuredData` already has its whitespace
// collapsed to single spaces within a paragraph, with "\n\n" (never any
// other run) marking a paragraph break -- `CollapsingWriter.paragraphBreak`
// in `html_main_content.d` is the only thing that ever emits it, and it
// never emits a leading/trailing one either. So splitting on literal
// "\n\n" recovers exactly the same paragraph boundaries the fallback
// scanner found, with no risk of an embedded "\n\n" inside one recovered
// body: any raw newline within a single JSON string is itself whitespace
// that `CollapsingWriter.feed` already collapsed to an ordinary space
// before it ever reached `.text`.
private string structuredDataMarkdown(string text) pure {
    if (!text.length) return null;
    string result;
    foreach (i, paragraph; text.split("\n\n")) {
        if (i) result ~= "\n\n";
        result ~= clean(paragraph);
    }
    result ~= "\n";
    return result;
}

/// Runs `extractMainContent` completely unchanged -- same scoring, same
/// selection, same abstention rules -- and, on either success status,
/// renders `.markdown`: for `selected`, the winning subtree (and only that
/// subtree) via `renderMarkdownFrom(tree, result.node)`; for
/// `selectedStructuredData`, `selection.text` reflowed as flat Markdown
/// paragraphs (`structuredDataMarkdown`, above). A genuine abstention
/// carries no `.markdown` (same reasoning as `MainContentResult.text` being
/// empty on abstention: there is no recovered content to render).
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
    else if (selection.status == MainContentStatus.selectedStructuredData)
        result.markdown = structuredDataMarkdown(selection.text);
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

// Issue #438 regression: `selectedStructuredData` (issue #411's JSON-LD
// fallback) must produce real `.markdown`, not be left empty/quarantined.
// Fixture pattern-matched directly off `html_main_content.d`'s own
// `structuredOnly` unittest fixture (same module, "structured-data
// fallback" section) -- a chrome-only <nav> DOM (abstains on its own) plus
// a schema.org HowTo `<script type="application/ld+json">` carrying the
// page's real content as `step[].itemListElement.text`.
unittest {
    import effects.html_tree : HtmlAttribute, HtmlNode, HtmlNodeKind;
    import std.algorithm.searching : canFind;

    string longParagraph;
    foreach (_; 0 .. 25) longParagraph ~= "Article body sentence. ";

    HtmlTree structuredOnly;
    structuredOnly.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "nav", null, null),
        HtmlNode(HtmlNodeKind.text, 0, null, "Home About Contact"),
        HtmlNode(HtmlNodeKind.element, size_t.max, "script", null,
            [HtmlAttribute("type", "application/ld+json")]),
        HtmlNode(HtmlNodeKind.text, 2, null,
            `{"@type":"HowTo","step":[{"@type":"HowToStep","itemListElement":` ~
            `{"@type":"HowToDirection","text":"<p>` ~ longParagraph ~ `</p>"}}]}`),
    ];
    auto plain = extractMainContent(structuredOnly);
    auto combined = extractMainContentMarkdown(structuredOnly);

    // Selection outcome mirrors `extractMainContent` exactly, same
    // invariant Slice 2's own `selected`-status test already checks.
    assert(combined.status == MainContentStatus.selectedStructuredData);
    assert(combined.status == plain.status);
    assert(combined.node == size_t.max, "structured-data text has no tree node");
    assert(combined.score == 0.0);

    // The key #438 proof: `.markdown` is populated (previously empty,
    // silently quarantined by the stage layer) and carries the recovered
    // text, with the same literal-character escaping (`.` -> `\.`) ordinary
    // `renderMarkdownFrom` output gets -- proving `clean()` reuse, not a
    // second hand-written escaper that could drift from it.
    assert(combined.markdown.length > 0,
        "recovered structured-data content must not be dropped on the floor");
    assert(combined.markdown.canFind("Article body sentence\\."),
        "same literal-`.`-escaping as ordinary rendered Markdown text");
    assert(!combined.markdown.canFind("<p>") && !combined.markdown.canFind("</p>"),
        "embedded HTML markup inside the JSON string must still be stripped");
    assert(!combined.markdown.canFind("Home") && !combined.markdown.canFind("Contact"),
        "the abstaining <nav> DOM contributes no content -- only the JSON-LD text does");

    // No heading/list syntax is synthesized -- there is no DOM structure for
    // a JSON-LD recovery to derive it from, just flat paragraph text.
    assert(!combined.markdown.canFind("#"), "no heading syntax may be invented");

    // Multi-body JSON-LD (two HowTo steps) becomes two Markdown paragraphs,
    // separated by a blank line exactly like `renderMarkdownFrom`'s own
    // block separation -- same "\n\n" the ordinary DOM path uses.
    HtmlTree twoSteps;
    twoSteps.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "script", null,
            [HtmlAttribute("type", "application/ld+json")]),
        HtmlNode(HtmlNodeKind.text, 0, null,
            `{"@type":"HowTo","step":[` ~
            `{"itemListElement":{"text":"<p>First step body text here now.` ~
            longParagraph ~ `</p>"}},` ~
            `{"itemListElement":{"text":"<p>Second step body text here now.` ~
            longParagraph ~ `</p>"}}]}`),
    ];
    auto twoStepResult = extractMainContentMarkdown(twoSteps);
    assert(twoStepResult.status == MainContentStatus.selectedStructuredData);
    // The literal `.` after "now" is itself escaped (`clean()`'s ordinary
    // Markdown-source escaping), same as every other `.` in this fixture.
    assert(twoStepResult.markdown.canFind("First step body text here now\\."));
    assert(twoStepResult.markdown.canFind("Second step body text here now\\."));
    assert(twoStepResult.markdown.canFind("\n\n"),
        "two recovered JSON-LD bodies must render as two separate paragraphs");
}
