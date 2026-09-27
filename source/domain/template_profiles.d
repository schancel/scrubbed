/// Pure, in-process, frozen site/page-family template profiles: recurrence
/// plus role/position/text-density/link-density chrome-removal evidence for
/// refining an already-#26-selected main-content subtree. This is issue
/// #244's production-wiring slice: it ports
/// `experiments/template_profiles/evaluation.d`'s already-evaluated,
/// mutation-tested training/classification algorithm (grouping,
/// minimum-sample check, confidence/veto scoring, frozen SHA-256 identity)
/// off that experiment's flat TSV-fixture input onto a real bounded
/// tree-plus-node-index shape -- the same shape
/// `effects.html_main_content.MainContentResult` actually exposes (a
/// winning node index over an already-parsed tree, not per-child-block
/// structure): `classifyBlock` only ever classifies a direct child of a
/// subtree root the *caller* already selected; it never picks or reselects
/// that root itself.
///
/// `scripts/check_modules.d` enforces that `domain` modules stay
/// independent of every other project layer, including `effects` -- so this
/// module cannot literally take an `effects.html_tree.HtmlTree` parameter.
/// `BlockTree`/`BlockNode` below are a domain-owned mirror of that type's
/// exact flat pre-order shape (`kind`/`parentIndex`/`name`/`text`/
/// `attributes`), so a future (explicitly out-of-scope here) adapter in
/// `content`/`extraction` can map one onto the other field-for-field.
///
/// Thresholds (`minimumPages`, `recurrenceThreshold`, `removalScoreThreshold`)
/// and the grouping rule are reused verbatim from the evaluation -- owner
/// decision 2026-09-27 on issue #244, verified against `evaluation.d:16-18`
/// (declared) and `evaluation.d:275-297,371-375` (used at real,
/// mutation-tested call sites) -- not re-derived.
///
/// Deliberate, ticket-documented deviation from a literal "fall back to #26
/// single-page behavior" reading: a page or block outside the profile's
/// known training revisions, or backed by an insufficiently sampled family,
/// abstains (keeps everything) via the evaluation's own
/// `unseen-layout-revision`/`insufficient-family-samples` reason codes,
/// rather than a new recursive per-block fallback mechanism this ticket has
/// no evaluation evidence for. Every call here treats the classified page as
/// the evaluation treats a held-out page (the profile is always already
/// frozen by the time production classification runs), so the drift check
/// is unconditional rather than gated on a train/held-out split flag that
/// has no production analogue.
///
/// Explicitly deferred, not built here: profile persistence to disk (no
/// on-disk format exists to design against yet, and no real caller/corpus
/// does either) and stage/CLI wiring (`html_main_content.d`'s own selection
/// logic is untouched).
module domain.template_profiles;

import crypto.sha256 : sha256Of;
import std.algorithm : canFind, sort;
import std.array : Appender, appender;
import std.exception : enforce;

// ---------------------------------------------------------------------------
// Reused verbatim from `experiments/template_profiles/evaluation.d`.
// ---------------------------------------------------------------------------

/// This module's own algorithm-version tag (distinct string from the
/// evaluation's `"template-profile-eval:v1"`, `evaluation.d:15`, since this
/// is a different, ported implementation over a different input shape) --
/// still bound into every frozen `TemplateProfile.identity` below, exactly
/// as `evaluation.d:251` binds its own.
enum string algorithmVersion = "template-profile-domain:v1";

/// `evaluation.d:16`, used at `evaluation.d:275-276,371,390`.
enum size_t minimumPages = 3;
/// `evaluation.d:17`, used at `evaluation.d:287,292,295,375`.
enum double recurrenceThreshold = 0.66;
/// `evaluation.d:18`, used at `evaluation.d:296-297`.
enum int removalScoreThreshold = 3;

/// The evaluation's own versioned path-prefix family rule
/// (`evaluation.d:113-119`), reused verbatim per the owner decision's
/// "Grouping" section. Named identically to the literal the evaluation
/// itself freezes into its own identity (`evaluation.d:252`).
private enum string groupingRule = "explicit-origin+path-family:v1";

/// `evaluation.d:199-200` (`chromeScore`), reused verbatim.
private enum string[] chromeRoles = ["navigation", "banner", "cookie",
    "advertisement", "account", "recommendation", "contentinfo", "timestamp"];

/// `evaluation.d:193-194` (`preserveRole`), reused verbatim.
private enum string[] preservedRoles = ["article", "main", "table",
    "infobox", "citation", "caption", "code", "list"];

/// Defensive bound on one page's block tree, matching
/// `effects.html_tree.maxNodes` in spirit (this module cannot import that
/// constant -- see the module doc on domain/effects independence).
enum size_t maxBlockTreeNodes = 8192;

// ---------------------------------------------------------------------------
// Domain-owned tree/node shape. See the module doc for why this mirrors
// `effects.html_tree.HtmlTree`/`HtmlNode` field-for-field instead of
// importing them.
// ---------------------------------------------------------------------------

enum BlockNodeKind : ubyte { element, text }

struct BlockAttribute {
    string name;
    string value;
}

/// Mirrors `effects.html_tree.HtmlNode` exactly: flat pre-order, parent
/// index only, D-owned strings/arrays.
struct BlockNode {
    BlockNodeKind kind;
    size_t parentIndex = size_t.max;
    string name;
    string text;
    BlockAttribute[] attributes;
}

/// Mirrors `effects.html_tree.HtmlTree`'s node-array shape.
struct BlockTree {
    BlockNode[] nodes;
}

// ---------------------------------------------------------------------------
// Training input.
// ---------------------------------------------------------------------------

/// One saved page offered as training evidence for a `TemplateProfile`.
/// `tree`/`rootIndex` are that page's own already-#26-selected main-content
/// subtree (`rootIndex` is the node `effects.html_main_content.
/// extractMainContent` selected); `trainProfiles` only ever reads
/// `rootIndex`'s direct element children, exactly as `classifyBlock` later
/// does for a page being classified.
///
/// Only pages the caller actually passes here ever participate in training
/// -- there is no internal train/held-out split flag to get wrong, so a
/// held-out page structurally cannot leak into a profile's identity or
/// evidence. This is a stronger property than the evaluation's own runtime
/// `page.split == "train"` filter (`evaluation.d:215`), which this port
/// does not need to reproduce for that reason: the evaluation's own
/// held-out-leakage mutation control (poisoning held-out `digest`/
/// `revision` and checking the frozen identity is unchanged) has no
/// analogue to break here, because held-out data is never in scope to leak
/// from in the first place.
struct TrainingPage {
    string id;
    string origin;
    string path;
    string revision;
    string digest;
    BlockTree tree;
    size_t rootIndex;
}

// ---------------------------------------------------------------------------
// TemplateProfile: mirrors `evaluation.Profile`'s shape (`evaluation.d:86-97`).
// ---------------------------------------------------------------------------

struct TemplateProfile {
    string origin;
    string family;
    /// Frozen identity binding `algorithmVersion`, `groupingRule`, `origin`,
    /// `family`, the three reused thresholds, and a digest of every
    /// training page's id/revision/digest -- see `computeIdentity`. Stored
    /// as `ubyte[32]` (this codebase's established digest representation,
    /// e.g. `domain.topical_tags.TopicalTagsIdentity`) rather than the
    /// evaluation's own hex-string `Profile.identity`; the exact same
    /// SHA-256 bytes either way, just not hex-encoded.
    ubyte[32] identity;
    string[] trainingPages;
    bool[string] revisions;
    bool[string] paths;
    bool[string] digests;
    size_t[string] recurrence;
    size_t[string] textVariants;
    string[string] representativeText;
}

// ---------------------------------------------------------------------------
// Decision: mirrors `evaluation.Decision`'s shape (`evaluation.d:50-59`),
// minus the page/block identity fields (the caller already knows which
// tree/node it asked about).
// ---------------------------------------------------------------------------

struct BlockDecision {
    bool keep;
    bool abstained;
    int score;
    double recurrence = 0.0;
    double contentVariation = 0.0;
    string reason;
}

// ---------------------------------------------------------------------------
// Family/grouping (`evaluation.d:113-119`), reused verbatim. Public so a
// caller assembling `TrainingPage`s -- or selecting which already-trained
// `TemplateProfile` applies to an incoming page -- can compute the same
// grouping key this module uses internally.
// ---------------------------------------------------------------------------

string deriveFamily(string path) pure nothrow @nogc {
    if (path.length >= 7 && path[0 .. 7] == "/story/") return "article";
    if (path.length >= 8 && path[0 .. 8] == "/photos/") return "gallery";
    if (path.length >= 8 && path[0 .. 8] == "/guides/") return "guide";
    if (path.length >= 9 && path[0 .. 9] == "/reports/") return "report";
    return "";
}

private string familyKey(string origin, string family) pure {
    return origin ~ "|" ~ family;
}

// ---------------------------------------------------------------------------
// Structural signal extraction: the same six-part fingerprint
// (`evaluation.structuralSignature`, `evaluation.d:187-190`), derived from a
// real `BlockTree`/node index instead of a TSV `Block` row.
//
// An explicit `data-role`/`data-path`/`data-position`/`data-density`/
// `data-links` attribute on the node -- a real, already-parsed DOM
// attribute, exactly what `experiments/template_profiles`'s own fixtures
// carry, per that experiment's own README: "HTML data-* attributes expose
// the bounded DOM, semantic, position, text-density, and link-density
// observations that a future parser-backed implementation would have to
// derive" -- always wins. A small set of bounded structural defaults below
// covers uninstrumented real pages; each is chosen to be the
// *non*-removal-favoring default when a signal is genuinely unknown: role
// `""` matches neither the chrome-role nor the preservation set; density
// defaults `"high"` and links default `"low"`, neither of which adds to the
// removal score; position defaults `"center"`, the only value that does not
// count as an edge. Deriving accurate real-world role/position signals from
// arbitrary class names or CSS layout is a separate, un-evaluated problem
// this ticket has no evaluation evidence for -- these bounded fallbacks are
// deliberately conservative defaults, not a new evaluated heuristic
// standing in for the evaluation's own thresholds.
// ---------------------------------------------------------------------------

private string attributeValue(const ref BlockNode node, string name) pure {
    foreach (ref const attr; node.attributes) if (attr.name == name) return attr.value;
    return null;
}

private string defaultRoleFor(string tag) pure nothrow @nogc {
    switch (tag) {
        case "nav": return "navigation";
        case "header": return "banner";
        case "footer": return "contentinfo";
        case "main": return "main";
        case "article": return "article";
        case "table": return "table";
        case "figcaption": return "caption";
        case "pre": case "code": return "code";
        case "ul": case "ol": return "list";
        case "time": return "timestamp";
        default: return "";
    }
}

private string roleOf(const ref BlockTree tree, size_t index) pure {
    auto explicitRole = attributeValue(tree.nodes[index], "data-role");
    if (explicitRole.length) return explicitRole;
    auto ariaRole = attributeValue(tree.nodes[index], "role");
    if (ariaRole.length) return ariaRole;
    return defaultRoleFor(tree.nodes[index].name);
}

// Subtree end index: pre-order means every descendant of `index` is a
// contiguous run of higher indices, so a forward scan with an ancestor
// check finds where that run stops. Same idiom as
// `effects.html_main_content.endOf`, re-derived here (domain cannot import
// effects).
private size_t subtreeEnd(const ref BlockTree tree, size_t index) pure {
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

private string domPathOf(const ref BlockTree tree, size_t index) pure {
    auto explicitPath = attributeValue(tree.nodes[index], "data-path");
    if (explicitPath.length) return explicitPath;
    string[] chain;
    size_t at = index;
    size_t guard;
    while (true) {
        enforce(guard++ <= tree.nodes.length, "template profiles: malformed parent chain");
        chain = [tree.nodes[at].name] ~ chain;
        auto parent = tree.nodes[at].parentIndex;
        if (parent == size_t.max) break;
        at = parent;
    }
    string joined;
    foreach (i, name; chain) {
        if (i) joined ~= "/";
        joined ~= name;
    }
    return joined;
}

private struct DensitySignals {
    size_t ownText;
    size_t totalText;
    size_t linkText;
}

private DensitySignals densitySignalsOf(const ref BlockTree tree, size_t index) pure {
    DensitySignals signals;
    bool selfIsLink = tree.nodes[index].name == "a";
    foreach (i; index + 1 .. subtreeEnd(tree, index)) {
        if (tree.nodes[i].kind != BlockNodeKind.text) continue;
        auto length = tree.nodes[i].text.length;
        signals.totalText += length;
        if (tree.nodes[i].parentIndex == index) signals.ownText += length;
        bool underLink = selfIsLink;
        if (!underLink)
            for (size_t p = tree.nodes[i].parentIndex; p != size_t.max && p != index;
                    p = tree.nodes[p].parentIndex)
                if (tree.nodes[p].name == "a") { underLink = true; break; }
        if (underLink) signals.linkText += length;
    }
    return signals;
}

private enum double lowDensityMaxOwnRatio = 0.3;
private enum double highLinksMinRatio = 0.5;

private string densityOf(const ref BlockTree tree, size_t index) pure {
    auto explicitDensity = attributeValue(tree.nodes[index], "data-density");
    if (explicitDensity.length) return explicitDensity;
    auto signals = densitySignalsOf(tree, index);
    if (signals.totalText == 0) return "high"; // no text signal: don't favor removal
    return (cast(double) signals.ownText / cast(double) signals.totalText) < lowDensityMaxOwnRatio ?
        "low" : "high";
}

private string linksOf(const ref BlockTree tree, size_t index) pure {
    auto explicitLinks = attributeValue(tree.nodes[index], "data-links");
    if (explicitLinks.length) return explicitLinks;
    auto signals = densitySignalsOf(tree, index);
    if (signals.totalText == 0) return "low"; // no text signal: don't favor removal
    return (cast(double) signals.linkText / cast(double) signals.totalText) >= highLinksMinRatio ?
        "high" : "low";
}

private string positionOf(const ref BlockTree tree, size_t rootIndex, size_t childIndex) pure {
    auto explicitPosition = attributeValue(tree.nodes[childIndex], "data-position");
    if (explicitPosition.length) return explicitPosition;
    size_t[] siblings;
    foreach (i, ref node; tree.nodes)
        if (node.parentIndex == rootIndex && node.kind == BlockNodeKind.element) siblings ~= i;
    enforce(siblings.length, "template profiles: selected root has no element children");
    if (siblings[0] == childIndex) return "top";
    if (siblings[$ - 1] == childIndex) return "bottom";
    if (tree.nodes[childIndex].name == "aside") return "rail";
    return "center";
}

private string blockTextOf(const ref BlockTree tree, size_t index) pure {
    string text;
    foreach (i; index + 1 .. subtreeEnd(tree, index))
        if (tree.nodes[i].kind == BlockNodeKind.text) text ~= tree.nodes[i].text;
    return text;
}

private string structuralSignatureOf(string tag, string role, string domPath, string position,
        string density, string links) pure {
    return tag ~ "|" ~ role ~ "|" ~ domPath ~ "|" ~ position ~ "|" ~ density ~ "|" ~ links;
}

/// One block's derived structural fingerprint plus its text, exposed
/// publicly so a caller can inspect the exact evidence a decision was based
/// on (issue #244's "record bounded evidence for every profile-based
/// keep/remove decision" acceptance criterion).
struct BlockSignals {
    string tag;
    string role;
    string domPath;
    string position;
    string density;
    string links;
    string text;
    string signature;
}

/// Derives `BlockSignals` for `childIndex`, a direct element child of the
/// already-#26-selected `rootIndex`. Throws if `childIndex` is not actually
/// a direct child of `rootIndex` -- this is the enforcement point that
/// makes `classifyBlock` structurally incapable of reaching outside the
/// subtree the caller selected.
BlockSignals blockSignalsAt(const ref BlockTree tree, size_t rootIndex, size_t childIndex) pure {
    enforce(tree.nodes.length <= maxBlockTreeNodes, "template profiles: block tree too large");
    enforce(rootIndex < tree.nodes.length && childIndex < tree.nodes.length,
        "template profiles: node index out of range");
    enforce(tree.nodes[childIndex].parentIndex == rootIndex,
        "template profiles: block is not a direct child of the selected root");
    enforce(tree.nodes[childIndex].kind == BlockNodeKind.element,
        "template profiles: block must be an element node");
    BlockSignals signals;
    signals.tag = tree.nodes[childIndex].name;
    signals.role = roleOf(tree, childIndex);
    signals.domPath = domPathOf(tree, childIndex);
    signals.position = positionOf(tree, rootIndex, childIndex);
    signals.density = densityOf(tree, childIndex);
    signals.links = linksOf(tree, childIndex);
    signals.text = blockTextOf(tree, childIndex);
    signals.signature = structuralSignatureOf(signals.tag, signals.role, signals.domPath,
        signals.position, signals.density, signals.links);
    return signals;
}

/// All direct element children of `rootIndex`, in document order -- the
/// exact set `trainProfiles`/a caller walking a page for classification
/// should treat as candidate blocks.
size_t[] directElementChildren(const ref BlockTree tree, size_t rootIndex) pure {
    size_t[] children;
    foreach (i, ref node; tree.nodes)
        if (node.parentIndex == rootIndex && node.kind == BlockNodeKind.element) children ~= i;
    return children;
}

// ---------------------------------------------------------------------------
// Scoring: `evaluation.chromeScore`/`preserveRole` (`evaluation.d:192-208`),
// reused verbatim over derived `BlockSignals` instead of a `Block` row.
// ---------------------------------------------------------------------------

private int chromeScore(const ref BlockSignals signals) pure {
    int score;
    if (chromeRoles.canFind(signals.role)) score += 2;
    if (signals.position == "top" || signals.position == "bottom" || signals.position == "rail")
        ++score;
    if (signals.links == "high") ++score;
    if (signals.density == "low") ++score;
    return score;
}

private bool preserveRole(string role) pure {
    return preservedRoles.canFind(role);
}

private double ratio(size_t numerator, size_t denominator) pure {
    return denominator ? cast(double) numerator / cast(double) denominator : 1.0;
}

// ---------------------------------------------------------------------------
// Frozen identity: binds algorithm version, grouping rule, origin, family,
// the three reused thresholds, and a digest of every training page's
// id/revision/digest -- per the owner decision's "Profile
// persistence/freezing" section. Sorted training order (imposed by
// `trainProfiles` before this is called) makes the result independent of
// input order.
// ---------------------------------------------------------------------------

private void appendU32(ref Appender!(ubyte[]) bytes, uint value) pure {
    foreach_reverse (shift; [0, 8, 16, 24]) bytes.put(cast(ubyte) (value >> shift));
}

private void appendField(ref Appender!(ubyte[]) bytes, string value) pure {
    enforce(value.length <= uint.max, "template profiles: field too long");
    appendU32(bytes, cast(uint) value.length);
    bytes.put(cast(const(ubyte)[]) value);
}

private ubyte[32] computeIdentity(string origin, string family,
        const(TrainingPage)[] sortedTraining) pure {
    auto evidence = appender!(ubyte[]);
    foreach (page; sortedTraining) {
        appendField(evidence, page.id);
        appendField(evidence, page.revision);
        appendField(evidence, page.digest);
    }
    auto bytes = appender!(ubyte[]);
    bytes.put(cast(const(ubyte)[]) "scrubbed:template-profiles:identity:v1\0");
    appendField(bytes, algorithmVersion);
    appendField(bytes, groupingRule);
    appendField(bytes, origin);
    appendField(bytes, family);
    appendU32(bytes, cast(uint) minimumPages);
    appendU32(bytes, cast(uint) (recurrenceThreshold * 1_000_000));
    appendU32(bytes, cast(uint) removalScoreThreshold);
    bytes.put(sha256Of(evidence.data)[]);
    return sha256Of(bytes.data);
}

// ---------------------------------------------------------------------------
// Training: `evaluation.trainProfiles` (`evaluation.d:212-261`), reused
// verbatim for grouping/recurrence/text-variant bookkeeping, over derived
// `BlockSignals` from each page's own selected subtree instead of TSV
// `Block` rows.
// ---------------------------------------------------------------------------

/// Groups `pages` by `origin ~ "|" ~ deriveFamily(path)` and builds one
/// frozen `TemplateProfile` per group. A group below `minimumPages`, or with
/// fewer than `minimumPages` distinct paths or digests, still gets a
/// profile (matching `evaluation.d:275-276`'s own insufficiency check,
/// which is evaluated per-classification, not at training time) --
/// `classifyBlock` abstains against it via `insufficient-family-samples`.
TemplateProfile[] trainProfiles(const(TrainingPage)[] pages) pure {
    TrainingPage[][string] groups;
    foreach (page; pages) {
        enforce(page.id.length, "template profiles: page id required");
        enforce(page.tree.nodes.length <= maxBlockTreeNodes,
            "template profiles: block tree too large");
        auto family = deriveFamily(page.path);
        enforce(family.length, "template profiles: path does not match a known family prefix");
        groups[familyKey(page.origin, family)] ~= cast(TrainingPage) page;
    }
    string[] keys;
    foreach (key; groups.keys) keys ~= key;
    keys.sort;
    TemplateProfile[] profiles;
    foreach (key; keys) {
        auto training = groups[key].dup;
        training.sort!((a, b) => a.id < b.id);
        TemplateProfile profile;
        profile.origin = training[0].origin;
        profile.family = deriveFamily(training[0].path);
        bool[string] observedTexts;
        foreach (page; training) {
            profile.trainingPages ~= page.id;
            profile.revisions[page.revision] = true;
            profile.paths[page.path] = true;
            profile.digests[page.digest] = true;
            bool[string] seenOnThisPage;
            foreach (childIndex; directElementChildren(page.tree, page.rootIndex)) {
                auto signals = blockSignalsAt(page.tree, page.rootIndex, childIndex);
                if (signals.signature !in seenOnThisPage) {
                    ++profile.recurrence[signals.signature];
                    seenOnThisPage[signals.signature] = true;
                }
                if (signals.signature !in profile.representativeText)
                    profile.representativeText[signals.signature] = signals.text;
                auto textKey = signals.signature ~ "\x1f" ~ signals.text;
                if (textKey !in observedTexts) {
                    ++profile.textVariants[signals.signature];
                    observedTexts[textKey] = true;
                }
            }
        }
        profile.identity = computeIdentity(profile.origin, profile.family, training);
        profiles ~= profile;
    }
    return profiles;
}

// ---------------------------------------------------------------------------
// Classification: `evaluation.classify`/`classifyWithOptions`
// (`evaluation.d:270-310`, both options `true`, matching the evaluation's
// own real `classify()` entry point, not its ablation variants), reused
// verbatim over derived `BlockSignals`.
// ---------------------------------------------------------------------------

/// Classifies `childIndex`, a direct element child of the already-#26-
/// selected `rootIndex`, against `profile`. `pageRevision` is the
/// classified page's own layout revision, checked against
/// `profile.revisions` exactly as the evaluation checks a held-out page
/// (`evaluation.d:277-278`) -- every production call is, by construction,
/// classifying a page the profile was not trained on at this moment (the
/// profile is already frozen), so that check is unconditional here rather
/// than gated on a train/held-out split flag.
///
/// Abstention (`keep = true`, `abstained = true`) covers both of the
/// evaluation's own reason codes: `"insufficient-family-samples"` (profile
/// has fewer than `minimumPages` training pages, distinct paths, or
/// distinct digests) and `"unseen-layout-revision"` (page revision absent
/// from `profile.revisions`). A default-initialized `TemplateProfile.init`
/// (no profile trained yet for this origin/family) safely abstains via the
/// same `insufficient-family-samples` path.
BlockDecision classifyBlock(const ref TemplateProfile profile, const ref BlockTree tree,
        size_t rootIndex, size_t childIndex, string pageRevision) pure {
    auto signals = blockSignalsAt(tree, rootIndex, childIndex);
    bool insufficient = profile.trainingPages.length < minimumPages ||
        profile.paths.length < minimumPages || profile.digests.length < minimumPages;
    bool revisionKnown = (pageRevision in profile.revisions) !is null;
    bool drift = !insufficient && !revisionKnown;
    if (insufficient || drift)
        return BlockDecision(true, true, 0, 0.0, 0.0,
            insufficient ? "insufficient-family-samples" : "unseen-layout-revision");

    auto countPtr = signals.signature in profile.recurrence;
    auto recurrenceRatio = ratio(countPtr ? *countPtr : 0, profile.trainingPages.length);
    auto variantPtr = signals.signature in profile.textVariants;
    auto variationRatio = ratio(variantPtr ? *variantPtr : 0, profile.trainingPages.length);
    auto score = chromeScore(signals);
    if (variationRatio >= recurrenceThreshold && score > 0) --score;
    auto preserved = preserveRole(signals.role);
    auto remove = recurrenceRatio >= recurrenceThreshold && score >= removalScoreThreshold &&
        !preserved;
    auto lowConfidence = !preserved && score < removalScoreThreshold;
    return BlockDecision(!remove, lowConfidence, score, recurrenceRatio, variationRatio,
        preserved ? "semantic-preservation-veto" :
        remove ? "recurrence+chrome-evidence" :
        lowConfidence ? "low-removal-confidence" :
        "insufficient-structural-recurrence");
}

// ---------------------------------------------------------------------------
// Unit tests.
// ---------------------------------------------------------------------------

version (unittest) {
    private BlockNode elementWith(size_t parentIndex, string tag, string role, string position,
            string density, string links) pure {
        BlockAttribute[] attrs;
        if (role.length) attrs ~= BlockAttribute("data-role", role);
        if (position.length) attrs ~= BlockAttribute("data-position", position);
        if (density.length) attrs ~= BlockAttribute("data-density", density);
        if (links.length) attrs ~= BlockAttribute("data-links", links);
        return BlockNode(BlockNodeKind.element, parentIndex, tag, null, attrs);
    }

    // root(0) -> nav(1)/text(2), p(3)/text(4), footer(5)/text(6): a
    // three-block page shape reused by several tests below.
    private BlockTree threeBlockPage(string paragraphText) pure {
        BlockTree tree;
        tree.nodes ~= BlockNode(BlockNodeKind.element, size_t.max, "article", null, null); // 0
        tree.nodes ~= elementWith(0, "nav", "navigation", "top", "low", "high"); // 1
        tree.nodes ~= BlockNode(BlockNodeKind.text, 1, null, "Home About", null); // 2
        tree.nodes ~= elementWith(0, "p", "", "center", "high", "low"); // 3
        tree.nodes ~= BlockNode(BlockNodeKind.text, 3, null, paragraphText, null); // 4
        tree.nodes ~= elementWith(0, "footer", "contentinfo", "bottom", "low", "high"); // 5
        tree.nodes ~= BlockNode(BlockNodeKind.text, 5, null, "About Terms", null); // 6
        return tree;
    }

    private TrainingPage trainingPage(string id, string revision, string paragraphText) pure {
        return TrainingPage(id, "https://example.test", "/story/" ~ id, revision,
            "digest-" ~ id, threeBlockPage(paragraphText), 0);
    }
}

unittest {
    assert(deriveFamily("/story/alpha") == "article");
    assert(deriveFamily("/photos/alpha") == "gallery");
    assert(deriveFamily("/guides/alpha") == "guide");
    assert(deriveFamily("/reports/alpha") == "report");
    assert(deriveFamily("/other/alpha") == "");
}

unittest {
    // End-to-end: a recurring nav/footer (chrome, high score, recurs on
    // every training page) gets removed; a unique-text paragraph with no
    // chrome cues (score 0) is kept, but -- matching the evaluation's own
    // `check.d` assertion that every non-preserved score-under-3 decision
    // is explicitly abstained -- is marked `abstained`, not confidently
    // decided.
    auto pages = [
        trainingPage("t1", "v1", "Article body one"),
        trainingPage("t2", "v1", "Article body two"),
        trainingPage("t3", "v1", "Article body three"),
    ];
    auto profiles = trainProfiles(pages);
    assert(profiles.length == 1);
    auto profile = profiles[0];
    assert(profile.origin == "https://example.test" && profile.family == "article");
    assert(profile.trainingPages.length == 3);

    auto heldout = threeBlockPage("Article body four");
    auto navDecision = classifyBlock(profile, heldout, 0, 1, "v1");
    assert(!navDecision.keep && !navDecision.abstained &&
        navDecision.reason == "recurrence+chrome-evidence");
    auto footerDecision = classifyBlock(profile, heldout, 0, 5, "v1");
    assert(!footerDecision.keep && !footerDecision.abstained &&
        footerDecision.reason == "recurrence+chrome-evidence");
    auto pDecision = classifyBlock(profile, heldout, 0, 3, "v1");
    assert(pDecision.keep && pDecision.abstained &&
        pDecision.reason == "low-removal-confidence");
}

unittest {
    // Insufficient samples: one training page abstains everything.
    auto pages = [trainingPage("t1", "v1", "Only page")];
    auto profiles = trainProfiles(pages);
    assert(profiles.length == 1);
    auto heldout = threeBlockPage("Only heldout page");
    auto decision = classifyBlock(profiles[0], heldout, 0, 1, "v1");
    assert(decision.keep && decision.abstained &&
        decision.reason == "insufficient-family-samples");

    // A default-initialized profile (no profile trained for this
    // origin/family at all yet) abstains the same way.
    TemplateProfile none;
    auto noneDecision = classifyBlock(none, heldout, 0, 1, "v1");
    assert(noneDecision.keep && noneDecision.abstained &&
        noneDecision.reason == "insufficient-family-samples");
}

unittest {
    // Unseen layout revision: a sufficiently sampled profile, but the
    // classified page carries a revision that never appeared in training.
    auto pages = [
        trainingPage("t1", "v1", "one"), trainingPage("t2", "v1", "two"),
        trainingPage("t3", "v1", "three"),
    ];
    auto profiles = trainProfiles(pages);
    auto heldout = threeBlockPage("redesigned");
    auto decision = classifyBlock(profiles[0], heldout, 0, 1, "v2");
    assert(decision.keep && decision.abstained &&
        decision.reason == "unseen-layout-revision");
}

unittest {
    // Semantic-preservation veto: a recurring, high-scoring block whose
    // role is in the preserved set is kept, not removed, and reports the
    // veto explicitly rather than "low-removal-confidence".
    BlockTree page(string tableRole = "table") {
        BlockTree tree;
        tree.nodes ~= BlockNode(BlockNodeKind.element, size_t.max, "article", null, null);
        tree.nodes ~= elementWith(0, "table", tableRole, "rail", "low", "high"); // score 2+1+1+1=5
        tree.nodes ~= BlockNode(BlockNodeKind.text, 1, null, "Regional measurements", null);
        return tree;
    }
    TrainingPage[] pages;
    foreach (id; ["t1", "t2", "t3"])
        pages ~= TrainingPage(id, "https://example.test", "/story/" ~ id, "v1",
            "digest-" ~ id, page(), 0);
    auto profiles = trainProfiles(pages);
    auto heldout = page();
    auto decision = classifyBlock(profiles[0], heldout, 0, 1, "v1");
    assert(decision.keep && !decision.abstained &&
        decision.reason == "semantic-preservation-veto");
}

unittest {
    // Order independence: reversing training page order does not change
    // the frozen identity (mirrors `check.d`'s own reversed-input mutation
    // control, `check.d:114-121`).
    auto pages = [
        trainingPage("t1", "v1", "one"), trainingPage("t2", "v1", "two"),
        trainingPage("t3", "v1", "three"),
    ];
    auto forward = trainProfiles(pages).dup;
    auto reversed = trainProfiles([pages[2], pages[0], pages[1]]).dup;
    assert(forward.length == reversed.length);
    assert(forward[0].identity == reversed[0].identity);
    assert(forward[0].trainingPages == reversed[0].trainingPages);
}

unittest {
    // Synthetic integration proof: classifyBlock only ever prunes children
    // of an already-#26-selected root; it cannot re-select a different node
    // or wander outside that subtree. `winner` (index 0) stands in for
    // `effects.html_main_content.extractMainContent`'s own winning node;
    // `decoy` (index 3) stands in for a *different*, non-selected candidate
    // subtree #26 considered and rejected -- classifyBlock must never be
    // able to reach into it from the winner's root.
    BlockTree tree;
    tree.nodes = [
        BlockNode(BlockNodeKind.element, size_t.max, "article", null, null), // 0: #26 winner
        elementWith(0, "nav", "navigation", "top", "low", "high"),           // 1: winner's child
        BlockNode(BlockNodeKind.element, size_t.max, "aside", null, null),   // 2: decoy root
        elementWith(2, "aside", "advertisement", "rail", "low", "high"),     // 3: decoy's child
    ];
    TemplateProfile profile; // insufficient by construction: a safe, inert stand-in

    // Classifying an actual child of the selected root succeeds.
    auto navDecision = classifyBlock(profile, tree, 0, 1, "v1");
    assert(navDecision.abstained && navDecision.reason == "insufficient-family-samples");

    import std.exception : assertThrown;

    // Node 2 (the decoy root) and node 3 (the decoy's own child) are not
    // children of the winner (root 0): classifyBlock refuses to reach into
    // them rather than silently reinterpreting them as if #26 had selected
    // that subtree.
    assertThrown(classifyBlock(profile, tree, 0, 2, "v1"));
    assertThrown(classifyBlock(profile, tree, 0, 3, "v1"));

    // The winning root is entirely caller-supplied, never rediscovered:
    // classifyBlock against the decoy as its own, explicitly-passed root
    // only ever prunes the decoy's own children, and never reaches back
    // into the real winner's subtree either way.
    auto decoyChildDecision = classifyBlock(profile, tree, 2, 3, "v1");
    assert(decoyChildDecision.abstained); // still just an insufficient-sample abstention
    assertThrown(classifyBlock(profile, tree, 2, 1, "v1")); // node 1 is not root 2's child
}
