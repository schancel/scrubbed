/// Pure execution of one compiled linear job over one checked document.
module composition.job_executor;

import composition.compiler : CompiledJob;
import composition.executor : runCompiledStage;
import stages.contract : EventKind, StageDocument, StageEvent;
import std.exception : enforce;

/// Identifies the compiled stage whose execution failed without exposing a
/// partially accumulated job result.
final class CompiledJobFailure : Exception {
    string jobIdentity;
    string stageId;
    size_t stageOrdinal;
    Exception original;

    this(string jobIdentity, string stageId, size_t stageOrdinal,
            Exception original) {
        super("compiled job " ~ jobIdentity ~ " stage " ~ stageId ~
            " failed: " ~ original.msg);
        this.jobIdentity = jobIdentity.idup;
        this.stageId = stageId.idup;
        this.stageOrdinal = stageOrdinal;
        this.original = original;
    }
}

private void validateNoOpInput(StageDocument input) {
    input.document.id;
    enforce(input.document.outputName.text.length != 0,
        "document output name is not initialized");
    enforce(input.content !is null, "stage input content is required");
    input.content.size;
}

/// A map/reject/quarantine after a split retains the child's immediate
/// parent provenance. A later split already supplies its own newer lineage.
private void retainLineage(ref StageEvent output, const ref StageEvent input) {
    if (!output.isChild && input.isChild) {
        output.parentId = input.parentId;
        output.childOrdinal = input.childOrdinal;
        output.isChild = true;
    }
}

/// Execute every compiled stage for one source record. Rejected and
/// quarantined events are terminal; emitted split children continue in their
/// existing order. Only terminal/final events are returned.
StageEvent[] runCompiledJob(StageDocument input, const ref CompiledJob job) {
    if (job.stages.length == 0) validateNoOpInput(input);
    StageEvent[] events = [StageEvent(EventKind.emitted, input)];
    foreach (stageOrdinal, ref stage; job.stages) {
        StageEvent[] next;
        foreach (event; events) {
            if (event.kind != EventKind.emitted) {
                next ~= event;
                continue;
            }
            try {
                auto result = runCompiledStage([event.payload], stage);
                enforce(!result.cancelled && result.processed == 1,
                    "compiled stage did not complete its input");
                foreach (output; result.events) {
                    if (output.kind == EventKind.emitted && !output.isChild)
                        enforce(output.payload.document.outputName.text ==
                            event.payload.document.outputName.text,
                            "map must preserve document output name");
                    retainLineage(output, event);
                    next ~= output;
                }
            } catch (Exception error) {
                throw new CompiledJobFailure(job.identity, stage.id,
                    stageOrdinal, error);
            }
        }
        events = next;
    }
    return events;
}

version (unittest) {
    import composition.compiler : compileJob;
    import content.pieces : Content, ContentPiece;
    import domain.document : Document, DocumentViewOwner, OutputName,
        SourceLocator;
    import job.cli_tokens : parseJobTokens;
    import job.json : parseJobJson;
    import job.legacy : lowerLegacyNames;
    import pipeline : Filter, FilterRegistry;
    import stages.contract : PassMode, ResourceDeclaration, StageDecision,
        StageDeclaration;
    import stages.registry : ConfiguredStageTransform, FilterPlacement,
        OptionDeclaration, OptionType, StageConfiguration, StageFactory,
        StageOptions, StageRegistration, StageRegistry;
    import std.exception : assertThrown;

    private Content ownedText(string text) pure {
        return new Content([ContentPiece.own(cast(const(ubyte)[]) text)]);
    }

    private string materializedText(Content content) pure {
        ubyte[] bytes;
        content.stream((const(ubyte)[] chunk) { bytes ~= chunk; });
        return cast(string) bytes;
    }

    private StageDocument testDocument(string text, string record = "root") {
        return StageDocument(Document(SourceLocator("test", "job", record),
            OutputName("out")), ownedText(text));
    }

    private StageRegistration registration(string key,
            StageFactory factory,
            FilterPlacement placement = FilterPlacement.none,
            OptionDeclaration[] options = null) {
        return StageRegistration(StageDeclaration(key, PassMode.singlePass,
            ResourceDeclaration(1, 0)), options, null, null, factory, placement);
    }

    private enum TestOperation {
        append, map, split, route, nestedSplit, reject, quarantine,
        invalidUtf8, rename, explode,
    }

    private class TestStageConfiguration : StageConfiguration {
        TestOperation operation;
        string suffix;

        this(TestOperation operation, string suffix = null) immutable {
            this.operation = operation;
            this.suffix = suffix;
        }
    }

    private StageDecision applyTestStage(StageDocument input,
            immutable(StageConfiguration) raw) pure {
        auto configured = cast(immutable(TestStageConfiguration)) raw;
        enforce(configured !is null, "invalid test stage configuration");
        final switch (configured.operation) {
        case TestOperation.append:
            input.content = ownedText(materializedText(input.content) ~
                configured.suffix);
            return StageDecision.map(input);
        case TestOperation.map:
            return StageDecision.map(input);
        case TestOperation.split:
            return StageDecision.split([
            StageDocument(Document(input.document.source, OutputName("left")),
                input.content),
            StageDocument(Document(input.document.source, OutputName("right")),
                input.content)
        ]);
        case TestOperation.route:
            return input.document.outputName.text == "left"
                ? StageDecision.reject("left rejected") : StageDecision.map(input);
        case TestOperation.nestedSplit:
            return StageDecision.split([
            StageDocument(Document(input.document.source, OutputName("leaf-a")),
                input.content),
            StageDocument(Document(input.document.source, OutputName("leaf-b")),
                input.content)
        ]);
        case TestOperation.reject:
            return StageDecision.reject("stop");
        case TestOperation.quarantine:
            return StageDecision.quarantine("review");
        case TestOperation.invalidUtf8:
            input.content = new Content([ContentPiece.own([cast(ubyte) 0xff])]);
            return StageDecision.map(input);
        case TestOperation.rename:
            input.document.outputName = OutputName("renamed");
            return StageDecision.map(input);
        case TestOperation.explode:
            throw new Exception("exploded");
        }
    }

    private ConfiguredStageTransform configured(TestOperation operation,
            string suffix = null) {
        return ConfiguredStageTransform(&applyTestStage,
            new immutable TestStageConfiguration(operation, suffix));
    }

    private ConfiguredStageTransform appendFactory(const ref StageOptions options) {
        return configured(TestOperation.append, options["suffix"].asText.idup);
    }

    private ConfiguredStageTransform mapFactory(const ref StageOptions options) {
        return configured(TestOperation.map);
    }

    private ConfiguredStageTransform splitFactory(const ref StageOptions options) {
        return configured(TestOperation.split);
    }

    private ConfiguredStageTransform routeFactory(const ref StageOptions options) {
        return configured(TestOperation.route);
    }

    private ConfiguredStageTransform nestedSplitFactory(
            const ref StageOptions options) {
        return configured(TestOperation.nestedSplit);
    }

    private ConfiguredStageTransform rejectFactory(const ref StageOptions options) {
        return configured(TestOperation.reject);
    }

    private ConfiguredStageTransform quarantineFactory(
            const ref StageOptions options) {
        return configured(TestOperation.quarantine);
    }

    private ConfiguredStageTransform invalidUtf8Factory(
            const ref StageOptions options) {
        return configured(TestOperation.invalidUtf8);
    }

    private ConfiguredStageTransform renameFactory(const ref StageOptions options) {
        return configured(TestOperation.rename);
    }

    private ConfiguredStageTransform explodeFactory(const ref StageOptions options) {
        return configured(TestOperation.explode);
    }

    private StageRegistry testStages() {
        StageRegistry stages;
        auto suffix = [OptionDeclaration("suffix", OptionType.text, true)];
        stages.add(registration("append-before", &appendFactory,
            FilterPlacement.before, suffix));
        stages.add(registration("append-after", &appendFactory,
            FilterPlacement.after, suffix));
        stages.add(registration("text-transform", &mapFactory,
            FilterPlacement.before));
        stages.add(registration("split", &splitFactory));
        stages.add(registration("route", &routeFactory));
        stages.add(registration("nested-split", &nestedSplitFactory));
        stages.add(registration("map", &mapFactory));
        stages.add(registration("reject", &rejectFactory));
        stages.add(registration("quarantine", &quarantineFactory));
        stages.add(registration("invalid-utf8", &invalidUtf8Factory));
        stages.add(registration("rename", &renameFactory));
        stages.add(registration("explode", &explodeFactory));
        return stages;
    }

    private FilterRegistry testFilters() {
        FilterRegistry filters;
        filters.addFilter("bang", cast(Filter) ((string text) => text ~ "!"));
        return filters;
    }
}

unittest {
    auto stages = testStages;
    auto filters = testFilters;
    auto spec = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"first","implementation":"append-before",` ~
        `"options":{"suffix":"A"},"filters":[{"name":"bang","options":{}}]},` ~
        `{"id":"second","implementation":"append-before",` ~
        `"options":{"suffix":"B"},"filters":[]},` ~
        `{"id":"third","implementation":"append-after",` ~
        `"options":{"suffix":"C"},"filters":[{"name":"bang","options":{}}]}]}`);
    auto plan = compileJob(spec, &stages, &filters);
    auto result = runCompiledJob(testDocument("x"), plan);
    assert(result.length == 1 && result[0].kind == EventKind.emitted);
    assert(materializedText(result[0].payload.content) == "x!ABC!");

    auto repeated = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"one","implementation":"append-before",` ~
        `"options":{"suffix":"1"},"filters":[]},` ~
        `{"id":"two","implementation":"append-before",` ~
        `"options":{"suffix":"2"},"filters":[]}]}`);
    auto repeatedPlan = compileJob(repeated, &stages, &filters);
    assert(repeatedPlan.stages[0].id == "one" &&
        repeatedPlan.stages[1].id == "two");
    assert(materializedText(runCompiledJob(testDocument("x"),
        repeatedPlan)[0].payload.content) == "x12");
}

unittest {
    auto stages = testStages;
    auto filters = testFilters;
    auto root = testDocument("x", "lineage");
    auto rootId = root.document.id;
    auto spec = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"root-split","implementation":"split","options":{},"filters":[]},` ~
        `{"id":"choose","implementation":"route","options":{},"filters":[]},` ~
        `{"id":"child-split","implementation":"nested-split","options":{},"filters":[]},` ~
        `{"id":"finish","implementation":"map","options":{},"filters":[]}]}`);
    auto plan = compileJob(spec, &stages, &filters);
    auto events = runCompiledJob(root, plan);
    assert(events.length == 3);
    assert(events[0].kind == EventKind.rejected &&
        events[0].reason == "left rejected" && events[0].isChild &&
        events[0].parentId == rootId && events[0].childOrdinal == 0);
    auto right = Document.derivedChild(root.document, "root-split", 1,
        OutputName("right"));
    foreach (i; 0 .. 2) {
        auto event = events[i + 1];
        assert(event.kind == EventKind.emitted && event.isChild &&
            event.parentId == right.id && event.childOrdinal == i);
        auto expectedName = i == 0 ? "leaf-a" : "leaf-b";
        assert(event.payload.document.outputName.text == expectedName);
        assert(event.payload.document.id == Document.derivedChild(right,
            "child-split", i, OutputName(expectedName)).id);
    }

    auto stopped = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"stop","implementation":"reject","options":{},"filters":[]},` ~
        `{"id":"must-not-run","implementation":"explode","options":{},"filters":[]}]}`);
    auto stoppedPlan = compileJob(stopped, &stages, &filters);
    auto stoppedEvents = runCompiledJob(testDocument("x"), stoppedPlan);
    assert(stoppedEvents.length == 1 && stoppedEvents[0].kind == EventKind.rejected);

    auto quarantined = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"review","implementation":"quarantine","options":{},"filters":[]},` ~
        `{"id":"must-not-run","implementation":"explode","options":{},"filters":[]}]}`);
    auto quarantinedPlan = compileJob(quarantined, &stages, &filters);
    auto quarantinedEvents = runCompiledJob(testDocument("x"), quarantinedPlan);
    assert(quarantinedEvents.length == 1 &&
        quarantinedEvents[0].kind == EventKind.quarantined &&
        quarantinedEvents[0].reason == "review");
}

unittest {
    auto stages = testStages;
    auto filters = testFilters;
    import job.spec : JobSpec;

    JobSpec emptySpec;
    auto emptyPlan = compileJob(emptySpec, &stages, &filters);
    auto emptyInput = testDocument("unchanged", "empty-plan");
    auto emptyResult = runCompiledJob(emptyInput, emptyPlan);
    assert(emptyResult.length == 1 && emptyResult[0].kind == EventKind.emitted &&
        emptyResult[0].payload.document.id == emptyInput.document.id &&
        emptyResult[0].payload.content is emptyInput.content);

    auto owner = new DocumentViewOwner(cast(ubyte[]) "borrowed".dup);
    auto borrowed = new Content([ContentPiece.borrow(owner.view(0, 8))]);
    auto document = Document(SourceLocator("test", "job", "borrowed"),
        OutputName("out"));
    auto maps = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"one","implementation":"map","options":{},"filters":[]},` ~
        `{"id":"two","implementation":"map","options":{},"filters":[]}]}`);
    auto mapsPlan = compileJob(maps, &stages, &filters);
    auto borrowedResult = runCompiledJob(StageDocument(document, borrowed), mapsPlan);
    assert(borrowedResult[0].payload.content is borrowed);
    owner.close();
    assertThrown(borrowedResult[0].payload.content.size);

    auto filteredOwner = new DocumentViewOwner(cast(ubyte[]) "owned".dup);
    auto filteredBorrow = new Content([ContentPiece.borrow(filteredOwner.view(0, 5))]);
    auto filtered = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"text","implementation":"text-transform","options":{},` ~
        `"filters":[{"name":"bang","options":{}}]}]}`);
    auto filteredPlan = compileJob(filtered, &stages, &filters);
    auto filteredResult = runCompiledJob(StageDocument(document, filteredBorrow),
        filteredPlan);
    filteredOwner.close();
    assert(materializedText(filteredResult[0].payload.content) == "owned!");
}

unittest {
    auto stages = testStages;
    auto filters = testFilters;
    auto json = parseJobJson(`{"version":3,"stages":[{"id":"legacy-text",` ~
        `"implementation":"text-transform","options":{},` ~
        `"filters":[{"name":"bang","options":{}}]}]}`);
    auto cli = parseJobTokens(["--stage", "legacy-text=text-transform",
        "--filter", "bang"]);
    auto legacy = lowerLegacyNames(["bang"]);
    foreach (spec; [json, cli, legacy]) {
        auto plan = compileJob(spec, &stages, &filters);
        auto events = runCompiledJob(testDocument("same"), plan);
        assert(events.length == 1 &&
            materializedText(events[0].payload.content) == "same!");
    }

    auto failed = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"first","implementation":"map","options":{},"filters":[]},` ~
        `{"id":"broken","implementation":"explode","options":{},"filters":[]}]}`);
    auto failedPlan = compileJob(failed, &stages, &filters);
    try {
        runCompiledJob(testDocument("x"), failedPlan);
        assert(0, "failing stage returned a partial result");
    } catch (CompiledJobFailure error) {
        assert(error.jobIdentity == failedPlan.identity &&
            error.stageId == "broken" && error.stageOrdinal == 1 &&
            error.original.msg == "exploded");
    }

    auto invalid = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"make-invalid","implementation":"invalid-utf8",` ~
        `"options":{},"filters":[]},` ~
        `{"id":"validate-utf8","implementation":"text-transform",` ~
        `"options":{},"filters":[{"name":"bang","options":{}}]}]}`);
    auto invalidPlan = compileJob(invalid, &stages, &filters);
    try {
        runCompiledJob(testDocument("x"), invalidPlan);
        assert(0, "invalid second-stage UTF-8 returned a partial result");
    } catch (CompiledJobFailure error) {
        assert(error.stageId == "validate-utf8" && error.stageOrdinal == 1);
    }

    auto renamed = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"bad-rename","implementation":"rename",` ~
        `"options":{},"filters":[]}]}`);
    auto renamedPlan = compileJob(renamed, &stages, &filters);
    try {
        runCompiledJob(testDocument("x"), renamedPlan);
        assert(0, "map changed the output name");
    } catch (CompiledJobFailure error) {
        assert(error.stageId == "bad-rename" &&
            error.original.msg == "map must preserve document output name");
    }
}

unittest {
    import core.thread : Thread;

    auto stages = testStages;
    auto filters = testFilters;
    auto spec = parseJobJson(`{"version":3,"stages":[{"id":"text",` ~
        `"implementation":"text-transform","options":{},` ~
        `"filters":[{"name":"bang","options":{}}]}]}`);
    auto plan = compileJob(spec, &stages, &filters);
    string[2] outputs;
    auto first = new Thread({
        outputs[0] = materializedText(runCompiledJob(
            testDocument("a", "thread-a"), plan)[0].payload.content);
    });
    auto second = new Thread({
        outputs[1] = materializedText(runCompiledJob(
            testDocument("b", "thread-b"), plan)[0].payload.content);
    });
    first.start;
    second.start;
    first.join;
    second.join;
    assert(outputs == ["a!", "b!"]);
    assert(materializedText(runCompiledJob(testDocument("c", "repeat"),
        plan)[0].payload.content) == "c!");
}
