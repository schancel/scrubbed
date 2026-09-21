/// Thin executable entry point. CLI behavior lives in `cli.d` so `dub test`
/// exercises the same production boundary that the built binary uses.
module app;

import cli : runApp;
import std.stdio : stderr;

int main(string[] args) {
    try {
        return runApp(args);
    } catch (Exception error) {
        stderr.writeln("scrubbed: ", error.msg);
        return 2;
    }
}
