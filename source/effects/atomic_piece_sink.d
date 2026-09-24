/// POSIX, one-destination atomic output for checked content pieces.
module effects.atomic_piece_sink;

import content.pieces : Content;
import core.stdc.errno : errno, EINTR, ENOSPC, EDQUOT, EMFILE, ENFILE;
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

/// The sink observed a resource condition that makes continuing unsafe.
class ResourceExhaustion : Exception {
    int errorCode;
    this(string message, int errorCode) {
        super(message);
        this.errorCode = errorCode;
    }
}

private bool isResourceCode(int errorCode) {
    return errorCode == ENOSPC || errorCode == EDQUOT ||
        errorCode == EMFILE || errorCode == ENFILE;
}

private void failIo(string message, int errorCode) {
    if (isResourceCode(errorCode))
        throw new ResourceExhaustion(message, errorCode);
    throw new Exception(message);
}

version (FailurePolicyHarness) {
    private void injectedIoFault(string destination, string phase) {
        import core.stdc.errno : EACCES, EIO;
        import std.file : exists;
        struct Fault { string name; int code; }
        foreach (spec; [
                Fault("ENOSPC", ENOSPC), Fault("EDQUOT", EDQUOT),
                Fault("EMFILE", EMFILE), Fault("ENFILE", ENFILE),
                Fault("EACCES", EACCES), Fault("EIO", EIO)]) {
            if (exists(destination ~ ".fault-" ~ phase ~ "-" ~ spec.name))
                failIo("injected atomic output " ~ phase ~ " failure", spec.code);
        }
    }

    private void injectedPhobosFault(string destination, string phase) {
        import core.stdc.errno : EACCES, EIO;
        import std.file : exists;
        struct Fault { string name; int code; }
        foreach (spec; [
                Fault("ENOSPC", ENOSPC), Fault("EDQUOT", EDQUOT),
                Fault("EMFILE", EMFILE), Fault("ENFILE", ENFILE),
                Fault("EACCES", EACCES), Fault("EIO", EIO)]) {
            if (exists(destination ~ ".fault-" ~ phase ~ "-" ~ spec.name))
                throw new FileException(destination, cast(uint)spec.code);
        }
    }
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
    int openError;
    // O_EXCL makes random-name collisions harmless and never truncates another file.
    foreach (_; 0 .. 10) {
        temporary = buildPath(parent, "." ~ baseName(destination) ~
                ".scrubbed-" ~ randomUUID.toString ~ ".tmp");
        version (FailurePolicyHarness) injectedIoFault(destination, "open");
        fd = open(temporary.toStringz, O_WRONLY | O_CREAT | O_EXCL, 384);
        if (fd >= 0) break;
        openError = errno;
        if (isResourceCode(openError))
            failIo("cannot create atomic output temporary", openError);
    }
    if (fd < 0) failIo("cannot create atomic output temporary", openError);
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
            version (FailurePolicyHarness) injectedIoFault(destination, "write");
            auto result = write(fd, buffer.ptr + offset, filled - offset);
            if (result < 0) {
                const savedErrno = errno;
                if (savedErrno == EINTR) continue;
                failIo("atomic output write failed", savedErrno);
            }
            if (result == 0) failIo("atomic output write failed", 0);
            offset += cast(size_t) result;
        }
        total += filled;
        filled = 0;
        if (checkpoint !is null) checkpoint(total);
    }
    while (!pieces.empty) {
        auto piece = pieces.front; // Checks even a zero-length borrowed piece.
        auto pieceSize = piece.size;
        size_t copied;
        while (copied < pieceSize) {
            auto available = chunkSize - filled;
            auto remaining = pieceSize - copied;
            auto count = available < remaining ? available : remaining;
            piece.copyTo(copied, buffer[filled .. filled + count]);
            copied += count;
            filled += count;
            if (filled == chunkSize) drain();
        }
        pieces.popFront();
    }
    if (filled) drain();
    if (checkpoint !is null) checkpoint(total);
    version (FailurePolicyHarness) injectedIoFault(destination, "fsync");
    if (fsync(fd) != 0) {
        const savedErrno = errno;
        failIo("atomic output flush failed", savedErrno);
    }
    auto closing = fd;
    fd = -1;
    const closeResult = close(closing);
    const closeError = closeResult == 0 ? 0 : errno;
    if (closeResult != 0) {
        failIo("atomic output close failed", closeError);
    }
    version (FailurePolicyHarness) injectedIoFault(destination, "close");
    if (prior) {
        try {
            version (FailurePolicyHarness) injectedPhobosFault(destination, "setattrs");
            setAttributes(temporary, attributes);
        } catch (FileException error) {
            if (isResourceCode(cast(int)error.errno))
                throw new ResourceExhaustion("atomic output attributes failed",
                    cast(int)error.errno);
            throw error;
        }
    }
    try {
        version (FailurePolicyHarness) injectedPhobosFault(destination, "rename");
        rename(temporary, destination);
    } catch (FileException error) {
        if (isResourceCode(cast(int)error.errno))
            throw new ResourceExhaustion("atomic output rename failed",
                cast(int)error.errno);
        throw error;
    }
    committed = true;
}

private import std.string : toStringz;
