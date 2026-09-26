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
import effects.html_tree : HtmlFailureReason, maxRawBytes, parseHtml;
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
    this(string charset) immutable { this.charset = charset; }
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
    if (input.content.size > maxRawBytes)
        return StageDecision.quarantine("rawLimit");
    auto raw = input.content.copy();
    auto outcome = parseHtml(raw, charset, input.document.source.recordKey);
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
    return ConfiguredStageTransform(&applyHtmlMetadataAnnotate,
        new immutable HtmlMetadataAnnotateConfiguration(charset));
}

static this() {
    registerStage(StageRegistration(StageDeclaration(htmlMetadataAnnotateStageKeyV1,
        PassMode.singlePass, ResourceDeclaration(1, 32 * 1024 * 1024)),
        [OptionDeclaration("charset", OptionType.text)], null, null, &factory,
        FilterPlacement.none, StageCardinality.oneToOne, SideOutputCapability.none));
}
