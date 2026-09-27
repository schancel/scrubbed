/// Self-registering, terminal v3 stage (`language-id-detect`, issue #311's
/// accepted contract): wires the existing, unmodified, frozen
/// `domain.language_id` classifier into the generic `--stage id=` reachable
/// composition path used by `html-main-content`/`pii-four-class`/
/// `topical-tags-extract` -- giving `domain.language_id` its first real
/// CLI/stage reachability. No new CLI subcommand; no domain-layer change.
///
/// Takes `StageDocument.content` raw bytes directly -- no HTML parsing, no
/// transformation -- matching `domain.language_id.detectLanguage`'s own
/// `const(ubyte)[] text` signature. Calls the existing
/// `buildLanguageIdentity(documentId, content)` to get a
/// `LanguageIdentityRecord`, then `encodeLanguageIdentity(record)` for the
/// wire bytes, and emits those bytes as this job's own single
/// `TerminalSideOutput`, mirroring `stages.pii_four_class`'s and
/// `effects.document_metadata_publish_stage`'s raw-bytes-in,
/// content-passthrough, single-terminal-side-output shape. `content` passes
/// through completely unmodified. No new domain logic: schema/versioning
/// (`languageIdSchema`/`algorithmVersion`/`profileTableIdentity`) is already
/// fully owned by `domain.language_id` itself.
///
/// **Abstention is not an error.** `detectLanguage`'s own typed
/// `LanguageAbstentionReason` values (`emptyText`, `oversizeText`,
/// `invalidUtf8`, `tooShort`, `unsupportedScript`, `mixedOrAmbiguous`,
/// `belowConfidenceThreshold`) are returned as ordinary data inside a
/// successfully built and encoded `LanguageIdentityRecord` -- via
/// `buildLanguageIdentity`, which calls `detectLanguage` internally -- so
/// this stage emits that record normally for every one of these routine
/// cases; it never quarantines for them. This stage only quarantines on a
/// genuine defensive-invariant failure inside `domain.language_id` itself
/// (a `checkLanguageIdentity` rejection surfaced through
/// `encodeLanguageIdentity`), which should not occur for any record
/// `buildLanguageIdentity` itself just built -- the same
/// catch-and-quarantine-with-a-fixed-reason idiom
/// `effects.compressibility_annotate_stage` and
/// `effects.topical_tags_extract_stage` both use for truly unexpected
/// internal errors, never for a metric/result that merely abstains.
module effects.language_id_detect_stage;

import domain.document : DocumentId;
import domain.language_id : LanguageIdentityRecord, buildLanguageIdentity,
    encodeLanguageIdentity;
import stages.contract : PassMode, ResourceDeclaration, StageDecision,
    StageDeclaration, StageDocument, TerminalSideOutput;
import stages.registry : ConfiguredStageTransform, FilterPlacement,
    SideOutputCapability, StageCardinality, StageConfiguration, StageOptions,
    StageRegistration, registerStage;

enum languageIdDetectStageKeyV1 = "language-id-detect";
enum languageIdDetectSideOutputKeyV1 = "language-id";
enum languageIdDetectSideOutputSchemaV1 = "scrubbed-language-id-v1";
enum languageIdDetectSideOutputSuffixV1 = ".language-id.bin";

// ---------------------------------------------------------------------------
// `domain.language_id` predates the configured-stage pure function boundary
// and is not itself marked `pure`, mirroring `stages.pii_four_class`'s own
// `scanPiiPure`/`applyPiiPolicyPure` wrappers (and
// `effects.topical_tags_extract_stage`'s equivalents) for exactly the same
// reason: these are deterministic, side-effect-free domain functions with
// no `pure` annotation on their declarations.
// ---------------------------------------------------------------------------

private LanguageIdentityRecord buildLanguageIdentityPure(DocumentId documentId,
        const(ubyte)[] text) pure @trusted {
    alias PureFn = LanguageIdentityRecord function(DocumentId, const(ubyte)[]) pure;
    return (cast(PureFn) &buildLanguageIdentity)(documentId, text);
}

private ubyte[] encodeLanguageIdentityPure(LanguageIdentityRecord value) pure @trusted {
    alias PureFn = ubyte[] function(LanguageIdentityRecord) pure;
    return (cast(PureFn) &encodeLanguageIdentity)(value);
}

private StageDecision applyLanguageIdDetect(StageDocument input,
        immutable(StageConfiguration)) pure {
    auto content = input.content.copy();
    ubyte[] encoded;
    try {
        auto record = buildLanguageIdentityPure(input.document.id, content);
        encoded = encodeLanguageIdentityPure(record);
    } catch (Exception) {
        // A genuine internal-invariant failure -- `checkLanguageIdentity`
        // (run inside `encodeLanguageIdentity`) rejecting a record
        // `buildLanguageIdentity` itself just built. Never raised merely
        // because detection abstained: every `LanguageAbstentionReason` is
        // carried as ordinary, successfully encoded data, above.
        return StageDecision.quarantine("language-id-detect: internal invariant failure");
    }
    auto sideOutput = TerminalSideOutput(languageIdDetectSideOutputKeyV1,
        languageIdDetectSideOutputSchemaV1, languageIdDetectSideOutputSuffixV1,
        encoded);
    // `content` passes through unchanged.
    return StageDecision.map(input, [sideOutput]);
}

private ConfiguredStageTransform factory(const ref StageOptions options) {
    return ConfiguredStageTransform(&applyLanguageIdDetect);
}

static this() {
    registerStage(StageRegistration(StageDeclaration(languageIdDetectStageKeyV1,
        PassMode.singlePass, ResourceDeclaration(1, 1024 * 1024)),
        null, null, null, &factory, FilterPlacement.none,
        StageCardinality.oneToOne, SideOutputCapability.terminal));
}

// ---------------------------------------------------------------------------
// Unit tests.
// ---------------------------------------------------------------------------

version (unittest) {
    import composition.compiler : compileJob;
    import composition.executor : runCompiledStage;
    import content.pieces : Content, ContentPiece;
    import domain.document : Document, OutputName, SourceLocator;
    import domain.language_id : LanguageAbstentionReason, LanguageDetectionStatus,
        decodeLanguageIdentity, maxLanguageIdTextBytes;
    import job.json : parseJobJson;
    import stages.contract : EventKind, StageEvent;

    private Document fixtureDocument() {
        return Document(SourceLocator("local-html:v1", "/tmp", "a.txt"), OutputName("a.txt.lang"));
    }

    /// Runs the real self-registered stage through `compileJob` +
    /// `runCompiledStage` -- the actual registry/executor path, not a direct
    /// call into a private function.
    private StageEvent runLanguageIdDetect(const(ubyte)[] content) {
        auto spec = parseJobJson(`{"version":3,"stages":[{"id":"detect",` ~
            `"implementation":"` ~ languageIdDetectStageKeyV1 ~ `","options":{},"filters":[]}]}`);
        auto plan = compileJob(spec);
        auto input = StageDocument(fixtureDocument(),
            new Content([ContentPiece.own(content)]));
        auto result = runCompiledStage([input], plan.stages[0]);
        assert(result.events.length == 1);
        return result.events[0];
    }

    private LanguageIdentityRecord decodedRecord(StageEvent event, const(ubyte)[] content) {
        assert(event.kind == EventKind.emitted);
        assert(event.sideOutputs.length == 1);
        auto sideOutput = event.sideOutputs[0];
        assert(sideOutput.key == languageIdDetectSideOutputKeyV1);
        assert(sideOutput.schema == languageIdDetectSideOutputSchemaV1);
        assert(sideOutput.suffix == languageIdDetectSideOutputSuffixV1);
        import crypto.sha256 : sha256Of;
        return decodeLanguageIdentity(sideOutput.bytes, fixtureDocument().id, sha256Of(content));
    }
}

// A plain, plausible English sentence is detected, and `content` passes
// through unchanged.
unittest {
    auto text = cast(const(ubyte)[]) "This is a short but plain example sentence for testing purposes today.";
    auto event = runLanguageIdDetect(text);
    assert(event.payload.content.copy() == text);
    auto record = decodedRecord(event, text);
    assert(record.result.status == LanguageDetectionStatus.detected);
    assert(record.result.reason == LanguageAbstentionReason.none);
    // Matches a direct in-process call on the same input, byte-for-byte.
    auto direct = encodeLanguageIdentity(buildLanguageIdentity(fixtureDocument().id, text));
    assert(event.sideOutputs[0].bytes == direct);
}

// Empty content abstains cleanly (never quarantines) with the exact typed
// reason `detectLanguage` documents for empty input.
unittest {
    auto event = runLanguageIdDetect([]);
    auto record = decodedRecord(event, []);
    assert(record.result.status == LanguageDetectionStatus.abstained);
    assert(record.result.reason == LanguageAbstentionReason.emptyText);
}

// Oversize content (over `maxLanguageIdTextBytes`) abstains cleanly, never
// quarantines, and still passes `content` through unmodified.
unittest {
    auto oversized = new ubyte[maxLanguageIdTextBytes + 1];
    oversized[] = cast(ubyte) 'a';
    auto event = runLanguageIdDetect(oversized);
    auto record = decodedRecord(event, oversized);
    assert(record.result.status == LanguageDetectionStatus.abstained);
    assert(record.result.reason == LanguageAbstentionReason.oversizeText);
    assert(event.payload.content.copy() == oversized);
}

// Invalid UTF-8 abstains cleanly, never quarantines.
unittest {
    ubyte[3] invalid = [0xff, 0xfe, 0xfd];
    auto event = runLanguageIdDetect(invalid[]);
    auto record = decodedRecord(event, invalid[]);
    assert(record.result.status == LanguageDetectionStatus.abstained);
    assert(record.result.reason == LanguageAbstentionReason.invalidUtf8);
}

// Unsupported-script text (all non-Latin letters, e.g. Han/CJK) abstains
// cleanly via `unsupportedScript`, never quarantines.
unittest {
    auto text = cast(const(ubyte)[]) "中文测试文本内容示例";
    auto event = runLanguageIdDetect(text);
    auto record = decodedRecord(event, text);
    assert(record.result.status == LanguageDetectionStatus.abstained);
    assert(record.result.reason == LanguageAbstentionReason.unsupportedScript);
}

// Below-confidence-threshold (or otherwise ambiguous/too-short) text also
// abstains cleanly, matching `detectLanguage`'s own direct result exactly --
// this stage adds no additional gating of its own.
unittest {
    auto text = cast(const(ubyte)[]) "ok";
    auto direct = buildLanguageIdentity(fixtureDocument().id, text);
    assert(direct.result.status == LanguageDetectionStatus.abstained);
    auto event = runLanguageIdDetect(text);
    auto record = decodedRecord(event, text);
    assert(record.result.status == LanguageDetectionStatus.abstained);
    assert(record.result.reason == direct.result.reason);
}

// Reachability: the stage is genuinely self-registering (importing this
// module is enough) and a job consisting of only this terminal stage
// compiles and runs.
unittest {
    auto spec = parseJobJson(`{"version":3,"stages":[{"id":"detect",` ~
        `"implementation":"` ~ languageIdDetectStageKeyV1 ~ `","options":{},"filters":[]}]}`);
    auto plan = compileJob(spec);
    assert(plan.stages.length == 1);
    assert(plan.stages[0].sideOutputCapability == SideOutputCapability.terminal);
    auto text = cast(const(ubyte)[]) "Solo reachability fixture sentence for the stage itself.";
    auto input = StageDocument(fixtureDocument(),
        new Content([ContentPiece.own(text)]));
    auto result = runCompiledStage([input], plan.stages[0]);
    assert(result.events.length == 1 && result.events[0].kind == EventKind.emitted);
}
