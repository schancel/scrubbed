# Dispatch job specification v4

Version 4 is an explicit opt-in dispatch root. It has exactly three top-level
members: `version`, `dispatch`, and `common`. The canonical example is
[`scrubbed.dispatch.example.json`](../scrubbed.dispatch.example.json).

`dispatch.detector` and `dispatch.container` contain all bounded detection and
ZIP-inspection limits. `routes` names a finite extractor and supplies its typed
options. `actions` contains exactly one entry for every outcome. Every route
must be used, and every action must explicitly be `route`, `pass`, `reject`, or
`quarantine`; there are no defaults. `common` is a complete nested v3 job.
Byte signatures and bounded content/container evidence are authoritative;
filename extensions and declared media hints are untrusted evidence and never
select a type alone. The fixed outcomes are `unknown`, `plain-text`, `html`,
`pdf`, `png`, `jpeg`, `gif`, `ambiguous`, `malformed`, `encrypted`,
`unsupported`, `generic-zip`, and `ooxml-word`.

The shipping executable registers only `core-plain-text/v1`. It accepts the
`plain-text` outcome and requires integer `max-output-bytes` in
`1..268435456`. It validates UTF-8 while retaining streamed owned pieces.
The checked-in example uses a 4,096-byte detector prefix, at most 16 evidence
records and 8 warnings, and ZIP limits of 32 MiB physical, 128 MiB expanded,
2,048 entries, depth 2, and ratio 100. These are explicit configuration, not
implicit defaults or a promise that a specialist archive extractor ships.

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
Each record represents one dispatched unit. Its fixed-size `unit_id` hashes
the document identity plus a domain token. JSONL tokens use the field's
zero-based position in the configured `--jsonl-fields` order, never its name,
so fields on the same physical line remain distinct without enabling a field
name dictionary attack. Reordering the configured selection rebinds unit IDs
to the new ordinals. Only present selected fields are dispatched and receive
records; absent fields do not. Local and durable single-document routes use
the same root-domain token, while whole-record JSONL failures use a separate
record-domain token.
JSONL explain records use stderr so stdout remains whole-record JSONL.

Ordinary local file/tree runs, selected-field JSONL, manifest v2, and
failure-journal v3 all execute the same compiled v4 plan. Local and durable
file routes write explain records to stdout; JSONL uses stderr. Detection,
refinement, extraction-factory, extraction, and common-plan
failures map to bounded inspect/decode/filter phases and stable codes. Records
may include bounded detector, container, extractor, and source-to-text
provenance plus byte accounting, but not raw evidence bytes or free-form
failure strings.

Durable v4 execution uses the existing manifest/journal schema and final-event
protocol. An existing bound store accepts only the identical v4 canonical plan
and executable. V3-bound stores refuse v4 before recovery or publication.
Pass uses the existing emitted sink kind while its live explain record retains
the pass action. Diagnostic stderr may repeat after a restart. Before
downgrading, stop new v4 submissions and drain v4 durable work with the v4
binary; v3 stores require no migration.

The D-only [shipping evidence harness](../experiments/dispatch_shipping/README.md)
compares v3 direct common transforms with v4 `core-plain-text` followed by the
same common transforms on deterministic 4,096 x 8 KiB and 8 x 4 MiB layouts.
It verifies exact tree and concatenated hashes, records three interleaved
O3/release observations and resource/accounting data, and checks retained
mapped-input ownership. It sets no speed threshold and makes no optimization
claim.
