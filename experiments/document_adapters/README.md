# Document adapter feasibility experiment

This directory is evidence only. It adds no runtime adapter or dependency.

Generate the deterministic CC0 fixtures and run the release-active evidence
checker from the repository root:

```console
ldc2 -O -release -of=/tmp/document-fixtures experiments/document_adapters/generate_fixtures.d
/tmp/document-fixtures
ldc2 -O -release -of=/tmp/document-adapters-check experiments/document_adapters/check.d
/tmp/document-adapters-check
```

`run_limited.d` is the D-only subprocess boundary used for the recorded probes.
It creates a process group, caps CPU time at five seconds and output size at 16
MiB, applies the requested wall timeout, and kills the process group on expiry.
Peak RSS was captured by putting `/usr/bin/time -l` outside that boundary.

```console
ldc2 -O -release -of=/tmp/document-run-limited experiments/document_adapters/run_limited.d
/usr/bin/time -l /tmp/document-run-limited 5000 ADAPTER ARGUMENTS
```

The tab-separated files are the reviewable evidence surface:

- `samples.tsv` pins fixture hashes, splits, licenses, and provenance.
- `ground_truth.tsv` freezes expected text order and layout semantics before
  held-out execution.
- `adapters.tsv` pins artifact/source hashes, licenses, dependency provenance,
  package size, and unsupported reasons.
- `results.tsv` is the sanitized raw report. Diagnostics are categories rather
  than input paths or engine messages.

Rollback is deletion of this directory and
`docs/document-adapters-evaluation.md`; there is no persisted or user-visible
format state.
