/// Argparse command shell and narrow adapter to the established CLI pipeline.
module cli_commands;

import argparse;
import cli : runApp, runExtract;
import effects.error_cli : runErrorCommand;
import effects.metadata_route_cli : runMetadataRoute;
import std.conv : to;
import std.file : thisExePath;
import std.stdio : stderr, writeln;
import std.string : indexOf, startsWith;

mixin template ProcessingOptions() {
    @(NamedArgument("input", "i").Description("Input file or directory tree"))
    string input;
    @(NamedArgument("output", "o").Description("Output path"))
    string output;
    @(NamedArgument.Description("Comma-separated filter chain"))
    string filters = "normalize-line-endings,strip-control";
    @(NamedArgument.Description("JSON filter config"))
    string config;
    @(NamedArgument("stage").Description("Ordered stage ID=IMPLEMENTATION"))
    string[] stages;
    @(NamedArgument("stage-option").Description("Typed option KEY=TYPE:VALUE for the preceding stage"))
    string[] stageOptions;
    @(NamedArgument("filter").Description("Filter for the preceding stage"))
    string[] stageFilters;
    @(NamedArgument("filter-option").Description("Typed option KEY=TYPE:VALUE for the preceding filter"))
    string[] filterOptions;
    @(NamedArgument("dispatch-option").Description("V4 dispatch limit KEY=VALUE"))
    string[] dispatchOptions;
    @(NamedArgument("route").Description("V4 dispatch route NAME=EXTRACTOR"))
    string[] routes;
    @(NamedArgument("route-option").Description("V4 route option KEY=TYPE:VALUE"))
    string[] routeOptions;
    @(NamedArgument("action").Description("V4 outcome action OUTCOME=KIND:TARGET"))
    string[] actions;
    @(NamedArgument("common").Description("End v4 dispatch declaration; begin common v3 stages"))
    bool common;
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
    @(NamedArgument("error-journal").Description("Existing opt-in v3 failure journal path"))
    string errorJournal;
    @(NamedArgument("error-retry").Description("Explicitly retry unresolved v3 outputs"))
    bool errorRetry;
    @(NamedArgument("error-targeted").Description("Retry only exact local v3 outstanding targets"))
    bool errorTargeted;
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

@(Command("extract", "x").Description("Export a bounded selected HTML parse tree or Markdown."))
struct Extract {
    @(NamedArgument("input", "i").Description("Input path")) string input;
    @(NamedArgument("output", "o").Description("Output path")) string output;
    @(NamedArgument("format", "f").Description("Extraction format")) string format;
    @(NamedArgument("charset").Description("Declared UTF-8/UTF-16LE/UTF-16BE charset"))
    string charset;
    @(NamedArgument("max-html-bytes").Description("Raw and decoded HTML byte limit (1..8388608; default 1048576)"))
    ulong maxHtmlBytes;
    @(NamedArgument("config").Description("Canonical JSON v3 job for the selected HTML stage"))
    string config;
}

@(Command("completion").Description("Generate shell setup or command/option-name candidates; use completion init --bash, --zsh or --fish."))
struct Completion {}

@(Command("errors-init").Description("Create a new opt-in v3 error journal."))
struct ErrorsInit {
    @(NamedArgument("journal").Description("New v3 journal path")) string journal;
}

@(Command("errors-copy").Description("Copy an existing v1 journal to a new v2 journal."))
struct ErrorsCopy {
    @(NamedArgument("from-v1").Description("Existing v1 journal path")) string fromV1;
    @(NamedArgument("journal").Description("New v2 journal path")) string journal;
}

@(Command("errors-export").Description("Export a bounded v2 or v3 journal snapshot."))
struct ErrorsExport {
    @(NamedArgument("journal").Description("Existing v2 or v3 journal path")) string journal;
    @(NamedArgument("errors-jsonl").Description("History JSONL destination")) string errorsJsonl;
    @(NamedArgument("outstanding-jsonl").Description("Outstanding JSONL destination"))
    string outstandingJsonl;
}

@(Command("errors-verify").Description("Verify exported JSONL and digest sidecars."))
struct ErrorsVerify {
    @(NamedArgument("errors-jsonl").Description("History JSONL path")) string errorsJsonl;
    @(NamedArgument("outstanding-jsonl").Description("Outstanding JSONL path"))
    string outstandingJsonl;
}

@(Command("route-metadata").Description("Route local HTML content and stage metadata to independent sinks."))
struct RouteMetadata {
    @(NamedArgument("input").Description("HTML file or directory tree")) string input;
    @(NamedArgument("content-output").Description("Existing content root")) string contentOutput;
    @(NamedArgument("metadata-output").Description("Existing metadata root")) string metadataOutput;
    @(NamedArgument("manifest").Description("Local v1 manifest path")) string manifest;
    @(NamedArgument("filters").Description("Comma-separated content filters")) string filters;
    @(NamedArgument("retry").Description("Explicitly retry unresolved sink outputs")) bool retry;
}

@(Command("scrubbed").Description("Sanitize text through a bounded filter pipeline."))
struct Commands {
    SubCommand!(Repair, Extract, Completion, ErrorsInit, ErrorsCopy,
        ErrorsExport, ErrorsVerify, RouteMetadata, Default!Run) command;
}

enum Config parserConfig = { errorExitCode: 2 };

private bool present(const string[] args, string name) {
    foreach (arg; args)
        if (arg == name || arg.startsWith(name ~ "=")) return true;
    return false;
}

private bool compositionFlag(string value) {
    foreach (name; ["--stage", "--stage-option", "--filter", "--filter-option",
            "--dispatch-option", "--route", "--route-option", "--action", "--common"])
        if (value == name || value.startsWith(name ~ "=")) return true;
    return false;
}

private void forwardComposition(ref string[] forwarded, const string[] original) {
    for (size_t i; i < original.length; ++i) {
        if (!compositionFlag(original[i])) continue;
        forwarded ~= original[i];
        if (original[i] == "--common") continue;
        if (original[i].indexOf('=') < 0 && i + 1 < original.length)
            forwarded ~= original[++i];
    }
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
    forwardComposition(forwarded, original);
    if (present(original, "--max-open-inputs"))
        forwarded ~= ["--max-open-inputs", options.maxOpenInputs.to!string];
    if (options.listFilters) forwarded ~= "--list-filters";
    if (options.validate) forwarded ~= "--validate";
    if (options.dryRun) forwarded ~= "--dry-run";
    if (options.explain) forwarded ~= "--explain";
    if (present(original, "--manifest")) forwarded ~= "--manifest=" ~ options.manifest;
    if (options.manifestRetry) forwarded ~= "--manifest-retry";
    if (present(original, "--error-journal"))
        forwarded ~= "--error-journal=" ~ options.errorJournal;
    if (options.errorRetry) forwarded ~= "--error-retry";
    if (options.errorTargeted) forwarded ~= "--error-targeted";
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

private void printCompletionHelp() {
    writeln("Usage: scrubbed completion [-h] <operation> [<args>]\n");
    writeln("Generate shell setup or command/option-name candidates.\n");
    writeln("Operations:");
    writeln("  init --bash|--zsh|--fish");
    writeln("      Print initialization script for the selected shell.");
    writeln("  complete --bash|--zsh|--fish -- <tokens>");
    writeln("      Print command and option name candidates.\n");
    writeln("Optional arguments:");
    writeln("  -h, --help    Show this help message and exit\n");
}

private bool publicCompletionShell(string value) {
    return value == "--bash" || value == "--zsh" || value == "--fish";
}

private int completionError(string message) {
    stderr.writeln("scrubbed: ", message);
    stderr.writeln("Try 'scrubbed completion --help' for usage.");
    return 2;
}

private string posixShellLiteral(string value) {
    string quoted = "'";
    foreach (character; value) {
        if (character == '\'') quoted ~= "'\\''";
        else quoted ~= character;
    }
    return quoted ~ "'";
}

private string fishShellLiteral(string value) {
    string quoted = "'";
    foreach (character; value) {
        if (character == '\'' || character == '\\') quoted ~= '\\';
        quoted ~= character;
    }
    return quoted ~ "'";
}

private int printCompletionSetup(string shell) {
    auto executable = thisExePath();
    if (shell == "--bash") {
        auto command = posixShellLiteral(executable) ~
            " completion complete --bash -- \"${COMP_WORDS[@]}\" ---";
        writeln("# Add this source command into .bashrc:");
        writeln("#       source <(", posixShellLiteral(executable),
            " completion init --bash)");
        writeln("_scrubbed_completion() {");
        writeln("    local candidate");
        writeln("    COMPREPLY=()");
        writeln("    while IFS= read -r candidate; do");
        writeln("        COMPREPLY+=(\"$candidate\")");
        writeln("    done < <(", command, ")");
        writeln("}");
        writeln("complete -F _scrubbed_completion scrubbed");
    } else if (shell == "--zsh") {
        auto command = posixShellLiteral(executable) ~
            " completion complete --zsh -- \"${COMP_WORDS[@]}\" ---";
        writeln("# Ensure that you called compinit and bashcompinit like below in your .zshrc:");
        writeln("#       autoload -Uz compinit && compinit");
        writeln("#       autoload -Uz bashcompinit && bashcompinit");
        writeln("# And then add this source command after them into your .zshrc:");
        writeln("#       source <(", posixShellLiteral(executable),
            " completion init --zsh)");
        writeln("_scrubbed_completion() {");
        writeln("    local candidate");
        writeln("    COMPREPLY=()");
        writeln("    while IFS= read -r candidate; do");
        writeln("        COMPREPLY+=(\"$candidate\")");
        writeln("    done < <(", command, ")");
        writeln("}");
        writeln("complete -F _scrubbed_completion scrubbed");
    } else {
        auto command = "(COMMAND_LINE=(commandline -p) " ~
            fishShellLiteral(executable) ~
            " completion complete --fish -- (commandline -op))";
        writeln("# Add this source command into ~/.config/fish/config.fish:");
        writeln("#       ", fishShellLiteral(executable),
            " completion init --fish | source");
        writeln("complete -c scrubbed -a ", fishShellLiteral(command),
            " --no-files");
    }
    return 0;
}

private int runPublicCompletion(const string[] argv) {
    if (argv.length == 3 && (argv[2] == "--help" || argv[2] == "-h")) {
        printCompletionHelp();
        return 0;
    }
    if (argv.length < 3)
        return completionError("completion requires init or complete");
    if (argv[2] == "init") {
        if (argv.length != 4 || !publicCompletionShell(argv[3]))
            return completionError("completion init requires exactly one of --bash, --zsh or --fish");
        return printCompletionSetup(argv[3]);
    }
    if (argv[2] == "complete") {
        if (argv.length < 5 || !publicCompletionShell(argv[3]) || argv[4] != "--")
            return completionError("completion complete requires --bash, --zsh or --fish followed by -- <tokens>");
        string backend;
        if (argv[3] == "--zsh") backend = "--bash";
        else backend = argv[3].dup;
        string[] forwarded = ["complete", backend];
        forwarded ~= argv[4 .. $].dup;
        if (backend == "--bash" && forwarded[$ - 1] != "---")
            forwarded ~= "---";
        return CLI!(parserConfig, Commands).complete(forwarded);
    }
    return completionError("unknown completion operation: " ~ argv[2]);
}

/// Dispatch from the shipping executable; argparse owns parsing, help and completion.
int runCommands(string[] argv) {
    // The opt-in failure route must contain all parser and runtime diagnostics:
    // ordinary CLI diagnostics may echo a user path or filter argument.
    if (present(argv, "--error-journal") || present(argv, "--error-retry") ||
        present(argv, "--error-targeted")) {
        string[] forwarded = ["scrubbed"];
        size_t first = 1;
        if (argv.length > 1 && (argv[1] == "run" || argv[1] == "clean" ||
            argv[1] == "repair" || argv[1] == "fix")) first = 2;
        forwarded ~= argv[first .. $];
        try return runApp(forwarded);
        catch (Throwable failure) {
            if (failure.msg ==
                    "durable job: journal-v2-requires-fresh-v3")
                stderr.writeln("scrubbed: journal-v2-requires-fresh-v3");
            else stderr.writeln("scrubbed: error-journal-fatal");
            return 2;
        }
    }
    if (argv.length > 1 && argv[1] == "route-metadata") {
        foreach (arg; argv[2 .. $])
            if (arg == "--help" || arg == "-h") {
                Commands help;
                auto result = CLI!(parserConfig, Commands).parseArgs(help,
                    [argv[1], "--help"]);
                return result.exitCode;
            }
        return runMetadataRoute(argv[2 .. $]);
    }
    if (argv.length > 1 && (argv[1] == "errors-init" ||
        argv[1] == "errors-copy" || argv[1] == "errors-export" ||
        argv[1] == "errors-verify")) {
        foreach (arg; argv[2 .. $])
            if (arg == "--help" || arg == "-h") {
                Commands help;
                auto result = CLI!(parserConfig, Commands).parseArgs(help,
                    [argv[1], "--help"]);
                return result.exitCode;
            }
        return runErrorCommand(argv[1], argv[2 .. $]);
    }
    if (argv.length > 1 && argv[1].startsWith("errors-")) {
        stderr.writeln("scrubbed: errors-invalid-arguments");
        return 2;
    }
    // Retain argparse's old hidden entry points so previously generated setup
    // keeps working. New help and generated bytes use the nested public form.
    if (argv.length > 1 && (argv[1] == "--bash" || argv[1] == "--fish" ||
        argv[1] == "--zsh" || argv[1] == "--tcsh"))
        return CLI!(parserConfig, Commands).complete(argv[1 .. $]);
    if (argv.length > 1 && argv[1] == "init")
        return CLI!(parserConfig, Commands).complete(argv[1 .. $]);
    if (argv.length > 1 && argv[1] == "completion")
        return runPublicCompletion(argv);
    Commands commands;
    const original = argv[1 .. $].dup;
    auto result = CLI!(parserConfig, Commands).parseArgs(commands, argv[1 .. $]);
    if (!result) return result.exitCode;
    return commands.command.matchCmd!((cmd) {
        static if (is(typeof(cmd) == Extract)) {
            if ((cmd.format != "tree-json" && cmd.format != "markdown") ||
                !cmd.input.length || !cmd.output.length) {
                stderr.writeln("scrubbed: extract requires --input, --output and --format=tree-json|markdown");
                return 2;
            }
            if (present(original, "--max-html-bytes") && cmd.maxHtmlBytes == 0) {
                stderr.writeln("scrubbed: --max-html-bytes must be between 1 and 8388608");
                return 2;
            }
            if (present(original, "--config") && cmd.config.length == 0) {
                stderr.writeln("scrubbed: extract --config requires a nonempty path");
                return 2;
            }
            if (present(original, "--config") && (present(original, "--max-html-bytes") ||
                present(original, "--charset"))) {
                stderr.writeln("scrubbed: extract --config cannot be combined with --charset or --max-html-bytes");
                return 2;
            }
            return runExtract(cmd.input, cmd.output, cmd.charset, cmd.format,
                cmd.maxHtmlBytes, cmd.config);
        } else static if (is(typeof(cmd) == Completion)) {
            stderr.writeln("scrubbed: use completion init or completion complete");
            return 2;
        } else static if (is(typeof(cmd) == ErrorsInit) ||
            is(typeof(cmd) == ErrorsCopy) || is(typeof(cmd) == ErrorsExport) ||
            is(typeof(cmd) == ErrorsVerify) || is(typeof(cmd) == RouteMetadata)) {
            assert(0, "management verbs dispatched before argparse");
            return 2;
        } else {
            return process(cmd, original);
        }
    });
}
