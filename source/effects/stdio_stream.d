/// Explicit stdio binding for the standalone synchronous JSONL adapter.
module effects.stdio_stream;

import effects.jsonl_stream : DocumentCommit, DocumentTransform, JsonlLimits,
    TextTransform, processJsonl, processJsonlDocuments;
import std.conv : to;
import std.stdio : File, stdin, stdout;

private size_t readStandard(ubyte[] buffer) {
    version (Posix) {
        import core.stdc.errno : EINTR, errno;
        import core.sys.posix.unistd : read;
        // fread/rawRead tries to fill its entire request on a live pipe.
        // A single POSIX read returns the currently available bytes so one
        // complete record can be emitted before the producer closes stdin.
        for (;;) {
            auto count = read(stdin.fileno, buffer.ptr, buffer.length);
            if (count >= 0) return cast(size_t) count;
            if (errno() != EINTR)
                throw new Exception("JSONL stdin read failed, errno " ~ errno().to!string);
        }
    } else {
        // A one-byte request does not wait for a full 4096-byte pipe chunk.
        return stdin.rawRead(buffer[0 .. 1]).length;
    }
}

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
    const(string)[] fields, TextTransform transform, JsonlLimits limits,
    bool dryRun = false) {
    // A closed stdout consumer must become a JsonlFailure(writer), not kill
    // the process with SIGPIPE before the completed-prefix report is emitted.
    version (Posix) {
        import core.stdc.signal : SIG_IGN, signal;
        import core.sys.posix.signal : SIGPIPE;
        // Keep it ignored through process exit: restoring the default while
        // a broken-pipe signal is pending can terminate us after reporting.
        signal(SIGPIPE, SIG_IGN);
    }
    return processJsonl(
        (ubyte[] buffer) => readStandard(buffer),
        (const(ubyte)[] bytes) {
            if (!dryRun) { stdout.rawWrite(bytes); stdout.flush(); }
        },
        datasetNamespace, sourceKey, fields, transform, limits);
}

/// Typed-document variant used by canonical compiled-job execution.
size_t processStandardJsonlDocuments(string datasetNamespace, string sourceKey,
    const(string)[] fields, DocumentTransform transform, JsonlLimits limits,
    bool dryRun = false, scope DocumentCommit committed = null) {
    version (Posix) {
        import core.stdc.signal : SIG_IGN, signal;
        import core.sys.posix.signal : SIGPIPE;
        signal(SIGPIPE, SIG_IGN);
    }
    return processJsonlDocuments(
        (ubyte[] buffer) => readStandard(buffer),
        (const(ubyte)[] bytes) {
            if (!dryRun) { stdout.rawWrite(bytes); stdout.flush(); }
        },
        datasetNamespace, sourceKey, fields, transform, limits, committed);
}
