# Content representation experiment

From this directory, run `dub run --build=release --compiler=ldc2`. The D
program constructs 4,096 repeated markup/text paragraphs (466,944 bytes), then
generates 2,000 deterministic scattered insertions, deletions, and replacements
from seed `0x12345678`. Both candidates receive the same saved trace and their
entire output bytes are compared for equality. The list holds source/replacement
string slices; the rope is a randomized-priority tree of slices. Neither
candidate copies input bytes during edits.

On Apple arm64 with LDC 1.43.0 (2026-09-21), one release run reported 60 ms
and 3,052,896 retained GC bytes for the list, versus below 1 ms and 527,360
retained GC bytes for the rope; output was exactly equal at 472,547 bytes.
`GC.stats().usedSize` deltas
are retained heap, not total allocation counts; `descriptor_writes` and
`nodes_created` report edit-structure allocation pressure without claiming to
be bytes actually allocated by the runtime. Timing is a single-process local
sample, not a throughput benchmark.

The rope wins this scattered 2,000-edit microbenchmark, but adds balancing,
split/merge, and lifecycle complexity not yet justified by a production caller.
F03 therefore uses the ordered list and leaves a tree as a measured follow-up
if a real workload makes list editing the bottleneck.
