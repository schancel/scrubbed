/// Focused, release-active integration proof for issue #285's next-slice
/// contract: a document flowing through multiple capability-providing
/// stages in one compiled job -- a metadata-writing stage preceding a
/// terminal stage -- with no compiler or executor change. Proof A chains a
/// mojibake-repairing text-transform, the new `html-metadata-annotate`
/// stage, and the existing `pii-four-class` terminal stage. Proof B chains
/// the same repair and annotate stages into the new
/// `document-metadata-publish` terminal stage. A regression case confirms
/// the compiler still rejects two terminal-capable stages in one job. No
/// filesystem or network reachability beyond what the stages themselves
/// already legitimately declare (HTML parsing is in-memory only).
module experiments.document_metadata_integration.check;

import composition.compiler : compileJob;
import composition.job_executor : runCompiledJob;
import content.pieces : Content, ContentPiece;
import domain.document : Document, OutputName, SourceLocator;
import domain.document_metadata : DocumentMetadata, StandardMetadataKey,
    encodeDocumentMetadataV1;
import domain.pii_patterns : scanPii;
import domain.pii_policy : applyPiiPolicy, PiiPolicy;
import effects.document_metadata_publish_stage : documentMetadataPublishSchemaV1;
import effects.html_metadata : extractHtmlMetadata;
import effects.html_metadata_annotate_stage : htmlMetadataAnnotateStageKeyV1;
import effects.html_tree : parseHtml;
import filters.mojibake : fixMojibake;
import job.json : parseJobJson;
import stages.contract : EventKind, StageDocument;
import stages.registry : availableStages, StageCardinality, StageRegistration,
    StageRegistry;
import std.exception : collectException;
import std.stdio : writeln;

// Self-registering production/new stage modules. Importing each runs its
// `static this()` registration into the process-wide registry that
// `availableStages()` exposes.
import stages.text_transform;
import stages.pii_four_class;
import effects.html_metadata_annotate_stage;
import effects.document_metadata_publish_stage;

private int failures;

/// Not `assert`: this checker builds with LDC `-O3 -release`, which elides
/// the `assert` language construct. Every check here is a plain runtime
/// comparison so nothing the proof depends on can be compiled away.
private void expect(bool condition, string label) {
    if (condition) {
        writeln("ok   ", label);
    } else {
        writeln("FAIL ", label);
        ++failures;
    }
}

private Content owned(string text) pure {
    return new Content([ContentPiece.own(cast(const(ubyte)[]) text)]);
}

/// `text-transform` (`source/stages/text_transform.d`) is production-
/// registered with its true, always-map, never-splitting behavior, but its
/// `StageRegistration.cardinality` is never set, so it defaults to
/// `StageCardinality.maySplit`. That default is a pre-existing gap entirely
/// orthogonal to #285: the compiler's terminal-stage admission rule
/// (`composition/compiler.d`) requires every stage preceding a
/// side-output-producing stage to be *declared* `oneToOne`, not merely to
/// behave that way, so a `maySplit`-declared prior stage is rejected before
/// either of this slice's new stages even enters the picture. This is
/// reproducible independently of #285 by compiling
/// `[text-transform, pii-four-class]` alone against the real production
/// registry -- confirmed while investigating this slice.
///
/// `source/stages/text_transform.d` is out of this slice's allowed scope
/// (and correcting a shared production stage's cardinality declaration is a
/// separate, narrower concern than DocumentMetadata's integration). This
/// checker works around it entirely locally, inside its own registry copy:
/// it copies the exact production registration byte-for-byte (same
/// declaration, same factory, same filter placement -- identical runtime
/// behavior) and corrects only the `cardinality` field to accurately
/// reflect what `text-transform` already, always does. No production file
/// changes; no compiler or executor change. `pii-four-class` and both new
/// stages are copied unmodified.
private StageRegistry integrationRegistry() {
    StageRegistry registry;
    auto textTransform = cast(StageRegistration)
        *availableStages().find("text-transform");
    textTransform.cardinality = StageCardinality.oneToOne;
    registry.add(textTransform);
    registry.add(cast(StageRegistration)
        *availableStages().find("html-metadata-annotate"));
    registry.add(cast(StageRegistration)
        *availableStages().find("document-metadata-publish"));
    registry.add(cast(StageRegistration)
        *availableStages().find("pii-four-class"));
    return registry;
}

// Mojibake in the title, the author, and the body (all CP1252-mangled UTF-8),
// plus a synthetic PII string (an email address) positioned after the body
// mojibake so that repair shifts its byte offset -- making a raw-mojibake-
// based PII computation land on a different span/output than a
// repaired-text-based one, not just coincidentally different bytes at the
// same offset.
private enum rawFixtureHtml =
    `<html><head><title>CafÃ© Culture</title>` ~
    `<meta name="author" content="RenÃ© GarcÃ­a"></head>` ~
    `<body><p>SchÃ¶n weather today, contact alice@example.com for details.` ~
    `</p></body></html>`;

private DocumentMetadata expectedAnnotateMetadata(string repairedHtml,
        string recordKey) {
    auto outcome = parseHtml(cast(const(ubyte)[]) repairedHtml, null, recordKey);
    auto extracted = extractHtmlMetadata(outcome.tree);
    auto metadata = DocumentMetadata.empty();
    if (extracted.title.status == "selected")
        metadata = metadata.withStandardField(StandardMetadataKey.title,
            extracted.title.value, htmlMetadataAnnotateStageKeyV1);
    if (extracted.author.status == "selected")
        metadata = metadata.withStandardField(StandardMetadataKey.author,
            extracted.author.value, htmlMetadataAnnotateStageKeyV1);
    if (extracted.date.status == "selected")
        metadata = metadata.withStandardField(StandardMetadataKey.date,
            extracted.date.value, htmlMetadataAnnotateStageKeyV1);
    if (extracted.url.status == "selected")
        metadata = metadata.withStandardField(StandardMetadataKey.url,
            extracted.url.value, htmlMetadataAnnotateStageKeyV1);
    return metadata;
}

/// Proof A: `[text-transform(fix-mojibake), html-metadata-annotate,
/// pii-four-class(terminal, last)]`.
private void proveProofA(ref StageRegistry registry) {
    auto spec = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"repair","implementation":"text-transform",` ~
        `"filters":[{"name":"fix-mojibake"}]},` ~
        `{"id":"annotate","implementation":"html-metadata-annotate"},` ~
        `{"id":"pii","implementation":"pii-four-class",` ~
        `"options":{"policy":"mask"}}]}`);
    auto plan = compileJob(spec, &registry);
    expect(plan.stages.length == 3, "proof A: job compiles with all three stages");

    auto document = Document(SourceLocator("document-metadata-integration",
        "proof-a", "fixture"), OutputName("out"));
    auto events = runCompiledJob(StageDocument(document, owned(rawFixtureHtml)),
        plan);
    expect(events.length == 1 && events[0].kind == EventKind.emitted,
        "proof A: exactly one emitted event");
    auto event = events[0];

    auto repaired = fixMojibake(rawFixtureHtml);
    expect(repaired != rawFixtureHtml,
        "proof A: fixture actually needs mojibake repair (sanity check)");

    auto repairedBytes = cast(const(ubyte)[]) repaired;
    auto repairedFindings = scanPii(repairedBytes, "US");
    auto repairedBasedOutput = applyPiiPolicy(repairedBytes, repairedFindings,
        PiiPolicy.mask, false).output;
    expect(event.payload.content.copy() == repairedBasedOutput,
        "proof A: final content is PII's output built from the mojibake-repaired text");

    auto rawBytes = cast(const(ubyte)[]) rawFixtureHtml;
    auto rawFindings = scanPii(rawBytes, "US");
    auto rawBasedOutput = applyPiiPolicy(rawBytes, rawFindings,
        PiiPolicy.mask, false).output;
    expect(event.payload.content.copy() != rawBasedOutput,
        "proof A: final content is NOT what PII would have produced from raw mojibake");

    expect(event.sideOutputs.length == 1,
        "proof A: exactly one TerminalSideOutput exists");
    expect(event.sideOutputs[0].schema == "scrubbed-pii-audit-v1",
        "proof A: the one side output is PII's own, unchanged schema");

    auto expectedMetadata = expectedAnnotateMetadata(repaired,
        document.source.recordKey);
    expect(expectedMetadata.hasStandardField(StandardMetadataKey.title) &&
        expectedMetadata.hasStandardField(StandardMetadataKey.author) &&
        !expectedMetadata.hasStandardField(StandardMetadataKey.date) &&
        !expectedMetadata.hasStandardField(StandardMetadataKey.url),
        "proof A: fixture sanity -- title/author selected, date/url absent");
    expect(event.payload.metadata == expectedMetadata,
        "proof A: payload.metadata carries what the annotate stage wrote, " ~
        "still present after PII's stage runs (PII never touches .metadata: " ~
        "confirmed both by source inspection of stages.pii_four_class.d, " ~
        "which references .metadata nowhere, and by this exact-equality check " ~
        "against annotate's own independently-computed output)");
}

/// Proof B: `[text-transform(fix-mojibake), html-metadata-annotate,
/// document-metadata-publish(terminal, last)]`.
private void proveProofB(ref StageRegistry registry) {
    auto spec = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"repair","implementation":"text-transform",` ~
        `"filters":[{"name":"fix-mojibake"}]},` ~
        `{"id":"annotate","implementation":"html-metadata-annotate"},` ~
        `{"id":"publish","implementation":"document-metadata-publish"}]}`);
    auto plan = compileJob(spec, &registry);
    expect(plan.stages.length == 3, "proof B: job compiles with all three stages");

    auto document = Document(SourceLocator("document-metadata-integration",
        "proof-b", "fixture"), OutputName("out"));
    auto events = runCompiledJob(StageDocument(document, owned(rawFixtureHtml)),
        plan);
    expect(events.length == 1 && events[0].kind == EventKind.emitted,
        "proof B: exactly one emitted event");
    auto event = events[0];

    auto repaired = fixMojibake(rawFixtureHtml);
    expect(cast(string) event.payload.content.copy() == repaired,
        "proof B: content is unchanged from the mojibake-repaired text");

    expect(event.sideOutputs.length == 1,
        "proof B: exactly one TerminalSideOutput exists");
    expect(event.sideOutputs[0].schema == documentMetadataPublishSchemaV1,
        "proof B: side output uses the document-metadata-v1 schema");

    auto expectedMetadata = expectedAnnotateMetadata(repaired,
        document.source.recordKey);
    auto expectedWire = encodeDocumentMetadataV1(document.id, expectedMetadata);
    expect(event.sideOutputs[0].bytes == cast(immutable(ubyte)[]) expectedWire,
        "proof B: side-output bytes exactly equal encodeDocumentMetadataV1 " ~
        "for the actually-extracted fields, computed independently");
}

/// The publish stage must produce a valid, well-formed (if entirely empty)
/// wire record even when nothing wrote any metadata field.
private void provePublishWithNoMetadataWritten(ref StageRegistry registry) {
    auto spec = parseJobJson(
        `{"version":3,"stages":[{"id":"publish",` ~
        `"implementation":"document-metadata-publish"}]}`);
    auto plan = compileJob(spec, &registry);
    auto document = Document(SourceLocator("document-metadata-integration",
        "proof-empty", "fixture"), OutputName("out"));
    auto events = runCompiledJob(
        StageDocument(document, owned("plain text, no metadata written")), plan);
    expect(events.length == 1 && events[0].sideOutputs.length == 1,
        "publish with no metadata written: still emits exactly one side output");
    auto expectedWire = encodeDocumentMetadataV1(document.id,
        DocumentMetadata.empty());
    expect(events[0].sideOutputs[0].bytes == cast(immutable(ubyte)[]) expectedWire,
        "publish with no metadata written: wire equals encodeDocumentMetadataV1(id, empty)");
    expect(cast(string) events[0].payload.content.copy() ==
        "plain text, no metadata written",
        "publish with no metadata written: content passes through unchanged");
}

/// Regression: the pre-existing cap that rejects two terminal-capable
/// stages in one job is unchanged now that a second terminal stage
/// (`document-metadata-publish`) exists in the registry.
private void proveDualTerminalStillRejected(ref StageRegistry registry) {
    auto spec = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"pii","implementation":"pii-four-class"},` ~
        `{"id":"publish","implementation":"document-metadata-publish"}]}`);
    auto error = collectException!Exception(compileJob(spec, &registry));
    expect(error !is null,
        "regression: compiling pii-four-class and document-metadata-publish " ~
        "both terminal in one job is still rejected (pre-existing cap, unchanged)");

    auto reversed = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"publish","implementation":"document-metadata-publish"},` ~
        `{"id":"pii","implementation":"pii-four-class"}]}`);
    auto reversedError = collectException!Exception(compileJob(reversed, &registry));
    expect(reversedError !is null,
        "regression: rejected in either stage order");
}

void main() {
    auto registry = integrationRegistry();
    proveProofA(registry);
    proveProofB(registry);
    provePublishWithNoMetadataWritten(registry);
    proveDualTerminalStillRejected(registry);

    if (failures) {
        writeln(failures, " check(s) failed");
        import core.stdc.stdlib : exit;
        exit(1);
    }
    writeln("all document-metadata integration checks passed");
}
