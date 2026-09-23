module stages.contract;

import content.pieces : Content;
import domain.document : Document, DocumentId, OutputName, SourceLocator;
import std.conv : to;
import std.exception : enforce;
import std.range.primitives : empty, front, isInputRange, popFront;
import std.string : indexOf;
import std.utf : validate;

/// Payload flowing through a document-range stage. Content retains its own
/// borrowed/owned lifetime rules; a stage does not extend a view owner.
struct StageDocument {
    Document document;
    Content content;
}

enum PassMode { singlePass, resumable }

/// Descriptive admission needs, not a reservation or scheduling instruction.
struct ResourceDeclaration {
    uint cpuSlots;
    size_t memoryBytes;
    string[] exclusiveNames;

    this(uint cpuSlots, size_t memoryBytes, string[] exclusiveNames = null) {
        enforce(cpuSlots > 0, "stage requires at least one CPU slot");
        foreach (i, name; exclusiveNames) {
            enforce(name.length != 0, "resource name must not be empty");
            validate(name);
            enforce(name.indexOf('\0') < 0, "resource name must not contain NUL");
            foreach (prior; exclusiveNames[0 .. i])
                enforce(name != prior, "duplicate exclusive resource name");
        }
        this.cpuSlots = cpuSlots;
        this.memoryBytes = memoryBytes;
        this.exclusiveNames = exclusiveNames.dup;
    }
}

/// Resumable means a caller may replay from the next fully committed input;
/// it promises neither a checkpoint store nor rollback of external effects.
struct StageDeclaration {
    string key;
    PassMode passMode;
    ResourceDeclaration resources;

    this(string key, PassMode passMode, ResourceDeclaration resources) {
        enforce(key.length != 0, "stage key must not be empty");
        validate(key);
        enforce(key.indexOf('\0') < 0, "stage key must not contain NUL");
        enforce(passMode == PassMode.singlePass || passMode == PassMode.resumable,
            "invalid pass mode");
        enforce(resources.cpuSlots > 0, "invalid resource declaration");
        this.key = key;
        this.passMode = passMode;
        this.resources = resources;
    }
}

enum DecisionKind { map, reject, quarantine, split }

/// One complete decision for one input. Empty splits are invalid: discarding
/// an input must be an explicit rejection or quarantine.
struct StageDecision {
    private DecisionKind decisionKind;
    private StageDocument[] output;
    private string explanation;

    static StageDecision map(StageDocument output) pure {
        return StageDecision(DecisionKind.map, [output], null);
    }
    static StageDecision reject(string reason) pure {
        enforce(reason.length != 0, "rejection needs a reason");
        return StageDecision(DecisionKind.reject, null, reason);
    }
    static StageDecision quarantine(string reason) pure {
        enforce(reason.length != 0, "quarantine needs a reason");
        return StageDecision(DecisionKind.quarantine, null, reason);
    }
    static StageDecision split(StageDocument[] children) pure {
        enforce(children.length > 0, "split needs children");
        return StageDecision(DecisionKind.split, children.dup, null);
    }
    DecisionKind kind() const { return decisionKind; }
    string reason() const { return explanation; }
    private StageDocument[] documents() { return output; }
}

enum EventKind { emitted, rejected, quarantined }

/// Events are in input order; split children occupy the parent's slot in
/// increasing ordinal order. Parent and ordinal are set only for children.
struct StageEvent {
    EventKind kind;
    StageDocument payload;
    string reason;
    DocumentId parentId;
    size_t childOrdinal;
    bool isChild;
}

struct StageResult {
    StageEvent[] events;
    size_t processed;
    bool cancelled;
}

alias StageTransform = StageDecision delegate(StageDocument input);
alias CancellationCheck = bool delegate();

private DocumentId checkedDocument(Document document) {
    auto id = document.id;
    // Document.id validates only the locator; a default OutputName is invalid.
    enforce(document.outputName.text.length != 0, "document output name is not initialized");
    return id;
}

/// A cancellation check occurs before each input and after committing its
/// complete decision. If cancellation is noticed afterward, its events stay
/// visible and the next input is not visited. No sink rollback is implied.
StageResult runStage(R)(R inputs, StageDeclaration stage,
    scope StageTransform transform, scope CancellationCheck isCancelled = null) {
    static assert(isInputRange!R, "stage inputs must be an InputRange");
    enforce(transform !is null, "stage transform is required");
    stage = StageDeclaration(stage.key, stage.passMode,
        ResourceDeclaration(stage.resources.cpuSlots, stage.resources.memoryBytes,
            stage.resources.exclusiveNames));
    StageResult result;
    for (auto pending = inputs; !pending.empty; pending.popFront()) {
        if (isCancelled !is null && isCancelled()) {
            result.cancelled = true;
            break;
        }
        auto input = pending.front;
        // Validate identity and content before calling user stage code.
        auto inputId = checkedDocument(input.document);
        enforce(input.content !is null, "stage input content is required");
        input.content.size;
        auto decision = transform(input);
        final switch (decision.kind) {
        case DecisionKind.map:
            enforce(decision.documents.length == 1, "map requires one document");
            auto mapped = decision.documents[0];
            enforce(mapped.content !is null && checkedDocument(mapped.document) == inputId,
                "map must preserve document identity and provide content");
            mapped.content.size;
            result.events ~= StageEvent(EventKind.emitted, mapped);
            break;
        case DecisionKind.reject:
            enforce(decision.reason.length != 0, "rejection needs a reason");
            result.events ~= StageEvent(EventKind.rejected, input, decision.reason);
            break;
        case DecisionKind.quarantine:
            enforce(decision.reason.length != 0, "quarantine needs a reason");
            result.events ~= StageEvent(EventKind.quarantined, input, decision.reason);
            break;
        case DecisionKind.split:
            enforce(decision.documents.length > 0, "split needs children");
            foreach (ordinal, child; decision.documents) {
                enforce(child.content !is null, "split child content is required");
                child.content.size;
                child.document = Document.derivedChild(input.document, stage.key,
                    ordinal, child.document.outputName);
                checkedDocument(child.document);
                result.events ~= StageEvent(EventKind.emitted, child, null,
                    inputId, ordinal, true);
            }
            break;
        }
        ++result.processed;
        if (isCancelled !is null && isCancelled()) {
            result.cancelled = true;
            break;
        }
    }
    return result;
}

unittest {
    import content.pieces : ContentPiece;
    import std.algorithm.iteration : map;
    import std.exception : assertThrown;

    auto resources = ResourceDeclaration(2, 4096, ["gpu", "scratch"]);
    auto stage = StageDeclaration("tokenize", PassMode.resumable, resources);
    assert(stage.passMode == PassMode.resumable && stage.resources.cpuSlots == 2);
    assertThrown(ResourceDeclaration(0, 0));
    assertThrown(ResourceDeclaration(1, 0, ["x", "x"]));
    assertThrown(ResourceDeclaration(1, 0, ["x\0y"]));
    assertThrown(StageDeclaration("", PassMode.singlePass, resources));
    assertThrown(StageDeclaration("x\0y", PassMode.singlePass, resources));
    assertThrown(StageDeclaration("x", cast(PassMode) 9, resources));
    assertThrown(StageDecision.reject(""));
    assertThrown(StageDecision.quarantine(""));
    assertThrown(StageDecision.split(null));

    StageDocument[] inputs;
    foreach (i; 0 .. 3) {
        auto doc = Document(SourceLocator("test", "source", i.to!string), OutputName("out"));
        inputs ~= StageDocument(doc, new Content([ContentPiece.own(cast(const(ubyte)[]) "abc")]));
    }
    auto mapped = runStage(inputs.map!(input => input), stage, (StageDocument input) {
        return StageDecision.map(input);
    });
    assert(mapped.processed == 3 && mapped.events.length == 3 && !mapped.cancelled);
    foreach (i, event; mapped.events)
        assert(event.kind == EventKind.emitted && event.payload.document.id == inputs[i].document.id);
    bool visitedInvalidInput;
    auto invalidInput = inputs[0];
    invalidInput.document.outputName = OutputName.init;
    assertThrown(runStage([invalidInput], stage, (StageDocument input) {
        visitedInvalidInput = true;
        return StageDecision.map(input);
    }));
    assert(!visitedInvalidInput);
    assertThrown(runStage(inputs[0 .. 1], stage, (StageDocument input) {
        auto invalidMap = input;
        invalidMap.document.outputName = OutputName.init;
        return StageDecision.map(invalidMap);
    }));
    assertThrown(runStage(inputs[0 .. 1], stage, (StageDocument input) {
        auto invalidChild = input;
        invalidChild.document.outputName = OutputName.init;
        return StageDecision.split([invalidChild]);
    }));

    auto decisions = runStage(inputs, stage, (StageDocument input) {
        if (input.document.id == inputs[0].document.id) return StageDecision.reject("bad");
        if (input.document.id == inputs[1].document.id) return StageDecision.quarantine("review");
        return StageDecision.split([
            StageDocument(Document(input.document.source, OutputName("first")), input.content),
            StageDocument(Document(input.document.source, OutputName("second")), input.content)
        ]);
    });
    assert(decisions.processed == 3 && decisions.events.length == 4);
    assert(decisions.events[0].kind == EventKind.rejected && decisions.events[0].reason == "bad");
    assert(decisions.events[1].kind == EventKind.quarantined && decisions.events[1].reason == "review");
    assert(decisions.events[2].isChild && decisions.events[2].childOrdinal == 0);
    assert(decisions.events[3].isChild && decisions.events[3].childOrdinal == 1);
    assert(decisions.events[2].parentId == inputs[2].document.id);
    assert(decisions.events[2].payload.document.id != decisions.events[3].payload.document.id);
    auto repeated = runStage(inputs[2 .. 3], stage, (StageDocument input) {
        return StageDecision.split([
            StageDocument(Document(input.document.source, OutputName("first")), input.content),
            StageDocument(Document(input.document.source, OutputName("second")), input.content)
        ]);
    });
    assert(repeated.events[0].payload.document.id == decisions.events[2].payload.document.id);
    assert(repeated.events[1].payload.document.id == decisions.events[3].payload.document.id);
    auto oldTuple = "stage-child:v1:" ~ inputs[2].document.id.text ~
        ":" ~ stage.key ~ ":0";
    auto adversarial = Document(SourceLocator("test", "source", oldTuple),
        OutputName("original source"));
    assert(adversarial.id != decisions.events[2].payload.document.id);
    assert(adversarial.id.text[0 .. "doc:v1:".length] == "doc:v1:");
    assert(decisions.events[2].payload.document.id.text[0 .. "child:v1:".length] ==
        "child:v1:");
    auto renamedChildren = runStage(inputs[2 .. 3], stage, (StageDocument input) {
        return StageDecision.split([
            StageDocument(Document(input.document.source, OutputName("renamed first")),
                input.content),
            StageDocument(Document(input.document.source, OutputName("renamed second")),
                input.content)
        ]);
    });
    assert(renamedChildren.events[0].payload.document.id ==
        decisions.events[2].payload.document.id);
    assert(renamedChildren.events[1].payload.document.id ==
        decisions.events[3].payload.document.id);
    auto parentChild = decisions.events[2].payload;
    auto nested = runStage([parentChild], stage, (StageDocument input) {
        return StageDecision.split([
            StageDocument(Document(input.document.source, OutputName("nested")),
                input.content)
        ]);
    });
    assert(nested.events.length == 1 && nested.events[0].isChild);
    assert(nested.events[0].parentId == parentChild.document.id);
    assert(nested.events[0].payload.document.id ==
        Document.derivedChild(parentChild.document, stage.key, 0,
            OutputName("other nested name")).id);
    assert(nested.events[0].payload.document.id != parentChild.document.id);
    assertThrown(runStage(inputs[0 .. 1], stage, (StageDocument input) {
        auto changed = input;
        changed.document = inputs[1].document;
        return StageDecision.map(changed);
    }));

    size_t checks;
    auto before = runStage(inputs, stage, (StageDocument input) {
        assert(false, "must not run after cancellation");
        return StageDecision.map(input);
    }, () { return ++checks == 1; });
    assert(before.cancelled && before.processed == 0 && before.events.length == 0);
    struct ThrowingFront {
        bool* accessed;
        @property bool empty() { return false; }
        @property StageDocument front() {
            *accessed = true;
            throw new Exception("front evaluated before cancellation");
        }
        void popFront() {}
    }
    bool accessed;
    checks = 0;
    auto lazyBefore = runStage(ThrowingFront(&accessed), stage,
        (StageDocument input) { return StageDecision.map(input); },
        () { ++checks; return true; });
    assert(lazyBefore.cancelled && lazyBefore.processed == 0 &&
        lazyBefore.events.length == 0 && checks == 1 && !accessed);
    checks = 0;
    auto after = runStage(inputs, stage, (StageDocument input) {
        return StageDecision.map(input);
    }, () { return ++checks == 2; });
    assert(after.cancelled && after.processed == 1 && after.events.length == 1);
    auto invalid = stage;
    invalid.resources.cpuSlots = 0;
    assertThrown(runStage(inputs, invalid, (StageDocument input) {
        return StageDecision.map(input);
    }));
}
