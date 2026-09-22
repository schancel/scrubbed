module run_limited;

import core.sys.posix.signal : SIGKILL, kill;
import core.sys.posix.sys.resource : RLIMIT_CPU, RLIMIT_FSIZE, getrlimit,
    rlimit, setrlimit;
import core.sys.posix.sys.wait : WNOHANG, waitpid;
import core.sys.posix.unistd : _exit, execvp, fork, setpgid;
import core.time : MonoTime, msecs;
import core.thread : Thread;
import std.conv : to;
import std.stdio : stderr, writeln;
import std.string : toStringz;

private void setLimit(int resource, ulong amount, int failureCode)
{
    rlimit limit;
    if (getrlimit(resource, &limit) != 0)
        _exit(failureCode);
    if (limit.rlim_max < amount)
        amount = limit.rlim_max;
    limit.rlim_cur = amount;
    if (setrlimit(resource, &limit) != 0)
        _exit(failureCode);
}

int main(string[] arguments)
{
    if (arguments.length < 3)
    {
        stderr.writeln("usage: run_limited TIMEOUT_MS COMMAND [ARG ...]");
        return 2;
    }

    const timeout = arguments[1].to!long.msecs;
    const command = arguments[2 .. $];
    const started = MonoTime.currTime;
    const child = fork();
    if (child == -1)
    {
        stderr.writeln("fork failed");
        return 2;
    }
    if (child == 0)
    {
        if (setpgid(0, 0) != 0)
            _exit(120);
        setLimit(RLIMIT_CPU, 5, 121);
        setLimit(RLIMIT_FSIZE, 16UL * 1024 * 1024, 123);

        auto argv = new const(char)*[command.length + 1];
        foreach (index, argument; command)
            argv[index] = argument.toStringz;
        argv[$ - 1] = null;
        execvp(argv[0], argv.ptr);
        _exit(127);
    }

    int status;
    auto waited = waitpid(child, &status, WNOHANG);
    while (waited == 0)
    {
        if (MonoTime.currTime - started >= timeout)
        {
            if (kill(-child, SIGKILL) != 0)
                kill(child, SIGKILL);
            if (waitpid(child, &status, 0) == -1)
                return 2;
            writeln("outcome=timeout elapsed_ms=", (MonoTime.currTime - started).total!"msecs");
            return 124;
        }
        Thread.sleep(10.msecs);
        waited = waitpid(child, &status, WNOHANG);
    }
    if (waited == -1)
        return 2;

    const elapsed = (MonoTime.currTime - started).total!"msecs";
    if ((status & 0x7f) != 0)
    {
        writeln("outcome=signal signal=", status & 0x7f, " elapsed_ms=", elapsed);
        return 125;
    }
    const exitCode = (status >> 8) & 0xff;
    writeln("outcome=exit status=", exitCode, " elapsed_ms=", elapsed);
    return exitCode;
}
