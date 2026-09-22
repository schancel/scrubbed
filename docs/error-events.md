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

## Future JSONL v1 wire contract (SPEC ONLY; unexecuted)

JSONL is a deterministic, bounded materialization of committed SQLite history,
not a live second durability authority. The following is the Stage 1 target
golden, **not** output of any current binary or a passing test. The DB schema
version is v2; JSONL history and outstanding records each have their own
`schema` discriminator and wire version 1. One UTF-8 JSON object plus one LF
is one record. No BOM, CRLF, insignificant spaces, or trailing non-record data.
All keys appear in the order below and all listed keys are required. Hex
digests are lowercase, fixed 64-hex strings; typed document IDs retain their
`doc:v1:` or `child:v1:` prefix. Event IDs are unique within the journal,
`sequence` is a monotonically increasing positive integer in commit order,
and `time_utc_ms` is a UTC Unix-millisecond integer. `run_id` is an opaque
run-scoped UUID string. A retry-success event references the prior event ID
for the same exact sink key; if the predecessor is a migrated v1 baseline,
`retry_of` is null because no event was forged.

The byte-exact history fixture below represents a failure in sink A, a failure
in sink B for the same document, then a successful retry of A. The repeated
hex digits are fixture digests, not hashes of these example strings. The
embedded quote and newline in the sink name are escaped as JSON bytes; neither
is an actual line break inside a record.

```jsonl
{"schema":"scrubbed.error-event.v1","event_id":"ev-1","sequence":1,"run_id":"00000000-0000-4000-8000-000000000001","config_sha256":"1111111111111111111111111111111111111111111111111111111111111111","document_id":"doc:v1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","input_sha256":"2222222222222222222222222222222222222222222222222222222222222222","sink_key":"sink\"A\n","phase":"sink","code":"sink-write-failed","state":"uncertain","retry_of":null,"time_utc_ms":1700000000000}
{"schema":"scrubbed.error-event.v1","event_id":"ev-2","sequence":2,"run_id":"00000000-0000-4000-8000-000000000001","config_sha256":"1111111111111111111111111111111111111111111111111111111111111111","document_id":"doc:v1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","input_sha256":"2222222222222222222222222222222222222222222222222222222222222222","sink_key":"sink-B","phase":"filter","code":"filter-failed","state":"failed","retry_of":null,"time_utc_ms":1700000000001}
{"schema":"scrubbed.error-event.v1","event_id":"ev-3","sequence":3,"run_id":"00000000-0000-4000-8000-000000000002","config_sha256":"1111111111111111111111111111111111111111111111111111111111111111","document_id":"doc:v1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","input_sha256":"2222222222222222222222222222222222222222222222222222222222222222","sink_key":"sink\"A\n","phase":"retry","code":"retry-succeeded","state":"committed","retry_of":"ev-1","time_utc_ms":1700000000002}
```

The matching outstanding export contains B only. It is sorted by full
canonical `(document_id,input_sha256,config_sha256,sink_key)` bytes, not by
document alone. It derives from current journal outstanding rows, not a
last-wins scan of history. The `origin` value is `event` for a v2 failure and
`legacy-v1` for a copied v1 failed/uncertain baseline. Legacy baselines use
literal JSON null for unknown `event_id`, `run_id`, and `time_utc_ms` while
retaining the exact copied sink key, state, and digests. They produce no
historical event line. The example B line and a separate legacy fixture are:

```jsonl
{"schema":"scrubbed.outstanding.v1","document_id":"doc:v1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","input_sha256":"2222222222222222222222222222222222222222222222222222222222222222","config_sha256":"1111111111111111111111111111111111111111111111111111111111111111","sink_key":"sink-B","state":"failed","origin":"event","event_id":"ev-2","run_id":"00000000-0000-4000-8000-000000000001","time_utc_ms":1700000000001}
{"schema":"scrubbed.outstanding.v1","document_id":"doc:v1:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","input_sha256":"3333333333333333333333333333333333333333333333333333333333333333","config_sha256":"4444444444444444444444444444444444444444444444444444444444444444","sink_key":"sink-C","state":"uncertain","origin":"legacy-v1","event_id":null,"run_id":null,"time_utc_ms":null}
```

The two outstanding lines illustrate record shape; they are independent
fixtures, not a claim that the earlier three-event history generated the
legacy row. An export snapshot must carry a separately validated content
digest over its exact record bytes (excluding the digest itself); the
successor must freeze its envelope or sidecar representation before it ships.
This Stage 1 document does not claim a digest format already exists.

JSON strings escape quote and backslash with `\"` and `\\`, the five
short-form controls with `\b`, `\f`, `\n`, `\r`, and `\t`,
and all other U+0000–U+001F controls as lowercase `\u00xx`. Slash is not
escaped; valid non-ASCII characters remain UTF-8, and malformed Unicode is
refused rather than replaced. No line may exceed the successor's reviewed
byte cap.

Neither JSONL bytes nor diagnostics may contain raw local paths, credentials,
URLs, source bytes, or freeform exception text. Only reviewed fixed diagnostic
tokens and safe bounded numeric counts may be added. A golden privacy test
must inject a path canary (`/private/f13-canary.txt`), a credential canary
(`F13_SECRET_TOKEN`), a URL canary (`https://invalid.example/f13-canary`),
and source/freeform-message canaries (`F13_SOURCE_BYTES`,
`F13_EXCEPTION_TEXT`); none may occur in exported bytes or stderr. The
canaries are test inputs only, never allowed diagnostic fields. Export must
validate its destination and aliases, bound record/page size and memory, write
a temporary file, fsync it, and atomically replace the destination. It must not claim a
partially written line as committed. Parent-directory fsync is not yet promised,
so process-crash evidence must not be described as power-loss durability.
Executable proof of this golden schema, content digest, encoding/escaping,
redaction canaries, kill/restart, lost-ack faults, and bounded exports belongs
to later slices. Stage 1 deliberately does not test absent exporter behavior.
