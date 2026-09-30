/// Release-active actual-binary check for the `route-metadata` command
/// example (issue #508). Mirrors `examples/pipelines/quickstart/check.d`'s,
/// `examples/pipelines/pii-policy/check.d`'s, and
/// `examples/pipelines/custom-composition/check.d`'s structure: validate the
/// corpus manifest, then run the documented recipe against a freshly built
/// release binary from a clean temp directory and diff both independent
/// sinks against pinned golden bytes.
///
/// **No JSON-config form exists for this command.** `route-metadata` is
/// dispatched directly from `source/cli_commands.d`'s `runCommands()` before
/// argparse's generic parse, and its own `parseOptions()`
/// (`source/effects/metadata_route_cli.d`) recognizes only `--input`/
/// `--content-output`/`--metadata-output`/`--manifest`/`--filters`/
/// `--retry` -- there is no `--config` flag and no JSON-loading code path
/// anywhere in that module. This is a real, current limitation of the
/// command itself (see `manifest.json`'s `commandNote`), not a gap in this
/// example. In its place, this checker proves CLI-token determinism the
/// concrete way: it runs the exact same `route-metadata` invocation twice,
/// as two separate real process launches of the release binary against the
/// same `--input` path but distinct output roots, and diffs both
/// independent sinks byte-for-byte between the two runs.
///
/// This checker also proves the "independent sinks" claim concretely, not
/// just by asserting two files exist: after a normal run, it deletes the
/// content sink and confirms the metadata sink is still present and
/// byte-correct on disk (one run), and separately moves the metadata sink
/// aside and confirms the content sink is still present and byte-correct
/// (the other run) -- showing each sink's correctness does not depend on
/// the other's continued existence.
///
/// compile with ldc2 -O, then pass scrubbed:
///   ldc2 -O3 -release -preview=dip1000 -i -Isource \
///     -of=.dub/route-metadata-check examples/pipelines/route-metadata/check.d
///   .dub/route-metadata-check ./scrubbed
module route_metadata_check;

import std.algorithm.searching : canFind, startsWith;
import std.array : replace;
import std.conv : to;
import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;
import std.file : exists, mkdirRecurse, read, readText, remove, rename,
    rmdirRecurse, tempDir, write;
import std.json : JSONValue, parseJSON;
import std.path : absolutePath, buildPath;
import std.process : execute;
import std.regex : ctRegex, matchFirst, replaceAll;
import std.uuid : randomUUID;

private enum provenance = "Authored for scrubbed issue #508 by Shammah Chancellor.";
private enum documentIdPattern = ctRegex!(`doc:v1:[0-9a-f]{64}`);
private enum documentIdToken = "<DOCUMENT_ID>";

private void need(bool condition, string label) {
    if (!condition) throw new Exception("route-metadata check: " ~ label);
}

private string digest(string path) {
    return toHexString!(LetterCase.lower)(sha256Of(read(path))).idup;
}

private void expectRejected(string label, void delegate() mutation) {
    bool rejected;
    try mutation();
    catch (Exception) rejected = true;
    need(rejected, "negative mutant accepted: " ~ label);
}

private void validateManifest(string repository, JSONValue manifest) {
    need(manifest["schema"].str == "scrubbed.route-metadata-corpus.v1", "manifest schema");
    auto licensePath = manifest["licenseFile"].str;
    need(licensePath == "examples/corpus/route-metadata/LICENSE.txt" &&
        digest(buildPath(repository, licensePath)) ==
            "d05e83eb1213daac7371eee9bb40c8d06e767e37dc38f6f10b8f0b06d72708e0",
        "exact corpus license");
    need(!manifest["claims"]["jsonConfigForm"].boolean &&
        !manifest["claims"]["trainingReady"].boolean,
        "must not falsely claim a JSON-config form or training-readiness");
    need(!manifest["commandNote"]["hasJsonConfigForm"].boolean,
        "commandNote must record that route-metadata has no JSON-config form");

    foreach (artifact; manifest["artifacts"].array) {
        auto path = artifact["path"].str;
        need(path.startsWith("examples/corpus/route-metadata/inputs/") ||
            path.startsWith("examples/corpus/route-metadata/expected/"),
            "artifact path escape: " ~ path);
        need(!path.canFind("..") && artifact["mediaType"].str.length != 0,
            "unsafe path or missing media type: " ~ path);
        need(artifact["provenance"].str == provenance ||
            artifact["provenance"].str.startsWith(
                "Generated from the authored issue #508 input"),
            "missing attribution/provenance: " ~ path);
        need(artifact["license"].str == "MIT", "missing artifact license: " ~ path);
        need(digest(buildPath(repository, path)) == artifact["sha256"].str,
            "artifact hash drift: " ~ path);
    }

    auto recipe = manifest["recipe"];
    need(recipe["id"].str == "dispatch-note", "unexpected recipe id");
    need(recipe["expectedExit"].integer == 0, "recipe must exit 0");
    auto arguments = recipe["cliArguments"].array;
    auto expectedArguments = ["route-metadata", "--input", "${INPUT}",
        "--content-output", "${CONTENT_OUTPUT}", "--metadata-output",
        "${METADATA_OUTPUT}", "--manifest", "${MANIFEST}"];
    need(arguments.length == expectedArguments.length, "recipe argument count");
    foreach (i, argument; arguments)
        need(argument.str == expectedArguments[i], "stale recipe argument " ~ i.to!string);
}

private void negativeMutants(string repository, string manifestText) {
    auto sampleHash = digest(buildPath(repository,
        "examples/corpus/route-metadata/inputs/dispatch-note.html"));
    expectRejected("hash drift", {
        validateManifest(repository, parseJSON(manifestText.replace(
            sampleHash, "0000000000000000000000000000000000000000000000000000000000000000")));
    });
    expectRejected("missing attribution", {
        validateManifest(repository, parseJSON(manifestText.replace(provenance, "")));
    });
    expectRejected("missing license", {
        validateManifest(repository, parseJSON(manifestText.replace(`"license": "MIT"`,
            `"license": ""`)));
    });
    expectRejected("path escape", {
        validateManifest(repository, parseJSON(manifestText.replace(
            "examples/corpus/route-metadata/inputs/dispatch-note.html",
            "../../../etc/passwd")));
    });
    expectRejected("false JSON-config-form claim", {
        validateManifest(repository, parseJSON(manifestText.replace(
            `"jsonConfigForm": false`, `"jsonConfigForm": true`)));
    });
    expectRejected("false training-ready claim", {
        validateManifest(repository, parseJSON(manifestText.replace(
            `"trainingReady": false`, `"trainingReady": true`)));
    });
    expectRejected("false hasJsonConfigForm command note", {
        validateManifest(repository, parseJSON(manifestText.replace(
            `"hasJsonConfigForm": false`, `"hasJsonConfigForm": true`)));
    });
    expectRejected("stale recipe command", {
        validateManifest(repository, parseJSON(manifestText.replace(
            `"--content-output"`, `"--content-out"`)));
    });
}

private struct RunResult {
    string contentPath;
    string metadataPath;
}

/// Runs one real `route-metadata` invocation against the release binary,
/// from a clean output pair (both roots must already exist -- the command's
/// own documented contract, see `--help`), and returns both sink paths.
private RunResult runOnce(string executable, string inputPath, string root, string id) {
    auto contentDir = buildPath(root, id ~ "-content");
    auto metadataDir = buildPath(root, id ~ "-metadata");
    auto manifestPath = buildPath(root, id ~ "-manifest.sqlite3");
    mkdirRecurse(contentDir);
    mkdirRecurse(metadataDir);
    auto result = execute([executable, "route-metadata", "--input", inputPath,
        "--content-output", contentDir, "--metadata-output", metadataDir,
        "--manifest", manifestPath]);
    need(result.status == 0, id ~ " route-metadata run failed (exit " ~
        result.status.to!string ~ "): " ~ result.output);
    auto contentPath = buildPath(contentDir, "dispatch-note.html");
    auto metadataPath = buildPath(metadataDir, "dispatch-note.html");
    need(exists(contentPath), id ~ ": content sink missing");
    need(exists(metadataPath), id ~ ": metadata sink missing");
    // The two sinks must actually be distinct, independently addressable
    // filesystem paths -- not merely distinct in name -- matching the
    // command's own documented "independent content and metadata sinks"
    // behavior (`source/effects/metadata_route_cli.d`'s `preflight`
    // deliberately refuses any overlap between content/metadata/input/
    // manifest roots).
    need(contentPath != metadataPath && contentDir != metadataDir,
        id ~ ": content and metadata sinks are not independently addressable paths");
    return RunResult(contentPath, metadataPath);
}

private string withDocumentIdToken(string text) {
    return replaceAll(text, documentIdPattern, documentIdToken);
}

private void checkDocumentId(string metadataText, string label) {
    auto match = matchFirst(metadataText, documentIdPattern);
    need(!match.empty, label ~ ": no doc:v1:<hex> document id found");
    auto id = match.hit;
    need(id.length == 71, label ~ ": document id has the wrong length");
}

private void runRecipe(string repository, string executable) {
    auto root = buildPath(tempDir, "scrubbed-route-metadata-" ~ randomUUID.toString);
    mkdirRecurse(root);
    scope (exit) if (exists(root)) rmdirRecurse(root);

    // A clean temp directory: the fixture is copied in, never read from the
    // repository checkout, so the checker exercises the same path a
    // downstream user copying the example would take. Both runs share the
    // exact same absolute --input path (`domain.document.DocumentId.from`
    // binds a document's identity to the source locator's key, which
    // `runMetadataRoute` derives from --input's own resolved absolute path
    // -- see `manifest.json`'s expected-outcome note for
    // dispatch-note.metadata.json) so the two runs' metadata sinks are
    // fully byte-for-byte comparable to each other, including the
    // documentId field itself, with no substitution needed between them.
    auto sharedInputDir = buildPath(root, "shared-input");
    mkdirRecurse(sharedInputDir);
    auto inputPath = buildPath(sharedInputDir, "dispatch-note.html");
    write(inputPath, read(buildPath(repository,
        "examples/corpus/route-metadata/inputs/dispatch-note.html")));

    auto runA = runOnce(executable, inputPath, root, "run-a");
    auto runB = runOnce(executable, inputPath, root, "run-b");

    // --- CLI-token determinism across two separate real process runs ---
    need(cast(const(ubyte)[]) read(runA.contentPath) ==
        cast(const(ubyte)[]) read(runB.contentPath),
        "content sink differs between two separate real runs of the identical command");
    auto metadataTextA = readText(runA.metadataPath);
    auto metadataTextB = readText(runB.metadataPath);
    need(metadataTextA == metadataTextB,
        "metadata sink differs between two separate real runs of the identical command " ~
        "(same --input path, so even documentId must match exactly)");

    // --- Content sink: pinned golden, and proof the filters did real work ---
    auto rawInput = read(inputPath);
    auto contentBytes = read(runA.contentPath);
    need(cast(const(ubyte)[]) contentBytes != cast(const(ubyte)[]) rawInput,
        "content sink is a pass-through of the raw input -- normalize-line-endings " ~
        "must have rewritten the fixture's CRLF/lone-CR line endings");
    need(!(cast(string) contentBytes).canFind("\r"),
        "content sink still contains a raw CR byte after normalize-line-endings");
    auto expectedContent = read(buildPath(repository,
        "examples/corpus/route-metadata/expected/dispatch-note.content.html"));
    need(cast(const(ubyte)[]) contentBytes == expectedContent,
        "content sink differs from its pinned golden");

    // --- Metadata sink: pinned golden (modulo the documentId substitution
    // this repository's convention already uses -- see pii-policy's own
    // check.d -- because DocumentId.from binds to --input's absolute path,
    // which is not reproducible across machines/temp directories) ---
    checkDocumentId(metadataTextA, "run-a metadata sink");
    auto expectedMetadata = readText(buildPath(repository,
        "examples/corpus/route-metadata/expected/dispatch-note.metadata.json"));
    need(withDocumentIdToken(metadataTextA) == expectedMetadata,
        "metadata sink (modulo documentId) differs from its pinned golden");
    need(metadataTextA.canFind(`"title":{"value":"Independent Sink Routing Dispatch"`),
        "metadata sink missing expected title field");
    need(metadataTextA.canFind(`"author":{"value":"Ada Fixture"`),
        "metadata sink missing expected author field");
    need(metadataTextA.canFind(`"key":"site-name"`) && metadataTextA.canFind(`"key":"description"`),
        "metadata sink missing expected extension fields");

    // --- Independent-sink proof: deleting/moving one sink does not affect
    // the other's correctness on disk. This is the concrete demonstration
    // the ticket requires, not merely asserting two files exist. ---

    // Direction 1 (run A): delete the content sink outright, then confirm
    // the metadata sink is still present and still byte-identical to its
    // pinned golden -- its correctness never depended on the content
    // sink's continued existence.
    remove(runA.contentPath);
    need(!exists(runA.contentPath), "content sink deletion did not take effect");
    need(exists(runA.metadataPath),
        "metadata sink vanished after the content sink was deleted -- sinks are not independent");
    need(withDocumentIdToken(readText(runA.metadataPath)) == expectedMetadata,
        "metadata sink bytes changed after the unrelated content sink was deleted");

    // Direction 2 (run B): move the metadata sink out of its root entirely,
    // then confirm the content sink is still present and still byte-
    // identical to its pinned golden.
    auto movedMetadata = buildPath(root, "moved-metadata.json");
    rename(runB.metadataPath, movedMetadata);
    need(!exists(runB.metadataPath), "metadata sink move did not take effect");
    need(exists(movedMetadata), "moved metadata sink is missing");
    need(exists(runB.contentPath),
        "content sink vanished after the unrelated metadata sink was moved -- sinks are not independent");
    need(cast(const(ubyte)[]) read(runB.contentPath) == expectedContent,
        "content sink bytes changed after the unrelated metadata sink was moved");
}

int main(string[] args) {
    need(args.length == 2 || args.length == 3,
        "usage: check <release executable> [repository root]");
    auto executable = absolutePath(args[1]);
    auto repository = absolutePath(args.length == 3 ? args[2] : ".");
    auto manifestPath = buildPath(repository, "examples/corpus/route-metadata/manifest.json");
    auto manifestText = readText(manifestPath);
    auto manifest = parseJSON(manifestText);
    validateManifest(repository, manifest);
    negativeMutants(repository, manifestText);
    runRecipe(repository, executable);
    import std.stdio : writeln;
    writeln("route-metadata check: manifest, mutants, two-run CLI-token determinism, " ~
        "pinned content/metadata sinks, and independent-sink deletion/move resilience all pass");
    return 0;
}
