# Dispatch job specification v4

Version 4 is an explicit opt-in dispatch root. It has exactly three top-level
members: `version`, `dispatch`, and `common`. The canonical example is
[`scrubbed.dispatch.example.json`](../scrubbed.dispatch.example.json).

`dispatch.detector` and `dispatch.container` contain all bounded detection and
ZIP-inspection limits. `routes` names a finite extractor and supplies its typed
options. `actions` contains exactly one entry for every outcome. Every route
must be used, and every action must explicitly be `route`, `pass`, `reject`, or
`quarantine`; there are no defaults. `common` is a complete nested v3 job.

The shipping executable registers only `core-plain-text/v1`. It accepts the
`plain-text` outcome and requires integer `max-output-bytes` in
`1..268435456`. It validates UTF-8 while retaining streamed owned pieces.

The equivalent token form uses ordered `--dispatch-option`, `--route`,
`--route-option`, and `--action` pairs, followed by the flag `--common` and any
nested v3 stage tokens. Dispatch tokens are exclusive with `--config` and
`--filters`. JSON and tokens canonicalize to the same `job:v4:` identity.

For each input, one action is selected. A route publishes one transformed root
after the common v3 plan runs once. Pass publishes the original bytes once and
skips extraction/common processing. Reject and quarantine publish no output.
Failures publish no partial output.

With `--explain`, v4 emits `EXPLAIN\t` followed by one canonical
`scrubbed.dispatch.v1` JSON record. Records contain bounded outcome,
provenance, accounting, and stable error vocabulary; they never include source
or extracted bytes, archive entry names, paths, hints, or exception text.
JSONL explain records use stderr so stdout remains whole-record JSONL.

Durable v4 execution uses the existing manifest/journal schema and final-event
protocol. An existing bound store accepts only the identical v4 canonical plan
and executable. V3-bound stores refuse v4 before recovery or publication.
Pass uses the existing emitted sink kind while its live explain record retains
the pass action. Diagnostic stderr may repeat after a restart. Before
downgrading, stop new v4 submissions and drain v4 durable work with the v4
binary; v3 stores require no migration.
