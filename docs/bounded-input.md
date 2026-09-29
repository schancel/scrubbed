# Bounded local input walk

The CLI walks a directory incrementally and submits each file through a
local bounded scheduler (`effects.bounded_input.BoundedInput`). It does not
retain a full-tree pathname array.

## Ceilings

| Flag | Default | Caps |
| --- | --- | --- |
| `--max-queued-docs` | 64 | File tasks admitted but not yet started |
| `--max-input-bytes` | 268435456 | Sum of admitted file sizes, including queued and active tasks |
| `--max-open-inputs` | `--threads` | Workers in the file-processing callback (input mapping + output writing) |

These are independent ceilings: a worker waiting for a descriptor still owns
its byte reservation, but is no longer queued. The scheduler exposes current
and peak counters for each ceiling, and a blocking join waits for every
submitted task before returning.

## File-size admission

- A file larger than the byte ceiling is a **run-fatal resource/admission
  error (exit 2)**, not an acknowledged per-document skip.
- For a nonempty file, the CLI checks size before opening, maps exactly its
  reserved byte count (never the grown full length), and checks size again
  before reading. A detected change fails closed rather than exceeding the
  byte budget.
- A file modified between those checks, or *after* mapping, may still fail
  during reading; this is not a stable snapshot protocol.
- Empty files use a size check on an opened handle.
- Future windowed-input work can replace the single-file rejection policy.

## Traversal, cancellation, and failure reporting

Traversal and processing can overlap. A symlink found later in a tree still
aborts the command, but earlier successfully written outputs can remain.

Cancellation stops new admissions, drains already-submitted work, and
releases all reservations.

- Only manifest-backed, durably acknowledged per-file failures are reported
  as `SKIP` and may continue; an unrecorded worker failure reports `FATAL`
  and exits 2.
- A discovered path rejected after worker-fatal cancellation gets one
  `status=canceled` EXPLAIN record; traversal-error cancellation remains
  distinct.
- In plain (non-`--explain`) mode, an abort mid-batch (including a
  `--max-input-bytes` admission failure) prints `done. N succeeded, M
  canceled before this fatal error.` before the fatal error propagates.
  `M` counts files already discovered in an already-walked directory's
  entry list that the walk had not yet reached when it aborted -- it does
  not count the file that caused the abort (already named separately in
  the fatal message) and cannot see into a sibling directory the walk had
  not yet reached at all. This is a diagnostic addition only; it does not
  change the run-fatal classification above.

This queue is local and ephemeral: it is not a resume manifest or a
distributed scheduler. The per-document pipeline still materializes
whole-document text and may expand it substantially, so the input-byte
ceiling is not a bound on process memory or output size.
