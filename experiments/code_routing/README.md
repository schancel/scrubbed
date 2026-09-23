# Code-routing feasibility experiment

This directory is isolated evidence only. It adds no production router or
parser dependency. All fixtures were authored for this evaluation and released
under CC0-1.0; strings resembling SPDX identifiers inside fixtures are test
content, not license grants.

The candidate rule routes exactly one closed `d`, `python`, or `json` fenced
span only when nonempty prose occurs before and after it. Baseline handling
retains the generic whole document. Candidate handling records a code span but
also leaves every input byte unchanged.

Build and run the release-active checker from the repository root:

```console
ldc2 -i -I=experiments/code_routing -O3 -release \
  experiments/code_routing/check.d -of=/tmp/code-routing-check
/tmp/code-routing-check
```

Reproduce the two benchmark rows in separate processes:

```console
ldc2 -i -I=experiments/code_routing -O3 -release \
  experiments/code_routing/evaluate.d -of=/tmp/code-routing-evaluate
/tmp/code-routing-evaluate baseline experiments/code_routing 10000
/tmp/code-routing-evaluate candidate experiments/code_routing 10000
```

The proxy asks whether a code-intent selector can return the authored span
containing the declared identifier. It is not a retrieval-quality, ranking, or
production-benefit claim. Runtime and peak RSS are single local observations.
