/// Ensures every pipeline gallery directory owns a checker and that the
/// gallery workflow discovers pipeline checkers rather than maintaining a
/// second, drift-prone list.
module gallery_closure_check;

import std.algorithm : equal, sort;
import std.algorithm.searching : canFind;
import std.file : SpanMode, dirEntries, exists, isDir, mkdirRecurse, readText,
    rmdirRecurse, tempDir, write;
import std.path : absolutePath, baseName, buildPath;
import std.uuid : randomUUID;

private enum requiredPipelines = [
    "clean-web-document",
    "crawl",
    "custom-composition",
    "extract-formats",
    "near-dedup",
    "pii-policy",
    "quickstart",
    "route-metadata"
];

private void need(bool condition, string label) {
    if (!condition) throw new Exception("gallery closure: " ~ label);
}

private string[] pipelineDirectories(string repository) {
    string[] result;
    auto root = buildPath(repository, "examples/pipelines");
    foreach (entry; dirEntries(root, SpanMode.shallow, false))
        if (entry.isDir) result ~= baseName(entry.name);
    result.sort;
    return result;
}

private string[] missingCheckers(string repository) {
    string[] result;
    foreach (name; pipelineDirectories(repository))
        if (!exists(buildPath(repository, "examples/pipelines", name, "check.d")))
            result ~= name;
    return result;
}

private void validateRepository(string repository, string workflowText) {
    auto directories = pipelineDirectories(repository);
    auto required = requiredPipelines.dup;
    required.sort;
    need(directories.equal(required), "required pipeline directory set drifted");
    need(missingCheckers(repository).length == 0,
        "pipeline directory without check.d");
    need(exists(buildPath(repository, "examples/cli/check.d")),
        "missing CLI checker");
    need(workflowText.canFind("find examples/pipelines") &&
        workflowText.canFind("-name check.d") &&
        workflowText.canFind("examples/cli/check.d") &&
        workflowText.canFind("gallery_closure_check.d") &&
        workflowText.canFind("--self-test"),
        "workflow does not discover and guard the full gallery");
}

private void selfTest() {
    auto root = buildPath(tempDir, "scrubbed-gallery-closure-" ~ randomUUID.toString);
    mkdirRecurse(buildPath(root, "examples/pipelines/registered"));
    mkdirRecurse(buildPath(root, "examples/pipelines/unregistered"));
    scope(exit) if (exists(root)) rmdirRecurse(root);
    write(buildPath(root, "examples/pipelines/registered/check.d"),
        "module registered_check;\n");
    auto missing = missingCheckers(root);
    need(missing.length == 1 && missing[0] == "unregistered",
        "missing-checker mutant was not rejected");
    write(buildPath(root, "examples/pipelines/unregistered/check.d"),
        "module unregistered_check;\n");
    need(missingCheckers(root).length == 0,
        "complete synthetic gallery was rejected");
}

int main(string[] args) {
    need(args.length == 2 || args.length == 3,
        "usage: gallery_closure_check <repository> [--self-test]");
    auto repository = absolutePath(args[1]);
    auto workflow = readText(buildPath(repository,
        ".github/workflows/examples-gallery-check.yml"));
    validateRepository(repository, workflow);
    if (args.length == 3) {
        need(args[2] == "--self-test", "unknown option");
        selfTest();
    }
    import std.stdio : writeln;
    writeln("gallery closure: all pipeline and CLI checkers are CI-discovered");
    return 0;
}
