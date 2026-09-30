/// Deterministic main-content-vs-boilerplate selection over the selected HTML tree.
module effects.html_main_content;

import effects.html_tree : HtmlAttribute, HtmlNode, HtmlNodeKind, HtmlTree;
import std.json : JSONOptions, JSONType, JSONValue, parseJSON;
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

// Issue #411 (www-homify-de.html): real content can live entirely inside a
// `<script type="application/ld+json">` schema.org block (JSON, not DOM
// text/element structure) rather than anywhere the candidate-scoring pass
// above can see it -- a React SSR page can render a component's real body
// only as JSON props/JSON-LD, with the *visible* DOM containing nothing but
// chrome (nav, an app-install banner, locale pickers). Real trafilatura
// 2.2.0 recovers exactly this page's content the same way (its own
// `baseline.py` walks the identical `<script type="application/ld+json">`
// schema.org `articleBody`/`step`/etc. properties as a fallback strategy
// when its own DOM-based extraction doesn't win) -- confirmed by running it
// directly against this repo's own copy of the page, not assumed. This is
// therefore a different content *source*, not a scoring-weight/threshold
// miscalibration in the candidate pass above, which is why it is a
// dedicated fallback path invoked only once that pass has already
// abstained, rather than a change to any candidate's score.
private enum string structuredDataScriptType = "application/ld+json";
// Aggregate ld+json bytes scanned per document, mirroring
// `topical_tags_extract_stage.d`'s own already-accepted bound for the
// identical "scan every ld+json script on the page" operation (this module
// may not import that one directly -- see `scripts/check_modules.d`'s
// effects-layer rule -- so the bound is restated here, not shared).
private enum size_t maxStructuredDataAggregateBytes = 128 * 1024;
private enum int maxStructuredDataParseDepth = 32;

// schema.org properties that carry real page body text, restricted to the
// same fixed set a real, independently-shipped tool (trafilatura 2.2.0's
// `baseline.py`) already validates against real pages: `articleBody`/
// `reviewBody` are direct content properties; `step`/`recipeInstructions`
// share the exact same shape (a string, or a list of strings/objects each
// carrying `text`, optionally one level down inside `itemListElement` --
// the schema.org HowTo shape www-homify-de.html itself uses); FAQPage's
// `acceptedAnswer.text` is handled separately below. Deliberately not
// gated on the JSON-LD block's own `@type`: a property literally named
// `articleBody`/`step`/`acceptedAnswer` inside a `application/ld+json`
// block is schema.org markup by construction, so checking the property
// name directly is simpler than -- and just as safe as -- an `@type`
// pre-filter.
private immutable string[] structuredDataTextKeys = ["articleBody", "reviewBody"];
private immutable string[] structuredDataStepKeys = ["step", "recipeInstructions"];

private struct NamedCharacterReference { string name; dchar value; }

// Deliberately narrow, evidence-grounded HTML character-reference decoder,
// local to this module: `effects.html_main_content` may not import
// `filters.entities` (`scripts/check_modules.d`'s effects-layer rule), and
// copying its full WHATWG-entities table here would be a large,
// unjustified duplication for one fallback path. Handles the numeric form
// (`&#NNN;`/`&#xHH;`) plus a small fixed set of named references: the one
// verified present in this repo's own corpus (grep-confirmed: only
// `&nbsp;` appears anywhere in www-homify-de.html's real ld+json text) and
// the handful (`amp`/`lt`/`gt`/`quot`/`apos`) any HTML-escaped snippet is
// overwhelmingly likely to carry. An unrecognized named reference is left
// as literal text rather than guessed at.
private immutable NamedCharacterReference[] structuredDataNamedReferences = [
    NamedCharacterReference("amp;", '&'),
    NamedCharacterReference("lt;", '<'),
    NamedCharacterReference("gt;", '>'),
    NamedCharacterReference("quot;", '"'),
    NamedCharacterReference("apos;", '\''),
    NamedCharacterReference("nbsp;", ' '),
];

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

// Issue #475: comment-section identification, distinct from the
// content-vs-boilerplate tables above. `"comment"` already discounts a
// matching node's own score/text via `negativeKeywords` above (so a comment
// section was already excluded from ever winning or leaking into main
// content before this ticket), but that only ever gave it a *penalty*, not
// an *identity* -- discarded exactly like an ad or a share widget, with no
// way to tell "this page has comments and here they are" from "this page
// has boilerplate we dropped". This table instead marks the *root* of a
// comment-section subtree for separate extraction (`collectComments`).
//
// Grounded in a real survey of this repo's own 20-page held-out corpus
// (`examples/pipeline-benchmark/corpus/`, the same corpus #411's own 20/20
// check uses), not guessed:
//   - `archiv-krimiblog-de.html`: `<div id="comments">` wrapping
//     `<div class="commentEntry"><div class="commentContent" id="comment-2310">`.
//   - `kleinegruenemonster-wordpress-com.html`: `<div id="comments">`
//     wrapping `<div id="comment-75">`, plus `<div id="respond"
//     class="comment-respond">` for the (empty, no real reply text) reply
//     form -- a real "no false positive on empty comment UI" case.
//   - `scienceblogs-de.html`: `<div id="comments">` wrapping 140 real
//     `<div id="comment-NNNNNN" class="comment ... thread-... depth-1
//     reply">` entries -- the single largest real comment thread in this
//     corpus.
//   - `france-attac-org.html`: `<div class="comments">` containing only two
//     bare `<a id="comments">`/`<a id="forum">` fragment-link anchors, no
//     comment text at all -- a real "structurally comment-shaped but empty"
//     page, distinct from a genuinely comment-free one.
// `"comment"` alone covers every real pattern observed above (it is a
// substring of "comments", "commentEntry", "commentContent", "comment-75",
// "comment-respond", "comment-NNNNNN", etc.). `"disqus"` is not present
// anywhere in this corpus -- it is added because the issue's own acceptance
// criteria explicitly name Disqus embeds (`<div id="disqus_thread">` is
// Disqus's own standard, widely documented embed-container id) as a pattern
// to detect, and because it is one of the most common third-party comment
// widgets on the web generally; this one entry is issue-instructed, not
// corpus-observed, and is disclosed as such rather than silently presented
// as corpus-grounded like the rest of this table.
immutable string[] commentSectionKeywords = ["comment", "disqus"];

// Trafilatura's own comment-detection XPath rules (`htmlprocessing.py`) are
// likewise restricted to `div`/`section`/`list`-shaped containers, not every
// tag -- matching that restriction here (rather than matching any element
// with a "comment"-ish class/id) is what keeps `<i class="fa fa-comments">`
// (a comment-*count* icon glyph, real corpus page `www-tofugu-com.html`) and
// `<a id="comments">` (a bare fragment-link anchor with no body,
// `france-attac-org.html` above) from being misidentified as comment
// *sections*: neither `i` nor `a` is a block container a real discussion
// thread would be built from.
private immutable string[] commentSectionRootTags = ["div", "section", "aside", "ol", "ul"];

// Issue #479: a configurable precision/recall extraction mode, analogous to
// trafilatura's own `--precision`/`--recall` CLI flags ("less noise, more
// precision" vs "more text, more recall"). Named `standard`/`precision`/
// `recall` -- matching trafilatura's own naming rather than inventing new
// terms, since the whole point is a like-for-like tuning knob a caller
// already familiar with trafilatura's own flags will recognize. `standard`
// is the pre-existing, still-default behavior: every constant/code path it
// exercises is byte-for-byte identical to this module's behavior before this
// ticket (issue #479's own explicit non-regression requirement -- #411's
// 20/20 corpus result must be unaffected at the default mode). `precision`
// and `recall` are each a REAL, coordinated, two-axis preset -- not a single
// raw exposed float with no guidance -- documented in `selectionThresholdsFor`
// and `excludedFromText`'s own doc comments below:
//   1. The final selection floor (`minSelectableTextBytes`/`minSelectableScore`)
//      is scaled: `precision` raises it (abstain rather than guess on a
//      borderline top candidate); `recall` lowers it (accept a weaker
//      top-candidate signal rather than abstain).
//   2. The boilerplate-exclusion "sandwich rule" issue #27 added during text
//      collection (`excludedFromText`) is tightened for `precision` (either
//      neighbor being negative-keyword-classed is enough to exclude a
//      keyword-neutral node, not both) and disabled for `recall` (a
//      keyword-neutral node is never excluded by adjacency alone, only an
//      outright negative keyword match on the node itself still excludes
//      it) -- more text kept inside the winning subtree, some of it noisier.
// See `docs/html-main-content.md`'s own "Configurable precision/recall
// extraction mode" section for the real corpus pages this was verified
// against and the real pinned trafilatura==2.2.0 comparison.
enum ExtractionMode {
    standard,
    precision,
    recall,
}

// Issue #479's own real evidence (`docs/html-main-content.md`): raising the
// floor by 1.5x is what flips `france-attac-org.html`'s real selected lede
// (score 510, text 210 bytes -- just 10 bytes over the *standard* 200-byte
// floor) into an explicit `precision`-mode abstention (300-byte floor), while
// lowering it by 0.5x never turns an already-passing real candidate on this
// corpus into a failure (loosening a floor can only ever let more
// candidates through, never fewer) -- `recall`'s own multiplier is chosen to
// be a real, symmetric "half as strict" counterpart to `precision`'s "1.5x
// stricter", not independently tuned.
private enum double precisionThresholdMultiplier = 1.5;
private enum double recallThresholdMultiplier = 0.5;

private struct SelectionThresholds { size_t minTextBytes; double minScore; }

// The first of `ExtractionMode`'s two coordinated preset axes: scales both
// halves of the existing "explicit abstention over best-effort guess" floor
// (see `extractMainContent`'s own doc comment) by a fixed, named multiplier.
// `standard` returns the exact pre-existing constants unchanged -- the
// non-regression requirement this ticket's default mode must meet.
private SelectionThresholds selectionThresholdsFor(ExtractionMode mode) pure nothrow @nogc {
    final switch (mode) {
    case ExtractionMode.standard:
        return SelectionThresholds(minSelectableTextBytes, minSelectableScore);
    case ExtractionMode.precision:
        return SelectionThresholds(
            cast(size_t) (minSelectableTextBytes * precisionThresholdMultiplier),
            minSelectableScore * precisionThresholdMultiplier);
    case ExtractionMode.recall:
        return SelectionThresholds(
            cast(size_t) (minSelectableTextBytes * recallThresholdMultiplier),
            minSelectableScore * recallThresholdMultiplier);
    }
}

enum MainContentStatus {
    selected,
    // Issue #411: the DOM candidate-scoring pass below abstained (any of the
    // three reasons below), but a `<script type="application/ld+json">`
    // schema.org block on the same page carried enough real content-bearing
    // text (`articleBody`/`reviewBody`/HowTo `step`/FAQ `acceptedAnswer`) to
    // clear the same `minSelectableTextBytes` floor an ordinary DOM
    // candidate must clear. `.node` stays `size_t.max` and `.score` stays
    // `0.0`: this text has no corresponding tree node/score, it was
    // synthesized from JSON, not selected from a subtree. See
    // `structuredDataFallbackText`'s doc comment for the real page
    // (www-homify-de.html) and real external-tool (trafilatura 2.2.0)
    // evidence this generalizes from, not just a single-page special case.
    selectedStructuredData,
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

    // Issue #475: comment-section identification, distinct from `.text`.
    // `commentsExtracted` is the identity signal the issue's own summary
    // asks for ("no separate identity" today) -- it is `true` whenever at
    // least one comment-section root was found, even when the recovered
    // text is empty (a real corpus page, `france-attac-org.html`, has a
    // `<div class="comments">` wrapping only bare fragment-link anchors with
    // no text at all: structurally comment-shaped, but nothing to read --
    // `commentsExtracted` is `true` and `.comments` is empty, which is a
    // different, more honest fact than a page that has no comment markup at
    // all, where `commentsExtracted` stays `false`). Always `false` and
    // `.comments` always empty when `extractMainContent` is called with
    // `includeComments = false`: comments are not merely filtered from the
    // output in that mode, they are never scanned for at all, mirroring
    // trafilatura's own `--no-comments` (comments suppressed, not computed
    // and discarded). Independent of `.status`/`.text`/`.node`: comment
    // sections are scanned across the whole document regardless of whether
    // the ordinary DOM candidate pass selects, abstains, or is rescued by
    // the structured-data fallback -- a real page can have a comment
    // section next to an article the candidate pass fails to find, or vice
    // versa.
    bool commentsExtracted;
    string comments;
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
//
// Issue #517: widened with `ul`/`ol`/`pre` (html_markdown.d's renderNode
// already opens a block around each of those) and with the HTML5
// sectioning/landmark containers in `sectioningBlockTag` below. Without
// them, text on either side of a `<section>`/`<nav>`/`<ul>` boundary was
// glued into one run ("...foo.Home About").
private bool blockTag(string name) pure nothrow @nogc {
    bool heading = name.length == 2 && name[0] == 'h' &&
        name[1] >= '1' && name[1] <= '6';
    return heading || name == "p" || name == "div" || name == "li" ||
        name == "table" || name == "blockquote" || name == "ul" ||
        name == "ol" || name == "pre" || sectioningBlockTag(name);
}

/// Issue #517: the HTML5 sectioning/landmark containers. They are block
/// boundaries for `.text` (`blockTag`), but html_markdown.d's renderNode
/// gives them no block separation of its own and otherwise treats them
/// exactly like `div` (it never names any of them). So
/// `effects.html_main_content_markdown` renames them to `div` in its own
/// copy of the selected subtree before rendering, which gives the Markdown
/// path the same boundaries as the text path.
bool sectioningBlockTag(string name) pure nothrow @nogc {
    return name == "article" || name == "aside" || name == "footer" ||
        name == "header" || name == "main" || name == "nav" || name == "section";
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

private bool isAsciiAlnum(char c) pure nothrow @nogc {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
}

// Issue #538: `keywordScoreFor`'s own case-insensitive match, but
// word-boundary-aware rather than an unanchored substring match. A candidate
// occurrence at `haystack[i .. i + needle.length]` only counts when it is
// not immediately preceded or followed by another ASCII alphanumeric
// character (or is at the string's own edge there) -- the usual class/id
// tokenization idea (split on non-alphanumeric delimiters, compare whole
// tokens), restated as a boundary check on each candidate match instead of
// pre-splitting the haystack, so a multi-token keyword like
// "registration-banner" (itself containing a `-` delimiter) still matches as
// one unit without needing sequence-of-tokens matching. Fixes the real
// false positive this ticket reports: `class="wp-block-heading"` contains
// "ad" as a substring of "heading" ("he-AD-ing"), but "ad" there is
// preceded by an alphanumeric 'e', so it is correctly rejected, while
// `class="ad-banner"` (preceded by nothing, followed by the non-alphanumeric
// '-') still matches. Same real-corpus false positives independently
// checked against the pinned benchmark page `utopia-de.html`: "headline",
// "loaded", "shadow", "download", "gradient" each contain "ad" only with an
// alphanumeric neighbor and must not be excluded either.
private bool containsKeywordWord(string haystack, string needle) pure nothrow @nogc {
    if (needle.length == 0) return true;
    if (needle.length > haystack.length) return false;
    outer: for (size_t i; i + needle.length <= haystack.length; ++i) {
        foreach (j, nc; needle) if (!asciiFoldEq(haystack[i + j], nc)) continue outer;
        bool precededByAlnum = i > 0 && isAsciiAlnum(haystack[i - 1]);
        bool followedByAlnum = i + needle.length < haystack.length &&
            isAsciiAlnum(haystack[i + needle.length]);
        if (!precededByAlnum && !followedByAlnum) return true;
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
        if ((classValue.length && containsKeywordWord(classValue, kw)) ||
            (idValue.length && containsKeywordWord(idValue, kw)))
            total += keywordWeightUnit;
    foreach (kw; negativeKeywords)
        if ((classValue.length && containsKeywordWord(classValue, kw)) ||
            (idValue.length && containsKeywordWord(idValue, kw)))
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

private int hexDigitValue(char c) pure nothrow @nogc {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

private int decDigitValue(char c) pure nothrow @nogc {
    return (c >= '0' && c <= '9') ? c - '0' : -1;
}

// See `structuredDataNamedReferences`'s doc comment for the deliberately
// narrow scope. Byte-wise scan for `&`/digits/`;`: safe against multi-byte
// UTF-8 the same way `topical_tags_extract_stage.d`'s own byte-wise
// `splitKeywordList` already documents -- continuation bytes are always
// >= 0x80, so none of these ASCII delimiters can ever match one.
private string decodeStructuredDataEntities(string text) pure {
    char[] result;
    bool copied;
    size_t i;
    while (i < text.length) {
        if (text[i] != '&') {
            if (copied) result ~= text[i];
            ++i;
            continue;
        }
        size_t cursor = i + 1;
        dchar codepoint;
        bool matched;
        if (cursor < text.length && text[cursor] == '#') {
            size_t digitsStart = cursor + 1;
            bool hex;
            if (digitsStart < text.length && (text[digitsStart] == 'x' || text[digitsStart] == 'X')) {
                hex = true;
                ++digitsStart;
            }
            size_t d = digitsStart;
            ulong value;
            while (d < text.length) {
                int dv = hex ? hexDigitValue(text[d]) : decDigitValue(text[d]);
                if (dv < 0) break;
                if (value <= 0x10FFFF) value = value * (hex ? 16 : 10) + dv;
                ++d;
            }
            if (d > digitsStart) {
                cursor = d;
                if (cursor < text.length && text[cursor] == ';') ++cursor;
                if (value > 0 && value <= 0x10FFFF && !(value >= 0xD800 && value <= 0xDFFF)) {
                    codepoint = cast(dchar) value;
                    matched = true;
                }
            }
        } else {
            foreach (reference; structuredDataNamedReferences) {
                if (cursor + reference.name.length <= text.length &&
                        text[cursor .. cursor + reference.name.length] == reference.name) {
                    codepoint = reference.value;
                    cursor += reference.name.length;
                    matched = true;
                    break;
                }
            }
        }
        if (!matched) {
            if (!copied) { result = text[0 .. i].dup; copied = true; }
            result ~= text[i];
            ++i;
            continue;
        }
        if (!copied) { result = text[0 .. i].dup; copied = true; }
        char[4] encoded;
        result ~= encoded[0 .. encode(encoded, codepoint)];
        i = cursor;
    }
    return copied ? cast(string) result : text;
}

// Case-insensitive "does `raw[start ..]` begin with the tag name `name`,
// followed by a non-name character (or end of string)" check -- so `name ==
// "script"` matches "<script>"/"<SCRIPT "/"<Script/>" but not "<scripted>".
// `nothrow @nogc`: only byte comparisons, no allocation.
private bool tagNameAt(string raw, size_t start, string name) pure nothrow @nogc {
    if (start + name.length > raw.length) return false;
    foreach (k, expected; name) {
        char actual = raw[start + k];
        if (actual >= 'A' && actual <= 'Z') actual = cast(char) (actual + 32);
        if (actual != expected) return false;
    }
    size_t after = start + name.length;
    if (after >= raw.length) return true;
    char next = raw[after];
    return !((next >= 'a' && next <= 'z') || (next >= 'A' && next <= 'Z') ||
        (next >= '0' && next <= '9') || next == '-' || next == '_');
}

// Issue #484: mirrors `hiddenTag`'s DOM-path exclusion of `<script>`/
// `<style>` *descendants*, not just their own tags, for this JSON-LD
// fallback's naive tag-stripper -- without this, a `<script>`/`<style>`
// element embedded inside a recovered JSON-LD string value has its tags
// removed by the ordinary per-tag stripping below but its non-visible text
// content left behind as if it were real prose (exactly the leak this
// ticket reports). Given `raw[i] == '<'`, returns the number of bytes
// spanned by a `<script>`/`<style>` *opening* tag found there through its
// matching closing tag's final `>` (0 when `raw[i]` is not such an opening
// tag, in which case the caller's ordinary single-tag stripping still
// applies). An opening tag with no matching close consumes to end-of-string,
// matching a real HTML tokenizer's raw-text-element handling (an
// unterminated `<script>`/`<style>` swallows the rest of the document
// rather than leaking as visible text) -- same "abstain toward hiding, not
// leaking" bias as `hiddenTag`'s own use.
private size_t hiddenElementSpanLength(string raw, size_t i) pure nothrow @nogc {
    size_t j = i + 1;
    if (j >= raw.length || raw[j] == '/') return 0; // a closing tag, not opening
    string tag;
    if (tagNameAt(raw, j, "script")) tag = "script";
    else if (tagNameAt(raw, j, "style")) tag = "style";
    else return 0;

    size_t k = j + tag.length;
    while (k < raw.length && raw[k] != '>') ++k;
    if (k >= raw.length) return raw.length - i; // unterminated opening tag
    ++k; // past the opening tag's '>'

    while (k < raw.length) {
        if (raw[k] == '<' && k + 1 < raw.length && raw[k + 1] == '/' &&
                tagNameAt(raw, k + 2, tag)) {
            size_t closeEnd = k + 2 + tag.length;
            while (closeEnd < raw.length && raw[closeEnd] != '>') ++closeEnd;
            if (closeEnd < raw.length) ++closeEnd; // include the closing tag's '>'
            return closeEnd - i;
        }
        ++k;
    }
    return raw.length - i; // no closing tag found: consume to end-of-string
}

// Strips literal HTML tags a schema.org JSON text/articleBody value may
// carry -- the exact www-homify-de.html HowTo `step[].itemListElement.text`
// shape ("<p>...</p>"). A removed tag becomes a single space (never a
// direct word concatenation), then decodes any character references left
// over (`_render_text`'s own two-step "unescape, then strip markup" shape,
// just in the opposite order -- decoding after stripping means a decoded
// `&lt;`/`&gt;` can never be mistaken for a real tag boundary). Issue #484:
// a `<script>`/`<style>` element's own text content is dropped along with
// its tags (`hiddenElementSpanLength`), not merely un-tagged into visible
// text, matching the DOM-selection path's `hiddenTag` exclusion.
private string plainTextFromStructuredData(string raw) pure {
    char[] stripped;
    stripped.reserve(raw.length);
    size_t i;
    while (i < raw.length) {
        char c = raw[i];
        if (c != '<') { stripped ~= c; ++i; continue; }
        if (stripped.length && stripped[$ - 1] != ' ') stripped ~= ' ';
        auto hiddenSpan = hiddenElementSpanLength(raw, i);
        if (hiddenSpan > 0) { i += hiddenSpan; continue; }
        ++i;
        while (i < raw.length && raw[i] != '>') ++i;
        if (i < raw.length) ++i; // past '>'
    }
    return decodeStructuredDataEntities(cast(string) stripped);
}

// Collects schema.org text content from one parsed JSON-LD value
// (list-wrapped and `@graph`/`mainEntity`-nested nodes included), per
// `structuredDataTextKeys`/`structuredDataStepKeys`'s doc comment. Bounded
// recursion: `parseJSON`'s own `maxStructuredDataParseDepth` already caps
// how deep a nested JSON-LD value can be before parsing ever reaches here,
// and total work is bounded by `maxStructuredDataAggregateBytes` (the raw
// JSON text this was parsed from).
private void collectStructuredDataBodies(ref JSONValue node, ref string[] bodies) pure {
    if (node.type == JSONType.array) {
        foreach (ref item; node.array) collectStructuredDataBodies(item, bodies);
        return;
    }
    if (node.type != JSONType.object) return;
    foreach (key; structuredDataTextKeys) {
        if (auto v = key in node.object)
            if (v.type == JSONType.string && v.str.length) bodies ~= v.str;
    }
    foreach (key; structuredDataStepKeys) {
        auto v = key in node.object;
        if (v is null) continue;
        if (v.type == JSONType.string) {
            if (v.str.length) bodies ~= v.str;
            continue;
        }
        if (v.type != JSONType.array) continue;
        foreach (ref step; v.array) {
            if (step.type == JSONType.string) {
                if (step.str.length) bodies ~= step.str;
                continue;
            }
            if (step.type != JSONType.object) continue;
            if (auto t = "text" in step.object)
                if (t.type == JSONType.string && t.str.length) bodies ~= t.str;
            auto ile = "itemListElement" in step.object;
            if (ile is null) continue;
            JSONValue[] subs = ile.type == JSONType.array ? ile.array : [*ile];
            foreach (ref sub; subs) {
                if (sub.type != JSONType.object) continue;
                if (auto t2 = "text" in sub.object)
                    if (t2.type == JSONType.string && t2.str.length) bodies ~= t2.str;
            }
        }
    }
    if (auto answer = "acceptedAnswer" in node.object) {
        if (answer.type == JSONType.object)
            if (auto t = "text" in answer.object)
                if (t.type == JSONType.string && t.str.length) bodies ~= t.str;
    }
    foreach (key; ["@graph", "mainEntity"]) {
        if (auto v = key in node.object) collectStructuredDataBodies(*v, bodies);
    }
}

// Direct (non-recursive) child text, for `<script>` bodies -- same idiom
// `topical_tags_extract_stage.d`'s own `directChildText` already
// establishes for the identical "read a script tag's own text" need
// (restated here, not shared: see `structuredDataScriptType`'s doc comment
// on this module's effects-layer import restriction).
private string scriptOwnText(const ref HtmlTree tree, size_t scriptIndex) pure {
    string result;
    foreach (i, ref node; tree.nodes)
        if (node.parentIndex == scriptIndex && node.kind == HtmlNodeKind.text)
            result ~= node.text;
    return result;
}

// Issue #411's real fallback: only reached once the ordinary candidate pass
// has already abstained (see `abstainOrRescue`). Scans every
// `<script type="application/ld+json">` on the page (bounded aggregate
// bytes, bounded JSON parse depth -- a single malformed/oversize block is
// skipped, never fatal to the whole document, same resilience idiom
// `topical_tags_extract_stage.d`'s own ld+json handling already uses) for
// schema.org content properties, and joins whatever real text they carry
// with the same `CollapsingWriter`/paragraph-break/output-cap machinery the
// ordinary selected-subtree path already uses below. Returns `null` when no
// script carried a recognized content property at all.
private string structuredDataFallbackText(const ref HtmlTree tree) pure {
    size_t aggregateBytesScanned;
    string[] bodies;
    foreach (i, ref node; tree.nodes) {
        if (node.kind != HtmlNodeKind.element || node.name != "script") continue;
        if (attributeValue(node, "type") != structuredDataScriptType) continue;
        auto scriptText = scriptOwnText(tree, i);
        if (scriptText.length == 0) continue;
        if (aggregateBytesScanned + scriptText.length > maxStructuredDataAggregateBytes) continue;
        aggregateBytesScanned += scriptText.length;
        JSONValue root;
        try root = parseJSON(scriptText, maxStructuredDataParseDepth, JSONOptions.strictParsing);
        catch (Exception) continue; // invalid JSON syntax: skip this block only
        collectStructuredDataBodies(root, bodies);
    }
    if (bodies.length == 0) return null;
    CollapsingWriter collapsing;
    foreach (bodyText; bodies) {
        collapsing.paragraphBreak();
        collapsing.feed(plainTextFromStructuredData(bodyText));
    }
    return collapsing.writer.bytes.idup;
}

// Tries the structured-data fallback before committing to an abstention;
// promotes to `selectedStructuredData` only if the recovered text clears
// the exact same floor an ordinary DOM candidate must clear
// (`minSelectableTextBytes`) -- a trivial/near-empty ld+json blob must not
// override a genuine abstention, matching this module's existing
// "explicit abstention over best-effort guess" rule. May propagate
// `HtmlMainContentOutputLimit` (via `CollapsingWriter`'s shared `Writer`),
// exactly as the ordinary selected path already can.
private MainContentResult abstainOrRescue(const ref HtmlTree tree,
        MainContentResult result, MainContentStatus reason) pure {
    auto rescued = structuredDataFallbackText(tree);
    if (rescued.length >= minSelectableTextBytes) {
        result.status = MainContentStatus.selectedStructuredData;
        result.text = rescued;
        return result;
    }
    result.status = reason;
    return result;
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
            // isWhite is checked before isControl: `\n`, `\t`, `\r`, `\f`,
            // `\v` are Unicode Cc (control) characters that are ALSO
            // White_Space, so an isControl-first check would drop them
            // outright (issue #516) instead of collapsing them into the
            // same single space as an ordinary run of ' '/'\t'. A control
            // character that is not whitespace (NUL, ESC, other C0/C1
            // controls) falls through to the isControl check below and is
            // still dropped exactly as before.
            if (isWhite(ch)) { if (any) pendingSpace = true; continue; }
            if (isControl(ch) || isFormat(ch)) continue;
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

// Issue #516 regression, at the primitive itself: `isControl` was checked
// before `isWhite`/`isSpace` in `feed`, and `\n`/`\t`/`\r` are Unicode Cc
// (control) characters that are ALSO White_Space, so they hit the
// isControl branch first and were dropped outright instead of collapsing
// into a single space -- silently gluing adjacent words together. Fail
// before the fix (isControl checked first): this exact assert fails with
// `cw.writer.bytes == "firstsecondthirdfourth"`. Pass after (isWhite
// checked first): words stay space-separated, participating in the same
// `pendingSpace` run-collapsing logic as an ordinary space/tab run.
unittest {
    CollapsingWriter cw;
    cw.feed("first");
    cw.feed("\n");
    cw.feed("second");
    cw.feed("\t");
    cw.feed("third");
    cw.feed("\r\n");
    cw.feed("fourth");
    assert(cw.writer.bytes == "first second third fourth",
        "newline/tab/CRLF between feed() calls must collapse to a single " ~
        "space, not glue words (#516)");

    // Same, all within a single feed() call (a single text node containing
    // pretty-printed/hand-wrapped whitespace, the routine real-world shape
    // the ticket describes).
    CollapsingWriter cwOneChunk;
    cwOneChunk.feed("fifth\nsixth\tseventh\r\neighth");
    assert(cwOneChunk.writer.bytes == "fifth sixth seventh eighth",
        "whitespace-classified control characters within one chunk must " ~
        "still collapse to single spaces, not glue words (#516)");

    // A genuinely non-whitespace control character (NUL) must still be
    // dropped outright, not converted to a space -- this must not regress
    // per the ticket's third acceptance criterion.
    CollapsingWriter cwNul;
    cwNul.feed("ninth\0tenth");
    assert(cwNul.writer.bytes == "ninthtenth",
        "a non-whitespace control character (NUL) must still be dropped " ~
        "outright, not converted to a space (#516)");
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
// carry a negative keyword match (`standard`/`precision`'s "both sides"
// case below) -- a real, observed structural pattern (a plain paragraph
// sandwiched directly between two `registration-banner*` siblings), not a
// guess, and narrow enough that an ordinary paragraph standing next to a
// single unrelated ad/share element is never caught.
//
// Issue #479's second `ExtractionMode` preset axis (see `ExtractionMode`'s
// own doc comment): `precision` widens this same real pattern to "either
// side is enough" -- willing to drop a keyword-neutral paragraph merely
// adjacent to one boilerplate-classed sibling, favoring less noise at the
// cost of occasionally dropping a real, adjacent-to-chrome paragraph.
// `recall` disables the sandwich heuristic entirely -- a keyword-neutral
// node is kept regardless of its neighbors, only an outright negative
// keyword match on the node itself still excludes it -- favoring more text
// kept, some of it real noise the sandwich rule would otherwise have
// caught. `standard` is the exact pre-existing "both sides" rule, unchanged
// -- this ticket's own non-regression requirement for the default mode.
// Real corpus evidence for the `recall` case:
// `docs/html-main-content.md`'s own "Configurable precision/recall
// extraction mode" section shows this exact page's real
// `registration-banner__text`/`registration-banner__button`-sandwiched
// paragraph ("erhalten Sie exklusive...") reappearing in `.text` under
// `recall` where `standard`/`precision` both still exclude it.
//
// Issue #517: a bare `<nav>` element is excluded by tag, in every mode,
// ahead of the keyword checks. This is the tag-level twin of the existing
// `"nav"` negative keyword, which already excludes `<div class="nav">` in
// every mode including `recall`. Only `nav` is excluded by tag here. The
// other `negativeContentTags` (`aside`/`header`/`footer`/`figure`/...)
// still count against scoring but are kept once inside the winning
// subtree: an in-article `<aside>` pull quote, `<header>` byline or
// `<figure>` caption is often real content. See `docs/html-main-content.md`
// ("Tag-level nav exclusion and text/Markdown agreement") for the
// trafilatura comparison and the held-out corpus measurement.
//
// This is the only exclusion rule for the selected subtree. Both `.text`
// (`extractMainContent`) and `.markdown` (`effects.html_main_content_markdown`)
// read it through `selectedContentTree`, so the two outputs cannot
// disagree on what they drop.
private bool excludedFromText(const ref HtmlTree tree, const size_t[] prevSibling,
        const size_t[] nextSibling, size_t index, ExtractionMode mode) pure {
    if (tree.nodes[index].name == "nav") return true;
    double keyword = keywordScoreFor(tree.nodes[index]);
    if (keyword < 0.0) return true;
    if (keyword > 0.0) return false;
    if (mode == ExtractionMode.recall) return false;
    auto prev = prevSibling[index];
    auto next = nextSibling[index];
    if (prev == size_t.max || next == size_t.max) return false;
    if (tree.nodes[prev].kind != HtmlNodeKind.element ||
        tree.nodes[next].kind != HtmlNodeKind.element) return false;
    bool prevNegative = keywordScoreFor(tree.nodes[prev]) < 0.0;
    bool nextNegative = keywordScoreFor(tree.nodes[next]) < 0.0;
    return mode == ExtractionMode.precision ? (prevNegative || nextNegative) :
        (prevNegative && nextNegative);
}

// Immediate previous/next *element* sibling of every node, for
// `excludedFromText`'s sandwich rule (issue #27 Case 2). A single forward
// pass: pre-order means one node's whole subtree is a contiguous run of
// higher indices before its next sibling begins, so the last child seen so
// far for a given parent is always that child's true immediate previous
// sibling by the time the next one is reached. Only element nodes take
// part: pretty-printed whitespace between two sibling elements is its own
// intervening text node in the flat tree (e.g. "...</p>\n    <p>...", the
// exact shape between the real for-me-online.de promo <p>s), and it must
// not break "immediate sibling" into "immediate non-whitespace-text
// sibling" -- excludedFromText only ever queries an element's siblings, so
// a text node is simply skipped rather than recorded here.
private void linkSiblings(const ref HtmlTree tree, size_t[] prevSibling,
        size_t[] nextSibling) pure {
    const n = tree.nodes.length;
    prevSibling[] = size_t.max;
    nextSibling[] = size_t.max;
    auto lastChildOfParent = new size_t[n];
    lastChildOfParent[] = size_t.max;
    size_t lastRootChild = size_t.max;
    foreach (i; 0 .. n) {
        if (tree.nodes[i].kind != HtmlNodeKind.element) continue;
        auto p = tree.nodes[i].parentIndex;
        size_t* last = p == size_t.max ? &lastRootChild : &lastChildOfParent[p];
        if (*last != size_t.max) {
            nextSibling[*last] = i;
            prevSibling[i] = *last;
        }
        *last = i;
    }
}

/// Issue #517: the selected subtree as its own standalone `HtmlTree`, with
/// every descendant `excludedFromText` rejects (and that descendant's whole
/// subtree) already removed. `root` becomes index 0 with no parent; the
/// remaining nodes keep their pre-order and are re-indexed. Node contents
/// are otherwise copied unchanged, and non-visible `script`/`style`/
/// `template`/`head` descendants are kept, since every renderer already
/// skips those itself.
///
/// This is the one place the selected subtree's boilerplate exclusion is
/// applied. `.text` (`extractMainContent`) collects from this tree and
/// `.markdown` (`effects.html_main_content_markdown`) renders from it, so
/// the two outputs drop exactly the same descendants. Before this, only
/// `.text` applied the exclusion; `.markdown` rendered the raw selected
/// node, so e.g. `<nav class="nav">` inside a selected `<div>` was missing
/// from `.text` but present in `.markdown`.
HtmlTree selectedContentTree(const ref HtmlTree tree, size_t root,
        ExtractionMode mode = ExtractionMode.standard) pure {
    const n = tree.nodes.length;
    auto prevSibling = new size_t[n];
    auto nextSibling = new size_t[n];
    linkSiblings(tree, prevSibling, nextSibling);

    HtmlTree result;
    result.observedBytes = tree.observedBytes;
    const end = endOf(tree, root);
    // Original index -> index in `result`, for the kept nodes only.
    auto remap = new size_t[end - root];
    for (size_t i = root; i < end;) {
        ref const node = tree.nodes[i];
        if (i != root && node.kind == HtmlNodeKind.element &&
                excludedFromText(tree, prevSibling, nextSibling, i, mode)) {
            i = endOf(tree, i);
            continue;
        }
        remap[i - root] = result.nodes.length;
        // A kept node's parent is always itself kept: excluding an element
        // skips its whole subtree above.
        size_t parent = i == root ? size_t.max : remap[node.parentIndex - root];
        result.nodes ~= HtmlNode(node.kind, parent, node.name, node.text,
            node.attributes.dup);
        ++i;
    }
    return result;
}

private bool commentSectionRootTag(string name) pure nothrow @nogc {
    foreach (tag; commentSectionRootTags) if (tag == name) return true;
    return false;
}

private bool matchesCommentSectionKeyword(const ref HtmlNode node) pure {
    auto classValue = attributeValue(node, "class");
    auto idValue = attributeValue(node, "id");
    foreach (kw; commentSectionKeywords)
        if ((classValue.length && containsCaseInsensitive(classValue, kw)) ||
            (idValue.length && containsCaseInsensitive(idValue, kw)))
            return true;
    return false;
}

// Visible text of one subtree, skipping the non-visible
// script/style/template/head descendants exactly as html_markdown.d's
// nodeText does (a bounded ancestor walk, not recursion). Also tracks each
// text node's nearest block-level ancestor (same walk, same bound) so a
// change of block ancestor between one text node and the next -- e.g. an
// `</h1>` followed by a `<p>`, or one `<li>` followed by the next -- emits
// an explicit paragraph break instead of the ordinary whitespace collapse.
// `blockAncestor` defaults to `start` itself (the subtree root) when no
// block-tag ancestor is found closer than the root, so two text nodes that
// are both direct, unwrapped children of the root (or of the same non-block
// wrapper) still group as one paragraph.
//
// No boilerplate exclusion happens here. The selected main content is
// collected from `selectedContentTree`, which has already removed what
// `excludedFromText` rejects. Comment sections are collected from the
// original tree with no exclusion at all: the sandwich rule exists to strip
// a small embedded promotional run out of an otherwise-legitimate *article*
// container (issue #27 Case 2), which has no bearing on a comment section's
// own text once the whole subtree has been identified as a comment section.
private void collectPlainSubtreeText(const ref HtmlTree tree, size_t start, size_t end,
        ref CollapsingWriter cw) pure {
    size_t lastBlockAncestor = size_t.max;
    foreach (i; start + 1 .. end) {
        if (tree.nodes[i].kind != HtmlNodeKind.text) continue;
        bool hidden;
        size_t blockAncestor = start;
        bool foundBlock;
        for (size_t parent = tree.nodes[i].parentIndex;
             parent != start && parent != size_t.max && parent < i;
             parent = tree.nodes[parent].parentIndex) {
            if (hiddenTag(tree.nodes[parent].name)) { hidden = true; break; }
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

// Issue #475: identifies and extracts comment-section text, entirely
// independent of the ordinary DOM candidate-scoring pass above (no
// interaction with `.text`/`.node`/`.score`/`.status` either way -- see
// `MainContentResult.commentsExtracted`'s doc comment). A single forward
// pre-order pass (the flat tree is already pre-order, the same invariant
// `endOf`/the sibling-linking pass above rely on): each element whose tag is
// a real block container (`commentSectionRootTags`) and whose class/id
// matches `commentSectionKeywords` becomes a comment-section root, and its
// whole subtree (`endOf`) is claimed -- a nested match inside an
// already-claimed root (e.g. `scienceblogs-de.html`'s individual
// `<div id="comment-NNNNNN">` entries inside the page's own outer
// `<div id="comments">`) is not treated as a second, separate root, since
// the outer root's own text collection already walks it. Multiple
// *sibling* (non-nested) comment sections on the same page (rare, but not
// impossible -- e.g. a "Recent Comments" sidebar widget alongside the
// post's own discussion thread) are each collected and joined with a
// paragraph break, same as separate blocks within one root.
//
// Deliberately does not share `extractMainContent`'s own 4 MiB
// `HtmlMainContentOutputLimit` invariant: that invariant exists so the
// *selected* main content is never observed as a truncated partial value.
// Comments are a supplementary, independently-identified output, and a
// single real page's comment thread growing past that bound (plausible --
// `scienceblogs-de.html`, this corpus's own largest real thread at 140
// entries, is well under it, but a highly-discussed post elsewhere would
// not be) must not turn into a hard failure that quarantines the whole
// document over a part of the page nothing else depends on. So this
// catches its own overflow and returns whatever was collected before the
// cap was hit, truncated rather than fatal -- a real, disclosed divergence
// from the main-content path's own stricter invariant, not an oversight.
private struct CommentScanResult { bool found; string text; }

private CommentScanResult collectComments(const ref HtmlTree tree) pure {
    const n = tree.nodes.length;
    CollapsingWriter cw;
    size_t claimedUntil;
    bool found;
    try {
        foreach (i; 0 .. n) {
            ref const node = tree.nodes[i];
            if (node.kind != HtmlNodeKind.element) continue;
            if (i < claimedUntil) continue;
            if (hiddenTag(node.name)) continue;
            if (!commentSectionRootTag(node.name)) continue;
            if (!matchesCommentSectionKeyword(node)) continue;
            found = true;
            auto end = endOf(tree, i);
            cw.paragraphBreak();
            collectPlainSubtreeText(tree, i, end, cw);
            claimedUntil = end;
        }
    } catch (HtmlMainContentOutputLimit) {
        // See doc comment above: truncate, never fail the whole document
        // over an oversized comment thread alone.
    }
    return CommentScanResult(found, cw.writer.bytes.idup);
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
/// collecting its text (`selectedContentTree`) additionally skips any `<nav>`
/// descendant (issue #517) or descendant
/// whose class/id matches a negative keyword, plus a keyword-neutral
/// descendant sandwiched directly between two such matches (`excludedFromText`;
/// issue #27) -- a boilerplate exclusion distinct from scoring itself, since
/// a large winning container can still have a small embedded promotional
/// block that never had to win a scoring contest to leak into the output.
///
/// Selection is a single rule: the highest-scoring node wins. Below
/// `minSelectableTextBytes`/`minSelectableScore` (each scaled by the chosen
/// `ExtractionMode` -- see that enum's own doc comment for issue #479's
/// precision/recall presets; `mode == standard` uses the two constants
/// unscaled, exactly as before this ticket), having no element candidate at
/// all, or an exact tie for the top score are each an explicit abstention
/// (`abstainedBelowThreshold`/`abstainedNoCandidate`/
/// `abstainedTie`) — never a best-effort guess -- UNLESS
/// `structuredDataFallbackText` (issue #411) recovers real schema.org JSON-LD
/// content the DOM candidate pass could never see at all (content delivered
/// only as JSON props/JSON-LD, not DOM text/elements -- see that function's
/// doc comment), in which case `abstainOrRescue` promotes the result to
/// `selectedStructuredData` instead. Only `HtmlTree`'s own bounded,
/// already-capped node data is read; this performs no parsing and makes no
/// native/native-adjacent calls (the structured-data fallback's own JSON
/// parsing is over `HtmlTree` text already captured by the same restricted
/// boundary, not a second native-adjacent call).
///
/// Throws `HtmlMainContentOutputLimit` before returning any result if the
/// selected node's (or, for `selectedStructuredData`, the recovered
/// structured-data text's) whitespace-collapsed UTF-8 text would exceed
/// 4 MiB.
///
/// `includeComments` (issue #475, default `true`, matching trafilatura's own
/// "comments on by default, `--no-comments` opts out" shape): when `true`,
/// also scans the whole document for comment-section markup
/// (`commentSectionKeywords`/`commentSectionRootTags`) and populates
/// `.commentsExtracted`/`.comments` -- a separate, identified output, never
/// merged into `.text` and never influencing which node the ordinary
/// candidate pass selects (that pass already discounted a "comment"-keyword
/// match to zero or negative before this ticket; this only adds an
/// *identity* for what was already being excluded). When `false`, comment
/// scanning does not run at all: `.commentsExtracted` stays `false` and
/// `.comments` stays empty, on every page, regardless of what markup is
/// actually present.
///
/// `mode` (issue #479, default `ExtractionMode.standard`, matching
/// trafilatura's own "no flag" default): selects one of the two real,
/// coordinated `precision`/`recall` presets described on `ExtractionMode`'s
/// own doc comment -- the selection floor and the text-collection sandwich
/// rule both scale together with the chosen preset. `standard` reproduces
/// every constant/code path this function used before this ticket exactly,
/// which is what keeps issue #411's 20/20 corpus result unaffected at the
/// default mode.
MainContentResult extractMainContent(const ref HtmlTree tree, bool includeComments = true,
        ExtractionMode mode = ExtractionMode.standard) pure {
    MainContentResult result;
    const n = tree.nodes.length;
    if (n == 0) {
        result.status = MainContentStatus.abstainedNoCandidate;
        return result;
    }
    if (includeComments) {
        auto comments = collectComments(tree);
        result.commentsExtracted = comments.found;
        result.comments = comments.text;
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

    if (topCount == 0)
        return abstainOrRescue(tree, result, MainContentStatus.abstainedNoCandidate);

    auto best = top[0];
    auto thresholds = selectionThresholdsFor(mode);
    if (best.textLength < thresholds.minTextBytes || best.score < thresholds.minScore)
        return abstainOrRescue(tree, result, MainContentStatus.abstainedBelowThreshold);
    if (topCount >= 2 && top[1].score == best.score)
        return abstainOrRescue(tree, result, MainContentStatus.abstainedTie);

    CollapsingWriter collapsing;
    auto content = selectedContentTree(tree, best.node, mode);
    collectPlainSubtreeText(content, 0, content.nodes.length, collapsing);
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

// Issue #411: the structured-data (JSON-LD) fallback. www-homify-de.html's
// own real shape -- a chrome-only DOM (here reduced to a bare abstaining
// `<nav>`) plus a `<script type="application/ld+json">` schema.org `HowTo`
// carrying the page's real content as `step[].itemListElement.text` -- must
// be rescued into `selectedStructuredData` rather than left quarantined.
unittest {
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
    auto structuredResult = extractMainContent(structuredOnly);
    assert(structuredResult.status == MainContentStatus.selectedStructuredData,
        "real JSON-LD content behind an abstaining DOM must be rescued");
    assert(structuredResult.node == size_t.max,
        "structured-data text has no corresponding tree node");
    assert(structuredResult.score == 0.0,
        "structured-data text has no corresponding candidate score");
    assert(structuredResult.text.canFind("Article body sentence."),
        "the HowTo step's own text must reach the final output");
    assert(!structuredResult.text.canFind("<p>") && !structuredResult.text.canFind("</p>"),
        "embedded HTML markup inside the JSON string must be stripped");

    // Multiple steps become multiple paragraphs, same "\n\n" separator the
    // ordinary DOM path already uses (Issue #335 Slice 1).
    HtmlTree twoSteps;
    twoSteps.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "script", null,
            [HtmlAttribute("type", "application/ld+json")]),
        HtmlNode(HtmlNodeKind.text, 0, null,
            `{"@type":"HowTo","step":[` ~
            `{"itemListElement":{"text":"<p>` ~ longParagraph ~ `</p>"}},` ~
            `{"itemListElement":{"text":"<p>` ~ longParagraph ~ `</p>"}}]}`),
    ];
    auto twoStepResult = extractMainContent(twoSteps);
    assert(twoStepResult.status == MainContentStatus.selectedStructuredData);
    // trim() mirrors CollapsingWriter never emitting a trailing pending space.
    string trimmedParagraph = longParagraph[0 .. $ - 1];
    assert(twoStepResult.text == trimmedParagraph ~ "\n\n" ~ trimmedParagraph);

    // A real `&nbsp;` character reference (the one actually observed in
    // www-homify-de.html's own ld+json text) decodes to U+00A0 -- a
    // whitespace character `CollapsingWriter` then collapses like any other
    // (same as the ordinary DOM path already does for real whitespace), so
    // the observable effect is an ordinary single space between the
    // surrounding real words, never literal "&nbsp;" text.
    HtmlTree entityCase;
    entityCase.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "script", null,
            [HtmlAttribute("type", "application/ld+json")]),
        HtmlNode(HtmlNodeKind.text, 0, null,
            `{"@type":"HowTo","step":[{"itemListElement":{"text":"<p>` ~
            longParagraph ~ `passt?&nbsp;danach geht es weiter.</p>"}}]}`),
    ];
    auto entityResult = extractMainContent(entityCase);
    assert(entityResult.status == MainContentStatus.selectedStructuredData);
    assert(entityResult.text.canFind("passt? danach"),
        "a real named character reference must decode, not survive as literal text");
    assert(!entityResult.text.canFind("&nbsp;"));

    // Too little recovered text must not override a genuine abstention --
    // same floor (`minSelectableTextBytes`) an ordinary DOM candidate must
    // clear, per this function's own doc comment.
    HtmlTree tooShort;
    tooShort.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "nav", null, null),
        HtmlNode(HtmlNodeKind.text, 0, null, "Home About Contact"),
        HtmlNode(HtmlNodeKind.element, size_t.max, "script", null,
            [HtmlAttribute("type", "application/ld+json")]),
        HtmlNode(HtmlNodeKind.text, 2, null,
            `{"@type":"Article","articleBody":"Too short."}`),
    ];
    auto tooShortResult = extractMainContent(tooShort);
    assert(tooShortResult.status == MainContentStatus.abstainedBelowThreshold,
        "a trivial ld+json blob must not override a genuine abstention");
    assert(tooShortResult.text.length == 0);

    // Malformed JSON syntax is skipped (this one block only), never fatal:
    // the document still abstains normally rather than throwing.
    HtmlTree malformed;
    malformed.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "nav", null, null),
        HtmlNode(HtmlNodeKind.text, 0, null, "Home About Contact"),
        HtmlNode(HtmlNodeKind.element, size_t.max, "script", null,
            [HtmlAttribute("type", "application/ld+json")]),
        HtmlNode(HtmlNodeKind.text, 2, null, `{not valid json at all`),
    ];
    auto malformedResult = extractMainContent(malformed);
    assert(malformedResult.status == MainContentStatus.abstainedBelowThreshold,
        "invalid ld+json syntax must be skipped, not fatal");

    // A non-ld+json script (e.g. ordinary page JS) is never treated as a
    // structured-data source, and its text never reaches scoring or output
    // either (hiddenTag; pre-existing behavior, reconfirmed here).
    HtmlTree ordinaryScript;
    ordinaryScript.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "nav", null, null),
        HtmlNode(HtmlNodeKind.text, 0, null, "Home About Contact"),
        HtmlNode(HtmlNodeKind.element, size_t.max, "script", null, null),
        HtmlNode(HtmlNodeKind.text, 2, null,
            `{"@type":"HowTo","step":[{"itemListElement":{"text":"<p>` ~
            longParagraph ~ `</p>"}}]}`),
    ];
    auto ordinaryScriptResult = extractMainContent(ordinaryScript);
    assert(ordinaryScriptResult.status == MainContentStatus.abstainedBelowThreshold,
        "a script with no ld+json type attribute must not be scanned");

    // Issue #484: a `<script>` element embedded *inside* a recovered JSON-LD
    // string value (e.g. `articleBody`) must have its non-visible text
    // content dropped along with its tags, exactly like `hiddenTag` already
    // does for the ordinary DOM-selection path (the "hidden script text
    // leaked" unittest above) -- not merely have the `<script>`/`</script>`
    // tags stripped while "evil()" itself leaks through as visible prose.
    // Ticket's own reproduction fixture, reduced to a unittest fixture.
    HtmlTree scriptInStructuredData;
    scriptInStructuredData.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "nav", null, null),
        HtmlNode(HtmlNodeKind.text, 0, null, "Home About Contact"),
        HtmlNode(HtmlNodeKind.element, size_t.max, "script", null,
            [HtmlAttribute("type", "application/ld+json")]),
        HtmlNode(HtmlNodeKind.text, 2, null,
            `{"@type":"Article","articleBody":"<div><p class=\"x\">Unclosed tags and ` ~
            `<b>bold <i>italic text here with <script>evil()<\/script> embedded and a ` ~
            `stray angle bracket and an unterminated tag with a very long real sentence ` ~
            `of readable prose padded out so that after every piece of embedded markup ` ~
            `is stripped away there is still comfortably more than two hundred bytes of ` ~
            `genuine paragraph text left over for the extraction floor to accept without ` ~
            `any trouble at all here now for sure."}`),
    ];
    auto scriptInStructuredDataResult = extractMainContent(scriptInStructuredData);
    assert(scriptInStructuredDataResult.status == MainContentStatus.selectedStructuredData,
        "the genuine prose padding must still clear the selection floor");
    assert(!scriptInStructuredDataResult.text.canFind("evil()"),
        "hidden <script> text embedded inside a JSON-LD string value leaked");
    assert(scriptInStructuredDataResult.text.canFind("readable prose padded out"),
        "the real surrounding prose must still survive the fix");

    // `<style>` gets the identical exclusion, not just `<script>`.
    HtmlTree styleInStructuredData;
    styleInStructuredData.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "script", null,
            [HtmlAttribute("type", "application/ld+json")]),
        HtmlNode(HtmlNodeKind.text, 0, null,
            `{"@type":"Article","articleBody":"<style>.x{color:red}<\/style>` ~
            longParagraph ~ `"}`),
    ];
    auto styleInStructuredDataResult = extractMainContent(styleInStructuredData);
    assert(styleInStructuredDataResult.status == MainContentStatus.selectedStructuredData);
    assert(!styleInStructuredDataResult.text.canFind("color:red"),
        "hidden <style> text embedded inside a JSON-LD string value leaked");
    assert(styleInStructuredDataResult.text.canFind("Article body sentence."));
}

// Issue #516, through the real DOM-selection path (the actual lexbor
// parser, not a hand-built tree) -- the ticket's own second reproduction,
// verbatim: inline elements (`<b>`/`<i>`) interleaved with bare-whitespace
// text nodes must not glue the surrounding words together either. Inline
// elements don't change the nearest block-level ancestor, so this exercises
// `CollapsingWriter.feed`'s own whitespace collapsing directly, independent
// of the paragraph-break ("\n\n") machinery Issue #335 Slice 1 covers.
unittest {
    import effects.html_tree : parseHtml;
    import std.algorithm.searching : canFind;

    string longParagraph;
    foreach (_; 0 .. 25) longParagraph ~= "Article body sentence. ";

    string realHtml = "<article><p>" ~ longParagraph ~
        "alpha\n<b>beta</b>\n<i>gamma</i> one\ntwo\tthree</p></article>";
    auto outcome = parseHtml(cast(const(ubyte)[]) realHtml);
    assert(outcome.isParsed);
    auto realResult = extractMainContent(outcome.tree);
    assert(realResult.status == MainContentStatus.selected);
    assert(realResult.text.canFind("alpha beta gamma one two three"),
        "the ticket's own real-DOM repro must not glue words together (#516)");
    assert(!realResult.text.canFind("alphabetagamma"),
        "the ticket's own real-DOM repro must not glue words together (#516)");
}

// Issue #485: a literal, unescaped `</script>` inside a JSON-LD string value.
// Parsed through the real lexbor boundary (not a hand-built tree), because
// the whole point is how the HTML5 tokenizer splits this: the raw-text
// `<script>` ends at the first `</script>`, so the script's own text is the
// truncated, unparseable `{"@type":"Article","articleBody":"... PrefixMarker `
// and everything after it (including the `"}` JSON tail) becomes ordinary
// `<body>` text -- exactly what a browser renders visibly. The invariant
// pinned here: the truncated block contributes *nothing* through the
// structured-data fallback (never parsed leniently, never stitched to
// sibling text outside the script element), so any text in the result
// comes from the ordinary DOM path, and the invisible prefix never appears.
// The properly escaped `<\/script>` twin must still be recovered whole.
unittest {
    import effects.html_tree : parseHtml;
    import std.algorithm.searching : canFind;

    string tailProse = " and some prose after the close tag with a very long real " ~
        "sentence of readable prose padded out so that there is still comfortably " ~
        "more than two hundred bytes of genuine paragraph text left over for the " ~
        "extraction floor to accept without any trouble at all here now for sure " ~
        "end of body.";
    string pageWith(string closeTag) {
        return "<html><head>\n<script type=\"application/ld+json\">\n" ~
            `{"@type":"Article","articleBody":"Some prose before the marker PrefixMarker ` ~
            closeTag ~ tailProse ~ "\"}\n</script>\n</head><body><nav>NavBoilerplateMarker " ~
            "Home About Contact</nav></body></html>";
    }

    auto unescaped = parseHtml(cast(const(ubyte)[]) pageWith("</script>"));
    assert(unescaped.isParsed);
    assert(structuredDataFallbackText(unescaped.tree) is null,
        "a JSON-LD block truncated by an unescaped </script> must contribute nothing");
    auto unescapedResult = extractMainContent(unescaped.tree);
    assert(unescapedResult.status != MainContentStatus.selectedStructuredData,
        "truncated JSON-LD must never be promoted to selectedStructuredData");
    assert(!unescapedResult.text.canFind("PrefixMarker"),
        "text inside the (truncated) script element must never leak into output");

    auto escaped = parseHtml(cast(const(ubyte)[]) pageWith(`<\/script>`));
    assert(escaped.isParsed);
    auto escapedResult = extractMainContent(escaped.tree);
    assert(escapedResult.status == MainContentStatus.selectedStructuredData);
    assert(escapedResult.text.canFind("PrefixMarker") &&
        escapedResult.text.canFind("end of body."),
        "a properly escaped JSON-LD value must be recovered whole");
    assert(!escapedResult.text.canFind("NavBoilerplateMarker"),
        "recovered JSON-LD text must never carry DOM boilerplate");
}

// Issue #475: comment-section identification/extraction, distinct from
// `.text`. Fixture shapes below are modeled directly on this repo's own real
// held-out corpus (`examples/pipeline-benchmark/corpus/`), not invented --
// see `commentSectionKeywords`'s own doc comment for the exact real pages
// each shape is drawn from.
unittest {
    import std.algorithm.searching : canFind;

    string longParagraph;
    foreach (_; 0 .. 25) longParagraph ~= "Article body sentence. ";

    // archiv-krimiblog-de.html / kleinegruenemonster-wordpress-com.html /
    // scienceblogs-de.html's real shape: an <article> with real body text,
    // followed by a sibling <div id="comments"> wrapping one or more real
    // comment entries. The comment section must not appear in `.text` (it
    // already didn't, before this ticket -- `selectedContentTree` only ever walks
    // the *selected* node's own subtree, and this comments div is a sibling,
    // not a descendant, of the winning <article>) but must now be separately
    // identified and extracted into `.comments`.
    HtmlTree wordpressShaped;
    wordpressShaped.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "body", null, null),
        HtmlNode(HtmlNodeKind.element, 0, "article", null,
            [HtmlAttribute("class", "post-content")]),
        HtmlNode(HtmlNodeKind.element, 1, "p", null, null),
        HtmlNode(HtmlNodeKind.text, 2, null, longParagraph),
        HtmlNode(HtmlNodeKind.element, 0, "div", null, [HtmlAttribute("id", "comments")]),
        HtmlNode(HtmlNodeKind.element, 4, "div", null, [HtmlAttribute("class", "commentEntry")]),
        HtmlNode(HtmlNodeKind.element, 5, "div", null,
            [HtmlAttribute("class", "commentContent"), HtmlAttribute("id", "comment-2310")]),
        HtmlNode(HtmlNodeKind.element, 6, "p", null, null),
        HtmlNode(HtmlNodeKind.text, 7, null, "First real reader comment."),
        HtmlNode(HtmlNodeKind.element, 4, "div", null,
            [HtmlAttribute("id", "comment-2311"), HtmlAttribute("class", "comment")]),
        HtmlNode(HtmlNodeKind.element, 9, "p", null, null),
        HtmlNode(HtmlNodeKind.text, 10, null, "Second real reader comment."),
    ];
    auto wpResult = extractMainContent(wordpressShaped);
    assert(wpResult.status == MainContentStatus.selected);
    assert(wpResult.node == 1, "the <article>, not the comments div, should still win");
    assert(!wpResult.text.canFind("reader comment"),
        "comment text must not leak into the selected main content");
    assert(wpResult.commentsExtracted, "a real comment section must be identified");
    assert(wpResult.comments.canFind("First real reader comment."));
    assert(wpResult.comments.canFind("Second real reader comment."));
    assert(!wpResult.comments.canFind("Article body sentence."),
        "main article text must not leak into the extracted comments");

    // A comment-free page (this fixture's own earlier `article` unittest
    // shape, re-checked here for the new fields specifically) must not
    // false-positive: no "comment"/"disqus"-keyword container anywhere.
    HtmlTree commentFree;
    commentFree.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "article", null, null),
        HtmlNode(HtmlNodeKind.element, 0, "p", null, null),
        HtmlNode(HtmlNodeKind.text, 1, null, longParagraph),
    ];
    auto freeResult = extractMainContent(commentFree);
    assert(freeResult.status == MainContentStatus.selected);
    assert(!freeResult.commentsExtracted, "a comment-free page must not false-positive");
    assert(freeResult.comments.length == 0);

    // www-tofugu-com.html's real shape: a "comments" *glyph* icon
    // (`<i class="fa fa-comments">`) inside nav chrome is not a comment
    // *section* -- `i` is not a block-container tag, so it must not be
    // misidentified as one, and no comments div exists on this page at all.
    HtmlTree commentGlyphOnly;
    commentGlyphOnly.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "article", null, null),
        HtmlNode(HtmlNodeKind.element, 0, "p", null, null),
        HtmlNode(HtmlNodeKind.text, 1, null, longParagraph),
        HtmlNode(HtmlNodeKind.element, 0, "nav", null, null),
        HtmlNode(HtmlNodeKind.element, 3, "a", null, null),
        HtmlNode(HtmlNodeKind.element, 4, "i", null, [HtmlAttribute("class", "fa fa-comments")]),
    ];
    auto glyphResult = extractMainContent(commentGlyphOnly);
    assert(!glyphResult.commentsExtracted,
        "a comment-count glyph icon must not be misidentified as a comment section");

    // france-attac-org.html's real shape: a comment section that is
    // structurally present (`<div class="comments">`) but carries no
    // comment text at all (its only children are two bare fragment-link
    // anchors) -- distinct from a genuinely comment-free page:
    // `commentsExtracted` is `true` (the section was found) even though
    // `.comments` is empty (there was nothing to read inside it).
    HtmlTree emptyCommentSection;
    emptyCommentSection.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "article", null, null),
        HtmlNode(HtmlNodeKind.element, 0, "p", null, null),
        HtmlNode(HtmlNodeKind.text, 1, null, longParagraph),
        HtmlNode(HtmlNodeKind.element, 0, "div", null, [HtmlAttribute("class", "comments")]),
        HtmlNode(HtmlNodeKind.element, 3, "a", null, [HtmlAttribute("id", "comments")]),
        HtmlNode(HtmlNodeKind.element, 3, "a", null, [HtmlAttribute("id", "forum")]),
    ];
    auto emptyResult = extractMainContent(emptyCommentSection);
    assert(emptyResult.commentsExtracted,
        "a structurally-present but textless comment section is still identified");
    assert(emptyResult.comments.length == 0,
        "there is nothing to read inside two bare fragment-link anchors");

    // A Disqus-style third-party embed container (issue-instructed, not
    // corpus-observed -- see `commentSectionKeywords`'s own doc comment):
    // `<div id="disqus_thread">` is Disqus's own standard embed id.
    HtmlTree disqusEmbed;
    disqusEmbed.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "article", null, null),
        HtmlNode(HtmlNodeKind.element, 0, "p", null, null),
        HtmlNode(HtmlNodeKind.text, 1, null, longParagraph),
        HtmlNode(HtmlNodeKind.element, 0, "div", null, [HtmlAttribute("id", "disqus_thread")]),
        HtmlNode(HtmlNodeKind.element, 3, "p", null, null),
        HtmlNode(HtmlNodeKind.text, 4, null, "A reader's Disqus-hosted reply."),
    ];
    auto disqusResult = extractMainContent(disqusEmbed);
    assert(disqusResult.commentsExtracted);
    assert(disqusResult.comments.canFind("A reader's Disqus-hosted reply."));

    // A <section>/<aside> comment container (the issue's own explicitly
    // named tag shapes, alongside <div>) is recognized the same way.
    HtmlTree asideComments;
    asideComments.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "article", null, null),
        HtmlNode(HtmlNodeKind.element, 0, "p", null, null),
        HtmlNode(HtmlNodeKind.text, 1, null, longParagraph),
        HtmlNode(HtmlNodeKind.element, 0, "aside", null, [HtmlAttribute("class", "comment-list")]),
        HtmlNode(HtmlNodeKind.element, 3, "p", null, null),
        HtmlNode(HtmlNodeKind.text, 4, null, "A comment inside an aside container."),
    ];
    auto asideResult = extractMainContent(asideComments);
    assert(asideResult.commentsExtracted);
    assert(asideResult.comments.canFind("A comment inside an aside container."));

    // `includeComments = false` (the opt-out flag, matching trafilatura's
    // own `--no-comments`) must suppress detection entirely, not merely
    // filter it out of the result: on the very same tree that positively
    // identifies comments above, passing `false` must report neither found.
    auto optedOut = extractMainContent(wordpressShaped, false);
    assert(optedOut.status == MainContentStatus.selected);
    assert(optedOut.node == 1, "opting out of comments must not change main-content selection");
    assert(!optedOut.commentsExtracted,
        "includeComments=false must suppress detection, not just filter the output");
    assert(optedOut.comments.length == 0);
}

// Issue #479: `ExtractionMode`'s two real, coordinated preset axes, proven
// here against hand-built `HtmlTree`s (independent of the native HTML
// parser, matching this file's own established unittest style). The real,
// corpus-grounded, real-pinned-trafilatura==2.2.0-corroborated evidence for
// both axes (`france-attac-org.html`'s real borderline lede for axis 1;
// `utopia-de.html`/`www-chemietechnik-de.html`'s real embedded share/ad
// elements for axis 2) lives in
// `experiments/html_main_content/precision_recall_check.d` and
// `docs/html-main-content.md`'s "Configurable precision/recall extraction
// mode" section, not duplicated here -- these fixtures exist to pin the
// mechanism itself precisely, the same division of labor this file's other
// unittest blocks already use against `experiments/html_main_content/check.d`'s
// own synthetic-fixture-only real proof.
unittest {
    import std.algorithm.searching : canFind;

    // Axis 1 (selection-floor multiplier): a winning candidate whose text is
    // just above the *standard* 200-byte floor but below `precision`'s
    // scaled 300-byte floor -- the same real shape
    // `france-attac-org.html`'s own lede has (score 510, text 210 bytes).
    string borderlineText;
    foreach (_; 0 .. 230) borderlineText ~= 'x'; // 230 bytes: > 200, < 300.
    HtmlTree borderline;
    borderline.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "article", null, null),
        HtmlNode(HtmlNodeKind.element, 0, "p", null, null),
        HtmlNode(HtmlNodeKind.text, 1, null, borderlineText),
    ];
    auto standardBorderline = extractMainContent(borderline, true, ExtractionMode.standard);
    assert(standardBorderline.status == MainContentStatus.selected,
        "standard must select this real-shaped borderline candidate");
    auto omittedBorderline = extractMainContent(borderline);
    assert(omittedBorderline.status == standardBorderline.status &&
        omittedBorderline.node == standardBorderline.node &&
        omittedBorderline.score == standardBorderline.score &&
        omittedBorderline.text == standardBorderline.text,
        "omitting `mode` must be byte-for-byte identical to explicit ExtractionMode.standard");

    auto precisionBorderline = extractMainContent(borderline, true, ExtractionMode.precision);
    assert(precisionBorderline.status == MainContentStatus.abstainedBelowThreshold,
        "precision's raised floor must abstain on the same candidate standard selects");
    assert(precisionBorderline.text.length == 0);

    auto recallBorderline = extractMainContent(borderline, true, ExtractionMode.recall);
    assert(recallBorderline.status == MainContentStatus.selected &&
        recallBorderline.node == standardBorderline.node &&
        recallBorderline.text == standardBorderline.text,
        "recall's lowered floor must never disqualify a candidate standard already selects");

    // Axis 1b (review round 2, finding 1): the fixture above only proves
    // "recall is a superset of standard" (never disqualifies what standard
    // already selects) -- it does NOT prove recall's lowered floor actually
    // ever *admits* a candidate standard/precision would reject, since 230
    // bytes clears every mode's floor except precision's. No real page in
    // this repo's current 20-page corpus has a top candidate sized strictly
    // between the `recall` and `standard` floors (confirmed: `recall`'s
    // output is byte-identical to `standard` on every page
    // `precision_recall_check.d`/`compare_precision_recall_trafilatura.sh`
    // exercise). This fixture is authored specifically to close that gap --
    // a candidate at 150 bytes: below `standard`'s 200-byte floor and
    // `precision`'s scaled 300-byte floor, but above `recall`'s scaled
    // 100-byte floor. Its score (490, from the wrapping `<article>`'s own
    // tag weight plus paragraph-clustering bonus) comfortably clears every
    // mode's score floor, isolating text length as the sole axis this
    // fixture tests. Mutation-testable: reverting `recallThresholdMultiplier`
    // to `1.0` (a no-op) raises `recall`'s floor back to 200 bytes, which
    // would make `admittedOnlyByRecall.status` below `abstainedBelowThreshold`
    // instead of `selected`, failing this assertion.
    string admittedOnlyByRecallText;
    foreach (_; 0 .. 150) admittedOnlyByRecallText ~= 'x'; // 150 bytes: > 100, < 200.
    HtmlTree admittedOnlyByRecallTree;
    admittedOnlyByRecallTree.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "article", null, null),
        HtmlNode(HtmlNodeKind.element, 0, "p", null, null),
        HtmlNode(HtmlNodeKind.text, 1, null, admittedOnlyByRecallText),
    ];
    auto standardRejectsWeak =
        extractMainContent(admittedOnlyByRecallTree, true, ExtractionMode.standard);
    assert(standardRejectsWeak.status == MainContentStatus.abstainedBelowThreshold,
        "standard must abstain on a 150-byte candidate (below its 200-byte floor)");
    auto precisionRejectsWeak =
        extractMainContent(admittedOnlyByRecallTree, true, ExtractionMode.precision);
    assert(precisionRejectsWeak.status == MainContentStatus.abstainedBelowThreshold,
        "precision must also abstain on the identical 150-byte candidate");
    auto admittedOnlyByRecall =
        extractMainContent(admittedOnlyByRecallTree, true, ExtractionMode.recall);
    assert(admittedOnlyByRecall.status == MainContentStatus.selected,
        "recall's lowered floor must actually admit a real candidate standard/precision reject, " ~
        "not merely never disqualify what standard already selects");
    assert(admittedOnlyByRecall.text.length == 150);

    // Axis 2 (text-collection sandwich-rule strictness): one fixture that
    // distinguishes all three modes at once. A keyword-neutral middle
    // paragraph sits between a negative-keyword-classed previous sibling
    // (`registration-banner__text`, issue #27's own real pattern) and a
    // keyword-neutral next sibling -- only ONE side is negative, so
    // `standard`'s "both sides" rule keeps it, `precision`'s "either side"
    // rule drops it, and `recall`'s disabled rule keeps it regardless.
    string longParagraph;
    foreach (_; 0 .. 25) longParagraph ~= "Article body sentence. ";
    HtmlTree sandwich;
    sandwich.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "article", null,
            [HtmlAttribute("class", "content")]),
        HtmlNode(HtmlNodeKind.element, 0, "p", null, null),
        HtmlNode(HtmlNodeKind.text, 1, null, longParagraph),
        HtmlNode(HtmlNodeKind.element, 0, "li", null, null),
        HtmlNode(HtmlNodeKind.element, 3, "p", null,
            [HtmlAttribute("class", "registration-banner__text")]),
        HtmlNode(HtmlNodeKind.text, 4, null, "Jetzt registrieren"),
        HtmlNode(HtmlNodeKind.element, 3, "p", null, null),
        HtmlNode(HtmlNodeKind.text, 6, null, "Neutral middle paragraph text."),
        HtmlNode(HtmlNodeKind.element, 3, "p", null, null),
        HtmlNode(HtmlNodeKind.text, 8, null, "Non-negative sibling text."),
    ];
    auto standardSandwich = extractMainContent(sandwich, true, ExtractionMode.standard);
    assert(standardSandwich.status == MainContentStatus.selected && standardSandwich.node == 0);
    assert(standardSandwich.text.canFind("Neutral middle paragraph text."),
        "standard's both-sides rule must keep a paragraph with only one negative neighbor");

    auto precisionSandwich = extractMainContent(sandwich, true, ExtractionMode.precision);
    assert(precisionSandwich.status == MainContentStatus.selected &&
        precisionSandwich.node == 0 && precisionSandwich.score == standardSandwich.score,
        "the sandwich rule must never change which node is selected or its score");
    assert(!precisionSandwich.text.canFind("Neutral middle paragraph text."),
        "precision's either-side rule must drop a paragraph with even one negative neighbor");
    assert(precisionSandwich.text.canFind("Article body sentence."),
        "precision must not touch real article text unrelated to the sandwich pattern");

    auto recallSandwich = extractMainContent(sandwich, true, ExtractionMode.recall);
    assert(recallSandwich.status == MainContentStatus.selected &&
        recallSandwich.node == 0 && recallSandwich.score == standardSandwich.score);
    assert(recallSandwich.text.canFind("Neutral middle paragraph text."),
        "recall's disabled sandwich rule must keep the same paragraph too");
    // recall never touches a node with its OWN outright negative keyword
    // match either way -- only the sandwich heuristic is disabled.
    assert(!recallSandwich.text.canFind("Jetzt registrieren"),
        "recall must still exclude a node with its own negative keyword match");
}

// Issue #517: block separation at sectioning/list/pre boundaries, and
// tag-level `<nav>` exclusion inside the selected subtree. Marker words are
// plain alphanumerics so no escaping can make a negative assertion vacuous.
unittest {
    import effects.html_tree : parseHtml;
    import std.algorithm.searching : canFind;

    // ~460 bytes of direct text, so the <div> itself outscores a child
    // <section>/<article>/<main>/<p> and its +300 positive-tag weight.
    string lede = "LedeStart the survey team spent three weeks mapping the river " ~
        "delta and recording water depth every two hundred meters along six " ~
        "transects while the main channel migrated nearly forty meters east " ~
        "since the previous survey was completed and the second leg of the " ~
        "survey repeated every one of those transects a month later to check " ~
        "how quickly the sandbars were moving after the spring floods had " ~
        "passed through the lower reaches of the delta LedeEnd";
    MainContentResult extract(string inner, ExtractionMode mode = ExtractionMode.standard) {
        auto outcome = parseHtml(cast(const(ubyte)[]) ("<html><body><div>" ~ lede ~
            inner ~ "</div></body></html>"));
        assert(outcome.isParsed);
        auto result = extractMainContent(outcome.tree, true, mode);
        assert(result.status == MainContentStatus.selected);
        assert(outcome.tree.nodes[result.node].name == "div",
            "the fixture's own <div> must be the selected node");
        return result;
    }

    // Separators: each of these tags used to glue onto "LedeEnd".
    foreach (tag; ["section", "article", "header", "footer", "aside", "main",
            "ul", "ol", "pre"]) {
        string inner = tag == "ul" || tag == "ol" ?
            "<" ~ tag ~ "><li>TailMarker words</li></" ~ tag ~ ">" :
            "<" ~ tag ~ ">TailMarker words</" ~ tag ~ ">";
        auto text = extract(inner).text;
        assert(text.canFind("LedeEnd\n\nTailMarker words"),
            "<" ~ tag ~ "> must start a new paragraph in .text, got: " ~ text);
        assert(!text.canFind("LedeEndTailMarker"), "<" ~ tag ~ "> text glued on");
    }
    // ...and the text after the boundary is a new block as well.
    auto after = extract("<section>InsideMarker</section>AfterMarker").text;
    assert(after.canFind("InsideMarker\n\nAfterMarker"), after);

    // Nav policy: a bare <nav> inside the selected subtree is dropped by tag,
    // in every extraction mode, like the existing class="nav" keyword rule.
    foreach (mode; [ExtractionMode.standard, ExtractionMode.precision,
            ExtractionMode.recall]) {
        auto navResult = extract("<nav>NavTagMarker Home About Contact</nav>" ~
            "<p>TrailingMarker</p>", mode);
        assert(!navResult.text.canFind("NavTagMarker"),
            "a <nav> descendant of the selected node leaked into .text");
        assert(navResult.text.canFind("LedeEnd") && navResult.text.canFind("TrailingMarker"),
            "real content around the <nav> must survive");
    }
    // A positive class does not rescue a <nav>: the tag decides, as it
    // already does for the scoring pass (`hasNegativeTagAncestor`).
    assert(!extract(`<nav class="post-content">NavTagMarker</nav>`).text.canFind("NavTagMarker"));
    // Other negative-scoring tags are kept once inside the winning subtree.
    assert(extract("<aside>AsideMarker</aside>").text.canFind("AsideMarker"));
    assert(extract("<header>HeaderMarker</header>").text.canFind("HeaderMarker"));
    assert(extract("<footer>FooterMarker</footer>").text.canFind("FooterMarker"));
    // The selected node itself is never excluded, even if it is a <nav>.
    auto navRoot = parseHtml(cast(const(ubyte)[]) ("<html><body><nav>" ~ lede ~
        "</nav></body></html>"));
    assert(navRoot.isParsed);
    auto navRootTree = navRoot.tree;
    size_t navIndex;
    foreach (i, ref node; navRootTree.nodes) if (node.name == "nav") navIndex = i;
    auto navCopy = selectedContentTree(navRootTree, navIndex);
    assert(navCopy.nodes.length == 2 && navCopy.nodes[0].name == "nav" &&
        navCopy.nodes[0].parentIndex == size_t.max && navCopy.nodes[1].parentIndex == 0);
}

// Issue #538: `keywordScoreFor`'s substring match was not word-boundary-aware,
// so `class="wp-block-heading"` scored as a negative-keyword match purely
// because "ad" is a substring of "heading" ("he-AD-ing") -- real content
// loss, confirmed on the pinned benchmark corpus page `utopia-de.html`,
// which drops two real `<h2 class="wp-block-heading">` section headings
// from both `.text` and the Markdown path before this fix. Fails before the
// fix (each class/id below scores negative purely from an unanchored
// substring hit) and passes after (word-boundary-aware: a keyword only
// counts when it is not touching another alphanumeric character on either
// side).
unittest {
    HtmlNode elementWithClass(string classValue) pure {
        return HtmlNode(HtmlNodeKind.element, size_t.max, "h2", null,
            [HtmlAttribute("class", classValue)]);
    }

    // The ticket's own real false positive, plus the other real,
    // non-boilerplate classes/ids it names that also contain "ad" as a
    // substring but never as a whole word.
    foreach (classValue; ["wp-block-heading", "headline", "shadow", "download", "gradient"]) {
        auto node = elementWithClass(classValue);
        assert(keywordScoreFor(node) == 0.0,
            `class="` ~ classValue ~ `" must not score as a negative-keyword match (#538)`);
    }

    auto idElement = HtmlNode(HtmlNodeKind.element, size_t.max, "div", null,
        [HtmlAttribute("id", "loaded")]);
    assert(keywordScoreFor(idElement) == 0.0,
        `id="loaded" must not score as a negative-keyword match (#538)`);

    // Genuine negative-keyword classes -- including ones where the keyword
    // is only a hyphen-delimited *part* of the class value, and one
    // (registration-banner) that is itself a hyphenated multi-word keyword
    // -- must still be excluded exactly as before. (A camelCase compound
    // like "commentEntry", with no non-alphanumeric delimiter at all between
    // "comment" and "Entry", is *not* included here: it is a real,
    // acknowledged tradeoff of word-boundary-aware matching -- shared by
    // both fix strategies this ticket names, token-splitting or a
    // boundary scan -- not a case this ticket's acceptance criteria
    // requires preserving.)
    foreach (classValue; ["nav", "site-nav", "sidebar", "sidebar-widget", "footer",
            "page-footer", "header", "site-header", "comment", "comment-list",
            "menu", "dropdown-menu", "ad", "ad-banner", "advert", "promo",
            "promo-block", "share", "share-buttons", "social", "social-links",
            "related", "related-posts", "widget", "breadcrumb",
            "breadcrumb-trail", "registration-banner"]) {
        auto node = elementWithClass(classValue);
        assert(keywordScoreFor(node) < 0.0,
            `class="` ~ classValue ~ `" must still score as a negative-keyword match`);
    }

    // Positive keywords share the same match, and are word-boundary-aware
    // for the same reason.
    auto contentNode = elementWithClass("content");
    auto articleBodyNode = elementWithClass("article-body");
    assert(keywordScoreFor(contentNode) > 0.0);
    assert(keywordScoreFor(articleBodyNode) > 0.0);
}

// Same issue, through the real DOM-selection path end to end: the false
// positive above must not silently drop real content out of either `.text`
// (`extractMainContent`) or the Markdown path (`selectedContentTree`, which
// both `.text` and `.markdown` read the same exclusion from).
unittest {
    import effects.html_tree : parseHtml;
    import std.algorithm.searching : canFind;

    string longParagraph;
    foreach (_; 0 .. 25) longParagraph ~= "Article body sentence. ";

    string html = `<html><body><article><h2 class="wp-block-heading">` ~
        `HeadingMarker Real Section Title</h2><p>` ~ longParagraph ~
        `</p></article></body></html>`;
    auto outcome = parseHtml(cast(const(ubyte)[]) html);
    assert(outcome.isParsed);
    auto result = extractMainContent(outcome.tree);
    assert(result.status == MainContentStatus.selected);
    assert(result.text.canFind("HeadingMarker Real Section Title"),
        `a <h2 class="wp-block-heading"> heading must not be dropped as a false ` ~
        `negative-keyword match on "ad" inside "heading" (#538)`);

    auto content = selectedContentTree(outcome.tree, result.node);
    bool headingKept;
    foreach (node; content.nodes)
        if (node.kind == HtmlNodeKind.element && node.name == "h2") headingKept = true;
    assert(headingKept, `wp-block-heading <h2> must survive selectedContentTree (#538)`);
}
