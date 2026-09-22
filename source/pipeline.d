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
import std.typecons : No;
import std.utf : byUTF;

alias FilterOptions = string[string];
/// Original public filter contract, retained for source compatibility.
alias Filter = string function(string);
/// A configured stage may capture typed options parsed once at build time.
alias ConfiguredFilter = string delegate(string);
alias FilterFactory = ConfiguredFilter function(const ref FilterOptions);

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

private struct FilterRegistration {
    Filter plain;
    FilterFactory factory;
    StreamingFilter streaming;
    StreamingFilterFactory streamingFactory;
}

private FilterRegistration[string] registry;

/// Register a filter under `name`. Call once per filter, typically from a
/// module constructor (`static this()`) in that filter's own module, so
/// registration stays next to the implementation rather than centralized
/// in one big list someone has to remember to update.
void registerFilter(string name, Filter f) {
    registry[name] = FilterRegistration(f, null, StreamingFilter.init, null);
}

/// Register an option-aware factory. It must validate and parse every option;
/// Pipeline.build calls it once and stores the returned typed closure.
void registerFilterFactory(string name, FilterFactory factory) {
    registry[name] = FilterRegistration(null, factory, StreamingFilter.init, null);
}

/// Register a no-option filter with both its compatibility materializer and
/// its bounded streaming implementation.
void registerStreamingFilter(string name, Filter fallback, StreamingFilter streaming) {
    enforce(fallback !is null && streaming.push !is null,
        "streaming filter requires fallback and push implementations");
    registry[name] = FilterRegistration(fallback, null, streaming, null);
}

/// Option-aware equivalent. The streaming factory validates and parses the
/// immutable options used by Pipeline; the fallback remains available to
/// compatibility callers that require a materialized string transform.
void registerStreamingFilterFactory(string name, FilterFactory fallback,
    StreamingFilterFactory streamingFactory) {
    enforce(fallback !is null && streamingFactory !is null,
        "streaming filter requires both factories");
    registry[name] = FilterRegistration(null, fallback, StreamingFilter.init,
        streamingFactory);
}

string[] availableFilters() {
    return registry.keys;
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

    static Pipeline build(const(string)[] filterNames) {
        FilterSpec[] specs;
        foreach (name; filterNames) specs ~= FilterSpec(name);
        return buildConfigured(specs);
    }

    static Pipeline buildConfigured(FilterSpec[] specs) {
        Pipeline p;
        foreach (spec; specs) {
            auto registration = spec.name in registry;
            if (registration is null)
                throw new Exception("unknown filter: " ~ spec.name ~
                    " (available: " ~ availableFilters.idup.to!string ~ ")");
            if (registration.factory !is null) {
                if (registration.streamingFactory !is null) {
                    auto streaming = registration.streamingFactory(spec.options);
                    enforce(streaming.push !is null,
                        "streaming filter factory returned no push implementation");
                    p.stages ~= Stage(null, null, streaming);
                } else {
                    p.stages ~= Stage(null, registration.factory(spec.options));
                }
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

private ConfiguredFilter streamingFallbackFactoryTest(
    const ref FilterOptions options) {
    enforce(options.length == 1 && options.get("mode", "") == "identity",
        "expected mode=identity");
    return delegate string(string text) { return text; };
}

private StreamingFilter streamingFactoryTest(const ref FilterOptions options) {
    enforce(options.length == 1 && options.get("mode", "") == "identity",
        "expected mode=identity");
    return StreamingFilter(StreamingState.init, &identityStreamingTest, null);
}

unittest {
    import std.exception : assertThrown;

    Filter typedLegacy = &legacyFilterTest;
    auto registrar = &registerFilter;
    registrar("__legacy-filter-test", typedLegacy);
    assert(Pipeline.build(["__legacy-filter-test"]).run("ok") == "ok!");
    assert(Pipeline.build([]).names.length == 0);
    assert(Pipeline.build(null).names.length == 0);

    registerStreamingFilter("__stream-duplicate-test", typedLegacy,
        StreamingFilter(StreamingState.init, &duplicateStreamingTest, null));
    registerStreamingFilter("__stream-identity-test", typedLegacy,
        StreamingFilter(StreamingState.init, &identityStreamingTest, null));
    registerStreamingFilter("__stream-delayed-test", typedLegacy,
        StreamingFilter(StreamingState.init, &delayedStreamingTest,
            &delayedStreamingFinishTest));
    registerStreamingFilterFactory("__stream-factory-test",
        &streamingFallbackFactoryTest, &streamingFactoryTest);
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
    assertThrown(Pipeline.build(["__stream-identity-test"])
        .run(cast(string)[cast(char) 0xC3]));
}
