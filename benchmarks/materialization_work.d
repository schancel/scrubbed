/// Release-active materialization accounting and copy-removal proof for #183.
/// Build with -version=MaterializationWorkProbe; ordinary builds have no probe API.
module benchmarks.materialization_work;

import composition.compiler : compileJob;
import composition.executor : ExecutorMaterializationWorkV1,
    runCompiledStage, runCompiledStageMeasured;
import content.pieces : Content, ContentPiece, ContentPieceOwnWorkV1;
import core.memory : GC;
import core.thread : Thread;
import domain.document : Document, DocumentViewOwner, OutputName, SourceLocator;
import effects.atomic_piece_sink : writeAtomicPieces;
import job.json : parseJobJson;
import pipeline : Filter, FilterRegistry, Pipeline, PipelineMaterializationWorkV1,
    OutputStorageRelation, PipelineBoundaryWorkV1, StreamingFilter,
    StreamingState, TypedFilterSpec, classifyOutputStorage;
import stages.contract : EventKind, PassMode, ResourceDeclaration,
    StageDecision, StageDeclaration, StageDocument, StageResult;
import stages.registry : ConfiguredStageTransform, FilterPlacement,
    StageConfiguration, StageOptions, StageRegistration, StageRegistry;
import std.array : appender;
import std.conv : to;
import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;
import std.exception : enforce;
import std.file : exists, mkdir, read, remove, rmdir, tempDir, thisExePath,
    write;
import std.json : JSONValue;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : representation;
import std.uuid : randomUUID;

version (D_Optimized) {} else static assert(false,
    "materialization evidence requires an optimized compiler build");
version (assert) static assert(false,
    "materialization evidence requires -release");

private enum sourceBase = "c46abf30872ffd213801babd442835aaa15d692f";
private enum oneMiB = 1024 * 1024;
private enum fourMiB = 4 * oneMiB;
private enum evidenceSourcePaths = [
    "source/content/pieces.d",
    "source/composition/compiler.d",
    "source/composition/executor.d",
    "source/pipeline.d",
    "source/effects/atomic_piece_sink.d",
    "benchmarks/materialization_work.d"
];
private enum frozenBaselinePaths = [
    "benchmarks/pipeline-canonical-profile.json",
    "benchmarks/pipeline-canonical-attribution.json"
];

private immutable string knownGcOutput;

shared static this() {
    knownGcOutput = "ordinary-safe-output".idup;
}

private string embeddedSource(string path) pure {
    final switch (path) {
    case "source/content/pieces.d":
        return import("source/content/pieces.d");
    case "source/composition/compiler.d":
        return import("source/composition/compiler.d");
    case "source/composition/executor.d":
        return import("source/composition/executor.d");
    case "source/pipeline.d":
        return import("source/pipeline.d");
    case "source/effects/atomic_piece_sink.d":
        return import("source/effects/atomic_piece_sink.d");
    case "benchmarks/materialization_work.d":
        return import("benchmarks/materialization_work.d");
    case "benchmarks/pipeline-canonical-profile.json":
        return import("benchmarks/pipeline-canonical-profile.json");
    case "benchmarks/pipeline-canonical-attribution.json":
        return import("benchmarks/pipeline-canonical-attribution.json");
    }
}

private void need(bool okay, string message) {
    if (!okay) throw new Exception("materialization work: " ~ message);
}

private size_t identityPush(ref StreamingState, dchar input,
        dchar[2]* output) pure {
    (*output)[0] = input;
    return 1;
}

private size_t duplicatePush(ref StreamingState, dchar input,
        dchar[2]* output) pure {
    (*output)[0] = input;
    (*output)[1] = input;
    return 2;
}

private string wholeIdentity(string input) pure @safe { return input; }
private string wholePrefix(string input) pure @safe { return input[0 .. $ - 1]; }
private string wholeSuffix(string input) pure @safe { return input[1 .. $]; }
private string wholeInterior(string input) pure @safe { return input[1 .. $ - 1]; }
private string wholeEmptyBorrowed(string input) pure @safe { return input[2 .. 2]; }
private string wholeTiny(string input) pure @safe { return input[0 .. 1]; }
private string wholeDistinct(string input) pure @safe {
    auto allocated = input ~ "!";
    return allocated[0 .. input.length];
}
private string wholeKnownGcOutput(string) pure @safe { return knownGcOutput; }

private StageDecision mapStage(StageDocument input,
        immutable(StageConfiguration)) pure {
    return StageDecision.map(input);
}

private StageDecision rejectStage(StageDocument input,
        immutable(StageConfiguration)) pure {
    return StageDecision.reject("policy-stop");
}

private StageDecision quarantineStage(StageDocument input,
        immutable(StageConfiguration)) pure {
    return StageDecision.quarantine("manual-review");
}

private StageDecision splitStage(StageDocument input,
        immutable(StageConfiguration)) pure {
    return StageDecision.split([
        StageDocument(Document(input.document.source, OutputName("a")),
            input.content),
        StageDocument(Document(input.document.source, OutputName("b")),
            input.content)
    ]);
}

private ConfiguredStageTransform mapFactory(const ref StageOptions) {
    return ConfiguredStageTransform(&mapStage);
}
private ConfiguredStageTransform rejectFactory(const ref StageOptions) {
    return ConfiguredStageTransform(&rejectStage);
}
private ConfiguredStageTransform quarantineFactory(const ref StageOptions) {
    return ConfiguredStageTransform(&quarantineStage);
}
private ConfiguredStageTransform splitFactory(const ref StageOptions) {
    return ConfiguredStageTransform(&splitStage);
}

private string bytes(Content content) {
    auto output = appender!string;
    content.stream((const(ubyte)[] chunk) {
        output.put(cast(const(char)[])chunk);
    });
    return output.data;
}

private void sameResult(StageResult ordinary, StageResult measured) {
    need(ordinary.events.length == measured.events.length,
        "event count differs");
    foreach (index; 0 .. ordinary.events.length) {
        auto left = ordinary.events[index];
        auto right = measured.events[index];
        need(left.kind == right.kind && left.isChild == right.isChild &&
            left.payload.document.id == right.payload.document.id &&
            left.payload.document.outputName == right.payload.document.outputName &&
            left.reason == right.reason && bytes(left.payload.content) ==
                bytes(right.payload.content),
            "ordinary/measured stage result differs");
    }
}

private FilterRegistry filters() {
    FilterRegistry result;
    result.addStreamingFilter("identity", StreamingFilter(
        StreamingState.init, &identityPush, null));
    result.addStreamingFilter("duplicate", StreamingFilter(
        StreamingState.init, &duplicatePush, null));
    result.addSafeFilter("whole-identity", &wholeIdentity);
    result.addSafeFilter("whole-prefix", &wholePrefix);
    result.addSafeFilter("whole-suffix", &wholeSuffix);
    result.addSafeFilter("whole-interior", &wholeInterior);
    result.addSafeFilter("whole-empty-borrowed", &wholeEmptyBorrowed);
    result.addSafeFilter("whole-tiny", &wholeTiny);
    result.addSafeFilter("whole-distinct", &wholeDistinct);
    result.addSafeFilter("whole-known-gc-output", &wholeKnownGcOutput);
    result.addFilter("legacy-identity", &wholeIdentity);
    result.addFilter("legacy-known-gc-output", &wholeKnownGcOutput);
    return result;
}

private StageRegistry stages() {
    StageRegistry result;
    auto resources = ResourceDeclaration(1, 0);
    result.add(StageRegistration(StageDeclaration("map", PassMode.singlePass,
        resources), null, null, null, &mapFactory, FilterPlacement.before));
    result.add(StageRegistration(StageDeclaration("split", PassMode.singlePass,
        resources), null, null, null, &splitFactory, FilterPlacement.after));
    result.add(StageRegistration(StageDeclaration("reject", PassMode.singlePass,
        resources), null, null, null, &rejectFactory, FilterPlacement.after));
    result.add(StageRegistration(StageDeclaration("quarantine",
        PassMode.singlePass, resources), null, null, null,
        &quarantineFactory, FilterPlacement.after));
    return result;
}

private struct Evidence {
    ContentPieceOwnWorkV1 own;
    PipelineMaterializationWorkV1 pipeline;
    ExecutorMaterializationWorkV1 before;
    ExecutorMaterializationWorkV1 split;
    ExecutorMaterializationWorkV1 reject;
    ExecutorMaterializationWorkV1 quarantine;
    ulong sinkCalls;
    ulong sinkInputBytes;
    ulong sinkLogicalCopiedBytes;
    ulong sinkGcAllocatedBytes;
}

private void validateRelation(T)(ref const T boundary, string label) {
    need(boundary.aliasedOutputCalls + boundary.overlappingOutputCalls +
            boundary.distinctOutputCalls == boundary.calls,
        label ~ " relation calls do not reconcile");
    need(boundary.aliasedOutputBytes + boundary.overlappingOutputBytes +
            boundary.distinctOutputBytes == boundary.outputBytes,
        label ~ " relation bytes do not reconcile");
}

private void validateEvidence(ref const Evidence evidence) {
    validateRelation(evidence.pipeline.fusedScalar, "pipeline fused scalar");
    validateRelation(evidence.pipeline.wholeTextFilter,
        "pipeline whole-text filter");
    validateRelation(evidence.before.filterExecution,
        "before filter execution");
    validateRelation(evidence.split.filterExecution,
        "split filter execution");
    need(evidence.own.calls == 1 &&
        evidence.own.sourceBytes == fourMiB &&
        evidence.own.retainedBytes == fourMiB &&
        evidence.own.logicalCopiedBytes == fourMiB &&
        evidence.own.gcAllocatedBytes >= fourMiB,
        "owned positive-control accounting does not reconcile");
    need(evidence.pipeline.fusedScalar.calls == 2 &&
        evidence.pipeline.fusedScalar.inputBytes == 12 &&
        evidence.pipeline.fusedScalar.outputBytes == 18 &&
        evidence.pipeline.fusedScalar.logicalMaterializedBytes == 18 &&
        evidence.pipeline.fusedScalar.distinctOutputCalls == 2 &&
        evidence.pipeline.fusedScalar.distinctOutputBytes == 18 &&
        evidence.pipeline.wholeTextFilter.calls == 1 &&
        evidence.pipeline.wholeTextFilter.inputBytes == 6 &&
        evidence.pipeline.wholeTextFilter.outputBytes == 6 &&
        evidence.pipeline.wholeTextFilter.aliasedOutputCalls == 1 &&
        evidence.pipeline.wholeTextFilter.aliasedOutputBytes == 6 &&
        evidence.pipeline.wholeTextFilter.distinctOutputBytes == 0,
        "pipeline boundary accounting does not reconcile");
    need(evidence.before.contentToUtf8.calls == 1 &&
        evidence.before.contentToUtf8.inputBytes == oneMiB &&
        evidence.before.contentToUtf8.outputBytes == oneMiB &&
        evidence.before.contentToUtf8.logicalCopiedBytes == oneMiB &&
        evidence.before.filterExecution.calls == 1 &&
        evidence.before.filterExecution.inputBytes == oneMiB &&
        evidence.before.filterExecution.outputBytes == 2 * oneMiB &&
        evidence.before.filterExecution.distinctOutputCalls == 1 &&
        evidence.before.filterExecution.distinctOutputBytes == 2 * oneMiB &&
        evidence.before.filterResultToOwnedPiece.calls == 1 &&
        evidence.before.filterResultToOwnedPiece.inputBytes == 2 * oneMiB &&
        evidence.before.filterResultToOwnedPiece.outputBytes == 2 * oneMiB &&
        evidence.before.filterResultToOwnedPiece.logicalCopiedBytes == 0 &&
        evidence.before.filterResultToOwnedPiece.gcAllocatedBytes < 64 * 1024 &&
        evidence.before.emittedFilterApplications == 1 &&
        evidence.before.terminalFilterSkips == 0,
        "before-filter accounting does not reconcile");
    need(evidence.split.contentToUtf8.calls == 2 &&
        evidence.split.contentToUtf8.inputBytes == 4 * oneMiB &&
        evidence.split.contentToUtf8.outputBytes == 4 * oneMiB &&
        evidence.split.contentToUtf8.logicalCopiedBytes == 4 * oneMiB &&
        evidence.split.filterExecution.calls == 2 &&
        evidence.split.filterExecution.inputBytes == 4 * oneMiB &&
        evidence.split.filterExecution.outputBytes == 4 * oneMiB &&
        evidence.split.filterExecution.distinctOutputCalls == 2 &&
        evidence.split.filterExecution.distinctOutputBytes == 4 * oneMiB &&
        evidence.split.filterResultToOwnedPiece.calls == 2 &&
        evidence.split.filterResultToOwnedPiece.inputBytes == 4 * oneMiB &&
        evidence.split.filterResultToOwnedPiece.outputBytes == 4 * oneMiB &&
        evidence.split.filterResultToOwnedPiece.logicalCopiedBytes == 0 &&
        evidence.split.filterResultToOwnedPiece.gcAllocatedBytes < 64 * 1024 &&
        evidence.split.emittedFilterApplications == 2 &&
        evidence.split.terminalFilterSkips == 0,
        "split accounting does not reconcile");
    need(evidence.reject.contentToUtf8.calls == 0 &&
        evidence.reject.filterExecution.calls == 0 &&
        evidence.reject.filterResultToOwnedPiece.calls == 0 &&
        evidence.reject.emittedFilterApplications == 0 &&
        evidence.reject.terminalFilterSkips == 1,
        "terminal-skip accounting does not reconcile");
    need(evidence.quarantine.contentToUtf8.calls == 0 &&
        evidence.quarantine.filterExecution.calls == 0 &&
        evidence.quarantine.filterResultToOwnedPiece.calls == 0 &&
        evidence.quarantine.emittedFilterApplications == 0 &&
        evidence.quarantine.terminalFilterSkips == 1,
        "quarantine accounting does not reconcile");
    need(evidence.sinkCalls == 1 &&
        evidence.sinkInputBytes == 2 * oneMiB &&
        evidence.sinkLogicalCopiedBytes == evidence.sinkInputBytes &&
        evidence.sinkGcAllocatedBytes >= 64 * 1024,
        "atomic sink accounting does not reconcile");
}

private void expectInvalid(scope void delegate() operation, string message) {
    try operation();
    catch (Exception) { return; }
    throw new Exception("materialization work: accepted mutant: " ~ message);
}

private Evidence measure() {
    Evidence evidence;

    auto heavy = new ubyte[fourMiB];
    heavy[] = 'h';
    auto retained = ContentPiece.ownMeasured(heavy, evidence.own);
    need(retained.size == heavy.length && retained.at(0) == 'h',
        "owned positive control changed bytes");
    heavy[0] = 'x';
    need(retained.at(0) == 'h', "owned positive control retained caller alias");
    need(evidence.own.gcAllocatedBytes >= heavy.length,
        "allocation-heavy positive control was not detected");

    auto registry = filters;
    auto chain = Pipeline.buildTyped([
        TypedFilterSpec("identity"), TypedFilterSpec("whole-identity"),
        TypedFilterSpec("duplicate")], &registry);
    auto pipelineInput = "line\r\n";
    auto expectedPipeline = chain.run(pipelineInput);
    auto measuredPipeline = chain.runMeasured(pipelineInput, evidence.pipeline);
    need(measuredPipeline == expectedPipeline &&
        evidence.pipeline.fusedScalar.calls == 2 &&
        evidence.pipeline.wholeTextFilter.calls == 1 &&
        evidence.pipeline.wholeTextFilter.aliasedOutputBytes ==
            pipelineInput.length,
        "pipeline boundary accounting differs");

    auto stageRegistry = stages;
    auto document = Document(SourceLocator("materialization", "fixture", "one"),
        OutputName("one.txt"));
    auto sourceBytes = new ubyte[oneMiB];
    sourceBytes[] = 'a';
    auto ordinaryOwner = new DocumentViewOwner(sourceBytes.dup);
    auto measuredOwner = new DocumentViewOwner(sourceBytes.dup);
    scope(exit) { ordinaryOwner.close; measuredOwner.close; }

    auto beforeSpec = parseJobJson(`{"version":3,"stages":[{"id":"one",` ~
        `"implementation":"map","filters":[{"name":"duplicate"}]}]}`);
    auto beforePlan = compileJob(beforeSpec, &stageRegistry, &registry);
    auto ordinaryBefore = runCompiledStage([StageDocument(document,
        new Content([ContentPiece.borrow(ordinaryOwner.view(0, sourceBytes.length))]))],
        beforePlan.stages[0]);
    auto measuredBefore = runCompiledStageMeasured([StageDocument(document,
        new Content([ContentPiece.borrow(measuredOwner.view(0, sourceBytes.length))]))],
        beforePlan.stages[0], evidence.before);
    sameResult(ordinaryBefore, measuredBefore);
    need(evidence.before.contentToUtf8.logicalCopiedBytes == oneMiB &&
        evidence.before.filterResultToOwnedPiece.logicalCopiedBytes == 0 &&
        evidence.before.filterResultToOwnedPiece.gcAllocatedBytes < 64 * 1024 &&
        evidence.before.emittedFilterApplications == 1,
        "before-filter logical copy accounting differs");
    measuredOwner.close;
    GC.collect();
    need(bytes(measuredBefore.events[0].payload.content).length == 2 * oneMiB,
        "filtered output did not outlive borrowed owner");
    bool borrowedRefused;
    try measuredOwner.view(0, 0).size;
    catch (Exception) borrowedRefused = true;
    need(borrowedRefused,
        "closed borrowed owner remained readable at an empty boundary");

    auto splitSpec = parseJobJson(`{"version":3,"stages":[{"id":"fork",` ~
        `"implementation":"split","filters":[{"name":"identity"}]}]}`);
    auto splitPlan = compileJob(splitSpec, &stageRegistry, &registry);
    auto splitOrdinary = runCompiledStage([StageDocument(document,
        ordinaryBefore.events[0].payload.content)], splitPlan.stages[0]);
    auto splitMeasured = runCompiledStageMeasured([StageDocument(document,
        ordinaryBefore.events[0].payload.content)], splitPlan.stages[0],
        evidence.split);
    sameResult(splitOrdinary, splitMeasured);
    need(evidence.split.emittedFilterApplications == 2 &&
        evidence.split.contentToUtf8.calls == 2 &&
        splitMeasured.events[0].isChild &&
        splitMeasured.events[1].isChild &&
        splitMeasured.events[0].payload.document.id == Document.derivedChild(
            document, "fork", 0, OutputName("a")).id &&
        splitMeasured.events[1].payload.document.id == Document.derivedChild(
            document, "fork", 1, OutputName("b")).id &&
        splitMeasured.events[0].payload.content !is
            splitMeasured.events[1].payload.content,
        "split boundary accounting differs");

    auto rejectSpec = parseJobJson(`{"version":3,"stages":[{"id":"stop",` ~
        `"implementation":"reject","filters":[{"name":"identity"}]}]}`);
    auto rejectPlan = compileJob(rejectSpec, &stageRegistry, &registry);
    auto rejected = runCompiledStageMeasured([StageDocument(document,
        ordinaryBefore.events[0].payload.content)], rejectPlan.stages[0],
        evidence.reject);
    auto ordinaryRejected = runCompiledStage([StageDocument(document,
        ordinaryBefore.events[0].payload.content)], rejectPlan.stages[0]);
    sameResult(ordinaryRejected, rejected);
    need(rejected.events.length == 1 &&
        rejected.events[0].kind == EventKind.rejected &&
        evidence.reject.terminalFilterSkips == 1 &&
        evidence.reject.contentToUtf8.calls == 0,
        "terminal decision unexpectedly materialized filters");

    auto quarantineSpec = parseJobJson(`{"version":3,"stages":[{"id":"hold",` ~
        `"implementation":"quarantine","filters":[{"name":"identity"}]}]}`);
    auto quarantinePlan = compileJob(quarantineSpec, &stageRegistry, &registry);
    auto ordinaryQuarantined = runCompiledStage([StageDocument(document,
        ordinaryBefore.events[0].payload.content)], quarantinePlan.stages[0]);
    auto quarantined = runCompiledStageMeasured([StageDocument(document,
        ordinaryBefore.events[0].payload.content)], quarantinePlan.stages[0],
        evidence.quarantine);
    sameResult(ordinaryQuarantined, quarantined);
    need(quarantined.events.length == 1 &&
        quarantined.events[0].kind == EventKind.quarantined &&
        evidence.quarantine.terminalFilterSkips == 1 &&
        evidence.quarantine.contentToUtf8.calls == 0,
        "quarantine decision unexpectedly materialized filters");

    auto root = buildPath(tempDir, "materialization-work-" ~
        randomUUID.toString);
    mkdir(root);
    scope(exit) if (exists(root)) rmdir(root);
    auto destination = buildPath(root, "output.bin");
    auto sinkContent = measuredBefore.events[0].payload.content;
    auto sinkBytes = sinkContent.size;
    auto beforeSink = GC.allocatedInCurrentThread;
    writeAtomicPieces(destination, sinkContent.pieces, null, 64 * 1024);
    auto afterSink = GC.allocatedInCurrentThread;
    need(afterSink >= beforeSink && read(destination) ==
        cast(const(ubyte)[])bytes(sinkContent),
        "atomic sink changed output");
    evidence.sinkCalls = 1;
    evidence.sinkInputBytes = sinkBytes;
    evidence.sinkLogicalCopiedBytes = sinkBytes;
    evidence.sinkGcAllocatedBytes = afterSink - beforeSink;
    write(destination, cast(const(ubyte)[])"prior-output");
    bool failedSink;
    try writeAtomicPieces(destination, sinkContent.pieces,
        (ulong completed) {
            if (completed) throw new Exception("injected sink checkpoint failure");
        }, 64 * 1024);
    catch (Exception failure) failedSink =
        failure.msg == "injected sink checkpoint failure";
    need(failedSink && read(destination) ==
        cast(const(ubyte)[])"prior-output",
        "atomic sink failure changed the prior output");
    remove(destination);
    validateEvidence(evidence);
    return evidence;
}

private final class ConcurrentRun {
    string output;
    PipelineMaterializationWorkV1 work;

    void execute() {
        auto registry = filters;
        auto chain = Pipeline.buildTyped([
            TypedFilterSpec("identity"), TypedFilterSpec("duplicate")],
            &registry);
        foreach (_; 0 .. 100)
            output = chain.runMeasured("thread", work);
    }
}

private void concurrencyControl() {
    enum workers = 8;
    ConcurrentRun[workers] runs;
    Thread[workers] threads;
    foreach (index; 0 .. workers) {
        runs[index] = new ConcurrentRun;
        threads[index] = new Thread(&runs[index].execute);
        threads[index].start;
    }
    foreach (thread; threads) thread.join;
    foreach (run; runs)
        need(run.output == "tthhrreeaadd" &&
            run.work.fusedScalar.calls == 100,
            "caller-owned concurrent evidence interfered");
}

private void needRelation(T)(ref const T boundary,
        OutputStorageRelation expected, size_t outputBytes, string label) {
    validateRelation(boundary, label);
    final switch (expected) {
    case OutputStorageRelation.borrowed:
        need(boundary.aliasedOutputCalls == 1 &&
            boundary.aliasedOutputBytes == outputBytes &&
            boundary.overlappingOutputCalls == 0 &&
            boundary.distinctOutputCalls == 0,
            label ~ " was not classified as borrowed storage");
        break;
    case OutputStorageRelation.overlaps:
        need(boundary.overlappingOutputCalls == 1 &&
            boundary.overlappingOutputBytes == outputBytes &&
            boundary.aliasedOutputCalls == 0 &&
            boundary.distinctOutputCalls == 0,
            label ~ " was not classified as overlapping storage");
        break;
    case OutputStorageRelation.distinct:
        need(boundary.distinctOutputCalls == 1 &&
            boundary.distinctOutputBytes == outputBytes &&
            boundary.aliasedOutputCalls == 0 &&
            boundary.overlappingOutputCalls == 0,
            label ~ " was not classified as distinct storage");
        break;
    }
}

private void aliasClassificationControl() {
    struct Case {
        string name;
        string expected;
        OutputStorageRelation relation;
        bool copiesResult;
    }
    immutable cases = [
        Case("whole-identity", "abcdef", OutputStorageRelation.borrowed, false),
        Case("whole-prefix", "abcde", OutputStorageRelation.borrowed, false),
        Case("whole-suffix", "bcdef", OutputStorageRelation.borrowed, false),
        Case("whole-interior", "bcde", OutputStorageRelation.borrowed, false),
        Case("whole-empty-borrowed", "", OutputStorageRelation.borrowed, true),
        Case("whole-distinct", "abcdef", OutputStorageRelation.distinct, false),
        Case("legacy-identity", "abcdef", OutputStorageRelation.borrowed, true)
    ];
    auto registry = filters;
    auto stageRegistry = stages;
    auto document = Document(SourceLocator("materialization", "alias", "one"),
        OutputName("alias.txt"));
    foreach (test; cases) {
        auto chain = Pipeline.buildTyped([TypedFilterSpec(test.name)],
            &registry);
        PipelineMaterializationWorkV1 pipelineWork;
        auto ordinaryPipeline = chain.run("abcdef");
        auto measuredPipeline = chain.runMeasured("abcdef", pipelineWork);
        need(ordinaryPipeline == test.expected &&
            measuredPipeline == ordinaryPipeline,
            test.name ~ " pipeline output differs");
        needRelation(pipelineWork.wholeTextFilter, test.relation,
            test.expected.length, test.name ~ " pipeline");

        auto spec = parseJobJson(`{"version":3,"stages":[{"id":"alias",` ~
            `"implementation":"map","filters":[{"name":"` ~ test.name ~
            `"}]}]}`);
        auto plan = compileJob(spec, &stageRegistry, &registry);
        auto content = new Content([ContentPiece.own(
            cast(const(ubyte)[])"abcdef")]);
        auto ordinary = runCompiledStage([StageDocument(document, content)],
            plan.stages[0]);
        ExecutorMaterializationWorkV1 executorWork;
        auto measured = runCompiledStageMeasured([
            StageDocument(document, content)], plan.stages[0], executorWork);
        sameResult(ordinary, measured);
        need(bytes(measured.events[0].payload.content) == test.expected,
            test.name ~ " executor output differs");
        needRelation(executorWork.filterExecution, test.relation,
            test.expected.length, test.name ~ " executor");
        need(executorWork.filterResultToOwnedPiece.logicalCopiedBytes ==
                (test.copiesResult ? test.expected.length : 0),
            test.name ~ " executor retention policy differs");
    }

    need(GC.addrOf(knownGcOutput.ptr) !is null,
        "ordinary retention control is not GC-backed");
    foreach (name, retains; ["whole-known-gc-output": true,
            "legacy-known-gc-output": false]) {
        auto spec = parseJobJson(`{"version":3,"stages":[{"id":"ordinary",` ~
            `"implementation":"map","filters":[{"name":"` ~ name ~
            `"}]}]}`);
        auto plan = compileJob(spec, &stageRegistry, &registry);
        auto ordinary = runCompiledStage([StageDocument(document,
            new Content([ContentPiece.own(cast(const(ubyte)[])"input")]))],
            plan.stages[0]);
        auto output = ordinary.events[0].payload.content;
        need(bytes(output) == knownGcOutput,
            name ~ " ordinary executor output differs");
        need(output.retainsImmutableStorage(
                cast(immutable(ubyte)[])knownGcOutput) == retains,
            name ~ " ordinary executor retention policy differs");
    }

    auto largeBytes = new ubyte[oneMiB];
    largeBytes[] = 'a';
    auto largeOwner = new DocumentViewOwner(largeBytes);
    auto tinySpec = parseJobJson(`{"version":3,"stages":[{"id":"tiny",` ~
        `"implementation":"map","filters":[{"name":"whole-tiny"}]}]}`);
    auto tinyPlan = compileJob(tinySpec, &stageRegistry, &registry);
    ExecutorMaterializationWorkV1 tinyWork;
    auto tiny = runCompiledStageMeasured([StageDocument(document,
        new Content([ContentPiece.borrow(largeOwner.view(0, oneMiB))]))],
        tinyPlan.stages[0], tinyWork);
    need(tinyWork.filterResultToOwnedPiece.logicalCopiedBytes == 1 &&
        tinyWork.filterResultToOwnedPiece.gcAllocatedBytes < 64 * 1024,
        "tiny retained slice did not use bounded compaction");
    largeOwner.close;
    GC.collect();
    need(bytes(tiny.events[0].payload.content) == "a",
        "compacted tiny output did not outlive borrowed owner");

    auto backing = "012345";
    need(classifyOutputStorage(backing[1 .. 5], backing[0 .. 3]) ==
        OutputStorageRelation.overlaps,
        "partial shared-storage overlap was classified as distinct");
    need(classifyOutputStorage(backing[1 .. 5], string.init) ==
        OutputStorageRelation.distinct,
        "unrelated empty storage was classified as borrowed");
    auto sameEmpty = backing[2 .. 2];
    need(classifyOutputStorage(sameEmpty, sameEmpty) ==
        OutputStorageRelation.borrowed,
        "identical empty storage was classified as distinct");
}

private void invalidUtf8Control() {
    auto registry = filters;
    auto chain = Pipeline.buildTyped([TypedFilterSpec("identity")], &registry);
    auto invalid = cast(string)[cast(char)0xc3];
    string ordinary, measured;
    try chain.run(invalid); catch (Throwable error)
        ordinary = typeid(error).name ~ ":" ~ error.msg;
    PipelineMaterializationWorkV1 work;
    try chain.runMeasured(invalid, work); catch (Throwable error)
        measured = typeid(error).name ~ ":" ~ error.msg;
    need(ordinary.length && measured == ordinary,
        "measured invalid UTF-8 exception differs");

    auto stageRegistry = stages;
    auto document = Document(SourceLocator("materialization", "invalid", "one"),
        OutputName("invalid.txt"));
    auto spec = parseJobJson(`{"version":3,"stages":[{"id":"one",` ~
        `"implementation":"map","filters":[{"name":"identity"}]}]}`);
    auto plan = compileJob(spec, &stageRegistry, &registry);
    auto firstOwner = new DocumentViewOwner([cast(ubyte)0xc3]);
    auto secondOwner = new DocumentViewOwner([cast(ubyte)0xc3]);
    scope(exit) { firstOwner.close; secondOwner.close; }
    ordinary = null;
    measured = null;
    try runCompiledStage([StageDocument(document, new Content([
            ContentPiece.borrow(firstOwner.view(0, 1))]))], plan.stages[0]);
    catch (Throwable error) ordinary = typeid(error).name ~ ":" ~ error.msg;
    ExecutorMaterializationWorkV1 executorWork;
    try runCompiledStageMeasured([StageDocument(document, new Content([
            ContentPiece.borrow(secondOwner.view(0, 1))]))], plan.stages[0],
        executorWork);
    catch (Throwable error) measured = typeid(error).name ~ ":" ~ error.msg;
    need(ordinary.length && measured == ordinary,
        "measured executor invalid UTF-8 exception differs");
}

private JSONValue boundaryJson(ulong calls, ulong inputBytes,
        ulong outputBytes, ulong copiedBytes, ulong gcBytes,
        ulong aliasedBytes = 0, ulong distinctBytes = 0,
        ulong overlappingBytes = 0, ulong aliasedCalls = 0,
        ulong overlappingCalls = 0, ulong distinctCalls = 0) {
    return JSONValue([
        "calls": JSONValue(cast(long)calls),
        "input_bytes": JSONValue(cast(long)inputBytes),
        "output_bytes": JSONValue(cast(long)outputBytes),
        "logical_copied_bytes": JSONValue(cast(long)copiedBytes),
        "gc_allocated_bytes": JSONValue(cast(long)gcBytes),
        "aliased_output_calls": JSONValue(cast(long)aliasedCalls),
        "aliased_output_bytes": JSONValue(cast(long)aliasedBytes),
        "overlapping_output_calls": JSONValue(cast(long)overlappingCalls),
        "overlapping_output_bytes": JSONValue(cast(long)overlappingBytes),
        "distinct_output_calls": JSONValue(cast(long)distinctCalls),
        "distinct_output_bytes": JSONValue(cast(long)distinctBytes)
    ]);
}

private string digestFile(string path) {
    return toHexString!(LetterCase.lower)(sha256Of(read(path))).idup;
}

private string digestText(string source) {
    return toHexString!(LetterCase.lower)(sha256Of(source.representation)).idup;
}

private void validateSourceIdentity() {
    foreach (path; evidenceSourcePaths)
        need(digestFile(path) == digestText(embeddedSource(path)),
            "source changed after probe compilation: " ~ path);
    foreach (path; frozenBaselinePaths)
        need(digestFile(path) == digestText(embeddedSource(path)),
            "frozen #59 baseline changed after probe compilation: " ~ path);
}

private JSONValue report(ref const Evidence evidence) {
    JSONValue root;
    root["schema"] = "scrubbed-materialization-work-v1";
    root["source_base"] = sourceBase;
    root["probe_binary_sha256"] = digestFile(thisExePath);
    root["compiler_vendor"] = __VENDOR__;
    root["compiler_version"] = cast(long)__VERSION__;
    root["build"] = "D_Optimized+release-required-command";
    root["ordinary_algorithm_changed"] = true;
    root["representation_change_authorized"] = true;
    root["performance_claim_authorized"] = false;
    root["reason"] = "DIP1000-checked allocation-sized filter results are retained without a payload copy while legacy results and pathological slices are copied; deterministic allocation and lifetime proof passed, but loaded-host wall timing is not a performance claim";
    JSONValue sources;
    foreach (path; evidenceSourcePaths)
        sources[path] = digestText(embeddedSource(path));
    root["source_sha256"] = sources;
    JSONValue frozenBaselines;
    foreach (path; frozenBaselinePaths)
        frozenBaselines[path] = digestText(embeddedSource(path));
    root["frozen_59_sha256"] = frozenBaselines;
    JSONValue boundaries;
    boundaries["content_piece_own"] = boundaryJson(evidence.own.calls,
        evidence.own.sourceBytes, evidence.own.retainedBytes,
        evidence.own.logicalCopiedBytes, evidence.own.gcAllocatedBytes);
    boundaries["pipeline_fused_scalar"] = boundaryJson(
        evidence.pipeline.fusedScalar.calls,
        evidence.pipeline.fusedScalar.inputBytes,
        evidence.pipeline.fusedScalar.outputBytes,
        evidence.pipeline.fusedScalar.logicalMaterializedBytes,
        evidence.pipeline.fusedScalar.gcAllocatedBytes,
        evidence.pipeline.fusedScalar.aliasedOutputBytes,
        evidence.pipeline.fusedScalar.distinctOutputBytes,
        evidence.pipeline.fusedScalar.overlappingOutputBytes,
        evidence.pipeline.fusedScalar.aliasedOutputCalls,
        evidence.pipeline.fusedScalar.overlappingOutputCalls,
        evidence.pipeline.fusedScalar.distinctOutputCalls);
    boundaries["pipeline_whole_text_filter"] = boundaryJson(
        evidence.pipeline.wholeTextFilter.calls,
        evidence.pipeline.wholeTextFilter.inputBytes,
        evidence.pipeline.wholeTextFilter.outputBytes,
        evidence.pipeline.wholeTextFilter.logicalMaterializedBytes,
        evidence.pipeline.wholeTextFilter.gcAllocatedBytes,
        evidence.pipeline.wholeTextFilter.aliasedOutputBytes,
        evidence.pipeline.wholeTextFilter.distinctOutputBytes,
        evidence.pipeline.wholeTextFilter.overlappingOutputBytes,
        evidence.pipeline.wholeTextFilter.aliasedOutputCalls,
        evidence.pipeline.wholeTextFilter.overlappingOutputCalls,
        evidence.pipeline.wholeTextFilter.distinctOutputCalls);
    boundaries["executor_content_to_utf8"] = boundaryJson(
        evidence.before.contentToUtf8.calls,
        evidence.before.contentToUtf8.inputBytes,
        evidence.before.contentToUtf8.outputBytes,
        evidence.before.contentToUtf8.logicalCopiedBytes,
        evidence.before.contentToUtf8.gcAllocatedBytes);
    boundaries["executor_filter_execution"] = boundaryJson(
        evidence.before.filterExecution.calls,
        evidence.before.filterExecution.inputBytes,
        evidence.before.filterExecution.outputBytes,
        evidence.before.filterExecution.logicalCopiedBytes,
        evidence.before.filterExecution.gcAllocatedBytes,
        evidence.before.filterExecution.aliasedOutputBytes,
        evidence.before.filterExecution.distinctOutputBytes,
        evidence.before.filterExecution.overlappingOutputBytes,
        evidence.before.filterExecution.aliasedOutputCalls,
        evidence.before.filterExecution.overlappingOutputCalls,
        evidence.before.filterExecution.distinctOutputCalls);
    boundaries["executor_filter_result_to_owned_piece"] = boundaryJson(
        evidence.before.filterResultToOwnedPiece.calls,
        evidence.before.filterResultToOwnedPiece.inputBytes,
        evidence.before.filterResultToOwnedPiece.outputBytes,
        evidence.before.filterResultToOwnedPiece.logicalCopiedBytes,
        evidence.before.filterResultToOwnedPiece.gcAllocatedBytes);
    boundaries["split_content_to_utf8"] = boundaryJson(
        evidence.split.contentToUtf8.calls,
        evidence.split.contentToUtf8.inputBytes,
        evidence.split.contentToUtf8.outputBytes,
        evidence.split.contentToUtf8.logicalCopiedBytes,
        evidence.split.contentToUtf8.gcAllocatedBytes);
    boundaries["split_filter_execution"] = boundaryJson(
        evidence.split.filterExecution.calls,
        evidence.split.filterExecution.inputBytes,
        evidence.split.filterExecution.outputBytes,
        evidence.split.filterExecution.logicalCopiedBytes,
        evidence.split.filterExecution.gcAllocatedBytes,
        evidence.split.filterExecution.aliasedOutputBytes,
        evidence.split.filterExecution.distinctOutputBytes,
        evidence.split.filterExecution.overlappingOutputBytes,
        evidence.split.filterExecution.aliasedOutputCalls,
        evidence.split.filterExecution.overlappingOutputCalls,
        evidence.split.filterExecution.distinctOutputCalls);
    boundaries["split_filter_result_to_owned_piece"] = boundaryJson(
        evidence.split.filterResultToOwnedPiece.calls,
        evidence.split.filterResultToOwnedPiece.inputBytes,
        evidence.split.filterResultToOwnedPiece.outputBytes,
        evidence.split.filterResultToOwnedPiece.logicalCopiedBytes,
        evidence.split.filterResultToOwnedPiece.gcAllocatedBytes);
    boundaries["atomic_piece_sink_buffer"] = boundaryJson(evidence.sinkCalls,
        evidence.sinkInputBytes, evidence.sinkInputBytes,
        evidence.sinkLogicalCopiedBytes, evidence.sinkGcAllocatedBytes);
    root["boundaries"] = boundaries;
    root["decision_accounting"] = JSONValue([
        "before_emitted_filter_applications": JSONValue(
            cast(long)evidence.before.emittedFilterApplications),
        "split_emitted_filter_applications": JSONValue(
            cast(long)evidence.split.emittedFilterApplications),
        "reject_terminal_filter_skips": JSONValue(
            cast(long)evidence.reject.terminalFilterSkips),
        "quarantine_terminal_filter_skips": JSONValue(
            cast(long)evidence.quarantine.terminalFilterSkips)
    ]);
    root["controls"] = JSONValue([
        "allocation_heavy_positive": JSONValue(true),
        "ordinary_measured_equivalence": JSONValue(true),
        "pipeline_executor_storage_relations": JSONValue(true),
        "partial_overlap_not_distinct": JSONValue(true),
        "owner_close": JSONValue(true),
        "split_order_identity": JSONValue(true),
        "terminal_reject_quarantine_skip": JSONValue(true),
        "invalid_utf8_exception": JSONValue(true),
        "caller_owned_concurrency": JSONValue(true),
        "atomic_sink_exact_bytes": JSONValue(true),
        "atomic_sink_failure_no_publish": JSONValue(true)
    ]);
    return root;
}

void main(string[] args) {
    need(args.length <= 2, "usage: materialization-work [--self-test]");
    if (args.length == 2)
        need(args[1] == "--self-test", "unknown option: " ~ args[1]);
    validateSourceIdentity;
    auto evidence = measure;
    invalidUtf8Control;
    concurrencyControl;
    aliasClassificationControl;
    // Mutants prove that logical-copy and outcome accounting are checked.
    auto copyMutant = evidence;
    ++copyMutant.before.contentToUtf8.logicalCopiedBytes;
    expectInvalid(() { validateEvidence(copyMutant); },
        "logical-copy accounting");
    auto splitBoundaryMutant = evidence;
    ++splitBoundaryMutant.split.filterResultToOwnedPiece.outputBytes;
    expectInvalid(() { validateEvidence(splitBoundaryMutant); },
        "split boundary accounting");
    auto outcomeMutant = evidence;
    outcomeMutant.reject.terminalFilterSkips = 0;
    expectInvalid(() { validateEvidence(outcomeMutant); },
        "terminal-outcome accounting");
    auto aliasMutant = evidence;
    aliasMutant.pipeline.wholeTextFilter.aliasedOutputCalls = 0;
    aliasMutant.pipeline.wholeTextFilter.distinctOutputCalls = 1;
    aliasMutant.pipeline.wholeTextFilter.aliasedOutputBytes = 0;
    aliasMutant.pipeline.wholeTextFilter.distinctOutputBytes = 6;
    expectInvalid(() { validateEvidence(aliasMutant); },
        "borrowed-output classification");
    if (args.length == 2) {
        writeln("materialization work self-test passed");
        return;
    }
    writeln(report(evidence).toString);
}
