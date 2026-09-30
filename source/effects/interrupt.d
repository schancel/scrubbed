/// Process-wide SIGINT flag, shared across every command that polls it.
module effects.interrupt;

// SIGINT graceful shutdown (fixes #448, extended to `extract`/`route-metadata`
// by #482). `app.d` installs `requestInterrupt` as the process's SIGINT
// handler before any command dispatch, so the flag it sets here may be
// stored from a signal handler running on an arbitrary thread at an
// arbitrary point during any command's run (or before one starts, or after
// it returns). Keep `requestInterrupt` to exactly this one atomic store: no
// GC, no throwing, no locking -- anything else is unsafe to run from a
// signal handler.
//
// This lives in `effects` (not `cli`) so that `effects.metadata_route_cli`
// (`route-metadata`) can poll `interruptRequested()` from its own admission
// loop without importing `cli` -- forbidden by this project's layering
// (`scripts/check_modules.d`: effects may not import cli). `cli.d`
// re-exports `requestInterrupt`/`interruptRequested` via `public import` so
// `app.d` (which may import only `cli` among project modules) and every
// existing `cli`-internal caller (`runApp`'s file walk, `runExtract`'s own
// admission loop) keep working unchanged.
//
// Each poller (`cli.runApp`'s `submitPath`, `cli.runExtract`'s admission
// loop, `effects.metadata_route_cli.runMetadataRoute`'s per-file loop) polls
// `interruptRequested()` cooperatively -- once per file/document, between
// admissions -- and, on a true result, stops admitting new work and drains
// whatever it had already started through its own graceful-cancellation
// path, rather than dying mid-write. See docs/signal-handling.md for the
// chosen behavior and its limits (cooperative, per-file granularity -- not
// preemptive) for each command.
private shared bool interruptRequestedFlag = false;

/// Async-signal-safe. Do not add anything here beyond the atomic store.
/// The `int` parameter is the signal number `signal(2)`'s callback ABI
/// requires; unused, since one process installs this for SIGINT alone.
extern(C) void requestInterrupt(int) nothrow @nogc {
    import core.atomic : atomicStore;
    atomicStore(interruptRequestedFlag, true);
}

bool interruptRequested() nothrow @nogc {
    import core.atomic : atomicLoad;
    return atomicLoad(interruptRequestedFlag);
}

version (unittest) {
    // Test-only reset: production has exactly one process-lifetime SIGINT,
    // so nothing outside the unittest build needs to un-flag this.
    void resetInterruptedForTest() nothrow @nogc {
        import core.atomic : atomicStore;
        atomicStore(interruptRequestedFlag, false);
    }
}
