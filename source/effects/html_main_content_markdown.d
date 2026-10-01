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
/// writing a second copy keeps punctuation escaping identical whichever path
/// recovered it, instead of silently diverging. No heading/list/emphasis
/// structure is synthesized: JSON-LD
/// content has no DOM to derive that structure from, so the result is flat
/// Markdown paragraphs only -- never a lossy re-guess at structure that was
/// never there.
module effects.html_main_content_markdown;

import effects.html_main_content : ExtractionMode, extractMainContent,
    HtmlMainContentOutputLimit, MainContentCandidate, MainContentStatus,
    sectioningBlockTag, selectedContentTree;
import effects.html_markdown : clean, HtmlMarkdownOutputLimit,
    MarkdownRenderOptions, renderMarkdownFrom;
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
/// subtree) via `renderMarkdownFrom(..., options)`; for
/// `selectedStructuredData`, `selection.text` reflowed as flat Markdown
/// paragraphs (`structuredDataMarkdown`, above -- `options` does not apply
/// there: JSON-LD recovery has no DOM inline elements to format, link, or
/// embed an image from in the first place, only flat escaped text, exactly
/// as before issue #477). A genuine abstention carries no `.markdown` (same
/// reasoning as `MainContentResult.text` being empty on abstention: there is
/// no recovered content to render).
///
/// Issue #477: `options` defaults to `MarkdownRenderOptions.init` (full
/// inline structural fidelity), matching `renderMarkdownFrom`'s own default
/// -- byte-identical to before this parameter existed for every caller that
/// does not pass one, so #411's 20/20 corpus result and #438's
/// JSON-LD-fallback path are unaffected by this addition.
///
/// Issue #517: the `selected` path renders `selectedContentTree` (the
/// selected subtree with `.text`'s boilerplate exclusion already applied),
/// not the raw selected node, so `.markdown` and `.text` drop exactly the
/// same descendants. In that copy, the sectioning containers
/// (`sectioningBlockTag`: `section`/`article`/`nav`/...) are renamed to
/// `div`: renderNode treats them exactly like `div` except that it gives
/// them no block separation, so without the rename their text glued onto
/// the neighbouring text, which `.text` no longer does. `mode` (default
/// `standard`) is passed to `extractMainContent` and `selectedContentTree`
/// alike.
MainContentMarkdownResult extractMainContentMarkdown(const ref HtmlTree tree,
        const MarkdownRenderOptions options = MarkdownRenderOptions.init,
        ExtractionMode mode = ExtractionMode.standard) pure {
    auto selection = extractMainContent(tree, true, mode);
    MainContentMarkdownResult result;
    result.status = selection.status;
    result.node = selection.node;
    result.score = selection.score;
    result.candidatesOverflow = selection.candidatesOverflow;
    result.candidates = selection.candidates;
    if (selection.status == MainContentStatus.selected) {
        auto content = selectedContentTree(tree, selection.node, mode);
        foreach (ref node; content.nodes)
            if (sectioningBlockTag(node.name)) node.name = "div";
        result.markdown = renderMarkdownFrom(content, 0, options);
    } else if (selection.status == MainContentStatus.selectedStructuredData)
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
    // plain text with a blank line (`plain.text` below). Punctuation follows
    // the same rules as every other `renderMarkdown`/`renderMarkdownFrom`
    // caller.
    assert(combined.markdown ==
        "# Field notes from the delta survey\n\n" ~
        "The survey team spent three weeks mapping the river delta's shifting " ~
        "sandbars, recording water depth every two hundred meters along six " ~
        "transects. The main channel has migrated nearly forty meters east " ~
        "since the last survey.\n",
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
    assert(combined.markdown.canFind("Article body sentence."),
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
    // The literal `.` after "now" remains ordinary prose punctuation.
    assert(twoStepResult.markdown.canFind("First step body text here now."));
    assert(twoStepResult.markdown.canFind("Second step body text here now."));
    assert(twoStepResult.markdown.canFind("\n\n"),
        "two recovered JSON-LD bodies must render as two separate paragraphs");

    // Issue #484: a `<script>` element's text embedded inside a recovered
    // JSON-LD string value must not leak into `.markdown` either -- the
    // Markdown path reuses `extractMainContent`'s own `.text`
    // (`structuredDataMarkdown`), so the fix belongs in `html_main_content.d`
    // alone, but the guarantee is reconfirmed here at this module's own
    // boundary, matching this unittest block's own "reconfirmed here" idiom.
    //
    // Deliberately uses "evilPayloadMarker" rather than the ticket's own
    // "evil()" here: `structuredDataMarkdown`'s Markdown-source escaping
    // (the same `clean()` reuse asserted on `longParagraph`'s own literal
    // `.` above) rewrites "evil()" to "evil\(\)", so a literal
    // `canFind("evil()")` check can never find it either way and would
    // pass even with the fix absent -- an alphanumeric-only marker has no
    // Markdown-special characters to escape, so this assertion actually
    // exercises the fix.
    HtmlTree scriptInStructuredData;
    scriptInStructuredData.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "nav", null, null),
        HtmlNode(HtmlNodeKind.text, 0, null, "Home About Contact"),
        HtmlNode(HtmlNodeKind.element, size_t.max, "script", null,
            [HtmlAttribute("type", "application/ld+json")]),
        HtmlNode(HtmlNodeKind.text, 2, null,
            `{"@type":"Article","articleBody":"<div><p class=\"x\">Unclosed tags and ` ~
            `<b>bold <i>italic text here with <script>evilPayloadMarker<\/script> embedded and a ` ~
            `stray angle bracket and an unterminated tag with a very long real sentence ` ~
            `of readable prose padded out so that after every piece of embedded markup ` ~
            `is stripped away there is still comfortably more than two hundred bytes of ` ~
            `genuine paragraph text left over for the extraction floor to accept without ` ~
            `any trouble at all here now for sure."}`),
    ];
    auto scriptResult = extractMainContentMarkdown(scriptInStructuredData);
    assert(scriptResult.status == MainContentStatus.selectedStructuredData);
    assert(!scriptResult.markdown.canFind("evilPayloadMarker"),
        "hidden <script> text embedded inside a JSON-LD string value leaked into Markdown");
    assert(scriptResult.markdown.canFind("readable prose padded out"),
        "the real surrounding prose must still survive the fix");
}

// Issue #477: `extractMainContentMarkdown`'s new `options` parameter reaches
// the `selected` path's `renderMarkdownFrom` call unchanged, at the
// selection-combinator level (not just `html_markdown.d`'s own renderer
// unit tests). Fixture is the same two real pronats.de excerpts
// (`html_markdown.d`'s own "formatting" and "links and images" fixtures --
// see those unittests' doc comments for exact provenance), concatenated
// inside one `<article>` alongside a `<nav>` boilerplate sibling, mirroring
// this module's own pre-existing `headingThenParagraph`-style fixture shape
// (real content standing in for the article body, a `<nav>` standing in for
// chrome that selection must not leak).
unittest {
    import effects.html_tree : parseHtml;
    import std.algorithm.searching : canFind;

    string formattingExcerpt =
        "<h3><strong>Arbeit ist wichtig für das Selbstwertgefühl</strong></h3>" ~
        "<p>Wenn wir von „kritischer Wertschätzung“ der Arbeit der " ~
        "Kinder sprechen, achten wir auf beides: auf die problematische Form und die " ~
        "Bedingungen der Arbeit, die der körperlichen und geistigen Entwicklung " ~
        "entgegenstehen, aber eben auch auf die Möglichkeiten, die sich aus der " ~
        "Arbeitserfahrung für Kinder ergeben.</p>";
    string linkImageExcerpt =
        `<div class="image">` ~
        `<a href="/assets/Uploads/burkina-appleseller.jpg" title="Äpfelverkäuferin in Burkina Faso - (c) Philip Meade" class="gallery">` ~
        `<img src="/assets/Uploads/burkina-appleseller.jpg" alt="Äpfelverkäuferin in Burkina Faso - (c) Philip Meade" />` ~
        `</a></div>` ~
        `<p class="imageDescription">Kinder identifizieren sich auch über ihre Arbeit, so wie bei diese ` ~
        `Äpfelverkäuferin aus Burkina Faso. Die Arbeit kann ihnen Möglichkeiten zur ` ~
        `gesellschaftlichen Teilhabe eröffnen.</p>`;
    string page = "<nav>Home About Contact</nav><article>" ~
        formattingExcerpt ~ linkImageExcerpt ~ "</article>";

    auto outcome = parseHtml(cast(const(ubyte)[]) page);
    assert(outcome.isParsed);
    auto tree = outcome.tree;

    auto defaulted = extractMainContentMarkdown(tree);
    auto explicitOn = extractMainContentMarkdown(tree, MarkdownRenderOptions(true, true, true));
    auto allOff = extractMainContentMarkdown(tree, MarkdownRenderOptions(false, false, false));

    assert(defaulted.status == MainContentStatus.selected);
    assert(defaulted.status == explicitOn.status && defaulted.status == allOff.status);
    assert(defaulted.node == explicitOn.node && defaulted.node == allOff.node,
        "options must change rendering only, never which subtree selection picks");

    // Default (omitted `options`) is byte-identical to explicitly requesting
    // full fidelity -- this is the #411/#438 non-regression guarantee at
    // this combinator's own public entry point, not just `html_markdown.d`'s.
    assert(defaulted.markdown == explicitOn.markdown);
    assert(defaulted.markdown.canFind("**Arbeit ist wichtig"),
        "default must preserve real ** emphasis around the page's own heading");
    assert(defaulted.markdown.canFind(
        "[![Äpfelverkäuferin in Burkina Faso \\- \\(c\\) Philip Meade]" ~
        "(</assets/Uploads/burkina-appleseller.jpg>)]" ~
        "(</assets/Uploads/burkina-appleseller.jpg>)"),
        "default must preserve the real linked thumbnail as nested image-inside-link syntax");

    assert(!allOff.markdown.canFind("**"), "formatting=false must drop ** at this level too");
    assert(!allOff.markdown.canFind("]("), "links=false must drop [...](...)  at this level too");
    assert(!allOff.markdown.canFind("!["), "images=false must drop ![...](...)  at this level too");
    assert(allOff.markdown.canFind("Arbeit ist wichtig für das Selbstwertgefühl"),
        "all-off must keep the real heading text itself, only strip the ** markers");
    assert(allOff.markdown.canFind("Äpfelverkäuferin in Burkina Faso"),
        "all-off must keep the real image's alt text as plain text");

    // Same invariant #438's own fixture above already proves for this
    // module: chrome never leaks into selected content, options or not.
    assert(!defaulted.markdown.canFind("Home") && !allOff.markdown.canFind("Home"));
}

// Issue #493 regression: the nested-table pipe-syntax corruption
// (`html_markdown.d`'s own fixture, same ticket) is reachable through this
// combinator too -- `extractMainContentMarkdown`'s `selected` path renders
// via the very same `renderMarkdownFrom`/`renderNode`/`renderTable` call
// chain, just scoped to the selected subtree, so the fix (an `inCell` guard
// entirely internal to `html_markdown.d`) is exercised here unmodified.
// This module's own source needed no change -- confirming that, not
// duplicating the fix, is the point of this test.
unittest {
    import effects.html_tree : parseHtml;
    import std.algorithm.searching : canFind;

    string html = "<nav>Home About Contact</nav><article><h1>Report</h1>" ~
        "<p>This report includes a small reference table summarizing the " ~
        "figures discussed below, reproduced here exactly as it appeared " ~
        "in the original source document for the reader's convenience.</p>" ~
        "<table><tr><th>Outer</th></tr>" ~
        "<tr><td>before<table><tr><th>Inner</th></tr>" ~
        "<tr><td>innerdata</td></tr></table>after</td></tr></table>" ~
        "<p>The remainder of this report continues with further analysis " ~
        "of the figures shown above and their implications for the " ~
        "overall conclusions reached by the study's authors.</p></article>";
    auto outcome = parseHtml(cast(const(ubyte)[]) html);
    assert(outcome.isParsed);
    auto tree = outcome.tree;

    auto result = extractMainContentMarkdown(tree);
    assert(result.status == MainContentStatus.selected);
    assert(!result.markdown.canFind("Home"),
        "the sibling <nav> boilerplate must not leak into the selected content");
    assert(result.markdown.canFind("| Outer | "),
        "the outer table's own real header row must still render");
    assert(result.markdown.canFind("before Inner innerdata after"),
        "the nested table's real content must survive, flattened into the " ~
        "outer cell");
    assert(!result.markdown.canFind("|---| |") && !result.markdown.canFind("| |---|"),
        "no stray delimiter-row fragment from the nested table may bleed " ~
        "into the outer table's data row at this combinator level either");
}

// Issue #478: `extractMainContentMarkdown`'s `options` parameter reaches the
// `selected` path's `renderMarkdownFrom` call for the four new fields
// (`tables`/`lists`/`quotes`/`code`), not just #477's original three, at
// this combinator's own public entry point. Fixture is the real held-out
// blockquote excerpt (`html_markdown.d`'s own "quotations" fixture -- see
// that unittest's doc comment for exact provenance: fixture 08 of the
// pinned adbar/trafilatura held-out corpus) alongside a real `<nav>`
// boilerplate sibling, mirroring this module's own pre-existing
// `headingThenParagraph`-style fixture shape. Named-field
// `MarkdownRenderOptions` construction throughout, per this ticket's own
// instruction (a 7-field all-`bool` struct makes positional construction a
// real transposition-risk footgun).
unittest {
    import effects.html_tree : parseHtml;
    import std.algorithm.searching : canFind;

    string quoteExcerpt =
        `<h1>Warum die Münze nicht fair ist</h1>` ~
        `<p>Ein letzte Woche in der Süddeutschen erschienener Artikel ` ~
        `erklärt es so:</p>` ~
        `<blockquote><p>Im Fall des Münzwurfs kommt es zur Präzession, ` ~
        `wenn die Münze nicht genau mittig geschnippt wird. Dann eiert sie ` ~
        `in der Flugphase, und das führt dazu, dass sie etwas mehr Zeit in ` ~
        `der ursprünglichen Ausrichtung verbringt und demzufolge häufiger ` ~
        `so landet, wie sie geschnipst wurde.</p></blockquote>` ~
        `<p>Das bestätigt experimentell eine Vorhersage aus der 2007 in ` ~
        `SIAM Reviews erschienenen Arbeit &#8220;Dynamical bias in the ` ~
        `coin toss&#8221; von Persi Diaconis, Susan Holmes und Richard ` ~
        `Montgomery.</p>`;
    string page = "<nav>Home About Contact</nav><article>" ~ quoteExcerpt ~ "</article>";

    auto outcome = parseHtml(cast(const(ubyte)[]) page);
    assert(outcome.isParsed);
    auto tree = outcome.tree;

    auto defaulted = extractMainContentMarkdown(tree);
    auto explicitOn = extractMainContentMarkdown(tree, MarkdownRenderOptions(
        formatting: true, links: true, images: true,
        tables: true, lists: true, quotes: true, code: true));
    auto quotesOff = extractMainContentMarkdown(tree,
        MarkdownRenderOptions(quotes: false));

    assert(defaulted.status == MainContentStatus.selected);
    assert(defaulted.status == explicitOn.status && defaulted.status == quotesOff.status);
    assert(defaulted.node == explicitOn.node && defaulted.node == quotesOff.node,
        "options must change rendering only, never which subtree selection picks");

    // Default (omitted `options`) is byte-identical to explicitly requesting
    // full fidelity -- the same #411/#438 non-regression guarantee this
    // module's own earlier unittest already proves for `formatting`/
    // `links`/`images`, now covering `quotes` (and, by the same code path,
    // `tables`/`lists`/`code`) too.
    assert(defaulted.markdown == explicitOn.markdown);
    assert(defaulted.markdown.canFind("> Im Fall des Münzwurfs"),
        "default must preserve the real blockquote's `> ` marker");

    assert(!quotesOff.markdown.canFind("> "),
        "quotes=false must drop the `> ` marker at this combinator level too");
    assert(quotesOff.markdown.canFind("Im Fall des Münzwurfs"),
        "quotes=false must keep the real quoted text itself, only strip the marker");

    // Same invariant #438's own fixture above already proves for this
    // module: chrome never leaks into selected content, options or not.
    assert(!defaulted.markdown.canFind("Home") && !quotesOff.markdown.canFind("Home"));
}

// Issue #485: Markdown-path twin of `html_main_content.d`'s own #485
// unittest (see its doc comment for the HTML5 tokenizer mechanics). A
// literal `</script>` inside a JSON-LD string value truncates the script
// element; the truncated block must never reach `structuredDataMarkdown`,
// and the script's own (invisible) prefix must never appear in Markdown.
// The escaped `<\/script>` twin still renders as recovered JSON-LD, free of
// the page's `<nav>` chrome. Marker words carry no Markdown-special
// characters so escaping cannot make a negative assertion pass by accident.
unittest {
    import effects.html_tree : parseHtml;
    import std.algorithm.searching : canFind;

    string tailProse = " and some prose after the close tag with a very long real " ~
        "sentence of readable prose padded out so that there is still comfortably " ~
        "more than two hundred bytes of genuine paragraph text left over for the " ~
        "extraction floor to accept without any trouble at all here now for sure " ~
        "end of body";
    string pageWith(string closeTag) {
        return "<html><head>\n<script type=\"application/ld+json\">\n" ~
            `{"@type":"Article","articleBody":"Some prose before the marker PrefixMarker ` ~
            closeTag ~ tailProse ~ "\"}\n</script>\n</head><body><nav>NavBoilerplateMarker " ~
            "Home About Contact</nav></body></html>";
    }

    auto unescaped = parseHtml(cast(const(ubyte)[]) pageWith("</script>"));
    assert(unescaped.isParsed);
    auto unescapedResult = extractMainContentMarkdown(unescaped.tree);
    assert(unescapedResult.status != MainContentStatus.selectedStructuredData,
        "truncated JSON-LD must never be promoted to selectedStructuredData");
    assert(!unescapedResult.markdown.canFind("PrefixMarker"),
        "text inside the (truncated) script element must never leak into Markdown");

    auto escaped = parseHtml(cast(const(ubyte)[]) pageWith(`<\/script>`));
    assert(escaped.isParsed);
    auto escapedResult = extractMainContentMarkdown(escaped.tree);
    assert(escapedResult.status == MainContentStatus.selectedStructuredData);
    assert(escapedResult.markdown.canFind("PrefixMarker") &&
        escapedResult.markdown.canFind("end of body"),
        "a properly escaped JSON-LD value must be recovered whole");
    assert(!escapedResult.markdown.canFind("NavBoilerplateMarker"),
        "recovered JSON-LD Markdown must never carry DOM boilerplate");
}

// Issue #517: `.text` and `.markdown` must drop the same descendants of the
// selected node, and put block boundaries in the same places. Before this,
// `.markdown` rendered the raw selected node, so a `<nav class="nav">`
// (negative keyword) was missing from `.text` but present in `.markdown`,
// and a `<section>` glued onto the preceding text in both. Marker words
// are plain alphanumerics so escaping cannot make a negative assertion
// vacuous.
unittest {
    import effects.html_main_content : ExtractionMode, MainContentResult;
    import effects.html_tree : parseHtml;
    import std.algorithm.searching : canFind;

    string lede = "LedeStart the survey team spent three weeks mapping the river " ~
        "delta and recording water depth every two hundred meters along six " ~
        "transects while the main channel migrated nearly forty meters east " ~
        "since the previous survey was completed and the second leg of the " ~
        "survey repeated every one of those transects a month later to check " ~
        "how quickly the sandbars were moving after the spring floods had " ~
        "passed through the lower reaches of the delta LedeEnd";
    // The boilerplate comes last, behind a spare paragraph, so `precision`'s
    // "either neighbour is negative" sandwich rule cannot also drop the
    // <section>/closing paragraph the positive assertions look for.
    string page = "<html><body><div>" ~ lede ~
        "<section>SectionMarker words</section>" ~
        "<p>ClosingMarker words</p><p>SpareParagraph</p>" ~
        `<nav class="nav">NavClassMarker Home About</nav>` ~
        "<nav>NavTagMarker Contact</nav>" ~
        `<div class="share">ShareMarker</div></div></body></html>`;
    auto outcome = parseHtml(cast(const(ubyte)[]) page);
    assert(outcome.isParsed);
    auto tree = outcome.tree;

    foreach (mode; [ExtractionMode.standard, ExtractionMode.precision,
            ExtractionMode.recall]) {
        MainContentResult plain = extractMainContent(tree, true, mode);
        auto combined = extractMainContentMarkdown(tree, MarkdownRenderOptions.init, mode);
        assert(plain.status == MainContentStatus.selected);
        assert(combined.status == plain.status && combined.node == plain.node);
        assert(tree.nodes[combined.node].name == "div");

        foreach (marker; ["NavClassMarker", "NavTagMarker", "ShareMarker"]) {
            assert(!plain.text.canFind(marker), marker ~ " leaked into .text");
            assert(!combined.markdown.canFind(marker), marker ~ " leaked into .markdown");
        }
        foreach (marker; ["LedeStart", "SectionMarker", "ClosingMarker"]) {
            assert(plain.text.canFind(marker), marker ~ " missing from .text");
            assert(combined.markdown.canFind(marker), marker ~ " missing from .markdown");
        }
        // Same block boundary at the <section> in both outputs.
        assert(plain.text.canFind("LedeEnd\n\nSectionMarker words\n\nClosingMarker"),
            plain.text);
        assert(combined.markdown.canFind("LedeEnd\n\nSectionMarker words\n\nClosingMarker"),
            combined.markdown);
    }

    // Sectioning tags are only renamed in the rendering copy: the caller's
    // tree is untouched.
    size_t sections;
    foreach (ref node; tree.nodes) if (node.name == "section") ++sections;
    assert(sections == 1, "extractMainContentMarkdown must not mutate its input tree");
}
