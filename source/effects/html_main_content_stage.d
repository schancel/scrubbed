/// Concrete v3 self-registering main-content-selection stage; importing this
/// module registers it. Mirrors `html_markdown_stage.d`'s existing pattern:
/// a raw-byte cap, `parseHtml`, then a pure content-replacing transform over
/// the parsed tree -- here `effects.html_main_content.extractMainContent`
/// (landed, frozen, read-only reference) instead of `renderMarkdown`.
///
/// Sequenced between `html-metadata-annotate` (#285) and the terminal
/// `pii-four-class` stage: `[text-transform] -> [html-metadata-annotate] ->
/// [html-main-content] -> [pii-four-class]`. Metadata-annotation must run
/// first because it reads `<head>` evidence and this stage's successful map
/// fully replaces `content` with the selected body subtree's plain text,
/// discarding `<head>` entirely; `html-metadata-annotate` returns `content`
/// completely unmodified, so running it first costs nothing.
///
/// Per owner decision (issue #26, v3-stage-registration contract), any
/// abstention status quarantines the *whole* document, including any
/// `.metadata` an earlier stage already wrote -- matching quarantine's
/// existing all-or-nothing semantics elsewhere, rather than a hard
/// `.reject`. `input.metadata` is otherwise passed through completely
/// untouched: this stage never reads or writes it.
///
/// Registered with explicit `StageCardinality.oneToOne` and explicit
/// `SideOutputCapability.none` (not left at their unspecified defaults):
/// this stage's real behavior always maps or quarantines and never splits,
/// and `composition/compiler.d`'s admission rule requires every stage
/// preceding a terminal stage to be *registered* `oneToOne`, not merely to
/// behave that way -- this stage precedes the terminal `pii-four-class`
/// stage in its required chain, so the default `maySplit` would make that
/// chain fail to compile.
module effects.html_main_content_stage;

import content.pieces : Content, ContentPiece;
import effects.html_main_content : extractMainContent, HtmlMainContentOutputLimit,
    MainContentResult, MainContentStatus;
import effects.html_tree : HtmlFailureReason, checkedHtmlByteLimit,
    defaultExtractHtmlBytes, parseHtml;
import stages.contract : PassMode, ResourceDeclaration, StageDecision,
    StageDeclaration, StageDocument;
import stages.registry : ConfiguredStageTransform, FilterPlacement,
    OptionDeclaration, OptionType, SideOutputCapability, StageCardinality,
    StageConfiguration, StageOptions, StageRegistration, registerStage;
import std.conv : to;
import std.exception : enforce;

private class HtmlMainContentConfiguration : StageConfiguration {
    string charset;
    size_t byteLimit;
    this(string charset, size_t byteLimit) immutable {
        this.charset = charset;
        this.byteLimit = byteLimit;
    }
}

private StageDecision applyHtmlMainContent(StageDocument input,
        immutable(StageConfiguration) configuration) pure {
    auto configured = cast(immutable(HtmlMainContentConfiguration)) configuration;
    enforce(configured !is null, "invalid html-main-content configuration");
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
    MainContentResult result;
    try result = extractMainContent(outcome.tree);
    catch (HtmlMainContentOutputLimit) return StageDecision.quarantine("outputLimit");
    // Issue #411: `selectedStructuredData` is a second, real success status
    // (structured-data-fallback content, not one lost to the DOM candidate
    // pass) -- see `effects.html_main_content`'s own doc comment on that
    // status for why it is distinct from `selected` rather than reusing it.
    if (result.status != MainContentStatus.selected &&
            result.status != MainContentStatus.selectedStructuredData)
        return StageDecision.quarantine(result.status.to!string);
    input.content = new Content([ContentPiece.own(cast(const(ubyte)[]) result.text)]);
    // `input.metadata` (written by any prior stage) passes through
    // completely untouched: this stage never reads or writes it.
    return StageDecision.map(input);
}

private ConfiguredStageTransform factory(const ref StageOptions options) {
    auto chosen = "charset" in options;
    auto charset = chosen is null ? null : chosen.asText();
    auto configuredLimit = "max-html-bytes" in options;
    auto byteLimit = configuredLimit is null ? defaultExtractHtmlBytes :
        checkedHtmlByteLimit(configuredLimit.asInteger());
    return ConfiguredStageTransform(&applyHtmlMainContent,
        new immutable HtmlMainContentConfiguration(charset, byteLimit));
}

static this() {
    registerStage(StageRegistration(StageDeclaration("html-main-content",
        PassMode.singlePass, ResourceDeclaration(1, 32 * 1024 * 1024)),
        [OptionDeclaration("charset", OptionType.text),
         OptionDeclaration("max-html-bytes", OptionType.integer)], null, null, &factory,
        FilterPlacement.none, StageCardinality.oneToOne, SideOutputCapability.none));
}

unittest {
    import composition.compiler : compileJob;
    import composition.executor : runCompiledStage;
    import domain.document : Document, OutputName, SourceLocator;
    import domain.document_metadata : DocumentMetadata, StandardMetadataKey;
    import job.json : parseJobJson;
    import stages.contract : EventKind;
    import std.exception : enforce;

    auto spec = parseJobJson(`{"version":3,"stages":[{"id":` ~
        `"extract","implementation":"html-main-content","options":{},"filters":[]}]}`);
    auto plan = compileJob(spec);
    enforce(plan.stages.length == 1);
    auto document = Document(SourceLocator("local-html:v1", "/tmp", "a.html"),
        OutputName("a.html.txt"));

    // Successful selection replaces content and preserves prior .metadata.
    string longParagraph;
    foreach (_; 0 .. 25) longParagraph ~= "Article body sentence. ";
    string html = "<article><p>" ~ longParagraph ~ "</p></article>";
    auto metadata = DocumentMetadata.empty().withStandardField(
        StandardMetadataKey.title, "Prior Title", "html-metadata-annotate");
    auto input = StageDocument(document,
        new Content([ContentPiece.own(cast(const(ubyte)[]) html)]), metadata);
    auto result = runCompiledStage([input], plan.stages[0]);
    enforce(result.events.length == 1 && result.events[0].kind == EventKind.emitted);
    enforce(result.events[0].payload.document.id == document.id);
    enforce(result.events[0].payload.metadata == metadata,
        "prior .metadata must survive a successful map untouched");
    string bytes;
    foreach (piece; result.events[0].payload.content.pieces())
        foreach (i; 0 .. piece.size) bytes ~= cast(char)piece.at(i);
    enforce(bytes.length > 0, "selected content must be nonempty");

    // Abstention (below-threshold nav content) quarantines with the status name.
    auto navInput = StageDocument(document,
        new Content([ContentPiece.own(cast(const(ubyte)[]) "<nav>Home About</nav>")]),
        metadata);
    auto navResult = runCompiledStage([navInput], plan.stages[0]);
    enforce(navResult.events.length == 1 &&
        navResult.events[0].kind == EventKind.quarantined &&
        navResult.events[0].reason == "abstainedBelowThreshold",
        "abstention must quarantine with the status name");
}
