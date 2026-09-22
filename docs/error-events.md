# Error events and outstanding failures (F13 staged contract)

Stage 2 adds an effects-only v2 SQLite journal and explicit offline v1-to-v2
copy. The release-active `experiments/errors/check.d` pins v1 behavior and
the v2 effects boundary. Stage 3a adds an opt-in effects-only JSONL exporter,
pinned by `experiments/errors/export_check.d`. Stage 3b1 exposes explicit
v2 management verbs. Stage 3b2 adds an opt-in v2 run/repair route; no-flag
processing still uses v1 by default.
The v1 `sink_state` table is
a last-state ledger, **not** immutable historical error events. Do not
interpret this check as proof of the F13 JSONL acceptance criteria.

## Stage 3b1 explicit management CLI

The shipping executable accepts `errors-init --journal NEW_PATH`,
`errors-copy --from-v1 EXISTING_V1 --journal NEW_V2`,
`errors-export --journal EXISTING_V2 [--errors-jsonl PATH]
[--outstanding-jsonl PATH]`, and `errors-verify [--errors-jsonl PATH]
[--outstanding-jsonl PATH]`. Export and verify require at least one JSONL
path. Both kinds requested in one export share a read snapshot. Init/copy
refuse existing journal paths and companions; copy leaves the v1 source intact.
All four verbs are opt-in: they never process documents, activate v2 for
run/repair, or migrate a path in place. Successful management commands exit 0
without stdout records or diagnostics; syntax and effects refusals exit 2
with fixed tokens that contain no user path, source byte, private sink key, or
freeform exception. Exit 1 remains a document-processing outcome.

Use one trusted, exclusive local directory for each export. Publication is
atomic per file, not across the JSONL/sidecar pair or both kinds. A process
crash may leave a mismatched pair; verify then refuses until an explicit
re-export. No parent-directory fsync or power-loss durability is promised.
The release-active actual-binary proof is `experiments/errors/cli_check.d`.

## Stage 3b2 opt-in live processing

`run` and `repair` accept `--error-journal EXISTING_V2` and optional
`--error-retry`. The journal must already exist from `errors-init` or
`errors-copy`; processing never creates or migrates it. This route is local
file/tree only, excludes `--manifest`, `--manifest-retry`, JSONL stdin/stdout,
and dry-run, and serializes one journal writer. `--validate` checks the
existing v2 journal without creating an output or journal; opening it may
recover a previously unresolved publication intent. A verified committed output is
skipped. An unresolved or pre-existing destination requires an explicit
retry; planned state alone does not grant replacement authority. A retry of
an exact key preserves old event history and clears only that key's
outstanding row after an independently rehashed publication.

The selected-file route uses the same typed document ID, input/config digest,
and stable `local-primary:v1` private sink label as the v1 manifest route.
`--explain` contains only fixed status/phase/code, typed document ID, and
the journal's opaque public sink ID. The opt-in route never prints paths,
source bytes, private labels, or exception text. Exit 0 means every selected
document was verified or published; 1 means only acknowledged document
failures or explicit retry-required decisions; 2 means syntax, preflight,
resource/policy, ledger, or acknowledgment failure. Once a key is planned,
document-level failure records one fixed-code event and exact-key outstanding
state in an acknowledged transaction. A failed acknowledgment stops the run.
Publication intent is acknowledged before sink bytes; on restart, unresolved
intent becomes uncertain and requires explicit retry. This is process-crash
recovery, not a power-loss or JSONL pair atomicity guarantee.

The release-active binary proof is `experiments/errors/live_cli_check.d`.
Compile it with `ldc2 -O3 -release -of=.dub/live-v2-cli-check
experiments/errors/live_cli_check.d` and run `.dub/live-v2-cli-check
./scrubbed`. A separate release-mode executable compiled with
`ManifestCliHarness` and `FailurePolicyHarness` enables deterministic
process-crash and acknowledgment-fault markers; that instrumentation is
absent from the shipping binary. The checker accepts its path plus
`--harness` and verifies restart and fail-stop behavior.

## Stage 3a export boundary

`exportV2(database, historyDestination, outstandingDestination, inputPath)`
accepts one or both export destinations. An empty destination omits that kind.
Each JSONL destination has a fixed `.sha256` sidecar. Both requested kinds are
read under one SQLite read transaction and share a fresh opaque UUIDv4
`snapshot_id`. A standalone kind verifies alone. Sidecar bytes are exactly
one UTF-8/LF line, with keys in this order and no whitespace:

```jsonl
{"schema":"scrubbed.error-export-digest.v1","kind":"history","sha256":"<64 lowercase hex>","bytes":0,"snapshot_id":"<lowercase UUIDv4>"}
```

`kind` is `history` or `outstanding`; `sha256` covers every JSONL byte,
including final LFs, and `bytes` is the decimal byte count. Empty JSONL is
zero bytes and has SHA-256 of the empty string. Angle-bracket fields above
are placeholders, not literal sidecar values. Export caps are 2,000,000 rows,
1 GiB per kind, 4096 bytes per line and 256 bytes per sidecar. Outstanding
also refuses more than 4096 rows sharing one public
`(document_id,input_sha256,config_sha256)` prefix before SQLite's final
`sink_id` sort; the release harness uses a lower test cap to exercise this
path. Reaching a cap refuses export. Destinations and sidecars must be non-aliased regular files or
absent, in an existing resolved parent directory; symlinks and hardlinks are
refused. The caller must serialize writers to this trusted directory.

`verifyV2Export(historyPath, outstandingPath)` opens stable file descriptors,
strictly checks canonical sidecar bytes, kind, byte count and streamed SHA-256,
and, when both are supplied, equal snapshot IDs. A missing or mismatched pair
is rejected. This is an integrity check, not an authenticity signature; an
attacker who can rewrite both files can forge a new digest. Re-export must be
explicit and start from the authoritative v2 database. The exporter stages
and fsyncs each file in its target directory, then renames JSONL before its
sidecar. Rename is atomic per file, not per pair or across kinds. A crash
before JSONL rename leaves the previous pair; a crash after it may leave a
pair that fails verification; a crash between kinds may leave individually
valid but jointly mismatched snapshot IDs. No parent-directory fsync or
power-loss durability is promised. A digest verifies bytes, not physical
generation: if two JSONL publications are byte-identical, the older matching
sidecar can still verify that standalone JSONL file.

V2 limits the stable private `SinkKey.sink` label to 256 UTF-8 bytes (not
characters). Exactly 256 bytes is allowed; 257 is refused without truncation
or changing identity. V1 retains its prior key behavior. Opt-in v1-to-v2 copy
refuses an oversized key before publishing the destination and leaves v1
untouched. Existing v2 databases with oversized keys refuse reopen/export
before shape or integrity scans and before any export publication. The fixed
refusal token is `v2-sink-label-too-long`; no private label is printed.

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

## JSONL v1 wire contract

JSONL is a deterministic, bounded materialization of committed SQLite history,
not a live second durability authority. The following is the Stage 1 target
golden, **not** output of the shipping CLI. The DB schema
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
one, even when the raw sink already looks like a UUID. The effects layer
rejects a persisted public ID equal to **any** raw sink on reopen and read.
It refuses a new raw sink equal to an existing public ID rather than changing
that previously published stable ID. The
full public sink identity for Stage 3 export is
`(document_id,input_sha256,config_sha256,sink_id)`; the full internal key
retains the exact raw sink value for migration, retry, and reconciliation.
Stage 3 must refuse export if a persisted mapping is missing or inconsistent;
never fall back to emitting a raw sink value. This is an implemented effects-layer shape
constraint; Stage 3 has not shipped the wire surface.
Stage 3 must also validate stored public event and run IDs before export;
Stage 2 does not expose those stored fields through a public-record API.

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
legacy row. An export snapshot carries the separately validated `.sha256`
sidecar above.

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
partially written line as committed. Parent-directory fsync is not promised,
so process-crash evidence must not be described as power-loss durability.
Stage 3a pins the event, outstanding, and sidecar bytes at the effects boundary;
Stage 3b owns shipping CLI activation and actual-binary proof.
