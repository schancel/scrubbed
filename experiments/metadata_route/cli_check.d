/// Release-active proof against the shipping route-metadata executable.
module experiments.metadata_route.cli_check;

import domain.document : Document, OutputName, SourceLocator;
import std.algorithm.searching : canFind;
import std.conv : to, octal;
import std.file : exists, mkdir, readText, remove, rmdirRecurse, symlink,
    tempDir, write;
import std.json : parseJSON;
import std.path : buildPath;
import std.process : execute;
import std.stdio : writeln;
import std.string : toStringz;
import std.uuid : randomUUID;
import core.sys.posix.unistd : link;
import core.sys.posix.sys.stat : chmod, stat, stat_t;
import core.stdc.stdlib : free;
import std.string : fromStringz;

private extern(C) char* realpath(const(char)*, char*);

private ulong inode(string path) {
    stat_t entry;
    need(stat(path.toStringz, &entry) == 0, "stat output");
    return cast(ulong) entry.st_ino;
}

private void need(bool okay, string message) {
    if (!okay) throw new Exception("metadata route check: " ~ message);
}

private string html = `<html><head><title>Fallback</title>` ~
    `<meta property="og:title" content="Primary">` ~
    `<meta name="author" content="Ada">` ~
    `<meta name="date" content="2024-02-29">` ~
    `<link rel="canonical" href="https://example.test/page">` ~
    `</head><body>Alpha` ~ "\r\n" ~ `Beta</body></html>`;

void main(string[] args) {
    need(args.length == 2, "expected shipping binary path");
    auto canonicalTemp = realpath(tempDir().toStringz, null);
    need(canonicalTemp !is null, "temporary directory resolution");
    scope(exit) free(canonicalTemp);
    auto root = buildPath(canonicalTemp.fromStringz.idup,
        "scrubbed-metadata-route-" ~ randomUUID().toString);
    mkdir(root);
    scope(exit) rmdirRecurse(root);
    size_t checks;
    auto call(string[] argv, int expected) {
        auto result = execute([args[1]] ~ argv);
        need(result.status == expected, "call " ~ checks.to!string ~ " exit " ~
            result.status.to!string ~ " expected " ~ expected.to!string);
        foreach (secret; ["PRIVATE_SOURCE_CANARY", "https://private.invalid/token"])
            need(!result.output.canFind(secret), "diagnostic leak");
        ++checks;
        return result.output;
    }
    auto content = buildPath(root, "content");
    auto metadata = buildPath(root, "metadata");
    mkdir(content); mkdir(metadata);
    auto input = buildPath(root, "PRIVATE_SOURCE_CANARY.html");
    auto db = buildPath(root, "manifest.db");
    write(input, html);
    auto route = ["route-metadata", "--input", input, "--content-output", content,
        "--metadata-output", metadata, "--manifest", db];
    need(call(["--help"], 0).canFind("route-metadata"), "top-level help");
    need(call(["route-metadata", "--help"], 0).canFind("--content-output"),
        "route help");
    call(["route-metadata", "--bogus", "PRIVATE_SOURCE_CANARY"], 2);
    call(route, 0);
    auto contentFile = buildPath(content, "PRIVATE_SOURCE_CANARY.html");
    auto metadataFile = buildPath(metadata, "PRIVATE_SOURCE_CANARY.html");
    need(readText(contentFile).canFind("Alpha\nBeta"), "content filter absent");
    auto json = parseJSON(readText(metadataFile));
    auto expectedId = Document(SourceLocator("local-html:v1", input,
        "PRIVATE_SOURCE_CANARY.html"), OutputName("PRIVATE_SOURCE_CANARY.html")).id.text;
    need(json["documentId"].str == expectedId &&
        json["version"].str == "metadata-json:v1", "typed metadata identity");
    foreach (field, expected; ["title": "Primary", "author": "Ada",
            "date": "2024-02-29", "url": "https://example.test/page"])
        need(json["fields"][field]["value"].str == expected, "stage field " ~ field);
    need(!readText(metadataFile).canFind("PRIVATE_SOURCE_CANARY") &&
        !readText(metadataFile).canFind("https://private.invalid/token"),
        "path or secret in metadata");
    auto priorContent = readText(contentFile);
    auto priorMetadata = readText(metadataFile);
    call(route, 0);
    need(readText(contentFile) == priorContent &&
        readText(metadataFile) == priorMetadata, "verified replay changed bytes");
    auto tree = buildPath(root, "tree");
    mkdir(tree); mkdir(buildPath(tree, "chapter"));
    write(buildPath(tree, "chapter", "one.html"), html);
    write(buildPath(tree, "two.htm"), html);
    auto treeContent = buildPath(root, "tree-content");
    auto treeMetadata = buildPath(root, "tree-metadata");
    mkdir(treeContent); mkdir(treeMetadata);
    auto treeDb = buildPath(root, "tree.db");
    auto treeRoute = ["route-metadata", "--input", tree,
        "--content-output", treeContent, "--metadata-output", treeMetadata,
        "--manifest", treeDb];
    call(treeRoute, 0);
    foreach (contentFailure; [true, false]) {
        auto tag = contentFailure ? "content-fail" : "metadata-fail";
        auto sample = buildPath(root, tag ~ ".html");
        auto left = buildPath(root, tag ~ "-content");
        auto right = buildPath(root, tag ~ "-metadata");
        auto ledger = buildPath(root, tag ~ ".db");
        write(sample, html);
        mkdir(left); mkdir(right);
        auto failedRoot = contentFailure ? left : right;
        auto survivor = buildPath(contentFailure ? right : left, tag ~ ".html");
        auto failed = buildPath(failedRoot, tag ~ ".html");
        auto flags = ["route-metadata", "--input", sample,
            "--content-output", left, "--metadata-output", right,
            "--manifest", ledger];
        need(chmod(failedRoot.toStringz, octal!"555") == 0, "chmod failure fixture");
        try {
            call(flags, 1);
            need(!exists(failed) && exists(survivor), "one-sink outcome " ~ tag);
        } finally {
            need(chmod(failedRoot.toStringz, octal!"755") == 0, "chmod restore");
        }
        auto priorInode = inode(survivor);
        call(flags, 1); // Unresolved sink never silently recovers.
        call(flags ~ "--retry", 0);
        need(exists(failed) && inode(survivor) == priorInode,
            "retry replaced verified sibling " ~ tag);
    }
    foreach (name; ["chapter/one.html", "two.htm"]) {
        need(exists(buildPath(treeContent, name)) &&
            exists(buildPath(treeMetadata, name)), "nested mirrored name " ~ name);
        auto record = parseJSON(readText(buildPath(treeMetadata, name)));
        auto id = Document(SourceLocator("local-html:v1", tree, name),
            OutputName(name)).id.text;
        need(record["documentId"].str == id, "nested typed identity " ~ name);
    }
    call(treeRoute, 0);
    auto other = buildPath(root, "other");
    mkdir(other);
    call(["route-metadata", "--input", tree, "--content-output", tree,
        "--metadata-output", other, "--manifest", buildPath(root, "bad.db")], 2);
    auto aliasPath = buildPath(root, "alias");
    symlink(metadata, aliasPath);
    call(["route-metadata", "--input", input, "--content-output", content,
        "--metadata-output", aliasPath, "--manifest", db], 2);
    auto hard = buildPath(root, "hard.html");
    need(link(input.toStringz, hard.toStringz) == 0, "hardlink fixture");
    call(["route-metadata", "--input", hard, "--content-output", content,
        "--metadata-output", metadata, "--manifest", db], 2);
    remove(hard);
    auto collisionInput = buildPath(root, "collision.html");
    write(collisionInput, html);
    auto collisionOutput = buildPath(content, "collision.html");
    auto prior = buildPath(root, "prior-file");
    write(prior, "prior");
    need(link(prior.toStringz, collisionOutput.toStringz) == 0,
        "destination hardlink fixture");
    call(["route-metadata", "--input", collisionInput,
        "--content-output", content, "--metadata-output", metadata,
        "--manifest", db, "--retry"], 2);
    need(!exists(buildPath(metadata, "collision.html")) &&
        readText(prior) == "prior", "alias published sibling");
    remove(collisionOutput);
    symlink(prior, collisionOutput);
    call(["route-metadata", "--input", collisionInput,
        "--content-output", content, "--metadata-output", metadata,
        "--manifest", db], 2);
    need(!exists(buildPath(metadata, "collision.html")), "symlink published sibling");
    auto bad = buildPath(root, "bad.html");
    write(bad, cast(const(ubyte)[]) [cast(ubyte) 0xff]);
    auto badRoute = ["route-metadata", "--input", bad, "--content-output", content,
        "--metadata-output", metadata, "--manifest", db];
    call(badRoute, 1);
    need(!exists(buildPath(content, "bad.html")) &&
        !exists(buildPath(metadata, "bad.html")), "bad UTF-8 published");
    auto large = buildPath(root, "large.html");
    write(large, new char[65 * 1024]);
    call(["route-metadata", "--input", large, "--content-output", content,
        "--metadata-output", metadata, "--manifest", db], 1);
    need(!exists(buildPath(content, "large.html")) &&
        !exists(buildPath(metadata, "large.html")), "raw cap published");
    auto legacy = buildPath(root, "legacy.txt");
    auto legacyOutput = buildPath(root, "legacy-out.txt");
    write(legacy, "hello\r\n");
    call(["run", "--input", legacy, "--output", legacyOutput], 0);
    need(readText(legacyOutput) == "hello\n", "legacy run changed");
    writeln("metadata route CLI check: ", checks, " actual-binary calls");
}
