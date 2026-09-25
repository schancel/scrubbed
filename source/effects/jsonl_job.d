/// One selected JSONL field through the canonical compiled-job effects bridge.
module effects.jsonl_job;

import composition.compiler : CompiledJob;
import composition.runtime_plan : RuntimeExecutionV1, RuntimePlanV1;
import content.pieces : Content, ContentPiece;
import domain.document : Document, OutputName, SourceLocator, DocumentViewOwner;
import effects.jsonl_stream : JsonlDecisionFailure, JsonlDecisionKind;
import effects.runner : Parser, Sink, Source, SourceRecord, runEffects;
import stages.contract : EventKind, StageEvent, TerminalSideOutput;

/// One independently owned selected-field result. Side outputs remain ordered
/// with the field and can be staged until the enclosing JSON record commits.
struct JsonlFieldOutcome {
    string text;
    TerminalSideOutput[] sideOutputs;
}

private final class FieldSource : Source {
    private SourceLocator locator;
    private string field;
    private ubyte[] bytes;
    private bool yielded;

    this(SourceLocator locator, string field, string text) {
        this.locator = locator;
        this.field = field.idup;
        bytes = cast(ubyte[]) text.dup;
    }

    override bool next(out SourceRecord record) {
        if (yielded) return false;
        yielded = true;
        record = SourceRecord(Document(locator, OutputName(field)),
            new DocumentViewOwner(bytes));
        return true;
    }
}

private final class FieldParser : Parser {
    private size_t length;

    this(size_t length) { this.length = length; }

    override Content parse(SourceRecord record) {
        return new Content([ContentPiece.borrow(record.owner.view(0, length))]);
    }
}

private final class FieldSink : Sink {
    size_t events;
    EventKind kind;
    bool child;
    string reason;
    string mapped;
    TerminalSideOutput[] sideOutputs;

    override void accept(StageEvent event) {
        ++events;
        if (events != 1) return;
        kind = event.kind;
        child = event.isChild;
        reason = event.reason.idup;
        sideOutputs = event.sideOutputs.dup;
        if (event.kind == EventKind.emitted && !event.isChild) {
            // The returned field must outlive the runner's input owner. Copy
            // once into its exact final size instead of growing a stream sink.
            mapped = cast(string) event.payload.content.copy;
        }
    }
}

private JsonlFieldOutcome checkedOutcome(FieldSink sink, string identity) {
    if (sink.events != 1 || sink.child)
        throw new JsonlDecisionFailure(JsonlDecisionKind.unsupportedFanout,
            "compiled JSONL job " ~ identity ~ " produced unsupported fanout");
    final switch (sink.kind) {
    case EventKind.emitted:
        return JsonlFieldOutcome(sink.mapped, sink.sideOutputs);
    case EventKind.rejected:
        throw new JsonlDecisionFailure(JsonlDecisionKind.rejected,
            "compiled JSONL job " ~ identity ~
            " rejected selected field: " ~ sink.reason);
    case EventKind.quarantined:
        throw new JsonlDecisionFailure(JsonlDecisionKind.quarantined,
            "compiled JSONL job " ~ identity ~
            " quarantined selected field: " ~ sink.reason);
    }
}

/// Execute exactly one selected field. Returned text owns its bytes after the
/// effects runner invalidates the input view owner.
string runJsonlField(SourceLocator locator, string field, string text,
        const ref CompiledJob job) {
    return runJsonlFieldOutcome(locator, field, text, job).text;
}

JsonlFieldOutcome runJsonlFieldOutcome(SourceLocator locator, string field,
        string text, const ref CompiledJob job) {
    auto source = new FieldSource(locator, field, text);
    auto sink = new FieldSink;
    runEffects(source, new FieldParser(text.length), sink, job);
    return checkedOutcome(sink, job.identity);
}

alias JsonlDispatchObserverV1 = void delegate(
    ref RuntimeExecutionV1 execution);

string runJsonlField(SourceLocator locator, string field, string text,
        ref RuntimePlanV1 plan, scope JsonlDispatchObserverV1 observe = null) {
    return runJsonlFieldOutcome(locator, field, text, plan, observe).text;
}

JsonlFieldOutcome runJsonlFieldOutcome(SourceLocator locator, string field,
        string text, ref RuntimePlanV1 plan,
        scope JsonlDispatchObserverV1 observe = null) {
    auto source = new FieldSource(locator, field, text);
    auto sink = new FieldSink;
    runEffects(source, new FieldParser(text.length), sink, plan, observe);
    return checkedOutcome(sink, plan.identity);
}

version (unittest) {
    import composition.compiler : compileJob;
    import composition.job_executor : CompiledJobFailure;
    import effects.runner : EffectFailure, EffectPhase;
    import job.spec : JobSpec, JobStageSpec;
    import stages.contract : PassMode, ResourceDeclaration, StageDecision,
        StageDeclaration, StageDocument;
    import stages.registry : ConfiguredStageTransform, FilterPlacement,
        StageConfiguration, StageOptions, StageRegistration, StageRegistry;
    import std.exception : assertThrown;
    import std.algorithm.searching : canFind;

    private enum FixtureAction { map, reject, quarantine, split, explode }

    private class FixtureConfiguration : StageConfiguration {
        FixtureAction action;
        this(FixtureAction action) immutable { this.action = action; }
    }

    private size_t fixtureFactories;

    private string contentText(Content content) pure {
        ubyte[] bytes;
        content.stream((const(ubyte)[] chunk) { bytes ~= chunk; });
        return cast(string) bytes;
    }

    private StageDecision applyFixture(StageDocument input,
            immutable(StageConfiguration) raw) pure {
        auto configured = cast(immutable(FixtureConfiguration)) raw;
        final switch (configured.action) {
        case FixtureAction.map:
            input.content = new Content([ContentPiece.own(
                cast(const(ubyte)[]) (contentText(input.content) ~ "!"))]);
            return StageDecision.map(input);
        case FixtureAction.reject:
            return StageDecision.reject("policy stop");
        case FixtureAction.quarantine:
            return StageDecision.quarantine("manual review");
        case FixtureAction.split:
            return StageDecision.split([
                StageDocument(Document(input.document.source, OutputName("left")),
                    input.content),
                StageDocument(Document(input.document.source, OutputName("right")),
                    input.content),
            ]);
        case FixtureAction.explode:
            throw new Exception("fixture exploded");
        }
    }

    private ConfiguredStageTransform fixture(FixtureAction action) {
        ++fixtureFactories;
        return ConfiguredStageTransform(&applyFixture,
            new immutable FixtureConfiguration(action));
    }

    private ConfiguredStageTransform mapFactory(const ref StageOptions) {
        return fixture(FixtureAction.map);
    }
    private ConfiguredStageTransform rejectFactory(const ref StageOptions) {
        return fixture(FixtureAction.reject);
    }
    private ConfiguredStageTransform quarantineFactory(const ref StageOptions) {
        return fixture(FixtureAction.quarantine);
    }
    private ConfiguredStageTransform splitFactory(const ref StageOptions) {
        return fixture(FixtureAction.split);
    }
    private ConfiguredStageTransform explodeFactory(const ref StageOptions) {
        return fixture(FixtureAction.explode);
    }

    private StageRegistry fixtureRegistry() {
        StageRegistry registry;
        foreach (entry; [
            StageRegistration(StageDeclaration("map", PassMode.singlePass,
                ResourceDeclaration(1, 0)), null, null, null, &mapFactory,
                FilterPlacement.none),
            StageRegistration(StageDeclaration("reject", PassMode.singlePass,
                ResourceDeclaration(1, 0)), null, null, null, &rejectFactory,
                FilterPlacement.none),
            StageRegistration(StageDeclaration("quarantine", PassMode.singlePass,
                ResourceDeclaration(1, 0)), null, null, null, &quarantineFactory,
                FilterPlacement.none),
            StageRegistration(StageDeclaration("split", PassMode.singlePass,
                ResourceDeclaration(1, 0)), null, null, null, &splitFactory,
                FilterPlacement.none),
            StageRegistration(StageDeclaration("explode", PassMode.singlePass,
                ResourceDeclaration(1, 0)), null, null, null, &explodeFactory,
                FilterPlacement.none),
        ]) registry.add(entry);
        return registry;
    }

    private CompiledJob plan(string implementation,
            ref StageRegistry registry) {
        auto spec = JobSpec([JobStageSpec("selected", implementation)]);
        return compileJob(spec, &registry);
    }
}

unittest {
    auto locator = SourceLocator("batch", "source", "7");
    auto registry = fixtureRegistry();
    fixtureFactories = 0;
    auto mapped = plan("map", registry);
    assert(fixtureFactories == 1);
    auto first = runJsonlField(locator, "text", "one", mapped);
    auto second = runJsonlField(locator, "title", "two", mapped);
    assert(first == "one!" && second == "two!" && fixtureFactories == 1);

    foreach (implementation, expectedKind; [
        "reject": JsonlDecisionKind.rejected,
        "quarantine": JsonlDecisionKind.quarantined,
        "split": JsonlDecisionKind.unsupportedFanout,
    ]) {
        auto decisionPlan = plan(implementation, registry);
        try {
            auto ignored = runJsonlField(locator, "text", "value",
                decisionPlan);
            assert(0, ignored);
        } catch (JsonlDecisionFailure error) {
            assert(error.kind == expectedKind && error.msg.canFind("job:v3:"));
        }
    }

    auto exploding = plan("explode", registry);
    try {
        auto ignored = runJsonlField(locator, "text", "value",
            exploding);
        assert(0, ignored);
    } catch (EffectFailure error) {
        auto compiled = cast(CompiledJobFailure) error.original;
        assert(error.phase == EffectPhase.stage && compiled !is null &&
            compiled.stageId == "selected" && compiled.jobIdentity.length != 0);
    }

    auto source = new FieldSource(locator, "text", "borrowed");
    SourceRecord record;
    assert(source.next(record));
    assert(record.document.id == Document(locator, OutputName("other")).id &&
        record.document.outputName.text == "text");
    auto borrowed = (new FieldParser(8)).parse(record);
    assert(contentText(borrowed) == "borrowed");
    record.owner.close();
    assertThrown(borrowed.size);
    assert(first == "one!");
}
