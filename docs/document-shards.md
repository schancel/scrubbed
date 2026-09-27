# Standalone document shards (binary v1)

An internal D artifact API for immutable per-document shards and analyzer
overlays — not a CLI, not a SQLite schema. `domain.shard_format` owns the
exact bytes; `effects.document_shards` owns bounded POSIX file I/O and
publication. Neither document IDs nor source text are reconstructed from
overlay data. A future incompatible format needs new magic bytes.

## Byte-level rules

- All lengths and counts are unsigned big-endian.
- Strings are nonempty, NUL-free, valid UTF-8 in NFC; a reader rejects
  noncanonical bytes instead of normalizing them.
- Values and document content are opaque bytes, including invalid UTF-8.
- `SourceLocator` derives the typed source-only `DocumentId`; output name
  and revision do not affect identity.
- IDs must be strictly increasing within a shard.

## Document shard

- File starts with magic `SCRBDOC1`, followed by zero or more frames.
- A frame is `u32` payload length, payload, and 32 raw SHA-256 bytes of the
  payload.
- A document frame payload is four `u16`-length-prefixed fields (dataset
  namespace, source key, record key, presentation output name), then a
  `u32` content length and exact content bytes.
- Maximum document payload: 1 MiB.
- EOF is legal only at a frame boundary. Empty files, truncated frames,
  extra bytes, bad digests, noncanonical metadata, oversize payloads, and
  duplicate/unsorted IDs all fail.
- Writers preflight the complete encoded length before copying opaque
  content or field values, so an oversized caller buffer never becomes a
  transient frame.

## Overlay shard

- Header bytes: `SCRBANN1 || u16BE(H) || H metadata bytes ||
  SHA256(all preceding header bytes)`. `H` is at most 4096.
- Metadata: `u16` key length/key, `u16` version length/version, then 32 raw
  SHA-256 bytes of the exact source-shard file.
- A reader validates magic, `H`, metadata canonicality, and the header
  digest before yielding any frame.
- Overlay frames use the same `u32`/SHA-256 envelope as document frames,
  capped at 64 KiB.
- Overlay payload: `u16` canonical ASCII source `doc:v1:` ID, 32-byte
  SHA-256 of that document's opaque content, `u16` field count, then sorted
  unique fields (`u16` NFC key length/key, `u32` opaque value length/value).
  An empty value is present; a missing key is absent.

## Reading (`joinShards`)

- Hashes the document shard, opens at most 32 overlays, then walks the
  document file and one record per overlay at a time.
- Distinct analyzer keys coexist. A repeated key — whether its version
  matches or differs — is an error; there is no last-wins rule.
- A missing annotation returns `present=false` with no invented fields.
- Errors: wrong source-shard digest, unknown document ID, stale content
  revision.
- Memory is bounded by one document frame plus one frame per overlay, plus
  small header/lookahead structures — it never reads a whole shard.
- The file reader has a configurable chunk size for boundary-invariant
  tests; production defaults to 64 KiB.

## Writing (atomicity)

- `DocumentShardWriter` publishes a same-directory temporary file, after
  fsync, using POSIX hard-link creation. The link succeeds only when the
  target name is absent, so a concurrent loser can never replace the
  winner's inode or bytes.
- `OverlayWriter` holds the source shard open read-only while writing and
  hashes that open descriptor. It fsyncs a same-directory temporary and
  atomically renames it over a regular, single-link overlay target.
- `OverlayWriter` refuses symlink and hardlink targets, any destination
  sharing the source shard's device/inode (including alternate path
  spellings), and a symlink parent directory at inspection time.
- Both writers expose `abort()`; publication/append failures also clean up
  their temporary files. Injected pre-publication failures preserve the
  prior overlay.
- Neither writer fsyncs the parent directory, so neither promises
  power-loss durability of the directory entry.
- Concurrent hostile path replacement after target inspection is not
  serialized by this API — callers must use a trusted, exclusively
  controlled output directory.

## Proof

`experiments/shards/check.d` fixes these complete-file goldens (hex, no
whitespace). The overlay header binds the document golden's full-file
SHA-256.

Document:

```text
53435242444f43310000001900037365740006736f7572636500017200016e00000002ff00bf1112eadb65af3c6a39712bdb04c95043b1ca9b5cf55b077f5caedffa04eb9e
```

Overlay:

```text
53435242414e4e31002e0008616e616c7973697300027631fe01ee7270ec6320d5e38a7c0c0058b53c6a974452e44150ac034fe23c34bb490234e56d99fa5214a1e09bd260563b7ab553d4d993ca082521dcc8822aece915000000770047646f633a76313a34363666623166643034363439323663343864333166376438333439336534363736623839316563366634323838303063363230613661393962373336363735ea5dbf9596d187e9500f23e9a680109475341cf4e81f7e043f7d97152c10772f00010006616e7377657200000000626d26a07271f4ba1ff6d25a554157aec63f92f9311bd3ca78aa7fd1360f498c
```

These are tiny deterministic fixtures, not a throughput or TB-scale claim.

## Non-goals

No CLI, analyzer algorithm, manifest checkpoint, JSONL interchange, or
schema migration. Rollback removes the standalone modules and artifacts; no
production durable state has been migrated.
