/// Self-registering document-map stage whose content work is its filter chain.
module stages.text_transform;

import stages.contract : PassMode, ResourceDeclaration, StageDecision,
    StageDeclaration, StageDocument, StageTransform;
import stages.registry : FilterPlacement, StageOptions, StageRegistration,
    registerStage;

private StageTransform buildTextTransform(const ref StageOptions options) {
    return (StageDocument input) => StageDecision.map(input);
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
