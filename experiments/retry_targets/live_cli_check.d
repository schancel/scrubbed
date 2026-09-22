/// Release-active actual-binary proof for local targeted v2 retry.
module experiments.retry_targets.live_cli_check;

import effects.failure_journal : FailureJournal;
import effects.local_manifest : SinkKey, inputDigest;
import effects.sqlite_ffi;
import std.algorithm.searching : canFind;
import std.array : replicate;
import std.conv : to;
import std.file : exists, getSize, mkdir, read, readText, remove, rmdirRecurse,
    tempDir, write;
import std.path : buildPath;
import std.process : execute, spawnProcess, tryWait, wait;
import std.string : toStringz;
import std.uuid : randomUUID;
import core.sys.posix.sys.stat : stat, stat_t;
import core.sys.posix.unistd : getpid, link, symlink;

version (OSX) {
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
    if (!okay) throw new Exception("targeted CLI check: " ~ label);
}
private ulong inode(string path) {
    stat_t info;
    need(stat(path.toStringz, &info) == 0, "stat output");
    return cast(ulong)info.st_ino;
}

private long historyCount(string path, SinkKey key) {
    sqlite3* db;
    need(sqlite3_open_v2(path.toStringz, &db, SQLITE_OPEN_READONLY,
        null) == SQLITE_OK, "history read-only open");
    scope(exit) need(sqlite3_close(db) == SQLITE_OK, "history read-only close");
    sqlite3_stmt* statement;
    enum query = `SELECT count(*) FROM error_event e JOIN sink_identity i
        ON e.sink_id=i.sink_id WHERE e.document_id=?1 AND
        e.input_sha256=?2 AND e.config_sha256=?3 AND i.raw_sink=?4`;
    need(sqlite3_prepare_v2(db, query.toStringz, -1, &statement, null) == SQLITE_OK,
        "history query prepare");
    scope(exit) need(sqlite3_finalize(statement) == SQLITE_OK,
        "history query finalize");
    need(sqlite3_bind_text(statement, 1, key.document.text.toStringz, -1,
            null) == SQLITE_OK &&
        sqlite3_bind_blob(statement, 2, key.inputSha256.ptr, 32, null) == SQLITE_OK &&
        sqlite3_bind_blob(statement, 3, key.configSha256.ptr, 32, null) == SQLITE_OK &&
        sqlite3_bind_text(statement, 4, key.sink.toStringz, -1,
            null) == SQLITE_OK &&
        sqlite3_step(statement) == SQLITE_ROW, "history query step");
    return sqlite3_column_int64(statement, 0);
}

private void checkResources(string binary, string root) {
    import core.thread : Thread;
    import std.datetime : dur;
    import std.stdio : File, stdin;
    enum files = 384;
    enum bytesPerFile = 256 * 1024;
    enum residentCap = 64UL * 1024 * 1024;
    auto input = buildPath(root, "resource-input");
    auto output = buildPath(root, "resource-output");
    auto db = buildPath(root, "resource.db");
    mkdir(input);
    ubyte[] payload = new ubyte[bytesPerFile];
    foreach (index; 0 .. files) {
        payload[] = cast(ubyte)(32 + index % 95);
        write(buildPath(input, index.to!string ~ ".txt"), payload);
    }
    need(execute([binary, "errors-init", "--journal", db]).status == 0,
        "resource journal init");
    auto route = [binary, "run", "--input", input, "--output", output,
        "--error-journal", db, "--threads", "4", "--max-queued-docs", "1",
        "--max-input-bytes", bytesPerFile.to!string, "--max-open-inputs", "1"];
    need(execute(route).status == 0, "resource first publish");
    foreach (index; 0 .. files)
        write(buildPath(output, index.to!string ~ ".txt"), "tampered");
    need(execute(route).status == 1, "resource target seeding");
    scope silent = File("/dev/null", "w");
    auto child = spawnProcess(route ~ ["--error-retry", "--error-targeted"],
        stdin, silent, silent);
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
                if (usage.residentSize > maxResident)
                    maxResident = usage.residentSize;
                auto count = cast(size_t)fdBytes / 8;
                if (count > maxDescriptors) maxDescriptors = count;
                ++samples;
            }
        }
        auto result = tryWait(child);
        if (result.terminated) { status = result.status; break; }
        Thread.sleep(dur!"msecs"(5));
    }
    need(status == 0, "resource targeted retry exit");
    version (OSX) {
        need(samples >= 5 && maxResident > 0 &&
            maxResident <= residentCap && maxDescriptors > 0 &&
            maxDescriptors <= 64, "resource bound");
        RusageV0 before, after;
        need(proc_pid_rusage(getpid(), 0, &before) == 0,
            "buffer control baseline");
        ubyte[][] retained;
        retained.length = files;
        foreach (index; 0 .. files)
            retained[index] = cast(ubyte[])read(
                buildPath(input, index.to!string ~ ".txt"));
        need(proc_pid_rusage(getpid(), 0, &after) == 0 &&
            retained[$ - 1][$ - 1] == cast(ubyte)(32 + (files - 1) % 95),
            "buffer control sample");
        need(after.residentSize >= before.residentSize + residentCap,
            "buffer control did not breach targeted cap");
        import std.stdio : writeln;
        writeln("targeted resources: ", samples, " samples, RSS ",
            maxResident, " bytes, FDs ", maxDescriptors,
            "; buffered control delta ",
            after.residentSize - before.residentSize, " bytes");
    }
    foreach (index; 0 .. files) {
        auto path = buildPath(output, index.to!string ~ ".txt");
        need(getSize(path) == bytesPerFile, "resource output length");
        auto bytes = cast(ubyte[])read(path);
        foreach (value; bytes)
            if (value != cast(ubyte)(32 + index % 95))
                throw new Exception("targeted CLI check: resource output mismatch");
    }
}

void main(string[] args) {
    need(args.length == 2 || args.length == 3,
        "expected shipping executable and optional crash harness");
    auto root = buildPath(tempDir(), "scrubbed-targeted-" ~ randomUUID().toString);
    mkdir(root);
    scope(exit) rmdirRecurse(root);
    size_t checks;
    string call(string binary, string[] command, int status) {
        auto result = execute([binary] ~ command);
        need(result.status == status, "exit " ~ command[0] ~ " got " ~
            result.status.to!string ~ " expected " ~ status.to!string ~
            " output=" ~ result.output);
        foreach (secret; ["TARGET_SOURCE_SECRET", "TARGET_PATH_SECRET",
                "OTHER_SINK_SECRET"])
            need(!result.output.canFind(secret), "private diagnostic");
        ++checks;
        return result.output;
    }
    auto binary = args[1];
    auto input = buildPath(root, "TARGET_PATH_SECRET-input");
    auto output = buildPath(root, "output");
    auto db = buildPath(root, "journal.db");
    mkdir(input);
    auto a = buildPath(input, "a.txt");
    auto b = buildPath(input, "b.txt");
    write(a, "TARGET_SOURCE_SECRET a");
    write(b, "TARGET_SOURCE_SECRET b");
    auto base = ["run", "--input", input, "--output", output,
        "--error-journal", db, "--threads", "1", "--explain"];
    auto targeted = base ~ ["--error-retry", "--error-targeted"];
    call(binary, targeted, 2);
    call(binary, ["run", "--input", input, "--output", output,
        "--error-targeted"], 2);
    call(binary, base ~ ["--error-targeted"], 2);
    auto legacyInput = buildPath(root, "legacy.txt");
    auto legacyImplicit = buildPath(root, "legacy-implicit.txt");
    auto legacyExplicit = buildPath(root, "legacy-explicit.txt");
    write(legacyInput, "legacy route");
    auto legacyResult = call(binary, ["--input", legacyInput,
        "--output", legacyImplicit], 0);
    need(call(binary, ["run", "--input", legacyInput,
        "--output", legacyExplicit], 0) == legacyResult &&
        readText(legacyImplicit) == readText(legacyExplicit),
        "no-flag v1 equivalence");
    call(binary, ["errors-init", "--journal", db], 0);
    call(binary, base, 0);
    auto outA = buildPath(output, "a.txt");
    auto outB = buildPath(output, "b.txt");
    need(readText(outA) == readText(a) && readText(outB) == readText(b),
        "initial publication");
    write(outA, "tampered-a");
    write(outB, "tampered-b");
    call(binary, base, 1); // Inspection records two exact outstanding keys.
    auto journal = new FailureJournal(db);
    SinkKey bKey;
    journal.visitOutstandingTargets((SinkKey key) {
        if (key.inputSha256 == inputDigest(cast(const(ubyte)[])read(b)))
            bKey = key;
    });
    need(bKey.sink == "local-primary:v1", "b outstanding key selected");
    auto bBefore = journal.lookup(bKey).get;
    auto eventsBefore = journal.eventCount();
    journal.close();
    auto bHistory = historyCount(db, bKey);
    auto huge = buildPath(input, "huge.txt");
    write(huge, "H".replicate(1024 * 1024));
    auto capped = targeted ~ ["--max-input-bytes", "64"];
    write(b, "changed TARGET_SOURCE_SECRET b");
    auto first = call(binary, capped, 1);
    need(first.canFind("target-mismatch") &&
        first.canFind("document_id=") && !first.canFind("sink_key="),
        "typed fixed mismatch");
    need(readText(outA) == readText(a) && readText(outB) == "tampered-b" &&
        !exists(buildPath(output, "huge.txt")),
        "one target succeeded, mismatch and non-target preserved");
    journal = new FailureJournal(db);
    need(journal.eventCount() == eventsBefore + 1 &&
        journal.lookup(bKey).get == bBefore && journal.hasOutstanding(bKey),
        "input mismatch changed old event or state");
    journal.close();
    need(historyCount(db, bKey) == bHistory,
        "input mismatch changed old key history");
    ++eventsBefore; // The independently successful a retry appended one success event.
    auto committedInode = inode(outA);
    call(binary, capped, 1);
    need(inode(outA) == committedInode, "repeat did not rewrite cleared key");
    journal = new FailureJournal(db);
    need(journal.eventCount() == eventsBefore &&
        journal.lookup(bKey).get == bBefore && journal.hasOutstanding(bKey),
        "repeat mismatch changed old event or state");
    journal.close();
    need(historyCount(db, bKey) == bHistory,
        "repeat mismatch changed old key history");
    write(b, "TARGET_SOURCE_SECRET b");
    call(binary, capped ~ ["--filters", "strip-control"], 1);
    need(readText(outB) == "tampered-b", "config-only mismatch preserved output");
    journal = new FailureJournal(db);
    need(journal.eventCount() == eventsBefore &&
        journal.lookup(bKey).get == bBefore && journal.hasOutstanding(bKey),
        "config mismatch changed old event or state");
    need(historyCount(db, bKey) == bHistory,
        "config mismatch changed old key history");
    SinkKey[] remaining;
    journal.visitOutstandingTargets((SinkKey key) { remaining ~= key; });
    need(remaining.length == 1, "only one local-primary outstanding");
    auto other = remaining[0];
    other.sink = "OTHER_SINK_SECRET";
    journal.plan(other, buildPath(root, "other-sink"));
    journal.recordFailure(other, "filter", "filter-failed", false);
    journal.close();
    need(call(binary, capped, 0).canFind("status=retry"),
        "matching target retried");
    need(readText(outB) == readText(b), "retry output");
    auto bInode = inode(outB);
    call(binary, capped, 0);
    need(inode(outA) == committedInode && inode(outB) == bInode,
        "idempotent targeted repeat");
    journal = new FailureJournal(db);
    remaining.length = 0;
    journal.visitOutstandingTargets((SinkKey key) { remaining ~= key; });
    need(remaining.length == 1 && remaining[0].sink == "OTHER_SINK_SECRET",
        "unrelated sink outstanding preserved");
    journal.close();
    auto hugeOnlyOut = buildPath(root, "huge-only-output");
    call(binary, ["run", "--input", huge, "--output", hugeOnlyOut,
        "--error-journal", db, "--error-retry", "--error-targeted",
        "--max-input-bytes", "1"], 0);
    need(!exists(hugeOnlyOut), "non-target skipped before output creation");
    auto noTargetTree = buildPath(root, "no-target-tree");
    auto noTargetOutput = buildPath(root, "no-target-output");
    mkdir(noTargetTree);
    write(buildPath(noTargetTree, "large.txt"), "large-enough");
    call(binary, ["run", "--input", noTargetTree, "--output", noTargetOutput,
        "--error-journal", db, "--error-retry", "--error-targeted",
        "--max-input-bytes", "1"], 0);
    need(!exists(noTargetOutput), "non-target directory created output");
    auto revisionsInput = buildPath(root, "revisions-input.txt");
    auto revisionsOutput = buildPath(root, "revisions-output.txt");
    auto revisionsDb = buildPath(root, "revisions.db");
    auto revisionsBase = ["run", "--input", revisionsInput, "--output",
        revisionsOutput, "--error-journal", revisionsDb];
    write(revisionsInput, "first revision");
    call(binary, ["errors-init", "--journal", revisionsDb], 0);
    call(binary, revisionsBase, 0);
    write(revisionsOutput, "tampered first");
    call(binary, revisionsBase, 1);
    write(revisionsInput, "second revision");
    call(binary, revisionsBase ~ ["--error-retry"], 0);
    write(revisionsOutput, "tampered second");
    call(binary, revisionsBase, 1);
    journal = new FailureJournal(revisionsDb);
    SinkKey[] revisions;
    journal.visitOutstandingTargets((SinkKey key) { revisions ~= key; });
    need(revisions.length == 2 &&
        revisions[0].document == revisions[1].document &&
        revisions[0].sink == "local-primary:v1" &&
        revisions[1].sink == "local-primary:v1" &&
        revisions[0].inputSha256 != revisions[1].inputSha256,
        "two full-key revisions outstanding");
    auto currentRevision = revisions[0].inputSha256 ==
        inputDigest(cast(const(ubyte)[])"second revision")
        ? revisions[0] : revisions[1];
    auto olderRevision = currentRevision == revisions[0] ? revisions[1] : revisions[0];
    auto olderBefore = journal.lookup(olderRevision).get;
    auto revisionEvents = journal.eventCount();
    journal.close();
    auto olderHistory = historyCount(revisionsDb, olderRevision);
    call(binary, revisionsBase ~ ["--error-retry", "--error-targeted"], 0);
    need(readText(revisionsOutput) == "second revision",
        "current revision published");
    journal = new FailureJournal(revisionsDb);
    need(!journal.hasOutstanding(currentRevision) &&
        journal.hasOutstanding(olderRevision) &&
        journal.lookup(olderRevision).get == olderBefore &&
        journal.eventCount() == revisionEvents + 1 &&
        historyCount(revisionsDb, olderRevision) == olderHistory,
        "targeted cleared only matching revision");
    journal.close();
    ++revisionEvents;
    auto revisionInode = inode(revisionsOutput);
    call(binary, revisionsBase ~ ["--error-retry", "--error-targeted"], 1);
    need(inode(revisionsOutput) == revisionInode &&
        readText(revisionsOutput) == "second revision",
        "older-only mismatch preserves current output");
    journal = new FailureJournal(revisionsDb);
    need(journal.hasOutstanding(olderRevision) &&
        journal.lookup(olderRevision).get == olderBefore &&
        journal.eventCount() == revisionEvents &&
        historyCount(revisionsDb, olderRevision) == olderHistory,
        "older-only mismatch changed old event or state");
    journal.close();
    auto hazardInput = buildPath(root, "hazard-input");
    auto hazardOutput = buildPath(root, "hazard-output");
    auto hazardDb = buildPath(root, "hazard.db");
    mkdir(hazardInput);
    write(buildPath(hazardInput, "x.txt"), "x");
    write(buildPath(hazardInput, "y.txt"), "y");
    auto hazardBase = ["run", "--input", hazardInput,
        "--output", hazardOutput, "--error-journal", hazardDb];
    call(binary, ["errors-init", "--journal", hazardDb], 0);
    call(binary, hazardBase, 0);
    auto hazardX = buildPath(hazardOutput, "x.txt");
    auto hazardY = buildPath(hazardOutput, "y.txt");
    write(hazardX, "tampered");
    call(binary, hazardBase, 1);
    remove(hazardX);
    auto outsideHazard = buildPath(root, "outside-hazard.txt");
    write(outsideHazard, "outside stays");
    need(symlink(outsideHazard.toStringz, hazardX.toStringz) == 0,
        "output symlink fixture");
    call(binary, hazardBase ~ ["--error-retry", "--error-targeted"], 2);
    need(readText(outsideHazard) == "outside stays", "output symlink preserved");
    remove(hazardX);
    need(link(hazardY.toStringz, hazardX.toStringz) == 0,
        "output hardlink fixture");
    call(binary, hazardBase ~ ["--error-retry", "--error-targeted"], 2);
    need(readText(hazardY) == "y", "other document hardlink preserved");
    remove(hazardX);
    auto outside = buildPath(root, "outside.txt");
    write(outside, "outside");
    auto linkPath = buildPath(input, "link.txt");
    need(symlink(outside.toStringz, linkPath.toStringz) == 0,
        "symlink fixture");
    call(binary, capped, 2);
    remove(linkPath);
    checkResources(binary, root);
    if (args.length == 3) {
        auto hook = args[2];
        auto crashInput = buildPath(root, "crash-input.txt");
        auto crashOutput = buildPath(root, "crash-output.txt");
        auto crashDb = buildPath(root, "crash.db");
        write(crashInput, "crash target");
        auto crashBase = ["run", "--input", crashInput, "--output",
            crashOutput, "--error-journal", crashDb];
        call(hook, ["errors-init", "--journal", crashDb], 0);
        call(hook, crashBase, 0);
        write(crashOutput, "tampered");
        call(hook, crashBase, 1);
        auto marker = crashDb ~ ".kill-after-publish";
        write(marker, "1");
        call(hook, crashBase ~ ["--error-retry", "--error-targeted"], -9);
        remove(marker);
        need(readText(crashOutput) == "crash target", "crash after publish");
        call(hook, crashBase ~ ["--error-retry", "--error-targeted"], 0);
        journal = new FailureJournal(crashDb);
        remaining.length = 0;
        journal.visitOutstandingTargets((SinkKey key) { remaining ~= key; });
        need(remaining.length == 0, "crash retry cleared exact key");
        journal.close();
    }
    import std.stdio : writeln;
    writeln("targeted CLI check: ", checks, " actual-binary assertions");
}
