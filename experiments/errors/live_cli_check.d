/// Release-active actual-binary checks for opt-in v2 file processing.
module experiments.errors.live_cli_check;

import std.algorithm.searching : canFind;
import std.conv : to;
import std.file : exists, getSize, mkdir, read, readText, remove,
    rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.process : execute, spawnProcess, tryWait, wait;
import std.string : splitLines, toStringz;
import std.uuid : randomUUID;
import core.sys.posix.unistd : getpid, link, symlink;

version (OSX) {
    // libproc reports this child's resident bytes and live descriptor list.
    // The layout and flavor values are from the macOS SDK's public headers.
    private extern(C) int proc_pid_rusage(int pid, int flavor, void* buffer);
    private extern(C) int proc_pidinfo(int pid, int flavor, ulong arg,
        void* buffer, int bufferSize);
    private struct RusageV0 {
        ubyte[16] uuid;
        ulong userTime, systemTime, idleWakeups, interruptWakeups;
        ulong pageins, wiredSize, residentSize, physicalFootprint;
        ulong processStart, processExit;
    }
}

private void need(bool okay, string label) {
    if (!okay) throw new Exception("live v2 check: " ~ label);
}

private void checkMeasuredTree(string binary, string root, string db) {
    import core.thread : Thread;
    import std.datetime : dur;
    import std.stdio : File, stdin;
    auto input = buildPath(root, "measured-tree");
    auto output = buildPath(root, "measured-out");
    enum files = 384;
    enum bytesPerFile = 256 * 1024;
    enum residentCap = 64UL * 1024 * 1024;
    mkdir(input);
    ubyte[] payload = new ubyte[bytesPerFile];
    foreach (index; 0 .. files) {
        payload[] = cast(ubyte)(32 + index % 95);
        write(buildPath(input, index.to!string ~ ".txt"), payload);
    }
    scope silent = File("/dev/null", "w");
    auto child = spawnProcess([binary, "run", "--input", input,
        "--output", output, "--error-journal", db, "--threads", "4",
        "--max-queued-docs", "1", "--max-input-bytes", bytesPerFile.to!string,
        "--max-open-inputs", "1"], stdin, silent, silent);
    scope(exit) if (child.processID > 0) wait(child);
    ulong maxResident;
    size_t maxDescriptors, samples;
    int status;
    while (true) {
        version (OSX) {
            RusageV0 usage;
            int rssResult = proc_pid_rusage(child.processID, 0, &usage);
            ubyte[4096] descriptors;
            int fdBytes = proc_pidinfo(child.processID, 1, 0,
                descriptors.ptr, cast(int)descriptors.length);
            if (rssResult == 0 && fdBytes > 0) {
                maxResident = maxResident > usage.residentSize ?
                    maxResident : usage.residentSize;
                auto count = cast(size_t)fdBytes / 8;
                maxDescriptors = maxDescriptors > count ? maxDescriptors : count;
                ++samples;
            }
        }
        auto result = tryWait(child);
        if (result.terminated) { status = result.status; break; }
        Thread.sleep(dur!"msecs"(5));
    }
    need(status == 0, "measured tree exited " ~ status.to!string);
    version (OSX) {
        need(samples >= 5, "insufficient live resource samples");
        // The 96 MiB corpus is larger than this bound; holding all input
        // buffers would fail while one-token scheduling stays below it.
        need(maxResident > 0 && maxResident <= residentCap,
            "resident bound " ~ maxResident.to!string);
        need(maxDescriptors > 0 && maxDescriptors <= 64,
            "descriptor bound " ~ maxDescriptors.to!string);
        import std.stdio : writeln;
        writeln("live v2 resources: ", samples, " samples, peak observed RSS ",
            maxResident, " bytes, peak observed FDs ", maxDescriptors);
    }
    version (OSX) {
        RusageV0 before, after;
        need(proc_pid_rusage(getpid(), 0, &before) == 0,
            "buffer control baseline");
        ubyte[][] retained;
        retained.length = files;
        foreach (index; 0 .. files)
            retained[index] = cast(ubyte[])read(
                buildPath(input, index.to!string ~ ".txt"));
        need(proc_pid_rusage(getpid(), 0, &after) == 0,
            "buffer control sample");
        need(retained[$ - 1][$ - 1] == cast(ubyte)(32 + (files - 1) % 95),
            "buffer control retained bytes");
        need(after.residentSize >= before.residentSize + residentCap,
            "buffer control did not breach child RSS cap");
        import std.stdio : writeln;
        writeln("live v2 buffering control: retained ", files * bytesPerFile,
            " bytes; RSS delta ", after.residentSize - before.residentSize,
            " bytes");
    }
    foreach (index; 0 .. files) {
        auto path = buildPath(output, index.to!string ~ ".txt");
        need(exists(path) && getSize(path) == bytesPerFile,
            "measured tree output length");
        auto bytes = cast(ubyte[])read(path);
        need(bytes.length == bytesPerFile, "measured tree output bytes");
        foreach (value; bytes)
            if (value != cast(ubyte)(32 + index % 95))
                throw new Exception("live v2 check: measured tree output mismatch");
    }
}

void main(string[] args) {
    need(args.length == 2 || (args.length == 3 && args[2] == "--harness"),
        "expected executable and optional --harness");
    bool harness = args.length == 3;
    auto root = buildPath(tempDir(), "scrubbed-live-v2-" ~ randomUUID().toString);
    mkdir(root);
    scope(exit) rmdirRecurse(root);
    size_t checks;
    string call(string[] command, int status) {
        auto result = execute([args[1]] ~ command);
        need(result.status == status, "exit " ~ command[0] ~ " got " ~
            result.status.to!string ~ " expected " ~ status.to!string ~
            " output=" ~ result.output);
        foreach (secret; ["F13_SOURCE_SECRET", "F13_PATH_SECRET",
                "F13_EXCEPTION_SECRET"])
            need(!result.output.canFind(secret), "private diagnostic");
        ++checks;
        return result.output;
    }
    auto source = buildPath(root, "F13_PATH_SECRET.txt");
    auto output = buildPath(root, "out.txt");
    auto db = buildPath(root, "journal.db");
    auto history = buildPath(root, "history.jsonl");
    auto outstanding = buildPath(root, "outstanding.jsonl");
    write(source, "F13_SOURCE_SECRET\n");
    auto route = ["run", "--input", source, "--output", output,
        "--error-journal", db, "--threads", "1", "--explain"];
    call(route, 2);
    call(route ~ ["--validate"], 2);
    need(!exists(db) && !exists(output), "implicit journal creation");
    call(["errors-init", "--journal", db], 0);
    call(route ~ ["--validate"], 0);
    need(!exists(output), "validate did not create output");
    auto foreign = buildPath(root, "foreign.db");
    write(foreign, "foreign schema");
    call(["run", "--input", source, "--output", output,
        "--error-journal", foreign, "--validate"], 2);
    need(readText(foreign) == "foreign schema" && !exists(output),
        "foreign validation did not mutate paths");
    auto v1Implicit = buildPath(root, "v1-implicit.txt");
    auto v1Explicit = buildPath(root, "v1-explicit.txt");
    auto legacyImplicit = call(["--input", source, "--output", v1Implicit], 0);
    auto legacyExplicit = call(["run", "--input", source,
        "--output", v1Explicit], 0);
    need(legacyImplicit == legacyExplicit &&
        readText(v1Implicit) == readText(v1Explicit),
        "no-flag v1 route equivalence");
    auto unownedInput = buildPath(root, "unowned-input.txt");
    auto unownedOutput = buildPath(root, "unowned-output.txt");
    write(unownedInput, "new bytes");
    write(unownedOutput, "old bytes");
    auto unownedRoute = ["run", "--input", unownedInput,
        "--output", unownedOutput, "--error-journal", db, "--explain"];
    auto unownedDecision = call(unownedRoute, 1);
    need(unownedDecision.canFind("retry-required") &&
        unownedDecision.canFind("document_id=") &&
        !unownedDecision.canFind("sink_id="),
        "unowned output has safe identity-free explanation");
    need(readText(unownedOutput) == "old bytes", "unowned output untouched");
    call(unownedRoute ~ ["--error-retry"], 0);
    need(readText(unownedOutput) == "new bytes", "explicit unowned retry");
    need(call(route, 0).canFind("status=unchanged"), "initial publish");
    need(readText(output) == readText(source), "published bytes");
    need(call(route, 0).canFind("status=skipped"), "verified skip");
    call(["errors-export", "--journal", db, "--errors-jsonl", history,
        "--outstanding-jsonl", outstanding], 0);
    need(readText(history).length == 0 && readText(outstanding).length == 0,
        "clean journal");
    write(output, "tampered");
    need(call(route, 1).canFind("retry-required"), "retry required after invalidation");
    call(["errors-export", "--journal", db, "--errors-jsonl", history,
        "--outstanding-jsonl", outstanding], 0);
    need(readText(history).canFind("inspect-invalidated") &&
        readText(outstanding).canFind("uncertain"), "invalidation recorded");
    need(call(route ~ ["--error-retry"], 0).canFind("status=retry"), "retry");
    need(readText(output) == readText(source), "retry published bytes");
    call(["errors-export", "--journal", db, "--errors-jsonl", history,
        "--outstanding-jsonl", outstanding], 0);
    need(readText(history).canFind("retry-succeeded") &&
        readText(outstanding).length == 0, "retry history and exact-key clear");
    call(route ~ ["--manifest", buildPath(root, "legacy.db")], 2);
    call(route ~ ["--dry-run"], 2);
    call(["run", "--input", "-", "--output", "-", "--error-journal", db], 2);
    call(["run", "--input", source, "--output", output, "--error-retry"], 2);
    auto otherInput = buildPath(root, "other-input.txt");
    write(otherInput, "other");
    call(["run", "--input", otherInput, "--output", output,
        "--error-journal", db, "--error-retry"], 2);
    need(readText(output) == readText(source), "foreign document cannot replace owner");
    auto aliasOut = buildPath(root, "alias-out.txt");
    need(link(output.toStringz, aliasOut.toStringz) == 0, "hardlink fixture");
    call(["run", "--input", otherInput, "--output", aliasOut,
        "--error-journal", db, "--error-retry"], 2);
    need(readText(output) == readText(source), "hardlink owner preserved");
    auto linkOut = buildPath(root, "symlink-out.txt");
    need(symlink(output.toStringz, linkOut.toStringz) == 0, "symlink fixture");
    call(["run", "--input", otherInput, "--output", linkOut,
        "--error-journal", db, "--error-retry"], 2);
    need(readText(output) == readText(source), "symlink target preserved");
    auto tree = buildPath(root, "tree");
    auto treeOut = buildPath(root, "tree-out");
    mkdir(tree);
    foreach (index; 0 .. 48)
        write(buildPath(tree, index.to!string ~ ".txt"), "small");
    call(["run", "--input", tree, "--output", treeOut,
        "--error-journal", db, "--threads", "4", "--max-queued-docs", "1",
        "--max-input-bytes", "5", "--max-open-inputs", "1"], 0);
    foreach (index; 0 .. 48)
        need(readText(buildPath(treeOut, index.to!string ~ ".txt")) == "small",
            "bounded tree output");
    auto oversized = buildPath(root, "oversized.txt");
    auto oversizedOut = buildPath(root, "oversized-out.txt");
    write(oversized, "sixsix");
    call(["run", "--input", oversized, "--output", oversizedOut,
        "--error-journal", db, "--max-input-bytes", "3"], 2);
    need(!exists(oversizedOut), "input cap refusal did not publish");
    checkMeasuredTree(args[1], root, db);
    if (harness) {
        auto failed = buildPath(root, "failed.txt");
        auto failedOut = buildPath(root, "failed-out.txt");
        write(failed, "failed");
        auto failedRoute = ["run", "--input", failed, "--output", failedOut,
            "--error-journal", db, "--threads", "1", "--explain"];
        auto marker = db ~ ".fault-filter";
        write(marker, "");
        need(call(failedRoute, 1).canFind("filter-failed"), "acknowledged filter failure");
        remove(marker);
        need(!exists(failedOut), "filter failure did not publish");
        need(call(failedRoute, 1).canFind("retry-required"), "failed key requires retry");
        marker = db ~ ".kill-after-plan";
        write(marker, "1");
        call(failedRoute ~ ["--error-retry"], -9);
        remove(marker);
        need(call(failedRoute, 1).canFind("retry-required"),
            "planned retry with outstanding still requires opt-in");
        call(failedRoute ~ ["--error-retry"], 0);
        need(readText(failedOut) == "failed", "failed key retry output");
        auto partialTree = buildPath(root, "partial-tree");
        auto partialOut = buildPath(root, "partial-out");
        mkdir(partialTree);
        write(buildPath(partialTree, "bad.txt"), "bad");
        write(buildPath(partialTree, "good.txt"), "good");
        marker = db ~ ".fault-filter";
        write(marker, "bad.txt");
        call(["run", "--input", partialTree, "--output", partialOut,
            "--error-journal", db, "--threads", "4"], 1);
        remove(marker);
        need(!exists(buildPath(partialOut, "bad.txt")) &&
            readText(buildPath(partialOut, "good.txt")) == "good",
            "acknowledged failure continued other document");
        auto secondFailed = buildPath(root, "second-failed.txt");
        auto secondFailedOut = buildPath(root, "second-failed-out.txt");
        write(secondFailed, "second-failed");
        auto secondFailedRoute = ["run", "--input", secondFailed,
            "--output", secondFailedOut, "--error-journal", db];
        marker = db ~ ".fault-filter";
        write(marker, "");
        call(secondFailedRoute, 1);
        remove(marker);
        call(["errors-export", "--journal", db, "--outstanding-jsonl", outstanding], 0);
        need(readText(outstanding).splitLines.length == 2,
            "two exact outstanding keys");
        call(secondFailedRoute ~ ["--error-retry"], 0);
        call(["errors-export", "--journal", db, "--outstanding-jsonl", outstanding], 0);
        need(readText(outstanding).splitLines.length == 1,
            "retry cleared only its exact key");
        auto sink = buildPath(root, "sink.txt");
        auto sinkOut = buildPath(root, "sink-out.txt");
        write(sink, "sink");
        auto sinkRoute = ["run", "--input", sink, "--output", sinkOut,
            "--error-journal", db, "--threads", "1", "--explain"];
        marker = db ~ ".fault-sink";
        write(marker, "");
        need(call(sinkRoute, 1).canFind("sink-write-failed"),
            "acknowledged sink failure");
        remove(marker);
        need(call(sinkRoute, 1).canFind("retry-required"),
            "uncertain sink requires retry");
        call(sinkRoute ~ ["--error-retry"], 0);
        need(readText(sinkOut) == "sink", "sink retry output");
        auto ack = buildPath(root, "ack.txt");
        auto ackOut = buildPath(root, "ack-out.txt");
        write(ack, "ack");
        auto ackRoute = ["run", "--input", ack, "--output", ackOut,
            "--error-journal", db, "--threads", "1", "--explain"];
        marker = db ~ ".fault-v2-ack";
        write(marker, "");
        call(ackRoute, 2);
        remove(marker);
        need(!exists(ackOut), "unacknowledged plan did not publish");
        call(ackRoute, 0);
        auto ackFailure = buildPath(root, "ack-failure.txt");
        auto ackFailureOut = buildPath(root, "ack-failure-out.txt");
        write(ackFailure, "ack-failure");
        auto ackFailureRoute = ["run", "--input", ackFailure,
            "--output", ackFailureOut, "--error-journal", db,
            "--threads", "1", "--explain"];
        write(db ~ ".fault-filter", "");
        write(db ~ ".fault-v2-arm-ack-on-failure", "1");
        call(ackFailureRoute, 2);
        remove(db ~ ".fault-filter");
        remove(db ~ ".fault-v2-arm-ack-on-failure");
        remove(db ~ ".fault-v2-ack");
        need(!exists(ackFailureOut), "unacknowledged failure did not publish");
        need(call(ackFailureRoute, 1).canFind("retry-required"),
            "uncertain ack does not silently resume");
        call(ackFailureRoute ~ ["--error-retry"], 0);
        auto second = buildPath(root, "second.txt");
        auto secondOut = buildPath(root, "second-out.txt");
        write(second, "second");
        auto secondRoute = ["run", "--input", second, "--output", secondOut,
            "--error-journal", db, "--threads", "1", "--explain"];
        marker = db ~ ".kill-after-plan";
        write(marker, "1");
        call(secondRoute, -9);
        remove(marker);
        need(call(secondRoute, 0).canFind("status=unchanged"),
            "planned crash resumed");
        auto third = buildPath(root, "third.txt");
        auto thirdOut = buildPath(root, "third-out.txt");
        write(third, "third");
        auto thirdRoute = ["run", "--input", third, "--output", thirdOut,
            "--error-journal", db, "--threads", "1", "--explain"];
        marker = db ~ ".kill-before-publish";
        write(marker, "1");
        call(thirdRoute, -9);
        remove(marker);
        need(call(thirdRoute, 1).canFind("retry-required"),
            "intent crash requires retry");
        call(thirdRoute ~ ["--error-retry"], 0);
        need(readText(thirdOut) == "third", "intent retry output");
        auto fourth = buildPath(root, "fourth.txt");
        auto fourthOut = buildPath(root, "fourth-out.txt");
        write(fourth, "fourth");
        auto fourthRoute = ["run", "--input", fourth, "--output", fourthOut,
            "--error-journal", db, "--threads", "1", "--explain"];
        marker = db ~ ".kill-after-publish";
        write(marker, "1");
        call(fourthRoute, -9);
        remove(marker);
        need(readText(fourthOut) == "fourth", "published before commit crash");
        need(call(fourthRoute, 1).canFind("retry-required"),
            "published uncommitted requires retry");
        call(fourthRoute ~ ["--error-retry"], 0);
        auto fifth = buildPath(root, "fifth.txt");
        auto fifthOut = buildPath(root, "fifth-out.txt");
        write(fifth, "fifth");
        auto fifthRoute = ["run", "--input", fifth, "--output", fifthOut,
            "--error-journal", db, "--threads", "1", "--explain"];
        marker = db ~ ".kill-after-commit";
        write(marker, "1");
        call(fifthRoute, -9);
        remove(marker);
        need(call(fifthRoute, 0).canFind("status=skipped"),
            "committed crash restart skip");
    }
    import std.stdio : writeln;
    writeln("live v2 CLI check: ", checks, " actual-binary assertions");
}
