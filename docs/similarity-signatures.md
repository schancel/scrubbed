# Similarity signatures, first slice

`domain.similarity_signature.similaritySignatures` computes a pure, bounded
byte-shingle signature for caller-selected content. It's an input for the
(separately reviewed) disk-backed bucket successor — not a durable record
or a duplicate decision.

## Scope

- Takes a typed `DocumentId` and up to 1 MiB of caller-selected UTF-8
  content.
- Does not read C01 shards or C04 overlays (which hold opaque bytes) — the
  caller must choose a text view.
- Malformed UTF-8 is refused with `similarity signature: invalid UTF-8`.
- No source or overlay is modified.

## Normalization

Frozen profile: `byte-shingle-minhash:v1`.

- ASCII `A`–`Z` → lowercase.
- Each run of ASCII whitespace (`U+0009`–`U+000D` or space), including at
  either edge, collapses to one space.
- No Unicode case folding, normalization, tokenization, or language
  processing.

## Minhash

- 5-byte sliding shingles over the normalized bytes.
- 64 lanes, each 64-bit FNV-1a seeded by a frozen SplitMix64 schedule; each
  lane keeps the minimum shingle hash.
- A band key is 64-bit FNV-1a over its one-byte band ordinal and its four
  lane values (each little-endian) — 16 position-separated keys per
  signature.
- All arithmetic wraps modulo 2^64.
- Input shorter than 5 normalized bytes abstains: no candidate keys.

## Segmentation

The document gets one signature. Segments cover non-overlapping normalized
byte ranges targeting 4096 bytes; a boundary moves backward if it would
split a UTF-8 code point, so the final segment may be shorter.

Each result carries: the typed document ID, a segment flag plus zero-based
ordinal, fixed-size lane and band arrays, and the profile version. Callers
must distinguish document keys from segment keys, and must include this
profile plus the normalization/segment rule in any future artifact
identity.

A matching band is only a candidate signal — there's no recall guarantee,
probability assertion, cluster, representative, or final policy here.

## Bounds

- Memory: one input copy plus one normalized copy, plus at most 257
  fixed-size segment signatures.
- No corpus state is retained.

## Rollback

Remove this optional module, checker, and document. Immutable source data
is untouched.
