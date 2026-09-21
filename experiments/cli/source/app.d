module app;

import argparse;
import std.stdio : stderr, writeln;

@(Command("repair", "fix")
    .Description("Repair text in a file or directory without extracting it."))
struct Repair {
    @(NamedArgument("input", "i").Required.Description("Source path"))
    string input;
    @(NamedArgument("output", "o").Required.Description("Destination path"))
    string output;
    @(NamedArgument("threads", "j").Description("Worker count"))
    uint threads = 1;
}

@(Command("extract", "x")
    .Description("Extract text before applying a filter chain."))
struct Extract {
    @(NamedArgument("input", "i").Required.Description("Source path"))
    string input;
    @(NamedArgument("output", "o").Required.Description("Destination path"))
    string output;
    @(NamedArgument("format", "f").Description("Extraction format"))
    string format = "text";
}

@(Command("run", "clean")
    .Description("Run the legacy file-cleaning options; also the no-verb default."))
struct Run {
    @(NamedArgument("input", "i").Description("Input file or directory"))
    string input;
    @(NamedArgument("output", "o").Description("Output path"))
    string output;
    @(NamedArgument.Description("Comma-separated filter chain"))
    string filters = "normalize-line-endings,strip-control";
    @(NamedArgument.Description("JSON filter config"))
    string config;
    @(NamedArgument.Description("Worker count"))
    size_t threads = 1;
    @(NamedArgument("list-filters").Description("List registered filters"))
    bool listFilters;
}

@(Command("scrubbed")
    .Description("Parser-only preview; no input is opened or modified."))
struct App {
    SubCommand!(Repair, Extract, Default!Run) command;
}

enum Config parserConfig = { errorExitCode: 2 };

version (argparse_completion) {
    mixin CLI!(parserConfig, App).mainComplete;
} else {
    int main(string[] argv) {
        App app;
        auto result = CLI!(parserConfig, App).parseArgs(app, argv[1 .. $]);
        if (!result)
            return result.exitCode;
        if (app.command.matchCmd!((cmd) {
            static if (is(typeof(cmd) == Run))
                return !cmd.listFilters && (cmd.input.length == 0 || cmd.output.length == 0);
            else
                return false;
        })) {
            stderr.writeln("--input and --output are required (--list-filters to see what's available)");
            return 2;
        }
        // This is intentionally only a parser probe, not a document processor.
        writeln(app.command);
        return 0;
    }
}
