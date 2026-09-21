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
  -of=/tmp/scrubbed-mojibake-benchmark
/tmp/scrubbed-mojibake-benchmark
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

## Text comparison: pinned ftfy fixtures

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
