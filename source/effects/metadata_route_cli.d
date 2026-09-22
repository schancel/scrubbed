/// Opt-in local HTML route. This is CLI orchestration, not a two-file commit.
module effects.metadata_route_cli;

import content.pieces : Content, ContentPiece;
import core.stdc.errno : errno, EINTR, ENOENT;
import core.sys.posix.fcntl : open, O_RDONLY, O_NOFOLLOW;
import core.sys.posix.sys.stat : fstat, lstat, stat, stat_t, S_ISDIR, S_ISREG, S_ISLNK;
import core.sys.posix.unistd : close, posixRead = read;
import domain.document : Document, OutputName, SourceLocator;
import effects.atomic_piece_sink : OutputPolicyViolation;
import effects.html_metadata_stage : htmlMetadataPlan;
import effects.html_tree : maxRawBytes;
import effects.independent_sinks : IndependentLocalSinks, IndependentPayloads,
    IndependentSinkFailure, contentSinkKey, metadataSinkKey;
import effects.local_manifest : LocalManifest, SinkKey, SinkState, configDigest,
    inputDigest;
import filters.entities;
import filters.mojibake;
import filters.normalize;
import filters.punctuation;
import pipeline : Pipeline;
import std.digest.sha : SHA256;
import stages.contract : EventKind, ResourceDeclaration, StageDeclaration,
    StageDocument, runStage;
import std.algorithm.sorting : sort;
import std.file : SpanMode, dirEntries, mkdir, read, thisExePath;
import std.path : absolutePath, baseName, buildNormalizedPath, buildPath,
    dirName, extension, relativePath;
import std.stdio : stderr;
import std.string : indexOf, split, startsWith, toLower, toStringz;
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
    SHA256 digest;
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
    for (size_t i; i < args.length; ++i) {
        string flag = args[i];
        if (flag == "--retry") {
            if (o.retry) return false;
            o.retry = true;
            continue;
        }
        string value;
        auto equal = flag.indexOf('=');
        if (equal >= 0) {
            value = flag[equal + 1 .. $];
            flag = flag[0 .. equal];
        } else {
            if (i + 1 >= args.length || args[i + 1].startsWith("--")) return false;
            value = args[++i];
        }
        if (!value.length || value.indexOf('\0') >= 0) return false;
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

private void checkedAncestors(string path) {
    auto cursor = path;
    while (true) {
        checkedEntry(cursor, true);
        if (cursor == "/") break;
        cursor = dirName(cursor);
    }
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
    checkedAncestors(root);
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
    checkedAncestors(o.contentRoot);
    checkedAncestors(o.metadataRoot);
    checkedAncestors(dirName(o.manifest));
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
    stat_t root;
    if (lstat(o.input.toStringz, &root) != 0 || S_ISLNK(root.st_mode))
        throw new OutputPolicyViolation("invalid input root");
    bool tree = S_ISDIR(root.st_mode);
    if (!tree && (!S_ISREG(root.st_mode) || root.st_nlink != 1))
        throw new OutputPolicyViolation("invalid input file");
    checkedAncestors(tree ? o.input : dirName(o.input));
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
        auto chain = Pipeline.build(o.filters.split(","));
        auto plan = htmlMetadataPlan();
        auto executable = runningExecutableDigest();
        auto contentHash = routeConfigDigest("route-content:v2:", o.filters, executable);
        auto metadataHash = routeConfigDigest("route-metadata:v2:",
            "html-metadata", executable);
        scope manifest = new LocalManifest(o.manifest);
        bool incomplete;
        foreach (file; files) {
            checkedTarget(o.contentRoot, file.name, false);
            checkedTarget(o.metadataRoot, file.name, false);
            auto size = checkedEntry(file.path, false).st_size;
            if (size > maxRawBytes) { incomplete = true; continue; }
            auto raw = cast(ubyte[]) read(file.path, maxRawBytes + 1);
            if (raw.length > maxRawBytes) { incomplete = true; continue; }
            try validate(cast(string) raw);
            catch (Exception) { incomplete = true; continue; }
            auto document = Document(SourceLocator("local-html:v1", o.input, file.name),
                OutputName(file.name));
            auto source = new Content([ContentPiece.own(raw)]);
            auto stage = plan.stages[0].declaration;
            auto staged = runStage([StageDocument(document, source)],
                StageDeclaration(stage.key.idup, stage.passMode,
                    ResourceDeclaration(stage.resources.cpuSlots,
                        stage.resources.memoryBytes,
                        stage.resources.exclusiveNames.dup)),
                plan.stages[0].transform);
            if (staged.events.length != 1) throw new Exception("unexpected stage event count");
            auto event = staged.events[0];
            if (event.kind == EventKind.quarantined || event.kind == EventKind.rejected) {
                incomplete = true;
                continue;
            }
            if (event.kind != EventKind.emitted || event.payload.document.id != document.id)
                throw new Exception("metadata stage identity changed");
            auto filtered = chain.run(cast(string) raw);
            auto content = new Content([ContentPiece.own(cast(const(ubyte)[]) filtered)]);
            auto metadata = event.payload.content;
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
