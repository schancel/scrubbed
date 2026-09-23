/// Opt-in HTML metadata stage; importing this module registers its name.
module effects.html_metadata_stage;

import content.pieces : Content, ContentPiece;
import effects.html_metadata : HtmlMetadataOutputLimit, extractHtmlMetadata,
    serializeHtmlMetadata;
import effects.html_tree : HtmlFailureReason, maxRawBytes, parseHtml;
import stages.contract : PassMode, ResourceDeclaration, StageDecision,
    StageDeclaration, StageDocument;
import stages.registry : ConfiguredStageTransform, OptionDeclaration, OptionType,
    StageConfiguration, StageOptions, StageRegistration, registerStage;
import std.conv : to;
import std.exception : enforce;

private class HtmlMetadataConfiguration : StageConfiguration {
    string charset;
    this(string charset) immutable { this.charset = charset; }
}

private StageDecision applyHtmlMetadata(StageDocument input,
        immutable(StageConfiguration) configuration) pure {
    auto configured = cast(immutable(HtmlMetadataConfiguration)) configuration;
    enforce(configured !is null, "invalid html-metadata configuration");
    auto charset = configured.charset;
    if (input.content.size > maxRawBytes)
        return StageDecision.quarantine("rawLimit");
    auto raw = new ubyte[input.content.size];
    size_t offset;
    foreach (piece; input.content.pieces())
        foreach (i; 0 .. piece.size) raw[offset++] = piece.at(i);
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
    string serialized;
    try serialized = serializeHtmlMetadata(input.document.id,
        extractHtmlMetadata(outcome.tree));
    catch (HtmlMetadataOutputLimit) return StageDecision.quarantine("outputLimit");
    input.content = new Content([ContentPiece.own(cast(const(ubyte)[]) serialized)]);
    return StageDecision.map(input);
}

private ConfiguredStageTransform factory(const ref StageOptions options) {
    auto chosen = "charset" in options;
    auto charset = chosen is null ? null : chosen.asText();
    return ConfiguredStageTransform(&applyHtmlMetadata,
        new immutable HtmlMetadataConfiguration(charset));
}

static this() {
    registerStage(StageRegistration(StageDeclaration("html-metadata",
        PassMode.singlePass, ResourceDeclaration(1, 32 * 1024 * 1024)),
        [OptionDeclaration("charset", OptionType.text)], null, null, &factory));
}
