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
/// untouched by a successful map, with one additive exception (issue #475):
/// see "Comment-section output" below.
///
/// ## Comment-section output (issue #475)
///
/// `extractMainContent`'s own `includeComments` parameter (default `true`)
/// is exposed here as the `include-comments` boolean option, matching
/// trafilatura's own "comments on by default, an explicit flag opts out"
/// shape (`pii-four-class`'s own `allow-redact` is this repo's existing
/// precedent for a hyphenated stage-level boolean option). When a comment
/// section is identified (`result.commentsExtracted`) *and* its recovered
/// text fits `domain.document_metadata`'s existing, already-wired v1
/// extension-field cap (`maxExtensionValueBytes`, 512 bytes), it is added to
/// `.metadata` as an extension field under the key `"comments"`, sourced as
/// `"html-main-content"` -- using the same mechanism
/// `quality_ratios_annotate_stage.d`/`compressibility_annotate_stage.d`/
/// `language_id_detect_stage.d` already use to attach a small, additive
/// annotation without replacing `.content`.
///
/// **Disclosed, deliberate scope boundary:** a real comment thread (this
/// repo's own held-out corpus has one with 140 real entries,
/// `scienceblogs-de.html`) is routinely far larger than 512 bytes.
/// `document-metadata:v2`'s own structured-section capability
/// (`maxStructuredSectionPayloadBytes`, 2 MiB) would comfortably fit it, but
/// per that module's own header comment it is "domain-only... not wired to
/// anything yet", and wiring a new `SideOutputCapability`/second output
/// bucket through `composition/compiler.d`/`composition/executor.d` is a
/// larger, cross-cutting change outside this ticket's allowed file scope
/// (`html_main_content.d`/`html_main_content_stage.d` only). Rather than
/// silently truncating a real comment thread's text to fit the wrong-sized
/// existing cap and presenting that as "the comments", this stage skips the
/// metadata write entirely once the text doesn't fit -- `.metadata` never
/// carries a truncated, misleading fragment. The full, untruncated
/// separation is real and already available at the `extractMainContent`
/// API level (`MainContentResult.comments`/`.commentsExtracted`, this
/// ticket's actual deliverable); giving the compiled v3 stage a real,
/// unbounded second output channel is flagged here as a concrete follow-up,
/// not silently dropped.
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
import domain.document_metadata : maxExtensionValueBytes;
import effects.html_main_content : extractMainContent, HtmlMainContentOutputLimit,
    MainContentResult, MainContentStatus;
import effects.html_tree : HtmlFailureReason, checkedHtmlByteLimit,
    defaultExtractHtmlBytes, parseHtml;
import stages.contract : PassMode, ResourceDeclaration, StageDecision,
    StageDeclaration, StageDocument;
import stages.registry : ConfiguredStageTransform, FilterPlacement,
    HtmlOutputShape, OptionDeclaration, OptionType, SideOutputCapability,
    StageCardinality, StageConfiguration, StageOptions, StageRegistration,
    registerStage;
import std.conv : to;
import std.exception : enforce;

private class HtmlMainContentConfiguration : StageConfiguration {
    string charset;
    size_t byteLimit;
    bool includeComments;
    this(string charset, size_t byteLimit, bool includeComments) immutable {
        this.charset = charset;
        this.byteLimit = byteLimit;
        this.includeComments = includeComments;
    }
}

// Same `key in options` / default-value idiom `pii_four_class.d`'s own
// `booleanOption` already establishes for the identical "an optional
// hyphenated boolean stage option" need; restated here rather than shared
// because it is three lines and `pii_four_class.d`'s copy is private to that
// module.
private bool booleanOption(const ref StageOptions options, string key, bool defaultValue) {
    auto selected = key in options;
    return selected is null ? defaultValue : selected.asBoolean;
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
    try result = extractMainContent(outcome.tree, configured.includeComments);
    catch (HtmlMainContentOutputLimit) return StageDecision.quarantine("outputLimit");
    // Issue #411: `selectedStructuredData` is a second, real success status
    // (structured-data-fallback content, not one lost to the DOM candidate
    // pass) -- see `effects.html_main_content`'s own doc comment on that
    // status for why it is distinct from `selected` rather than reusing it.
    if (result.status != MainContentStatus.selected &&
            result.status != MainContentStatus.selectedStructuredData)
        return StageDecision.quarantine(result.status.to!string);
    input.content = new Content([ContentPiece.own(cast(const(ubyte)[]) result.text)]);
    // Issue #475: `input.metadata` (written by any prior stage) otherwise
    // passes through completely untouched -- the one additive exception is
    // this bounded "comments" extension field, only ever added, never
    // replacing or reading anything a prior stage wrote. See this module's
    // own "Comment-section output" doc comment above for why a real, larger
    // comment thread is deliberately left unwritten here rather than
    // truncated to fit.
    if (result.commentsExtracted && result.comments.length &&
            result.comments.length <= maxExtensionValueBytes) {
        input.metadata = input.metadata.withExtensionField("comments",
            cast(immutable(ubyte)[]) result.comments, "html-main-content");
    }
    return StageDecision.map(input);
}

private ConfiguredStageTransform factory(const ref StageOptions options) {
    auto chosen = "charset" in options;
    auto charset = chosen is null ? null : chosen.asText();
    auto configuredLimit = "max-html-bytes" in options;
    auto byteLimit = configuredLimit is null ? defaultExtractHtmlBytes :
        checkedHtmlByteLimit(configuredLimit.asInteger());
    // Issue #475: default `true`, matching trafilatura's own "comments on by
    // default" shape -- `include-comments=false` is this stage's
    // `--no-comments`-equivalent opt-out.
    auto includeComments = booleanOption(options, "include-comments", true);
    return ConfiguredStageTransform(&applyHtmlMainContent,
        new immutable HtmlMainContentConfiguration(charset, byteLimit, includeComments));
}

static this() {
    // Issue #447: parses `.content` as HTML and replaces it with flattened
    // plain text -- a later HTML-consuming stage in the same pipeline must
    // not receive this stage's output as if it were still HTML.
    auto registration = StageRegistration(StageDeclaration("html-main-content",
        PassMode.singlePass, ResourceDeclaration(1, 32 * 1024 * 1024)),
        [OptionDeclaration("charset", OptionType.text),
         OptionDeclaration("max-html-bytes", OptionType.integer),
         OptionDeclaration("include-comments", OptionType.boolean)], null, null, &factory,
        FilterPlacement.none, StageCardinality.oneToOne, SideOutputCapability.none);
    registration.requiresRawHtmlInput = true;
    registration.producesHtmlShape = HtmlOutputShape.nonHtml;
    registerStage(registration);
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

// Issue #475: comment-section output through the compiled stage boundary.
unittest {
    import composition.compiler : compileJob;
    import composition.executor : runCompiledStage;
    import domain.document : Document, OutputName, SourceLocator;
    import domain.document_metadata : DocumentMetadata;
    import job.json : parseJobJson;
    import stages.contract : EventKind;
    import std.algorithm.searching : canFind;
    import std.exception : enforce;

    auto document = Document(SourceLocator("local-html:v1", "/tmp", "a.html"),
        OutputName("a.html.txt"));
    string longParagraph;
    foreach (_; 0 .. 25) longParagraph ~= "Article body sentence. ";
    string html = "<article><p>" ~ longParagraph ~ "</p></article>" ~
        `<div id="comments"><div class="comment"><p>A real reader comment.</p></div></div>`;

    // Default configuration (`include-comments` defaults true): a small
    // comment section that fits the existing v1 extension-field cap is
    // added to `.metadata` as an additive "comments" field, and `.content`
    // still carries only the selected main content, exactly as before.
    auto defaultSpec = parseJobJson(`{"version":3,"stages":[{"id":` ~
        `"extract","implementation":"html-main-content","options":{},"filters":[]}]}`);
    auto defaultPlan = compileJob(defaultSpec);
    auto defaultInput = StageDocument(document,
        new Content([ContentPiece.own(cast(const(ubyte)[]) html)]), DocumentMetadata.empty());
    auto defaultResult = runCompiledStage([defaultInput], defaultPlan.stages[0]);
    enforce(defaultResult.events.length == 1 &&
        defaultResult.events[0].kind == EventKind.emitted);
    auto defaultMetadata = defaultResult.events[0].payload.metadata;
    enforce(defaultMetadata.extensionFieldCount() == 1,
        "a real comment section must add exactly one extension field by default");
    auto commentsField = defaultMetadata.extensionFields()[0];
    enforce(commentsField.key == "comments" && commentsField.sourceStage == "html-main-content");
    enforce((cast(string) commentsField.value).canFind("A real reader comment."));
    string mainBytes;
    foreach (piece; defaultResult.events[0].payload.content.pieces())
        foreach (i; 0 .. piece.size) mainBytes ~= cast(char) piece.at(i);
    enforce(!mainBytes.canFind("A real reader comment."),
        "comment text must never appear in .content, only in the additive metadata field");

    // `include-comments=false` (the opt-out flag) must add no extension
    // field at all, on the identical input.
    auto optedOutSpec = parseJobJson(`{"version":3,"stages":[{"id":"extract",` ~
        `"implementation":"html-main-content","options":{"include-comments":false},` ~
        `"filters":[]}]}`);
    auto optedOutPlan = compileJob(optedOutSpec);
    auto optedOutInput = StageDocument(document,
        new Content([ContentPiece.own(cast(const(ubyte)[]) html)]), DocumentMetadata.empty());
    auto optedOutResult = runCompiledStage([optedOutInput], optedOutPlan.stages[0]);
    enforce(optedOutResult.events.length == 1 &&
        optedOutResult.events[0].kind == EventKind.emitted);
    enforce(optedOutResult.events[0].payload.metadata.extensionFieldCount() == 0,
        "include-comments=false must add no metadata field at all");

    // A comment section larger than the existing v1 extension-field cap
    // (512 bytes) is deliberately left out of .metadata rather than
    // truncated -- see this module's own "Comment-section output" doc
    // comment for why. The stage must still succeed normally either way.
    string oversizedComment;
    foreach (_; 0 .. 40) oversizedComment ~= "A much longer real reader comment. ";
    string oversizedHtml = "<article><p>" ~ longParagraph ~ "</p></article>" ~
        `<div id="comments"><div class="comment"><p>` ~ oversizedComment ~ `</p></div></div>`;
    auto oversizedInput = StageDocument(document,
        new Content([ContentPiece.own(cast(const(ubyte)[]) oversizedHtml)]),
        DocumentMetadata.empty());
    auto oversizedResult = runCompiledStage([oversizedInput], defaultPlan.stages[0]);
    enforce(oversizedResult.events.length == 1 &&
        oversizedResult.events[0].kind == EventKind.emitted,
        "an oversized comment section must not fail the whole document");
    enforce(oversizedResult.events[0].payload.metadata.extensionFieldCount() == 0,
        "an oversized comment section must be left out of .metadata, not truncated into it");
}
