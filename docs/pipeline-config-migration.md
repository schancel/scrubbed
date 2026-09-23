# Pipeline configuration migration

Issue #148 replaces two disconnected execution descriptions with one typed job
specification. This document pins predecessor behavior during the compatibility
window. Ordinary and durable local file/tree, selected-field JSONL, extract,
and metadata routing now compile canonical v3 jobs. Supported predecessor
selectors lower at the edge and have no independent execution model.

## Current compatibility boundary

The shipping `run`/`repair` path accepts at most one explicit selector:

- `--filters NAME,NAME,...`, an ordered comma-separated chain with no
  per-filter CLI options; or
- a v1 JSON object containing only `filters`, whose ordered entries are names
  or `{ "name": ..., "options": { ... } }` objects.

Omitting both selectors applies the default ordered chain
`normalize-line-endings,strip-control`.

Filter order is semantic. Options are validated by the selected registered
filter before any input is processed. Unknown root/entry/option keys, unknown
filters, and simultaneous `--config` plus `--filters` are errors. A rejected
configuration must not create or replace a destination.

The compatibility window lowers all three forms into one implicit document
transform stage on the switched route. It does not retain a second execution
model there. Actual-binary migration diagnostics, exact-output equivalence,
and source reachability checks now prove the removal boundary. The predecessor
parser/orchestrator and v2 stage facade are deleted.

## Release-active predecessor check

Build the shipping binary and the D-only checker with optimizations enabled:

```sh
DFLAGS=-O3 dub build --build=release --compiler=ldc2
ldc2 -O3 -release experiments/pipeline_config/legacy_check.d \
  -of=/tmp/scrubbed-pipeline-config-check
/tmp/scrubbed-pipeline-config-check "$(pwd)/scrubbed"
ldc2 -O3 -release experiments/pipeline_config/shipping_check.d \
  -of=/tmp/scrubbed-pipeline-shipping-check
/tmp/scrubbed-pipeline-shipping-check "$(pwd)/scrubbed"
ldc2 -O3 -release -i -Isource \
  experiments/pipeline_config/resource_check.d \
  -of=/tmp/scrubbed-pipeline-resource-check
/tmp/scrubbed-pipeline-resource-check "$(pwd)/scrubbed"
ldc2 -O3 -release experiments/pipeline_config/predecessor_reachability_check.d \
  -of=/tmp/scrubbed-pipeline-reachability-check
/tmp/scrubbed-pipeline-reachability-check source
```

The checker runs the actual binary and pins:

- the no-selector default chain through both `run` and `repair`;
- exact CLI/v1-JSON output for the same five-filter order;
- an order-sensitive entity-decoding/mojibake example;
- numeric `max-passes` and candidate-selecting `encodings` behavior; and
- rejection of malformed JSON, malformed/unknown options, unknown filters,
  root/entry keys, ambiguous selectors, and an explicitly selected empty
  config without destination mutation; and
- global normalized-relative lexical publication plus an identical committed
  prefix when a later root fails with one or several workers.

These remain compatibility constraints, not an endorsement of the v1 shape.
Stage 5a adds actual-binary CLI/JSON and process-resource checks in
`shipping_check.d` and `resource_check.d`. Stage 5b extends the JSONL CLI
checker and adds `jsonl_stream/job_resource_check.d` for exact predecessor /
canonical bytes plus fresh-child wall, CPU, and peak-RSS observations.
Stage 5c switches manifest/journal routes to the same compiled plan and derives
durable identity from canonical v3 bytes rather than selector spelling.
Stage 6 migrates extract and metadata routing, removes predecessor factories
and v2 configuration, and gates source reachability so canonical compilation
is the only internal composition root.
