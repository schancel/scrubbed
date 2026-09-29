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
        import core.stdc.signal : signal;
        import core.sys.posix.signal : SIGINT;
        signal(SIGINT, &requestInterrupt);
    }
    try {
        return runCommands(args);
    } catch (Exception error) {
        stderr.writeln("scrubbed: ", error.msg);
        return 2;
    }
}
