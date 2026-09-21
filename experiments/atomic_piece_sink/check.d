module atomic_piece_sink.check;

import content.pieces : Content, ContentPiece;
import core.memory : GC;
import domain.document : DocumentViewOwner;
import effects.atomic_piece_sink : writeAtomicPieces;
import effects.mapped_file : openMappedFile;
import std.file : SpanMode, dirEntries, exists, getAttributes, getSize, mkdir, read,
    rmdirRecurse, setAttributes, symlink, tempDir, write;
import std.path : buildPath;
import std.stdio : File, writeln;
import std.algorithm.searching : canFind, endsWith;
import std.uuid : randomUUID;

private void require(bool condition, string message) {
    if (!condition) throw new Exception(message);
}

private void noTemps(string directory) {
    foreach (entry; dirEntries(directory, SpanMode.shallow))
        if (entry.name.canFind(".scrubbed-") && entry.name.endsWith(".tmp"))
            throw new Exception("orphan atomic output temporary: " ~ entry.name);
}

private void expectedFailure(scope void delegate() operation) {
    bool failed;
    try operation();
    catch (Exception) failed = true;
    require(failed, "expected release-active failure");
}

private void smallChecks(string root) {
    auto path = buildPath(root, "output");
    write(path, "prior destination");
    auto mode = getAttributes(path);
    auto content = new Content([ContentPiece.own(cast(const(ubyte)[]) "abc"),
        ContentPiece.own(cast(const(ubyte)[]) "def")]);
    writeAtomicPieces(path, content.pieces(), null, 2);
    require(cast(const(ubyte)[]) read(path) == cast(const(ubyte)[]) "abcdef",
        "successful output bytes");
    require(getAttributes(path) == mode, "successful replacement mode");
    noTemps(root);

    write(path, "prior destination");
    setAttributes(path, mode);
    expectedFailure({
        writeAtomicPieces(path, content.pieces(), (ulong n) {
            if (n >= 2) throw new Exception("injected mid-stream write failure");
        }, 2);
    });
    require(cast(const(ubyte)[]) read(path) == cast(const(ubyte)[]) "prior destination",
        "fault retained prior bytes");
    require(getAttributes(path) == mode, "fault retained prior attributes");
    noTemps(root);

    expectedFailure({
        writeAtomicPieces(path, content.pieces(), (ulong n) {
            if (n == 6) throw new Exception("cancel immediately before commit");
        }, 2);
    });
    require(cast(const(ubyte)[]) read(path) == cast(const(ubyte)[]) "prior destination",
        "cancel retained prior bytes");
    require(getAttributes(path) == mode, "cancel retained prior attributes");
    noTemps(root);

    auto absent = buildPath(root, "absent");
    expectedFailure({
        writeAtomicPieces(absent, content.pieces(), (ulong n) {
            throw new Exception("injected failure without prior destination");
        }, 2);
    });
    require(!exists(absent), "failure published partial new destination");
    noTemps(root);

    auto owner = openMappedFile(path);
    auto borrowed = new Content([ContentPiece.borrow(owner.view(0, getSize(path)))]);
    // POSIX rename keeps the old mapped inode live until the sink finishes.
    writeAtomicPieces(path, borrowed.pieces(), null, 3);
    require(cast(const(ubyte)[]) read(path) == cast(const(ubyte)[]) "prior destination",
        "same-file mapped input/output");
    owner.close();
    expectedFailure({ writeAtomicPieces(path, borrowed.pieces()); });
    require(cast(const(ubyte)[]) read(path) == cast(const(ubyte)[]) "prior destination",
        "expired borrow retained destination");
    noTemps(root);
    auto emptyOwner = new DocumentViewOwner([cast(ubyte) 'x']);
    auto emptyBorrowed = new Content([
        ContentPiece.borrow(emptyOwner.view(0, 0))]);
    emptyOwner.close();
    expectedFailure({ writeAtomicPieces(path, emptyBorrowed.pieces()); });
    require(cast(const(ubyte)[]) read(path) == cast(const(ubyte)[]) "prior destination",
        "expired empty borrow retained destination");
    noTemps(root);
    auto link = buildPath(root, "output-link");
    symlink(path, link);
    expectedFailure({ writeAtomicPieces(link, content.pieces()); });
    require(cast(const(ubyte)[]) read(path) == cast(const(ubyte)[]) "prior destination",
        "symlink target retained destination");
    noTemps(root);
    expectedFailure({ writeAtomicPieces(path, content.pieces(), null, 0); });
}

private void largeCheck(string root, size_t repeats) {
    import core.sys.posix.sys.resource : getrusage, rusage, RUSAGE_SELF;
    import core.sys.posix.sys.stat : stat, stat_t;
    import std.digest.sha : SHA256;

    enum chunkBytes = 1024 * 1024;
    auto input = buildPath(root, "repeated-source");
    auto pattern = new ubyte[chunkBytes];
    foreach (i, ref byteValue; pattern) byteValue = cast(ubyte)((i * 37 + 11) & 255);
    write(input, pattern);
    auto owner = openMappedFile(input);
    auto piece = ContentPiece.borrow(owner.view(0, chunkBytes));
    ContentPiece[] descriptors;
    descriptors.length = repeats;
    descriptors[] = piece;
    auto content = new Content(descriptors);
    auto destination = buildPath(root, "large-output");
    auto beforeGC = GC.stats().usedSize;
    auto beforeAllocated = GC.allocatedInCurrentThread();
    size_t peakGC = beforeGC;
    writeAtomicPieces(destination, content.pieces(), (ulong n) {
        auto now = GC.stats().usedSize;
        if (now > peakGC) peakGC = now;
    });
    auto allocated = GC.allocatedInCurrentThread() - beforeAllocated;
    owner.close();
    auto expectedSize = cast(ulong) chunkBytes * repeats;
    require(getSize(destination) == expectedSize, "multi-GiB exact size");
    auto output = File(destination, "rb");
    ubyte[chunkBytes] buffer;
    SHA256 actual;
    foreach (i; 0 .. repeats) {
        auto got = output.rawRead(buffer[]);
        require(got.length == chunkBytes, "multi-GiB chunk boundary");
        require(got[0] == pattern[0] && got[$ - 1] == pattern[$ - 1],
            "multi-GiB boundary byte");
        actual.put(got);
    }
    require(output.rawRead(buffer[0 .. 1]).length == 0, "multi-GiB trailing byte");
    SHA256 expected;
    foreach (_; 0 .. repeats) expected.put(pattern);
    require(actual.finish() == expected.finish(), "multi-GiB SHA-256 mismatch");
    noTemps(root);
    rusage usage;
    require(getrusage(RUSAGE_SELF, &usage) == 0, "getrusage failed");
    version (OSX) auto peakRSS = cast(ulong) usage.ru_opaque[0];
    else version (linux) auto peakRSS = cast(ulong) usage.ru_maxrss * 1024;
    else static assert(0, "RSS measurement needs a platform implementation");
    stat_t info;
    require(stat(destination.toStringz, &info) == 0, "stat output failed");
    writeln("logical_bytes=", expectedSize, " physical_bytes=", info.st_blocks * 512,
        " peak_rss_bytes=", peakRSS, " gc_used_before=", beforeGC,
        " gc_used_peak=", peakGC, " gc_growth=", peakGC - beforeGC,
        " gc_allocated_during_sink=", allocated);
}

private import std.string : toStringz;

void main(string[] args) {
    require(args.length == 1 || (args.length == 3 && args[1] == "--large"),
        "usage: check [--large repeats]");
    auto root = buildPath(tempDir(), "atomic-piece-sink-" ~ randomUUID.toString);
    mkdir(root);
    scope (exit) rmdirRecurse(root);
    smallChecks(root);
    if (args.length == 3) {
        import std.conv : to;
        auto repeats = args[2].to!size_t;
        require(repeats > 0, "repeats must be positive");
        largeCheck(root, repeats);
    }
    writeln("atomic piece sink checks passed");
}
