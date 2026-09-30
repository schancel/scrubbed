/// Concrete self-registering stages exposing `effects.extract_formats`'s
/// pure CSV/XML/XML-TEI serializers through `extract --format=csv|xml|
/// xml-tei` (issue #481, the last of #471's seven slices), mirroring
/// `html_markdown_stage.d`/`html_tree_json_stage.d`/`html_main_content_
/// markdown_stage.d`'s own already-established shape exactly: parse raw
/// HTML off `.content`, replace it with this stage's own non-HTML rendered
/// output, quarantine on a parse failure or an output-size cap. None of the
/// three formats here ever abstains the way `html-main-content`/`html-
/// main-content-markdown` can (like `html-markdown`/`html-tree-json`, they
/// always render *something* -- possibly an empty `<main>`/`<div
/// type="entry">`, or a CSV row with `"null"` in every content column -- for
/// a page `extractMainContent` cannot select from; see `extract_formats.d`'s
/// own abstention unittest). Three separate stages (rather than one
/// parameterized stage) mirror this codebase's own existing granularity --
/// one small concrete stage module per format -- deliberately kept in a
/// single file here since all three share the exact same shape and differ
/// only in which pure renderer they call.
module effects.extract_formats_stage;

import content.pieces : Content, ContentPiece;
import effects.extract_formats : csvRow, ExtractFormatOutputLimit, renderXml, renderXmlTei;
import effects.html_main_content : HtmlMainContentOutputLimit;
import effects.html_tree : HtmlFailure, HtmlFailureReason, checkedHtmlByteLimit,
    defaultExtractHtmlBytes, parseHtml;
import stages.contract : PassMode, ResourceDeclaration, StageDecision,
    StageDeclaration, StageDocument;
import stages.registry : ConfiguredStageTransform, HtmlOutputShape,
    OptionDeclaration, OptionType, StageConfiguration, StageOptions,
    StageRegistration, registerStage;
import std.conv : to;
import std.exception : enforce;

private class HtmlExtractFormatConfiguration : StageConfiguration {
    string charset;
    size_t byteLimit;
    this(string charset, size_t byteLimit) immutable {
        this.charset = charset;
        this.byteLimit = byteLimit;
    }
}

private string failureReason(const ref HtmlFailure failure) pure {
    auto reason = failure.reason.to!string;
    if (failure.reason == HtmlFailureReason.decode) {
        reason ~= ":" ~ failure.decodeReason.to!string;
        if (failure.hasOffendingOffset) reason ~= "@" ~ failure.offendingOffset.to!string;
    }
    return reason;
}

private ConfiguredStageTransform factoryFor(alias apply)(const ref StageOptions options) {
    auto chosen = "charset" in options;
    auto charset = chosen is null ? null : chosen.asText();
    auto configuredLimit = "max-html-bytes" in options;
    auto byteLimit = configuredLimit is null ? defaultExtractHtmlBytes :
        checkedHtmlByteLimit(configuredLimit.asInteger());
    return ConfiguredStageTransform(&apply,
        new immutable HtmlExtractFormatConfiguration(charset, byteLimit));
}

private void registerExtractFormatStage(string name,
        StageDecision function(StageDocument, immutable(StageConfiguration)) pure apply,
        ConfiguredStageTransform function(const ref StageOptions) makeFactory) {
    auto registration = StageRegistration(StageDeclaration(name,
        PassMode.singlePass, ResourceDeclaration(1, 32 * 1024 * 1024)),
        [OptionDeclaration("charset", OptionType.text),
         OptionDeclaration("max-html-bytes", OptionType.integer)], null, null, makeFactory);
    registration.requiresRawHtmlInput = true;
    registration.producesHtmlShape = HtmlOutputShape.nonHtml;
    registerStage(registration);
}

private StageDecision applyCsv(StageDocument input,
        immutable(StageConfiguration) configuration) pure {
    auto configured = cast(immutable(HtmlExtractFormatConfiguration)) configuration;
    enforce(configured !is null, "invalid html-csv configuration");
    if (input.content.size > configured.byteLimit) return StageDecision.quarantine("rawLimit");
    auto raw = input.content.copy();
    auto outcome = parseHtml(raw, configured.charset, input.document.source.recordKey,
        configured.byteLimit);
    if (!outcome.isParsed) return StageDecision.quarantine(failureReason(outcome.failure));
    string rendered;
    try rendered = csvRow(outcome.tree);
    catch (HtmlMainContentOutputLimit) return StageDecision.quarantine("outputLimit");
    catch (ExtractFormatOutputLimit) return StageDecision.quarantine("outputLimit");
    input.content = new Content([ContentPiece.own(cast(const(ubyte)[]) rendered)]);
    return StageDecision.map(input);
}

private StageDecision applyXml(StageDocument input,
        immutable(StageConfiguration) configuration) pure {
    auto configured = cast(immutable(HtmlExtractFormatConfiguration)) configuration;
    enforce(configured !is null, "invalid html-xml configuration");
    if (input.content.size > configured.byteLimit) return StageDecision.quarantine("rawLimit");
    auto raw = input.content.copy();
    auto outcome = parseHtml(raw, configured.charset, input.document.source.recordKey,
        configured.byteLimit);
    if (!outcome.isParsed) return StageDecision.quarantine(failureReason(outcome.failure));
    string rendered;
    try rendered = renderXml(outcome.tree);
    catch (HtmlMainContentOutputLimit) return StageDecision.quarantine("outputLimit");
    catch (ExtractFormatOutputLimit) return StageDecision.quarantine("outputLimit");
    input.content = new Content([ContentPiece.own(cast(const(ubyte)[]) rendered)]);
    return StageDecision.map(input);
}

private StageDecision applyXmlTei(StageDocument input,
        immutable(StageConfiguration) configuration) pure {
    auto configured = cast(immutable(HtmlExtractFormatConfiguration)) configuration;
    enforce(configured !is null, "invalid html-xml-tei configuration");
    if (input.content.size > configured.byteLimit) return StageDecision.quarantine("rawLimit");
    auto raw = input.content.copy();
    auto outcome = parseHtml(raw, configured.charset, input.document.source.recordKey,
        configured.byteLimit);
    if (!outcome.isParsed) return StageDecision.quarantine(failureReason(outcome.failure));
    string rendered;
    try rendered = renderXmlTei(outcome.tree);
    catch (HtmlMainContentOutputLimit) return StageDecision.quarantine("outputLimit");
    catch (ExtractFormatOutputLimit) return StageDecision.quarantine("outputLimit");
    input.content = new Content([ContentPiece.own(cast(const(ubyte)[]) rendered)]);
    return StageDecision.map(input);
}

static this() {
    registerExtractFormatStage("html-csv", &applyCsv, &factoryFor!applyCsv);
    registerExtractFormatStage("html-xml", &applyXml, &factoryFor!applyXml);
    registerExtractFormatStage("html-xml-tei", &applyXmlTei, &factoryFor!applyXmlTei);
}

unittest {
    import composition.compiler : compileJob;
    import composition.executor : runCompiledStage;
    import domain.document : Document, OutputName, SourceLocator;
    import job.json : parseJobJson;
    import stages.contract : EventKind;
    import std.algorithm.searching : canFind;

    string longParagraph;
    foreach (_; 0 .. 25) longParagraph ~= "Article body sentence. ";
    string html = "<nav>Home About Contact</nav>" ~
        "<article><h1>Title</h1><p>" ~ longParagraph ~ "</p></article>";

    foreach (implementation; ["html-csv", "html-xml", "html-xml-tei"]) {
        auto spec = parseJobJson(`{"version":3,"stages":[{"id":"extract",` ~
            `"implementation":"` ~ implementation ~ `","options":{},"filters":[]}]}`);
        auto plan = compileJob(spec);
        enforce(plan.stages.length == 1);
        auto document = Document(SourceLocator("local-html:v1", "/tmp", "a.html"),
            OutputName("a.html.out"));
        auto input = StageDocument(document, new Content([ContentPiece.own(cast(const(ubyte)[]) html)]));
        auto result = runCompiledStage([input], plan.stages[0]);
        enforce(result.events.length == 1 && result.events[0].kind == EventKind.emitted,
            implementation ~ " must emit on real content");
        string bytes;
        foreach (piece; result.events[0].payload.content.pieces())
            foreach (i; 0 .. piece.size) bytes ~= cast(char) piece.at(i);
        enforce(bytes.canFind("Article body sentence"),
            implementation ~ " must carry the real selected content");
        enforce(!bytes.canFind("Home") && !bytes.canFind("Contact"),
            implementation ~ " must not leak boilerplate nav text");
    }
}

// Issue #447: same HTML-output-shape refusal `html_markdown_stage.d` already
// proves for its own stage, exercised here for all three new stages -- each
// must be refused as the second half of a shape-changing pair chained after
// `html-main-content`'s flattened plain-text output.
unittest {
    import composition.compiler : compileJob;
    import effects.html_main_content_stage; // registers "html-main-content"
    import job.json : parseJobJson;
    import std.exception : collectException;

    foreach (implementation; ["html-csv", "html-xml", "html-xml-tei"]) {
        auto badChain = parseJobJson(`{"version":3,"stages":[` ~
            `{"id":"extract","implementation":"html-main-content","options":{},"filters":[]},` ~
            `{"id":"out","implementation":"` ~ implementation ~ `","options":{},"filters":[]}]}`);
        auto failure = collectException(compileJob(badChain));
        assert(failure !is null,
            "html-main-content -> " ~ implementation ~ " must be rejected at compile time");
    }
}
