/// Bounded local-file transport for the WARC/1.1 readers.
module effects.warc_file;

import effects.warc_reader : WarcError, WarcReader, WarcRecord, WarcVisit;
import effects.warc_compressed : Compression, CompressedWarcError,
    CompressedReason, WarcCompressedReader;
import core.sys.posix.fcntl : open, openat, O_RDONLY, O_NOFOLLOW, O_NONBLOCK;
import core.sys.posix.unistd : read, close;
import core.sys.posix.sys.stat : fstat, stat_t, S_ISREG;
import core.stdc.errno : errno, EINTR;
import std.string : indexOf, split, toStringz;

enum WarcFileFormat { plain, gzip, zstd }
enum WarcFilePhase { path, open, read, parser, cancel, callback }
enum size_t warcFileChunk = 16_384;
// Darwin's O_DIRECTORY in the macOS SDK; not exported by this Phobos fcntl.
private enum int directoryOnly = 0x00100000;

/// Completed callbacks are never rolled back, including on late errors.
final class WarcFileError : Exception {
    WarcFilePhase phase;
    size_t completed;
    Exception original;

    this(WarcFilePhase phase, size_t completed, string detail,
        Exception original = null) {
        super(detail);
        this.phase = phase;
        this.completed = completed;
        this.original = original;
    }
}

/// `root` is trusted; `relativePath` must be canonical, nonempty, and below it.
/// No snapshot is promised if another process mutates an opened regular file.
size_t readWarcFile(string root, string relativePath, WarcFileFormat format,
    string sourceKey, WarcVisit visit) {
    if (root.length == 0 || root.indexOf('\0') >= 0 ||
        relativePath.length == 0 || relativePath[0] == '/' ||
        relativePath.indexOf('\0') >= 0)
        throw new WarcFileError(WarcFilePhase.path, 0, "invalid input path");
    auto components = relativePath.split('/');
    foreach (component; components)
        if (component.length == 0 || component == "." || component == "..")
            throw new WarcFileError(WarcFilePhase.path, 0, "noncanonical input path");
    if (visit is null || (format != WarcFileFormat.plain &&
        format != WarcFileFormat.gzip && format != WarcFileFormat.zstd))
        throw new WarcFileError(WarcFilePhase.parser, 0,
            "callback and supported format required");

    int fd = open(root.toStringz, O_RDONLY | directoryOnly | O_NOFOLLOW);
    if (fd < 0) throw new WarcFileError(WarcFilePhase.open, 0, "cannot open input root");
    scope(exit) close(fd);
    foreach (i, component; components) {
        auto flags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK;
        if (i + 1 != components.length) flags |= directoryOnly;
        int next = openat(fd, component.toStringz, flags);
        if (next < 0)
            throw new WarcFileError(WarcFilePhase.open, 0, "cannot open input component");
        close(fd);
        fd = next;
    }
    stat_t info;
    if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode))
        throw new WarcFileError(WarcFilePhase.open, 0, "input is not a regular file");

    size_t completed;
    WarcFilePhase callbackFailure = WarcFilePhase.parser;
    Exception callbackError;
    auto wrapped = (WarcRecord record) {
        bool accepted;
        try accepted = visit(record);
        catch (Exception error) {
            callbackFailure = WarcFilePhase.callback;
            callbackError = error;
            throw error;
        }
        if (!accepted) callbackFailure = WarcFilePhase.cancel;
        else ++completed;
        return accepted;
    };
    WarcReader plain;
    WarcCompressedReader compressed;
    try {
        final switch (format) {
            case WarcFileFormat.plain:
                plain = new WarcReader(sourceKey, wrapped);
                break;
            case WarcFileFormat.gzip:
                compressed = new WarcCompressedReader(Compression.gzip, sourceKey, wrapped);
                break;
            case WarcFileFormat.zstd:
                compressed = new WarcCompressedReader(Compression.zstd, sourceKey, wrapped);
                break;
        }
        scope(exit) if (compressed !is null) compressed.close();
        ubyte[warcFileChunk] buffer;
        while (true) {
            auto amount = read(fd, buffer.ptr, buffer.length);
            if (amount < 0) {
                if (errno == EINTR) continue;
                throw new WarcFileError(WarcFilePhase.read, completed, "input read failed");
            }
            if (amount == 0) break;
            if (plain !is null) plain.feed(buffer[0 .. amount]);
            else compressed.feed(buffer[0 .. amount]);
        }
        if (plain !is null) plain.finish();
        else compressed.finish();
        return completed;
    } catch (WarcFileError error) {
        if (callbackError !is null)
            throw new WarcFileError(WarcFilePhase.callback, completed,
                callbackError.msg, callbackError);
        throw error;
    } catch (Exception error) {
        auto phase = callbackFailure;
        if (phase == WarcFilePhase.parser &&
            ((cast(CompressedWarcError) error !is null &&
              (cast(CompressedWarcError) error).reason == CompressedReason.cancelled) ||
             (cast(WarcError) error !is null && error.msg == "callback cancelled")))
            phase = WarcFilePhase.cancel;
        throw new WarcFileError(phase, completed, error.msg,
            callbackError is null ? error : callbackError);
    }
}
