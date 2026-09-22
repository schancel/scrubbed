/// Concrete selected-tree Markdown stage; importing this module registers it.
module effects.html_markdown_stage;

import content.pieces : Content, ContentPiece;
import effects.html_tree : HtmlFailureReason, maxRawBytes, parseHtml;
import effects.html_markdown : HtmlMarkdownOutputLimit, renderMarkdown;
import stages.config : StagePlan, buildConfigV2;
import stages.contract : PassMode, ResourceDeclaration, StageDecision,
    StageDeclaration, StageDocument, StageTransform;
import stages.registry : OptionDeclaration, OptionType, StageOptions,
    StageRegistration, registerStage;
import std.conv : to;
import std.json : JSONValue;

private string failureReason(HtmlFailureReason reason) {
    return reason.to!string;
}

private StageTransform factory(const ref StageOptions options) {
    auto chosen = "charset" in options;
    auto charset = chosen is null ? null : chosen.asText();
    return (StageDocument input) {
        if (input.content.size > maxRawBytes)
            return StageDecision.quarantine("rawLimit");
        auto raw = new ubyte[input.content.size];
        size_t offset;
        foreach (piece; input.content.pieces()) {
            foreach (i; 0 .. piece.size) raw[offset++] = piece.at(i);
        }
        auto outcome = parseHtml(raw, charset, input.document.source.recordKey);
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
    };
}

static this() {
    registerStage(StageRegistration(StageDeclaration("html-markdown",
        PassMode.singlePass, ResourceDeclaration(1, 32 * 1024 * 1024)),
        [OptionDeclaration("charset", OptionType.text)], null, null, &factory));
}

/// The concrete module owns its name; CLI consumes only this typed plan.
StagePlan htmlMarkdownPlan(string charset = null) {
    auto options = charset is null ? "" : `,"options":{"charset":` ~
        JSONValue(charset).toString ~ `}`;
    return buildConfigV2(`{"version":2,"stages":[{"name":"html-markdown"` ~
        options ~ `}]}`);
}

unittest {
    import domain.document : Document, OutputName, SourceLocator;
    import stages.contract : EventKind, StageDocument, runStage;
    import std.exception : enforce;

    auto plan = htmlMarkdownPlan();
    enforce(plan.stages.length == 1);
    auto document = Document(SourceLocator("local-html:v1", "/tmp", "a.html"),
        OutputName("a.html.md"));
    auto input = StageDocument(document,
        new Content([ContentPiece.own(cast(const(ubyte)[])"<p>hi</p>")]));
    auto spec = plan.stages[0].declaration;
    auto declaration = StageDeclaration(spec.key.idup, spec.passMode,
        ResourceDeclaration(spec.resources.cpuSlots, spec.resources.memoryBytes));
    auto result = runStage([input], declaration, plan.stages[0].transform);
    enforce(result.events.length == 1 && result.events[0].kind == EventKind.emitted);
    enforce(result.events[0].payload.document.id == document.id);
    string bytes;
    foreach (piece; result.events[0].payload.content.pieces())
        foreach (i; 0 .. piece.size) bytes ~= cast(char)piece.at(i);
    enforce(bytes == "hi\n");
}
