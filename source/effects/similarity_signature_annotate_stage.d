/// Self-registering, annotate-only v3 stage (`similarity-signature-annotate`,
/// issue #564's Option C first-slice contract): computes each document's
/// whole-document MinHash signature via the existing, unmodified, pure
/// `domain.similarity_signature.similaritySignatures` and publishes it into
/// `StageDocument.metadata` as a `document-metadata:v2` **structured
/// section** -- deliberately NOT a scalar extension field. A 64-lane
/// signature's `lanes` array alone is exactly 512 bytes
/// (`domain.similarity_signature.similarityLanes == 64`), which is the
/// entire `document_metadata.maxExtensionValueBytes` scalar cap with zero
/// room left for `hasKeys`, `contentLength`, or a version tag -- the
/// load-bearing correction issue #564's own design thread found the hard
/// way (see that issue's "Load-bearing correction to Option C's own text"
/// comment). `document-metadata:v2`'s structured-section mechanism
/// (`DocumentMetadata.withStructuredSection`, 2 MiB cap) is exactly the
/// precedent `stages.pii_four_class` already established for its own
/// large per-document payload.
///
/// Mirrors `effects.language_id_detect_stage`'s exact shape: self-
/// registering, `StageCardinality.oneToOne`, `SideOutputCapability.none`,
/// `content` passthrough, published later by the unchanged, unmodified
/// `document-metadata-publish` terminal stage (it already picks the v2 wire
/// automatically whenever a structured section is present -- see that
/// stage's own doc comment).
///
/// Document-level signature only, never segment-level (issue #564's explicit
/// scope: `effects.near_dedup_overlay`'s own pruning decision already only
/// ever consults document-level members for pruning eligibility;
/// segment-level richness is a separately-gated future capability, issue
/// #492).
///
/// `similaritySignatures` predates the configured-stage pure function
/// boundary and is not itself marked `pure`, so this stage uses the same
/// `pure @trusted` function-pointer-cast wrapper idiom
/// `effects.language_id_detect_stage.d` already established for exactly this
/// situation (`domain.language_id.buildLanguageIdentity`).
///
/// `similaritySignatures` throws for content over `maxSimilarityInputBytes`
/// (1 MiB) -- a real, historical, size-limit-only precedent distinct from
/// its own dedicated invalid-UTF-8 failure path. Letting that specific
/// exception surface would crash the whole `run` invocation on an ordinary
/// large document, so this stage checks the size bound itself and abstains
/// cleanly (a structured section with `hasKeys == false`) instead of ever
/// calling the throwing function for oversize content -- the same
/// "abstain, don't error" philosophy `effects.language_id_detect_stage`
/// already uses for its own oversize case. Invalid UTF-8 is handled
/// differently: `similaritySignatures` wraps that failure as
/// `domain.encoding_failure.InvalidEncodingFailure`
/// (`domain.encoding_failure.InvalidUtf8Exception`), which this stage lets
/// propagate unmodified so `cli.d`'s existing `isInvalidEncodingFailure`
/// detector (#402) quarantines it the same clean way it already handles
/// every other stage that independently re-validates UTF-8.
module effects.similarity_signature_annotate_stage;

import domain.document : DocumentId;
import domain.similarity_signature : SimilaritySignature, SimilaritySignatures,
    maxSimilarityInputBytes, signatureVersion, similarityLanes,
    similaritySignatures;
import stages.contract : PassMode, ResourceDeclaration, StageDecision,
    StageDeclaration, StageDocument;
import stages.registry : ConfiguredStageTransform, FilterPlacement,
    SideOutputCapability, StageCardinality, StageConfiguration, StageOptions,
    StageRegistration, registerStage;
import std.exception : enforce;

enum similaritySignatureAnnotateStageKeyV1 = "similarity-signature-annotate";
enum similaritySignatureSectionIdV1 = "similarity-signature-v1";

// ---------------------------------------------------------------------------
// Wire payload for the `similarity-signature-v1` structured section: a
// small, fixed-shape binary encoding of one document-level
// `SimilaritySignature` -- `hasKeys`, `contentLength`, the frozen algorithm
// version tag, and all 64 lanes. Deliberately self-contained (not a reuse of
// any existing wire format): roughly 547 bytes, comfortably inside
// `document-metadata:v2`'s 2 MiB per-section cap. The 16 band hashes are
// derived values, so phase 2 recomputes them from these canonical lanes;
// persisting both would create two authorities for the same signature.
// ---------------------------------------------------------------------------

private void putU64(ref ubyte[] output, ulong value) pure {
    foreach_reverse (shift; 0 .. 8)
        output ~= cast(ubyte) (value >> (shift * 8));
}

private ulong getU64(const(ubyte)[] input, ref size_t at) pure {
    enforce(at + 8 <= input.length, "similarity signature payload: truncated field");
    ulong value;
    foreach (_; 0 .. 8) value = (value << 8) | input[at++];
    return value;
}

/// Encodes one document-level `SimilaritySignature` for the structured
/// section wire. Pure, deterministic, and total for any signature value
/// this module itself produces.
ubyte[] encodeSimilaritySignaturePayload(SimilaritySignature signature,
        size_t contentLength) pure {
    ubyte[] output;
    output ~= cast(ubyte) (signature.hasKeys ? 1 : 0);
    putU64(output, cast(ulong) contentLength);
    enforce(signatureVersion.length <= ushort.max,
        "similarity signature payload: algorithm version tag too long");
    output ~= cast(ubyte) (signatureVersion.length >> 8);
    output ~= cast(ubyte) (signatureVersion.length & 0xff);
    output ~= cast(ubyte[]) signatureVersion;
    foreach (lane; signature.lanes) putU64(output, lane);
    return output;
}

/// One decoded document-level signature plus its persisted content length.
struct DecodedSimilaritySignaturePayload {
    bool hasKeys;
    size_t contentLength;
    ulong[similarityLanes] lanes;
}

/// Decodes a payload this module itself encoded. Fails closed on
/// truncation, trailing garbage, or an algorithm-version tag that does not
/// match the version this build of `domain.similarity_signature` currently
/// produces (`signatureVersion`) -- a future signature-algorithm change
/// must never be silently misinterpreted as the current one by a phase-2
/// corpus-level reader.
DecodedSimilaritySignaturePayload decodeSimilaritySignaturePayload(
        const(ubyte)[] payload) pure {
    enum bad = "similarity signature payload: malformed";
    size_t at;
    enforce(payload.length >= 1, bad);
    DecodedSimilaritySignaturePayload result;
    auto hasKeys = payload[at++];
    enforce(hasKeys <= 1, bad ~ ": invalid hasKeys flag");
    result.hasKeys = hasKeys == 1;
    result.contentLength = cast(size_t) getU64(payload, at);
    enforce(at + 2 <= payload.length, bad);
    size_t versionLength = (cast(size_t) payload[at] << 8) | payload[at + 1];
    at += 2;
    enforce(at + versionLength <= payload.length, bad);
    auto algorithmVersion = cast(string) payload[at .. at + versionLength];
    at += versionLength;
    enforce(algorithmVersion == signatureVersion,
        "similarity signature payload: algorithm version mismatch (expected " ~
        signatureVersion ~ ", got " ~ algorithmVersion ~ ")");
    foreach (ref lane; result.lanes) lane = getU64(payload, at);
    enforce(at == payload.length, bad ~ ": trailing data");
    return result;
}

unittest {
    import std.exception : assertThrown;

    SimilaritySignature signature;
    signature.hasKeys = true;
    foreach (i; 0 .. similarityLanes) signature.lanes[i] = i * 7 + 1;
    auto payload = encodeSimilaritySignaturePayload(signature, 12345);
    assert(payload.length == 1 + 8 + 2 + signatureVersion.length +
        similarityLanes * ulong.sizeof);
    auto decoded = decodeSimilaritySignaturePayload(payload);
    assert(decoded.hasKeys);
    assert(decoded.contentLength == 12345);
    assert(decoded.lanes == signature.lanes);
    auto forgedDerivedFields = signature;
    foreach (ref band; forgedDerivedFields.bands) band = ulong.max;
    assert(encodeSimilaritySignaturePayload(forgedDerivedFields, 12345) == payload,
        "derived band hashes must not be serialized as a second authority");

    SimilaritySignature abstained;
    abstained.hasKeys = false;
    auto abstainedPayload = encodeSimilaritySignaturePayload(abstained, 3);
    auto decodedAbstained = decodeSimilaritySignaturePayload(abstainedPayload);
    assert(!decodedAbstained.hasKeys);
    assert(decodedAbstained.contentLength == 3);

    assertThrown(decodeSimilaritySignaturePayload([]));
    assertThrown(decodeSimilaritySignaturePayload(payload[0 .. $ - 1]));
    auto malformedFlag = payload.dup;
    malformedFlag[0] = 2;
    assertThrown(decodeSimilaritySignaturePayload(malformedFlag));
    // Flipping the version tag's own bytes must fail.
    auto tamperedVersion = payload.dup;
    tamperedVersion[10] ^= 0xff; // inside the version tag text
    assertThrown(decodeSimilaritySignaturePayload(tamperedVersion));
}

// ---------------------------------------------------------------------------
// `similaritySignatures` predates the configured-stage pure function
// boundary; wrap it exactly as `effects.language_id_detect_stage.d` wraps
// `buildLanguageIdentity`.
// ---------------------------------------------------------------------------

private SimilaritySignatures similaritySignaturesPure(DocumentId documentId,
        const(ubyte)[] content) pure @trusted {
    alias PureFn = SimilaritySignatures function(DocumentId, const(ubyte)[]) pure;
    return (cast(PureFn) &similaritySignatures)(documentId, content);
}

private StageDecision applySimilaritySignatureAnnotate(StageDocument input,
        immutable(StageConfiguration)) pure {
    auto content = input.content.copy();
    SimilaritySignature documentSignature;
    if (content.length > maxSimilarityInputBytes) {
        // Oversize content: `similaritySignatures` itself throws for this
        // (see this module's own doc comment). Abstain cleanly instead of
        // crashing the whole run -- a structured section with
        // `hasKeys == false`, matching `domain.similarity_signature`'s own
        // existing "no real MinHash keys available" shape for short
        // content, rather than treating an ordinary large document as a
        // fatal error.
        documentSignature.documentId = input.document.id;
        documentSignature.profileVersion = signatureVersion;
    } else {
        // Invalid UTF-8 propagates from here unmodified (see this module's
        // doc comment): `similaritySignatures` wraps it as
        // `domain.encoding_failure.InvalidEncodingFailure`, which `cli.d`'s
        // existing #402 detector already quarantines cleanly.
        auto signatures = similaritySignaturesPure(input.document.id, content);
        documentSignature = signatures.document;
    }
    auto payload = encodeSimilaritySignaturePayload(documentSignature, content.length);
    input.metadata = input.metadata.withStructuredSection(similaritySignatureSectionIdV1,
        payload.idup, similaritySignatureAnnotateStageKeyV1);
    // `content` passes through unchanged.
    return StageDecision.map(input);
}

private ConfiguredStageTransform factory(const ref StageOptions options) {
    return ConfiguredStageTransform(&applySimilaritySignatureAnnotate);
}

static this() {
    registerStage(StageRegistration(StageDeclaration(similaritySignatureAnnotateStageKeyV1,
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
    import domain.document_metadata : decodeDocumentMetadataV2;
    import effects.document_metadata_publish_stage : documentMetadataPublishKeyV1;
    import job.json : parseJobJson;
    import stages.contract : EventKind, StageEvent;

    private Document fixtureDocument() {
        return Document(SourceLocator("local-html:v1", "/tmp", "a.txt"), OutputName("a.txt.sig"));
    }

    private StageEvent runSimilaritySignatureAnnotate(const(ubyte)[] content) {
        auto spec = parseJobJson(`{"version":3,"stages":[{"id":"annotate",` ~
            `"implementation":"` ~ similaritySignatureAnnotateStageKeyV1 ~
            `","options":{},"filters":[]}]}`);
        auto plan = compileJob(spec);
        auto input = StageDocument(fixtureDocument(),
            new Content([ContentPiece.own(content)]));
        auto result = runCompiledStage([input], plan.stages[0]);
        assert(result.events.length == 1);
        return result.events[0];
    }

    private DecodedSimilaritySignaturePayload decodedPayload(StageEvent event) {
        assert(event.kind == EventKind.emitted);
        auto sections = event.payload.metadata.structuredSections;
        assert(sections.length == 1);
        assert(sections[0].sectionId == similaritySignatureSectionIdV1);
        assert(sections[0].sourceStage == similaritySignatureAnnotateStageKeyV1);
        return decodeSimilaritySignaturePayload(sections[0].payload);
    }
}

// A plain sentence produces a real `hasKeys == true` signature matching a
// direct in-process call, byte-for-byte, and `content` passes through
// unchanged.
unittest {
    auto text = cast(const(ubyte)[]) "This is a short but plain example sentence for testing similarity.";
    auto event = runSimilaritySignatureAnnotate(text);
    assert(event.payload.content.copy() == text);
    auto decoded = decodedPayload(event);
    assert(decoded.hasKeys);
    assert(decoded.contentLength == text.length);
    auto direct = similaritySignatures(fixtureDocument().id, text);
    assert(decoded.lanes == direct.document.lanes);
}

// Content too short for a real shingle (under 5 bytes) still gets annotated
// -- a structured section with `hasKeys == false` -- exactly mirroring
// `domain.similarity_signature`'s own short-content behavior, never a
// quarantine.
unittest {
    auto event = runSimilaritySignatureAnnotate(cast(const(ubyte)[]) "abcd");
    auto decoded = decodedPayload(event);
    assert(!decoded.hasKeys);
    assert(decoded.contentLength == 4);
}

// Empty content abstains cleanly too.
unittest {
    auto event = runSimilaritySignatureAnnotate([]);
    auto decoded = decodedPayload(event);
    assert(!decoded.hasKeys);
    assert(decoded.contentLength == 0);
}

// Oversize content (over `maxSimilarityInputBytes`) abstains cleanly --
// never throws, never quarantines -- and `content` still passes through
// unmodified.
unittest {
    auto oversized = new ubyte[maxSimilarityInputBytes + 1];
    oversized[] = cast(ubyte) 'a';
    auto event = runSimilaritySignatureAnnotate(oversized);
    auto decoded = decodedPayload(event);
    assert(!decoded.hasKeys);
    assert(decoded.contentLength == oversized.length);
    assert(event.payload.content.copy() == oversized);
}

// Invalid UTF-8 propagates as an exception out of the compiled stage
// (`similaritySignatures`'s own `InvalidUtf8Exception`), never silently
// swallowed into a quarantine by this stage itself -- `cli.d`'s own #402
// detector is what quarantines it cleanly at the CLI boundary.
unittest {
    import std.exception : assertThrown;

    ubyte[3] invalid = [0xff, 0xfe, 0xfd];
    assertThrown(runSimilaritySignatureAnnotate(invalid[]));
}

// Reachability: the stage is genuinely self-registering (importing this
// module is enough), registers `SideOutputCapability.none`, and a job
// consisting of only this annotate-only stage compiles and runs.
unittest {
    auto spec = parseJobJson(`{"version":3,"stages":[{"id":"annotate",` ~
        `"implementation":"` ~ similaritySignatureAnnotateStageKeyV1 ~
        `","options":{},"filters":[]}]}`);
    auto plan = compileJob(spec);
    assert(plan.stages.length == 1);
    assert(plan.stages[0].sideOutputCapability == SideOutputCapability.none);
    auto text = cast(const(ubyte)[]) "Solo reachability fixture sentence for the stage itself.";
    auto input = StageDocument(fixtureDocument(),
        new Content([ContentPiece.own(text)]));
    auto result = runCompiledStage([input], plan.stages[0]);
    assert(result.events.length == 1 && result.events[0].kind == EventKind.emitted);
}

// Regression proof (issue #564's core acceptance criterion): `[similarity-
// signature-annotate, document-metadata-publish]` compiles and runs as one
// job, and the terminal `document-metadata:v2` side output's decoded
// structured section, round-tripped back through `domain
// .similarity_signature`'s own lane/hasKeys shape, matches a direct
// in-process call to `similaritySignatures` on the same input byte-for-byte
// -- mirroring `language_id_detect_stage.d`'s own chained-regression
// unittest.
unittest {
    auto spec = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"annotate","implementation":"` ~ similaritySignatureAnnotateStageKeyV1 ~
        `","options":{},"filters":[]},` ~
        `{"id":"publish","implementation":"document-metadata-publish",` ~
        `"options":{},"filters":[]}]}`);
    auto plan = compileJob(spec);
    auto text = cast(const(ubyte)[])
        "A chained regression fixture sentence proving the structured-section path end to end.";
    auto document = fixtureDocument();
    auto input = StageDocument(document, new Content([ContentPiece.own(text)]));
    auto events = runCompiledJob(input, plan);
    assert(events.length == 1 && events[0].kind == EventKind.emitted);
    assert(events[0].sideOutputs.length == 1);
    auto sideOutput = events[0].sideOutputs[0];
    assert(sideOutput.key == documentMetadataPublishKeyV1);
    assert(events[0].payload.content.copy() == text);

    auto decodedMetadata = decodeDocumentMetadataV2(document.id, cast(string) sideOutput.bytes());
    assert(decodedMetadata.structuredSectionCount == 1);
    auto section = decodedMetadata.structuredSections[0];
    assert(section.sectionId == similaritySignatureSectionIdV1);
    assert(section.sourceStage == similaritySignatureAnnotateStageKeyV1);

    auto decoded = decodeSimilaritySignaturePayload(section.payload);
    auto direct = similaritySignatures(document.id, text);
    assert(decoded.hasKeys == direct.document.hasKeys);
    assert(decoded.lanes == direct.document.lanes);
    assert(decoded.contentLength == text.length);
}
