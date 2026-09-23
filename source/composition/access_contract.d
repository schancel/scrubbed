/// External-module compile contract for opaque compiled job construction.
module composition.access_contract;

import composition.compiler : CompiledJob, CompiledStage;
import pipeline : Pipeline;
import stages.contract : StageDeclaration;
import stages.registry : ConfiguredStageTransform, FilterPlacement;

// D's generated aggregate initializer can otherwise bypass private fields.
// Only composition.compiler may pair canonical identity with resolved behavior.
static assert(!__traits(compiles,
    CompiledJob("job:v3:forged", cast(CompiledStage[]) null)));
static assert(!__traits(compiles,
    CompiledStage("forged", StageDeclaration.init, ConfiguredStageTransform.init,
        FilterPlacement.none, Pipeline.init)));
static assert(!__traits(compiles, { CompiledJob forged; }));
static assert(!__traits(compiles, { CompiledStage forged; }));

private void publicReadContract(CompiledJob compiled) {
    auto identity = compiled.identity;
    auto stages = compiled.stages;
}

// Make DUB's unittest discovery import this otherwise compile-only contract.
unittest {
    import std.exception : assertThrown;

    static assert(__traits(compiles, &publicReadContract));
    // D exposes `T.init` even when default construction is disabled. The
    // opaque value must remain unusable rather than impersonating a plan.
    assertThrown(CompiledJob.init.identity);
    assertThrown(CompiledJob.init.stages);
    assertThrown(CompiledStage.init.id);
    assertThrown(CompiledStage.init.transform);
}
