# Windowed input effect (F07)

`effects.windowed_input.WindowedInput` is a standalone, read-only local-file
effect: it opens one descriptor, records its `fstat` length, and permits one
live `WindowLease` at a time. **No CLI path uses it yet.**

## How it works

A caller requests a window at an absolute byte offset and a maximum logical
length; the returned lease reports its actual offset and length. Rules:

- The next window requires closing the previous lease first.
- `cancel` invalidates the active lease and forbids future windows.
- `close` also closes the descriptor.
- Both `cancel` and `close` are idempotent.

Two ways to hold onto bytes after that:

- **`WindowBorrow`** — checked `at`, `length`, `offset`, and an opt-in owning
  `copy`. It never returns a mapping-backed D slice. Every borrowed access
  rejects after lease close, input close, or cancellation; an earlier `copy`
  remains valid.
- **`WindowCarry`** — an owning, capacity-checked byte handoff for small
  undecided spans or caller-maintained state. Callers choose its capacity
  from their transform's maximum lookahead; this effect does not infer a
  parser state or promise an arbitrary transform is streamable.

## The mapping cap

The cap bounds *simultaneously mapped virtual bytes*, not logical payload
bytes:

- The reader aligns the requested offset downward to the OS page size,
  counts the prefix, and rounds the mapping extent upward to a page.
- A cap must cover at least one page.
- A non-page-multiple remainder is unused, so a window near a page end may
  contain fewer bytes than requested.
- The single-active-map rule makes overlap impossible.
- Handoff carry is copied GC memory, separately bounded by the caller.
- `mappingStats` reports current, peak, and total mapped bytes, plus map
  count.
- The cap is per reader, not process-wide across multiple readers. Mapping
  does not cap OS page cache or other allocations.

## Harness

D-only, at `experiments/windowed_input/check.d`:

```sh
ldc2 -O -release -enable-inlining -i -I=source experiments/windowed_input/check.d -of=/tmp/windowed-input-check-release
/tmp/windowed-input-check-release
/tmp/windowed-input-check-release --negative-control # expected exit 1
ldc2 -O -release -unittest -main source/effects/windowed_input.d -of=/tmp/windowed-input-release-unittests
/tmp/windowed-input-release-unittests
```

All harness checks throw explicit runtime failures and remain active under
`-release`; the deliberate negative control exits 1.

What it checks:

- Bounded stitched token recognition against an independent D whole-buffer
  recognizer, at every split inside and around the chosen UTF-8, CRLF, HTML
  named/numeric entity, and bounded mojibake byte candidates.
- Byte preservation for invalid/truncated UTF-8 (the effect does not
  decode), empty input, page/EOF boundaries, lease invalidation,
  cancellation, and a real sparse file larger than the cap. Every mapped
  byte of the sparse hole is checked as zero, followed by the terminal
  marker.
- An additional 16 MiB borrow, rejected by an 8-byte carry before copying;
  GC live-used growth at rejection is separately bounded below 1 MiB, and
  appending the same borrow after lease close must reject.
- A release-mode module unittest injects a failed page-size result into the
  private validator, to verify it rejects before unsigned conversion.

Observed on macOS arm64 in this run:

| Metric | Value |
| --- | --- |
| Cases | 47 |
| Page size | 16,384 bytes |
| Sparse file length | 2,097,155 bytes |
| Windows | 65 |
| Peak simultaneously mapped | 32,768 bytes (32,785-byte cap) |
| GC `usedSize` delta (release-mode harness) | 6,528 bytes |
| GC `usedSize` delta (16 MiB borrow rejection, 1 MiB test ceiling) | 128 bytes |

Both GC-delta numbers are observed D-GC live-used deltas, not RSS or
lifetime-allocation bounds and not peak-RSS measurements. The sparse probe
writes only its last byte and traverses all windows without creating an
input-sized D buffer.

## What this doesn't prove

This proof covers the local bounded-token examples, not the current CLI's
whole-document scoring, context-heavy HTML parsing, normalization decisions,
or every filter. Those need separate state/algorithm contracts before a CLI
integration. There is no terabyte-readiness claim.

POSIX `mmap`/`fstat` and page accounting are the supported platform
mechanism; Windows is unsupported.
