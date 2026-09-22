module structured_chunks.check;

import core.memory : GC;
import core.sys.posix.sys.resource : RUSAGE_SELF, getrusage, rusage;
import domain.document : DocumentId, SourceLocator;
import domain.structured_chunks : ChunkMetadata, SpanKind, StructuredSpan,
    chunkStructured, maxChunkBytes, maxStructuredTextBytes;
import effects.chunk_jsonl : decodeChunkJsonl, encodeChunkJsonl, maxChunkJsonlBytes;
import std.array : replicate;
import std.conv : to;
import std.file : thisExePath;
import std.process : execute;
import std.stdio : writeln;
import std.string : replace, split, strip;

private enum ulong structuredRssCeiling = 256UL * 1024 * 1024;

private void check(bool condition, string message) {
    if (!condition) throw new Exception(message);
}

private void rejects(void delegate() action, string message) {
    bool rejected;
    try action();
    catch (Exception) rejected = true;
    check(rejected, message);
}

private ulong peakRssBytes() {
    rusage usage;
    check(getrusage(RUSAGE_SELF, &usage) == 0, "RSS observation failed");
    version (OSX) return cast(ulong) usage.ru_opaque[0];
    else version (linux) return cast(ulong) usage.ru_maxrss * 1024;
    else static assert(0, "structured chunk RSS proof requires Darwin or Linux");
}

private void rssWorker(string mode) {
    auto id = DocumentId.from(SourceLocator("fixtures", "structured-rss", mode));
    size_t payloadBytes;
    size_t byteCap;
    final switch (mode) {
    case "max-payload":
        payloadBytes = maxStructuredTextBytes;
        byteCap = maxChunkBytes;
        break;
    case "max-chunks":
        payloadBytes = 65_536;
        byteCap = 1;
        break;
    }
    auto material = cast(immutable(char)[]) "x".replicate(payloadBytes);
    GC.collect();
    auto chunks = chunkStructured(id, "rss-v1", material,
        [StructuredSpan(SpanKind.paragraph, 0, material.length, [0])],
        ChunkMetadata.init, byteCap);
    ulong encodedBytes;
    size_t encodedRows;
    foreach (chunk; chunks) {
        encodedBytes += encodeChunkJsonl(chunk).length;
        ++encodedRows;
    }
    auto rss = peakRssBytes();
    check(rss <= structuredRssCeiling,
        "structured chunk RSS ceiling exceeded: " ~ rss.to!string);
    writeln(rss, " ", chunks.length, " ", encodedRows, " ", encodedBytes);
}

private ulong runRssWorker(string mode, size_t expectedChunks) {
    auto child = execute([thisExePath(), "--rss-worker", mode]);
    check(child.status == 0, mode ~ " RSS child failed: " ~ child.output);
    auto values = child.output.strip.split;
    check(values.length == 4, mode ~ " RSS child output shape");
    auto rss = values[0].to!ulong;
    check(values[1].to!size_t == expectedChunks &&
        values[2].to!size_t == expectedChunks && values[3].to!ulong != 0,
        mode ~ " RSS child did not exercise expected output");
    check(rss <= structuredRssCeiling, mode ~ " RSS exceeded parent ceiling");
    return rss;
}

void main(string[] args) {
    if (args.length == 3 && args[1] == "--rss-worker") {
        check(args[2] == "max-payload" || args[2] == "max-chunks",
            "unknown RSS worker mode");
        rssWorker(args[2]);
        return;
    }
    check(args.length == 1, "unexpected checker arguments");
    auto id = DocumentId.from(SourceLocator("fixtures", "structured", "one"));
    immutable text = "A\xc3\xa9\nB\xf0\x9f\x99\x82";
    auto spans = [
        StructuredSpan(SpanKind.section, 0, 9, [0],
            ChunkMetadata("en", "Section", "")),
        StructuredSpan(SpanKind.page, 0, 4, [0, 0],
            ChunkMetadata("", "", "page 1")),
        StructuredSpan(SpanKind.paragraph, 0, 4, [0, 0, 0],
            ChunkMetadata("", "Paragraph", "")),
        StructuredSpan(SpanKind.page, 4, 9, [0, 1],
            ChunkMetadata("", "", "page 2")),
        StructuredSpan(SpanKind.paragraph, 4, 9, [0, 1, 0],
            ChunkMetadata.init),
    ];
    auto chunks = chunkStructured(id, "rev-1", text, spans,
        ChunkMetadata("", "Root", "source"));
    check(chunks.length == 2 && chunks[0].start == 0 && chunks[0].end == 4 &&
        chunks[1].start == 4 && chunks[1].end == 9,
        "paragraph byte offsets");
    check(chunks[0].text == "A\xc3\xa9\n" && chunks[1].text == "B\xf0\x9f\x99\x82",
        "exact Unicode text");
    check(chunks[0].sectionPaths == [[0]] && chunks[0].pagePaths == [[0, 0]] &&
        chunks[1].pagePaths == [[0, 1]], "section/page ancestry");
    check(chunks[0].metadata.language == "en" &&
        chunks[0].metadata.title == "Paragraph" &&
        chunks[0].metadata.sourceLabel == "page 1" &&
        chunks[1].metadata.title == "Section" &&
        chunks[1].metadata.sourceLabel == "page 2",
        "typed metadata inheritance");
    check(chunks[0].documentId == id && chunks[0].id.text[0 .. 9] == "chunk:v1:",
        "source and chunk identity remain distinct");
    check(chunks[0].id.text ==
        "chunk:v1:5816d55c8feafed2e6c59b1ab01abd105a7317b1ada45458ce5c12de426d6d9a" &&
        chunks[1].id.text ==
        "chunk:v1:af8adc825f462c2947b857254ed7e024131f2b89d9f981275b54f8bb81f079b3",
        "versioned ID goldens");

    auto changed = chunkStructured(id, "rev-2", "A\xc3\xa9\nC\xf0\x9f\x99\x82", spans);
    check(changed[0].id == chunks[0].id && changed[1].id != chunks[1].id,
        "only changed exact chunk bytes invalidate ID");
    auto revisionOnly = chunkStructured(id, "rev-2", text, spans);
    check(revisionOnly[0].id == chunks[0].id, "revision does not change unchanged bytes ID");

    auto split = chunkStructured(id, "rev-3", "\xc3\xa9\xc3\xa9\xc3\xa9",
        [StructuredSpan(SpanKind.paragraph, 0, 6, [4], ChunkMetadata.init)],
        ChunkMetadata.init, 3);
    check(split.length == 3 && split[0].start == 0 && split[0].end == 2 &&
        split[1].start == 2 && split[1].end == 4 && split[2].end == 6 &&
        split[0].path == [4, 0] && split[1].path == [4, 1] &&
        split[0].id != split[1].id, "bounded UTF-8 split ordinals");
    rejects({ chunkStructured(id, "r", "\xc3\xa9",
        [StructuredSpan(SpanKind.paragraph, 0, 2, [0])],
        ChunkMetadata.init, 1); }, "scalar exceeding cap");
    rejects({ chunkStructured(id, "r", text,
        [StructuredSpan(SpanKind.paragraph, 0, 1, [0])]); }, "coverage gap");
    rejects({ chunkStructured(id, "r", text,
        [StructuredSpan(SpanKind.paragraph, 0, 2, [0]),
         StructuredSpan(SpanKind.paragraph, 2, 9, [1])]); }, "UTF-8 split offset");
    rejects({ chunkStructured(id, "r", text,
        [StructuredSpan(SpanKind.paragraph, 0, 4, [0]),
         StructuredSpan(SpanKind.paragraph, 3, 9, [1])]); }, "overlap");
    rejects({ chunkStructured(id, "r", text,
        [StructuredSpan(SpanKind.paragraph, 0, 4, [0]),
         StructuredSpan(SpanKind.paragraph, 4, 9, [0])]); }, "duplicate path");
    rejects({ chunkStructured(id, "r", text,
        [StructuredSpan(SpanKind.paragraph, 0, 4, [1]),
         StructuredSpan(SpanKind.paragraph, 4, 9, [0])]); }, "unordered path");
    rejects({ chunkStructured(id, "r", text,
        [StructuredSpan(SpanKind.page, 0, 9, [0]),
         StructuredSpan(SpanKind.paragraph, 0, 9, [1])]); }, "invalid nesting");
    rejects({ chunkStructured(id, "r", text,
        [StructuredSpan(SpanKind.paragraph, 0, 10, [0])]); }, "out of range");

    auto row = encodeChunkJsonl(chunks[0]);
    enum prefix = "{\"schema\":\"structured-chunk:v1\",\"version\":1,";
    check(row.length <= maxChunkJsonlBytes &&
        row[0 .. prefix.length] == prefix,
        "canonical schema header");
    auto expected = prefix ~ "\"document_id\":\"" ~ id.text ~
        "\",\"content_revision\":\"rev-1\",\"chunk_id\":\"" ~ chunks[0].id.text ~
        "\",\"start\":0,\"end\":4,\"path\":[0,0,0,0]," ~
        "\"section_paths\":[[0]],\"page_paths\":[[0,0]]," ~
        "\"metadata\":{\"language\":\"en\",\"title\":\"Paragraph\"," ~
        "\"source_label\":\"page 1\"},\"text\":\"A\xc3\xa9\\n\"}\n";
    check(row == expected, "canonical JSONL golden");
    auto decoded = decodeChunkJsonl(row);
    check(encodeChunkJsonl(decoded) == row && decoded.id == chunks[0].id &&
        decoded.metadata.title == "Paragraph", "JSONL round trip");
    rejects({ decodeChunkJsonl(" " ~ row); }, "noncanonical whitespace");
    rejects({ decodeChunkJsonl(row[0 .. $ - 1]); }, "missing LF");
    rejects({ decodeChunkJsonl(row[0 .. $ - 1] ~ " "); }, "noncanonical terminator");
    rejects({ decodeChunkJsonl(row[0 .. $ - 2] ~ ",\"extra\":0}\n"); },
        "unknown field");
    rejects({ decodeChunkJsonl(row.replace(chunks[0].id.text, chunks[1].id.text)); },
        "wrong chunk digest");
    auto hostileDepth = "[".replicate(8_000) ~ "0" ~ "]".replicate(8_000) ~ "\n";
    rejects({ decodeChunkJsonl(hostileDepth); },
        "deeply nested bounded-size JSON must reject without stack exhaustion");

    // A material payload is intentionally much larger than one row.
    auto material = "x".replicate(maxChunkBytes * 64);
    auto bulk = chunkStructured(id, "bulk", material,
        [StructuredSpan(SpanKind.paragraph, 0, material.length, [8])]);
    check(bulk.length == 64, "material payload split count");
    foreach (part; bulk)
        check(part.text.length <= maxChunkBytes &&
            encodeChunkJsonl(part).length <= maxChunkJsonlBytes,
            "bounded record payload");
    auto payloadRss = runRssWorker("max-payload",
        maxStructuredTextBytes / maxChunkBytes);
    auto chunksRss = runRssWorker("max-chunks", 65_536);
    writeln("structured chunks: hierarchy, Unicode, identity, rejection, JSONL, " ~
        "process-isolated max payload/chunks RSS passed (", payloadRss, ", ",
        chunksRss, " bytes; ceiling ", structuredRssCeiling, ")");
}
