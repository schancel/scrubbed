/// Deterministic work proof for exact-size Content materialization.
/// Build with MaterializationWorkProbe and ContentStreamWorkProbe.
module benchmarks.content_materialize_work;

import content.pieces : Content, ContentCopyWorkV1, ContentPiece,
    ContentStreamWorkV1;
import domain.document : DocumentViewOwner;
import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;
import std.file : read, thisExePath;
import std.json : JSONValue;
import std.stdio : writeln;
import std.string : representation;

version (D_Optimized) {} else static assert(false,
    "content materialization evidence requires an optimized compiler build");
version (assert) static assert(false,
    "content materialization evidence requires -release");
version (MaterializationWorkProbe) {} else static assert(false,
    "content materialization evidence requires MaterializationWorkProbe");
version (ContentStreamWorkProbe) {} else static assert(false,
    "content materialization evidence requires ContentStreamWorkProbe");

private enum sourceBase = "c9c6937355bcdbbb7b68b416352ec9b939eff0ad";
private enum inputBytes = 4 * 1024 * 1024;
private enum chunkBytes = 8 * 1024;
private enum evidenceSourcePaths = [
    "source/domain/document.d",
    "source/content/pieces.d",
    "source/composition/executor.d",
    "source/effects/jsonl_job.d",
    "benchmarks/content_materialize_work.d"
];

private string embeddedSource(string path) pure {
    final switch (path) {
    case "source/domain/document.d":
        return import("source/domain/document.d");
    case "source/content/pieces.d":
        return import("source/content/pieces.d");
    case "source/composition/executor.d":
        return import("source/composition/executor.d");
    case "source/effects/jsonl_job.d":
        return import("source/effects/jsonl_job.d");
    case "benchmarks/content_materialize_work.d":
        return import("benchmarks/content_materialize_work.d");
    }
}

private string digestBytes(const(ubyte)[] bytes) {
    return toHexString!(LetterCase.lower)(sha256Of(bytes)).idup;
}

private string digestText(string source) {
    return digestBytes(source.representation);
}

private void need(bool okay, string message) {
    if (!okay) throw new Exception("content materialize work: " ~ message);
}

private void validateSourceIdentity() {
    foreach (path; evidenceSourcePaths)
        need(digestBytes(cast(const(ubyte)[])read(path)) ==
            digestText(embeddedSource(path)),
            "source changed after probe compilation: " ~ path);
}

private JSONValue measure() {
    auto input = new ubyte[inputBytes];
    foreach (index, ref value; input)
        value = cast(ubyte)((index * 131 + index / 251) & 0xff);
    auto owner = new DocumentViewOwner(input);
    auto content = new Content([
        ContentPiece.own(null),
        ContentPiece.borrow(owner.view(0, input.length / 3)),
        ContentPiece.own(cast(const(ubyte)[])input[
            input.length / 3 .. 2 * input.length / 3]),
        ContentPiece.borrow(owner.view(2 * input.length / 3,
            input.length - 2 * input.length / 3)),
        ContentPiece.own(null)
    ]);

    ContentStreamWorkV1 legacyStream;
    ubyte[] legacyOutput;
    ulong legacyAppendBytes;
    content.streamMeasured((const(ubyte)[] chunk) {
        legacyOutput ~= chunk;
        legacyAppendBytes += chunk.length;
    }, legacyStream, chunkBytes);

    ContentCopyWorkV1 exactWork;
    auto exactOutput = content.copyMeasured(exactWork);
    need(legacyOutput == input && exactOutput == legacyOutput,
        "legacy and exact-size output differ");
    need(legacyStream.copiedBytes == inputBytes &&
        legacyAppendBytes == inputBytes,
        "legacy two-copy accounting differs");
    need(exactWork.pieceChecks == 5 && exactWork.bulkCopyCalls == 3 &&
        exactWork.copiedBytes == inputBytes &&
        exactWork.allocations == 1 && exactWork.allocatedBytes == inputBytes,
        "exact-size copy accounting differs");

    owner.close;
    need(exactOutput == legacyOutput,
        "exact-size output did not outlive borrowed input");

    JSONValue root;
    root["schema"] = "scrubbed-content-materialize-work-v1";
    root["source_base"] = sourceBase;
    root["probe_binary_sha256"] = digestBytes(
        cast(const(ubyte)[])read(thisExePath));
    root["performance_claim_authorized"] = false;
    root["reason"] = "exact output and deterministic work account for removal of the intermediate stream-buffer copy; loaded-host timing is not a performance claim";
    root["input_bytes"] = JSONValue(cast(long)inputBytes);
    root["output_sha256"] = digestBytes(exactOutput);
    root["legacy_source_to_buffer_bytes"] = JSONValue(
        cast(long)legacyStream.copiedBytes);
    root["legacy_buffer_to_output_bytes"] = JSONValue(
        cast(long)legacyAppendBytes);
    root["exact_copy_calls"] = JSONValue(cast(long)exactWork.bulkCopyCalls);
    root["exact_copied_bytes"] = JSONValue(cast(long)exactWork.copiedBytes);
    root["exact_allocations"] = JSONValue(cast(long)exactWork.allocations);
    root["exact_allocated_bytes"] = JSONValue(
        cast(long)exactWork.allocatedBytes);
    JSONValue sources;
    foreach (path; evidenceSourcePaths)
        sources[path] = digestText(embeddedSource(path));
    root["source_sha256"] = sources;
    return root;
}

void main(string[] args) {
    need(args.length <= 2,
        "usage: content-materialize-work [--self-test]");
    if (args.length == 2)
        need(args[1] == "--self-test", "unknown option: " ~ args[1]);
    validateSourceIdentity;
    auto evidence = measure;
    if (args.length == 2) {
        writeln("content materialize work self-test passed");
        return;
    }
    writeln(evidence.toString);
}
