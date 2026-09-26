/// Pure publication seam for terminal side outputs.
///
/// `cli` currently constructs four local writers for the terminal side
/// outputs a stage event can carry (a flat JSONL sidecar, a tree-mirrored
/// file, and a durable-ledger-tracked file used for both the `--manifest`
/// and `--error-journal` routes) and selects among them by branching on
/// writer-specific state. They already share one implicit contract: publish
/// zero or more side outputs, then finalize with `commit` or discard with
/// `abort`. This module names that contract so `cli` can select among
/// conforming adapters polymorphically instead.
///
/// This is a publication-only seam: it knows nothing about admission,
/// leasing, or job completion, and must not import `cli`, `domain.job_queue`,
/// or any frontier/queue module.
module effects.side_output_sink;

import stages.contract : TerminalSideOutput;

/// A destination for the terminal side outputs a stage event carries.
///
/// The caller (`cli`) resolves and preflights each output's destination —
/// symlink/alias refusal, collision detection, and ancestor-directory
/// policy all stay in `cli`, unchanged by this seam — and passes the
/// resolved destination to `publish`. Adapters that always publish to one
/// fixed destination (for example a flat JSONL sidecar, fixed at
/// construction) are free to ignore it.
///
/// `publish` may write immediately (an atomic per-output replace, as the
/// tree-mirror and durable-ledger adapters do) or stage the output for a
/// later batched write (as the JSONL sidecar adapter does); either is legal
/// as long as `commit` finalizes whatever `publish` accumulated and `abort`
/// discards it instead. Adapters are constructed once per run (or once per
/// durable route) and reused across every document that run publishes.
interface SideOutputSink {
    /// Publish one terminal side output at its already-resolved
    /// destination.
    void publish(const ref TerminalSideOutput output, string destination);

    /// Finalize whatever publish() calls have accumulated so far. A no-op
    /// for adapters that already wrote each output atomically in publish().
    void commit();

    /// Discard any partial publication state. Must not throw.
    void abort() nothrow;
}
