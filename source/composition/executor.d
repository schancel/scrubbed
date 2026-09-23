/// Checked execution of one compiled stage with declared filter placement.
module composition.executor;

import composition.compiler : CompiledStage, compileJob;
import content.pieces : Content, ContentPiece;
import stages.contract : EventKind, ResourceDeclaration, StageDeclaration,
    StageDocument, StageResult, StageTransform, runStage;
import stages.registry : FilterPlacement;
import std.exception : enforce;
import std.utf : validate;

private string materializeUtf8(Content input) pure {
    enforce(input !is null, "stage content is required");
    ubyte[] bytes;
    input.stream((const(ubyte)[] chunk) { bytes ~= chunk; });
    auto text = cast(string) bytes;
    validate(text);
    return text;
}

private Content ownedText(string text) pure {
    validate(text);
    return new Content([ContentPiece.own(cast(const(ubyte)[]) text)]);
}

private Content applyFilters(Content input, const ref CompiledStage stage) {
    enforce(input !is null, "stage content is required");
    if (stage.filterNames.length == 0) return input;
    auto text = materializeUtf8(input);
    auto filtered = stage.runFilters(text);
    return ownedText(filtered);
}

private StageDeclaration instanceDeclaration(const ref CompiledStage stage) {
    auto registered = stage.declaration;
    return StageDeclaration(stage.id, registered.passMode,
        ResourceDeclaration(registered.resources.cpuSlots,
            registered.resources.memoryBytes,
            registered.resources.exclusiveNames.dup));
}

/// Execute one resolved stage over an ordered batch. A nonempty filter chain
/// is an explicit whole-text barrier; an empty chain retains Content identity.
StageResult runCompiledStage(StageDocument[] inputs,
        const ref CompiledStage stage) {
    auto placement = stage.filterPlacement;
    auto names = stage.filterNames;
    enforce(placement != FilterPlacement.none || names.length == 0,
        "stage without filter placement has filters");

    auto configured = stage.transform;
    StageTransform transform = (StageDocument input) => configured(input);
    if (placement == FilterPlacement.before && names.length) {
        transform = (StageDocument input) {
            input.content = applyFilters(input.content, stage);
            return configured(input);
        };
    }

    auto result = runStage(inputs, instanceDeclaration(stage), transform);
    if (placement == FilterPlacement.after && names.length)
        foreach (ref event; result.events)
            if (event.kind == EventKind.emitted)
                event.payload.content = applyFilters(event.payload.content, stage);
    return result;
}

version (unittest) {
    import domain.document : Document, OutputName;
    import stages.contract : StageDecision;
    import stages.registry : ConfiguredStageTransform, StageConfiguration,
        StageOptions;

    private class ObservingFilterCalled : Exception {
        this() pure { super("observing filter called"); }
    }
    private string observingFilter(string text) pure {
        throw new ObservingFilterCalled;
    }

    private StageDecision applyAppendStage(StageDocument input,
            immutable(StageConfiguration)) pure {
        input.content = ownedText(materializeUtf8(input.content) ~ "S");
        return StageDecision.map(input);
    }

    private StageDecision applyRejectStage(StageDocument input,
            immutable(StageConfiguration)) pure {
        return StageDecision.reject("kept");
    }

    private StageDecision applyQuarantineStage(StageDocument input,
            immutable(StageConfiguration)) pure {
        return StageDecision.quarantine("review");
    }

    private StageDecision applySplitStage(StageDocument input,
            immutable(StageConfiguration)) pure {
        return StageDecision.split([
            StageDocument(Document(input.document.source, OutputName("a")),
                input.content),
            StageDocument(Document(input.document.source, OutputName("b")),
                input.content)
        ]);
    }

    private StageDecision applyIdentityStage(StageDocument input,
            immutable(StageConfiguration)) pure {
        return StageDecision.map(input);
    }

    private ConfiguredStageTransform appendStageFactory(
            const ref StageOptions options) {
        return ConfiguredStageTransform(&applyAppendStage);
    }
    private ConfiguredStageTransform rejectStageFactory(
            const ref StageOptions options) {
        return ConfiguredStageTransform(&applyRejectStage);
    }
    private ConfiguredStageTransform quarantineStageFactory(
            const ref StageOptions options) {
        return ConfiguredStageTransform(&applyQuarantineStage);
    }
    private ConfiguredStageTransform splitStageFactory(
            const ref StageOptions options) {
        return ConfiguredStageTransform(&applySplitStage);
    }
    private ConfiguredStageTransform identityStageFactory(
            const ref StageOptions options) {
        return ConfiguredStageTransform(&applyIdentityStage);
    }
}

unittest {
    import domain.document : Document, DocumentViewOwner, OutputName,
        SourceLocator;
    import job.json : parseJobJson;
    import pipeline : Filter, FilterRegistry;
    import stages.contract : DecisionKind, PassMode, StageDecision,
        StageTransform;
    import stages.registry : StageOptions, StageRegistration, StageRegistry;
    import std.exception : assertThrown;

    FilterRegistry filters;
    filters.addFilter("suffix-f", cast(Filter) ((string text) => text ~ "F"));
    filters.addFilter("observing", &observingFilter);
    StageRegistry stages;
    stages.add(StageRegistration(StageDeclaration("before-stage",
        PassMode.singlePass, ResourceDeclaration(1, 0)), null, null, null,
        &appendStageFactory, FilterPlacement.before));
    stages.add(StageRegistration(StageDeclaration("after-stage",
        PassMode.singlePass, ResourceDeclaration(1, 0)), null, null, null,
        &appendStageFactory, FilterPlacement.after));
    stages.add(StageRegistration(StageDeclaration("reject-stage",
        PassMode.singlePass, ResourceDeclaration(1, 0)), null, null, null,
        &rejectStageFactory, FilterPlacement.after));
    stages.add(StageRegistration(StageDeclaration("quarantine-stage",
        PassMode.singlePass, ResourceDeclaration(1, 0)), null, null, null,
        &quarantineStageFactory, FilterPlacement.after));
    stages.add(StageRegistration(StageDeclaration("split-stage",
        PassMode.singlePass, ResourceDeclaration(1, 0)), null, null, null,
        &splitStageFactory, FilterPlacement.after));

    auto document = Document(SourceLocator("memory", "batch", "1"),
        OutputName("out"));
    auto input = StageDocument(document, ownedText("x"));
    auto before = parseJobJson(`{"version":3,"stages":[{"id":"before-one",` ~
        `"implementation":"before-stage","filters":[{"name":"suffix-f"}]}]}`);
    auto beforePlan = compileJob(before, &stages, &filters);
    auto beforeResult = runCompiledStage([input], beforePlan.stages[0]);
    assert(materializeUtf8(beforeResult.events[0].payload.content) == "xFS");

    auto after = parseJobJson(`{"version":3,"stages":[{"id":"after-one",` ~
        `"implementation":"after-stage","filters":[{"name":"suffix-f"}]}]}`);
    auto afterPlan = compileJob(after, &stages, &filters);
    auto afterResult = runCompiledStage([input], afterPlan.stages[0]);
    assert(materializeUtf8(afterResult.events[0].payload.content) == "xSF");

    auto reject = parseJobJson(`{"version":3,"stages":[{"id":"reject-one",` ~
        `"implementation":"reject-stage","filters":[{"name":"suffix-f"}]}]}`);
    auto rejectPlan = compileJob(reject, &stages, &filters);
    auto rejected = runCompiledStage([input], rejectPlan.stages[0]);
    assert(rejected.events[0].kind == EventKind.rejected &&
        materializeUtf8(rejected.events[0].payload.content) == "x");
    auto quarantine = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"quarantine-one","implementation":"quarantine-stage",` ~
        `"filters":[{"name":"suffix-f"}]}]}`);
    auto quarantinePlan = compileJob(quarantine, &stages, &filters);
    auto quarantined = runCompiledStage([input], quarantinePlan.stages[0]);
    assert(quarantined.events[0].kind == EventKind.quarantined &&
        materializeUtf8(quarantined.events[0].payload.content) == "x");

    auto split = parseJobJson(`{"version":3,"stages":[{"id":"split-one",` ~
        `"implementation":"split-stage","filters":[{"name":"suffix-f"}]}]}`);
    auto splitPlan = compileJob(split, &stages, &filters);
    auto children = runCompiledStage([input], splitPlan.stages[0]);
    assert(children.events.length == 2 && children.events[0].isChild &&
        children.events[0].payload.document.id != children.events[1].payload.document.id);
    assert(materializeUtf8(children.events[0].payload.content) == "xF" &&
        materializeUtf8(children.events[1].payload.content) == "xF");
    assert(children.events[0].payload.document.id == Document.derivedChild(
        document, "split-one", 0, OutputName("a")).id);

    auto noFilter = parseJobJson(`{"version":3,"stages":[{"id":"plain",` ~
        `"implementation":"before-stage"}]}`);
    auto owner = new DocumentViewOwner(cast(ubyte[]) "z".dup);
    auto borrowed = new Content([ContentPiece.borrow(owner.view(0, 1))]);
    StageRegistry identityStages;
    identityStages.add(StageRegistration(StageDeclaration("before-stage",
        PassMode.singlePass, ResourceDeclaration(1, 0)), null, null, null,
        &identityStageFactory, FilterPlacement.before));
    auto identityPlan = compileJob(noFilter,
        &identityStages, &filters);
    auto unchanged = runCompiledStage([StageDocument(document, borrowed)],
        identityPlan.stages[0]);
    assert(unchanged.events[0].payload.content is borrowed);
    owner.close();
    assertThrown(unchanged.events[0].payload.content.size);

    auto filteredOwner = new DocumentViewOwner(cast(ubyte[]) "q".dup);
    auto filteredBorrow = new Content([
        ContentPiece.borrow(filteredOwner.view(0, 1))
    ]);
    auto retained = runCompiledStage([StageDocument(document, filteredBorrow)],
        beforePlan.stages[0]);
    filteredOwner.close();
    assert(materializeUtf8(retained.events[0].payload.content) == "qFS");

    auto invalidOwner = new DocumentViewOwner([cast(ubyte) 0xff]);
    auto invalid = new Content([ContentPiece.borrow(invalidOwner.view(0, 1))]);
    auto observing = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"observing-one","implementation":"before-stage",` ~
        `"filters":[{"name":"observing"}]}]}`);
    auto observingPlan = compileJob(observing, &identityStages, &filters);
    assertThrown(runCompiledStage([StageDocument(document, invalid)],
        observingPlan.stages[0]));
    invalidOwner.close();

    auto invalidDocument = Document.init;
    assertThrown!ObservingFilterCalled(runCompiledStage([
        StageDocument(document, ownedText("first")),
        StageDocument(invalidDocument, ownedText("second"))
    ], observingPlan.stages[0]));
}
