/// Concrete self-registering stage that exposes issue #335 Slice 2's
/// library-level `effects.html_main_content_markdown.extractMainContentMarkdown`
/// combinator through the `extract` command (issue #431), the way
/// `html_main_content_stage.d` and `html_markdown_stage.d` already expose
/// their respective pure modules. That combinator itself is unchanged: it
/// runs `extractMainContent`'s selection exactly as `html-main-content`
/// does, then renders only the winning subtree as Markdown via
/// `renderMarkdownFrom` -- the same renderer `html-markdown` uses for the
/// whole document. This stage is the CLI/stage wiring `html_main_content_
/// markdown.d`'s own module doc explicitly deferred as "a separate, later,
/// real product decision".
///
/// Mirrors `html_main_content_stage.d`'s shape (raw-byte cap, `parseHtml`,
/// pure transform, abstention quarantines the whole document) rather than
/// `html_markdown_stage.d`'s (which never abstains) because -- like
/// `html-main-content` -- this stage's success is conditional on
/// `extractMainContent` finding a selectable candidate at all; on
/// `MainContentStatus.selected` the content is replaced with Markdown
/// (`result.markdown`) instead of `MainContentResult.text`'s flattened
/// plain text.
module effects.html_main_content_markdown_stage;

import content.pieces : Content, ContentPiece;
import effects.html_main_content : HtmlMainContentOutputLimit, MainContentStatus;
import effects.html_main_content_markdown : extractMainContentMarkdown,
    MainContentMarkdownResult;
import effects.html_markdown : HtmlMarkdownOutputLimit;
import effects.html_tree : HtmlFailureReason, checkedHtmlByteLimit,
    defaultExtractHtmlBytes, parseHtml;
import stages.contract : PassMode, ResourceDeclaration, StageDecision,
    StageDeclaration, StageDocument;
import stages.registry : ConfiguredStageTransform, FilterPlacement,
    OptionDeclaration, OptionType, SideOutputCapability, StageCardinality,
    StageConfiguration, StageOptions, StageRegistration, registerStage;
import std.conv : to;
import std.exception : enforce;

private class HtmlMainContentMarkdownConfiguration : StageConfiguration {
    string charset;
    size_t byteLimit;
    this(string charset, size_t byteLimit) immutable {
        this.charset = charset;
        this.byteLimit = byteLimit;
    }
}

private StageDecision applyHtmlMainContentMarkdown(StageDocument input,
        immutable(StageConfiguration) configuration) pure {
    auto configured = cast(immutable(HtmlMainContentMarkdownConfiguration)) configuration;
    enforce(configured !is null, "invalid html-main-content-markdown configuration");
    auto charset = configured.charset;
    auto byteLimit = configured.byteLimit;
    if (input.content.size > byteLimit)
        return StageDecision.quarantine("rawLimit");
    auto raw = input.content.copy();
    auto outcome = parseHtml(raw, charset, input.document.source.recordKey, byteLimit);
    if (!outcome.isParsed) {
        auto failure = outcome.failure;
        auto reason = failure.reason.to!string;
        if (failure.reason == HtmlFailureReason.decode) {
            reason ~= ":" ~ failure.decodeReason.to!string;
            if (failure.hasOffendingOffset)
                reason ~= "@" ~ failure.offendingOffset.to!string;
        }
        return StageDecision.quarantine(reason);
    }
    MainContentMarkdownResult result;
    try result = extractMainContentMarkdown(outcome.tree);
    catch (HtmlMainContentOutputLimit) return StageDecision.quarantine("outputLimit");
    catch (HtmlMarkdownOutputLimit) return StageDecision.quarantine("outputLimit");
    if (result.status != MainContentStatus.selected)
        return StageDecision.quarantine(result.status.to!string);
    input.content = new Content([ContentPiece.own(cast(const(ubyte)[]) result.markdown)]);
    // `input.metadata` (written by any prior stage) passes through
    // completely untouched: this stage never reads or writes it, matching
    // `html-main-content`'s own metadata handling.
    return StageDecision.map(input);
}

private ConfiguredStageTransform factory(const ref StageOptions options) {
    auto chosen = "charset" in options;
    auto charset = chosen is null ? null : chosen.asText();
    auto configuredLimit = "max-html-bytes" in options;
    auto byteLimit = configuredLimit is null ? defaultExtractHtmlBytes :
        checkedHtmlByteLimit(configuredLimit.asInteger());
    return ConfiguredStageTransform(&applyHtmlMainContentMarkdown,
        new immutable HtmlMainContentMarkdownConfiguration(charset, byteLimit));
}

static this() {
    registerStage(StageRegistration(StageDeclaration("html-main-content-markdown",
        PassMode.singlePass, ResourceDeclaration(1, 32 * 1024 * 1024)),
        [OptionDeclaration("charset", OptionType.text),
         OptionDeclaration("max-html-bytes", OptionType.integer)], null, null, &factory,
        FilterPlacement.none, StageCardinality.oneToOne, SideOutputCapability.none));
}

unittest {
    import composition.compiler : compileJob;
    import composition.executor : runCompiledStage;
    import domain.document : Document, OutputName, SourceLocator;
    import job.json : parseJobJson;
    import stages.contract : EventKind;
    import std.algorithm.searching : canFind;
    import std.exception : enforce;

    auto spec = parseJobJson(`{"version":3,"stages":[{"id":` ~
        `"extract","implementation":"html-main-content-markdown","options":{},"filters":[]}]}`);
    auto plan = compileJob(spec);
    enforce(plan.stages.length == 1);
    auto document = Document(SourceLocator("local-html:v1", "/tmp", "a.html"),
        OutputName("a.html.md"));

    // Successful selection replaces content with Markdown, scoped to the
    // selected subtree only -- a sibling <nav> never appears in the output.
    string longParagraph;
    foreach (_; 0 .. 25) longParagraph ~= "Article body sentence. ";
    string html = "<nav>Home About Contact</nav>" ~
        "<article><h1>Title</h1><p>" ~ longParagraph ~ "</p></article>";
    auto input = StageDocument(document,
        new Content([ContentPiece.own(cast(const(ubyte)[]) html)]));
    auto result = runCompiledStage([input], plan.stages[0]);
    enforce(result.events.length == 1 && result.events[0].kind == EventKind.emitted);
    string bytes;
    foreach (piece; result.events[0].payload.content.pieces())
        foreach (i; 0 .. piece.size) bytes ~= cast(char)piece.at(i);
    enforce(bytes.canFind("# Title"), "must contain real Markdown heading syntax");
    enforce(!bytes.canFind("Home") && !bytes.canFind("Contact"),
        "boilerplate nav text must not appear in the selected-subtree Markdown");

    // Abstention (below-threshold nav content) quarantines with the status
    // name, same as plain-text `html-main-content`.
    auto navInput = StageDocument(document,
        new Content([ContentPiece.own(cast(const(ubyte)[]) "<nav>Home About</nav>")]));
    auto navResult = runCompiledStage([navInput], plan.stages[0]);
    enforce(navResult.events.length == 1 &&
        navResult.events[0].kind == EventKind.quarantined &&
        navResult.events[0].reason == "abstainedBelowThreshold",
        "abstention must quarantine with the status name");
}
