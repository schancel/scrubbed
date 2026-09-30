/// Opt-in, two-destination local effect. The caller owns the manifest and
/// supplies both payloads; this module does not extract metadata.
module effects.independent_sinks;

import content.pieces : Content, ContentPiece;
import core.stdc.errno : errno, ENOENT;
import core.stdc.stdlib : free;
import core.sys.posix.sys.stat : lstat, stat, stat_t, S_ISDIR, S_ISLNK, S_ISREG;
import domain.document : Document;
import effects.atomic_piece_sink : OutputPolicyViolation, writeAtomicPieces;
import effects.local_manifest : Inspection, LocalManifest, SinkKey, SinkState;
import effects.runner : Sink;
import stages.contract : EventKind, StageDocument, StageEvent;
import crypto.sha256 : Sha256;
import std.exception : enforce;
import std.file : exists;
import std.path : absolutePath, buildPath;
import std.string : fromStringz, indexOf, split, toStringz;

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

/// Issue #467 hardening. Before this, `checkedRoot` walked every ancestor
/// directory of `root` up to `/`, rejecting any symlink found along the
/// way -- the same over-broad check issue #458 fixed in
/// `metadata_route_cli.d`'s own `checkedAncestors`, which false-refuses on
/// ordinary OS-level indirection a caller never named and can't avoid, such
/// as macOS's `/tmp` -> `/private/tmp`. This module's own check kept that
/// bug; it merely never triggered, because this module's one caller
/// (`metadata_route_cli.d`) already pre-resolves `contentRoot`/
/// `metadataRoot` via `realpath` (its `resolvedRoot`) before ever calling
/// in here. That made the safety entirely a property of caller discipline,
/// not of this module: a second caller that passed an unresolved path
/// through an OS-level symlinked ancestor would reproduce #458's exact
/// false-refusal here, unnoticed until it shipped.
///
/// This now follows the same fix metadata_route_cli.d already applied and
/// had independently reviewed: check only the exact given root's own
/// identity (it must itself, not any ancestor above it, be a real,
/// symlink-free directory), then resolve it to its canonical form via
/// `realpath`. A symlink introduced *within* the root (nested content) is
/// still caught separately, by `checkedDestination`'s walk down to each
/// target. Because the returned value is always the fully realpath-resolved
/// form, this module no longer depends on any caller pre-resolving its
/// input -- the constructor and `destinations()` both canonicalize
/// internally, unconditionally.
private string checkedRoot(string root) {
    if (!root.length || root.indexOf('\0') >= 0)
        throw new OutputPolicyViolation("independent sink root must be an existing directory");
    auto absolute = absolutePath(root);
    stat_t entry;
    if (lstat(absolute.toStringz, &entry) != 0 ||
        S_ISLNK(entry.st_mode) || !S_ISDIR(entry.st_mode))
        throw new OutputPolicyViolation(
            "independent sink root must be an existing non-symlink directory");
    auto resolved = realpath(absolute.toStringz, null);
    if (resolved is null)
        throw new OutputPolicyViolation("independent sink root cannot be resolved");
    scope(exit) free(resolved);
    return resolved.fromStringz.idup;
}

private string[] checkedName(Document document) {
    auto name = document.outputName.text;
    if (!name.length || name.indexOf('\\') >= 0 || name.indexOf('\0') >= 0)
        throw new OutputPolicyViolation("output name must be a safe relative path");
    auto components = name.split('/');
    foreach (component; components)
        if (!component.length || component == "." || component == "..")
            throw new OutputPolicyViolation("output name has an unsafe path component");
    return components;
}

private string checkedDestination(string root, string[] components) {
    auto cursor = root;
    foreach (component; components[0 .. $ - 1]) {
        cursor = buildPath(cursor, component);
        stat_t entry;
        if (lstat(cursor.toStringz, &entry) != 0 ||
            S_ISLNK(entry.st_mode) || !S_ISDIR(entry.st_mode))
            throw new OutputPolicyViolation(
                "independent sink output parent must be an existing non-symlink directory");
    }
    auto destination = buildPath(cursor, components[$ - 1]);
    stat_t entry;
    if (lstat(destination.toStringz, &entry) == 0) {
        if (S_ISLNK(entry.st_mode) || !S_ISREG(entry.st_mode) || entry.st_nlink != 1)
            throw new OutputPolicyViolation(
                "independent sink destination must be a regular unaliased file or absent");
    } else if (errno != ENOENT) {
        throw new OutputPolicyViolation("independent sink destination cannot be inspected");
    }
    return destination;
}

private bool sameInode(string left, string right) {
    stat_t a, b;
    return stat(left.toStringz, &a) == 0 && stat(right.toStringz, &b) == 0 &&
        a.st_dev == b.st_dev && a.st_ino == b.st_ino;
}

private ubyte[32] digestContent(Content content) {
    auto digest = Sha256.create;
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
        // Include all prior manifest states before either plan or publication.
        manifest.requireDestinationOwner(contentKey, contentPath);
        manifest.requireDestinationOwner(metadataKey, metadataPath);
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
        auto components = checkedName(document);
        auto contentDir = checkedRoot(contentRoot);
        auto metadataDir = checkedRoot(metadataRoot);
        if (contentDir != contentRoot || metadataDir != metadataRoot)
            throw new OutputPolicyViolation("independent sink root changed");
        if (contentDir == metadataDir)
            throw new OutputPolicyViolation("independent sink roots alias");
        auto contentPath = checkedDestination(contentDir, components);
        auto metadataPath = checkedDestination(metadataDir, components);
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

/// Issue #467 regression: proves the ancestor-symlink protection is now
/// enforced by `IndependentLocalSinks` itself, not merely by
/// `metadata_route_cli.d` (this module's one current caller) happening to
/// pre-resolve its roots via `realpath` before calling in.
///
/// This constructs a synthetic caller that deliberately skips that
/// discipline -- exactly the "hypothetical/synthetic second caller that does
/// not pre-resolve" the issue's acceptance criteria calls for -- by handing
/// `IndependentLocalSinks` roots reached only through a symlinked ancestor
/// it built itself (the same portable `/tmp` -> `/private/tmp` shape as
/// `metadata_route_cli.d`'s own #458 regression, reproduced without relying
/// on the host OS to provide it).
///
/// Against the pre-#467 `checkedRoot` (full ancestor walk, no internal
/// resolution), this construction would throw `OutputPolicyViolation`
/// immediately -- a false refusal of two genuine, symlink-free directories,
/// solely because an unrelated caller-supplied path was unresolved. Against
/// the fix, construction succeeds, and a full `accept()` through this
/// unresolved-path instance actually publishes both sinks into the real
/// underlying directories.
unittest {
    import domain.document : OutputName, SourceLocator;
    import effects.local_manifest : configDigest, inputDigest;
    import std.file : mkdirRecurse, read, rmdirRecurse, symlink, tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto resolvedTempPtr = realpath(tempDir.toStringz, null);
    assert(resolvedTempPtr !is null, "could not resolve tempDir()");
    auto resolvedTemp = fromStringz(resolvedTempPtr).idup;
    free(resolvedTempPtr);

    auto tag = randomUUID.toString;
    // The genuine, symlink-free directory that actually holds the two sink
    // roots -- standing in for `/private/tmp`.
    auto real_ = buildPath(resolvedTemp, "scrubbed-independent-sinks-467-real-" ~ tag);
    // A sibling path that is nothing but a symlink to `real_` -- standing in
    // for `/tmp` itself. Both roots below are reached only through this
    // symlinked ancestor, never directly through `real_`.
    auto link = buildPath(resolvedTemp, "scrubbed-independent-sinks-467-link-" ~ tag);

    mkdirRecurse(real_);
    scope(exit) if (exists(real_)) rmdirRecurse(real_);
    symlink(real_, link);
    scope(exit) if (exists(link)) rmdirRecurse(link);

    // Unresolved: every path a fresh, undisciplined caller would compute by
    // hand, none of them pre-resolved via `realpath` the way
    // `metadata_route_cli.d`'s `resolvedRoot` does.
    auto contentRoot = buildPath(link, "content");
    auto metadataRoot = buildPath(link, "metadata");
    mkdirRecurse(contentRoot);
    mkdirRecurse(metadataRoot);
    auto manifestPath = buildPath(real_, "manifest.sqlite3");

    auto document = Document(SourceLocator("independent-467", "fixture", "1"),
        OutputName("record"));
    auto inputHash = inputDigest([cast(ubyte) 'x']);
    auto contentConfigHash = configDigest(cast(const(ubyte)[]) "content-config");
    auto metadataConfigHash = configDigest(cast(const(ubyte)[]) "metadata-config");

    scope manifest = new LocalManifest(manifestPath);
    // Construction alone is the false-refusal boundary: pre-#467, this line
    // throws OutputPolicyViolation for both roots before any sink is ever
    // planned.
    auto adapter = new IndependentLocalSinks(manifest, contentRoot, metadataRoot,
        inputHash, contentConfigHash, metadataConfigHash,
        (StageEvent event) {
            return IndependentPayloads(
                new Content([ContentPiece.own(cast(const(ubyte)[]) "content-bytes")]),
                new Content([ContentPiece.own(cast(const(ubyte)[]) "metadata-bytes")]));
        });

    auto event = StageEvent(EventKind.emitted, StageDocument(document,
        new Content([ContentPiece.own(cast(const(ubyte)[]) "source-bytes")])));
    adapter.accept(event);

    assert(exists(buildPath(contentRoot, "record")),
        "content sink must publish through the unresolved, symlinked-ancestor root");
    assert(exists(buildPath(metadataRoot, "record")),
        "metadata sink must publish through the unresolved, symlinked-ancestor root");
    assert(cast(const(ubyte)[]) read(buildPath(real_, "content", "record")) ==
        cast(const(ubyte)[]) "content-bytes",
        "content bytes must have actually landed in the real directory the symlink resolves to");
    assert(cast(const(ubyte)[]) read(buildPath(real_, "metadata", "record")) ==
        cast(const(ubyte)[]) "metadata-bytes",
        "metadata bytes must have actually landed in the real directory the symlink resolves to");
}
