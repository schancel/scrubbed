# Error events and outstanding failures (F13 staged contract)

Stage 2 adds an effects-only v2 SQLite journal and explicit offline v1-to-v2
copy. The release-active `experiments/errors/check.d` pins v1 behavior and
the v2 effects boundary. The shipping CLI still uses v1; it neither creates
nor opens v2, and there is no JSONL exporter yet. The v1 `sink_state` table is
a last-state ledger, **not** immutable historical error events. Do not
interpret this check as proof of the F13 JSONL acceptance criteria.

Run the Stage 2 checker against a release executable built with
`DFLAGS=-d-version=FailurePolicyHarness dub build --build=release
--compiler=ldc2 --force`:

```sh
ldc2 -O3 -release -d-version=FailurePolicyHarness -Isource \
  source/domain/document.d source/content/pieces.d \
  source/effects/atomic_piece_sink.d source/effects/sqlite_ffi.d \
  source/effects/local_manifest.d source/effects/failure_journal.d \
  experiments/errors/check.d \
  third_party/sqlite/sqlite3.o -of=/tmp/scrubbed-errors-check
/tmp/scrubbed-errors-check ./scrubbed
```

## Stage 2 effects boundary

`createV2(newPath)` explicitly creates a fresh v2 database. `copyV1ToV2`
requires an existing, valid v1 database and a separate absent destination;
it checkpoints a quiescent source, stages and validates the new v2 database,
and renames it into view without changing source rows. It rejects existing
targets and companion paths, aliases, foreign/corrupt/version-mismatched v1,
and busy checkpoint state. A copied failed/uncertain row becomes a `legacy-v1`
outstanding baseline with no invented event, run, or timestamp. The full raw
sink key stays private; a distinct random opaque public sink ID is persisted
per raw sink value and reused across reopen.

`FailureJournal` is the exclusive v2 state owner; the v1 `LocalManifest`
rejects its version. Its fixed-code failure append, exact-key outstanding
transition, and sink-state transition share one FULL-synchronous transaction.
`beginPublication(key)` must be acknowledged before the caller writes sink
bytes. The durable `publication_intent` row survives a failed postpublication
commit; on reopen the journal conservatively materializes it as an uncertain
fixed-code event and outstanding key. A successful verified commit removes the
intent in its state/event transaction. Calling `commitPublished` without a
durable intent is refused.
The handle fails closed after a begin/write/commit/read-back acknowledgment
failure. Planned retry keeps outstanding; only verified publication records
retry success and clears that key. Inspect invalidation records uncertainty.
On reopen, inconsistent outstanding, sink-state, event, or identity mappings
produce an explicit repair-needed refusal. This is process-crash evidence at
SQLite's documented FULL-synchronous boundary, not a claim about directory
fsync or power loss during the final staged-file rename.

Stage 3 owns shipping CLI activation and bounded JSONL materialization. There
is no automatic same-path migration, live stream, or S3 journal in Stage 2.

## Durability and migration invariants

The effects boundary uses one authoritative versioned SQLite journal. An event
append and its exact outstanding `SinkKey` transition must commit and
acknowledge together. Failure of begin, write, commit, or acknowledgment must
stop further processing. Retry success removes only its matching outstanding
key; it never erases historical events. On restart, journal outstanding and
manifest failed/uncertain state must reconcile or refuse with an explicit
repair-needed result, never silently skip.

Existing v1 continues to work without F13. Stage 3 must refuse F13 activation
against v1 with an actionable opt-in upgrade requirement. Upgrade is an offline
copy to a **new** v2 DB path after the writer is quiescent and checkpointed:
validate integrity
and version, copy every exact sink-state key and field, compare counts and
fields before making v2 visible, and leave v1 rows untouched. Failed/uncertain v1
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

The raw `SinkKey.sink` is **internal only**: v1 permits arbitrary nonempty,
NUL-free strings, including paths, URLs, and credentials. V2 persists a
private mapping from each distinct raw sink value to a randomly generated,
opaque UUID `sink_id` before that identity is exposed. The mapping is stable
across restart and reused for historical events, outstanding rows, retry,
and v1-copy baselines; it must be created transactionally with the v2 record
that first uses it. It is neither a raw value nor a reversible/plain hash of
one. The full public sink identity for Stage 3 export is
`(document_id,input_sha256,config_sha256,sink_id)`; the full internal key
retains the exact raw sink value for migration, retry, and reconciliation.
Stage 3 must refuse export if a persisted mapping is missing or inconsistent;
never fall back to emitting a raw sink value. This is an implemented effects-layer shape
constraint; Stage 3 has not shipped the wire surface.

The byte-exact history fixture below represents a failure in sink A, a failure
in sink B for the same document, then a successful retry of A. The repeated
hex digits are fixture digests, not hashes of these example strings. The
private sink A may contain an embedded quote, newline, or path canary; none
appears in the public record. The two public sink UUIDs remain stable across
both runs.

```jsonl
{"schema":"scrubbed.error-event.v1","event_id":"ev-1","sequence":1,"run_id":"00000000-0000-4000-8000-000000000001","config_sha256":"1111111111111111111111111111111111111111111111111111111111111111","document_id":"doc:v1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","input_sha256":"2222222222222222222222222222222222222222222222222222222222222222","sink_id":"00000000-0000-4000-8000-0000000000a1","phase":"sink","code":"sink-write-failed","state":"uncertain","retry_of":null,"time_utc_ms":1700000000000}
{"schema":"scrubbed.error-event.v1","event_id":"ev-2","sequence":2,"run_id":"00000000-0000-4000-8000-000000000001","config_sha256":"1111111111111111111111111111111111111111111111111111111111111111","document_id":"doc:v1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","input_sha256":"2222222222222222222222222222222222222222222222222222222222222222","sink_id":"00000000-0000-4000-8000-0000000000b2","phase":"filter","code":"filter-failed","state":"failed","retry_of":null,"time_utc_ms":1700000000001}
{"schema":"scrubbed.error-event.v1","event_id":"ev-3","sequence":3,"run_id":"00000000-0000-4000-8000-000000000002","config_sha256":"1111111111111111111111111111111111111111111111111111111111111111","document_id":"doc:v1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","input_sha256":"2222222222222222222222222222222222222222222222222222222222222222","sink_id":"00000000-0000-4000-8000-0000000000a1","phase":"retry","code":"retry-succeeded","state":"committed","retry_of":"ev-1","time_utc_ms":1700000000002}
```

The matching outstanding export contains B only. It is sorted by full
canonical public `(document_id,input_sha256,config_sha256,sink_id)` bytes,
not by document alone. Sorting by private sink values could reveal their
relative order and is forbidden. It derives from current journal outstanding
rows, not a
last-wins scan of history. The `origin` value is `event` for a v2 failure and
`legacy-v1` for a copied v1 failed/uncertain baseline. Legacy baselines use
literal JSON null for unknown `event_id`, `run_id`, and `time_utc_ms` while
retaining the exact copied sink key internally and publishing its persisted
opaque `sink_id`, state, and digests. They produce no
historical event line. The example B line and a separate legacy fixture are:

```jsonl
{"schema":"scrubbed.outstanding.v1","document_id":"doc:v1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","input_sha256":"2222222222222222222222222222222222222222222222222222222222222222","config_sha256":"1111111111111111111111111111111111111111111111111111111111111111","sink_id":"00000000-0000-4000-8000-0000000000b2","state":"failed","origin":"event","event_id":"ev-2","run_id":"00000000-0000-4000-8000-000000000001","time_utc_ms":1700000000001}
{"schema":"scrubbed.outstanding.v1","document_id":"doc:v1:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","input_sha256":"3333333333333333333333333333333333333333333333333333333333333333","config_sha256":"4444444444444444444444444444444444444444444444444444444444444444","sink_id":"00000000-0000-4000-8000-0000000000c3","state":"uncertain","origin":"legacy-v1","event_id":null,"run_id":null,"time_utc_ms":null}
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
same negative expectation applies when every canary is placed in the raw
`SinkKey.sink` of a migrated v1 row and a newly recorded v2 failure: exports
and stderr contain only their opaque `sink_id`, never the raw key or a
reversible encoding of it. The canaries are test inputs only, never allowed
diagnostic fields. Export must
validate its destination and aliases, bound record/page size and memory, write
a temporary file, fsync it, and atomically replace the destination. It must not claim a
partially written line as committed. Parent-directory fsync is not yet promised,
so process-crash evidence must not be described as power-loss durability.
Executable proof of this golden schema, content digest, encoding/escaping,
redaction canaries, kill/restart, lost-ack faults, and bounded exports belongs
to later slices. Stage 1 deliberately does not test absent exporter behavior.
