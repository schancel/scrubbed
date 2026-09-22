# Error events and outstanding failures (F13 staged contract)

Stage 1 adds no error-event journal or JSONL output. The release-active
`experiments/errors/check.d` pins existing v1 behavior only: exact per-sink
failed/uncertain state, explicit retry, fail-stop on lost acknowledgment, and
refusal of an incompatible manifest version. The current v1 `sink_state` table
is a last-state ledger, **not** immutable historical error events. Do not
interpret a successful Stage 1 check as proof of the F13 JSONL acceptance
criteria.

Run the Stage 1 checker against a release executable built with
`DFLAGS=-d-version=FailurePolicyHarness dub build --build=release
--compiler=ldc2 --force`:

```sh
ldc2 -O3 -release -Isource \
  source/domain/document.d source/content/pieces.d \
  source/effects/atomic_piece_sink.d source/effects/sqlite_ffi.d \
  source/effects/local_manifest.d experiments/errors/check.d \
  third_party/sqlite/sqlite3.o -of=/tmp/scrubbed-errors-check
/tmp/scrubbed-errors-check ./scrubbed
```

## Required v2 durability and migration invariants (not implemented yet)

The successor must use one authoritative versioned SQLite journal. An event
append and its exact outstanding `SinkKey` transition must commit and
acknowledge together. Failure of begin, write, commit, or acknowledgment must
stop further processing. Retry success removes only its matching outstanding
key; it never erases historical events. On restart, journal outstanding and
manifest failed/uncertain state must reconcile or refuse with an explicit
repair-needed result, never silently skip.

Existing v1 continues to work without F13. F13 against v1 must refuse with an
actionable opt-in upgrade requirement. Upgrade is an offline copy to a **new**
v2 DB path after the writer is quiescent and checkpointed: validate integrity
and version, copy every exact sink-state key and field, compare counts and
fields before making v2 visible, and leave v1 untouched. Failed/uncertain v1
rows become outstanding `legacy-v1` baselines with unknown run/event identity;
do not fabricate historical events. A later successful retry clears only its
matching baseline atomically. Historical event export starts when v2 begins
accepting events. No automatic same-path migration or silent downgrade.

## Required JSONL contract (not implemented yet)

JSONL is a deterministic, bounded materialization of committed SQLite history,
not a live second durability authority. Its reviewed schema must fix UTF-8
key order, escaping, LF line endings, version, event ID/sequence, run ID,
canonical config digest, typed document ID, full sink key, phase, stable
machine code, terminal state, retry link, and timestamp semantics. The
outstanding export is distinct, sorted by full canonical `SinkKey`, and
derived from current outstanding rows; a document ID alone cannot deduplicate
sinks. Missing legacy identity must be explicit rather than invented.

Neither JSONL bytes nor diagnostics may contain raw local paths, credentials,
URLs, source bytes, or freeform exception text. Only reviewed fixed diagnostic
tokens and safe bounded numeric counts may be added. Export must validate its
destination and aliases, bound record/page size and memory, write a temporary
file, fsync it, and atomically replace the destination. It must not claim a
partially written line as committed. Parent-directory fsync is not yet promised,
so process-crash evidence must not be described as power-loss durability.
Schema version, content digest, golden encoding/escaping, redaction canaries,
kill/restart, lost-ack faults, and bounded export proofs belong to later slices.
