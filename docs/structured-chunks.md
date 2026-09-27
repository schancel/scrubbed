# Structured chunks (opt-in Stage 1)

`domain.structured_chunks.chunkStructured` is a pure post-extraction facade.
A caller supplies a canonical `DocumentId`, an opaque nonempty content
revision, immutable UTF-8 text, and preorder `StructuredSpan` nodes.

It does not parse PDF/Office layout, read a shard, change C01 IDs, infer
sentences, assign rights, create embeddings, or build a search index. The
existing CLI does not invoke it.

## Span rules

- Each span has a half-open **byte** range and a nonempty ordinal path. A
  root has one ordinal; a direct child extends its parent's path by one
  ordinal, and sibling paths must increase strictly.
- Sections and pages are containers and can nest in either order; paragraphs
  are leaves.
- Paragraphs must partition the whole text in source order, without gaps or
  overlap. Container ranges must be exactly covered by their descendants.
- Empty text has no spans and emits no chunks.
- Rejected: invalid UTF-8, offsets that land inside a UTF-8 scalar,
  duplicate/unordered paths, invalid nesting, oversized input, and coverage
  errors. Diagnostics never include source text.

**Limits:** 1 MiB input, at most 65,536 spans, path depth 32, at most 65,536
emitted chunks.

## Metadata

`language`, `title`, and `sourceLabel` are typed descriptive data, not a
rights decision — no license or permission is inferred from an absent field.
A nonempty child value replaces the inherited value; an empty value means
inherit. Each value is at most 1,024 UTF-8 bytes. Chunks own copies of their
text and paths; they never retain a borrowed view into the caller's input.

## Chunking

The default chunk cap is 4,096 bytes; callers may only lower it (a cap
smaller than one UTF-8 scalar is rejected). An oversized paragraph is split
greedily at the last UTF-8 boundary at or before the cap, and each emitted
path appends a zero-based split ordinal to its paragraph path. Offsets stay
byte-exact, and section/page ancestry is carried explicitly as ordered path
arrays.

Splitting is deterministic but not semantic: a change before a split
boundary can shift later pieces, and therefore their IDs.

## Chunk ID

`chunk:v1:<64 lowercase hex>` is SHA-256 of, in order:

1. the NUL-ended domain tag `scrubbed:structured-chunk-id:v1`
2. a big-endian u32 length, then the ASCII canonical parent `DocumentId`
3. a big-endian u32 path length, then each path ordinal as big-endian u32
4. a big-endian u32 length, then the exact chunk UTF-8 bytes

Revision, offsets, metadata, and iteration order do not enter the ID, so
unchanged chunks stay stable across content revisions while changed bytes
invalidate only the affected ID. The `chunk:` namespace cannot masquerade as
a C01 `doc:`/`child:` source identity.

## JSONL projection

`effects.chunk_jsonl.encodeChunkJsonl` projects one chunk to one canonical
LF-terminated JSON row, at most 16 KiB; a row whose escaped size would
exceed the cap is rejected outright, never truncated. `decodeChunkJsonl`
accepts only canonical rows and recomputes the ID.

Exact v1 key order:

```text
schema, version, document_id, content_revision, chunk_id, start, end,
path, section_paths, page_paths, metadata, text
```

`schema` is `structured-chunk:v1`; `version` is `1`; `metadata` contains
`language`, `title`, `source_label` in that order. Offsets are UTF-8 byte
offsets, not codepoint indices. The reader limits JSON parser recursion to
depth 3 (root object at depth 0; the deepest canonical value is a number
nested inside a path array) to reject hostile deep input before it can
exhaust a small process stack.

No writer, persistence migration, or index is part of this adapter.

## Proof

`experiments/structured_chunks/check.d` covers golden IDs, hierarchy/
Unicode/invalid-span fixtures, a JSONL round-trip, a deeply nested hostile-
row rejection, and a 256-KiB payload with a bounded per-row assertion. It
also launches fresh child processes for the maximum 1-MiB payload at the
default cap and the maximum 65,536 accepted chunk count, serializes every
JSONL row, and rejects peak RSS above an explicit 256-MiB ceiling. On
Darwin, where the D `rusage` binding exposes no named max-RSS field, it
reads the value straight from the raw struct (already bytes there); on
Linux it reads `ru_maxrss` and converts from KiB. The bound includes
process/runtime overhead.

## Rollback

Deletes these opt-in modules and their fixtures; existing binary shards and
CLI output remain unchanged.
