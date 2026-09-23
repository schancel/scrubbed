/// Abrupt-publication and restart harness for embedding-dimension evidence.
module experiments.embedding_dimension.crash_resume;

import core.sys.posix.signal : SIGKILL, kill;
import core.thread : Thread;
import core.time : msecs, seconds;
import std.algorithm : startsWith;
import std.exception : enforce;
import std.file : exists, readText, write;
import std.process : Pid, spawnProcess, wait;
import std.stdio : writeln;

private string[] command(string runner, string index, string output, bool pause) {
    auto result = [runner, index, output, "crash-control", "model:synthetic:v1",
        "euclidean", "none", "169", "0"];
    if (pause) result ~= "--pause-before-publish";
    return result;
}

int main(string[] args) {
    if (args.length != 4)
        throw new Exception("usage: crash-resume RUNNER SYNTHETIC_INDEX OUTPUT");
    auto prior = "prior-committed-evidence\n";
    write(args[3], prior);
    auto child = spawnProcess(command(args[1], args[2], args[3], true));
    auto deadline = 100;
    while (!exists(args[3] ~ ".pending") && deadline-- > 0)
        Thread.sleep(50.msecs);
    enforce(exists(args[3] ~ ".pending"), "child did not stage pending evidence");
    enforce(kill(child.processID, SIGKILL) == 0, "could not kill staged evaluator");
    auto status = child.wait();
    enforce(status != 0, "killed evaluator unexpectedly succeeded");
    enforce(readText(args[3]) == prior, "abrupt termination replaced committed evidence");

    auto restart = spawnProcess(command(args[1], args[2], args[3], false));
    enforce(restart.wait() == 0, "restart failed");
    auto committed = readText(args[3]);
    enforce(committed.length > prior.length && committed.startsWith("embedding-dimension:v1\n"),
        "restart did not atomically publish complete evidence");
    auto replay = spawnProcess(command(args[1], args[2], args[3], false));
    enforce(replay.wait() == 0 && readText(args[3]) == committed,
        "replay changed committed bytes");
    writeln("crash/restart: ok; prior preserved; restart/replay bytes stable");
    return 0;
}
