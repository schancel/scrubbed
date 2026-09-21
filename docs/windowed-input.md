# Windowed input effect (F07)

`effects.windowed_input.WindowedInput` is a standalone, read-only local-file
effect. It opens one descriptor, records its `fstat` length, and permits one
live `WindowLease` at a time. No CLI path uses it yet. A caller requests a
window at an absolute byte offset and a maximum logical length; the returned
lease reports its actual offset and length. The next window requires closing
the previous lease. `cancel` invalidates the active lease and forbids future
windows; `close` also closes the descriptor. Both are idempotent.

`WindowBorrow` exposes checked `at`, `length`, `offset`, and an opt-in owning
`copy`. It never returns a mapping-backed D slice. Every borrowed access
rejects after lease close, input close, or cancellation; an earlier `copy`
remains valid. `WindowCarry` is an owning, capacity-checked byte handoff for
small undecided spans or caller-maintained state. Callers choose its capacity
from their transform's maximum lookahead; this effect does not infer a parser
state or promise an arbitrary transform is streamable.

The cap is for *simultaneously mapped virtual bytes*, not logical payload
bytes. The reader aligns the requested offset downward to the OS page size,
counts the prefix, and rounds the mapping extent upward to a page. A cap must
cover at least one page. A non-page-multiple remainder is unused, so a window
near a page end may contain fewer bytes than requested. The single-active-map
rule makes overlap impossible; handoff carry is copied GC memory and is
separately bounded by the caller. `mappingStats` reports current, peak, total
mapped bytes, and map count. The cap is per reader, not process-wide across
multiple readers. Mapping does not cap OS page cache or other allocations.

The D-only harness is `experiments/windowed_input/check.d`:

```sh
ldc2 -O -release -enable-inlining -i -I=source experiments/windowed_input/check.d -of=/tmp/windowed-input-check-release
/tmp/windowed-input-check-release
/tmp/windowed-input-check-release --negative-control # expected exit 1
ldc2 -O -release -unittest -main source/effects/windowed_input.d -of=/tmp/windowed-input-release-unittests
/tmp/windowed-input-release-unittests
```

All harness checks throw explicit runtime failures and remain active under
`-release`; the deliberate negative control exits 1. The harness compares
bounded stitched token recognition against an independent D
whole-buffer recognizer at every split inside and around the chosen UTF-8,
CRLF, HTML named/numeric entity, and bounded mojibake byte candidates. It
also checks byte preservation for invalid/truncated UTF-8 (the effect does not
decode), empty input, page/EOF boundaries, lease invalidation, cancellation,
and a real sparse file larger than the cap. Every mapped byte of the sparse
hole is checked as zero, followed by the terminal marker. An additional
16 MiB borrow is rejected by an 8-byte carry before copying; GC live-used
growth at rejection is separately bounded below 1 MiB, and appending the
same borrow after lease close must reject. A release-mode module unittest
injects a failed page-size result into the private validator to verify it
rejects before unsigned conversion. On macOS arm64 in this run:
47 cases; page 16,384 bytes; sparse length 2,097,155 bytes; 65 windows;
peak simultaneously mapped 32,768 bytes under a 32,785-byte cap; GC
`usedSize` delta 6,528 bytes in the release-mode harness. The latter is an
observed D-GC live-used delta,
not an RSS or lifetime-allocation bound. The sparse probe writes only its last
byte and traverses all windows without creating an input-sized D buffer.
The 16 MiB borrow rejection produced a 128-byte D-GC live-used delta under
the 1 MiB test ceiling; this is also not a peak-RSS measurement.

This proof covers the local bounded-token examples, not the current CLI's
whole-document scoring, context-heavy HTML parsing, normalization decisions,
or every filter. Those need separate state/algorithm contracts before a CLI
integration. There is no terabyte-readiness claim. POSIX `mmap`/`fstat` and
page accounting are the supported platform mechanism; Windows is unsupported.
