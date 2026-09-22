# Structured chunks (opt-in Stage 1)

`domain.structured_chunks.chunkStructured` is a pure post-extraction facade. A
caller supplies a canonical `DocumentId`, an opaque nonempty content revision,
immutable UTF-8 text, and preorder `StructuredSpan` nodes. It does not parse
PDF/Office layout, read a shard, change C01 IDs, infer sentences, assign
rights, create embeddings, or build a search index. The existing CLI does not
invoke it.

Each span has a half-open **byte** range and a nonempty ordinal path. Roots
have one ordinal; a direct child extends its parent's path by one ordinal.
Sections and pages are containers and can nest in either order; paragraphs are
leaves. Sibling paths increase strictly. Paragraphs must partition the whole
text in source order without gaps or overlap. Container ranges must be exactly
covered by descendants. Empty text has no spans and emits no chunks. Invalid
UTF-8, offsets inside a UTF-8 scalar, duplicate/unordered paths, invalid
nesting, oversized input, and coverage errors are rejected. Diagnostics do not
include source text. The input limit is 1 MiB, at most 65,536 spans and path
depth 32, and at most 65,536 emitted chunks.

Metadata is typed descriptive data (`language`, `title`, `sourceLabel`), not a
rights decision. A nonempty child value replaces the inherited value; an empty
value means inherit. Each value is at most 1,024 UTF-8 bytes. No license or
permission is inferred from an absent field. Chunks own copies of their text
and paths, so they do not retain a borrowed view into the caller's input.

The default chunk cap is 4,096 bytes; callers may lower it. An oversized
paragraph is split greedily at the last UTF-8 boundary at or before the cap.
A cap smaller than one scalar is rejected. Each emitted path appends a zero-based
split ordinal to its paragraph path. Offsets remain byte-exact, and section
and page ancestry is carried explicitly as ordered path arrays. Splitting is
deterministic but not semantic; a change before a split boundary can shift later
pieces and therefore their IDs.

`chunk:v1:<64 lowercase hex>` is SHA-256 of the following bytes: the NUL-ended
domain tag `scrubbed:structured-chunk-id:v1`, a big-endian u32 length and the
ASCII canonical parent `DocumentId`, a big-endian u32 path length and each path
ordinal as big-endian u32, then a big-endian u32 length and exact chunk UTF-8
bytes. Revision, offsets, metadata, and iteration order do not enter the ID.
This keeps unchanged chunks stable across content revisions, while changed
bytes invalidate the affected ID. The `chunk:` namespace cannot masquerade
as the C01 `doc:`/`child:` source identity.

`effects.chunk_jsonl.encodeChunkJsonl` projects one chunk to one canonical
LF-terminated JSON row, at most 16 KiB. `decodeChunkJsonl` accepts only those
canonical rows and recomputes the ID. A chunk whose escaped row would exceed
the cap is rejected; the projection does not silently truncate it. The exact
v1 key order is:

```text
schema, version, document_id, content_revision, chunk_id, start, end,
path, section_paths, page_paths, metadata, text
```

`schema` is `structured-chunk:v1`; `version` is `1`. `metadata` contains
`language`, `title`, `source_label` in that order. Offset numbers are UTF-8 byte
offsets, not codepoint indices. No writer, persistence migration, or index is
part of this adapter. Rollback deletes these opt-in modules and their fixtures;
existing binary shards and CLI output remain unchanged.

The reader limits JSON parser recursion to depth 3 (root object at depth 0;
the deepest canonical value is a number in a nested path array). It rejects
deeper input before recursion can exhaust a small process stack.

The release-active checker is `experiments/structured_chunks/check.d`; it
contains golden IDs, hierarchy/Unicode/invalid-span fixtures, a JSONL
round-trip, a deeply nested hostile-row rejection, and a 256-KiB material
payload with a bounded per-row assertion.
