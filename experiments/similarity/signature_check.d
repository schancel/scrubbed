module similarity.signature_check;

import domain.document : DocumentId, SourceLocator;
import domain.similarity_signature;
import std.exception : assertThrown;
import std.stdio : writeln;

private DocumentId id(string record) {
    return DocumentId.from(SourceLocator("similarity-check", "fixture", record));
}

private bool sharesBand(const SimilaritySignature a, const SimilaritySignature b) {
    if (!a.hasKeys || !b.hasKeys) return false;
    foreach (key; a.bands) foreach (other; b.bands) if (key == other) return true;
    return false;
}

private ulong vectorDigest(const SimilaritySignature value) {
    ulong hash = 0xcbf29ce484222325UL;
    foreach (number; value.lanes) {
        ulong little = number;
        foreach (_; 0 .. 8) { hash = (hash ^ cast(ubyte) little) * 0x100000001b3UL; little >>= 8; }
    }
    foreach (number; value.bands) {
        ulong little = number;
        foreach (_; 0 .. 8) { hash = (hash ^ cast(ubyte) little) * 0x100000001b3UL; little >>= 8; }
    }
    return hash;
}

void main() {
    auto vector = similaritySignatures(id("vector"), cast(const(ubyte)[]) "ABCDE abcde");
    assert(vector.document.lanes[0] == 1460517101408883136UL);
    assert(vector.document.lanes[63] == 1932892404006057359UL);
    assert(vector.document.bands[0] == 11815277551846556947UL);
    assert(vector.document.bands[15] == 11562072951552938369UL);
    assert(vectorDigest(vector.document) == 4255929734725147412UL);
    assert(vector.document.profileVersion == signatureVersion);
    assert(vector.document.hasKeys && vector.segments.length == 1);
    assert(vector.document.lanes == vector.segments[0].lanes);

    auto a = similaritySignatures(id("a"), cast(const(ubyte)[])
        "The quick brown fox jumps over the lazy dog. A consistent related text.");
    auto b = similaritySignatures(id("b"), cast(const(ubyte)[])
        "The quick brown fox jumps over the lazy dog! A consistent related text.");
    auto control = similaritySignatures(id("control"), cast(const(ubyte)[])
        "Numbers 0123456789 and symbols xxxxxx do not describe that animal.");
    assert(sharesBand(a.document, b.document));
    writeln("authored unrelated control shared band: ", sharesBand(a.document, control.document));
    assert(a.document.lanes == similaritySignatures(id("a"), cast(const(ubyte)[])
        "The quick brown fox jumps over the lazy dog. A consistent related text.").document.lanes);
    // Independent calls in a different input order cannot affect the vector.
    auto reverseFirst = similaritySignatures(id("control"), cast(const(ubyte)[])
        "Numbers 0123456789 and symbols xxxxxx do not describe that animal.");
    assert(reverseFirst.document.lanes == control.document.lanes);
    assert(vectorDigest(similaritySignatures(id("vector"),
        cast(const(ubyte)[]) "ABCDE abcde").document) == 4255929734725147412UL);

    auto unicode = similaritySignatures(id("unicode"), cast(const(ubyte)[]) "É é E e");
    assert(unicode.document.hasKeys);
    assert(!similaritySignatures(id("short"), cast(const(ubyte)[]) "é").document.hasKeys);
    bool fixedReason;
    try similaritySignatures(id("bad"), [cast(ubyte) 0xc3]);
    catch (Exception error) fixedReason = error.msg == "similarity signature: invalid UTF-8";
    assert(fixedReason);
    assertThrown!Exception(similaritySignatures(id("large"),
        new ubyte[maxSimilarityInputBytes + 1]));

    ubyte[] edge = new ubyte[4095];
    edge[] = 'a';
    edge ~= cast(const(ubyte)[]) "ébcde";
    auto segmented = similaritySignatures(id("edge"), edge);
    assert(edge[4095] == 0xc3 && edge[4096] == 0xa9);
    assert(segmented.segments.length == 2);
    assert(segmented.segments[0].hasKeys && segmented.segments[1].hasKeys);
    assert(segmented.segments[0].segmentOrdinal == 0 &&
        segmented.segments[1].segmentOrdinal == 1);
    assert(segmented.document.documentId == segmented.segments[1].documentId);
    auto exactCap = new ubyte[maxSimilarityInputBytes];
    exactCap[] = 'x';
    assert(similaritySignatures(id("cap"), exactCap).document.hasKeys);
    auto boundary = new ubyte[similaritySegmentBytes];
    boundary[] = 'x';
    assert(similaritySignatures(id("boundary"), boundary).segments.length == 1);
    writeln("similarity signature checker passed");
}
