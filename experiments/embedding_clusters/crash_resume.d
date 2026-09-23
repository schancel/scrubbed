/// Parent-controlled abrupt publication and restart evidence for the evaluator.
module experiments.embedding_clusters.crash_resume;

version (OSX) {} else static assert(0,
    "crash/RSS evidence is verified only on macOS");

import experiments.embedding_clusters.contract : maxCpuSeconds, maxLogBytes,
    maxRssBytes, serverArguments, wallSeconds;
import core.sys.posix.fcntl : F_GETFL, F_SETFL, O_CREAT, O_NONBLOCK, O_TRUNC,
    O_WRONLY, fcntl, open;
import core.sys.posix.poll : POLLIN, poll, pollfd;
import core.sys.posix.signal : SIGKILL, SIGTERM, kill;
import core.sys.posix.sys.resource : RLIMIT_CPU, RLIMIT_FSIZE, getrlimit,
    rlimit, setrlimit;
import core.sys.posix.sys.wait : WNOHANG, WIFSIGNALED, WTERMSIG, waitpid;
import core.sys.posix.unistd : _exit, close, dup2, execvp, fork, pipe,
    posixRead = read, setpgid;
import core.time : MonoTime, msecs, seconds;
import core.thread : Thread;
import std.conv : to;
import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;
import std.exception : enforce;
import std.file : exists, isFile, mkdirRecurse, read, readText, write;
import std.path : buildPath;
import std.string : split, splitLines, toStringz;

private extern(C) int proc_pid_rusage(int pid, int flavor, void* buffer);
private struct RusageV0 {
    ubyte[16] uuid;
    ulong userTime, systemTime, idleWakeups, interruptWakeups;
    ulong pageins, wiredSize, residentSize, physicalFootprint;
    ulong processStart, processExit;
}

private struct Restart {
    string result;
    size_t reused;
    size_t recomputed;
    size_t maxLive;
}

private void setLimit(int resource, ulong amount) {
    rlimit limit;
    if (getrlimit(resource, &limit) != 0) _exit(120);
    if (limit.rlim_max < amount) amount = limit.rlim_max;
    limit.rlim_cur = amount;
    if (setrlimit(resource, &limit) != 0) _exit(121);
}

private int redirect(string path) {
    auto fd = open(path.toStringz, O_WRONLY | O_CREAT | O_TRUNC, 384);
    if (fd < 0 || dup2(fd, 1) < 0 || dup2(fd, 2) < 0) _exit(122);
    if (fd > 2) close(fd);
    return fd;
}

private void execute(string[] arguments) {
    auto argv = new const(char)*[arguments.length + 1];
    foreach (i, argument; arguments) argv[i] = argument.toStringz;
    argv[$ - 1] = null;
    execvp(argv[0], argv.ptr);
    _exit(123);
}

private int startServer(string server, string model, string log) {
    auto pid = fork();
    enforce(pid >= 0, "cannot fork server");
    if (pid == 0) {
        if (setpgid(0, 0) != 0) _exit(124);
        setLimit(RLIMIT_CPU, maxCpuSeconds);
        setLimit(RLIMIT_FSIZE, maxLogBytes);
        redirect(log);
        execute(serverArguments(server, model));
    }
    return pid;
}

private void stopChildGroup(int pid) {
    if (pid <= 0) return;
    kill(-pid, SIGTERM);
    int status;
    foreach (_; 0 .. 50) {
        if (waitpid(pid, &status, WNOHANG) == pid) return;
        Thread.sleep(20.msecs);
    }
    kill(-pid, SIGKILL);
    waitpid(pid, &status, 0);
}

private string[] runnerBase(string runner, string server, string model,
        string corpus, string train, string heldout, string workdir) {
    return [runner, server, model, corpus, train, heldout, workdir];
}

private string runCrash(string phase, string[] base, string logRoot,
        out bool hadIndex, out bool hadShard, out bool hadPending) {
    int[2] control;
    enforce(pipe(control) == 0, "cannot create crash control pipe");
    auto serverPid = startServer(base[1], base[2],
        buildPath(logRoot, phase ~ "-server.log"));
    int evaluatorPid = fork();
    enforce(evaluatorPid >= 0, "cannot fork evaluator");
    if (evaluatorPid == 0) {
        close(control[0]);
        if (setpgid(0, 0) != 0) _exit(125);
        setLimit(RLIMIT_CPU, maxCpuSeconds);
        redirect(buildPath(logRoot, phase ~ "-evaluator.log"));
        execute(base ~ ["--external-server", "--crash-phase=" ~ phase,
            "--control-fd=" ~ control[1].to!string]);
    }
    close(control[1]);
    auto flags = fcntl(control[0], F_GETFL, 0);
    enforce(flags >= 0 && fcntl(control[0], F_SETFL, flags | O_NONBLOCK) == 0,
        "cannot make control pipe nonblocking");
    auto deadline = MonoTime.currTime + wallSeconds.seconds;
    string signal;
    int status;
    scope(failure) {
        kill(-evaluatorPid, SIGKILL);
        waitpid(evaluatorPid, &status, 0);
        stopChildGroup(serverPid);
    }
    while (signal.length == 0) {
        enforce(MonoTime.currTime < deadline, "crash boundary exceeded wall cap");
        RusageV0 usage;
        enforce(proc_pid_rusage(serverPid, 0, &usage) == 0,
            "cannot sample server RSS");
        enforce(usage.residentSize <= maxRssBytes, "server exceeded RSS cap");
        enforce(waitpid(evaluatorPid, &status, WNOHANG) == 0,
            "evaluator exited before crash boundary");
        pollfd descriptor = pollfd(control[0], POLLIN, 0);
        auto ready = poll(&descriptor, 1, 10);
        enforce(ready >= 0, "control poll failed");
        if (ready > 0 && (descriptor.revents & POLLIN)) {
            ubyte[256] buffer;
            auto count = posixRead(control[0], buffer.ptr, buffer.length);
            enforce(count > 0, "empty crash boundary signal");
            signal = (cast(string) buffer[0 .. count]).idup;
        }
    }
    close(control[0]);
    enforce(signal == phase ~ "\t0\t" ~
        (phase == "committed" ? "1\t4\n" : "0\t0\n"),
        "unexpected crash boundary signal: " ~ signal);
    enforce(kill(-evaluatorPid, SIGKILL) == 0,
        "cannot abruptly terminate evaluator");
    enforce(waitpid(evaluatorPid, &status, 0) == evaluatorPid &&
        WIFSIGNALED(status) && WTERMSIG(status) == SIGKILL,
        "evaluator was not terminated by SIGKILL");
    stopChildGroup(serverPid);

    auto workdir = base[6];
    auto indexPath = buildPath(workdir, "index.tsv");
    auto shardPath = buildPath(workdir, "shard-000.tsv");
    auto pendingPath = buildPath(workdir, "shard-000.tsv.pending");
    hadIndex = exists(indexPath) && isFile(indexPath);
    hadShard = exists(shardPath) && isFile(shardPath);
    hadPending = exists(pendingPath) && isFile(pendingPath);
    if (phase == "pending")
        enforce(!hadIndex && !hadShard && hadPending,
            "pending crash did not preserve only pending state");
    else if (phase == "orphan")
        enforce(!hadIndex && hadShard && !hadPending,
            "orphan crash state mismatch");
    else
        enforce(hadIndex && hadShard && !hadPending,
            "committed crash state mismatch");
    return signal;
}

private void runNormal(string[] base, string observation, string logPath) {
    auto pid = fork();
    enforce(pid >= 0, "cannot fork restart evaluator");
    if (pid == 0) {
        redirect(logPath);
        execute(base ~ ["--observation=" ~ observation]);
    }
    int status;
    enforce(waitpid(pid, &status, 0) == pid && status == 0,
        "restart evaluator failed");
}

private Restart restart(string workdir, string observation) {
    auto rows = readText(buildPath(workdir, observation ~ "-observation.tsv"))
        .splitLines;
    enforce(rows.length == 2, "restart observation shape");
    auto field = rows[1].split('\t');
    enforce(field.length == 14, "restart observation columns");
    return Restart(field[10], field[8].to!size_t, field[9].to!size_t,
        field[7].to!size_t);
}

private string digestFile(string path) {
    return toHexString!(LetterCase.lower)(sha256Of(cast(ubyte[]) read(path))).idup;
}

int main(string[] args) {
    enforce(args.length == 10,
        "usage: crash_resume RUNNER SERVER MODEL CORPUS TRAIN HELDOUT EVIDENCE SCRATCH RESULT_SHA256");
    const runner = args[1], server = args[2], model = args[3];
    const corpus = args[4], train = args[5], heldout = args[6];
    const evidence = args[7], scratch = args[8], expectedResult = args[9];
    enforce(!exists(evidence), "evidence directory must be new");
    mkdirRecurse(scratch);
    string summary = "phase\tsignal\tindex_present\tshard_present\tpending_present\treused_shards\trecomputed_shards\tresult_sha256\n";
    foreach (phase; ["pending", "orphan", "committed"]) {
        auto workdir = phase == "committed" ? evidence : buildPath(scratch, phase);
        enforce(!exists(workdir), "crash work directory must be new: " ~ phase);
        mkdirRecurse(workdir);
        auto base = runnerBase(runner, server, model, corpus, train, heldout,
            workdir);
        bool indexPresent, shardPresent, pendingPresent;
        runCrash(phase, base, scratch, indexPresent, shardPresent, pendingPresent);
        auto observation = phase == "committed" ? "resume" : phase ~ "-resume";
        runNormal(base, observation, buildPath(scratch, phase ~ "-resume.log"));
        auto resumed = restart(workdir, observation);
        enforce(resumed.result == expectedResult, "restart result digest drift");
        enforce(resumed.reused == (phase == "committed" ? 1 : 0) &&
            resumed.recomputed == (phase == "committed" ? 8 : 9),
            "restart reused uncommitted state");
        enforce(resumed.maxLive == 2,
            "restart decoded-vector working-set evidence drift");
        summary ~= phase ~ "\tSIGKILL\t" ~ indexPresent.to!string ~ "\t" ~
            shardPresent.to!string ~ "\t" ~ pendingPresent.to!string ~ "\t" ~
            resumed.reused.to!string ~ "\t" ~ resumed.recomputed.to!string ~
            "\t" ~ resumed.result ~ "\n";
    }
    auto finalBase = runnerBase(runner, server, model, corpus, train, heldout,
        evidence);
    runNormal(finalBase, "replay", buildPath(scratch, "replay.log"));
    auto replay = restart(evidence, "replay");
    enforce(replay.result == expectedResult && replay.reused == 9 &&
        replay.recomputed == 0 && replay.maxLive == 2,
        "post-crash replay drift");
    write(buildPath(evidence, "crash-observations.tsv"), summary);
    auto indexHash = digestFile(buildPath(evidence, "index.tsv"));
    write(buildPath(evidence, "kill-observation.tsv"),
        "schema\tphase\tsignal\tcommitted_shards\tcommitted_ids\tindex_sha256\n" ~
        "embedding-abrupt-kill:v2\tcommitted\tSIGKILL\t1\t4\t" ~ indexHash ~ "\n");
    return 0;
}
