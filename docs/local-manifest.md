# Local SQLite manifest API (F09 production slice)

`effects.local_manifest.LocalManifest` is a standalone local effects API. It
is **not wired to the CLI**. `scrubbed` does not yet offer restart/resume.
Callers own source-record enumeration, canonical config bytes and versioning,
safe retry decisions, and the sink publication step.

The v1 schema fixes `application_id=0x53435242` and `user_version=1`.
`sink_state` is keyed by `(document_id,input_sha256,config_sha256,sink_key)`
without a rowid. Digests are 32-byte BLOBs. The state/key index supports
bounded keyset replay. Existing foreign, old, or newer databases are refused,
not migrated. The v1 columns are exactly the owner-approved issue #13 schema;
changing them requires a reviewed version amendment. One process should own
the local writer; SQLite WAL serializes database writes but does not coordinate
independent sink publishers. WAL and `synchronous=FULL` are set on every open.
Call `checkpoint()` at an explicit idle boundary; it requests a TRUNCATE
checkpoint and fails if SQLite cannot complete it. `close()` closes the handle.

`DocumentId` is the existing typed source/child ID. The input digest is SHA-256
of exact observed input bytes. The config digest is SHA-256 of ASCII
`scrubbed:manifest-config:v1`, one NUL byte, unsigned 64-bit big-endian length,
then exact caller-supplied canonical config bytes. The caller must say what
configuration those bytes canonically represent. The output digest is SHA-256
of exact published bytes. Diagnostics display `sha256:` followed by lowercase
64-hex; storage remains binary. Presentation filename does not define identity.

Sequence for each sink: `plan(key,destination)`, publish via the existing
`writeAtomicPieces` sink, then `commitPublished(key,destination,digest)`.
`commitPublished` independently reads and hashes the observed destination
before storing committed. `inspect(key)` may return `verifiedCommitted` only
after independently rehashing a present, matching output. Missing, changed, or
unsafe output changes committed to uncertain. A process killed after publish
but before the DB update leaves planned; the caller must reconcile before
`retry(key)`, which is the explicit acknowledgement of replacement/partial-
write risk. Failed and uncertain rows cannot directly become committed. Sink
A never completes sink B. No transaction atomically covers filesystem rename
and SQLite commit.

`replay(state,limit,cursor)` returns up to 1024 rows per call, ordered by the
state/key index. Cursor is an opaque manifest-local token; a cursor for another
database or state is rejected. Replay exposes textual stored IDs because the
public `DocumentId` intentionally has no arbitrary parse constructor. A caller
must resolve its own source record to a typed `DocumentId` before keyed
mutations. The release harness proves a 10,100-row page boundary and bounded
GC growth; it does not claim TB-scale throughput.

The manifest rejects a symlink or non-regular DB, WAL/SHM companion, or output,
and rejects path or inode aliases between these files. Parent components are
resolved for comparisons. This is a local trusted-directory tool, not a
defense against an attacker concurrently replacing a parent path. There is no
network-filesystem or distributed-writer guarantee. The F08 atomic sink fsyncs
the file before rename but does not fsync the parent directory: the SIGKILL
proof is a process-crash proof, **not a power-loss durability guarantee**.

From the repository root run `dub test --compiler=ldc2` and
`dub build --build=release --compiler=ldc2`. Compile the D-only release
harness with:

```sh
ldc2 -O3 -release -d-version=ManifestHarness -Isource \
  source/domain/document.d source/content/pieces.d \
  source/effects/atomic_piece_sink.d source/effects/sqlite_ffi.d \
  source/effects/local_manifest.d experiments/manifest_runtime/check.d \
  third_party/sqlite/sqlite3.o -of=/tmp/scrubbed-manifest-runtime-check
/tmp/scrubbed-manifest-runtime-check
```

On macOS, `otool -L scrubbed` and `otool -L
/tmp/scrubbed-manifest-runtime-check` must not list `libsqlite3`. On Linux use
`ldd`. The checker exercises actual SIGKILL points before/after publish and
after commit, two sinks, config/input revisions, tamper/deletion, lock failure,
foreign/incompatible version, symlink/path hazards and bounded replay.
