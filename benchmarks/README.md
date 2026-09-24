# Benchmarks

All project benchmark and corpus-analysis utilities are written in D. The
baseline also measures the external ftfy CLI on its task-equivalent fixture.

## Exact durable verified-skip evidence

`durable_skip_check.d` reproduces the frozen 128 MiB many-small (4,096 files)
and few-large (eight files) layouts for both manifest-v2 and journal-v3. It
compares the instrumented preflight-disabled control with the candidate in
three alternating O3/release runs. Every retained run requires exact source
and output tree/concatenated hashes, the full skipped-status cardinality, one
exact source and output hash per file, no publication, and compiled execution
counts of one versus zero. Timings are descriptive local observations, not a
general performance guarantee.

```sh
dub build --compiler=ldc2 --build=release --force
ldc2 -O3 -release benchmarks/durable_skip_check.d \
  -of=/tmp/scrubbed-durable-skip-check
/tmp/scrubbed-durable-skip-check ./scrubbed \
  /tmp/scrubbed-durable-skip-evidence.json
```

The shipping instrumentation is fixed-cardinality, content-free,
concurrency-safe, and disabled unless the harness supplies its private metrics
environment. The evidence contains phase counts, bytes and elapsed time plus
child wall/CPU/RSS and sampled-FD observations. The first run in each series
also enables the D runtime's GC summary as a release-active availability
control. Scratch fixtures and raw logs remain private and are removed.

## Attested full-process target

`pipeline.d --attested-build` refuses a dirty checkout, builds the release
target exclusively from a hashed Git archive in private scratch with isolated
DUB dependency resolution, and binds every v5/v6 timing sample to the executed
target SHA-256 plus a versioned source/compiler/dependency/build attestation.
The attestation invokes private read-only snapshots of LDC and DUB and
re-verifies them after the build. It also pins and re-verifies the ambient
`cc`, `ar`, and `ranlib` selectors, their selected compiler/archive
executables, the selected final linker, and the `cmake` and `make` executables
used by the hashed pre-build recipe. Per-executable archive versions are never
borrowed from another binary: unavailable `ar` versions are explicit, with
separately hash-bound archive-suite evidence.
`pipeline_attestation_check.d` is the D-only changed-executable control: two
distinct target variants process the same exact-output fixture in A/B/A/B
order, and every sample retains its own executable hash. The control makes no
speed ranking. `pipeline_build_attestation_check.d` poisons caller ignored
artifacts and proves private argparse-input hashing, target discovery, and
actual report publication. Supplied binaries continue to emit explicitly
unverified v3/v4 reports. Commands, report fields, negatives, and unsupported
metrics are in [`docs/benchmark-pipeline.md`](../docs/benchmark-pipeline.md).

## Canonical full-CLI profile

`pipeline_profile_check.d` is the D-only runner and publication checker for
the evidence-only `scrubbed-cli-profile-v1` report. It measures only an
executable produced by `pipeline.d`'s existing private attested-build closure;
the bridge snapshots both target and profile harness before execution. The
fixed corpus is exactly 524,288 independently specified 256-byte records
(128 MiB), partitioned as 4,096 small files and eight large files without
changing the logical byte stream. Independently authored scalar and mixed
expected streams are exact-gated before a sample is retained.

```sh
ldc2 -O3 -release benchmarks/pipeline.d -of=/tmp/scrubbed-pipeline
ldc2 -O3 -release benchmarks/pipeline_profile_check.d \
  -of=/tmp/scrubbed-pipeline-profile-check
/tmp/scrubbed-pipeline-profile-check --self-test
/tmp/scrubbed-pipeline-profile-check --self-test-live "$(pwd)/scrubbed"
# The full run requires a clean Darwin checkout and passes its preflight first.
/tmp/scrubbed-pipeline --attested-profile "$(pwd)" \
  /tmp/scrubbed-pipeline-profile-check \
  benchmarks/pipeline-canonical-profile.json 1800
/tmp/scrubbed-pipeline-profile-check --check \
  benchmarks/pipeline-canonical-profile.json
ldc2 -O3 -release benchmarks/pipeline_resource_check.d \
  -of=/tmp/scrubbed-pipeline-resource-check
/tmp/scrubbed-pipeline-resource-check \
  benchmarks/pipeline-canonical-profile.json
```

The checker command above is the exact identity recipe: do not add compiler
flags or change the output basename. The run verifies the resolved `ldc2`
hash and version against the attested build-tool closure, and `--check` binds
the resulting Mach-O hash to the report.

The report binds source/compiler/dependency/build attestation, executed binary,
harness, frozen record table, configs, input and expected file sets, and every
timed output. Darwin `wait4` supplies direct-child wall/CPU/RSS accounting. FD
evidence is a `proc_pidinfo` sampled lower bound. `proc_pid_rusage` disk bytes
use the complete 296-byte `rusage_info_v4` ABI through `ri_runnable_time`, with
compile-time disk-field offsets and a guarded live layout canary, and retain
their kernel and last-success semantics. DTrace/dtruss, xctrace
allocations, D GC profiling, and `/usr/bin/sample` are calibrated separately;
failed controls are structured `UNSUPPORTED`, never zero or a substitute.
The strict checker also rejects nonfinite or negative timing/CPU values,
signals, byte-count drift, invalid RSS/FD/rusage domains, and fabricated disk
support for every ordinary and durable measurement.

## Canonical CLI attribution

`pipeline_attribution_check.d` publishes the evidence-only companion
`scrubbed-cli-attribution-v1`. It reuses the canonical profile's frozen
128 MiB fixtures, configs, expected outputs, durable semantics, report hash,
historical target hash, and build-closure schema without changing them. New
traces bind separately to the current-base attested target. For each layout it records
three exact-PID `/usr/bin/sample` traces for scalar threads1, mixed threads1,
mixed threads4, manifest-v2 verified skip, and journal-v3 verified skip. A
trace is accepted only after exact output and status gates and at least 100
bound stacks. Three separate druntime profiles cover scalar and mixed
threads1; their fields are explicitly D-GC-only.

```sh
ldc2 -O3 -release benchmarks/pipeline.d -of=/tmp/scrubbed-pipeline
ldc2 -O3 -release benchmarks/pipeline_attribution_check.d \
  -of=/tmp/scrubbed-pipeline-attribution-check
/tmp/scrubbed-pipeline-attribution-check --self-test
/tmp/scrubbed-pipeline-attribution-check --self-test-live-sample
# The full run requires a clean Darwin checkout and passes capacity first.
/tmp/scrubbed-pipeline --attested-attribution "$(pwd)" \
  /tmp/scrubbed-pipeline-attribution-check \
  benchmarks/pipeline-canonical-profile.json \
  benchmarks/pipeline-canonical-attribution.json 1800
/tmp/scrubbed-pipeline-attribution-check --check \
  benchmarks/pipeline-canonical-attribution.json
```

The exact checker recipe and output basename above bind the report to the
rebuilt Mach-O. Original sample/GC logs remain in private scratch only; the
report retains their hashes plus sanitized top symbols, partitions,
repetition order, median/range, tool settings, direct-child diagnostic
wall/CPU/RSS, and structured unsupported fields. Sampling is not an exact-call
counter, and D-GC evidence is not native or total-process allocation evidence.
The derived conclusion can be a stable named hotspot, distributed cost, or
unavailable attribution; none authorizes a production edit in this slice.
Current-revision diagnostic times are never merged with or directly compared
to the historical canonical timing samples.

## Materialization-boundary work evidence

`materialization_work.d` is the evidence-only first landing for #183. Its
fixed-size counters are caller-owned and exist only in a
`MaterializationWorkProbe` build; the ordinary executable contains neither the
probe APIs nor counter/GC branches. The JSON identifies the executable and
embeds and hashes each instrumented source plus its harness; execution refuses
a checkout that differs from those compiled-in texts. It also embeds and
hashes the frozen #59 canonical profile and attribution inputs without editing
or reinterpreting them. It deliberately reports
that no representation change is authorized: there is no boundary-removal
candidate or five-pair full-process threshold comparison in this landing.

```sh
ldc2 -i -O3 -release -d-version=MaterializationWorkProbe -Isource -J. \
  benchmarks/materialization_work.d -of=/tmp/scrubbed-materialization-work
/tmp/scrubbed-materialization-work --self-test
/tmp/scrubbed-materialization-work
```

The self-test compares ordinary and measured execution, checks strict invalid
UTF-8 exceptions, independent concurrent counters, split identity/order,
terminal reject/quarantine filter skipping, post-owner-close retained output, exact atomic
sink bytes and failure non-publication, identical/prefix/suffix/interior/empty
borrowed and distinct filter outputs in both measured paths, three accounting
mutants, and a 4 MiB allocation-heavy positive control. GC numbers are D
runtime current-thread allocation evidence, not total process or native
allocation.

| Boundary | Current ownership/lifetime rule | Payload work and status |
|---|---|---|
| mapped view -> borrowed `ContentPiece` | Descriptor retains a checked `DocumentViewOwner`; even an empty borrow fails after close. | No payload copy; mandatory zero-copy admission seam. |
| `Content` descriptor snapshot/edit/split | Descriptor arrays may be copied, but every borrow still requires its live owner; split children may share immutable input. | No payload copy. Sharing is mandatory for current split/lineage semantics. |
| `Content` -> UTF-8 string | `composition.executor` appends pieces into a growing GC-owned byte array, validates it, and exposes the resulting owning string before the public filter ABI. | One logical payload copy; mandatory while filters accept `string`; allocation can exceed final payload bytes while the array grows. |
| fused scalar run | Up to 16 consecutive caller-owned transducers borrow the input string and materialize one owning result. | One result materialization per fused run; longer runs intentionally form another bounded barrier. |
| whole-text filter | The pure public filter may return the identical input, a borrowed prefix/suffix/interior/empty subslice, a partially overlapping slice, or distinct GC-owned storage. The probe uses integer byte intervals rather than ordering unrelated pointers and records borrowed/overlap/distinct calls and bytes without retaining mutable state. | Borrowed subslices are not materializations; partial overlaps are never reported as distinct. Distinct algorithm-owned work is not removable by orchestration evidence alone. |
| filter result -> owned `ContentPiece` | `ContentPiece.own` duplicates the result so no caller/appender/scratch slice escapes and output survives source-owner close. | A second logical payload copy and the leading future candidate, but not authorized here. |
| final-event split/map descriptors | Events retain `Content` references synchronously; after-filters independently own each emitted result. | Unfiltered sharing is payload-copy-free; filtered siblings currently repeat the explicit barriers. |
| atomic piece sink | A 64 KiB caller-local buffer is consumed synchronously, fsynced, and renamed; no chunk escapes and no full-output join occurs. | One logical stream copy into bounded syscall storage; required by the current atomic sink. |

The frozen #59 scalar/mixed many-small and few-large reports remain the
full-process timing/RSS/D-GC baseline and are not edited or reinterpreted here.
Any later single-boundary candidate must run the accepted interleaved five-pair
gate against those exact hashes and meet the #183 improvement/regression
thresholds before production authorization.

## Fused scalar-filter microbenchmark

`fused_filters.d` compares the former separately materialized
line-ending/control/quote transforms with the runtime registry's fused scalar
range. It generates 131,072 identical mixed CRLF/control/curly-quote rows
(4,063,232 input bytes), checks every output byte and SHA-256, interleaves the
two implementations, and reports five rounds per sample.

```sh
ldc2 -i -O3 -release -Isource benchmarks/fused_filters.d \
  -of=/tmp/scrubbed-fused-filters
/tmp/scrubbed-fused-filters
```

On an Apple M4 / macOS 25.6.0 / LDC 1.43.0, the inline-state implementation's
three samples measured legacy at 0.41224–0.41767 seconds and fused at
0.21459–0.22009 seconds for five rounds, about 1.9x faster. Both produced
2,752,512 bytes with SHA-256
`31FED0E686961EAC721F89861DBA3AB0157F33C3C438AA314B3B4E226D96A62A`.
This is a warm synthetic in-process microbenchmark, not whole-CLI,
terabyte-scale, or contextual-filter evidence.

## Pre-refactor full-CLI baseline (A00)

`cli_baseline.d` measures whole processes, including input/output and startup,
on generated UTF-8 text and a 32-file nested tree. It refuses to emit a result
if any output differs byte-for-byte from the independently specified expected
output. Every case has five repetitions, raw wall/user/system CPU seconds and
peak resident bytes. The JSON emitted on stdout also records input/output
SHA-256, publication-safe command templates, binary and harness hashes, source
commit, host-neutral OS fields, CPU model, compiler, observed Python package
versions, flags, and unsupported capabilities. No fixture bytes from other
projects are redistributed.

From a clean checkout on macOS or Linux, with `ldc2`, `dub`, `uv`, and BSD/GNU
`/usr/bin/time` available:

```sh
bench_env=$(mktemp -d /tmp/scrubbed-a00-XXXXXX)
uv venv "$bench_env/venv"
uv pip install --python "$bench_env/venv/bin/python" ftfy==6.3.1 wcwidth==0.8.4
dub build --build=release --compiler=ldc2
ldc2 -O -release benchmarks/cli_baseline.d -of="$bench_env/cli_baseline"
"$bench_env/cli_baseline" --self-test
"$bench_env/cli_baseline" "$(pwd)/scrubbed" "$bench_env/venv/bin/ftfy" > "$bench_env/result.json"
```

In JSON, substitute `<scrubbed-binary>`, `<ftfy-cli>`, and `<fixture-root>`
with the run's local paths to replay a command; no checkout, user, hostname,
or temporary-directory path is published. The `result.json` path is local run
output, not a committed fixture. The runner creates and removes its own
generated inputs under the system temporary
directory. `uv` installs only pinned public packages in the isolated venv.
The D self-test rejects prefix-collision versions such as `ftfy==6.3.10` and
`wcwidth==0.8.40`, duplicate rows, and missing Linux CPU-model fields. The
run parses exact `uv pip freeze` name/version pairs and reports the observed
versions, not assumed pins. On macOS `cpu_model` comes from
`machdep.cpu.brand_string` and `hardware_model` from `hw.model`; on Linux the
CPU model comes from `model name`, `Hardware`, or `Processor` in
`/proc/cpuinfo`. An unavailable/unreadable source is reported explicitly,
never replaced with the architecture.
The binary build uses the repository's release Dub configuration; the harness
uses the shown LDC flags. Run on an otherwise idle machine and retain all raw
samples; compare only cases with the same input hash and a passing exact-output
gate. BSD `/usr/bin/time -l -p` reports RSS bytes, while GNU `time -v` reports
KiB, converted to bytes in JSON. Both report process peak, not summed memory
across a fleet. Their clocks round to centiseconds; do not interpret apparent
ties for fast cases as precise equality.

The measured comparator configurations were discovered through their installed
CLIs. [ftfy 6.3.1](https://github.com/rspeer/python-ftfy) runs on the same
UTF-8 mojibake file with `--preserve-entities -n none`, which avoids unrelated
HTML-entity and Unicode-normalization behavior on this fixture. Its
`wcwidth==0.8.4` dependency is pinned. No custom non-D transformation script
is included as a comparator. These are task-specific process measurements,
not a ranking of whole tools.

One Apple M4 / macOS 25.6.0 / LDC 1.43.0 sample at source
`9dea1f6272660ebaccbb8965b0fe4cfe3fe7286b` passed every exact-output
gate. Ranges below are the five raw repetitions, not confidence intervals:

| Case | Wall (s) | CPU user+system (s) | Peak RSS (MiB) |
|---|---:|---:|---:|
| 4,096-line mojibake, scrubbed | 2.95–3.16 | 2.93–3.14 | 2.92–2.94 |
| Same mojibake, ftfy 6.3.1 | 0.16–0.16 | 0.14–0.16 | 23.78–23.91 |
| 262,144-record normalization, scrubbed | 0.13–0.13 | 0.12–0.12 | 53.98–54.00 |
| 32-file normalization tree, scrubbed | 0.04–0.04 | 0.03–0.03 | 6.83–6.84 |

The repeated synthetic lines favor neither a realistic document mix nor broad
output-quality coverage; the existing pinned ftfy correctness corpus below is
the separate quality gate. In particular, no single-machine speed claim or
cross-task raw-speed comparison follows from this table. The tree exercises
file discovery, nested output creation, and per-file writes, but ftfy's CLI
does not provide an equivalent recursive tree mode. The present binary has no
HTML extraction filter, so trafilatura is not a quality-matched comparator;
the future full-pipeline comparison belongs to #59. The tree gate also rejects
unexpected output files or directories, not only missing/incorrect files.
No independently sourced executable comparator has been verified for the
combined current line-ending and control-stripping task:
[dos2unix](https://manpages.debian.org/wheezy/dos2unix/dos2unix.1.en.html)
handles newline conversion but not the same control-stripping operation. We
found no separately
verified, executable comparator with the same current quote/entity semantics,
or a second credible mojibake repair CLI beyond ftfy. Specifically,
[mojiblame](https://pypi.org/project/mojiblame/) exposes a Git-aware,
in-place `fix` command rather than a quality-matched file-to-file transform;
[scrubkit](https://pypi.org/project/scrubkit/) has no installed CLI. Those
cases are reported as unsupported rather than assigned misleading speed
numbers.

## Optimized mojibake follow-up

The first A00 table above is historical, not the current repair speed. A
September 2026 sampling profile of the `-O3` repair path showed repeated
runtime UTF-8 decoding of scorer membership literals as the dominant cost.
The scorer now rejects ASCII-only adjacencies and converts its non-ASCII
membership sets to Unicode scalars at compile time. A second profile pass now
returns immediately for ASCII fixed points, computes badness and penalties in
one traversal, classifies each non-ASCII scalar once, and materializes an
already-validated legacy-byte Voldemort range directly instead of decoding and
re-encoding it. The pinned ftfy correctness
gate still passes 39/39 supported repairs and preserves 48/48 encoding-negative
cases; the held-out per-fix gate also passes.

The separate D full-process scale check compares an authored 131,072-line
(5,898,240-byte) mojibake file against ftfy 6.3.1. It checks the exact output
after every run, interleaves three samples per tool, and emits binary/input
hashes and raw timings. Run with the pinned Python environment above:

The report records the observed checkout, host, commands, and binary hashes.
It cannot prove that the supplied scrubbed binary was built from that checkout
or with the shown flags; retain the build log alongside any published result.

```sh
DFLAGS=-O3 dub build --build=release --compiler=ldc2
ldc2 -O3 -release benchmarks/mojibake_scale.d -of=/tmp/scrubbed-mojibake-scale
/tmp/scrubbed-mojibake-scale "$(pwd)/scrubbed" "$bench_env/venv/bin/ftfy"
```

One Apple M4 / macOS 26.6.2 follow-up sample, with exact output in all six
runs, measured scrubbed at 0.152–0.156 s and ftfy at 3.698–4.076 s. The
immediately preceding binary measured 0.346–0.374 s in a separate run on the
same host; that before/after observation is not an interleaved statistical
comparison. This establishes a win
on this repetitive single-file task only; it does not establish speed or
quality parity for varied, mixed-encoding corpora, HTML extraction, or
terabyte-scale pipelines. The small A00 fixture is now near the BSD `time`
tool's centisecond resolution and should not be used for a new speed ratio.

## Full-process pipeline resource evidence

The separate full-process pipeline benchmark now has an opt-in, D-only
capacity-gated larger-corpus mode (about 16 MiB and 128 MiB per layout).
See [the pipeline methodology](../docs/benchmark-pipeline.md) for the exact
quality gates, run command, supported CPU/RSS metrics, and unsupported FD,
GC, syscall-byte, OS-cold, and >RAM claims.

## Lazy mojibake candidates

### Bounded mojibake work attribution

`mojibake_work.d` is the evidence-only follow-up to the canonical attribution
report. It is available only in a `MojibakeWorkProbe` build; ordinary product
builds contain neither its API nor counter branches. The probe also runs the
ordinary implementation and refuses any valid-input result that differs.
Its fixed eight pass buckets are caller-owned, so concurrent probes do not
share counters and a requested ninth pass is rejected instead of allocating an
unbounded profile from an option value.

```sh
ldc2 -O3 -release -d-version=MojibakeWorkProbe \
  -d-version=MojibakeWorkO3Release -Isource \
  benchmarks/mojibake_work.d source/filters/mojibake.d source/pipeline.d \
  -of=/tmp/scrubbed-mojibake-work
/tmp/scrubbed-mojibake-work --self-test
/tmp/scrubbed-mojibake-work
```

The self-test release-actively reconciles call/outcome totals and checks ten
clean, damaged, multilayer, local-island, ambiguous and incomplete cases. It
also checks the exact invalid-UTF-8 exception, fixed pass capacity, and two
concurrent caller-owned runs. The JSON output retains every entered pass and
separate Latin-1/CP1252 counts for legacy-byte mapping, sequence scans,
encodability, candidate decoding, plausibility, grouping and materialization.
It hashes and validates the exact probe and harness sources, hashes every case
input and its option-bearing identity, and records the compiler vendor/frontend
version, exact `ldc2` 1.43.0 version line, and the required O3/release flags and
build mode. A changed probe source, case set, input hash, build identity, or
published count is rejected by the D harness before JSON is emitted.

On the authored focused cases, whole-string one-layer and multilayer repairs
did not call `legacySequenceEnd`; that helper was exercised by the fallback
for unmappable surrounding Unicode. On pass 0, the local-island case made 19
Latin-1 and 20 CP1252 sequence calls, with 38 and 58 corresponding
`legacyByte` calls, and selected local repair; pass 1 stopped at score zero.
On pass 0, the ambiguous-C2 preservation case made 11 sequence calls and 22
legacy-byte calls for each encoding, selected unchanged, and did not alter the
output. These exact counts and outcomes are release-active goldens. They
identify bounded repeated work but do not supply a candidate or an end-to-end
A/B win.
The production threshold is therefore **not met**, optimization remains
unauthorized, and the ordinary mojibake algorithm is unchanged. This is not a
claim about every corpus, SIMD, the pipeline scheduler, or materialization.

`mojibake_ranges.d` compares three implementations using identical scorer
logic and inputs:

1. the exact eager candidate-building path used before the range refactor;
2. that eager path plus the current score-zero early exit, to isolate the
   representation change;
3. the current lazy Voldemort-range implementation.

Build and run it from the repository root:

```sh
ldc2 -O3 -release -enable-inlining -Isource \
  benchmarks/mojibake_ranges.d source/filters/mojibake.d source/pipeline.d \
  -of=/tmp/scrubbed-mojibake-benchmark
/tmp/scrubbed-mojibake-benchmark
```

On an Apple M4 with LDC 1.43.0, two consecutive runs produced these ranges:

| Workload | Old eager | Current lazy | Old allocation | Eager + guard allocation | Lazy allocation |
|---|---:|---:|---:|---:|---:|
| Clean ASCII | 542–655 ns/call | 7.3–7.5 ns/call | 102.4 B/call | 0 B/call | 0 B/call |
| Clean Unicode | 2.93–2.95 µs/call | 204–205 ns/call | 329.6 B/call | 0 B/call | 0 B/call |
| One-layer damage | 2.74–2.76 µs/call | 470–482 ns/call | 300 B/call | 98 B/call | 62 B/call |
| Multilayer damage | 6.75–6.96 µs/call | 4.37–4.38 µs/call | 816 B/call | 616 B/call | 304 B/call |

These are short-input microbenchmarks, not the Phase 5 document-tree throughput
benchmark. The score-zero guard, not the range representation, accounts for
the clean-input drop to zero allocation. The ASCII fixed-point scan explains
the additional clean-ASCII timing drop. Direct validated-range materialization
reduces damaged-input allocation, while single-pass cached classification
reduces scorer time. These tiny inputs are useful regression evidence, not a
document-throughput claim; use the full-process scale check above for that.

## Text comparison: pinned ftfy fixtures

### Held-out per-fix text evidence (T03)

`text_fixes.d` is a separate D-only, authored synthetic corpus and scorer. Its
31 cases are version `issue-22-v1`, MIT-licensed, and pinned by SHA-256
`b95399c0ab5f65785af8d89adda240e7b067564a0fffc34cf86222d3b49048ca`.
The digest covers a length-prefixed serialization of each case's ID, fix,
class, input, expected output, and pair ID, in source order. The JSON report
identifies every case by ID, class, paired negative/positive, and input and
expected byte hashes. Cases are held out from production tuning. The overlap
audit below checks all 31 case inputs against quoted D literals in `source/**`
and `tests/**` and exact JSON string values in the four pinned F01 files;
the corrected corpus has zero matches. The initial review caught `café` in a
mojibake unittest; the repair also replaced two other incidental literal
matches (`A`, `a\nb`). Do not reuse these IDs or bytes for tuning; add new
separately identified held-out cases if a filter changes.

Build and run from the repository root:

```sh
ldc2 -O -release -Isource benchmarks/text_fixes.d \
  source/filters/mojibake.d source/filters/entities.d \
  source/filters/entities_data.d source/filters/punctuation.d \
  source/filters/normalize.d source/pipeline.d \
  -of=/tmp/scrubbed-text-fixes
/tmp/scrubbed-text-fixes --self-test
/tmp/scrubbed-text-fixes
# After fetching and validating the pinned F01 files below:
/tmp/scrubbed-text-fixes --audit-overlap source tests \
  /tmp/python-ftfy/tests/test-cases/negative.json \
  /tmp/python-ftfy/tests/test-cases/synthetic.json \
  /tmp/python-ftfy/tests/test-cases/in-the-wild.json \
  /tmp/python-ftfy/tests/test-cases/language-names.json
```

The self-test checks a recall miss, a false positive, unsupported exclusion,
both zero-denominator `null` values, and hash rejection. The following fault
injections must each exit nonzero: `--inject-miss`,
`--inject-false-positive`, and `--inject-hash-mismatch`. The ordinary run
must exit zero. Each fix's `fix_recall` is exact expected-output matches over
supported expected changes; `clean_false_positive_rate` is changed clean
inputs over supported unchanged cases. Both rates are `null` when their
denominator is zero. A missed positive or edited clean negative fails that
fix's gate. Unsupported and invalid-input cases have separate counts and
never enter either denominator. This benchmark does not parse malformed
fixture declarations as cases: missing fields, broken pairs, duplicate IDs,
or a changed corpus digest invalidate the entire run. `mi` is intentionally
invalid UTF-8 (`FF`), excluded before invoking a filter.

The six `unsupported` inputs are actual out-of-scope phenomena, not prose
labels: `mu` contains U+FFFD, whose lost byte cannot be reconstructed; `eu`
is script markup, where entity decoding needs HTML tokenizer state; `au` is
markup rather than an extracted attribute value; `qu` contains French angle
quotes whose locale-dependent handling is not this filter's contract; `cu`
contains U+200B (format, not Cc); `nu` contains U+2028 (a Unicode line
separator, not CR/LF). These are classification counts only: no unsupported
case is scored as a filter success or failure. The audit is a literal/value
overlap check, not a semantic proof that no independently written test could
exercise a similar transformation.

| Fix/context | Supported task in this corpus | Deliberately unsupported |
|---|---|---|
| `fix-mojibake` | Latin-1/CP1252-looking UTF-8 repair on text | Irrecoverable replacement characters, UTF-16 and other encodings; F01 has broader pinned mojibake evidence below. |
| `decode-entities/text` | One-pass character references in text | HTML tokenizer state, including script and comments. |
| `decode-entities/attribute` | One-pass references in an already-tokenized attribute value | Markup parsing and attribute extraction. |
| `uncurl-quotes` | Straighten the filter's fixed curly-quote set | Locale-aware typography or smart quote insertion. |
| `strip-control` | Remove Cc controls except tab, CR, LF | Unicode format characters and whitespace policy. |
| `normalize-line-endings` | CRLF/CR to LF | Unicode line separators and paragraph semantics. |

This is exact-output evidence for these filter APIs with explicit context,
not a `ftfy.fix_text` parity or speed comparison. The F01 runner below remains
the pinned upstream-reference mojibake gate; its 64 unsupported changed cases
are not silently reclassified here. No third-party fixture bytes are included
in this new corpus.

### Pinned F01 mojibake reference gate

The reference inputs are four files from `tests/test-cases/` in the public
[ftfy repository](https://github.com/rspeer/python-ftfy), commit
`74dd0452b48286a3770013b3a02755313bd5575e`. The upstream project
licenses its test suite under Apache-2.0 (see its `LICENSE.txt` at that
commit); the local notice and license copies are in `THIRD_PARTY_NOTICES.md`
and `third_party/`. The files are fetched for a run, not redistributed here.
Their SHA-256 values are below. File names and hashes are embedded in the D
runner, which rejects changed or mismatched inputs before scoring.

From a clean checkout, run these exact commands from the repository root:

```sh
git clone https://github.com/rspeer/python-ftfy.git /tmp/python-ftfy
git -C /tmp/python-ftfy checkout --detach 74dd0452b48286a3770013b3a02755313bd5575e
ldc2 -O -release -Isource benchmarks/ftfy_corpus.d \
  source/filters/mojibake.d source/pipeline.d \
  -of=/tmp/scrubbed-ftfy-corpus
/tmp/scrubbed-ftfy-corpus \
  /tmp/python-ftfy/tests/test-cases/negative.json \
  /tmp/python-ftfy/tests/test-cases/synthetic.json \
  /tmp/python-ftfy/tests/test-cases/in-the-wild.json \
  /tmp/python-ftfy/tests/test-cases/language-names.json
dub test
```

The runner writes one JSON object to stdout (`schema`:
`scrubbed-text-comparison-v1`) and diagnostics to stderr. Expected summary
fields are `fix_correct: 39`, `fix_eligible: 39`, `fix_recall: 1`,
`clean_unchanged: 48`, `clean_eligible: 48`, `clean_false_positives: 0`,
`clean_false_positive_rate: 0`, `unsupported: 64`, and `gate_passed: true`.
The `fixtures` array gives each input's hash and counts. Exit status is zero
only when identity and the 39/39 and 48/48 gates pass; a changed fixture,
malformed JSON, or a score regression fails. `dub test` should pass. The 64
unsupported positives do not enter fix recall; they are not successes or
failures for the presently supported transformation.

SHA-256 fixture hashes at that revision:

| Fixture | SHA-256 |
|---|---|
| `negative.json` | `ca80c9eab7c67909a9bd33bf88d0caa021c53e26ebc41854dc95a069dfbaccd0` |
| `synthetic.json` | `260cce934da5aeb5564587e26f4ef8fb4f0f9933a58271355748c9fd6e0c4df3` |
| `in-the-wild.json` | `f72996a0e4d50ae01c8057cd5247c03dcb77cc5049c09c2227db9d98a90b7212` |
| `language-names.json` | `011dd44c92877b16b03061c297834688780bccdc195e27796742608c011d6c67` |

### Scope and metric policy

| Reference case | Current text runner | Scoring |
|---|---|---|
| Expected change reachable in at most four Latin-1/UTF-8 or CP1252/UTF-8 round trips | Supported | Exact expected string counts toward fix recall. |
| Expected unchanged text (`original == expected`) | Supported | Any edit is a clean-text false positive. |
| Expected change not reachable by those round trips | Unsupported | Count in `unsupported`; exclude from both supported denominators. |
| Other ftfy behavior (normalization, replacement, other encodings) | Unsupported | No parity claim or score. |
| Saved HTML main content and metadata | Not implemented | Dataset/runner contract below; no score yet. |

For text, fix recall is `fix_correct / fix_eligible` and clean-text
false-positive rate is `clean_false_positives / clean_eligible`. A denominator
of zero is reported as `null` in a future general scorer, not as perfect
quality; this pinned runner requires nonzero fixed totals. A candidate that
leaves a supported damaged input unchanged is a fix miss, not an abstention.
An explicit abstention from a future candidate must stay in the eligible
denominator and count as a miss for a needed fix; for clean text, it counts as
preserved only if the candidate returns the original bytes unchanged. A
malformed fixture or missing required field invalidates the run (nonzero exit,
no comparison result); malformed *candidate input* in a future interface is
recorded in a separate invalid-input bucket, excluded from quality
denominators, with the raw bytes and parse policy pinned before comparison.

### Saved-HTML baseline and future runner contract

No saved-HTML corpus is published by this change. Upstream trafilatura's
public test cache includes third-party page snapshots, whose individual
redistribution rights and ground-truth labels have not been vetted. A later
dataset version must identify each snapshot's origin URL, capture date,
upstream repository commit, upstream and page-content licenses, and SHA-256;
fetch inputs externally when redistribution is not established. It must pin
human-reviewed ground truth independently of either extractor. Do not treat
upstream extractor output as truth or infer rights from its repository license.

The future D runner should reject hash or schema drift and emit versioned JSON
per document: fixture ID, candidate/reference versions, outcome
(`success`, `abstain`, or `invalid`), aligned main-content token counts
(`true_positive`, `false_positive`, `false_negative`), and exact-match outcomes
for each separately named metadata field. Count content precision as
`TP/(TP+FP)` and recall as `TP/(TP+FN)` over the validated corpus, using a
frozen tokenizer and alignment policy. Count metadata accuracy per field as
correct attempts over all eligible labelled documents; missing/abstained
values are incorrect when ground truth exists, and unknown ground truth is
excluded and reported separately. A document-level abstention contributes
all labelled content tokens as false negatives and each labelled metadata
field as incorrect. Malformed saved HTML is reported in a separate invalid
bucket and excluded from quality denominators, with failure rate reported;
zero denominators yield `null`, never 100%. Pin the dataset and policy before
any cross-tool comparison. No HTML extractor or trafilatura parity is claimed.

## SHA-256 backend-only evidence

`sha256_backend_check.d` exercises the private incremental facade introduced
for #185. The migration inventory is fixed at 77 `Sha256`/`sha256Of`
occurrences in the same 21 production modules recorded at base
`cd15948466509055ae0431439f651ecba8a301f6`. The generated backend evidence
records each module's source hash and preserves representative document,
child, and v3 job identity fixtures.

Build and run the release-active checks from the repository root:

```sh
ldc2 -O3 -release -d-version=Sha256BackendO3Release -Isource \
  benchmarks/sha256_backend_check.d source/crypto/sha256.d \
  source/crypto/sha256_arm64.d source/crypto/sha256_x86_64.d \
  -of=/tmp/scrubbed-sha256-backend-check
/tmp/scrubbed-sha256-backend-check --self-test
/tmp/scrubbed-sha256-backend-check --long-test
/tmp/scrubbed-sha256-backend-check --report benchmarks/sha256-backend-evidence.json
/tmp/scrubbed-sha256-backend-check --check-report benchmarks/sha256-backend-evidence.json
/tmp/scrubbed-sha256-backend-check --check-native-report \
  benchmarks/sha256-native-arm64-evidence.json
/tmp/scrubbed-sha256-backend-check --check-native-report \
  benchmarks/sha256-native-x86_64-evidence.json
```

The self-test checks authoritative empty/`abc`/long-message vectors, Phobos
equivalence, every alignment 0..31, boundary and one-byte chunking, repeatable
`start`, refusal after `finish`, forced-unavailable refusal, eight concurrent
instances, the frozen caller inventory, compile-time rejection of external raw
backend imports, and `/usr/bin/shasum` as a separate system oracle. The long
test streams 4,296,015,890 logical bytes through both
the selected facade and Phobos without allocating that logical input.

The native report also records five interleaved scalar/hardware samples for
32, 55, 56, 63, 64, 65, 128, 256, 512, and 1,024-byte one-shot messages. This
is descriptive crossover evidence from hosted runners, not a frequency-
controlled throughput claim; it exists to prevent a large-buffer win from
silently regressing the short identity hashes used by production callers.
Run `35917242376` found no portable short-message cutoff: hosted ARM64 was
70--78% faster with hardware and hosted x86-64 was 46--55% faster across the
entire 32--1,024-byte range even though the harness uses the more conservative
forced selected-backend constructor. Production's automatic constructor skips
that forced-selection validation after process startup. An unreproducible
local Apple M4 follow-up that compared those distinct constructor paths has
been removed rather than retained as quantitative evidence. No size cutoff is
introduced: the production policy remains automatic hardware selection at
every input size.

The ARM compression function alone has LDC `@target("sha2")`; runtime Darwin
`sysctl` or Linux `getauxval` detection happens once before automatic
selection. The x86 function alone has `@target("sha")`; normal x86 builds use
`core.cpuid.hasSha` before selection. Unsupported forced backends fail before
their compression function is called. Scalar is always compiled and
forceable, and digest state belongs to each facade instance.

The evidence binds a sanitized host identity: Darwin release, architecture,
and CPU brand, with no serial number or other private identifier. On the
recorded hosted `Apple M1 (Virtual)` AArch64 host, ARM execution and
disassembly prove
`sha256h`, `sha256h2`, `sha256su0`, and `sha256su1`. The D source also
cross-compiles to x86-64 Mach-O and Linux objects whose disassembly contains
32 `sha256rnds2` instructions. Because this process is AArch64, x86 execution
is `BLOCKED_EXTERNAL_ARCHITECTURE_MISMATCH_CPUID_UNKNOWN`: no x86 CPUID query
was made, and no x86 result was substituted. On native x86-64, the report
instead distinguishes CPUID without SHA-NI from executed-and-passed SHA-NI. A
capable native x86-64 host must run the same KAT/chunk/alignment suite.

The `SHA-256 native backends` GitHub Actions workflow runs the same
release-active harness on GitHub-hosted `ubuntu-24.04` x86-64 and
`ubuntu-24.04-arm` arm64 runners. `--native-report` refuses scalar fallback:
the x86 job must expose and select SHA-NI, while the ARM job must expose and
select ARMv8 SHA2. Each job also runs the multi-GiB logical stream and uploads
a sanitized, source- and binary-bound architecture report, then validates both
that generated report and the corresponding committed artifact for exact
schema, source hashes, benchmark rows, and digests. Caller-only source changes
trigger the workflow; a macOS ARM job also tests and builds the production
package. Workflow actions and LDC 1.43.0 are pinned; the workflow has read-only
repository permission.
Run `35955574514` at source head
`9857764f3185e57a23d4df37caccb4e182152199` generated the committed backend
and native artifacts. Both native generation/self-validation steps and the
hosted backend report step passed; the overall bootstrap run later failed on
the deliberately stale committed-native checks and the comparison-validator
defect corrected in the following candidate. The native artifacts record
`SUPPORTED_AND_PASSED` with automatic selection of `x86-sha-ni` on x86-64 and
`armv8-sha2` on arm64, and identical source hashes across both architectures.
Native x86 execution is therefore no longer an external blocker.

`sha256-backend-evidence.json` contains five interleaved scalar/selected
samples at 64 B, 1 KiB, 8 KiB, and 1 MiB, exact source/tool/binary identities,
and instruction counts. The validator re-derives the host identity and
architecture-conditioned execution statuses. These timings are descriptive:
cache and frequency state are uncontrolled. Its v3 schema deliberately makes
no production-migration decision; the comparison artifact below is the sole
owner of that decision.

The workflow's hosted `production migration comparison` job runs on dedicated
feature-branch pushes and manual dispatch. It builds exact base
`cd15948466509055ae0431439f651ecba8a301f6` and the candidate with the same
pinned compiler, then runs them on one macOS ARM host in alternating order.
`durable_skip_check.d --compare` covers manifest-v2 and journal-v3, forced
reexecution and verified skip, many-small, few-large, and one-file startup
layouts. It records five samples per binary/case plus wall, total CPU, RSS,
Darwin `proc_pidinfo` sampled file-descriptor lower bounds, source-hash time,
output-hash time, exact output identities, caller-expected source revisions,
and binary/harness hashes. Startup wall stops when the child is reaped rather
than after sampler teardown; the zero-tolerance descriptor gate applies only
to the longer non-startup layouts with at least one successful sample.
Private durable phase metrics are enabled for this evidence and remain off by
default in production.

Before timing, each layout and route also proves a real binary upgrade: the
base creates the durable store and output, the candidate opens those exact
paths under explicit retry, and a subsequent candidate replay verified-skips
with no execution or publication. `--self-test-upgrade` runs the same
base-to-candidate contract on the small startup fixture.

The generated `sha256-migration-comparison.json` is one source-bound artifact;
its medians and decision are re-derived by the validator. The gate requires a
material non-startup wall win and source/output-hash win, rejects meaningful
wall/paired-total-CPU/hash-phase/RSS regressions and any measured non-startup
file-descriptor increase. A complete artifact is retained when threshold
validation fails. `--self-test-comparison` proves the decision's missing-win
and regression cases and rejects threshold, observation, source-identity,
fixture-identity, and decision mutations.
Run `35957903665` passed all four workflow jobs at exact source head
`758d894eee744baf386ae0c9a8ab1771fbc84327`; its full comparison report is
retained as `sha256-migration-comparison.json`. The report's re-derived
decision is `PASS`. Across the non-startup medians, many-small wall time fell
24.0--40.0% and few-large wall time fell 31.1--71.1%; source hashing fell
63.4--66.6% and 66.4--67.7%, respectively, while output hashing fell
58.7--70.2% and 77.3--81.9%. Paired total CPU tracked those wall-time wins,
RSS stayed within the configured bound, and sampled file-descriptor peaks
were unchanged or lower. These are same-host, interleaved hosted-run results,
not claims about every machine; cache and frequency state remained
uncontrolled.
