# Code-routing feasibility evaluation

## Decision

**No-go for production adoption.** The narrow rule is technically feasible on
the authored fixtures, but this experiment does not demonstrate retrieval or
selection quality on representative documents. A production change would need
a separate contract, representative rights-cleared evidence, and an explicit
maintenance budget.

The evaluated candidate recognizes exactly one closed, lowercase `d`,
`python`, or `json` Markdown fence when nonempty prose occurs both before and
after it. It records that span as routing metadata; it does not alter the input
or production behavior. The baseline keeps only the generic whole-document
view. Both modes receive the same bytes.

## Evidence

Eight fixtures were authored for this experiment and released under CC0-1.0.
Their immutable SHA-256 digests, expected language and route, syntax
annotation, synthetic license marker, selection token, and fixture rights are
recorded in `experiments/code_routing/fixtures/manifest.tsv`. SPDX-like strings
inside fixtures are test content, not license grants.

The release-active D checker recomputes the fixture hashes and all recorded
measurements. Results are:

- Classification: 3/3 expected mixed prose/code inputs routed; 0/5 negative
  inputs falsely routed.
- Syntax/delimiter integrity: 3/3 routed spans passed their declared narrow
  checks in both modes.
- License markers: 4/4 annotated fixtures retained their exact marker; the
  retention predicate passed for all 8/8 fixtures.
- Outside-span equality: 8/8 inputs remained byte-identical outside the
  candidate span. The candidate also leaves the span itself unchanged.
- Selection proxy: candidate 3/3, baseline 0/3. The proxy merely asks whether
  a code-intent selector can return the already-declared span containing a
  known token. It is not evidence of retrieval quality, ranking quality, or
  user benefit.

The recorded optimized benchmark performs 10,000 passes over the same eight
inputs per mode (80,000 fixture evaluations). Its input digest is
`73916a5bc81b5b327b6e30a340ddbd109eeaf09d425962bfe5c90733798a1643`.
The baseline observation was 5.125451900 seconds and 3,489,792 bytes peak RSS;
the candidate observation was 7.271006600 seconds and 3,538,944 bytes peak
RSS. On this single local run, the candidate was about 42% slower and used
49,152 more peak-RSS bytes (about 1.4%). These are reproducibility observations,
not generalized performance estimates; the candidate path also computes the
experiment's hashes, integrity checks, and metadata.

## Maintenance cost and limits

The rule would create a maintained boundary around fence spelling, language
aliases, nested or multiple fences, prose classification, and syntax-specific
integrity. The current checks are intentionally small heuristics, not language
parsers: braces inside strings or comments and richer Markdown constructs are
outside their claims. The fixture set is tiny and synthetic, contains no
production corpus, and exercises only triple-backtick lowercase language
labels. Negative cases cover inline code, a prose license marker, code-only
input, an unclosed fence, a non-code fence, and multiple fences.

Given those limits, the perfect fixture classification and proxy result do not
justify the additional runtime and maintenance surface. This package adds no
parser dependency, production router, source change, corpus export, or license
grant.

## Reproduction

From the repository root, build and run the optimized release checker:

```console
ldc2 -i -I=experiments/code_routing -O3 -release \
  experiments/code_routing/check.d -of=/tmp/code-routing-check
/tmp/code-routing-check
```

Rebuild the D-only benchmark and run each mode in a separate process:

```console
ldc2 -i -I=experiments/code_routing -O3 -release \
  experiments/code_routing/evaluate.d -of=/tmp/code-routing-evaluate
/tmp/code-routing-evaluate baseline experiments/code_routing 10000
/tmp/code-routing-evaluate candidate experiments/code_routing 10000
```

The benchmark prints a fresh row; runtime and RSS are expected to vary by
machine and load. `experiments/code_routing/benchmark.tsv` preserves the
recorded run checked by this evaluation.
