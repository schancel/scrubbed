# Independent local sinks (path-aware adapter slice)

`effects.independent_sinks.IndependentLocalSinks` is an opt-in `effects.runner.Sink`.
It accepts emitted stage events and calls a synchronous `PayloadProvider` for
caller-supplied content and metadata `Content` values. Both values are routed
under the event's **same** `Document.id` and checked `Document.outputName`;
the provider cannot substitute a second identity. Rejected and quarantined
events are not published. The existing CLI and single-sink route are unchanged.

The caller supplies two existing local directory roots, one manifest, a source
input digest, separate configuration digests, and a retry decision. The adapter
uses stable keys `local-content:v1` and `local-metadata:v1`. Each output path is
its canonical root plus the same NFC-normalized, slash-delimited relative
`Document.outputName` (for example, `chapter/page.txt`). Flat names still work.
Every path component must be nonempty and neither `.` nor `..`; absolute paths,
backslashes, and NUL are refused. Both output parent chains must already exist
as ordinary, non-symlink directories. Existing destinations must be regular
files with one link. Root aliases, destination aliases, and manifest/output
ownership collisions are rejected before publishing either output. Routes are
rechecked after the caller-supplied payload callback, which may itself change
the filesystem. A later CLI route will create bounded mirrored parents; this
adapter never creates them.
The manifest owns its own path policy; callers must keep it open for the
duration of `accept`.

Before either plan, the adapter asks F09 to scan all persisted sink states for
another owner of either canonical path or existing inode. A different document
or stable sink key reserves that destination even if its row is only planned,
failed, or uncertain. Revisions of the *same* document and stable sink may
reuse it with explicit retry. This read-only check uses F09's single-local-
writer/trusted-directory premise; it is not a multi-writer lock or protection
against hostile concurrent filesystem replacement. The v1 schema and existing
single-sink `plan` behavior are unchanged.

Each sink has its own F09 plan, inspection, and commit. F08 publishes each file
atomically by temporary write, flush, and rename. A failure before publication
is marked failed; a failure after publication but before manifest commit is
marked uncertain. The adapter attempts the other sink after either failure and
then reports the first failure. A verified committed sink is skipped on replay;
an unresolved or pre-existing destination requires explicit `retry=true` to
accept replacement risk. Digest/config values must describe the caller's
actual source and transformations; reusing a digest for changed payloads can
cause a legitimate committed skip.

This is not a two-file transaction, protection from hostile concurrent path
replacement, a power-loss durability claim, metadata extraction, an S3
implementation, or a CLI selector. A later, separately reviewed route will
expose the adapter to the shipping binary.

The release-active D checker covers both failure directions before and after
publication, process-exit/reopen cutpoints, retry, cross-document ownership,
same-document revisions, identity, nested routes, unsafe components, missing
parents, pre-existing and provider-created aliases, and owner lifetime.
After `dub test --compiler=ldc2` builds the project SQLite object, run:

```sh
ldc2 -O3 -release -d-version=IndependentSinksHarness -Isource \
  source/effects/independent_sinks.d source/effects/atomic_piece_sink.d \
  source/effects/local_manifest.d source/effects/sqlite_ffi.d \
  source/effects/runner.d source/stages/contract.d source/content/pieces.d \
  source/domain/document.d experiments/independent_sinks/check.d \
  third_party/sqlite/sqlite3.o -of=/tmp/scrubbed-independent-sinks-check
/tmp/scrubbed-independent-sinks-check
```

`dub test --compiler=ldc2` also retains the existing single-sink goldens.
