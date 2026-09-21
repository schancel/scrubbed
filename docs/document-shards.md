# Standalone document shards (binary v1)

This is an internal D artifact API, not a CLI or SQLite schema. `domain.shard_format`
owns the exact bytes; `effects.document_shards` owns bounded POSIX file I/O and
publication. Future incompatible formats require new magic bytes. Neither
document IDs nor source text are reconstructed from overlay data.

All lengths and counts are unsigned big-endian. Strings are nonempty, NUL-free,
valid UTF-8 in NFC; a reader rejects noncanonical bytes instead of normalizing
them silently. Values and document content are opaque bytes, including invalid
UTF-8. A document frame payload is four u16-length-prefixed fields (dataset
namespace, source key, record key, presentation output name), then a u32 content
length and exact content bytes. `SourceLocator` derives the typed source-only
`DocumentId`; output name and revision do not affect identity. IDs must be
strictly increasing. Each file starts with `SCRBDOC1`, followed by zero or
more frames. A frame is u32 payload length, payload, and 32 raw SHA-256 bytes
of the payload. Maximum document payload is 1 MiB. EOF is legal only at a
frame boundary; empty files, truncated frames, extra bytes, bad digests,
noncanonical metadata, oversize, and duplicate/unsorted IDs fail.

Overlay header bytes are exactly `SCRBANN1 || u16BE(H) || H metadata bytes ||
SHA256(all preceding header bytes)`. H is at most 4096. Metadata is u16-key
length/key, u16-version length/version, then 32 raw SHA-256 bytes of the exact
source-shard file. A reader validates magic, H, metadata canonicality and
header digest before yielding a frame. Overlay frames use the same u32/SHA-256
envelope, capped at 64 KiB. Payload is u16 canonical ASCII source `doc:v1:` ID,
32-byte SHA-256 of that document's opaque content, u16 field count, then sorted
unique fields (u16 NFC key length/key, u32 opaque value length/value). Empty
value is present; a missing key is absent.

`joinShards` hashes the document shard and opens at most 32 overlays, then
walks the document file and one record per overlay at a time. Distinct analyzer
keys coexist. A repeated key, whether its version matches or differs, is an
error; there is no last-wins rule. Missing annotation is returned as
`present=false` with no invented fields. Wrong source-shard digest, unknown
document ID, and stale content revision are errors. The file reader has
configurable chunk size for boundary-invariant tests; production defaults to
64 KiB. Memory is bounded by one document frame and one frame per overlay,
plus the small header/lookahead structures; it never reads a whole shard.

`DocumentShardWriter` publishes a same-directory temporary file after file
fsync using POSIX hard-link creation. The link succeeds only when the target
name is absent; a concurrent loser cannot replace the winner's inode or bytes.
`OverlayWriter` holds the source shard open read-only while writing and hashes
that open descriptor. It fsyncs a same-directory temporary and atomically
renames it over a regular single-link overlay target. It refuses symlink and
hardlink targets and a symlink parent at inspection time. Writers expose
`abort`; publication/append failures also clean their temporary files.
Injected pre-publication failures preserve the prior overlay. Neither path
fsyncs the parent directory, so neither promises power-loss durability of the
directory entry. Concurrent hostile path replacement after overlay target
inspection is not serialized by this standalone API; callers must use a
trusted, exclusively controlled output directory.

The D release checker `experiments/shards/check.d` fixes these complete-file
goldens (hex, no whitespace). The overlay header binds the document golden's
full-file SHA-256:

Document:

```text
53435242444f43310000001900037365740006736f7572636500017200016e00000002ff00bf1112eadb65af3c6a39712bdb04c95043b1ca9b5cf55b077f5caedffa04eb9e
```

Overlay:

```text
53435242414e4e31002e0008616e616c7973697300027631fe01ee7270ec6320d5e38a7c0c0058b53c6a974452e44150ac034fe23c34bb490234e56d99fa5214a1e09bd260563b7ab553d4d993ca082521dcc8822aece915000000770047646f633a76313a34363666623166643034363439323663343864333166376438333439336534363736623839316563366634323838303063363230613661393962373336363735ea5dbf9596d187e9500f23e9a680109475341cf4e81f7e043f7d97152c10772f00010006616e7377657200000000626d26a07271f4ba1ff6d25a554157aec63f92f9311bd3ca78aa7fd1360f498c
```

These are tiny deterministic fixtures, not a throughput or TB-scale claim.
No CLI, analyzer algorithm, manifest checkpoint, JSONL interchange, or schema
migration is included. Rollback removes the standalone modules and artifacts;
no production durable state has been migrated.
