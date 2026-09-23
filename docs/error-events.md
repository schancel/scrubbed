# Error events and outstanding failures (F13 staged contract)

## Canonical failure journal v3

`errors-init` creates only a fresh `application_id=0x53435242`,
`user_version=3` journal. Canonical `run --error-journal` refuses v2 without
opening it as a writer; retain that file read-only and choose a fresh v3 path.
V3 adds the same root and ordered-final-event workflow tables as manifest v2
while retaining the bounded public `error_event` and `outstanding` projections.
`errors-export` validates and exports either archival v2 or current v3 with the
unchanged public JSON schemas. `errors-copy --from-v1` remains the explicit
offline v1-to-v2 archival copy; its result is exportable but not runnable.

Failures persist bounded phase/code values and opaque public sink IDs. The
private stable sink derives from final kind, final document identity, and event
ordinal; targeted retry uses it internally but never prints it. A root-level
compiled failure keeps job/stage attribution in the live diagnostic and a
bounded persisted code. No journal operation claims filesystem rollback or
power-loss atomicity.

Canonical live processing accepts unchanged v3 or explicit v4 plans. An
incoming v4 root requires every existing row to bind its exact readable job
identity, canonical plan bytes, output route, and executable, so v3-bound or
changed-v4 rows refuse it before recovery or publication. Incoming v3 retains
the historical multi-configuration behavior and may coexist after v4 work. V4
reject/quarantine decisions persist as acknowledged no-output events, while
route/pass use the existing emitted sink kind.

## F14 Stage 1 retry-target visitor

`FailureJournal.visitOutstandingTargets` is an internal, read-only stream of
the current v2 `outstanding` table. It yields the typed DocumentId, exact
input and config SHA-256 digests, and private stable sink label in binary
full-key order. Failed, uncertain, and planned-with-outstanding keys remain
targets; committed and history-only keys do not. Opening the journal may
recover interrupted publication intents before visitation. The visitor
itself does not mutate state, and a throwing synchronous callback stops the
scan. Callbacks cannot reenter or close the same journal; those operations
refuse with the fixed `target-visitor-active` token, and the journal remains
usable after the callback aborts. Stage 2 must finish enumeration before
mutating this handle (or add a separately reviewed snapshot/paging seam).
Internal storage stays bounded, but a caller that retains keys can use
unbounded memory. Raw sink labels and paths must never be copied to a public
CLI or diagnostic. This stage does not select sources or perform retries;
those are later F14 stages. `experiments/retry_targets/check.d` proves exact
selection/order, callback/reentrancy behavior, no mutation after open, malformed and
foreign-v1 refusal, and a 100,000-target fresh-process resource bound. Its
large fixture uses near-maximum 254/255-byte private labels; a separate
fresh child that deliberately retains every returned key must exceed the
same 32 MiB cap that the streaming child passes, as well as exceed the
streaming child's observed RSS by at least 2 MiB. The checker samples
descriptors during callbacks and requires baseline descriptor count after
close.
Matching persisted rows with embedded NUL in either the document ID or sink
label refuse before any callback, rather than shortening an identity. A
32-byte SQLite TEXT value in either digest column also refuses; target
digests must be exact 32-byte BLOB values, not coercible text.
Build it with `ldc2 -i -O3 -release -Isource
experiments/retry_targets/check.d third_party/sqlite/sqlite3.o
-of=.dub/retry-targets-check`, then run `.dub/retry-targets-check`.

## Current local targeted retry (journal v3)

`run` and `repair` accept `--error-targeted` only alongside an existing v3
`--error-journal` and explicit `--error-retry`. This opt-in local file/tree
route selects only documents with a current outstanding `local-primary:v1`
sink before file-size admission, content reads, or output preflight. It does
not materialize the target corpus. After hashing a selected input it requires
the exact outstanding document/input/config/sink key; changed input or config
reports a fixed `target-mismatch` and leaves the prior key and output alone.
Matching targets reuse the v3 durable plan, publication-intent, rehash and
commit path; a repeat skips cleared targets without rewriting outputs. Other sinks,
roots, and missing sources may still have outstanding rows: success is not a
claim that the journal is globally empty. Use `errors-export` and
`errors-verify` for inspection. The route does not handle multi-sink
publication, non-seekable sources or S3. Journals are created explicitly with
`errors-init`; v2 journals are export-only compatibility inputs and are
refused for live processing.

`experiments/retry_targets/live_cli_check.d` drives the shipping executable
through exact mismatch, multi-target, unrelated-sink preservation,
pre-admission over-cap skip, idempotence, privacy and path checks. Its macOS
resource fixture retries 384 256-KiB targets (96 MiB total) under a
one-document/one-open-input cap, samples child RSS/FDs, and requires a D
retain-all control to exceed the 64 MiB RSS limit. A separate release-mode
`ManifestCliHarness` executable covers a deterministic crash after sink
publication; that marker code is absent from the shipping binary.

Historical predecessor note: Stage 2 added an effects-only v2 SQLite journal
and explicit offline v1-to-v2 copy. The release-active
`experiments/errors/check.d` pins v1 behavior and
the v2 effects boundary. Stage 3a adds an opt-in effects-only JSONL exporter,
pinned by `experiments/errors/export_check.d`. Stage 3b1 exposes explicit
v2 management verbs. Stage 3b2 adds an opt-in v2 run/repair route; no-flag
processing still uses v1 by default.
The v1 `sink_state` table is
a last-state ledger, **not** immutable historical error events. Do not
interpret this check as proof of the F13 JSONL acceptance criteria.

## Stage 3b1 explicit management CLI

The shipping executable accepts `errors-init --journal NEW_V3`,
`errors-copy --from-v1 EXISTING_V1 --journal NEW_V2`,
`errors-export --journal EXISTING_V2_OR_V3 [--errors-jsonl PATH]
[--outstanding-jsonl PATH]`, and `errors-verify [--errors-jsonl PATH]
[--outstanding-jsonl PATH]`. Export and verify require at least one JSONL
path. Both kinds requested in one export share a read snapshot. Init/copy
refuse existing journal paths and companions; copy leaves the v1 source intact.
All four verbs are opt-in: they never process documents, activate a v2 copy for
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

`run` and `repair` accept `--error-journal EXISTING_V3` and optional
`--error-retry`. The v3 journal must already exist from `errors-init`;
processing never creates or migrates it. V2 copies remain export-only. This
route is local file/tree only, excludes `--manifest`, `--manifest-retry`, JSONL stdin/stdout,
and dry-run, and serializes one journal writer. `--validate` checks the
existing v3 journal without creating an output or journal; opening it may
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

With explicit v4, dispatch explain/error records retain bounded outcome,
action, detector/extractor versions, warning codes, provenance, and accounting.
They omit paths, untrusted hints, source/extracted bytes, archive entry names,
private sink keys, and exception strings. Diagnostic stderr may repeat after
restart; durable event state remains the authority. Targeted retry requires the
same v4 plan/executable binding as the outstanding key.

The release-active binary proof is `experiments/errors/live_cli_check.d`.
Compile it with `ldc2 -O3 -release -of=.dub/live-v3-cli-check
experiments/errors/live_cli_check.d` and run `.dub/live-v3-cli-check
./scrubbed`. A separate release-mode executable compiled with
`ManifestCliHarness` and `FailurePolicyHarness` enables deterministic
process-crash and acknowledgment-fault markers; that instrumentation is
absent from the shipping binary. The checker accepts its path plus
`--harness` and verifies restart and fail-stop behavior.
On macOS, the shipping-binary checker additionally streams 384 256-KiB files
(96 MiB total) through a one-document/one-descriptor scheduler cap and samples
the child with `proc_pid_rusage` and `proc_pidinfo` until exit. It requires at
least five live samples, no more than 64 MiB observed resident memory, and no
more than 64 observed file descriptors. A D negative control retains all
96 MiB of input buffers and must measurably exceed the child RSS cap. These
are regression bounds, not promises about every host or unsampled peaks.

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
