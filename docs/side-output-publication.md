# Terminal side-output publication

`run --sidecar-output PATH` publishes the one bounded terminal side output
declared by a compiled job. The option is generic transport plumbing: it does
not select or configure the producing stage. A producing plan requires the
option, and a plan without a producer rejects it before input is read.

For one local input file, `PATH` is the exact side-output file. For a tree it
is a separate mirrored root; each safe relative primary output name receives
the producer's suffix. Primary and side destinations are checked together for
root overlap, path collision, symlink traversal, and existing hard-link aliases
before either payload is written. Publication is intentionally independent,
not a two-file transaction: both sinks are attempted, either may already be
committed when the peer reports a content-free sink failure, and no rollback or
power-loss atomicity is claimed. `--dry-run` writes neither sink, while
`--validate` performs plan and route checks without reading documents.

Selected-field JSONL still uses stdin/stdout for primary records. Its
`--sidecar-output` must be a distinct file and is replaced atomically rather
than appended. One complete JSON object is staged for each present selected
field in input-record and configured-field order. A side record is staged only
after the corresponding primary JSON record has been fully flushed; a failure
never renders a partial current primary record. Earlier stdout records may
therefore be committed even when the independently published side file fails.
The aggregate spool is bounded by `--max-jsonl-sidecar-bytes` (64 MiB by
default), in addition to the per-record `--max-jsonl-output-bytes` limit.
Overflow is checked before writing the next side record, removes the temporary,
and leaves the prior side destination unchanged.

Manifest-v2 and journal-v3 retain their existing schemas. Each primary payload
and terminal side payload is an ordinary, separate final-event plan under the
same root and config identity. The normalized side destination participates in
that identity. Verified skip rehashes both destinations; retry skips a verified
peer and addresses only unresolved event plans. Existing jobs with no terminal
side output preserve their prior identity, event shape, and behavior.

The release-active proof is:

```sh
ldc2 -O3 -release -preview=dip1000 -i -Isource \
  experiments/side_output_publication/check.d \
  -of=/tmp/scrubbed-side-output-check
/tmp/scrubbed-side-output-check ./scrubbed
```

Passing a release binary built with `FailurePolicyHarness` as the optional
second argument additionally proves manifest-v2 and journal-v3 primary-sink
failure, side commit, restart refusal, and retry of only the unresolved peer.
