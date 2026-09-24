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
  valid lease outcome or other admissions.
- Reclaim invalidates the old generation before rescheduling the item. Stale,
  unknown, reused, and double-completed leases do not mutate state.
- Cancellation stops new leases but preserves every admitted item and live
  lease. Resuming permits work to continue. Sealing rejects all later seeds and
  discoveries while already admitted work remains leaseable.
- Completion is true only after sealing, with no ready or deferred work and no
  active lease. This prevents an empty but still-open frontier from terminating.

Admission is bounded by total pages, pages per host, maximum depth, provenance
bytes, and total retained string bytes. Ready items and active leases have
separate caps. Refusals are values rather than waits or implicit drops.

The release checker exercises duplicate and policy identity, every cap,
ready/deferred saturation and FIFO promotion, retry/reclaim generations,
cancellation, seal/completion races, late discoveries, poison items, and 64
seeded randomized traces. This slice intentionally excludes SQLite, schema and
restart encoding, network scheduling, discovery parsing, and workflow policy.
