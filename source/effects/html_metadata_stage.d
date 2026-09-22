/// Opt-in HTML metadata stage; importing this module registers its name.
module effects.html_metadata_stage;

import content.pieces : Content, ContentPiece;
import effects.html_metadata : HtmlMetadataOutputLimit, extractHtmlMetadata,
    serializeHtmlMetadata;
import effects.html_tree : HtmlFailureReason, maxRawBytes, parseHtml;
import stages.config : StagePlan, buildConfigV2;
import stages.contract : PassMode, ResourceDeclaration, StageDecision,
    StageDeclaration, StageDocument, StageTransform;
import stages.registry : OptionDeclaration, OptionType, StageOptions,
    StageRegistration, registerStage;
import std.conv : to;
import std.json : JSONValue;

private StageTransform factory(const ref StageOptions options) {
    auto chosen = "charset" in options;
    auto charset = chosen is null ? null : chosen.asText();
    return (StageDocument input) {
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
    };
}

static this() {
    registerStage(StageRegistration(StageDeclaration("html-metadata",
        PassMode.singlePass, ResourceDeclaration(1, 32 * 1024 * 1024)),
        [OptionDeclaration("charset", OptionType.text)], null, null, &factory));
}

StagePlan htmlMetadataPlan(string charset = null) {
    auto options = charset is null ? "" : `,"options":{"charset":` ~
        JSONValue(charset).toString ~ `}`;
    return buildConfigV2(`{"version":2,"stages":[{"name":"html-metadata"` ~
        options ~ `}]}`);
}
