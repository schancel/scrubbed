/// Pluggable filter pipeline: filters are named, registered once, and
/// composed at runtime from config (CLI flags or a config file) rather
/// than hardcoded into a fixed chain -- so adding a new filter (an
/// HTML->Markdown converter, a different encoding fixer, a whitespace
/// normalizer with different rules) never means editing the orchestration
/// code, only registering the new filter and naming it in the chain.
///
/// Whole-buffer filters retain the original `string -> string` contract.
/// Bounded scalar transducers may additionally register a streaming
/// descriptor; consecutive streaming filters then share one lazy traversal
/// and one final materialization without hardcoding filter names here.
module pipeline;

import std.exception : enforce;
import std.range.primitives : empty, front, popFront;
import std.string : indexOf;
import std.typecons : No;
import std.utf : byUTF, validate;

/// Plain filter contract; purity prevents retained callbacks from sharing state.
alias Filter = string function(string) pure;

/// Type-erased, transitively immutable configuration parsed by a filter factory.
class FilterConfiguration {}

alias ConfiguredFilterApply = string function(string,
    immutable(FilterConfiguration)) pure;

/// Reentrant configured execution: code has no delegate context and all
/// retained configuration is transitively immutable.
struct ConfiguredFilter {
private:
    ConfiguredFilterApply filterApply;
    immutable(FilterConfiguration) filterConfiguration;

public:
    this(ConfiguredFilterApply apply,
            immutable(FilterConfiguration) configuration = null) {
        enforce(apply !is null, "configured filter implementation is required");
        filterApply = apply;
        filterConfiguration = configuration;
    }

    bool isValid() const { return filterApply !is null; }

    string opCall(string input) const {
        enforce(isValid, "configured filter is not initialized");
        return filterApply(input, filterConfiguration);
    }
}

enum FilterOptionType { text, integer, boolean }

/// Typed v3 option value received only after edge compatibility lowering.
struct FilterOption {
    private FilterOptionType optionType;
    private string textValue;
    private long integerValue;
    private bool booleanValue;

    static FilterOption text(string value) {
        validate(value);
        enforce(value.indexOf('\0') < 0, "filter option text must not contain NUL");
        FilterOption result;
        result.optionType = FilterOptionType.text;
        result.textValue = value.idup;
        return result;
    }
    static FilterOption integer(long value) {
        FilterOption result;
        result.optionType = FilterOptionType.integer;
        result.integerValue = value;
        return result;
    }
    static FilterOption boolean(bool value) {
        FilterOption result;
        result.optionType = FilterOptionType.boolean;
        result.booleanValue = value;
        return result;
    }
    FilterOptionType type() const { return optionType; }
    string asText() const {
        enforce(optionType == FilterOptionType.text, "filter option is not text");
        return textValue;
    }
    long asInteger() const {
        enforce(optionType == FilterOptionType.integer,
            "filter option is not an integer");
        return integerValue;
    }
    bool asBoolean() const {
        enforce(optionType == FilterOptionType.boolean,
            "filter option is not boolean");
        return booleanValue;
    }
}

alias TypedFilterOptions = FilterOption[string];
alias TypedFilterFactory = ConfiguredFilter function(const ref TypedFilterOptions);

struct FilterOptionDeclaration {
    string key;
    FilterOptionType type;
    bool required;
}

/// Opaque, caller-owned state for one configured scalar transducer. Keeping
/// it inline makes the returned fused range own the state in its caller.
struct StreamingState {
    ulong[2] words;
}

enum maxStreamingExpansion = 2;
private enum maxFusedStages = 16;
alias StreamingPush = size_t function(ref StreamingState, dchar,
    dchar[maxStreamingExpansion]*) pure;
alias StreamingFinish = size_t function(ref StreamingState,
    dchar[maxStreamingExpansion]*) pure;

/// One bounded UTF-8-scalar transducer. `push` and `finish` may emit at most
/// `maxStreamingExpansion` scalars. Empty output drops an input scalar.
struct StreamingFilter {
    StreamingState initialState;
    StreamingPush push;
    StreamingFinish finish;
}

struct TypedFilterSpec {
    string name;
    TypedFilterOptions options;
}

private struct FilterRegistration {
    Filter plain;
    TypedFilterFactory typedFactory;
    FilterOptionDeclaration[] optionDeclarations;
    StreamingFilter streaming;
}

/// Injectable registry: concrete filters still own registration, while tests
/// and the v3 composition root can resolve against an explicit instance.
struct FilterRegistry {
    private FilterRegistration[string] registrations;

    private void add(string name, FilterRegistration registration) {
        enforce(name.length != 0, "filter name must not be empty");
        validate(name);
        enforce(name.indexOf('\0') < 0, "filter name must not contain NUL");
        enforce((name in registrations) is null, "duplicate filter: " ~ name);
        foreach (i, declaration; registration.optionDeclarations) {
            enforce(declaration.key.length != 0, "filter option key must not be empty");
            validate(declaration.key);
            enforce(declaration.key.indexOf('\0') < 0,
                "filter option key must not contain NUL");
            enforce(declaration.type == FilterOptionType.text ||
                declaration.type == FilterOptionType.integer ||
                declaration.type == FilterOptionType.boolean,
                "invalid filter option type");
            foreach (prior; registration.optionDeclarations[0 .. i])
                enforce(declaration.key != prior.key,
                    "duplicate filter option: " ~ declaration.key);
        }
        registration.optionDeclarations = registration.optionDeclarations.dup;
        registrations[name] = registration;
    }

    void addFilter(string name, Filter filter) {
        enforce(filter !is null, "filter implementation is required");
        add(name, FilterRegistration(filter));
    }

    void addTypedFilterFactory(string name,
            FilterOptionDeclaration[] declarations,
            TypedFilterFactory typedFactory) {
        enforce(typedFactory !is null, "typed filter factory is required");
        FilterRegistration registration;
        registration.typedFactory = typedFactory;
        registration.optionDeclarations = declarations;
        add(name, registration);
    }

    void addStreamingFilter(string name, StreamingFilter streaming) {
        enforce(streaming.push !is null,
            "streaming filter requires a push implementation");
        FilterRegistration registration;
        registration.streaming = streaming;
        add(name, registration);
    }

    string[] names() const { return registrations.keys; }
}

private FilterRegistry registeredFilters;

/// Register a filter under `name`. Call once per filter, typically from a
/// module constructor (`static this()`) in that filter's own module, so
/// registration stays next to the implementation rather than centralized
/// in one big list someone has to remember to update.
void registerFilter(string name, Filter f) {
    registeredFilters.addFilter(name, f);
}

/// Register a typed v3 factory with its exact option declarations.
void registerTypedFilterFactory(string name,
        FilterOptionDeclaration[] declarations,
        TypedFilterFactory typedFactory) {
    registeredFilters.addTypedFilterFactory(name, declarations, typedFactory);
}

/// Register a no-option bounded streaming implementation.
void registerStreamingFilter(string name, StreamingFilter streaming) {
    registeredFilters.addStreamingFilter(name, streaming);
}

const(FilterRegistry)* availableFilterRegistry() {
    return &registeredFilters;
}

string[] availableFilters(const(FilterRegistry)* selected = null) {
    if (selected is null) selected = availableFilterRegistry();
    return selected.names;
}

/// An ordered, resolved chain of filters, built from names against the
/// registry. Throws if any name isn't registered -- fail at pipeline
/// construction time, not partway through processing a document tree.
struct Pipeline {
    private struct Stage {
        Filter plain;
        ConfiguredFilter configured;
        StreamingFilter streaming;
    }
    private Stage[] stages;
    private string[] stageNames;

    /// Resolve typed v3 values without string inference or coercion.
    static Pipeline buildTyped(TypedFilterSpec[] specs,
            const(FilterRegistry)* selected = null) {
        if (selected is null) selected = availableFilterRegistry();
        Pipeline p;
        foreach (spec; specs) {
            auto registration = spec.name in selected.registrations;
            if (registration is null)
                throw new Exception("unknown filter: " ~ spec.name ~
                    " (available: " ~ availableFilters(selected).idup.to!string ~ ")");
            if (registration.typedFactory !is null) {
                foreach (key, value; spec.options) {
                    const(FilterOptionDeclaration)* declaration;
                    foreach (ref candidate; registration.optionDeclarations)
                        if (candidate.key == key) declaration = &candidate;
                    enforce(declaration !is null,
                        "unknown option '" ~ key ~ "' for filter '" ~ spec.name ~ "'");
                    enforce(declaration.type == value.type,
                        "option '" ~ key ~ "' for filter '" ~ spec.name ~
                        "' has the wrong type");
                }
                foreach (declaration; registration.optionDeclarations)
                    if (declaration.required)
                        enforce((declaration.key in spec.options) !is null,
                            "missing option '" ~ declaration.key ~
                            "' for filter '" ~ spec.name ~ "'");
                auto configured = registration.typedFactory(spec.options);
                enforce(configured.isValid,
                    "typed filter factory returned no implementation");
                p.stages ~= Stage(Filter.init, configured);
            } else {
                enforce(spec.options.length == 0,
                    "filter '" ~ spec.name ~ "' accepts no typed options");
                if (registration.streaming.push !is null)
                    p.stages ~= Stage(Filter.init, ConfiguredFilter.init,
                        registration.streaming);
                else
                    p.stages ~= Stage(registration.plain,
                        ConfiguredFilter.init);
            }
            p.stageNames ~= spec.name;
        }
        return p;
    }

    string run(string text) const {
        size_t index;
        while (index < stages.length) {
            if (stages[index].streaming.push !is null) {
                // Bound recursive pull depth without restricting user chains;
                // unusually long runs become multiple fused materializations.
                StreamingFilter[maxFusedStages] fused;
                size_t fusedLength;
                while (index < stages.length &&
                       stages[index].streaming.push !is null &&
                       fusedLength < maxFusedStages) {
                    fused[fusedLength++] = stages[index].streaming;
                    ++index;
                }
                text = fusedStreamingRange(text, fused[0 .. fusedLength]).to!string;
                continue;
            }
            auto stage = stages[index++];
            if (stage.configured.isValid)
                text = stage.configured(text);
            else
                text = stage.plain(text);
        }
        return text;
    }

    version (MaterializationWorkProbe) {
        /// Run the unchanged filter decisions with caller-owned boundary
        /// accounting. Ordinary builds contain neither this entry point nor
        /// the GC/counter branches.
        string runMeasured(string text, ref PipelineMaterializationWorkV1 work) const {
            import core.memory : GC;

            size_t index;
            while (index < stages.length) {
                if (stages[index].streaming.push !is null) {
                    StreamingFilter[maxFusedStages] fused;
                    size_t fusedLength;
                    while (index < stages.length &&
                           stages[index].streaming.push !is null &&
                           fusedLength < maxFusedStages) {
                        fused[fusedLength++] = stages[index].streaming;
                        ++index;
                    }
                    auto input = text;
                    auto inputBytes = input.length;
                    auto before = GC.allocatedInCurrentThread;
                    text = fusedStreamingRange(text,
                        fused[0 .. fusedLength]).to!string;
                    auto after = GC.allocatedInCurrentThread;
                    enforce(after >= before,
                        "pipeline GC counter moved backwards");
                    auto boundary = &work.fusedScalar;
                    ++boundary.calls;
                    boundary.inputBytes += inputBytes;
                    boundary.outputBytes += text.length;
                    boundary.logicalMaterializedBytes += text.length;
                    boundary.gcAllocatedBytes += after - before;
                    recordOutputRelation(*boundary, input, text);
                    continue;
                }
                auto stage = stages[index++];
                auto input = text;
                auto before = GC.allocatedInCurrentThread;
                text = stage.configured.isValid
                    ? stage.configured(text) : stage.plain(text);
                auto after = GC.allocatedInCurrentThread;
                enforce(after >= before,
                    "pipeline GC counter moved backwards");
                auto boundary = &work.wholeTextFilter;
                ++boundary.calls;
                boundary.inputBytes += input.length;
                boundary.outputBytes += text.length;
                boundary.gcAllocatedBytes += after - before;
                recordOutputRelation(*boundary, input, text);
            }
            return text;
        }
    }

    const(string)[] names() const {
        return stageNames;
    }
}

version (MaterializationWorkProbe) {
    enum OutputStorageRelation : ubyte { borrowed, overlaps, distinct }

    /// Classify byte-storage relationships without ordering unrelated
    /// pointers. Integer intervals also make partial overlap explicit. An
    /// empty output borrows when its pointer is anywhere from the input start
    /// through its one-past-the-end address; two identical empty slices borrow.
    OutputStorageRelation classifyOutputStorage(string input,
            string output) pure {
        auto inputStart = cast(size_t)input.ptr;
        auto outputStart = cast(size_t)output.ptr;
        if (input.length == 0)
            return output.length == 0 && outputStart == inputStart
                ? OutputStorageRelation.borrowed
                : OutputStorageRelation.distinct;
        if (input.length > size_t.max - inputStart)
            return OutputStorageRelation.distinct;
        auto inputEnd = inputStart + input.length;
        if (output.length == 0)
            return outputStart >= inputStart && outputStart <= inputEnd
                ? OutputStorageRelation.borrowed
                : OutputStorageRelation.distinct;
        if (output.length > size_t.max - outputStart)
            return outputStart >= inputStart && outputStart < inputEnd
                ? OutputStorageRelation.overlaps
                : OutputStorageRelation.distinct;
        auto outputEnd = outputStart + output.length;
        if (outputStart >= inputStart && outputEnd <= inputEnd)
            return OutputStorageRelation.borrowed;
        if (outputStart < inputEnd && inputStart < outputEnd)
            return OutputStorageRelation.overlaps;
        return OutputStorageRelation.distinct;
    }

    struct PipelineBoundaryWorkV1 {
        ulong calls;
        ulong inputBytes;
        ulong outputBytes;
        ulong logicalMaterializedBytes;
        ulong gcAllocatedBytes;
        ulong aliasedOutputCalls;
        ulong overlappingOutputCalls;
        ulong distinctOutputCalls;
        ulong aliasedOutputBytes;
        ulong overlappingOutputBytes;
        ulong distinctOutputBytes;
    }

    struct PipelineMaterializationWorkV1 {
        PipelineBoundaryWorkV1 fusedScalar;
        PipelineBoundaryWorkV1 wholeTextFilter;
    }

    private void recordOutputRelation(ref PipelineBoundaryWorkV1 work,
            string input, string output) pure {
        final switch (classifyOutputStorage(input, output)) {
        case OutputStorageRelation.borrowed:
            ++work.aliasedOutputCalls;
            work.aliasedOutputBytes += output.length;
            break;
        case OutputStorageRelation.overlaps:
            ++work.overlappingOutputCalls;
            work.overlappingOutputBytes += output.length;
            break;
        case OutputStorageRelation.distinct:
            ++work.distinctOutputCalls;
            work.distinctOutputBytes += output.length;
            break;
        }
    }
}

/// Compose a runtime-selected list of bounded transducers as one Voldemort
/// InputRange. The returned struct owns mutable per-stage state and queues;
/// the source string remains borrowed until consumption completes.
private auto fusedStreamingRange(string text, const(StreamingFilter)[] configured) {
    struct RuntimeStage {
        StreamingFilter configured;
        StreamingState state;
        dchar[maxStreamingExpansion] pending;
        ubyte pendingAt;
        ubyte pendingLength;
        bool finished;
    }

    struct FusedStreamingRange {
        private typeof(text.byUTF!(dchar, No.useReplacementDchar)) source;
        private RuntimeStage[maxFusedStages] stages;
        private ubyte stageCount;
        private dchar cached;
        private bool cachedReady;
        private bool exhausted;

        private bool pullStage(size_t index, out dchar value) {
            auto stage = &stages[index];
            while (true) {
                if (stage.pendingAt < stage.pendingLength) {
                    value = stage.pending[stage.pendingAt++];
                    return true;
                }
                stage.pendingAt = 0;
                stage.pendingLength = 0;

                dchar input;
                bool haveInput;
                if (index == 0) {
                    if (!source.empty) {
                        input = source.front;
                        source.popFront();
                        haveInput = true;
                    }
                } else {
                    haveInput = pullStage(index - 1, input);
                }

                size_t emitted;
                if (haveInput) {
                    emitted = stage.configured.push(stage.state, input,
                        &stage.pending);
                } else if (!stage.finished) {
                    stage.finished = true;
                    if (stage.configured.finish !is null)
                        emitted = stage.configured.finish(stage.state,
                            &stage.pending);
                } else {
                    return false;
                }
                enforce(emitted <= maxStreamingExpansion,
                    "streaming filter exceeded its declared expansion bound");
                stage.pendingLength = cast(ubyte) emitted;
            }
        }

        private void fill() {
            if (cachedReady || exhausted) return;
            if (pullStage(stageCount - 1, cached)) cachedReady = true;
            else exhausted = true;
        }

        @property bool empty() {
            fill();
            return exhausted;
        }

        @property dchar front() {
            fill();
            enforce(cachedReady, "streaming range is empty");
            return cached;
        }

        void popFront() {
            front;
            cachedReady = false;
        }
    }

    enforce(configured.length != 0, "fused streaming range requires a stage");
    enforce(configured.length <= maxFusedStages,
        "fused streaming range has too many stages");
    FusedStreamingRange result;
    result.source = text.byUTF!(dchar, No.useReplacementDchar);
    result.stageCount = cast(ubyte) configured.length;
    foreach (index, definition; configured) {
        enforce(definition.push !is null, "streaming filter has no push implementation");
        result.stages[index].configured = definition;
        result.stages[index].state = definition.initialState;
    }
    return result;
}

import std.conv : to;
import std.range.primitives : isInputRange;

static assert(isInputRange!(typeof(fusedStreamingRange("x", [StreamingFilter(
    StreamingState.init,
    (ref StreamingState, dchar input, dchar[maxStreamingExpansion]* output) {
        (*output)[0] = input;
        return cast(size_t) 1;
    }, null)]))));

private string legacyFilterTest(string text) pure { return text ~ "!"; }

private size_t duplicateStreamingTest(ref StreamingState, dchar input,
        dchar[maxStreamingExpansion]* output) pure {
    (*output)[0] = input;
    (*output)[1] = input;
    return 2;
}

private size_t identityStreamingTest(ref StreamingState, dchar input,
        dchar[maxStreamingExpansion]* output) pure {
    (*output)[0] = input;
    return 1;
}

private size_t delayedStreamingTest(ref StreamingState state, dchar input,
        dchar[maxStreamingExpansion]* output) pure {
    if (state.words[0] == 0) {
        state.words[0] = input;
        return 0;
    }
    (*output)[0] = cast(dchar) state.words[0];
    state.words[0] = input;
    return 1;
}

private size_t delayedStreamingFinishTest(ref StreamingState state,
        dchar[maxStreamingExpansion]* output) pure {
    if (state.words[0] == 0) return 0;
    (*output)[0] = cast(dchar) state.words[0];
    state.words[0] = 0;
    return 1;
}

private class TypedFilterTestConfiguration : FilterConfiguration {
    long count;
    bool enabled;
    string label;

    this(long count, bool enabled, string label) immutable {
        this.count = count;
        this.enabled = enabled;
        this.label = label;
    }
}

private string applyTypedFilterTest(string text,
        immutable(FilterConfiguration) raw) pure {
    auto configured = cast(immutable(TypedFilterTestConfiguration)) raw;
    return configured.enabled
        ? text ~ configured.label ~ configured.count.to!string : text;
}

private ConfiguredFilter typedFactoryTest(const ref TypedFilterOptions options) {
    auto configured = new immutable TypedFilterTestConfiguration(
        options["count"].asInteger, options["enabled"].asBoolean,
        options["label"].asText);
    return ConfiguredFilter(&applyTypedFilterTest, configured);
}

unittest {
    import std.exception : assertThrown;

    size_t mutableState;
    auto captured = (string input, immutable(FilterConfiguration)) {
        ++mutableState;
        return input;
    };
    static assert(!__traits(compiles, ConfiguredFilter(captured)));
    assertThrown(ConfiguredFilter.init("x"));

    Filter typedLegacy = &legacyFilterTest;
    auto registrar = &registerFilter;
    registrar("__legacy-filter-test", typedLegacy);
    assert(Pipeline.buildTyped([TypedFilterSpec("__legacy-filter-test")])
        .run("ok") == "ok!");
    assert(Pipeline.buildTyped([]).names.length == 0);
    assert(Pipeline.buildTyped(null).names.length == 0);

    registerStreamingFilter("__stream-duplicate-test",
        StreamingFilter(StreamingState.init, &duplicateStreamingTest, null));
    registerStreamingFilter("__stream-identity-test",
        StreamingFilter(StreamingState.init, &identityStreamingTest, null));
    registerStreamingFilter("__stream-delayed-test",
        StreamingFilter(StreamingState.init, &delayedStreamingTest,
            &delayedStreamingFinishTest));
    assert(Pipeline.buildTyped([TypedFilterSpec("__stream-duplicate-test"),
        TypedFilterSpec("__stream-delayed-test")])
        .run("ab") == "aabb");
    // A whole-buffer stage is a materialization barrier, and execution order
    // remains exactly the user's registration order.
    assert(Pipeline.buildTyped([TypedFilterSpec("__stream-duplicate-test"),
        TypedFilterSpec("__legacy-filter-test"),
        TypedFilterSpec("__stream-delayed-test")]).run("a") == "aa!");
    TypedFilterSpec[] longRun;
    foreach (_; 0 .. 17) longRun ~= TypedFilterSpec("__stream-identity-test");
    assert(Pipeline.buildTyped(longRun).run("bounded") == "bounded");

    // Explicit registries make resolution testable without global mutation.
    FilterRegistry isolated;
    isolated.addFilter("plain", &legacyFilterTest);
    isolated.addTypedFilterFactory("typed", [
        FilterOptionDeclaration("label", FilterOptionType.text, true),
        FilterOptionDeclaration("count", FilterOptionType.integer, true),
        FilterOptionDeclaration("enabled", FilterOptionType.boolean, true)
    ], &typedFactoryTest);
    assert(Pipeline.buildTyped([TypedFilterSpec("plain")], &isolated)
        .run("ok") == "ok!");
    TypedFilterOptions typedOptions = [
        "label": FilterOption.text("x"),
        "count": FilterOption.integer(2),
        "enabled": FilterOption.boolean(true)
    ];
    assert(Pipeline.buildTyped([TypedFilterSpec("typed", typedOptions)],
        &isolated).run("a") == "ax2");
    assertThrown(Pipeline.buildTyped([TypedFilterSpec("typed")], &isolated));
    assertThrown(Pipeline.buildTyped([TypedFilterSpec("__legacy-filter-test")],
        &isolated));
    assertThrown(Pipeline.buildTyped([TypedFilterSpec("typed", [
        "label": FilterOption.text("x"),
        "count": FilterOption.text("2"),
        "enabled": FilterOption.boolean(true)])], &isolated));
    assertThrown(Pipeline.buildTyped([TypedFilterSpec("typed", [
        "label": FilterOption.text("x"),
        "count": FilterOption.integer(2)])], &isolated));
    assertThrown(Pipeline.buildTyped([TypedFilterSpec("typed", [
        "label": FilterOption.text("x"),
        "count": FilterOption.integer(2),
        "enabled": FilterOption.boolean(true),
        "unknown": FilterOption.text("x")])], &isolated));
    assertThrown(isolated.addFilter("plain", &legacyFilterTest));
    static assert(!__traits(compiles, availableFilterRegistry().addFilter(
        "forbidden", &legacyFilterTest)));
    assertThrown(Pipeline.buildTyped([TypedFilterSpec("__stream-identity-test")])
        .run(cast(string)[cast(char) 0xC3]));
}
