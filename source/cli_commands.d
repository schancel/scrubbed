/// Argparse command shell and narrow adapter to the established CLI pipeline.
module cli_commands;

import argparse;
import cli : runApp, runExtract;
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
    @(NamedArgument.Description("Opt-in local SQLite restart manifest path"))
    string manifest;
    @(NamedArgument("manifest-retry").Description("Inspect and explicitly replace an unresolved manifest output"))
    bool manifestRetry;
    @(NamedArgument("jsonl-fields").Description("Comma-separated top-level JSON text fields for stdin/stdout JSONL"))
    string jsonlFields;
    @(NamedArgument("dataset-namespace").Description("Stable JSONL dataset namespace"))
    string datasetNamespace;
    @(NamedArgument("source-key").Description("Stable JSONL source key"))
    string sourceKey;
    @(NamedArgument("max-jsonl-line-bytes").Description("Maximum JSONL input record bytes"))
    size_t maxJsonlLineBytes;
    @(NamedArgument("max-jsonl-output-bytes").Description("Maximum JSONL output record bytes including LF"))
    size_t maxJsonlOutputBytes;
}

@(Command("run", "clean").Description("Run the bounded filter pipeline (also the no-verb default)."))
struct Run {
    mixin ProcessingOptions;
}

@(Command("repair", "fix").Description("Repair text with the existing filter pipeline."))
struct Repair {
    mixin ProcessingOptions;
}

@(Command("extract", "x").Description("Export a bounded selected HTML parse tree."))
struct Extract {
    @(NamedArgument("input", "i").Description("Input path")) string input;
    @(NamedArgument("output", "o").Description("Output path")) string output;
    @(NamedArgument("format", "f").Description("Extraction format")) string format;
    @(NamedArgument("charset").Description("Declared UTF-8/UTF-16LE/UTF-16BE charset"))
    string charset;
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
        "--output", options.output];
    if (present(original, "--max-queued-docs") || !present(original, "--jsonl-fields"))
        forwarded ~= ["--max-queued-docs", options.maxQueuedDocs.to!string];
    if (present(original, "--max-input-bytes") || !present(original, "--jsonl-fields"))
        forwarded ~= ["--max-input-bytes", options.maxInputBytes.to!string];
    if (present(original, "--threads"))
        forwarded ~= ["--threads", options.threads.to!string];
    if (present(original, "--filters")) forwarded ~= ["--filters", options.filters];
    if (options.config.length) forwarded ~= "--config=" ~ options.config;
    if (present(original, "--max-open-inputs"))
        forwarded ~= ["--max-open-inputs", options.maxOpenInputs.to!string];
    if (options.listFilters) forwarded ~= "--list-filters";
    if (options.validate) forwarded ~= "--validate";
    if (options.dryRun) forwarded ~= "--dry-run";
    if (options.explain) forwarded ~= "--explain";
    if (present(original, "--manifest")) forwarded ~= "--manifest=" ~ options.manifest;
    if (options.manifestRetry) forwarded ~= "--manifest-retry";
    if (present(original, "--jsonl-fields"))
        forwarded ~= "--jsonl-fields=" ~ options.jsonlFields;
    if (present(original, "--dataset-namespace"))
        forwarded ~= "--dataset-namespace=" ~ options.datasetNamespace;
    if (present(original, "--source-key"))
        forwarded ~= "--source-key=" ~ options.sourceKey;
    if (present(original, "--max-jsonl-line-bytes"))
        forwarded ~= ["--max-jsonl-line-bytes", options.maxJsonlLineBytes.to!string];
    if (present(original, "--max-jsonl-output-bytes"))
        forwarded ~= ["--max-jsonl-output-bytes", options.maxJsonlOutputBytes.to!string];
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
    const original = argv[1 .. $].dup;
    auto result = CLI!(parserConfig, Commands).parseArgs(commands, argv[1 .. $]);
    if (!result) return result.exitCode;
    return commands.command.matchCmd!((cmd) {
        static if (is(typeof(cmd) == Extract)) {
            if (cmd.format != "tree-json" || !cmd.input.length || !cmd.output.length) {
                stderr.writeln("scrubbed: extract requires --input, --output and --format=tree-json");
                return 2;
            }
            return runExtract(cmd.input, cmd.output, cmd.charset);
        } else static if (is(typeof(cmd) == Completion)) {
            stderr.writeln("scrubbed: use completion init or completion complete");
            return 2;
        } else {
            return process(cmd, original);
        }
    });
}
