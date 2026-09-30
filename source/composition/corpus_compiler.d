/// Two-phase composition compiler (issue #564): splits one `--stage` token
/// list into its per-document half (compiled exactly as
/// `composition.compiler.compileJob` already does, completely unchanged)
/// and its new, strictly-later corpus-level half, structurally enforcing
/// that every per-document stage precedes every corpus-level stage. This is
/// the compile-time mechanism `stages.corpus_contract`'s own module doc
/// comment promises: a corpus-level stage can never occupy an arbitrary
/// position in a composition relative to a per-document stage, because this
/// compiler rejects any token order that would require it.
///
/// A `JobSpec`'s `stages` list is unchanged by issue #564 -- the same
/// `--stage id=impl[,--stage-option ...]` tokens name both per-document and
/// corpus-level implementations; which half a token belongs to is
/// determined structurally, by which registry (`stages.registry
/// .StageRegistry` vs `stages.corpus_contract.CorpusStageRegistry`)
/// recognizes its `implementation` key -- never a caller-chosen split, and
/// never a third kind of token syntax.
module composition.corpus_compiler;

import composition.compiler : CompiledJob, compileJob;
import job.spec : JobOption, JobOptionType, JobOptions, JobSpec, JobStageSpec,
    validateJobSpec;
import pipeline : FilterRegistry, availableFilterRegistry;
import stages.corpus_contract : CorpusStageRegistry, CorpusStageRun,
    availableCorpusStages;
import stages.registry : StageOption, StageOptions, StageRegistry, availableStages;
import std.exception : enforce;

/// One corpus-level stage's own compiled identity plus its configured,
/// ready-to-run implementation. Mirrors `composition.compiler.CompiledStage`'s
/// "resolve everything before any document is observed" discipline, applied
/// to the corpus-level contract instead.
struct CompiledCorpusStage {
private:
    bool initialized;
    string stageId;
    string implementationKeyValue;
    CorpusStageRun stageRun;

    @disable this();

    this(string id, string implementationKey, CorpusStageRun run) {
        enforce(id.length != 0, "compiled corpus stage ID is required");
        enforce(implementationKey.length != 0,
            "compiled corpus stage implementation key is required");
        enforce(run !is null, "compiled corpus stage run delegate is required");
        initialized = true;
        stageId = id;
        implementationKeyValue = implementationKey;
        stageRun = run;
    }

    void requireCompiled() const {
        enforce(initialized, "compiled corpus stage is not initialized");
    }

public:
    string id() const { requireCompiled; return stageId; }
    string implementationKey() const { requireCompiled; return implementationKeyValue; }
    CorpusStageRun run() const { requireCompiled; return stageRun; }
}

/// The compiled result of a two-phase composition. `perDocument` is
/// compiled by the existing, completely unchanged `compileJob` -- every
/// composition that declares zero corpus-level stages (every composition
/// that existed before issue #564) produces a `CompiledComposition` whose
/// `perDocument` is byte-for-byte what `compileJob` alone would have
/// produced, and whose `corpusStages` is empty. `corpusStages` is ordered:
/// a caller (`source/cli.d`'s phase 2) runs them in this order, once each,
/// only after phase 1 (`perDocument`) has fully drained.
struct CompiledComposition {
private:
    bool initialized;
    CompiledJob perDocumentJob;
    CompiledCorpusStage[] corpusStagesList;

    @disable this();

    this(CompiledJob perDocument, CompiledCorpusStage[] corpusStages) {
        initialized = true;
        perDocumentJob = perDocument;
        corpusStagesList = corpusStages;
    }

    void requireCompiled() const {
        enforce(initialized, "compiled composition is not initialized");
    }

public:
    const(CompiledJob) perDocument() const { requireCompiled; return perDocumentJob; }
    const(CompiledCorpusStage)[] corpusStages() const { requireCompiled; return corpusStagesList; }
    bool hasCorpusStages() const { requireCompiled; return corpusStagesList.length != 0; }
}

private StageOption stageOption(const ref JobOption value) {
    final switch (value.type) {
    case JobOptionType.text: return StageOption.text(value.asText);
    case JobOptionType.integer: return StageOption.integer(value.asInteger);
    case JobOptionType.boolean: return StageOption.boolean(value.asBoolean);
    }
}

private StageOptions stageOptions(const ref JobOptions source) {
    StageOptions result;
    foreach (key, value; source) result[key] = stageOption(value);
    return result;
}

/// Compiles a full `--stage` token composition into its two-phase result.
///
/// Rejects, at compile time (never silently accepted and reordered, never a
/// runtime surprise):
/// - an implementation key unknown to both registries;
/// - an implementation key registered in BOTH registries (an unresolvable
///   ambiguity -- `stages.corpus_contract`'s own module doc names this as a
///   compile-time error, not a silent preference for one registry);
/// - a corpus-level stage token that names filters (filters are a
///   per-document content-transform concept with no corpus-level analogue);
/// - any per-document-registry stage token that appears, anywhere in the
///   token list, after the first corpus-registry stage token -- the actual
///   "two strict phases, never interleaved" enforcement this whole module
///   exists to provide.
CompiledComposition compileComposition(const ref JobSpec spec,
        const(StageRegistry)* perDocumentRegistry = null,
        const(CorpusStageRegistry)* corpusRegistry = null,
        const(FilterRegistry)* filterRegistry = null) {
    validateJobSpec(spec);
    if (perDocumentRegistry is null) perDocumentRegistry = availableStages();
    if (corpusRegistry is null) corpusRegistry = availableCorpusStages();
    if (filterRegistry is null) filterRegistry = availableFilterRegistry();

    JobStageSpec[] perDocumentStages;
    JobStageSpec[] corpusStageSpecs;
    bool sawCorpusStage;
    string firstCorpusStage;
    foreach (stage; spec.stages) {
        auto isPerDocument = perDocumentRegistry.find(stage.implementation) !is null;
        auto isCorpus = corpusRegistry.find(stage.implementation) !is null;
        enforce(!(isPerDocument && isCorpus),
            "stage " ~ stage.id ~ " (" ~ stage.implementation ~ ") is registered as " ~
            "both a per-document and a corpus-level implementation -- ambiguous, and " ~
            "never silently resolved to one or the other");
        enforce(isPerDocument || isCorpus, "unknown stage: " ~ stage.implementation);
        if (isCorpus) {
            sawCorpusStage = true;
            if (!firstCorpusStage.length)
                firstCorpusStage = stage.id ~ " (" ~ stage.implementation ~ ")";
            enforce(stage.filters.length == 0,
                "corpus-level stage " ~ stage.id ~ " (" ~ stage.implementation ~
                ") cannot accept filters -- filters are a per-document content " ~
                "transform with no corpus-level analogue");
            corpusStageSpecs ~= cast(JobStageSpec) stage;
        } else {
            enforce(!sawCorpusStage,
                "stage " ~ stage.id ~ " (" ~ stage.implementation ~ ") is a " ~
                "per-document stage that appears after corpus-level stage " ~
                firstCorpusStage ~ " in this " ~
                "composition -- every per-document stage must precede every " ~
                "corpus-level stage (issue #564's two-phase model: a corpus-level " ~
                "stage runs only as a strictly later pass over the whole " ~
                "already-published corpus, and can never be interleaved with a " ~
                "per-document stage in the same pass)");
            perDocumentStages ~= cast(JobStageSpec) stage;
        }
    }

    JobSpec perDocumentSpec;
    perDocumentSpec.stages = perDocumentStages;
    auto compiledJob = compileJob(perDocumentSpec, perDocumentRegistry, filterRegistry);

    CompiledCorpusStage[] compiledCorpusStages;
    foreach (stage; corpusStageSpecs) {
        auto run = corpusRegistry.build(stage.implementation, stageOptions(stage.options));
        compiledCorpusStages ~= CompiledCorpusStage(stage.id.idup,
            stage.implementation.idup, run);
    }

    return CompiledComposition(compiledJob, compiledCorpusStages);
}

// ---------------------------------------------------------------------------
// Unit tests.
// ---------------------------------------------------------------------------

version (unittest) {
    import stages.contract : PassMode, ResourceDeclaration, StageDecision,
        StageDeclaration, StageDocument;
    import stages.corpus_contract : CorpusStageDeclaration, CorpusStageRegistration,
        CorpusStageSink;
    import stages.registry : ConfiguredStageTransform, FilterPlacement,
        SideOutputCapability, StageCardinality, StageConfiguration, StageRegistration;

    private StageDecision testPerDocumentApply(StageDocument input,
            immutable(StageConfiguration)) pure {
        return StageDecision.map(input);
    }

    private ConfiguredStageTransform testPerDocumentFactory(const ref StageOptions) {
        return ConfiguredStageTransform(&testPerDocumentApply);
    }

    private StageRegistry testPerDocumentRegistry() {
        StageRegistry registry;
        registry.add(StageRegistration(StageDeclaration("test-per-document",
            PassMode.singlePass, ResourceDeclaration(1, 0)), null, null, null,
            &testPerDocumentFactory, FilterPlacement.none, StageCardinality.oneToOne,
            SideOutputCapability.none));
        return registry;
    }

    private CorpusStageRun testCorpusRun(const ref StageOptions) {
        return (string sidecarRoot, scope CorpusStageSink sink) {};
    }

    private CorpusStageRegistry testCorpusRegistry() {
        CorpusStageRegistry registry;
        registry.add(CorpusStageRegistration(CorpusStageDeclaration("test-corpus-stage"),
            null, &testCorpusRun));
        return registry;
    }
}

// A composition with zero corpus-level stages compiles to an empty
// `corpusStages` and a `perDocument` job identical to what `compileJob`
// alone would produce -- the "provably unaffected" guarantee for every
// pre-#564 composition.
unittest {
    import job.cli_tokens : parseJobTokens;

    auto tokens = ["--stage", "first=test-per-document"];
    auto spec = parseJobTokens(tokens);
    auto perDocumentRegistry = testPerDocumentRegistry();
    auto corpusRegistry = testCorpusRegistry();

    auto composition = compileComposition(spec, &perDocumentRegistry, &corpusRegistry);
    assert(!composition.hasCorpusStages());
    assert(composition.corpusStages().length == 0);

    auto directJob = compileJob(spec, &perDocumentRegistry);
    assert(composition.perDocument().identity == directJob.identity);
    assert(composition.perDocument().stages().length == directJob.stages().length);
}

// A per-document stage followed by a corpus-level stage compiles cleanly,
// with the corpus-level stage reachable through the exact same `--stage`
// syntax as every other stage.
unittest {
    import job.cli_tokens : parseJobTokens;

    auto tokens = ["--stage", "first=test-per-document",
        "--stage", "prune=test-corpus-stage"];
    auto spec = parseJobTokens(tokens);
    auto perDocumentRegistry = testPerDocumentRegistry();
    auto corpusRegistry = testCorpusRegistry();

    auto composition = compileComposition(spec, &perDocumentRegistry, &corpusRegistry);
    assert(composition.hasCorpusStages());
    assert(composition.corpusStages().length == 1);
    assert(composition.corpusStages()[0].id == "prune");
    assert(composition.corpusStages()[0].implementationKey == "test-corpus-stage");
    assert(composition.perDocument().stages().length == 1);
}

// A composition consisting ONLY of corpus-level stages (zero per-document
// stages) compiles cleanly -- a legitimate use (e.g. running pruning again
// as a standalone pass over an already-published corpus).
unittest {
    import job.cli_tokens : parseJobTokens;

    auto spec = parseJobTokens(["--stage", "prune=test-corpus-stage"]);
    auto perDocumentRegistry = testPerDocumentRegistry();
    auto corpusRegistry = testCorpusRegistry();

    auto composition = compileComposition(spec, &perDocumentRegistry, &corpusRegistry);
    assert(composition.perDocument().stages().length == 0);
    assert(composition.corpusStages().length == 1);
}

// A per-document stage that appears AFTER a corpus-level stage is rejected
// with a clear ordering error, naming both stages involved.
unittest {
    import job.cli_tokens : parseJobTokens;
    import std.exception : assertThrown, collectExceptionMsg;

    auto spec = parseJobTokens(["--stage", "prune=test-corpus-stage",
        "--stage", "after=test-per-document"]);
    auto perDocumentRegistry = testPerDocumentRegistry();
    auto corpusRegistry = testCorpusRegistry();

    auto message = collectExceptionMsg!Exception(
        compileComposition(spec, &perDocumentRegistry, &corpusRegistry));
    assert(message.length != 0);
    assert(message.canFind("prune"));
    assert(message.canFind("after"));
    assert(message.canFind("corpus-level"));
}

// A corpus-level stage token naming filters is rejected.
unittest {
    import job.json : parseJobJson;
    import std.exception : assertThrown;

    auto spec = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"prune","implementation":"test-corpus-stage","options":{},` ~
        `"filters":[{"name":"whatever"}]}]}`);
    auto perDocumentRegistry = testPerDocumentRegistry();
    auto corpusRegistry = testCorpusRegistry();
    assertThrown(compileComposition(spec, &perDocumentRegistry, &corpusRegistry));
}

// An implementation key unknown to both registries is rejected.
unittest {
    import job.cli_tokens : parseJobTokens;
    import std.exception : assertThrown;

    auto spec = parseJobTokens(["--stage", "x=totally-unknown-implementation"]);
    auto perDocumentRegistry = testPerDocumentRegistry();
    auto corpusRegistry = testCorpusRegistry();
    assertThrown(compileComposition(spec, &perDocumentRegistry, &corpusRegistry));
}

// An implementation key registered in BOTH registries is rejected as an
// ambiguity, never silently preferring one registry.
unittest {
    import job.cli_tokens : parseJobTokens;
    import std.exception : assertThrown;

    auto perDocumentRegistry = testPerDocumentRegistry();
    perDocumentRegistry.add(StageRegistration(StageDeclaration("shared-name",
        PassMode.singlePass, ResourceDeclaration(1, 0)), null, null, null,
        &testPerDocumentFactory, FilterPlacement.none, StageCardinality.oneToOne,
        SideOutputCapability.none));
    auto corpusRegistry = testCorpusRegistry();
    corpusRegistry.add(CorpusStageRegistration(CorpusStageDeclaration("shared-name"),
        null, &testCorpusRun));

    auto spec = parseJobTokens(["--stage", "x=shared-name"]);
    assertThrown(compileComposition(spec, &perDocumentRegistry, &corpusRegistry));
}

private import std.algorithm.searching : canFind;
