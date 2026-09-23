/// Pure compilation of canonical job data through injected stage/filter registries.
module composition.compiler;

import job.json : jobIdentity;
import job.spec : JobOption, JobOptionType, JobOptions, JobSpec, validateJobSpec;
import pipeline : FilterOption, FilterRegistry, Pipeline, TypedFilterOptions,
    TypedFilterSpec, availableFilterRegistry;
import stages.contract : ResourceDeclaration, StageDeclaration;
import stages.registry : ConfiguredStageTransform, FilterPlacement, StageOption,
    StageOptions, StageRegistry, availableStages;
import std.exception : enforce;

struct CompiledStage {
private:
    bool initialized;
    string stageId;
    StageDeclaration stageDeclaration;
    ConfiguredStageTransform stageTransform;
    FilterPlacement placement;
    Pipeline filterPipeline;

    @disable this();

    this(string id, StageDeclaration declaration,
            ConfiguredStageTransform transform,
            FilterPlacement filterPlacement, Pipeline filters) {
        enforce(id.length != 0, "compiled stage ID is required");
        enforce(transform.isValid, "compiled stage transform is required");
        enforce(filterPlacement == FilterPlacement.none ||
            filterPlacement == FilterPlacement.before ||
            filterPlacement == FilterPlacement.after,
            "invalid compiled filter placement");
        initialized = true;
        stageId = id;
        stageDeclaration = declaration;
        stageTransform = transform;
        placement = filterPlacement;
        filterPipeline = filters;
    }

    void requireCompiled() const {
        enforce(initialized, "compiled stage is not initialized");
    }

public:
    string id() const { requireCompiled; return stageId; }
    const(StageDeclaration) declaration() const {
        requireCompiled;
        return stageDeclaration;
    }
    ConfiguredStageTransform transform() const {
        requireCompiled;
        return stageTransform;
    }
    FilterPlacement filterPlacement() const { requireCompiled; return placement; }
    string runFilters(string input) const {
        requireCompiled;
        return filterPipeline.run(input);
    }
    const(string)[] filterNames() const {
        requireCompiled;
        return filterPipeline.names;
    }
}

struct CompiledJob {
private:
    bool initialized;
    string canonicalIdentity;
    CompiledStage[] compiledStages;

    @disable this();

    this(string identity, CompiledStage[] stages) {
        enforce(identity.length != 0, "compiled job identity is required");
        initialized = true;
        canonicalIdentity = identity;
        compiledStages = stages;
    }

    void requireCompiled() const {
        enforce(initialized, "compiled job is not initialized");
    }

public:
    string identity() const { requireCompiled; return canonicalIdentity; }
    const(CompiledStage)[] stages() const {
        requireCompiled;
        return compiledStages;
    }
}

private StageOption stageOption(const ref JobOption value) {
    final switch (value.type) {
    case JobOptionType.text: return StageOption.text(value.asText);
    case JobOptionType.integer: return StageOption.integer(value.asInteger);
    case JobOptionType.boolean: return StageOption.boolean(value.asBoolean);
    }
}

private FilterOption filterOption(const ref JobOption value) {
    final switch (value.type) {
    case JobOptionType.text: return FilterOption.text(value.asText);
    case JobOptionType.integer: return FilterOption.integer(value.asInteger);
    case JobOptionType.boolean: return FilterOption.boolean(value.asBoolean);
    }
}

private StageOptions stageOptions(const ref JobOptions source) {
    StageOptions result;
    foreach (key, value; source) result[key] = stageOption(value);
    return result;
}

private TypedFilterOptions filterOptions(const ref JobOptions source) {
    TypedFilterOptions result;
    foreach (key, value; source) result[key] = filterOption(value);
    return result;
}

/// Resolve every declaration and factory before any document is observed.
CompiledJob compileJob(const ref JobSpec spec,
        const(StageRegistry)* stageRegistry = null,
        const(FilterRegistry)* filterRegistry = null) {
    validateJobSpec(spec);
    if (stageRegistry is null) stageRegistry = availableStages();
    if (filterRegistry is null) filterRegistry = availableFilterRegistry();

    auto identity = jobIdentity(spec);
    CompiledStage[] compiledStages;
    string[] implementationOrder;
    foreach (stage; spec.stages) {
        auto registration = stageRegistry.find(stage.implementation);
        enforce(registration !is null, "unknown stage: " ~ stage.implementation);
        enforce(stage.filters.length == 0 ||
            registration.filterPlacement != FilterPlacement.none,
            "stage " ~ stage.id ~ " does not accept filters");
        TypedFilterSpec[] filters;
        foreach (filter; stage.filters)
            filters ~= TypedFilterSpec(filter.name, filterOptions(filter.options));
        auto compiledFilters = Pipeline.buildTyped(filters, filterRegistry);
        auto transform = stageRegistry.build(stage.implementation,
            stageOptions(stage.options));
        auto declaration = StageDeclaration(registration.declaration.key,
            registration.declaration.passMode,
            ResourceDeclaration(registration.declaration.resources.cpuSlots,
                registration.declaration.resources.memoryBytes,
                registration.declaration.resources.exclusiveNames.dup));
        compiledStages ~= CompiledStage(stage.id.idup,
            declaration, transform, registration.filterPlacement,
            compiledFilters);
        implementationOrder ~= stage.implementation;
    }
    stageRegistry.validateOrder(implementationOrder);
    return CompiledJob(identity, compiledStages);
}

version (unittest) {
    import std.conv : to;
    import stages.contract : StageDecision, StageDocument;
    import stages.registry : StageConfiguration;
    import pipeline : ConfiguredFilter, FilterConfiguration;

    private class CompilerStageTestConfiguration : StageConfiguration {
        bool enabled;
        this(bool enabled) immutable { this.enabled = enabled; }
    }

    private StageDecision applyCompilerStageTest(StageDocument input,
            immutable(StageConfiguration) raw) pure {
        auto configured = cast(immutable(CompilerStageTestConfiguration)) raw;
        return configured.enabled ? StageDecision.map(input) :
            StageDecision.reject("disabled");
    }

    private ConfiguredStageTransform compilerStageTestFactory(
            const ref StageOptions options) {
        const label = options["label"].asText;
        const count = options["count"].asInteger;
        const enabled = options["enabled"].asBoolean;
        enforce(label == "ready" && count == 3,
            "stage scalar conversion failed");
        return ConfiguredStageTransform(&applyCompilerStageTest,
            new immutable CompilerStageTestConfiguration(enabled));
    }

    private StageDecision applyCompilerNoop(StageDocument input,
            immutable(StageConfiguration)) pure {
        return StageDecision.map(input);
    }

    private ConfiguredStageTransform compilerNoopFactory(
            const ref StageOptions options) {
        return ConfiguredStageTransform(&applyCompilerNoop);
    }

    private class CompilerFilterTestConfiguration : FilterConfiguration {
        string label;
        long count;
        bool enabled;
        this(string label, long count, bool enabled) immutable {
            this.label = label;
            this.count = count;
            this.enabled = enabled;
        }
    }

    private string applyCompilerFilterTest(string text,
            immutable(FilterConfiguration) raw) pure {
        auto configured = cast(immutable(CompilerFilterTestConfiguration)) raw;
        return text ~ configured.label ~ configured.count.to!string ~
            (configured.enabled ? "T" : "F");
    }

    private ConfiguredFilter compilerFilterTestFactory(
            const ref TypedFilterOptions options) {
        return ConfiguredFilter(&applyCompilerFilterTest,
            new immutable CompilerFilterTestConfiguration(
                options["label"].asText, options["count"].asInteger,
                options["enabled"].asBoolean));
    }
}

unittest {
    import job.cli_tokens : parseJobTokens;
    import job.json : parseJobJson;
    import job.legacy : lowerLegacyNames;
    import pipeline : ConfiguredFilter, Filter, FilterOptionDeclaration,
        FilterOptionType, TypedFilterOptions;
    import stages.contract : DecisionKind, PassMode, ResourceDeclaration,
        StageDecision, StageDocument;
    import stages.registry : OptionDeclaration, OptionType, StageRegistration;
    import std.conv : to;
    import std.exception : assertThrown;

    FilterRegistry filters;
    filters.addFilter("plain", cast(Filter) ((string text) => text ~ "!"));
    filters.addTypedFilterFactory("typed", [
        FilterOptionDeclaration("label", FilterOptionType.text, true),
        FilterOptionDeclaration("count", FilterOptionType.integer, true),
        FilterOptionDeclaration("enabled", FilterOptionType.boolean, true)
    ], &compilerFilterTestFactory);

    StageRegistry stages;
    stages.add(StageRegistration(StageDeclaration("text-transform",
        PassMode.singlePass, ResourceDeclaration(1, 0)), [
            OptionDeclaration("label", OptionType.text, true),
            OptionDeclaration("count", OptionType.integer, true),
            OptionDeclaration("enabled", OptionType.boolean, true)
        ], null, null, &compilerStageTestFactory, FilterPlacement.before));
    stages.add(StageRegistration(StageDeclaration("sink",
        PassMode.singlePass, ResourceDeclaration(1, 0)), null, null,
        ["text-transform"], &compilerNoopFactory, FilterPlacement.none));

    auto json = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"first","implementation":"text-transform",` ~
        `"options":{"label":"ready","count":3,"enabled":true},"filters":[` ~
        `{"name":"plain"},{"name":"typed","options":` ~
        `{"label":"v","count":2,"enabled":true}}]},` ~
        `{"id":"second","implementation":"text-transform",` ~
        `"options":{"label":"ready","count":3,"enabled":true},"filters":[]},` ~
        `{"id":"out","implementation":"sink"}]}`);
    auto compiled = compileJob(json, &stages, &filters);
    assert(compiled.stages.length == 3 && compiled.stages[0].id == "first" &&
        compiled.stages[1].id == "second" &&
        compiled.stages[0].declaration.key == "text-transform" &&
        compiled.stages[0].filterPlacement == FilterPlacement.before);
    assert(compiled.stages[0].runFilters("x") == "x!v2T");
    assert(compiled.stages[0].transform()(StageDocument.init).kind == DecisionKind.map);
    assert(compiled.identity == jobIdentity(json));
    static assert(!__traits(compiles, compiled.identity = "forged"));
    static assert(!__traits(compiles, compiled.stages.length = 0));
    static assert(!__traits(compiles, compiled.stages[0].id = "forged"));
    static assert(!__traits(compiles,
        compiled.stages[0].declaration.key = "forged"));

    auto cli = parseJobTokens(["--stage", "first=text-transform",
        "--stage-option", "label=text:ready", "--stage-option", "count=integer:3",
        "--stage-option", "enabled=boolean:true", "--filter", "plain",
        "--filter", "typed", "--filter-option", "label=text:v",
        "--filter-option", "count=integer:2", "--filter-option",
        "enabled=boolean:true",
        "--stage", "second=text-transform", "--stage-option",
        "label=text:ready", "--stage-option", "count=integer:3",
        "--stage-option", "enabled=boolean:true", "--stage", "out=sink"]);
    assert(compileJob(cli, &stages, &filters).identity == compiled.identity);

    auto disabled = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"disabled","implementation":"text-transform",` ~
        `"options":{"label":"ready","count":3,"enabled":false}}]}`);
    assert(compileJob(disabled, &stages, &filters).stages[0]
        .transform()(StageDocument.init).kind == DecisionKind.reject);
    auto disabledFilter = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"disabled-filter","implementation":"text-transform",` ~
        `"options":{"label":"ready","count":3,"enabled":true},` ~
        `"filters":[{"name":"typed","options":` ~
        `{"label":"v","count":2,"enabled":false}}]}]}`);
    assert(compileJob(disabledFilter, &stages, &filters).stages[0]
        .runFilters("x") == "xv2F");

    auto legacy = lowerLegacyNames(["plain"]);
    // The predecessor implicit stage has no stage options.
    StageRegistry legacyRegistry;
    legacyRegistry.add(StageRegistration(StageDeclaration("text-transform",
        PassMode.singlePass, ResourceDeclaration(1, 0)), null, null, null,
        &compilerNoopFactory, FilterPlacement.before));
    assert(compileJob(legacy, &legacyRegistry, &filters)
        .stages[0].runFilters("x") == "x!");

    auto badPlacement = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"out","implementation":"sink","filters":[{"name":"plain"}]}]}`);
    assertThrown(compileJob(badPlacement, &stages, &filters));
    auto badType = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"x","implementation":"text-transform",` ~
        `"options":{"enabled":"true"},"filters":[]}]}`);
    assertThrown(compileJob(badType, &stages, &filters));
    auto unknownFilter = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"x","implementation":"text-transform",` ~
        `"options":{"label":"ready","count":3,"enabled":true},` ~
        `"filters":[{"name":"missing"}]}]}`);
    assertThrown(compileJob(unknownFilter, &stages, &filters));
    auto unknownStage = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"x","implementation":"missing"}]}`);
    assertThrown(compileJob(unknownStage, &stages, &filters));
    auto badOrder = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"out","implementation":"sink"},` ~
        `{"id":"x","implementation":"text-transform",` ~
        `"options":{"label":"ready","count":3,"enabled":true}}]}`);
    assertThrown(compileJob(badOrder, &stages, &filters));
}
