# Benchmarks

All project benchmark and corpus-analysis utilities are written in D. The
baseline also measures the external ftfy CLI on its task-equivalent fixture.

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

## Fused scalar-filter microbenchmark

`fused_filters.d` compares the former separately materialized
line-ending/control/quote transforms with the runtime registry's fused scalar
range. It generates 131,072 identical mixed CRLF/control/curly-quote rows
(4,063,232 input bytes), checks every output byte and SHA-256, interleaves the
two implementations, and reports five rounds per sample.

```sh
ldc2 -O3 -release -Isource benchmarks/fused_filters.d \
  source/pipeline.d source/filters/normalize.d source/filters/punctuation.d \
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
