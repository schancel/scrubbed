# URL frontier transition model

`domain.url_frontier` is the pure, single-writer state machine for URL work. It
does not parse or normalize URLs, perform I/O, or provide synchronization. A
later persistence adapter can map each public transition to one transaction
without changing frontier identity or lifecycle semantics.

Identity is the exact pair `(policyId, canonicalLocator)`. Both values are
opaque, and the nonempty policy ID is the caller's normalization-policy
version. The caller also supplies an opaque host key, depth, and provenance.
Duplicate identity is idempotent before sealing, even when the duplicate carries
different metadata; the first admitted metadata remains authoritative.

The frontier owns these transitions:

- Admission places new work in the bounded ready queue or, when it is full, in
  a bounded deferred FIFO. The total-page and stored-byte caps bound deferred
  work, so a completing worker never waits for queue capacity.
- Leasing advances a generation and respects the active-lease cap. Retryable
  failure remains scheduled and is observable as `retryableFailed` while ready.
  Permanent failure is terminal, so a poison item cannot prevent draining.
- `finish` is the atomic boundary for one outcome and its discoveries. Each
  discovery receives a typed admission or refusal; a refusal does not undo the
  valid lease outcome or other admissions. Per-finish discovery-count and
  aggregate input-byte caps are checked before any lease or frontier mutation;
  exceeding either rejects the whole transition and leaves the lease live.
- Reclaim invalidates the old generation before rescheduling the item. Stale,
  unknown, reused, and double-completed leases do not mutate state. An exhausted
  generation is reported before FIFO removal, leaving the item truthfully queued
  and preventing false completion.
- Cancellation stops new leases but preserves every admitted item and live
  lease. Resuming permits work to continue. Sealing rejects all later seeds and
  discoveries while already admitted work remains leaseable.
- Completion is true only after sealing, with no ready or deferred work and no
  active lease. This prevents an empty but still-open frontier from terminating.

Admission is bounded by total pages, pages per host, maximum depth, provenance
bytes, and total retained string bytes. Ready items and active leases have
separate caps. Each finish also bounds discovery count and aggregate discovery
input bytes. Refusals are values rather than waits or implicit drops.

Identity and host accounting use content-keyed indexes. Ready and deferred work
use geometrically grown ring FIFOs, so filling and draining a valid `P`-page
frontier does not scan all prior pages or copy an array tail per lease. The
release checks fill and drain 4,096 pages and assert fewer than `2P` FIFO resize
moves, guarding the linear-growth bound while checking deterministic order in
the smaller lifecycle fixtures.

The release checker exercises duplicate and policy identity, every cap,
ready/deferred saturation and FIFO promotion, retry/reclaim generations,
cancellation, seal/completion races, late discoveries, poison items, and 64
seeded randomized traces. This slice intentionally excludes SQLite, schema and
restart encoding, network scheduling, discovery parsing, and workflow policy.
