/// Thin executable entry point. The command shell lives in `cli_commands.d`;
/// processing remains in `cli.d`.
module app;

import cli_commands : runCommands;
import std.stdio : stderr;

int main(string[] args) {
    try {
        return runCommands(args);
    } catch (Exception error) {
        stderr.writeln("scrubbed: ", error.msg);
        return 2;
    }
}
