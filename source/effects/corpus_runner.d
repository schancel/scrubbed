/// Phase-2 corpus-level driver (issue #564): `prune-near-duplicates`, the
/// first consumer of `stages.corpus_contract`. Walks the already-published
/// `document-metadata` sidecar tree (the same `--sidecar-output` directory
/// `effects.similarity_signature_annotate_stage` +
/// `effects.document_metadata_publish_stage` populated during phase 1),
/// recovers each document's `DocumentId` from its sidecar's own wire text
/// (`DocumentId.fromCanonicalText`, precedented in
/// `effects.near_dedup_overlay.d:151`), decodes its `similarity-signature`
/// structured section, and replicates `effects.similarity_buckets.d`'s
/// external-sort/bucket-cap ALGORITHM SHAPE (bounded runRecords batches,
/// disk-spilled scratch runs, a bounded `fanIn`-way merge) against this
/// sidecar-sourced candidate stream -- not its code, which is shard-typed
/// and left completely untouched, per issue #564's contract.
///
/// One real simplification versus `similarity_buckets.d`'s three-pass shape
/// (band/identity/assignment, joined by shard index): this module's single
/// candidate record already carries everything `domain.near_dedup_decision`
/// needs (the full 64-lane signature, not just a derived band hash), so one
/// external-sort pass over one record type suffices -- there is no shard
/// index to join back against, and no re-derivation-from-content step
/// (`effects.near_dedup_overlay`'s tamper/staleness recheck has no analogue
/// here: the sidecar IS the published source of truth, computed once, by
/// the same per-document job run that also serialized it -- see issue
/// #564's corrected contract comment).
///
/// `domain.near_dedup_decision.nearDuplicateLinksInBucket` is called
/// completely unmodified, once per bucket, exactly as
/// `effects.near_dedup_overlay.d`'s own Phase B already does. Because one
/// document's signature can land in more than one bucket (up to
/// `similarityBands` independent band rows) with a different representative
/// named by each, this module also independently reimplements
/// `near_dedup_overlay.d`'s own private cross-bucket conflict-resolution
/// shape (smallest-representative-wins, then chain-resolution to each
/// document's true root) -- reproduced here rather than imported, since that
/// helper is private to a module this slice must not modify.
///
/// **Non-destructive toward corpus output.** This driver never touches
/// `--output`; it atomically publishes the current derived decision set next
/// to the metadata sidecars and removes only stale files bearing its own
/// decision suffix. Materializing a physically pruned corpus remains a
/// separate opt-in follow-on.
module effects.corpus_runner;

import domain.document : DocumentId;
import domain.document_metadata : decodeDocumentMetadataV1,
    decodeDocumentMetadataV2, maxTotalEncodedBytesV2;
import domain.near_dedup_decision : NearDedupCandidate, PruningPolicy,
    nearDuplicateLinksInBucket;
import domain.similarity_signature : similarityBands, similarityLanes;
import effects.document_metadata_publish_stage : documentMetadataPublishSuffixV1;
import effects.sqlite_ffi;
import effects.similarity_signature_annotate_stage : decodeSimilaritySignaturePayload,
    similaritySignatureSectionIdV1;
import stages.corpus_contract : CorpusDecisionKind, CorpusStageDecision,
    CorpusStageDeclaration, CorpusStageRegistration, CorpusStageRun, CorpusStageSink,
    registerCorpusStage;
import stages.registry : OptionDeclaration, OptionType, StageOptions;
import std.algorithm.sorting : sort;
import std.conv : to;
import std.exception : enforce;
import std.file : SpanMode, dirEntries, exists, isDir, isFile, isSymlink,
    read, remove, rmdir, tempDir;
import std.format : format;
import std.path : baseName, buildPath, dirName;
import std.stdio : File;
import std.string : endsWith, indexOf, join, split;
import std.uuid : randomUUID;
import std.json : JSONOptions, JSONType, parseJSON;
import core.stdc.errno : errno, EINTR, ENOENT;
import core.sys.posix.dirent : DIR, closedir, readdir;
import core.sys.posix.fcntl : AT_SYMLINK_NOFOLLOW, open, openat, O_CREAT,
    O_EXCL, O_NOFOLLOW, O_RDONLY, O_WRONLY;
import core.sys.posix.stdio : renameat;
import core.sys.posix.sys.stat : fchmod, fstat, fstatat, posixMkdir = mkdir,
    stat_t, S_ISDIR, S_ISLNK, S_ISREG;
import core.sys.posix.unistd : close, fsync, posixRead = read,
    posixWrite = write, unlinkat;
import std.string : fromStringz, toStringz;

extern (C) int sqlite3_reset(sqlite3_stmt*);
extern (C) int sqlite3_clear_bindings(sqlite3_stmt*);
extern (C) DIR* fdopendir(int);

version (OSX) {
    // Phobos does not export O_DIRECTORY on macOS. The project already uses
    // this same SDK value in effects.warc_file.
    private enum int directoryOnly = 0x00100000;
} else {
    import core.sys.posix.fcntl : O_DIRECTORY;
    private enum int directoryOnly = O_DIRECTORY;
}

enum pruneNearDuplicatesStageKeyV1 = "prune-near-duplicates";
enum pruneNearDuplicatesDecisionSchemaV1 = "scrubbed-prune-near-duplicates-decision-v1";
enum pruneNearDuplicatesDecisionSuffixV1 = ".prune-near-duplicates-decision.json";

/// Same value as `effects.similarity_buckets.defaultSimilarityBucketCap`,
/// independently declared rather than imported: this module must not depend
/// on `similarity_buckets.d` at all (issue #564's contract leaves that
/// module's shard-based path completely untouched), and the two caps are
/// conceptually independent ceilings that merely happen to share a sensible
/// default today.
enum defaultPruneBucketCap = 4096;

private enum runRecords = 32;
private enum fanIn = 8;

// ---------------------------------------------------------------------------
// Release-checker-only observation of scratch file-descriptor and batch-size
// bounds, mirroring `effects.similarity_buckets`'s own
// `version (SimilarityBucketsCheck)` idiom exactly (independently declared,
// not shared -- that module must not be touched by this slice).
// ---------------------------------------------------------------------------
version (unittest) {
    private __gshared size_t openScratchFilesCurrent;
    private __gshared size_t openScratchFilesPeak;
    private __gshared size_t batchPeakRecords;
    private __gshared size_t bucketPeakMembers;
    private __gshared size_t scratchArtifactsCurrent;
    private __gshared size_t scratchArtifactsPeak;
    private __gshared string[] decodedDocumentOrder;
    private __gshared void delegate(string) rootAnchoredHook;
    private __gshared void delegate(string) postDiscoveryHook;
    private __gshared void delegate() preDecisionCommitHook;
    size_t corpusRunnerPeakOpenScratchFiles() { return openScratchFilesPeak; }
    size_t corpusRunnerPeakBatchRecords() { return batchPeakRecords; }
    size_t corpusRunnerPeakBucketMembers() { return bucketPeakMembers; }
    size_t corpusRunnerPeakScratchArtifacts() { return scratchArtifactsPeak; }
    string[] corpusRunnerDecodedDocumentOrder() { return decodedDocumentOrder.dup; }
    void resetCorpusRunnerObservations() {
        openScratchFilesCurrent = 0;
        openScratchFilesPeak = 0;
        batchPeakRecords = 0;
        bucketPeakMembers = 0;
        scratchArtifactsCurrent = 0;
        scratchArtifactsPeak = 0;
        decodedDocumentOrder = null;
        rootAnchoredHook = null;
        postDiscoveryHook = null;
        preDecisionCommitHook = null;
    }
    private void trackOpen() {
        ++openScratchFilesCurrent;
        if (openScratchFilesCurrent > openScratchFilesPeak)
            openScratchFilesPeak = openScratchFilesCurrent;
    }
    private void trackClose() {
        if (openScratchFilesCurrent) --openScratchFilesCurrent;
    }
    private void trackBatch(size_t size) {
        if (size > batchPeakRecords) batchPeakRecords = size;
    }
    private void trackBucket(size_t size) {
        if (size > bucketPeakMembers) bucketPeakMembers = size;
    }
    private void trackScratchCreate() {
        ++scratchArtifactsCurrent;
        if (scratchArtifactsCurrent > scratchArtifactsPeak)
            scratchArtifactsPeak = scratchArtifactsCurrent;
    }
    private void trackScratchRemove() {
        enforce(scratchArtifactsCurrent > 0,
            "corpus runner: scratch artifact accounting underflow");
        --scratchArtifactsCurrent;
    }
    private void trackDecodedDocument(string documentId) {
        decodedDocumentOrder ~= documentId;
    }
} else {
    private void trackOpen() {}
    private void trackClose() {}
    private void trackBatch(size_t) {}
    private void trackBucket(size_t) {}
    private void trackScratchCreate() {}
    private void trackScratchRemove() {}
    private void trackDecodedDocument(string) {}
}

string pruneBucketIdentity(size_t bandIndex, ulong bandKeyValue) pure {
    return format("band=%d,key=%016x", bandIndex, bandKeyValue);
}

// ---------------------------------------------------------------------------
// One candidate record: a single document's full signature exploded into
// one band row. Self-contained -- unlike similarity_buckets.d's BandMember,
// this carries the full lane array, so no later join against a separate
// identity/content-length pass is needed.
// ---------------------------------------------------------------------------
private struct BandCandidate {
    string documentId;
    size_t bandIndex;
    ulong bandKeyValue;
    ulong[similarityLanes] lanes;
    size_t contentLength;
}

private bool bandCandidateLess(BandCandidate a, BandCandidate b) {
    if (a.bandIndex != b.bandIndex) return a.bandIndex < b.bandIndex;
    if (a.bandKeyValue != b.bandKeyValue) return a.bandKeyValue < b.bandKeyValue;
    return a.documentId < b.documentId;
}

private void putU64(ref ubyte[] bytes, ulong value) {
    foreach_reverse (shift; [0, 8, 16, 24, 32, 40, 48, 56])
        bytes ~= cast(ubyte)(value >> shift);
}
private ulong getU64(const(ubyte)[] bytes, ref size_t at) {
    enforce(at + 8 <= bytes.length, "corpus runner: short u64 field");
    ulong value;
    foreach (_; 0 .. 8) value = (value << 8) | bytes[at++];
    return value;
}
private void putScratchBytes(ref ubyte[] outBytes, const(ubyte)[] value) {
    putU64(outBytes, value.length);
    outBytes ~= value;
}
private ubyte[] takeScratchBytes(const(ubyte)[] bytes, ref size_t at) {
    auto length = getU64(bytes, at);
    enforce(length <= bytes.length - at, "corpus runner: short scratch field");
    auto result = bytes[at .. at + cast(size_t) length].dup;
    at += cast(size_t) length;
    return result;
}
private ubyte[] encodeCandidate(BandCandidate item) {
    ubyte[] bytes;
    putScratchBytes(bytes, cast(const(ubyte)[]) item.documentId);
    putU64(bytes, item.bandIndex);
    putU64(bytes, item.bandKeyValue);
    putU64(bytes, item.contentLength);
    foreach (lane; item.lanes) putU64(bytes, lane);
    return bytes;
}
private BandCandidate decodeCandidate(const(ubyte)[] bytes) {
    BandCandidate item;
    size_t at;
    item.documentId = cast(string) takeScratchBytes(bytes, at).idup;
    item.bandIndex = cast(size_t) getU64(bytes, at);
    item.bandKeyValue = getU64(bytes, at);
    item.contentLength = cast(size_t) getU64(bytes, at);
    foreach (i; 0 .. similarityLanes) item.lanes[i] = getU64(bytes, at);
    enforce(at == bytes.length, "corpus runner: bad candidate record length");
    return item;
}

private void writeFrame(File file, const(ubyte)[] bytes) {
    ubyte[] prefix;
    putU64(prefix, bytes.length);
    file.rawWrite(prefix);
    file.rawWrite(bytes);
}
private bool readFrame(File file, out ubyte[] bytes) {
    ubyte[8] prefix;
    auto first = file.rawRead(prefix[0 .. 1]);
    if (!first.length) return false;
    size_t prefixUsed = first.length;
    while (prefixUsed < prefix.length) {
        auto part = file.rawRead(prefix[prefixUsed .. $]);
        enforce(part.length != 0, "corpus runner: short scratch frame header");
        prefixUsed += part.length;
    }
    size_t at;
    auto length = getU64(prefix[], at);
    bytes = new ubyte[cast(size_t) length];
    size_t used;
    while (used < bytes.length) {
        auto part = file.rawRead(bytes[used .. $]);
        enforce(part.length != 0, "corpus runner: short scratch frame");
        used += part.length;
    }
    return true;
}
private bool readRecord(File file, out BandCandidate item) {
    ubyte[] bytes;
    if (!readFrame(file, bytes)) return false;
    item = decodeCandidate(bytes);
    return true;
}

private File createScratchFile(string path) {
    auto fd = open(path.toStringz,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 384);
    enforce(fd >= 0, "corpus runner: cannot create private scratch artifact");
    File file;
    try file.fdopen(fd, "wb");
    catch (Exception error) {
        close(fd);
        throw error;
    }
    return file;
}

private struct RunSet {
    string manifest;
    size_t count;
    this(string manifest) {
        this.manifest = manifest;
        auto file = createScratchFile(manifest);
        file.close();
        trackScratchCreate();
    }
    void append(string path) {
        auto file = File(manifest, "ab");
        scope(exit) file.close();
        writeFrame(file, cast(const(ubyte)[]) path);
        ++count;
    }
    string firstPath() {
        enforce(count == 1, "corpus runner: expected one sorted run");
        auto file = File(manifest, "rb");
        scope(exit) file.close();
        ubyte[] bytes;
        enforce(readFrame(file, bytes), "corpus runner: missing run path");
        return cast(string) bytes;
    }
}
private void removeScratch(string path) {
    remove(path);
    trackScratchRemove();
}
private string mergePaths(const(string)[] paths, string delegate() fresh) {
    enforce(paths.length > 0 && paths.length <= fanIn,
        "corpus runner: merge fan-in outside bound");
    auto output = fresh();
    auto writer = createScratchFile(output);
    trackOpen();
    trackScratchCreate();
    File[] readers;
    BandCandidate[] heads;
    bool[] present;
    scope(exit) {
        foreach (ref reader; readers) { reader.close(); trackClose(); }
        writer.close();
        trackClose();
    }
    foreach (path; paths) {
        readers ~= File(path, "rb");
        trackOpen();
        BandCandidate item;
        present ~= readRecord(readers[$ - 1], item);
        heads ~= item;
    }
    while (true) {
        size_t minimum = size_t.max;
        foreach (i, active; present)
            if (active && (minimum == size_t.max ||
                    bandCandidateLess(heads[i], heads[minimum])))
                minimum = i;
        if (minimum == size_t.max) break;
        writeFrame(writer, encodeCandidate(heads[minimum]));
        present[minimum] = readRecord(readers[minimum], heads[minimum]);
    }
    return output;
}

/// Incremental leveled compaction: at most `fanIn - 1` complete runs remain
/// at each level while ingestion continues, so peak scratch artifact count
/// grows logarithmically rather than once per input batch.
private struct RunAccumulator {
    string[][] levels;
    string delegate() fresh;

    void add(string path, size_t level = 0) {
        while (levels.length <= level) levels ~= null;
        levels[level] ~= path;
        if (levels[level].length < fanIn) return;
        auto inputs = levels[level];
        levels[level] = null;
        auto merged = mergePaths(inputs, fresh);
        foreach (input; inputs) removeScratch(input);
        add(merged, level + 1);
    }

    RunSet finish() {
        auto runs = RunSet(fresh());
        foreach (level; levels)
            foreach (path; level) runs.append(path);
        return runs;
    }
}

private void flushRun(ref BandCandidate[] batch, ref RunAccumulator runs) {
    batch.sort!((a, b) => bandCandidateLess(a, b));
    auto path = runs.fresh();
    auto file = createScratchFile(path);
    trackOpen();
    trackScratchCreate();
    bool closed;
    scope(exit) if (!closed) { file.close(); trackClose(); }
    foreach (item; batch) writeFrame(file, encodeCandidate(item));
    // A leveled add may immediately merge this run, so publish all buffered
    // bytes before making its path visible to the accumulator.
    file.close();
    trackClose();
    closed = true;
    runs.add(path);
    batch.length = 0;
}

private RunSet mergeRuns(RunSet runs, string delegate() fresh) {
    while (runs.count > 1) {
        auto next = RunSet(fresh());
        auto manifest = File(runs.manifest, "rb");
        trackOpen();
        string[] oldPaths;
        while (true) {
            string[] group;
            foreach (_; 0 .. fanIn) {
                ubyte[] pathBytes;
                if (!readFrame(manifest, pathBytes)) break;
                auto path = cast(string) pathBytes;
                group ~= path;
                oldPaths ~= path;
            }
            if (!group.length) break;
            next.append(mergePaths(group, fresh));
        }
        manifest.close();
        trackClose();
        foreach (path; oldPaths) removeScratch(path);
        removeScratch(runs.manifest);
        runs = next;
    }
    return runs;
}

// ---------------------------------------------------------------------------
// Sidecar discovery and decode.
// ---------------------------------------------------------------------------

private void dbNeed(bool okay, string operation) {
    if (!okay) throw new Exception("corpus runner: scratch database " ~ operation);
}

private final class CorpusScratchDatabase {
    sqlite3* handle;

    this(string path) {
        dbNeed(sqlite3_open_v2(path.toStringz, &handle, SQLITE_OPEN_READWRITE,
            null) == SQLITE_OK, "open failed");
        dbNeed(sqlite3_busy_timeout(handle, 0) == SQLITE_OK,
            "busy timeout failed");
        exec(`PRAGMA journal_mode=OFF;
PRAGMA synchronous=OFF;
PRAGMA temp_store=FILE;
PRAGMA cache_size=-2048;
PRAGMA locking_mode=EXCLUSIVE;
CREATE TABLE documents(
 document_id TEXT PRIMARY KEY,
 sidecar_path TEXT NOT NULL UNIQUE,
 device TEXT NOT NULL,
 inode TEXT NOT NULL
) WITHOUT ROWID;
CREATE TABLE links(
 document_id TEXT PRIMARY KEY,
 representative_id TEXT NOT NULL,
 bucket_identity TEXT NOT NULL
) WITHOUT ROWID;
CREATE TABLE decisions(
 decision_path TEXT PRIMARY KEY
) WITHOUT ROWID;
CREATE TABLE directories(
 path TEXT PRIMARY KEY,
 device TEXT NOT NULL,
 inode TEXT NOT NULL
) WITHOUT ROWID;
CREATE TABLE walk_dirs(
 path TEXT PRIMARY KEY
) WITHOUT ROWID;`);
    }

    ~this() { close(); }

    void close() {
        if (handle is null) return;
        auto prior = handle;
        handle = null;
        dbNeed(sqlite3_close(prior) == SQLITE_OK, "close failed");
    }

    void exec(string sql) {
        dbNeed(sqlite3_exec(handle, sql.toStringz, null, null, null) == SQLITE_OK,
            "statement failed");
    }

    sqlite3_stmt* prepare(string sql) {
        sqlite3_stmt* statement;
        dbNeed(sqlite3_prepare_v2(handle, sql.toStringz, -1, &statement, null) ==
            SQLITE_OK, "prepare failed");
        return statement;
    }
}

private void recordDirectoryIdentity(CorpusScratchDatabase db, string relative,
        const ref stat_t info) {
    auto statement = db.prepare("INSERT INTO directories VALUES(?1,?2,?3)");
    scope(exit) sqlite3_finalize(statement);
    bindText(statement, 1, relative);
    bindText(statement, 2, info.st_dev.to!string);
    bindText(statement, 3, info.st_ino.to!string);
    dbNeed(sqlite3_step(statement) == SQLITE_DONE,
        "directory identity write failed");
}

private void verifyDirectoryIdentity(CorpusScratchDatabase db, string relative,
        const ref stat_t info) {
    if (db is null) return;
    auto statement = db.prepare(
        "SELECT device,inode FROM directories WHERE path=?1");
    scope(exit) sqlite3_finalize(statement);
    bindText(statement, 1, relative);
    dbNeed(sqlite3_step(statement) == SQLITE_ROW,
        "directory identity missing");
    auto device = columnText(statement, 0);
    auto inode = columnText(statement, 1);
    enforce(device == info.st_dev.to!string && inode == info.st_ino.to!string,
        "corpus runner: sidecar directory changed during phase 2: " ~ relative);
}

private void bindText(sqlite3_stmt* statement, int index, string value) {
    dbNeed(sqlite3_bind_text(statement, index, value.toStringz,
        cast(int) value.length, cast(void*) -1) == SQLITE_OK, "bind failed");
}

private string columnText(sqlite3_stmt* statement, int index) {
    auto value = sqlite3_column_text(statement, index);
    dbNeed(value !is null, "invalid text result");
    return value.fromStringz.idup;
}

private void resetStatement(sqlite3_stmt* statement) {
    dbNeed(sqlite3_reset(statement) == SQLITE_OK, "reset failed");
    dbNeed(sqlite3_clear_bindings(statement) == SQLITE_OK, "clear bindings failed");
}

/// Fixed-descriptor breadth walk. Pending directory names live in the
/// bounded-cache scratch database, and each shallow iterator is destroyed
/// before another directory is opened, so descriptor use is independent of
/// tree depth and breadth.
private void walkSidecarTree(CorpusScratchDatabase db, string root,
        int rootFd, bool recordDirectories,
        scope void delegate(string path, string relative, bool directory,
            bool regular, bool symlink) visit) {
    db.exec("DELETE FROM walk_dirs");
    auto add = db.prepare("INSERT OR IGNORE INTO walk_dirs VALUES(?1)");
    scope(exit) sqlite3_finalize(add);
    auto take = db.prepare("SELECT path FROM walk_dirs ORDER BY path LIMIT 1");
    scope(exit) sqlite3_finalize(take);
    auto drop = db.prepare("DELETE FROM walk_dirs WHERE path=?1");
    scope(exit) sqlite3_finalize(drop);

    bindText(add, 1, "");
    dbNeed(sqlite3_step(add) == SQLITE_DONE, "walk root write failed");
    resetStatement(add);
    while (true) {
        auto step = sqlite3_step(take);
        dbNeed(step == SQLITE_ROW || step == SQLITE_DONE,
            "walk queue read failed");
        if (step == SQLITE_DONE) break;
        auto directoryRelative = columnText(take, 0);
        resetStatement(take);
        bindText(drop, 1, directoryRelative);
        dbNeed(sqlite3_step(drop) == SQLITE_DONE, "walk queue delete failed");
        resetStatement(drop);

        auto directoryFd = openRelativeDirectory(db, rootFd, directoryRelative);
        auto stream = fdopendir(directoryFd);
        if (stream is null) {
            close(directoryFd);
            throw new Exception("corpus runner: cannot enumerate anchored directory");
        }
        scope(exit) closedir(stream);
        while (true) {
            errno = 0;
            auto entry = readdir(stream);
            if (entry is null) {
                enforce(errno == 0,
                    "corpus runner: anchored directory read failed");
                break;
            }
            auto name = entry.d_name.ptr.fromStringz.idup;
            if (name == "." || name == "..") continue;
            stat_t info;
            enforce(fstatat(directoryFd, name.toStringz, &info,
                    AT_SYMLINK_NOFOLLOW) == 0,
                "corpus runner: cannot inspect anchored sidecar entry");
            auto link = S_ISLNK(info.st_mode) != 0;
            auto directory = !link && S_ISDIR(info.st_mode) != 0;
            auto regular = !link && S_ISREG(info.st_mode) != 0;
            auto relative = directoryRelative.length ?
                buildPath(directoryRelative, name) : name;
            visit(buildPath(root, relative), relative, directory, regular, link);
            if (directory) {
                if (recordDirectories)
                    recordDirectoryIdentity(db, relative, info);
                else
                    verifyDirectoryIdentity(db, relative, info);
                bindText(add, 1, relative);
                dbNeed(sqlite3_step(add) == SQLITE_DONE,
                    "walk queue write failed");
                resetStatement(add);
            }
        }
    }
}

private void insertDocument(sqlite3_stmt* statement, string documentId,
        string sidecarPath, const ref stat_t info) {
    bindText(statement, 1, documentId);
    bindText(statement, 2, sidecarPath);
    bindText(statement, 3, info.st_dev.to!string);
    bindText(statement, 4, info.st_ino.to!string);
    dbNeed(sqlite3_step(statement) == SQLITE_DONE,
        "duplicate document ID or sidecar path");
    resetStatement(statement);
}

private void upsertLink(sqlite3_stmt* statement, string documentId,
        string representativeId, string bucketIdentity) {
    bindText(statement, 1, documentId);
    bindText(statement, 2, representativeId);
    bindText(statement, 3, bucketIdentity);
    dbNeed(sqlite3_step(statement) == SQLITE_DONE, "link write failed");
    resetStatement(statement);
}

private ubyte[] readBoundedSidecar(CorpusScratchDatabase db, int rootFd,
        string relativePath, out stat_t identity) {
    string leaf;
    auto parentFd = openRelativeParent(db, rootFd, relativePath, leaf);
    scope(exit) close(parentFd);
    auto fd = openat(parentFd, leaf.toStringz, O_RDONLY | O_NOFOLLOW);
    enforce(fd >= 0, "corpus runner: cannot open metadata sidecar safely");
    scope(exit) close(fd);
    enforce(fstat(fd, &identity) == 0 && S_ISREG(identity.st_mode),
        "corpus runner: metadata sidecar is not a regular file");
    enforce(identity.st_size >= 0 &&
            cast(ulong) identity.st_size <= maxTotalEncodedBytesV2,
        "corpus runner: metadata sidecar exceeds wire-size limit");

    auto bytes = new ubyte[maxTotalEncodedBytesV2 + 1];
    size_t used;
    while (used < bytes.length) {
        auto count = posixRead(fd, bytes.ptr + used, bytes.length - used);
        if (count < 0) {
            if (errno == EINTR) continue;
            throw new Exception("corpus runner: metadata sidecar read failed");
        }
        if (count == 0) break;
        used += cast(size_t) count;
    }
    enforce(used <= maxTotalEncodedBytesV2,
        "corpus runner: metadata sidecar exceeds wire-size limit");
    return bytes[0 .. used];
}

private string metadataVersion(string wire) {
    auto root = parseJSON(wire, 16,
        JSONOptions.strictParsing | JSONOptions.preserveObjectOrder);
    enforce(root.type == JSONType.object,
        "corpus runner: metadata sidecar root must be an object");
    foreach (ref member; root.orderedObject)
        if (member.key == "version") {
            enforce(member.value.type == JSONType.string,
                "corpus runner: metadata sidecar version must be text");
            return member.value.str;
        }
    throw new Exception("corpus runner: metadata sidecar missing version");
}

/// Recovers a sidecar's own bound `DocumentId` from its raw wire text
/// WITHOUT first knowing it. `decodeDocumentMetadataV1`/`V2` both require a
/// pre-known `expectedId` to verify against, so this does a small, strict
/// pre-parse of the fixed `"documentId":"<...>"` field first --
/// `DocumentId.text` is always a plain hex string (`doc:v1:`/`child:v1:` +
/// 64 hex chars), never containing a quote or backslash, so a plain
/// substring scan up to the next `"` is exact, not an approximation -- then
/// binds it for real via `DocumentId.fromCanonicalText`, mirroring
/// `effects.near_dedup_overlay.d:151`'s own use of that same constructor to
/// recover an ID from wire text.
private DocumentId recoverDocumentId(string wire) {
    enum marker = `"documentId":"`;
    auto at = wire.indexOf(marker);
    enforce(at >= 0, "corpus runner: sidecar missing documentId field");
    auto start = at + marker.length;
    auto end = wire.indexOf('"', start);
    enforce(end > start, "corpus runner: malformed sidecar documentId field");
    return DocumentId.fromCanonicalText(wire[start .. end]);
}

private struct DecodedCandidate {
    DocumentId documentId;
    bool hasKeys;
    ulong[similarityLanes] lanes;
    size_t contentLength;
}

/// Frozen `byte-shingle-minhash:v1` band derivation. The persisted payload
/// stores only canonical lanes; keeping this version-local adapter beside
/// the phase-2 reader honors the approved zero-change boundary around
/// `domain.similarity_signature` without creating a second wire authority.
private ulong[similarityBands] bandValuesFromLanesV1(
        const ulong[similarityLanes] lanes) pure {
    ulong[similarityBands] result;
    foreach (band; 0 .. similarityBands) {
        ulong hash = (0xcbf29ce484222325UL ^ cast(ubyte) band) *
            0x100000001b3UL;
        foreach (lane; band * 4 .. band * 4 + 4) {
            ulong value = lanes[lane];
            foreach (_; 0 .. 8) {
                hash = (hash ^ cast(ubyte) value) * 0x100000001b3UL;
                value >>= 8;
            }
        }
        result[band] = hash;
    }
    return result;
}

/// Decodes one sidecar file into a candidate, or returns `false` if this
/// sidecar carries no `similarity-signature-v1` structured section (a v1
/// document-metadata sidecar, or a v2 sidecar some other composition
/// produced) -- such a document is simply not a pruning candidate, not an
/// error. Bands are derived from the persisted canonical lanes using the
/// payload's already-validated `byte-shingle-minhash:v1` algorithm version.
private bool tryDecodeCandidate(CorpusScratchDatabase db, int rootFd,
        string relativePath,
        out DecodedCandidate result, out stat_t identity) {
    auto bytes = readBoundedSidecar(db, rootFd, relativePath, identity);
    auto wire = cast(string) bytes;
    auto versionName = metadataVersion(wire);
    auto id = recoverDocumentId(wire);
    trackDecodedDocument(id.text);
    if (versionName == "document-metadata:v1") {
        // Legacy records cannot contain the structured signature section,
        // but they must still be canonical valid metadata rather than a
        // malformed file silently changing the candidate set.
        decodeDocumentMetadataV1(id, wire);
        return false;
    }
    enforce(versionName == "document-metadata:v2",
        "corpus runner: unsupported metadata sidecar version: " ~ versionName);
    auto metadata = decodeDocumentMetadataV2(id, wire);
    foreach (section; metadata.structuredSections) {
        if (section.sectionId != similaritySignatureSectionIdV1) continue;
        auto payload = decodeSimilaritySignaturePayload(section.payload);
        result.documentId = id;
        result.hasKeys = payload.hasKeys;
        result.lanes = payload.lanes;
        result.contentLength = payload.contentLength;
        return true;
    }
    return false;
}

private struct PruneOptions {
    size_t bucketCap = defaultPruneBucketCap;
    PruningPolicy policy = PruningPolicy.keepFirst;
}

/// Writes the mandatory per-pruned-document decision sidecar next to the
/// pruned document's own `.document-metadata.json`, naming the removed
/// document, its surviving representative, and the matching bucket
/// identity. Every field written here is internally constructed (a
/// canonical hex `DocumentId.text`, or `pruneBucketIdentity`'s own fixed
/// `band=N,key=HEX` shape) and therefore never needs JSON escaping.
private string decisionPathFor(string sidecarPath) {
    auto base = baseName(sidecarPath);
    enforce(base.endsWith(documentMetadataPublishSuffixV1),
        "corpus runner: unexpected sidecar file name: " ~ base);
    auto stem = base[0 .. $ - documentMetadataPublishSuffixV1.length];
    auto decisionName = stem ~ pruneNearDuplicatesDecisionSuffixV1;
    auto parent = dirName(sidecarPath);
    return parent == "." ? decisionName : buildPath(parent, decisionName);
}

private int openRelativeDirectory(CorpusScratchDatabase db, int rootFd,
        string relative) {
    enforce(relative.indexOf('\0') < 0 &&
            (!relative.length || relative[0] != '/'),
        "corpus runner: invalid relative directory path");
    auto components = relative.length ? relative.split('/') : null;
    foreach (component; components)
        enforce(component.length && component != "." && component != "..",
            "corpus runner: noncanonical relative sidecar path");
    // `dup` would share the directory-stream offset with the root handle;
    // reopening `.` relative to it creates an independent open description
    // while remaining bound to the same directory inode.
    auto current = openat(rootFd, ".".toStringz,
        O_RDONLY | O_NOFOLLOW | directoryOnly);
    enforce(current >= 0, "corpus runner: cannot reopen sidecar root handle");
    scope(failure) if (current >= 0) close(current);
    stat_t info;
    enforce(fstat(current, &info) == 0,
        "corpus runner: cannot inspect anchored sidecar root");
    verifyDirectoryIdentity(db, "", info);
    string traversed;
    foreach (component; components) {
        auto next = openat(current, component.toStringz,
            O_RDONLY | O_NOFOLLOW | directoryOnly);
        enforce(next >= 0,
            "corpus runner: sidecar parent changed during phase 2");
        close(current);
        current = next;
        traversed = traversed.length ? buildPath(traversed, component) : component;
        enforce(fstat(current, &info) == 0,
            "corpus runner: cannot inspect anchored sidecar directory");
        verifyDirectoryIdentity(db, traversed, info);
    }
    return current;
}

private int openRelativeParent(CorpusScratchDatabase db, int rootFd,
        string relative, out string leaf) {
    enforce(relative.length && relative[0] != '/' && relative.indexOf('\0') < 0,
        "corpus runner: invalid relative sidecar path");
    auto components = relative.split('/');
    foreach (component; components)
        enforce(component.length && component != "." && component != "..",
            "corpus runner: noncanonical relative sidecar path");
    leaf = components[$ - 1];
    return openRelativeDirectory(db, rootFd,
        components.length == 1 ? "" : components[0 .. $ - 1].join("/"));
}

private void verifyMetadataLeafAt(int parentFd, string metadataLeaf,
        string expectedDevice, string expectedInode) {
    stat_t metadataInfo;
    enforce(fstatat(parentFd, metadataLeaf.toStringz, &metadataInfo,
            AT_SYMLINK_NOFOLLOW) == 0 && S_ISREG(metadataInfo.st_mode),
        "corpus runner: metadata sidecar changed before decision publication");
    enforce(metadataInfo.st_dev.to!string == expectedDevice &&
            metadataInfo.st_ino.to!string == expectedInode,
        "corpus runner: metadata sidecar identity changed before decision publication");
}

private void verifyMetadataSidecarIdentity(CorpusScratchDatabase db, int rootFd,
        string relativeSidecarPath, string expectedDevice, string expectedInode) {
    string metadataLeaf;
    auto parentFd = openRelativeParent(db, rootFd, relativeSidecarPath,
        metadataLeaf);
    scope(exit) close(parentFd);
    verifyMetadataLeafAt(parentFd, metadataLeaf, expectedDevice, expectedInode);
}

private string writeDecisionSidecar(CorpusScratchDatabase db, int rootFd,
        string relativeSidecarPath,
        string expectedDevice, string expectedInode,
        string representativeSidecarPath,
        string representativeDevice, string representativeInode,
        CorpusStageDecision decision) {
    auto relativeDecisionPath = decisionPathFor(relativeSidecarPath);
    auto json = `{"schema":"` ~ pruneNearDuplicatesDecisionSchemaV1 ~
        `","removed_document_id":"` ~ decision.documentId.text ~
        `","representative_id":"` ~ decision.representativeId.text ~
        `","bucket_identity":"` ~ decision.bucketIdentity ~ `"}` ~ "\n";
    string leaf;
    auto parentFd = openRelativeParent(db, rootFd, relativeDecisionPath, leaf);
    scope(exit) close(parentFd);

    auto metadataLeaf = baseName(relativeSidecarPath);
    verifyMetadataLeafAt(parentFd, metadataLeaf, expectedDevice, expectedInode);
    verifyMetadataSidecarIdentity(db, rootFd, representativeSidecarPath,
        representativeDevice, representativeInode);

    stat_t priorInfo;
    auto priorFd = openat(parentFd, leaf.toStringz, O_RDONLY | O_NOFOLLOW);
    bool prior;
    if (priorFd >= 0) {
        scope(exit) close(priorFd);
        enforce(fstat(priorFd, &priorInfo) == 0 && S_ISREG(priorInfo.st_mode),
            "corpus runner: decision destination is not a regular file");
        prior = true;
    } else enforce(errno == ENOENT,
        "corpus runner: cannot inspect decision destination safely");

    auto temporary = "." ~ leaf ~ ".scrubbed-" ~ randomUUID.toString ~ ".tmp";
    auto fd = openat(parentFd, temporary.toStringz,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 384);
    enforce(fd >= 0, "corpus runner: cannot create atomic decision temporary");
    bool committed;
    scope(exit) {
        if (fd >= 0) close(fd);
        if (!committed) unlinkat(parentFd, temporary.toStringz, 0);
    }
    auto bytes = cast(const(ubyte)[]) json;
    size_t written;
    while (written < bytes.length) {
        auto amount = posixWrite(fd, bytes.ptr + written, bytes.length - written);
        if (amount < 0) {
            if (errno == EINTR) continue;
            throw new Exception("corpus runner: decision write failed");
        }
        enforce(amount != 0, "corpus runner: decision write made no progress");
        written += cast(size_t) amount;
    }
    enforce(fsync(fd) == 0, "corpus runner: decision flush failed");
    if (prior)
        enforce(fchmod(fd, priorInfo.st_mode & 0xfff) == 0,
            "corpus runner: decision mode preservation failed");
    auto closing = fd;
    fd = -1;
    enforce(close(closing) == 0, "corpus runner: decision close failed");
    version (unittest) {
        if (preDecisionCommitHook !is null) {
            auto hook = preDecisionCommitHook;
            preDecisionCommitHook = null;
            hook();
        }
    }
    verifyMetadataSidecarIdentity(db, rootFd, representativeSidecarPath,
        representativeDevice, representativeInode);
    verifyMetadataLeafAt(parentFd, metadataLeaf, expectedDevice, expectedInode);
    enforce(renameat(parentFd, temporary.toStringz,
        parentFd, leaf.toStringz) == 0,
        "corpus runner: atomic decision replacement failed");
    committed = true;
    return relativeDecisionPath;
}

private void removeDecisionSidecar(CorpusScratchDatabase db, int rootFd,
        string relativeDecisionPath) {
    string leaf;
    auto parentFd = openRelativeParent(db, rootFd, relativeDecisionPath, leaf);
    scope(exit) close(parentFd);
    enforce(unlinkat(parentFd, leaf.toStringz, 0) == 0,
        "corpus runner: stale decision removal failed");
}

/// The actual `prune-near-duplicates` driver. Deterministic regardless of
/// filesystem directory-entry order: candidates are externally sorted by
/// band and document identity before grouping, links are reconciled by a
/// total document ranking, and decisions are emitted in document-ID order.
private void runPruneNearDuplicates(string sidecarRoot, scope CorpusStageSink sink,
        PruneOptions options) {
    enforce(options.bucketCap > 0, "prune-near-duplicates: bucket-cap must be positive");
    enforce(sidecarRoot.length != 0 && exists(sidecarRoot) && isDir(sidecarRoot) &&
            !isSymlink(sidecarRoot),
        "prune-near-duplicates: sidecar root does not exist: " ~ sidecarRoot);
    auto sidecarRootFd = open(sidecarRoot.toStringz,
        O_RDONLY | O_NOFOLLOW | directoryOnly);
    enforce(sidecarRootFd >= 0,
        "prune-near-duplicates: cannot anchor sidecar root safely");
    scope(exit) close(sidecarRootFd);
    version (unittest) {
        if (rootAnchoredHook !is null) {
            auto hook = rootAnchoredHook;
            rootAnchoredHook = null;
            hook(sidecarRoot);
        }
    }

    auto scratch = buildPath(tempDir(), "scrubbed-prune-near-duplicates-" ~
        randomUUID.toString);
    enforce(posixMkdir(scratch.toStringz, 448) == 0,
        "corpus runner: cannot create private scratch directory");
    scope(exit) {
        foreach (entry; dirEntries(scratch, SpanMode.shallow))
            removeScratch(entry.name);
        rmdir(scratch);
    }
    CorpusScratchDatabase db;
    scope(exit) if (db !is null) db.close();
    size_t serial;
    string fresh() { return buildPath(scratch, (serial++).to!string ~ ".run"); }

    auto databasePath = buildPath(scratch, "state.sqlite3");
    auto databaseFd = open(databasePath.toStringz,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 384);
    enforce(databaseFd >= 0, "corpus runner: cannot create scratch database");
    enforce(close(databaseFd) == 0, "corpus runner: cannot close scratch database");
    trackScratchCreate();
    db = new CorpusScratchDatabase(databasePath);
    stat_t rootInfo;
    enforce(fstat(sidecarRootFd, &rootInfo) == 0,
        "corpus runner: cannot inspect anchored sidecar root");
    recordDirectoryIdentity(db, "", rootInfo);

    RunAccumulator accumulator;
    accumulator.fresh = &fresh;
    BandCandidate[] batch;
    auto addDocument = db.prepare("INSERT INTO documents VALUES(?1,?2,?3,?4)");
    scope(exit) sqlite3_finalize(addDocument);
    db.exec("BEGIN");
    walkSidecarTree(db, sidecarRoot, sidecarRootFd, true,
            (string path, string relative, bool directory, bool regular,
                bool symlink) {
        enforce(!symlink,
            "prune-near-duplicates: symlink inside sidecar root: " ~ path);
        if (directory) return;
        enforce(regular,
            "prune-near-duplicates: non-regular entry inside sidecar root: " ~ path);
        if (!path.endsWith(documentMetadataPublishSuffixV1)) return;
        DecodedCandidate decoded;
        stat_t sidecarIdentity;
        if (!tryDecodeCandidate(db, sidecarRootFd, relative, decoded,
                sidecarIdentity)) return;
        auto idText = decoded.documentId.text;
        insertDocument(addDocument, idText, relative, sidecarIdentity);
        // A document whose signature never received real content
        // (hasKeys == false) is excluded here -- never a spurious bucket
        // candidate, matching similarity_buckets.d's own explode().
        if (!decoded.hasKeys) return;
        auto bands = bandValuesFromLanesV1(decoded.lanes);
        foreach (bandIndex; 0 .. similarityBands) {
            batch ~= BandCandidate(idText, bandIndex, bands[bandIndex], decoded.lanes,
                decoded.contentLength);
            trackBatch(batch.length);
            if (batch.length == runRecords) flushRun(batch, accumulator);
        }
    });
    db.exec("COMMIT");
    version (unittest) {
        if (postDiscoveryHook !is null) {
            auto hook = postDiscoveryHook;
            postDiscoveryHook = null;
            hook(sidecarRoot);
        }
    }
    if (batch.length) flushRun(batch, accumulator);
    auto runs = accumulator.finish();
    if (runs.count) runs = mergeRuns(runs, &fresh);

    // Single sequential scan: one already-capped (bandIndex, bandKeyValue)
    // bucket in memory at a time -- never a structure sized by corpus
    // document count.
    auto addLink = db.prepare(`INSERT INTO links VALUES(?1,?2,?3)
ON CONFLICT(document_id) DO UPDATE SET
 representative_id=excluded.representative_id,
 bucket_identity=excluded.bucket_identity
WHERE excluded.representative_id < links.representative_id`);
    scope(exit) sqlite3_finalize(addLink);
    db.exec("BEGIN");
    if (runs.count) {
        auto sorted = File(runs.firstPath(), "rb");
        trackOpen();
        scope(exit) { sorted.close(); trackClose(); }
        BandCandidate item;
        bool hasItem = readRecord(sorted, item);
        while (hasItem) {
            auto bandIndex = item.bandIndex;
            auto bandKeyValue = item.bandKeyValue;
            NearDedupCandidate[] members;
            size_t groupSize;
            while (hasItem && item.bandIndex == bandIndex && item.bandKeyValue == bandKeyValue) {
                if (groupSize < options.bucketCap) {
                    import domain.similarity_signature : SimilaritySignature;
                    SimilaritySignature signature;
                    signature.documentId = DocumentId.fromCanonicalText(item.documentId);
                    signature.hasKeys = true;
                    signature.lanes = item.lanes;
                    members ~= NearDedupCandidate(false, 0, bandIndex, bandKeyValue,
                        false, signature, item.contentLength);
                    trackBucket(members.length);
                }
                ++groupSize;
                hasItem = readRecord(sorted, item);
            }
            if (groupSize > options.bucketCap)
                foreach (ref member; members) member.overflowed = true;
            if (members.length >= 2) {
                auto identity = pruneBucketIdentity(bandIndex, bandKeyValue);
                foreach (link; nearDuplicateLinksInBucket(members, options.policy))
                    upsertLink(addLink, link.documentId.text,
                        link.representativeId.text, identity);
            }
        }
    }
    db.exec("COMMIT");

    // Cross-bucket conflict resolution: a document's signature can explode
    // into up to `similarityBands` independent band rows and land in more
    // than one bucket at once, with each bucket independently possibly
    // naming a different representative for it. The smallest representative
    // ID wins (the same deterministic tie-break representative selection
    // itself already uses), then every entry is chain-resolved to its true
    // root -- never itself a key in this same map -- mirroring
    // `effects.near_dedup_overlay.d`'s own private Phase C exactly
    // (independently reimplemented here: that helper is private to a module
    // this slice must not modify). The bucket identity recorded for each
    // document is the one belonging to its winning direct link (before
    // chain resolution), giving the mandatory decision sidecar a concrete,
    // real grouping to name.
    while (true) {
        db.exec(`UPDATE links SET representative_id=(
 SELECT parent.representative_id FROM links AS parent
 WHERE parent.document_id=links.representative_id)
WHERE EXISTS(
 SELECT 1 FROM links AS parent
 WHERE parent.document_id=links.representative_id)`);
        if (sqlite3_changes(db.handle) == 0) {
            break;
        }
    }

    // Validate the complete discovered corpus before the first publication so
    // a changed representative cannot leave a partially published decision
    // set. Per-decision checks below narrow the subsequent race window too.
    auto verifyDocuments = db.prepare(`SELECT sidecar_path,device,inode
FROM documents ORDER BY document_id`);
    scope(exit) sqlite3_finalize(verifyDocuments);
    int verifyStep;
    while ((verifyStep = sqlite3_step(verifyDocuments)) == SQLITE_ROW)
        verifyMetadataSidecarIdentity(db, sidecarRootFd,
            columnText(verifyDocuments, 0), columnText(verifyDocuments, 1),
            columnText(verifyDocuments, 2));
    dbNeed(verifyStep == SQLITE_DONE, "document identity scan failed");

    auto addDecision = db.prepare("INSERT INTO decisions VALUES(?1)");
    scope(exit) sqlite3_finalize(addDecision);
    auto decisions = db.prepare(`SELECT links.document_id,
 links.representative_id,links.bucket_identity,removed.sidecar_path,
 removed.device,removed.inode,representative.sidecar_path,
 representative.device,representative.inode
FROM links
JOIN documents AS removed ON removed.document_id=links.document_id
JOIN documents AS representative
 ON representative.document_id=links.representative_id
ORDER BY links.document_id`);
    scope(exit) sqlite3_finalize(decisions);
    int decisionStep;
    while ((decisionStep = sqlite3_step(decisions)) == SQLITE_ROW) {
        auto documentId = columnText(decisions, 0);
        auto representativeId = columnText(decisions, 1);
        auto bucketIdentity = columnText(decisions, 2);
        auto relativeSidecarPath = columnText(decisions, 3);
        auto expectedDevice = columnText(decisions, 4);
        auto expectedInode = columnText(decisions, 5);
        auto representativeSidecarPath = columnText(decisions, 6);
        auto representativeDevice = columnText(decisions, 7);
        auto representativeInode = columnText(decisions, 8);
        auto decision = CorpusStageDecision(DocumentId.fromCanonicalText(documentId),
            CorpusDecisionKind.prune, DocumentId.fromCanonicalText(representativeId),
            bucketIdentity);
        auto decisionPath = writeDecisionSidecar(db, sidecarRootFd,
            relativeSidecarPath, expectedDevice, expectedInode,
            representativeSidecarPath, representativeDevice,
            representativeInode, decision);
        bindText(addDecision, 1, decisionPath);
        dbNeed(sqlite3_step(addDecision) == SQLITE_DONE,
            "decision path write failed");
        resetStatement(addDecision);
        sink(decision);
    }
    dbNeed(decisionStep == SQLITE_DONE, "decision scan failed");

    // Reconcile derived decisions only after all current decisions were
    // published successfully. Files from an earlier run whose documents no
    // longer prune are removed; current files remain atomically replaced.
    auto currentDecision = db.prepare(
        "SELECT 1 FROM decisions WHERE decision_path=?1");
    scope(exit) sqlite3_finalize(currentDecision);
    walkSidecarTree(db, sidecarRoot, sidecarRootFd, false,
            (string path, string relative, bool directory, bool regular,
                bool symlink) {
        enforce(!symlink,
            "prune-near-duplicates: symlink inside sidecar root: " ~ path);
        if (directory) return;
        enforce(regular,
            "prune-near-duplicates: non-regular entry inside sidecar root: " ~ path);
        if (!path.endsWith(pruneNearDuplicatesDecisionSuffixV1)) return;
        bindText(currentDecision, 1, relative);
        auto currentStep = sqlite3_step(currentDecision);
        dbNeed(currentStep == SQLITE_ROW || currentStep == SQLITE_DONE,
            "decision reconciliation scan failed");
        auto isCurrent = currentStep == SQLITE_ROW;
        resetStatement(currentDecision);
        if (!isCurrent) {
            removeDecisionSidecar(db, sidecarRootFd, relative);
        }
    });
}

// ---------------------------------------------------------------------------
// Registration.
// ---------------------------------------------------------------------------

private string optionalText(const ref StageOptions options, string key, string defaultValue) {
    auto selected = key in options;
    return selected is null ? defaultValue : selected.asText;
}
private long optionalInteger(const ref StageOptions options, string key, long defaultValue) {
    auto selected = key in options;
    return selected is null ? defaultValue : selected.asInteger;
}

private CorpusStageRun factory(const ref StageOptions options) {
    PruneOptions resolved;
    auto bucketCap = optionalInteger(options, "bucket-cap", defaultPruneBucketCap);
    enforce(bucketCap > 0, "prune-near-duplicates: bucket-cap must be positive");
    resolved.bucketCap = cast(size_t) bucketCap;
    auto policyName = optionalText(options, "policy", "keep-first");
    if (policyName == "keep-first") resolved.policy = PruningPolicy.keepFirst;
    else if (policyName == "keep-longest") resolved.policy = PruningPolicy.keepLongest;
    else throw new Exception("prune-near-duplicates: unsupported policy: " ~ policyName);
    return (string sidecarRoot, scope CorpusStageSink sink) {
        runPruneNearDuplicates(sidecarRoot, sink, resolved);
    };
}

static this() {
    registerCorpusStage(CorpusStageRegistration(
        CorpusStageDeclaration(pruneNearDuplicatesStageKeyV1),
        [OptionDeclaration("bucket-cap", OptionType.integer, false),
         OptionDeclaration("policy", OptionType.text, false)],
        &factory));
}

// ---------------------------------------------------------------------------
// Unit tests.
// ---------------------------------------------------------------------------

version (unittest) {
    import domain.document : SourceLocator;
    import domain.document_metadata : DocumentMetadata, encodeDocumentMetadataV1,
        encodeDocumentMetadataV2;
    import domain.similarity_signature : similaritySignatures;
    import effects.similarity_signature_annotate_stage : encodeSimilaritySignaturePayload;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, exists, write;
    import std.json : parseJSON;

    private DocumentId fixtureId(string recordKey) {
        return DocumentId.from(SourceLocator("corpus-runner-unit", "source", recordKey));
    }

    private string freshRoot(string label) {
        auto root = buildPath(tempDir(), "scrubbed-corpus-runner-" ~ label ~ "-" ~ randomUUID().toString());
        mkdirRecurse(root);
        return root;
    }

    /// Writes a real, fully-encoded `document-metadata:v2` sidecar -- the
    /// same wire shape `effects.similarity_signature_annotate_stage` +
    /// `effects.document_metadata_publish_stage` would actually produce --
    /// so these tests exercise the real decode path, not a synthetic
    /// shortcut.
    /// `declaredContentLength` defaults to the real `content.length`, but a
    /// caller may override it independently -- `encodeSimilaritySignaturePayload`
    /// itself takes content length as a separate, caller-supplied parameter
    /// (it is not derived from the signature), so a fixture can pin two
    /// documents to the exact same real MinHash signature (byte-identical
    /// `content`, a guaranteed-above-threshold match) while still declaring
    /// different content lengths, to test `PruningPolicy.keepLongest`
    /// without depending on real natural-language content happening to
    /// clear the similarity threshold after being lengthened.
    private void writeFixtureSidecar(string root, string name, string content,
            long declaredContentLength = -1) {
        auto id = fixtureId(name);
        auto signatures = similaritySignatures(id, cast(const(ubyte)[]) content);
        auto contentLength = declaredContentLength < 0 ? content.length : cast(size_t) declaredContentLength;
        auto payload = encodeSimilaritySignaturePayload(signatures.document, contentLength);
        auto metadata = DocumentMetadata.empty()
            .withStructuredSection(similaritySignatureSectionIdV1, payload.idup,
                "similarity-signature-annotate");
        auto wire = encodeDocumentMetadataV2(id, metadata);
        write(buildPath(root, name ~ documentMetadataPublishSuffixV1), wire);
    }

    private CorpusStageDecision[] runFixture(string root, PruneOptions options = PruneOptions.init) {
        CorpusStageDecision[] observed;
        runPruneNearDuplicates(root, (CorpusStageDecision decision) { observed ~= decision; }, options);
        return observed;
    }
}

// The phase-2 v1 adapter is byte-for-byte compatible with the canonical
// domain implementation for real signatures, while the wire retains only
// the lanes from which these values are derived.
unittest {
    auto texts = [
        "A deterministic band derivation compatibility fixture.",
        "Another fixture with unrelated words and punctuation!",
        "UPPER\tcase and whitespace normalization fixture"
    ];
    foreach (i, text; texts) {
        auto signature = similaritySignatures(fixtureId("bands-" ~ i.to!string),
            cast(const(ubyte)[]) text).document;
        assert(signature.hasKeys);
        assert(bandValuesFromLanesV1(signature.lanes) == signature.bands);
    }
}

// Two byte-identical documents are a certain near-duplicate pair: exactly
// one prune decision is emitted, the lexicographically-smaller ID survives
// as representative, and the mandatory decision sidecar is written next to
// the pruned document's own `.document-metadata.json` with the right
// fields.
unittest {
    auto root = freshRoot("basic");
    scope(exit) rmdirRecurse(root);

    auto text = "This exact sentence is long enough to produce real MinHash shingles for testing.";
    writeFixtureSidecar(root, "doc-one", text);
    writeFixtureSidecar(root, "doc-two", text);
    writeFixtureSidecar(root, "doc-three",
        "An entirely unrelated sentence about something completely different from the others.");

    auto decisions = runFixture(root);
    assert(decisions.length == 1);
    assert(decisions[0].kind == CorpusDecisionKind.prune);

    auto idOne = fixtureId("doc-one");
    auto idTwo = fixtureId("doc-two");
    auto expectedRepresentative = idOne.text < idTwo.text ? idOne : idTwo;
    auto expectedDropped = expectedRepresentative == idOne ? idTwo : idOne;
    assert(decisions[0].documentId == expectedDropped);
    assert(decisions[0].representativeId == expectedRepresentative);
    assert(decisions[0].bucketIdentity.length != 0);

    auto droppedName = expectedDropped == idOne ? "doc-one" : "doc-two";
    auto decisionPath = buildPath(root, droppedName ~ pruneNearDuplicatesDecisionSuffixV1);
    assert(exists(decisionPath));
    auto parsed = parseJSON(cast(string) read(decisionPath));
    assert(parsed["removed_document_id"].str == expectedDropped.text);
    assert(parsed["representative_id"].str == expectedRepresentative.text);
    assert(parsed["bucket_identity"].str == decisions[0].bucketIdentity);

    // The surviving representative gets no decision sidecar of its own.
    auto survivorName = expectedRepresentative == idOne ? "doc-one" : "doc-two";
    assert(!exists(buildPath(root, survivorName ~ pruneNearDuplicatesDecisionSuffixV1)));
    // Nothing under `--output`/primary content is ever touched by this
    // driver -- it only ever reads and adds sidecar-adjacent files.
}

// Below-threshold documents never link, and a document whose content is too
// short for real MinHash keys (`hasKeys == false`) never contributes a
// spurious bucket candidate.
unittest {
    auto root = freshRoot("no-link");
    scope(exit) rmdirRecurse(root);

    writeFixtureSidecar(root, "alpha", "A completely unrelated first sentence about gardening techniques today.");
    writeFixtureSidecar(root, "beta", "A totally different second sentence concerning astronomy and telescopes.");
    writeFixtureSidecar(root, "short-one", "ab"); // hasKeys == false
    writeFixtureSidecar(root, "short-two", "cd"); // identical zero lanes

    auto decisions = runFixture(root);
    assert(decisions.length == 0);
}

// `PruningPolicy.keepLongest` is honored end to end through the real
// registered factory: the longer document survives as representative even
// when its ID sorts later.
unittest {
    import stages.registry : StageOption;

    auto root = freshRoot("keep-longest");
    scope(exit) rmdirRecurse(root);

    auto text = "Byte-identical content guarantees a near-duplicate match for this fixture case.";
    auto firstById = fixtureId("policy-one").text < fixtureId("policy-two").text ?
        "policy-one" : "policy-two";
    auto laterById = firstById == "policy-one" ? "policy-two" : "policy-one";

    // Byte-identical real content (Jaccard == 1.0, certainly above
    // threshold) for both documents, with independently DECLARED content
    // lengths -- `keepLongest` only ever consults the declared length, so
    // this isolates that policy's own behavior from real-content
    // similarity variance.
    writeFixtureSidecar(root, firstById, text, 10);
    writeFixtureSidecar(root, laterById, text, 500);

    StageOptions selected = ["policy": StageOption.text("keep-longest")];
    auto run = factory(selected);
    CorpusStageDecision[] decisions;
    run(root, (CorpusStageDecision decision) { decisions ~= decision; });
    assert(decisions.length == 1);
    assert(decisions[0].representativeId == fixtureId(laterById));
    assert(decisions[0].documentId == fixtureId(firstById));
}

// Order-invariance proof (issue #564's own explicit acceptance criterion):
// the SAME three real document identities (identical `name` parameters, so
// identical `DocumentId`s), stored under deliberately different
// subdirectory prefixes in two separate roots so their filesystem walk
// order comes out reversed between the two roots, still produce byte-for-
// byte identical decisions either way. (Per-bucket
// representative selection is already proven order-invariant by
// `domain.near_dedup_decision`'s own "chain" unittest, reused completely
// unmodified here; this test instead exercises this module's own
// responsibility -- that its path-sort-based canonicalization and its
// cross-bucket reconciliation produce one, order-independent answer.)
unittest {
    auto text = "A shared sentence long enough for real MinHash shingles across three documents.";

    void writeNested(string root, string subdir, string name) {
        auto dir = buildPath(root, subdir);
        mkdirRecurse(dir);
        auto id = fixtureId(name);
        auto signatures = similaritySignatures(id, cast(const(ubyte)[]) text);
        auto payload = encodeSimilaritySignaturePayload(signatures.document, text.length);
        auto metadata = DocumentMetadata.empty()
            .withStructuredSection(similaritySignatureSectionIdV1, payload.idup,
                "similarity-signature-annotate");
        auto wire = encodeDocumentMetadataV2(id, metadata);
        write(buildPath(dir, name ~ documentMetadataPublishSuffixV1), wire);
    }

    auto rootA = freshRoot("order-a");
    scope(exit) rmdirRecurse(rootA);
    writeNested(rootA, "a-dir", "first");
    writeNested(rootA, "m-dir", "second");
    writeNested(rootA, "z-dir", "third");
    // rootA's full sidecar paths sort as: a-dir/first, m-dir/second, z-dir/third.

    auto rootB = freshRoot("order-b");
    scope(exit) rmdirRecurse(rootB);
    writeNested(rootB, "z-dir", "first");
    writeNested(rootB, "m-dir", "second");
    writeNested(rootB, "a-dir", "third");
    // rootB's full sidecar paths sort as: a-dir/third, m-dir/second, z-dir/first
    // -- the REVERSE processing order relative to rootA, for the exact same
    // three document identities ("first"/"second"/"third").

    resetCorpusRunnerObservations();
    auto decisionsA = runFixture(rootA);
    auto orderA = corpusRunnerDecodedDocumentOrder();
    resetCorpusRunnerObservations();
    auto decisionsB = runFixture(rootB);
    auto orderB = corpusRunnerDecodedDocumentOrder();
    assert(orderA != orderB,
        "fixture must exercise genuinely different candidate traversal orders");
    assert(decisionsA.length == 2 && decisionsB.length == 2);
    assert(decisionsA == decisionsB,
        "ordered full decisions must be identical regardless of walk order");

    string[] decisionBytes(string root) {
        string[] result;
        foreach (entry; dirEntries(root, SpanMode.depth, false))
            if (entry.isFile &&
                    entry.name.endsWith(pruneNearDuplicatesDecisionSuffixV1))
                result ~= baseName(entry.name) ~ "\0" ~ cast(string) read(entry.name);
        result.sort();
        return result;
    }
    assert(decisionBytes(rootA) == decisionBytes(rootB),
        "serialized decision sidecars must be byte-identical");
}

// Resource enforcement: every live-memory/scratch ceiling tracks the fixed
// batch, fan-in, and declared bucket cap rather than corpus size.
unittest {
    resetCorpusRunnerObservations();
    auto root = freshRoot("bucket-cap");
    scope(exit) rmdirRecurse(root);

    auto text = "Shared bulk-fixture content long enough for real MinHash shingles in this corpus.";
    // 144 documents produce 72 initial runs (16 band rows each), exceeding
    // fanIn^^2 and therefore forcing a second compaction level.
    enum size_t documentCount = 144;
    string[] expectedIds;
    foreach (i; 0 .. documentCount)
    {
        auto name = "bulk-" ~ i.to!string;
        expectedIds ~= fixtureId(name).text;
        writeFixtureSidecar(root, name, text);
    }
    expectedIds.sort();

    auto decisions = runFixture(root, PruneOptions(4, PruningPolicy.keepFirst));
    assert(decisions.length == 3,
        "every one of the four capped records must survive multi-level compaction");
    foreach (i, decision; decisions) {
        assert(decision.documentId.text == expectedIds[i + 1]);
        assert(decision.representativeId.text == expectedIds[0]);
    }
    assert(corpusRunnerPeakBatchRecords() <= runRecords,
        "peak in-flight batch record count must track runRecords, not corpus size");
    assert(corpusRunnerPeakBucketMembers() <= 4,
        "peak bucket members must track bucket-cap, not corpus size");
    assert(corpusRunnerPeakOpenScratchFiles() <= fanIn + 3,
        "open scratch descriptors must track merge fan-in");
    // Two populated levels may each hold fanIn runs transiently while the
    // next merge output is created; the extra artifact is the scratch DB.
    assert(corpusRunnerPeakScratchArtifacts() <= fanIn * 2 + 1,
        "two-level compaction must keep scratch artifacts logarithmic");
    assert(scratchArtifactsCurrent == 0,
        "all scratch artifacts must be cleaned after the run");
}

// The configured cap limits actual bucket membership; it is never used as
// an eager allocation size. A singleton therefore remains cheap even with
// the largest representable direct-call cap.
unittest {
    auto root = freshRoot("lazy-cap");
    scope(exit) rmdirRecurse(root);
    writeFixtureSidecar(root, "only", "A keyed singleton document for cap testing.");
    auto decisions = runFixture(root,
        PruneOptions(size_t.max, PruningPolicy.keepFirst));
    assert(decisions.length == 0);
}

// Legacy v1 records are valid non-candidates, but malformed v1 text is a
// hard corpus error rather than a silently skipped candidate.
unittest {
    import std.exception : assertThrown;

    resetCorpusRunnerObservations();
    auto root = freshRoot("v1-validation");
    scope(exit) rmdirRecurse(root);
    auto validId = fixtureId("legacy-valid");
    write(buildPath(root, "legacy-valid" ~ documentMetadataPublishSuffixV1),
        encodeDocumentMetadataV1(validId, DocumentMetadata.empty));
    assert(runFixture(root).length == 0);

    write(buildPath(root, "legacy-malformed" ~ documentMetadataPublishSuffixV1),
        `{"version":"document-metadata:v1","documentId":"` ~
        fixtureId("legacy-malformed").text ~ `"}`);
    assertThrown(runFixture(root));
    assert(scratchArtifactsCurrent == 0,
        "malformed-wire failure must clean every scratch artifact");
}

// Successful reruns reconcile the derived decision set: when a former
// duplicate becomes unique, its old prune verdict must disappear.
unittest {
    auto root = freshRoot("stale-decision");
    scope(exit) rmdirRecurse(root);
    auto sharedText = "Shared text long enough to produce a deterministic duplicate signature.";
    writeFixtureSidecar(root, "first", sharedText);
    writeFixtureSidecar(root, "second", sharedText);
    assert(runFixture(root).length == 1);
    string stale;
    foreach (entry; dirEntries(root, SpanMode.shallow, false))
        if (entry.name.endsWith(pruneNearDuplicatesDecisionSuffixV1))
            stale = entry.name;
    assert(stale.length && exists(stale));

    writeFixtureSidecar(root, "second",
        "Now this document is unrelated to the first one and must not remain pruned.");
    assert(runFixture(root).length == 0);
    assert(!exists(stale));
}

// A sidecar is bounded before parsing/materialization, not after an
// arbitrarily large read.
unittest {
    import std.exception : assertThrown;

    resetCorpusRunnerObservations();
    auto root = freshRoot("oversize-sidecar");
    scope(exit) rmdirRecurse(root);
    auto oversized = new ubyte[maxTotalEncodedBytesV2 + 1];
    write(buildPath(root, "oversized" ~ documentMetadataPublishSuffixV1), oversized);
    assertThrown(runFixture(root));
    assert(scratchArtifactsCurrent == 0,
        "oversize failure must clean every scratch artifact");
}

version (Posix) unittest {
    import std.exception : assertThrown;
    import std.file : symlink;

    auto root = freshRoot("symlink-boundary");
    scope(exit) rmdirRecurse(root);
    auto outside = freshRoot("symlink-outside");
    scope(exit) rmdirRecurse(outside);
    writeFixtureSidecar(outside, "outside-one",
        "Shared outside text long enough for a signature.");
    writeFixtureSidecar(outside, "outside-two",
        "Shared outside text long enough for a signature.");
    auto sentinel = buildPath(outside, "sentinel.txt");
    write(sentinel, "must survive");
    auto linkPath = buildPath(root, "escape");
    symlink(outside, linkPath);
    scope(exit) if (exists(linkPath) || isSymlink(linkPath)) remove(linkPath);
    assertThrown(runFixture(root));
    assert(cast(string) read(sentinel) == "must survive");
}

// Decision publication and stale removal are anchored to the root descriptor.
// If a parent is swapped for a symlink after that descriptor is opened, both
// operations fail closed and cannot redirect outside the corpus root.
version (Posix) unittest {
    import std.exception : assertThrown;
    import std.file : mkdir, rename, symlink;

    auto root = freshRoot("parent-swap");
    scope(exit) rmdirRecurse(root);
    auto outside = freshRoot("parent-swap-outside");
    scope(exit) rmdirRecurse(outside);
    auto nested = buildPath(root, "nested");
    mkdir(nested);
    auto rootFd = open(root.toStringz, O_RDONLY | O_NOFOLLOW | directoryOnly);
    assert(rootFd >= 0);
    scope(exit) close(rootFd);
    rename(nested, buildPath(root, "original"));
    symlink(outside, nested);
    auto outsideDecision = buildPath(outside,
        "doc" ~ pruneNearDuplicatesDecisionSuffixV1);
    write(outsideDecision, "must survive");

    auto removed = fixtureId("swap-removed");
    auto representative = fixtureId("swap-representative");
    auto decision = CorpusStageDecision(removed, CorpusDecisionKind.prune,
        representative, "band=0,key=0000000000000000");
    assertThrown(writeDecisionSidecar(null, rootFd,
        "nested/doc" ~ documentMetadataPublishSuffixV1, "", "",
        "nested/representative" ~ documentMetadataPublishSuffixV1,
        "", "", decision));
    assert(cast(string) read(outsideDecision) == "must survive");
    assertThrown(removeDecisionSidecar(null, rootFd,
        "nested/doc" ~ pruneNearDuplicatesDecisionSuffixV1));
    assert(cast(string) read(outsideDecision) == "must survive");
}

// The descriptor opened for the corpus root governs discovery, reads, and
// writes together. Replacing the pathname after that open cannot make the
// runner read a replacement corpus and publish those decisions into the
// originally opened one.
version (Posix) unittest {
    import std.file : mkdir, rename;

    auto container = freshRoot("root-swap");
    scope(exit) rmdirRecurse(container);
    auto sidecarRoot = buildPath(container, "sidecars");
    auto replacement = buildPath(container, "replacement");
    auto anchored = buildPath(container, "anchored");
    mkdir(sidecarRoot);
    mkdir(replacement);
    auto textA = "Original-root duplicate text with enough shingles for a signature.";
    auto textB = "Replacement-root duplicate text with enough shingles for a signature.";
    writeFixtureSidecar(sidecarRoot, "a-one", textA);
    writeFixtureSidecar(sidecarRoot, "a-two", textA);
    writeFixtureSidecar(replacement, "b-one", textB);
    writeFixtureSidecar(replacement, "b-two", textB);

    rootAnchoredHook = (string openedRoot) {
        assert(openedRoot == sidecarRoot);
        rename(sidecarRoot, anchored);
        rename(replacement, sidecarRoot);
    };
    auto decisions = runFixture(sidecarRoot);
    assert(decisions.length == 1);
    assert(decisions[0].documentId == fixtureId("a-one") ||
        decisions[0].documentId == fixtureId("a-two"));

    size_t anchoredDecisions;
    foreach (entry; dirEntries(anchored, SpanMode.shallow, false))
        if (entry.isFile &&
                entry.name.endsWith(pruneNearDuplicatesDecisionSuffixV1))
            ++anchoredDecisions;
    size_t replacementDecisions;
    foreach (entry; dirEntries(sidecarRoot, SpanMode.shallow, false))
        if (entry.isFile &&
                entry.name.endsWith(pruneNearDuplicatesDecisionSuffixV1))
            ++replacementDecisions;
    assert(anchoredDecisions == 1);
    assert(replacementDecisions == 0);
}

// A descendant ordinary directory is identity-bound during discovery. If it
// is replaced before publication, the run fails before writing a decision or
// emitting one for metadata that no longer occupies that directory.
version (Posix) unittest {
    import std.exception : assertThrown;
    import std.file : mkdir, rename;

    auto root = freshRoot("nested-directory-swap");
    scope(exit) rmdirRecurse(root);
    auto nested = buildPath(root, "nested");
    auto replacement = buildPath(root, "replacement");
    auto original = buildPath(root, "original");
    mkdir(nested);
    mkdir(replacement);
    auto originalText =
        "Original nested duplicate text with enough shingles for a signature.";
    writeFixtureSidecar(nested, "one", originalText);
    writeFixtureSidecar(nested, "two", originalText);
    auto replacementText =
        "Replacement nested duplicate text with enough shingles for a signature.";
    writeFixtureSidecar(replacement, "other-one", replacementText);
    writeFixtureSidecar(replacement, "other-two", replacementText);

    postDiscoveryHook = (string) {
        rename(nested, original);
        rename(replacement, nested);
    };
    CorpusStageDecision[] observed;
    assertThrown(runPruneNearDuplicates(root,
        (CorpusStageDecision decision) { observed ~= decision; },
        PruneOptions.init));
    assert(observed.length == 0,
        "a changed directory must fail before emitting any decision");

    foreach (directory; [original, nested])
        foreach (entry; dirEntries(directory, SpanMode.shallow, false))
            assert(!entry.name.endsWith(pruneNearDuplicatesDecisionSuffixV1));
}

// Metadata leaves are identity-bound too. Replacing only the selected
// representative after its first per-decision check cannot publish or emit a
// decision that names metadata no longer present in the unchanged directory.
version (Posix) unittest {
    import std.exception : assertThrown;
    import std.file : mkdir, rename;

    auto root = freshRoot("metadata-leaf-swap");
    scope(exit) rmdirRecurse(root);
    auto nested = buildPath(root, "nested");
    mkdir(nested);
    auto replacements = freshRoot("metadata-leaf-replacements");
    scope(exit) if (exists(replacements)) rmdirRecurse(replacements);
    auto originalText =
        "Original metadata duplicate text with enough shingles for a signature.";
    writeFixtureSidecar(nested, "one", originalText);
    writeFixtureSidecar(nested, "two", originalText);
    auto replacementText =
        "Unrelated replacement metadata text with enough shingles for a signature.";
    writeFixtureSidecar(replacements, "replacement", replacementText);
    auto representativeStem = fixtureId("one").text < fixtureId("two").text ?
        "one" : "two";

    preDecisionCommitHook = () {
        rename(buildPath(replacements,
                "replacement" ~ documentMetadataPublishSuffixV1),
            buildPath(nested,
                representativeStem ~ documentMetadataPublishSuffixV1));
    };
    CorpusStageDecision[] observed;
    assertThrown(runPruneNearDuplicates(root,
        (CorpusStageDecision decision) { observed ~= decision; },
        PruneOptions.init));
    assert(observed.length == 0,
        "a changed representative must fail before emitting any decision");
    size_t remainingFiles;
    foreach (entry; dirEntries(nested, SpanMode.shallow, false)) {
        assert(entry.isFile &&
            entry.name.endsWith(documentMetadataPublishSuffixV1),
            "failed publication must remove its temporary artifact");
        ++remainingFiles;
    }
    assert(remainingFiles == 2);
}

// Reachability: the stage is genuinely self-registering, and a run through
// its real factory (default options) behaves identically to calling
// `runPruneNearDuplicates` directly with `PruneOptions.init`.
unittest {
    import stages.corpus_contract : availableCorpusStages;

    auto registration = availableCorpusStages().find(pruneNearDuplicatesStageKeyV1);
    assert(registration !is null);
    StageOptions defaultOptions;
    auto run = registration.factory(defaultOptions);

    auto root = freshRoot("reachability");
    scope(exit) rmdirRecurse(root);
    auto text = "Reachability fixture sentence long enough for a real MinHash signature to be computed.";
    writeFixtureSidecar(root, "solo-one", text);
    writeFixtureSidecar(root, "solo-two", text);

    CorpusStageDecision[] observed;
    run(root, (CorpusStageDecision decision) { observed ~= decision; });
    assert(observed.length == 1);
    assert(observed[0].kind == CorpusDecisionKind.prune);
}

// An unsupported `policy` option value, and a non-positive `bucket-cap`
// value, are both rejected at factory-build time, not silently defaulted
// or accepted.
unittest {
    import stages.registry : StageOption;
    import std.exception : assertThrown;

    StageOptions badPolicy = ["policy": StageOption.text("not-a-real-policy")];
    assertThrown(factory(badPolicy));
    StageOptions zeroCap = ["bucket-cap": StageOption.integer(0)];
    assertThrown(factory(zeroCap));
    StageOptions negativeCap = ["bucket-cap": StageOption.integer(-5)];
    assertThrown(factory(negativeCap));
}

// Cross-validation against issue #480's original, shard-sourced
// implementation (issue #564's own explicit acceptance criterion): this
// module's sidecar-sourced path and `effects.near_dedup_overlay`'s
// shard-sourced path must reach the SAME pruning decisions on identical
// input content -- run both paths and diff decisions, not just eyeball one
// path's output.
//
// Both paths reuse `domain.near_dedup_decision.nearDuplicateLinksInBucket`
// completely unmodified, so agreement here is really a proof that this
// module's own sidecar-sourced grouping (external sort + band recompute +
// cross-bucket reconciliation) reaches the same bucket membership and the
// same cross-bucket resolution as `similarity_buckets.d` +
// `near_dedup_overlay.d`'s shard-sourced grouping, for the same real
// signatures.
//
// Scope note: `near_dedup_overlay.d`'s main annotation overlay is sourced
// from `finalLinks` (segment-level AND document-level candidates), while
// this module is document-level only by design (issue #564's explicit
// scope). For a fixture document short enough to fit in exactly one
// segment (under `similaritySegmentBytes` = 4096 bytes -- true of every
// fixture below), `domain.similarity_signature.similaritySignatures`
// computes that one segment's signature over the exact same byte range as
// the document-level signature, so the two are numerically identical and
// `finalLinks`/`finalPruningLinks` provably coincide for these fixtures
// specifically -- reading the plain annotation overlay is a valid stand-in
// for the document-level-only decision set here, not in general.
unittest {
    import domain.document : SourceLocator;
    import domain.shard_format : AnnotationRecord, ShardDocument;
    import effects.document_shards : DocumentShardWriter, OverlayReader;
    import effects.near_dedup_overlay : NearDedupShard, writeNearDedupOverlays;
    import effects.similarity_buckets : SimilarityBatchEntry, SimilarityShard,
        similarityBatchReader, writeSimilarityBucketOverlays;
    import domain.document : OutputName;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir;

    auto root = buildPath(tempDir(), "scrubbed-corpus-runner-crossval-" ~ randomUUID().toString());
    mkdirRecurse(root);
    scope(exit) rmdirRecurse(root);

    auto sharedText =
        "Cross-validation fixture sentence long enough for real MinHash shingles in this test.";
    auto uniqueText =
        "An entirely unrelated sentence about something different for this crossval fixture only.";

    ShardDocument[] documents = [
        ShardDocument(SourceLocator("corpus-runner-crossval", "source", "alpha"),
            OutputName("alpha"), cast(ubyte[]) sharedText.dup),
        ShardDocument(SourceLocator("corpus-runner-crossval", "source", "beta"),
            OutputName("beta"), cast(ubyte[]) sharedText.dup),
        ShardDocument(SourceLocator("corpus-runner-crossval", "source", "gamma"),
            OutputName("gamma"), cast(ubyte[]) uniqueText.dup),
    ];

    // --- Path A: the shard-sourced path (issue #480's original implementation). ---
    auto sourcePath = buildPath(root, "source.shard");
    {
        auto sorted = documents.dup;
        sorted.sort!((a, b) => a.id.text < b.id.text);
        auto writer = new DocumentShardWriter(sourcePath);
        foreach (record; sorted) writer.append(record);
        writer.publish();
    }
    SimilarityBatchEntry[] entries;
    foreach (record; documents)
        entries ~= SimilarityBatchEntry(
            similaritySignatures(record.id, record.content), record.contentDigest, 0);
    auto bucketsPath = buildPath(root, "buckets.overlay");
    writeSimilarityBucketOverlays([SimilarityShard(sourcePath, bucketsPath)],
        similarityBatchReader(entries));
    auto annotationPath = buildPath(root, "annotation.overlay");
    writeNearDedupOverlays([NearDedupShard(sourcePath, bucketsPath, annotationPath)]);

    string[string] shardPathDecisions; // documentId -> representativeId
    {
        auto reader = new OverlayReader(annotationPath);
        scope(exit) reader.closeReader();
        AnnotationRecord record;
        while (reader.next(record))
            shardPathDecisions[record.documentId] = cast(string) record.fields[2].value;
    }
    assert(shardPathDecisions.length != 0, "fixture bug: shard path found no near-duplicates");

    // --- Path B: the sidecar-sourced path (this module). ---
    auto sidecarRoot = buildPath(root, "sidecar");
    mkdirRecurse(sidecarRoot);
    foreach (record; documents) {
        auto signatures = similaritySignatures(record.id, record.content);
        auto payload = encodeSimilaritySignaturePayload(signatures.document, record.content.length);
        auto metadata = DocumentMetadata.empty()
            .withStructuredSection(similaritySignatureSectionIdV1, payload.idup,
                "similarity-signature-annotate");
        auto wire = encodeDocumentMetadataV2(record.id, metadata);
        write(buildPath(sidecarRoot, record.id.text ~ documentMetadataPublishSuffixV1), wire);
    }
    string[string] sidecarPathDecisions; // documentId -> representativeId
    runPruneNearDuplicates(sidecarRoot, (CorpusStageDecision decision) {
        sidecarPathDecisions[decision.documentId.text] = decision.representativeId.text;
    }, PruneOptions.init);

    assert(sidecarPathDecisions == shardPathDecisions,
        "sidecar-sourced and shard-sourced paths must reach the same pruning decisions");
}
