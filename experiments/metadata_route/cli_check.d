/// Release-active proof against the shipping route-metadata executable.
module experiments.metadata_route.cli_check;

import domain.document : Document, OutputName, SourceLocator;
import effects.local_manifest : LocalManifest, SinkKey, SinkState,
    configDigest, inputDigest;
import std.algorithm.searching : canFind;
import std.conv : to, octal;
import std.file : copy, exists, mkdir, read, readText, remove, rmdirRecurse, symlink,
    tempDir, write;
import std.json : parseJSON;
import std.path : buildPath;
import std.process : execute;
import std.stdio : writeln;
import std.string : toStringz;
import std.uuid : randomUUID;
import std.digest.sha : sha256Of;
import core.sys.posix.unistd : link;
import core.sys.posix.sys.stat : chmod, stat, stat_t;
import core.sys.posix.sys.resource : getrusage, RUSAGE_CHILDREN, rusage;
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
    need(args.length == 2 || (args.length == 3 && args[2] == "--cap"),
        "expected shipping binary path and optional --cap");
    auto canonicalTemp = realpath(tempDir().toStringz, null);
    need(canonicalTemp !is null, "temporary directory resolution");
    scope(exit) free(canonicalTemp);
    auto root = buildPath(canonicalTemp.fromStringz.idup,
        "scrubbed-metadata-route-" ~ randomUUID().toString);
    mkdir(root);
    scope(exit) rmdirRecurse(root);
    if (args.length == 3) {
        auto inputRoot = buildPath(root, "cap-input");
        auto contentRoot = buildPath(root, "cap-content");
        auto metadataRoot = buildPath(root, "cap-metadata");
        auto capDb = buildPath(root, "cap.db");
        mkdir(inputRoot); mkdir(contentRoot); mkdir(metadataRoot);
        foreach (i; 0 .. 65_537)
            write(buildPath(inputRoot, i.to!string ~ ".html"), "");
        auto result = execute([args[1], "route-metadata", "--input", inputRoot,
            "--content-output", contentRoot, "--metadata-output", metadataRoot,
            "--manifest", capDb]);
        need(result.status == 2 && result.output == "scrubbed: route-refused\n",
            "cap+1 refusal");
        need(!exists(capDb) && !exists(buildPath(contentRoot, "0.html")) &&
            !exists(buildPath(metadataRoot, "0.html")),
            "cap+1 caused manifest or output publication");
        rusage usage;
        need(getrusage(RUSAGE_CHILDREN, &usage) == 0 &&
            // LDC's Darwin rusage binding exposes the 14 longs after time
            // as opaque; Darwin's first is ru_maxrss, measured in bytes.
            usage.ru_opaque[0] < 512L * 1024 * 1024,
            "cap+1 child exceeded 512 MiB RSS ceiling");
        writeln("metadata route cap+1 check: 65,537 entries refused before publication");
        return;
    }
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
    auto oldContentInode = inode(contentFile);
    auto oldMetadataInode = inode(metadataFile);
    auto variant = buildPath(root, "scrubbed-variant");
    copy(args[1], variant);
    need(chmod(variant.toStringz, octal!"755") == 0,
        "variant executable permission");
    auto signing = execute(["/usr/bin/codesign", "--force", "--sign", "-",
        "--identifier", "scrubbed-route-variant", variant]);
    need(signing.status == 0, "variant binary signing failed");
    auto variantRoute = [variant] ~ route;
    auto changedBinary = execute(variantRoute);
    need(changedBinary.status == 2 &&
        changedBinary.output == "scrubbed: route-refused\n",
        "changed binary incorrectly verified old sinks, exit " ~
            changedBinary.status.to!string ~ " output " ~ changedBinary.output);
    changedBinary = execute(variantRoute ~ "--retry");
    need(changedBinary.status == 0 && inode(contentFile) != oldContentInode &&
        inode(metadataFile) != oldMetadataInode,
        "changed binary did not revise both sink identities");
    checks += 2;
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
    auto ownerA = buildPath(root, "owner-a");
    auto ownerB = buildPath(root, "owner-b");
    auto ownerContent = buildPath(root, "owner-content");
    auto ownerMetadata = buildPath(root, "owner-metadata");
    auto ownerDb = buildPath(root, "owner.db");
    mkdir(ownerA); mkdir(ownerB); mkdir(ownerContent); mkdir(ownerMetadata);
    write(buildPath(ownerA, "shared.html"), html);
    write(buildPath(ownerB, "shared.html"), html);
    auto ownerRoute = ["route-metadata", "--input", ownerA,
        "--content-output", ownerContent, "--metadata-output", ownerMetadata,
        "--manifest", ownerDb];
    call(ownerRoute, 0);
    auto ownerContentFile = buildPath(ownerContent, "shared.html");
    auto ownerMetadataFile = buildPath(ownerMetadata, "shared.html");
    auto ownerContentInode = inode(ownerContentFile);
    auto ownerMetadataInode = inode(ownerMetadataFile);
    auto ownerContentBytes = readText(ownerContentFile);
    auto ownerMetadataBytes = readText(ownerMetadataFile);
    auto executableHash = sha256Of(cast(const(ubyte)[]) read(args[1]));
    ubyte[32] routeHash(string domain, string config) {
        ubyte[] material = (cast(const(ubyte)[]) (domain ~ config)).dup;
        material ~= executableHash[];
        return configDigest(material);
    }
    auto ownerDocument = Document(SourceLocator("local-html:v1", ownerA,
        "shared.html"), OutputName("shared.html"));
    auto ownerInput = inputDigest(cast(const(ubyte)[]) html);
    auto ownerContentKey = SinkKey(ownerDocument.id, ownerInput,
        routeHash("route-content:v2:", "normalize-line-endings,strip-control"),
        "local-content:v1");
    auto ownerMetadataKey = SinkKey(ownerDocument.id, ownerInput,
        routeHash("route-metadata:v2:", "html-metadata"),
        "local-metadata:v1");
    scope ownerManifest = new LocalManifest(ownerDb);
    auto priorContentRow = ownerManifest.lookup(ownerContentKey).get;
    auto priorMetadataRow = ownerManifest.lookup(ownerMetadataKey).get;
    need(priorContentRow.state == SinkState.committed &&
        priorMetadataRow.state == SinkState.committed, "initial owner ledger rows");
    ownerManifest.close();
    ownerRoute[2] = ownerB;
    call(ownerRoute ~ "--retry", 2);
    need(inode(ownerContentFile) == ownerContentInode &&
        inode(ownerMetadataFile) == ownerMetadataInode &&
        readText(ownerContentFile) == ownerContentBytes &&
        readText(ownerMetadataFile) == ownerMetadataBytes,
        "cross-document route changed prior outputs");
    scope reopenedOwner = new LocalManifest(ownerDb);
    auto afterContentRow = reopenedOwner.lookup(ownerContentKey).get;
    auto afterMetadataRow = reopenedOwner.lookup(ownerMetadataKey).get;
    auto otherDocument = Document(SourceLocator("local-html:v1", ownerB,
        "shared.html"), OutputName("shared.html"));
    auto otherContentKey = ownerContentKey;
    otherContentKey.document = otherDocument.id;
    auto otherMetadataKey = ownerMetadataKey;
    otherMetadataKey.document = otherDocument.id;
    need(afterContentRow.state == priorContentRow.state &&
        afterContentRow.attempt == priorContentRow.attempt &&
        afterMetadataRow.state == priorMetadataRow.state &&
        afterMetadataRow.attempt == priorMetadataRow.attempt &&
        reopenedOwner.lookup(otherContentKey).isNull &&
        reopenedOwner.lookup(otherMetadataKey).isNull,
        "cross-document route changed prior ledger rows");
    reopenedOwner.close();
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
