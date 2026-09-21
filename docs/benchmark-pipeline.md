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
```

The self-test runs in release mode. It rejects missing required metadata,
partial or zero samples, a false quality claim, a temporary path in the
report, incorrect output bytes, and an extra output file. The checked-in
`cli_baseline.d --self-test` separately rejects prefix-collision ftfy and
wcwidth versions. `experiments/content/bench.d` now checks equality with a
runtime throw, even when assertions are disabled by `-release`.

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
does not yet include changed-input/config/binary/output manifest paths,
kill-and-restart injection, open-FD or GC sampling, or a safely completed
greater-than-RAM case. Those acceptance obligations remain open. This host
had only 24 GiB free scratch space at preflight; no >RAM run was attempted
without a measured RAM, scratch, and run-time budget. The benchmark streams
fixture generation into individual files rather than allocating an aggregate
corpus in memory. Its UUID-scoped scratch tree is removed after the report;
the report should be saved separately before process exit.

## Comparator boundary

The existing [CLI baseline](../benchmarks/README.md) pins `ftfy==6.3.1` and
`wcwidth==0.8.4` and compares the observed ftfy CLI against scrubbed only on
the exact-output-matched mojibake file task. This new normalization/tree
benchmark has no verified task-equivalent independently sourced executable
installed on this host (`uconv` and `dos2unix` are unavailable). ICU's
[transforms](https://unicode-org.github.io/icu/userguide/transforms/general/)
document character removal, but a verified CLI invocation with identical
CRLF/CR and Cc-except-tab/CR/LF semantics and matching tree I/O has not been
established. [dos2unix's own manual](https://dos2unix.sourceforge.io/dos2unix/man1/dos2unix.htm)
addresses line conversion but not this combined
filter task. Its speed is therefore **UNSUPPORTED**, not zero or omitted from
a claimed ranking. [Trafilatura's CLI](https://trafilatura.readthedocs.io/en/latest/usage-cli.html)
extracts content from HTML; scrubbed does not yet provide that production
task, so no trafilatura parity or speed comparison is made. No speedup, TB
readiness, or cross-task ranking follows from this benchmark.
