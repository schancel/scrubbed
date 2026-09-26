/// Release-active, network-free structural and safety check for the pure
/// main-content selector. Only reads files under experiments/html_main_content
/// /fixtures/** (authored, synthetic, no third-party bytes). Never invokes
/// fetch_held_out.sh and has no dependency on the held-out acquisition tier.
module experiments.html_main_content.check;

import effects.html_main_content : HtmlMainContentOutputLimit, MainContentCandidate,
    MainContentResult, MainContentStatus, extractMainContent, maxMainContentCandidates,
    maxMainContentTextBytes, negativeContentTags, negativeKeywords, positiveContentTags,
    positiveKeywords;
import effects.html_tree : HtmlAttribute, HtmlNode, HtmlNodeKind, HtmlTree, parseHtml;
import std.conv : to;
import std.file : readText;
import std.path : buildPath;
import std.stdio : writeln;

private void need(bool condition, string label) {
    if (!condition) throw new Exception("HTML main content check: " ~ label);
}

private MainContentResult runFixture(string root, string name) {
    auto html = readText(buildPath(root, name ~ ".html"));
    auto parsed = parseHtml(cast(const(ubyte)[]) html);
    need(parsed.isParsed, name ~ " did not parse");
    auto first = extractMainContent(parsed.tree);
    auto second = extractMainContent(parsed.tree);
    need(first.status == second.status && first.node == second.node &&
        first.score == second.score && first.text == second.text,
        name ~ " was not deterministic across repeat calls");
    return first;
}

private void expectSelected(string root, string name, size_t node, double score,
        string text) {
    auto result = runFixture(root, name);
    need(result.status == MainContentStatus.selected,
        name ~ " expected selected, got " ~ to!string(result.status));
    need(result.node == node, name ~ " unexpected selected node index");
    need(result.score == score, name ~ " unexpected selected score");
    need(result.text == text, name ~ " unexpected selected text: " ~ result.text);
}

private void expectAbstained(string root, string name, MainContentStatus status) {
    auto result = runFixture(root, name);
    need(result.status == status, name ~ " expected " ~ to!string(status) ~
        " got " ~ to!string(result.status));
    need(result.node == size_t.max, name ~ " abstention carried a node index");
    need(result.text.length == 0, name ~ " abstention carried text");
}

// A test-authored, hand-built HtmlTree that never goes through the parser,
// used only to prove the output cap and the fixed-table golden.
private HtmlTree syntheticArticle(string text) {
    HtmlTree tree;
    tree.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "article", null, null),
        HtmlNode(HtmlNodeKind.text, 0, null, text),
    ];
    return tree;
}

private void tableDriftProof() {
    // Any accidental edit to the fixed tag/keyword tables changes these
    // exact lists and fails here before it can silently change scoring.
    need(positiveContentTags == ["article", "main", "section", "p"],
        "positive tag table drifted");
    need(negativeContentTags == ["nav", "aside", "footer", "header", "form",
        "button", "figure"], "negative tag table drifted");
    need(positiveKeywords == ["content", "article", "main", "post", "body", "entry"],
        "positive keyword table drifted");
    need(negativeKeywords == ["nav", "sidebar", "footer", "header", "comment",
        "menu", "ad", "advert", "promo", "share", "social", "related", "widget",
        "breadcrumb"], "negative keyword table drifted");

    // A drift in the tag table's numeric weight, not just its membership,
    // must also change a directly observable score.
    HtmlTree positiveTag;
    positiveTag.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "article", null, null),
        HtmlNode(HtmlNodeKind.element, 0, "p", null, null),
        HtmlNode(HtmlNodeKind.text, 1, null,
            "Enough paragraph text to clear the selectable floor by a wide margin so the tag weight golden is unambiguous and stable across edits."),
    ];
    auto tagged = extractMainContent(positiveTag);
    need(tagged.candidates[0].score == 473, "article/p positive tag weight drifted");

    HtmlTree negativeTag;
    negativeTag.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "nav", null, null),
        HtmlNode(HtmlNodeKind.text, 0, null, "Home About Contact Careers Support"),
    ];
    auto navScored = extractMainContent(negativeTag);
    need(navScored.candidates[0].score == -266, "negative tag weight drifted");

    // A div with a positive keyword class and a substantial direct paragraph.
    HtmlTree keywordDiv;
    keywordDiv.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "div", null,
            [HtmlAttribute("class", "content")]),
        HtmlNode(HtmlNodeKind.element, 0, "p", null, null),
        HtmlNode(HtmlNodeKind.text, 1, null,
            "Enough paragraph text to clear the selectable floor by a wide margin for the keyword table golden."),
    ];
    auto keyworded = extractMainContent(keywordDiv);
    need(keyworded.candidates[0].score == 398, "content keyword weight drifted");
}

private void capProof() {
    auto longText = new char[maxMainContentTextBytes + 1];
    longText[] = 'x';
    auto oversized = syntheticArticle(cast(string) longText.idup);
    bool rejected;
    try extractMainContent(oversized);
    catch (HtmlMainContentOutputLimit) rejected = true;
    need(rejected, "output cap did not reject expansion before publish");

    // The cap rejects before any partial text is observable: a second call
    // on the same (unmutated) tree throws again rather than returning a
    // truncated result.
    bool rejectedAgain;
    try extractMainContent(oversized);
    catch (HtmlMainContentOutputLimit) rejectedAgain = true;
    need(rejectedAgain, "output cap was not stable across repeat calls");
}

private void candidateBoundProof() {
    // 40 direct <p> siblings under one article: far more element candidates
    // than the 16-entry cap, proving the top list stays bounded and flags
    // overflow rather than growing unboundedly.
    HtmlNode[] nodes = [HtmlNode(HtmlNodeKind.element, size_t.max, "article", null, null)];
    foreach (i; 0 .. 40) {
        nodes ~= HtmlNode(HtmlNodeKind.element, 0, "p", null, null);
        nodes ~= HtmlNode(HtmlNodeKind.text, cast(size_t) nodes.length - 1, null,
            "Distinct paragraph text padded to clear the per-paragraph floor number " ~
            to!string(i) ~ ".");
    }
    HtmlTree many;
    many.nodes = nodes;
    auto result = extractMainContent(many);
    need(result.candidates.length <= maxMainContentCandidates,
        "candidate list exceeded its bound");
    need(result.candidatesOverflow, "41 element candidates did not flag overflow");
}

void main() {
    auto root = buildPath("experiments", "html_main_content", "fixtures");

    expectSelected(root, "news-article-shaped", 18, 1325,
        "Local Council Approves New Park FundingThe city council voted unanimously " ~
        "on Tuesday evening to approve a new round of funding for the downtown park " ~
        "renovation project, citing strong public support gathered over several " ~
        "months of community meetings.Council members said the funding would cover " ~
        "new playground equipment, expanded walking trails, and a renovated public " ~
        "plaza, with construction expected to begin next spring after final design " ~
        "review.Residents who attended the meeting praised the decision, noting " ~
        "that the park has been a focal point for neighborhood gatherings for over " ~
        "three decades and was in need of significant repair.");

    expectSelected(root, "blog-post-shaped", 12, 1042,
        "Learning to Bake Sourdough at HomeSourdough bread relies on a naturally " ~
        "fermented starter rather than commercial yeast, which gives the finished " ~
        "loaf its distinctive tang and chewy crumb structure that many home bakers " ~
        "spend years perfecting.Feeding your starter consistently, at the same " ~
        "time each day, keeps the wild yeast and bacteria culture active and " ~
        "predictable, which in turn makes the dough's rise far easier to plan " ~
        "around a normal schedule.Once the dough has proofed, a hot Dutch oven " ~
        "traps steam during the first few minutes of baking, producing the " ~
        "crackling crust that distinguishes a good sourdough loaf from an " ~
        "ordinary sandwich bread.");

    expectSelected(root, "docs-page-shaped", 14, 709,
        "Getting StartedThis guide walks new users through installing the " ~
        "toolkit, configuring a first project, and running an initial build, " ~
        "and is the recommended starting point before consulting any individual " ~
        "reference section below.IntroductionThe toolkit ships as a single " ~
        "self-contained binary with no external runtime dependency, so most " ~
        "environments can begin using it immediately after downloading the " ~
        "appropriate release archive.SetupInstall the command line tool with " ~
        "your package manager of choice, then verify the installation by " ~
        "running the version command, which should print a matching release " ~
        "number back to the terminal.UsageRun the build command from the " ~
        "project root to produce output artifacts, and pass the watch flag " ~
        "during development to automatically rebuild whenever a source file " ~
        "on disk changes.");

    expectSelected(root, "forum-thread-shaped", 12, 719,
        "Best practices for organizing a home workshop?I've been slowly " ~
        "filling my garage with tools over the last few years and it's turned " ~
        "into a disaster. Does anyone have a system that actually works for " ~
        "keeping hand tools and power tools organized long term?Pegboard " ~
        "changed everything for me. I traced an outline around each tool so " ~
        "it's obvious immediately when something is missing or was put back " ~
        "in the wrong spot after a project finished last spring.Second the " ~
        "pegboard suggestion, and I'd add labeled bins for small hardware " ~
        "like screws and anchors, sorted by size rather than by project, " ~
        "since projects change but sizes generally don't.");

    // Adversarial cases: both abstention paths this contract requires.
    expectAbstained(root, "nav-heavy-near-empty", MainContentStatus.abstainedBelowThreshold);
    expectAbstained(root, "below-minimum-length", MainContentStatus.abstainedBelowThreshold);
    expectAbstained(root, "two-competing-articles", MainContentStatus.abstainedTie);

    // The two below-threshold cases are bound by different halves of the
    // "minimum-length/score" rule, not the same one twice.
    auto navHeavy = runFixture(root, "nav-heavy-near-empty");
    need(navHeavy.candidates[0].textLength >= 200 && navHeavy.candidates[0].score < 150.0,
        "nav-heavy case should fail on score with length already sufficient");
    auto tooShort = runFixture(root, "below-minimum-length");
    need(tooShort.candidates[0].score >= 150.0 && tooShort.candidates[0].textLength < 200,
        "below-minimum-length case should fail on length with score already sufficient");

    tableDriftProof();
    capProof();
    candidateBoundProof();

    writeln("html main content check: exact structure, abstention paths, " ~
        "determinism, table drift, output cap, candidate bound pass");
}
