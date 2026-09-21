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
/tmp/scrubbed-pipeline "$(pwd)/scrubbed" > /tmp/scrubbed-pipeline-result.json
# To preserve a publication-safe raw sample in the repository instead:
/tmp/scrubbed-pipeline "$(pwd)/scrubbed" benchmarks/pipeline-sample.json
```

The self-test runs in release mode. It rejects missing required metadata,
partial or zero samples, a false quality claim, a temporary path in the
report, incorrect output bytes, an extra output file, an unproven restart,
a false post-restart skip, and swapped retry/skip statuses between two files.
The checked-in
`cli_baseline.d --self-test` separately rejects prefix-collision ftfy and
wcwidth versions. `experiments/content/bench.d` now checks equality with a
runtime throw, even when assertions are disabled by `-release`.

The timing runner is paired with the pre-existing release-active, actual-binary
manifest boundary check. Run it on the *same shipping executable* before
accepting a manifest timing report:

```sh
ldc2 -O3 -release -Isource experiments/manifest_cli/check.d \
  source/domain/document.d source/effects/sqlite_ffi.d \
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

The version-2 reports use only path tokens in their command templates; they do not embed
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
The filter digest hashes the selected filter string, not the
manifest's entire effective canonical configuration (which also includes
output route, binary and other policy bytes).
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
times changed input/filter selection/output route and post-kill replay, but
does not time changed executable bytes. The paired release gate above checks
all of those correctness paths. Peak open-FD/GC and actual read/write byte
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
timing is included. The committed raw Apple M4 samples are 0.03/0.04/0.03/0.04
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
