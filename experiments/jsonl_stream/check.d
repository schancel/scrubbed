/// Release-active standalone adapter checks.
/// Run: ldc2 -O -release -enable-inlining -i -I=source experiments/jsonl_stream/check.d -of=/tmp/issue16-check && /tmp/issue16-check
module experiments.jsonl_stream.check;

import domain.document : DocumentId, SourceLocator;
import effects.jsonl_stream;
import core.memory : GC;
import core.sync.semaphore : Semaphore;
import core.thread : Thread;
import std.algorithm : min;
import std.conv : to;
import std.json : JSONType, parseJSON;
import std.stdio : writeln;
import std.string : splitLines;

private void require(bool condition, string message) {
    if (!condition) throw new Exception(message);
}

private struct Fixture {
    string input;
    size_t cursor;
    size_t reads;
    string output;
    size_t writes;
    size_t[] readCountsAtWrite;
    bool failWrite;

    size_t read(ubyte[] dst) {
        ++reads;
        auto n = min(dst.length, input.length - cursor);
        if (n) dst[0 .. n] = cast(const(ubyte)[]) input[cursor .. cursor + n];
        cursor += n;
        return n;
    }

    void write(const(ubyte)[] src) {
        ++writes;
        readCountsAtWrite ~= reads;
        if (failWrite) {
            output ~= cast(string) src[0 .. min(src.length, 3)];
            throw new Exception("sink fault");
        }
        output ~= cast(string) src;
    }

    size_t run(const(string)[] fields = ["text"],
        TextTransform transform = null, JsonlLimits limits = JsonlLimits(1024, 2048)) {
        if (transform is null)
            transform = (string field, string text, DocumentId id) => text ~ "!";
        return processJsonl(&read, &write, "batch", "stable-source", fields,
            transform, limits);
    }
}

private JsonlFailure expectFailure(ref Fixture f, JsonlFailureKind kind,
    const(string)[] fields = ["text"], TextTransform transform = null,
    JsonlLimits limits = JsonlLimits(1024, 2048)) {
    try f.run(fields, transform, limits);
    catch (JsonlFailure error) {
        require(error.kind == kind, "wrong failure category");
        return error;
    }
    throw new Exception("expected JSONL failure");
}

void main(string[] args) {
    if (args.length == 2 && args[1] == "--negative-control")
        require(false, "intentional release-active negative control");
    require(args.length == 1, "unexpected harness argument");

    auto fixture = Fixture(
        "{\"text\":\"caf\u00e9\",\"nested\":{\"flag\":true,\"array\":[null,42]},\"other\":\"keep\"}\r\n" ~
        "{\"text\":\"two\",\"large\":18446744073709551615}\n" ~
        "{\"text\":\"last\",\"n\":-9223372036854775808}");
    string[] seen;
    auto count = fixture.run(["text"], (string field, string text, DocumentId id) {
        seen ~= id.text;
        return text ~ "!";
    });
    require(count == 3 && fixture.writes == 3, "record count/order");
    require(seen[0] == DocumentId.from(SourceLocator("batch", "stable-source", "1")).text &&
        seen[1] == DocumentId.from(SourceLocator("batch", "stable-source", "2")).text &&
        seen[2] == DocumentId.from(SourceLocator("batch", "stable-source", "3")).text,
        "physical line IDs");
    auto lines = fixture.output.splitLines();
    require(lines.length == 3, "output line count");
    auto first = parseJSON(lines[0]);
    require(first["text"].str == "café!" && first["other"].str == "keep" &&
        first["nested"]["flag"].type == JSONType.true_ &&
        first["nested"]["array"][0].type == JSONType.null_ &&
        first["nested"]["array"][1].integer == 42, "semantic fields");
    require(parseJSON(lines[1])["large"].uinteger == ulong.max &&
        parseJSON(lines[2])["n"].integer == long.min, "integer preservation");
    auto retry = Fixture(fixture.input);
    string[] retryIds;
    retry.run(["text"], (string field, string text, DocumentId id) {
        retryIds ~= id.text; return text ~ "!";
    });
    require(retryIds == seen && retry.output == fixture.output, "retry stability");

    foreach (bad; ["{oops}\n", "[]\n", "{\"a\":1,\"a\":2}\n",
                   "{\"a\":1,\"\\u0061\":2}\n",
                   "{\"a\":{\"x\":1,\"x\":2}}\n",
                   "{\"a\":0.1}\n", "{\"a\":1e0}\n",
                   "{\"a\":18446744073709551616}\n",
                   "{\"a\":-9223372036854775809}\n", "\n"]) {
        auto badFixture = Fixture(bad);
        auto error = expectFailure(badFixture, JsonlFailureKind.malformedJson);
        require(error.line == 1 && error.completedRecords == 0 &&
            !error.partialOutputPossible && badFixture.output.length == 0,
            "malformed JSON boundary");
    }
    auto invalidText = Fixture("{\"text\":\"valid JSON\"}\n");
    auto textError = expectFailure(invalidText, JsonlFailureKind.invalidText,
        ["text"], (string field, string text, DocumentId id) {
            throw new Exception("document text rejected");
            return string.init;
        });
    require(textError.line == 1 && invalidText.output.length == 0,
        "valid JSON/text error distinction");
    auto nonText = Fixture("{\"text\":3}\n");
    expectFailure(nonText, JsonlFailureKind.invalidText);

    auto tooLong = Fixture("{\"text\":\"123456789\"}\n");
    auto limitError = expectFailure(tooLong, JsonlFailureKind.inputLimit, ["text"], null,
        JsonlLimits(8, 2048));
    require(tooLong.output.length == 0 &&
        limitError.documentId.text == DocumentId.from(SourceLocator(
            "batch", "stable-source", "1")).text, "oversized raw line emitted/ID");
    auto tooWide = Fixture("{\"text\":\"a\"}\n");
    expectFailure(tooWide, JsonlFailureKind.outputLimit, ["text"],
        (string field, string text, DocumentId id) => "12345678901234567890",
        JsonlLimits(1024, 16));
    require(tooWide.output.length == 0, "oversized output emitted");
    auto escapeExpansion = Fixture("{\"other\":\"\\n\\n\\n\\n\\n\"}\n");
    expectFailure(escapeExpansion, JsonlFailureKind.outputLimit, [], null,
        JsonlLimits(1024, 18));
    require(escapeExpansion.output.length == 0, "escaped output cap emitted");

    // A writer is called synchronously once per record. On failure, the next
    // record is not processed; bytes for it may already be in the read chunk.
    auto writerFault = Fixture("{\"text\":\"a\"}\n{\"text\":\"b\"}\n");
    writerFault.failWrite = true;
    auto writerError = expectFailure(writerFault, JsonlFailureKind.writer);
    require(writerError.line == 1 && writerError.completedRecords == 0 &&
        writerError.partialOutputPossible && writerFault.writes == 1 &&
        writerFault.output.length == 3, "writer partial-output uncertainty");
    // Reader faults are processing failures at the next physical line, not
    // invocation failures; the previously written prefix remains complete.
    size_t readCalls;
    string readOutput;
    try processJsonl((ubyte[] dst) {
        if (++readCalls == 1) {
            enum firstRecord = "{\"text\":\"a\"}\n";
            dst[0 .. firstRecord.length] = cast(const(ubyte)[]) firstRecord;
            return firstRecord.length;
        }
        throw new Exception("injected read fault");
        return size_t.init;
    }, (const(ubyte)[] bytes) { readOutput ~= cast(string) bytes; },
        "batch", "stable-source", ["text"],
        (string field, string text, DocumentId id) => text,
        JsonlLimits(1024, 2048));
    catch (JsonlFailure error) {
        require(error.kind == JsonlFailureKind.reader && error.line == 2 &&
            error.completedRecords == 1 && !error.partialOutputPossible &&
            error.documentId.text == DocumentId.from(SourceLocator(
                "batch", "stable-source", "2")).text &&
            readOutput == "{\"text\":\"a\"}\n", "reader fault prefix/identity");
    }
    require(readCalls == 2, "reader fault was not exercised");
    // With a one-byte reader, no additional read callback runs during writing.
    auto serial = Fixture("{\"text\":\"a\"}\n{\"text\":\"b\"}\n");
    size_t position;
    size_t reads;
    size_t writes;
    processJsonl((ubyte[] dst) { ++reads; if (position == serial.input.length) return 0;
        dst[0] = cast(ubyte) serial.input[position++]; return 1; },
        (const(ubyte)[] bytes) { ++writes;
            require(reads == (writes == 1 ? 13 : 26), "reader advanced during write");
        }, "batch", "stable-source", ["text"],
        (string field, string text, DocumentId id) => text, JsonlLimits(64, 64));
    require(writes == 2, "synchronous writer order");

    auto entered = new Semaphore(0);
    auto resume = new Semaphore(0);
    size_t blockedReads, blockedWrites, blockedPosition;
    Exception workerFailure;
    auto blockedInput = "{\"text\":\"a\"}\n{\"text\":\"b\"}\n";
    auto worker = new Thread({
        try processJsonl((ubyte[] dst) {
            ++blockedReads;
            if (blockedPosition == blockedInput.length) return 0;
            dst[0] = cast(ubyte) blockedInput[blockedPosition++];
            return 1;
        }, (const(ubyte)[] bytes) {
            ++blockedWrites;
            if (blockedWrites == 1) { entered.notify(); resume.wait(); }
        }, "batch", "blocked-source", ["text"],
        (string field, string text, DocumentId id) => text,
        JsonlLimits(64, 64));
        catch (Exception error) workerFailure = error;
    });
    worker.start();
    entered.wait();
    auto readsWhileBlocked = blockedReads;
    resume.notify();
    worker.join();
    require(workerFailure is null && readsWhileBlocked == 13 &&
        blockedWrites == 2, "blocked writer allowed another read callback");

    // A full-chunk reader can fetch later-line bytes before the first write.
    // Writer failure must stop further reads and never process those bytes.
    string chunkedInput;
    foreach (_; 0 .. 400) chunkedInput ~= "{\"text\":\"a\"}\n";
    auto readAhead = Fixture(chunkedInput);
    readAhead.failWrite = true;
    auto aheadError = expectFailure(readAhead, JsonlFailureKind.writer);
    require(aheadError.completedRecords == 0 && readAhead.reads == 1 &&
        readAhead.cursor == 4096 && readAhead.writes == 1,
        "writer fault exceeded bounded read-ahead or processed later record");

    // Generate records at the reader boundary instead of constructing a file.
    // Force collection periodically: retained adapter state must not grow with
    // record count, including when the sink keeps no output.
    enum record = "{\"text\":\"x\",\"nested\":[1,true,null]}\n";
    size_t supplied, discarded, peakUsed;
    auto baseline = GC.stats().usedSize;
    auto streamed = processJsonl((ubyte[] dst) {
        if (supplied == 20_000) return 0;
        auto bytes = cast(const(ubyte)[]) record;
        dst[0 .. bytes.length] = bytes;
        ++supplied;
        return bytes.length;
    }, (const(ubyte)[] bytes) {
        ++discarded;
        if (discarded % 1000 == 0) {
            GC.collect();
            auto used = GC.stats().usedSize;
            if (used > peakUsed) peakUsed = used;
        }
    }, "batch", "bounded-source", ["text"],
       (string field, string text, DocumentId id) => text,
       JsonlLimits(64, 128));
    require(streamed == 20_000 && discarded == 20_000, "large stream count");
    require(peakUsed <= baseline + 16 * 1024 * 1024,
        "adapter retained memory proportional to record count");
    writeln("jsonl_stream release-active checks: ok");
}
