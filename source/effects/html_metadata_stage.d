/// Opt-in HTML metadata stage; importing this module registers its name.
module effects.html_metadata_stage;

import content.pieces : Content, ContentPiece;
import effects.html_metadata : HtmlMetadataOutputLimit, extractHtmlMetadata,
    serializeHtmlMetadata;
import effects.html_tree : HtmlFailureReason, checkedHtmlByteLimit,
    defaultExtractHtmlBytes, parseHtml;
import stages.contract : PassMode, ResourceDeclaration, StageDecision,
    StageDeclaration, StageDocument, TerminalSideOutput;
import stages.registry : ConfiguredStageTransform, FilterPlacement,
    HtmlOutputShape, OptionDeclaration, OptionType, SideOutputCapability,
    StageCardinality, StageConfiguration, StageOptions, StageRegistration,
    registerStage;
import std.conv : to;
import std.exception : enforce;

enum htmlMetadataSideOutputKeyV2 = "html-metadata";
enum htmlMetadataSideOutputSchemaV2 = "metadata-json-v2";
enum htmlMetadataSideOutputSuffixV2 = ".metadata.json";

private class HtmlMetadataConfiguration : StageConfiguration {
    string charset;
    size_t byteLimit;
    this(string charset, size_t byteLimit) immutable {
        this.charset = charset;
        this.byteLimit = byteLimit;
    }
}

/// A quarantined/rejected decision carries no extracted metadata, but this
/// stage's `SideOutputCapability.terminal` registration requires every event
/// -- quarantined ones included -- to carry exactly one `TerminalSideOutput`
/// (`composition.executor.validateCapabilities` enforces this unconditionally).
/// This placeholder is never read by `metadata_route_cli.runMetadataRoute`,
/// which branches on quarantine/reject before touching side outputs.
private TerminalSideOutput quarantinedMetadataSideOutput() pure {
    return TerminalSideOutput(htmlMetadataSideOutputKeyV2,
        htmlMetadataSideOutputSchemaV2, htmlMetadataSideOutputSuffixV2, null);
}

private StageDecision applyHtmlMetadata(StageDocument input,
        immutable(StageConfiguration) configuration) pure {
    auto configured = cast(immutable(HtmlMetadataConfiguration)) configuration;
    enforce(configured !is null, "invalid html-metadata configuration");
    auto charset = configured.charset;
    auto byteLimit = configured.byteLimit;
    if (input.content.size > byteLimit)
        return StageDecision.quarantine("rawLimit", [quarantinedMetadataSideOutput()]);
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
        return StageDecision.quarantine(reason, [quarantinedMetadataSideOutput()]);
    }
    string serialized;
    try serialized = serializeHtmlMetadata(input.document.id,
        extractHtmlMetadata(outcome.tree));
    catch (HtmlMetadataOutputLimit)
        return StageDecision.quarantine("outputLimit", [quarantinedMetadataSideOutput()]);
    auto sideOutput = TerminalSideOutput(htmlMetadataSideOutputKeyV2,
        htmlMetadataSideOutputSchemaV2, htmlMetadataSideOutputSuffixV2,
        cast(const(ubyte)[]) serialized);
    return StageDecision.map(input, [sideOutput]);
}

private ConfiguredStageTransform factory(const ref StageOptions options) {
    auto chosen = "charset" in options;
    auto charset = chosen is null ? null : chosen.asText();
    auto configuredLimit = "max-html-bytes" in options;
    auto byteLimit = configuredLimit is null ? defaultExtractHtmlBytes :
        checkedHtmlByteLimit(configuredLimit.asInteger());
    return ConfiguredStageTransform(&applyHtmlMetadata,
        new immutable HtmlMetadataConfiguration(charset, byteLimit));
}

static this() {
    // Issue #447: parses `.content` as HTML but returns it completely
    // unmodified (the extracted metadata goes to a side output instead), so
    // this stage's own output is still `rawHtml`-shaped -- a later
    // HTML-consuming stage may safely follow it.
    auto registration = StageRegistration(StageDeclaration("html-metadata",
        PassMode.singlePass, ResourceDeclaration(1, 32 * 1024 * 1024)),
        [OptionDeclaration("charset", OptionType.text),
         OptionDeclaration("max-html-bytes", OptionType.integer)], null, null, &factory,
        FilterPlacement.none, StageCardinality.oneToOne,
        SideOutputCapability.terminal);
    registration.requiresRawHtmlInput = true;
    registration.producesHtmlShape = HtmlOutputShape.rawHtml;
    registerStage(registration);
}

unittest {
    import composition.compiler : compileJob;
    import composition.executor : runCompiledStage;
    import domain.document : Document, OutputName, SourceLocator;
    import job.json : parseJobJson;
    import stages.contract : DecisionKind, EventKind;

    auto spec = parseJobJson(`{"version":3,"stages":[{"id":"metadata",` ~
        `"implementation":"html-metadata","options":{},"filters":[]}]}`);
    auto plan = compileJob(spec);
    auto document = Document(SourceLocator("fixture:v1", "/PRIVATE/secret", "record"),
        OutputName("record.html"));

    // Successful map: content stays the raw input HTML (the bug destroyed it by
    // overwriting content with the metadata JSON); exactly one TerminalSideOutput
    // carries the same bytes that used to overwrite content.
    string html = `<head><title>Fallback</title>` ~
        `<meta property="og:title" content="Primary">` ~
        `<meta name="author" content="Ada">` ~
        `<meta name="date" content="2024-02-29">` ~
        `<link rel="canonical" href="https://example.test/page"></head>`;
    auto parsed = parseHtml(cast(const(ubyte)[]) html);
    assert(parsed.isParsed);
    auto expectedJson = serializeHtmlMetadata(document.id,
        extractHtmlMetadata(parsed.tree));

    auto mapInput = StageDocument(document,
        new Content([ContentPiece.own(cast(const(ubyte)[]) html)]));
    auto mapped = runCompiledStage([mapInput], plan.stages[0]);
    assert(mapped.events.length == 1 && mapped.events[0].kind == EventKind.emitted &&
        mapped.events[0].payload.document.id == document.id,
        "successful html-metadata run must map, preserving document identity");
    auto emitted = mapped.events[0];
    assert(cast(string) emitted.payload.content.copy() == html,
        "content must be left untouched on success, not overwritten with metadata");
    assert(emitted.sideOutputs.length == 1,
        "exactly one TerminalSideOutput must be emitted on success");
    assert(cast(string) emitted.sideOutputs[0].bytes() == expectedJson,
        "side output bytes must equal the prior content-overwrite bytes");
    assert(emitted.sideOutputs[0].schema == htmlMetadataSideOutputSchemaV2 &&
        emitted.sideOutputs[0].key == htmlMetadataSideOutputKeyV2 &&
        emitted.sideOutputs[0].suffix == htmlMetadataSideOutputSuffixV2,
        "side output identity mismatch");

    // Quarantine: rawLimit, at the stage's *default* configured limit
    // (`defaultExtractHtmlBytes`, 1 MiB -- issue #444: this stage used to
    // hardcode `effects.html_tree.maxRawBytes`, 64 KiB, with no way to
    // configure it, unlike `html-main-content`). Same reason string as
    // before this change, now proven through the full runCompiledStage path
    // (exercising the SideOutputCapability.terminal invariant, not just the
    // bare transform).
    auto oversized = StageDocument(document,
        new Content([ContentPiece.own(new ubyte[defaultExtractHtmlBytes + 1])]));
    auto rawLimited = runCompiledStage([oversized], plan.stages[0]);
    assert(rawLimited.events.length == 1 &&
        rawLimited.events[0].kind == EventKind.quarantined &&
        rawLimited.events[0].reason == "rawLimit",
        "rawLimit quarantine trigger/reason changed");

    // Quarantine: HTML decode failure (invalid UTF-8). Compare the reason
    // produced through runCompiledStage against the reason the bare transform
    // produces, proving runCompiledStage does not alter or suppress it.
    auto badUtf8 = StageDocument(document,
        new Content([ContentPiece.own([cast(ubyte) 0xff])]));
    auto transform = plan.stages[0].transform;
    auto directDecision = transform(badUtf8);
    assert(directDecision.kind == DecisionKind.quarantine);
    auto decodeFailed = runCompiledStage([badUtf8], plan.stages[0]);
    assert(decodeFailed.events.length == 1 &&
        decodeFailed.events[0].kind == EventKind.quarantined &&
        decodeFailed.events[0].reason == directDecision.reason &&
        decodeFailed.events[0].reason.length != 0,
        "HTML decode-failure quarantine trigger/reason changed");

    // Quarantine: outputLimit (metadata JSON exceeds its cap). Same fixture
    // shape as the pre-existing experiments/metadata/check.d golden.
    string slashes;
    foreach (_; 0 .. 512) slashes ~= "\\";
    string large = "<head>";
    foreach (_; 0 .. 16) {
        large ~= `<meta property="og:title" content="` ~ slashes ~ `">`;
        large ~= `<meta name="author" content="` ~ slashes ~ `">`;
    }
    large ~= "</head>";
    auto largeDoc = StageDocument(document,
        new Content([ContentPiece.own(cast(const(ubyte)[]) large)]));
    auto overflowed = runCompiledStage([largeDoc], plan.stages[0]);
    assert(overflowed.events.length == 1 &&
        overflowed.events[0].kind == EventKind.quarantined &&
        overflowed.events[0].reason == "outputLimit",
        "outputLimit quarantine trigger/reason changed");
}

/// Issue #444 regression: a real corpus page comfortably inside
/// `html-main-content`'s existing 1 MiB default admission bound used to be
/// quarantined here anyway, because this stage independently hardcoded
/// `effects.html_tree.maxRawBytes` (64 KiB) with no configurable option.
/// Pinned against a real bundled corpus file, not a synthetic fixture: run
/// from the repository root (as `dub test`/`README.md`'s other documented
/// commands already assume), `examples/pipeline-benchmark/corpus/appen-com.html`
/// (81,918 bytes) is well over the old 64 KiB cap and well under the new
/// 1 MiB default, so this proves both halves at once -- this exact
/// assertion would have failed (quarantined `rawLimit`) against the
/// pre-fix hardcoded-64 KiB behavior, and passes (maps successfully) now.
unittest {
    import composition.compiler : compileJob;
    import composition.executor : runCompiledStage;
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

    auto spec = parseJobJson(`{"version":3,"stages":[{"id":"metadata",` ~
        `"implementation":"html-metadata","options":{},"filters":[]}]}`);
    auto plan = compileJob(spec);
    auto document = Document(SourceLocator("fixture:v1", "corpus", "appen-com.html"),
        OutputName("appen-com.html"));
    auto input = StageDocument(document, new Content([ContentPiece.own(bytes)]));
    auto result = runCompiledStage([input], plan.stages[0]);
    assert(result.events.length == 1 && result.events[0].kind == EventKind.emitted,
        "real corpus page appen-com.html (82KB) must no longer quarantine with " ~
        "rawLimit under html-metadata's default byte limit (issue #444)");
}
