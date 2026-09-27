# Terminal side-output publication (`--sidecar-output`)

`run --sidecar-output PATH` publishes the one bounded terminal side output
declared by a compiled job. The option is generic transport plumbing only —
it does not select or configure the producing stage. A plan whose stages
produce a side output requires this option; a plan without a producer
rejects it before input is read.

## Destinations

- **One file**: `PATH` is the exact side-output file.
- **A tree**: `PATH` is a separate mirrored root; each safe relative primary
  output name receives the producer's suffix.

Primary and side destinations are checked together for root overlap, path
collision, symlink traversal, and existing hard-link aliases before either
payload is written.

Publication is intentionally independent, not a two-file transaction: both
sinks are attempted, either may already be committed when the peer reports a
content-free sink failure, and no rollback or power-loss atomicity is
claimed.

- `--dry-run` writes neither sink.
- `--validate` performs plan and route checks without reading documents.

## JSONL mode

Selected-field JSONL still uses stdin/stdout for primary records.
`--sidecar-output` must be a distinct file here and is replaced atomically
rather than appended.

- One complete JSON object is staged per present selected field, in
  input-record and configured-field order.
- A side record is staged only after its primary JSON record has been fully
  flushed — a failure never renders a partial primary record. Earlier
  stdout records can therefore already be committed even when the
  independently published side file fails.
- The aggregate spool is bounded by `--max-jsonl-sidecar-bytes` (64 MiB
  default), on top of the per-record `--max-jsonl-output-bytes` limit.
  Overflow is checked before the next side record is written; it removes
  the temporary file and leaves the prior side destination unchanged.

## Manifests and identity

Manifest-v2 and journal-v3 retain their existing schemas. Each primary
payload and terminal side payload is an ordinary, separate final-event plan
under the same root and config identity; the normalized side destination
participates in that identity.

- Verified-skip rehashes both destinations.
- Retry skips a verified peer and addresses only unresolved event plans.
- Existing jobs with no terminal side output preserve their prior identity,
  event shape, and behavior.

## Testing

Release-active proof:

```sh
ldc2 -O3 -release -preview=dip1000 -i -Isource \
  experiments/side_output_publication/check.d \
  -of=/tmp/scrubbed-side-output-check
/tmp/scrubbed-side-output-check ./scrubbed
```

Passing a release binary built with `FailurePolicyHarness` as the optional
second argument additionally proves manifest-v2 and journal-v3
primary-sink failure, side commit, restart refusal, and retry of only the
unresolved peer.
