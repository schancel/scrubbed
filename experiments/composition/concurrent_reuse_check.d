/// Release-active proof that compiled execution retains no mutable closure state.
module experiments.composition.concurrent_reuse_check;

version (LegacyClosureApi) {
import composition.compiler : CompiledJob, compileJob;
import composition.executor : runCompiledStage;
import content.pieces : Content, ContentPiece;
import domain.document : Document, OutputName, SourceLocator;
import job.json : parseJobJson;
import pipeline : ConfiguredFilter, FilterRegistry, TypedFilterOptions;
import stages.contract : PassMode, ResourceDeclaration, StageDecision,
    StageDeclaration, StageDocument, StageTransform;
import stages.registry : FilterPlacement, StageOptions, StageRegistration,
    StageRegistry;
import std.conv : to;
import std.exception : enforce;
import std.stdio : writeln;

private Content legacyOwnedText(string text) {
    return new Content([ContentPiece.own(cast(const(ubyte)[]) text)]);
}

private string legacyText(Content content) {
    ubyte[] bytes;
    content.stream((const(ubyte)[] chunk) { bytes ~= chunk; });
    return cast(string) bytes;
}

private StageTransform legacyStageFactory(const ref StageOptions options) {
    size_t calls;
    return (StageDocument input) {
        ++calls;
        input.content = legacyOwnedText(legacyText(input.content) ~ "S" ~
            calls.to!string);
        return StageDecision.map(input);
    };
}

private ConfiguredFilter legacyFilterFactory(
        const ref TypedFilterOptions options) {
    size_t calls;
    return (string input) {
        ++calls;
        return input ~ "F" ~ calls.to!string;
    };
}

private string legacyRun(const ref CompiledJob job, string record) {
    auto input = StageDocument(Document(SourceLocator("concurrent-reuse",
        "memory", record), OutputName("out")), legacyOwnedText("x"));
    return legacyText(runCompiledStage([input], job.stages[0])
        .events[0].payload.content);
}

void main() {
    StageRegistry stages;
    stages.add(StageRegistration(StageDeclaration("append",
        PassMode.singlePass, ResourceDeclaration(1, 0)), null, null, null,
        &legacyStageFactory, FilterPlacement.before));
    FilterRegistry filters;
    filters.addTypedFilterFactory("append", null, &legacyFilterFactory);
    auto spec = parseJobJson(`{"version":3,"stages":[{"id":"append",` ~
        `"implementation":"append","filters":[{"name":"append"}]}]}`);
    auto job = compileJob(spec, &stages, &filters);
    auto copied = job;
    auto first = legacyRun(job, "first");
    auto second = legacyRun(job, "second");
    auto copiedResult = legacyRun(copied, "copied");
    writeln("first=", first, " second=", second, " copied=", copiedResult);
    enforce(first == second && first == copiedResult,
        "compiled execution retained mutable closure state");
}
} else {
import composition.compiler : CompiledJob, compileJob;
import composition.executor : runCompiledStage;
import content.pieces : Content, ContentPiece;
import core.thread : Thread;
import domain.document : Document, OutputName, SourceLocator;
import job.json : parseJobJson;
import pipeline : ConfiguredFilter, Filter, FilterConfiguration, FilterRegistry,
    Pipeline, StreamingFilter, StreamingFinish, StreamingPush, StreamingState,
    TypedFilterOptions, maxStreamingExpansion;
import stages.contract : EventKind, PassMode, ResourceDeclaration,
    StageDecision, StageDeclaration, StageDocument;
import stages.registry : ConfiguredStageTransform, FilterPlacement,
    StageConfiguration, StageOptions, StageRegistration, StageRegistry;
import std.algorithm : all;
import std.conv : to;
import std.exception : enforce;
import std.stdio : writeln;

private size_t stageFactoryCalls;
private size_t filterFactoryCalls;
private size_t forbiddenGlobalState;

private class AppendStageConfiguration : StageConfiguration {
    string suffix;
    this(string suffix) immutable { this.suffix = suffix; }
}

private class AppendFilterConfiguration : FilterConfiguration {
    string suffix;
    this(string suffix) immutable { this.suffix = suffix; }
}

private Content ownedText(string text) pure {
    return new Content([ContentPiece.own(cast(const(ubyte)[]) text)]);
}

private string materializedText(Content content) pure {
    ubyte[] bytes;
    content.stream((const(ubyte)[] chunk) { bytes ~= chunk; });
    return cast(string) bytes;
}

private StageDecision applyAppendStage(StageDocument input,
        immutable(StageConfiguration) raw) pure {
    auto configured = cast(immutable(AppendStageConfiguration)) raw;
    input.content = ownedText(materializedText(input.content) ~ configured.suffix);
    return StageDecision.map(input);
}

private ConfiguredStageTransform appendStageFactory(
        const ref StageOptions options) {
    ++stageFactoryCalls;
    return ConfiguredStageTransform(&applyAppendStage,
        new immutable AppendStageConfiguration("S"));
}

private string applyAppendFilter(string text,
        immutable(FilterConfiguration) raw) pure {
    auto configured = cast(immutable(AppendFilterConfiguration)) raw;
    return text ~ configured.suffix;
}

private ConfiguredFilter appendFilterFactory(
        const ref TypedFilterOptions options) {
    ++filterFactoryCalls;
    return ConfiguredFilter(&applyAppendFilter,
        new immutable AppendFilterConfiguration("F"));
}

private size_t delayedPush(ref StreamingState state, dchar input,
        dchar[maxStreamingExpansion]* output) pure {
    if (state.words[0] == 0) {
        state.words[0] = input;
        return 0;
    }
    (*output)[0] = cast(dchar) state.words[0];
    state.words[0] = input;
    return 1;
}

private size_t delayedFinish(ref StreamingState state,
        dchar[maxStreamingExpansion]* output) pure {
    if (state.words[0] == 0) return 0;
    (*output)[0] = cast(dchar) state.words[0];
    state.words[0] = 0;
    return 1;
}

private StageDecision globalMutatingStage(StageDocument input,
        immutable(StageConfiguration)) {
    ++forbiddenGlobalState;
    return StageDecision.map(input);
}

private string globalMutatingConfiguredFilter(string input,
        immutable(FilterConfiguration)) {
    ++forbiddenGlobalState;
    return input;
}

private string globalMutatingPlainFilter(string input) {
    ++forbiddenGlobalState;
    return input;
}

private size_t globalMutatingPush(ref StreamingState, dchar,
        dchar[maxStreamingExpansion]*) {
    return ++forbiddenGlobalState;
}

private size_t globalMutatingFinish(ref StreamingState,
        dchar[maxStreamingExpansion]*) {
    return ++forbiddenGlobalState;
}

private StageDocument inputFor(size_t ordinal) {
    return StageDocument(Document(SourceLocator("concurrent-reuse", "memory",
        "record-" ~ ordinal.to!string), OutputName("out")), ownedText("x"));
}

private bool oneRun(const ref CompiledJob job, size_t ordinal,
        const ref Pipeline streaming) {
    auto result = runCompiledStage([inputFor(ordinal)], job.stages[0]);
    return result.events.length == 1 &&
        result.events[0].kind == EventKind.emitted &&
        materializedText(result.events[0].payload.content) == "xFS" &&
        streaming.run("ab") == "ab";
}

private Thread worker(size_t index, CompiledJob job, Pipeline streaming,
        bool[] passed) {
    return new Thread(() {
        foreach (iteration; 0 .. 100)
            if (!oneRun(job, index * 100 + iteration, streaming)) return;
        passed[index] = true;
    });
}

private void compileBoundaryProof() {
    size_t mutableState;
    auto capturedStage = (StageDocument input,
            immutable(StageConfiguration)) {
        ++mutableState;
        return StageDecision.map(input);
    };
    auto capturedFilter = (string input, immutable(FilterConfiguration)) {
        ++mutableState;
        return input;
    };
    static assert(!__traits(compiles,
        ConfiguredStageTransform(capturedStage)));
    static assert(!__traits(compiles,
        ConfiguredFilter(capturedFilter)));
    static assert(!__traits(compiles,
        ConfiguredStageTransform(&globalMutatingStage)));
    static assert(!__traits(compiles,
        ConfiguredFilter(&globalMutatingConfiguredFilter)));
    static assert(!__traits(compiles, {
        Filter callback = &globalMutatingPlainFilter;
    }));
    static assert(!__traits(compiles, {
        StreamingPush callback = &globalMutatingPush;
    }));
    static assert(!__traits(compiles, {
        StreamingFinish callback = &globalMutatingFinish;
    }));
}

void main() {
    StageRegistry stages;
    stages.add(StageRegistration(StageDeclaration("append",
        PassMode.singlePass, ResourceDeclaration(1, 0)), null, null, null,
        &appendStageFactory, FilterPlacement.before));
    FilterRegistry filters;
    filters.addTypedFilterFactory("append", null, &appendFilterFactory);

    auto spec = parseJobJson(`{"version":3,"stages":[{"id":"append",` ~
        `"implementation":"append","filters":[{"name":"append"}]}]}`);
    auto job = compileJob(spec, &stages, &filters);
    auto copied = job;
    enforce(stageFactoryCalls == 1 && filterFactoryCalls == 1,
        "factories did not run exactly once during compilation");

    FilterRegistry streamingFilters;
    streamingFilters.addStreamingFilter("delayed", StreamingFilter(
        StreamingState.init, &delayedPush, &delayedFinish));
    auto streaming = Pipeline.build(["delayed"], &streamingFilters);

    enforce(oneRun(job, 0, streaming) && oneRun(job, 1, streaming) &&
        oneRun(copied, 2, streaming),
        "sequential or copied execution retained mutable state");

    enum workerCount = 8;
    bool[] passed = new bool[workerCount];
    Thread[] workers;
    foreach (index; 0 .. workerCount)
        workers ~= worker(index, index % 2 == 0 ? job : copied,
            streaming, passed);
    foreach (thread; workers) thread.start;
    foreach (thread; workers) thread.join;
    enforce(passed.all, "concurrent execution was not deterministic");
    enforce(stageFactoryCalls == 1 && filterFactoryCalls == 1,
        "document execution rebuilt a factory");
    writeln("sequential=true copied=true concurrent=true streaming_fresh=true ",
        "stage_factory_calls=1 filter_factory_calls=1");
}
}
