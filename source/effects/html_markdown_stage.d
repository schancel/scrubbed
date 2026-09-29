/// Concrete selected-tree Markdown stage; importing this module registers it.
module effects.html_markdown_stage;

import content.pieces : Content, ContentPiece;
import effects.html_tree : HtmlFailureReason, checkedHtmlByteLimit,
    defaultExtractHtmlBytes, parseHtml;
import effects.html_markdown : HtmlMarkdownOutputLimit, renderMarkdown;
import stages.contract : PassMode, ResourceDeclaration, StageDecision,
    StageDeclaration, StageDocument;
import stages.registry : ConfiguredStageTransform, HtmlOutputShape,
    OptionDeclaration, OptionType, StageConfiguration, StageOptions,
    StageRegistration, registerStage;
import std.conv : to;
import std.exception : enforce;

private string failureReason(HtmlFailureReason reason) pure {
    return reason.to!string;
}

private class HtmlMarkdownConfiguration : StageConfiguration {
    string charset;
    size_t byteLimit;
    this(string charset, size_t byteLimit) immutable {
        this.charset = charset;
        this.byteLimit = byteLimit;
    }
}

private StageDecision applyHtmlMarkdown(StageDocument input,
        immutable(StageConfiguration) configuration) pure {
    auto configured = cast(immutable(HtmlMarkdownConfiguration)) configuration;
    enforce(configured !is null, "invalid html-markdown configuration");
    auto charset = configured.charset;
    auto byteLimit = configured.byteLimit;
    if (input.content.size > byteLimit)
        return StageDecision.quarantine("rawLimit");
    auto raw = input.content.copy();
    auto outcome = parseHtml(raw, charset, input.document.source.recordKey, byteLimit);
    if (!outcome.isParsed) {
        auto failure = outcome.failure;
        auto reason = failureReason(failure.reason);
        if (failure.reason == HtmlFailureReason.decode) {
            reason ~= ":" ~ failure.decodeReason.to!string;
            if (failure.hasOffendingOffset)
                reason ~= "@" ~ failure.offendingOffset.to!string;
        }
        return StageDecision.quarantine(reason);
    }
    string markdown;
    try markdown = renderMarkdown(outcome.tree);
    catch (HtmlMarkdownOutputLimit) return StageDecision.quarantine("outputLimit");
    input.content = new Content([ContentPiece.own(cast(const(ubyte)[])markdown)]);
    return StageDecision.map(input);
}

private ConfiguredStageTransform factory(const ref StageOptions options) {
    auto chosen = "charset" in options;
    auto charset = chosen is null ? null : chosen.asText();
    auto configuredLimit = "max-html-bytes" in options;
    auto byteLimit = configuredLimit is null ? defaultExtractHtmlBytes :
        checkedHtmlByteLimit(configuredLimit.asInteger());
    return ConfiguredStageTransform(&applyHtmlMarkdown,
        new immutable HtmlMarkdownConfiguration(charset, byteLimit));
}

static this() {
    // Issue #447: parses `.content` as HTML and replaces it with rendered
    // Markdown -- a later HTML-consuming stage in the same pipeline must
    // not receive this stage's output as if it were still HTML.
    auto registration = StageRegistration(StageDeclaration("html-markdown",
        PassMode.singlePass, ResourceDeclaration(1, 32 * 1024 * 1024)),
        [OptionDeclaration("charset", OptionType.text),
         OptionDeclaration("max-html-bytes", OptionType.integer)], null, null, &factory);
    registration.requiresRawHtmlInput = true;
    registration.producesHtmlShape = HtmlOutputShape.nonHtml;
    registerStage(registration);
}

unittest {
    import composition.compiler : compileJob;
    import composition.executor : runCompiledStage;
    import domain.document : Document, OutputName, SourceLocator;
    import job.json : parseJobJson;
    import stages.contract : EventKind, StageDocument;
    import std.exception : enforce;

    auto spec = parseJobJson(`{"version":3,"stages":[{"id":` ~
        `"extract","implementation":"html-markdown","options":{},"filters":[]}]}`);
    auto plan = compileJob(spec);
    enforce(plan.stages.length == 1);
    auto document = Document(SourceLocator("local-html:v1", "/tmp", "a.html"),
        OutputName("a.html.md"));
    auto input = StageDocument(document,
        new Content([ContentPiece.own(cast(const(ubyte)[])"<p>hi</p>")]));
    auto result = runCompiledStage([input], plan.stages[0]);
    enforce(result.events.length == 1 && result.events[0].kind == EventKind.emitted);
    enforce(result.events[0].payload.document.id == document.id);
    string bytes;
    foreach (piece; result.events[0].payload.content.pieces())
        foreach (i; 0 .. piece.size) bytes ~= cast(char)piece.at(i);
    enforce(bytes == "hi\n");
}

// Issue #447 regression: `html-main-content` flattens HTML to plain text,
// so a pipeline that hands that output straight to `html-markdown` (which
// then parses it as if it were still HTML) must be refused at compile
// time, naming both stages, instead of silently producing the
// backslash-escaped garbage the original report observed (every literal
// `.`/`-` in the plain-text prose treated as Markdown syntax to escape).
unittest {
    import composition.compiler : compileJob;
    import effects.html_main_content_stage; // registers "html-main-content"
    import job.json : parseJobJson;
    import std.algorithm.searching : canFind;
    import std.exception : collectException;

    auto badChain = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"extract","implementation":"html-main-content","options":{},"filters":[]},` ~
        `{"id":"md","implementation":"html-markdown","options":{},"filters":[]}]}`);
    auto failure = collectException(compileJob(badChain));
    assert(failure !is null,
        "html-main-content -> html-markdown must be rejected at compile time");
    assert(failure.msg.canFind("md") && failure.msg.canFind("html-markdown"),
        "rejection must name the HTML-consuming stage");
    assert(failure.msg.canFind("extract") && failure.msg.canFind("html-main-content"),
        "rejection must name the non-HTML-producing stage");

    // The same shape must be tracked through an intervening passthrough
    // stage (html-metadata-annotate reads .content but never replaces it,
    // so it must not "launder" html-main-content's non-HTML output back
    // into looking safe for html-markdown).
    auto badChainThroughPassthrough = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"extract","implementation":"html-main-content","options":{},"filters":[]},` ~
        `{"id":"meta","implementation":"html-metadata-annotate","options":{},"filters":[]},` ~
        `{"id":"md","implementation":"html-markdown","options":{},"filters":[]}]}`);
    assert(collectException(compileJob(badChainThroughPassthrough)) !is null,
        "a passthrough stage between the two must not hide the shape mismatch");

    // The inverse, real-world-supported order (metadata annotation, an
    // HTML-preserving stage, ahead of the HTML-consuming selector) must
    // keep compiling -- this is exactly `clean-web-document`'s own chain.
    auto goodChain = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"meta","implementation":"html-metadata-annotate","options":{},"filters":[]},` ~
        `{"id":"extract","implementation":"html-main-content","options":{},"filters":[]}]}`);
    assert(collectException(compileJob(goodChain)) is null,
        "an HTML-preserving stage ahead of an HTML-consuming stage must still compile");

    // html-main-content as the very first stage: its "prior" shape is
    // whatever the caller's real input is, never second-guessed here.
    auto firstStage = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"extract","implementation":"html-main-content","options":{},"filters":[]}]}`);
    assert(collectException(compileJob(firstStage)) is null,
        "the first stage's input shape is never rejected");
}
