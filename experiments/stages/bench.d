module experiments.stages.bench;

import content.pieces : Content, ContentPiece;
import core.memory : GC;
import domain.document : Document, DocumentViewOwner, OutputName, SourceLocator;
import stages.contract : PassMode, ResourceDeclaration, StageDeclaration,
    StageDecision, StageDocument, runStage;
import std.conv : to;
import std.datetime.stopwatch : StopWatch;
import std.stdio : writeln;

void main(string[] args) {
    enum inputSize = 1024 * 1024;
    auto editCount = args.length > 1 ? args[1].to!size_t : 2000;
    auto source = new ubyte[inputSize];
    foreach (i; 0 .. source.length) source[i] = cast(ubyte) ('a' + i % 26);
    auto expected = source.dup;
    auto owner = new DocumentViewOwner(source);
    scope (exit) owner.close();
    auto content = new Content([ContentPiece.borrow(owner.view(0, source.length))]);
    auto input = StageDocument(
        Document(SourceLocator("experiment", "list-edit", "record"), OutputName("record")),
        content);
    auto stage = StageDeclaration("edit", PassMode.singlePass,
        ResourceDeclaration(1, inputSize * 2));

    auto before = GC.stats().usedSize;
    StopWatch timer;
    timer.start();
    auto result = runStage([input], stage, (StageDocument document) {
        foreach (i; 0 .. editCount) {
            auto position = (i * 1009 + 17) % inputSize;
            auto value = cast(ubyte) ('A' + i % 26);
            document.content.replace(position, 1, [ContentPiece.own([value])]);
            expected[position] = value;
        }
        return StageDecision.map(document);
    });
    timer.stop();
    auto after = GC.stats().usedSize;

    assert(result.processed == 1 && result.events.length == 1);
    assert(result.events[0].payload.document.id == input.document.id);
    ubyte[] actual;
    result.events[0].payload.content.stream((const(ubyte)[] chunk) {
        actual ~= chunk;
    });
    assert(actual == expected, "wired list-edit output differs from direct byte edits");
    writeln("edits=", editCount, " bytes=", inputSize,
        " output_equivalent=true wall_ms=", timer.peek.total!"msecs",
        " gc_used_delta_bytes=", cast(long) after - cast(long) before,
        " gc_used_after_bytes=", after);
}
