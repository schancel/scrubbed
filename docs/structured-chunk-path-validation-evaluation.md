# Structured-chunk path-validation stringification evaluation (issue #233)

## Decision

**No production change in this slice.** This ticket's own grooming pass
scoped it as measurement/evidence only ("a real rewrite is a separate,
later decision gated on what the measurement phase actually finds"), and
that gate is not yet crossed here. `source/domain/structured_chunks.d` is
unmodified.

The measurements below *do* show a repeatable, material improvement is
plausible from a specific, narrow candidate: replacing the `path.to!string`
associative-array keys (`bool[string] seen`, `uint[string] lastOrdinal`,
`bool[string] hasOrdinal`) with the `uint[]` path slice itself as the
associative-array key (`bool[const(uint)[]]`, `uint[const(uint)[]]`) --
using D's built-in structural array hashing/equality instead of formatting
a decimal string. The saving is small in absolute terms for an ordinary
document and grows substantially for adversarial maximum-span,
maximum-depth input. **Whether that's worth landing is a separate,
follow-on ticket's call**, not this one's -- see "If a follow-on ticket is
opened" below.

## What was measured

`experiments/structured_chunk_validation/check.d` (new; does not touch
`source/`) follows the `GC.allocatedInCurrentThread()`-delta /
`GC.collect()` / `GC.disable()` idiom already established in
`experiments/dispatch_record_reservation/check.d`, plus `getrusage`-based
CPU-time deltas (the same `getrusage` idiom already used for RSS in
`experiments/structured_chunks/check.d`).

Two separate measurements, both over the same three fixtures:

- **(A) Full pipeline.** Calls the real, unmodified public
  `chunkStructured` end to end. This is the true total cost, including
  everything else the function does (SHA-256 chunk IDs, output-array
  growth, metadata inheritance, `sectionPaths`/`pagePaths` copies) --
  not just the validation loop this ticket is about.
- **(B) Isolated microbenchmark.** A local, clearly-separated
  reimplementation of *only* the three-associative-array
  duplicate/sibling-order validation block (structurally identical to
  `structured_chunks.d` lines 153-186), run two ways over the exact same
  path sequences the (A) fixtures use:
  - `string-key` -- byte-for-byte the same approach as production.
  - `array-key` -- the candidate described above.

  This isolates the validation loop's own cost, since (A)'s totals are
  dominated by unrelated allocations (SHA-256 hex IDs, chunk structs) once
  span/chunk counts get large. **Both (B) variants are duplicated code
  written for this comparison only** -- the real validation logic lives
  in private, non-exported code inside `chunkStructured` and cannot be
  called in isolation from outside the module. Neither variant is
  production code, and correctness there was checked separately (below),
  not assumed from this duplication.

### Fixtures

| Fixture | Shape | Spans | Chunks | Purpose |
| --- | --- | --- | --- | --- |
| `ordinary` | 8 sections x 6 pages x 5 paragraphs/page, depth 3, 20 bytes/paragraph | 296 | 240 | A modest, realistic document |
| `maximum-span-shallow` | 65,536 top-level paragraphs, depth 1, 1 byte each | 65,536 | 65,536 | Widest possible sibling run at the existing `spans.length <= 65_536` cap |
| `maximum-span-deep` | 2,048 independent chains, each 32 spans deep (31 containers + 1 leaf), 1 byte/leaf | 65,536 | 2,048 | Every chain saturates the existing `path.length <= 32` bound; maximizes per-key length while also hitting the span-count cap |

All three satisfy `chunkStructured`'s real nesting/coverage rules (built
by a small generator function in the harness, not hand-authored one span
at a time) and were run through the real function first to confirm
determinism and expected chunk counts before any timed loop.

## Results

All allocation-byte figures below were **exactly reproducible bit-for-bit
across repeated process runs** (not just within a run's own first/second
half -- see "Repro" below for the two independent runs compared). CPU-time
figures vary run to run with ordinary scheduler/thermal jitter, as
expected on a shared machine; the *relative* improvement (the ratio
between `string-key` and `array-key`) was consistently in the same range
across two independent full runs, reported below as the range observed.

### (A) Full pipeline (real, unmodified `chunkStructured`)

| Fixture | Bytes/call | CPU seconds/call |
| --- | ---: | ---: |
| `ordinary` | 401,175 | 0.00048 - 0.00068 |
| `maximum-span-shallow` | 59,293,843 | 0.066 - 0.106 |
| `maximum-span-deep` | 83,718,848 | 0.163 - 0.241 |

(Second-half figures shown; first/second-half agreement was within the
harness's built-in 0.4x-2.5x stability guard on every fixture, i.e. no
warm-up or leak artifact.)

### (B) Isolated validation-block microbenchmark

| Fixture | Variant | Bytes/call | CPU seconds/call (range, 2 runs) |
| --- | --- | ---: | ---: |
| `ordinary` | string-key (current) | 69,376 | 0.000136 - 0.000192 |
| `ordinary` | array-key (candidate) | 40,960 | 0.000026 - 0.000050 |
| `maximum-span-shallow` | string-key (current) | 11,208,352 | 0.0164 - 0.0265 |
| `maximum-span-shallow` | array-key (candidate) | 4,916,896 | 0.0062 - 0.0097 |
| `maximum-span-deep` | string-key (current) | 36,281,344 | 0.1354 - 0.1555 |
| `maximum-span-deep` | array-key (candidate) | 14,617,856 | 0.0193 - 0.0246 |

Allocation-byte reduction, `array-key` vs. `string-key` (exact, reproducible):

| Fixture | Bytes saved | Reduction |
| --- | ---: | ---: |
| `ordinary` | 28,416 | 41.0% |
| `maximum-span-shallow` | 6,291,456 | 56.1% |
| `maximum-span-deep` | 21,663,488 | 59.7% |

CPU speedup, `array-key` vs. `string-key` (ratio range across the 2 runs):

| Fixture | Speedup |
| --- | ---: |
| `ordinary` | ~3.8x - 5.2x |
| `maximum-span-shallow` | ~2.5x - 2.7x |
| `maximum-span-deep` | ~6.3x - 7.0x |

### How much of the full-pipeline cost is this validation block?

Dividing (B)'s `string-key` numbers by (A)'s totals, matched within the
same run:

| Fixture | Share of full-pipeline bytes | Share of full-pipeline CPU |
| --- | ---: | ---: |
| `ordinary` | ~17% | ~28% |
| `maximum-span-shallow` | ~19% | ~25% |
| `maximum-span-deep` | ~43% | **~83%** |

For an ordinary document, the entire validation block -- string-keyed or
not -- costs under 100 microseconds and well under 100 KB; this is not
where an ordinary document's processing time goes, and the absolute
savings from a rewrite would be imperceptible. For the deepest-path,
highest-span adversarial shape this codebase's own bounds allow, the
validation block is the dominant cost of the entire chunking call (over
four-fifths of measured CPU time), and cutting it to roughly a sixth to a
seventh of its current cost (per the `array-key` CPU numbers above) would
materially move the adversarial-case total.

## Candidate semantic correctness (informal, not a full test suite)

This is an evidence-only slice, so the harness runs a handful of targeted
agreement checks between `string-key` and `array-key` -- not the full
production test matrix a real implementation ticket would need -- to
support the claim that the candidate doesn't obviously change accept/
reject behavior on the cases most likely to expose a bug in a naive key
scheme:

- A valid ascending-sibling path set: both accept.
- A duplicate path: both reject.
- An unordered sibling pair: both reject.
- `uint.max` as a leaf ordinal and as a mid-path element: both accept
  (this exercises the boundary value a decimal-string formatter also has
  to get right, alongside the array-key candidate's hash on that value).
- A parent/child/grandchild prefix chain (`[1]`, `[1,0]`, `[1,0,0]`):
  both accept -- neither keying scheme treats a path and one of its own
  prefixes as equal, since both are length-aware.
- Repeated parents at different depths with the same trailing ordinal
  (`[2,0]` and `[3,0]`, i.e. shared ordinal 0 under distinct parents):
  both accept -- this is exactly the kind of case a naive
  string/delimiter-free encoding could collide on, and neither variant
  does.

All six probes agreed on every run. This is deliberately not exhaustive
(it does not, for example, fuzz random path sets or explicitly test
`spans.length == 65_536` adversarial duplicate/near-duplicate collision
attempts) -- see the ticket's own acceptance-criteria list
("collision-prone or ambiguous path encoding", "worker-order invariance",
etc.) for what a real implementation ticket would still need to cover
before landing.

On the collision-risk question specifically: the *current* production
`.to!string` encoding (`std.conv.to!string` on `uint[]`, e.g. `[1, 2, 3]`)
is already unambiguous for this purpose -- it's a length-implicit,
delimiter-separated decimal encoding with no way for two distinct `uint[]`
values to format identically. The motivation for a rewrite here is
**allocation/CPU cost, not a correctness defect** in the existing
approach. The `array-key` candidate doesn't fix a collision bug; it avoids
formatting a string (and the associative-array hashing/rehashing that
string then has to go through) at all, using D's own built-in
length-and-contents array hash/equality on the `uint[]` slice directly.

## Repro

```sh
ldc2 -i -Isource -O3 -release -preview=dip1000 \
  third_party/sqlite/sqlite3.o .dub/lexbor/liblexbor_static.a \
  .dub/zstd/libzstd_decompress.a .dub/zstd/libzstd_compress.a -L-lcurl \
  experiments/structured_chunk_validation/check.d \
  -of=/tmp/structured-chunk-validation-check
/tmp/structured-chunk-validation-check
```

Run twice to see the allocation-byte figures reproduce exactly and the
CPU-time figures vary within ordinary scheduler jitter.

## Caveats and what's still unknown

- This slice measures allocation bytes and single-process CPU time only.
  It does not measure wall-clock latency under concurrent load, does not
  profile where inside the validation block the cost specifically falls
  (AA insert vs. `to!string` formatting vs. AA lookup), and does not
  measure the effect of `-preview=dip1000`/GC settings other than the
  shipped `release`/`release-unittest` build types.
- The `array-key` candidate as prototyped here does not `dup` the path
  slices it stores as AA keys, relying on the caller-owned `spans` array
  outliving the single synchronous `chunkStructured` call. That's true of
  the real call site too (the AAs are local to one call and never escape
  it), but a real implementation ticket should re-verify this explicitly
  against `-preview=dip1000` borrow-checking and any future change that
  might make the validation loop async or defer AA use past the call.
- Only one candidate shape was evaluated (native `uint[]`-as-AA-key). The
  ticket's own phrasing floats two other directions -- "hashing the
  `uint[]` bytes directly" (e.g. into a fixed-width struct key) and "a
  traversal-based check that never allocates a string at all" (e.g. a
  sorted-array or trie-based approach avoiding associative arrays
  entirely) -- neither of which was prototyped or measured here. The
  array-key candidate was the cheapest one to prototype safely and turned
  out to already show a large win; a follow-on ticket doing the real
  implementation should decide whether it's worth also comparing against
  those alternatives, particularly a traversal-based approach that could
  avoid associative-array overhead altogether (a different, likely
  larger, rewrite this ticket's evidence-only scope didn't authorize
  attempting).
- Fixture selection is this evaluator's judgment, not exhaustively
  reviewed. "Ordinary" in particular is a guess at what a typical
  structured document looks like; a real corpus sample was not available
  to this evaluation.

## If a follow-on ticket is opened

Based on the evidence above, a follow-on implementation ticket for the
`array-key` (or a related bounded-structural-key) candidate is
**plausible to justify**, particularly given how much of the
adversarial-shape cost (~83% of CPU) sits in exactly this block. It
should re-derive its own acceptance criteria from the parent ticket's
list (duplicate/sibling-order semantics for all path lengths and `uint`
values, bounded memory, worker-order invariance, no collision-prone
encoding) rather than treating this document's six informal probes as
sufficient, and should re-measure on the shipped `release` build type
(this evaluation used direct `ldc2 -O3 -release`, matching this
codebase's `release` `buildType`, but did not go through `dub build`
itself for the experiment binary).
