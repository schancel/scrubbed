/// Concrete selected-tree JSON stage; importing this module registers it.
module effects.html_tree_json_stage;

import content.pieces : Content, ContentPiece;
import effects.html_tree : HtmlFailureReason, checkedHtmlByteLimit,
    defaultExtractHtmlBytes, parseHtml;
import effects.html_tree_export : HtmlTreeOutputLimit, serializeTreeJson;
import stages.config : StagePlan, buildConfigV2;
import stages.contract : PassMode, ResourceDeclaration, StageDecision,
    StageDeclaration, StageDocument;
import stages.registry : ConfiguredStageTransform, OptionDeclaration, OptionType,
    StageConfiguration, StageOptions, StageRegistration, registerStage;
import std.conv : to;
import std.exception : enforce;
import std.json : JSONValue;

private string failureReason(HtmlFailureReason reason) pure {
    return reason.to!string;
}

private class HtmlTreeJsonConfiguration : StageConfiguration {
    string charset;
    size_t byteLimit;
    this(string charset, size_t byteLimit) immutable {
        this.charset = charset;
        this.byteLimit = byteLimit;
    }
}

private StageDecision applyHtmlTreeJson(StageDocument input,
        immutable(StageConfiguration) configuration) pure {
    auto configured = cast(immutable(HtmlTreeJsonConfiguration)) configuration;
    enforce(configured !is null, "invalid html-tree-json configuration");
    auto charset = configured.charset;
    auto byteLimit = configured.byteLimit;
    if (input.content.size > byteLimit)
        return StageDecision.quarantine("rawLimit");
    auto raw = new ubyte[input.content.size];
    size_t offset;
    foreach (piece; input.content.pieces()) {
        foreach (i; 0 .. piece.size) raw[offset++] = piece.at(i);
    }
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
    string serialized;
    try serialized = serializeTreeJson(input.document, outcome.tree);
    catch (HtmlTreeOutputLimit) return StageDecision.quarantine("outputLimit");
    input.content = new Content([ContentPiece.own(cast(const(ubyte)[])serialized)]);
    return StageDecision.map(input);
}

private ConfiguredStageTransform factory(const ref StageOptions options) {
    auto chosen = "charset" in options;
    auto charset = chosen is null ? null : chosen.asText();
    auto configuredLimit = "max-html-bytes" in options;
    auto byteLimit = configuredLimit is null ? defaultExtractHtmlBytes :
        checkedHtmlByteLimit(configuredLimit.asInteger());
    return ConfiguredStageTransform(&applyHtmlTreeJson,
        new immutable HtmlTreeJsonConfiguration(charset, byteLimit));
}

static this() {
    registerStage(StageRegistration(StageDeclaration("html-tree-json",
        PassMode.singlePass, ResourceDeclaration(1, 32 * 1024 * 1024)),
        [OptionDeclaration("charset", OptionType.text),
         OptionDeclaration("max-html-bytes", OptionType.integer)], null, null, &factory));
}

/// The concrete module owns its name; CLI consumes only this typed plan.
StagePlan htmlTreeJsonPlan(string charset = null,
    size_t byteLimit = defaultExtractHtmlBytes) {
    checkedHtmlByteLimit(byteLimit);
    auto options = `,"options":{"max-html-bytes":` ~
        JSONValue(cast(long)byteLimit).toString;
    if (charset !is null) options ~= `,"charset":` ~ JSONValue(charset).toString;
    options ~= `}`;
    return buildConfigV2(`{"version":2,"stages":[{"name":"html-tree-json"` ~
        options ~ `}]}`);
}

unittest {
    import domain.document : Document, OutputName, SourceLocator;
    import stages.contract : EventKind, StageDocument, runStage;
    import std.exception : enforce;

    auto plan = htmlTreeJsonPlan();
    enforce(plan.stages.length == 1);
    auto document = Document(SourceLocator("local-html:v1", "/tmp", "a.html"),
        OutputName("a.html.tree.json"));
    auto input = StageDocument(document,
        new Content([ContentPiece.own(cast(const(ubyte)[])"<p>hi</p>")]));
    auto spec = plan.stages[0].declaration;
    auto declaration = StageDeclaration(spec.key.idup, spec.passMode,
        ResourceDeclaration(spec.resources.cpuSlots, spec.resources.memoryBytes));
    auto result = runStage([input], declaration,
        plan.stages[0].transform);
    enforce(result.events.length == 1 && result.events[0].kind == EventKind.emitted);
    enforce(result.events[0].payload.document.id == document.id);
}
