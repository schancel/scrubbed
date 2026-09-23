/// Test-only concrete stage: importing this module performs its own registration.
module stages.fixture;

version(unittest) {
import stages.contract : PassMode, ResourceDeclaration, StageDecision,
    StageDeclaration, StageDocument;
import stages.registry : ConfiguredStageTransform, OptionDeclaration,
    OptionType, StageConfiguration, StageOptions, StageRegistration,
    registerStage;
import std.exception : enforce;

private class FixtureConfiguration : StageConfiguration {
    string suffix;
    bool enabled;

    this(string suffix, bool enabled) immutable {
        this.suffix = suffix;
        this.enabled = enabled;
    }
}

private StageDecision applyFixture(StageDocument input,
        immutable(StageConfiguration) raw) pure {
    auto configured = cast(immutable(FixtureConfiguration)) raw;
    enforce(configured !is null, "invalid fixture configuration");
    if (configured.enabled) return StageDecision.reject(configured.suffix);
    return StageDecision.map(input);
}

private ConfiguredStageTransform fixtureFactory(const ref StageOptions options) {
    auto enabled = "enabled" in options;
    auto configured = new immutable FixtureConfiguration(
        options["suffix"].asText(), enabled !is null && enabled.asBoolean());
    return ConfiguredStageTransform(&applyFixture, configured);
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
