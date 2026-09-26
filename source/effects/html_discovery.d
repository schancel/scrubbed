/// Bounded link-discovery walker over the restricted HTML tree boundary.
module effects.html_discovery;

import effects.html_tree : HtmlAttribute, HtmlNode, HtmlNodeKind, HtmlTree;
import effects.web_url : AttributeKind, DiscoveryCandidate, RelationKind,
    WebUrl, WebUrlFailure, discoverWebUrl;

/// Per-document cap on attempted link resolutions (accepted, rejected, or
/// out-of-scope). This is the first-slice link-explosion trap: once reached,
/// the walker stops scanning the tree and reports `truncated`. It does not
/// dedupe or detect cycles; the frontier's existing permanent-duplicate
/// rejection owns that property across documents.
enum size_t maxDiscoveredLinksPerDocument = 4096;

/// Per-attribute cap on `srcset` candidate-URL-plus-descriptor entries. One
/// adversarial `srcset` value cannot alone exhaust the per-document budget.
enum size_t maxSrcsetCandidatesPerAttribute = 64;

enum DiscoveryScopePolicyVersion : ubyte { v1 }

/// Exactly the three scope variants accepted for this slice. A same-site
/// (public-suffix-list-style) classifier is explicitly out of scope and is
/// deferred to a later slice; it is not partially implemented here.
enum DiscoveryScopeKind : ubyte { sameOrigin, allowedDomain, oneHopExternal }

/// Versioned scope policy. `allowedOrigins` is meaningful only for
/// `allowedDomain`: it is an exact-match allow-list of canonical origins
/// (scheme + host + effective port), never a bare-host or suffix comparison.
struct DiscoveryScopePolicy {
    DiscoveryScopePolicyVersion policyVersion = DiscoveryScopePolicyVersion.v1;
    DiscoveryScopeKind kind;
    const(string)[] allowedOrigins;
}

/// `sameOrigin` is exact scheme/host/port equality with the referring
/// document. `allowedDomain` is exact origin membership in the caller-
/// supplied allow-list; it does not parse hosts, strip subdomains, or
/// consult a public-suffix table. `oneHopExternal` admits any destination
/// origin: it marks that this walker intentionally does not restrict
/// destination scope for a single hop away from an already in-scope
/// document. Enforcing that no *further* hop is taken is a frontier-level
/// decision across documents, outside what a single-document walker can
/// determine.
bool htmlDiscoveryInScope(const DiscoveryScopePolicy policy,
        const WebUrl referrer, const WebUrl candidate) pure nothrow @safe {
    final switch (policy.kind) {
        case DiscoveryScopeKind.sameOrigin:
            return candidate.sameOrigin(referrer);
        case DiscoveryScopeKind.allowedDomain:
            foreach (origin; policy.allowedOrigins)
                if (candidate.origin == origin) return true;
            return false;
        case DiscoveryScopeKind.oneHopExternal:
            return true;
    }
}

/// Result of one document walk. `candidates` are resolved and in scope;
/// `rejections` are `effects.web_url`'s own typed, content-free failures
/// (never a raw URL/attribute value); `outOfScopeCount` counts resolved
/// candidates excluded by `policy`. `truncated` is set once
/// `maxDiscoveredLinksPerDocument` attempted resolutions have been reached.
struct HtmlDiscoveryOutcome {
    DiscoveryCandidate[] candidates;
    WebUrlFailure[] rejections;
    size_t outOfScopeCount;
    bool truncated;
}

private bool asciiWhitespace(char c) pure nothrow @safe {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f';
}

private struct SrcsetCandidate {
    string url;
    string descriptor;
}

/// Bounded `srcset` candidate-URL-plus-descriptor parse, kept local to this
/// module per the accepted contract. Tokenizes on ASCII whitespace/commas;
/// this is a pragmatic bounded parse, not full HTML `srcset` conformance
/// (for example it does not special-case a comma embedded inside an
/// unescaped URL). It never scans past `maxSrcsetCandidatesPerAttribute`
/// entries, bounding compute even for an adversarially long single value.
private SrcsetCandidate[] parseSrcset(string value) pure {
    SrcsetCandidate[] result;
    size_t at;
    while (at < value.length && result.length < maxSrcsetCandidatesPerAttribute) {
        while (at < value.length &&
            (asciiWhitespace(value[at]) || value[at] == ',')) ++at;
        if (at >= value.length) break;
        const urlStart = at;
        while (at < value.length && !asciiWhitespace(value[at])) ++at;
        auto url = value[urlStart .. at];
        if (url.length && url[$ - 1] == ',') url = url[0 .. $ - 1];
        while (at < value.length && asciiWhitespace(value[at])) ++at;
        const descStart = at;
        while (at < value.length && value[at] != ',') ++at;
        auto descriptor = value[descStart .. at];
        while (descriptor.length && asciiWhitespace(descriptor[$ - 1]))
            descriptor = descriptor[0 .. $ - 1];
        if (at < value.length && value[at] == ',') ++at;
        if (url.length) result ~= SrcsetCandidate(url, descriptor);
    }
    return result;
}

private string attributeValue(const ref HtmlNode node, string name) pure {
    foreach (attr; node.attributes) if (attr.name == name) return attr.value;
    return null;
}

private bool hasAttribute(const ref HtmlNode node, string name) pure {
    foreach (attr; node.attributes) if (attr.name == name) return true;
    return false;
}

/// Walk the full `tree` for link discovery. This takes the complete
/// `HtmlTree`, never a content-extraction result: main-content selection and
/// discovery stay fully independent, so a hypothetical boilerplate/
/// main-content rejection elsewhere never suppresses a discovered link here.
///
/// Matches exactly the fixed v1 table: `a[href]`, `link[href]` (including
/// `rel=canonical`, which needs no special case since every `link[href]` is
/// matched regardless of `rel`), `img[src]`, `source[src]`, and
/// `img[srcset]`/`source[srcset]`. Every accepted attribute value is handed
/// to `effects.web_url.discoverWebUrl`, which owns all malformed/unsupported-
/// scheme/credential-bearing rejection; this walker re-implements none of it.
///
/// `<base href>` is honored the same way a browser honors it: the first
/// element named `base` with an `href` attribute, in document order, sets
/// `documentBase` for every subsequent resolution. A misleading or invalid
/// `base` is not specially handled here either -- `discoverWebUrl` reports
/// its own typed `documentBase` failure for every attempted resolution when
/// that happens, which is the intended, honest outcome rather than a silent
/// fallback to "no base".
HtmlDiscoveryOutcome discoverHtmlLinks(const ref HtmlTree tree,
        string responseUrl, const DiscoveryScopePolicy policy,
        size_t maxLinks = maxDiscoveredLinksPerDocument) {
    HtmlDiscoveryOutcome result;
    if (tree.nodes.length == 0) return result;

    auto depths = new size_t[tree.nodes.length];
    string documentBase;
    bool hasDocumentBase;
    foreach (i, ref node; tree.nodes) {
        depths[i] = node.parentIndex == size_t.max ? 0 : depths[node.parentIndex] + 1;
        if (!hasDocumentBase && node.kind == HtmlNodeKind.element &&
                node.name == "base" && hasAttribute(node, "href")) {
            documentBase = attributeValue(node, "href");
            hasDocumentBase = true;
        }
    }

    bool budgetExceeded;
    void attempt(size_t nodeIndex, string reference, RelationKind relation,
            AttributeKind attributeKind) {
        if (budgetExceeded) return;
        const attempted = result.candidates.length + result.rejections.length +
            result.outOfScopeCount;
        if (attempted >= maxLinks) {
            budgetExceeded = true;
            result.truncated = true;
            return;
        }
        auto outcome = discoverWebUrl(responseUrl, reference, relation,
            nodeIndex, attributeKind, depths[nodeIndex],
            hasDocumentBase ? documentBase : null);
        if (!outcome.isDiscovered) {
            result.rejections ~= outcome.failure;
            return;
        }
        auto candidate = outcome.value;
        if (htmlDiscoveryInScope(policy, candidate.evidence.referrer,
                candidate.locator))
            result.candidates ~= candidate;
        else
            ++result.outOfScopeCount;
    }

    foreach (i, ref node; tree.nodes) {
        if (budgetExceeded) break;
        if (node.kind != HtmlNodeKind.element) continue;
        if (node.name == "a" || node.name == "link") {
            if (hasAttribute(node, "href"))
                attempt(i, attributeValue(node, "href"), RelationKind.hyperlink,
                    AttributeKind.href);
        } else if (node.name == "img" || node.name == "source") {
            if (hasAttribute(node, "src"))
                attempt(i, attributeValue(node, "src"),
                    RelationKind.embeddedResource, AttributeKind.src);
            if (!budgetExceeded && hasAttribute(node, "srcset")) {
                foreach (candidate; parseSrcset(attributeValue(node, "srcset"))) {
                    if (budgetExceeded) break;
                    attempt(i, candidate.url, RelationKind.embeddedResource,
                        AttributeKind.src);
                }
            }
        }
    }
    return result;
}

unittest {
    // a[href] and link[href] (including rel=canonical) are matched, with
    // depth and node ordinal taken from the flat pre-order tree.
    HtmlTree tree;
    tree.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "html", null, []),
        HtmlNode(HtmlNodeKind.element, 0, "head", null, []),
        HtmlNode(HtmlNodeKind.element, 1, "link", null,
            [HtmlAttribute("rel", "canonical"),
             HtmlAttribute("href", "/canonical")]),
        HtmlNode(HtmlNodeKind.element, 0, "body", null, []),
        HtmlNode(HtmlNodeKind.element, 3, "a", null,
            [HtmlAttribute("href", "/next")]),
    ];
    DiscoveryScopePolicy policy;
    policy.kind = DiscoveryScopeKind.sameOrigin;
    auto outcome = discoverHtmlLinks(tree, "https://example.test/page", policy);
    assert(outcome.candidates.length == 2);
    assert(outcome.rejections.length == 0);
    assert(!outcome.truncated);
    assert(outcome.candidates[0].locator.canonical == "https://example.test/canonical");
    assert(outcome.candidates[0].evidence.relation == RelationKind.hyperlink);
    assert(outcome.candidates[0].evidence.attribute == AttributeKind.href);
    assert(outcome.candidates[0].evidence.nodeOrdinal == 2);
    assert(outcome.candidates[0].evidence.depth == 2);
    assert(outcome.candidates[1].locator.canonical == "https://example.test/next");
    assert(outcome.candidates[1].evidence.nodeOrdinal == 4);
    assert(outcome.candidates[1].evidence.depth == 2);
}

unittest {
    // Main-content independence: a walk over the full tree still discovers
    // a link that lives in a subtree a hypothetical boilerplate/main-content
    // selector would have discarded (here, a "footer" element never
    // consulted by this module).
    HtmlTree tree;
    tree.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "html", null, []),
        HtmlNode(HtmlNodeKind.element, 0, "body", null, []),
        HtmlNode(HtmlNodeKind.element, 1, "footer", null, []),
        HtmlNode(HtmlNodeKind.element, 2, "a", null,
            [HtmlAttribute("href", "/boilerplate-link")]),
    ];
    DiscoveryScopePolicy policy;
    policy.kind = DiscoveryScopeKind.sameOrigin;
    auto outcome = discoverHtmlLinks(tree, "https://example.test/page", policy);
    assert(outcome.candidates.length == 1);
    assert(outcome.candidates[0].locator.canonical ==
        "https://example.test/boilerplate-link");
}

unittest {
    // srcset produces one candidate per bounded entry; descriptors are
    // parsed but do not affect discovery, and duplicate/cyclic references
    // within one document are neither deduped nor followed recursively.
    HtmlTree tree;
    tree.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "img", null,
            [HtmlAttribute("src", "/a.jpg"),
             HtmlAttribute("srcset",
                "/a.jpg 1x, /b.jpg 2x, /a.jpg 3x")]),
    ];
    DiscoveryScopePolicy policy;
    policy.kind = DiscoveryScopeKind.sameOrigin;
    auto outcome = discoverHtmlLinks(tree, "https://example.test/page", policy);
    assert(outcome.candidates.length == 4); // src + 3 srcset entries, undeduped
    foreach (candidate; outcome.candidates)
        assert(candidate.evidence.relation == RelationKind.embeddedResource &&
            candidate.evidence.attribute == AttributeKind.src);
}

unittest {
    // The per-document cap truncates rather than growing unbounded, and a
    // caller-supplied maxLinks is honored.
    HtmlNode[] nodes = [HtmlNode(HtmlNodeKind.element, size_t.max, "html", null, [])];
    foreach (i; 0 .. 20)
        nodes ~= HtmlNode(HtmlNodeKind.element, 0, "a", null,
            [HtmlAttribute("href", "/n")]);
    HtmlTree tree;
    tree.nodes = nodes;
    DiscoveryScopePolicy policy;
    policy.kind = DiscoveryScopeKind.sameOrigin;
    auto outcome = discoverHtmlLinks(tree, "https://example.test/page", policy, 5);
    assert(outcome.truncated);
    assert(outcome.candidates.length == 5);
}

unittest {
    // discoverWebUrl's typed rejection surfaces per attempt; no raw value
    // is retained (WebUrlFailure carries only typed enums).
    HtmlTree tree;
    tree.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "a", null,
            [HtmlAttribute("href", "mailto:user@example.test")]),
    ];
    DiscoveryScopePolicy policy;
    policy.kind = DiscoveryScopeKind.sameOrigin;
    auto outcome = discoverHtmlLinks(tree, "https://example.test/page", policy);
    assert(outcome.candidates.length == 0);
    assert(outcome.rejections.length == 1);
    import effects.web_url : WebUrlFailureReason, WebUrlInput;
    assert(outcome.rejections[0].reason == WebUrlFailureReason.unsupportedScheme);
    assert(outcome.rejections[0].input == WebUrlInput.reference);
}

unittest {
    // Scope policy variants: sameOrigin excludes a cross-origin candidate,
    // allowedDomain admits only an exact configured origin, and
    // oneHopExternal admits regardless of destination origin.
    HtmlTree tree;
    tree.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "a", null,
            [HtmlAttribute("href", "https://other.test/x")]),
    ];
    DiscoveryScopePolicy sameOrigin;
    sameOrigin.kind = DiscoveryScopeKind.sameOrigin;
    auto excluded = discoverHtmlLinks(tree, "https://example.test/", sameOrigin);
    assert(excluded.candidates.length == 0 && excluded.outOfScopeCount == 1);

    DiscoveryScopePolicy allowed;
    allowed.kind = DiscoveryScopeKind.allowedDomain;
    allowed.allowedOrigins = ["https://other.test"];
    auto admitted = discoverHtmlLinks(tree, "https://example.test/", allowed);
    assert(admitted.candidates.length == 1 && admitted.outOfScopeCount == 0);

    DiscoveryScopePolicy notAllowed;
    notAllowed.kind = DiscoveryScopeKind.allowedDomain;
    notAllowed.allowedOrigins = ["https://third.test"];
    auto rejected = discoverHtmlLinks(tree, "https://example.test/", notAllowed);
    assert(rejected.candidates.length == 0 && rejected.outOfScopeCount == 1);

    DiscoveryScopePolicy oneHop;
    oneHop.kind = DiscoveryScopeKind.oneHopExternal;
    auto external = discoverHtmlLinks(tree, "https://example.test/", oneHop);
    assert(external.candidates.length == 1 && external.outOfScopeCount == 0);
}

unittest {
    // A misleading <base>: only the first base[href] in document order is
    // honored, and it applies to a later, unrelated relative reference.
    HtmlTree tree;
    tree.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "html", null, []),
        HtmlNode(HtmlNodeKind.element, 0, "head", null, []),
        HtmlNode(HtmlNodeKind.element, 1, "base", null,
            [HtmlAttribute("href", "https://cdn.example.test/x/")]),
        HtmlNode(HtmlNodeKind.element, 1, "base", null,
            [HtmlAttribute("href", "https://ignored.example.test/")]),
        HtmlNode(HtmlNodeKind.element, 0, "body", null, []),
        HtmlNode(HtmlNodeKind.element, 4, "a", null,
            [HtmlAttribute("href", "y")]),
    ];
    DiscoveryScopePolicy policy;
    policy.kind = DiscoveryScopeKind.allowedDomain;
    policy.allowedOrigins = ["https://cdn.example.test"];
    auto outcome = discoverHtmlLinks(tree, "https://example.test/page", policy);
    assert(outcome.candidates.length == 1);
    assert(outcome.candidates[0].locator.canonical == "https://cdn.example.test/x/y");
}

unittest {
    // An invalid base is not silently ignored: discoverWebUrl's own typed
    // documentBase failure surfaces for the affected attempt, rather than
    // this module reimplementing a fallback.
    HtmlTree tree;
    tree.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "base", null,
            [HtmlAttribute("href", "not a url")]),
        HtmlNode(HtmlNodeKind.element, size_t.max, "a", null,
            [HtmlAttribute("href", "/x")]),
    ];
    DiscoveryScopePolicy policy;
    policy.kind = DiscoveryScopeKind.sameOrigin;
    auto outcome = discoverHtmlLinks(tree, "https://example.test/page", policy);
    assert(outcome.candidates.length == 0);
    assert(outcome.rejections.length == 1);
    import effects.web_url : WebUrlInput;
    assert(outcome.rejections[0].input == WebUrlInput.documentBase);
}

unittest {
    // Empty tree is handled without walking.
    HtmlTree tree;
    DiscoveryScopePolicy policy;
    auto outcome = discoverHtmlLinks(tree, "https://example.test/", policy);
    assert(outcome.candidates.length == 0 && !outcome.truncated);
}
