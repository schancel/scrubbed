/// Thin executable entry point. The command shell lives in `cli_commands.d`;
/// processing remains in `cli.d`.
module app;

import cli : requestInterrupt;
import cli_commands : runCommands;
import std.stdio : stderr;

int main(string[] args) {
    // Graceful SIGINT shutdown (fixes #448): without this, SIGINT reaching
    // the process has no effect scrubbed's own code ever observes -- see
    // docs/signal-handling.md for why (root cause) and what "graceful" means
    // here. `requestInterrupt` only sets an atomic flag; `cli.runApp`'s file
    // walk polls it between files and drains in-flight work through the
    // same cancellation path a fatal processing failure already uses.
    // SIGTERM is left at its OS default (immediate termination), which the
    // acceptance criteria for #448 treat as an acceptable baseline in its
    // own right.
    version (Posix) {
        import core.sys.posix.signal : SIGINT, sigaction, sigaction_t,
            sigemptyset;

        sigaction_t newAction;
        newAction.sa_handler = &requestInterrupt;
        sigemptyset(&newAction.sa_mask);
        // No SA_RESTART: `requestInterrupt` only sets a flag that
        // `runApp`'s file walk polls between files (see above), so this
        // handler has no in-handler work that a restarted syscall would
        // help finish. Any blocking syscall a signal-delivery thread
        // happens to be in (e.g. a slow read/write) should return EINTR
        // and unwind promptly instead of transparently resuming, so the
        // process is never left waiting on I/O the user has already asked
        // to interrupt.
        newAction.sa_flags = 0;
        sigaction(SIGINT, &newAction, null);
    }
    try {
        return runCommands(args);
    } catch (Exception error) {
        stderr.writeln("scrubbed: ", error.msg);
        return 2;
    }
}
