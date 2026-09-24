/// Release-active terminal side-output ownership and propagation proof.
module experiments.terminal_side_output.check;

import composition.compiler : CompiledJob, compileJob;
import composition.job_executor : CompiledJobFailure, runCompiledJob;
import content.pieces : Content, ContentPiece;
import core.thread : Thread;
import crypto.sha256 : sha256Of;
import domain.document : Document, OutputName, SourceLocator;
import job.json : jobIdentity, parseJobJson;
import pipeline : Filter, FilterRegistry;
import stages.contract : EventKind, PassMode, ResourceDeclaration,
    StageDecision, StageDeclaration, StageDocument, TerminalSideOutput;
import stages.registry : ConfiguredStageTransform, FilterPlacement,
    SideOutputCapability, StageApply, StageCardinality, StageConfiguration,
    StageOptions, StageRegistration, StageRegistry;
import std.conv : to;
import std.exception : enforce;
import std.stdio : writeln;

private enum Operation { map, reject, quarantine, explode, omit, split }

private class Configuration : StageConfiguration {
    Operation operation;
    this(Operation operation) immutable { this.operation = operation; }
}

private Content owned(string value) pure {
    return new Content([ContentPiece.own(cast(const(ubyte)[]) value)]);
}

private StageDocument inputFor(size_t ordinal) {
    return StageDocument(Document(SourceLocator("terminal-side-output",
        "memory", ordinal.to!string), OutputName("out")), owned("content"));
}

private TerminalSideOutput outputFor(size_t ordinal) pure {
    auto bytes = cast(ubyte[])("record-" ~ ordinal.to!string).dup;
    return TerminalSideOutput("audit", "side-output-v1", ".audit.json", bytes);
}

private StageDecision applyProducer(StageDocument input,
        immutable(StageConfiguration) raw) pure {
    auto configured = cast(immutable(Configuration)) raw;
    auto output = outputFor(input.document.source.recordKey.to!size_t);
    final switch (configured.operation) {
    case Operation.map:
        return StageDecision.map(input, [output]);
    case Operation.reject:
        return StageDecision.reject("policy", [output]);
    case Operation.quarantine:
        return StageDecision.quarantine("review", [output]);
    case Operation.explode:
        throw new Exception("producer failed");
    case Operation.omit:
        return StageDecision.map(input);
    case Operation.split:
        return StageDecision.split([input, input]);
    }
}

private ConfiguredStageTransform producer(Operation operation) {
    return ConfiguredStageTransform(&applyProducer,
        new immutable Configuration(operation));
}

private ConfiguredStageTransform mapFactory(const ref StageOptions) {
    return producer(Operation.map);
}
private ConfiguredStageTransform rejectFactory(const ref StageOptions) {
    return producer(Operation.reject);
}
private ConfiguredStageTransform quarantineFactory(const ref StageOptions) {
    return producer(Operation.quarantine);
}
private ConfiguredStageTransform explodeFactory(const ref StageOptions) {
    return producer(Operation.explode);
}
private ConfiguredStageTransform omitFactory(const ref StageOptions) {
    return producer(Operation.omit);
}
private ConfiguredStageTransform splitFactory(const ref StageOptions) {
    return producer(Operation.split);
}

private StageDecision applyPlain(StageDocument input,
        immutable(StageConfiguration)) pure {
    return StageDecision.map(input);
}
private ConfiguredStageTransform plainFactory(const ref StageOptions) {
    return ConfiguredStageTransform(&applyPlain);
}

private StageDecision applyEarlyReject(StageDocument input,
        immutable(StageConfiguration)) pure {
    return StageDecision.reject("early policy");
}
private ConfiguredStageTransform earlyRejectFactory(const ref StageOptions) {
    return ConfiguredStageTransform(&applyEarlyReject);
}

private StageRegistration terminal(string key,
        ConfiguredStageTransform function(const ref StageOptions) factory,
        FilterPlacement placement = FilterPlacement.none,
        StageCardinality cardinality = StageCardinality.oneToOne) {
    return StageRegistration(StageDeclaration(key, PassMode.singlePass,
        ResourceDeclaration(1, 0)), null, null, null, factory, placement,
        cardinality, SideOutputCapability.terminal);
}

private StageRegistration plain(string key) {
    return StageRegistration(StageDeclaration(key, PassMode.singlePass,
        ResourceDeclaration(1, 0)), null, null, null, &plainFactory,
        FilterPlacement.none);
}

private bool throws(void delegate() action) {
    try action();
    catch (Exception) return true;
    return false;
}

private CompiledJob planFor(string implementation, StageRegistry* stages,
        FilterRegistry* filters = null) {
    auto spec = parseJobJson(`{"version":3,"stages":[{"id":"terminal",` ~
        `"implementation":"` ~ implementation ~ `"}]}`);
    return compileJob(spec, stages, filters);
}

private __gshared size_t forbiddenGlobal;
private StageDecision globalHandoff(StageDocument input,
        immutable(StageConfiguration)) {
    ++forbiddenGlobal;
    return StageDecision.map(input);
}
private StageDecision threadLocalHandoff(StageDocument input,
        immutable(StageConfiguration)) {
    static size_t forbiddenThreadLocal;
    ++forbiddenThreadLocal;
    return StageDecision.map(input);
}

private void proveValueBoundsAndOwnership() {
    auto mutableBytes = cast(ubyte[]) "owned".dup;
    auto output = TerminalSideOutput("audit", "side-output-v1",
        ".audit.json", mutableBytes);
    mutableBytes[] = cast(ubyte) 'x';
    enforce(cast(string) output.bytes == "owned",
        "side output retained mutable caller storage");
    enforce(output.digest == sha256Of(cast(const(ubyte)[]) "owned"),
        "side output digest does not bind its owned bytes");

    ubyte[] tooLarge = new ubyte[TerminalSideOutput.maxPayloadBytes + 1];
    enforce(throws(() { TerminalSideOutput("audit", "side-output-v1",
        ".audit.json", tooLarge); }), "oversize side output was accepted");
    foreach (bad; ["../audit", "audit/path", "audit..key", ".audit"])
        enforce(throws(() { TerminalSideOutput(bad, "side-output-v1",
            ".audit.json", null); }), "path-like side-output key was accepted");
    enforce(throws(() { TerminalSideOutput("audit", "../schema",
        ".audit.json", null); }), "path-like schema was accepted");
    enforce(throws(() { TerminalSideOutput("audit", "side-output-v1",
        "audit.json", null); }), "non-suffix side-output name was accepted");
    auto duplicate = outputFor(0);
    enforce(throws(() { StageDecision.map(inputFor(0),
        [duplicate, duplicate]); }), "duplicate side-output key/suffix was accepted");
    enforce(throws(() { StageDecision.map(inputFor(0),
        [TerminalSideOutput.init]); }),
        "default-initialized side output was accepted");
}

private void proveCompilerEnforcement() {
    FilterRegistry filters;
    filters.addFilter("later", cast(Filter) ((string input) => input ~ "!"));

    StageRegistry stages;
    stages.add(terminal("producer", &mapFactory));
    stages.add(plain("plain"));
    auto nonterminal = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"producer","implementation":"producer"},` ~
        `{"id":"later","implementation":"plain"}]}`);
    enforce(throws(() { compileJob(nonterminal, &stages, &filters); }),
        "nonterminal side-output producer compiled");

    StageRegistry splitting;
    splitting.add(terminal("producer", &splitFactory,
        FilterPlacement.none, StageCardinality.maySplit));
    enforce(throws(() { planFor("producer", &splitting, &filters); }),
        "splitting side-output producer compiled");

    StageRegistry upstreamSplit;
    upstreamSplit.add(StageRegistration(StageDeclaration("split",
        PassMode.singlePass, ResourceDeclaration(1, 0)), null, null, null,
        &plainFactory, FilterPlacement.none, StageCardinality.maySplit));
    upstreamSplit.add(terminal("producer", &mapFactory));
    auto upstreamSplitSpec = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"split","implementation":"split"},` ~
        `{"id":"producer","implementation":"producer"}]}`);
    enforce(throws(() { compileJob(upstreamSplitSpec, &upstreamSplit,
        &filters); }), "upstream split before side-output producer compiled");

    StageRegistry after;
    after.add(terminal("producer", &mapFactory, FilterPlacement.after));
    auto afterSpec = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"producer","implementation":"producer",` ~
        `"filters":[{"name":"later"}]}]}`);
    enforce(throws(() { compileJob(afterSpec, &after, &filters); }),
        "post-output content transform compiled");
}

private Thread concurrentWorker(size_t workerIndex, CompiledJob plan,
        bool[] passed) {
    return new Thread({
        foreach (iteration; 0 .. 64) {
            auto ordinal = workerIndex * 64 + iteration;
            auto events = runCompiledJob(inputFor(ordinal), plan);
            if (events.length != 1 || events[0].sideOutputs.length != 1 ||
                    cast(string) events[0].sideOutputs[0].bytes !=
                        "record-" ~ ordinal.to!string)
                return;
        }
        passed[workerIndex] = true;
    });
}

private void proveDecisionsFailureAndConcurrency() {
    StageRegistry stages;
    stages.add(terminal("map", &mapFactory));
    stages.add(terminal("reject", &rejectFactory));
    stages.add(terminal("quarantine", &quarantineFactory));
    stages.add(terminal("explode", &explodeFactory));
    stages.add(terminal("omit", &omitFactory));
    FilterRegistry filters;

    foreach (implementation, expected; ["map": EventKind.emitted,
            "reject": EventKind.rejected,
            "quarantine": EventKind.quarantined]) {
        auto decisionPlan = planFor(implementation, &stages, &filters);
        auto events = runCompiledJob(inputFor(7), decisionPlan);
        enforce(events.length == 1 && events[0].kind == expected &&
            events[0].sideOutputs.length == 1 &&
            cast(string) events[0].sideOutputs[0].bytes == "record-7",
            implementation ~ " did not preserve terminal side output");
    }

    auto failing = planFor("explode", &stages, &filters);
    bool sawFailure;
    try runCompiledJob(inputFor(8), failing);
    catch (CompiledJobFailure error) {
        sawFailure = error.stageId == "terminal" &&
            error.original.msg == "producer failed";
    }
    enforce(sawFailure, "producer failure exposed a partial result");
    auto omit = planFor("omit", &stages, &filters);
    enforce(throws(() { runCompiledJob(inputFor(9), omit); }),
        "declared producer omitted its side output");

    StageRegistry bypassStages;
    bypassStages.add(StageRegistration(StageDeclaration("early-reject",
        PassMode.singlePass, ResourceDeclaration(1, 0)), null, null, null,
        &earlyRejectFactory, FilterPlacement.none, StageCardinality.oneToOne));
    bypassStages.add(terminal("producer", &mapFactory));
    auto bypassSpec = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"early","implementation":"early-reject"},` ~
        `{"id":"producer","implementation":"producer"}]}`);
    auto bypassPlan = compileJob(bypassSpec, &bypassStages, &filters);
    enforce(throws(() { runCompiledJob(inputFor(10), bypassPlan); }),
        "terminal policy bypass returned without the required side output");

    auto sharedPlan = planFor("map", &stages, &filters);
    auto passed = new bool[4];
    Thread[4] workers;
    foreach (index; 0 .. workers.length) {
        workers[index] = concurrentWorker(index, sharedPlan, passed);
        workers[index].start;
    }
    foreach (worker; workers) worker.join;
    enforce(passed == [true, true, true, true],
        "concurrent plan reuse crossed side outputs between roots");
}

private void proveBackwardEquivalence() {
    StageRegistry stages;
    stages.add(plain("plain"));
    FilterRegistry filters;
    auto spec = parseJobJson(
        `{"version":3,"stages":[{"id":"plain","implementation":"plain"}]}`);
    auto plan = compileJob(spec, &stages, &filters);
    auto event = runCompiledJob(inputFor(1), plan)[0];
    enforce(plan.identity == jobIdentity(spec) &&
        event.kind == EventKind.emitted && event.sideOutputs.length == 0 &&
        event.payload.content.copy == cast(const(ubyte)[]) "content",
        "ordinary compiled job behavior or identity changed");
    static assert(!__traits(compiles, {
        StageApply callback = &globalHandoff;
    }));
    static assert(!__traits(compiles, {
        StageApply callback = &threadLocalHandoff;
    }));
}

void main() {
    proveValueBoundsAndOwnership;
    proveCompilerEnforcement;
    proveDecisionsFailureAndConcurrency;
    proveBackwardEquivalence;
    writeln("terminal side-output release proof: ok");
}
