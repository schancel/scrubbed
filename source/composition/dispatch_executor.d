/// Pure exactly-once execution of one compiled v4 dispatch job.
module composition.dispatch_executor;

import composition.dispatch_compiler : CompiledDispatchJobV1,
    CompiledDispatchRouteV1;
import composition.job_executor : runCompiledJob;
import content.pieces : Content;
import extraction.container : ZipInspectionResultV1;
import extraction.contracts : DetectionOutcomeV1, DetectionResultV1,
    ExtractionProvenanceV1, RouteActionKindV1, RouteActionV1, TextDocumentV1;
import extraction.detector : detectMediaV1;
import extraction.port : ExtractionInputV1, SourceContentV1;
import extraction.refinement : RefinedMediaV1, refineMediaV1;
import stages.contract : EventKind, StageDocument;
import std.exception : enforce;

enum DispatchEventKindV1 : ubyte { emitted, rejected, quarantined, passed }

struct DispatchExecutionEventV1 {
private:
    string jobIdentityValue;
    DispatchEventKindV1 kindValue;
    StageDocument sourceValue;
    StageDocument outputValue;
    DetectionResultV1 detectionValue;
    bool hasContainerValue;
    ZipInspectionResultV1 containerValue;
    RouteActionV1 actionValue;
    string routeValue;
    string extractorValue;
    string extractorVersionValue;
    string[] warningsValue;
    ExtractionProvenanceV1 provenanceValue;
    bool hasProvenanceValue;
    string reasonValue;
public:
    string jobIdentity() const pure { return jobIdentityValue; }
    DispatchEventKindV1 kind() const pure { return kindValue; }
    StageDocument source() { return sourceValue; }
    StageDocument output() {
        enforce(kindValue == DispatchEventKindV1.emitted ||
            kindValue == DispatchEventKindV1.passed,
            "terminal policy event has no output");
        return outputValue;
    }
    DetectionResultV1 detection() { return detectionValue; }
    bool hasContainer() const pure { return hasContainerValue; }
    ZipInspectionResultV1 container() {
        enforce(hasContainerValue, "dispatch event has no container evidence");
        return containerValue;
    }
    RouteActionV1 action() const { return actionValue; }
    string routeName() const pure { return routeValue; }
    string extractor() const pure { return extractorValue; }
    string extractorVersion() const pure { return extractorVersionValue; }
    const(string)[] warnings() const pure { return warningsValue; }
    bool hasProvenance() const pure { return hasProvenanceValue; }
    ExtractionProvenanceV1 provenance() const {
        enforce(hasProvenanceValue, "dispatch event has no extraction provenance");
        return provenanceValue;
    }
    string reason() const pure { return reasonValue; }
}

final class DispatchExecutionFailureV1 : Exception {
    string jobIdentity;
    DetectionOutcomeV1 outcome;
    string routeName;
    string phase;
    Exception original;
    this(string identity, DetectionOutcomeV1 outcome, string route,
            string phase, Exception original) {
        super("dispatch job " ~ identity ~ " phase " ~ phase ~ " failed: " ~ original.msg);
        jobIdentity = identity.idup; this.outcome = outcome;
        routeName = route.idup; this.phase = phase.idup; this.original = original;
    }
}

DispatchExecutionEventV1 runDispatchJobV1(StageDocument input,
        ref CompiledDispatchJobV1 plan,
        string declaredMediaType = null, string fileName = null) {
    auto identity = plan.identity;
    validateInput(input);
    DetectionResultV1 detected;
    RefinedMediaV1 refined;
    try {
        detected = detectMediaV1(input.content, declaredMediaType, fileName,
            plan.detectionLimits);
        refined = refineMediaV1(input.content, detected, plan.zipLimits);
    } catch (Exception error) {
        throw new DispatchExecutionFailureV1(identity,
            detected.detectorVersion.length ? detected.outcome : DetectionOutcomeV1.unknown,
            null, "refine", error);
    }
    auto finalDetection = refined.detection;
    auto action = plan.declaration.actionFor(finalDetection.outcome);
    DispatchExecutionEventV1 event;
    event.jobIdentityValue = identity.idup;
    event.sourceValue = input;
    event.detectionValue = finalDetection;
    event.actionValue = action;
    event.warningsValue = finalDetection.warnings.dup;
    if (refined.containerInspected) {
        event.hasContainerValue = true;
        event.containerValue = refined.container;
    }

    final switch (action.kind) {
    case RouteActionKindV1.reject:
        event.kindValue = DispatchEventKindV1.rejected;
        event.reasonValue = action.reason.idup;
        return event;
    case RouteActionKindV1.quarantine:
        event.kindValue = DispatchEventKindV1.quarantined;
        event.reasonValue = action.reason.idup;
        return event;
    case RouteActionKindV1.passThrough:
        event.kindValue = DispatchEventKindV1.passed;
        event.reasonValue = action.reason.idup;
        event.outputValue = input; // Same Document and Content object.
        return event;
    case RouteActionKindV1.route:
        break;
    }

    auto route = plan.routeFor(action.routeName);
    event.routeValue = route.name.idup;
    event.extractorValue = route.implementation.idup;
    event.extractorVersionValue = route.version_.idup;
    TextDocumentV1 text;
    try {
        auto configured = route.configured;
        text = configured(ExtractionInputV1(input.document,
            SourceContentV1.from(input.content),
            finalDetection, route.name,
            refined.hasAdmittedZip ? refined.admittedZip : null));
        validateExtraction(text, input, finalDetection, route);
    } catch (Exception error) {
        throw new DispatchExecutionFailureV1(identity, finalDetection.outcome,
            route.name, "extract", error);
    }

    event.warningsValue ~= text.warnings.dup;
    event.provenanceValue = text.provenance;
    event.hasProvenanceValue = true;
    auto commonInput = StageDocument(text.document, text.content.toContent);
    try {
        auto commonPlan = plan.common;
        auto commonEvents = runCompiledJob(commonInput, commonPlan);
        enforce(commonEvents.length == 1,
            "common plan must converge to exactly one terminal event");
        auto common = commonEvents[0];
        enforce(!common.isChild && common.payload.document.id == input.document.id,
            "common plan must not split or derive a child");
        enforce(common.payload.document.outputName == input.document.outputName,
            "common plan must preserve output name");
        final switch (common.kind) {
        case EventKind.emitted:
            event.kindValue = DispatchEventKindV1.emitted;
            event.outputValue = common.payload;
            break;
        case EventKind.rejected:
            event.kindValue = DispatchEventKindV1.rejected;
            event.reasonValue = common.reason.idup;
            break;
        case EventKind.quarantined:
            event.kindValue = DispatchEventKindV1.quarantined;
            event.reasonValue = common.reason.idup;
            break;
        }
    } catch (Exception error) {
        throw new DispatchExecutionFailureV1(identity, finalDetection.outcome,
            route.name, "common", error);
    }
    return event;
}

private void validateInput(StageDocument input) {
    input.document.id;
    enforce(input.document.outputName.text.length, "dispatch input needs output name");
    enforce(input.content !is null, "dispatch input needs source content");
    input.content.size;
}

private void validateExtraction(const ref TextDocumentV1 text,
        StageDocument input, DetectionResultV1 detection,
        ref CompiledDispatchRouteV1 route) {
    enforce(text.id == input.document.id &&
        text.outputName == input.document.outputName,
        "extractor must preserve source identity and output name");
    auto actualDetection = text.detection;
    enforce(sameDetection(actualDetection, detection),
        "extractor must preserve refined detection");
    enforce(text.extractor == route.implementation &&
        text.extractorVersion == route.version_,
        "extractor identity/version mismatch");
    enforce(text.provenance.sourceOutcome == detection.outcome &&
        text.provenance.routeName == route.name &&
        text.provenance.sourceBytes == input.content.size,
        "extractor provenance mismatch");
}

private bool sameDetection(const ref DetectionResultV1 left,
        const ref DetectionResultV1 right) {
    if (left.outcome != right.outcome ||
            left.detectorVersion != right.detectorVersion ||
            left.bytesInspected != right.bytesInspected ||
            left.inspectionLimit != right.inspectionLimit ||
            left.availableBytes != right.availableBytes ||
            left.evidence.length != right.evidence.length ||
            left.warnings.length != right.warnings.length) return false;
    foreach (index, evidence; left.evidence) {
        auto expected = right.evidence[index];
        if (evidence.kind != expected.kind || evidence.outcome != expected.outcome ||
                evidence.detail != expected.detail) return false;
    }
    foreach (index, warning; left.warnings)
        if (warning != right.warnings[index]) return false;
    return true;
}

version (unittest) {
    import composition.dispatch_compiler : compileDispatchJobV1;
    import content.pieces : ContentPiece;
    import domain.document : Document, DocumentViewOwner, OutputName,
        SourceLocator;
    import extraction.contracts : ExtractionProvenanceV1;
    import extraction.port : ConfiguredExtractorV1, ExtractorConfigurationV1,
        ExtractorOptionDeclarationV1, ExtractorOptionsV1,
        ExtractorOptionTypeV1, ExtractorRegistrationV1, ExtractorRegistryV1,
        ExtractorResourcesV1;
    import job.dispatch_spec : DispatchActionKindV1, DispatchActionSpecV1,
        DispatchContainerSpecV1, DispatchDetectorSpecV1, DispatchJobSpecV1,
        DispatchOutcomeV1, DispatchRouteSpecV1, DispatchSpecV1;
    import job.spec : JobOption, JobSpec, JobStageSpec;
    import pipeline : FilterRegistry;
    import stages.contract : PassMode, ResourceDeclaration, StageDecision,
        StageDeclaration;
    import stages.registry : ConfiguredStageTransform, FilterPlacement,
        StageConfiguration, StageOptions, StageRegistration, StageRegistry;

    private __gshared size_t dispatchFactoryCalls;
    private __gshared size_t commonFactoryCalls;

    private TextDocumentV1 applyIdentityExtractor(ExtractionInputV1 input,
            immutable(ExtractorConfigurationV1)) pure {
        ubyte[] bytes;
        input.source.stream((const(ubyte)[] chunk) { bytes ~= chunk; });
        return TextDocumentV1.extractedOwned(input.document, bytes,
            input.detection,
            "identity", "identity:v1", ["extracted"],
            ExtractionProvenanceV1(input.detection.outcome,
                input.routeName, input.source.size));
    }

    private ConfiguredExtractorV1 identityFactory(
            const ref ExtractorOptionsV1 options) {
        ++dispatchFactoryCalls;
        enforce(options.length == 0, "identity extractor takes no options");
        return ConfiguredExtractorV1(&applyIdentityExtractor);
    }

    private StageDecision applyAppendCommon(StageDocument input,
            immutable(StageConfiguration)) pure {
        ubyte[] bytes;
        input.content.stream((const(ubyte)[] chunk) { bytes ~= chunk; });
        bytes ~= '!';
        input.content = new Content([ContentPiece.own(bytes)]);
        return StageDecision.map(input);
    }
    private ConfiguredStageTransform appendCommonFactory(const ref StageOptions) {
        ++commonFactoryCalls;
        return ConfiguredStageTransform(&applyAppendCommon);
    }
    private StageDecision applySplitCommon(StageDocument input,
            immutable(StageConfiguration)) pure {
        return StageDecision.split([
            StageDocument(Document(input.document.source, OutputName("a")), input.content),
            StageDocument(Document(input.document.source, OutputName("b")), input.content)
        ]);
    }
    private ConfiguredStageTransform splitCommonFactory(const ref StageOptions) {
        return ConfiguredStageTransform(&applySplitCommon);
    }

    private DispatchJobSpecV1 testDispatchSpec(string commonImplementation = null) {
        DispatchActionSpecV1[] actions;
        foreach (i; 0 .. cast(size_t) DispatchOutcomeV1.max + 1) {
            auto outcome = cast(DispatchOutcomeV1) i;
            if (outcome == DispatchOutcomeV1.plainText)
                actions ~= DispatchActionSpecV1.route(outcome, "text");
            else if (outcome == DispatchOutcomeV1.pdf)
                actions ~= DispatchActionSpecV1.policy(outcome,
                    DispatchActionKindV1.passThrough, "retain binary");
            else if (outcome == DispatchOutcomeV1.ambiguous)
                actions ~= DispatchActionSpecV1.policy(outcome,
                    DispatchActionKindV1.quarantine, "conflicting evidence");
            else
                actions ~= DispatchActionSpecV1.policy(outcome,
                    DispatchActionKindV1.reject, "not selected");
        }
        JobSpec common;
        if (commonImplementation.length)
            common.stages = [JobStageSpec("common", commonImplementation)];
        return DispatchJobSpecV1(DispatchSpecV1(
            DispatchDetectorSpecV1(4096, 16, 8),
            DispatchContainerSpecV1(1024, 2048, 10, 2, 100),
            [DispatchRouteSpecV1("text", "identity")], actions), common);
    }

    private ExtractorRegistryV1 testExtractors() {
        ExtractorRegistryV1 result;
        result.add(ExtractorRegistrationV1("identity", "identity:v1",
            [DetectionOutcomeV1.plainText], ExtractorResourcesV1(1, 4096),
            null, &identityFactory));
        return result;
    }

    private DispatchJobSpecV1 twoRouteSpec(string secondImplementation) {
        auto result = testDispatchSpec("append");
        result.dispatch.routes ~= DispatchRouteSpecV1("second",
            secondImplementation);
        result.dispatch.actions[cast(size_t) DispatchOutcomeV1.html] =
            DispatchActionSpecV1.route(DispatchOutcomeV1.html, "second");
        return result;
    }

    private void addSecond(ref ExtractorRegistryV1 registry,
            DetectionOutcomeV1 accepted,
            ExtractorOptionDeclarationV1[] schema = null) {
        registry.add(ExtractorRegistrationV1("second", "second:v1",
            [accepted], ExtractorResourcesV1(1, 4096), schema,
            &identityFactory));
    }
}

unittest {
    import core.thread : Thread;
    import std.exception : assertThrown;

    dispatchFactoryCalls = 0;
    commonFactoryCalls = 0;
    auto extractors = testExtractors;
    StageRegistry stages;
    stages.add(StageRegistration(StageDeclaration("append",
        PassMode.singlePass, ResourceDeclaration(1, 0)), null, null, null,
        &appendCommonFactory, FilterPlacement.none));
    FilterRegistry filters;
    auto spec = testDispatchSpec("append");
    auto incomplete = spec;
    incomplete.dispatch.actions = incomplete.dispatch.actions[0 .. $ - 1];
    assertThrown(compileDispatchJobV1(incomplete, &extractors, &stages, &filters));
    assert(dispatchFactoryCalls == 0 && commonFactoryCalls == 0);
    auto incompatible = testDispatchSpec("append");
    auto zipIndex = cast(size_t) DispatchOutcomeV1.genericZip;
    incompatible.dispatch.actions[zipIndex] = DispatchActionSpecV1.route(
        DispatchOutcomeV1.genericZip, "text");
    assertThrown(compileDispatchJobV1(incompatible, &extractors, &stages, &filters));
    assert(dispatchFactoryCalls == 0 && commonFactoryCalls == 0);

    auto unknownLater = twoRouteSpec("missing");
    assertThrown(compileDispatchJobV1(unknownLater, &extractors,
        &stages, &filters));
    assert(dispatchFactoryCalls == 0 && commonFactoryCalls == 0);

    auto unsupportedRegistry = testExtractors;
    addSecond(unsupportedRegistry, DetectionOutcomeV1.pdf);
    auto unsupportedLater = twoRouteSpec("second");
    assertThrown(compileDispatchJobV1(unsupportedLater, &unsupportedRegistry,
        &stages, &filters));
    assert(dispatchFactoryCalls == 0 && commonFactoryCalls == 0);

    auto optionRegistry = testExtractors;
    addSecond(optionRegistry, DetectionOutcomeV1.html,
        [ExtractorOptionDeclarationV1("enabled",
            ExtractorOptionTypeV1.boolean, true)]);
    auto badOptionLater = twoRouteSpec("second");
    badOptionLater.dispatch.routes[1].options["enabled"] =
        JobOption.text("true");
    assertThrown(compileDispatchJobV1(badOptionLater, &optionRegistry,
        &stages, &filters));
    assert(dispatchFactoryCalls == 0 && commonFactoryCalls == 0);

    auto unknownOptionRegistry = testExtractors;
    addSecond(unknownOptionRegistry, DetectionOutcomeV1.html);
    auto unknownOptionLater = twoRouteSpec("second");
    unknownOptionLater.dispatch.routes[1].options["extra"] =
        JobOption.boolean(true);
    assertThrown(compileDispatchJobV1(unknownOptionLater,
        &unknownOptionRegistry, &stages, &filters));
    assert(dispatchFactoryCalls == 0 && commonFactoryCalls == 0);

    auto resourceRegistry = testExtractors;
    addSecond(resourceRegistry, DetectionOutcomeV1.html);
    resourceRegistry.find("second").resources.cpuSlots = 0;
    auto badResourceLater = twoRouteSpec("second");
    assertThrown(compileDispatchJobV1(badResourceLater, &resourceRegistry,
        &stages, &filters));
    assert(dispatchFactoryCalls == 0 && commonFactoryCalls == 0);

    auto plan = compileDispatchJobV1(spec, &extractors, &stages, &filters);
    assert(dispatchFactoryCalls == 1);
    assert(commonFactoryCalls == 1);
    assert(plan.identity[0 .. 7] == "job:v4:" && plan.routes.length == 1);

    auto document = Document(SourceLocator("test", "dispatch", "one"),
        OutputName("out.txt"));
    auto owner = new DocumentViewOwner(cast(ubyte[]) "hello".dup);
    auto source = new Content([ContentPiece.borrow(owner.view(0, 5))]);
    auto event = runDispatchJobV1(StageDocument(document, source), plan);
    assert(event.kind == DispatchEventKindV1.emitted);
    assert(event.source.content is source);
    assert(event.output.document.id == document.id &&
        event.output.document.outputName == document.outputName);
    ubyte[] output;
    event.output.content.stream((const(ubyte)[] chunk) { output ~= chunk; });
    assert(cast(string) output == "hello!"); // extractor and common each ran once
    assert(event.routeName == "text" && event.extractor == "identity" &&
        event.extractorVersion == "identity:v1");
    assert(event.provenance.routeName == "text" &&
        event.provenance.sourceBytes == 5 && event.warnings.length == 1);
    assert(owner.view(0, 1).at(0) == 'h'); // executor did not close borrowed owner

    auto repeated = runDispatchJobV1(StageDocument(document, source), plan);
    assert(repeated.jobIdentity == event.jobIdentity);
    auto concurrentPlanA = plan;
    auto concurrentPlanB = plan;
    string concurrentTextA;
    string concurrentTextB;
    auto threadA = new Thread({
        auto concurrentSource = new Content([ContentPiece.own(
            cast(const(ubyte)[]) "hello")]);
        auto concurrent = runDispatchJobV1(
            StageDocument(document, concurrentSource), concurrentPlanA);
        ubyte[] bytes;
        concurrent.output.content.stream(
            (const(ubyte)[] chunk) { bytes ~= chunk; });
        concurrentTextA = cast(string) bytes;
    });
    auto threadB = new Thread({
        auto concurrentSource = new Content([ContentPiece.own(
            cast(const(ubyte)[]) "hello")]);
        auto concurrent = runDispatchJobV1(
            StageDocument(document, concurrentSource), concurrentPlanB);
        ubyte[] bytes;
        concurrent.output.content.stream(
            (const(ubyte)[] chunk) { bytes ~= chunk; });
        concurrentTextB = cast(string) bytes;
    });
    threadA.start; threadB.start; threadA.join; threadB.join;
    assert(concurrentTextA == "hello!" && concurrentTextB == concurrentTextA);
    auto pdf = new Content([ContentPiece.own(cast(const(ubyte)[]) "%PDF-1.7")]);
    auto passed = runDispatchJobV1(StageDocument(document, pdf), plan);
    assert(passed.kind == DispatchEventKindV1.passed &&
        passed.output.content is pdf && !passed.hasProvenance);
    auto binary = new Content([ContentPiece.own([cast(ubyte) 0, 1, 2])]);
    auto rejected = runDispatchJobV1(StageDocument(document, binary), plan);
    assert(rejected.kind == DispatchEventKindV1.rejected &&
        rejected.reason == "not selected" && !rejected.hasProvenance);
    auto conflict = new Content([ContentPiece.own(
        cast(const(ubyte)[]) "<html>%PDF-1.7")]);
    auto quarantined = runDispatchJobV1(StageDocument(document, conflict), plan);
    assert(quarantined.kind == DispatchEventKindV1.quarantined &&
        quarantined.reason == "conflicting evidence");

    StageRegistry splitStages;
    splitStages.add(StageRegistration(StageDeclaration("split",
        PassMode.singlePass, ResourceDeclaration(1, 0)), null, null, null,
        &splitCommonFactory, FilterPlacement.none));
    auto splitSpec = testDispatchSpec("split");
    auto splitPlan = compileDispatchJobV1(splitSpec, &extractors,
        &splitStages, &filters);
    try {
        runDispatchJobV1(StageDocument(document,
            new Content([ContentPiece.own(cast(const(ubyte)[]) "text")])), splitPlan);
        assert(false, "split common plan must fail closed");
    } catch (DispatchExecutionFailureV1 error) {
        assert(error.phase == "common" && error.routeName == "text" &&
            error.jobIdentity == splitPlan.identity);
    }
    owner.close();
    assertThrown(event.source.content.size);
    output.length = 0;
    event.output.content.stream((const(ubyte)[] chunk) { output ~= chunk; });
    assert(cast(string) output == "hello!");
}
