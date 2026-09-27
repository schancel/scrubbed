# Frontier backend contract

`domain.job_queue.JobQueue` is the pipeline-facing seam for URL work. Its
values live in `domain.frontier_contract`; the pure state machine remains in
`domain.url_frontier` (see [docs/url-frontier.md](url-frontier.md)), behind
`openInMemoryJobQueue`.

## Version and capability policy

- The contract identity is `scrubbed.frontier`, version 1.0.
- A backend is compatible when the identity and major version match and its
  minor version is at least the caller's requested minor. An unknown
  identity, major version, or newer requested minor is rejected before a
  queue is allocated.
- Queue ordering and lifecycle operations are mandatory semantics, not
  optional capabilities. The only optional capability in version 1 is
  process durability: the in-memory backend (`openInMemoryJobQueue`)
  truthfully reports `processDurable = false`, and a caller requiring
  durability receives `unsupportedProcessDurability` with no queue and no
  mutable state.

## Required semantics

- `(policyId, canonicalLocator)` is the opaque candidate identity. Contract
  code neither parses nor normalizes URLs.
- Admission is bounded by page, per-host, depth, queued, stored-byte, and
  provenance-byte limits. Saturated ready work moves to a bounded deferred
  FIFO and is promoted deterministically.
- A lease advances its generation. Reclaim advances it again before
  requeueing, so late completion is stale. Retryable work joins the FIFO
  tail; permanent failure is terminal.
- `finish` validates the producing lease and the entire discovery
  count/input byte envelope before mutation. Once valid, the outcome and
  each typed discovery admission form one backend transaction boundary.
  Individual admission refusals do not roll back other discoveries or the
  lease outcome.
- Sealing rejects later admissions but permits queued and active work to
  drain. Completion is true only when a sealed queue has no ready,
  deferred, or leased work. An open empty queue reports no work, not
  completion.
- Cancellation stops new leases without changing existing work. Reclaim
  remains available while leasing is canceled.
- Snapshots are sorted by opaque identity. A caller supplies the maximum
  number of items it will accept; an oversized snapshot returns its
  required count and no partial data or mutation.

## Conformance suite

`experiments/frontier_conformance/conformance.d` is the reusable executable
specification. A backend registers a factory with that suite unchanged. The
suite checks typed results, every bound, mutation-free refusal, lease races,
retry/poison behavior, saturation, sealing, cancellation, and replay
equality. `fixtures/v1.expected.tsv` pins the canonical replay for contract
v1.

## Backends

Two implementations attach through `JobQueue` and pass the same conformance
suite:

- **In-memory** (`openInMemoryJobQueue`, `domain.url_frontier`) — no process
  durability, as above.
- **SQLite** (`effects.sqlite_frontier.openLocalJobQueue`, the shipped
  default local durable backend) — reports `processDurable = true`; see
  [docs/sqlite-frontier.md](sqlite-frontier.md) for its schema and
  transaction boundary.

A JetStream backend was evaluated and its direct production adoption
rejected for missing the mandatory transaction and state-machine semantics
above; see [docs/jetstream-evaluation.md](jetstream-evaluation.md). No
JetStream adapter exists in the codebase.

## Architecture boundary

The durable shape is only the typed identity, generations, states, limits,
and results already established by the pure frontier. This contract moves
those values to a backend-neutral owner; it does not create a stored or wire
format. No filesystem, SQLite, broker, network, clock, process, coordinator,
consensus, or CLI/profile concern belongs in the domain contract. In
particular, version and durability metadata are not a plugin registry or an
alternate semantic API.

The SQLite backend above already persists real work through this contract.
Rolling back the contract layer itself (not just swapping backends) now
means deleting `domain.frontier_contract`/`domain.job_queue`, restoring the
value declarations directly in `url_frontier.d`, and retiring or migrating
the SQLite backend built on top of it — a materially larger decision than
when this contract had no durable consumer.
