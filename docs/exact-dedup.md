# Exact-byte deduplication overlays

`domain.exact_dedup` defines `exact-bytes:v1`: content bytes are duplicates
only when every byte matches. Its batch API is for bounded in-memory callers.
`effects.exact_dedup_overlay.writeExactDedupOverlays` is the opt-in effects
route that applies this to C01 document shards.

It does not decode text, compute near-duplicate similarity, prune documents,
update a manifest, or register a CLI command.

## Safety

- All destinations must live in one trusted, exclusively controlled output
  directory.
- Before any write, the adapter rejects duplicate destination paths and any
  destination path or existing inode that aliases a source shard. It also
  rejects nonregular, symlink, or hardlinked existing targets.
- The check repeats for the active target immediately before its publication
  and again inside every fault callback; every target is also rechecked once
  after staging (the external sort). Source path/inode and
  destination-uniqueness sets are built once, so path inspections grow
  linearly with shard count, even across repeated publication hooks.
- The underlying C01 writer publishes each overlay with a same-directory
  temporary file and an atomic rename. This is **not** a multi-shard
  transaction: a prepublication failure leaves that target's prior bytes
  unchanged, and re-running with the same shards after a partial publication
  converges to byte-identical overlays.
- Source shards and unrelated overlays are never written. A hostile process
  racing to replace paths inside the trusted directory is outside the C01
  guarantee.

## Overlay format

Each overlay has analyzer key `exact-dedup`, version `exact-bytes:v1`, and
the exact source-shard digest in its header. Every source document gets a
strictly ID-sorted record:

| Field | Value |
| --- | --- |
| `canonical_version` | UTF-8 `exact-bytes:v1` |
| `digest_sha256` | 32 raw SHA-256 bytes of the original content |
| `duplicate` | one byte: 0 for the representative, 1 otherwise |
| `group_cardinality` | ASCII decimal member count |
| `representative_id` | canonical minimum `DocumentId`, UTF-8 |

## Algorithm

- Candidate records are ordered by index hash, then complete content bytes,
  then `DocumentId`, in fixed 32-record sort runs merged eight-way to keep
  file-descriptor and frame memory bounded. A hash collision only affects
  ordering — equality always requires a full byte comparison, never the hash
  alone.
- Equal-byte groups larger than one run are spooled to disk, counted, and
  assigned their minimum ID in one pass, then reread to emit links.
- Two further external sorts follow: one rejects duplicate IDs globally
  (across shards); another orders the surviving links by source shard and
  `DocumentId`. Run paths live in on-disk manifests, not corpus-sized arrays.
- Maximum input frame size follows C01's 1 MiB document payload cap; scratch
  records cap at 2 MiB. Intermediate files are removed after each pass and
  on exit.
- Disk use is proportional to input and output plus bounded merge
  intermediates — not a fixed quota, and not a whole-corpus RAM promise.

## Proof

The release-active checker exercises 300 equal-byte records across three
shards, forced index collisions with distinct bytes, ascending pure-link and
overlay order, shuffled shard/worker layouts, C01 join, restart equivalence,
source and unrelated-overlay immutability, destination/source aliases,
duplicate IDs, and all three prepublication fault points:

```sh
ldc2 -O3 -release -d-version=ExactDedupOverlayCheck -i -I=source \
    experiments/exact_dedup/overlay_check.d \
    -of=.dub/exact-dedup-overlay-check
.dub/exact-dedup-overlay-check
```

## Rollback

Removes the opt-in overlay module and any overlays it produced. No
predecessor format or durable schema is migrated.
