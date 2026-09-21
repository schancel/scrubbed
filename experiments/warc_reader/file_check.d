// Release-active, on-disk checks for the local-file WARC transport.
import effects.warc_file;
import effects.warc_reader;
import effects.warc_compressed;
import core.memory : GC;
import core.sys.posix.sys.resource : getrusage, rusage, RUSAGE_SELF;
import core.sys.posix.dlfcn : dlopen, dlsym, dlclose, RTLD_NOW, RTLD_FIRST;
import core.sys.posix.unistd : symlink;
import core.sys.posix.sys.stat : mkfifo;
import etc.c.zlib : z_stream, Z_OK, Z_STREAM_END, Z_FINISH,
    Z_DEFLATED, Z_DEFAULT_STRATEGY;
import std.conv : to;
import std.algorithm.searching : canFind;
import std.array : join;
import std.base64 : Base64;
import std.file : mkdir, remove, rmdir, write, getSize, dirEntries, SpanMode;
import std.path : buildPath;
import std.range : repeat;
import std.stdio : File, writeln;
import std.string : toStringz;
import std.uuid : randomUUID;

extern(C) @nogc nothrow ulong ZSTD_XXH64(const(void)*, size_t, ulong);

void need(bool ok, string why) { if (!ok) throw new Exception(why); }

ubyte[] record(string id, string kind, const(ubyte)[] block, string extra = "") {
    auto text = "WARC/1.1\r\nWARC-Type: " ~ kind ~
        "\r\nWARC-Record-ID: <urn:uuid:" ~ id ~ ">\r\n" ~
        "WARC-Target-URI: https://example.org/a\r\n" ~
        "WARC-Date: 2026-09-21T00:00:00Z\r\n" ~
        extra ~
        "Content-Length: " ~ block.length.to!string ~ "\r\n\r\n";
    return (cast(ubyte[]) text.dup ~ block ~ cast(ubyte[]) "\r\n\r\n").dup;
}

// Official zstd v1.5.7 --check --content-size goldens, produced by the
// companion compressed_check.d from D-authored WARC fixtures. Both use
// compressed (not raw) zstd blocks and are verified there against SHA-256.
enum responseCompressedGolden =
    "KLUv/STXFQUAMgoiHWCJHqiWttu9RM/Pt2H3q1HL39VQ16nSNeOy2EEOaqlVocKBvRcZPKBDzElQSy0YWUP/WDc4e+vTpkYY07f+9iZqKfq9CWMLvAaIL7L2pwp1T76HR3hBGe5cS/gfYr3IRHt/Mh24ve3UaWqbJwFrZWlOvo1Ll+zFkmfWjhuzJRJh1IIHdIlEmAgA2Qw+dEEVNhFMIrrGsJR7YfVG6M48V+TNaw==";
enum wetCompressedGolden =
    "KLUv/STD7QQAcgkiJJAlbv/ru7tuyAJZCuwdNbb2Mee0mGCDvpz//QOlFmlx1nqMCsuWLUFBQj7LliGNpY+8DT5Jir6/+t/7fSrLEAxhYxxuAB1ywKNxv1zki+osmqIA8ur3uKL/UmMmHtx3VGVhCjxDk2WxV4vQeGEcVOfT0edU1Q7w+TRuOtA4JSbOMqMwnhITJwYAPRsZXiK6xrCUe2n1xurOPD3tlpk=";

ubyte[] gzipFrame(const(ubyte)[] plain) {
    alias Init = extern(C) int function(z_stream*, int, int, int, int, int,
        const(char)*, int);
    alias Deflate = extern(C) int function(z_stream*, int);
    alias End = extern(C) int function(z_stream*);
    alias Version = extern(C) const(char)* function();
    auto library = dlopen("/usr/lib/libz.1.dylib", RTLD_NOW | RTLD_FIRST);
    need(library !is null, "system gzip fixture encoder");
    scope(exit) dlclose(library);
    auto init = cast(Init) dlsym(library, "deflateInit2_");
    auto deflate = cast(Deflate) dlsym(library, "deflate");
    auto end = cast(End) dlsym(library, "deflateEnd");
    auto version_ = cast(Version) dlsym(library, "zlibVersion");
    need(init !is null && deflate !is null && end !is null && version_ !is null,
        "system gzip encoder ABI");
    z_stream stream;
    need(init(&stream, 6, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY,
        version_(), cast(int) z_stream.sizeof) == Z_OK, "gzip init");
    scope(exit) end(&stream);
    auto out_ = new ubyte[plain.length + 1024];
    stream.next_in = plain.ptr;
    stream.avail_in = cast(uint) plain.length;
    stream.next_out = out_.ptr;
    stream.avail_out = cast(uint) out_.length;
    need(deflate(&stream, Z_FINISH) == Z_STREAM_END, "gzip encode");
    return out_[0 .. out_.length - stream.avail_out].dup;
}

ubyte[] zstdFrame(const(ubyte)[] plain) {
    need(plain.length > 255 && plain.length <= 65_791, "zstd raw fixture size");
    ubyte[] out_ = [0x28, 0xB5, 0x2F, 0xFD, 0x64];
    auto length = plain.length - 256;
    out_ ~= [cast(ubyte) length, cast(ubyte)(length >> 8)];
    auto block = cast(uint)((plain.length << 3) | 1);
    out_ ~= [cast(ubyte) block, cast(ubyte)(block >> 8), cast(ubyte)(block >> 16)];
    out_ ~= plain;
    auto checksum = cast(uint) ZSTD_XXH64(plain.ptr, plain.length, 0);
    foreach (shift; [0, 8, 16, 24]) out_ ~= cast(ubyte)(checksum >> shift);
    return out_;
}

string signature(WarcRecord r) {
    string result = r.sourceKey ~ ":" ~ r.ordinal.to!string ~ ":" ~
        r.recordId ~ ":" ~ r.date ~ ":" ~ r.type ~ ":" ~
        (r.hasTargetUri ? "target=" ~ r.targetUri : "no-target") ~ ":" ~
        "content-type=" ~ r.contentType ~ ":" ~ cast(string) r.block ~ ":" ~
        (r.isConversionText() ? "conversion=" ~ r.conversionText() : "not-conversion");
    foreach (f; r.fields) result ~= ":" ~ f.name ~ "=" ~ f.value;
    return result;
}

size_t fdCount() {
    size_t count;
    foreach (_; dirEntries("/dev/fd", SpanMode.shallow)) ++count;
    return count;
}

void expectFailure(string root, string rel, WarcFileFormat format,
    WarcFilePhase phase, size_t prefix, string[] seen = null) {
    bool failed;
    try readWarcFile(root, rel, format, "source-key", (WarcRecord r) {
        seen ~= signature(r); return true;
    });
    catch (WarcFileError error) {
        failed = true;
        need(error.phase == phase && error.completed == prefix,
            "wrong phase/prefix for " ~ rel ~ ": " ~ error.phase.to!string ~
            "/" ~ error.completed.to!string);
    }
    need(failed && seen.length == prefix, "missing failure or incorrect callback prefix");
}

void cleanup(string root) {
    foreach (name; ["plain", "gzip", "zstd", "late-gzip", "truncated",
        "trailing", "empty", "long", "leaf", "fifo", "official-zstd",
        "late-zstd", "truncated-gzip", "truncated-zstd",
        "large-plain", "large-gzip"])
        try remove(buildPath(root, name)); catch (Exception) {}
    try remove(buildPath(root, "sub", "link")); catch (Exception) {}
    try rmdir(buildPath(root, "sub")); catch (Exception) {}
    try rmdir(root); catch (Exception) {}
}

void main() {
    auto root = buildPath("/tmp", "scrubbed-warc-file-" ~ randomUUID().toString());
    mkdir(root);
    scope(exit) cleanup(root);
    auto first = record("first", "response", cast(ubyte[]) "HTTP/1.1 200 OK\r\n\r\nbody");
    auto second = record("second", "conversion", cast(ubyte[]) "caf\xc3\xa9\n",
        "Content-Type: text/plain\r\n");
    auto paddedFirst = record("first", "response", cast(ubyte[]) ("x".repeat(300).join()).dup);
    auto paddedSecond = record("second", "conversion", cast(ubyte[]) ("y".repeat(300).join()).dup,
        "Content-Type: text/plain\r\n");
    auto plainBytes = first ~ second;
    auto gzipBytes = gzipFrame(first) ~ gzipFrame(second);
    auto zstdBytes = zstdFrame(paddedFirst) ~ zstdFrame(paddedSecond);
    write(buildPath(root, "plain"), plainBytes);
    write(buildPath(root, "gzip"), gzipBytes);
    write(buildPath(root, "zstd"), zstdBytes);
    auto officialPlain = record("one", "response",
        cast(ubyte[]) "HTTP/1.1 200 OK\r\n\r\nhi", "Content-Type: application/http\r\n") ~
        record("two", "conversion", cast(ubyte[]) "caf\xc3\xa9\n",
            "Content-Type: text/plain\r\n");
    auto officialBytes = Base64.decode(responseCompressedGolden) ~
        Base64.decode(wetCompressedGolden);
    write(buildPath(root, "official-zstd"), officialBytes);
    string[] officialExpected, officialActual;
    auto officialReader = new WarcReader("source-key", (WarcRecord r) {
        officialExpected ~= signature(r); return true;
    });
    officialReader.feed(officialPlain); officialReader.finish();
    need(readWarcFile(root, "official-zstd", WarcFileFormat.zstd,
        "source-key", (WarcRecord r) { officialActual ~= signature(r); return true; }) == 2 &&
        officialActual == officialExpected, "on-disk official compressed-block parity");
    ubyte[] largeBlock = new ubyte[32_000];
    uint randomState = 0x6d2b79f5;
    foreach (ref octet; largeBlock) {
        randomState ^= randomState << 13;
        randomState ^= randomState >> 17;
        randomState ^= randomState << 5;
        octet = cast(ubyte) randomState;
    }
    auto large = record("large", "response", largeBlock);
    write(buildPath(root, "large-plain"), large);
    write(buildPath(root, "large-gzip"), gzipFrame(large));
    foreach (item; ["large-plain", "large-gzip"])
        need(readWarcFile(root, item, item == "large-plain" ?
            WarcFileFormat.plain : WarcFileFormat.gzip, "source-key",
            (WarcRecord r) => r.block.length == 32_000) == 1,
            "cross-chunk large record " ~ item);
    foreach (item; ["plain", "gzip", "zstd"]) {
        auto format = item == "plain" ? WarcFileFormat.plain :
            item == "gzip" ? WarcFileFormat.gzip : WarcFileFormat.zstd;
        auto bytes = item == "plain" ? plainBytes : item == "gzip" ? gzipBytes : zstdBytes;
        string[] expected, actual;
        if (format == WarcFileFormat.plain) {
            auto reader = new WarcReader("source-key", (WarcRecord r) {
                expected ~= signature(r); return true;
            });
            reader.feed(bytes); reader.finish();
        } else {
            auto reader = new WarcCompressedReader(
                format == WarcFileFormat.gzip ? Compression.gzip : Compression.zstd,
                "source-key", (WarcRecord r) { expected ~= signature(r); return true; });
            reader.feed(bytes); reader.finish(); reader.close();
        }
        need(readWarcFile(root, item, format, "source-key", (WarcRecord r) {
            actual ~= signature(r); return true;
        }) == 2 && expected == actual, "on-disk parity " ~ item);
        need(actual[0].canFind(":1:") && actual[1].canFind(":2:"), "ordinals");
        need(actual[0].canFind("2026-09-21T00:00:00Z") &&
            actual[0].canFind("target=https://example.org/a") &&
            actual[1].canFind("content-type=text/plain") &&
            actual[1].canFind(item == "zstd" ? "conversion=yyy" :
                "conversion=caf\xc3\xa9\n"),
            "date/URI/Content-Type/WET parity " ~ item);
    }
    auto bad = gzipBytes.dup;
    bad[$ - 8] ^= 1;
    write(buildPath(root, "late-gzip"), bad);
    expectFailure(root, "late-gzip", WarcFileFormat.gzip, WarcFilePhase.parser, 1);
    auto badZstd = officialBytes.dup;
    badZstd[$ - 1] ^= 1;
    write(buildPath(root, "late-zstd"), badZstd);
    expectFailure(root, "late-zstd", WarcFileFormat.zstd, WarcFilePhase.parser, 1);
    write(buildPath(root, "truncated-gzip"), gzipBytes[0 .. $ - 1]);
    expectFailure(root, "truncated-gzip", WarcFileFormat.gzip, WarcFilePhase.parser, 1);
    write(buildPath(root, "truncated-zstd"), zstdBytes[0 .. $ - 1]);
    expectFailure(root, "truncated-zstd", WarcFileFormat.zstd, WarcFilePhase.parser, 1);
    write(buildPath(root, "truncated"), plainBytes[0 .. $ - 1]);
    expectFailure(root, "truncated", WarcFileFormat.plain, WarcFilePhase.parser, 1);
    write(buildPath(root, "trailing"), zstdBytes ~ cast(ubyte[]) "junk");
    expectFailure(root, "trailing", WarcFileFormat.zstd, WarcFilePhase.parser, 2);
    write(buildPath(root, "empty"), cast(ubyte[]) []);
    foreach (format; [WarcFileFormat.plain, WarcFileFormat.gzip, WarcFileFormat.zstd])
        expectFailure(root, "empty", format, WarcFilePhase.parser, 0);
    foreach (item; ["plain", "gzip", "zstd"]) {
        auto format = item == "plain" ? WarcFileFormat.plain :
            item == "gzip" ? WarcFileFormat.gzip : WarcFileFormat.zstd;
        size_t called;
        bool cancelled;
        try readWarcFile(root, item, format, "source-key", (WarcRecord r) {
            ++called; return false;
        });
        catch (WarcFileError error) {
            cancelled = error.phase == WarcFilePhase.cancel && error.completed == 0;
        }
        need(cancelled && called == 1, "callback-false cancellation " ~ item);
        bool thrown;
        try readWarcFile(root, item, format, "source-key", (WarcRecord r) {
            throw new Exception("callback sentinel");
            return true;
        });
        catch (WarcFileError error) {
            thrown = error.phase == WarcFilePhase.callback && error.completed == 0 &&
                error.original !is null && error.original.msg == "callback sentinel";
        }
        need(thrown, "thrown callback classification " ~ item);
    }
    size_t outerCalls;
    bool nestedClassified;
    try readWarcFile(root, "plain", WarcFileFormat.plain, "source-key",
        (WarcRecord r) {
            ++outerCalls;
            if (outerCalls == 2)
                readWarcFile(root, "../plain", WarcFileFormat.plain,
                    "nested-source", (WarcRecord inner) => true);
            return true;
        });
    catch (WarcFileError error) {
        auto inner = cast(WarcFileError) error.original;
        nestedClassified = error.phase == WarcFilePhase.callback &&
            error.completed == 1 && inner !is null &&
            inner.phase == WarcFilePhase.path && inner.completed == 0;
    }
    need(nestedClassified && outerCalls == 2,
        "nested WARC file error must be outer callback failure with completed prefix");
    mkdir(buildPath(root, "sub"));
    need(symlink("../plain", buildPath(root, "sub", "link").toStringz) == 0,
        "leaf symlink fixture");
    need(symlink("sub", buildPath(root, "leaf").toStringz) == 0,
        "ancestor symlink fixture");
    need(mkfifo(buildPath(root, "fifo").toStringz, 384) == 0,
        "FIFO fixture");
    foreach (rel; ["sub/link", "leaf/link", "fifo", "sub"])
        expectFailure(root, rel, WarcFileFormat.plain, WarcFilePhase.open, 0);
    foreach (rel; ["../plain", "/plain", "sub/../plain", "./plain",
        "sub//link", "plain/", "plain\0alias"])
        expectFailure(root, rel, WarcFileFormat.plain, WarcFilePhase.path, 0);
    expectFailure(root, "plain", cast(WarcFileFormat) 99, WarcFilePhase.parser, 0);
    bool nullRejected;
    try readWarcFile(root, "plain", WarcFileFormat.plain, "source-key", null);
    catch (WarcFileError error) {
        nullRejected = error.phase == WarcFilePhase.parser && error.completed == 0;
    }
    need(nullRejected, "null callback rejected");
    auto baseline = fdCount();
    for (size_t n; n < 100; ++n)
        need(readWarcFile(root, "gzip", WarcFileFormat.gzip, "source-key",
            (WarcRecord r) => true) == 2, "repeat gzip");
    need(fdCount() == baseline, "FD leak");
    // The total file is much larger than any member or input buffer.
    auto longPath = buildPath(root, "long");
    auto longFrame = gzipFrame(first);
    auto longOutput = File(longPath, "wb");
    foreach (_; 0 .. 120_000) longOutput.rawWrite(longFrame);
    longOutput.close();
    auto archiveSize = getSize(longPath);
    need(archiveSize > 10_000_000, "long fixture must exceed ten MiB");
    GC.collect();
    auto before = GC.stats.usedSize;
    auto count = readWarcFile(root, "long", WarcFileFormat.gzip,
        "source-key", (WarcRecord r) => true);
    GC.collect();
    auto after = GC.stats.usedSize;
    need(count == 120_000 && fdCount() == baseline, "long-file stream/FD");
    need(after < before + 1_000_000, "long-file retained GC growth");
    rusage usage;
    need(getrusage(RUSAGE_SELF, &usage) == 0, "RSS observation");
    // Phobos exposes Darwin ru_maxrss as the first ru_opaque word.
    auto peakRss = usage.ru_opaque[0];
    need(peakRss >= 0 && peakRss < archiveSize + 32_000_000,
        "long-file process peak RSS is excessive relative to input size");
    writeln("file adapter release checks: 3-format parity, prefix, path, cancellation, FD, long file OK; input=",
        archiveSize, " peak RSS=", peakRss, " retained GC delta=",
        after > before ? after - before : 0);
}
