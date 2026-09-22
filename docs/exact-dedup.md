# Exact-byte deduplication overlays

`domain.exact_dedup` defines `exact-bytes:v1`: opaque content bytes are equal
only when every byte matches. Its batch API is for bounded in-memory callers.
`effects.exact_dedup_overlay.writeExactDedupOverlays` is the opt-in effects
route for C01 document shards. It does not decode text, compute near-duplicate
similarity, prune documents, update a manifest, or register a CLI command.

The caller supplies each source shard and its dedup-overlay destination. All
destinations must be in one trusted, exclusively controlled output directory.
Before any write, the adapter rejects duplicate destination paths and any
destination path or existing inode that aliases any source shard. It also
rejects nonregular, symlink, or hardlinked existing targets. The same check
is repeated for the active target before its publication and after each fault
callback; every target is rechecked once after staging. Source path/inode and
destination uniqueness sets are built once, so path inspections grow linearly
with shard count even across publication hooks. The underlying
C01 writer publishes each overlay with a same-directory temporary and atomic
rename; this is **not** a multi-shard transaction. After a partial publication,
re-running with the same shards converges to byte-identical overlays. A
prepublication failure leaves that target's prior bytes unchanged. Source
shards and unrelated overlays are never written. A hostile process racing to
replace paths inside the trusted directory is outside the C01 guarantee.

Each C01 overlay has analyzer key `exact-dedup`, version `exact-bytes:v1`, and
the exact source-shard digest in its header. Every source document receives a
strictly ID-sorted record with fields:

| Field | Value |
| --- | --- |
| `canonical_version` | UTF-8 `exact-bytes:v1` |
| `digest_sha256` | 32 raw SHA-256 bytes of original content |
| `duplicate` | one byte: 0 for representative, 1 otherwise |
| `group_cardinality` | ASCII decimal member count |
| `representative_id` | canonical minimum DocumentId, UTF-8 |

The adapter creates fixed 32-record sort runs of candidate records ordered by
index hash, complete content bytes, then DocumentId. A hash collision is only
an index collision, never equality. Eight-way merges keep file-descriptor and
frame memory bounded. Equal-byte groups larger than one run are spooled to
disk, counted and assigned their minimum ID, then reread for link emission.
Further external sorts reject duplicate IDs globally and order links by
source shard and DocumentId. Run paths live in on-disk manifests rather than
corpus-sized arrays. Maximum input frame size follows C01's 1 MiB document
payload cap; scratch records cap at 2 MiB. Intermediate files are removed
after each pass and on exit. Disk use is proportional to input and output plus
bounded merge intermediates; this is not a fixed-disk quota or a whole-corpus
RAM promise.

The release-active checker exercises 300 equal-byte records spanning three
shards, forced index collisions with distinct bytes, ascending pure-link and
overlay order, shuffled shard and worker layouts, C01 join, restart equivalence, source and
unrelated-overlay immutability, destination/source aliases, duplicate IDs,
and all three prepublication fault points:

```sh
ldc2 -O3 -release -d-version=ExactDedupOverlayCheck -i -I=source \
    experiments/exact_dedup/overlay_check.d \
    -of=.dub/exact-dedup-overlay-check
.dub/exact-dedup-overlay-check
```

Rollback removes the opt-in overlay module and any overlays it produced. No
predecessor format or durable schema is migrated.
