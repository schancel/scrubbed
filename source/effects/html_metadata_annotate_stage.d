/// Opt-in HTML metadata *annotate* stage (#285 integration slice): reuses
/// `parseHtml`/`extractHtmlMetadata` exactly as `effects.html_metadata_stage`
/// (issue #284's separate, disjoint stage) does, but instead of producing its
/// own side output, writes each "selected" standard field directly into
/// `StageDocument.metadata` so it survives forward to a later stage in the
/// same compiled job. `content` is returned completely unmodified. This
/// module does not import or touch `effects.html_metadata_stage`.
module effects.html_metadata_annotate_stage;

import domain.document_metadata : DocumentMetadata, StandardMetadataKey;
import effects.html_metadata : MetadataField, extractHtmlMetadata;
import effects.html_tree : HtmlFailureReason, checkedHtmlByteLimit,
    defaultExtractHtmlBytes, parseHtml;
import stages.contract : PassMode, ResourceDeclaration, StageDecision,
    StageDeclaration, StageDocument;
import stages.registry : ConfiguredStageTransform, FilterPlacement,
    OptionDeclaration, OptionType, SideOutputCapability, StageCardinality,
    StageConfiguration, StageOptions, StageRegistration, registerStage;
import std.conv : to;
import std.exception : enforce;

/// The stage's own static implementation-key literal, used as every written
/// field's `sourceStage` provenance (#285's flagged minimal option: no
/// per-job-instance provenance mechanism in this slice).
enum htmlMetadataAnnotateStageKeyV1 = "html-metadata-annotate";

private class HtmlMetadataAnnotateConfiguration : StageConfiguration {
    string charset;
    size_t byteLimit;
    this(string charset, size_t byteLimit) immutable {
        this.charset = charset;
        this.byteLimit = byteLimit;
    }
}

/// Only a "selected" field is written; every other status (absent, invalid,
/// ambiguous, overflow) leaves that standard key unset, matching #285's
/// first-slice "final decided value only" decision.
private DocumentMetadata annotateSelected(DocumentMetadata metadata,
        StandardMetadataKey key, const ref MetadataField field) pure {
    if (field.status != "selected") return metadata;
    return metadata.withStandardField(key, field.value,
        htmlMetadataAnnotateStageKeyV1);
}

private StageDecision applyHtmlMetadataAnnotate(StageDocument input,
        immutable(StageConfiguration) configuration) pure {
    auto configured = cast(immutable(HtmlMetadataAnnotateConfiguration)) configuration;
    enforce(configured !is null, "invalid html-metadata-annotate configuration");
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
    auto extracted = extractHtmlMetadata(outcome.tree);
    auto metadata = input.metadata;
    metadata = annotateSelected(metadata, StandardMetadataKey.title, extracted.title);
    metadata = annotateSelected(metadata, StandardMetadataKey.author, extracted.author);
    metadata = annotateSelected(metadata, StandardMetadataKey.date, extracted.date);
    metadata = annotateSelected(metadata, StandardMetadataKey.url, extracted.url);
    input.metadata = metadata;
    // `content` is returned completely unmodified.
    return StageDecision.map(input);
}

private ConfiguredStageTransform factory(const ref StageOptions options) {
    auto chosen = "charset" in options;
    auto charset = chosen is null ? null : chosen.asText();
    auto configuredLimit = "max-html-bytes" in options;
    auto byteLimit = configuredLimit is null ? defaultExtractHtmlBytes :
        checkedHtmlByteLimit(configuredLimit.asInteger());
    return ConfiguredStageTransform(&applyHtmlMetadataAnnotate,
        new immutable HtmlMetadataAnnotateConfiguration(charset, byteLimit));
}

static this() {
    registerStage(StageRegistration(StageDeclaration(htmlMetadataAnnotateStageKeyV1,
        PassMode.singlePass, ResourceDeclaration(1, 32 * 1024 * 1024)),
        [OptionDeclaration("charset", OptionType.text),
         OptionDeclaration("max-html-bytes", OptionType.integer)], null, null, &factory,
        FilterPlacement.none, StageCardinality.oneToOne, SideOutputCapability.none));
}

unittest {
    import composition.compiler : compileJob;
    import composition.executor : runCompiledStage;
    import content.pieces : Content, ContentPiece;
    import domain.document : Document, OutputName, SourceLocator;
    import job.json : parseJobJson;
    import stages.contract : EventKind;

    auto spec = parseJobJson(`{"version":3,"stages":[{"id":"annotate",` ~
        `"implementation":"html-metadata-annotate","options":{},"filters":[]}]}`);
    auto plan = compileJob(spec);
    auto document = Document(SourceLocator("fixture:v1", "/tmp", "record"),
        OutputName("record.html"));

    // Successful map: content stays completely unmodified, and the
    // "selected" title is written into .metadata.
    string html = `<head><title>Only Title</title></head>`;
    auto input = StageDocument(document,
        new Content([ContentPiece.own(cast(const(ubyte)[]) html)]));
    auto mapped = runCompiledStage([input], plan.stages[0]);
    assert(mapped.events.length == 1 && mapped.events[0].kind == EventKind.emitted,
        "successful html-metadata-annotate run must map");
    auto emitted = mapped.events[0];
    assert(cast(string) emitted.payload.content.copy() == html,
        "content must be left completely unmodified");
    assert(emitted.payload.metadata.standardValue(StandardMetadataKey.title) ==
            "Only Title",
        "selected title field must be annotated into .metadata");

    // Quarantine: rawLimit, at the stage's *default* configured limit
    // (`defaultExtractHtmlBytes`, 1 MiB -- issue #444: this stage used to
    // hardcode `effects.html_tree.maxRawBytes`, 64 KiB, with no way to
    // configure it, unlike `html-main-content`).
    auto oversized = StageDocument(document,
        new Content([ContentPiece.own(new ubyte[defaultExtractHtmlBytes + 1])]));
    auto rawLimited = runCompiledStage([oversized], plan.stages[0]);
    assert(rawLimited.events.length == 1 &&
        rawLimited.events[0].kind == EventKind.quarantined &&
        rawLimited.events[0].reason == "rawLimit",
        "rawLimit quarantine trigger/reason changed");
}

/// Issue #444 regression, pinned against the specific stage
/// `clean-web-document/v1` actually runs (`job.presets
/// .cleanWebDocumentTokensV1`): a real corpus page comfortably inside
/// `html-main-content`'s existing 1 MiB default admission bound used to be
/// quarantined by *this* stage anyway, independently, because it hardcoded
/// the unrelated, unconfigurable 64 KiB `effects.html_tree.maxRawBytes`.
/// Run from the repository root (as `dub test`/`README.md`'s other
/// documented commands already assume),
/// `examples/pipeline-benchmark/corpus/appen-com.html` (81,918 bytes) is
/// well over the old 64 KiB cap and well under the new 1 MiB default, so
/// this proves both halves at once -- this exact assertion would have
/// failed (quarantined `rawLimit`) against the pre-fix hardcoded-64 KiB
/// behavior, and passes (maps successfully) now.
unittest {
    import composition.compiler : compileJob;
    import composition.executor : runCompiledStage;
    import content.pieces : Content, ContentPiece;
    import domain.document : Document, OutputName, SourceLocator;
    import job.json : parseJobJson;
    import stages.contract : EventKind;
    import std.file : read;

    enum corpusFile = "examples/pipeline-benchmark/corpus/appen-com.html";
    auto bytes = cast(const(ubyte)[]) read(corpusFile);
    assert(bytes.length > 64 * 1024,
        "fixture must exceed the old hardcoded 64 KiB cap to prove the fix");
    assert(bytes.length <= defaultExtractHtmlBytes,
        "fixture must fit the new default so the regression actually pins success");

    auto spec = parseJobJson(`{"version":3,"stages":[{"id":"annotate",` ~
        `"implementation":"html-metadata-annotate","options":{},"filters":[]}]}`);
    auto plan = compileJob(spec);
    auto document = Document(SourceLocator("fixture:v1", "corpus", "appen-com.html"),
        OutputName("appen-com.html"));
    auto input = StageDocument(document, new Content([ContentPiece.own(bytes)]));
    auto result = runCompiledStage([input], plan.stages[0]);
    assert(result.events.length == 1 && result.events[0].kind == EventKind.emitted,
        "real corpus page appen-com.html (82KB) must no longer quarantine with " ~
        "rawLimit under html-metadata-annotate's default byte limit (issue #444)");
}
