# Signal handling

## SIGINT: graceful shutdown

`scrubbed` installs a `SIGINT` handler in `app.d`, before any command runs.
The handler (`effects.interrupt.requestInterrupt`, re-exported by `cli.d` as
`cli.requestInterrupt` so `app.d` -- which may import only `cli` among
project modules -- can still reach it) does exactly one thing -- set an
atomic flag -- because a signal handler can run on any thread at any point
and must stay async-signal-safe: no GC, no allocation, no locking, no
throwing. The flag itself lives in `effects.interrupt`, not `cli`, so that
`route-metadata` (a plain `effects` module) can poll it without importing
`cli`, which this project's module layering forbids for `effects` code (see
`scripts/check_modules.d`).

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

`extract` (`cli.runExtract`, a separate command with its own scheduler) and
`route-metadata` (`effects.metadata_route_cli.runMetadataRoute`) poll the
same flag cooperatively too (#482). Both gaps were real bugs, not a
documented scope limit: because `app.d` installs `requestInterrupt` as the
process's SIGINT handler unconditionally, before any subcommand dispatch,
installing it replaces the OS default SIGINT disposition for *every*
command in the binary -- including these two, which never polled the flag
it sets. SIGINT during `extract` or `route-metadata` did not "fall through
to the OS default" as this document previously (incorrectly) claimed for
`extract`; it was silently swallowed, and the process ran to completion
exactly as if no signal had ever arrived. This was verified empirically,
against the pre-fix binary, with real `kill -INT` sends: see "Measured
evidence (#482)" below for the after-fix numbers, and issue #482 itself for
the original before-fix repro (route-metadata: CPU climbing for 8+ seconds
past the signal; extract: 6000 files fully completed 1 second after SIGINT).

- `runExtract`'s own admission loop (the `dirEntries`/single-file walk that
  calls `scheduler.submit`) polls `interruptRequested()` once per discovered
  file, before admitting it -- the same granularity and the same
  `scheduler.cancel(); scheduler.finish();` graceful-drain path `runApp`
  uses, reached through the same `interrupted (SIGINT); canceling after
  in-flight work drains` exception and exit code 2.
- `runMetadataRoute`'s per-file loop polls `interruptRequested()` once per
  file, before starting it. Each file this route processes is committed
  independently and atomically (`IndependentLocalSinks`), so stopping
  between files already drains exactly the in-flight document; there is
  nothing further to wait on. Unlike `run`/`repair`/`extract`, this route's
  diagnostics are deliberately fixed-token, with no dynamic content (no
  source bytes, paths, or metadata) -- so a SIGINT stop reports the fixed
  string `scrubbed: route-interrupted` on stderr and exits 2, rather than
  the dynamic `interrupted (SIGINT); canceling after in-flight work drains`
  message the other three commands use.

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

## Regression coverage and measured evidence (#482)

`source/cli.d` has the same shape of deterministic in-process `unittest` for
`runExtract` as the one described above for `runApp`: pre-set the interrupt
flag before `runExtract` ever admits a file from a real multi-file
directory, and assert the run throws with the "interrupted (SIGINT)"
message and admits no files. `source/effects/metadata_route_cli.d` has the
equivalent test for `runMetadataRoute`: pre-set the flag before it processes
the one file in a real input directory, and assert it returns exit code 2
and publishes neither the content nor the metadata sink. Both reset the flag
on exit so it cannot leak into other tests in the same process. As with
#448's own `runApp` test, a real-subprocess/real-`kill -INT` automated test
was deliberately not attempted for either command, for the same
`--DRT-testmode=run-main` recursion/preamble reasons given above; the timing
proof below was gathered by hand against the built `release` binary instead.

Measured against the plain `release` build (`dub build --build=release`),
the same 4000-file, ~526 MB HTML corpus used for #448's own measurement
above, `SIGINT` sent via `kill(2)` from a separate Python process (not a
backgrounded shell job):

- **`extract`** (single-threaded by construction -- its `BoundedInput` is
  configured with a worker count of 1): natural completion took ~8.2s.
  Sending `SIGINT` 2.0s in produced exit code 2 at t=2.01s -- effectively
  immediate -- with `scrubbed: interrupted (SIGINT); canceling after
  in-flight work drains` on stderr and 1115/4000 output files written.
  Before this change, the identical setup ran to completion regardless of
  the signal (matching issue #482's own report of 6000/6000 files
  completing despite a SIGINT sent 1s in).
- **`route-metadata`**: sending `SIGINT` 3.0s into the run produced exit
  code 2 at t=3.02s with the fixed-token `scrubbed: route-interrupted` on
  stderr, and 172/4000 files written to *both* the content and the metadata
  sink (equal counts, confirming each file's independent sinks are still
  published atomically together, never one without the other, even when a
  signal lands between files). Before this change, the identical setup
  showed no observable effect from SIGINT at all, matching issue #482's
  report of CPU climbing for 8+ seconds past the signal.
