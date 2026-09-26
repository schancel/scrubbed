/// Focused, release-active regression proof for issue #293:
/// `stages.text_transform`'s registration now declares
/// `StageCardinality.oneToOne`/`SideOutputCapability.none`, matching its
/// real, always-map, never-splitting behavior. Before this fix, the
/// registration defaulted to `StageCardinality.maySplit`, and
/// `composition/compiler.d`'s terminal-stage admission rule (which requires
/// every stage preceding a side-output-producing stage to be *declared*
/// `oneToOne`, not merely to behave that way) rejected any job compiling
/// `text-transform` ahead of a terminal stage -- e.g.
/// `[text-transform, pii-four-class]` -- against the real production
/// registry, with no local `StageRegistry` workaround.
///
/// This proof deliberately lives here, not as a `unittest` inside
/// `source/stages/text_transform.d` itself: `composition.compiler` and
/// `job.json` are not legal imports for a `stages/*` module under
/// `scripts/check_modules.d`'s layering rule ("stages may import only
/// stages, domain and content project modules"), so a cross-layer proof
/// against the compiler and job-spec parser belongs in `experiments/`,
/// matching the precedent already established by
/// `experiments/document_metadata_integration/check.d` (#285).
module experiments.text_transform_registration.check;

import composition.compiler : compileJob;
import job.json : parseJobJson;
import stages.registry : availableStages;
import std.stdio : writeln;

// Self-registering production stage modules. Importing each runs its
// `static this()` registration into the process-wide registry that
// `availableStages()` exposes.
import stages.text_transform;
import stages.pii_four_class;

private int failures;

/// Not `assert`: this checker builds with LDC `-O3 -release`, which elides
/// the `assert` language construct. Every check here is a plain runtime
/// comparison so nothing the proof depends on can be compiled away.
private void expect(bool condition, string label) {
    if (condition) {
        writeln("ok   ", label);
    } else {
        writeln("FAIL ", label);
        ++failures;
    }
}

/// Compiles `[text-transform, pii-four-class]` against the real,
/// unmodified, process-wide production registry (`availableStages()`,
/// resolved by `compileJob` when no explicit registry is supplied) -- not a
/// local `StageRegistry` copy. Before #293's fix, this threw "stage before
/// side-output producer must be non-splitting: clean"; after the fix, it
/// compiles cleanly.
private void proveTextTransformChainsAheadOfTerminalStage() {
    auto spec = parseJobJson(`{
        "version": 3,
        "stages": [
            {"id": "clean", "implementation": "text-transform",
             "options": {}, "filters": []},
            {"id": "privacy", "implementation": "pii-four-class",
             "options": {}, "filters": []}
        ]
    }`);

    auto compiled = compileJob(spec);
    expect(compiled.stages.length == 2,
        "text-transform ahead of a terminal stage compiles against the " ~
        "real production registry (2 stages)");
}

/// Sanity check that the real production registration itself, not just the
/// compiled-job outcome, carries the corrected declaration.
private void proveTextTransformRegistrationDeclaresOneToOne() {
    import stages.registry : StageCardinality, SideOutputCapability;
    auto registration = availableStages().find("text-transform");
    expect(registration !is null &&
        registration.cardinality == StageCardinality.oneToOne &&
        registration.sideOutputCapability == SideOutputCapability.none,
        "text-transform's production registration declares " ~
        "StageCardinality.oneToOne and SideOutputCapability.none");
}

void main() {
    proveTextTransformRegistrationDeclaresOneToOne();
    proveTextTransformChainsAheadOfTerminalStage();

    if (failures) {
        writeln(failures, " check(s) failed");
        import core.stdc.stdlib : exit;
        exit(1);
    }
    writeln("all text-transform registration checks passed");
}
