# Bounded local input walk

The CLI now walks a directory incrementally and submits each file through a
local bounded scheduler. It does not retain a full-tree pathname array.

`--max-queued-docs` (default 64) caps file tasks admitted but not yet started.
`--max-input-bytes` (default 268435456) caps the sum of admitted file sizes,
including queued and active tasks. `--max-open-inputs` (default `--threads`)
caps workers in the file-processing callback, conservatively covering input
mapping and output writing. These are independent ceilings: a worker waiting
for a descriptor still owns its byte reservation, but is no longer queued.
The scheduler exposes current and peak counters for each ceiling, and a
blocking join waits for every submitted task before returning.

A file larger than the byte ceiling is skipped with a diagnostic and makes
the command exit nonzero. If its mapped length differs from the size reserved
during traversal, it is likewise skipped rather than exceeding the byte
budget. A file that is modified *after* mapping may still fail during reading;
this is not a stable snapshot protocol. Empty files stay supported. The
future windowed-input work can replace the single-file rejection policy.

Traversal and processing can now overlap. A symlink found later in a tree
still aborts the command, but earlier successfully written outputs can remain.
Cancellation stops new admissions, drains already submitted work and releases
all reservations. Ordinary per-file failures are reported as `SKIP` and do not
cancel unrelated files. This queue is local and ephemeral: it is not a resume
manifest or a distributed scheduler. The per-document pipeline still
materializes whole-document text and may expand it substantially, so the
input-byte ceiling is not a bound on process memory or output size.
