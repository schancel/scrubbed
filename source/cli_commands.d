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
import job.presets : cleanWebDocumentRunEquivalentV1, cleanWebDocumentTokensV1,
    expandCleanWebDocumentPresetV1;
import std.conv : to;
import std.file : FileException, exists, isDir, isSymlink, thisExePath;
import std.path : buildNormalizedPath;
import std.stdio : stderr, stdout, writeln;
import std.string : indexOf, startsWith, strip;

// #498: single-owned version source. `VERSION` at the repo root is the one
// place that owns the printed version string -- `dub.json` intentionally
// has no `"version"` field (see #499 for real tag/release wiring, out of
// scope here). `stringImportPaths: ["."]` in dub.json makes this
// compile-time `import()` expression pull the file's contents in as a
// string literal; `.strip` drops the trailing newline the checked-in file
// ends with. Before a real git tag exists this is a fixed placeholder/dev
// string, not a claim about what the shipped release version will be.
private immutable string scrubbedVersion = import("VERSION").strip;

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
    // #473: bound as `string`, not `size_t`/`ulong` -- a numeric type here
    // would let argparse's own automatic std.conv-based binding run first
    // and throw a raw, un-"scrubbed:"-prefixed Phobos exception on a
    // negative or overflowing value, before scrubbed's own validation (in
    // `cli.d`, reached via `process()` below) ever sees it. The raw text
    // is sanitized by `sanitizedNumericToken` just before forwarding.
    @(NamedArgument.Description("Worker thread count"))
    string threads;
    @(NamedArgument("max-queued-docs").Description("Maximum queued documents"))
    string maxQueuedDocs = "64";
    @(NamedArgument("max-input-bytes").Description("Maximum reserved input bytes"))
    string maxInputBytes = "268435456";
    @(NamedArgument("max-open-inputs").Description("Maximum worker-held input descriptors"))
    string maxOpenInputs;
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
    // #473: same rationale as `threads`/`maxQueuedDocs`/etc. above -- kept
    // as `string` so a negative/overflowing value reaches scrubbed's own
    // sanitization instead of Phobos's automatic conversion.
    @(NamedArgument("max-jsonl-line-bytes").Description("Maximum JSONL input record bytes"))
    string maxJsonlLineBytes;
    @(NamedArgument("max-jsonl-output-bytes").Description("Maximum JSONL output record bytes including LF"))
    string maxJsonlOutputBytes;
    @(NamedArgument("max-jsonl-sidecar-bytes").Description("Maximum aggregate terminal side-output JSONL bytes"))
    string maxJsonlSidecarBytes;
}

@(Command("run", "clean").Description("Run the bounded filter pipeline."))
struct Run {
    mixin ProcessingOptions;
}

@(Command("repair", "fix").Description("Repair text with the existing filter pipeline."))
struct Repair {
    mixin ProcessingOptions;
}

@(Command("extract", "x").Description("Export a bounded selected HTML parse tree, whole-page Markdown, boilerplate-stripped main-content Markdown, CSV, generic XML, or TEI-conformant XML."))
struct Extract {
    @(NamedArgument("input", "i").Description("Input path")) string input;
    @(NamedArgument("output", "o").Description("Output path")) string output;
    @(NamedArgument("format", "f").Description(
        "Extraction format (required): tree-json, markdown (whole page), " ~
        "main-content-markdown (boilerplate/nav/ad/footer stripped " ~
        "first, same selection as html-main-content/clean-web-document, " ~
        "then rendered as Markdown instead of plain text), csv (one " ~
        "metadata/content row, columns matching trafilatura's own " ~
        "--output-format csv), xml (generic structured XML of the " ~
        "selected main content), or xml-tei (TEI P5-conformant XML of " ~
        "the selected main content)"))
    string format;
    @(NamedArgument("charset").Description("Declared UTF-8/UTF-16LE/UTF-16BE charset"))
    string charset;
    // #473: `string`, not `ulong` -- see `ProcessingOptions.threads` above
    // for why; sanitized by `sanitizedNumericValue` before use below.
    @(NamedArgument("max-html-bytes").Description("Raw and decoded HTML byte limit (1..8388608; default 1048576)"))
    string maxHtmlBytes;
    @(NamedArgument("config").Description("Canonical JSON v3 job for the selected HTML stage"))
    string config;
}

// #563: this Description is built from `cleanWebDocumentRunEquivalentV1` --
// itself rendered from `cleanWebDocumentTokensV1`, the exact token list
// `expandCleanWebDocumentPresetV1`/`--emit-config` compiles -- rather than a
// separately hand-typed enumeration of the stage sequence, so `--help` can
// never drift out of sync with what the preset actually runs.
private enum string cleanWebDocumentHelpV1 =
    "Run the sealed clean-web-document/v1 preset. Equivalent to: " ~
    cleanWebDocumentRunEquivalentV1 ~ " (plus your own --input/--output, " ~
    "and optionally --threads/--max-queued-docs/--max-input-bytes/" ~
    "--max-open-inputs) -- generated from the same compiled stage-token " ~
    "list --emit-config prints, not hand-maintained prose. No " ~
    "--stage/--filter/--stage-option/--filter-option overrides accepted " ~
    "directly; use 'run' for custom composition. Automatically writes a " ~
    "document-metadata sidecar (annotated title/author/date/url plus the " ~
    "PII audit, in one blob) beside --output (see --output help); fails " ~
    "before touching anything if that derived path already exists.";

@(Command("clean-web-document").Description(cleanWebDocumentHelpV1))
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

// #498: documentation-only stand-in so argparse's own generated --help
// lists "version" under "Available commands", matching how every other
// management verb here (errors-init, route-metadata, clean-web-document,
// crawl, ...) is self-documenting through the same union. This must NOT be
// a `NamedArgument` field directly on `Commands`: argparse treats a field
// there as a "common"/global flag accepted anywhere in argv, including
// *after* a real subcommand's own token (e.g. `scrubbed run --version` would
// then be silently accepted and ignored instead of correctly erroring as an
// unrecognized argument -- confirmed empirically, this was caught and
// reverted in review). A `Command`-tagged struct in the `SubCommand!` union
// below, by contrast, is only ever matched as the single command-position
// token, so it carries no such risk -- but for that same reason (argparse
// statically rejects any subcommand name starting with its short-name
// prefix, "typetraits.d: Subcommand name should not begin with '-'") it
// cannot be spelled `--version` as a second alias here the way `run,clean`
// or `repair,fix` are; the flag spelling is documented in the description
// text below instead. The actual `scrubbed --version`/`scrubbed version`
// invocation is handled earlier in `runCommands`, in the same bare-flag
// dispatch spot that already special-cases `-h`/`--help`, before this
// struct is ever parsed -- this variant is never actually reached at
// runtime (see the `assert(0, "management verbs dispatched before
// argparse")` case below, shared with every other early-dispatched verb).
@(Command("version").Description("Print version and exit (same as --version)"))
struct Version {
}

@(Command("scrubbed").Description("Sanitize text through a bounded filter pipeline."))
struct Commands {
    SubCommand!(Run, Repair, Extract, Completion, ErrorsInit, ErrorsCopy,
        ErrorsExport, ErrorsVerify, RouteMetadata, CleanWebDocument, Crawl,
        Version)
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

// #473: every numeric CLI flag argparse used to bind directly to `ulong`/
// `size_t` (`--threads`, `--max-input-bytes`, `--max-queued-docs`,
// `--max-open-inputs`, `extract --max-html-bytes`, the
// `--max-jsonl-*-bytes` family) validated a clean, already-in-domain
// invalid value (e.g. `0`) with scrubbed's own message and exit 2, but a
// negative sign or an out-of-range magnitude made argparse's own
// std.conv-based conversion (`Convert!T` in argparse's parsefunc.d) throw
// *before* any of scrubbed's own validation ever ran, surfacing a raw,
// un-"scrubbed:"-prefixed Phobos parser error instead. `cli.d`'s own
// downstream `std.getopt` binding for these same fields has the identical
// exposure (confirmed empirically: it throws `std.conv.ConvException`,
// still reasonably worded but not in scrubbed's own per-flag style).
//
// Every one of these flags is bound in the structs above as a raw
// `string` instead, so argparse never attempts the conversion at all --
// it only captures the literal text. `sanitizedNumericValue`/
// `sanitizedNumericToken` then parse that text themselves, in a `try`
// scrubbed already controls. On a valid, in-range value the original text
// passes through unchanged (canonicalized to its parsed decimal form).
// On a negative sign, a non-numeric value, or a magnitude that overflows
// `ulong`, they resolve to the sentinel `0` instead of throwing -- and `0`
// is exactly the value every one of these flags' own pre-existing
// validators downstream (in `cli.d`'s `runApp`, and the `--max-html-bytes
// == 0` check just below in this file) already rejects with its own
// established `scrubbed: ...`-prefixed message and exit 2. This reuses
// that existing validation and wording verbatim instead of inventing new
// messages, and needs no change to `cli.d` at all: a negative/overflowing
// value degrades to the exact same "explicit 0" experience the acceptance
// criteria ask for.
private ulong sanitizedNumericValue(string raw) {
    if (!raw.length) return 0;
    try return raw.to!ulong;
    catch (Exception) return 0;
}

/// Same sentinel-on-invalid behavior as `sanitizedNumericValue`, but
/// returns the safe-to-forward decimal string form for building a
/// `forwarded` argv for `runApp` (which re-parses it with `std.getopt`).
/// An empty value (`--threads=`) also becomes `"0"`, matching argparse's
/// old `TYPE.init` behavior for an empty numeric value; forwarding `""`
/// would make getopt throw its own raw conversion error instead.
private string sanitizedNumericToken(string raw) {
    return sanitizedNumericValue(raw).to!string;
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
        forwarded ~= ["--max-queued-docs", sanitizedNumericToken(options.maxQueuedDocs)];
    if (present(original, "--max-input-bytes") || !present(original, "--jsonl-fields"))
        forwarded ~= ["--max-input-bytes", sanitizedNumericToken(options.maxInputBytes)];
    if (present(original, "--threads"))
        forwarded ~= ["--threads", sanitizedNumericToken(options.threads)];
    if (present(original, "--filters")) forwarded ~= ["--filters", options.filters];
    if (options.config.length) forwarded ~= "--config=" ~ options.config;
    forwardComposition(forwarded, original);
    if (present(original, "--max-open-inputs"))
        forwarded ~= ["--max-open-inputs", sanitizedNumericToken(options.maxOpenInputs)];
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
        forwarded ~= ["--max-jsonl-line-bytes", sanitizedNumericToken(options.maxJsonlLineBytes)];
    if (present(original, "--max-jsonl-output-bytes"))
        forwarded ~= ["--max-jsonl-output-bytes", sanitizedNumericToken(options.maxJsonlOutputBytes)];
    if (present(original, "--max-jsonl-sidecar-bytes"))
        forwarded ~= ["--max-jsonl-sidecar-bytes",
            sanitizedNumericToken(options.maxJsonlSidecarBytes)];
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
    // `output` reaches here exactly as the user typed it (a trailing
    // `/`/`\` is cosmetic and otherwise harmless everywhere else in this
    // CLI -- `cli.d`'s preflight checks all normalize through
    // `buildNormalizedPath(absolutePath(path))` before comparing paths).
    // This is the one place that instead concatenates onto `output`
    // directly, so a trailing separator silently changes the computed
    // sidecar path from a *sibling* of `output` (`clean.document-metadata`)
    // to a path *inside* it (`clean/.document-metadata`), which then
    // legitimately fails the overlap check downstream. Normalize away the
    // trailing separator (and any other cosmetic noise, e.g. a leading
    // `./`) before deriving the sidecar path so the result only ever
    // depends on the path's real identity, not its literal spelling.
    const normalized = buildNormalizedPath(output);
    return normalized ~ (inputIsDir ? "." ~ documentMetadataPublishKeyV1 :
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
    // #498: real `--version`/`version` top-level handling, in the same
    // bare-flag dispatch spot that already special-cases a genuine top-level
    // `-h`/`--help` (see `isKnownVerbToken` above) -- covers both the bare-
    // flag case (`scrubbed --version` with no other arguments) and staying
    // out of the way of the `run,clean`-alias-style generic argparse
    // dispatch just below for every other verb. Handled directly here
    // rather than left to argparse's generic `SubCommand!` parse: unlike
    // `-h`/`--help`, which argparse recognizes natively on any parser,
    // `--version` is scrubbed's own flag with no built-in argparse support,
    // so it must never fall through to the "unknown verb" branch just below
    // (which would print full help text and exit 2).
    if (argv.length > 1 && (argv[1] == "--version" || argv[1] == "version")) {
        writeln("scrubbed ", scrubbedVersion);
        return 0;
    }
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
                    cmd.format != "main-content-markdown" && cmd.format != "csv" &&
                    cmd.format != "xml" && cmd.format != "xml-tei") ||
                !cmd.input.length || !cmd.output.length) {
                stderr.writeln("scrubbed: extract requires --input, --output and " ~
                    "--format=tree-json|markdown|main-content-markdown|csv|xml|xml-tei");
                return 2;
            }
            // #473: a negative/overflowing --max-html-bytes sanitizes to
            // the same `0` sentinel an explicit `--max-html-bytes 0`
            // already produces, so it hits this exact pre-existing check.
            const maxHtmlBytes = sanitizedNumericValue(cmd.maxHtmlBytes);
            if (present(original, "--max-html-bytes") && maxHtmlBytes == 0) {
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
                maxHtmlBytes, cmd.config);
        } else static if (is(typeof(cmd) == Completion)) {
            stderr.writeln("scrubbed: use completion init or completion complete");
            return 2;
        } else static if (is(typeof(cmd) == ErrorsInit) ||
            is(typeof(cmd) == ErrorsCopy) || is(typeof(cmd) == ErrorsExport) ||
            is(typeof(cmd) == ErrorsVerify) || is(typeof(cmd) == RouteMetadata) ||
            is(typeof(cmd) == CleanWebDocument) || is(typeof(cmd) == Crawl) ||
            is(typeof(cmd) == Version)) {
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
    import std.path : buildPath, dirSeparator;
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

    /// Same as `runCommandsCapturingStdout`, but captures `stderr` instead
    /// -- every one of scrubbed's own diagnostics (including every
    /// `scrubbed: ...` message this file and `cli.d` print) goes there,
    /// not to stdout.
    private auto runCommandsCapturingStderr(string[] argv) {
        auto capturePath = buildPath(tempDir,
            "scrubbed-runcommands-stderr-capture-" ~ randomUUID.toString ~ ".txt");
        auto saved = stderr;
        scope(exit) {
            stderr = saved;
            tryRemove(capturePath);
        }
        stderr = File(capturePath, "w");
        auto exitCode = runCommands(argv);
        stderr.flush();
        stderr = saved;
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

// Issue #498: `scrubbed --version` (and `scrubbed version`) must print a
// non-empty version string and exit 0, exactly like `--help`/`-h`, and must
// never fall through to the general command-list usage text that a bare or
// unknown verb prints.
unittest {
    auto flagVersion = runCommandsCapturingStdout(["scrubbed", "--version"]);
    assert(flagVersion[0] == 0, "--version must exit 0");
    assert(flagVersion[1].length > 0, "--version must print a non-empty string");
    assert(flagVersion[1].startsWith("scrubbed "),
        "--version output must name scrubbed: " ~ flagVersion[1]);
    assert(!flagVersion[1].canFind("Available commands"),
        "--version must not fall through to the general command-list usage text");

    auto subcommandVersion = runCommandsCapturingStdout(["scrubbed", "version"]);
    assert(subcommandVersion[0] == 0, "version subcommand must exit 0");
    assert(subcommandVersion[1] == flagVersion[1],
        "version subcommand output must match --version exactly");

    // --version must also be discoverable from the generated --help text,
    // the same way -h/--help documents itself.
    auto help = runCommandsCapturingStdout(["scrubbed", "--help"]);
    assert(help[1].canFind("--version"),
        "--help output must document --version");
}

// Regression (caught in review of #498): the first implementation attempt
// documented `--version` as a plain `NamedArgument` field directly on the
// top-level `Commands` struct. argparse treats such a field as a
// "common"/global flag accepted anywhere in argv -- including *after* a
// real subcommand's own token -- so `scrubbed run --version ...` was
// silently accepted and the pipeline just ran, instead of erroring on the
// unrecognized argument the way it did before #498 and the way any other
// unknown flag still does. `--version` must remain scoped to genuinely
// being the top-level verb: appending it to a real subcommand's own argv
// must still be a hard, loud error, never a silent no-op flag.
unittest {
    foreach (argv; [["scrubbed", "run", "--version", "--input", "in.txt",
                "--output", "out.txt"],
            ["scrubbed", "extract", "--version", "--input", "in.txt",
                "--output", "out.txt", "--format", "markdown"],
            ["scrubbed", "repair", "--version", "--input", "in.txt",
                "--output", "out.txt"]]) {
        auto result = runCommandsCapturingStderr(argv);
        assert(result[0] == 2,
            "--version appended to a real subcommand must still exit 2: " ~
            argv[1]);
        assert(result[1].canFind("Unrecognized"),
            "--version appended to a real subcommand must still surface " ~
            "an unrecognized-argument error, not be silently swallowed: " ~
            argv[1] ~ " -> " ~ result[1]);
    }
}

// Issue #474: `extract --help` must not claim `--format` has a default --
// it is required (omitting it exits 2 with "extract requires ...
// --format=..."). The help must say so and must list every accepted format.
unittest {
    import std.array : split, join;
    auto help = runCommandsCapturingStdout(["scrubbed", "extract", "--help"]);
    assert(help[0] == 0, "extract --help must exit 0");
    // argparse wraps descriptions; collapse whitespace before matching.
    auto flat = help[1].split.join(" ");
    assert(flat.canFind("--format"), "extract --help must document --format");
    assert(!flat.canFind("(default)"),
        "extract --help must not claim --format has a default: " ~ flat);
    assert(flat.canFind("Extraction format (required)"),
        "extract --help must mark --format as required: " ~ flat);
    foreach (fmt; ["tree-json", "markdown", "main-content-markdown", "csv",
            "xml", "xml-tei"])
        assert(flat.canFind(fmt),
            "extract --help must list format " ~ fmt ~ ": " ~ flat);
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

// Issue #445: directory-mode `clean-web-document` used to hard-fail with
// exit 2 ("sidecar root overlaps input or primary output") whenever
// `--output` ended in a trailing separator -- exactly the shape of the
// directory-mode Quick Start example in README.md/docs/cli-commands.md
// (`--input pages/ --output clean/`). `cleanWebDocumentSidecarPath` derived
// the sidecar path by naive string concatenation onto `--output`, so
// `"clean/"` produced `"clean/.document-metadata"` (nested *inside* the
// output directory, a genuine overlap) instead of `"clean.document-metadata"`
// (a sibling of it, as with `"clean"`). Directory-mode `clean-web-document`
// must succeed identically regardless of a trailing separator on `--input`
// and/or `--output`, and the sidecar must always land as a sibling of the
// (separator-stripped) output directory, never nested inside it.
unittest {
    string articleHtml() {
        string sentence = "This is a real article sentence with enough " ~
            "words in it to clear html-main-content's extraction threshold. ";
        string body;
        foreach (_; 0 .. 15) body ~= sentence;
        return `<html><head><title>Trailing Slash Regression</title></head>` ~
            `<body><nav>Home About Contact</nav><article><h1>Trailing Slash ` ~
            `Regression</h1><p>` ~ body ~ `</p></article></body></html>`;
    }

    void runCase(string label, bool slashInput, bool slashOutput) {
        auto root = buildPath(tempDir, "scrubbed-cwd-445-" ~ label ~ "-" ~
            randomUUID.toString);
        scope(exit) if (exists(root)) rmdirRecurse(root);

        auto inputDir = buildPath(root, "pages");
        mkdirRecurse(inputDir);
        write(buildPath(inputDir, "article.html"), articleHtml());

        auto outputDir = buildPath(root, "clean");
        auto inputArg = slashInput ? inputDir ~ dirSeparator : inputDir;
        auto outputArg = slashOutput ? outputDir ~ dirSeparator : outputDir;

        auto exitCode = runCommands(["scrubbed", "clean-web-document",
            "--input", inputArg, "--output", outputArg, "--threads", "1"]);
        assert(exitCode == 0, label ~
            ": clean-web-document must succeed regardless of trailing " ~
            "separators on --input/--output (was exit " ~ exitCode.to!string ~
            ")");

        auto producedFile = buildPath(outputDir, "article.html");
        assert(exists(producedFile), label ~
            ": output directory must actually contain the processed document");

        auto sidecarRoot = outputDir ~ "." ~ documentMetadataPublishKeyV1;
        assert(exists(sidecarRoot) && isDir(sidecarRoot), label ~
            ": document-metadata sidecar must exist as a sibling of the " ~
            "output directory (" ~ sidecarRoot ~ ")");
        assert(!exists(buildPath(outputDir, "." ~ documentMetadataPublishKeyV1)),
            label ~ ": document-metadata sidecar must never be nested " ~
            "inside the output directory");
    }

    // The ticket's exact repro shape: only --output trailing-slashed.
    runCase("output-slash-only", false, true);
    // The ticket's "ideally also --input" ask: both trailing-slashed,
    // matching the literal README/docs Quick Start invocation verbatim.
    runCase("both-slash", true, true);
}

// Issue #563: `clean-web-document --help` shows its real equivalent
// `run --stage ...` composition (`cleanWebDocumentHelpV1`, built from
// `cleanWebDocumentRunEquivalentV1`), not hand-maintained prose. This is the
// acceptance criterion's real, end-to-end proof of that equivalence: the
// rendered invocation, actually split into argv tokens and run through the
// real top-level `run` command (not `expandCleanWebDocumentPresetV1`/the
// job layer directly -- this exercises the same argparse/CLI boundary a
// user copy-pasting the printed text would), must produce byte-identical
// primary output to running `clean-web-document` directly on the same
// input. If a future change to `cleanWebDocumentTokensV1` were not
// reflected in the rendered/help text (the exact drift this ticket exists
// to prevent), this test -- not just a snapshot of today's help string --
// would catch it, because it actually executes the rendered text.
unittest {
    import std.array : split;
    import std.file : read;

    auto root = buildPath(tempDir, "scrubbed-563-equivalence-" ~
        randomUUID.toString);
    scope(exit) if (exists(root)) rmdirRecurse(root);
    mkdirRecurse(root);

    string sentence = "This is a real article sentence with enough words " ~
        "in it to clear html-main-content's extraction threshold. ";
    string body;
    foreach (_; 0 .. 15) body ~= sentence;
    auto html = `<html><head><title>Equivalence Check</title></head>` ~
        `<body><nav>Home About Contact</nav><article><h1>Equivalence ` ~
        `Check</h1><p>` ~ body ~ `</p></article></body></html>`;

    auto input = buildPath(root, "doc.html");
    write(input, html);

    auto presetOutput = buildPath(root, "preset-out.html");
    auto presetExit = runCommands(["scrubbed", "clean-web-document",
        "--input", input, "--output", presetOutput, "--threads", "1"]);
    assert(presetExit == 0, "clean-web-document must succeed on the fixture");

    // Parse the actual rendered `--help` equivalence text back into argv
    // tokens -- not a re-import of `cleanWebDocumentTokensV1` -- so this
    // exercises what `--help` really prints, not just what generated it.
    auto renderedTokens = cleanWebDocumentHelpV1.split("Equivalent to: ")[1]
        .split(" (plus")[0].split(" ");
    assert(renderedTokens[0] == "run",
        "rendered equivalence text must start with 'run': " ~
        cleanWebDocumentHelpV1);
    auto composedTokens = renderedTokens[1 .. $];
    assert(composedTokens == cleanWebDocumentTokensV1,
        "tokens parsed back out of the rendered --help text must exactly " ~
        "match the real compiled preset tokens");

    auto composedOutput = buildPath(root, "composed-out.html");
    auto composedSidecar = buildPath(root, "composed-out.html.sidecar");
    auto composedExit = runCommands(["scrubbed", "run", "--input", input,
        "--output", composedOutput, "--sidecar-output", composedSidecar,
        "--threads", "1"] ~ composedTokens);
    assert(composedExit == 0,
        "a hand-composed run --stage invocation of the rendered tokens " ~
        "must succeed on the same fixture");

    assert(read(presetOutput) == read(composedOutput),
        "the rendered --stage composition, run via 'run --stage ...' with " ~
        "those exact tokens, must produce byte-identical output to " ~
        "running clean-web-document directly on the same input");
}

// Issue #473: negative and overflowing values for the numeric CLI flags
// argparse used to bind directly to `ulong`/`size_t` must reach scrubbed's
// own validation (and its own established message/exit-2 style), not a raw
// Phobos parser exception. First, the shared sanitization mechanism itself,
// in isolation, for both failure shapes on both integral widths it is used
// for.
unittest {
    // Valid input passes through (canonicalized to its parsed decimal form).
    assert(sanitizedNumericValue("42") == 42);
    assert(sanitizedNumericToken("42") == "42");
    assert(sanitizedNumericToken("007") == "7");
    // Empty inline value (`--threads=`) is the "0" sentinel too, exactly as
    // argparse's old `TYPE.init` binding produced -- forwarding "" would
    // leak std.getopt's raw conversion error instead.
    assert(sanitizedNumericValue("") == 0);
    assert(sanitizedNumericToken("") == "0");

    // Negative: the ticket's exact repro shape ("-1", "-5").
    assert(sanitizedNumericValue("-1") == 0);
    assert(sanitizedNumericToken("-1") == "0");
    assert(sanitizedNumericValue("-5") == 0);

    // Overflow: past ulong.max, and past size_t.max on a 32-bit target --
    // both are the ticket's second repro shape.
    assert(sanitizedNumericValue("99999999999999999999") == 0);
    assert(sanitizedNumericToken("99999999999999999999") == "0");

    // Garbage (neither a negative sign nor a magnitude, just not an
    // integer at all) degrades the same way -- it hit the identical raw
    // argparse `Convert!T` exception before this fix, for the same root
    // cause.
    assert(sanitizedNumericValue("abc") == 0);
}

// #473: `run --threads -1` and `run --threads <overflow>` -- the ticket's
// own headline repro -- must resolve to scrubbed's existing, already-tested
// "--threads must be positive" validator (`cli.d`, `runApp`) instead of
// argparse's raw `std.conv` exception. Exercised through `runCommands`
// (the actual argparse boundary the bug lives at), not `runApp` directly,
// so this proves the sanitization is actually wired into the CLI dispatch
// path and not just correct in isolation.
//
// `runApp`'s own validators still throw a plain `Exception` (unchanged by
// this fix -- `app.d`'s `main` is what adds the "scrubbed: " prefix before
// printing to the real process stderr, and that wrapping is untouched),
// so this asserts on `.msg` exactly like `cli.d`'s own existing
// "--threads must be at most" regression test does (see the #472 test
// above it in cli.d), rather than re-deriving `app.d`'s prefixing here.
unittest {
    import std.exception : collectException;

    auto root = buildPath(tempDir, "scrubbed-473-threads-" ~
        randomUUID.toString);
    scope(exit) if (exists(root)) rmdirRecurse(root);
    mkdirRecurse(root);
    auto input = buildPath(root, "in.txt");
    write(input, "hello");
    auto output = buildPath(root, "out.txt");

    auto negative = collectException!Exception(runCommands(["scrubbed",
        "run", "--input", input, "--output", output, "--threads", "-1"]));
    assert(negative !is null,
        "--threads -1 must reach scrubbed's own validator, not silently succeed");
    assert(negative.msg == "--threads must be positive",
        "--threads -1 must produce the exact existing 0-value message, got: " ~
        negative.msg);
    assert(!negative.msg.canFind("Unexpected") && !negative.msg.canFind("convert"),
        "--threads -1 must not leak argparse's raw std.conv wording, got: " ~
        negative.msg);

    auto overflow = collectException!Exception(runCommands(["scrubbed",
        "run", "--input", input, "--output", output, "--threads",
        "99999999999999999999"]));
    assert(overflow !is null,
        "an overflowing --threads must reach scrubbed's own validator, not silently succeed");
    assert(overflow.msg == "--threads must be positive",
        "an overflowing --threads must produce the exact existing 0-value message, got: " ~
        overflow.msg);
    assert(!overflow.msg.canFind("Overflow") && !overflow.msg.canFind("convert"),
        "an overflowing --threads must not leak argparse's raw std.conv wording, got: " ~
        overflow.msg);

    // Empty inline value: on base argparse bound `--threads=` to 0 and the
    // clean 0-value message fired; it must still, not std.getopt's raw
    // "Argument '' ... could not be converted" text.
    auto emptyInline = collectException!Exception(runCommands(["scrubbed",
        "run", "--input", input, "--output", output, "--threads="]));
    assert(emptyInline !is null);
    assert(emptyInline.msg == "--threads must be positive",
        "--threads= must produce the existing 0-value message, got: " ~
        emptyInline.msg);

    // #472 regression guard: a merely-oversized (but perfectly convertible)
    // value must still hit the *upper-bound* check, completely unaffected
    // by this fix -- confirms the sanitization only intercepts genuinely
    // malformed (negative/overflowing) text and passes any in-range-for-
    // the-type value through unchanged.
    auto oversized = collectException!Exception(runCommands(["scrubbed",
        "run", "--input", input, "--output", output, "--threads",
        "999999999"]));
    assert(oversized !is null);
    assert(oversized.msg.canFind("--threads must be at most "),
        "#472's upper-bound check must still fire after #473's fix, got: " ~
        oversized.msg);

    // The clean (in-range) case is completely unaffected.
    assert(runCommands(["scrubbed", "run", "--input", input, "--output",
        output, "--threads", "1"]) == 0);
}

// #473: `extract --max-html-bytes` is the representative flag whose
// validator lives directly in this file (`stderr.writeln` + `return 2`,
// no throw -- see the `Extract` branch of `runCommands` above), so this is
// exercised end-to-end through `runCommandsCapturingStderr`, asserting on
// the literal captured "scrubbed: ..." text and exit code exactly as a
// real invocation would print them -- the highest-fidelity check of the
// acceptance criteria's exact wording ("a `scrubbed: ...`-prefixed error
// and exit 2, not a raw Phobos exception").
unittest {
    auto negative = runCommandsCapturingStderr(["scrubbed", "extract",
        "--input", "in.html", "--output", "out.json", "--format", "tree-json",
        "--max-html-bytes", "-5"]);
    assert(negative[0] == 2, "negative --max-html-bytes must exit 2");
    assert(negative[1].canFind("scrubbed: --max-html-bytes must be between 1 and 8388608"),
        "negative --max-html-bytes must produce the exact existing 0-value " ~
        "message, got: " ~ negative[1]);

    auto overflow = runCommandsCapturingStderr(["scrubbed", "extract",
        "--input", "in.html", "--output", "out.json", "--format", "tree-json",
        "--max-html-bytes", "99999999999999999999"]);
    assert(overflow[0] == 2, "overflowing --max-html-bytes must exit 2");
    assert(overflow[1].canFind("scrubbed: --max-html-bytes must be between 1 and 8388608"),
        "overflowing --max-html-bytes must produce the exact existing " ~
        "0-value message, got: " ~ overflow[1]);

    // The existing 0-value and in-range behavior is completely unaffected.
    auto zero = runCommandsCapturingStderr(["scrubbed", "extract", "--input",
        "in.html", "--output", "out.json", "--format", "tree-json",
        "--max-html-bytes", "0"]);
    assert(zero[0] == 2);
    assert(zero[1].canFind("scrubbed: --max-html-bytes must be between 1 and 8388608"));
}

// #473: cheap additional coverage across the rest of the flag family,
// confirming the shared mechanism (not just --threads/--max-html-bytes)
// reaches scrubbed's own validators for both failure shapes.
unittest {
    import std.exception : collectException;

    auto root = buildPath(tempDir, "scrubbed-473-family-" ~
        randomUUID.toString);
    scope(exit) if (exists(root)) rmdirRecurse(root);
    mkdirRecurse(root);
    auto input = buildPath(root, "in.txt");
    write(input, "hello");
    auto output = buildPath(root, "out.txt");

    foreach (flag; ["--max-input-bytes", "--max-queued-docs", "--max-open-inputs"]) {
        auto negative = collectException!Exception(runCommands(["scrubbed",
            "run", "--input", input, "--output", output, "--threads", "1",
            flag, "-3"]));
        assert(negative !is null,
            flag ~ " -3 must reach scrubbed's own validator, not silently succeed");
        assert(negative.msg == "input limits must be positive",
            flag ~ " -3 must produce the exact existing 0-value message, got: " ~
            negative.msg);

        auto overflow = collectException!Exception(runCommands(["scrubbed",
            "run", "--input", input, "--output", output, "--threads", "1",
            flag, "99999999999999999999"]));
        assert(overflow !is null,
            flag ~ " overflow must reach scrubbed's own validator, not silently succeed");
        assert(overflow.msg == "input limits must be positive",
            flag ~ " overflow must produce the exact existing 0-value message, got: " ~
            overflow.msg);
    }
}
