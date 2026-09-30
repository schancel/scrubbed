/// Opt-in PDF text extraction via execve of a user-already-installed Poppler
/// `pdftotext` (issue #296's accepted first-slice contract). Extraction never
/// runs implicitly: the caller must pass `allow = true`, mirroring
/// `effects.pii_policy_overlay`'s shipped "fails closed without an explicit
/// flag" idiom (`require(policy != PiiPolicy.redact || allowRedact, ...)`)
/// applied to a different trust boundary -- host subprocess execution rather
/// than a redaction policy. Unlike that idiom, declining here is a structured
/// `PdfExtractOutcome` failure (reason `declined`), never a thrown exception:
/// this module follows `effects.http_fetch`'s "content-free rejection"
/// result shape instead.
///
/// The bounded-subprocess mechanics (fork, `setpgid`, `RLIMIT_CPU` 5s,
/// `RLIMIT_FSIZE` 16 MiB, caller wall-clock timeout via `MonoTime`, whole
/// process-group `SIGKILL` on timeout) are a direct port of
/// `experiments/document_adapters/run_limited.d`'s proven pattern -- that
/// file is experiment code outside `dub.json`'s `sourcePaths`, not an
/// importable dependency, so the sequence is re-implemented here as
/// production code exactly as `benchmarks/external_comparator.d` already
/// ports the same sequence into its own context.
///
/// PATH resolution is exactly `pdftotext`'s own PATH search performed by
/// `execvp` (the same mechanism `run_limited.d` already relies on): this
/// module never scans `$PATH` itself and never probes any other binary name
/// or falls back to a list. A failed `execvp` inside the forked child exits
/// `127` (the standard "command not found" convention `run_limited.d` and
/// POSIX shells already use); that convention is what distinguishes
/// "not found" from every other subprocess failure here.
///
/// Scope: Poppler `pdftotext` only. MuPDF `mutool` support is a named
/// non-goal (a small follow-on second engine, not a redesign) -- Poppler is
/// only the *install-hint recommendation* named here (GPL-2.0, more commonly
/// pre-packaged, less restrictive copyleft than MuPDF's AGPL, per the
/// issue's owner decision). This module performs no PDF parsing/rendering of
/// its own: pure subprocess delegation. It has no CLI/config wiring; `allow`
/// and `PdfExtractLimits` are parameters this module's API exposes, not a
/// wired flag.
module effects.pdf_execve;

import core.stdc.errno : errno, EINTR;
import core.sys.posix.fcntl : O_CREAT, O_EXCL, O_WRONLY, open;
import core.sys.posix.signal : SIGKILL, SIGXFSZ, kill;
import core.sys.posix.stdlib : getenv, setenv, unsetenv;
import core.sys.posix.sys.resource : RLIMIT_CPU, RLIMIT_FSIZE, getrlimit,
    rlimit, setrlimit;
import core.sys.posix.sys.wait : WEXITSTATUS, WIFEXITED, WIFSIGNALED,
    WNOHANG, WTERMSIG, waitpid;
import core.sys.posix.unistd : _exit, close, dup2, execvp, fork, setpgid;
import core.thread : Thread;
import core.time : MonoTime, msecs;
import std.conv : octal;
import std.exception : enforce;
import std.file : exists, read, remove, tempDir;
import std.path : buildPath;
import std.string : fromStringz, toStringz;
import std.uuid : randomUUID;

/// The one binary this module ever executes. PATH lookup and the install
/// hint below are both fixed to exactly this name; there is no second name
/// or fallback list anywhere in this module.
enum string pdfExtractToolName = "pdftotext";

/// Fixed, specific install hint naming `pdftotext`/Poppler by name (the
/// owner-decided default recommendation). Never generic, never blank.
enum string pdfExtractInstallHint =
    "pdftotext (from Poppler) was not found on PATH. Install Poppler to " ~
    "enable PDF text extraction, e.g. `brew install poppler` (macOS) or " ~
    "`apt-get install poppler-utils` (Debian/Ubuntu).";

enum PdfExtractFailureReason : ubyte {
    none,
    /// The caller did not pass `allow = true`. No PATH lookup or subprocess
    /// spawn was ever attempted.
    declined,
    /// `execvp("pdftotext", ...)` itself failed (PATH search found nothing
    /// runnable by that exact name).
    toolNotFound,
    /// The caller's wall-clock timeout elapsed; the whole process group was
    /// sent `SIGKILL`, not just the direct child.
    timedOut,
    /// The child was killed by `SIGXFSZ`: it tried to write past the
    /// `RLIMIT_FSIZE` output cap, and was cut off rather than read
    /// unbounded.
    outputCapExceeded,
    /// The child was terminated by some other signal (a crash, or the
    /// `RLIMIT_CPU` cap raising `SIGXCPU`).
    terminatedBySignal,
    /// The child exited normally with a nonzero status.
    nonZeroExit,
}

/// Content-free failure: a fixed reason plus the numeric exit code or
/// signal that produced it. Never carries the subprocess's raw stderr, its
/// argument vector, or any other tool-controlled diagnostic text.
struct PdfExtractFailure {
    PdfExtractFailureReason reason;
    int exitCode;
    int signal;
    /// Populated only when `reason == toolNotFound`.
    string installHint;
}

struct PdfExtractOutcome {
    private bool succeeded_;
    private string text_;
    private PdfExtractFailure failure_;

    bool succeeded() const pure nothrow @safe @nogc { return succeeded_; }

    string text() const pure {
        enforce(succeeded_, "pdf extract outcome is a failure");
        return text_;
    }

    PdfExtractFailure failure() const pure {
        enforce(!succeeded_, "pdf extract outcome is a success");
        return failure_;
    }
}

/// Caps ported from `run_limited.d`: 5s CPU time, 16 MiB output, plus a
/// caller-supplied wall-clock timeout (`run_limited.d` takes that as a CLI
/// argument; here it is a struct field with the same default this module's
/// own fixtures exercise it at).
struct PdfExtractLimits {
    long cpuSeconds = 5;
    long maxOutputBytes = 16 * 1024 * 1024;
    long wallTimeoutMs = 10_000;
}

private void setLimit(int resource, ulong amount, int failureCode) {
    rlimit limit;
    if (getrlimit(resource, &limit) != 0) _exit(failureCode);
    if (limit.rlim_max < amount) amount = limit.rlim_max;
    limit.rlim_cur = amount;
    if (setrlimit(resource, &limit) != 0) _exit(failureCode);
}

private struct BoundedRunOutcome {
    bool timedOut;
    bool signaled;
    int signal;
    int exitCode;
}

// `waitpid` -- with or without `WNOHANG` -- is a syscall that can return
// -1/EINTR under `app.d`'s process-wide SIGINT handler (`sa_flags=0`, no
// `SA_RESTART`; see docs/signal-handling.md): the blocking `waitpid(child,
// &status, 0)` call below (reaping after a timeout `SIGKILL`) genuinely
// sleeps and can be interrupted mid-wait; even the non-blocking `WNOHANG`
// poll can race a signal at syscall entry/exit. Without retrying, either
// call returning -1/EINTR would either leave the killed child unreaped (a
// zombie, since the caller doesn't check that return value at all) or throw
// the misleading "waitpid failed" from the `enforce` below instead of
// continuing to poll. Same EINTR-retry shape used for raw `read`/`write` in
// effects.document_shards, effects.mix_export, effects.error_export, and
// elsewhere in this codebase.
//
// `syscall` defaults to the real `waitpid` and is only ever overridden by
// the unittests below, which inject a fake that returns -1/EINTR a
// controlled number of times -- this codebase has no precedent for real
// signal-delivery tests (see #469), so this dependency-injection seam
// covers the retry logic deterministically instead, without forking a real
// child or sending a real signal.
private int waitpidRetry(int child, int* status, int options,
        typeof(&waitpid) syscall = &waitpid) {
    for (;;) {
        auto waited = syscall(child, status, options);
        if (waited < 0 && errno == EINTR) continue;
        return waited;
    }
}

version (unittest) {
    private int pdfExecveFakeCallsRemaining;

    private extern(C) int pdfExecveFakeWaitpidEintrThenOk(int child, int* status, int options) nothrow @nogc {
        if (pdfExecveFakeCallsRemaining > 0) {
            pdfExecveFakeCallsRemaining--;
            errno = EINTR;
            return -1;
        }
        return child;
    }

    private extern(C) int pdfExecveFakeWaitpidAlwaysOk(int child, int* status, int options) nothrow @nogc {
        return child;
    }
}

unittest {
    // Happy path: no EINTR, returns the real syscall's result untouched.
    int status;
    assert(waitpidRetry(4242, &status, 0, &pdfExecveFakeWaitpidAlwaysOk) == 4242);
}

unittest {
    // Retry path: the injected fake returns -1/EINTR exactly twice before
    // succeeding; waitpidRetry must retry through both and return the real
    // child pid on the third attempt, not surface the EINTR failure (which
    // would otherwise leave the child unreaped, per the comment above).
    int status;
    pdfExecveFakeCallsRemaining = 2;
    assert(waitpidRetry(4242, &status, 0, &pdfExecveFakeWaitpidEintrThenOk) == 4242);
    assert(pdfExecveFakeCallsRemaining == 0);
}

/// Forks `argv[0]` as its own process-group leader, applies the run_limited.d
/// CPU/output-size caps, and enforces `wallTimeoutMs` by polling `MonoTime`
/// and, on expiry, sending `SIGKILL` to the whole process group
/// (`kill(-child, ...)`) so a grandchild the tool spawned is killed too, not
/// left orphaned. No partial result is ever returned for a timed-out run.
private BoundedRunOutcome runBounded(const string[] argv, long cpuSeconds,
        long maxOutputBytes, long wallTimeoutMs) {
    const started = MonoTime.currTime;
    const timeout = msecs(wallTimeoutMs);
    const child = fork();
    enforce(child != -1, "pdf execve: fork failed");
    if (child == 0) {
        if (setpgid(0, 0) != 0) _exit(120);
        setLimit(RLIMIT_CPU, cast(ulong) cpuSeconds, 121);
        setLimit(RLIMIT_FSIZE, cast(ulong) maxOutputBytes, 123);
        auto devNull = open("/dev/null", O_WRONLY);
        if (devNull >= 0) {
            dup2(devNull, 1);
            dup2(devNull, 2);
            close(devNull);
        }
        auto argvz = new const(char)*[argv.length + 1];
        foreach (index, argument; argv) argvz[index] = argument.toStringz;
        argvz[$ - 1] = null;
        execvp(argvz[0], argvz.ptr);
        _exit(127);
    }
    int status;
    auto waited = waitpidRetry(child, &status, WNOHANG);
    while (waited == 0) {
        if (MonoTime.currTime - started >= timeout) {
            if (kill(-child, SIGKILL) != 0) kill(child, SIGKILL);
            waitpidRetry(child, &status, 0);
            return BoundedRunOutcome(true, false, 0, 0);
        }
        Thread.sleep(10.msecs);
        waited = waitpidRetry(child, &status, WNOHANG);
    }
    enforce(waited == child, "pdf execve: waitpid failed");
    if (WIFSIGNALED(status)) return BoundedRunOutcome(false, true, WTERMSIG(status), 0);
    enforce(WIFEXITED(status), "pdf execve: child neither exited nor was signaled");
    return BoundedRunOutcome(false, false, 0, WEXITSTATUS(status));
}

private void claimOutputPath(string path) {
    auto descriptor = open(path.toStringz, O_CREAT | O_EXCL | O_WRONLY, octal!600);
    enforce(descriptor >= 0, "pdf execve: cannot claim output path");
    close(descriptor);
}

/// Extracts plain text from `pdfPath` by invoking `pdftotext -layout` as a
/// bounded subprocess.
///
/// `allow` is the explicit opt-in gate: when false, this function returns a
/// `declined` outcome immediately and performs no PATH lookup or subprocess
/// spawn whatsoever.
///
/// `pathOverride`, when non-null, temporarily replaces the process's `PATH`
/// environment variable for the duration of the forked child's `execvp`
/// search, then restores it. It exists so tests can prove the present/absent
/// cases deterministically without depending on the real host's `PATH`;
/// production callers should leave it null to search the real inherited
/// `PATH`.
PdfExtractOutcome extractPdfText(string pdfPath, bool allow,
        PdfExtractLimits limits = PdfExtractLimits.init,
        string pathOverride = null) {
    PdfExtractOutcome outcome;
    if (!allow) {
        outcome.failure_ = PdfExtractFailure(PdfExtractFailureReason.declined);
        return outcome;
    }

    auto outputPath = buildPath(tempDir,
        "scrubbed-pdf-execve-" ~ randomUUID.toString ~ ".txt");
    claimOutputPath(outputPath);
    scope(exit) if (exists(outputPath)) remove(outputPath);

    string savedPath;
    bool hadPath;
    if (pathOverride !is null) {
        auto existing = getenv("PATH");
        hadPath = existing !is null;
        if (hadPath) savedPath = existing.fromStringz.idup;
        setenv("PATH", pathOverride.toStringz, 1);
    }
    scope(exit) if (pathOverride !is null) {
        if (hadPath) setenv("PATH", savedPath.toStringz, 1);
        else unsetenv("PATH");
    }

    const string[] argv = [pdfExtractToolName, "-layout", pdfPath, outputPath];
    auto result = runBounded(argv, limits.cpuSeconds, limits.maxOutputBytes,
        limits.wallTimeoutMs);

    if (result.timedOut) {
        outcome.failure_ = PdfExtractFailure(PdfExtractFailureReason.timedOut);
        return outcome;
    }
    if (result.signaled) {
        outcome.failure_ = result.signal == SIGXFSZ ?
            PdfExtractFailure(PdfExtractFailureReason.outputCapExceeded) :
            PdfExtractFailure(PdfExtractFailureReason.terminatedBySignal, 0, result.signal);
        return outcome;
    }
    if (result.exitCode == 127) {
        outcome.failure_ = PdfExtractFailure(PdfExtractFailureReason.toolNotFound,
            0, 0, pdfExtractInstallHint);
        return outcome;
    }
    if (result.exitCode != 0) {
        outcome.failure_ = PdfExtractFailure(PdfExtractFailureReason.nonZeroExit,
            result.exitCode);
        return outcome;
    }
    outcome.succeeded_ = true;
    outcome.text_ = cast(string) read(outputPath);
    return outcome;
}

version(unittest) {
    import core.sys.posix.sys.stat : chmod;
    import core.time : seconds;
    import std.file : mkdirRecurse, rmdirRecurse, timeLastModified, write;

    private string makeTestDir(string label) {
        auto dir = buildPath(tempDir,
            "scrubbed-pdf-execve-test-" ~ label ~ "-" ~ randomUUID.toString);
        mkdirRecurse(dir);
        return dir;
    }

    private void makeFakeTool(string dir, string script) {
        auto path = buildPath(dir, pdfExtractToolName);
        write(path, script);
        enforce(chmod(path.toStringz, octal!755) == 0, "cannot mark fake tool executable");
    }

    private string makeFixturePdf(string dir) {
        auto path = buildPath(dir, "input.pdf");
        write(path, "%PDF-1.4\n%fixture\n");
        return path;
    }

    /// A fake fixture's own `#!/bin/sh` script needs ordinary coreutils
    /// (`sleep`, `date`, `yes`, `printf`) to resolve too; only the directory
    /// intentionally holding (or lacking) "pdftotext" is under test, so
    /// `/bin:/usr/bin` is appended for the script interpreter's own use.
    private string withCoreutils(string dir) {
        return dir ~ ":/bin:/usr/bin";
    }
}

unittest {
    // Declining without the opt-in flag must never attempt a PATH lookup or
    // subprocess spawn: a fake "pdftotext" that would leave a marker behind
    // if invoked must be left untouched.
    auto dir = makeTestDir("declined");
    scope(exit) rmdirRecurse(dir);
    auto marker = buildPath(dir, "invoked");
    makeFakeTool(dir, "#!/bin/sh\ntouch \"" ~ marker ~ "\"\n");
    auto pdfPath = makeFixturePdf(dir);

    auto outcome = extractPdfText(pdfPath, false, PdfExtractLimits.init, dir);
    assert(!outcome.succeeded);
    assert(outcome.failure.reason == PdfExtractFailureReason.declined);
    assert(!exists(marker), "declined extraction attempted a subprocess spawn");
}

unittest {
    // PATH lookup against a directory that genuinely lacks "pdftotext" fails
    // with the exact fixed Poppler install-hint text -- never a generic or
    // blank error.
    auto dir = makeTestDir("missing");
    scope(exit) rmdirRecurse(dir);
    auto pdfPath = makeFixturePdf(dir);

    auto outcome = extractPdfText(pdfPath, true, PdfExtractLimits.init, dir);
    assert(!outcome.succeeded);
    assert(outcome.failure.reason == PdfExtractFailureReason.toolNotFound);
    assert(outcome.failure.installHint == pdfExtractInstallHint);
    assert(outcome.failure.installHint.length > 0);
}

unittest {
    // PATH lookup against a directory that genuinely provides "pdftotext"
    // succeeds and returns exactly what that binary wrote.
    auto dir = makeTestDir("present");
    scope(exit) rmdirRecurse(dir);
    makeFakeTool(dir, "#!/bin/sh\nprintf 'FAKE EXTRACTED TEXT' > \"$3\"\n");
    auto pdfPath = makeFixturePdf(dir);

    auto outcome = extractPdfText(pdfPath, true, PdfExtractLimits.init, withCoreutils(dir));
    assert(outcome.succeeded);
    assert(outcome.text == "FAKE EXTRACTED TEXT");
}

unittest {
    // A nonzero, non-127 exit (a real tool declining malformed input) is a
    // distinct nonZeroExit failure, not conflated with "not found".
    auto dir = makeTestDir("nonzero");
    scope(exit) rmdirRecurse(dir);
    makeFakeTool(dir, "#!/bin/sh\nexit 3\n");
    auto pdfPath = makeFixturePdf(dir);

    auto outcome = extractPdfText(pdfPath, true, PdfExtractLimits.init, withCoreutils(dir));
    assert(!outcome.succeeded);
    assert(outcome.failure.reason == PdfExtractFailureReason.nonZeroExit);
    assert(outcome.failure.exitCode == 3);
}

unittest {
    // A subprocess that ignores termination and spawns a background
    // grandchild that keeps running must still be killed as a whole process
    // group on wall-timeout: killing only the direct child would leave the
    // grandchild's heartbeat file still being touched after we return.
    auto dir = makeTestDir("timeout");
    scope(exit) rmdirRecurse(dir);
    auto heartbeat = buildPath(dir, "heartbeat");
    makeFakeTool(dir, "#!/bin/sh\n" ~
        "hb=\"" ~ heartbeat ~ "\"\n" ~
        "trap '' TERM\n" ~
        "( trap '' TERM; while true; do date +%s%N > \"$hb\" 2>/dev/null; sleep 0.02; done ) &\n" ~
        "sleep 100\n");
    auto pdfPath = makeFixturePdf(dir);

    PdfExtractLimits limits;
    limits.wallTimeoutMs = 800;
    const started = MonoTime.currTime;
    auto outcome = extractPdfText(pdfPath, true, limits, withCoreutils(dir));
    const elapsed = MonoTime.currTime - started;

    assert(!outcome.succeeded);
    assert(outcome.failure.reason == PdfExtractFailureReason.timedOut);
    assert(elapsed < 5.seconds, "timeout kill did not bound wall-clock time");

    // The grandchild may take a moment to actually start under load (its
    // parent shell only forks it after the fake tool's own exec, all within
    // the 800ms wall-clock budget above), so give existence a short bounded
    // poll instead of a single immediate check.
    {
        const existedBy = MonoTime.currTime;
        while (!exists(heartbeat)) {
            enforce(MonoTime.currTime - existedBy < 1.seconds,
                "grandchild never started");
            Thread.sleep(20.msecs);
        }
    }

    // `kill(-child, SIGKILL)` above enqueues the kill for every process in
    // the group atomically, but delivery is not instantaneous: a
    // CPU-starved grandchild only actually dies once the kernel schedules
    // it, and can complete an already-in-flight loop iteration (fork+exec
    // "date"+write) in the meantime. A single fixed-delay snapshot
    // therefore risks observing a heartbeat write that lands shortly after
    // the kill but before the grandchild is actually scheduled to die --
    // this is a real, reproducible-under-load timing race (see issue #389:
    // confirmed to reproduce at roughly 1 in 25 runs of this exact test
    // under 4x CPU oversubscription -- 40 busy-loop processes pinned
    // against a 10-core machine -- versus 0 failures in 20 unloaded runs;
    // GitHub Actions' shared "ubuntu-24.04" runners are exactly this kind
    // of contended, noisy-neighbor environment). It is not a bug in the
    // process-group kill itself: `kill(-child, SIGKILL)` cannot be
    // un-sent, blocked, or "sent harder" -- the only fix available at this
    // layer is to distinguish "reaped, but the kernel took a moment to
    // schedule it" from "never reaped" by polling for quiescence instead
    // of sampling once. A genuine reap failure keeps the heartbeat
    // updating indefinitely and will still fail this assert once the
    // ceiling below is reached.
    enum quietWindow = 400.msecs; // same "stopped updating" bar as before
    enum ceiling = 5.seconds;     // matches this test's own kill-detection
                                   // bound above; ~12x the quiet window as
                                   // a safety factor for CI scheduling
                                   // variance.
    const pollStarted = MonoTime.currTime;
    auto lastMtime = timeLastModified(heartbeat);
    auto lastChangeAt = MonoTime.currTime;
    bool reaped;
    while (MonoTime.currTime - pollStarted < ceiling) {
        if (MonoTime.currTime - lastChangeAt >= quietWindow) {
            reaped = true;
            break;
        }
        Thread.sleep(50.msecs);
        auto mtime = timeLastModified(heartbeat);
        if (mtime != lastMtime) {
            lastMtime = mtime;
            lastChangeAt = MonoTime.currTime;
        }
    }
    assert(reaped,
        "grandchild survived the process-group kill (orphaned, not reaped)");
}

unittest {
    // A subprocess that tries to write past the output cap is cut off by
    // RLIMIT_FSIZE (SIGXFSZ) and reported as a distinct outputCapExceeded
    // failure, never read unbounded.
    auto dir = makeTestDir("outputcap");
    scope(exit) rmdirRecurse(dir);
    // `exec` replaces the shell's own process image with `yes`, so the
    // direct child our fork/waitpid observes IS the process that hits
    // RLIMIT_FSIZE (rlimits survive exec) -- not an intermediate shell
    // reporting its child's signal as a numeric exit code.
    makeFakeTool(dir, "#!/bin/sh\nexec yes 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' > \"$3\"\n");
    auto pdfPath = makeFixturePdf(dir);

    PdfExtractLimits limits;
    limits.maxOutputBytes = 65_536;
    limits.wallTimeoutMs = 10_000;
    auto outcome = extractPdfText(pdfPath, true, limits, withCoreutils(dir));

    assert(!outcome.succeeded);
    assert(outcome.failure.reason == PdfExtractFailureReason.outputCapExceeded);
}

unittest {
    // Real end-to-end proof against #67's frozen, license-clear PDF fixture,
    // reusing its pinned generator output rather than authoring a new one.
    // Runs only when this environment's real PATH actually has "pdftotext"
    // (pathOverride is left null so this exercises the genuine PATH search,
    // not a fake tool); otherwise this proof is left to
    // experiments/document_adapters/pdf_execve_check.d, which reports tool
    // absence explicitly rather than silently skipping.
    import std.process : environment;
    import std.string : split;

    bool foundOnRealPath;
    foreach (directory; environment.get("PATH", "").split(':')) {
        if (exists(buildPath(directory, pdfExtractToolName))) { foundOnRealPath = true; break; }
    }
    if (!foundOnRealPath) return;

    enum expectedText = "TRAINING PDF\n\nALPHA ONE\nBETA TWO\n\f";
    auto fixture = "experiments/document_adapters/fixtures/pdf-training.pdf";
    if (!exists(fixture)) return; // run from a working directory without the fixture checked out

    auto outcome = extractPdfText(fixture, true);
    assert(outcome.succeeded, "real pdftotext failed against the frozen fixture");
    assert(outcome.text == expectedText,
        "real pdftotext output did not match the pinned frozen-fixture text");
}
