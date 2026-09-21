/// Explicit stdio binding for the standalone synchronous JSONL adapter.
module effects.stdio_stream;

import effects.jsonl_stream : JsonlLimits, TextTransform, processJsonl;
import std.stdio : File, stdin, stdout;

/// File handles stay caller-owned. Flush each record before admitting the next.
size_t processFileJsonl(ref File input, ref File output, string datasetNamespace,
    string sourceKey, const(string)[] fields, TextTransform transform,
    JsonlLimits limits) {
    return processJsonl(
        (ubyte[] buffer) => input.rawRead(buffer).length,
        (const(ubyte)[] bytes) { output.rawWrite(bytes); output.flush(); },
        datasetNamespace, sourceKey, fields, transform, limits);
}

/// Caller chooses the stable source key; this does not expose CLI flags.
size_t processStandardJsonl(string datasetNamespace, string sourceKey,
    const(string)[] fields, TextTransform transform, JsonlLimits limits) {
    return processFileJsonl(stdin, stdout, datasetNamespace, sourceKey,
        fields, transform, limits);
}
