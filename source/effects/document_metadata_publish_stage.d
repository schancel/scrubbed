/// Terminal `DocumentMetadata` publish stage (#285 integration slice):
/// encodes whatever `StageDocument.metadata` a job has accumulated by the
/// time this stage runs and emits it as the job's single
/// `TerminalSideOutput`. `content` passes through unchanged. Registered the
/// same shape as `stages.pii_four_class`'s former terminal registration
/// (`StageCardinality.oneToOne`, `SideOutputCapability.terminal`). Produces a
/// valid, well-formed (if entirely empty) wire record even when no prior
/// stage wrote any field, since both `encodeDocumentMetadataV1` and
/// `encodeDocumentMetadataV2` already round-trip `DocumentMetadata.empty()`
/// (see `domain.document_metadata`).
///
/// #300 Slice 3 addendum: `encodeDocumentMetadataV1` fails closed on any
/// `DocumentMetadata` carrying a `document-metadata:v2`-only structured
/// section (by design -- v1 has no wire shape for one; see
/// `domain.document_metadata`'s own doc comment on
/// `encodeDocumentMetadataV1`). Once `stages.pii_four_class` converged onto
/// `.withStructuredSection` for its audit, a job chaining
/// `pii-four-class -> document-metadata-publish` (e.g. `clean-web-document`)
/// would otherwise fail on every document. This stage now picks the wire
/// version per document: `encodeDocumentMetadataV2` only when at least one
/// structured section is actually present, `encodeDocumentMetadataV1`
/// (unchanged) otherwise. Every existing caller that never populates a
/// structured section -- concretely, `route-metadata` (#352) and every other
/// current `document-metadata-publish` consumer -- is completely unaffected:
/// `structuredSectionCount == 0` always, so it always takes the untouched v1
/// path and its wire bytes are byte-for-byte identical to before this
/// addendum.
module effects.document_metadata_publish_stage;

import domain.document_metadata : encodeDocumentMetadataV1,
    encodeDocumentMetadataV2;
import stages.contract : PassMode, ResourceDeclaration, StageDecision,
    StageDeclaration, StageDocument, TerminalSideOutput;
import stages.registry : ConfiguredStageTransform, FilterPlacement,
    SideOutputCapability, StageCardinality, StageConfiguration, StageOptions,
    StageRegistration, registerStage;

enum documentMetadataPublishSchemaV1 = "document-metadata-v1";
enum documentMetadataPublishSchemaV2 = "document-metadata-v2";
enum documentMetadataPublishKeyV1 = "document-metadata";
enum documentMetadataPublishSuffixV1 = ".document-metadata.json";

private StageDecision applyDocumentMetadataPublish(StageDocument input,
        immutable(StageConfiguration)) pure {
    // v1 exactly when no structured section is present (byte-identical to
    // every caller's pre-existing behavior); v2 only when a structured
    // section (e.g. pii-four-class's audit) is actually there to publish.
    immutable hasStructuredSections = input.metadata.structuredSectionCount != 0;
    auto wire = hasStructuredSections
        ? encodeDocumentMetadataV2(input.document.id, input.metadata)
        : encodeDocumentMetadataV1(input.document.id, input.metadata);
    auto schema = hasStructuredSections
        ? documentMetadataPublishSchemaV2 : documentMetadataPublishSchemaV1;
    auto sideOutput = TerminalSideOutput(documentMetadataPublishKeyV1,
        schema, documentMetadataPublishSuffixV1, cast(immutable(ubyte)[]) wire);
    // `content` passes through unchanged.
    return StageDecision.map(input, [sideOutput]);
}

private ConfiguredStageTransform factory(const ref StageOptions options) {
    return ConfiguredStageTransform(&applyDocumentMetadataPublish);
}

static this() {
    registerStage(StageRegistration(StageDeclaration("document-metadata-publish",
        PassMode.singlePass, ResourceDeclaration(1, 1024 * 1024)),
        null, null, null, &factory, FilterPlacement.none,
        StageCardinality.oneToOne, SideOutputCapability.terminal));
}
