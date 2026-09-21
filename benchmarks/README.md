# Benchmarks

All benchmark and corpus-analysis utilities are written in D.

## Lazy mojibake candidates

`mojibake_ranges.d` compares three implementations using identical scorer
logic and inputs:

1. the exact eager candidate-building path used before the range refactor;
2. that eager path plus the current score-zero early exit, to isolate the
   representation change;
3. the current lazy Voldemort-range implementation.

Build and run it from the repository root:

```sh
ldc2 -O -release -enable-inlining -Isource \
  benchmarks/mojibake_ranges.d source/filters/mojibake.d source/pipeline.d \
  -of=/tmp/scrubd-mojibake-benchmark
/tmp/scrubd-mojibake-benchmark
```

On an Apple M4 with LDC 1.43.0, two consecutive runs produced these ranges:

| Workload | Old eager | Current lazy | Old allocation | Eager + guard allocation | Lazy allocation |
|---|---:|---:|---:|---:|---:|
| Clean ASCII | 121–125 µs/call | 119–125 µs/call | 102.4 B/call | 0 B/call | 0 B/call |
| Clean Unicode | 142–147 µs/call | 128–135 µs/call | 329.6 B/call | 0 B/call | 0 B/call |
| One-layer damage | 217–226 µs/call | 210–220 µs/call | 300 B/call | 98 B/call | 60 B/call |
| Multilayer damage | 1.14–1.19 ms/call | 1.14–1.18 ms/call | 816 B/call | 616 B/call | 392 B/call |

These are short-input microbenchmarks, not the Phase 5 document-tree throughput
benchmark. The score-zero guard, not the range representation, accounts for
the clean-input drop to zero allocation. Against that guarded control, lazy
candidates save roughly 36–39% on the damaged workloads shown here. Timing is
close enough on damaged text that it should be treated as tied pending larger
runs.

## ftfy fixture coverage

Clone the exact ftfy revision used for the published counts, then compile the
harness:

```sh
git clone https://github.com/rspeer/python-ftfy.git /tmp/python-ftfy
git -C /tmp/python-ftfy checkout 74dd0452b48286a3770013b3a02755313bd5575e
ldc2 -O -release -Isource benchmarks/ftfy_corpus.d \
  source/filters/mojibake.d source/pipeline.d \
  -of=/tmp/scrubd-ftfy-corpus
/tmp/scrubd-ftfy-corpus \
  /path/to/python-ftfy/tests/test-cases/negative.json \
  /path/to/python-ftfy/tests/test-cases/synthetic.json \
  /path/to/python-ftfy/tests/test-cases/in-the-wild.json \
  /path/to/python-ftfy/tests/test-cases/language-names.json
```

The September 2026 run reported 39/39 passing fixtures reachable using
Latin-1/CP1252 round trips and 48/48 encoding-negative fixtures preserved.
The harness now treats those totals and all mismatches as a failing gate.

SHA-256 fixture hashes at that revision:

| Fixture | SHA-256 |
|---|---|
| `negative.json` | `ca80c9eab7c67909a9bd33bf88d0caa021c53e26ebc41854dc95a069dfbaccd0` |
| `synthetic.json` | `260cce934da5aeb5564587e26f4ef8fb4f0f9933a58271355748c9fd6e0c4df3` |
| `in-the-wild.json` | `f72996a0e4d50ae01c8057cd5247c03dcb77cc5049c09c2227db9d98a90b7212` |
| `language-names.json` | `011dd44c92877b16b03061c297834688780bccdc195e27796742608c011d6c67` |
