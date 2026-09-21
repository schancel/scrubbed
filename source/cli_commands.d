/// Argparse command shell and narrow adapter to the established CLI pipeline.
module cli_commands;

import argparse;
import cli : runApp;
import std.conv : to;
import std.stdio : stderr;
import std.string : startsWith;

mixin template ProcessingOptions() {
    @(NamedArgument("input", "i").Description("Input file or directory tree"))
    string input;
    @(NamedArgument("output", "o").Description("Output path"))
    string output;
    @(NamedArgument.Description("Comma-separated filter chain"))
    string filters = "normalize-line-endings,strip-control";
    @(NamedArgument.Description("JSON filter config"))
    string config;
    @(NamedArgument.Description("Worker thread count"))
    size_t threads;
    @(NamedArgument("max-queued-docs").Description("Maximum queued documents"))
    size_t maxQueuedDocs = 64;
    @(NamedArgument("max-input-bytes").Description("Maximum reserved input bytes"))
    ulong maxInputBytes = 256UL * 1024 * 1024;
    @(NamedArgument("max-open-inputs").Description("Maximum worker-held input descriptors"))
    size_t maxOpenInputs;
    @(NamedArgument("list-filters").Description("List registered filters and exit"))
    bool listFilters;
    @(NamedArgument.Description("Validate without processing"))
    bool validate;
    @(NamedArgument("dry-run").Description("Run filters without writing output"))
    bool dryRun;
    @(NamedArgument.Description("Print one decision record per input file"))
    bool explain;
}

@(Command("run", "clean").Description("Run the bounded filter pipeline (also the no-verb default)."))
struct Run {
    mixin ProcessingOptions;
}

@(Command("repair", "fix").Description("Repair text with the existing filter pipeline."))
struct Repair {
    mixin ProcessingOptions;
}

@(Command("extract", "x").Description("Extract text before filtering (not yet available)."))
struct Extract {
    @(NamedArgument("input", "i").Description("Input path")) string input;
    @(NamedArgument("output", "o").Description("Output path")) string output;
    @(NamedArgument("format", "f").Description("Extraction format")) string format;
}

@(Command("completion").Description("Generate shell setup or command/option-name candidates; use completion init --bash, --zsh or --fish."))
struct Completion {}

@(Command("scrubbed").Description("Sanitize text through a bounded filter pipeline."))
struct Commands {
    SubCommand!(Repair, Extract, Completion, Default!Run) command;
}

enum Config parserConfig = { errorExitCode: 2 };

private bool present(const string[] args, string name) {
    foreach (arg; args)
        if (arg == name || arg.startsWith(name ~ "=")) return true;
    return false;
}

private int process(T)(ref T options, const string[] original) {
    string[] forwarded = ["scrubbed", "--input", options.input,
        "--output", options.output,
        "--max-queued-docs", options.maxQueuedDocs.to!string,
        "--max-input-bytes", options.maxInputBytes.to!string];
    if (present(original, "--threads"))
        forwarded ~= ["--threads", options.threads.to!string];
    if (present(original, "--filters")) forwarded ~= ["--filters", options.filters];
    if (options.config.length) forwarded ~= ["--config", options.config];
    if (present(original, "--max-open-inputs"))
        forwarded ~= ["--max-open-inputs", options.maxOpenInputs.to!string];
    if (options.listFilters) forwarded ~= "--list-filters";
    if (options.validate) forwarded ~= "--validate";
    if (options.dryRun) forwarded ~= "--dry-run";
    if (options.explain) forwarded ~= "--explain";
    return runApp(forwarded);
}

/// Dispatch from the shipping executable; argparse owns parsing, help and completion.
int runCommands(string[] argv) {
    // Generated setup scripts invoke the executable directly with --bash or
    // --fish, so these entry points must use the same argparse completer.
    if (argv.length > 1 && (argv[1] == "--bash" || argv[1] == "--fish" ||
        argv[1] == "--zsh" || argv[1] == "--tcsh"))
        return CLI!(parserConfig, Commands).complete(argv[1 .. $]);
    if (argv.length > 1 && argv[1] == "init")
        return CLI!(parserConfig, Commands).complete(argv[1 .. $]);
    if (argv.length > 1 && argv[1] == "completion") {
        if (argv.length < 3 || argv[2] == "--help" || argv[2] == "-h") {
            Commands help;
            auto result = CLI!(parserConfig, Commands).parseArgs(help, ["completion", "--help"]);
            return result.exitCode;
        }
        if (argv[2] != "init" && argv[2] != "complete") {
            stderr.writeln("scrubbed: unknown completion operation: ", argv[2]);
            return 2;
        }
        return CLI!(parserConfig, Commands).complete(argv[2 .. $]);
    }
    Commands commands;
    auto result = CLI!(parserConfig, Commands).parseArgs(commands, argv[1 .. $]);
    if (!result) return result.exitCode;
    return commands.command.matchCmd!((cmd) {
        static if (is(typeof(cmd) == Extract)) {
            stderr.writeln("scrubbed: extract is not yet available");
            return 2;
        } else static if (is(typeof(cmd) == Completion)) {
            stderr.writeln("scrubbed: use completion init or completion complete");
            return 2;
        } else {
            return process(cmd, argv[1 .. $]);
        }
    });
}
