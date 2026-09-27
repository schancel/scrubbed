/// Self-registering, self-contained, TERMINAL v3 stage (`topical-tags-extract`,
/// issue #167 next-slice contract): parses a document's own HTML exactly
/// once (`effects.html_tree.parseHtml`), extracts source-*declared* topical-
/// tag candidates from three evidence sources -- `<meta name="keywords">`,
/// the `rel="tag"` microformat (`<a rel="tag">` and `<link rel="tag">`), and
/// JSON-LD `<script type="application/ld+json">` schema.org `Article`
/// (`keywords`/`about`) -- maps them into `domain.topical_tags`'s frozen
/// `DeclaredObservation`/`DeclaredCandidate` shape via the unmodified
/// `canonicalizeDeclared`, and publishes the resulting `TopicalTagsAnnotation`
/// as this job's own `TerminalSideOutput`.
///
/// This slice is **declared-extraction only**: no controlled-vocabulary
/// inference is wired. `domain.topical_tags`'s only construction entry
/// point, `buildAnnotation`, unconditionally also runs `controlled-token-v1`
/// inference, so this stage calls it with a fixed, inert placeholder
/// `Vocabulary` (one topic, required only because `Vocabulary.build` rejects
/// zero topics) and `language = "und"`, which deterministically abstains
/// inference via `InferenceAbstention.unsupportedLanguage` (or, on a
/// genuinely empty/oversize page text, one of the other typed abstentions)
/// *before* the vocabulary is ever consulted -- the language gate precedes
/// vocabulary iteration in `inferControlledTokenV1`. This reuses the frozen
/// API exactly as written; the always-inert placeholder vocabulary literal
/// is a small, contained, accepted seam.
///
/// **Content-support signal.** Raw `<meta name="keywords">` extraction
/// surfaces SEO spam (keyword-stuffed tags never actually about the page).
/// This stage is terminal and self-parsing -- it is never sandwiched between
/// `html-metadata-annotate` and `html-main-content` in one job (structurally
/// impossible under `composition.compiler`'s admission rule; see below) --
/// so the only text available to check a candidate against is the whole
/// page's own visible text, concatenated from every `HtmlNodeKind.text` node
/// in the parsed tree (nav/boilerplate included, head and body alike). This
/// is deliberately named `pageTextSupport`, not "canonical-text support":
/// it is page-text support, narrower/broader in different ways than the
/// main-content-only canonical text `domain.topical_tags`'s own doc comment
/// refers to. The owner-approved additive `DeclaredEvidence` schema 1->2
/// bump (`support`/`contentMatchCount`) carries a bounded raw occurrence
/// count of a candidate's canonical token sequence in that page text -- no
/// BM25/TF-IDF/relevance formula, just a plain bounded count (see
/// `domain.topical_tags.DeclaredContentSupport`'s doc comment for why this
/// does not require re-deriving `evidenceDigest`).
///
/// **Architecture: terminal-stage placement (accepted, inherited
/// limitation).** The rich `TopicalTagsAnnotation` payload cannot travel
/// through `StageDocument.metadata` (the `html-metadata-annotate` ->
/// `document-metadata-publish` two-phase shape): `DocumentMetadata`'s
/// extension-field cap is 512 bytes and this annotation's own identity/
/// digest overhead alone is already close to that before any candidate; and
/// `composition.compiler`'s `compileJob` admits at most one
/// `SideOutputCapability.terminal`-producing stage per compiled job, which
/// must be last. So this stage is single, self-contained, and terminal --
/// the same shape as `stages.pii_four_class`, not the two-phase
/// `html-metadata-annotate` + `html-main-content` shape -- parsing its own
/// full HTML (head and body) independent of any prior stage's transform.
/// Being terminal, it can only ever be the pipeline's last stage, so "must
/// run before html-main-content" is satisfied by construction: it can never
/// run after `html-main-content` reduces `content` to plain text in the same
/// job (its own `parseHtml` would simply fail and quarantine).
///
/// **Accepted, not resolved here:** a single job cannot currently produce
/// both topical-tags output and PII-audit/document-metadata output at once
/// -- the same limitation `pii-four-class` vs. `document-metadata-publish`
/// already has today. This inherits, not resolves, that gap; a future
/// generic multi-sink redesign remains real, still-open successor work.
module effects.topical_tags_extract_stage;

import content.pieces : Content;
import domain.document : DocumentId;
import domain.topical_tags : DeclaredCandidate, DeclaredContentSupport,
    DeclaredEvidence, DeclaredObservation, MatchOptions, TopicalTagsAnnotation,
    Vocabulary, VocabularyTerm, VocabularyTopic, buildAnnotation,
    canonicalDisplay, canonicalKeyOf, canonicalizeDeclared, encodeTopicalTags,
    maxDeclaredCandidates, maxDeclaredContentMatchCount, maxDisplayBytes;
import effects.html_tree : HtmlFailureReason, HtmlNode, HtmlNodeKind, HtmlTree,
    checkedHtmlByteLimit, defaultExtractHtmlBytes, maxRawBytes, parseHtml;
import stages.contract : PassMode, ResourceDeclaration, StageDecision,
    StageDeclaration, StageDocument, TerminalSideOutput;
import stages.registry : ConfiguredStageTransform, FilterPlacement,
    OptionDeclaration, OptionType, SideOutputCapability, StageCardinality,
    StageConfiguration, StageOptions, StageRegistration, registerStage;
import std.conv : to;
import std.exception : enforce;
import std.json : JSONOptions, JSONType, JSONValue, parseJSON;
import std.string : indexOf;
import std.uni : unicode;
import std.utf : decode;

enum topicalTagsExtractStageKeyV1 = "topical-tags-extract";
enum topicalTagsExtractExtractorId = "topical-tags-extract:v1";
enum topicalTagsSideOutputKeyV1 = "topical-tags";
enum topicalTagsSideOutputSchemaV1 = "scrubbed-topical-tags-v2";
enum topicalTagsSideOutputSuffixV1 = ".topical-tags.bin";

private enum sourceRuleMetaKeywords = "meta.keywords";
private enum sourceRuleRelTag = "microformat.rel-tag";
private enum sourceRuleLdJsonKeywords = "ldjson.article.keywords";
private enum sourceRuleLdJsonAbout = "ldjson.article.about";

/// Explicit scope narrowing per the accepted contract: no deterministic,
/// bounded detection rule exists for visible category/tag navigation absent
/// an explicit `rel="tag"` microformat signal, so it is not extracted here.
/// JSON-LD scope is narrowed to `@type` exactly `"Article"` (string or array
/// containing it), never `NewsArticle`/`BlogPosting`/etc.
private enum ldJsonArticleType = "Article";

/// Aggregate ld+json bytes scanned per document, and JSON parse depth cap,
/// per the accepted contract.
private enum size_t maxLdJsonAggregateBytes = 128 * 1024;
private enum int maxLdJsonParseDepth = 32;

/// A fixed, always-inert placeholder vocabulary/options/language: this
/// slice defers controlled-vocabulary inference wiring entirely (see the
/// module doc comment).
private enum placeholderTopicId = "topical-tags-extract:placeholder-topic";
private enum placeholderTopicDisplay = "Placeholder Topic";
private enum placeholderTermId = "topical-tags-extract:placeholder-term";
private enum placeholderToken = "placeholder";
private enum placeholderLanguage = "und";

// ---------------------------------------------------------------------------
// `domain.topical_tags` predates the configured-stage pure function boundary
// and is not itself marked `pure`, mirroring `stages.pii_four_class`'s own
// `scanPiiPure`/`applyPiiPolicyPure` wrappers for exactly the same reason:
// these are deterministic, side-effect-free domain functions with no `pure`
// annotation on their declarations.
// ---------------------------------------------------------------------------

private string canonicalDisplayPure(string raw) pure @trusted {
    alias PureFn = string function(string) pure;
    return (cast(PureFn) &canonicalDisplay)(raw);
}

private string canonicalKeyOfPure(string canonicalDisplayValue) pure @trusted {
    alias PureFn = string function(string) pure;
    return (cast(PureFn) &canonicalKeyOf)(canonicalDisplayValue);
}

private Vocabulary buildVocabularyPure(const(VocabularyTopic)[] topics) pure @trusted {
    alias PureFn = Vocabulary function(const(VocabularyTopic)[]) pure;
    return (cast(PureFn) &Vocabulary.build)(topics);
}

private TopicalTagsAnnotation buildAnnotationPure(DocumentId documentId,
        const(ubyte)[] canonicalText, const(DeclaredObservation)[] declaredObservations,
        Vocabulary vocabulary, string language, MatchOptions options) pure @trusted {
    alias PureFn = TopicalTagsAnnotation function(DocumentId, const(ubyte)[],
        const(DeclaredObservation)[], Vocabulary, string, MatchOptions) pure;
    return (cast(PureFn) &buildAnnotation)(documentId, canonicalText,
        declaredObservations, vocabulary, language, options);
}

private ubyte[] encodeTopicalTagsPure(TopicalTagsAnnotation value) pure @trusted {
    alias PureFn = ubyte[] function(TopicalTagsAnnotation) pure;
    return (cast(PureFn) &encodeTopicalTags)(value);
}

// ---------------------------------------------------------------------------
// Local HTML-tree helpers. Owned here per the accepted contract's scope
// ("owns its own JSON-LD parsing, meta-keyword splitting, rel-tag walking,
// all local to this file") rather than importing `effects.html_metadata`'s
// private idioms.
// ---------------------------------------------------------------------------

private string attribute(const ref HtmlNode node, string name) pure {
    foreach (a; node.attributes) if (a.name == name) return a.value;
    return null;
}

/// Concatenates every text-node descendant of `nodeIndex`, walking each
/// text node's ancestor chain (the flat pre-order tree only stores a parent
/// link) -- the same ancestor-walk idiom `effects.html_metadata`'s own
/// head-membership check uses.
private string descendantText(const ref HtmlTree tree, size_t nodeIndex) pure {
    string result;
    foreach (node; tree.nodes) {
        if (node.kind != HtmlNodeKind.text) continue;
        bool descendant;
        for (size_t parent = node.parentIndex; parent != size_t.max;
                parent = tree.nodes[parent].parentIndex) {
            if (parent == nodeIndex) { descendant = true; break; }
        }
        if (descendant) result ~= node.text;
    }
    return result;
}

/// Direct (non-recursive) child text, for `<script>` bodies.
private string directChildText(const ref HtmlTree tree, size_t nodeIndex) pure {
    string result;
    foreach (i, node; tree.nodes)
        if (node.parentIndex == nodeIndex && node.kind == HtmlNodeKind.text)
            result ~= node.text;
    return result;
}

/// Splits on literal `,`/`;` (ASCII, safe to compare byte-wise against
/// otherwise-arbitrary valid UTF-8: continuation bytes are always >= 0x80).
private string[] splitKeywordList(string content) pure {
    if (content is null) return null;
    string[] pieces;
    size_t start;
    foreach (i, c; content) {
        if (c == ',' || c == ';') {
            pieces ~= content[start .. i];
            start = i + 1;
        }
    }
    pieces ~= content[start .. $];
    return pieces;
}

/// Fallback display candidate for a `rel="tag"` element with no usable text
/// (a `<link>`, or an `<a>` with empty text content): the href's last
/// non-empty path segment, with `-`/`_` loosened to spaces so the result
/// reads as a display value rather than a raw slug. Query/fragment and one
/// trailing slash are stripped first. Deliberately simple and bounded --
/// no percent-decoding, no unbounded heuristic.
private string hrefSlug(string href) pure {
    if (href is null) return null;
    auto queryAt = href.indexOf('?');
    if (queryAt >= 0) href = href[0 .. queryAt];
    auto fragmentAt = href.indexOf('#');
    if (fragmentAt >= 0) href = href[0 .. fragmentAt];
    while (href.length && href[$ - 1] == '/') href = href[0 .. $ - 1];
    size_t slashAt = href.length;
    for (size_t i = href.length; i > 0; --i)
        if (href[i - 1] == '/') { slashAt = i; break; }
    auto segment = slashAt < href.length ? href[slashAt .. $] : href;
    if (segment.length == 0) return null;
    char[] result = segment.dup;
    foreach (ref c; result) if (c == '-' || c == '_') c = ' ';
    return cast(string) result;
}

// ---------------------------------------------------------------------------
// Whole-token matching for the page-text content-support signal. Local and
// deliberately not shared with `domain.topical_tags`'s own private
// tokenizer: matching here is a plain bounded raw-occurrence count, not
// controlled-vocabulary inference.
// ---------------------------------------------------------------------------

private bool isTokenChar(dchar c) pure {
    static immutable letters = unicode("Letter");
    static immutable numbers = unicode("Number");
    return (c in letters) || (c in numbers);
}

/// Splits an already NFC-normalized, case-folded string (`canonicalKeyOf`'s
/// output) into whole Unicode letter/number token runs.
private string[] wholeTokens(string canonicalKeyText) pure {
    string[] tokens;
    size_t tokenStart = size_t.max;
    size_t at;
    while (at < canonicalKeyText.length) {
        auto start = at;
        dchar c = decode(canonicalKeyText, at);
        if (isTokenChar(c)) {
            if (tokenStart == size_t.max) tokenStart = start;
        } else if (tokenStart != size_t.max) {
            tokens ~= canonicalKeyText[tokenStart .. start];
            tokenStart = size_t.max;
        }
    }
    if (tokenStart != size_t.max) tokens ~= canonicalKeyText[tokenStart .. $];
    return tokens;
}

/// Bounded count of contiguous, in-order occurrences of `candidateTokens`
/// within `pageTokens` -- adjacent-token matching, not a naive substring
/// search: "tax" and "return" only count together when they are adjacent
/// document tokens in that order.
private uint countTokenSequenceOccurrences(const(string)[] pageTokens,
        const(string)[] candidateTokens) pure {
    if (candidateTokens.length == 0 || pageTokens.length < candidateTokens.length)
        return 0;
    uint count;
    foreach (i; 0 .. pageTokens.length - candidateTokens.length + 1) {
        bool matched = true;
        foreach (k; 0 .. candidateTokens.length)
            if (pageTokens[i + k] != candidateTokens[k]) { matched = false; break; }
        if (matched && count < maxDeclaredContentMatchCount) ++count;
    }
    return count;
}

/// Attaches `support`/`contentMatchCount` to each already-canonicalized
/// declared candidate by checking its canonical token sequence against the
/// page's own text. Every candidate is resolved to `supported` or
/// `unsupported` -- a real check always runs here, so `unchecked` is left
/// only if the page text itself cannot be canonicalized (a defensive
/// fallback: every page-text byte was already UTF-8-validated while
/// building the restricted HTML tree).
private void attachContentSupport(ref TopicalTagsAnnotation annotation, string pageText) pure {
    string pageKey;
    try pageKey = canonicalKeyOfPure(canonicalDisplayPure(pageText));
    catch (Exception) return;
    auto pageTokens = wholeTokens(pageKey);
    foreach (ref candidate; annotation.declared) {
        auto candidateTokens = wholeTokens(candidate.canonicalKey);
        auto matches = countTokenSequenceOccurrences(pageTokens, candidateTokens);
        candidate.evidence.support = matches != 0 ?
            DeclaredContentSupport.supported : DeclaredContentSupport.unsupported;
        candidate.evidence.contentMatchCount = matches;
    }
}

// ---------------------------------------------------------------------------
// Extraction: one forward pass over the parsed tree.
// ---------------------------------------------------------------------------

private struct ExtractionResult {
    DeclaredObservation[] observations;
    string pageText;
}

/// Extracts declared observations from all three evidence sources plus the
/// page's own concatenated visible text, in one pass over `tree.nodes`
/// (document order). A single malformed evidence item (an overlong/invalid
/// display candidate, invalid ld+json syntax, a non-object/non-string
/// `about` entry, an oversize ld+json aggregate) is skipped, never fatal to
/// the whole document. Extraction caps itself at `maxDeclaredCandidates`,
/// truncating extras in this fixed document order, rather than handing
/// `canonicalizeDeclared` a batch its own `enforce` would reject outright.
private ExtractionResult extractDeclaredObservations(const ref HtmlTree tree) pure {
    ExtractionResult result;
    size_t head = size_t.max;
    foreach (i, node; tree.nodes)
        if (node.kind == HtmlNodeKind.element && node.name == "head") { head = i; break; }
    size_t ldJsonBytesScanned;

    void addRaw(string rawText, string sourceRuleId, size_t sourceNode) {
        if (rawText is null) return;
        if (result.observations.length >= maxDeclaredCandidates) return;
        string canonical;
        try canonical = canonicalDisplayPure(rawText);
        catch (Exception) return;
        if (canonical.length == 0 || canonical.length > maxDisplayBytes) return;
        result.observations ~= DeclaredObservation(rawText, null, sourceRuleId,
            topicalTagsExtractExtractorId, sourceNode);
    }

    bool isArticleType(ref JSONValue root) {
        auto typeField = "@type" in root.object;
        if (typeField is null) return false;
        if (typeField.type == JSONType.string) return typeField.str == ldJsonArticleType;
        if (typeField.type == JSONType.array) {
            foreach (entry; typeField.array)
                if (entry.type == JSONType.string && entry.str == ldJsonArticleType) return true;
        }
        return false;
    }

    void addKeywordsField(ref JSONValue value, size_t nodeIndex) {
        if (value.type == JSONType.string) {
            foreach (piece; splitKeywordList(value.str))
                addRaw(piece, sourceRuleLdJsonKeywords, nodeIndex);
        } else if (value.type == JSONType.array) {
            foreach (entry; value.array)
                if (entry.type == JSONType.string)
                    addRaw(entry.str, sourceRuleLdJsonKeywords, nodeIndex);
        }
    }

    void addAboutField(ref JSONValue value, size_t nodeIndex) {
        if (value.type != JSONType.array) return;
        foreach (entry; value.array) {
            if (entry.type == JSONType.string) {
                addRaw(entry.str, sourceRuleLdJsonAbout, nodeIndex);
            } else if (entry.type == JSONType.object) {
                auto nameField = "name" in entry.object;
                if (nameField !is null && nameField.type == JSONType.string)
                    addRaw(nameField.str, sourceRuleLdJsonAbout, nodeIndex);
            }
            // Any other entry shape (number, bool, null, array) is a single
            // malformed evidence item: skipped, not fatal.
        }
    }

    void handleLdJsonScript(size_t nodeIndex) {
        auto scriptText = directChildText(tree, nodeIndex);
        if (scriptText.length == 0) return;
        if (ldJsonBytesScanned + scriptText.length > maxLdJsonAggregateBytes) return;
        ldJsonBytesScanned += scriptText.length;
        JSONValue root;
        try root = parseJSON(scriptText, maxLdJsonParseDepth, JSONOptions.strictParsing);
        catch (Exception) return; // invalid JSON syntax: skip this block only
        if (root.type != JSONType.object || !isArticleType(root)) return;
        if (auto keywordsField = "keywords" in root.object) addKeywordsField(*keywordsField, nodeIndex);
        if (auto aboutField = "about" in root.object) addAboutField(*aboutField, nodeIndex);
    }

    foreach (i, node; tree.nodes) {
        if (node.kind == HtmlNodeKind.text) { result.pageText ~= node.text; continue; }
        if (node.name == "meta") {
            bool inHead = i == head;
            for (size_t parent = node.parentIndex; !inHead && parent != size_t.max;
                    parent = tree.nodes[parent].parentIndex) inHead = parent == head;
            if (inHead && attribute(node, "name") == "keywords")
                foreach (piece; splitKeywordList(attribute(node, "content")))
                    addRaw(piece, sourceRuleMetaKeywords, i);
        } else if (node.name == "a" && attribute(node, "rel") == "tag") {
            auto text = descendantText(tree, i);
            addRaw(text.length ? text : hrefSlug(attribute(node, "href")), sourceRuleRelTag, i);
        } else if (node.name == "link" && attribute(node, "rel") == "tag") {
            addRaw(hrefSlug(attribute(node, "href")), sourceRuleRelTag, i);
        } else if (node.name == "script" && attribute(node, "type") == "application/ld+json") {
            handleLdJsonScript(i);
        }
    }
    return result;
}

// ---------------------------------------------------------------------------
// Stage wiring.
// ---------------------------------------------------------------------------

private class TopicalTagsExtractConfiguration : StageConfiguration {
    string charset;
    size_t byteLimit;
    this(string charset, size_t byteLimit) immutable {
        this.charset = charset;
        this.byteLimit = byteLimit;
    }
}

/// A quarantined decision carries no extracted annotation, but this stage's
/// `SideOutputCapability.terminal` registration requires every event --
/// quarantined ones included -- to carry exactly one `TerminalSideOutput`
/// (`composition.executor.validateCapabilities` enforces this
/// unconditionally). Mirrors `effects.html_metadata_stage`'s own
/// `quarantinedMetadataSideOutput` placeholder for exactly the same reason;
/// this placeholder is never read once a caller branches on quarantine.
private TerminalSideOutput quarantinedTopicalTagsSideOutput() pure {
    return TerminalSideOutput(topicalTagsSideOutputKeyV1,
        topicalTagsSideOutputSchemaV1, topicalTagsSideOutputSuffixV1, null);
}

private StageDecision applyTopicalTagsExtract(StageDocument input,
        immutable(StageConfiguration) configuration) pure {
    auto configured = cast(immutable(TopicalTagsExtractConfiguration)) configuration;
    enforce(configured !is null, "invalid topical-tags-extract configuration");
    if (input.content.size > configured.byteLimit)
        return StageDecision.quarantine("rawLimit", [quarantinedTopicalTagsSideOutput()]);
    auto raw = input.content.copy();
    auto outcome = parseHtml(raw, configured.charset, input.document.source.recordKey,
        configured.byteLimit);
    if (!outcome.isParsed) {
        auto failure = outcome.failure;
        auto reason = failure.reason.to!string;
        if (failure.reason == HtmlFailureReason.decode) {
            reason ~= ":" ~ failure.decodeReason.to!string;
            if (failure.hasOffendingOffset) reason ~= "@" ~ failure.offendingOffset.to!string;
        }
        return StageDecision.quarantine(reason, [quarantinedTopicalTagsSideOutput()]);
    }
    try {
        auto extracted = extractDeclaredObservations(outcome.tree);
        auto vocabulary = buildVocabularyPure([VocabularyTopic(placeholderTopicId,
            placeholderTopicDisplay, [], [VocabularyTerm(placeholderTermId, [placeholderToken])])]);
        auto annotation = buildAnnotationPure(input.document.id,
            cast(const(ubyte)[]) extracted.pageText, extracted.observations, vocabulary,
            placeholderLanguage, MatchOptions(1000, 1));
        attachContentSupport(annotation, extracted.pageText);
        auto payload = encodeTopicalTagsPure(annotation);
        auto sideOutput = TerminalSideOutput(topicalTagsSideOutputKeyV1,
            topicalTagsSideOutputSchemaV1, topicalTagsSideOutputSuffixV1, payload);
        return StageDecision.map(input, [sideOutput]);
    } catch (Exception) {
        // A genuine internal-invariant failure in this stage's own mapping
        // code (not a per-item extraction issue -- those are pre-filtered
        // above and never reach `canonicalizeDeclared`/`checkTopicalTags`).
        // Mirrors `html-main-content`'s `catch (HtmlMainContentOutputLimit)`
        // defensive-quarantine pattern.
        return StageDecision.quarantine("annotationBuildFailure",
            [quarantinedTopicalTagsSideOutput()]);
    }
}

private ConfiguredStageTransform factory(const ref StageOptions options) {
    auto chosen = "charset" in options;
    auto charset = chosen is null ? null : chosen.asText();
    auto configuredLimit = "max-html-bytes" in options;
    auto byteLimit = configuredLimit is null ? defaultExtractHtmlBytes :
        checkedHtmlByteLimit(configuredLimit.asInteger());
    return ConfiguredStageTransform(&applyTopicalTagsExtract,
        new immutable TopicalTagsExtractConfiguration(charset, byteLimit));
}

static this() {
    registerStage(StageRegistration(StageDeclaration(topicalTagsExtractStageKeyV1,
        PassMode.singlePass, ResourceDeclaration(1, 32 * 1024 * 1024)),
        [OptionDeclaration("charset", OptionType.text),
         OptionDeclaration("max-html-bytes", OptionType.integer)], null, null, &factory,
        FilterPlacement.none, StageCardinality.oneToOne, SideOutputCapability.terminal));
}

// ---------------------------------------------------------------------------
// Unit tests. Fixture numbers reference the accepted contract's "Acceptance
// criteria and fixtures" list.
// ---------------------------------------------------------------------------

version (unittest) {
    import composition.compiler : compileJob;
    import composition.executor : runCompiledStage;
    import crypto.sha256 : sha256Of;
    import domain.document : Document, OutputName, SourceLocator;
    import domain.topical_tags : decodeTopicalTags;
    import job.json : parseJobJson;
    import stages.contract : EventKind, StageEvent;

    private Document fixtureDocument() {
        return Document(SourceLocator("local-html:v1", "/tmp", "a.html"), OutputName("a.html.tags"));
    }

    private ubyte[32] fixtureTextRevision(string html, size_t byteLimit = maxRawBytes) {
        auto outcome = parseHtml(cast(const(ubyte)[]) html, null, "", byteLimit);
        assert(outcome.isParsed);
        auto extracted = extractDeclaredObservations(outcome.tree);
        return sha256Of(cast(const(ubyte)[]) extracted.pageText);
    }

    /// Runs the real self-registered stage through `compileJob` +
    /// `runCompiledStage` -- the actual registry/executor path, not a direct
    /// call into a private function.
    private StageEvent runTopicalTagsExtract(string html, string jobOptionsJson = "{}") {
        auto spec = parseJobJson(`{"version":3,"stages":[{"id":"extract",` ~
            `"implementation":"` ~ topicalTagsExtractStageKeyV1 ~ `",` ~
            `"options":` ~ jobOptionsJson ~ `,"filters":[]}]}`);
        auto plan = compileJob(spec);
        auto input = StageDocument(fixtureDocument(),
            new Content([ContentPiece.own(cast(const(ubyte)[]) html)]));
        auto result = runCompiledStage([input], plan.stages[0]);
        assert(result.events.length == 1);
        return result.events[0];
    }

    private TopicalTagsAnnotation decodedAnnotation(StageEvent event, string html,
            size_t byteLimit = maxRawBytes) {
        assert(event.kind == EventKind.emitted);
        assert(event.sideOutputs.length == 1);
        auto sideOutput = event.sideOutputs[0];
        assert(sideOutput.key == topicalTagsSideOutputKeyV1);
        return decodeTopicalTags(sideOutput.bytes, fixtureDocument().id,
            fixtureTextRevision(html, byteLimit));
    }

    private const(DeclaredCandidate) findDeclared(const(DeclaredCandidate)[] declared, string key) {
        foreach (candidate; declared) if (candidate.canonicalKey == key) return candidate;
        assert(false, "no declared candidate with key " ~ key);
    }

    import content.pieces : ContentPiece;
}

// Fixture 1a: meta-keywords only.
unittest {
    auto html = `<html><head><meta name="keywords" content="Cooking, Baking , recipes"></head>` ~
        `<body><p>An article about cooking.</p></body></html>`;
    auto event = runTopicalTagsExtract(html);
    auto annotation = decodedAnnotation(event, html);
    assert(annotation.declared.length == 3);
    assert(annotation.identity.hasEvidence);
    foreach (candidate; annotation.declared)
        assert(candidate.evidence.sourceRuleId == sourceRuleMetaKeywords);
    assert(annotation.declared[0].displayValue == "Cooking");
    assert(annotation.declared[1].displayValue == "Baking");
    assert(annotation.declared[2].displayValue == "recipes");
}

// Fixture 1b: rel="tag" only, both `<a>` and `<link>` variants.
unittest {
    auto html = `<html><head><link rel="tag" href="/tags/baking"></head>` ~
        `<body><a rel="tag" href="/tags/cooking">Cooking</a></body></html>`;
    auto event = runTopicalTagsExtract(html);
    auto annotation = decodedAnnotation(event, html);
    assert(annotation.declared.length == 2);
    foreach (candidate; annotation.declared)
        assert(candidate.evidence.sourceRuleId == sourceRuleRelTag);
    assert(findDeclared(annotation.declared, "baking").displayValue == "baking");
    assert(findDeclared(annotation.declared, "cooking").displayValue == "Cooking");
}

// Fixture 1c: JSON-LD Article `keywords`/`about` only.
unittest {
    auto html = `<html><head><script type="application/ld+json">` ~
        `{"@type":"Article","keywords":"Cooking, Baking",` ~
        `"about":[{"@type":"Thing","name":"Recipes"},"Kitchen"]}` ~
        `</script></head><body><p>Text.</p></body></html>`;
    auto event = runTopicalTagsExtract(html);
    auto annotation = decodedAnnotation(event, html);
    assert(annotation.declared.length == 4);
    assert(findDeclared(annotation.declared, "cooking").evidence.sourceRuleId == sourceRuleLdJsonKeywords);
    assert(findDeclared(annotation.declared, "baking").evidence.sourceRuleId == sourceRuleLdJsonKeywords);
    assert(findDeclared(annotation.declared, "recipes").evidence.sourceRuleId == sourceRuleLdJsonAbout);
    assert(findDeclared(annotation.declared, "kitchen").evidence.sourceRuleId == sourceRuleLdJsonAbout);
}

// Fixture 2 & 3: all three sources combined, overlapping/duplicate tags
// across sources including conflicting spelling/casing ("Cooking" /
// "cooking" / "COOKING ").
unittest {
    auto html = `<html><head>` ~
        `<meta name="keywords" content="Cooking">` ~
        `<script type="application/ld+json">{"@type":"Article","keywords":"COOKING "}</script>` ~
        `</head><body><a rel="tag" href="/tags/cooking">cooking</a></body></html>`;
    auto event = runTopicalTagsExtract(html);
    auto annotation = decodedAnnotation(event, html);
    assert(annotation.declared.length == 3);
    assert(!annotation.declared[0].duplicateKey);
    assert(annotation.declared[1].duplicateKey);
    assert(annotation.declared[2].duplicateKey);
    assert(annotation.declared[0].evidence.sourceRuleId == sourceRuleMetaKeywords);
    assert(annotation.declared[1].evidence.sourceRuleId == sourceRuleLdJsonKeywords);
    assert(annotation.declared[2].evidence.sourceRuleId == sourceRuleRelTag);
    assert(annotation.declared[0].displayValue == "Cooking");
    assert(annotation.declared[1].displayValue == "COOKING");
    assert(annotation.declared[2].displayValue == "cooking");
}

// Fixture 4: malformed JSON-LD does not quarantine and does not stop other
// evidence from being extracted; wrong `@type` is not picked up; a
// non-object/non-string `about` entry is skipped; an oversize ld+json block
// (beyond the 128 KiB aggregate cap) is skipped, not fatal.
unittest {
    string oversizePayload = "\"about\":[";
    foreach (i; 0 .. 40_000) oversizePayload ~= (i ? ",\"x\"" : "\"x\"");
    oversizePayload ~= "]";
    auto html = `<html><head>` ~
        `<meta name="keywords" content="Widgets">` ~
        `<script type="application/ld+json">{not valid json at all</script>` ~
        `<script type="application/ld+json">{"@type":"NewsArticle","keywords":"ShouldNotAppear"}</script>` ~
        `<script type="application/ld+json">{"@type":"Article","about":[{"name":"ValidThing"},42,"AlsoValid"]}</script>` ~
        `<script type="application/ld+json">{"@type":"Article",` ~ oversizePayload ~ `}</script>` ~
        `</head><body><p>Some widgets and things text.</p></body></html>`;
    auto event = runTopicalTagsExtract(html, `{"max-html-bytes":1048576}`);
    assert(event.kind == EventKind.emitted, "malformed/oversize ld+json must not quarantine");
    auto annotation = decodedAnnotation(event, html, 1_048_576);
    bool[string] keys;
    foreach (candidate; annotation.declared) keys[candidate.canonicalKey] = true;
    assert(("widgets" in keys) !is null);
    assert(("validthing" in keys) !is null);
    assert(("alsovalid" in keys) !is null);
    assert(("shouldnotappear" in keys) is null, "NewsArticle must not be picked up");
    assert(("x" in keys) is null, "oversize ld+json block must be skipped");
}

// Fixture 5: absent evidence entirely succeeds with empty declared,
// `hasEvidence == false`, not quarantined.
unittest {
    auto html = `<html><head><title>No tags here</title></head>` ~
        `<body><p>Just an ordinary article with no tag evidence at all.</p></body></html>`;
    auto event = runTopicalTagsExtract(html);
    assert(event.kind == EventKind.emitted);
    auto annotation = decodedAnnotation(event, html);
    assert(annotation.declared.length == 0);
    assert(!annotation.identity.hasEvidence);
}

// Fixture 6: SEO-spam case. A keyword that never appears in the page's own
// visible text is still surfaced as a real declared candidate, never
// dropped, with `support == unsupported` and `contentMatchCount == 0`.
unittest {
    auto html = `<html><head><meta name="keywords" content="Nonexistent Topic"></head>` ~
        `<body><p>This page is actually about something else entirely.</p></body></html>`;
    auto event = runTopicalTagsExtract(html);
    auto annotation = decodedAnnotation(event, html);
    assert(annotation.declared.length == 1);
    assert(annotation.declared[0].evidence.support == DeclaredContentSupport.unsupported);
    assert(annotation.declared[0].evidence.contentMatchCount == 0);
}

// Fixture 7: genuine case. Declared tags that do appear -- verbatim and via
// normalized-equivalent casing/whitespace -- resolve to `support ==
// supported` with a correct nonzero `contentMatchCount`, including a
// multi-token candidate that requires adjacent-token matching (not a naive
// substring search).
unittest {
    auto html = `<html><head><meta name="keywords" content="cooking, Tax Return, personal finance"></head>` ~
        `<body><p>This COOKING guide explains how to file your tax return early. ` ~
        `Cooking well is a form of personal   finance too, and cooking again helps.</p></body></html>`;
    auto event = runTopicalTagsExtract(html);
    auto annotation = decodedAnnotation(event, html);
    auto cooking = findDeclared(annotation.declared, "cooking");
    assert(cooking.evidence.support == DeclaredContentSupport.supported);
    assert(cooking.evidence.contentMatchCount == 3);
    auto taxReturn = findDeclared(annotation.declared, "tax return");
    assert(taxReturn.evidence.support == DeclaredContentSupport.supported);
    assert(taxReturn.evidence.contentMatchCount == 1);
    // "tax" and "return" alone are not adjacent anywhere else in the page,
    // so a naive substring/independent-word search would overcount this.
    auto personalFinance = findDeclared(annotation.declared, "personal finance");
    assert(personalFinance.evidence.support == DeclaredContentSupport.supported);
    assert(personalFinance.evidence.contentMatchCount == 1);
}

// Fixture 8: rel-tag anchor with empty text content falls back to the
// href-derived slug.
unittest {
    auto html = `<html><body><a rel="tag" href="/tags/machine-learning"></a></body></html>`;
    auto event = runTopicalTagsExtract(html);
    auto annotation = decodedAnnotation(event, html);
    assert(annotation.declared.length == 1);
    assert(annotation.declared[0].displayValue == "machine learning");
    assert(annotation.declared[0].evidence.sourceRuleId == sourceRuleRelTag);
}

// Fixture 9: deterministic ordering -- re-running extraction on the same
// document produces byte-identical encoded output.
unittest {
    auto html = `<html><head><meta name="keywords" content="Alpha, Beta, Gamma">` ~
        `<script type="application/ld+json">{"@type":"Article","about":["Delta"]}</script>` ~
        `</head><body><a rel="tag" href="/tags/epsilon">Epsilon</a>` ~
        `<p>Alpha appears here, plus beta and gamma and delta and epsilon.</p></body></html>`;
    auto first = runTopicalTagsExtract(html);
    auto second = runTopicalTagsExtract(html);
    assert(first.kind == EventKind.emitted && second.kind == EventKind.emitted);
    assert(first.sideOutputs[0].bytes == second.sideOutputs[0].bytes);
}

// Fixture 10: more than 64 total declared candidates across all sources --
// the stage caps its own extraction at 64 before calling
// `canonicalizeDeclared`, deterministically truncating extras, rather than
// letting `canonicalizeDeclared`'s own cap enforcement throw.
unittest {
    string[] tags;
    foreach (i; 0 .. 100) tags ~= "tag" ~ i.to!string;
    import std.array : join;
    auto html = `<html><head><meta name="keywords" content="` ~ tags.join(",") ~
        `"></head><body><p>Many tags.</p></body></html>`;
    auto outcome = parseHtml(cast(const(ubyte)[]) html);
    assert(outcome.isParsed);
    auto extracted = extractDeclaredObservations(outcome.tree);
    assert(extracted.observations.length == maxDeclaredCandidates);
    assert(extracted.observations[0].displayValue == "tag0");
    assert(extracted.observations[$ - 1].displayValue == "tag" ~ (maxDeclaredCandidates - 1).to!string);

    auto event = runTopicalTagsExtract(html);
    assert(event.kind == EventKind.emitted, "candidate overflow must not quarantine");
    auto annotation = decodedAnnotation(event, html);
    assert(annotation.declared.length == maxDeclaredCandidates);
}

// Reachability: the stage is genuinely self-registering (importing this
// module is enough) and a job consisting of only this terminal stage
// compiles and runs, matching the terminal-stage-alone framing.
unittest {
    auto spec = parseJobJson(`{"version":3,"stages":[{"id":"extract",` ~
        `"implementation":"` ~ topicalTagsExtractStageKeyV1 ~ `","options":{},"filters":[]}]}`);
    auto plan = compileJob(spec);
    assert(plan.stages.length == 1);
    assert(plan.stages[0].sideOutputCapability == SideOutputCapability.terminal);
    auto html = `<html><head><meta name="keywords" content="Solo"></head><body><p>Solo.</p></body></html>`;
    auto input = StageDocument(fixtureDocument(),
        new Content([ContentPiece.own(cast(const(ubyte)[]) html)]));
    auto result = runCompiledStage([input], plan.stages[0]);
    assert(result.events.length == 1 && result.events[0].kind == EventKind.emitted);
}

// HTML parse failure quarantines, same reason-mapping idiom as sibling
// HTML-parsing stages.
unittest {
    // The stage's own default byte limit is `defaultExtractHtmlBytes` (1 MiB),
    // not `effects.html_tree.parseHtml`'s smaller internal default.
    string oversize;
    foreach (_; 0 .. defaultExtractHtmlBytes + 1) oversize ~= "a";
    auto event = runTopicalTagsExtract(oversize);
    assert(event.kind == EventKind.quarantined);
    assert(event.reason == "rawLimit");
}
