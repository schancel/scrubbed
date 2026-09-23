/// Typed effect ports and the single-document composition root. Adapters own
/// their resources; no port implies persistence, rollback, or scheduling.
module effects.runner;

import content.pieces : Content;
import composition.compiler : CompiledJob;
import composition.job_executor : runCompiledJob;
import composition.runtime_plan : RuntimeExecutionV1, RuntimePlanV1,
    runRuntimePlanV1;
import domain.document : Document, DocumentId, DocumentViewOwner;
import stages.contract : CancellationCheck, EventKind, StageDeclaration,
    StageDocument, StageEvent, StageTransform, runStage;
import std.conv : to;
import std.exception : enforce;

/// A successful Source.next transfers `owner` to the runner. The runner closes
/// it after sink calls; a parser may borrow its view but must not close it.
struct SourceRecord {
    Document document;
    DocumentViewOwner owner;
}

interface Source {
    /// Return false at end of input; own any resource retained on a throw.
    /// Fetch is never called after cancellation is observed.
    bool next(out SourceRecord record);
}

interface Parser {
    /// Return content for this record. Borrowed pieces are valid only while
    /// record.owner stays open; the runner closes it after synchronous writes.
    Content parse(SourceRecord record);
}

interface Sink {
    /// Consume an event synchronously. A sink retaining content must explicitly
    /// copy bytes; Content.stream chunks are temporary and never transferable.
    void accept(StageEvent event);
}

enum EffectPhase { source, parser, stage, sink, release }

/// `completed` counts whole input decisions accepted by the sink. On a sink
/// failure, earlier event writes (including within this decision) may persist.
class EffectFailure : Exception {
    EffectPhase phase;
    size_t completed;
    size_t eventOrdinal;
    DocumentId documentId;
    bool partialWritePossible;
    Exception original;

    this(EffectPhase phase, size_t completed, size_t eventOrdinal,
        DocumentId documentId, bool partialWritePossible, Exception original) {
        super("effect " ~ phase.to!string ~ " failure: " ~ original.msg);
        this.phase = phase;
        this.completed = completed;
        this.eventOrdinal = eventOrdinal;
        this.documentId = documentId;
        this.partialWritePossible = partialWritePossible;
        this.original = original;
    }
}

unittest {
    import content.pieces : ContentPiece;
    import domain.document : OutputName, SourceLocator;
    import stages.contract : PassMode, ResourceDeclaration, StageDecision;
    import std.exception : assertThrown;

    class MemorySource : Source {
        SourceRecord[] records;
        size_t cursor;
        size_t failAt = size_t.max;
        override bool next(out SourceRecord record) {
            if (cursor == failAt) throw new Exception("source fault");
            if (cursor == records.length) return false;
            record = records[cursor++];
            return true;
        }
    }
    class MemoryParser : Parser {
        size_t calls;
        size_t failAt = size_t.max;
        override Content parse(SourceRecord record) {
            if (calls++ == failAt) throw new Exception("parser fault");
            return new Content([ContentPiece.borrow(record.owner.view(0, 1))]);
        }
    }
    class MemorySink : Sink {
        StageEvent[] events;
        ubyte[][] bytes;
        size_t failAt = size_t.max;
        override void accept(StageEvent event) {
            if (events.length == failAt) throw new Exception("sink fault");
            ubyte[] collected;
            event.payload.content.stream((const(ubyte)[] chunk) {
                collected ~= chunk;
            });
            events ~= event;
            bytes ~= collected;
        }
    }
    SourceRecord[] records;
    foreach (i; 0 .. 4) {
        auto document = Document(SourceLocator("memory", "batch", i.to!string),
            OutputName("original"));
        records ~= SourceRecord(document, new DocumentViewOwner([cast(ubyte) ('a' + i)]));
    }
    auto stage = StageDeclaration("decision", PassMode.singlePass,
        ResourceDeclaration(1, 0));
    StageDecision decide(StageDocument input) {
        auto key = input.document.source.recordKey;
        if (key == "0") return StageDecision.map(input);
        if (key == "1") return StageDecision.reject("no");
        if (key == "2") return StageDecision.quarantine("review");
        return StageDecision.split([
            StageDocument(Document(input.document.source, OutputName("first")), input.content),
            StageDocument(Document(input.document.source, OutputName("second")), input.content)
        ]);
    }
    auto source = new MemorySource;
    source.records = records;
    auto parser = new MemoryParser;
    auto sink = new MemorySink;
    auto complete = runEffects(source, parser, sink, stage, &decide);
    assert(complete.completed == 4 && complete.eventsAccepted == 5 && !complete.cancelled);
    assert(sink.events.length == 5);
    assert(sink.events[0].kind == EventKind.emitted &&
        sink.events[0].payload.document.id == records[0].document.id);
    assert(sink.events[1].kind == EventKind.rejected && sink.events[1].reason == "no" &&
        sink.events[1].payload.document.id == records[1].document.id);
    assert(sink.events[2].kind == EventKind.quarantined && sink.events[2].reason == "review" &&
        sink.events[2].payload.document.id == records[2].document.id);
    assert(sink.events[3].isChild && sink.events[3].childOrdinal == 0 &&
        sink.events[4].isChild && sink.events[4].childOrdinal == 1);
    assert(sink.events[3].parentId == records[3].document.id &&
        sink.events[4].parentId == records[3].document.id);
    assert(sink.events[3].payload.document.id != sink.events[4].payload.document.id);
    assert(sink.bytes == [[cast(ubyte) 'a'], [cast(ubyte) 'b'], [cast(ubyte) 'c'],
        [cast(ubyte) 'd'], [cast(ubyte) 'd']]);
    assertThrown(sink.events[0].payload.content.size); // borrowed owner closed

    foreach (phase; [EffectPhase.source, EffectPhase.parser, EffectPhase.sink]) {
        auto badSource = new MemorySource;
        badSource.records = [SourceRecord(records[0].document,
            new DocumentViewOwner([cast(ubyte) 'x']))];
        auto badParser = new MemoryParser;
        auto badSink = new MemorySink;
        if (phase == EffectPhase.source) badSource.failAt = 0;
        if (phase == EffectPhase.parser) badParser.failAt = 0;
        if (phase == EffectPhase.sink) badSink.failAt = 0;
        try {
            runEffects(badSource, badParser, badSink, stage, &decide);
            assert(0, "fault reported as success");
        } catch (EffectFailure fault) {
            assert(fault.phase == phase && fault.completed == 0);
            assert(fault.partialWritePossible == (phase == EffectPhase.sink));
        }
        if (phase != EffectPhase.source)
            assertThrown(badSource.records[0].owner.view(0, 0));
    }
    auto splitSource = new MemorySource;
    splitSource.records = [SourceRecord(records[3].document,
        new DocumentViewOwner([cast(ubyte) 'd']))];
    auto splitSink = new MemorySink;
    splitSink.failAt = 1;
    try {
        runEffects(splitSource, new MemoryParser, splitSink, stage, &decide);
        assert(0, "partial split reported as success");
    } catch (EffectFailure fault) {
        assert(fault.phase == EffectPhase.sink && fault.completed == 0 &&
            fault.eventOrdinal == 1 && fault.partialWritePossible);
        assert(splitSink.events.length == 1);
    }
    assertThrown(splitSource.records[0].owner.view(0, 0));

    auto laterSource = new MemorySource;
    laterSource.records = [
        SourceRecord(records[0].document, new DocumentViewOwner([cast(ubyte) 'a'])),
        SourceRecord(records[1].document, new DocumentViewOwner([cast(ubyte) 'b']))
    ];
    auto laterSink = new MemorySink;
    laterSink.failAt = 1;
    try {
        runEffects(laterSource, new MemoryParser, laterSink, stage, &decide);
        assert(0, "later sink fault reported as success");
    } catch (EffectFailure fault) {
        assert(fault.phase == EffectPhase.sink && fault.completed == 1 &&
            fault.documentId == records[1].document.id && fault.eventOrdinal == 0 &&
            fault.partialWritePossible && laterSink.events.length == 1);
    }
    assertThrown(laterSource.records[0].owner.view(0, 0));
    assertThrown(laterSource.records[1].owner.view(0, 0));
    auto cancelledSource = new MemorySource;
    cancelledSource.records = records;
    auto cancelled = runEffects(cancelledSource, new MemoryParser, new MemorySink,
        stage, &decide, () => true);
    assert(cancelled.cancelled && cancelled.completed == 0 && cancelledSource.cursor == 0);

    auto fetchedSource = new MemorySource;
    fetchedSource.records = [SourceRecord(records[0].document,
        new DocumentViewOwner([cast(ubyte) 'a']))];
    auto fetched = runEffects(fetchedSource, new MemoryParser, new MemorySink,
        stage, &decide, () => fetchedSource.cursor == 1);
    assert(fetched.cancelled && fetched.completed == 0 && fetchedSource.cursor == 1);
    assertThrown(fetchedSource.records[0].owner.view(0, 0));

    auto afterCommitSource = new MemorySource;
    afterCommitSource.records = [
        SourceRecord(records[0].document, new DocumentViewOwner([cast(ubyte) 'a'])),
        SourceRecord(records[1].document, new DocumentViewOwner([cast(ubyte) 'b']))
    ];
    afterCommitSource.failAt = 1; // proves the second lazy fetch is not evaluated
    auto afterCommitSink = new MemorySink;
    auto afterCommit = runEffects(afterCommitSource, new MemoryParser,
        afterCommitSink, stage, &decide,
        () => afterCommitSink.events.length == 1);
    assert(afterCommit.cancelled && afterCommit.completed == 1 &&
        afterCommitSource.cursor == 1);
    assertThrown(afterCommitSource.records[0].owner.view(0, 0));
    assert(afterCommitSource.records[1].owner.view(0, 0).size == 0);

    auto stageSource = new MemorySource;
    stageSource.records = [SourceRecord(records[0].document,
        new DocumentViewOwner([cast(ubyte) 'a']))];
    try {
        runEffects(stageSource, new MemoryParser, new MemorySink, stage,
            (StageDocument input) {
                throw new Exception("stage fault");
                return StageDecision.map(input);
            });
        assert(0, "stage fault reported as success");
    } catch (EffectFailure fault) {
        assert(fault.phase == EffectPhase.stage && fault.completed == 0 &&
            !fault.partialWritePossible);
    }
    assertThrown(stageSource.records[0].owner.view(0, 0));

    SourceRecord releasingRecord() {
        auto bytes = [cast(ubyte) 'a'];
        return SourceRecord(records[0].document,
            new DocumentViewOwner(cast(const(ubyte)[]) bytes,
                () { throw new Exception("release fault"); }));
    }
    auto releasedSource = new MemorySource;
    releasedSource.records = [releasingRecord()];
    auto releasedSink = new MemorySink;
    try {
        runEffects(releasedSource, new MemoryParser, releasedSink, stage, &decide);
        assert(0, "throwing release reported as success");
    } catch (EffectFailure fault) {
        assert(fault.phase == EffectPhase.release && fault.completed == 1 &&
            fault.documentId == records[0].document.id &&
            fault.partialWritePossible && fault.original.msg == "release fault");
        assert(releasedSink.events.length == 1);
    }
    assertThrown(releasedSource.records[0].owner.view(0, 0));

    foreach (phase; [EffectPhase.parser, EffectPhase.sink]) {
        auto failingSource = new MemorySource;
        failingSource.records = [releasingRecord()];
        auto failingParser = new MemoryParser;
        auto failingSink = new MemorySink;
        if (phase == EffectPhase.parser) failingParser.failAt = 0;
        if (phase == EffectPhase.sink) failingSink.failAt = 0;
        try {
            runEffects(failingSource, failingParser, failingSink, stage, &decide);
            assert(0, "primary fault reported as success");
        } catch (EffectFailure fault) {
            assert(fault.phase == phase && fault.completed == 0 &&
                fault.documentId == records[0].document.id &&
                fault.original.msg == (phase == EffectPhase.parser ?
                    "parser fault" : "sink fault"));
            assert(fault.next !is null && fault.next.msg == "release fault");
        }
        assertThrown(failingSource.records[0].owner.view(0, 0));
    }
}

struct RunResult {
    size_t completed;
    size_t eventsAccepted;
    bool cancelled;
}

private void closeRecord(DocumentViewOwner owner, bool primaryFailed,
    size_t completed, DocumentId id, bool sinkTouched) {
    if (primaryFailed) {
        owner.close(); // D chains this behind the primary effect failure.
        return;
    }
    try {
        owner.close();
    } catch (Exception error) {
        throw new EffectFailure(EffectPhase.release, completed, 0,
            id, sinkTouched, error);
    }
}

private alias RecordTransform = StageEvent[] delegate(StageDocument);

/// Run the shared effect lifetime and delivery policy around a record
/// transform. One input decision is fully delivered before fetching another.
/// This is not transactional: a throwing sink can leave an uncertain accepted
/// prefix.
private RunResult runEffectRecords(Source source, Parser parser, Sink sink,
        scope RecordTransform transform,
        scope CancellationCheck isCancelled = null) {
    enforce(source !is null && parser !is null && sink !is null,
        "source, parser and sink are required");
    enforce(transform !is null, "stage transform is required");
    RunResult result;
    while (true) {
        if (isCancelled !is null && isCancelled()) {
            result.cancelled = true;
            return result;
        }
        SourceRecord record;
        bool available;
        try available = source.next(record);
        catch (Exception error)
            throw new EffectFailure(EffectPhase.source, result.completed, 0,
                DocumentId.init, false, error);
        if (!available) return result;
        DocumentId id;
        bool sinkTouched;
        bool primaryFailed;
        scope(exit) if (record.owner !is null)
            closeRecord(record.owner, primaryFailed, result.completed, id, sinkTouched);
        try {
            enforce(record.owner !is null, "source record owner is required");
            id = record.document.id;
        }
        catch (Exception error) {
            primaryFailed = true;
            throw new EffectFailure(EffectPhase.source, result.completed, 0,
                DocumentId.init, false, error);
        }
        if (isCancelled !is null && isCancelled()) {
            result.cancelled = true;
            return result;
        }
        Content content;
        try content = parser.parse(record);
        catch (Exception error) {
            primaryFailed = true;
            throw new EffectFailure(EffectPhase.parser, result.completed, 0,
                id, false, error);
        }
        if (isCancelled !is null && isCancelled()) {
            result.cancelled = true;
            return result;
        }
        StageEvent[] events;
        try events = transform(StageDocument(record.document, content));
        catch (Exception error) {
            primaryFailed = true;
            throw new EffectFailure(EffectPhase.stage, result.completed, 0,
                id, false, error);
        }
        foreach (ordinal, event; events) {
            sinkTouched = true;
            try sink.accept(event);
            catch (Exception error) {
                primaryFailed = true;
                throw new EffectFailure(EffectPhase.sink, result.completed, ordinal,
                    id, true, error);
            }
            ++result.eventsAccepted;
        }
        ++result.completed;
        // Cancellation after commitment is tested at the top of the loop,
        // before source.next can evaluate the next lazy input.
    }
}

/// Execute one declared stage per source record under the effect policy.
RunResult runEffects(Source source, Parser parser, Sink sink,
        StageDeclaration stage, scope StageTransform transform,
        scope CancellationCheck isCancelled = null) {
    enforce(transform !is null, "stage transform is required");
    return runEffectRecords(source, parser, sink,
        (StageDocument input) {
            return runStage([input], stage, transform).events;
        }, isCancelled);
}

/// Execute one already-compiled job per source record. Only the job's ordered
/// final/terminal events cross the synchronous sink boundary.
RunResult runEffects(Source source, Parser parser, Sink sink,
        const ref CompiledJob job,
        scope CancellationCheck isCancelled = null) {
    job.identity; // Reject an uninitialized plan before touching the source.
    return runEffectRecords(source, parser, sink,
        (StageDocument input) => runCompiledJob(input, job), isCancelled);
}

alias RuntimeExecutionObserverV1 = void delegate(
    ref RuntimeExecutionV1 execution);

/// Execute either closed shipping plan through the same lifetime boundary.
RunResult runEffects(Source source, Parser parser, Sink sink,
        ref RuntimePlanV1 plan,
        scope RuntimeExecutionObserverV1 observe = null,
        scope CancellationCheck isCancelled = null) {
    plan.identity; // Reject an uninitialized plan before touching the source.
    return runEffectRecords(source, parser, sink,
        (StageDocument input) {
            auto execution = runRuntimePlanV1(input, plan);
            if (observe !is null) observe(execution);
            return execution.events;
        }, isCancelled);
}

version (unittest) {
    import composition.compiler : compileJob;
    import content.pieces : ContentPiece;
    import domain.document : OutputName;
    import stages.contract : PassMode, ResourceDeclaration, StageDecision;
    import stages.registry : ConfiguredStageTransform, FilterPlacement,
        StageConfiguration, StageOptions, StageRegistration, StageRegistry;

    private enum RunnerTestOperation { map, append, split, route, nested, explode }

    private class RunnerTestConfiguration : StageConfiguration {
        RunnerTestOperation operation;
        string suffix;
        this(RunnerTestOperation operation, string suffix = null) immutable {
            this.operation = operation;
            this.suffix = suffix;
        }
    }

    private size_t runnerFactoryCalls;

    private Content runnerOwned(string text) pure {
        return new Content([ContentPiece.own(cast(const(ubyte)[]) text)]);
    }

    private string runnerText(Content content) pure {
        ubyte[] bytes;
        content.stream((const(ubyte)[] chunk) { bytes ~= chunk; });
        return cast(string) bytes;
    }

    private StageDecision applyRunnerStage(StageDocument input,
            immutable(StageConfiguration) raw) pure {
        auto configured = cast(immutable(RunnerTestConfiguration)) raw;
        enforce(configured !is null, "invalid runner test configuration");
        final switch (configured.operation) {
        case RunnerTestOperation.map:
            return StageDecision.map(input);
        case RunnerTestOperation.append:
            input.content = runnerOwned(runnerText(input.content) ~ configured.suffix);
            return StageDecision.map(input);
        case RunnerTestOperation.split:
            return StageDecision.split([
                StageDocument(Document(input.document.source, OutputName("left")),
                    input.content),
                StageDocument(Document(input.document.source, OutputName("right")),
                    input.content)
            ]);
        case RunnerTestOperation.route:
            return input.document.outputName.text == "left"
                ? StageDecision.reject("left rejected") : StageDecision.map(input);
        case RunnerTestOperation.nested:
            return StageDecision.split([
                StageDocument(Document(input.document.source, OutputName("leaf-a")),
                    input.content),
                StageDocument(Document(input.document.source, OutputName("leaf-b")),
                    input.content)
            ]);
        case RunnerTestOperation.explode:
            throw new Exception("compiled stage fault");
        }
    }

    private ConfiguredStageTransform runnerConfigured(RunnerTestOperation operation,
            string suffix = null) {
        ++runnerFactoryCalls;
        return ConfiguredStageTransform(&applyRunnerStage,
            new immutable RunnerTestConfiguration(operation, suffix));
    }

    private ConfiguredStageTransform runnerMapFactory(const ref StageOptions) {
        return runnerConfigured(RunnerTestOperation.map);
    }
    private ConfiguredStageTransform runnerAppendFactory(const ref StageOptions) {
        return runnerConfigured(RunnerTestOperation.append, "S");
    }
    private ConfiguredStageTransform runnerSplitFactory(const ref StageOptions) {
        return runnerConfigured(RunnerTestOperation.split);
    }
    private ConfiguredStageTransform runnerRouteFactory(const ref StageOptions) {
        return runnerConfigured(RunnerTestOperation.route);
    }
    private ConfiguredStageTransform runnerNestedFactory(const ref StageOptions) {
        return runnerConfigured(RunnerTestOperation.nested);
    }
    private ConfiguredStageTransform runnerExplodeFactory(const ref StageOptions) {
        return runnerConfigured(RunnerTestOperation.explode);
    }

    private StageRegistry runnerStages() {
        StageRegistry registry;
        StageRegistration registration(string key,
                ConfiguredStageTransform function(const ref StageOptions) factory,
                FilterPlacement placement = FilterPlacement.none) {
            return StageRegistration(StageDeclaration(key, PassMode.singlePass,
                ResourceDeclaration(1, 0)), null, null, null, factory, placement);
        }
        registry.add(registration("text-transform", &runnerMapFactory,
            FilterPlacement.before));
        registry.add(registration("append", &runnerAppendFactory));
        registry.add(registration("split", &runnerSplitFactory));
        registry.add(registration("route", &runnerRouteFactory));
        registry.add(registration("nested", &runnerNestedFactory));
        registry.add(registration("explode", &runnerExplodeFactory));
        return registry;
    }

}

unittest {
    import composition.job_executor : CompiledJobFailure;
    import domain.document : OutputName, SourceLocator;
    import job.cli_tokens : parseJobTokens;
    import job.json : parseJobJson;
    import job.legacy : lowerLegacyNames;
    import job.spec : JobSpec;
    import std.exception : assertThrown;

    class CompiledSource : Source {
        SourceRecord[] records;
        size_t cursor;
        size_t failAt = size_t.max;
        override bool next(out SourceRecord record) {
            if (cursor == failAt) throw new Exception("source fault");
            if (cursor == records.length) return false;
            record = records[cursor++];
            return true;
        }
    }
    class CompiledParser : Parser {
        size_t calls;
        size_t failAt = size_t.max;
        override Content parse(SourceRecord record) {
            if (calls++ == failAt) throw new Exception("parser fault");
            return new Content([ContentPiece.borrow(record.owner.view(0, 1))]);
        }
    }
    class CompiledSink : Sink {
        StageEvent[] events;
        ubyte[][] bytes;
        size_t failAt = size_t.max;
        override void accept(StageEvent event) {
            if (events.length == failAt) throw new Exception("sink fault");
            ubyte[] copy;
            event.payload.content.stream((const(ubyte)[] chunk) { copy ~= chunk; });
            events ~= event;
            bytes ~= copy;
        }
    }
    SourceRecord record(string key, char value = 'x',
            void delegate() onClose = null) {
        auto document = Document(SourceLocator("memory", "compiled", key),
            OutputName("out"));
        auto bytes = [cast(ubyte) value];
        auto owner = onClose is null
            ? new DocumentViewOwner(bytes)
            : new DocumentViewOwner(cast(const(ubyte)[]) bytes, onClose);
        return SourceRecord(document, owner);
    }
    CompiledSource sourceWith(SourceRecord[] records) {
        auto source = new CompiledSource;
        source.records = records;
        return source;
    }

    auto stages = runnerStages;

    // The old and new paths agree for one stage, including borrowed lifetime.
    auto oneSpec = parseJobJson(`{"version":3,"stages":[{"id":"one",` ~
        `"implementation":"text-transform","options":{},"filters":[]}]}`);
    auto one = compileJob(oneSpec, &stages);
    auto oldRecord = record("old");
    auto oldSource = sourceWith([oldRecord]);
    auto oldSink = new CompiledSink;
    StageDecision identity(StageDocument input) pure {
        return StageDecision.map(input);
    }
    auto declaration = StageDeclaration("one", PassMode.singlePass,
        ResourceDeclaration(1, 0));
    auto oldResult = runEffects(oldSource, new CompiledParser, oldSink,
        declaration, &identity);
    auto newRecord = record("new");
    auto newSource = sourceWith([newRecord]);
    auto newSink = new CompiledSink;
    auto newResult = runEffects(newSource, new CompiledParser, newSink, one);
    assert(oldResult.completed == newResult.completed &&
        oldResult.eventsAccepted == newResult.eventsAccepted &&
        oldSink.bytes == newSink.bytes &&
        oldSink.events[0].kind == newSink.events[0].kind);
    assertThrown(oldSink.events[0].payload.content.size);
    assertThrown(newSink.events[0].payload.content.size);

    // All accepted input forms compile once and execute through the same bridge.
    auto json = parseJobJson(`{"version":3,"stages":[{"id":"legacy-text",` ~
        `"implementation":"text-transform","options":{},` ~
        `"filters":[{"name":"normalize-line-endings","options":{}}]}]}`);
    auto cli = parseJobTokens(["--stage", "legacy-text=text-transform",
        "--filter", "normalize-line-endings"]);
    auto legacy = lowerLegacyNames(["normalize-line-endings"]);
    foreach (spec; [json, cli, legacy]) {
        auto plan = compileJob(spec, &stages);
        auto input = record("equivalent");
        auto sink = new CompiledSink;
        auto result = runEffects(sourceWith([input]), new CompiledParser, sink, plan);
        assert(result.completed == 1 && result.eventsAccepted == 1 &&
            sink.bytes == [cast(ubyte[]) "x".dup]);
    }

    JobSpec emptySpec;
    auto empty = compileJob(emptySpec, &stages);
    auto emptyRecord = record("empty");
    auto emptySink = new CompiledSink;
    auto emptyResult = runEffects(sourceWith([emptyRecord]), new CompiledParser,
        emptySink, empty);
    assert(emptyResult.completed == 1 && emptyResult.eventsAccepted == 1 &&
        emptySink.bytes == [[cast(ubyte) 'x']]);
    assertThrown(emptySink.events[0].payload.content.size);

    // Split/route/nested split emits only the three ordered terminal events.
    auto fanoutSpec = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"root","implementation":"split","options":{},"filters":[]},` ~
        `{"id":"choose","implementation":"route","options":{},"filters":[]},` ~
        `{"id":"leaves","implementation":"nested","options":{},"filters":[]} ]}`);
    auto fanout = compileJob(fanoutSpec, &stages);
    auto factoriesAfterCompile = runnerFactoryCalls;
    auto roots = [record("a", 'a'), record("b", 'b')];
    auto fanoutSource = sourceWith(roots);
    auto fanoutParser = new CompiledParser;
    auto fanoutSink = new CompiledSink;
    auto fanoutResult = runEffects(fanoutSource, fanoutParser, fanoutSink, fanout);
    assert(fanoutResult.completed == 2 && fanoutResult.eventsAccepted == 6 &&
        fanoutParser.calls == 2 && runnerFactoryCalls == factoriesAfterCompile);
    assert(fanoutSink.events.length == 6);
    foreach (i; 0 .. 3)
        assert(fanoutSink.events[i].payload.document.source.recordKey == "a");
    foreach (i; 3 .. 6)
        assert(fanoutSink.events[i].payload.document.source.recordKey == "b");
    assert(fanoutSink.events[0].kind == EventKind.rejected &&
        fanoutSink.events[1].payload.document.outputName.text == "leaf-a" &&
        fanoutSink.events[2].payload.document.outputName.text == "leaf-b");

    // A whole-text filter produces owned output that remains available as copied bytes.
    auto filteredRecord = record("filtered", '\r');
    auto filteredSink = new CompiledSink;
    auto filteredSpec = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"filter","implementation":"text-transform","options":{},` ~
        `"filters":[{"name":"normalize-line-endings","options":{}}]},` ~
        `{"id":"append","implementation":"append","options":{},"filters":[]} ]}`);
    auto filtered = compileJob(filteredSpec, &stages);
    runEffects(sourceWith([filteredRecord]), new CompiledParser, filteredSink, filtered);
    assert(filteredSink.bytes == [cast(ubyte[]) "\nS".dup]);
    assert(runnerText(filteredSink.events[0].payload.content) == "\nS");

    // Compiled-stage identity remains nested as the original effect failure.
    auto brokenSpec = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"first","implementation":"append","options":{},"filters":[]},` ~
        `{"id":"broken","implementation":"explode","options":{},"filters":[]} ]}`);
    auto broken = compileJob(brokenSpec, &stages);
    auto brokenRecord = record("broken");
    try {
        runEffects(sourceWith([brokenRecord]), new CompiledParser,
            new CompiledSink, broken);
        assert(0, "compiled fault returned success");
    } catch (EffectFailure fault) {
        auto original = cast(CompiledJobFailure) fault.original;
        assert(fault.phase == EffectPhase.stage && fault.completed == 0 &&
            fault.documentId == brokenRecord.document.id &&
            !fault.partialWritePossible && original !is null &&
            original.jobIdentity == broken.identity &&
            original.stageId == "broken" && original.stageOrdinal == 1);
    }
    assertThrown(brokenRecord.owner.view(0, 0));

    // A sink fault preserves only the accepted prefix and never fetches root two.
    auto partialRecords = [record("partial-a"), record("partial-b")];
    auto partialSource = sourceWith(partialRecords);
    auto partialSink = new CompiledSink;
    partialSink.failAt = 1;
    try {
        runEffects(partialSource, new CompiledParser, partialSink, fanout);
        assert(0, "partial fanout returned success");
    } catch (EffectFailure fault) {
        assert(fault.phase == EffectPhase.sink && fault.completed == 0 &&
            fault.eventOrdinal == 1 && fault.partialWritePossible &&
            partialSink.events.length == 1 && partialSource.cursor == 1);
    }
    assertThrown(partialRecords[0].owner.view(0, 0));
    partialRecords[1].owner.view(0, 0);

    // Parser/job/sink primaries retain priority when owner release also fails.
    foreach (phase; [EffectPhase.parser, EffectPhase.stage, EffectPhase.sink]) {
        auto releasing = record("release-chain", 'x',
            () { throw new Exception("release fault"); });
        auto parser = new CompiledParser;
        auto sink = new CompiledSink;
        auto plan = one;
        if (phase == EffectPhase.parser) parser.failAt = 0;
        if (phase == EffectPhase.stage) plan = broken;
        if (phase == EffectPhase.sink) sink.failAt = 0;
        try {
            runEffects(sourceWith([releasing]), parser, sink, plan);
            assert(0, "primary plus release fault returned success");
        } catch (EffectFailure fault) {
            assert(fault.phase == phase && fault.completed == 0 &&
                fault.documentId == releasing.document.id &&
                fault.partialWritePossible == (phase == EffectPhase.sink) &&
                fault.next !is null && fault.next.msg == "release fault");
            if (phase == EffectPhase.parser)
                assert(fault.original.msg == "parser fault");
            if (phase == EffectPhase.stage)
                assert(cast(CompiledJobFailure) fault.original !is null);
            if (phase == EffectPhase.sink)
                assert(fault.original.msg == "sink fault");
        }
    }
    auto releaseOnly = record("release", 'x',
        () { throw new Exception("release fault"); });
    try {
        runEffects(sourceWith([releaseOnly]), new CompiledParser,
            new CompiledSink, one);
        assert(0, "release fault returned success");
    } catch (EffectFailure fault) {
        assert(fault.phase == EffectPhase.release && fault.completed == 1 &&
            fault.partialWritePossible && fault.documentId == releaseOnly.document.id);
    }

    // Cancellation is observed only at safe root boundaries.
    auto before = sourceWith([record("before")]);
    auto beforeResult = runEffects(before, new CompiledParser,
        new CompiledSink, one, () => true);
    assert(beforeResult.cancelled && before.cursor == 0);

    auto afterFetchRecord = record("after-fetch");
    auto afterFetch = sourceWith([afterFetchRecord]);
    auto afterFetchResult = runEffects(afterFetch, new CompiledParser,
        new CompiledSink, one, () => afterFetch.cursor == 1);
    assert(afterFetchResult.cancelled && afterFetch.cursor == 1);
    assertThrown(afterFetchRecord.owner.view(0, 0));

    auto afterParseRecord = record("after-parse");
    auto afterParse = sourceWith([afterParseRecord]);
    auto cancelParser = new CompiledParser;
    auto afterParseResult = runEffects(afterParse, cancelParser,
        new CompiledSink, one, () => cancelParser.calls == 1);
    assert(afterParseResult.cancelled && afterParse.cursor == 1 &&
        cancelParser.calls == 1);
    assertThrown(afterParseRecord.owner.view(0, 0));

    auto committedRecords = [record("commit-a"), record("commit-b")];
    auto committedSource = sourceWith(committedRecords);
    committedSource.failAt = 1;
    auto committedSink = new CompiledSink;
    auto committed = runEffects(committedSource, new CompiledParser,
        committedSink, fanout, () => committedSink.events.length != 0);
    assert(committed.cancelled && committed.completed == 1 &&
        committed.eventsAccepted == 3 && committedSource.cursor == 1);
    assertThrown(committedRecords[0].owner.view(0, 0));
    committedRecords[1].owner.view(0, 0);

    // Source attribution remains unchanged on the compiled path.
    auto badSource = new CompiledSource;
    badSource.failAt = 0;
    try {
        runEffects(badSource, new CompiledParser, new CompiledSink, one);
        assert(0, "source fault returned success");
    } catch (EffectFailure fault) {
        assert(fault.phase == EffectPhase.source && fault.completed == 0 &&
            fault.documentId == DocumentId.init && !fault.partialWritePossible);
    }
}
