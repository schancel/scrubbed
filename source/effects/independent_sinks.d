/// Opt-in, two-destination local effect. The caller owns the manifest and
/// supplies both payloads; this module does not extract metadata.
module effects.independent_sinks;

import content.pieces : Content;
import core.stdc.stdlib : free;
import core.sys.posix.sys.stat : stat, stat_t;
import domain.document : Document;
import effects.atomic_piece_sink : OutputPolicyViolation, writeAtomicPieces;
import effects.local_manifest : Inspection, LocalManifest, SinkKey, SinkState;
import effects.runner : Sink;
import stages.contract : EventKind, StageEvent;
import std.digest.sha : SHA256;
import std.exception : enforce;
import std.file : exists, isDir;
import std.path : absolutePath, buildPath;
import std.string : fromStringz, indexOf, toStringz;

enum contentSinkKey = "local-content:v1";
enum metadataSinkKey = "local-metadata:v1";

/// Both payloads belong to the event's one immutable Document envelope.
struct IndependentPayloads {
    Content content;
    Content metadata;
}

alias PayloadProvider = IndependentPayloads delegate(StageEvent event);

/// Reports the first sink error after attempting the other sink. Inspect the
/// manifest for the two independent outcomes; neither error implies rollback.
class IndependentSinkFailure : Exception {
    string sink;
    Exception cause;
    this(string sink, Exception cause) {
        super("independent " ~ sink ~ " sink failed: " ~ cause.msg);
        this.sink = sink;
        this.cause = cause;
    }
}

private extern(C) char* realpath(const(char)*, char*);

private string checkedRoot(string root) {
    if (!root.length || root.indexOf('\0') >= 0 || !isDir(root))
        throw new OutputPolicyViolation("independent sink root must be an existing directory");
    auto resolved = realpath(absolutePath(root).toStringz, null);
    if (resolved is null)
        throw new OutputPolicyViolation("independent sink root cannot be resolved");
    scope(exit) free(resolved);
    return resolved.fromStringz.idup;
}

private string checkedName(Document document) {
    auto name = document.outputName.text;
    if (!name.length || name == "." || name == ".." ||
        name.indexOf('/') >= 0 || name.indexOf('\\') >= 0 || name.indexOf('\0') >= 0)
        throw new OutputPolicyViolation("output name must be a single safe path component");
    return name;
}

private bool sameInode(string left, string right) {
    stat_t a, b;
    return stat(left.toStringz, &a) == 0 && stat(right.toStringz, &b) == 0 &&
        a.st_dev == b.st_dev && a.st_ino == b.st_ino;
}

private ubyte[32] digestContent(Content content) {
    SHA256 digest;
    content.stream((const(ubyte)[] chunk) { digest.put(chunk); });
    return digest.finish();
}

version (IndependentSinksHarness) {
    /// D checker only; never built into the shipping adapter.
    void delegate(string sink, string phase) independentSinksFault;
    private void fault(string sink, string phase) {
        if (independentSinksFault !is null) independentSinksFault(sink, phase);
    }
}

final class IndependentLocalSinks : Sink {
    private LocalManifest manifest;
    private string contentRoot;
    private string metadataRoot;
    private ubyte[32] inputHash;
    private ubyte[32] contentConfigHash;
    private ubyte[32] metadataConfigHash;
    private PayloadProvider payloads;
    private bool allowRetry;

    /// `retry` explicitly accepts replacement of an unresolved or existing
    /// destination. The caller must keep `manifest` live through every accept.
    this(LocalManifest manifest, string contentRoot, string metadataRoot,
        ubyte[32] inputHash, ubyte[32] contentConfigHash,
        ubyte[32] metadataConfigHash, PayloadProvider payloads, bool retry = false) {
        enforce(manifest !is null && payloads !is null, "manifest and payload provider required");
        this.manifest = manifest;
        this.contentRoot = checkedRoot(contentRoot);
        this.metadataRoot = checkedRoot(metadataRoot);
        if (this.contentRoot == this.metadataRoot)
            throw new OutputPolicyViolation("independent sink roots alias");
        this.inputHash = inputHash;
        this.contentConfigHash = contentConfigHash;
        this.metadataConfigHash = metadataConfigHash;
        this.payloads = payloads;
        allowRetry = retry;
    }

    override void accept(StageEvent event) {
        if (event.kind != EventKind.emitted) return;
        auto document = event.payload.document;
        // A provider is arbitrary caller code: it can replace a root with a
        // symlink or create a hard link after the first validation.
        destinations(document);
        auto data = payloads(event);
        enforce(data.content !is null && data.metadata !is null,
            "both independent sink payloads required");
        auto paths = destinations(document);
        auto contentPath = paths.content;
        auto metadataPath = paths.metadata;
        auto contentKey = SinkKey(document.id, inputHash, contentConfigHash, contentSinkKey);
        auto metadataKey = SinkKey(document.id, inputHash, metadataConfigHash, metadataSinkKey);
        // Both plans and destination checks finish before either publication.
        manifest.plan(contentKey, contentPath);
        manifest.plan(metadataKey, metadataPath);
        IndependentSinkFailure first;
        try deliver(contentKey, contentPath, data.content);
        catch (Exception failure) first = new IndependentSinkFailure(contentSinkKey, failure);
        try deliver(metadataKey, metadataPath, data.metadata);
        catch (Exception failure) {
            if (first is null) first = new IndependentSinkFailure(metadataSinkKey, failure);
        }
        if (first !is null) throw first;
    }

    private struct Destinations {
        string content;
        string metadata;
    }

    private Destinations destinations(Document document) {
        auto name = checkedName(document);
        auto contentDir = checkedRoot(contentRoot);
        auto metadataDir = checkedRoot(metadataRoot);
        if (contentDir == metadataDir)
            throw new OutputPolicyViolation("independent sink roots alias");
        auto contentPath = buildPath(contentDir, name);
        auto metadataPath = buildPath(metadataDir, name);
        if (contentPath == metadataPath || sameInode(contentPath, metadataPath))
            throw new OutputPolicyViolation("independent sink destinations collide");
        return Destinations(contentPath, metadataPath);
    }

    private void deliver(SinkKey key, string path, Content content) {
        auto inspection = manifest.inspect(key, path);
        if (inspection == Inspection.verifiedCommitted) return;
        auto previous = manifest.lookup(key).get;
        bool unresolved = previous.state != SinkState.planned || exists(path);
        if (unresolved && !allowRetry)
            throw new Exception("explicit retry required for " ~ key.sink);
        if (unresolved) manifest.retry(key);
        bool published;
        try {
            auto digest = digestContent(content);
            version (IndependentSinksHarness) fault(key.sink, "before-write");
            writeAtomicPieces(path, content.pieces());
            published = true;
            version (IndependentSinksHarness) fault(key.sink, "after-publish");
            manifest.commitPublished(key, path, digest);
        } catch (Exception failure) {
            if (published) manifest.markUncertain(key);
            else manifest.markFailed(key);
            throw failure;
        }
    }
}
