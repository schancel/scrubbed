# Atomic piece output (F08)

`effects.atomic_piece_sink.writeAtomicPieces(destination, content.pieces(), checkpoint, chunkSize)` is a standalone POSIX effects-layer sink. It consumes checked `ContentPiece` descriptors in order into one bounded buffer (64 KiB by default). It creates a random, exclusive temporary file in the destination directory, writes all chunks, calls `fsync`, closes successfully, copies the old destination's POSIX mode bits when replacing it, then uses one rename to publish. It never joins the document. A checkpoint runs after each full/drained buffer and once immediately before commit; throwing cancels the operation. Any pre-commit exception removes the temporary file and leaves an existing destination's bytes and attributes unchanged. If no destination existed, no partial destination is published.

Borrowed owners must remain live for the entire consumption call. Each borrowed access checks its owner, including zero-length pieces, so an expired borrow throws and is not converted to owned content. The call is synchronous; callers must not mutate or close a borrowed backing concurrently. Same-file mapped input/output is supported on POSIX: the old inode remains mapped while the sink writes beside it and renames after consumption. This does not promise Windows behavior. The sink accepts an existing regular file or a new path in an existing directory; it rejects destination symlinks and other non-regular targets. Concurrent writers to the same path, parent-directory symlink races, and hostile path replacement are not coordinated by this API.

This is one-destination publication, not a multi-sink transaction. `fsync` covers the temporary file's data before rename, but the parent directory is not synced, so post-crash rename durability is not promised. The destination's previous inode is replaced; hard-link aliases retain the old inode. Stage 5a ordinary local file/tree jobs consume compiled map/split content through this sink while the mapped owner is live; durable and JSONL routes are unchanged. There is no S3 commit, throughput, or terabyte-readiness claim.

The D-only proof harness is `experiments/atomic_piece_sink/check.d`. Build it with:

```sh
ldc2 -O3 -release -Isource source/effects/atomic_piece_sink.d source/effects/mapped_file.d source/content/pieces.d source/domain/document.d experiments/atomic_piece_sink/check.d -of=/tmp/atomic-piece-sink-check
/tmp/atomic-piece-sink-check
/tmp/atomic-piece-sink-check --large 1025
/tmp/atomic-piece-sink-check --large 2049
```

The release-mode small check covers success, injected mid-stream failure, pre-commit cancellation, prior bytes/attributes, absent-destination non-publication, no orphan temporary, same-file mapped input/output, expired owner rejection, and invalid chunk size. The large checks map one 1 MiB source block and reuse its borrowed descriptor 1,025 or 2,049 times. Input storage is one ordinary 1 MiB file, not a multi-GiB input allocation or sparse output. Output is a real ordinary file: the harness verifies exact logical size, every 1 MiB boundary, EOF, and independent SHA-256 values of expected repeated bytes and sequentially read output. It reports allocated output blocks (`st_blocks * 512`), peak process RSS (`getrusage`, Darwin bytes or Linux KiB converted to bytes), sampled peak live GC bytes, and cumulative current-thread GC allocation during the sink (`GC.allocatedInCurrentThread`). The latter excludes fixture setup and output verification. Measurements are local, not a throughput or universal memory guarantee; APFS block accounting, OS caching, and other platforms may differ.

The temporary directory is removed after each harness run. The large checks need over 2 GiB of free disk space plus filesystem overhead. A real `ENOSPC` failure was not forced because filling the host volume would affect unrelated work; the checked fault path injects an exception at the streaming checkpoint instead. Rollback is deletion of this standalone module, harness, and document; no stored migration is required.

On macOS/APFS with LDC 1.43.0 (2026-09-21), the two release runs measured:

| Repeats | Logical bytes | Allocated output blocks, bytes | Peak RSS, bytes | GC bytes allocated during sink |
| ---: | ---: | ---: | ---: | ---: |
| 1,025 | 1,074,790,400 | 1,076,953,088 | 5,029,888 | 70,704 |
| 2,049 | 2,148,532,224 | 2,161,901,568 | 5,177,344 | 70,704 |

The same 70,704-byte GC allocation over both sizes supports the bounded-buffer behavior in this exercise; peak RSS differs slightly because it is a whole-process high-water mark.
