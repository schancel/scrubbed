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

alias FilterOptions = string[string];
/// Original public filter contract, retained for source compatibility.
alias Filter = string function(string);
/// A configured stage may capture typed options parsed once at build time.
alias ConfiguredFilter = string delegate(string);
alias FilterFactory = ConfiguredFilter function(const ref FilterOptions);

enum FilterOptionType { text, integer, boolean }

/// Typed v3 option value. The predecessor factory API remains separate so its
/// string-coercion behavior can be retired only after the CLI switch is proven.
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
    dchar[maxStreamingExpansion]*);
alias StreamingFinish = size_t function(ref StreamingState,
    dchar[maxStreamingExpansion]*);

/// One bounded UTF-8-scalar transducer. `push` and `finish` may emit at most
/// `maxStreamingExpansion` scalars. Empty output drops an input scalar.
struct StreamingFilter {
    StreamingState initialState;
    StreamingPush push;
    StreamingFinish finish;
}

alias StreamingFilterFactory = StreamingFilter function(const ref FilterOptions);

struct FilterSpec {
    string name;
    FilterOptions options;
}

struct TypedFilterSpec {
    string name;
    TypedFilterOptions options;
}

private struct FilterRegistration {
    Filter plain;
    FilterFactory factory;
    TypedFilterFactory typedFactory;
    FilterOptionDeclaration[] optionDeclarations;
    StreamingFilter streaming;
    StreamingFilterFactory streamingFactory;
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

    void addFilterFactory(string name, FilterFactory factory) {
        enforce(factory !is null, "filter factory is required");
        FilterRegistration registration;
        registration.factory = factory;
        add(name, registration);
    }

    void addTypedFilterFactory(string name,
            FilterOptionDeclaration[] declarations,
            TypedFilterFactory typedFactory,
            FilterFactory legacyFactory = null) {
        enforce(typedFactory !is null, "typed filter factory is required");
        FilterRegistration registration;
        registration.factory = legacyFactory;
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

    void addStreamingFilterFactory(string name,
            StreamingFilterFactory streamingFactory) {
        enforce(streamingFactory !is null, "streaming filter requires a factory");
        FilterRegistration registration;
        registration.streamingFactory = streamingFactory;
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

/// Register an option-aware factory. It must validate and parse every option;
/// Pipeline.build calls it once and stores the returned typed closure.
void registerFilterFactory(string name, FilterFactory factory) {
    registeredFilters.addFilterFactory(name, factory);
}

/// Register a typed v3 factory and, while v1 remains accepted, its exact
/// predecessor adapter. New configuration code should use the typed factory.
void registerTypedFilterFactory(string name,
        FilterOptionDeclaration[] declarations,
        TypedFilterFactory typedFactory,
        FilterFactory legacyFactory = null) {
    registeredFilters.addTypedFilterFactory(name, declarations, typedFactory,
        legacyFactory);
}

/// Register a no-option bounded streaming implementation.
void registerStreamingFilter(string name, StreamingFilter streaming) {
    registeredFilters.addStreamingFilter(name, streaming);
}

/// Option-aware equivalent. The factory validates and parses immutable
/// options once while Pipeline is built.
void registerStreamingFilterFactory(string name,
    StreamingFilterFactory streamingFactory) {
    registeredFilters.addStreamingFilterFactory(name, streamingFactory);
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

    static Pipeline build(const(string)[] filterNames,
            const(FilterRegistry)* selected = null) {
        FilterSpec[] specs;
        foreach (name; filterNames) specs ~= FilterSpec(name);
        return buildConfigured(specs, selected);
    }

    static Pipeline buildConfigured(FilterSpec[] specs,
            const(FilterRegistry)* selected = null) {
        if (selected is null) selected = availableFilterRegistry();
        Pipeline p;
        foreach (spec; specs) {
            auto registration = spec.name in selected.registrations;
            if (registration is null)
                throw new Exception("unknown filter: " ~ spec.name ~
                    " (available: " ~ availableFilters(selected).idup.to!string ~ ")");
            if (registration.streamingFactory !is null) {
                auto streaming = registration.streamingFactory(spec.options);
                enforce(streaming.push !is null,
                    "streaming filter factory returned no push implementation");
                p.stages ~= Stage(null, null, streaming);
            } else if (registration.factory !is null) {
                p.stages ~= Stage(null, registration.factory(spec.options));
            } else if (registration.typedFactory !is null) {
                throw new Exception("filter '" ~ spec.name ~
                    "' has no predecessor configuration adapter");
            } else {
                if (spec.options.length)
                    throw new Exception("filter '" ~ spec.name ~ "' accepts no options");
                if (registration.streaming.push !is null)
                    p.stages ~= Stage(null, null, registration.streaming);
                else
                    p.stages ~= Stage(registration.plain, null);
            }
            p.stageNames ~= spec.name;
        }
        return p;
    }

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
                enforce(configured !is null,
                    "typed filter factory returned no implementation");
                p.stages ~= Stage(null, configured);
            } else {
                enforce(spec.options.length == 0,
                    "filter '" ~ spec.name ~ "' accepts no typed options");
                enforce(registration.factory is null &&
                    registration.streamingFactory is null,
                    "filter '" ~ spec.name ~ "' has no typed v3 factory");
                if (registration.streaming.push !is null)
                    p.stages ~= Stage(null, null, registration.streaming);
                else
                    p.stages ~= Stage(registration.plain, null);
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
            if (stage.configured !is null)
                text = stage.configured(text);
            else
                text = stage.plain(text);
        }
        return text;
    }

    const(string)[] names() const {
        return stageNames;
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

private string legacyFilterTest(string text) { return text ~ "!"; }

private size_t duplicateStreamingTest(ref StreamingState, dchar input,
    dchar[maxStreamingExpansion]* output) {
    (*output)[0] = input;
    (*output)[1] = input;
    return 2;
}

private size_t identityStreamingTest(ref StreamingState, dchar input,
    dchar[maxStreamingExpansion]* output) {
    (*output)[0] = input;
    return 1;
}

private size_t delayedStreamingTest(ref StreamingState state, dchar input,
    dchar[maxStreamingExpansion]* output) {
    if (state.words[0] == 0) {
        state.words[0] = input;
        return 0;
    }
    (*output)[0] = cast(dchar) state.words[0];
    state.words[0] = input;
    return 1;
}

private size_t delayedStreamingFinishTest(ref StreamingState state,
    dchar[maxStreamingExpansion]* output) {
    if (state.words[0] == 0) return 0;
    (*output)[0] = cast(dchar) state.words[0];
    state.words[0] = 0;
    return 1;
}

private StreamingFilter streamingFactoryTest(const ref FilterOptions options) {
    enforce(options.length == 1 && options.get("mode", "") == "identity",
        "expected mode=identity");
    return StreamingFilter(StreamingState.init, &identityStreamingTest, null);
}

private ConfiguredFilter typedFactoryTest(const ref TypedFilterOptions options) {
    const count = options["count"].asInteger;
    const enabled = options["enabled"].asBoolean;
    const label = options["label"].asText.idup;
    return (string text) => enabled ? text ~ label ~ count.to!string : text;
}

unittest {
    import std.exception : assertThrown;

    Filter typedLegacy = &legacyFilterTest;
    auto registrar = &registerFilter;
    registrar("__legacy-filter-test", typedLegacy);
    assert(Pipeline.build(["__legacy-filter-test"]).run("ok") == "ok!");
    assert(Pipeline.build([]).names.length == 0);
    assert(Pipeline.build(null).names.length == 0);

    registerStreamingFilter("__stream-duplicate-test",
        StreamingFilter(StreamingState.init, &duplicateStreamingTest, null));
    registerStreamingFilter("__stream-identity-test",
        StreamingFilter(StreamingState.init, &identityStreamingTest, null));
    registerStreamingFilter("__stream-delayed-test",
        StreamingFilter(StreamingState.init, &delayedStreamingTest,
            &delayedStreamingFinishTest));
    registerStreamingFilterFactory("__stream-factory-test", &streamingFactoryTest);
    assert(Pipeline.build(["__stream-duplicate-test", "__stream-delayed-test"])
        .run("ab") == "aabb");
    // A whole-buffer stage is a materialization barrier, and execution order
    // remains exactly the user's registration order.
    assert(Pipeline.build(["__stream-duplicate-test", "__legacy-filter-test",
        "__stream-delayed-test"]).run("a") == "aa!");
    string[] longRun;
    foreach (_; 0 .. 17) longRun ~= "__stream-identity-test";
    assert(Pipeline.build(longRun).run("bounded") == "bounded");
    FilterOptions factoryOptions = ["mode": "identity"];
    assert(Pipeline.buildConfigured([FilterSpec("__stream-factory-test",
        factoryOptions)]).run("configured") == "configured");
    factoryOptions["unknown"] = "rejected";
    assertThrown(Pipeline.buildConfigured([FilterSpec("__stream-factory-test",
        factoryOptions)]));

    // Explicit registries make resolution testable without global mutation.
    FilterRegistry isolated;
    isolated.addFilter("plain", &legacyFilterTest);
    isolated.addTypedFilterFactory("typed", [
        FilterOptionDeclaration("label", FilterOptionType.text, true),
        FilterOptionDeclaration("count", FilterOptionType.integer, true),
        FilterOptionDeclaration("enabled", FilterOptionType.boolean, true)
    ], &typedFactoryTest);
    assert(Pipeline.build(["plain"], &isolated).run("ok") == "ok!");
    TypedFilterOptions typedOptions = [
        "label": FilterOption.text("x"),
        "count": FilterOption.integer(2),
        "enabled": FilterOption.boolean(true)
    ];
    assert(Pipeline.buildTyped([TypedFilterSpec("typed", typedOptions)],
        &isolated).run("a") == "ax2");
    assertThrown(Pipeline.build(["typed"], &isolated));
    assertThrown(Pipeline.build(["__legacy-filter-test"], &isolated));
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
    assertThrown(Pipeline.build(["__stream-identity-test"])
        .run(cast(string)[cast(char) 0xC3]));
}
