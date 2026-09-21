// Release-active production-boundary checks; all fixture bytes are made in D.
import effects.warc_compressed;
import effects.warc_reader;
import core.memory : GC;
import core.sys.posix.dlfcn : dlopen, dlsym, dlclose, RTLD_NOW, RTLD_FIRST;
import core.sys.posix.sys.resource : getrusage, rusage, RUSAGE_SELF;
import etc.c.zlib : z_stream,
    Z_OK, Z_STREAM_END, Z_FINISH, Z_DEFLATED, Z_DEFAULT_STRATEGY;
import std.conv : to;
import std.digest.sha : sha256Of, toHexString;
import std.file : dirEntries, SpanMode;
import std.stdio : writeln;

extern(C) @nogc nothrow ulong ZSTD_XXH64(const(void)* data, size_t length, ulong seed);

void need(bool okay, string detail) {
    if (!okay) throw new Exception(detail);
}

size_t fdCount() {
    size_t count;
    foreach (_; dirEntries("/dev/fd", SpanMode.shallow)) ++count;
    return count;
}

ubyte[] record(string id, string kind, const(ubyte)[] block, string extra = "") {
    auto header = "WARC/1.1\r\nWARC-Type: " ~ kind ~
        "\r\nWARC-Record-ID: <urn:uuid:" ~ id ~ ">\r\n" ~
        "WARC-Target-URI: https://example.org/a\r\n" ~
        "WARC-Date: 2026-09-21T00:00:00Z\r\n" ~ extra ~
        "Content-Length: " ~ block.length.to!string ~ "\r\n\r\n";
    return (cast(ubyte[]) header.dup ~ block ~ cast(ubyte[]) "\r\n\r\n").dup;
}

ubyte[] gzipFrame(const(ubyte)[] plain) {
    alias DeflateInit2 = extern(C) int function(z_stream*, int, int, int, int,
        int, const(char)*, int);
    alias Deflate = extern(C) int function(z_stream*, int);
    alias DeflateEnd = extern(C) int function(z_stream*);
    alias ZlibVersion = extern(C) const(char)* function();
    auto library = dlopen("/usr/lib/libz.1.dylib", RTLD_NOW | RTLD_FIRST);
    need(library !is null, "system gzip fixture encoder unavailable");
    scope(exit) dlclose(library);
    auto init = cast(DeflateInit2) dlsym(library, "deflateInit2_");
    auto encode = cast(Deflate) dlsym(library, "deflate");
    auto end = cast(DeflateEnd) dlsym(library, "deflateEnd");
    auto runtimeVersion = cast(ZlibVersion) dlsym(library, "zlibVersion");
    need(init !is null && encode !is null && end !is null && runtimeVersion !is null,
        "system gzip fixture encoder ABI unavailable");
    z_stream stream;
    need(init(&stream, 6, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY,
        runtimeVersion(), cast(int) z_stream.sizeof) == Z_OK,
        "gzip encoder init");
    scope(exit) end(&stream);
    auto buffer = new ubyte[plain.length + 1024];
    stream.next_in = plain.ptr;
    stream.avail_in = cast(uint) plain.length;
    stream.next_out = buffer.ptr;
    stream.avail_out = cast(uint) buffer.length;
    need(encode(&stream, Z_FINISH) == Z_STREAM_END, "gzip fixture encode");
    return buffer[0 .. buffer.length - stream.avail_out].dup;
}

ubyte[] zstdFrame(const(ubyte)[] plain) {
    need(plain.length <= 131072, "raw zstd block fixture cap");
    ubyte[] result = [0x28, 0xB5, 0x2F, 0xFD];
    if (plain.length <= 255) {
        result ~= 0x24; // single segment, one-byte size, checksum present
        result ~= cast(ubyte) plain.length;
    } else if (plain.length <= 65791) {
        result ~= 0x64; // single segment, two-byte size biased by 256
        auto size = plain.length - 256;
        result ~= [cast(ubyte) size, cast(ubyte)(size >> 8)];
    } else {
        result ~= 0xA4; // single segment, four-byte size
        foreach (shift; [0, 8, 16, 24]) result ~= cast(ubyte)(plain.length >> shift);
    }
    auto block = cast(uint)((plain.length << 3) | 1); // last raw block
    foreach (shift; [0, 8, 16]) result ~= cast(ubyte)(block >> shift);
    result ~= plain;
    auto checksum = cast(uint) ZSTD_XXH64(plain.ptr, plain.length, 0);
    foreach (shift; [0, 8, 16, 24]) result ~= cast(ubyte)(checksum >> shift);
    return result;
}

string fingerprint(WarcRecord value) {
    auto result = value.sourceKey ~ "|" ~ value.ordinal.to!string ~ "|" ~
        value.recordId ~ "|" ~ value.date ~ "|" ~ value.type ~ "|" ~
        value.targetUri ~ "|" ~ value.contentType ~ "|" ~
        toHexString(sha256Of(value.block)).idup;
    foreach (field; value.fields)
        result ~= "|" ~ field.name ~ ":" ~ field.value;
    return result;
}

string[] plainOutput(const(ubyte)[] archive) {
    string[] result;
    auto reader = new WarcReader("source-key", (WarcRecord r) {
        result ~= fingerprint(r); return true;
    });
    reader.feed(archive);
    reader.finish();
    return result;
}

string[] compressedOutput(Compression format, const(ubyte)[] archive, size_t chunk) {
    string[] result;
    auto reader = new WarcCompressedReader(format, "source-key", (WarcRecord r) {
        if (r.isConversionText()) need(r.conversionText() == "caf\xc3\xa9\n", "WET text view");
        result ~= fingerprint(r); return true;
    });
    for (size_t at; at < archive.length; at += chunk) {
        auto end = at + chunk < archive.length ? at + chunk : archive.length;
        reader.feed(archive[at .. end]);
    }
    reader.finish();
    return result;
}

void rejects(Compression format, const(ubyte)[] archive, CompressedReason reason,
    size_t expectedEmitted = 0, bool finish = true) {
    size_t emitted;
    auto reader = new WarcCompressedReader(format, "source-key", (WarcRecord r) {
        ++emitted; return true;
    });
    bool failed;
    try {
        reader.feed(archive);
        if (finish) reader.finish();
    } catch (CompressedWarcError error) {
        need(error.reason == reason,
            "wrong rejection reason for " ~ format.to!string ~ " size " ~
            archive.length.to!string ~ ": " ~ error.reason.to!string ~ " vs " ~
            reason.to!string);
        failed = true;
    }
    need(failed && emitted == expectedEmitted, "rejection/publication boundary");
    bool poisoned;
    try reader.feed([]);
    catch (CompressedWarcError error) { poisoned = error.reason == CompressedReason.stopped; }
    need(poisoned, "failure did not poison reader");
}

void main(string[] args) {
    auto systemDecoder = new WarcCompressedReader(Compression.gzip, "source-key",
        (WarcRecord r) => true);
    auto systemVersion = systemDecoder.systemZlibVersion();
    auto systemImage = systemDecoder.systemZlibImage();
    writeln("observed system zlib: ", systemVersion, " from ", systemImage);
    need(systemVersion.length != 0 && systemImage == "/usr/lib/libz.1.dylib",
        "wrong dynamic system zlib identity");
    systemDecoder.close();
    auto response = record("one", "response", cast(const(ubyte)[]) "HTTP/1.1 200 OK\r\n\r\nhi",
        "Content-Type: application/http\r\n");
    if (args.length > 1 && args[1] == "--negative-control") {
        auto corrupt = gzipFrame(response);
        corrupt[$ - 1] ^= 1;
        auto decoder = new WarcCompressedReader(Compression.gzip, "source-key",
            (WarcRecord r) => true);
        decoder.feed(corrupt); // must throw under -release
        decoder.finish();
        throw new Exception("negative control unexpectedly returned");
    }
    auto wet = record("two", "conversion", cast(const(ubyte)[]) "caf\xc3\xa9\n",
        "Content-Type: text/plain\r\n");
    auto plain = response ~ wet;
    auto expected = plainOutput(plain);
    foreach (format; [Compression.gzip, Compression.zstd]) {
        auto first = format == Compression.gzip ? gzipFrame(response) : zstdFrame(response);
        auto second = format == Compression.gzip ? gzipFrame(wet) : zstdFrame(wet);
        auto archive = first ~ second;
        foreach (chunk; [cast(size_t) 1, 127, 16_384, archive.length])
            need(compressedOutput(format, archive, chunk) == expected,
                "chunk/identity/hash mismatch for " ~ format.to!string);
        auto corrupt = archive.dup;
        corrupt[$ - 1] ^= 1; // late checksum in second member/frame
        rejects(format, corrupt, CompressedReason.checksum, 1);
        auto corruptFirst = first.dup;
        corruptFirst[$ - 1] ^= 1;
        rejects(format, corruptFirst, CompressedReason.checksum);
        rejects(format, first[0 .. $ - 1], CompressedReason.truncated);
        rejects(format, first[0 .. 2], CompressedReason.truncated);
        rejects(format, first ~ cast(ubyte[]) "garbagegarbagegarbage",
            CompressedReason.unsupported, 1);
        auto twoRecords = format == Compression.gzip ? gzipFrame(plain) : zstdFrame(plain);
        rejects(format, twoRecords, CompressedReason.invalidWarc);
        auto emptyMember = format == Compression.gzip ? gzipFrame([]) : zstdFrame([]);
        rejects(format, first ~ emptyMember, CompressedReason.invalidWarc, 1);
        rejects(format, [], CompressedReason.empty);
        auto largeBlock = new ubyte[65537];
        uint random = 17;
        foreach (ref b; largeBlock) {
            random ^= random << 13;
            random ^= random >> 17;
            random ^= random << 5;
            b = cast(ubyte) random;
        }
        auto tooLargeWarc = record("large", "response", largeBlock);
        rejects(format, format == Compression.gzip ? gzipFrame(tooLargeWarc) :
            zstdFrame(tooLargeWarc), CompressedReason.invalidWarc);
        WarcCompressedReader reentrant;
        bool sawReentrant, sawReentrantClose;
        reentrant = new WarcCompressedReader(format, "source-key", (WarcRecord r) {
            try reentrant.feed([]);
            catch (CompressedWarcError error) {
                sawReentrant = error.reason == CompressedReason.reentrant;
            }
            try reentrant.close();
            catch (CompressedWarcError error) {
                sawReentrantClose = error.reason == CompressedReason.reentrant;
            }
            return true;
        });
        reentrant.feed(first);
        reentrant.finish();
        need(sawReentrant && sawReentrantClose && reentrant.completedRecords == 1,
            "callback reentrancy duplicated or escaped");
        WarcRecord retained;
        auto ownedInput = first.dup;
        auto ownership = new WarcCompressedReader(format, "source-key", (WarcRecord r) {
            retained = r; return true;
        });
        ownership.feed(ownedInput);
        ownership.finish();
        ownedInput[] = 0;
        need(retained.sourceKey == "source-key" &&
            retained.recordId == "<urn:uuid:one>" &&
            retained.block == cast(ubyte[]) "HTTP/1.1 200 OK\r\n\r\nhi",
            "retained record aliases compressed input or released native state");
        auto throwing = new WarcCompressedReader(format, "source-key", (WarcRecord r) {
            throw new Exception("callback failure");
            return false;
        });
        bool propagated;
        try throwing.feed(first);
        catch (Exception error) { propagated = error.msg == "callback failure"; }
        need(propagated, "callback exception lost");
        bool stopped;
        try throwing.feed([]);
        catch (CompressedWarcError error) { stopped = error.reason == CompressedReason.stopped; }
        need(stopped, "callback exception did not poison adapter");
    }
    auto noChecksum = zstdFrame(response);
    noChecksum[4] &= ~cast(ubyte) 4;
    rejects(Compression.zstd, noChecksum, CompressedReason.unsupported);
    auto unknownSize = zstdFrame(response);
    unknownSize[4] = 0x04;
    rejects(Compression.zstd, unknownSize, CompressedReason.unsupported);
    rejects(Compression.zstd, cast(ubyte[]) [0x50, 0x2A, 0x4D, 0x18, 0, 0, 0, 0],
        CompressedReason.unsupported);
    ubyte[] tooLargeDeclared = [0x28, 0xB5, 0x2F, 0xFD, 0xA4, 1, 0, 2, 0];
    rejects(Compression.zstd, tooLargeDeclared, CompressedReason.overCap);
    auto dictionary = zstdFrame(response);
    dictionary[4] |= 1; // one-byte dictionary ID flag
    dictionary = dictionary[0 .. 6] ~ cast(ubyte[]) [1] ~ dictionary[6 .. $];
    rejects(Compression.zstd, dictionary, CompressedReason.unsupported);
    auto bigWindow = zstdFrame(response);
    auto contentSize = cast(uint) response.length;
    ubyte[] windowed = [0x28, 0xB5, 0x2F, 0xFD, 0x84, 0x40];
    foreach (shift; [0, 8, 16, 24]) windowed ~= cast(ubyte)(contentSize >> shift);
    windowed ~= bigWindow[6 .. $];
    rejects(Compression.zstd, windowed, CompressedReason.overCap);
    auto excessiveFrame = bigWindow[0 .. 6].dup;
    foreach (_; 0 .. compressedMemberLimit / 3 + 1)
        excessiveFrame ~= cast(ubyte[]) [0, 0, 0]; // nonlast empty raw blocks
    excessiveFrame ~= bigWindow[6 .. $];
    rejects(Compression.zstd, excessiveFrame, CompressedReason.overCap);
    auto hugeGzipHeader = gzipFrame(response);
    hugeGzipHeader[3] |= 8; // optional NUL-terminated FNAME
    auto name = new ubyte[compressedMemberLimit];
    name[] = 'n';
    hugeGzipHeader = hugeGzipHeader[0 .. 10] ~ name ~ cast(ubyte[]) [0] ~
        hugeGzipHeader[10 .. $];
    rejects(Compression.gzip, hugeGzipHeader, CompressedReason.overCap);
    auto oversize = record("large", "response", new ubyte[65537]);
    rejects(Compression.gzip, gzipFrame(oversize), CompressedReason.ratio);
    auto invalidWarc = gzipFrame(cast(ubyte[]) "not WARC\r\n\r\n");
    rejects(Compression.gzip, invalidWarc, CompressedReason.invalidWarc);
    auto trailing = gzipFrame(response);
    trailing ~= 0;
    rejects(Compression.gzip, trailing, CompressedReason.truncated, 1);
    size_t cancelled;
    auto cancel = new WarcCompressedReader(Compression.gzip, "source-key", (WarcRecord r) {
        ++cancelled; return false;
    });
    bool didCancel;
    try cancel.feed(gzipFrame(response));
    catch (CompressedWarcError error) { didCancel = error.reason == CompressedReason.cancelled; }
    need(didCancel && cancelled == 1, "callback cancellation");
    auto gzipOne = gzipFrame(response);
    auto zstdOne = zstdFrame(response);
    GC.collect();
    auto usedBefore = GC.stats.usedSize;
    auto fdsBefore = fdCount();
    foreach (_; 0 .. 200) {
        foreach (format; [Compression.gzip, Compression.zstd]) {
            auto frame = format == Compression.gzip ? gzipOne : zstdOne;
            auto decoder = new WarcCompressedReader(format, "source-key",
                (WarcRecord r) => true);
            decoder.feed(frame);
            decoder.finish();
        }
    }
    GC.collect();
    auto usedAfter = GC.stats.usedSize;
    auto fdsAfter = fdCount();
    need(fdsAfter <= fdsBefore + 1, "file descriptor growth across 400 decoders");
    need(usedAfter <= usedBefore + 1_048_576, "retained GC growth across 400 decoders");
    rusage usage;
    need(getrusage(RUSAGE_SELF, &usage) == 0, "getrusage failed");
    // Darwin's Phobos rusage exposes ru_maxrss as ru_opaque[0].
    writeln("resource process high-water RSS bytes=", usage.ru_opaque[0],
        " GC before/after=", usedBefore, "/", usedAfter,
        " FDs before/after=", fdsBefore, "/", fdsAfter);
    writeln("compressed adapter release checks passed; system zlib ", systemVersion);
}
