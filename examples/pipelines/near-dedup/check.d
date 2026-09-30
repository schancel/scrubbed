/// Release-active actual-binary check for the near-duplicate pruning example.
module near_dedup_check;

import std.algorithm : equal, sort;
import std.algorithm.searching : canFind, endsWith, startsWith;
import std.conv : to;
import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;
import std.file : SpanMode, copy, dirEntries, exists, isFile, mkdirRecurse,
    read, readText, rmdirRecurse, tempDir;
import std.json : JSONValue, parseJSON;
import std.path : absolutePath, baseName, buildPath;
import std.process : execute;
import std.string : replace;
import std.uuid : randomUUID;

import domain.document : DocumentId, SourceLocator;

version (Posix) {
    import core.stdc.stdlib : free;
    import core.sys.posix.stdlib : realpath;
    import std.string : fromStringz, toStringz;
}

private enum provenance = "Authored for scrubbed issue #506 by Shammah Chancellor.";
private enum expectedBucket = "band=1,key=8caffa8cf5b30161";
private enum documentMetadataPublishSuffixV1 = ".document-metadata.json";
private enum pruneNearDuplicatesDecisionSuffixV1 =
    ".prune-near-duplicates-decision.json";
private enum pruneNearDuplicatesDecisionSchemaV1 =
    "scrubbed-prune-near-duplicates-decision-v1";

private void need(bool condition, string label) {
    if (!condition) throw new Exception("near-dedup check: " ~ label);
}

private string digest(string path) {
    return toHexString!(LetterCase.lower)(sha256Of(read(path))).idup;
}

private string canonicalExisting(string path) {
    version (Posix) {
        auto resolved = realpath(path.toStringz, null);
        need(resolved !is null, "cannot resolve scratch root");
        scope(exit) free(resolved);
        return fromStringz(resolved).idup;
    } else return absolutePath(path);
}

private void expectRejected(string label, void delegate() mutation) {
    bool rejected;
    try mutation();
    catch (Exception) rejected = true;
    need(rejected, "negative mutant accepted: " ~ label);
}

private void validateManifest(string repository, JSONValue manifest) {
    need(manifest["schema"].str == "scrubbed.near-dedup-corpus.v1",
        "manifest schema");
    auto licensePath = manifest["licenseFile"].str;
    need(licensePath == "examples/corpus/near-dedup/LICENSE.txt" &&
        digest(buildPath(repository, licensePath)) ==
            "d05e83eb1213daac7371eee9bb40c8d06e767e37dc38f6f10b8f0b06d72708e0",
        "exact corpus license");
    need(manifest["claims"]["synthetic"].boolean &&
        !manifest["claims"]["trainingReady"].boolean &&
        !manifest["claims"]["physicallyDeletesDocuments"].boolean,
        "corpus claims");

    string[] declared;
    foreach (artifact; manifest["artifacts"].array) {
        auto path = artifact["path"].str;
        need(path.startsWith("examples/corpus/near-dedup/inputs/") &&
            !path.canFind(".."), "artifact path: " ~ path);
        need(artifact["mediaType"].str == "text/plain; charset=utf-8" &&
            artifact["provenance"].str == provenance &&
            artifact["license"].str == "MIT" &&
            artifact["expectedOutcome"].str.length != 0,
            "artifact metadata: " ~ path);
        need(isFile(buildPath(repository, path)) &&
            digest(buildPath(repository, path)) == artifact["sha256"].str,
            "artifact hash: " ~ path);
        declared ~= baseName(path);
    }
    declared.sort;
    need(declared.equal(["brief.txt", "distinct.txt", "expanded.txt"]),
        "fixture closure");

    auto recipes = manifest["recipes"].array;
    need(recipes.length == 3 && recipes[0]["id"].str == "default" &&
        recipes[0]["policy"].str == "keep-first" &&
        !recipes[0]["explicitPolicy"].boolean &&
        recipes[1]["id"].str == "keep-first" &&
        recipes[1]["explicitPolicy"].boolean &&
        recipes[2]["id"].str == "keep-longest" &&
        recipes[2]["explicitPolicy"].boolean,
        "recipe declarations");
}

private void negativeMutants(string repository, string manifestText) {
    auto briefHash = digest(buildPath(repository,
        "examples/corpus/near-dedup/inputs/brief.txt"));
    expectRejected("hash drift", {
        validateManifest(repository, parseJSON(manifestText.replace(briefHash,
            "0000000000000000000000000000000000000000000000000000000000000000")));
    });
    expectRejected("missing provenance", {
        validateManifest(repository, parseJSON(manifestText.replace(provenance, "")));
    });
    expectRejected("training-ready overclaim", {
        validateManifest(repository, parseJSON(manifestText.replace(
            `"trainingReady": false`, `"trainingReady": true`)));
    });
    expectRejected("physical-delete overclaim", {
        validateManifest(repository, parseJSON(manifestText.replace(
            `"physicallyDeletesDocuments": false`,
            `"physicallyDeletesDocuments": true`)));
    });
}

private string chooseInputRoot(string scratch) {
    foreach (i; 0 .. 256) {
        auto candidate = buildPath(scratch, "case-" ~ i.to!string, "inputs");
        auto brief = DocumentId.from(SourceLocator("local-files:v1", candidate,
            "brief.txt")).text;
        auto expanded = DocumentId.from(SourceLocator("local-files:v1", candidate,
            "expanded.txt")).text;
        if (brief < expanded) return candidate;
    }
    throw new Exception("near-dedup check: could not select deterministic policy fixture root");
}

private struct Result {
    string removedName;
    string representativeName;
    string decisionBytes;
}

private Result runPolicy(string repository, string executable, string inputRoot,
        string scratch, string id, string policy, bool explicitPolicy) {
    auto outputRoot = buildPath(scratch, "output-" ~ id);
    auto sidecarRoot = buildPath(scratch, "sidecars-" ~ id);
    string[] command = [executable, "run", "--input", inputRoot,
        "--output", outputRoot, "--sidecar-output", sidecarRoot,
        "--threads", "1", "--stage", "sig=similarity-signature-annotate",
        "--stage", "publish=document-metadata-publish", "--stage",
        "prune=prune-near-duplicates"];
    if (explicitPolicy)
        command ~= ["--stage-option", "policy=text:" ~ policy];
    auto execution = execute(command);
    need(execution.status == 0,
        id ~ " execution failed: " ~ execution.output);

    string[string] documentIds;
    foreach (name; ["brief.txt", "expanded.txt", "distinct.txt"]) {
        need(read(buildPath(outputRoot, name)) == read(buildPath(inputRoot, name)),
            id ~ " changed or removed primary output " ~ name);
        auto metadataPath = buildPath(sidecarRoot,
            name ~ documentMetadataPublishSuffixV1);
        need(isFile(metadataPath), id ~ " missing metadata for " ~ name);
        auto metadata = parseJSON(readText(metadataPath));
        need(metadata["version"].str == "document-metadata:v2",
            id ~ " metadata version for " ~ name);
        documentIds[name] = metadata["documentId"].str;
    }

    string[] decisions;
    foreach (entry; dirEntries(sidecarRoot, SpanMode.shallow, false))
        if (entry.isFile && entry.name.endsWith(pruneNearDuplicatesDecisionSuffixV1))
            decisions ~= entry.name;
    need(decisions.length == 1, id ~ " expected exactly one decision");
    auto decisionName = baseName(decisions[0]);
    auto removedName = decisionName[0 .. $ - pruneNearDuplicatesDecisionSuffixV1.length];
    need(removedName == "brief.txt" || removedName == "expanded.txt",
        id ~ " pruned the negative control");
    auto representativeName = removedName == "brief.txt" ?
        "expanded.txt" : "brief.txt";

    auto bytes = readText(decisions[0]);
    auto decision = parseJSON(bytes);
    need(decision["schema"].str == pruneNearDuplicatesDecisionSchemaV1 &&
        decision["removed_document_id"].str == documentIds[removedName] &&
        decision["representative_id"].str == documentIds[representativeName] &&
        decision["bucket_identity"].str == expectedBucket,
        id ~ " decision contents");
    need(!exists(buildPath(sidecarRoot,
        "distinct.txt" ~ pruneNearDuplicatesDecisionSuffixV1)),
        id ~ " negative control decision");
    return Result(removedName, representativeName, bytes);
}

private void runRecipes(string repository, string executable) {
    auto scratch = buildPath(tempDir, "scrubbed-near-dedup-" ~ randomUUID.toString);
    mkdirRecurse(scratch);
    scope(exit) if (exists(scratch)) rmdirRecurse(scratch);
    scratch = canonicalExisting(scratch);
    auto inputRoot = chooseInputRoot(scratch);
    mkdirRecurse(inputRoot);
    foreach (name; ["brief.txt", "expanded.txt", "distinct.txt"])
        copy(buildPath(repository, "examples/corpus/near-dedup/inputs", name),
            buildPath(inputRoot, name));

    auto defaultResult = runPolicy(repository, executable, inputRoot, scratch,
        "default", "keep-first", false);
    auto first = runPolicy(repository, executable, inputRoot, scratch,
        "keep-first", "keep-first", true);
    auto longest = runPolicy(repository, executable, inputRoot, scratch,
        "keep-longest", "keep-longest", true);

    need(defaultResult.decisionBytes == first.decisionBytes,
        "default is not keep-first");
    need(first.representativeName == "brief.txt" &&
        first.removedName == "expanded.txt",
        "keep-first did not keep the lowest document ID");
    need(longest.representativeName == "expanded.txt" &&
        longest.removedName == "brief.txt",
        "keep-longest did not keep the longer document");
    need(first.representativeName != longest.representativeName,
        "policies did not produce different survivors");
}

int main(string[] args) {
    need(args.length == 2 || args.length == 3,
        "usage: check <release executable> [repository root]");
    auto executable = absolutePath(args[1]);
    auto repository = absolutePath(args.length == 3 ? args[2] : ".");
    auto manifestPath = buildPath(repository,
        "examples/corpus/near-dedup/manifest.json");
    auto manifestText = readText(manifestPath);
    validateManifest(repository, parseJSON(manifestText));
    negativeMutants(repository, manifestText);
    runRecipes(repository, executable);
    import std.stdio : writeln;
    writeln("near-dedup check: manifest, mutants, default/keep-first/" ~
        "keep-longest policies, decisions, and unchanged outputs pass");
    return 0;
}
