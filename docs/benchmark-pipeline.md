# Local pipeline benchmark (A01)

`benchmarks/pipeline.d` is a D-only, full-process local-file benchmark. It
generates 32 small files or two larger files with the same aggregate bytes,
then runs the shipping CLI on both. Each run starts a new process, admits the
input tree, applies `normalize-line-endings,strip-control`, and writes a fresh
output tree. The manifest variant times a first run followed by two verified
skips, each with independent rehashing of the outputs. All three samples and
per-file input/output SHA-256 values are retained in JSON. Incorrect bytes,
missing files, extra files, failed commands, missing timing metrics, partial
samples, and a manifest warm run without a reported skip abort the run. The
quality gate precedes publication of every timing result.

From the repository root on macOS or Linux:

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
report, incorrect output bytes, and an extra output file. The checked-in
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

The report uses only path tokens in its command templates; it does not embed
checkout, fixture, manifest, executable, or hostname paths. It includes the
source revision observed at run time and exact binary/harness/config hashes,
compiler and build flags, OS/architecture/CPU, per-run status, phase, wall,
user and system CPU seconds, peak process RSS, fixture input bytes, expected
output bytes, and raw samples. Fixture and expected-output byte counts are
calculated from the generated corpus; they are not independently observed I/O
counter values. GC and peak open FDs are not instrumented. `time` reports
process peak RSS only. BSD `time -l -p` gives bytes; GNU `time -v` gives KiB
converted to bytes. Both round short timings to hundredths of a second.
The report explicitly labels the source-to-supplied-binary mapping
`UNVERIFIED`: the executable's SHA-256 is measured, but merely reading Git
HEAD does not prove which source commit produced an externally supplied
binary. The filter digest hashes the selected filter string, not the
manifest's entire effective canonical configuration (which also includes
output route, binary and other policy bytes).

"First" means the first process for a freshly generated tree, not OS-cold
page cache. "Warm" means another process with its application cache empty;
the OS page cache may be warm. The harness neither drops nor measures OS page
cache. The no-manifest repetitions delete only their own UUID-scoped output
tree. The manifest repetitions retain the exact destination and database so
the output rehash/skip cost remains in the measured process boundary. This
is not an A/B interleaving study: no cross-tool or cross-revision speed claim
is made from these runs.

The current generated corpus is small and repetitive: each layout contains
32,768 records, around 0.8 MiB of input. It is an integration and
methodology baseline, not a representative document corpus. The benchmark
does not time changed-input/config/binary/output manifest paths or
kill-and-restart recovery; the paired release gate above checks their
correctness. Open-FD or GC sampling and a safely completed greater-than-RAM
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
timing is included. The raw Apple M4 samples were 0.03/0.03/0.02/0.03
seconds in A/B/A/B order—too coarse for a speed ranking. The report marks
source-tar-to-binary mapping unverified despite recording the observed build;
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
