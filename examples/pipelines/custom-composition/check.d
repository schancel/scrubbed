/// Release-active actual-binary check for the custom `--stage` composition +
/// `language-id-detect` example (issue #505). Mirrors
/// `examples/pipelines/quickstart/check.d`'s and
/// `examples/pipelines/pii-policy/check.d`'s structure: validate the corpus
/// manifest, then run every documented recipe against a freshly built
/// release binary from a clean temp directory and diff both the primary
/// output and the decoded `language-id-detect` annotation (via the
/// `document-metadata-publish` sidecar) against pinned expected results.
///
/// This example is deliberately NOT one of the sealed presets
/// (`clean-web-document`/`extract`): it hand-composes three ordinary stages
/// -- `text-transform` (with the `fix-mojibake` filter), `language-id-detect`,
/// and `document-metadata-publish` -- to prove `run --stage` lets a caller
/// build their own pipeline order. The specific stages/order shown here are
/// illustrative, not the only valid composition -- see this directory's
/// README.
///
/// compile with ldc2 -O, then pass scrubbed:
///   ldc2 -O3 -release -preview=dip1000 -i -Isource \
///     -of=.dub/custom-composition-check examples/pipelines/custom-composition/check.d
///   .dub/custom-composition-check ./scrubbed
module custom_composition_check;

import std.algorithm.searching : canFind, startsWith;
import std.array : replace;
import std.conv : to;
import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;
import std.file : exists, mkdirRecurse, read, readText, rmdirRecurse, tempDir, write;
import std.json : JSONValue, parseJSON;
import std.path : absolutePath, buildPath;
import std.process : execute;
import std.uuid : randomUUID;

import crypto.sha256 : sha256OfBytes = sha256Of;
import domain.document : DocumentId;
import domain.language_id : LanguageAbstentionReason, LanguageDetectionStatus,
    LanguageIdentityRecord, SupportedLanguage, decodeLanguageIdentity,
    languageIdAlgorithmVersion;

private enum provenance = "Authored for scrubbed issue #505 by Shammah Chancellor.";
private enum languageIdExtensionKey = "language-id";
private enum languageIdStageKey = "language-id-detect";

private void need(bool condition, string label) {
    if (!condition) throw new Exception("custom-composition check: " ~ label);
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

/// Bounded, deterministic hex decode. Extension-field values in the
/// `document-metadata` wire are `Writer.putHex`-encoded raw bytes (lowercase,
/// unpadded) -- see `domain.document_metadata`.
private ubyte[] decodeHex(string hex) {
    need(hex.length % 2 == 0, "odd-length hex payload");
    auto result = new ubyte[hex.length / 2];
    foreach (i; 0 .. result.length) {
        int high = hexNibble(hex[i * 2]);
        int low = hexNibble(hex[i * 2 + 1]);
        result[i] = cast(ubyte) ((high << 4) | low);
    }
    return result;
}

private int hexNibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    need(false, "non-lowercase-hex byte in extension-field payload");
    assert(0);
}

private void validateManifest(string repository, JSONValue manifest) {
    need(manifest["schema"].str == "scrubbed.custom-composition-corpus.v1", "manifest schema");
    auto licensePath = manifest["licenseFile"].str;
    need(licensePath == "examples/corpus/custom-composition/LICENSE.txt" &&
        digest(buildPath(repository, licensePath)) ==
            "d05e83eb1213daac7371eee9bb40c8d06e767e37dc38f6f10b8f0b06d72708e0",
        "exact corpus license");
    need(!manifest["claims"]["sealedPreset"].boolean &&
        !manifest["claims"]["trainingReady"].boolean,
        "must not claim to be a sealed preset or training-ready");

    auto configPath = manifest["configuration"]["path"].str;
    need(configPath == "examples/pipelines/custom-composition/pipeline.json",
        "unexpected configuration path");
    need(digest(buildPath(repository, configPath)) == manifest["configuration"]["sha256"].str,
        "canonical configuration hash drift");

    foreach (artifact; manifest["artifacts"].array) {
        auto path = artifact["path"].str;
        need(path.startsWith("examples/corpus/custom-composition/inputs/") ||
            path.startsWith("examples/corpus/custom-composition/expected/"),
            "artifact path escape: " ~ path);
        need(!path.canFind("..") && artifact["mediaType"].str.length != 0,
            "unsafe path or missing media type: " ~ path);
        need(artifact["provenance"].str == provenance ||
            artifact["provenance"].str.startsWith(
                "Generated from the authored issue #505 input"),
            "missing attribution/provenance: " ~ path);
        need(artifact["license"].str == "MIT", "missing artifact license: " ~ path);
        need(digest(buildPath(repository, path)) == artifact["sha256"].str,
            "artifact hash drift: " ~ path);
    }

    auto recipes = manifest["recipes"].array;
    need(recipes.length == 3, "recipe count");
    foreach (recipe; recipes)
        need(recipe["expectedExit"].integer == 0, "recipe " ~ recipe["id"].str ~
            " must exit 0 (abstention is typed data, never a quarantine)");
}

private struct ModeResult {
    string id;
    string outputPath;
    string sidecarPath;
    JSONValue wire;
    LanguageIdentityRecord record;
}

/// Runs one fixture's CLI recipe from a clean temp directory against the
/// release binary, then structurally verifies the sidecar envelope
/// (`document-metadata:v1` -- `language-id-detect` writes an extension
/// field, not a structured section, so `document-metadata-publish` always
/// takes the v1 wire path for this composition) before decoding the
/// `language-id` extension field for the caller to check against a pinned
/// golden descriptor.
private ModeResult runRecipe(string executable, string inputPath, string root, string id) {
    auto outputPath = buildPath(root, id ~ "-out.txt");
    auto sidecarPath = buildPath(root, id ~ "-sidecar.json");
    string[] command = [executable, "run", "--input", inputPath, "--output",
        outputPath, "--sidecar-output", sidecarPath, "--stage",
        "clean=text-transform", "--filter", "fix-mojibake", "--filter-option",
        "encodings=text:latin1,cp1252", "--filter-option", "max-passes=integer:2",
        "--stage", "detect=language-id-detect", "--stage",
        "pub=document-metadata-publish"];
    auto result = execute(command);
    need(result.status == 0, id ~ " recipe failed (exit " ~
        result.status.to!string ~ "): " ~ result.output);

    auto wireText = readText(sidecarPath);
    auto wire = parseJSON(wireText);
    need(wire["version"].str == "document-metadata:v1", id ~
        " sidecar version -- language-id-detect writes an extension field, " ~
        "not a structured section, so document-metadata-publish must pick v1");
    need(wire["standard"]["title"].isNull && wire["standard"]["author"].isNull &&
        wire["standard"]["date"].isNull && wire["standard"]["url"].isNull,
        id ~ " sidecar carries unexpected standard fields");
    auto extension = wire["extension"].array;
    need(extension.length == 1 && extension[0]["key"].str == languageIdExtensionKey &&
        extension[0]["sourceStage"].str == languageIdStageKey,
        id ~ " sidecar extension-field identity/provenance");

    auto documentIdText = wire["documentId"].str;
    need(documentIdText.startsWith("doc:v1:") && documentIdText.length == 71,
        id ~ " document ID shape");
    foreach (ch; documentIdText[7 .. $])
        need((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f'),
            id ~ " document ID is not lowercase hex");
    auto documentId = DocumentId.fromCanonicalText(documentIdText);

    auto payloadHex = extension[0]["value"].str;
    auto encoded = decodeHex(payloadHex);
    // `language-id-detect` passes `content` through unchanged, and no later
    // stage in this composition touches it, so the primary output file's
    // own bytes are exactly the text that was scored -- the same
    // `expectedTextRevision` binding `language_id_detect_stage.d`'s own
    // unit tests use.
    ubyte[32] outputRevision = sha256OfBytes(cast(const(ubyte)[]) read(outputPath));
    auto record = decodeLanguageIdentity(cast(immutable(ubyte)[]) encoded, documentId,
        outputRevision);
    need(record.identity.algorithmVersion == languageIdAlgorithmVersion,
        id ~ " unexpected algorithm version");

    return ModeResult(id, outputPath, sidecarPath, wire, record);
}

/// A small, stable, human-readable descriptor of a decoded
/// `LanguageIdentityRecord`'s result -- deliberately excludes the
/// document-/environment-bound identity fields (documentId, textRevision,
/// profileTableIdentity), which `runRecipe` above already structurally
/// binds and verifies; this descriptor pins only the classifier's own,
/// fully content-deterministic verdict.
private string describeResult(LanguageIdentityRecord record) {
    auto r = record.result;
    if (r.status == LanguageDetectionStatus.detected) {
        long perMille = cast(long)(r.confidence * 1000.0 + 0.5);
        return `{"status":"detected","language":"` ~ r.language.to!string ~
            `","confidencePerMille":` ~ perMille.to!string ~
            `,"abstentionReason":"none"}` ~ "\n";
    }
    return `{"status":"abstained","language":null,"confidencePerMille":null,` ~
        `"abstentionReason":"` ~ r.reason.to!string ~ `"}` ~ "\n";
}

private void checkAgainstGolden(string repository, ModeResult result) {
    auto expectedOutput = read(buildPath(repository,
        "examples/corpus/custom-composition/expected/" ~ result.id ~ ".txt"));
    need(cast(const(ubyte)[]) read(result.outputPath) == expectedOutput,
        result.id ~ ": output bytes differ from pinned golden");

    auto expectedDescriptor = readText(buildPath(repository,
        "examples/corpus/custom-composition/expected/" ~ result.id ~
        ".language-id.json"));
    auto actualDescriptor = describeResult(result.record);
    need(actualDescriptor == expectedDescriptor,
        result.id ~ ": decoded language-id descriptor differs from pinned golden -- " ~
        "expected " ~ expectedDescriptor ~ " got " ~ actualDescriptor);
}

private void runRecipes(string repository, string executable) {
    auto root = buildPath(tempDir, "scrubbed-custom-composition-" ~ randomUUID.toString);
    mkdirRecurse(root);
    scope (exit) if (exists(root)) rmdirRecurse(root);

    // A clean temp directory: fixtures are copied in, never read from the
    // repository checkout, so the checker exercises the same path a
    // downstream user copying the example would take.
    string[string] inputPaths;
    foreach (id; ["clean", "repair", "short"]) {
        auto inputPath = buildPath(root, id ~ ".txt");
        write(inputPath, read(buildPath(repository,
            "examples/corpus/custom-composition/inputs/" ~ id ~ ".txt")));
        inputPaths[id] = inputPath;
    }

    auto clean = runRecipe(executable, inputPaths["clean"], root, "clean");
    auto repair = runRecipe(executable, inputPaths["repair"], root, "repair");
    auto short_ = runRecipe(executable, inputPaths["short"], root, "short");

    checkAgainstGolden(repository, clean);
    checkAgainstGolden(repository, repair);
    checkAgainstGolden(repository, short_);

    // `clean.txt` carries no mojibake -- fix-mojibake is a no-op on it,
    // matching quickstart's clean.txt idiom.
    need(cast(const(ubyte)[]) read(clean.outputPath) ==
        cast(const(ubyte)[]) read(inputPaths["clean"]),
        "clean recipe: fix-mojibake unexpectedly altered already-clean input");
    // `repair.txt` DOES carry mojibake -- fix-mojibake must actually change
    // the bytes (proving the extra composed stage does real work ahead of
    // language-id-detect, not just pass through).
    need(cast(const(ubyte)[]) read(repair.outputPath) !=
        cast(const(ubyte)[]) read(inputPaths["repair"]),
        "repair recipe: fix-mojibake did not alter mojibake-corrupted input");

    // The confident cases must each name one of the 17 supported languages,
    // with the exact expected one, and must not merely happen to abstain.
    need(clean.record.result.status == LanguageDetectionStatus.detected &&
        clean.record.result.language == SupportedLanguage.es,
        "clean recipe: expected a confident Spanish (es) classification");
    need(repair.record.result.status == LanguageDetectionStatus.detected &&
        repair.record.result.language == SupportedLanguage.en,
        "repair recipe: expected a confident English (en) classification");

    // The abstention case must genuinely abstain, with a populated,
    // non-"none" typed reason -- never a silently guessed language.
    need(short_.record.result.status == LanguageDetectionStatus.abstained &&
        short_.record.result.reason == LanguageAbstentionReason.tooShort,
        "short recipe: expected a genuine tooShort abstention, not a guess");

    // The JSON `--config` form (pipeline.json) must compile and run to the
    // exact same golden as the equivalent `--stage` tokens, for every fixture.
    foreach (id; ["clean", "repair", "short"]) {
        auto configOutput = buildPath(root, id ~ "-config-out.txt");
        auto configSidecar = buildPath(root, id ~ "-config-sidecar.json");
        auto command = [executable, "run", "--input", inputPaths[id], "--output",
            configOutput, "--sidecar-output", configSidecar, "--config",
            buildPath(repository, "examples/pipelines/custom-composition/pipeline.json")];
        auto result = execute(command);
        need(result.status == 0, id ~ " JSON-config recipe failed: " ~ result.output);
        auto expectedOutput = read(buildPath(repository,
            "examples/corpus/custom-composition/expected/" ~ id ~ ".txt"));
        need(cast(const(ubyte)[]) read(configOutput) == expectedOutput,
            id ~ " JSON-config output differs from the --stage-token form's golden");
        need(cast(const(ubyte)[]) read(configSidecar) ==
            cast(const(ubyte)[]) read(buildPath(root, id ~ "-sidecar.json")),
            id ~ " JSON-config sidecar differs byte-for-byte from the --stage-token form's sidecar");
    }
}

private void negativeMutants(string repository, string manifestText) {
    // Corrupt the pinned hash of the first declared artifact.
    auto sampleHash = digest(buildPath(repository,
        "examples/corpus/custom-composition/inputs/clean.txt"));
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
            "examples/corpus/custom-composition/inputs/clean.txt",
            "../../../etc/passwd")));
    });
    expectRejected("false sealed-preset claim", {
        validateManifest(repository, parseJSON(manifestText.replace(
            `"sealedPreset": false`, `"sealedPreset": true`)));
    });
    expectRejected("false training-ready claim", {
        validateManifest(repository, parseJSON(manifestText.replace(
            `"trainingReady": false`, `"trainingReady": true`)));
    });
}

int main(string[] args) {
    need(args.length == 2 || args.length == 3,
        "usage: check <release executable> [repository root]");
    auto executable = absolutePath(args[1]);
    auto repository = absolutePath(args.length == 3 ? args[2] : ".");
    auto manifestPath = buildPath(repository, "examples/corpus/custom-composition/manifest.json");
    auto manifestText = readText(manifestPath);
    auto manifest = parseJSON(manifestText);
    validateManifest(repository, manifest);
    negativeMutants(repository, manifestText);
    runRecipes(repository, executable);
    import std.stdio : writeln;
    writeln("custom-composition check: manifest, mutants, clean/repair/short recipes " ~
        "(--stage tokens and --config JSON), and decoded language-id descriptors all pass");
    return 0;
}
