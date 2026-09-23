/// Self-registering document-map stage whose content work is its filter chain.
module stages.text_transform;

import stages.contract : PassMode, ResourceDeclaration, StageDecision,
    StageDeclaration, StageDocument;
import stages.registry : ConfiguredStageTransform, FilterPlacement,
    StageConfiguration, StageOptions, StageRegistration, registerStage;

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
        null, null, null, &buildTextTransform, FilterPlacement.before));
}

unittest {
    import stages.registry : availableStages;
    auto registration = availableStages.find("text-transform");
    assert(registration !is null &&
        registration.filterPlacement == FilterPlacement.before);
}
