/// POSIX, one-destination atomic output for checked content pieces.
module effects.atomic_piece_sink;

import content.pieces : Content;
import core.stdc.errno : errno, EINTR;
import core.sys.posix.fcntl : open, O_CREAT, O_EXCL, O_WRONLY;
import core.sys.posix.unistd : close, fsync, write;
import std.file : FileException, exists, getAttributes, isDir, isFile, isSymlink,
    remove, rename, setAttributes;
import std.path : baseName, buildPath, dirName;
import std.uuid : randomUUID;

/// Existing destination-policy guards failed. Callers decide run severity.
class OutputPolicyViolation : Exception {
    this(string message) { super(message); }
}

/// The checkpoint runs after each complete buffer and once immediately before
/// commit. It may throw to cancel or inject a fault. Pieces and their borrowed
/// owners must stay live until this function returns. No full-output join occurs.
/// The destination's existing POSIX mode is retained when replacing it.
void writeAtomicPieces(string destination, Content.PieceRange pieces,
        scope void delegate(ulong) checkpoint = null, size_t chunkSize = 64 * 1024) {
    if (!chunkSize) throw new Exception("atomic output chunk size must be positive");
    auto parent = dirName(destination);
    if (!isDir(parent))
        throw new OutputPolicyViolation("atomic output parent is not a directory");
    bool symlink;
    try symlink = isSymlink(destination);
    catch (FileException error) {
        if (exists(destination)) throw error;
    }
    if (symlink)
        throw new OutputPolicyViolation("refusing to replace output symlink");
    bool prior = exists(destination);
    uint attributes;
    if (prior) {
        if (!isFile(destination))
            throw new OutputPolicyViolation("refusing to replace non-regular destination");
        attributes = getAttributes(destination);
    }

    string temporary;
    int fd = -1;
    // O_EXCL makes random-name collisions harmless and never truncates another file.
    foreach (_; 0 .. 10) {
        temporary = buildPath(parent, "." ~ baseName(destination) ~
                ".scrubbed-" ~ randomUUID.toString ~ ".tmp");
        fd = open(temporary.toStringz, O_WRONLY | O_CREAT | O_EXCL, 384);
        if (fd >= 0) break;
    }
    if (fd < 0) throw new Exception("cannot create atomic output temporary");
    bool committed;
    scope (exit) {
        if (fd >= 0) close(fd);
        if (!committed && exists(temporary)) remove(temporary);
    }

    auto buffer = new ubyte[chunkSize];
    size_t filled;
    ulong total;
    void drain() {
        size_t offset;
        while (offset < filled) {
            auto result = write(fd, buffer.ptr + offset, filled - offset);
            if (result < 0 && errno == EINTR) continue;
            if (result <= 0) throw new Exception("atomic output write failed");
            offset += cast(size_t) result;
        }
        total += filled;
        filled = 0;
        if (checkpoint !is null) checkpoint(total);
    }
    while (!pieces.empty) {
        auto piece = pieces.front; // Checks even a zero-length borrowed piece.
        foreach (index; 0 .. piece.size) {
            buffer[filled++] = piece.at(index);
            if (filled == chunkSize) drain();
        }
        pieces.popFront();
    }
    if (filled) drain();
    if (checkpoint !is null) checkpoint(total);
    if (fsync(fd) != 0) throw new Exception("atomic output flush failed");
    auto closing = fd;
    fd = -1;
    if (close(closing) != 0) throw new Exception("atomic output close failed");
    if (prior) setAttributes(temporary, attributes);
    rename(temporary, destination);
    committed = true;
}

private import std.string : toStringz;
