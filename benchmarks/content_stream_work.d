/// Deterministic work proof for bounded bulk Content streaming.
/// Build with -version=ContentStreamWorkProbe.
module benchmarks.content_stream_work;

import content.pieces : Content, ContentPiece, ContentStreamWorkV1;
import domain.document : DocumentViewOwner;
import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;
import std.exception : enforce;
import std.file : read, thisExePath;
import std.json : JSONValue;
import std.stdio : writeln;
import std.string : representation;

version (D_Optimized) {} else static assert(false,
    "content stream evidence requires an optimized compiler build");
version (assert) static assert(false,
    "content stream evidence requires -release");
version (ContentStreamWorkProbe) {} else static assert(false,
    "content stream evidence requires ContentStreamWorkProbe");

private enum sourceBase = "8813e0fbc74da11c35a46115934e42aef1bb09d0";
private enum inputBytes = 4 * 1024 * 1024;
private enum chunkBytes = 8 * 1024;
private enum evidenceSourcePaths = [
    "source/domain/document.d",
    "source/content/pieces.d",
    "benchmarks/content_stream_work.d"
];

private struct LegacyStreamWorkV1 {
    ulong pieceChecks;
    ulong scalarReads;
    ulong emittedChunks;
    ulong emittedBytes;
    size_t bufferBytes;
}

private string embeddedSource(string path) pure {
    final switch (path) {
    case "source/domain/document.d":
        return import("source/domain/document.d");
    case "source/content/pieces.d":
        return import("source/content/pieces.d");
    case "benchmarks/content_stream_work.d":
        return import("benchmarks/content_stream_work.d");
    }
}

private string digestBytes(const(ubyte)[] bytes) {
    return toHexString!(LetterCase.lower)(sha256Of(bytes)).idup;
}

private string digestText(string source) {
    return digestBytes(source.representation);
}

private void need(bool okay, string message) {
    if (!okay) throw new Exception("content stream work: " ~ message);
}

private void validateSourceIdentity() {
    foreach (path; evidenceSourcePaths)
        need(digestBytes(cast(const(ubyte)[])read(path)) ==
            digestText(embeddedSource(path)),
            "source changed after probe compilation: " ~ path);
}

/// Exact reference for the pre-change scalar stream loop at `sourceBase`.
private void legacyStream(Content content,
        scope void delegate(const(ubyte)[]) pure sink,
        ref LegacyStreamWorkV1 work, size_t chunkSize) {
    enforce(chunkSize != 0, "stream chunk size must be positive");
    auto buffer = new ubyte[chunkSize];
    work.bufferBytes = chunkSize;
    size_t filled;
    foreach (_, piece; content) {
        auto pieceSize = piece.size;
        ++work.pieceChecks;
        foreach (index; 0 .. pieceSize) {
            buffer[filled++] = piece.at(index);
            ++work.scalarReads;
            if (filled == chunkSize) {
                sink(buffer[]);
                ++work.emittedChunks;
                work.emittedBytes += filled;
                filled = 0;
            }
        }
    }
    if (filled) {
        sink(buffer[0 .. filled]);
        ++work.emittedChunks;
        work.emittedBytes += filled;
    }
}

private JSONValue measure() {
    auto input = new ubyte[inputBytes];
    foreach (index, ref value; input)
        value = cast(ubyte)((index * 131 + index / 251) & 0xff);
    auto owner = new DocumentViewOwner(input);
    auto content = new Content([
        ContentPiece.own(null),
        ContentPiece.borrow(owner.view(0, input.length)),
        ContentPiece.own(null)
    ]);

    LegacyStreamWorkV1 legacyWork;
    ubyte[] legacyOutput;
    legacyStream(content,
        (const(ubyte)[] chunk) { legacyOutput ~= chunk; },
        legacyWork, chunkBytes);

    ContentStreamWorkV1 bulkWork;
    ubyte[] bulkOutput;
    content.streamMeasured(
        (const(ubyte)[] chunk) { bulkOutput ~= chunk; },
        bulkWork, chunkBytes);

    need(legacyOutput == input && bulkOutput == legacyOutput,
        "legacy and bulk output differ");
    need(legacyWork.pieceChecks == 3 && bulkWork.pieceChecks == 3,
        "piece accounting differs");
    need(legacyWork.scalarReads == inputBytes,
        "legacy scalar-read accounting differs");
    need(bulkWork.bulkCopyCalls == inputBytes / chunkBytes &&
        bulkWork.copiedBytes == inputBytes,
        "bulk-copy accounting differs");
    need(legacyWork.emittedChunks == inputBytes / chunkBytes &&
        bulkWork.emittedChunks == legacyWork.emittedChunks &&
        legacyWork.emittedBytes == inputBytes &&
        bulkWork.emittedBytes == inputBytes,
        "emission accounting differs");
    need(legacyWork.bufferBytes == chunkBytes &&
        bulkWork.bufferBytes == chunkBytes,
        "buffer bound differs");

    owner.close;
    need(bulkOutput == legacyOutput,
        "bulk output did not outlive borrowed input");

    JSONValue root;
    root["schema"] = "scrubbed-content-stream-work-v1";
    root["source_base"] = sourceBase;
    root["probe_binary_sha256"] = digestBytes(
        cast(const(ubyte)[])read(thisExePath));
    root["performance_claim_authorized"] = false;
    root["reason"] = "exact output and bounded work prove replacement of per-byte checked reads with checked bulk transfers; loaded-host timing is not a performance claim";
    root["input_bytes"] = JSONValue(cast(long)inputBytes);
    root["chunk_bytes"] = JSONValue(cast(long)chunkBytes);
    root["output_sha256"] = digestBytes(bulkOutput);
    root["legacy_scalar_reads"] = JSONValue(cast(long)legacyWork.scalarReads);
    root["bulk_copy_calls"] = JSONValue(cast(long)bulkWork.bulkCopyCalls);
    root["bulk_copied_bytes"] = JSONValue(cast(long)bulkWork.copiedBytes);
    root["emitted_chunks"] = JSONValue(cast(long)bulkWork.emittedChunks);
    root["buffer_bytes"] = JSONValue(cast(long)bulkWork.bufferBytes);
    JSONValue sources;
    foreach (path; evidenceSourcePaths)
        sources[path] = digestText(embeddedSource(path));
    root["source_sha256"] = sources;
    return root;
}

void main(string[] args) {
    need(args.length <= 2, "usage: content-stream-work [--self-test]");
    if (args.length == 2)
        need(args[1] == "--self-test", "unknown option: " ~ args[1]);
    validateSourceIdentity;
    auto evidence = measure;
    if (args.length == 2) {
        writeln("content stream work self-test passed");
        return;
    }
    writeln(evidence.toString);
}
