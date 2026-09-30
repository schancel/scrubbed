# Independent local sinks (path-aware adapter slice)

`effects.independent_sinks.IndependentLocalSinks` is an opt-in
`effects.runner.Sink`. It accepts emitted stage events and calls a
synchronous `PayloadProvider` for caller-supplied content and metadata
`Content` values. Both values are routed under the event's **same**
`Document.id` and checked `Document.outputName`; the provider cannot
substitute a second identity. Rejected and quarantined events are not
published. The existing CLI and single-sink route are unchanged.

## Shipped via `scrubbed route-metadata`

The adapter is exposed to the shipping binary through the `route-metadata`
CLI command (`effects.metadata_route_cli.runMetadataRoute`): an opt-in,
local-only route that content-filters and metadata-annotates a tree of
`.html`/`.htm` files and publishes each pair through this adapter. That
route owns file discovery, path safety, and job compilation; the adapter
itself remains a plain `Sink` and is not a CLI selector, a two-file
transaction, protection from hostile concurrent path replacement, a
power-loss durability claim, metadata extraction, or an S3 implementation.

## Inputs and path policy

The caller supplies two existing local directory roots, one manifest, a
source input digest, separate configuration digests, and a retry decision.
The adapter uses stable keys `local-content:v1` and `local-metadata:v1`.

- Each output path is its canonical root plus the same NFC-normalized,
  slash-delimited relative `Document.outputName` (for example,
  `chapter/page.txt`). Flat names still work.
- Every path component must be nonempty and neither `.` nor `..`; absolute
  paths, backslashes, and NUL are refused.
- Both output parent chains must already exist as ordinary, non-symlink
  directories. The caller-supplied root paths themselves must also be
  ordinary, non-symlink directories; the adapter then canonicalizes each root
  via `realpath` internally (issue #467), so a caller does not need to
  pre-resolve an ancestor symlink it doesn't control (for example, macOS's
  `/tmp` -> `/private/tmp`) before calling in — the same false-refusal class
  issue #458 fixed in `route-metadata`'s own preflight.
- Existing destinations must be regular files with one link.
- Root aliases, destination aliases, and manifest/output ownership
  collisions are rejected before publishing either output.
- Routes are rechecked after the caller-supplied payload callback, which
  may itself change the filesystem — a provider is arbitrary caller code.
- A later CLI route will create bounded mirrored parents; this adapter
  never creates them.

The manifest owns its own path policy; callers must keep it open for the
duration of `accept`.

## Ownership check (F09)

Before either plan, the adapter asks F09 (`effects.local_manifest`) to scan
all persisted sink states for another owner of either canonical path or
existing inode. A different document or stable sink key reserves that
destination even if its row is only planned, failed, or uncertain. Revisions
of the *same* document and stable sink may reuse it with explicit retry.

This read-only check uses F09's single-local-writer/trusted-directory
premise; it is **not** a multi-writer lock or protection against hostile
concurrent filesystem replacement. The v1 schema and existing single-sink
`plan` behavior are unchanged.

## Publication and failure handling

Each sink has its own F09 plan, inspection, and commit. F08
(`effects.atomic_piece_sink`) publishes each file atomically by temporary
write, flush, and rename.

- A failure before publication is marked `failed`; a failure after
  publication but before manifest commit is marked `uncertain`.
- The adapter attempts the other sink after either failure, then reports
  the first failure.
- A verified committed sink is skipped on replay; an unresolved or
  pre-existing destination requires explicit `retry=true` to accept
  replacement risk.
- Digest/config values must describe the caller's actual source and
  transformations; reusing a digest for changed payloads can cause a
  legitimate committed skip.

## Harness

The release-active D checker covers both failure directions before and
after publication, process-exit/reopen cutpoints, retry, cross-document
ownership, same-document revisions, identity, nested routes, unsafe
components, missing parents, pre-existing and provider-created aliases, and
owner lifetime.

After `dub test --compiler=ldc2` builds the project SQLite object, run:

```sh
ldc2 -i -O3 -release -preview=dip1000 -d-version=IndependentSinksHarness -Isource \
  source/effects/independent_sinks.d source/effects/atomic_piece_sink.d \
  source/effects/local_manifest.d source/effects/sqlite_ffi.d \
  source/effects/runner.d source/stages/contract.d source/content/pieces.d \
  source/domain/document.d experiments/independent_sinks/check.d \
  third_party/sqlite/sqlite3.o -of=/tmp/scrubbed-independent-sinks-check
/tmp/scrubbed-independent-sinks-check
```

`dub test --compiler=ldc2` also retains the existing single-sink goldens.
