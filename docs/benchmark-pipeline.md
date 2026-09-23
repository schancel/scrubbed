# Local pipeline benchmark (A01)

`benchmarks/pipeline.d` is a D-only, full-process local-file benchmark. It
generates 32 small files or two larger files with the same aggregate bytes,
then runs the shipping CLI on both. Each run starts a new process, admits the
input tree, applies `normalize-line-endings,strip-control`, and writes a fresh
output tree. The manifest variant times a first run followed by two verified
skips, each with independent rehashing of the outputs. All three samples and
per-file input/output SHA-256 values are retained in JSON. After the skip
samples, it separately times an explicit changed-input retry, a changed
filter-selection retry, and a new output route. The changed-input fixture
changes the first file's visible `alpha` to `Alpha`; the output gate requires
that change in `doc-0.txt` and unchanged bytes in every other file. Each
`EXPLAIN` status is keyed to its unique input filename, so one retry on the
wrong file cannot pass the aggregate count. All per-file statuses and exact
output trees are gated. A 64 MiB single-file restart probe
observes a durable `planned` row through the local `sqlite3` CLI, kills only
the recorded child PID, then times replay/reconciliation and a verified skip.
The replay is checked against exact input/output hashes. Incorrect bytes,
missing files, extra files, failed commands, missing timing metrics, partial
samples, and a manifest warm run without a reported skip abort the run. The
quality gate precedes publication of every timing result.

From the repository root on macOS or Linux with `sqlite3` CLI available:

```sh
dub test --compiler=ldc2
dub build --build=release --compiler=ldc2
ldc2 -O3 -release benchmarks/pipeline.d -of=/tmp/scrubbed-pipeline
/tmp/scrubbed-pipeline --self-test
/tmp/scrubbed-pipeline --self-test-attestation \
  benchmarks/pipeline_attestation_check.d
/tmp/scrubbed-pipeline --self-test-build-isolation "$(pwd)"
ldc2 -O3 -release benchmarks/pipeline_build_attestation_check.d \
  -of=/tmp/scrubbed-pipeline-build-attestation-check
/tmp/scrubbed-pipeline-build-attestation-check \
  /tmp/scrubbed-pipeline "$(pwd)"
/tmp/scrubbed-pipeline --self-test-snapshot "$(pwd)/scrubbed" \
  /tmp/dos2unix-7.5.7/dos2unix
/tmp/scrubbed-pipeline "$(pwd)/scrubbed" > /tmp/scrubbed-pipeline-result.json
# To preserve a publication-safe raw sample in the repository instead:
/tmp/scrubbed-pipeline "$(pwd)/scrubbed" benchmarks/pipeline-sample.json
# From a clean checkout, build and time only harness-attested target bytes:
/tmp/scrubbed-pipeline --attested-build "$(pwd)" \
  /tmp/scrubbed-pipeline-attested.json
```

The self-test runs in release mode. It rejects missing required metadata,
partial or zero samples, a false quality claim, a temporary path in the
report, incorrect output bytes, an extra output file, an unproven restart,
a false post-restart skip, and swapped retry/skip statuses between two files.
The checked-in
`cli_baseline.d --self-test` separately rejects prefix-collision ftfy and
wcwidth versions. `experiments/content/bench.d` now checks equality with a
runtime throw, even when assertions are disabled by `-release`.
The separate release snapshot self-test copies dos2unix into an owned
disposable path, atomically replaces that original path with an invalid
executable after the first comparator sample, and requires the later sample
and published hash to remain bound to the pre-timing snapshot.
The D-only attestation self-test builds two task-equivalent line-ending targets
from `pipeline_attestation_check.d`. Their executable hashes must differ, their
exact output must match, and the A/B/A/B samples must each carry the hash of
the executable actually run. It release-actively rejects a modified post-build
target, a changed snapshot, mixed sample attribution, and false exact-output
status. This is an attribution control, not a speed comparison.

The timing runner is paired with the pre-existing release-active, actual-binary
manifest boundary check. Run it on the *same shipping executable* before
accepting a manifest timing report:

```sh
ldc2 -O3 -release -Isource experiments/manifest_cli/check.d \
  source/domain/document.d source/content/pieces.d \
  source/effects/atomic_piece_sink.d source/effects/sqlite_ffi.d \
  source/effects/local_manifest.d third_party/sqlite/sqlite3.o \
  -of=/tmp/scrubbed-manifest-cli-check
/tmp/scrubbed-manifest-cli-check "$(pwd)/scrubbed"
```

It is D code with runtime throws, not assert-only proof. It checks changed
input, config bytes, executable bytes and output route; tampered outputs;
independent tree skips; and a live SIGKILL after a durable planned row,
followed by explicit reconciliation or safe restart and a verified skip. This
is a correctness gate, not a timed sample, and it does not claim power-loss
durability. The optional marker-instrumented build described in
[`local-manifest.md`](local-manifest.md) covers additional crash windows.

The version-3 and version-4 reports use only path tokens in their command templates; they do not embed
checkout, fixture, manifest, executable, or hostname paths. They include the
source revision observed at run time and exact binary/harness/config hashes,
the available host LDC version and harness reproduction command,
OS/architecture/CPU, measured physical RAM and its
source, per-run status, phase, wall,
user and system CPU seconds, peak process RSS, fixture input bytes, expected
output bytes, and raw samples. Fixture and expected-output byte counts are
calculated from the generated corpus; they are not independently observed I/O
counter values. GC and peak open FDs are not instrumented. `time` reports
process peak RSS only. BSD `time -l -p` gives bytes; GNU `time -v` gives KiB
converted to bytes. Both round short timings to hundredths of a second.
The per-sample `input_tree_bytes_observed` and
`output_tree_bytes_observed` are post-run filesystem lengths; they are not
the syscall bytes read/written, especially for a verified skip. The benchmark
does not instrument actual I/O byte counters. Peak open FDs are unavailable:
neither supported `time` variant exposes them, and a short-lived subprocess
`lsof` poll would only be a sampling lower bound. GC internals are likewise
not observable from the external shipping process. These metrics are
explicitly unsupported, not reported as zero.
The report explicitly labels the source-to-supplied-binary mapping
`UNVERIFIED`: the executable's SHA-256 is measured, but merely reading Git
HEAD does not prove which source commit produced an externally supplied
binary. The supplied target binary's compiler and build flags are also
`UNVERIFIED`; `harness_compiler_available_version` identifies only an LDC
installation available on the benchmark host, while
`harness_reproduction_command` is a recipe, not an attested build log.
Before timing, the D runner copies each supplied executable into its own
mode-restricted UUID scratch directory, makes the copy read-only/executable,
hashes that snapshot, executes only the snapshot for every sample and restart,
and checks its hash again before publication. The reported binary hash is the
*executed snapshot* hash; changes to the caller's original pathname after
snapshot creation cannot mix binary versions in one report. A source-path
replacement during the initial copy can at worst produce a snapshot whose
actual bytes are hashed and tested; source-to-binary provenance remains
unverified. All snapshots are removed with the benchmark's own scratch tree.
The filter digest hashes the selected filter string, not the
manifest's entire effective canonical configuration (which also includes
output route, binary and other policy bytes).

The opt-in `--attested-build` path emits version 5 for the small corpus and
version 6 for `--large`. It refuses tracked or untracked source changes,
records the exact source commit/tree and SHA-256 of its Git archive, then
extracts that already-hashed archive into UUID-named, user-private scratch.
The release build runs only there; ignored caller `.dub`, native-object, and
target artifacts are neither copied nor consumed. DUB resolution uses a
private `DUB_HOME` and `--cache=local` beneath the private extracted source.

Build attestation v4 records hashes of `dub.json`, `dub.selections.json`, the
resolved compiler and DUB executables, their versions, and the complete
versioned argparse recipe/input set named by DUB's release build description.
LDC and DUB are invoked only through private read-only snapshots and their
hashes are verified again after the build, so same-path replacement of the
original executable cannot change the described or compiled target.
It also records the fixed native pre-build command digest and exact identities
(name, role, per-executable version or explicit `UNAVAILABLE`, and executable SHA-256) of the ambient `cc`, `ar`, and
`ranlib` selectors; their `xcrun`-selected Clang/archive executables; and
`cmake` and the `xcrun`-selected Make executable. Selector shims and the selected `ar` binary expose no usable
per-executable version query, so their rows say `UNAVAILABLE`; a separate
versioned archive-suite record
names the exact `ranlib-writer -V` evidence command and binds its output to
that ranlib executable's SHA-256. It is never presented as an `ar` version.
The closure also hashes, honestly versions, pins, and re-verifies the
`xcrun`-selected final linker. `COMPILER_PATH` points to its private `ld`
symlink, and an attested-compiler `-###` trace must select that exact path
before the release build. The private commands invoke the selected executables
directly. The material tools are
resolved before building, exposed through a
private pinned-tool directory and fixed system PATH, and accompanied by exact
`CC`, `AR`, and `RANLIB` environment values. Their identities are verified
again after compilation. The selected macOS SDK version/build is recorded and
its exact root is supplied privately through `SDKROOT`; the report omits that
host path. The Lexbor CMake cache must name the attested C
compiler, archive tools, and pinned make executable. A D-only negative swaps
ambient PATH to executable poison tools, including `ld`, after resolution and
requires the private build and emitted attestation to remain bound to the
resolved set. A separate D-only same-path replacement control proves the
private LDC/DUB snapshots remain executable and hash-bound after their source
paths change.
The argparse input digest is likewise verified after compilation. The supported DUB
1.42.0 target path is derived from the described root `targetPath` plus
`targetFileName`, required to remain the private relative path `scrubbed`, and
verified before snapshotting. The D-only build-attestation check poisons caller
ignored artifacts, mutates a private argparse source to prove digest change and
rejection, exercises target discovery, and requires actual v5 report
publication. Attestation v2 and inconsistent v3 records are rejected.

The target is hashed, copied to a read-only snapshot, and accepted only when
the built-target and snapshot hashes match. Every timed case, manifest
transition, replay, and skip in v5/v6 carries that target hash. The embedded
changed-executable control retains both distinct variant hashes and raw A/B/A/B
sample attribution. Supplied binaries remain v3/v4 and explicitly
`UNVERIFIED`; adding an attestation to an old schema, spoofing compiler/flags,
or mixing a sample hash causes rejection. Reports contain only path tokens and
hashes, never checkout or scratch paths.

On Linux, the D harness reads `model name`, `Hardware`, or `Processor` from
`/proc/cpuinfo` and `MemTotal` in `kB` from `/proc/meminfo`. If either cannot
be parsed, it exits nonzero without publishing a report; it never records a
placeholder model or `ram_bytes=-1`. The release self-test includes valid and
invalid Linux metadata plus a cross-host negative for a fabricated capacity
claim. Every generated report marks >RAM *not attempted* pending a host-specific
RAM/scratch/time preflight; the Apple capacity finding below belongs only to
the committed Apple sample and its documentation.

"First" means the first process for a freshly generated tree, not OS-cold
page cache. "Warm" means another process with its application cache empty;
the OS page cache may be warm. The harness neither drops nor measures OS page
cache. The no-manifest repetitions delete only their own UUID-scoped output
tree. The manifest repetitions retain the exact destination and database so
the output rehash/skip cost remains in the measured process boundary. This
is not an A/B interleaving study: no cross-tool or cross-revision speed claim
is made from these runs.

The current generated corpus is small and repetitive: each layout contains
32,768 records, 786,432 bytes (0.75 MiB) of input. It is an integration and
methodology baseline, not a representative document corpus. The benchmark
times changed input/filter selection/output route and post-kill replay.
Attested reports additionally run the separate task-equivalent
changed-executable attribution control, but make no ranking from its timings.
Peak open-FD/GC and actual read/write byte
counters and a safely completed greater-than-RAM
case remain unsupported. On the observed Apple M4 host, `sysctl -n hw.memsize`
reported 17,179,869,184 bytes (16 GiB) RAM and `df -k .` reported
24,899,788 KiB (23.75 GiB) free. A >RAM normalization case needs more than
16 GiB input *and* roughly equal output plus manifest/temp headroom, already
exceeding free scratch before a time budget is considered. It is unsafe here,
so the >RAM case is **UNSUPPORTED** rather than scored. The benchmark streams
fixture generation into individual files rather than allocating an aggregate
corpus in memory. Its UUID-scoped scratch tree is removed after the report;
the report should be saved separately before process exit.

### Larger, capacity-gated local corpus

The opt-in `--large` mode adds matched many-small (32 files) and few-large
(two files) layouts at 16,776,960 bytes (about 16 MiB) and 134,215,680 bytes
(about 128 MiB) of input per layout, alongside the small cases. Both layouts
at each size contain the same number of identical 24-byte generated records;
they apply the same two filters and independently gate exact bytes and keyed
per-file manifest statuses. First-process, two verified-skip repetitions,
changed input/config/output route, and the separate planned-row restart probe
remain included. The larger fixture uses chunked writes rather than millions
of record-sized writes. Run with a declared local time budget of at least
900 seconds:

```sh
/tmp/scrubbed-pipeline "$(pwd)/scrubbed" \
  benchmarks/pipeline-resource-sample.json --large 1800
```

The D harness checks measured physical RAM and `df -Pk` scratch availability
*before* any large fixture is created. It requires at least 2 GiB RAM, the
large corpus to fit in RAM, about 1.63 GiB of free scratch reservation for input,
output, alternate output, manifest/restart state and headroom, and the declared
time budget. The check is a refusal threshold, not a deadline or guarantee
against other users consuming disk. The version-4 report records the measured
preflight inputs and per-sample observed fixture/output filesystem lengths.
Version 3 small-only reports remain distinct; a version-4 report missing any
layout or preflight fails validation. The v4 validator recomputes the scratch
reservation from the known total input footprint and checks the independent
2 GiB RAM floor and input-less-than-RAM rule; a report cannot validate by
forging RAM, free scratch and reservation to mutually consistent tiny values.
No >RAM run is attempted by this mode.

The external `/usr/bin/time` supplies process user/system CPU and peak RSS.
We investigated an FD count sampler, but the current timing wrapper owns the
PID of the `time` process rather than a portable, directly sampled target PID;
macOS and Linux expose different process-FD APIs. An interval sampler here
would miss short spikes and could perturb short runs, so no FD maximum is
published. It remains **UNSUPPORTED**, as do external-process GC counts and
actual syscall read/write bytes. The fixture/output byte fields are measured
file lengths or calculated expected lengths, never syscall counters. These
synthetic scaling samples do not establish OS-cold, TB readiness, or a general
speed advantage over other tools.

The checked-in `pipeline-resource-sample.json` was collected on an Apple M4
with 17,179,869,184 physical RAM bytes and 17,557,745,664 free scratch bytes
at preflight. The raw report retains three samples per case, including the
small baseline, manifest skips, all per-file output hashes/statuses, and the
restart probe. For the 16 MiB/128 MiB first-write layouts, the raw wall ranges
were 0.58–0.66 s / 3.27–4.05 s across three samples per layout; user+system
CPU ranges were 0.55–0.62 s / 3.21–3.95 s, respectively. Peak RSS ranges
across these layouts were 8.34–97.20 MiB / 75.91–668.39 MiB; the disparity
between many-small and few-large is a useful reason to keep both layouts,
not a general memory scaling law. The 128 MiB layouts each had 123,031,040
bytes of exact-gated output. Wall variance reflects this host and run, and
these are raw repetitions rather than confidence intervals. The supplied
target binary's source mapping, compiler, and flags remain `UNVERIFIED` even
though its executed snapshot hash is retained.

### Canonical 128 MiB shipping-CLI profile

`scrubbed-cli-profile-v1` is an additive evidence artifact, not a production
optimization or a speedup claim. `pipeline.d --attested-profile` creates the
shipping release executable through the existing private
`scrubbed-build-attestation-v4` closure, snapshots that executable and the
D-only `pipeline_profile_check.d` harness, and lets the snapshot run the fixed
matrix. The report can be deleted with its harness/docs to roll this slice
back; no production format or behavior depends on it.

The independently authored cyclic table contains exactly 524,288 fixed-width
256-byte records (134,217,728 input bytes). It covers unchanged ASCII, valid
accented Unicode and emoji, supported Latin-1/CP1252 mojibake and negatives,
named/numeric entities and ampersand negatives, curly/straight quotes,
CRLF/bare CR, and removable controls while preserving tab/LF. ASCII padding
does not make a transform depend on record boundaries. The frozen table,
legacy-v1 config, scalar-v3 config, and mixed-v3 config have literal SHA-256
pins in the harness. Independently authored expected bytes do not call project
filters. The same logical stream is partitioned into 4,096 files of 32,768
bytes and eight files of 16,777,216 bytes. Reports retain exact per-file sets,
sizes and hashes plus tree and canonical-concatenation hashes. The checker
recomputes file counts, bytes, and tree hashes and binds every generated tree
and concatenation hash to literal fixture identities; the two layouts must
have equal concatenated input.

An untimed 8 MiB freeze requires exact output equality for default selection,
explicit `--filters`, equivalent v1 JSON, canonical v3 JSON, and ordered v3
tokens. The canonical v3 identity must match wherever that identity is
exposed; predecessor selectors are recorded as `NOT_EXPOSED`, not assigned a
fabricated identity. The expected selector tree, concatenated content, and
canonical v3 identity are literal independently frozen pins, so coordinated
replacement of expected and observed values is rejected. The 128 MiB ordinary matrix covers scalar
`normalize-line-endings,strip-control` and mixed
`uncurl-quotes,fix-mojibake,decode-html-entities,normalize-line-endings,strip-control`
workloads through both v3 JSON and ordered tokens on both layouts. Options are
pinned (`fix-mojibake max-passes=2`). Each case gets one untimed conditioning
process, then five fresh-process/fresh-output samples in round-robin declared
order. All ordinary children use `--threads 4 --max-open-inputs 4`. This is
application-cold with uncontrolled OS cache, never OS-cold.

The durable mixed matrix uses v3 JSON and shipping serialization. Each layout
has three independent manifest-v2 first-publication/verified-skip pairs and,
after explicit `errors-init`, three journal-v3 first/skip pairs. Every status,
exit, output set, byte count, and hash is gated. Every first and skip EXPLAIN
stream is parsed by exact filename, required complete, and reduced to a
deterministic status digest retained in the report. Crash/retry timing is outside
this profile; the existing manifest/journal correctness gates remain required.

The capacity preflight executes before fixture creation. Checked arithmetic
derives the planned scratch footprint, requires four times that value and at
least 2 GiB free scratch, at least 2 GiB physical RAM, and a declared budget of
at least 1,800 seconds. It refuses overflow and does not attempt a greater-than-
RAM workload.

Every timed application is the profiler's direct child PID. Monotonic wall
time and Darwin `wait4` user/system CPU, termination status and `ru_maxrss`
bytes are retained. `proc_pidinfo(PROC_PIDLISTFDS)` is polled every 10 ms; the
result is explicitly `sampled_peak_fd_lower_bound`, with sample/error counts
and polling interval, never an exact peak. Successful live-child
`proc_pid_rusage(RUSAGE_INFO_V4)` values are reported as Darwin disk-I/O bytes
from the last successful sample, never syscall bytes. The harness mirrors the
complete 296-byte Darwin `rusage_info_v4` through `ri_runnable_time`, proves
the 144/152 disk-counter offsets at compile time, and runs a guarded live ABI
canary. A noninteractive
privilege-free DTrace probe determines whether syscall tracing can proceed.
An exact-PID xctrace control is attempted before any total-allocation claim.
D runtime profiling, when recognized, is labelled GC-only and excludes native
allocations. `/usr/bin/sample` runs separately on a single-thread mixed child
for each layout and is accepted only with PID/binary binding and at least two
samples. Instrumented runs and their overhead are excluded from timing.
Unavailable or failed controls are structured `UNSUPPORTED`; zero is never a
substitute.

The checker executable basename is literally
`scrubbed-pipeline-profile-check` in the bridge and documented commands, so a
documented `ldc2 -O3 -release` rebuild with no additional flags reproduces the
report-bound Mach-O identity. The run also binds the resolved compiler hash
and version to the attested compiler closure.
`pipeline_profile_check --self-test` release-actively rejects 102 mutations,
including every material build-attestation axis, fixture/config/binary/harness
drift, unequal or swapped layouts, selector set/order/identity/output drift,
incomplete or reordered samples, durable route/pair/status drift, unsupported
metrics represented as zero, forged sample aggregates, sampled FDs represented
as exact, GC represented as total allocation, unsafe capacity arithmetic,
nonfinite/negative resource domains for both ordinary and durable samples,
bogus supported disk semantics, and local path leakage.
`--self-test-live` checks the authored records, direct-PID measurement, and
complete manifest-v2 and journal-v3 filename bindings on small actual shipping
invocations before the capacity-gated run. `--check`
revalidates the sanitized report and binds it to the checker executable.

The report makes no OS-cold, greater-than-RAM, 1 TiB, comparator superiority,
cross-platform, exact-FD, exact-syscall, native-allocation, or statistical
performance claim. Any later optimization needs a separate accepted contract
that preserves this fixture/schema/equivalence boundary and supplies
interleaved before/after evidence.

## Comparator boundary

The existing [CLI baseline](../benchmarks/README.md) pins `ftfy==6.3.1` and
`wcwidth==0.8.4` and compares the observed ftfy CLI against scrubbed only on
the exact-output-matched mojibake file task. A *separate* restricted
single-file CRLF-only task can compare scrubbed's `normalize-line-endings`
filter against independently sourced dos2unix. It does **not** compare the
combined normalization/control-stripping tree task. On this host we fetched
the official [7.5.7 source archive](https://dos2unix.sourceforge.io/) with
SHA-256 `669ee27120ae71589f638fe3a167d6ea54f8633f5ab1b282551bd7a7c9510dfa`,
built its CLI with `make ENABLE_NLS= dos2unix`, and observed
`dos2unix 7.5.7 (2026-08-27)`. Its official `COPYING.txt` identifies the
FreeBSD license. The independent binary and input/output hashes are recorded
in the raw report. Reproduce the A/B/A/B measurement after building that
exact version:

```sh
/tmp/scrubbed-pipeline --compare-dos2unix "$(pwd)/scrubbed" \
  /tmp/dos2unix-7.5.7/dos2unix benchmarks/dos2unix-sample.json
```

Both CLIs read the same 851,968-byte CRLF-only file and write a fresh
720,896-byte file. The scrubbed command uses `--filters
normalize-line-endings --threads 1`; dos2unix uses `-n INPUT OUTPUT`.
Every run must exactly match the independently specified bytes before its
timing is included. The committed raw Apple M4 samples are 0.24/0.02/0.01/0.02
seconds in A/B/A/B order—too coarse for a speed ranking. The report marks
source-tar-to-binary mapping and both supplied binaries' compiler/flags
unverified despite recording the observed build recipe;
the exact binary hash is the reproducible identity.

For the *combined* filter task, no equivalent executable was verified. ICU's
[transforms](https://unicode-org.github.io/icu/userguide/transforms/general/)
document character removal, but a verified CLI invocation with identical
CRLF/CR and Cc-except-tab/CR/LF semantics and matching tree I/O has not been
established. [dos2unix's own manual](https://dos2unix.sourceforge.io/dos2unix/man1/dos2unix.htm)
addresses line conversion but not this combined filter task. Its speed for
that task is therefore **UNSUPPORTED**. [Trafilatura's CLI](https://trafilatura.readthedocs.io/en/latest/usage-cli.html)
extracts content from HTML; scrubbed does not yet provide that production
task, so no trafilatura parity or speed comparison is made. No speedup, TB
readiness, or cross-task ranking follows from this benchmark.
