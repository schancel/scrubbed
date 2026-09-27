/// Release-active, black-box proof for issue #240's `clean-web-document`
/// preset command. Runs the real compiled `scrubbed` executable as a
/// subprocess (path given as `args[1]`) plus a handful of pure in-process
/// checks against `job.presets`/`job.json`. Proves:
///
///   A. token-list/CLI/JSON equivalence (the preset's fixed token list
///      lowers to the same `JobSpec`/canonical JSON a hand-written
///      `run --stage ...` invocation of the same four stages would),
///   B. `--emit-config` performs no filesystem mutation at all and is
///      byte-stable/deterministic across repeated invocations,
///   C. every sealed composition-flag attempt and unknown/malformed option
///      fails before any I/O, with an error naming `run` as the escape
///      hatch,
///   D. real execution through `clean-web-document` produces byte-identical
///      primary output and PII-audit sidecar bytes to the equivalent
///      hand-written `run --stage ...` invocation of the same four stages,
///   E. the automatically derived PII-audit sidecar path never silently
///      clobbers a pre-existing file or directory there -- it fails closed,
///      before any I/O, leaving the pre-existing content untouched and the
///      primary output never created.
module experiments.clean_web_document_preset.check;

import job.json : canonicalJobJson;
import job.presets : cleanWebDocumentTokensV1, expandCleanWebDocumentPresetV1;
import std.algorithm.searching : canFind;
import std.file : SpanMode, dirEntries, exists, mkdir, mkdirRecurse,
    read, readText, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.process : execute;
import std.uuid : randomUUID;

private int failures;

/// Not `assert`: this checker builds with LDC `-O3 -release`, which elides
/// the `assert` language construct. Every check here is a plain runtime
/// comparison so nothing this proof depends on can be compiled away.
private void expect(bool condition, string label) {
    if (condition) {
        import std.stdio : writeln;
        writeln("ok   ", label);
    } else {
        import std.stdio : writeln;
        writeln("FAIL ", label);
        ++failures;
    }
}

private struct Run {
    int status;
    string output;
    string error;
}

private Run run(string[] command) {
    auto result = execute(command);
    // std.process.execute merges stdout/stderr by default; re-run split
    // only when a check needs the streams kept apart.
    return Run(result.status, result.output, "");
}

private Run runSplit(string[] command) {
    import std.process : Redirect, pipeProcess, wait;
    auto pipes = pipeProcess(command, Redirect.stdout | Redirect.stderr);
    Run result;
    foreach (chunk; pipes.stdout.byLine) result.output ~= chunk ~ "\n";
    foreach (chunk; pipes.stderr.byLine) result.error ~= chunk ~ "\n";
    result.status = pipes.pid.wait();
    return result;
}

private string freshRoot(string label) {
    auto root = buildPath(tempDir, "scrubbed-cwd-preset-" ~ label ~ "-" ~
        randomUUID.toString);
    mkdirRecurse(root);
    return root;
}

// Same shape as experiments/document_metadata_integration/check.d's proof-D
// fixture: mojibake in title/author/body, a nav boilerplate block
// html-main-content must exclude, enough repeated sentences for confident
// main-content selection, and an email address for pii-four-class to find.
private string articleHtml() {
    string sentence = `SchÃ¶n weather today. `;
    string body;
    foreach (_; 0 .. 15) body ~= sentence;
    body ~= `Contact alice@example.com for details.`;
    return `<html><head><title>CafÃ© Culture</title>` ~
        `<meta name="author" content="RenÃ© GarcÃ­a"></head>` ~
        `<body><nav>Home About Contact</nav><article><p>` ~ body ~
        `</p></article></body></html>`;
}

/// Proof A: the preset's fixed token list is exactly what a hand-written
/// `run --stage ...` invocation of the real four-stage chain would be, and
/// `clean-web-document --emit-config`'s stdout is exactly the same
/// canonical JSON the pure `job.presets`/`job.json` layers compute
/// in-process -- proving the CLI surface is wired to the real model, not a
/// separate parallel implementation.
private void proveTokenCliJsonEquivalence(string exe) {
    auto spec = expandCleanWebDocumentPresetV1();
    auto expectedJson = canonicalJobJson(spec);
    expect(expectedJson.length != 0, "proof A: preset expands to nonempty canonical JSON");

    auto emitted = run([exe, "clean-web-document", "--emit-config"]);
    expect(emitted.status == 0, "proof A: --emit-config exits 0");
    expect(emitted.output == expectedJson ~ "\n" ||
        emitted.output == expectedJson,
        "proof A: --emit-config stdout equals in-process canonicalJobJson(expandCleanWebDocumentPresetV1())");
}

/// Proof B: `--emit-config` performs zero filesystem mutation (empirically,
/// against nonexistent paths and a freshly snapshotted directory -- the
/// structural, import-boundary half of this proof lives in
/// scripts/check_modules.d's existing job/composition-layer no-I/O rule,
/// confirmed separately) and is byte-stable/deterministic.
private void proveEmitConfigNoMutation(string exe) {
    auto root = freshRoot("emit-config");
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto missingInput = buildPath(root, "does-not-exist-input.html");
    auto missingOutput = buildPath(root, "does-not-exist-output.txt");

    string[] before;
    foreach (entry; dirEntries(root, SpanMode.breadth)) before ~= entry.name;

    auto first = run([exe, "clean-web-document", "--input", missingInput,
        "--output", missingOutput, "--emit-config"]);
    auto second = run([exe, "clean-web-document", "--input", missingInput,
        "--output", missingOutput, "--emit-config"]);
    auto bare = run([exe, "clean-web-document", "--emit-config"]);

    expect(first.status == 0, "proof B: --emit-config with nonexistent paths still exits 0");
    expect(first.output == second.output,
        "proof B: --emit-config stdout is byte-stable across repeated invocations");
    expect(first.output == bare.output,
        "proof B: --emit-config output does not depend on --input/--output at all");

    string[] after;
    foreach (entry; dirEntries(root, SpanMode.breadth)) after ~= entry.name;
    expect(before == after,
        "proof B: --emit-config created no file or directory anywhere (directory snapshot unchanged)");
    expect(!exists(missingInput), "proof B: --emit-config never created the input path");
    expect(!exists(missingOutput), "proof B: --emit-config never created the output path");
    expect(!exists(missingOutput ~ ".pii-audit.json"),
        "proof B: --emit-config never created the derived sidecar path");
}

/// Proof C: every sealed composition-flag attempt and every unknown or
/// malformed preset option fails before any I/O, with a clear message
/// naming `run` as the escape hatch. Uses nonexistent input/output paths so
/// any accidental I/O would be directly observable as a created path.
private void proveSealedRejectionBeforeIo(string exe) {
    auto root = freshRoot("sealed-rejection");
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto missingInput = buildPath(root, "in.html");
    auto missingOutput = buildPath(root, "out.txt");

    string[][] compositionAttempts = [
        ["--stage", "extra=text-transform"],
        ["--filter", "fix-mojibake"],
        ["--stage-option", "x=text:y"],
        ["--filter-option", "x=text:y"],
        ["--dispatch-option", "x=text:y"],
        ["--route", "x=y"],
        ["--route-option", "x=text:y"],
        ["--action", "x=y:z"],
        ["--common"],
    ];
    foreach (extra; compositionAttempts) {
        auto result = runSplit([exe, "clean-web-document", "--input",
            missingInput, "--output", missingOutput] ~ extra);
        expect(result.status == 2,
            "proof C: composition attempt " ~ extra[0] ~ " exits 2");
        expect(result.error.canFind("run"),
            "proof C: composition attempt " ~ extra[0] ~ " error names run as the escape hatch");
        expect(!exists(missingInput) && !exists(missingOutput),
            "proof C: composition attempt " ~ extra[0] ~ " touched no path");
    }

    string[][] malformedAttempts = [
        ["--config", "somewhere.json"],
        ["--filters", "fix-mojibake"],
        ["--emit-config=true"],
        ["--bogus-option", "value"],
    ];
    foreach (extra; malformedAttempts) {
        auto result = runSplit([exe, "clean-web-document", "--input",
            missingInput, "--output", missingOutput] ~ extra);
        expect(result.status == 2,
            "proof C: malformed/unknown option " ~ extra[0] ~ " exits 2");
        expect(result.error.canFind("run"),
            "proof C: malformed/unknown option " ~ extra[0] ~ " error names run as the escape hatch");
        expect(!exists(missingInput) && !exists(missingOutput),
            "proof C: malformed/unknown option " ~ extra[0] ~ " touched no path");
    }

    // Missing --input/--output entirely: still a clean, pre-I/O rejection.
    auto missingBoth = runSplit([exe, "clean-web-document"]);
    expect(missingBoth.status == 2, "proof C: missing --input/--output exits 2");
    expect(missingBoth.error.canFind("run"),
        "proof C: missing --input/--output error also names run");
}

/// Proof D: real execution through `clean-web-document` produces
/// byte-identical primary output AND PII-audit sidecar bytes to the
/// equivalent hand-written `run --stage id=text-transform=text-transform
/// --filter fix-mojibake --stage id=html-metadata-annotate=... --stage
/// id=html-main-content=... --stage id=pii-four-class=...` invocation of
/// the same four stages against the same input file.
private void proveByteIdenticalRealExecution(string exe) {
    auto root = freshRoot("byte-identical");
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto input = buildPath(root, "article.html");
    write(input, articleHtml());

    auto presetOutput = buildPath(root, "preset-out.txt");
    auto presetResult = runSplit([exe, "clean-web-document", "--input",
        input, "--output", presetOutput, "--threads", "1"]);
    expect(presetResult.status == 0, "proof D: clean-web-document real execution exits 0");
    auto presetSidecar = presetOutput ~ ".pii-audit.json";
    expect(exists(presetOutput), "proof D: clean-web-document wrote its primary output");
    expect(exists(presetSidecar), "proof D: clean-web-document wrote its derived sidecar");

    auto handOutput = buildPath(root, "hand-out.txt");
    auto handSidecar = buildPath(root, "hand-side.json");
    auto handTokens = cleanWebDocumentTokensV1.dup;
    auto handResult = runSplit([exe, "run", "--input", input, "--output",
        handOutput, "--sidecar-output", handSidecar, "--threads", "1"] ~
        handTokens);
    expect(handResult.status == 0, "proof D: hand-written run invocation exits 0");
    expect(exists(handOutput), "proof D: hand-written run wrote its primary output");
    expect(exists(handSidecar), "proof D: hand-written run wrote its sidecar");

    expect(cast(ubyte[]) read(presetOutput) == cast(ubyte[]) read(handOutput),
        "proof D: primary output bytes are byte-identical between the preset and the hand-written run invocation");
    expect(cast(ubyte[]) read(presetSidecar) == cast(ubyte[]) read(handSidecar),
        "proof D: PII-audit sidecar bytes are byte-identical between the preset and the hand-written run invocation");

    // The printed job identity line (derived from the compiled JobSpec) is
    // also byte-identical, since both invocations compile the exact same
    // four-stage v3 job.
    auto presetJobLine = presetResult.output.canFind("job: job:v3:");
    auto handJobLine = handResult.output.canFind("job: job:v3:");
    expect(presetJobLine && handJobLine, "proof D: both invocations print a v3 job identity line");
    expect(presetResult.output == handResult.output,
        "proof D: full stdout (job identity + done-count line) is byte-identical between the preset and the hand-written run invocation");
}

/// Proof E: the automatically derived PII-audit sidecar path never silently
/// clobbers a pre-existing file or directory -- both for a file `--output`
/// and for a directory (tree) `--output`.
private void proveDerivedSidecarSafety(string exe) {
    // File-output case.
    {
        auto root = freshRoot("sidecar-safety-file");
        scope(exit) if (exists(root)) rmdirRecurse(root);
        auto input = buildPath(root, "article.html");
        write(input, articleHtml());
        auto output = buildPath(root, "out.txt");
        auto sidecar = output ~ ".pii-audit.json";
        enum sentinel = "PRE-EXISTING UNRELATED CONTENT, MUST SURVIVE";
        write(sidecar, sentinel);

        auto result = runSplit([exe, "clean-web-document", "--input", input,
            "--output", output, "--threads", "1"]);
        expect(result.status == 2,
            "proof E (file): pre-existing derived sidecar fails closed with exit 2");
        expect(result.error.canFind(sidecar),
            "proof E (file): error names the occupied derived sidecar path");
        expect(readText(sidecar) == sentinel,
            "proof E (file): pre-existing sidecar content is byte-for-byte untouched");
        expect(!exists(output),
            "proof E (file): primary output was never created -- failure happened before any mutation");
    }

    // Directory (tree) output case.
    {
        auto root = freshRoot("sidecar-safety-tree");
        scope(exit) if (exists(root)) rmdirRecurse(root);
        auto inputDir = buildPath(root, "in");
        mkdir(inputDir);
        write(buildPath(inputDir, "article.html"), articleHtml());
        auto outputDir = buildPath(root, "out");
        auto sidecarRoot = outputDir ~ ".pii-audit";
        mkdir(sidecarRoot);
        enum sentinelName = "unrelated-preexisting-file.txt";
        enum sentinel = "PRE-EXISTING UNRELATED TREE CONTENT, MUST SURVIVE";
        write(buildPath(sidecarRoot, sentinelName), sentinel);

        auto result = runSplit([exe, "clean-web-document", "--input",
            inputDir, "--output", outputDir, "--threads", "1"]);
        expect(result.status == 2,
            "proof E (tree): pre-existing derived sidecar directory fails closed with exit 2");
        expect(result.error.canFind(sidecarRoot),
            "proof E (tree): error names the occupied derived sidecar directory");
        expect(readText(buildPath(sidecarRoot, sentinelName)) == sentinel,
            "proof E (tree): pre-existing file inside the sidecar directory is untouched");
        expect(!exists(outputDir),
            "proof E (tree): primary output directory was never created -- failure happened before any mutation");
    }

    // Control: with no pre-existing sidecar, the derived path is used and
    // populated exactly as documented (differentiates "fails only when
    // occupied" from "always fails").
    {
        auto root = freshRoot("sidecar-safety-control");
        scope(exit) if (exists(root)) rmdirRecurse(root);
        auto input = buildPath(root, "article.html");
        write(input, articleHtml());
        auto output = buildPath(root, "out.txt");
        auto sidecar = output ~ ".pii-audit.json";

        auto result = runSplit([exe, "clean-web-document", "--input", input,
            "--output", output, "--threads", "1"]);
        expect(result.status == 0,
            "proof E (control): clean-web-document succeeds when the derived sidecar path is free");
        expect(exists(output), "proof E (control): primary output was created");
        expect(exists(sidecar), "proof E (control): derived sidecar was created at the documented path");
        expect(readText(sidecar).canFind("scrubbed-pii-audit-v1"),
            "proof E (control): derived sidecar actually holds a real PII-audit record");
    }
}

void main(string[] args) {
    assert(args.length == 2, "usage: clean-web-document-preset-check <scrubbed executable>");
    auto exe = args[1];

    proveTokenCliJsonEquivalence(exe);
    proveEmitConfigNoMutation(exe);
    proveSealedRejectionBeforeIo(exe);
    proveByteIdenticalRealExecution(exe);
    proveDerivedSidecarSafety(exe);

    auto topHelp = run([exe, "--help"]);
    expect(topHelp.status == 0 && topHelp.output.canFind("clean-web-document"),
        "root --help lists clean-web-document");
    auto commandHelp = run([exe, "clean-web-document", "--help"]);
    expect(commandHelp.status == 0, "clean-web-document --help exits 0");
    expect(commandHelp.output.canFind("pii-audit") &&
        commandHelp.output.canFind("already exist"),
        "clean-web-document --help plainly documents the automatic sidecar file and its fail-closed behavior");
    expect(commandHelp.output.canFind("emit-config"),
        "clean-web-document --help documents --emit-config");

    import std.stdio : writeln;
    if (failures) {
        writeln(failures, " check(s) failed");
        import core.stdc.stdlib : exit;
        exit(1);
    }
    writeln("all clean-web-document preset checks passed");
}
