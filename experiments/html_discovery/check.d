/// Release-active goldens and adversarial proof for the bounded HTML
/// link-discovery walker over synthetic `HtmlTree` fixtures.
module experiments.html_discovery.check;

import effects.html_discovery;
import effects.html_tree : HtmlAttribute, HtmlNode, HtmlNodeKind, HtmlTree;
import effects.web_url : AttributeKind, RelationKind, WebUrlFailureReason,
    WebUrlInput;
import std.conv : to;
import std.stdio : writeln;
import std.string : indexOf;

private size_t checks;

private void need(bool condition, string label) {
    ++checks;
    if (!condition) throw new Exception("html-discovery check failed: " ~ label);
}

private HtmlAttribute attr(string name, string value) pure {
    return HtmlAttribute(name, value);
}

private HtmlNode elem(size_t parent, string name, HtmlAttribute[] attrs = null) pure {
    return HtmlNode(HtmlNodeKind.element, parent, name, null, attrs);
}

private DiscoveryScopePolicy sameOriginPolicy() pure {
    DiscoveryScopePolicy policy;
    policy.kind = DiscoveryScopeKind.sameOrigin;
    return policy;
}

// ---------------------------------------------------------------------
// Goldens: href/src/srcset/canonical extraction against synthetic fixtures.
// ---------------------------------------------------------------------

private void checkGoldenTable() {
    HtmlTree tree;
    tree.nodes = [
        elem(size_t.max, "html"),
        elem(0, "head"),
        elem(1, "link", [attr("rel", "canonical"), attr("href", "/canonical")]),
        elem(1, "link", [attr("rel", "stylesheet"), attr("href", "/style.css")]),
        elem(0, "body"),
        elem(4, "a", [attr("href", "/next")]),
        elem(4, "img", [attr("src", "/hero.jpg")]),
        elem(4, "source", [attr("src", "/hero.webp")]),
        elem(4, "img", [attr("srcset", "/small.jpg 1x, /large.jpg 2x")]),
        elem(4, "source", [attr("srcset", "/small.webp 480w, /large.webp 960w")]),
        // Attribute the fixed v1 table must NOT match.
        elem(4, "div", [attr("href", "/ignored"), attr("data-src", "/ignored")]),
        elem(4, "script", [attr("src", "/ignored.js")]),
    ];
    auto outcome = discoverHtmlLinks(tree, "https://example.test/page", sameOriginPolicy);
    need(outcome.rejections.length == 0, "no rejections in golden table");
    need(!outcome.truncated, "golden table not truncated");

    string[] canonicals;
    foreach (candidate; outcome.candidates) canonicals ~= candidate.locator.canonical;
    need(canonicals == [
        "https://example.test/canonical",
        "https://example.test/style.css",
        "https://example.test/next",
        "https://example.test/hero.jpg",
        "https://example.test/hero.webp",
        "https://example.test/small.jpg",
        "https://example.test/large.jpg",
        "https://example.test/small.webp",
        "https://example.test/large.webp",
    ], "golden table canonical list, got " ~ canonicals.to!string);

    need(outcome.candidates[0].evidence.relation == RelationKind.hyperlink &&
        outcome.candidates[0].evidence.attribute == AttributeKind.href,
        "link[rel=canonical] relation/attribute");
    need(outcome.candidates[2].evidence.relation == RelationKind.hyperlink &&
        outcome.candidates[2].evidence.attribute == AttributeKind.href,
        "a[href] relation/attribute");
    foreach (candidate; outcome.candidates[3 .. $])
        need(candidate.evidence.relation == RelationKind.embeddedResource &&
            candidate.evidence.attribute == AttributeKind.src,
            "img/source src+srcset relation/attribute");

    // script[src] and div[href]/div[data-src] are not in the fixed v1 table.
    need(outcome.candidates.length == 9, "unmatched attributes are never discovered");
}

// ---------------------------------------------------------------------
// Link explosion: per-document cap truncates, never grows unbounded.
// ---------------------------------------------------------------------

private void checkLinkExplosion() {
    HtmlNode[] nodes = [elem(size_t.max, "html")];
    foreach (i; 0 .. 20_000)
        nodes ~= elem(0, "a", [attr("href", "/n" ~ i.to!string)]);
    HtmlTree tree;
    tree.nodes = nodes;

    auto outcome = discoverHtmlLinks(tree, "https://example.test/", sameOriginPolicy);
    need(outcome.truncated, "default cap truncates a 20k-link document");
    need(outcome.candidates.length == maxDiscoveredLinksPerDocument,
        "candidates stop exactly at the per-document cap");

    auto small = discoverHtmlLinks(tree, "https://example.test/", sameOriginPolicy, 7);
    need(small.truncated && small.candidates.length == 7,
        "caller-supplied maxLinks is honored");

    // One adversarial srcset attribute alone cannot exhaust the document
    // budget: it is bounded independently at maxSrcsetCandidatesPerAttribute.
    string huge;
    foreach (i; 0 .. 5_000) huge ~= "/s" ~ i.to!string ~ " " ~ i.to!string ~ "w, ";
    HtmlTree srcsetTree;
    srcsetTree.nodes = [elem(size_t.max, "img", [attr("srcset", huge)])];
    auto srcsetOutcome = discoverHtmlLinks(srcsetTree, "https://example.test/",
        sameOriginPolicy);
    need(srcsetOutcome.candidates.length == maxSrcsetCandidatesPerAttribute,
        "one srcset attribute is bounded independently of the document cap");
    need(!srcsetOutcome.truncated,
        "the per-attribute srcset bound does not itself report document truncation");
}

// ---------------------------------------------------------------------
// Cyclic reference graph within one document: the walker only extracts
// evidence, never follows a reference, so a document that (conceptually)
// forms a cycle across the crawl graph cannot make it choke or loop. The
// frontier's permanent-duplicate rejection owns cross-document dedup.
// ---------------------------------------------------------------------

private void checkCyclicReferenceGraph() {
    HtmlTree tree;
    tree.nodes = [
        elem(size_t.max, "html"),
        // Self-reference: this document links to its own response URL.
        elem(0, "a", [attr("href", "https://example.test/self")]),
        // Mutual reference pair, both present in this one document: A -> B
        // and B -> A. Neither node "follows" the other; both are simply
        // extracted as independent, undeduped candidates.
        elem(0, "a", [attr("href", "https://example.test/a")]),
        elem(0, "a", [attr("href", "https://example.test/b")]),
        // The exact same URL discovered many times over.
        elem(0, "a", [attr("href", "https://example.test/a")]),
        elem(0, "a", [attr("href", "https://example.test/a")]),
        elem(0, "a", [attr("href", "https://example.test/a")]),
    ];
    auto outcome = discoverHtmlLinks(tree, "https://example.test/self", sameOriginPolicy);
    need(outcome.candidates.length == 6, "every reference is extracted, undeduped");
    size_t selfCount;
    foreach (candidate; outcome.candidates)
        if (candidate.locator.canonical == "https://example.test/a") ++selfCount;
    need(selfCount == 4, "duplicate references are retained, not collapsed");
    need(!outcome.truncated, "a small cyclic fixture never truncates");
}

// ---------------------------------------------------------------------
// Calendar and query-permutation traps: this slice names no such
// heuristic, so both kinds of link are discovered as ordinary candidates,
// neither specially rejected nor collapsed.
// ---------------------------------------------------------------------

private void checkCalendarAndQueryPermutations() {
    HtmlNode[] nodes = [elem(size_t.max, "html")];
    foreach (year; 2020 .. 2026)
        foreach (month; 1 .. 13)
            nodes ~= elem(0, "a",
                [attr("href", "/events/" ~ year.to!string ~ "/" ~ month.to!string)]);
    HtmlTree calendar;
    calendar.nodes = nodes;
    auto calendarOutcome = discoverHtmlLinks(calendar, "https://example.test/",
        sameOriginPolicy);
    need(calendarOutcome.candidates.length == 72,
        "no calendar-permutation heuristic filters these in this slice");
    need(calendarOutcome.rejections.length == 0, "calendar links resolve cleanly");

    HtmlNode[] queryNodes = [elem(size_t.max, "html")];
    foreach (i; 0 .. 50)
        queryNodes ~= elem(0, "a",
            [attr("href", "/search?page=" ~ i.to!string ~ "&sort=asc&filter=x")]);
    HtmlTree query;
    query.nodes = queryNodes;
    auto queryOutcome = discoverHtmlLinks(query, "https://example.test/", sameOriginPolicy);
    need(queryOutcome.candidates.length == 50,
        "no query-permutation heuristic filters these in this slice");
    // Distinct query strings remain distinct canonical identities.
    bool[string] distinct;
    foreach (candidate; queryOutcome.candidates) distinct[candidate.locator.canonical] = true;
    need(distinct.length == 50, "query permutations are not collapsed by this walker");
}

// ---------------------------------------------------------------------
// Misleading <base> tags.
// ---------------------------------------------------------------------

private void checkBaseTags() {
    // Only the first base[href] in document order applies, even to a
    // later, unrelated relative reference.
    HtmlTree firstWins;
    firstWins.nodes = [
        elem(size_t.max, "html"),
        elem(0, "head"),
        elem(1, "base", [attr("href", "https://cdn.example.test/x/")]),
        elem(1, "base", [attr("href", "https://ignored.example.test/")]),
        elem(0, "body"),
        elem(4, "a", [attr("href", "y")]),
    ];
    DiscoveryScopePolicy allowCdn;
    allowCdn.kind = DiscoveryScopeKind.allowedDomain;
    allowCdn.allowedOrigins = ["https://cdn.example.test"];
    auto outcome = discoverHtmlLinks(firstWins, "https://example.test/page", allowCdn);
    need(outcome.candidates.length == 1 &&
        outcome.candidates[0].locator.canonical == "https://cdn.example.test/x/y",
        "only the first base[href] applies");

    // A base without an href attribute at all is skipped in favor of the
    // next base element that does carry one.
    HtmlTree hrefless;
    hrefless.nodes = [
        elem(size_t.max, "base"),
        elem(size_t.max, "base", [attr("href", "https://cdn.example.test/z/")]),
        elem(size_t.max, "a", [attr("href", "w")]),
    ];
    auto hreflessOutcome = discoverHtmlLinks(hrefless, "https://example.test/page", allowCdn);
    need(hreflessOutcome.candidates.length == 1 &&
        hreflessOutcome.candidates[0].locator.canonical == "https://cdn.example.test/z/w",
        "a base element without href is skipped, not treated as a present empty base");

    // An invalid base surfaces discoverWebUrl's own typed documentBase
    // failure for every affected attempt, rather than silently falling
    // back to "no base" -- this module reimplements none of that logic.
    HtmlTree invalidBase;
    invalidBase.nodes = [
        elem(size_t.max, "base", [attr("href", "not a url")]),
        elem(size_t.max, "a", [attr("href", "/x")]),
        elem(size_t.max, "a", [attr("href", "/y")]),
    ];
    auto invalidOutcome = discoverHtmlLinks(invalidBase, "https://example.test/page",
        sameOriginPolicy);
    need(invalidOutcome.candidates.length == 0, "invalid base blocks resolution");
    need(invalidOutcome.rejections.length == 2, "every affected attempt is rejected");
    foreach (rejection; invalidOutcome.rejections)
        need(rejection.input == WebUrlInput.documentBase,
            "typed failure names the documentBase input");
}

// ---------------------------------------------------------------------
// Unicode hosts and duplicate encodings.
// ---------------------------------------------------------------------

private void checkUnicodeAndDuplicateEncodings() {
    HtmlTree tree;
    tree.nodes = [
        elem(size_t.max, "a", [attr("href", "https://bücher.example/straße")]),
        // The same resource referenced through two different encodings of
        // the reference text; both are extracted as separate candidates,
        // neither collapsed nor treated as proof of content identity.
        elem(size_t.max, "a", [attr("href", "/a%2Fb?q=x%20y")]),
        elem(size_t.max, "a", [attr("href", "/a%2fb?q=x+y")]),
    ];
    DiscoveryScopePolicy allowUnicode;
    allowUnicode.kind = DiscoveryScopeKind.allowedDomain;
    allowUnicode.allowedOrigins = ["https://xn--bcher-kva.example"];
    auto outcome = discoverHtmlLinks(tree, "https://example.test/", allowUnicode);
    need(outcome.candidates.length == 1 &&
        outcome.candidates[0].locator.canonical ==
        "https://xn--bcher-kva.example/stra%C3%9Fe",
        "IDNA host canonicalization is exactly web_url's, not reimplemented here");
    need(outcome.outOfScopeCount == 2,
        "the two differently-encoded same-origin references stay out of the allow-list");

    auto sameOriginOutcome = discoverHtmlLinks(tree, "https://example.test/",
        sameOriginPolicy);
    need(sameOriginOutcome.candidates.length == 2, "both encodings resolve independently");
    need(sameOriginOutcome.candidates[0].locator.canonical !=
        sameOriginOutcome.candidates[1].locator.canonical,
        "differing percent/plus encodings are not normalized to one identity here");
}

// ---------------------------------------------------------------------
// Main-content independence: discovery sees the full tree, never a
// content-extraction result, so a subtree a boilerplate selector would
// reject still yields its link.
// ---------------------------------------------------------------------

private void checkMainContentIndependence() {
    HtmlTree tree;
    tree.nodes = [
        elem(size_t.max, "html"),
        elem(0, "body"),
        elem(1, "nav"),
        elem(2, "a", [attr("href", "/nav-link")]),
        elem(1, "main"),
        elem(4, "a", [attr("href", "/main-link")]),
        elem(1, "footer"),
        elem(6, "a", [attr("href", "/footer-link")]),
    ];
    auto outcome = discoverHtmlLinks(tree, "https://example.test/", sameOriginPolicy);
    string[] found;
    foreach (candidate; outcome.candidates) found ~= candidate.locator.canonical;
    need(found == [
        "https://example.test/nav-link",
        "https://example.test/main-link",
        "https://example.test/footer-link",
    ], "discovery walks the full tree independent of any main-content selection, got " ~
        found.to!string);
}

// ---------------------------------------------------------------------
// Scope policy variants.
// ---------------------------------------------------------------------

private void checkScopePolicies() {
    HtmlTree tree;
    tree.nodes = [elem(size_t.max, "a", [attr("href", "https://other.test/x")])];

    auto sameOrigin = discoverHtmlLinks(tree, "https://example.test/", sameOriginPolicy);
    need(sameOrigin.candidates.length == 0 && sameOrigin.outOfScopeCount == 1,
        "sameOrigin excludes a cross-origin candidate");

    DiscoveryScopePolicy allowed;
    allowed.kind = DiscoveryScopeKind.allowedDomain;
    allowed.allowedOrigins = ["https://other.test", "https://third.test"];
    auto admitted = discoverHtmlLinks(tree, "https://example.test/", allowed);
    need(admitted.candidates.length == 1 && admitted.outOfScopeCount == 0,
        "allowedDomain admits an exact configured origin");

    DiscoveryScopePolicy notAllowed;
    notAllowed.kind = DiscoveryScopeKind.allowedDomain;
    notAllowed.allowedOrigins = ["https://third.test"];
    auto rejected = discoverHtmlLinks(tree, "https://example.test/", notAllowed);
    need(rejected.candidates.length == 0 && rejected.outOfScopeCount == 1,
        "allowedDomain rejects an origin outside the exact allow-list");

    DiscoveryScopePolicy oneHop;
    oneHop.kind = DiscoveryScopeKind.oneHopExternal;
    auto external = discoverHtmlLinks(tree, "https://example.test/", oneHop);
    need(external.candidates.length == 1 && external.outOfScopeCount == 0,
        "oneHopExternal admits any destination origin");
}

// ---------------------------------------------------------------------
// Content-free diagnostics: rejections carry no raw URL/attribute text.
// ---------------------------------------------------------------------

private void checkContentFreeDiagnostics() {
    string secret = "mailto:leaked-secret-token@example.test";
    HtmlTree tree;
    tree.nodes = [elem(size_t.max, "a", [attr("href", secret)])];
    auto outcome = discoverHtmlLinks(tree, "https://example.test/", sameOriginPolicy);
    need(outcome.candidates.length == 0 && outcome.rejections.length == 1,
        "unsupported scheme is rejected");
    need(outcome.rejections[0].reason == WebUrlFailureReason.unsupportedScheme &&
        outcome.rejections[0].input == WebUrlInput.reference,
        "typed rejection reason/input");
    auto rendered = outcome.rejections[0].to!string;
    need(rendered.indexOf("leaked-secret-token") < 0,
        "rejection rendering never contains the raw reference text");
    need(rendered.indexOf("mailto") < 0,
        "rejection rendering never contains the raw scheme text");

    // Credentials in the response URL itself are also rejected without
    // leaking the credential text.
    HtmlTree credTree;
    credTree.nodes = [elem(size_t.max, "a", [attr("href", "/safe")])];
    auto credOutcome = discoverHtmlLinks(credTree,
        "https://user:hunter2@example.test/", sameOriginPolicy);
    need(credOutcome.candidates.length == 0 && credOutcome.rejections.length == 1 &&
        credOutcome.rejections[0].reason == WebUrlFailureReason.credentials,
        "credential-bearing response URL is rejected");
    need(credOutcome.rejections[0].to!string.indexOf("hunter2") < 0,
        "credential rejection never leaks the password");
}

void main() {
    checkGoldenTable();
    checkLinkExplosion();
    checkCyclicReferenceGraph();
    checkCalendarAndQueryPermutations();
    checkBaseTags();
    checkUnicodeAndDuplicateEncodings();
    checkMainContentIndependence();
    checkScopePolicies();
    checkContentFreeDiagnostics();
    writeln("html-discovery release checks passed: ", checks);
}
