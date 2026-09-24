/// Bounded POSIX file adapters for binary-v1 immutable shards and overlays.
module effects.document_shards;

import core.stdc.errno : errno, EINTR, ENOENT;
import core.sys.posix.fcntl : open, O_CREAT, O_EXCL, O_NOFOLLOW, O_RDONLY, O_WRONLY;
import core.sys.posix.sys.stat : fstat, lstat, stat_t, S_ISREG;
import core.sys.posix.unistd : close, fsync, link, read, unlink, write;
import domain.shard_format;
import crypto.sha256 : Sha256, sha256Of;
import std.exception : enforce;
import std.file : isDir, isSymlink, rename;
import std.path : absolutePath, baseName, buildNormalizedPath, buildPath, dirName;
import std.string : toStringz;
import std.uuid : randomUUID;

private void require(bool okay, string reason) {
    enforce(okay, "document shards: " ~ reason);
}

private void writeAll(int fd, const(ubyte)[] bytes) {
    size_t offset;
    while (offset < bytes.length) {
        auto amount = write(fd, bytes.ptr + offset, bytes.length - offset);
        if (amount < 0 && errno == EINTR) continue;
        require(amount > 0, "write failed");
        offset += cast(size_t)amount;
    }
}

private size_t readSome(int fd, ubyte[] bytes) {
    while (true) {
        auto amount = read(fd, bytes.ptr, bytes.length);
        if (amount < 0 && errno == EINTR) continue;
        require(amount >= 0, "read failed");
        return cast(size_t)amount;
    }
}

private bool readExact(int fd, ubyte[] bytes, bool boundary = false,
        size_t chunkSize = 64 * 1024) {
    require(chunkSize != 0, "zero read chunk size");
    size_t offset;
    while (offset < bytes.length) {
        auto take = bytes.length - offset < chunkSize ? bytes.length - offset : chunkSize;
        auto amount = readSome(fd, bytes[offset .. offset + take]);
        if (amount == 0) {
            if (boundary && offset == 0) return false;
            throw new Exception("document shards: truncated file");
        }
        offset += amount;
    }
    return true;
}

private uint readLength(ubyte[4] bytes) {
    return (cast(uint)bytes[0] << 24) | (cast(uint)bytes[1] << 16) |
        (cast(uint)bytes[2] << 8) | bytes[3];
}

private bool readFrame(int fd, uint limit, out ubyte[] payload, size_t chunkSize) {
    ubyte[4] width;
    if (!readExact(fd, width[], true, chunkSize)) return false;
    auto length = readLength(width);
    require(length <= limit, "oversized frame");
    payload = new ubyte[length];
    readExact(fd, payload, false, chunkSize);
    ubyte[32] recorded;
    readExact(fd, recorded[], false, chunkSize);
    require(sha256Of(payload) == recorded, "frame digest mismatch");
    return true;
}

private ubyte[32] digestDescriptor(int fd) {
    stat_t info;
    require(fstat(fd, &info) == 0 && S_ISREG(info.st_mode), "shard is not regular");
    auto digest = Sha256.create;
    ubyte[64 * 1024] buffer;
    while (true) {
        auto size = readSome(fd, buffer[]);
        if (!size) break;
        digest.put(buffer[0 .. size]);
    }
    return digest.finish();
}

ubyte[32] shardDigest(string path) {
    auto fd = open(path.toStringz, O_RDONLY | O_NOFOLLOW);
    require(fd >= 0, "cannot open regular shard");
    scope(exit) close(fd);
    return digestDescriptor(fd);
}

/// One frame at a time; EOF is legal only between complete frames.
final class DocumentShardReader {
    private int fd = -1;
    private string previous;
    private bool ended;
    private size_t chunkSize;
    this(string path, size_t chunkSize = 64 * 1024) {
        require(chunkSize != 0, "zero read chunk size");
        this.chunkSize = chunkSize;
        fd = open(path.toStringz, O_RDONLY | O_NOFOLLOW);
        require(fd >= 0, "cannot open document shard");
        try {
            stat_t info;
            require(fstat(fd, &info) == 0 && S_ISREG(info.st_mode), "nonregular document shard");
            ubyte[8] magic;
            readExact(fd, magic[], false, chunkSize);
            require(magic[] == documentMagic, "unsupported document shard magic");
        } catch (Throwable error) { closeReader(); throw error; }
    }
    void closeReader() { if (fd >= 0) { close(fd); fd = -1; } }
    ~this() { closeReader(); }
    bool next(out ShardDocument record) {
        require(fd >= 0, "document reader closed");
        if (ended) return false;
        ubyte[] bytes;
        if (!readFrame(fd, maxDocumentPayload, bytes, chunkSize)) { ended = true; return false; }
        record = decodeDocument(bytes);
        auto id = record.id.text;
        require(previous.length == 0 || previous < id, "document IDs not strictly sorted");
        previous = id;
        return true;
    }
}

/// Header validation precedes every record yield.
final class OverlayReader {
    private int fd = -1;
    private string previous;
    private bool ended;
    private size_t chunkSize;
    OverlayHeader header;
    this(string path, size_t chunkSize = 64 * 1024) {
        require(chunkSize != 0, "zero read chunk size");
        this.chunkSize = chunkSize;
        fd = open(path.toStringz, O_RDONLY | O_NOFOLLOW);
        require(fd >= 0, "cannot open overlay");
        try {
            stat_t info;
            require(fstat(fd, &info) == 0 && S_ISREG(info.st_mode), "nonregular overlay");
            ubyte[10] prefix;
            readExact(fd, prefix[], false, chunkSize);
            auto length = (cast(size_t)prefix[8] << 8) | prefix[9];
            require(length <= maxOverlayMetadata, "oversized overlay header");
            auto bytes = new ubyte[10 + length + 32];
            bytes[0 .. 10] = prefix[];
            readExact(fd, bytes[10 .. $], false, chunkSize);
            header = decodeOverlayHeader(bytes);
        } catch (Throwable error) { closeReader(); throw error; }
    }
    void closeReader() { if (fd >= 0) { close(fd); fd = -1; } }
    ~this() { closeReader(); }
    bool next(out AnnotationRecord record) {
        require(fd >= 0, "overlay reader closed");
        if (ended) return false;
        ubyte[] bytes;
        if (!readFrame(fd, maxAnnotationPayload, bytes, chunkSize)) { ended = true; return false; }
        record = decodeAnnotation(bytes);
        require(previous.length == 0 || previous < record.documentId,
            "overlay IDs not strictly sorted");
        previous = record.documentId;
        return true;
    }
}

enum PublishStep { afterWrite, afterFsync, beforePublish }
alias PublishFault = void delegate(PublishStep);

private final class TemporaryFile {
    string destination;
    string temporary;
    private string temporaryZ;
    int fd = -1;
    this(string destination) {
        this.destination = buildNormalizedPath(absolutePath(destination));
        auto parent = dirName(this.destination);
        require(isDir(parent) && !isSymlink(parent), "unsafe parent directory");
        foreach (_; 0 .. 10) {
            temporary = buildPath(parent, "." ~ baseName(this.destination) ~
                ".scrubbed-" ~ randomUUID.toString ~ ".tmp");
            temporaryZ = temporary ~ "\0";
            fd = open(temporaryZ.ptr, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 384);
            if (fd >= 0) break;
        }
        require(fd >= 0, "cannot create temporary file");
    }
    void put(const(ubyte)[] bytes) { require(fd >= 0, "writer closed"); writeAll(fd, bytes); }
    void syncClose(PublishFault fault) {
        require(fd >= 0, "writer closed");
        if (fault !is null) fault(PublishStep.afterWrite);
        require(fsync(fd) == 0, "temporary fsync failed");
        if (fault !is null) fault(PublishStep.afterFsync);
        auto old = fd;
        fd = -1;
        require(close(old) == 0, "temporary close failed");
        if (fault !is null) fault(PublishStep.beforePublish);
    }
    void discard() {
        if (fd >= 0) { close(fd); fd = -1; }
        if (temporaryZ.length) {
            unlink(temporaryZ.ptr);
            temporaryZ = null;
            temporary = null;
        }
    }
    ~this() { discard(); }
}

/// The hard-link publication is atomic create-only on this POSIX filesystem.
/// A losing writer never replaces the winner's inode or bytes.
final class DocumentShardWriter {
    private TemporaryFile file;
    private string previous;
    private bool published;
    this(string destination) {
        file = new TemporaryFile(destination);
        try file.put(documentMagic);
        catch (Throwable error) { file.discard(); throw error; }
    }
    void append(ShardDocument record) {
        scope(failure) file.discard();
        require(!published, "writer already published");
        auto id = record.id.text;
        require(previous.length == 0 || previous < id, "document IDs not strictly sorted");
        file.put(frame(encodeDocument(record), maxDocumentPayload));
        previous = id;
    }
    void publish(PublishFault fault = null) {
        scope(failure) file.discard();
        require(!published, "writer already published");
        file.syncClose(fault);
        require(link(file.temporaryZ.ptr, file.destination.toStringz) == 0,
            "immutable shard already exists or link failed");
        published = true;
        file.discard();
    }
    void abort() { file.discard(); }
}

private void checkReplaceTarget(string destination, int sourceFd) {
    stat_t observed;
    if (lstat(destination.toStringz, &observed) != 0) {
        require(errno == ENOENT, "cannot inspect overlay target");
        return;
    }
    require(S_ISREG(observed.st_mode) && observed.st_nlink == 1,
        "overlay target is nonregular or hardlinked");
    auto fd = open(destination.toStringz, O_RDONLY | O_NOFOLLOW);
    require(fd >= 0, "overlay target changed during inspection");
    scope(exit) close(fd);
    stat_t info;
    require(fstat(fd, &info) == 0 && S_ISREG(info.st_mode) && info.st_nlink == 1 &&
        info.st_dev == observed.st_dev && info.st_ino == observed.st_ino,
        "overlay target is nonregular or hardlinked");
    stat_t sourceInfo;
    require(fstat(sourceFd, &sourceInfo) == 0 && S_ISREG(sourceInfo.st_mode),
        "source shard changed while publishing overlay");
    require(info.st_dev != sourceInfo.st_dev || info.st_ino != sourceInfo.st_ino,
        "overlay destination aliases immutable source shard");
}

final class OverlayWriter {
    private TemporaryFile file;
    private string sourcePath;
    private string previous;
    private bool published;
    private int sourceFd = -1;
    this(string destination, string documentPath, string analyzerKey,
            string analyzerVersion) {
        sourcePath = buildNormalizedPath(absolutePath(documentPath));
        sourceFd = open(documentPath.toStringz, O_RDONLY | O_NOFOLLOW);
        require(sourceFd >= 0, "cannot open source shard read-only");
        try {
            auto digest = digestDescriptor(sourceFd);
            file = new TemporaryFile(destination);
            file.put(encodeOverlayHeader(
                OverlayHeader(analyzerKey, analyzerVersion, digest)));
        } catch (Throwable error) { abort(); throw error; }
    }
    void append(AnnotationRecord record) {
        scope(failure) abort();
        require(!published, "writer already published");
        require(previous.length == 0 || previous < record.documentId,
            "overlay IDs not strictly sorted");
        file.put(frame(encodeAnnotation(record), maxAnnotationPayload));
        previous = record.documentId;
    }
    void publish(PublishFault fault = null) {
        scope(failure) abort();
        require(!published, "writer already published");
        file.syncClose(fault);
        require(buildNormalizedPath(absolutePath(file.destination)) != sourcePath,
            "overlay destination is the immutable source shard path");
        checkReplaceTarget(file.destination, sourceFd);
        rename(file.temporary, file.destination);
        file.temporary = null;
        file.temporaryZ = null;
        published = true;
        closeSource();
    }
    private void closeSource() {
        if (sourceFd >= 0) { close(sourceFd); sourceFd = -1; }
    }
    void abort() {
        if (file !is null) file.discard();
        closeSource();
    }
    ~this() { closeSource(); }
}

struct JoinedOverlay {
    string analyzerKey;
    string analyzerVersion;
    bool present;
    AnnotationField[] fields;
}

/// Bounded one-record lookahead per overlay. Caller owns returned records only
/// until its visit callback returns. Any orphan or stale revision is fatal.
void joinShards(string documentPath, const(string)[] overlayPaths,
        scope void delegate(ShardDocument, JoinedOverlay[]) visit) {
    require(overlayPaths.length <= maxOverlayFanIn, "too many overlays");
    auto sourceDigest = shardDigest(documentPath);
    auto documents = new DocumentShardReader(documentPath);
    scope(exit) documents.closeReader();
    OverlayReader[] overlays;
    scope(exit) foreach (reader; overlays) reader.closeReader();
    AnnotationRecord[] heads;
    bool[] hasHead;
    foreach (path; overlayPaths) {
        auto reader = new OverlayReader(path);
        overlays ~= reader;
        require(reader.header.sourceShardDigest == sourceDigest, "wrong source-shard digest");
        foreach (other; overlays[0 .. $ - 1])
            require(other.header.analyzerKey != reader.header.analyzerKey,
                "duplicate analyzer key or conflicting version");
        AnnotationRecord first;
        hasHead ~= reader.next(first);
        heads ~= first;
    }
    ShardDocument document;
    while (documents.next(document)) {
        JoinedOverlay[] joined;
        foreach (index, reader; overlays) {
            auto head = heads[index];
            require(!hasHead[index] || head.documentId >= document.id.text,
                "orphan overlay document ID");
            JoinedOverlay entry;
            entry.analyzerKey = reader.header.analyzerKey;
            entry.analyzerVersion = reader.header.analyzerVersion;
            if (hasHead[index] && head.documentId == document.id.text) {
                require(head.contentDigest == document.contentDigest,
                    "stale source content revision");
                entry.present = true;
                entry.fields = head.fields;
                hasHead[index] = reader.next(heads[index]);
            }
            joined ~= entry;
        }
        visit(document, joined);
    }
    foreach (present; hasHead) require(!present, "orphan overlay document ID");
}
