/// Release-active proof for the v3 self-registering `html-main-content`
/// stage (issue #26 next-slice: `source/effects/html_main_content_stage.d`).
/// Fixtures run through the compiled stage boundary
/// (`composition.compiler`/`composition.executor`), not just the frozen
/// `effects.html_main_content.extractMainContent` pure function, which has
/// its own separate, untouched checker (`experiments/html_main_content/
/// check.d`). Proves: successful selection replaces content and preserves
/// any prior `.metadata`; each reachable abstention status quarantines with
/// the exact status-name reason string; the raw-byte cap quarantines with
/// reason `rawLimit`; a parse failure quarantines with a nonempty reason,
/// including the specific `observationLimit` reason for a document large
/// enough to exceed `html_tree.d`'s native-observation cap.
///
/// `abstainedNoCandidate` is not exercised here: per
/// `docs/html-main-content.md`, real parsed HTML always has at least one
/// root element node, so that status is only reachable from a degenerate,
/// empty `HtmlTree` -- unreachable through this stage's real `parseHtml` ->
/// `extractMainContent` path, exactly as `experiments/html_main_content/
/// check.d` itself documents for the underlying pure function. The stage's
/// own quarantine branch (`applyHtmlMainContent`) has a single,
/// undifferentiated `result.status.to!string` statement for every
/// non-`selected` status, so proving it correct for the two reachable
/// abstentions below (`abstainedBelowThreshold`, `abstainedTie`) exercises
/// the identical code path `abstainedNoCandidate` would take.
///
/// **Disclosed finding**: `HtmlMainContentOutputLimit`/`"outputLimit"` (the
/// stage's item-6 handling for `extractMainContent`'s 4 MiB collected-text
/// cap, `maxMainContentTextBytes`) is implemented exactly per contract but
/// is *not reachable through any real byte input* to this stage. Confirmed
/// experimentally: `html_tree.d`'s own native-observation accounting
/// (`maxObservationBytes`, a fixed 1 MiB cap on total bytes observed while
/// building the parsed tree -- unrelated to and independent of this stage's
/// own configurable `max-html-bytes` option) always binds first for any
/// document large enough to approach 4 MiB of collected text, failing parse
/// with `HtmlFailureReason.observationLimit` before `extractMainContent`
/// ever runs. This differs from `html-markdown-stage`'s own `"outputLimit"`,
/// which genuinely is reachable, because Markdown rendering can structurally
/// *amplify* a small parsed tree past 4 MiB (for example nested-list
/// indentation duplicated per line), whereas main-content's plain-text
/// collection only ever concatenates and whitespace-collapses already-observed
/// text, so it can never produce more output than was observed as input.
/// `html_tree.d` is out of this slice's allowed scope to change (not listed
/// among the allowed files), so this is disclosed here, not patched around,
/// exactly the same class of documented, out-of-scope-to-fix unreachability
/// as `abstainedNoCandidate` already is for the underlying pure function.
///
/// Because this checker builds with LDC `-O3 -release` (which elides the
/// `assert` language construct), every check here is a plain runtime
/// comparison, matching `experiments/document_metadata_integration/check.d`'s
/// own `expect`-not-`assert` pattern.
module experiments.html_main_content_stage.check;

import composition.compiler : compileJob;
import composition.executor : runCompiledStage;
import content.pieces : Content, ContentPiece;
import domain.document : Document, OutputName, SourceLocator;
import domain.document_metadata : DocumentMetadata, StandardMetadataKey;
import effects.html_main_content : maxMainContentTextBytes;
import effects.html_tree : defaultExtractHtmlBytes;
import job.json : parseJobJson;
import stages.contract : EventKind, StageDocument;
import std.algorithm.searching : canFind;
import std.stdio : writeln;

// Self-registering stage module under test.
import effects.html_main_content_stage;

private int failures;

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

private auto compiledStage(string optionsJson = "{}") {
    auto spec = parseJobJson(`{"version":3,"stages":[{"id":"extract",` ~
        `"implementation":"html-main-content","options":` ~ optionsJson ~
        `,"filters":[]}]}`);
    auto plan = compileJob(spec);
    return plan.stages[0];
}

private Document fixtureDocument() {
    return Document(SourceLocator("html-main-content-stage-check", "fixture",
        "record"), OutputName("record.html"));
}

private string longArticleParagraph() {
    string paragraph;
    foreach (_; 0 .. 25) paragraph ~= "Article body sentence. ";
    return paragraph;
}

private void proveSuccessfulSelectionPreservesMetadata() {
    auto stage = compiledStage();
    string html = "<nav>Home About Contact</nav><article><p>" ~
        longArticleParagraph() ~ "</p></article>";
    auto document = fixtureDocument();
    auto metadata = DocumentMetadata.empty().withStandardField(
        StandardMetadataKey.title, "Prior Title", "html-metadata-annotate");
    auto input = StageDocument(document, owned(html), metadata);
    auto result = runCompiledStage([input], stage);
    expect(result.events.length == 1 && result.events[0].kind == EventKind.emitted,
        "selection: exactly one emitted event");
    auto event = result.events[0];
    expect(event.payload.document.id == document.id,
        "selection: document identity preserved");
    expect(event.payload.metadata == metadata,
        "selection: prior .metadata passes through untouched");
    auto text = cast(string) event.payload.content.copy();
    expect(text.canFind("Article body sentence."),
        "selection: selected article text is present in the replaced content");
    expect(!text.canFind("Home About Contact"),
        "selection: discarded nav boilerplate is absent from the replaced content");
}

private void proveAbstainedBelowThresholdQuarantines() {
    auto stage = compiledStage();
    auto document = fixtureDocument();
    auto metadata = DocumentMetadata.empty().withStandardField(
        StandardMetadataKey.title, "Prior Title", "html-metadata-annotate");
    auto input = StageDocument(document,
        owned("<nav>Home About Contact</nav>"), metadata);
    auto result = runCompiledStage([input], stage);
    expect(result.events.length == 1 &&
        result.events[0].kind == EventKind.quarantined &&
        result.events[0].reason == "abstainedBelowThreshold",
        "abstainedBelowThreshold: quarantines with the exact status-name reason");
}

private void proveAbstainedTieQuarantines() {
    auto stage = compiledStage();
    string paragraph = longArticleParagraph();
    string html = "<article><p>" ~ paragraph ~ "</p></article>" ~
        "<article><p>" ~ paragraph ~ "</p></article>";
    auto document = fixtureDocument();
    auto input = StageDocument(document, owned(html));
    auto result = runCompiledStage([input], stage);
    expect(result.events.length == 1 &&
        result.events[0].kind == EventKind.quarantined &&
        result.events[0].reason == "abstainedTie",
        "abstainedTie: quarantines with the exact status-name reason");
}

private void proveParseFailureQuarantines() {
    auto stage = compiledStage();
    auto document = fixtureDocument();
    auto badUtf8 = StageDocument(document,
        new Content([ContentPiece.own([cast(ubyte) 0xff])]));
    auto result = runCompiledStage([badUtf8], stage);
    expect(result.events.length == 1 &&
        result.events[0].kind == EventKind.quarantined &&
        result.events[0].reason.length != 0,
        "parse failure: quarantines with a nonempty reason");
}

private void proveRawByteCapQuarantines() {
    auto stage = compiledStage();
    auto document = fixtureDocument();
    auto input = StageDocument(document,
        new Content([ContentPiece.own(new ubyte[defaultExtractHtmlBytes + 1])]));
    auto result = runCompiledStage([input], stage);
    expect(result.events.length == 1 &&
        result.events[0].kind == EventKind.quarantined &&
        result.events[0].reason == "rawLimit",
        "raw-byte cap: quarantines with reason rawLimit");
}

/// A higher configured raw-byte cap admits a document whose collected text
/// would approach `maxMainContentTextBytes` (4 MiB) past this stage's own
/// raw-byte gate -- but `html_tree.d`'s independent, fixed 1 MiB native-
/// observation cap (`maxObservationBytes`, unrelated to and unaffected by
/// `max-html-bytes`) binds first, failing parse with
/// `HtmlFailureReason.observationLimit` before `extractMainContent` ever
/// runs. See this module's header comment ("Disclosed finding") for why
/// `HtmlMainContentOutputLimit`/`"outputLimit"` itself is consequently
/// unreachable through any real byte input to this stage. This fixture
/// instead proves the specific, real, reachable `observationLimit` reason
/// for an over-cap document, distinct from the generic invalid-UTF-8 parse
/// failure already covered by `proveParseFailureQuarantines`.
private void proveObservationLimitQuarantines() {
    auto stage = compiledStage(`{"max-html-bytes":8388608}`);
    auto document = fixtureDocument();
    auto longText = new char[maxMainContentTextBytes + 1];
    longText[] = 'x';
    string html = "<article><p>" ~ cast(string) longText.idup ~ "</p></article>";
    auto input = StageDocument(document, owned(html));
    auto result = runCompiledStage([input], stage);
    expect(result.events.length == 1 &&
        result.events[0].kind == EventKind.quarantined &&
        result.events[0].reason == "observationLimit",
        "over-observation-cap document: quarantines with reason observationLimit " ~
        "(html_tree.d's fixed 1 MiB native-observation cap binds before " ~
        "extractMainContent's own 4 MiB output cap could ever be reached)");
}

void main() {
    proveSuccessfulSelectionPreservesMetadata();
    proveAbstainedBelowThresholdQuarantines();
    proveAbstainedTieQuarantines();
    proveParseFailureQuarantines();
    proveRawByteCapQuarantines();
    proveObservationLimitQuarantines();

    if (failures) {
        writeln(failures, " check(s) failed");
        import core.stdc.stdlib : exit;
        exit(1);
    }
    writeln("all html-main-content stage checks passed");
}
