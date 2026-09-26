/// Terminal `DocumentMetadata` publish stage (#285 integration slice):
/// encodes whatever `StageDocument.metadata` a job has accumulated by the
/// time this stage runs into the frozen `document-metadata:v1` wire and
/// emits it as the job's single `TerminalSideOutput`. `content` passes
/// through unchanged. Registered the same shape as `stages.pii_four_class`'s
/// terminal registration (`StageCardinality.oneToOne`,
/// `SideOutputCapability.terminal`). Produces a valid, well-formed (if
/// entirely empty) wire record even when no prior stage wrote any field,
/// since `encodeDocumentMetadataV1` already round-trips `DocumentMetadata
/// .empty()` (see `domain.document_metadata`).
module effects.document_metadata_publish_stage;

import domain.document_metadata : encodeDocumentMetadataV1;
import stages.contract : PassMode, ResourceDeclaration, StageDecision,
    StageDeclaration, StageDocument, TerminalSideOutput;
import stages.registry : ConfiguredStageTransform, FilterPlacement,
    SideOutputCapability, StageCardinality, StageConfiguration, StageOptions,
    StageRegistration, registerStage;

enum documentMetadataPublishSchemaV1 = "document-metadata-v1";
enum documentMetadataPublishKeyV1 = "document-metadata";
enum documentMetadataPublishSuffixV1 = ".document-metadata.json";

private StageDecision applyDocumentMetadataPublish(StageDocument input,
        immutable(StageConfiguration)) pure {
    auto wire = encodeDocumentMetadataV1(input.document.id, input.metadata);
    auto sideOutput = TerminalSideOutput(documentMetadataPublishKeyV1,
        documentMetadataPublishSchemaV1, documentMetadataPublishSuffixV1,
        cast(immutable(ubyte)[]) wire);
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
