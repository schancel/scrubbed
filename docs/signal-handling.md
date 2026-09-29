# Signal handling

## SIGINT: graceful shutdown

`scrubbed` installs a `SIGINT` handler in `app.d`, before any command runs.
The handler (`cli.requestInterrupt`) does exactly one thing -- set an atomic
flag -- because a signal handler can run on any thread at any point and must
stay async-signal-safe: no GC, no allocation, no locking, no throwing.

`cli.runApp`'s file walk (`submitPath`, the single call site used for both
the single-file case and every file `walkCanonical` discovers) polls that
flag cooperatively, once per file, before admitting the next one. On a true
read it stops admitting new work and drains already-admitted work through
the same graceful-cancellation path a fatal processing failure already uses
(`scheduler.cancel(); scheduler.finish();`, see
[bounded-input.md](bounded-input.md#traversal-cancellation-and-failure-reporting)):
in-flight files finish, queued reservations release, and the process exits
2 with `scrubbed: interrupted (SIGINT); canceling after in-flight work
drains` on stderr.

`--explain` can report a per-file `status=canceled`, `canceled after SIGINT`
record -- distinct from a fatal processing failure or a traversal error --
but only for a file that had already reached the pending/submitted set (via
`pending.add(file)` in `submitPath`) before the signal landed; a file the
walk had not yet admitted at that point is simply absent from `--explain`
output, not reported as canceled. In practice this makes the per-file
`canceled after SIGINT` record a multi-threaded/deep-queue phenomenon: with
several workers and files queued ahead of them, there is reliably a batch of
admitted-but-unfinished files at the moment SIGINT lands. Single-threaded
(`--threads 1`) runs are the opposite case -- submission and completion track
closely enough that there is essentially never a file sitting
admitted-but-unfinished at signal time, so `--explain --threads 1` produces
zero `canceled` records even though many files never got processed; those
files are just missing from the output. (The overall exit path still prints
an aggregate `done. N succeeded, M canceled before this fatal error.` count
regardless of thread count, per
[bounded-input.md](bounded-input.md#traversal-cancellation-and-failure-reporting)
-- it is only the per-file `--explain` record that depends on admission
timing this way.)

This is **cooperative, per-file granularity, not preemptive**: a SIGINT that
arrives while a single file is mid-transform is only observed after that
file finishes (or the next one starts). For the CLI's normal workload --
many bounded-size documents -- this keeps the observable latency well under
a second; it does not bound the latency for an unusually large single file.

`extract` (a separate command with its own scheduler in `runApp`'s sibling
function) does not yet poll this flag; SIGINT during `extract` currently
falls through to whatever the process's default disposition happens to be
(see the caveat below). This is a deliberate scope limit for #448, not an
oversight -- the ticket's acceptance criteria target `clean-web-document`/
`run`.

## SIGTERM: OS default (immediate termination)

`scrubbed` installs no `SIGTERM` handler. `SIGTERM` keeps its OS default
disposition: the process dies immediately, with no flush, no summary line,
and no distinction from any other abrupt kill. Output written so far is
whatever atomic per-file writes had already completed
(`effects.atomic_piece_sink`); nothing is corrupted, but nothing says "this
run was cut short" either. This asymmetry (courteous SIGINT, abrupt
SIGTERM) is intentional: SIGINT is the signal an interactive `kill -INT` or
a wrapper's Ctrl-C equivalent sends when it wants the tool to *stop*, and is
common enough (a CI job canceling a step, a supervisor sending SIGINT before
escalating to SIGTERM) to be worth a defined, tested shutdown path; SIGTERM
already behaves reasonably (prompt, deterministic, non-corrupting) without
one.

## Root cause of the original report (#448)

Investigation found no signal handling anywhere in `scrubbed`'s own source
or its path dependencies (`lexbor-d`, `lexcontent`, `warc-reader`,
`httpfetch`, `third_party/*`) before this change -- confirmed by grepping
all of them for `SIGINT`/`SIGTERM`/`signal(`/`sigaction`/`sigprocmask`, all
empty except the pre-existing `SIGPIPE` handler in
`effects/stdio_stream.d`. `libcurl`'s own signal interaction was also ruled
out: `CURLOPT_NOSIGNAL` is already set for every request, and the
`clean-web-document`/`run` local-file path never calls `curl_global_init` at
all.

The GC's parallel-marking scan threads (`core.internal.gc.impl.conservative
.gc.startScanThreads`, upstream druntime issue 20256) were the first
suspect -- they deliberately block all signals via `pthread_sigmask` before
spawning, so the newly created background scan threads never observe
process signals. A minimal, dependency-free repro program (single-threaded,
GC-allocation-heavy, no `TaskPool`, no `scrubbed` code at all) was built to
test this in isolation from `scrubbed`'s own dependencies. Disabling
parallel GC marking entirely (`--DRT-gcopt=parallel:0`) did **not** change
the outcome -- the same repro still swallowed `SIGINT` completely -- which
rules out the GC scan-thread mechanism as the actual cause.

The actual cause: **how the reproduction launched the process, not
`scrubbed` itself.** Both the ticket's own repro ("start ... in the
background ... `kill -INT $PID`") and this investigation's initial testing
used a shell's `cmd &` backgrounding. POSIX shells (and bash specifically,
in a non-interactive/scripted context, which is exactly how an autonomous
agent's shell tool and many CI runners operate) set `SIGINT` and `SIGQUIT`
to `SIG_IGN` for a command started asynchronously with `&`, so that an
interactive Ctrl-C (which the terminal driver delivers to the whole
foreground process group) does not also kill background jobs. `exec`
preserves a `SIG_IGN` disposition across the call, so the child inherits
"ignore `SIGINT`" *before `scrubbed` -- or druntime, or anything else in the
process -- ever runs a single line of code.* `SIGTERM` is untouched by this
shell convention, which is exactly why the ticket's SIGTERM control test
worked normally while SIGINT did not: the asymmetry was never about what
`scrubbed` does with the two signals, only about what the launching shell
had already done to one of them.

This was confirmed directly, three ways, with the same minimal
dependency-free repro binary:

1. **Foreground** (no shell backgrounding): querying the process's own
   `SIGINT` disposition via `sigaction(SIGINT, null, &act)` at startup
   reports `SIG_DFL` (default -- would terminate the process).
2. **`./repro &` inside a non-interactive bash script** (the harness used
   for this investigation, and structurally the same pattern the ticket's
   own repro describes): the same query reports `SIG_IGN` (ignored).
3. **Launched via `subprocess.Popen` (Python), with no shell job control
   involved**: the same query reports `SIG_DFL` again, and an explicit
   `kill -INT` sent from the launching Python process actually terminates
   the child (confirmed via `poll()` returning `-2`, Python's
   terminated-by-signal-2 convention) well before the job's natural
   ~15-second completion.

None of this means the fix above is unnecessary, though: many real
callers -- CI steps, orchestrators, `nohup`-style supervisors, and shell
scripts that background the job -- launch `scrubbed` exactly the way that
triggers the inherited `SIG_IGN`, so relying on the OS default disposition
for `SIGINT` is not reliable for this tool's actual audience. Installing an
explicit handler in `app.d` (this change) always overrides whatever
disposition was inherited, `SIG_IGN` included, which is what makes `kill
-INT` reliable across all three launch methods above -- not just the
foreground/`Popen` cases that happened to work already.

## Regression coverage

`source/cli.d` has an in-process `unittest` that pre-sets the interrupt flag
(`resetInterruptedForTest`/`requestInterrupt`) before calling `runApp` on a
real multi-file directory, and asserts the run stops immediately with the
"interrupted (SIGINT)" message and admits no files -- a fast, deterministic
proof that the flag actually reaches and stops the walk. It resets the flag
on exit so it cannot leak into other tests in the same process.

The wall-clock claim in the acceptance criteria -- exits well before a
job's natural completion when SIGINT arrives partway through -- was proven
by hand against the built `release` binary rather than folded into `dub
test`: this same binary, built with `--build=release-unittest`, reruns its
*entire* module-unittest suite (several seconds, arbitrary console output)
on every invocation before an invocation's own argv is ever dispatched, and
a real subprocess test needs to both launch a second real invocation of the
binary and send it a real signal -- both interact badly with that: a
naive version either measures the wrong thing (the unittest preamble, not
the real command) or -- once corrected to actually reach real dispatch via
druntime's own `--DRT-testmode=run-main` switch -- recurses (the spawned
child reruns this same subprocess-spawning test as part of *its own*
preamble) or lets one process's real SIGINT land while an unrelated
module's unrelated unittest is still running concurrently in the same
run, which was observed, once, to fail an unrelated module's assertion.
`--DRT-testmode=run-main` was also separately observed to make SIGINT fall
through to the OS default in that configuration specifically (a
druntime/test-harness interaction, not a second `scrubbed` bug, and not a
flag `scrubbed`'s own invocations ever pass). None of that risk is worth
taking on for the sake of one more automated assertion, so the timing proof
stays manual, with its real numbers recorded here and in the PR that landed
this change; the deterministic in-process test above is what actually
guards against a future regression in the wiring.

Measured against the plain `release` build (`dub build --build=release`),
single-threaded, on a 4000-file HTML corpus (20x the bundled
`examples/pipeline-benchmark/corpus`, ~530 MB): natural completion took
~28.8s. Sending `SIGINT` 5.0s in (via `kill(2)` from a separate Python
process, not a backgrounded shell job, to isolate this from the shell
artifact described above) produced exit code 2 at t=5.01s -- effectively
immediate -- with `scrubbed: interrupted (SIGINT); canceling after
in-flight work drains` on stderr and 552/4000 files written. The identical
setup with `SIGTERM` in place of `SIGINT` exited at t=5.02s with no
handler-driven message (raw signal death, unchanged from before this
change).
