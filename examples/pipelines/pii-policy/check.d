/// Release-active actual-binary check for the `pii-four-class` report/mask/
/// redact policy example (issue #507). Mirrors
/// `examples/pipelines/quickstart/check.d`'s structure: validate the corpus
/// manifest, then run every documented recipe against a freshly built
/// release binary from a clean temp directory and diff both the primary
/// output and the PII-audit sidecar against pinned expected results.
///
/// compile with ldc2 -O, then pass scrubbed:
///   ldc2 -O3 -release -preview=dip1000 -i -Isource \
///     -of=.dub/pii-policy-check examples/pipelines/pii-policy/check.d
///   .dub/pii-policy-check ./scrubbed
module pii_policy_check;

import std.algorithm.searching : canFind, endsWith, startsWith;
import std.array : replace;
import std.conv : to;
import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;
import std.file : exists, mkdirRecurse, read, readText, rmdirRecurse, tempDir, write;
import std.json : JSONValue, parseJSON;
import std.path : absolutePath, buildPath;
import std.process : execute;
import std.string : indexOf, strip;
import std.uuid : randomUUID;

/// The three findings this fixture is designed to trip, in ascending byte-
/// offset order: one email, one NANP fictional-exchange phone number, and
/// one RFC 5737 TEST-NET-3 IPv4 address. Every value is obviously
/// synthetic/placeholder, never real harvested data.
private enum fixtureCategories = ["email", "phone", "ip"];

private enum provenance = "Authored for scrubbed issue #507 by Shammah Chancellor.";
private enum documentIdPlaceholder = "<DOCUMENT_ID>";

private void need(bool condition, string label) {
    if (!condition) throw new Exception("pii-policy check: " ~ label);
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

/// Bounded, deterministic hex decode. The sidecar's structured-section
/// payload is `Writer.putHex`-encoded raw bytes (lowercase, unpadded).
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
    need(false, "non-lowercase-hex byte in structured-section payload");
    assert(0);
}

private void validateManifest(string repository, JSONValue manifest) {
    need(manifest["schema"].str == "scrubbed.pii-policy-corpus.v1", "manifest schema");
    auto licensePath = manifest["licenseFile"].str;
    need(licensePath == "examples/corpus/pii-policy/LICENSE.txt" &&
        digest(buildPath(repository, licensePath)) ==
            "d05e83eb1213daac7371eee9bb40c8d06e767e37dc38f6f10b8f0b06d72708e0",
        "exact corpus license");
    need(!manifest["claims"]["deidentificationGuarantee"].boolean &&
        !manifest["claims"]["trainingReady"].boolean,
        "no de-identification-guarantee or training-ready claim");
    need(manifest["fixtureProvenance"]["kind"].str == "wholly-new",
        "fixture provenance must record wholly-new authorship, not a copy of #180's fixture");

    foreach (artifact; manifest["artifacts"].array) {
        auto path = artifact["path"].str;
        need(path.startsWith("examples/corpus/pii-policy/inputs/") ||
            path.startsWith("examples/corpus/pii-policy/expected/"),
            "artifact path escape: " ~ path);
        need(!path.canFind("..") && artifact["mediaType"].str.length != 0,
            "unsafe path or missing media type: " ~ path);
        need(artifact["provenance"].str == provenance ||
            artifact["provenance"].str.startsWith(
                "Generated from the authored issue #507 input"),
            "missing attribution/provenance: " ~ path);
        need(artifact["license"].str == "MIT", "missing artifact license: " ~ path);
        need(digest(buildPath(repository, path)) == artifact["sha256"].str,
            "artifact hash drift: " ~ path);
    }

    auto recipes = manifest["recipes"].array;
    need(recipes.length == 3, "recipe count");
    foreach (recipe; recipes)
        need(recipe["expectedExit"].integer == 0, "recipe " ~ recipe["id"].str ~
            " must exit 0");
}

private struct ModeResult {
    string policy;
    string outputPath;
    string sidecarPath;
    JSONValue wire;
    string documentId;
    string auditText;
}

/// Runs one policy mode's CLI recipe from a clean temp directory against the
/// release binary, then structurally verifies the sidecar envelope
/// (`document-metadata:v2`, one `pii-audit` structured section owned by
/// `pii-four-class`, no `html-metadata-annotate` standard fields since this
/// example chains only the two PII stages) before handing back the decoded
/// audit JSON for the caller to diff against a pinned golden.
private ModeResult runMode(string executable, string inputPath, string root,
        string policy, string[] extraStageOptions) {
    auto outputPath = buildPath(root, policy ~ "-out.txt");
    auto sidecarPath = buildPath(root, policy ~ "-sidecar.json");
    string[] command = [executable, "run", "--input", inputPath, "--output",
        outputPath, "--sidecar-output", sidecarPath, "--stage",
        "pii=pii-four-class"] ~ extraStageOptions ~
        ["--stage", "pub=document-metadata-publish"];
    auto result = execute(command);
    need(result.status == 0, policy ~ " recipe failed (exit " ~
        result.status.to!string ~ "): " ~ result.output);

    auto wireText = readText(sidecarPath);
    auto wire = parseJSON(wireText);
    need(wire["version"].str == "document-metadata:v2", policy ~ " sidecar version");
    need(wire["standard"]["title"].isNull && wire["standard"]["author"].isNull &&
        wire["standard"]["date"].isNull && wire["standard"]["url"].isNull,
        policy ~ " sidecar carries unexpected standard fields");
    need(wire["extension"].array.length == 0,
        policy ~ " sidecar carries unexpected extension fields");
    auto sections = wire["structuredSections"].array;
    need(sections.length == 1 && sections[0]["sectionId"].str == "pii-audit" &&
        sections[0]["sourceStage"].str == "pii-four-class",
        policy ~ " sidecar structured-section identity/provenance");

    auto documentId = wire["documentId"].str;
    need(documentId.startsWith("doc:v1:") && documentId.length == 71,
        policy ~ " document ID shape");
    foreach (ch; documentId[7 .. $])
        need((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f'),
            policy ~ " document ID is not lowercase hex");

    auto payloadHex = sections[0]["payload"].str;
    auto auditText = cast(string) decodeHex(payloadHex);
    auto parsedAudit = parseJSON(auditText);
    need(parsedAudit["document_id"].str == documentId,
        policy ~ " audit document_id does not match the sidecar envelope's own ID");
    need(!auditText.canFind("example.test") && !auditText.canFind("555-0198") &&
        !auditText.canFind("203.0.113.42") && !auditText.canFind("agent.demo"),
        policy ~ " audit leaked matched PII content");

    return ModeResult(policy, outputPath, sidecarPath, wire, documentId, auditText);
}

private void checkAgainstGolden(string repository, ModeResult result, string label) {
    auto expectedOutput = read(buildPath(repository,
        "examples/corpus/pii-policy/expected/" ~ result.policy ~ ".txt"));
    need(cast(const(ubyte)[]) read(result.outputPath) == expectedOutput,
        label ~ ": output bytes differ from pinned golden");

    auto expectedAudit = readText(buildPath(repository,
        "examples/corpus/pii-policy/expected/" ~ result.policy ~ ".pii-audit.json"))
        .strip;
    auto normalized = result.auditText.replace(result.documentId, documentIdPlaceholder);
    need(normalized == expectedAudit,
        label ~ ": audit content (modulo document_id) differs from pinned golden");

    foreach (category; fixtureCategories)
        need(result.auditText.canFind(`"category":"` ~ category ~ `"`),
            label ~ ": audit missing expected category " ~ category);
}

private void runRecipes(string repository, string executable) {
    auto root = buildPath(tempDir, "scrubbed-pii-policy-" ~ randomUUID.toString);
    mkdirRecurse(root);
    scope (exit) if (exists(root)) rmdirRecurse(root);

    // A clean temp directory: the fixture is copied in, never read from the
    // repository checkout, so the checker exercises the same path a
    // downstream user copying the example would take.
    auto inputPath = buildPath(root, "notice.txt");
    write(inputPath, read(buildPath(repository,
        "examples/corpus/pii-policy/inputs/notice.txt")));

    auto report = runMode(executable, inputPath, root, "report", []);
    auto mask = runMode(executable, inputPath, root, "mask",
        ["--stage-option", "policy=text:mask"]);
    auto redact = runMode(executable, inputPath, root, "redact",
        ["--stage-option", "policy=text:redact", "--stage-option",
            "allow-redact=boolean:true"]);

    checkAgainstGolden(repository, report, "report");
    checkAgainstGolden(repository, mask, "mask");
    checkAgainstGolden(repository, redact, "redact");

    // report is audit-only: it must never alter the original content, byte
    // for byte.
    auto inputBytes = read(inputPath);
    need(cast(const(ubyte)[]) read(report.outputPath) == inputBytes,
        "report policy altered input bytes");

    // mask and redact must each be distinguishable from the original and
    // from each other -- three pairwise-distinct outputs for the same input.
    auto maskBytes = read(mask.outputPath);
    auto redactBytes = read(redact.outputPath);
    need(cast(const(ubyte)[]) inputBytes != cast(const(ubyte)[]) maskBytes,
        "mask output is identical to the original -- not distinguishable");
    need(cast(const(ubyte)[]) inputBytes != cast(const(ubyte)[]) redactBytes,
        "redact output is identical to the original -- not distinguishable");
    need(cast(const(ubyte)[]) maskBytes != cast(const(ubyte)[]) redactBytes,
        "mask and redact produced identical output -- not distinguishable");

    // mask preserves byte length (offset-stable `*` substitution); redact
    // does not (fixed-width `[REDACTED]` markers replace variable-length
    // spans), which is itself part of what makes the two modes
    // deterministically distinguishable from each other.
    need(maskBytes.length == inputBytes.length,
        "mask policy did not preserve byte length");
    need(redactBytes.length != inputBytes.length,
        "redact policy unexpectedly preserved byte length");

    // The JSON `--config` form (report/mask/redact.json) must compile and
    // run to the exact same golden as the equivalent `--stage` tokens.
    foreach (policy; ["report", "mask", "redact"]) {
        auto configOutput = buildPath(root, policy ~ "-config-out.txt");
        auto configSidecar = buildPath(root, policy ~ "-config-sidecar.json");
        auto command = [executable, "run", "--input", inputPath, "--output",
            configOutput, "--sidecar-output", configSidecar, "--config",
            buildPath(repository, "examples/pipelines/pii-policy/" ~ policy ~ ".json")];
        auto result = execute(command);
        need(result.status == 0, policy ~ " JSON-config recipe failed: " ~ result.output);
        auto expectedOutput = read(buildPath(repository,
            "examples/corpus/pii-policy/expected/" ~ policy ~ ".txt"));
        need(cast(const(ubyte)[]) read(configOutput) == expectedOutput,
            policy ~ " JSON-config output differs from the --stage-token form's golden");
    }

    // redact is opt-in only: the same policy without allow-redact must fail
    // to compile, not silently fall back to report/mask.
    expectRejected("redact without allow-redact opt-in", {
        auto command = [executable, "run", "--input", inputPath, "--output",
            buildPath(root, "redact-noopt-out.txt"), "--sidecar-output",
            buildPath(root, "redact-noopt-sidecar.json"), "--stage",
            "pii=pii-four-class", "--stage-option", "policy=text:redact",
            "--stage", "pub=document-metadata-publish"];
        auto result = execute(command);
        if (result.status != 0)
            throw new Exception("rejected, as expected");
    });
}

private void negativeMutants(string repository, string manifestText) {
    expectRejected("hash drift", {
        validateManifest(repository, parseJSON(manifestText.replace(
            "4467d4afb7d6177b75b3bd67797565637ed18d773308d867d54582903e086bdf",
            "0000000000000000000000000000000000000000000000000000000000000000")));
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
            "examples/corpus/pii-policy/inputs/notice.txt",
            "../../../etc/passwd")));
    });
    expectRejected("false de-identification-guarantee claim", {
        validateManifest(repository, parseJSON(manifestText.replace(
            `"deidentificationGuarantee": false`, `"deidentificationGuarantee": true`)));
    });
    expectRejected("copied-fixture provenance claim", {
        validateManifest(repository, parseJSON(manifestText.replace(
            `"kind": "wholly-new"`, `"kind": "copied"`)));
    });
}

int main(string[] args) {
    need(args.length == 2 || args.length == 3,
        "usage: check <release executable> [repository root]");
    auto executable = absolutePath(args[1]);
    auto repository = absolutePath(args.length == 3 ? args[2] : ".");
    auto manifestPath = buildPath(repository, "examples/corpus/pii-policy/manifest.json");
    auto manifestText = readText(manifestPath);
    auto manifest = parseJSON(manifestText);
    validateManifest(repository, manifest);
    negativeMutants(repository, manifestText);
    runRecipes(repository, executable);
    import std.stdio : writeln;
    writeln("pii-policy check: manifest, mutants, report/mask/redact recipes " ~
        "(--stage tokens and --config JSON), and sidecar audit content all pass");
    return 0;
}
