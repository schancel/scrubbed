/// Release-active executable check for #498: `scrubbed --version` and
/// `scrubbed version` against the real compiled binary. Compile with ldc2
/// (or dmd) and pass the release `scrubbed` executable path, following the
/// same real-subprocess convention as `examples/cli/check.d`'s own module
/// comment ("compile with ldc2 -O, then pass scrubbed"). Kept as its own
/// small file rather than folded into `check.d`: that file's "root help
/// golden" already hardcodes a byte-for-byte `--help` transcript that
/// predates `clean-web-document`/`crawl`/`errors-*` and does not match the
/// binary's current `--help` output -- a pre-existing staleness unrelated
/// to #498 and out of scope here. This file only asserts on `--version`.
module cli_version_check;

import std.algorithm.searching : canFind, startsWith;
import std.process : execute;

private void check(bool condition, string label) {
    if (!condition) throw new Exception("CLI version golden: " ~ label);
}

int main(string[] args) {
    check(args.length == 2, "usage: version_check <release executable>");
    auto exe = args[1];

    auto flagVersion = execute([exe, "--version"]);
    check(flagVersion.status == 0, "--version exits 0");
    check(flagVersion.output.length > 0, "--version prints a non-empty string");
    check(flagVersion.output.startsWith("scrubbed "), "--version output names scrubbed");
    check(!flagVersion.output.canFind("Available commands"),
        "--version must not fall through to the general command-list usage text");

    auto subcommandVersion = execute([exe, "version"]);
    check(subcommandVersion.status == 0, "version subcommand exits 0");
    check(subcommandVersion.output == flagVersion.output,
        "version subcommand output matches --version exactly");
    check(!subcommandVersion.output.canFind("Available commands"),
        "version subcommand must not fall through to the general command-list usage text");

    // Regression (caught in review): --version must stay scoped to the
    // genuine top-level bare-flag case. Appending it to a real subcommand's
    // own argv is a plausible typo and must remain a hard, loud error
    // (argparse's own "Unrecognized arguments"), exactly as it was before
    // #498 -- never a silently-accepted, ignored flag that lets the
    // pipeline run anyway.
    foreach (subcommandArgs; [["run", "--version", "--input", "in.txt",
                "--output", "out.txt"],
            ["extract", "--version", "--input", "in.txt", "--output",
                "out.txt", "--format", "markdown"],
            ["repair", "--version", "--input", "in.txt", "--output",
                "out.txt"]]) {
        auto swallowed = execute([exe] ~ subcommandArgs);
        check(swallowed.status == 2,
            "--version appended to `" ~ subcommandArgs[0] ~
            "` must still exit 2, not be silently accepted");
        check(swallowed.output.canFind("Unrecognized"),
            "--version appended to `" ~ subcommandArgs[0] ~
            "` must still surface an unrecognized-argument error: " ~
            swallowed.output);
    }

    return 0;
}
