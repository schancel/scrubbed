/// Self-registering document-map stage whose content work is its filter chain.
module stages.text_transform;

import stages.contract : PassMode, ResourceDeclaration, StageDecision,
    StageDeclaration, StageDocument;
import stages.registry : ConfiguredStageTransform, FilterPlacement,
    SideOutputCapability, StageCardinality, StageConfiguration, StageOptions,
    StageRegistration, registerStage;

private StageDecision applyTextTransform(StageDocument input,
        immutable(StageConfiguration)) pure {
    return StageDecision.map(input);
}

private ConfiguredStageTransform buildTextTransform(
        const ref StageOptions options) {
    return ConfiguredStageTransform(&applyTextTransform);
}

static this() {
    registerStage(StageRegistration(
        StageDeclaration("text-transform", PassMode.singlePass,
            ResourceDeclaration(1, 0)),
        null, null, null, &buildTextTransform, FilterPlacement.before,
        StageCardinality.oneToOne, SideOutputCapability.none));
}

unittest {
    import stages.registry : availableStages;
    auto registration = availableStages.find("text-transform");
    assert(registration !is null &&
        registration.filterPlacement == FilterPlacement.before);
}

unittest {
    // Regression for #293: text-transform's registration must declare
    // StageCardinality.oneToOne / SideOutputCapability.none so that chaining
    // it ahead of a terminal (side-output-producing) stage is admissible.
    // The full cross-layer proof (compiling a real job against the real
    // production registry) lives in
    // experiments/text_transform_registration/check.d instead of here,
    // since composition.compiler/job.json are not legal imports for a
    // stages/* module (see scripts/check_modules.d's layering rule).
    import stages.registry : availableStages, StageCardinality,
        SideOutputCapability;
    auto registration = availableStages.find("text-transform");
    assert(registration !is null &&
        registration.cardinality == StageCardinality.oneToOne &&
        registration.sideOutputCapability == SideOutputCapability.none);
}
