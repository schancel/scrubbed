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
- In plain (non-`--explain`) mode, an abort mid-batch (a
  `--max-input-bytes` admission failure, a traversal error, a worker-fatal
  failure the walk then observes, or SIGINT) prints a summary before the
  fatal error propagates:

  ```
  done. N succeeded[, Q quarantined][, F failed][, K canceled in flight], M canceled before this fatal error.
  ```

  The bracketed clauses appear only when their count is nonzero, so a
  single-threaded abort still prints `done. N succeeded, M canceled before
  this fatal error.` Each discovered file is counted in exactly one bucket:

  - `N succeeded`: completed and written. This equals the number of
    outputs the run produced.
  - `Q quarantined`: completed with a quarantine or reject decision.
  - `F failed`: a worker failed on the document, for example the
    worker-fatal failure that stopped the run. That file also gets its own
    `FATAL` line.
  - `K canceled in flight`: admitted into the concurrent queue but not
    finished when the abort cancelled the scheduler. This covers documents
    still queued, which are discarded without being processed, and
    documents processed but refused ordered publication, which print
    `CANCELED <file>: ordered publication canceled after an earlier fatal
    root` on stderr. Each document is counted once, when the scheduler
    resolves it. This bucket is essentially always zero with `--threads
    1`, and under concurrency it can be as large as about
    `--max-queued-docs` plus `--threads`.
  - `M canceled before this fatal error`: discovered, but never admitted.
    That means files in an already-walked directory's entry list that the
    walk had not reached yet, plus the file the walk stopped on when that
    file was only refused admission and did not itself cause the abort
    (SIGINT, or an earlier worker-fatal failure).

  The one file excluded from all buckets is the file that caused the abort
  itself, for example the file over `--max-input-bytes` or a file that
  could not be stat'ed. The fatal message already names it. So when a file
  causes the abort, `N + Q + F + K + M` equals the discovered file count
  minus one. When the stop comes from SIGINT or a worker failure, the sum
  equals the discovered file count. The count cannot see into a sibling
  directory the walk had not reached at all, because those files were
  never discovered. This summary is diagnostic only and does not change
  the run-fatal classification above.

This queue is local and ephemeral: it is not a resume manifest or a
distributed scheduler. The per-document pipeline still materializes
whole-document text and may expand it substantially, so the input-byte
ceiling is not a bound on process memory or output size.
