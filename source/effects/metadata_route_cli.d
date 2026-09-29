/// Opt-in local HTML route. This is CLI orchestration, not a two-file commit.
module effects.metadata_route_cli;

import composition.compiler : compileJob;
import composition.executor : runCompiledStage;
import composition.job_executor : runCompiledJob;
import content.pieces : Content, ContentPiece;
import core.stdc.errno : errno, EINTR, ENOENT;
import core.stdc.stdlib : free;
import core.sys.posix.fcntl : open, O_RDONLY, O_NOFOLLOW;
import core.sys.posix.stdlib : realpath;
import core.sys.posix.sys.stat : fstat, lstat, stat, stat_t, S_ISDIR, S_ISREG, S_ISLNK;
import core.sys.posix.unistd : close, posixRead = read;
import domain.document : Document, OutputName, SourceLocator;
import effects.atomic_piece_sink : OutputPolicyViolation;
import effects.cli_option_parsing : nextOption;
import effects.document_metadata_publish_stage;
import effects.html_metadata_annotate_stage : htmlMetadataAnnotateStageKeyV1;
import effects.html_tree : defaultExtractHtmlBytes;
import effects.independent_sinks : IndependentLocalSinks, IndependentPayloads,
    IndependentSinkFailure, contentSinkKey, metadataSinkKey;
import effects.local_manifest : LocalManifest, SinkKey, SinkState, configDigest,
    inputDigest;
import job.legacy : lowerLegacyNames;
import job.spec : JobSpec, JobStageSpec;
import crypto.sha256 : Sha256;
import stages.contract : EventKind, StageDocument;
import std.algorithm.sorting : sort;
import std.file : SpanMode, dirEntries, mkdir, read, thisExePath;
import std.path : absolutePath, baseName, buildNormalizedPath, buildPath,
    dirName, extension, relativePath;
import std.stdio : stderr;
import std.string : fromStringz, indexOf, split, startsWith, toLower, toStringz;
import std.utf : validate;

private struct Options {
    string input, contentRoot, metadataRoot, manifest;
    string filters = "normalize-line-endings,strip-control";
    bool retry;
    bool hasInput, hasContent, hasMetadata, hasManifest, hasFilters;
}

private enum size_t maxRouteFiles = 65_536;
private enum size_t maxRouteNameBytes = 16 * 1024 * 1024;

/// Bind both independent sink revisions to the running binary, as the v1
/// single-sink CLI does. Check the opened inode/size before and after hashing.
private ubyte[32] runningExecutableDigest() {
    auto path = thisExePath();
    if (!path.length) throw new Exception("running executable unavailable");
    stat_t before, opened, after;
    if (lstat(path.toStringz, &before) != 0 || !S_ISREG(before.st_mode))
        throw new Exception("running executable is not a plain file");
    int fd = open(path.toStringz, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) throw new Exception("running executable cannot be opened");
    scope(exit) close(fd);
    if (fstat(fd, &opened) != 0 || !S_ISREG(opened.st_mode) ||
        before.st_dev != opened.st_dev || before.st_ino != opened.st_ino ||
        before.st_size != opened.st_size)
        throw new Exception("running executable changed before hashing");
    auto digest = Sha256.create;
    ubyte[64 * 1024] buffer;
    ulong total;
    while (true) {
        auto count = posixRead(fd, buffer.ptr, buffer.length);
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) throw new Exception("running executable read failed");
        if (count == 0) break;
        digest.put(buffer[0 .. cast(size_t) count]);
        total += cast(ulong) count;
    }
    if (lstat(path.toStringz, &after) != 0 ||
        opened.st_dev != after.st_dev || opened.st_ino != after.st_ino ||
        opened.st_size != after.st_size || total != cast(ulong) opened.st_size)
        throw new Exception("running executable changed while hashing");
    return digest.finish();
}

private ubyte[32] routeConfigDigest(string domain, string config,
    ubyte[32] executable) {
    ubyte[] identity = (cast(const(ubyte)[]) (domain ~ config)).dup;
    identity ~= executable[];
    return configDigest(identity);
}

private bool parseOptions(const string[] args, ref Options o) {
    for (size_t i; i < args.length; ) {
        if (args[i] == "--retry") {
            if (o.retry) return false;
            o.retry = true;
            ++i;
            continue;
        }
        auto parsed = nextOption(args, i);
        if (!parsed.ok) return false;
        string flag = parsed.flag;
        string value = parsed.value;
        switch (flag) {
        case "--input":
            if (o.hasInput) return false;
            o.input = value; o.hasInput = true; break;
        case "--content-output":
            if (o.hasContent) return false;
            o.contentRoot = value; o.hasContent = true; break;
        case "--metadata-output":
            if (o.hasMetadata) return false;
            o.metadataRoot = value; o.hasMetadata = true; break;
        case "--manifest":
            if (o.hasManifest) return false;
            o.manifest = value; o.hasManifest = true; break;
        case "--filters":
            if (o.hasFilters) return false;
            o.filters = value; o.hasFilters = true; break;
        default: return false;
        }
    }
    return o.hasInput && o.hasContent && o.hasMetadata && o.hasManifest;
}

private string clean(string path) {
    if (!path.length || path.indexOf('\0') >= 0)
        throw new OutputPolicyViolation("invalid route path");
    return buildNormalizedPath(absolutePath(path));
}

private bool within(string child, string parent) {
    return child == parent || child.startsWith(parent == "/" ? parent : parent ~ "/");
}

private stat_t checkedEntry(string path, bool directory, bool mayBeAbsent = false) {
    stat_t entry;
    if (lstat(path.toStringz, &entry) != 0) {
        if (mayBeAbsent && errno == ENOENT) return stat_t.init;
        throw new OutputPolicyViolation("route path cannot be inspected");
    }
    if (S_ISLNK(entry.st_mode) || (directory ? !S_ISDIR(entry.st_mode) :
        !S_ISREG(entry.st_mode)))
        throw new OutputPolicyViolation("route path has unsafe type");
    if (!directory && entry.st_nlink != 1)
        throw new OutputPolicyViolation("route file has alias");
    return entry;
}

/// Issue #458: this used to walk every ancestor directory up to `/`,
/// rejecting any symlink along the way -- which false-refused on ordinary
/// OS-level indirection the caller never controls and can't avoid, such as
/// macOS's `/tmp` -> `/private/tmp` and `/var` -> `/private/var`. The actual
/// protection this route needs is that the caller's own root -- the exact
/// directory named by `--input`/`--content-output`/`--metadata-output`, or
/// holding `--manifest` -- is itself a real, symlink-free directory; a
/// symlink introduced *within* that root (nested content) is still caught
/// separately, by `checkedParent`'s walk down to each target and by the
/// input tree's own `entry.isSymlink` rejection below. So this now checks
/// only the root itself, not any OS-level ancestor above it.
private void checkedRoot(string path) {
    checkedEntry(path, true);
}

/// Validates `path` itself exactly as `checkedRoot` does, then resolves it
/// to its canonical, fully symlink-free form (the same `realpath` idiom
/// `source/cli.d`'s `canonicalExisting` uses). `preflight` re-anchors every
/// route root to this resolved form before comparing, walking, or handing
/// any of them onward, so no OS-level ancestor symlink above a root --
/// issue #458's macOS `/tmp` -> `/private/tmp` case -- can survive to
/// confuse the overlap/alias checks below, `checkedParent`'s walk from a
/// root down to a target, or `effects.independent_sinks`' own ancestor
/// check once `contentRoot`/`metadataRoot` reach it. A symlink at `path`
/// itself is still caught by `checkedRoot`, before any resolution happens.
private string resolvedRoot(string path) {
    checkedRoot(path);
    auto resolved = realpath(path.toStringz, null);
    if (resolved is null)
        throw new OutputPolicyViolation("route path cannot be resolved");
    scope(exit) free(resolved);
    return resolved.fromStringz.idup;
}

private void checkedParent(string root, string relative, bool create) {
    auto cursor = root;
    auto parts = relative.split('/');
    foreach (part; parts[0 .. $ - 1]) {
        if (!part.length || part == "." || part == ".." || part.indexOf('\\') >= 0)
            throw new OutputPolicyViolation("unsafe relative route");
        cursor = buildPath(cursor, part);
        stat_t entry;
        if (lstat(cursor.toStringz, &entry) != 0) {
            if (errno != ENOENT) throw new OutputPolicyViolation("route parent inspection failed");
            if (create) {
                mkdir(cursor);
                checkedEntry(cursor, true);
            }
        } else if (S_ISLNK(entry.st_mode) || !S_ISDIR(entry.st_mode)) {
            throw new OutputPolicyViolation("unsafe route parent");
        }
    }
}

private void checkedTarget(string root, string relative, bool createParent) {
    checkedRoot(root);
    auto parts = relative.split('/');
    foreach (part; parts)
        if (!part.length || part == "." || part == ".." || part.indexOf('\\') >= 0 ||
            part.indexOf('\0') >= 0)
            throw new OutputPolicyViolation("unsafe relative route");
    checkedParent(root, relative, createParent);
    auto target = buildPath(root, relative);
    checkedEntry(target, false, true);
}

private bool sameInode(string a, string b) {
    stat_t left, right;
    return stat(a.toStringz, &left) == 0 && stat(b.toStringz, &right) == 0 &&
        left.st_dev == right.st_dev && left.st_ino == right.st_ino;
}

private struct Input {
    string path, name;
}

private Input[] preflight(ref Options o) {
    o.input = clean(o.input);
    o.contentRoot = clean(o.contentRoot);
    o.metadataRoot = clean(o.metadataRoot);
    o.manifest = clean(o.manifest);
    o.contentRoot = resolvedRoot(o.contentRoot);
    o.metadataRoot = resolvedRoot(o.metadataRoot);
    o.manifest = buildPath(resolvedRoot(dirName(o.manifest)), baseName(o.manifest));
    stat_t root;
    if (lstat(o.input.toStringz, &root) != 0 || S_ISLNK(root.st_mode))
        throw new OutputPolicyViolation("invalid input root");
    bool tree = S_ISDIR(root.st_mode);
    if (!tree && (!S_ISREG(root.st_mode) || root.st_nlink != 1))
        throw new OutputPolicyViolation("invalid input file");
    o.input = tree ? resolvedRoot(o.input) :
        buildPath(resolvedRoot(dirName(o.input)), baseName(o.input));
    if (within(o.contentRoot, o.metadataRoot) ||
        within(o.metadataRoot, o.contentRoot) ||
        within(o.contentRoot, o.input) || within(o.metadataRoot, o.input) ||
        within(o.input, o.contentRoot) || within(o.input, o.metadataRoot) ||
        within(o.manifest, o.input) || within(o.manifest, o.contentRoot) ||
        within(o.manifest, o.metadataRoot) ||
        within(o.input, o.manifest) || within(o.contentRoot, o.manifest) ||
        within(o.metadataRoot, o.manifest))
        throw new OutputPolicyViolation("route paths overlap");
    foreach (suffix; ["", "-wal", "-shm"]) {
        auto companion = o.manifest ~ suffix;
        checkedEntry(companion, false, true);
        if (sameInode(companion, o.input) || sameInode(companion, o.contentRoot) ||
            sameInode(companion, o.metadataRoot))
            throw new OutputPolicyViolation("manifest alias");
    }
    Input[] files;
    size_t nameBytes;
    void admit(string path, string relative) {
        if (files.length == maxRouteFiles)
            throw new OutputPolicyViolation("route file admission limit");
        auto suffix = extension(path).toLower;
        if (suffix != ".html" && suffix != ".htm")
            throw new OutputPolicyViolation("route accepts HTML files only");
        auto name = OutputName(relative).text;
        if (name.length > maxRouteNameBytes - nameBytes)
            throw new OutputPolicyViolation("route name admission limit");
        nameBytes += name.length;
        files ~= Input(path, name);
    }
    if (tree) {
        foreach (entry; dirEntries(o.input, SpanMode.depth, false)) {
            auto path = clean(entry.name);
            if (entry.isSymlink) throw new OutputPolicyViolation("symlink in input tree");
            if (entry.isDir) { checkedEntry(path, true); continue; }
            checkedEntry(path, false);
            admit(path, relativePath(path, o.input));
        }
    } else admit(o.input, baseName(o.input));
    bool[string] names;
    foreach (ref file; files) {
        if (file.name in names) throw new OutputPolicyViolation("duplicate logical output name");
        names[file.name] = true;
        checkedTarget(o.contentRoot, file.name, false);
        checkedTarget(o.metadataRoot, file.name, false);
        auto content = buildPath(o.contentRoot, file.name);
        auto metadata = buildPath(o.metadataRoot, file.name);
        if (sameInode(content, metadata) || sameInode(content, file.path) ||
            sameInode(metadata, file.path))
            throw new OutputPolicyViolation("route file alias");
        foreach (companionSuffix; ["", "-wal", "-shm"])
            if (sameInode(o.manifest ~ companionSuffix, content) ||
                sameInode(o.manifest ~ companionSuffix, metadata) ||
                sameInode(o.manifest ~ companionSuffix, file.path))
                throw new OutputPolicyViolation("route manifest alias");
    }
    files.sort!((a, b) => a.name < b.name);
    return files;
}

private bool recordedFailure(LocalManifest manifest, Document document,
    ubyte[32] inputHash, ubyte[32] contentHash, ubyte[32] metadataHash) {
    bool failed;
    foreach (item; [SinkKey(document.id, inputHash, contentHash, contentSinkKey),
        SinkKey(document.id, inputHash, metadataHash, metadataSinkKey)]) {
        auto row = manifest.lookup(item);
        if (row.isNull || row.get.state == SinkState.planned) return false;
        if (row.get.state == SinkState.failed || row.get.state == SinkState.uncertain)
            failed = true;
    }
    return failed;
}

/// Fixed-token diagnostics: no source bytes, paths, metadata, or sink keys.
int runMetadataRoute(const string[] args) {
    Options o;
    if (!parseOptions(args, o)) {
        stderr.writeln("scrubbed: route-invalid-arguments");
        return 2;
    }
    try {
        auto files = preflight(o);
        auto contentSpec = lowerLegacyNames(o.filters.split(","));
        auto contentJob = compileJob(contentSpec);
        JobSpec metadataSpec;
        metadataSpec.stages = [
            JobStageSpec("metadata-annotate", htmlMetadataAnnotateStageKeyV1),
            JobStageSpec("metadata-publish", "document-metadata-publish")];
        auto metadataJob = compileJob(metadataSpec);
        auto executable = runningExecutableDigest();
        auto contentHash = routeConfigDigest("route-content:v2:", o.filters, executable);
        auto metadataHash = routeConfigDigest("route-metadata:v3:",
            "html-metadata-annotate,document-metadata-publish", executable);
        scope manifest = new LocalManifest(o.manifest);
        bool incomplete;
        foreach (file; files) {
            checkedTarget(o.contentRoot, file.name, false);
            checkedTarget(o.metadataRoot, file.name, false);
            auto size = checkedEntry(file.path, false).st_size;
            if (size > defaultExtractHtmlBytes) { incomplete = true; continue; }
            auto raw = cast(ubyte[]) read(file.path, defaultExtractHtmlBytes + 1);
            if (raw.length > defaultExtractHtmlBytes) { incomplete = true; continue; }
            try validate(cast(string) raw);
            catch (Exception) { incomplete = true; continue; }
            auto document = Document(SourceLocator("local-html:v1", o.input, file.name),
                OutputName(file.name));
            auto source = new Content([ContentPiece.own(raw)]);
            auto metadataEvents = runCompiledJob(
                StageDocument(document, source), metadataJob);
            if (metadataEvents.length != 1)
                throw new Exception("unexpected stage event count");
            auto event = metadataEvents[0];
            if (event.kind == EventKind.quarantined || event.kind == EventKind.rejected) {
                incomplete = true;
                continue;
            }
            if (event.kind != EventKind.emitted || event.payload.document.id != document.id)
                throw new Exception("metadata stage identity changed");
            if (event.sideOutputs.length != 1)
                throw new Exception("metadata stage side-output count changed");
            auto contentResult = runCompiledStage([StageDocument(document,
                new Content([ContentPiece.own(raw.dup)]))], contentJob.stages[0]);
            if (contentResult.events.length != 1 ||
                    contentResult.events[0].kind != EventKind.emitted ||
                    contentResult.events[0].payload.document.id != document.id)
                throw new Exception("content stage identity changed");
            auto content = contentResult.events[0].payload.content;
            auto metadata = new Content([ContentPiece.own(
                cast(const(ubyte)[]) event.sideOutputs[0].bytes())]);
            checkedTarget(o.contentRoot, file.name, true);
            checkedTarget(o.metadataRoot, file.name, true);
            auto digest = inputDigest(raw);
            auto adapter = new IndependentLocalSinks(manifest, o.contentRoot,
                o.metadataRoot, digest, contentHash, metadataHash,
                (typeof(event) emitted) { return IndependentPayloads(content, metadata); },
                o.retry);
            try adapter.accept(event);
            catch (IndependentSinkFailure failure) {
                if (failure.cause is null ||
                    cast(OutputPolicyViolation) failure.cause !is null ||
                    !recordedFailure(manifest, document, digest, contentHash, metadataHash))
                    throw failure;
                incomplete = true;
            }
        }
        if (incomplete) {
            stderr.writeln("scrubbed: route-incomplete");
            return 1;
        }
        return 0;
    } catch (Exception) {
        stderr.writeln("scrubbed: route-refused");
        return 2;
    }
}

unittest {
    // A valid flag set, mixing the `--flag value` and `--flag=value`
    // spellings, still parses exactly as before this file's `parseOptions`
    // switched to the shared `effects.cli_option_parsing.nextOption` helper,
    // including that the default `--filters` value survives untouched.
    string[] args = ["--input", "/tmp/in", "--content-output=/tmp/content",
        "--metadata-output", "/tmp/metadata", "--manifest=/tmp/manifest.sqlite3",
        "--retry"];
    Options o;
    assert(parseOptions(args, o), "a valid flag set was rejected");
    assert(o.input == "/tmp/in" && o.hasInput);
    assert(o.contentRoot == "/tmp/content" && o.hasContent);
    assert(o.metadataRoot == "/tmp/metadata" && o.hasMetadata);
    assert(o.manifest == "/tmp/manifest.sqlite3" && o.hasManifest);
    assert(o.retry);
    assert(o.filters == "normalize-line-endings,strip-control",
        "default --filters value changed");
}

unittest {
    // Regression for issue #351: this file already had the NUL-byte/empty-
    // value check `error_cli.d` was missing; confirm the switch to the
    // shared `cli_option_parsing` helper didn't lose it, in both flag
    // spellings.
    string[] spaceForm = ["--input", "bad\0value"];
    Options rejectedSpaceForm;
    assert(!parseOptions(spaceForm, rejectedSpaceForm),
        "metadata_route_cli.d parseOptions accepted a NUL-byte-containing value (--flag value form)");

    string[] equalsForm = ["--input=bad\0value"];
    Options rejectedEqualsForm;
    assert(!parseOptions(equalsForm, rejectedEqualsForm),
        "metadata_route_cli.d parseOptions accepted a NUL-byte-containing value (--flag=value form)");
}

/// Issue #451 regression: `runMetadataRoute` had its own, separate raw-HTML
/// preflight gate -- run before the compiled `metadata-annotate` job is ever
/// invoked -- that still hardcoded the old `effects.html_tree.maxRawBytes`
/// (64 KiB) limit, even after issue #444/#452 raised the *stage-level*
/// default (`defaultExtractHtmlBytes`, 1 MiB) that `html-metadata-annotate`
/// itself now honors. A real corpus page comfortably inside the new 1 MiB
/// default used to be marked `incomplete` here anyway, without ever reaching
/// the compiled job. Pinned against a real bundled corpus file, not a
/// synthetic fixture: run from the repository root (as `dub test`/
/// `README.md`'s other documented commands already assume),
/// `examples/pipeline-benchmark/corpus/appen-com.html` (81,918 bytes) is
/// well over the old 64 KiB cap and well under the new 1 MiB default, so
/// this proves both halves at once -- this exact assertion would have
/// failed (`route-incomplete`, exit 1) against the pre-fix hardcoded-64 KiB
/// behavior, and passes (exit 0, both sinks populated) now.
unittest {
    import core.stdc.stdlib : free;
    import core.sys.posix.stdlib : realpath;
    import effects.html_tree : defaultExtractHtmlBytes;
    import std.file : copy, exists, getSize, mkdirRecurse, read, rmdirRecurse,
        tempDir;
    import std.path : buildPath;
    import std.string : fromStringz, toStringz;
    import std.uuid : randomUUID;

    enum corpusFile = "examples/pipeline-benchmark/corpus/appen-com.html";
    auto fixtureSize = getSize(corpusFile);
    assert(fixtureSize > 64 * 1024,
        "fixture must exceed the old hardcoded 64 KiB cap to prove the fix");
    assert(fixtureSize <= defaultExtractHtmlBytes,
        "fixture must fit the new default so the regression actually pins success");

    // Before issue #458, `preflight`'s ancestor walk rejected any symlink
    // above the given root -- and on macOS `tempDir()` (from `$TMPDIR`) sits
    // under `/var`, itself a symlink to `/private/var` -- so this test used
    // to need `tempDir()` pre-resolved to a real, symlink-free path just to
    // exercise the command's own byte-limit gate rather than that unrelated
    // check. `checkedRoot` no longer walks ancestors (see its doc comment),
    // so an unresolved `tempDir()` would pass here too; this keeps resolving
    // it anyway, both because it costs nothing and to keep this fixture's
    // root stable and comparable across runs (`source/cli.d`'s
    // `canonicalExisting` uses the same `realpath` idiom).
    auto resolvedTempPtr = realpath(tempDir.toStringz, null);
    assert(resolvedTempPtr !is null, "could not resolve tempDir()");
    auto resolvedTemp = fromStringz(resolvedTempPtr).idup;
    free(resolvedTempPtr);

    auto root = buildPath(resolvedTemp, "scrubbed-metadata-route-451-" ~
        randomUUID.toString);
    scope(exit) if (exists(root)) rmdirRecurse(root);

    auto inputDir = buildPath(root, "input");
    auto contentDir = buildPath(root, "content");
    auto metadataDir = buildPath(root, "metadata");
    auto manifestPath = buildPath(root, "manifest.sqlite3");
    mkdirRecurse(inputDir);
    mkdirRecurse(contentDir);
    mkdirRecurse(metadataDir);

    auto inputFile = buildPath(inputDir, "appen-com.html");
    copy(corpusFile, inputFile);

    auto exitCode = runMetadataRoute(["--input", inputDir,
        "--content-output", contentDir, "--metadata-output", metadataDir,
        "--manifest", manifestPath]);
    assert(exitCode == 0,
        "route-metadata must no longer report route-incomplete for a real " ~
        "82 KB corpus page under the new 1 MiB default (issue #451)");
    assert(exists(buildPath(contentDir, "appen-com.html")),
        "route-metadata must publish the content sink for the admitted file");
    assert(exists(buildPath(metadataDir, "appen-com.html")),
        "route-metadata must publish the metadata sink for the admitted file");
}

/// Issue #458 regression: `preflight`'s old `checkedAncestors` walked every
/// ancestor directory of `--input`/`--content-output`/`--metadata-output`/
/// `--manifest` up to `/`, rejecting any symlink found along the way. That
/// false-refused on an ordinary OS-level symlinked ancestor the caller
/// never named and has no control over -- macOS's `/tmp` -> `/private/tmp`
/// is the reported case -- making `route-metadata` unusable from the OS's
/// own default scratch directory, even though every root the caller
/// actually specified was a genuine, symlink-free directory.
///
/// Rather than depend on `/tmp` happening to be symlinked (true on macOS,
/// not guaranteed on Linux CI), this builds its own synthetic symlinked
/// ancestor so the regression is pinned portably: a real scratch directory
/// holding the actual input/content/metadata roots and manifest, reached
/// through a *second* path that symlinks to it one level above those
/// roots -- exactly the `/tmp` -> `/private/tmp` shape, reproduced without
/// relying on the host OS to provide it.
///
/// Against the pre-fix `checkedAncestors`, every one of this test's four
/// route paths sits under the symlinked ancestor, so preflight would walk
/// up from each root, hit that symlink, and refuse with `route-refused`
/// (exit 2) before ever inspecting the input file. Against the fix (which
/// only checks each given root's own identity, not what sits above it),
/// the route succeeds and both sinks are published.
unittest {
    import core.stdc.stdlib : free;
    import core.sys.posix.stdlib : realpath;
    import std.file : exists, mkdirRecurse, rmdirRecurse, symlink, tempDir,
        write;
    import std.path : buildPath;
    import std.string : fromStringz, toStringz;
    import std.uuid : randomUUID;

    auto resolvedTempPtr = realpath(tempDir.toStringz, null);
    assert(resolvedTempPtr !is null, "could not resolve tempDir()");
    auto resolvedTemp = fromStringz(resolvedTempPtr).idup;
    free(resolvedTempPtr);

    auto tag = randomUUID.toString;
    // The genuine, symlink-free directory that actually holds every root
    // this route will be given -- standing in for `/private/tmp`.
    auto real_ = buildPath(resolvedTemp, "scrubbed-metadata-route-458-real-" ~ tag);
    // A second, sibling path that is nothing but a symlink to `real_` --
    // standing in for `/tmp` itself. Every `--input`/`--content-output`/
    // `--metadata-output`/`--manifest` path below is reached through this
    // symlinked ancestor, never directly through `real_`.
    auto link = buildPath(resolvedTemp, "scrubbed-metadata-route-458-link-" ~ tag);

    mkdirRecurse(real_);
    scope(exit) if (exists(real_)) rmdirRecurse(real_);
    symlink(real_, link);
    scope(exit) if (exists(link)) rmdirRecurse(link);

    auto inputDir = buildPath(link, "input");
    auto contentDir = buildPath(link, "content");
    auto metadataDir = buildPath(link, "metadata");
    // The manifest's own directory must, like the other three roots, be a
    // genuine directory reached *through* the symlinked ancestor -- not the
    // symlinked ancestor's own path -- so this pins the same "ancestor
    // above the root" class this issue is about, not the already-covered
    // "root itself is a symlink" case (see the "manifest alias" path-safety
    // test, which deliberately passes a symlink as `--metadata-output`
    // itself and must keep being refused).
    auto manifestDir = buildPath(link, "manifest");
    auto manifestPath = buildPath(manifestDir, "manifest.sqlite3");
    mkdirRecurse(inputDir);
    mkdirRecurse(contentDir);
    mkdirRecurse(metadataDir);
    mkdirRecurse(manifestDir);

    enum sample = `<html><head><title>Fallback</title>` ~
        `<meta property="og:title" content="Primary">` ~
        `<meta name="author" content="Ada">` ~
        `<meta name="date" content="2024-02-29">` ~
        `<link rel="canonical" href="https://example.test/page">` ~
        `</head><body>Alpha` ~ "\r\n" ~ `Beta</body></html>`;
    write(buildPath(inputDir, "page.html"), sample);

    auto exitCode = runMetadataRoute(["--input", inputDir,
        "--content-output", contentDir, "--metadata-output", metadataDir,
        "--manifest", manifestPath]);
    assert(exitCode == 0,
        "route-metadata must not report route-refused for roots reached " ~
        "only through a symlinked ancestor the caller does not control " ~
        "(issue #458); an ordinary OS-level indirection like macOS's " ~
        "/tmp -> /private/tmp must not false-refuse this route");
    assert(exists(buildPath(contentDir, "page.html")),
        "route-metadata must publish the content sink through the symlinked ancestor");
    assert(exists(buildPath(metadataDir, "page.html")),
        "route-metadata must publish the metadata sink through the symlinked ancestor");
    assert(exists(buildPath(real_, "content", "page.html")),
        "the content sink must have actually landed in the real directory the symlink resolves to");
    assert(exists(buildPath(real_, "metadata", "page.html")),
        "the metadata sink must have actually landed in the real directory the symlink resolves to");
}
