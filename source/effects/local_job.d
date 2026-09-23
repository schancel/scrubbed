/// Local-file adapter for one already-compiled job and synchronous publication.
module effects.local_job;

import composition.compiler : CompiledJob;
import composition.job_executor : runCompiledJob;
import composition.runtime_plan : RuntimeExecutionV1, RuntimePlanV1,
    runRuntimePlanV1;
import content.pieces : Content, ContentPiece;
import domain.document : Document, DocumentViewOwner;
import effects.atomic_piece_sink : writeAtomicPieces;
import effects.mapped_file : openMappedFile;
import effects.runner : Parser, Sink, Source, SourceRecord, runEffects;
import stages.contract : EventKind, StageDocument, StageEvent;
import std.digest.sha : SHA256;
import std.exception : enforce;
import std.file : isSymlink;
import std.stdio : File;

alias LocalDestination = string delegate(const ref StageEvent event);
alias LocalAdmission = void delegate(string destination,
    const ref StageEvent event);
alias LocalPublicationBegin = void delegate();
alias LocalRootPlan = void delegate(ref const ubyte[32] inputHash);
alias LocalEventBatch = void delegate(StageEvent[] events,
    ref const ubyte[32] inputHash);
alias LocalRuntimeBatchV1 = void delegate(ref RuntimeExecutionV1 execution,
    ref const ubyte[32] inputHash);

struct LocalJobOutcome {
    size_t emitted;
    size_t rejected;
    size_t quarantined;
    bool changed;
    string firstReason;
    string dispatchRecord;

    string status() const {
        if (quarantined) return "quarantined";
        if (rejected) return "rejected";
        if (emitted > 1) return "split";
        return changed ? "changed" : "unchanged";
    }
}

/// Execute one compiled local job while retaining the mapped input through a
/// single callback over its complete ordered final-event set. `planRoot` runs
/// after the input digest is trustworthy and before compiled execution. Both
/// callbacks are synchronous and must not retain event content.
LocalJobOutcome runLocalJobBatch(string filename, ulong expectedBytes,
        Document document, const ref CompiledJob job,
        scope LocalRootPlan planRoot, scope LocalEventBatch acceptBatch) {
    enforce(planRoot !is null && acceptBatch !is null,
        "local batch callbacks are required");
    enforce(!isSymlink(filename), "refusing symlink input: " ~ filename);
    DocumentViewOwner owner;
    if (expectedBytes == 0) {
        scope input = File(filename, "rb");
        enforce(input.size == 0,
            "input changed size after admission: " ~ filename);
        owner = new DocumentViewOwner(new ubyte[0]);
    } else owner = openMappedFile(filename, expectedBytes);
    scope(exit) owner.close();
    auto content = new Content([ContentPiece.borrow(
        owner.view(0, cast(size_t) expectedBytes))]);
    auto inputHash = contentDigest(content);
    planRoot(inputHash);
    auto events = runCompiledJob(StageDocument(document, content), job);
    enforce(events.length != 0,
        "compiled job produced no terminal decision");
    acceptBatch(events, inputHash);
    LocalJobOutcome outcome;
    foreach (ref event; events) final switch (event.kind) {
    case EventKind.emitted:
        ++outcome.emitted;
        if (event.isChild || contentDigest(event.payload.content) != inputHash)
            outcome.changed = true;
        break;
    case EventKind.rejected:
        ++outcome.rejected;
        if (!outcome.firstReason.length) outcome.firstReason = event.reason.idup;
        break;
    case EventKind.quarantined:
        ++outcome.quarantined;
        if (!outcome.firstReason.length) outcome.firstReason = event.reason.idup;
        break;
    }
    return outcome;
}

LocalJobOutcome runLocalJobBatch(string filename, ulong expectedBytes,
        Document document, ref RuntimePlanV1 plan,
        scope LocalRootPlan planRoot, scope LocalRuntimeBatchV1 acceptBatch) {
    enforce(planRoot !is null && acceptBatch !is null,
        "local runtime batch callbacks are required");
    enforce(!isSymlink(filename), "refusing symlink input: " ~ filename);
    DocumentViewOwner owner;
    if (expectedBytes == 0) {
        scope input = File(filename, "rb");
        enforce(input.size == 0,
            "input changed size after admission: " ~ filename);
        owner = new DocumentViewOwner(new ubyte[0]);
    } else owner = openMappedFile(filename, expectedBytes);
    scope(exit) owner.close();
    auto content = new Content([ContentPiece.borrow(
        owner.view(0, cast(size_t) expectedBytes))]);
    auto inputHash = contentDigest(content);
    planRoot(inputHash);
    auto execution = runRuntimePlanV1(StageDocument(document, content), plan,
        null, filename);
    enforce(execution.events.length != 0,
        "compiled job produced no terminal decision");
    acceptBatch(execution, inputHash);
    LocalJobOutcome outcome;
    foreach (ref event; execution.events) final switch (event.kind) {
    case EventKind.emitted:
        ++outcome.emitted;
        if (event.isChild || contentDigest(event.payload.content) != inputHash)
            outcome.changed = true;
        break;
    case EventKind.rejected:
        ++outcome.rejected;
        if (!outcome.firstReason.length) outcome.firstReason = event.reason.idup;
        break;
    case EventKind.quarantined:
        ++outcome.quarantined;
        if (!outcome.firstReason.length) outcome.firstReason = event.reason.idup;
        break;
    }
    return outcome;
}

private final class LocalSource : Source {
    string filename;
    ulong expectedBytes;
    Document document;
    bool delivered;

    override bool next(out SourceRecord record) {
        if (delivered) return false;
        delivered = true;
        enforce(!isSymlink(filename), "refusing symlink input: " ~ filename);
        DocumentViewOwner owner;
        if (expectedBytes == 0) {
            scope input = File(filename, "rb");
            enforce(input.size == 0,
                "input changed size after admission: " ~ filename);
            owner = new DocumentViewOwner(new ubyte[0]);
        } else owner = openMappedFile(filename, expectedBytes);
        record = SourceRecord(document, owner);
        return true;
    }
}

private final class LocalParser : Parser {
    size_t expectedBytes;
    ubyte[32]* inputHash;

    override Content parse(SourceRecord record) {
        auto content = new Content([ContentPiece.borrow(
            record.owner.view(0, expectedBytes))]);
        *inputHash = contentDigest(content);
        return content;
    }
}

private ubyte[32] contentDigest(Content content) {
    SHA256 digest;
    content.stream((const(ubyte)[] chunk) { digest.put(chunk); });
    return digest.finish();
}

private final class LocalSink : Sink {
    LocalDestination destinationFor;
    LocalAdmission admit;
    LocalPublicationBegin begin;
    bool dryRun;
    bool began;
    LocalJobOutcome outcome;
    ubyte[32] inputHash;

    override void accept(StageEvent event) {
        if (!began) {
            begin();
            began = true;
        }
        final switch (event.kind) {
        case EventKind.emitted:
            auto destination = destinationFor(event);
            admit(destination, event);
            if (!dryRun)
                writeAtomicPieces(destination, event.payload.content.pieces());
            ++outcome.emitted;
            // A derived event is necessarily a new presentation. For a root
            // map, callers compare bytes separately when they need changed vs
            // unchanged; publishing remains exact in either case.
            if (event.isChild || contentDigest(event.payload.content) != inputHash)
                outcome.changed = true;
            break;
        case EventKind.rejected:
            ++outcome.rejected;
            if (!outcome.firstReason.length) outcome.firstReason = event.reason.idup;
            break;
        case EventKind.quarantined:
            ++outcome.quarantined;
            if (!outcome.firstReason.length) outcome.firstReason = event.reason.idup;
            break;
        }
    }
}

/// Run one admitted file through the shared compiled effects bridge. Destination
/// resolution/admission are synchronous and must not retain event content.
LocalJobOutcome runLocalJob(string filename, ulong expectedBytes,
        Document document, const ref CompiledJob job,
        scope LocalDestination destinationFor,
        scope LocalAdmission admit, scope LocalPublicationBegin begin,
        bool dryRun = false) {
    enforce(destinationFor !is null && admit !is null && begin !is null,
        "local destination callbacks are required");
    auto source = new LocalSource;
    source.filename = filename;
    source.expectedBytes = expectedBytes;
    source.document = document;
    auto sink = new LocalSink;
    sink.destinationFor = destinationFor;
    sink.admit = admit;
    sink.begin = begin;
    sink.dryRun = dryRun;
    auto parser = new LocalParser;
    parser.expectedBytes = cast(size_t) expectedBytes;
    parser.inputHash = &sink.inputHash;
    auto result = runEffects(source, parser, sink, job);
    enforce(result.completed == 1, "local compiled job did not complete its root");
    return sink.outcome;
}

LocalJobOutcome runLocalJob(string filename, ulong expectedBytes,
        Document document, ref RuntimePlanV1 plan,
        scope LocalDestination destinationFor,
        scope LocalAdmission admit, scope LocalPublicationBegin begin,
        scope LocalRuntimeBatchV1 observe = null, bool dryRun = false) {
    enforce(destinationFor !is null && admit !is null && begin !is null,
        "local destination callbacks are required");
    auto source = new LocalSource;
    source.filename = filename;
    source.expectedBytes = expectedBytes;
    source.document = document;
    auto sink = new LocalSink;
    sink.destinationFor = destinationFor;
    sink.admit = admit;
    sink.begin = begin;
    sink.dryRun = dryRun;
    auto parser = new LocalParser;
    parser.expectedBytes = cast(size_t) expectedBytes;
    parser.inputHash = &sink.inputHash;
    RuntimeExecutionV1 captured;
    bool hasCaptured;
    auto result = runEffects(source, parser, sink, plan,
        (ref RuntimeExecutionV1 execution) {
            captured = execution;
            hasCaptured = true;
        });
    enforce(result.completed == 1,
        "local runtime job did not complete its root");
    if (!sink.began) begin();
    if (observe !is null && hasCaptured) observe(captured, sink.inputHash);
    return sink.outcome;
}
