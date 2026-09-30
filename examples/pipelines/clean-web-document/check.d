/// Release-active actual-binary check for the `clean-web-document` flagship
/// example (issue #503). Mirrors `examples/pipelines/quickstart/check.d`'s
/// pattern: validate the manifest and its required negative mutants, then
/// exercise the real shipping binary from a clean temporary directory (never
/// the dev tree) and byte-diff its real output/sidecar bytes against pinned
/// expected files.
///
/// One structural difference from quickstart's own checker: `clean-web-
/// document`'s sidecar embeds `DocumentId`, a SHA-256 of (among other
/// inputs) the *resolved absolute filesystem path* passed as `--input`
/// (`domain.document.DocumentId.from` via `cli.d`'s `resolveExistingPrefix`
/// -> `SourceLocator("local-files:v1", inputRoot, relative)`). That path is
/// different on every machine and every run (this checker's own temp root is
/// freshly randomized), so the raw `documentId` bytes a fresh run produces
/// can never equal a value pinned once at golden-generation time -- pinning
/// them verbatim would make this checker fail everywhere except the exact
/// machine/run that generated the golden files. `normalizeDocumentId` below
/// replaces the one real occurrence of the document's own `documentId`
/// (verbatim in the `"documentId":"doc:v1:...` field, and again hex-encoded
/// inside the embedded PII-audit structured-section payload, which restates
/// it as its own `"document_id"` field) with a fixed, fixed-length
/// placeholder before every sidecar byte-comparison, on both the live output
/// and the checked-in golden. Every other field -- annotated title/author/
/// date/url, the PII audit's categories/rules/offsets/outcome, and the
/// content-derived `input_revision_sha256`/`output_sha256` hashes -- is
/// fully deterministic and is compared byte-for-byte with no normalization.
module clean_web_document_check;

import std.algorithm : equal, filter, reverse, sort;
import std.algorithm.searching : canFind;
import std.array : array, replace, replicate;
import std.conv : to;
import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;
import std.file : SpanMode, copy, dirEntries, exists, getSize, isFile, mkdirRecurse,
    read, readText, remove, rmdirRecurse, tempDir, write;
import std.json : JSONValue, parseJSON;
import std.path : absolutePath, buildPath, dirName, isAbsolute, relativePath;
import std.process : execute;
import std.string : indexOf, split, startsWith;
import std.uuid : randomUUID;

private enum artifactPrefixes = [
    "examples/corpus/clean-web-document/inputs/",
    "examples/corpus/clean-web-document/expected/"
];
private enum provenanceAuthored =
    "Authored for scrubbed issue #503 by Shammah Chancellor.";
private enum provenanceGeneratedPrefix =
    "Generated from the authored issue #503 input by the shipping scrubbed binary";

/// Fixed-length (71-byte) placeholder standing in for any real `doc:v1:`
/// document identity in a sidecar comparison. See the module doc comment.
private enum string documentIdPlaceholder =
    "doc:v1:0000000000000000000000000000000000000000000000000000000000000000";
static assert(documentIdPlaceholder.length == 71);

private struct Captured {
    int status;
    string output;
    string error;
}

private void need(bool condition, string label) {
    if (!condition) throw new Exception("clean-web-document check: " ~ label);
}

private string digest(string path) {
    return toHexString!(LetterCase.lower)(sha256Of(read(path))).idup;
}

private string[] strings(JSONValue value) {
    string[] result;
    foreach (entry; value.array) result ~= entry.str;
    return result;
}

private bool safeRepositoryPath(string path, string[] prefixes) {
    if (path.length == 0 || isAbsolute(path) || path.canFind('\\')) return false;
    foreach (part; path.split("/"))
        if (part.length == 0 || part == "." || part == "..") return false;
    foreach (prefix; prefixes)
        if (path.startsWith(prefix)) return true;
    return false;
}

private string[] filesBelow(string root, string relativeRoot) {
    string[] result;
    auto directory = buildPath(root, relativeRoot);
    foreach (entry; dirEntries(directory, SpanMode.depth)) {
        if (entry.isFile) {
            auto local = relativePath(entry.name, directory);
            result ~= relativeRoot.length ? relativeRoot ~ "/" ~ local : local;
        }
    }
    result.sort;
    return result;
}

// ---------------------------------------------------------------------------
// DocumentId normalization (see module doc comment).
// ---------------------------------------------------------------------------

private ptrdiff_t indexOfBytes(const(ubyte)[] haystack, const(ubyte)[] needle) {
    if (needle.length == 0 || needle.length > haystack.length) return -1;
    foreach (i; 0 .. haystack.length - needle.length + 1)
        if (haystack[i .. i + needle.length] == needle) return cast(ptrdiff_t) i;
    return -1;
}

/// Replace the sidecar's own real `documentId` (both its verbatim occurrence
/// in the `"documentId":"..."` field and its hex-encoded restatement inside
/// the embedded PII-audit payload's own `"document_id"` field) with a fixed
/// placeholder of the identical length, so the remaining bytes -- which
/// carry all of the sidecar's real information -- can be compared exactly
/// against a checked-in golden file that was normalized the same way.
private immutable(ubyte)[] normalizeDocumentId(const(ubyte)[] sidecar) {
    enum prefix = cast(immutable(ubyte)[]) `"documentId":"`;
    auto start = indexOfBytes(sidecar, prefix);
    need(start >= 0, "sidecar missing documentId field");
    start += cast(ptrdiff_t) prefix.length;
    auto end = start;
    while (end < cast(ptrdiff_t) sidecar.length && sidecar[end] != '"') ++end;
    need(end < cast(ptrdiff_t) sidecar.length, "sidecar documentId field unterminated");
    auto documentId = sidecar[start .. end].idup;
    need(documentId.length == documentIdPlaceholder.length &&
        documentId[0 .. 7] == cast(immutable(ubyte)[]) "doc:v1:",
        "sidecar documentId shape changed (clean-web-document never splits, " ~
        "so every document keeps its own source-level doc:v1: identity)");
    const(ubyte)[] documentIdBytes = documentId;
    const(ubyte)[] placeholderBytes = cast(const(ubyte)[]) documentIdPlaceholder.dup;
    auto hexOfDocumentId = toHexString!(LetterCase.lower)(documentIdBytes).idup;
    auto hexOfPlaceholder = toHexString!(LetterCase.lower)(placeholderBytes).idup;
    auto text = cast(string) sidecar.idup;
    text = text.replace(cast(string) documentId, documentIdPlaceholder);
    text = text.replace(hexOfDocumentId, hexOfPlaceholder);
    return cast(immutable(ubyte)[]) text;
}

private immutable(ubyte)[] normalizedSidecarBytes(string path) {
    return normalizeDocumentId(cast(immutable(ubyte)[]) read(path));
}

// ---------------------------------------------------------------------------
// Manifest validation.
// ---------------------------------------------------------------------------

private void validateManifest(string repository, JSONValue manifest) {
    need(manifest["schema"].str == "scrubbed.clean-web-document-corpus.v1",
        "manifest schema");
    auto licensePath = manifest["licenseFile"].str;
    need(licensePath == "examples/corpus/clean-web-document/LICENSE.txt" &&
        digest(buildPath(repository, licensePath)) ==
            "d05e83eb1213daac7371eee9bb40c8d06e767e37dc38f6f10b8f0b06d72708e0",
        "exact corpus license");
    need(manifest["claims"]["mainContentExtraction"].boolean &&
        manifest["claims"]["piiDetection"].boolean &&
        !manifest["claims"]["trainingReady"].boolean &&
        !manifest["claims"]["generalPurposeAnonymization"].boolean,
        "clean-web-document does perform main-content extraction and PII " ~
        "detection, but is not a training-ready corpus and is not a " ~
        "general-purpose anonymization tool (default policy is report, not redact)");
    need(manifest["sidecarDocumentIdPlaceholder"].str == documentIdPlaceholder,
        "stale documentId placeholder");

    auto expectedConfigs = [
        "examples/pipelines/clean-web-document/clean-web-document.json":
            "dcbc0308272a136cfe6e0180f3c4d77b254bc5be5815cee8ab0b45613fb02405"
    ];
    need(manifest["configurations"].array.length == expectedConfigs.length,
        "configuration count");
    foreach (configuration; manifest["configurations"].array) {
        auto path = configuration["path"].str;
        need((path in expectedConfigs) !is null &&
            configuration["sha256"].str == expectedConfigs[path] &&
            digest(buildPath(repository, path)) == expectedConfigs[path],
            "canonical configuration " ~ path);
    }

    string[] declared;
    foreach (artifact; manifest["artifacts"].array) {
        auto path = artifact["path"].str;
        need(safeRepositoryPath(path, artifactPrefixes), "artifact path escape: " ~ path);
        need(artifact["mediaType"].str.length != 0, "missing media type: " ~ path);
        need(artifact["provenance"].str == provenanceAuthored ||
            artifact["provenance"].str.startsWith(provenanceGeneratedPrefix),
            "missing attribution/provenance: " ~ path);
        need(artifact["license"].str == "MIT", "missing artifact license: " ~ path);
        need(artifact["intendedPipeline"].str.length != 0 &&
            artifact["expectedOutcome"].str.length != 0,
            "missing pipeline/outcome: " ~ path);
        need(isFile(buildPath(repository, path)) &&
            digest(buildPath(repository, path)) == artifact["sha256"].str,
            "artifact hash drift: " ~ path);
        declared ~= path;
    }
    declared.sort;
    auto actual = filesBelow(repository, "examples/corpus/clean-web-document/inputs") ~
        filesBelow(repository, "examples/corpus/clean-web-document/expected");
    actual.sort;
    need(declared.equal(actual), "undeclared or missing corpus artifact");

    auto recipes = manifest["recipes"].array;
    need(recipes.length == 3, "recipe count");
    auto cliShape = ["clean-web-document", "--input", "${INPUT}", "--output", "${OUTPUT}"];
    auto configShape = ["run", "--input", "${INPUT}", "--output", "${OUTPUT}",
        "--sidecar-output", "${SIDECAR}", "--config", "${CONFIG}"];
    need(recipes[0]["id"].str == "clean-web-document-single-file" &&
        recipes[0]["expectedExit"].integer == 0 &&
        strings(recipes[0]["cliArguments"]).equal(cliShape) &&
        strings(recipes[0]["configArguments"]).equal(configShape),
        "stale single-file recipe");
    need(recipes[1]["id"].str == "clean-web-document-directory-tree" &&
        recipes[1]["expectedExit"].integer == 0 &&
        strings(recipes[1]["cliArguments"]).equal(cliShape) &&
        strings(recipes[1]["configArguments"]).equal(configShape),
        "stale directory-tree recipe");
    need(recipes[2]["id"].str == "clean-web-document-sidecar-occupied" &&
        recipes[2]["expectedExit"].integer == 2 &&
        strings(recipes[2]["cliArguments"]).equal(cliShape),
        "stale sidecar-occupied recipe");

    ulong corpusBytes;
    foreach (entry; dirEntries(buildPath(repository, "examples/corpus/clean-web-document"),
            SpanMode.depth))
        if (entry.isFile) corpusBytes += getSize(entry.name);
    need(corpusBytes < 1024 * 1024, "corpus must remain below 1 MiB");
}

private void expectRejected(string label, void delegate() mutation) {
    bool rejected;
    try mutation();
    catch (Exception) rejected = true;
    need(rejected, "negative mutant accepted: " ~ label);
}

private void copyTree(string source, string destination) {
    auto entries = dirEntries(source, SpanMode.depth)
        .filter!(entry => entry.isFile).array;
    entries.sort!((a, b) => a.name < b.name);
    foreach (entry; entries) {
        auto target = buildPath(destination, relativePath(entry.name, source));
        mkdirRecurse(dirName(target));
        copy(entry.name, target);
    }
}

private void negativeMutants(string repository, string manifestText) {
    expectRejected("hash drift", {
        validateManifest(repository, parseJSON(manifestText.replace(
            "1b8719d530684bed7a4e220b9320f3615c20faa5f92d01e4ed113911f3ba5b99",
            "0b8719d530684bed7a4e220b9320f3615c20faa5f92d01e4ed113911f3ba5b99")));
    });
    expectRejected("missing attribution", {
        validateManifest(repository, parseJSON(manifestText.replace(provenanceAuthored, "")));
    });
    expectRejected("missing license", {
        validateManifest(repository, parseJSON(manifestText.replace(`"license": "MIT"`,
            `"license": ""`)));
    });
    expectRejected("stale command", {
        validateManifest(repository, parseJSON(manifestText.replace(
            `"clean-web-document", "--input"`, `"run", "--input"`)));
    });
    expectRejected("path escape", {
        validateManifest(repository, parseJSON(manifestText.replace(
            "examples/corpus/clean-web-document/inputs/single-file/hydrology-notebook.html",
            "../LICENSE")));
    });
    expectRejected("false training-ready claim", {
        validateManifest(repository, parseJSON(manifestText.replace(
            `"trainingReady": false`, `"trainingReady": true`)));
    });
    expectRejected("false general-purpose anonymization claim", {
        validateManifest(repository, parseJSON(manifestText.replace(
            `"generalPurposeAnonymization": false`, `"generalPurposeAnonymization": true`)));
    });
    expectRejected("false main-content-extraction disclaimer", {
        validateManifest(repository, parseJSON(manifestText.replace(
            `"mainContentExtraction": true`, `"mainContentExtraction": false`)));
    });
    expectRejected("stale documentId placeholder", {
        validateManifest(repository, parseJSON(manifestText.replace(
            documentIdPlaceholder, "doc:v1:" ~ "1".replicate(64))));
    });

    auto mutantRoot = buildPath(tempDir,
        "scrubbed-clean-web-document-mutant-" ~ randomUUID.toString);
    mkdirRecurse(mutantRoot);
    scope(exit) if (exists(mutantRoot)) rmdirRecurse(mutantRoot);
    foreach (path; ["examples/corpus/clean-web-document", "examples/pipelines/clean-web-document"])
        copyTree(buildPath(repository, path), buildPath(mutantRoot, path));
    write(buildPath(mutantRoot, "examples/pipelines/clean-web-document/clean-web-document.json"),
        "{}\n");
    expectRejected("stale config", {
        validateManifest(mutantRoot, parseJSON(manifestText));
    });
    copy(buildPath(repository, "examples/pipelines/clean-web-document/clean-web-document.json"),
        buildPath(mutantRoot, "examples/pipelines/clean-web-document/clean-web-document.json"));
    write(buildPath(mutantRoot,
        "examples/corpus/clean-web-document/expected/directory-tree/undeclared.txt"), "extra\n");
    expectRejected("undeclared output", {
        validateManifest(mutantRoot, parseJSON(manifestText));
    });
}

// ---------------------------------------------------------------------------
// Real, release-active binary execution from a clean temporary directory.
// ---------------------------------------------------------------------------

private Captured run(string[] command) {
    auto result = execute(command);
    return Captured(result.status, result.output, "");
}

private void sameFileBytes(string actual, string expected, string label) {
    need(read(actual) == read(expected), label ~ " content bytes");
}

private void sameSidecarBytes(string actual, string expected, string label) {
    need(normalizedSidecarBytes(actual) == normalizedSidecarBytes(expected),
        label ~ " sidecar bytes (documentId-normalized)");
}

private void sameTreeContent(string actualRoot, string expectedRoot, string label) {
    auto actualFiles = filesBelow(actualRoot, "");
    auto expectedFiles = filesBelow(expectedRoot, "");
    need(actualFiles.equal(expectedFiles), label ~ " relative path set");
    foreach (path; expectedFiles)
        sameFileBytes(buildPath(actualRoot, path), buildPath(expectedRoot, path),
            label ~ " " ~ path);
}

private void sameSidecarTree(string actualRoot, string expectedRoot, string label) {
    auto actualFiles = filesBelow(actualRoot, "");
    auto expectedFiles = filesBelow(expectedRoot, "");
    need(actualFiles.equal(expectedFiles), label ~ " sidecar relative path set");
    foreach (path; expectedFiles)
        sameSidecarBytes(buildPath(actualRoot, path), buildPath(expectedRoot, path),
            label ~ " " ~ path);
}

/// A generic `document-metadata:v2` sidecar carries the PII audit as a
/// hex-encoded structured-section payload -- decoded back to text here so a
/// plain `canFind` can assert the audit actually flagged something real,
/// proving the PII fixture is not accidentally a no-op.
private string decodedPayloadText(string sidecarPath, string sectionId) {
    auto text = readText(sidecarPath);
    auto marker = `"sectionId":"` ~ sectionId ~ `","payload":"`;
    auto start = text.indexOf(marker);
    need(start >= 0, "sidecar missing structured section: " ~ sectionId);
    start += cast(ptrdiff_t) marker.length;
    auto end = text.indexOf('"', start);
    need(end > start, "sidecar structured section payload unterminated");
    auto hexPayload = text[start .. end];
    need(hexPayload.length % 2 == 0, "structured section payload has odd hex length");
    ubyte[] decoded;
    decoded.reserve(hexPayload.length / 2);
    foreach (i; 0 .. hexPayload.length / 2) {
        auto hi = hexPayload[i * 2];
        auto lo = hexPayload[i * 2 + 1];
        ubyte nibble(char c) {
            if (c >= '0' && c <= '9') return cast(ubyte) (c - '0');
            if (c >= 'a' && c <= 'f') return cast(ubyte) (c - 'a' + 10);
            throw new Exception("structured section payload has non-hex byte");
        }
        decoded ~= cast(ubyte) ((nibble(hi) << 4) | nibble(lo));
    }
    return cast(string) decoded.idup;
}

/// Asserts the embedded PII audit's `unions` array actually contains at
/// least one finding of the given category with the given confidence --
/// direct proof against the real generated sidecar (not the pinned golden)
/// that the PII fixture is not accidentally a no-op.
private void assertRealPiiFinding(string sidecarPath, string category, string confidence) {
    auto audit = decodedPayloadText(sidecarPath, "pii-audit");
    need(!audit.canFind(`"unions":[]`), "PII audit union list is empty: " ~ sidecarPath);
    need(audit.canFind(`"category":"` ~ category ~ `"`) &&
        audit.canFind(`"confidence":"` ~ confidence ~ `"`) &&
        audit.canFind(`"outcome":"reported"`),
        "PII audit did not flag the expected " ~ category ~ "/" ~ confidence ~
        " finding: " ~ sidecarPath);
}

private void assertEmptyPiiFindings(string sidecarPath) {
    auto audit = decodedPayloadText(sidecarPath, "pii-audit");
    need(audit.canFind(`"unions":[]`),
        "PII audit expected to be empty but found a union: " ~ sidecarPath);
}

private string sidecarPathFor(string output, bool isDir) {
    // Mirrors `cli_commands.d`'s own `cleanWebDocumentSidecarPath` exactly
    // (no trailing separator on `output` anywhere in this checker, so the
    // cosmetic-normalization branch there never triggers).
    return output ~ (isDir ? ".document-metadata" : ".document-metadata.json");
}

private void runPositiveRecipes(string repository, string executable, JSONValue manifest) {
    auto configPath =
        buildPath(repository, "examples/pipelines/clean-web-document/clean-web-document.json");
    auto expected = buildPath(repository, "examples/corpus/clean-web-document/expected");
    auto root = buildPath(tempDir, "scrubbed-clean-web-document-" ~ randomUUID.toString);
    mkdirRecurse(root);
    scope(exit) if (exists(root)) rmdirRecurse(root);

    // `--emit-config` must touch nothing and must exactly match the
    // checked-in canonical config -- the single source of truth this
    // checker's own CLI-vs-config-form equivalence proof below depends on.
    auto emitted = run([executable, "clean-web-document", "--emit-config"]);
    need(emitted.status == 0 &&
        cast(const(ubyte)[]) emitted.output == read(configPath),
        "clean-web-document --emit-config drifted from the checked-in canonical config");

    // ---- Single-file mode -------------------------------------------------
    {
        auto inputsCopy = buildPath(root, "single-file-input");
        copyTree(buildPath(repository, "examples/corpus/clean-web-document/inputs/single-file"),
            inputsCopy);
        auto input = buildPath(inputsCopy, "hydrology-notebook.html");

        auto cliOutput = buildPath(root, "single-file-cli-out", "hydrology-notebook.txt");
        mkdirRecurse(dirName(cliOutput));
        auto cli = run([executable, "clean-web-document", "--input", input,
            "--output", cliOutput]);
        need(cli.status == 0, "single-file CLI-form exit: " ~ cli.output);
        auto cliSidecar = sidecarPathFor(cliOutput, false);

        auto configOutput = buildPath(root, "single-file-config-out", "hydrology-notebook.txt");
        mkdirRecurse(dirName(configOutput));
        auto configSidecar = sidecarPathFor(configOutput, false);
        auto config = run([executable, "run", "--input", input, "--output", configOutput,
            "--sidecar-output", configSidecar, "--config", configPath]);
        need(config.status == 0, "single-file config-form exit: " ~ config.output);

        // CLI form and config form share the identical resolved --input
        // path in this one checker run, so their DocumentId values are
        // identical too (see the module doc comment) -- a direct,
        // unnormalized byte comparison is the strongest available proof
        // that the two forms compile to the same canonical job and produce
        // byte-equivalent results, including the sidecar.
        sameFileBytes(cliOutput, configOutput, "single-file CLI-vs-config content");
        need(read(cliSidecar) == read(configSidecar),
            "single-file CLI-vs-config sidecar bytes (unnormalized; same --input root)");

        sameFileBytes(cliOutput,
            buildPath(expected, "single-file/content/hydrology-notebook.txt"),
            "single-file content");
        sameSidecarBytes(cliSidecar,
            buildPath(expected,
                "single-file/sidecar/hydrology-notebook.txt.document-metadata.json"),
            "single-file");

        // Proof the PII fixture is not accidentally a no-op: the audit
        // actually flags the synthetic email address, at high confidence,
        // under the default report policy (content unmodified).
        assertRealPiiFinding(cliSidecar, "email", "high");
    }

    // ---- Directory-tree mode -----------------------------------------------
    {
        auto inputsCopy = buildPath(root, "directory-tree-input");
        copyTree(buildPath(repository,
            "examples/corpus/clean-web-document/inputs/directory-tree"), inputsCopy);

        auto cliOutput = buildPath(root, "directory-tree-cli-out");
        auto cli = run([executable, "clean-web-document", "--input", inputsCopy,
            "--output", cliOutput]);
        need(cli.status == 0, "directory-tree CLI-form exit: " ~ cli.output);
        auto cliSidecarRoot = sidecarPathFor(cliOutput, true);

        auto configOutput = buildPath(root, "directory-tree-config-out");
        auto configSidecarRoot = sidecarPathFor(configOutput, true);
        auto config = run([executable, "run", "--input", inputsCopy, "--output", configOutput,
            "--sidecar-output", configSidecarRoot, "--config", configPath]);
        need(config.status == 0, "directory-tree config-form exit: " ~ config.output);

        sameTreeContent(cliOutput, configOutput, "directory-tree CLI-vs-config content");
        auto cliSidecarFiles = filesBelow(cliSidecarRoot, "");
        auto configSidecarFiles = filesBelow(configSidecarRoot, "");
        need(cliSidecarFiles.equal(configSidecarFiles),
            "directory-tree CLI-vs-config sidecar path set");
        foreach (path; cliSidecarFiles)
            need(read(buildPath(cliSidecarRoot, path)) == read(buildPath(configSidecarRoot, path)),
                "directory-tree CLI-vs-config sidecar bytes (unnormalized; same --input root) " ~ path);

        sameTreeContent(cliOutput, buildPath(expected, "directory-tree/content"), "directory-tree");
        sameSidecarTree(cliSidecarRoot, buildPath(expected, "directory-tree/sidecar"),
            "directory-tree sidecar");

        assertEmptyPiiFindings(buildPath(cliSidecarRoot, "clean-record.html.document-metadata.json"));
        assertEmptyPiiFindings(
            buildPath(cliSidecarRoot, "mojibake-record.html.document-metadata.json"));
        assertRealPiiFinding(buildPath(cliSidecarRoot, "pii-record.html.document-metadata.json"),
            "phone", "ambiguous");
    }
}

/// Acceptance criterion: clean-web-document fails before touching anything
/// if the derived document-metadata sidecar path already exists. Pre-creates
/// the sidecar output path, runs the CLI form, and asserts it fails cleanly
/// (exit 2), leaves the pre-existing sidecar byte-for-byte unchanged (no
/// clobber), and never creates the primary output at all (no partial write).
private void runNegativeSidecarFixture(string repository, string executable) {
    auto root = buildPath(tempDir,
        "scrubbed-clean-web-document-negative-" ~ randomUUID.toString);
    mkdirRecurse(root);
    scope(exit) if (exists(root)) rmdirRecurse(root);

    auto inputsCopy = buildPath(root, "input");
    copyTree(buildPath(repository, "examples/corpus/clean-web-document/inputs/single-file"),
        inputsCopy);
    auto input = buildPath(inputsCopy, "hydrology-notebook.html");

    auto outputDir = buildPath(root, "out");
    mkdirRecurse(outputDir);
    auto output = buildPath(outputDir, "hydrology-notebook.txt");
    auto sidecar = sidecarPathFor(output, false);
    enum sentinel = "PRE-EXISTING SIDECAR -- MUST NOT BE CLOBBERED\n";
    write(sidecar, sentinel);

    auto result = run([executable, "clean-web-document", "--input", input,
        "--output", output]);
    need(result.status == 2, "sidecar-occupied exit code: " ~ result.status.to!string);
    need(result.output.canFind("derived document-metadata sidecar path already exists"),
        "sidecar-occupied diagnostic message");
    need(cast(string) read(sidecar) == sentinel,
        "pre-existing sidecar must be left byte-for-byte unchanged, not clobbered");
    need(!exists(output),
        "primary output must not be created at all when the sidecar path is occupied");
    // Only the one pre-created sidecar file may exist in the output
    // directory afterward -- proof there is no partial/stray write anywhere.
    need(filesBelow(outputDir, "").equal(["hydrology-notebook.txt.document-metadata.json"]),
        "no partial or stray write when the sidecar path is occupied");
}

int main(string[] args) {
    need(args.length == 2 || args.length == 3,
        "usage: check <release executable> [repository root]");
    auto executable = absolutePath(args[1]);
    auto repository = absolutePath(args.length == 3 ? args[2] : ".");
    auto manifestPath =
        buildPath(repository, "examples/corpus/clean-web-document/manifest.json");
    auto manifestText = readText(manifestPath);
    auto manifest = parseJSON(manifestText);
    validateManifest(repository, manifest);
    negativeMutants(repository, manifestText);
    runPositiveRecipes(repository, executable, manifest);
    runNegativeSidecarFixture(repository, executable);
    import std.stdio : writeln;
    writeln("clean-web-document check: manifest, mutants, CLI/config " ~
        "equivalence, real PII findings, and the sidecar-occupied negative " ~
        "path all pass");
    return 0;
}
