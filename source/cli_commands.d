/// Argparse command shell and narrow adapter to the established CLI pipeline.
module cli_commands;

import argparse;
import cli : runApp, runExtract;
import composition.compiler : compileJob;
import effects.crawl_cli : runCrawl;
import effects.document_metadata_publish_stage : documentMetadataPublishKeyV1,
    documentMetadataPublishSuffixV1;
import effects.error_cli : runErrorCommand;
import effects.metadata_route_cli : runMetadataRoute;
import job.json : canonicalJobJson;
import job.presets : cleanWebDocumentTokensV1, expandCleanWebDocumentPresetV1;
import std.conv : to;
import std.file : FileException, exists, isDir, isSymlink, thisExePath;
import std.stdio : stderr, stdout, writeln;
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
    @(NamedArgument("sidecar-output").Description("Generic terminal side-output file or mirrored tree root"))
    string sidecarOutput;
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
    @(NamedArgument("max-jsonl-sidecar-bytes").Description("Maximum aggregate terminal side-output JSONL bytes"))
    ulong maxJsonlSidecarBytes;
}

@(Command("run", "clean").Description("Run the bounded filter pipeline."))
struct Run {
    mixin ProcessingOptions;
}

@(Command("repair", "fix").Description("Repair text with the existing filter pipeline."))
struct Repair {
    mixin ProcessingOptions;
}

@(Command("extract", "x").Description("Export a bounded selected HTML parse tree, whole-page Markdown, or boilerplate-stripped main-content Markdown."))
struct Extract {
    @(NamedArgument("input", "i").Description("Input path")) string input;
    @(NamedArgument("output", "o").Description("Output path")) string output;
    @(NamedArgument("format", "f").Description(
        "Extraction format: tree-json (default), markdown (whole page), " ~
        "or main-content-markdown (boilerplate/nav/ad/footer stripped " ~
        "first, same selection as html-main-content/clean-web-document, " ~
        "then rendered as Markdown instead of plain text)"))
    string format;
    @(NamedArgument("charset").Description("Declared UTF-8/UTF-16LE/UTF-16BE charset"))
    string charset;
    @(NamedArgument("max-html-bytes").Description("Raw and decoded HTML byte limit (1..8388608; default 1048576)"))
    ulong maxHtmlBytes;
    @(NamedArgument("config").Description("Canonical JSON v3 job for the selected HTML stage"))
    string config;
}

@(Command("clean-web-document").Description(
    "Run the sealed clean-web-document/v1 preset: text-transform's " ~
    "fix-mojibake filter, then html-metadata-annotate, html-main-content, " ~
    "pii-four-class, and terminal document-metadata-publish. No " ~
    "--stage/--filter overrides; use 'run' for custom composition. " ~
    "Automatically writes a document-metadata sidecar (annotated " ~
    "title/author/date/url plus the PII audit, in one blob) beside " ~
    "--output (see --output help); fails before touching anything if that " ~
    "derived path already exists."))
struct CleanWebDocument {
    @(NamedArgument("input", "i").Description("Input file or directory tree"))
    string input;
    @(NamedArgument("output", "o").Description(
        "Output path. Also fixes the automatic document-metadata sidecar " ~
        "path: '<output>.document-metadata.json' for a file, or " ~
        "'<output>.document-metadata/' (mirroring the input tree) for a " ~
        "directory. That derived path must not already exist."))
    string output;
    @(NamedArgument.Description("Worker thread count"))
    size_t threads;
    @(NamedArgument("max-queued-docs").Description("Maximum queued documents"))
    size_t maxQueuedDocs = 64;
    @(NamedArgument("max-input-bytes").Description("Maximum reserved input bytes"))
    ulong maxInputBytes = 256UL * 1024 * 1024;
    @(NamedArgument("max-open-inputs").Description("Maximum worker-held input descriptors"))
    size_t maxOpenInputs;
    @(NamedArgument("emit-config").Description(
        "Print the compiled canonical v3 job JSON for clean-web-document/v1 " ~
        "and exit 0; touches no input, output, or sidecar path (no " ~
        "filesystem or network mutation of any kind)."))
    bool emitConfig;
}

@(Command("crawl").Description(
    "Fetch, discover links, and save raw HTML with a concurrent, resumable " ~
    "frontier. Fetch + discover + save raw only: no mojibake repair, no " ~
    "metadata/main-content/PII stages. Use 'clean-web-document' as a " ~
    "separate later pass over the raw output."))
struct Crawl {
    @(NamedArgument("seeds").Description("Newline-delimited seed URL file (repeatable)"))
    string[] seeds;
    @(NamedArgument("seed").Description("Individual seed URL (repeatable)"))
    string[] seed;
    @(NamedArgument("corpus-dir").Description("Output directory for raw/, manifest.jsonl, and (unless --in-memory) frontier.sqlite3 (required)"))
    string corpusDir;
    @(NamedArgument("db").Description("SQLite frontier DB path (default: <corpus-dir>/frontier.sqlite3)"))
    string db;
    @(NamedArgument("in-memory").Description("Use a non-durable in-memory frontier instead of SQLite (explicit opt-out of resumability)"))
    bool inMemory;
    @(NamedArgument("max-pages").Description("Maximum distinct admitted pages (default 200)"))
    size_t maxPages = 200;
    @(NamedArgument("max-pages-per-host").Description("Maximum pages per host (default 50)"))
    size_t maxPagesPerHost = 50;
    @(NamedArgument("max-depth").Description("Maximum discovery depth from a seed (default 3)"))
    size_t maxDepth = 3;
    @(NamedArgument("concurrency").Description("Concurrent worker OS threads and max active frontier leases (default 4)"))
    size_t concurrency = 4;
    @(NamedArgument("min-host-delay-ms").Description("Minimum delay between requests to the same host, in ms (default 3000)"))
    long minHostDelayMs = 3000;
    @(NamedArgument("scope").Description("Discovery scope: allowed-domain (default), same-origin, or one-hop-external"))
    string discoveryScope = "allowed-domain";
    @(NamedArgument("allowed-origin").Description("Extra allowed/core origin for allowed-domain or one-hop-external scope (repeatable; default: seed origins)"))
    string[] allowedOrigin;
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
    SubCommand!(Run, Repair, Extract, Completion, ErrorsInit, ErrorsCopy,
        ErrorsExport, ErrorsVerify, RouteMetadata, CleanWebDocument, Crawl)
        command;
}

enum Config parserConfig = { errorExitCode: 2 };

/// True for a genuine top-level `--help`/`-h`, left to argparse's own
/// handling, or for any recognized subcommand name/alias. Every other
/// argument value here is dispatched earlier in `runCommands`, before this
/// helper is ever consulted; this covers only the remaining commands
/// (`run`/`clean`/`repair`/`fix`/`extract`/`x`) that fall through to
/// argparse's generic `SubCommand!` parse below.
private bool isKnownVerbToken(string token) {
    if (token == "--help" || token == "-h") return true;
    foreach (name; ["run", "clean", "repair", "fix", "extract", "x"])
        if (token == name) return true;
    return false;
}

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
    if (present(original, "--sidecar-output"))
        forwarded ~= "--sidecar-output=" ~ options.sidecarOutput;
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
    if (present(original, "--max-jsonl-sidecar-bytes"))
        forwarded ~= ["--max-jsonl-sidecar-bytes",
            options.maxJsonlSidecarBytes.to!string];
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

private int cleanWebDocumentError(string message) {
    stderr.writeln("scrubbed: ", message);
    stderr.writeln("scrubbed: clean-web-document is a sealed preset (no " ~
        "--stage/--filter/--stage-option/--filter-option overrides); use " ~
        "'run' for custom stage/filter composition.");
    stderr.writeln("Try 'scrubbed clean-web-document --help' for usage.");
    return 2;
}

private bool cleanWebDocumentKnownValueFlag(string flag) {
    foreach (candidate; ["--input", "-i", "--output", "-o", "--threads",
            "--max-queued-docs", "--max-input-bytes", "--max-open-inputs"])
        if (flag == candidate) return true;
    return false;
}

/// The automatic document-metadata sidecar path derived from `--output`.
/// #300 Slice 3: `pii-four-class` converged onto the shared `DocumentMetadata`
/// accumulator and is no longer its own terminal stage -- `clean-web-document`'s
/// chain now ends in the shared `document-metadata-publish` stage (see
/// `job.presets.cleanWebDocumentTokensV1`), so the derived sidecar now uses
/// that stage's own already-established convention instead of a
/// `pii-four-class`-specific one: a file output gets a sibling
/// `document_metadata_publish_stage.d`'s `documentMetadataPublishSuffixV1`
/// (`.document-metadata.json`) file; a directory (tree) output gets a
/// sibling `.document-metadata` directory (derived from that same stage's
/// `documentMetadataPublishKeyV1` identity, exactly as the prior
/// `.pii-audit` directory name was derived from `pii-four-class`'s own key)
/// that mirrors the input tree, exactly like a hand-written
/// `--sidecar-output` directory root would. The published blob now carries
/// both the annotated title/author/date/url metadata (previously silently
/// discarded -- the bug this slice fixes) and the PII audit together.
private string cleanWebDocumentSidecarPath(string output, bool inputIsDir) {
    return output ~ (inputIsDir ? "." ~ documentMetadataPublishKeyV1 :
        documentMetadataPublishSuffixV1);
}

private bool cleanWebDocumentPathOccupied(string path) {
    // `isSymlink` (unlike `exists`) throws `FileException` for a path that
    // simply does not exist yet -- the ordinary, expected case here.
    bool link;
    try link = isSymlink(path);
    catch (FileException failure) { if (exists(path)) throw failure; }
    return link || exists(path);
}

/// Real dispatch for the sealed `clean-web-document/v1` preset, called
/// before argparse ever sees `argv[2 .. $]` so every rejection below (a
/// sealed composition-flag attempt, an unknown/malformed option, or an
/// occupied derived sidecar path) happens before any I/O.
private int runCleanWebDocument(const string[] rawArgs) {
    string input;
    string output;
    string threadsText;
    string maxQueuedDocsText;
    string maxInputBytesText;
    string maxOpenInputsText;
    bool emitConfig;

    size_t index;
    while (index < rawArgs.length) {
        auto token = rawArgs[index];
        string flag = token;
        string value;
        bool hasInline;
        auto separator = token.indexOf('=');
        if (separator > 0) {
            flag = token[0 .. separator];
            value = token[separator + 1 .. $];
            hasInline = true;
        }
        if (compositionFlag(flag))
            return cleanWebDocumentError(
                "clean-web-document does not accept composition overrides (" ~
                flag ~ ")");
        if (flag == "--emit-config") {
            if (hasInline)
                return cleanWebDocumentError("--emit-config does not take a value");
            emitConfig = true;
            ++index;
            continue;
        }
        if (!cleanWebDocumentKnownValueFlag(flag))
            return cleanWebDocumentError("unknown clean-web-document option: " ~ flag);
        if (!hasInline) {
            if (index + 1 >= rawArgs.length)
                return cleanWebDocumentError("missing value for " ~ flag);
            value = rawArgs[++index];
        }
        if (flag == "--input" || flag == "-i") input = value;
        else if (flag == "--output" || flag == "-o") output = value;
        else if (flag == "--threads") threadsText = value;
        else if (flag == "--max-queued-docs") maxQueuedDocsText = value;
        else if (flag == "--max-input-bytes") maxInputBytesText = value;
        else if (flag == "--max-open-inputs") maxOpenInputsText = value;
        ++index;
    }

    if (emitConfig) {
        // Pure job-layer expansion plus the existing, unmodified
        // composition-layer compiler and job-layer canonical serializer
        // only. scripts/check_modules.d already forbids both the job and
        // composition layers from importing effects or any concrete I/O
        // module (std.file/std.stdio/std.socket/std.net/std.process), so
        // this whole branch is structurally incapable of reaching the
        // filesystem or network -- and, distinctly from that layering
        // proof, it also never references `input`, `output`, or any of the
        // sidecar path machinery below at all.
        auto spec = expandCleanWebDocumentPresetV1();
        cast(void) compileJob(spec);
        writeln(canonicalJobJson(spec));
        return 0;
    }

    if (!input.length || !output.length)
        return cleanWebDocumentError("clean-web-document requires --input and --output");

    const inputIsDir = exists(input) && isDir(input);
    auto sidecarPath = cleanWebDocumentSidecarPath(output, inputIsDir);
    if (cleanWebDocumentPathOccupied(sidecarPath))
        return cleanWebDocumentError(
            "derived document-metadata sidecar path already exists: " ~ sidecarPath ~
            " (clean-web-document writes it automatically beside --output " ~
            "and refuses to overwrite an unexpected existing path there; " ~
            "move it aside or choose a different --output, then retry)");

    string[] forwarded = ["scrubbed", "--input", input, "--output", output,
        "--sidecar-output", sidecarPath];
    if (threadsText.length) forwarded ~= ["--threads", threadsText];
    if (maxQueuedDocsText.length)
        forwarded ~= ["--max-queued-docs", maxQueuedDocsText];
    if (maxInputBytesText.length)
        forwarded ~= ["--max-input-bytes", maxInputBytesText];
    if (maxOpenInputsText.length)
        forwarded ~= ["--max-open-inputs", maxOpenInputsText];
    forwarded ~= cleanWebDocumentTokensV1;
    return runApp(forwarded);
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
    if (argv.length > 1 && argv[1] == "clean-web-document") {
        foreach (arg; argv[2 .. $])
            if (arg == "--help" || arg == "-h") {
                Commands help;
                auto result = CLI!(parserConfig, Commands).parseArgs(help,
                    [argv[1], "--help"]);
                return result.exitCode;
            }
        return runCleanWebDocument(argv[2 .. $]);
    }
    if (argv.length > 1 && argv[1] == "crawl") {
        foreach (arg; argv[2 .. $])
            if (arg == "--help" || arg == "-h") {
                Commands help;
                auto result = CLI!(parserConfig, Commands).parseArgs(help,
                    [argv[1], "--help"]);
                return result.exitCode;
            }
        return runCrawl(argv[2 .. $]);
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
    // Every other recognized subcommand token is dispatched above before
    // this point; only `run`/`clean`/`repair`/`fix`/`extract`/`x` (plus a
    // genuine top-level --help/-h, left to argparse's own handling just
    // below) reach here as valid. No token at all, or any other token --
    // including a bare informational/pipeline flag like `--input` or
    // `--list-filters` with no verb, or a misspelled/unknown verb -- means
    // there is no bare-no-verb pipeline-execution fallback anymore: print
    // real help (the same generated text `--help` prints) and fail loudly,
    // rather than silently no-op (bare `scrubbed`) or surface argparse's own
    // terse "Unrecognized arguments" message (bare `scrubbed --input ...`).
    if (argv.length < 2 || !isKnownVerbToken(argv[1])) {
        Commands help;
        cast(void) CLI!(parserConfig, Commands).parseArgs(help, ["--help"]);
        return 2;
    }
    Commands commands;
    const original = argv[1 .. $].dup;
    auto result = CLI!(parserConfig, Commands).parseArgs(commands, argv[1 .. $]);
    if (!result) return result.exitCode;
    return commands.command.matchCmd!((cmd) {
        static if (is(typeof(cmd) == Extract)) {
            if ((cmd.format != "tree-json" && cmd.format != "markdown" &&
                    cmd.format != "main-content-markdown") ||
                !cmd.input.length || !cmd.output.length) {
                stderr.writeln("scrubbed: extract requires --input, --output and " ~
                    "--format=tree-json|markdown|main-content-markdown");
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
            is(typeof(cmd) == ErrorsVerify) || is(typeof(cmd) == RouteMetadata) ||
            is(typeof(cmd) == CleanWebDocument) || is(typeof(cmd) == Crawl)) {
            assert(0, "management verbs dispatched before argparse");
            return 2;
        } else {
            return process(cmd, original);
        }
    });
}

version (unittest) {
    import std.algorithm : canFind;
    import std.file : mkdirRecurse, readText, remove, rmdirRecurse, tempDir,
        write;
    import std.path : buildPath;
    import std.stdio : File;
    import std.typecons : tuple;
    import std.uuid : randomUUID;

    private void tryRemove(string path) {
        if (!exists(path)) return;
        try remove(path);
        catch (Exception ignored) {}
    }

    /// Runs `runCommands(argv)` with stdout redirected to a temp file, and
    /// returns (exit code, captured stdout text) so a test can assert on
    /// both without depending on process-level output capture.
    private auto runCommandsCapturingStdout(string[] argv) {
        auto capturePath = buildPath(tempDir,
            "scrubbed-runcommands-capture-" ~ randomUUID.toString ~ ".txt");
        auto saved = stdout;
        scope(exit) {
            stdout = saved;
            tryRemove(capturePath);
        }
        stdout = File(capturePath, "w");
        auto exitCode = runCommands(argv);
        stdout.flush();
        stdout = saved;
        return tuple(exitCode, exists(capturePath) ? readText(capturePath) : "");
    }
}

// Issue #336: the bare no-verb pipeline-execution form (`Default!Run`) is
// gone. Zero arguments, and any first token that is not a recognized verb,
// must print real help+examples (not silently no-op, not argparse's terse
// "Unrecognized arguments" message) and exit 2.
unittest {
    auto zeroArgs = runCommandsCapturingStdout(["scrubbed"]);
    assert(zeroArgs[0] == 2, "zero-args must exit 2, not silently succeed");
    assert(zeroArgs[1].length > 0,
        "zero-args must print help, not stay silent");
    assert(zeroArgs[1].canFind("Available commands"),
        "zero-args help output must list the real subcommands");
    assert(zeroArgs[1].canFind("run,clean"),
        "zero-args help output must mention the run verb");
}

unittest {
    auto bareWithFlags = runCommandsCapturingStdout(["scrubbed", "--input",
        "in.txt", "--output", "out.txt"]);
    assert(bareWithFlags[0] == 2,
        "bare --input/--output with no verb must exit 2");
    assert(bareWithFlags[1].canFind("Available commands"),
        "bare --input/--output with no verb must print real help, not " ~
        "argparse's terse 'Unrecognized arguments' message");
}

unittest {
    auto unknownVerb = runCommandsCapturingStdout(["scrubbed", "bogus",
        "--input", "in.txt", "--output", "out.txt"]);
    assert(unknownVerb[0] == 2, "an unrecognized verb must exit 2");
    assert(unknownVerb[1].canFind("Available commands"),
        "an unrecognized verb must print real help");
}

// A genuine top-level --help/-h is a different, pre-existing code path and
// must remain completely unaffected: still exit 0.
unittest {
    auto help = runCommandsCapturingStdout(["scrubbed", "--help"]);
    assert(help[0] == 0, "--help must still exit 0");
    assert(help[1].canFind("Available commands"));

    auto shortHelp = runCommandsCapturingStdout(["scrubbed", "-h"]);
    assert(shortHelp[0] == 0, "-h must still exit 0");
}

// run/repair/clean/fix remain byte-identical to each other and completely
// unchanged by the Default! removal, once a verb is actually given.
unittest {
    auto root = buildPath(tempDir, "scrubbed-cli-commands-" ~
        randomUUID.toString);
    scope(exit) if (exists(root)) rmdirRecurse(root);
    mkdirRecurse(root);
    auto input = buildPath(root, "in.txt");
    write(input, "hello  world");

    foreach (verb; ["run", "clean", "repair", "fix"]) {
        auto output = buildPath(root, verb ~ "-out.txt");
        auto exitCode = runCommands(["scrubbed", verb, "--input", input,
            "--output", output]);
        assert(exitCode == 0, verb ~ " must still succeed");
        assert(exists(output), verb ~ " must still write its output");
        assert(readText(output) == readText(input),
            verb ~ " must still behave exactly as before");
    }

    // Still requires --input/--output once a real verb is named -- only the
    // bare/unrecognized-verb fallback changed.
    auto missingArgs = runCommandsCapturingStdout(["scrubbed", "run"]);
    assert(missingArgs[0] == 2);
}
