/// Opt-in HTML metadata *annotate* stage (#285 integration slice): reuses
/// `parseHtml`/`extractHtmlMetadata` exactly as `effects.html_metadata_stage`
/// (issue #284's separate, disjoint stage) does, but instead of producing its
/// own side output, writes each "selected" standard field directly into
/// `StageDocument.metadata` so it survives forward to a later stage in the
/// same compiled job. `content` is returned completely unmodified. This
/// module does not import or touch `effects.html_metadata_stage`.
///
/// **Issue #476 (structured metadata expansion) additions.** `siteName`,
/// `description`, and `rights` (published here as `"license"` -- see below)
/// are written as `document-metadata:v1` *extension* fields
/// (`DocumentMetadata.withExtensionField`), not new `StandardMetadataKey`
/// enum values: `domain.document_metadata`'s standard-key set and its
/// `document-metadata:v1` wire (`putStandardAndExtensionFields`) hardcode
/// exactly four fixed keys ("title"/"author"/"date"/"url") in a fixed JSON
/// key order, consumed byte-for-byte elsewhere (e.g.
/// `effects.language_id_detect_stage`'s own `scoreScrubbedLanguageId`-style
/// consumers, `benchmarks/external_comparator.d`); adding a fifth standard
/// key would change that frozen wire shape for every existing consumer.
/// `language-id-detect` (issue #300 Slice 2) already established this exact
/// "new field -> extension field, not a new standard key" precedent for
/// exactly the same reason. `rights` is published under the extension key
/// `"license"` (matching trafilatura==2.2.0's own metadata field name,
/// confirmed present in its `Document` model via `extract_license` -- see
/// this ticket's PR description) even though `effects.html_metadata`'s own
/// field is named `rights`: that field's evidence (`link[rel=license]`,
/// `dc.rights`, `copyright`) is exactly license/rights provenance, and no
/// new extraction was added for it -- this is pure re-exposure of
/// already-existing, previously-unwired extraction.
///
/// **Categories/tags are deliberately NOT added here.** `topical-tags-extract`
/// (`effects.topical_tags_extract_stage`) already extracts exactly this
/// evidence -- `<meta name="keywords">`, the `rel="tag"` microformat, and
/// JSON-LD `Article` `keywords`/`about` -- with real canonicalization,
/// duplicate detection, and page-text support-checking that this module does
/// not have and should not reimplement. Both stages write into the same
/// `StageDocument.metadata` `DocumentMetadata` accumulator (this one via
/// `withStandardField`/`withExtensionField`, that one via a
/// `withStructuredSection("topical-tags", ...)` structured section), and
/// both declare `requiresRawHtmlInput`/`producesHtmlShape = rawHtml`, so a
/// job chaining `html-metadata-annotate` -> `topical-tags-extract` ->
/// `document-metadata-publish` already reaches every field (title/author/
/// date/url/siteName/description/license plus categories/tags) in one
/// shared envelope with zero new integration code -- see this module's
/// chaining regression test below for a real, executed proof of that claim,
/// not merely an assertion.
///
/// **Language is out of scope here for the same reason**, already covered by
/// `language-id-detect` (issue #300 Slice 2), which writes its own
/// `"language-id"` extension field into the identical accumulator.
module effects.html_metadata_annotate_stage;

import domain.document_metadata : DocumentMetadata, StandardMetadataKey;
import effects.html_metadata : MetadataField, extractHtmlMetadata;
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

/// The stage's own static implementation-key literal, used as every written
/// field's `sourceStage` provenance (#285's flagged minimal option: no
/// per-job-instance provenance mechanism in this slice).
enum htmlMetadataAnnotateStageKeyV1 = "html-metadata-annotate";

/// Extension-field keys for the issue #476 additions (see the module doc
/// comment for why these are extension fields, not standard keys).
enum htmlMetadataAnnotateSiteNameKeyV1 = "site-name";
enum htmlMetadataAnnotateDescriptionKeyV1 = "description";
enum htmlMetadataAnnotateLicenseKeyV1 = "license";

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

/// Same "selected only" decision as `annotateSelected`, for an issue #476
/// field published as a `document-metadata:v1` extension field instead of a
/// standard key (see the module doc comment).
private DocumentMetadata annotateSelectedExtension(DocumentMetadata metadata,
        string extensionKey, const ref MetadataField field) pure {
    if (field.status != "selected") return metadata;
    return metadata.withExtensionField(extensionKey,
        cast(immutable(ubyte)[]) field.value, htmlMetadataAnnotateStageKeyV1);
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
    metadata = annotateSelectedExtension(metadata, htmlMetadataAnnotateSiteNameKeyV1,
        extracted.siteName);
    metadata = annotateSelectedExtension(metadata, htmlMetadataAnnotateDescriptionKeyV1,
        extracted.description);
    metadata = annotateSelectedExtension(metadata, htmlMetadataAnnotateLicenseKeyV1,
        extracted.rights);
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
    // Issue #447: parses `.content` as HTML but returns it completely
    // unmodified (the extracted fields go into `.metadata` instead), so
    // this stage's own output is still `rawHtml`-shaped -- a later
    // HTML-consuming stage may safely follow it, matching the sealed
    // `clean-web-document` chain's own `html-metadata-annotate` ->
    // `html-main-content` ordering.
    auto registration = StageRegistration(StageDeclaration(htmlMetadataAnnotateStageKeyV1,
        PassMode.singlePass, ResourceDeclaration(1, 32 * 1024 * 1024)),
        [OptionDeclaration("charset", OptionType.text),
         OptionDeclaration("max-html-bytes", OptionType.integer)], null, null, &factory,
        FilterPlacement.none, StageCardinality.oneToOne, SideOutputCapability.none);
    registration.requiresRawHtmlInput = true;
    registration.producesHtmlShape = HtmlOutputShape.rawHtml;
    registerStage(registration);
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

// ---------------------------------------------------------------------------
// Issue #476 regression proofs: site name, description, license.
// ---------------------------------------------------------------------------

version (unittest) import stages.contract : StageEvent;

version (unittest) private StageEvent runHtmlMetadataAnnotate(string html) {
    import composition.compiler : compileJob;
    import composition.executor : runCompiledStage;
    import content.pieces : Content, ContentPiece;
    import domain.document : Document, OutputName, SourceLocator;
    import job.json : parseJobJson;

    auto spec = parseJobJson(`{"version":3,"stages":[{"id":"annotate",` ~
        `"implementation":"html-metadata-annotate","options":{},"filters":[]}]}`);
    auto plan = compileJob(spec);
    auto document = Document(SourceLocator("fixture:v1", "/tmp", "record"),
        OutputName("record.html"));
    auto input = StageDocument(document,
        new Content([ContentPiece.own(cast(const(ubyte)[]) html)]));
    auto result = runCompiledStage([input], plan.stages[0]);
    assert(result.events.length == 1);
    return result.events[0];
}

version (unittest) private string extensionValue(
        const ref DocumentMetadata metadata, string key) {
    foreach (field; metadata.extensionFields)
        if (field.key == key) return cast(string) field.value;
    assert(false, "no extension field with key " ~ key);
}

version (unittest) private bool hasExtensionKey(
        const ref DocumentMetadata metadata, string key) {
    foreach (field; metadata.extensionFields) if (field.key == key) return true;
    return false;
}

// Real OpenGraph + plain-HTML + `<link rel="license">` markup (the same
// three evidence sources this ticket's pinned trafilatura==2.2.0 comparison
// exercises -- see this ticket's PR description): site name, description,
// and license are each written as their own `document-metadata:v1`
// extension field, with the correct `sourceStage` provenance, alongside the
// pre-existing standard title field, unaffected.
unittest {
    import stages.contract : EventKind;

    auto html = `<html><head>` ~
        `<title>Example Article</title>` ~
        `<meta property="og:site_name" content="Example News">` ~
        `<meta property="og:description" content="A real article summary.">` ~
        `<link rel="license" href="https://creativecommons.org/licenses/by/4.0/">` ~
        `</head><body><p>Article body text.</p></body></html>`;
    auto event = runHtmlMetadataAnnotate(html);
    assert(event.kind == EventKind.emitted);
    auto metadata = event.payload.metadata;
    assert(metadata.standardValue(StandardMetadataKey.title) == "Example Article",
        "pre-existing standard-field behavior must be unaffected");
    assert(extensionValue(metadata, htmlMetadataAnnotateSiteNameKeyV1) == "Example News");
    assert(extensionValue(metadata, htmlMetadataAnnotateDescriptionKeyV1) ==
        "A real article summary.");
    assert(extensionValue(metadata, htmlMetadataAnnotateLicenseKeyV1) ==
        "https://creativecommons.org/licenses/by/4.0/");
    foreach (key; [htmlMetadataAnnotateSiteNameKeyV1, htmlMetadataAnnotateDescriptionKeyV1,
            htmlMetadataAnnotateLicenseKeyV1]) {
        bool found;
        foreach (field; metadata.extensionFields) if (field.key == key) {
            assert(field.sourceStage == htmlMetadataAnnotateStageKeyV1);
            found = true;
        }
        assert(found);
    }
}

// Absent evidence for the new fields writes no extension field at all --
// matching the pre-existing "selected only" rule `annotateSelected` already
// enforces for the four standard fields.
unittest {
    import stages.contract : EventKind;

    auto html = `<html><head><title>No Extra Metadata</title></head>` ~
        `<body><p>Nothing else here.</p></body></html>`;
    auto event = runHtmlMetadataAnnotate(html);
    assert(event.kind == EventKind.emitted);
    auto metadata = event.payload.metadata;
    assert(metadata.extensionFieldCount == 0,
        "no extension field is written when the underlying evidence is absent");
}

// Issue #476's required overlap-avoidance proof: `topical-tags-extract`
// already extracts categories/tags evidence (issue #300 Slice 4), so this
// module deliberately does not duplicate that extraction (see the module
// doc comment). This proves, through the real compiled-job path (not an
// assertion in prose), that chaining `html-metadata-annotate` ahead of
// `topical-tags-extract` and `document-metadata-publish` in one job reaches
// *both* this module's own fields (title/siteName/description/license) and
// `topical-tags-extract`'s declared-tag structured section in the exact
// same published `document-metadata` envelope -- the "thin integration
// point" the accepted contract allows, with zero new glue code: both stages
// already write into the same `StageDocument.metadata` accumulator and
// already declare compatible raw-HTML shapes.
unittest {
    import composition.compiler : compileJob;
    import composition.job_executor : runCompiledJob;
    import content.pieces : Content, ContentPiece;
    import domain.document : Document, OutputName, SourceLocator;
    import domain.document_metadata : decodeDocumentMetadataV2;
    import effects.document_metadata_publish_stage : documentMetadataPublishKeyV1;
    import effects.topical_tags_extract_stage; // registers "topical-tags-extract"
    import job.json : parseJobJson;
    import stages.contract : EventKind;

    auto html = `<html><head>` ~
        `<title>Chained Article</title>` ~
        `<meta property="og:site_name" content="Example News">` ~
        `<meta name="description" content="Chained fixture description.">` ~
        `<meta name="keywords" content="Cooking, Baking">` ~
        `</head><body><a rel="tag" href="/tags/kitchen">Kitchen</a>` ~
        `<p>An article about cooking and baking in the kitchen.</p></body></html>`;
    auto spec = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"meta","implementation":"html-metadata-annotate","options":{},"filters":[]},` ~
        `{"id":"tags","implementation":"topical-tags-extract","options":{},"filters":[]},` ~
        `{"id":"publish","implementation":"document-metadata-publish",` ~
        `"options":{},"filters":[]}]}`);
    auto plan = compileJob(spec);
    assert(plan.stages.length == 3, "the chain must compile: no shape conflict between stages");
    auto document = Document(SourceLocator("fixture:v1", "/tmp", "record"),
        OutputName("record.html"));
    auto input = StageDocument(document, new Content([ContentPiece.own(cast(const(ubyte)[]) html)]));
    auto events = runCompiledJob(input, plan);
    assert(events.length == 1 && events[0].kind == EventKind.emitted);
    auto event = events[0];
    assert(event.payload.content.copy() == cast(const(ubyte)[]) html,
        "content must still pass through both stages completely unmodified");
    assert(event.sideOutputs.length == 1 &&
        event.sideOutputs[0].key == documentMetadataPublishKeyV1);

    auto decoded = decodeDocumentMetadataV2(document.id,
        cast(string) event.sideOutputs[0].bytes());
    // This module's own fields, reaching the terminal publish unchanged.
    assert(decoded.standardValue(StandardMetadataKey.title) == "Chained Article");
    assert(hasExtensionKey(decoded, htmlMetadataAnnotateSiteNameKeyV1));
    assert(extensionValue(decoded, htmlMetadataAnnotateSiteNameKeyV1) == "Example News");
    assert(hasExtensionKey(decoded, htmlMetadataAnnotateDescriptionKeyV1));
    // `topical-tags-extract`'s own declared-tag structured section, reached
    // through the exact same envelope with no code in this module aware of
    // it at all -- the real reuse proof. (Decoding the section's own payload
    // is exhaustively covered by `effects.topical_tags_extract_stage`'s own
    // test suite; the point proven here is that *this* module's fields and
    // that stage's structured section land in one shared envelope together,
    // not a second, independent decode of that stage's own output shape.)
    assert(decoded.structuredSectionCount == 1);
    assert(decoded.structuredSections[0].sectionId == "topical-tags");
    assert(decoded.structuredSections[0].sourceStage == "topical-tags-extract");
}
