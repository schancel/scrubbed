# Wired ordered-list stage edit experiment

From the repository root:

```sh
ldc2 -O -release -enable-inlining -i -I=source -of=/tmp/scrubbed-issue6-stage-bench-release experiments/stages/bench.d
/tmp/scrubbed-issue6-stage-bench-release 2000
/tmp/scrubbed-issue6-stage-bench-release 500 --probe-failure
```

The D program sends one 1 MiB borrowed document through `runStage`, performs
the requested number of deterministic one-byte replacements (default 2,000)
via the production `Content.replace` list, then streams the result. An
independently edited D byte array must be exactly equal to that output.
Runtime `enforce` checks remain active with `-release`; the deliberate
`--probe-failure` mismatch must exit nonzero with the expected error. The timer
surrounds the wired stage and edits;
the GC figures report used-size change at that boundary, not peak RSS or all
allocation traffic. They are a local observation, not a throughput guarantee.

On 2026-09-21, Apple Silicon / LDC 1.43.0, output equivalence passed at every
measured count. With `-O -release -enable-inlining`, two sequential sweeps
measured 6 ms at 500 edits; 25/25 ms at 1,000; 193/242 ms at 2,000; and
1,689/1,735 ms at 4,000. GC used-size deltas in the first sweep were
3,093,296, 1,745,440, 2,400,896, and 12,698,208 bytes respectively.
After replacing disabled release assertions with runtime checks, a further
optimized sweep measured 9/39/265/1,309 ms at 500/1,000/2,000/4,000 edits;
the negative-control probe exited 1 with the expected mismatch error.
After the lazy-range cancellation repair, the same optimized binary was
rebuilt and again proved exact output at every count (22/245/684/2,846 ms).
Other repository gates were running concurrently during that sweep, so its
wall times are recorded as contended rather than used as the capacity estimate;
the negative-control probe again exited 1 with the expected mismatch error.
The same D source compiled without optimization measured 27/384/1,549/6,004
ms at 500/1,000/2,000/4,000 edits in one sweep. Those debug timings must not
be compared directly with F03's optimized result. GC timing and process
contention add noise; the sweeps are not a fitted complexity proof.
The isolated F03 list-vs-rope experiment reported about 60 ms / 3 MiB retained
for the list and under 1 ms / 0.5 MiB retained for the rope on a different edit
trace. The optimized wired trace still rises from 25–39 ms at 1,000 edits to
about 1.3–1.7 seconds at 4,000 edits for one 1 MiB document. This list-edit
path is unsuitable for a high-edit throughput caller and warrants scope/score
review before integration; no throughput target was accepted for this
experiment. The list remains a private, reversible representation.
No rope migration is included because the claim owns stage semantics and
explicitly forbids silently replacing the F03 list. A representation change
needs its own accepted scope.
