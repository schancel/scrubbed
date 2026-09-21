/// Typed effect ports and the single-document composition root. Adapters own
/// their resources; no port implies persistence, rollback, or scheduling.
module effects.runner;

import content.pieces : Content;
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

enum EffectPhase { source, parser, stage, sink }

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
}

struct RunResult {
    size_t completed;
    size_t eventsAccepted;
    bool cancelled;
}

/// One input decision is fully delivered before fetching another. This is not
/// transactional: a throwing sink can leave an uncertain accepted prefix.
RunResult runEffects(Source source, Parser parser, Sink sink,
    StageDeclaration stage, scope StageTransform transform,
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
        scope(exit) if (record.owner !is null) record.owner.close();
        DocumentId id;
        try {
            enforce(record.owner !is null, "source record owner is required");
            id = record.document.id;
        }
        catch (Exception error)
            throw new EffectFailure(EffectPhase.source, result.completed, 0,
                DocumentId.init, false, error);
        if (isCancelled !is null && isCancelled()) {
            result.cancelled = true;
            return result;
        }
        Content content;
        try content = parser.parse(record);
        catch (Exception error)
            throw new EffectFailure(EffectPhase.parser, result.completed, 0,
                id, false, error);
        if (isCancelled !is null && isCancelled()) {
            result.cancelled = true;
            return result;
        }
        import stages.contract : StageResult;
        StageResult decision;
        try decision = runStage([StageDocument(record.document, content)], stage, transform);
        catch (Exception error)
            throw new EffectFailure(EffectPhase.stage, result.completed, 0,
                id, false, error);
        foreach (ordinal, event; decision.events) {
            try sink.accept(event);
            catch (Exception error)
                throw new EffectFailure(EffectPhase.sink, result.completed, ordinal,
                    id, true, error);
            ++result.eventsAccepted;
        }
        ++result.completed;
        // Cancellation after commitment is tested at the top of the loop,
        // before source.next can evaluate the next lazy input.
    }
}
