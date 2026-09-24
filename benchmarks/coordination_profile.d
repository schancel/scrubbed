/// Frozen O3/release coordination attribution for issue #182.
module benchmarks.coordination_profile;

import core.atomic : atomicLoad, atomicStore;
import core.stdc.errno : EINTR, errno;
import core.sys.posix.signal : posixKill = kill, siginfo_t, SIGKILL, SIGTERM;
import core.sys.posix.sys.resource : RLIMIT_FSIZE, getrlimit, rlimit, rusage,
    setrlimit;
import core.sys.posix.sys.stat : chmod, mkdir, S_IRUSR, S_IWUSR, S_IXUSR,
    S_IRWXU;
import core.sys.posix.unistd : execv, getpid, link, setpgid;
import core.sys.posix.sys.wait : idtype_t, WEXITED, WEXITSTATUS, WIFEXITED,
    WIFSIGNALED, WNOHANG, WNOWAIT, WTERMSIG, waitid;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : msecs, seconds;
import std.algorithm.comparison : min;
import std.algorithm.sorting : sort;
import std.algorithm.searching : canFind;
import std.array : appender;
import std.conv : to;
import std.datetime.stopwatch : AutoStart, MonoTime, StopWatch;
import std.digest : LetterCase, toHexString;
import std.digest.sha : SHA256, sha256Of;
import std.file : SpanMode, dirEntries, exists, getAttributes,
    getAvailableDiskSpace, getSize, isFile, isSymlink, mkdirRecurse, read,
    readText, remove, rmdirRecurse,
    setAttributes, tempDir, write;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : absolutePath, buildPath, relativePath;
import std.process : Config, Pid, environment, execute, spawnProcess;
import std.stdio : File, writeln;
import std.string : splitLines, strip, toStringz;
import std.uuid : randomUUID;

extern(C) int wait4(int pid, int* status, int options, rusage* usage);
extern(C) int proc_listpids(uint type, uint typeInfo, void* buffer,
    int bufferSize);

private enum recordBytes = 256;
private enum recordCount = 524_288;
private enum runs = 5;
private enum sampleTimeoutSeconds = 900L;
private enum wholeRunTimeoutSeconds = 21_600L;
private enum samplerTimeoutSeconds = 2L;
private enum executableSnapshotMaxBytes = 512UL * 1024 * 1024;
private enum diagnosticFileMaxBytes = 64UL * 1024 * 1024;
private __gshared string launcherPath;
private __gshared Mutex processGroupMutex;
private __gshared int[] activeProcessGroups;
private __gshared bool watchdogFiring;
private MonoTime wholeRunDeadline;
private enum fixtureTablePin =
    "34B08DAEE0547466C0EEF809A0A1BEDBDC4FEE26BEABE23F4478BBDAFFF0727E";
private enum configPin =
    "FC1829939C5EC9347EFBD576978F3EBE017F069C525157FDCC626E8842EBD7FB";

private struct RecordCase { string input, scalar, mixed; }
private immutable RecordCase[] records = [
    RecordCase("plain ASCII unchanged 123\t\n", "plain ASCII unchanged 123\t\n", "plain ASCII unchanged 123\t\n"),
    RecordCase("valid café 😀 unchanged\n", "valid café 😀 unchanged\n", "valid café 😀 unchanged\n"),
    RecordCase("repair cafÃ© and FranÃ§ais\n", "repair cafÃ© and FranÃ§ais\n", "repair café and Français\n"),
    RecordCase("negative © α 中 remains valid\n", "negative © α 中 remains valid\n", "negative © α 中 remains valid\n"),
    RecordCase("entities &amp; &lt; &#33; &unknown;\n", "entities &amp; &lt; &#33; &unknown;\n", "entities & < ! &unknown;\n"),
    RecordCase("quotes “hello” ‘world’ straight \"ok\"\n", "quotes “hello” ‘world’ straight \"ok\"\n", "quotes \"hello\" 'world' straight \"ok\"\n"),
    RecordCase("lines a\r\nb\rc\n", "lines a\nb\nc\n", "lines a\nb\nc\n"),
    RecordCase("control \x01 removed; tab\tand LF\n", "control  removed; tab\tand LF\n", "control  removed; tab\tand LF\n")
];

private struct Layout { string name; size_t files; size_t perFile; }
private immutable Layout[] layouts = [
    Layout("many-small", 4096, 128),
    Layout("few-large", 8, 65_536)
];
private immutable string[string] inputTreePins = [
    "many-small": "5B5D9E66435A5BC705152EB88C551046BE0AA37B51F4FA42A038683AAFB51167",
    "few-large": "A69113BEE8E66CE349C620BD122821F4D0719ABC2263A143E8AA0264CF030548"];
private immutable string[string] outputTreePins = [
    "many-small": "3ED0A176AA89B8B9428FD3F937042EE45781C6FF3546069BB7CF92A4FA6D9529",
    "few-large": "9AAC92A1892B67FCADCAD16E98917446B8077ABB0F8B6826810E5767EACB6DDC"];

private void need(bool value, string message) {
    if (!value) throw new Exception("coordination evidence: " ~ message);
}

private void armWholeRunWatchdog(MonoTime deadline) {
    auto watchdog = new Thread({
        while (MonoTime.currTime < deadline) Thread.sleep(10.msecs);
        processGroupMutex.lock();
        watchdogFiring = true;
        foreach (pid; activeProcessGroups) {
            // Registration precedes the launcher's setpgid handshake. Stop an
            // leader first so it cannot create the group after the group
            // signal. Normal cleanup observes exit without reaping and holds
            // this mutex until the pinned PID/PGID is cleaned and retired.
            foreach (target; watchdogTargets(pid))
                posixKill(target, SIGKILL);
        }
        processGroupMutex.unlock();
        posixKill(getpid(), SIGKILL);
    });
    watchdog.isDaemon = true;
    watchdog.start();
}

private void removeProcessGroupLocked(int pid) {
    foreach (index, active; activeProcessGroups)
        if (active == pid) {
            activeProcessGroups[index] = activeProcessGroups[$ - 1];
            activeProcessGroups.length = activeProcessGroups.length - 1;
            break;
        }
}

private int[] watchdogTargets(int pid) {
    return [pid, -pid];
}

private string hexDigest(const(ubyte)[] value) {
    return toHexString(sha256Of(value)).idup;
}

private string fileDigest(string path) {
    auto input = File(path, "rb");
    ubyte[64 * 1024] buffer;
    SHA256 digest;
    while (!input.eof) {
        auto chunk = input.rawRead(buffer[]);
        if (!chunk.length) break;
        digest.put(chunk);
    }
    return toHexString(digest.finish()).idup;
}

private struct ExecutableSnapshot { string path, digest; }

private string privateScratch(string prefix) {
    auto root = buildPath(tempDir, prefix ~ randomUUID.toString);
    need(mkdir(root.toStringz, S_IRWXU) == 0,
        "cannot create private benchmark scratch directory");
    return root;
}

private ExecutableSnapshot snapshotExecutable(string source, string root,
        string label) {
    need(isFile(source) && !isSymlink(source),
        label ~ " binary must be a regular non-symlink file");
    auto expectedBytes = getSize(source);
    need(expectedBytes <= executableSnapshotMaxBytes &&
        getAvailableDiskSpace(root) >= expectedBytes * 2,
        label ~ " binary exceeds snapshot resource bounds");
    auto destination = buildPath(root, label ~ "-executable");
    auto input = File(source, "rb");
    auto output = File(destination, "wb");
    ubyte[64 * 1024] buffer;
    ulong copied;
    auto deadline = MonoTime.currTime + seconds(120);
    while (copied < expectedBytes) {
        need(MonoTime.currTime < deadline,
            label ~ " executable snapshot exceeded its time bound");
        auto wanted = min(cast(size_t)(expectedBytes - copied), buffer.length);
        auto chunk = input.rawRead(buffer[0 .. wanted]);
        need(chunk.length != 0,
            label ~ " binary shrank while snapshotting");
        output.rawWrite(chunk);
        copied += chunk.length;
    }
    ubyte[1] extra;
    need(input.rawRead(extra[]).length == 0 &&
        getSize(source) == expectedBytes,
        label ~ " binary grew while snapshotting");
    input.close(); output.close();
    need(chmod(destination.toStringz, S_IRUSR | S_IXUSR) == 0,
        label ~ " executable snapshot could not be made read-only");
    need(isFile(destination) && !isSymlink(destination),
        label ~ " executable snapshot differs");
    auto digest = fileDigest(destination);
    need(digest == fileDigest(source), label ~ " binary changed while snapshotting");
    return ExecutableSnapshot(destination, digest);
}

private void verifySnapshot(ref const ExecutableSnapshot snapshot) {
    need(isFile(snapshot.path) && !isSymlink(snapshot.path) &&
        fileDigest(snapshot.path) == snapshot.digest,
        "executable snapshot changed during benchmark");
}

private void publishReport(string reportPath, string text) {
    auto temporary = reportPath ~ ".tmp-" ~ randomUUID.toString;
    scope(exit) if (exists(temporary)) remove(temporary);
    write(temporary, text ~ "\n");
    need(readText(temporary) == text ~ "\n",
        "temporary report reopen differs");
    parseJSON(readText(temporary));
    need(link(temporary.toStringz, reportPath.toStringz) == 0,
        "cannot publish report without overwriting an existing path");
    remove(temporary);
    need(readText(reportPath) == text ~ "\n", "report reopen differs");
}

private string commandOutput(string[] command) {
    auto result = execute(command, [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"],
        Config.newEnv);
    need(result.status == 0, "host identity command failed");
    return result.output.strip.idup;
}

private string inputRecord(size_t index) {
    auto value = records[index % records.length].input;
    auto result = (value ~ cast(string)new char[](recordBytes - value.length)).dup;
    foreach (ref c; result[value.length .. $]) c = 'x';
    return cast(string)result;
}

private string tableIdentity() {
    string value;
    foreach (row; records)
        value ~= row.input.length.to!string ~ ":" ~ row.input ~
            row.scalar.length.to!string ~ ":" ~ row.scalar ~
            row.mixed.length.to!string ~ ":" ~ row.mixed;
    return hexDigest(cast(const(ubyte)[])value);
}

private string configText() {
    return `{"version":3,"stages":[{"id":"legacy-text",` ~
        `"implementation":"text-transform","options":{},"filters":[` ~
        `{"name":"uncurl-quotes","options":{}},` ~
        `{"name":"fix-mojibake","options":{"max-passes":2}},` ~
        `{"name":"decode-html-entities","options":{}},` ~
        `{"name":"normalize-line-endings","options":{}},` ~
        `{"name":"strip-control","options":{}}]}]}`;
}

private void makeFixture(string root, ref const Layout layout) {
    mkdirRecurse(root);
    size_t ordinal;
    foreach (index; 0 .. layout.files) {
        auto file = File(buildPath(root, "doc-" ~ index.to!string ~ ".txt"), "wb");
        foreach (_; 0 .. layout.perFile) file.rawWrite(inputRecord(ordinal++));
    }
    need(ordinal == recordCount, "fixture cardinality differs");
}

private void makeSizeOrderFixture(string root, string variant) {
    enum files = 4096;
    enum largeFiles = 64;
    enum smallRecords = 64; // 16 KiB
    enum largeRecords = 4096; // 1 MiB
    mkdirRecurse(root);
    size_t recordOrdinal;
    foreach (index; 0 .. files) {
        bool large;
        if (variant == "clustered-late") large = index >= files - largeFiles;
        else if (variant == "largest-first") large = index < largeFiles;
        else if (variant == "seeded-distribution")
            large = ((index * 4051) % files) < largeFiles;
        else throw new Exception("unknown size-order fixture");
        auto file = File(buildPath(root, format!"doc-%04d.txt"(index)), "wb");
        foreach (_; 0 .. (large ? largeRecords : smallRecords))
            file.rawWrite(inputRecord(recordOrdinal++));
    }
    string[] names;
    foreach (entry; dirEntries(root, SpanMode.shallow, false))
        names ~= relativePath(entry.name, root);
    names.sort();
    size_t[] largeRanks;
    foreach (rank, name; names) {
        auto index = name[4 .. 8].to!size_t;
        bool large = variant == "clustered-late" ? index >= files - largeFiles :
            variant == "largest-first" ? index < largeFiles :
            ((index * 4051) % files) < largeFiles;
        if (large) largeRanks ~= rank;
    }
    need(largeRanks.length == largeFiles, "size-order large-file count differs");
    if (variant == "clustered-late")
        foreach (offset, rank; largeRanks)
            need(rank == files - largeFiles + offset,
                "clustered-late canonical ranks differ");
    else if (variant == "largest-first")
        foreach (offset, rank; largeRanks)
            need(rank == offset, "largest-first canonical ranks differ");
}

private struct Tree { ulong bytes; string tree; string concatenated; }
private Tree identify(string root) {
    string[] names;
    foreach (entry; dirEntries(root, SpanMode.depth, false)) {
        need(entry.isFile, "tree contains non-file");
        names ~= relativePath(entry.name, root);
    }
    names.sort();
    SHA256 tree, concatenated;
    ulong bytes;
    foreach (name; names) {
        auto body = cast(const(ubyte)[])read(buildPath(root, name));
        auto leaf = hexDigest(body);
        foreach (part; [name, body.length.to!string, leaf]) {
            auto length = part.length.to!string;
            tree.put(cast(const(ubyte)[])length);
            tree.put(cast(const(ubyte)[])":");
            tree.put(cast(const(ubyte)[])part);
        }
        concatenated.put(body); bytes += body.length;
    }
    return Tree(bytes,
        toHexString(tree.finish()).idup,
        toHexString(concatenated.finish()).idup);
}

private ulong micros(ref const typeof(rusage.init.ru_utime) value) {
    return cast(ulong)value.tv_sec * 1_000_000 + value.tv_usec;
}

private string[string] childEnvironment(bool instrumented,
        string metricsPath = "") {
    auto result = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"];
    if (instrumented)
        result["SCRUBBED_COORDINATION_METRICS_V2"] = metricsPath;
    return result;
}

private bool processGroupHasDescendants(int pid,
        bool injectFailureForTest = false) {
    need(!injectFailureForTest, "injected process-group membership failure");
    enum procPgrpOnly = 2U;
    int[16] members;
    errno = 0;
    auto used = proc_listpids(procPgrpOnly, cast(uint)pid, members.ptr,
        cast(int)(members.length * int.sizeof));
    need(errno == 0 && used >= int.sizeof &&
            used <= members.length * int.sizeof,
        "process-group membership could not be read");
    foreach (member; members[0 .. cast(size_t)used / int.sizeof])
        if (member > 0 && member != pid) return true;
    return false;
}

private bool tryReapExited(int pid, out int status, out rusage usage,
        out bool groupClean, bool injectMembershipFailureForTest = false,
        bool allowGroupGrace = false,
        MonoTime groupGraceDeadline = MonoTime.init) {
    processGroupMutex.lock();
    bool mutexHeld = true;
    scope(exit) if (mutexHeld) processGroupMutex.unlock();
    siginfo_t information;
    int observed;
    do observed = waitid(idtype_t.P_PID, cast(uint)pid, &information,
        WEXITED | WNOHANG | WNOWAIT);
    while (observed < 0 && errno == EINTR);
    if (observed < 0)
        need(false, "child exit could not be observed for PID " ~
            pid.to!string ~ " (errno " ~ errno.to!string ~ ")");
    if (information.si_pid != pid) return false;
    auto descendantsRemain = processGroupHasDescendants(pid,
        injectMembershipFailureForTest);
    groupClean = !descendantsRemain;
    if (descendantsRemain && allowGroupGrace) {
        processGroupMutex.unlock();
        mutexHeld = false;
        while (MonoTime.currTime < groupGraceDeadline &&
                processGroupHasDescendants(pid))
            Thread.sleep(10.msecs);
        processGroupMutex.lock();
        mutexHeld = true;
    }
    // The unreaped leader pins both numeric identities while every possible
    // descendant receives the terminal signal.
    posixKill(-pid, SIGKILL);
    int waited;
    do waited = wait4(pid, &status, WNOHANG, &usage);
    while (waited < 0 && errno == EINTR);
    if (waited == pid) removeProcessGroupLocked(pid);
    need(waited == pid, "observed child could not be reaped");
    return true;
}

private bool reapUntil(int pid, MonoTime deadline, out int status,
        out rusage usage, out bool groupClean, bool allowGroupGrace = false,
        MonoTime groupGraceDeadline = MonoTime.init) {
    while (!tryReapExited(pid, status, usage, groupClean, false,
            allowGroupGrace, groupGraceDeadline)) {
        if (MonoTime.currTime >= deadline) return false;
        Thread.sleep(10.msecs);
    }
    return true;
}

private bool reapBlocking(int pid, out int status, out rusage usage,
        bool injectMembershipFailureForTest = false) {
    bool groupClean;
    while (!tryReapExited(pid, status, usage, groupClean,
            injectMembershipFailureForTest))
        Thread.sleep(10.msecs);
    return groupClean;
}

private void signalRegisteredProcess(int pid, int signal,
        bool includeLeader) {
    processGroupMutex.lock();
    foreach (active; activeProcessGroups)
        if (active == pid) {
            if (includeLeader) posixKill(pid, signal);
            posixKill(-pid, signal);
            break;
        }
    processGroupMutex.unlock();
}

private void terminateGroupAndReap(int pid, out int status,
        out rusage usage) {
    signalRegisteredProcess(pid, SIGTERM, true);
    auto graceDeadline = MonoTime.currTime + seconds(1);
    bool groupClean;
    if (!reapUntil(pid, graceDeadline, status, usage, groupClean, true,
            graceDeadline)) {
        signalRegisteredProcess(pid, SIGKILL, true);
        reapBlocking(pid, status, usage);
    }
}

private bool processDisappeared(int pid, MonoTime deadline) {
    while (posixKill(pid, 0) == 0 && MonoTime.currTime < deadline)
        Thread.sleep(10.msecs);
    return posixKill(pid, 0) != 0;
}

private Pid spawnGrouped(string[] command, string readyPath, File stdinFile,
        File stdoutFile, File stderrFile,
        const string[string] environment_, MonoTime deadline,
        long registrationDelayMilliseconds = 0,
        ulong fileLimitBytes = diagnosticFileMaxBytes) {
    // Spawn and register in one short critical section, before waiting for the
    // launcher to create its group. The watchdog kills both PID and -PGID, so
    // it owns the child on either side of that handshake without postponing
    // the hard deadline.
    processGroupMutex.lock();
    if (watchdogFiring) {
        processGroupMutex.unlock();
        need(false, "whole-run watchdog fired before child launch");
    }
    Pid child;
    try child = spawnProcess([launcherPath, "--exec-child", readyPath,
            fileLimitBytes.to!string] ~ command, stdinFile, stdoutFile,
        stderrFile, environment_, Config.newEnv);
    catch (Exception error) {
        processGroupMutex.unlock();
        throw error;
    }
    activeProcessGroups ~= child.processID;
    processGroupMutex.unlock();
    auto readyDeadline = MonoTime.currTime + seconds(2);
    if (deadline < readyDeadline) readyDeadline = deadline;
    while (!exists(readyPath) && MonoTime.currTime < readyDeadline)
        Thread.sleep(1.msecs);
    if (!exists(readyPath)) {
        int status; rusage usage;
        signalRegisteredProcess(child.processID, SIGKILL, true);
        reapBlocking(child.processID, status, usage);
        need(false, "child process group did not become ready");
    }
    if (registrationDelayMilliseconds > 0)
        Thread.sleep(msecs(registrationDelayMilliseconds));
    return child;
}

private string boundedCommandOutput(string[] command, string root,
        string label, MonoTime outerDeadline) {
    if (MonoTime.currTime >= outerDeadline) return null;
    auto stdoutPath = buildPath(root, label ~ "-" ~ randomUUID.toString ~
        ".bounded.out");
    auto stderrPath = stdoutPath ~ ".err";
    auto readyPath = stdoutPath ~ ".ready";
    scope(exit) {
        if (exists(stdoutPath)) remove(stdoutPath);
        if (exists(stderrPath)) remove(stderrPath);
        if (exists(readyPath)) remove(readyPath);
    }
    auto stdinFile = File("/dev/null", "rb");
    auto stdoutFile = File(stdoutPath, "wb");
    auto stderrFile = File(stderrPath, "wb");
    auto commandDeadline = MonoTime.currTime +
        seconds(samplerTimeoutSeconds);
    if (outerDeadline < commandDeadline) commandDeadline = outerDeadline;
    Pid child;
    try child = spawnGrouped(command, readyPath, stdinFile, stdoutFile,
        stderrFile, childEnvironment(false), commandDeadline);
    catch (Exception) return null;
    stdinFile.close(); stdoutFile.close(); stderrFile.close();
    int status; rusage usage; bool groupClean;
    if (!reapUntil(child.processID, commandDeadline, status, usage,
            groupClean)) {
        terminateGroupAndReap(child.processID, status, usage);
        return null;
    }
    if (!groupClean) return null;
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) return null;
    if (getSize(stdoutPath) > diagnosticFileMaxBytes ||
        getSize(stderrPath) > diagnosticFileMaxBytes) return null;
    return readText(stdoutPath);
}

private JSONValue invoke(string binary, string input, string output,
        string config, size_t threads, size_t ordinal, string root,
        bool instrumented, string expectedBinaryDigest,
        bool injectProbeFailure = false,
        long timeoutSeconds = sampleTimeoutSeconds) {
    need(MonoTime.currTime < wholeRunDeadline,
        "whole-run deadline expired before a sample started");
    need(fileDigest(binary) == expectedBinaryDigest,
        "executable snapshot changed before invocation");
    auto sampleDeadline = MonoTime.currTime + seconds(timeoutSeconds);
    if (wholeRunDeadline < sampleDeadline) sampleDeadline = wholeRunDeadline;
    auto label = (instrumented ? "attribution-" : "performance-") ~
        threads.to!string ~ "-" ~ ordinal.to!string ~ "-" ~
        randomUUID.toString;
    auto metricsPath = buildPath(root, label ~ ".metrics.json");
    auto stdoutPath = buildPath(root, label ~ ".out");
    auto stderrPath = buildPath(root, label ~ ".err");
    auto stdinFile = File("/dev/null", "rb");
    auto stdoutFile = File(stdoutPath, "wb");
    auto stderrFile = File(stderrPath, "wb");
    string[] command = [binary];
    if (instrumented && ordinal == 0) command ~= "--DRT-gcopt=profile:2";
    command ~= ["run", "--input", input, "--output", output, "--config", config,
        "--threads", threads.to!string, "--max-open-inputs", threads.to!string];
    auto timer = StopWatch(AutoStart.yes);
    auto readyPath = buildPath(root, label ~ ".ready");
    auto child = spawnGrouped(command, readyPath, stdinFile, stdoutFile,
        stderrFile, childEnvironment(instrumented, metricsPath),
        sampleDeadline);
    stdinFile.close(); stdoutFile.close(); stderrFile.close();
    bool childReaped;
    scope(failure) if (!childReaped) {
        int cleanupStatus; rusage cleanupUsage;
        terminateGroupAndReap(child.processID, cleanupStatus, cleanupUsage);
    }
    shared bool stopped;
    shared bool diagnosticOverflow;
    shared size_t peakFd;
    auto sampler = new Thread({
        while (!atomicLoad(stopped) && MonoTime.currTime < sampleDeadline) {
            if (getSize(stdoutPath) > diagnosticFileMaxBytes ||
                    getSize(stderrPath) > diagnosticFileMaxBytes) {
                atomicStore(diagnosticOverflow, true);
                signalRegisteredProcess(child.processID, SIGKILL, false);
                break;
            }
            auto seen = boundedCommandOutput(["/usr/sbin/lsof", "-p",
                child.processID.to!string], root, label ~ "-lsof",
                sampleDeadline);
            if (seen.length) {
                auto count = seen.splitLines.length;
                if (count) --count;
                if (count > atomicLoad(peakFd)) atomicStore(peakFd, count);
            }
            Thread.sleep(10.msecs);
        }
    });
    sampler.start();
    bool samplerJoined;
    scope(exit) if (!samplerJoined) {
        atomicStore(stopped, true);
        sampler.join();
    }
    if (injectProbeFailure) {
        auto injectionDeadline = MonoTime.currTime + seconds(1);
        while (!exists(config) && MonoTime.currTime < injectionDeadline)
            Thread.sleep(1.msecs);
        need(exists(config),
            "post-spawn cleanup probe did not become ready");
        throw new Exception("injected post-spawn probe failure");
    }
    string stackStatus = "not-attempted", stackHash;
    if (instrumented && ordinal == 0) {
        auto stackPath = buildPath(root, label ~ ".sample.txt");
        auto sampled = boundedCommandOutput(["/usr/bin/sample",
            child.processID.to!string, "1", "10", "-file", stackPath],
            root, label ~ "-sample", sampleDeadline);
        if (sampled.length && exists(stackPath) &&
                getSize(stackPath) <= diagnosticFileMaxBytes) {
            auto body = cast(const(ubyte)[])read(stackPath);
            stackStatus = body.length ? "supported" : "unsupported-empty";
            if (body.length) stackHash = hexDigest(body);
        } else stackStatus = "unsupported-sample-failed";
    }
    int status; rusage usage; bool groupClean;
    childReaped = reapUntil(child.processID, sampleDeadline, status, usage,
        groupClean);
    bool timedOut = !childReaped;
    if (timedOut) {
        terminateGroupAndReap(child.processID, status, usage);
        childReaped = true;
    } else need(groupClean,
        "child exited while descendants remained in its process group");
    timer.stop();
    atomicStore(stopped, true); sampler.join();
    samplerJoined = true;
    need(!timedOut, "child exceeded the per-sample deadline");
    need(!atomicLoad(diagnosticOverflow) &&
        getSize(stdoutPath) <= diagnosticFileMaxBytes &&
        getSize(stderrPath) <= diagnosticFileMaxBytes,
        "child diagnostics exceeded their byte bound");
    need(WIFEXITED(status) && WEXITSTATUS(status) == 0,
        "child failed: " ~ readText(stderrPath));
    auto log = readText(stdoutPath);
    need(log.canFind("done. "), "missing completion diagnostic");
    if (instrumented && ordinal == 0)
        need(log.canFind("GC summary:"), "missing D-GC summary");
    auto result = JSONValue([
        "threads": JSONValue(cast(long)threads),
        "ordinal": JSONValue(cast(long)ordinal),
        "wall_us": JSONValue(timer.peek.total!"usecs"),
        "user_us": JSONValue(cast(long)micros(usage.ru_utime)),
        "system_us": JSONValue(cast(long)micros(usage.ru_stime)),
        "peak_rss_bytes": JSONValue(cast(long)usage.ru_opaque[0]),
        "sampled_fd_peak": JSONValue(cast(long)atomicLoad(peakFd)),
        "log_sha256": JSONValue(hexDigest(cast(const(ubyte)[])log)),
        "stack_status": JSONValue(stackStatus),
        "stack_sha256": JSONValue(stackHash),
        "d_gc_status": JSONValue(instrumented && ordinal == 0 ?
            "supported" : "not-attempted"),
        "syscall_status": JSONValue("unsupported-no-exact-child-counter")]);
    if (instrumented) {
        need(getSize(metricsPath) <= diagnosticFileMaxBytes,
            "coordination metrics exceeded their byte bound");
        auto metrics = parseJSON(readText(metricsPath));
        need(metrics["schema"].str == "scrubbed.coordination-metrics.v2",
            "metrics schema differs");
        result["metrics"] = metrics;
    }
    need(fileDigest(binary) == expectedBinaryDigest,
        "executable snapshot changed during invocation");
    return result;
}

private void requireKeys(ref JSONValue value, string[] expected,
        string label) {
    need(value.type == JSONType.object, label ~ " must be an object");
    need(value.object.length == expected.length,
        label ~ " field cardinality differs");
    foreach (key; expected)
        need((key in value.object) !is null, label ~ " omitted " ~ key);
}

private long metricInteger(ref JSONValue value, string key, string label) {
    auto result = value[key].integer;
    need(result >= 0, label ~ " contains negative " ~ key);
    return result;
}

private void validateMetrics(ref JSONValue sample, size_t expectedFiles,
        ulong expectedBytes) {
    auto metrics = sample["metrics"];
    requireKeys(metrics, ["schema", "version", "wall_nanoseconds", "limits",
        "counts", "phases"], "metrics");
    need(metrics["schema"].str == "scrubbed.coordination-metrics.v2" &&
        metrics["version"].integer == 2,
        "metrics revision differs");
    need(metricInteger(metrics, "wall_nanoseconds", "metrics") > 0,
        "metrics wall duration is empty");
    auto limits = metrics["limits"];
    requireKeys(limits, ["queued_documents", "reserved_bytes",
        "worker_descriptors"], "metrics limits");
    auto queuedLimit = metricInteger(limits, "queued_documents", "limits");
    auto byteLimit = metricInteger(limits, "reserved_bytes", "limits");
    auto descriptorLimit = metricInteger(limits, "worker_descriptors", "limits");
    need(queuedLimit > 0 && byteLimit > 0 && descriptorLimit > 0,
        "metrics limits must be positive");
    auto counts = metrics["counts"];
    requireKeys(counts, ["queued_documents", "reserved_bytes",
        "worker_descriptors", "peak_queued_documents", "peak_reserved_bytes",
        "peak_worker_descriptors", "submitted", "succeeded", "failed",
        "skipped"], "metrics counts");
    foreach (key; ["queued_documents", "reserved_bytes", "worker_descriptors",
            "peak_queued_documents", "peak_reserved_bytes",
            "peak_worker_descriptors", "submitted", "succeeded", "failed",
            "skipped"])
        metricInteger(counts, key, "counts");
    need(counts["submitted"].integer == expectedFiles &&
        counts["succeeded"].integer == expectedFiles &&
        counts["failed"].integer == 0 && counts["skipped"].integer == 0 &&
        counts["queued_documents"].integer == 0 &&
        counts["reserved_bytes"].integer == 0 &&
        counts["worker_descriptors"].integer == 0 &&
        counts["peak_queued_documents"].integer <= queuedLimit &&
        counts["peak_reserved_bytes"].integer <= byteLimit &&
        counts["peak_worker_descriptors"].integer <= descriptorLimit,
        "terminal/reservation accounting differs");
    auto phases = metrics["phases"];
    auto rootPhases = ["source_stat", "ordinal_assignment", "admission_wait",
            "accepted_worker_queue", "descriptor_wait", "descriptor_hold",
            "transform", "ordered_result_wait", "atomic_publication"];
    requireKeys(phases, ["discovery"] ~ rootPhases ~ ["shutdown_join"],
        "metrics phases");
    foreach (name; ["discovery"] ~ rootPhases ~ ["shutdown_join"]) {
        auto phase = phases[name];
        requireKeys(phase, ["calls", "units", "nanoseconds"],
            "metrics phase " ~ name);
        foreach (key; ["calls", "units", "nanoseconds"])
            metricInteger(phase, key, "metrics phase " ~ name);
    }
    foreach (name; rootPhases)
        need(phases[name]["calls"].integer == expectedFiles,
            name ~ " root count differs");
    need(phases["discovery"]["calls"].integer == 1 &&
        phases["discovery"]["units"].integer == expectedFiles &&
        phases["source_stat"]["units"].integer == expectedFiles &&
        phases["ordinal_assignment"]["units"].integer == expectedFiles &&
        phases["admission_wait"]["units"].integer == expectedBytes &&
        phases["accepted_worker_queue"]["units"].integer == expectedBytes &&
        phases["accepted_worker_queue"]["nanoseconds"].integer > 0,
        "accepted-worker queue accounting differs");
    need(phases["descriptor_wait"]["units"].integer == expectedBytes &&
        phases["descriptor_hold"]["units"].integer == expectedBytes &&
        phases["transform"]["units"].integer == expectedBytes &&
        phases["transform"]["nanoseconds"].integer > 0 &&
        phases["ordered_result_wait"]["units"].integer == 0 &&
        phases["atomic_publication"]["units"].integer > 0,
        "transform byte accounting differs");
    need(phases["shutdown_join"]["calls"].integer == 1 &&
        phases["shutdown_join"]["units"].integer == 0,
        "shutdown count differs");
    auto processCpuNanoseconds =
        (sample["user_us"].integer + sample["system_us"].integer) * 1_000;
    need(phases["transform"]["nanoseconds"].integer <=
        processCpuNanoseconds + 1_000_000,
        "transform CPU exceeds whole-process CPU");
}

private void runSelfTest(string harnessPath) {
    auto root = privateScratch("scrubbed-coordination-self-test-");
    scope(exit) if (exists(root)) rmdirRecurse(root);
    need((getAttributes(root) & 511) == S_IRWXU,
        "benchmark scratch permissions differ");
    need(watchdogTargets(73) == [73, -73],
        "watchdog does not stop an unreaped leader before its process group");

    auto mutableExecutable = buildPath(root, "mutable-executable");
    write(mutableExecutable, "#!/bin/sh\nexit 0\n");
    setAttributes(mutableExecutable, getAttributes(harnessPath));
    auto snapshot = snapshotExecutable(mutableExecutable, root, "self-test");
    auto snapshotDigest = fileDigest(snapshot.path);
    write(mutableExecutable, "replaced after snapshot\n");
    need(fileDigest(snapshot.path) == snapshotDigest &&
        fileDigest(mutableExecutable) != snapshotDigest,
        "executable snapshot followed mutable source");

    need(chmod(snapshot.path.toStringz, S_IRUSR | S_IWUSR | S_IXUSR) == 0,
        "cannot make self-test snapshot writable");
    write(snapshot.path, "changed snapshot\n");
    bool changedSnapshotRejected;
    try verifySnapshot(snapshot);
    catch (Exception) { changedSnapshotRejected = true; }
    need(changedSnapshotRejected, "changed executable snapshot was accepted");

    auto membershipOut = buildPath(root, "membership-failure.out");
    auto membershipErr = buildPath(root, "membership-failure.err");
    auto membershipReady = buildPath(root, "membership-failure.ready");
    auto membershipInputFile = File("/dev/null", "rb");
    auto membershipOutputFile = File(membershipOut, "wb");
    auto membershipErrorFile = File(membershipErr, "wb");
    auto membershipChild = spawnGrouped(["/usr/bin/true"], membershipReady,
        membershipInputFile, membershipOutputFile, membershipErrorFile,
        childEnvironment(false), MonoTime.currTime + seconds(5));
    membershipInputFile.close(); membershipOutputFile.close();
    membershipErrorFile.close();
    int membershipStatus; rusage membershipUsage;
    bool membershipFailureObserved;
    try reapBlocking(membershipChild.processID, membershipStatus,
        membershipUsage, true);
    catch (Exception error)
        membershipFailureObserved = error.msg ==
            "coordination evidence: injected process-group membership failure";
    need(membershipFailureObserved,
        "injected membership failure did not reach the reap boundary");
    processGroupMutex.lock();
    processGroupMutex.unlock();
    need(reapBlocking(membershipChild.processID, membershipStatus,
            membershipUsage),
        "membership failure prevented retrying registered-child cleanup");

    auto environmentProbe = buildPath(root, "environment-probe");
    write(environmentProbe,
        "#!/bin/sh\n" ~
        "test -z \"$SCRUBBED_COORDINATION_METRICS_V2\" || exit 7\n" ~
        "test -z \"$SCRUBBED_DURABLE_METRICS_V1\" || exit 8\n" ~
        "echo 'done. environment clean'\n");
    need(chmod(environmentProbe.toStringz, S_IRUSR | S_IXUSR) == 0,
        "cannot make environment probe executable");
    auto priorMetricsEnvironment =
        environment.get("SCRUBBED_COORDINATION_METRICS_V2", "");
    scope(exit) {
        if (priorMetricsEnvironment.length)
            environment["SCRUBBED_COORDINATION_METRICS_V2"] =
                priorMetricsEnvironment;
        else environment.remove("SCRUBBED_COORDINATION_METRICS_V2");
    }
    environment["SCRUBBED_COORDINATION_METRICS_V2"] = "ambient-must-not-leak";
    auto priorDurableEnvironment =
        environment.get("SCRUBBED_DURABLE_METRICS_V1", "");
    scope(exit) {
        if (priorDurableEnvironment.length)
            environment["SCRUBBED_DURABLE_METRICS_V1"] =
                priorDurableEnvironment;
        else environment.remove("SCRUBBED_DURABLE_METRICS_V1");
    }
    environment["SCRUBBED_DURABLE_METRICS_V1"] = "ambient-must-not-leak";
    invoke(environmentProbe, root, root, root, 1, 1, root, false,
        fileDigest(environmentProbe));

    auto overflowProbe = buildPath(root, "diagnostic-overflow-probe");
    write(overflowProbe, "#!/bin/sh\n" ~
        "/bin/dd if=/dev/zero bs=1048576 count=2 2>/dev/null\n");
    need(chmod(overflowProbe.toStringz, S_IRUSR | S_IXUSR) == 0,
        "cannot make diagnostic overflow probe executable");
    auto overflowOut = buildPath(root, "diagnostic-overflow.out");
    auto overflowErr = buildPath(root, "diagnostic-overflow.err");
    auto overflowReady = buildPath(root, "diagnostic-overflow.ready");
    auto overflowInputFile = File("/dev/null", "rb");
    auto overflowOutputFile = File(overflowOut, "wb");
    auto overflowErrorFile = File(overflowErr, "wb");
    enum testFileLimit = 1024UL * 1024;
    auto overflowChild = spawnGrouped([overflowProbe], overflowReady,
        overflowInputFile, overflowOutputFile, overflowErrorFile,
        childEnvironment(false), MonoTime.currTime + seconds(5), 0,
        testFileLimit);
    overflowInputFile.close(); overflowOutputFile.close();
    overflowErrorFile.close();
    int overflowStatus; rusage overflowUsage;
    auto overflowGroupClean = reapBlocking(overflowChild.processID,
        overflowStatus, overflowUsage);
    need(overflowGroupClean &&
        (!WIFEXITED(overflowStatus) || WEXITSTATUS(overflowStatus) != 0) &&
        getSize(overflowOut) <= testFileLimit,
        "diagnostic output exceeded its write-time file-size limit");

    auto leakyProbe = buildPath(root, "leaky-success-probe");
    auto leakyPidPath = buildPath(root, "leaky-success-descendant.pid");
    write(leakyProbe, "#!/bin/sh\n" ~
        "sh -c 'trap \"\" TERM; while :; do sleep 1; done' &\n" ~
        "echo $! > '" ~ leakyPidPath ~ "'\n" ~
        "echo 'done. leaky leader'\n");
    need(chmod(leakyProbe.toStringz, S_IRUSR | S_IXUSR) == 0,
        "cannot make leaky-success probe executable");
    bool leakySuccessRejected;
    try invoke(leakyProbe, root, root, root, 1, 2, root, false,
        fileDigest(leakyProbe), false, 5);
    catch (Exception error)
        leakySuccessRejected = error.msg.canFind(
            "descendants remained in its process group");
    need(leakySuccessRejected && exists(leakyPidPath),
        "successful leader with a live descendant was accepted");
    auto leakyPid = readText(leakyPidPath).strip.to!int;
    need(processDisappeared(leakyPid, MonoTime.currTime + seconds(1)),
        "successful leader left a descendant running");
    auto hangingProbe = buildPath(root, "hanging-probe");
    auto descendantPidPath = buildPath(root, "hanging-descendant.pid");
    write(hangingProbe, "#!/bin/sh\n" ~
        "trap 'exit 0' TERM\n" ~
        "sh -c 'trap \"\" TERM; while :; do sleep 1; done' &\n" ~
        "echo $! > '" ~ descendantPidPath ~ "'\n" ~
        "wait\n");
    need(chmod(hangingProbe.toStringz, S_IRUSR | S_IXUSR) == 0,
        "cannot make hanging probe executable");
    auto gracefulProbe = buildPath(root, "graceful-probe");
    auto gracefulReady = buildPath(root, "graceful-descendant.ready");
    auto gracefulMarker = buildPath(root, "graceful-descendant.done");
    write(gracefulProbe, "#!/bin/sh\n" ~
        "sh -c 'trap \"echo graceful > " ~ gracefulMarker ~
            "; exit 0\" TERM; echo ready > " ~ gracefulReady ~
            "; while :; do :; done' &\n" ~
        "wait\n");
    need(chmod(gracefulProbe.toStringz, S_IRUSR | S_IXUSR) == 0,
        "cannot make graceful cleanup probe executable");
    auto gracefulOut = buildPath(root, "graceful-probe.out");
    auto gracefulErr = buildPath(root, "graceful-probe.err");
    auto gracefulLaunchReady = buildPath(root, "graceful-probe.ready");
    auto gracefulInputFile = File("/dev/null", "rb");
    auto gracefulOutputFile = File(gracefulOut, "wb");
    auto gracefulErrorFile = File(gracefulErr, "wb");
    auto gracefulChild = spawnGrouped([gracefulProbe], gracefulLaunchReady,
        gracefulInputFile, gracefulOutputFile, gracefulErrorFile,
        childEnvironment(false), MonoTime.currTime + seconds(5));
    gracefulInputFile.close(); gracefulOutputFile.close();
    gracefulErrorFile.close();
    auto gracefulSetupDeadline = MonoTime.currTime + seconds(1);
    while (!exists(gracefulReady) && MonoTime.currTime < gracefulSetupDeadline)
        Thread.sleep(1.msecs);
    need(exists(gracefulReady), "graceful descendant did not become ready");
    int gracefulStatus; rusage gracefulUsage;
    terminateGroupAndReap(gracefulChild.processID, gracefulStatus,
        gracefulUsage);
    need(exists(gracefulMarker),
        "TERM grace did not let a cooperative descendant finish");
    bool cleanupFailureObserved;
    try invoke(hangingProbe, root, root, descendantPidPath, 1, 0, root, false,
        fileDigest(hangingProbe), true, 5);
    catch (Exception error) {
        cleanupFailureObserved = error.msg == "injected post-spawn probe failure";
    }
    need(cleanupFailureObserved && exists(descendantPidPath),
        "post-spawn cleanup injection differed");
    auto cleanupDescendantPid = readText(descendantPidPath).strip.to!int;
    need(processDisappeared(cleanupDescendantPid,
            MonoTime.currTime + seconds(1)),
        "post-spawn cleanup left a descendant running");
    remove(descendantPidPath);
    bool deadlineObserved;
    string deadlineError;
    try invoke(hangingProbe, root, root, root, 1, 2, root, false,
        fileDigest(hangingProbe), false, 1);
    catch (Exception error) {
        deadlineError = error.msg;
        deadlineObserved = error.msg.canFind(
            "child exceeded the per-sample deadline");
    }
    need(deadlineObserved, "hung child did not reach the bounded deadline: " ~
        deadlineError);
    need(exists(descendantPidPath),
        "hanging probe did not record its descendant");
    auto descendantPid = readText(descendantPidPath).strip.to!int;
    need(processDisappeared(descendantPid, MonoTime.currTime + seconds(1)),
        "timed-out process group left a descendant running");
    remove(descendantPidPath);

    auto watchdogOut = buildPath(root, "whole-watchdog.out");
    auto watchdogErr = buildPath(root, "whole-watchdog.err");
    auto watchdogReady = buildPath(root, "whole-watchdog.ready");
    auto watchdogInput = File("/dev/null", "rb");
    auto watchdogOutput = File(watchdogOut, "wb");
    auto watchdogError = File(watchdogErr, "wb");
    auto watchdogDeadline = MonoTime.currTime + seconds(4);
    auto watchdogTimer = StopWatch(AutoStart.yes);
    auto watchdogChild = spawnGrouped(
        [harnessPath, "--self-test-whole-timeout-probe", hangingProbe, root],
        watchdogReady,
        watchdogInput, watchdogOutput, watchdogError, childEnvironment(false),
        watchdogDeadline);
    watchdogInput.close(); watchdogOutput.close(); watchdogError.close();
    int watchdogStatus; rusage watchdogUsage;
    bool watchdogGroupClean;
    auto watchdogReaped = reapUntil(watchdogChild.processID,
        watchdogDeadline, watchdogStatus, watchdogUsage,
        watchdogGroupClean);
    watchdogTimer.stop();
    if (!watchdogReaped)
        terminateGroupAndReap(watchdogChild.processID, watchdogStatus,
            watchdogUsage);
    else
        need(watchdogGroupClean,
            "whole-run watchdog left its registered process group alive");
    need(watchdogReaped && WIFSIGNALED(watchdogStatus) &&
        WTERMSIG(watchdogStatus) == SIGKILL &&
        watchdogTimer.peek.total!"msecs" < 2_000,
        "whole-run watchdog did not terminate a stalled non-child phase");
    need(exists(descendantPidPath),
        "whole-run watchdog probe did not record its descendant");
    auto watchdogDescendantPid = readText(descendantPidPath).strip.to!int;
    need(processDisappeared(watchdogDescendantPid,
            MonoTime.currTime + seconds(1)),
        "whole-run watchdog left a descendant running");

    enum validMetrics = `{"user_us":1000,"system_us":1000,"metrics":{` ~
        `"schema":"scrubbed.coordination-metrics.v2","version":2,` ~
        `"wall_nanoseconds":1000,` ~
        `"limits":{"queued_documents":1,"reserved_bytes":1,` ~
        `"worker_descriptors":1},` ~
        `"counts":{"submitted":1,"succeeded":1,"failed":0,"skipped":0,` ~
        `"queued_documents":0,"reserved_bytes":0,"worker_descriptors":0,` ~
        `"peak_queued_documents":1,"peak_reserved_bytes":1,` ~
        `"peak_worker_descriptors":1},` ~
        `"phases":{` ~
        `"discovery":{"calls":1,"units":1,"nanoseconds":1},` ~
        `"source_stat":{"calls":1,"units":1,"nanoseconds":1},` ~
        `"ordinal_assignment":{"calls":1,"units":1,"nanoseconds":1},` ~
        `"admission_wait":{"calls":1,"units":1,"nanoseconds":1},` ~
        `"accepted_worker_queue":{"calls":1,"units":1,"nanoseconds":1},` ~
        `"descriptor_wait":{"calls":1,"units":1,"nanoseconds":1},` ~
        `"descriptor_hold":{"calls":1,"units":1,"nanoseconds":1},` ~
        `"transform":{"calls":1,"units":1,"nanoseconds":1},` ~
        `"ordered_result_wait":{"calls":1,"units":0,"nanoseconds":1},` ~
        `"atomic_publication":{"calls":1,"units":1,"nanoseconds":1},` ~
        `"shutdown_join":{"calls":1,"units":0,"nanoseconds":1}}}}`;
    auto valid = parseJSON(validMetrics);
    validateMetrics(valid, 1, 1);
    auto invalid = parseJSON(validMetrics);
    invalid["metrics"]["phases"]["accepted_worker_queue"]["calls"] = 0;
    bool invalidRejected;
    try validateMetrics(invalid, 1, 1);
    catch (Exception) { invalidRejected = true; }
    need(invalidRejected, "zeroed comparison attribution was accepted");
    invalid = parseJSON(validMetrics);
    invalid["metrics"]["version"] = 999;
    invalidRejected = false;
    try validateMetrics(invalid, 1, 1);
    catch (Exception) { invalidRejected = true; }
    need(invalidRejected, "mismatched metrics revision was accepted");
    invalid = parseJSON(validMetrics);
    invalid["metrics"]["unexpected"] = 1;
    invalidRejected = false;
    try validateMetrics(invalid, 1, 1);
    catch (Exception) { invalidRejected = true; }
    need(invalidRejected, "unexpected metrics field was accepted");
    invalid = parseJSON(validMetrics);
    invalid["metrics"]["phases"]["transform"]["nanoseconds"] = 0;
    invalidRejected = false;
    try validateMetrics(invalid, 1, 1);
    catch (Exception) { invalidRejected = true; }
    need(invalidRejected, "zero transform CPU duration was accepted");
    auto reportPath = buildPath(root, "atomic-report.json");
    publishReport(reportPath, `{"schema":"self-test"}`);
    need(parseJSON(readText(reportPath))["schema"].str == "self-test",
        "atomic report publication differed");
    bool overwriteRejected;
    try publishReport(reportPath, `{"schema":"replacement"}`);
    catch (Exception) { overwriteRejected = true; }
    need(overwriteRejected &&
        parseJSON(readText(reportPath))["schema"].str == "self-test",
        "report publication overwrote an existing path");

    need(withinFivePercent(100_000, 105_000) &&
        !withinFivePercent(100_000, 105_001) &&
        !withinFivePercent(100_000, 105_009) &&
        !withinFivePercent(1, long.max) &&
        withinFivePercent(long.max, long.max),
        "exact five-percent control boundary differs");
    need(atLeastTenPercentFaster(100, 90) &&
        !atLeastTenPercentFaster(101, 91) &&
        !atLeastTenPercentFaster(long.max, long.max),
        "exact ten-percent target boundary differs");

    writeln("coordination profile self-test: ok");
}

private long[] values(JSONValue[] samples, size_t threads, string field) {
    long[] result;
    foreach (sample; samples) if (sample["threads"].integer == threads) {
        if (field != "cpu_us") {
            auto value = sample[field].integer;
            need(value >= 0, "comparison sample value is negative");
            result ~= value;
        } else {
            auto user = sample["user_us"].integer;
            auto system = sample["system_us"].integer;
            need(user >= 0 && system >= 0 && user <= long.max - system,
                "comparison CPU value is invalid");
            result ~= user + system;
        }
    }
    result.sort();
    return result;
}

private long median(JSONValue[] samples, size_t threads, string field) {
    auto ordered = values(samples, threads, field);
    need(ordered.length == runs, "comparison sample cardinality differs");
    return ordered[ordered.length / 2];
}

private long sampleValue(JSONValue[] samples, size_t threads,
        size_t ordinal, string field) {
    foreach (sample; samples)
        if (sample["threads"].integer == threads &&
                sample["ordinal"].integer == ordinal) {
            if (field != "cpu_us") {
                auto value = sample[field].integer;
                need(value >= 0, "comparison sample value is negative");
                return value;
            }
            auto user = sample["user_us"].integer;
            auto system = sample["system_us"].integer;
            need(user >= 0 && system >= 0 && user <= long.max - system,
                "comparison CPU value is invalid");
            return user + system;
        }
    throw new Exception("comparison sample missing");
}

private bool withinFivePercent(long baseline, long candidate) {
    need(baseline > 0 && candidate >= 0,
        "comparison control values must be nonnegative with positive baseline");
    return candidate <= baseline || candidate - baseline <= baseline / 20;
}

private bool atLeastTenPercentFaster(long baseline, long candidate) {
    need(baseline > 0 && candidate >= 0,
        "comparison target values must be nonnegative with positive baseline");
    if (candidate >= baseline) return false;
    auto requiredImprovement = baseline / 10 + (baseline % 10 != 0 ? 1 : 0);
    return baseline - candidate >= requiredImprovement;
}

private bool pairedMedianWithinFivePercent(JSONValue[] baseline,
        JSONValue[] candidate, size_t threads, string field) {
    size_t passing;
    foreach (round; 0 .. runs) {
        auto base = sampleValue(baseline, threads, round, field);
        auto changed = sampleValue(candidate, threads, round, field);
        if (withinFivePercent(base, changed)) ++passing;
    }
    return passing > runs / 2;
}

private void runComparison(string[] args) {
    auto baseline = absolutePath(args[2]);
    auto candidate = absolutePath(args[3]);
    auto reportPath = absolutePath(args[4]);
    need(exists(baseline) && exists(candidate) && !exists(reportPath),
        "comparison binary missing or measurement exists");
    need(tableIdentity() == fixtureTablePin, "fixture table pin differs");
    auto root = privateScratch("scrubbed-coordination-compare-");
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto baselineSnapshot = snapshotExecutable(baseline, root, "baseline");
    auto candidateSnapshot = snapshotExecutable(candidate, root, "candidate");
    baseline = baselineSnapshot.path;
    candidate = candidateSnapshot.path;
    auto harnessDigest = fileDigest(absolutePath(args[0]));
    auto config = buildPath(root, "mixed-v3.json");
    write(config, configText());
    need(fileDigest(config) == configPin, "config pin differs");
    JSONValue[] layoutReports;
    bool controlsPass = true;
    size_t targetWins;
    long targetBaselineWall, targetCandidateWall;
    JSONValue[] baselineAttribution, candidateAttribution;
    foreach (ref layout; layouts) {
        auto input = buildPath(root, layout.name ~ "-input");
        makeFixture(input, layout);
        auto inputId = identify(input);
        need(inputId.tree == inputTreePins[layout.name], "input tree pin differs");
        JSONValue[] baselineSamples, candidateSamples;
        foreach (round; 0 .. runs) foreach (threads; [1, 2, 4]) {
            foreach (candidateFirst; [round % 2 == 1, round % 2 == 0]) {
                auto isCandidate = candidateFirst;
                auto binary = isCandidate ? candidate : baseline;
                auto output = buildPath(root, layout.name ~
                    (isCandidate ? "-candidate-" : "-baseline-") ~
                    threads.to!string ~ "-" ~ round.to!string);
                auto sample = invoke(binary, input, output, config, threads,
                    round, root, false, isCandidate ?
                        candidateSnapshot.digest : baselineSnapshot.digest);
                auto outputId = identify(output);
                need(outputId.tree == outputTreePins[layout.name],
                    "comparison exact output tree pin differs");
                sample["output_bytes"] = cast(long)outputId.bytes;
                sample["output_tree_sha256"] = outputId.tree;
                sample["output_concatenated_sha256"] = outputId.concatenated;
                if (isCandidate) candidateSamples ~= sample;
                else baselineSamples ~= sample;
                rmdirRecurse(output);
            }
        }
        foreach (threads; [1, 2, 4]) {
            auto baselineWall = median(baselineSamples, threads, "wall_us");
            auto candidateWall = median(candidateSamples, threads, "wall_us");
            if (layout.name == "many-small" && threads == 4) {
                targetBaselineWall = baselineWall;
                targetCandidateWall = candidateWall;
                foreach (round; 0 .. runs)
                    if (sampleValue(candidateSamples, threads, round, "wall_us") <
                            sampleValue(baselineSamples, threads, round, "wall_us"))
                        ++targetWins;
            }
            if (threads == 1 || layout.name == "few-large") {
                foreach (field; ["wall_us", "cpu_us", "peak_rss_bytes",
                        "sampled_fd_peak"])
                    controlsPass = controlsPass && pairedMedianWithinFivePercent(
                        baselineSamples, candidateSamples, threads, field);
            }
        }
        if (layout.name == "many-small")
        foreach (round; 0 .. runs) foreach (candidateFirst;
                [round % 2 == 1, round % 2 == 0]) {
            auto isCandidate = candidateFirst;
            auto binary = isCandidate ? candidate : baseline;
            auto output = buildPath(root, "many-small-attribution-" ~
                (isCandidate ? "candidate-" : "baseline-") ~ round.to!string);
            auto sample = invoke(binary, input, output, config, 4, round,
                root, true, isCandidate ?
                    candidateSnapshot.digest : baselineSnapshot.digest);
            validateMetrics(sample, layout.files, inputId.bytes);
            auto outputId = identify(output);
            need(outputId.tree == outputTreePins[layout.name],
                "comparison attribution output tree pin differs");
            sample["output_bytes"] = cast(long)outputId.bytes;
            sample["output_tree_sha256"] = outputId.tree;
            sample["output_concatenated_sha256"] = outputId.concatenated;
            if (isCandidate) candidateAttribution ~= sample;
            else baselineAttribution ~= sample;
            rmdirRecurse(output);
        }
        layoutReports ~= JSONValue([
            "layout": JSONValue(layout.name),
            "files": JSONValue(cast(long)layout.files),
            "input_bytes": JSONValue(cast(long)inputId.bytes),
            "input_tree_sha256": JSONValue(inputId.tree),
            "baseline_samples": JSONValue(baselineSamples),
            "candidate_samples": JSONValue(candidateSamples)]);
    }
    auto waitField = "accepted_worker_queue";
    long[] baselineWait, candidateWait;
    foreach (sample; baselineAttribution)
        baselineWait ~= sample["metrics"]["phases"][waitField]["nanoseconds"].integer;
    foreach (sample; candidateAttribution)
        candidateWait ~= sample["metrics"]["phases"][waitField]["nanoseconds"].integer;
    baselineWait.sort(); candidateWait.sort();
    auto waitFalls = candidateWait[runs / 2] < baselineWait[runs / 2];
    auto thresholdsSatisfied = targetWins >= 4 &&
        atLeastTenPercentFaster(targetBaselineWall, targetCandidateWall) &&
        waitFalls && controlsPass;
    auto report = JSONValue([
        "schema": JSONValue("scrubbed.coordination-scheduler-measurement.v2"),
        "version": JSONValue(2),
        "host_os": JSONValue(commandOutput(["uname", "-s"])),
        "host_architecture": JSONValue(commandOutput(["uname", "-m"])),
        "host_cpu": JSONValue(commandOutput(
            ["sysctl", "-n", "machdep.cpu.brand_string"])),
        "baseline_binary_sha256": JSONValue(baselineSnapshot.digest),
        "candidate_binary_sha256": JSONValue(candidateSnapshot.digest),
        "harness_sha256": JSONValue(harnessDigest),
        "fixture_table_sha256": JSONValue(fixtureTablePin),
        "config_sha256": JSONValue(configPin),
        "cache_semantics": JSONValue("application-cold; OS cache uncontrolled"),
        "sample_timeout_seconds": JSONValue(sampleTimeoutSeconds),
        "whole_run_timeout_seconds": JSONValue(wholeRunTimeoutSeconds),
        "sampler_timeout_seconds": JSONValue(samplerTimeoutSeconds),
        "termination_policy": JSONValue(
            "sample TERM process group; one-second grace; KILL process group; reap; 64 MiB RLIMIT_FSIZE per launched process; hard SIGKILL harness watchdog at whole-run deadline"),
        "runtime_environment_policy": JSONValue(
            "Config.newEnv PATH/LC_ALL allowlist plus opt-in coordination metrics only"),
        "control_method": JSONValue(
            "at least three of five exact paired candidate values <= 105% of baseline"),
        "target_wins": JSONValue(cast(long)targetWins),
        "target_baseline_median_wall_us": JSONValue(targetBaselineWall),
        "target_candidate_median_wall_us": JSONValue(targetCandidateWall),
        "target_baseline_median_queue_ns": JSONValue(baselineWait[runs / 2]),
        "target_candidate_median_queue_ns": JSONValue(candidateWait[runs / 2]),
        "controls_within_five_percent": JSONValue(controlsPass),
        "thresholds_satisfied": JSONValue(thresholdsSatisfied),
        "production_candidate_authorized": JSONValue(false),
        "decision": JSONValue(
            "MEASUREMENT_ONLY_REQUIRES_PIPELINE_ATTESTATION"),
        "baseline_attribution": JSONValue(baselineAttribution),
        "candidate_attribution": JSONValue(candidateAttribution),
        "layouts": JSONValue(layoutReports)]);
    auto text = report.toString;
    need(!text.canFind(root), "comparison report leaked temporary path");
    parseJSON(text);
    verifySnapshot(baselineSnapshot);
    verifySnapshot(candidateSnapshot);
    publishReport(reportPath, text);
    writeln("coordination measurement: wrote ", reportPath);
}

private void runDisabledMetricsOverhead(string[] args) {
    auto baseline = absolutePath(args[2]);
    auto candidate = absolutePath(args[3]);
    auto reportPath = absolutePath(args[4]);
    need(exists(baseline) && exists(candidate) && !exists(reportPath),
        "overhead binary missing or report exists");
    need(tableIdentity() == fixtureTablePin, "fixture table pin differs");
    auto root = privateScratch("scrubbed-coordination-overhead-");
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto baselineSnapshot = snapshotExecutable(baseline, root, "baseline");
    auto candidateSnapshot = snapshotExecutable(candidate, root, "candidate");
    baseline = baselineSnapshot.path;
    candidate = candidateSnapshot.path;
    auto harnessDigest = fileDigest(absolutePath(args[0]));
    auto config = buildPath(root, "mixed-v3.json");
    write(config, configText());
    need(fileDigest(config) == configPin, "config pin differs");
    auto layout = layouts[0];
    auto input = buildPath(root, layout.name ~ "-input");
    makeFixture(input, layout);
    auto inputId = identify(input);
    need(inputId.tree == inputTreePins[layout.name], "input tree pin differs");
    JSONValue[] baselineSamples, candidateSamples;
    foreach (round; 0 .. runs) foreach (threads; [1, 4])
    foreach (candidateFirst; [round % 2 == 1, round % 2 == 0]) {
        auto isCandidate = candidateFirst;
        auto binary = isCandidate ? candidate : baseline;
        auto output = buildPath(root, (isCandidate ? "candidate-" : "baseline-") ~
            threads.to!string ~ "-" ~ round.to!string);
        auto sample = invoke(binary, input, output, config, threads,
            round, root, false, isCandidate ?
                candidateSnapshot.digest : baselineSnapshot.digest);
        auto outputId = identify(output);
        need(outputId.tree == outputTreePins[layout.name],
            "overhead exact output tree pin differs");
        sample["output_bytes"] = cast(long)outputId.bytes;
        sample["output_tree_sha256"] = outputId.tree;
        if (isCandidate) candidateSamples ~= sample;
        else baselineSamples ~= sample;
        rmdirRecurse(output);
    }
    bool accepted = true;
    foreach (threads; [1, 4]) foreach (field;
            ["wall_us", "cpu_us", "peak_rss_bytes", "sampled_fd_peak"])
        accepted = accepted && pairedMedianWithinFivePercent(
            baselineSamples, candidateSamples, threads, field);
    auto report = JSONValue([
        "schema": JSONValue("scrubbed.coordination-disabled-overhead.v1"),
        "host_os": JSONValue(commandOutput(["uname", "-s"])),
        "host_architecture": JSONValue(commandOutput(["uname", "-m"])),
        "host_cpu": JSONValue(commandOutput(
            ["sysctl", "-n", "machdep.cpu.brand_string"])),
        "baseline_binary_sha256": JSONValue(baselineSnapshot.digest),
        "candidate_binary_sha256": JSONValue(candidateSnapshot.digest),
        "harness_sha256": JSONValue(harnessDigest),
        "fixture_table_sha256": JSONValue(fixtureTablePin),
        "config_sha256": JSONValue(configPin),
        "cache_semantics": JSONValue("application-cold; OS cache uncontrolled"),
        "control_method": JSONValue(
            "at least three of five exact paired candidate values <= 105% of baseline"),
        "metrics_environment": JSONValue("absent for every child"),
        "disabled_metrics_overhead_accepted": JSONValue(accepted),
        "baseline_samples": JSONValue(baselineSamples),
        "candidate_samples": JSONValue(candidateSamples)]);
    auto text = report.toString;
    need(!text.canFind(root), "overhead report leaked temporary path");
    parseJSON(text);
    verifySnapshot(baselineSnapshot);
    verifySnapshot(candidateSnapshot);
    publishReport(reportPath, text);
    writeln("coordination disabled-overhead: wrote ", reportPath);
}

private void runSizeOrder(string[] args) {
    auto binary = absolutePath(args[2]);
    auto reportPath = absolutePath(args[3]);
    need(exists(binary) && !exists(reportPath),
        "size-order binary missing or report exists");
    need(tableIdentity() == fixtureTablePin, "fixture table pin differs");
    auto root = privateScratch("scrubbed-size-order-");
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto binarySnapshot = snapshotExecutable(binary, root, "shipping");
    binary = binarySnapshot.path;
    auto harnessDigest = fileDigest(absolutePath(args[0]));
    auto config = buildPath(root, "mixed-v3.json");
    write(config, configText());
    need(fileDigest(config) == configPin, "config pin differs");
    static immutable variants = ["clustered-late", "largest-first",
        "seeded-distribution"];
    string[string] inputs;
    Tree[string] inputIds;
    JSONValue[][string] samples;
    string[string] expectedOutputTrees;
    ulong[string] expectedOutputBytes;
    foreach (variant; variants) {
        auto input = buildPath(root, variant ~ "-input");
        makeSizeOrderFixture(input, variant);
        inputs[variant] = input;
        inputIds[variant] = identify(input);
    }
    foreach (round; 0 .. runs) foreach (threads; [2, 4])
    foreach (offset; 0 .. variants.length) {
            auto variant = variants[(round + offset +
                (threads == 4 ? 1 : 0)) % variants.length];
            auto output = buildPath(root, variant ~ "-output-" ~
                threads.to!string ~ "-" ~ round.to!string);
            auto sample = invoke(binary, inputs[variant], output, config, threads,
                round, root, false, binarySnapshot.digest);
            auto outputId = identify(output);
            if ((variant in expectedOutputTrees) is null) {
                expectedOutputTrees[variant] = outputId.tree;
                expectedOutputBytes[variant] = outputId.bytes;
            }
            need(outputId.tree == expectedOutputTrees[variant],
                "size-order output tree differs between samples");
            need(outputId.bytes == expectedOutputBytes[variant],
                "size-order output byte count differs between samples");
            sample["output_bytes"] = cast(long)outputId.bytes;
            sample["output_tree_sha256"] = outputId.tree;
            sample["output_concatenated_sha256"] = outputId.concatenated;
            samples[variant] ~= sample;
            rmdirRecurse(output);
    }
    JSONValue[] variantReports;
    foreach (variant; variants) {
        variantReports ~= JSONValue([
            "variant": JSONValue(variant),
            "files": JSONValue(4096),
            "large_files": JSONValue(64),
            "input_bytes": JSONValue(cast(long)inputIds[variant].bytes),
            "input_tree_sha256": JSONValue(inputIds[variant].tree),
            "output_tree_sha256": JSONValue(expectedOutputTrees[variant]),
            "samples": JSONValue(samples[variant])]);
    }
    auto report = JSONValue([
        "schema": JSONValue("scrubbed.size-order-profile.v1"),
        "host_os": JSONValue(commandOutput(["uname", "-s"])),
        "host_architecture": JSONValue(commandOutput(["uname", "-m"])),
        "host_cpu": JSONValue(commandOutput(
            ["sysctl", "-n", "machdep.cpu.brand_string"])),
        "shipping_binary_sha256": JSONValue(binarySnapshot.digest),
        "harness_sha256": JSONValue(harnessDigest),
        "fixture_table_sha256": JSONValue(fixtureTablePin),
        "config_sha256": JSONValue(configPin),
        "cache_semantics": JSONValue("application-cold; OS cache uncontrolled"),
        "variants": JSONValue(variantReports)]);
    auto text = report.toString;
    need(!text.canFind(root), "size-order report leaked temporary path");
    parseJSON(text);
    verifySnapshot(binarySnapshot);
    publishReport(reportPath, text);
    writeln("size-order profile: wrote ", reportPath);
}

private void runAttribution(string[] args) {
    auto binary = absolutePath(args[1]);
    auto reportPath = absolutePath(args[2]);
    need(exists(binary) && !exists(reportPath), "binary missing or report exists");
    need(tableIdentity() == fixtureTablePin, "fixture table pin differs");
    auto root = privateScratch("scrubbed-coordination-");
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto binarySnapshot = snapshotExecutable(binary, root, "shipping");
    binary = binarySnapshot.path;
    auto harnessDigest = fileDigest(absolutePath(args[0]));
    auto config = buildPath(root, "mixed-v3.json");
    write(config, configText());
    need(fileDigest(config) == configPin, "config pin differs");
    JSONValue[] layoutReports;
    foreach (ref layout; layouts) {
        auto input = buildPath(root, layout.name ~ "-input");
        makeFixture(input, layout);
        auto inputId = identify(input);
        need(inputId.tree == inputTreePins[layout.name], "input tree pin differs");
        JSONValue[] performanceSamples, attributionSamples;
        foreach (instrumented; [false, true])
        foreach (round; 0 .. runs) foreach (threads; [1, 2, 4]) {
            auto output = buildPath(root, layout.name ~
                (instrumented ? "-attribution-t" : "-performance-t") ~
                threads.to!string ~ "-r" ~ round.to!string);
            auto sample = invoke(binary, input, output, config, threads, round,
                root, instrumented, binarySnapshot.digest);
            auto outputId = identify(output);
            need(outputId.tree == outputTreePins[layout.name],
                "exact output tree pin differs");
            if (instrumented) {
                validateMetrics(sample, layout.files, inputId.bytes);
            }
            sample["output_bytes"] = cast(long)outputId.bytes;
            sample["output_tree_sha256"] = outputId.tree;
            sample["output_concatenated_sha256"] = outputId.concatenated;
            if (instrumented) attributionSamples ~= sample;
            else performanceSamples ~= sample;
            rmdirRecurse(output);
        }
        layoutReports ~= JSONValue([
            "layout": JSONValue(layout.name),
            "files": JSONValue(cast(long)layout.files),
            "input_bytes": JSONValue(cast(long)inputId.bytes),
            "input_tree_sha256": JSONValue(inputId.tree),
            "input_concatenated_sha256": JSONValue(inputId.concatenated),
            "performance_samples": JSONValue(performanceSamples),
            "attribution_samples": JSONValue(attributionSamples)]);
    }
    auto report = JSONValue([
        "schema": JSONValue("scrubbed.coordination-profile.v1"),
        "host_os": JSONValue(commandOutput(["uname", "-s"])),
        "host_architecture": JSONValue(commandOutput(["uname", "-m"])),
        "host_kernel": JSONValue(commandOutput(["uname", "-r"])),
        "host_cpu": JSONValue(commandOutput(
            ["sysctl", "-n", "machdep.cpu.brand_string"])),
        "compiler": JSONValue(commandOutput(["ldc2", "--version"])),
        "shipping_binary_sha256": JSONValue(binarySnapshot.digest),
        "harness_sha256": JSONValue(harnessDigest),
        "fixture_table_sha256": JSONValue(fixtureTablePin),
        "config_sha256": JSONValue(configPin),
        "cache_semantics": JSONValue("application-cold; OS cache uncontrolled"),
        "production_candidate_authorized": JSONValue(false),
        "decision": JSONValue("ATTRIBUTION_ONLY_NO_CANDIDATE"),
        "layouts": JSONValue(layoutReports)]);
    auto text = report.toString;
    need(!text.canFind(root), "report leaked temporary path");
    parseJSON(text);
    verifySnapshot(binarySnapshot);
    publishReport(reportPath, text);
    writeln("coordination profile: wrote ", reportPath);
}

void main(string[] args) {
    launcherPath = absolutePath(args[0]);
    if (args.length >= 5 && args[1] == "--exec-child") {
        need(setpgid(0, 0) == 0, "child process group could not be created");
        auto requestedLimit = args[3].to!ulong;
        need(requestedLimit > 0 && requestedLimit <= diagnosticFileMaxBytes,
            "child file-size limit is invalid");
        rlimit fileLimit;
        need(getrlimit(RLIMIT_FSIZE, &fileLimit) == 0,
            "child file-size limit could not be read");
        if (fileLimit.rlim_max < requestedLimit)
            requestedLimit = fileLimit.rlim_max;
        fileLimit.rlim_cur = requestedLimit;
        need(setrlimit(RLIMIT_FSIZE, &fileLimit) == 0,
            "child file-size limit could not be installed");
        write(args[2], "ready");
        const(char)*[] childArguments;
        foreach (argument; args[4 .. $])
            childArguments ~= argument.toStringz;
        childArguments ~= null;
        execv(childArguments[0], childArguments.ptr);
        need(false, "child exec failed");
    }
    processGroupMutex = new Mutex;
    if (args.length == 4 && args[1] == "--self-test-whole-timeout-probe") {
        wholeRunDeadline = MonoTime.currTime + seconds(1);
        armWholeRunWatchdog(wholeRunDeadline);
        auto probeOut = buildPath(args[3], "whole-probe-child.out");
        auto probeErr = buildPath(args[3], "whole-probe-child.err");
        auto probeReady = buildPath(args[3], "whole-probe-child.ready");
        auto probeInput = File("/dev/null", "rb");
        auto probeOutput = File(probeOut, "wb");
        auto probeError = File(probeErr, "wb");
        spawnGrouped([args[2]], probeReady, probeInput, probeOutput,
            probeError, childEnvironment(false), wholeRunDeadline, 2_500);
        probeInput.close(); probeOutput.close(); probeError.close();
        Thread.sleep(seconds(30));
        need(false, "whole-run watchdog probe survived");
    }
    wholeRunDeadline = MonoTime.currTime + seconds(wholeRunTimeoutSeconds);
    armWholeRunWatchdog(wholeRunDeadline);
    need(args.length == 2 || args.length == 3 || args.length == 4 ||
        args.length == 5,
        "usage: coordination_profile <release-binary> <report> | " ~
        "--measure-comparison <baseline-binary> <candidate-binary> " ~
        "<private-measurement> | " ~
        "--size-order <release-binary> <report> | " ~
        "--disabled-overhead <baseline-binary> <candidate-binary> <report> | " ~
        "--self-test");
    if (args.length == 2 && args[1] == "--self-test")
        runSelfTest(absolutePath(args[0]));
    else if (args.length == 5 && args[1] == "--disabled-overhead")
        runDisabledMetricsOverhead(args);
    else if (args.length == 4 && args[1] == "--size-order") runSizeOrder(args);
    else if (args.length == 5 && args[1] == "--measure-comparison")
        runComparison(args);
    else if (args.length == 3) runAttribution(args);
    else need(false, "arguments do not select a supported mode");
}
