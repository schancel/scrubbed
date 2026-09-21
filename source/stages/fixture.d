/// Test-only concrete stage: importing this module performs its own registration.
module stages.fixture;

version(unittest) {
import stages.contract : PassMode, ResourceDeclaration, StageDecision,
    StageDeclaration, StageDocument, StageTransform;
import stages.registry : OptionDeclaration, OptionType, StageOptions,
    StageRegistration, registerStage;

private StageTransform fixtureFactory(const ref StageOptions options) {
    auto suffix = options["suffix"].asText();
    auto configured = "enabled" in options;
    auto enabled = configured !is null && configured.asBoolean();
    return (StageDocument input) {
        if (enabled) return StageDecision.reject(suffix);
        return StageDecision.map(input);
    };
}

static this() {
    registerStage(StageRegistration(
        StageDeclaration("fixture", PassMode.singlePass, ResourceDeclaration(1, 0)),
        [OptionDeclaration("suffix", OptionType.text, true),
         OptionDeclaration("enabled", OptionType.boolean)],
        ["fixture-later"], null, &fixtureFactory));
    registerStage(StageRegistration(
        StageDeclaration("fixture-later", PassMode.singlePass, ResourceDeclaration(1, 0)),
        [OptionDeclaration("suffix", OptionType.text, true)],
        null, ["fixture"], &fixtureFactory));
}
}
