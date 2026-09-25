# Durable local SQLite frontier

The default local crawler queue is `effects.sqlite_frontier.openLocalJobQueue`.
It returns the backend-neutral `domain.job_queue.JobQueue` interface and needs
no broker. Callers select a database path and the same bounded
`FrontierLimits` used by every backend. Reopening requires those limits to
match exactly; silently changing an existing job's limits would change replay
semantics.

## Durable shape and transaction boundary

Schema v1 has two tables. `frontier_meta` is a singleton owning the nine
limits, lifecycle flags, and next FIFO sequence. `frontier_candidate` owns one
row per `(policy_id, canonical_locator)`, including the opaque input, lifecycle
state, lease generation, retry placement, FIFO sequence, and measured stored
bytes. Pending and host indexes support bounded lease/promotion and admission
checks. The application id and `user_version=1` identify this format.
The generation column uses SQLite's signed integer cell as an unsigned 64-bit
bit pattern: negative stored values represent contract generations `2^63`
through `ulong.max`. Only the all-one-bit value is exhausted.

Every public mutation uses one `BEGIN IMMEDIATE` transaction. In particular,
finishing a producer changes its state, admits every accepted or refused
discovery, and promotes deferred work before one `COMMIT`. A crash before that
commit exposes neither completion nor discoveries; a crash after it exposes
both. `FULL` synchronous WAL is required at open. Generation changes are the
lease ownership token, so two local handles cannot lease the same row and a
late finisher is refused after reclaim.

Rows are retained through terminal state because identity suppression and
restart counters depend on them. Retention is bounded by `maxPages`. Each
handle has a two-second busy bound, a 2 MiB page-cache target, a 64-page WAL
auto-checkpoint window, and a 1 MiB journal-size target. Statements are
operation-local and finalized; transactions cover at most one producer plus
`maxDiscoveriesPerFinish`. `checkpoint()` requests a truncating maintenance
checkpoint and refuses a busy or partial result.

## Reopen and failure policy

Open checks the pinned SQLite 3.53.4 implementation, regular non-symlink path,
application/schema versions, integrity, required tables and indexes, queue
ordering/accounting invariants, configured limits, and bounded durable
contents before returning a mutable handle. Unknown versions, corruption,
limit mismatches, impossible states, and interrupted or unavailable durability
modes fail closed. A handle whose begun transaction throws becomes fail-stop,
because commit acknowledgement may be ambiguous; reopen is the recovery path.
Before reading any integer value, open also checks SQLite storage classes for
every metadata and candidate column. Numeric text is not accepted through
affinity coercion; opaque fields must be stored as text, numeric fields as
integers, and `queue_order` is the only nullable value. Policy id, canonical
locator, and host key must also contain at least one byte both at admission and
reopen; storage-class correctness alone is not a valid identity.

Reachability validation also checks the scheduler's durable high-water mark:
every pending order is unique and below `next_order`; deferred work exists only
behind a full ready queue; and every ready order precedes every deferred order.
These conditions reject superficially well-typed rows that no v1 transition
could have produced, preventing false no-work observations after corruption.
Pending orders are nonnegative, and leased or terminal/retryable states must
have a nonzero generation. This prevents a corrupt sealed row from appearing
truthfully complete even though no lease could have produced it.

For an existing database, schema, storage classes, configured limits, and all
reachability checks finish before `journal_mode`, cache, checkpoint, or journal
configuration runs. A refused DELETE-mode database therefore remains in DELETE
mode and gains no WAL/SHM sidecars merely because open detected corruption.

Active leases deliberately survive process restart. Another local worker may
finish them with the saved token or call `reclaim`; reclaim increments the
generation before returning the item to FIFO work, permanently invalidating a
late result from the old worker. An open empty frontier is not complete.
Completion is true only after sealing and after queued, deferred, leased, and
retryable work are all absent.

## Shape decision and rollback

The previous shape was memory-only `UrlFrontier` state. The target stores the
existing v1 contract without changing its identity or lifecycle results. The
known next backend is the optional JetStream work in #254/#252; it attaches at
`JobQueue`, so no SQLite adapter interface or generic persistence framework is
introduced. The durable hole left for that work is the already-versioned
backend descriptor and contract, not a shared database schema.

Changing candidate identity, row meaning, or FIFO sequence later requires an
explicit schema migration; this implementation never upgrades unknown
formats. Before this candidate is released, rollback is deletion of the new
database and use of the explicit in-memory factory. After real crawl state is
created, rollback preserves the database as evidence and requires export or a
versioned migration rather than destructive reinterpretation.

## Proof

`experiments/sqlite_frontier/check.d` links the repository-pinned amalgamation
and runs the shared frontier conformance transcript plus restart, two-handle
ownership, stale lease, pre/post-commit process-kill, incompatible schema,
corruption, limit mismatch, checkpoint, and resource-cleanup checks. Build it
from the repository root:

```sh
cc -O2 -DSQLITE_THREADSAFE=1 -DSQLITE_OMIT_LOAD_EXTENSION \
  -c third_party/sqlite/sqlite3.c -o /tmp/scrubbed-sqlite-frontier.o
ldc2 -O3 -release -d-version=SQLiteFrontierHarness -Isource -I. \
  experiments/sqlite_frontier/check.d \
  experiments/frontier_conformance/conformance.d \
  source/effects/sqlite_frontier.d source/effects/sqlite_ffi.d \
  source/domain/job_queue.d source/domain/frontier_contract.d \
  source/domain/url_frontier.d /tmp/scrubbed-sqlite-frontier.o \
  -of=/tmp/scrubbed-sqlite-frontier-check
/tmp/scrubbed-sqlite-frontier-check
```
