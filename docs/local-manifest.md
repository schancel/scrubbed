# Local SQLite manifest API (F09 production slice)

## Canonical durable route (Stage 5c)

Shipping `--manifest` now creates only `application_id=0x53435242`,
`user_version=2` state through `effects.durable_job`. One root row is keyed by
`(DocumentId,input_sha256,config_sha256)`; the config digest binds canonical v3
job JSON, readable `job:v3:` identity, file/tree mode, canonical output route,
`compiled-final-events:v1`, and the exact executable digest. The complete
ordered final-event set is recorded transactionally before publication.
Emitted events own stable sinks, destinations, and expected output digests;
reject/quarantine events are acknowledged no-output terminals. The root becomes
complete only after every event is committed or acknowledged.

Publication remains per destination, not a multi-file transaction. A durable
intent recovered after a crash becomes uncertain; default restart refuses
replacement, while explicit `--manifest-retry` rehashes and skips committed
siblings, retries only unresolved events, then continues later planned events
in order. Existing v1 manifests are refused without mutation and require a
fresh v2 path. The remainder of this document describes the retained v1 API
used by offline migration and predecessor consumers; it is not the canonical
shipping writer.

`effects.local_manifest.LocalManifest` is the v1 local effects API. The
`run`/`repair`/no-verb CLI offers an opt-in local-file/tree restart path with
`--manifest PATH`. Without that flag, existing file/tree and JSONL behavior is
unchanged. JSONL stdin/stdout cannot use a local manifest.

The CLI uses `local-files:v1`, the canonical selected input root as source key,
and a normalized root-relative record path (`.` for one file) for typed
`DocumentId`. Moving the root intentionally creates a new identity. The one
output sink is `local-primary:v1`; this does not imply multi-sink completion.
The input digest is from the same admitted mapping used by the filter chain,
hashed before transformation and again before publication. A changed size or
SHA-256 fails. Concurrent in-place writers are not a snapshot guarantee.

The CLI's versioned canonical config bytes include the exact selected filter
string or config-file bytes used to build the chain, file/tree output policy,
canonical output route, and a bounded stream SHA-256 of the running executable
path. `--manifest-retry` is deliberately excluded. The executable path is
checked for inode and size changes around hashing. On macOS, `thisExePath()`
resolves a filesystem path rather than a stable mapped-image handle: concurrent
replacement of the executable is outside this guarantee, including replacement
before the path is opened. Keep the executable path stable for a run; rebuilt
executables may safely invalidate old work. No cross-machine equivalence is
claimed.

An exact committed row skips only after the CLI checks the canonical stored
destination against its selected output and the API rehashes that output.
Unresolved failed/uncertain rows or any pre-existing destination fail by
default. A planned row with no destination can resume. After inspecting a
destination, `--manifest-retry` explicitly authorizes replacement; it is not
part of output identity. `--validate` checks paths/config without creating a
DB, and `--dry-run` runs filters but creates neither DB nor output. `--explain`
reports one status per input: `skipped` for verified committed output,
`uncertain` for invalidated committed output, `retry-required` for other
unresolved/pre-existing destinations, and `retry` with a separate
changed/unchanged detail after authorized replacement. Refused inputs retain
a nonzero incomplete exit. Manifest DB, `-wal`, and
`-shm` must lie outside the selected input and output trees; aliases and
hardlinks are rejected. The first CLI slice serializes manifest work even when
`--threads` is larger, while preserving bounded input admission. It makes no
general throughput claim. The existing string pipeline materializes output;
adapting it to F08's `ContentPiece.own` adds a temporary whole-output copy,
so the CLI does not claim bounded output memory. The F08 sink publishes before
the DB commit. A crash in between may require explicit retry; it never grants
a false committed skip.

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
before storing committed. `inspect(key, intendedDestination)` may return
`verifiedCommitted` only after the canonical route matches and a present output
rehashes correctly. Missing output or changed bytes makes the committed row
uncertain and requires retry. An unsafe stored destination/path alias or output
rehash syscall failure (including EACCES, EIO, or resource exhaustion) is keyed
run-fatal (exit 2), not an uncertain retry. A process killed after publish but
before the DB update leaves planned; the caller must reconcile before
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

The opt-in CLI release harness runs against the built executable (not a mock
CLI) and covers validate/dry-run non-mutation, committed skip, changed
input/config/executable/output routes, tamper/reconcile, two independent tree
files, path/alias/resource gates and a live SIGKILL after observing a durable
`planned` row. Run it with:

```sh
ldc2 -O3 -release -Isource experiments/manifest_cli/check.d \
  source/domain/document.d source/content/pieces.d \
  source/effects/atomic_piece_sink.d source/effects/sqlite_ffi.d \
  source/effects/local_manifest.d third_party/sqlite/sqlite3.o \
  -of=/tmp/scrubbed-manifest-cli-check
ldc2 -i -O3 -release -d-version=ManifestCliHarness -Isource \
  -I"$ARGPARSE_SOURCE" \
  source/app.d third_party/sqlite/sqlite3.o \
  .dub/lexbor/liblexbor_static.a .dub/zstd/libzstd_decompress.a \
  -of=/tmp/scrubbed-manifest-cli-hook
/tmp/scrubbed-manifest-cli-check ./scrubbed /tmp/scrubbed-manifest-cli-hook
```

Set `ARGPARSE_SOURCE` to the local argparse 2.0.2 source path reported by
`dub describe --data=import-paths` first. `ManifestCliHarness` compiles marker-file
SIGKILL checkpoints only into the second, separate release-mode D executable;
the shipping `dub build` binary has no kill-marker behavior. The actual
shipping binary is exercised by the live post-plan SIGKILL test; the separate
release harness deterministically covers after-plan, before-publish,
after-publish/before-DB-commit, and after-commit windows. It also drives a
three-child compiled split through argparse and durable execution, proves the
complete event set precedes publication, recovers committed/uncertain/planned
siblings without rewriting the committed inode, proves root completion occurs
after all three final events and restart rewrites none of them, and checks reject/quarantine
as replay-stable no-output terminals in manifest v2 and journal v3. Neither
proof is a power-loss guarantee.
