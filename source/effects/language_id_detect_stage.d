/// Self-registering, annotate-only v3 stage (`language-id-detect`, issue
/// #300 Slice 2's accepted contract): wires the existing, unmodified, frozen
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
/// wire bytes, and writes those bytes into `StageDocument.metadata` as an
/// extension field, mirroring `effects.html_metadata_annotate_stage`'s and
/// `effects.compressibility_annotate_stage`'s exact
/// `SideOutputCapability.none`, write-into-the-shared-accumulator,
/// content-passthrough shape, to be published later by the existing,
/// unmodified `document-metadata-publish` terminal stage. `content` passes
/// through completely unmodified. No new domain logic: schema/versioning
/// (`languageIdSchema`/`algorithmVersion`/`profileTableIdentity`) is already
/// fully owned by `domain.language_id` itself, and the encoded record fits
/// comfortably inside `document-metadata:v1`'s frozen 512-byte scalar
/// extension-value cap.
///
/// **Abstention is not an error.** `detectLanguage`'s own typed
/// `LanguageAbstentionReason` values (`emptyText`, `oversizeText`,
/// `invalidUtf8`, `tooShort`, `unsupportedScript`, `mixedOrAmbiguous`,
/// `belowConfidenceThreshold`) are returned as ordinary data inside a
/// successfully built and encoded `LanguageIdentityRecord` -- via
/// `buildLanguageIdentity`, which calls `detectLanguage` internally -- so
/// this stage writes that record normally for every one of these routine
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
    StageDeclaration, StageDocument;
import stages.registry : ConfiguredStageTransform, FilterPlacement,
    SideOutputCapability, StageCardinality, StageConfiguration, StageOptions,
    StageRegistration, registerStage;

enum languageIdDetectStageKeyV1 = "language-id-detect";
enum languageIdDetectExtensionKeyV1 = "language-id";

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
    input.metadata = input.metadata.withExtensionField(languageIdDetectExtensionKeyV1,
        encoded.idup, languageIdDetectStageKeyV1);
    // `content` passes through unchanged.
    return StageDecision.map(input);
}

private ConfiguredStageTransform factory(const ref StageOptions options) {
    return ConfiguredStageTransform(&applyLanguageIdDetect);
}

static this() {
    registerStage(StageRegistration(StageDeclaration(languageIdDetectStageKeyV1,
        PassMode.singlePass, ResourceDeclaration(1, 1024 * 1024)),
        null, null, null, &factory, FilterPlacement.none,
        StageCardinality.oneToOne, SideOutputCapability.none));
}

// ---------------------------------------------------------------------------
// Unit tests.
// ---------------------------------------------------------------------------

version (unittest) {
    import composition.compiler : compileJob;
    import composition.executor : runCompiledStage;
    import composition.job_executor : runCompiledJob;
    import content.pieces : Content, ContentPiece;
    import domain.document : Document, OutputName, SourceLocator;
    import domain.document_metadata : decodeDocumentMetadataV1;
    import domain.language_id : LanguageAbstentionReason, LanguageDetectionStatus,
        decodeLanguageIdentity, maxLanguageIdTextBytes;
    import effects.document_metadata_publish_stage : documentMetadataPublishKeyV1;
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

    /// Reads the extension field this stage writes into `StageDocument
    /// .metadata` (no more standalone `TerminalSideOutput`) and decodes it.
    private LanguageIdentityRecord decodedRecord(StageEvent event, const(ubyte)[] content) {
        assert(event.kind == EventKind.emitted);
        auto fields = event.payload.metadata.extensionFields;
        assert(fields.length == 1);
        assert(fields[0].key == languageIdDetectExtensionKeyV1);
        assert(fields[0].sourceStage == languageIdDetectStageKeyV1);
        import crypto.sha256 : sha256Of;
        return decodeLanguageIdentity(fields[0].value, fixtureDocument().id, sha256Of(content));
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
    assert(event.payload.metadata.extensionFields[0].value == direct);
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
// module is enough), registers `SideOutputCapability.none` (not `.terminal`
// -- issue #300 Slice 2), and a job consisting of only this annotate-only
// stage compiles and runs.
unittest {
    auto spec = parseJobJson(`{"version":3,"stages":[{"id":"detect",` ~
        `"implementation":"` ~ languageIdDetectStageKeyV1 ~ `","options":{},"filters":[]}]}`);
    auto plan = compileJob(spec);
    assert(plan.stages.length == 1);
    assert(plan.stages[0].sideOutputCapability == SideOutputCapability.none);
    auto text = cast(const(ubyte)[]) "Solo reachability fixture sentence for the stage itself.";
    auto input = StageDocument(fixtureDocument(),
        new Content([ContentPiece.own(text)]));
    auto result = runCompiledStage([input], plan.stages[0]);
    assert(result.events.length == 1 && result.events[0].kind == EventKind.emitted);
}

// Regression proof (issue #300 Slice 2's core acceptance criterion):
// `[language-id-detect, document-metadata-publish]` compiles and runs as one
// job via `compileJob`/`runCompiledJob`, and the terminal `document-metadata
// :v1` side output's decoded metadata carries exactly the `language-id`
// extension field this stage wrote -- which, decoded, equals exactly the
// `LanguageIdentityRecord` the old standalone terminal stage would have
// produced for the same input.
unittest {
    auto spec = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"detect","implementation":"` ~ languageIdDetectStageKeyV1 ~
        `","options":{},"filters":[]},` ~
        `{"id":"publish","implementation":"document-metadata-publish",` ~
        `"options":{},"filters":[]}]}`);
    auto plan = compileJob(spec);
    auto text = cast(const(ubyte)[])
        "A chained regression fixture sentence proving the accumulator path end to end.";
    auto document = fixtureDocument();
    auto input = StageDocument(document, new Content([ContentPiece.own(text)]));
    auto events = runCompiledJob(input, plan);
    assert(events.length == 1 && events[0].kind == EventKind.emitted);
    assert(events[0].sideOutputs.length == 1);
    auto sideOutput = events[0].sideOutputs[0];
    assert(sideOutput.key == documentMetadataPublishKeyV1);
    // `content` passed through both stages unmodified.
    assert(events[0].payload.content.copy() == text);

    auto decodedMetadata = decodeDocumentMetadataV1(document.id, cast(string) sideOutput.bytes());
    assert(decodedMetadata.extensionFieldCount == 1);
    auto field = decodedMetadata.extensionFields[0];
    assert(field.key == languageIdDetectExtensionKeyV1);
    assert(field.sourceStage == languageIdDetectStageKeyV1);

    import crypto.sha256 : sha256Of;
    auto chainedRecord = decodeLanguageIdentity(field.value, document.id, sha256Of(text));

    // Exactly the same `LanguageIdentityRecord` the old standalone
    // `language-id-detect` terminal stage would have produced for the same
    // input, via a direct in-process call.
    auto direct = buildLanguageIdentity(document.id, text);
    auto directEncoded = encodeLanguageIdentity(direct);
    auto directRecord = decodeLanguageIdentity(directEncoded, document.id, sha256Of(text));
    assert(chainedRecord == directRecord);
    assert(field.value == directEncoded);
}
