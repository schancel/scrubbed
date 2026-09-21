/// Bounded per-record gzip/zstd WARC/1.1 decoder; see docs/warc-reader.md.
module effects.warc_compressed;

import effects.warc_reader : WarcError, WarcReader, WarcRecord, WarcVisit,
    warcRecordLimit;
import effects.zstd_ffi;
import etc.c.zlib : z_stream,
    Z_OK, Z_STREAM_END, Z_DATA_ERROR, Z_NO_FLUSH;
import core.sys.posix.dlfcn : dlopen, dlsym, dlclose, dladdr, Dl_info,
    RTLD_NOW, RTLD_FIRST;
import std.string : fromStringz;

private alias InflateInit2 = extern(C) int function(z_stream*, int, const(char)*, int);
private alias Inflate = extern(C) int function(z_stream*, int);
private alias InflateEnd = extern(C) int function(z_stream*);
private alias ZlibVersion = extern(C) const(char)* function();

enum Compression { gzip, zstd }
enum CompressedReason {
    empty, truncated, checksum, overCap, ratio, unsupported, invalidWarc,
    cancelled, stopped, reentrant
}

final class CompressedWarcError : Exception {
    CompressedReason reason;
    this(CompressedReason reason, string detail) {
        super(detail);
        this.reason = reason;
    }
}

enum size_t compressedMemberLimit = 1_048_576;
enum size_t compressedOutputChunk = 16_384;
enum size_t zstdWindowLimit = 131_072;
enum size_t expansionRatioLimit = 64;

/// One independently compressed member/frame must contain exactly one record.
/// A record is staged until the native checksum/footer and WARC boundary pass.
final class WarcCompressedReader {
    private Compression format;
    private string key;
    private WarcVisit visit;
    private WarcReader parser;
    private WarcRecord staged;
    private bool hasStaged;
    private bool active;
    private bool stopped;
    private bool inCallback;
    private size_t completed;
    private size_t compressed;
    private size_t expanded;
    private z_stream gzip;
    private void* zlibHandle;
    private InflateInit2 zInflateInit;
    private Inflate zInflate;
    private InflateEnd zInflateEnd;
    private ZlibVersion zVersion;
    private ZstdDStream* zstd;
    private ubyte[] zstdHeader;
    private bool zstdHeaderReady;

    this(Compression format, string sourceKey, WarcVisit onRecord) {
        if (format != Compression.gzip && format != Compression.zstd)
            fail(CompressedReason.unsupported, "unsupported compression format");
        // Reuse the uncompressed reader's source-key validation, without
        // starting a member or allocating native state for an empty stream.
        auto validation = new WarcReader(sourceKey, onRecord);
        this.format = format;
        key = sourceKey.idup;
        visit = onRecord;
        if (format == Compression.gzip) loadSystemZlib();
    }

    size_t completedRecords() const { return completed; }

    /// Diagnostic identity of the actual system decoder, not the SDK header.
    string systemZlibVersion() const {
        if (format != Compression.gzip || zlibHandle is null)
            fail(CompressedReason.stopped, "system zlib is not open");
        return fromStringz(zVersion()).idup;
    }

    string systemZlibImage() const {
        if (format != Compression.gzip || zlibHandle is null)
            fail(CompressedReason.stopped, "system zlib is not open");
        Dl_info info;
        if (dladdr(cast(const(void)*) zInflate, &info) == 0 || info.dli_fname is null)
            fail(CompressedReason.unsupported, "cannot identify system zlib image");
        return fromStringz(info.dli_fname).idup;
    }

    void feed(const(ubyte)[] bytes) {
        if (inCallback) fail(CompressedReason.reentrant, "reentrant compressed reader call");
        if (stopped) fail(CompressedReason.stopped, "compressed reader stopped");
        try {
            size_t at;
            while (at < bytes.length) {
                if (!active) beginMember();
                if (format == Compression.gzip)
                    at += decodeGzip(bytes[at .. $]);
                else if (!zstdHeaderReady)
                    at += collectZstdHeader(bytes[at .. $]);
                else
                    at += decodeZstd(bytes[at .. $], false);
            }
        } catch (Exception error) {
            poison();
            throw error;
        }
    }

    void finish() {
        if (inCallback) fail(CompressedReason.reentrant, "reentrant compressed reader call");
        if (stopped) fail(CompressedReason.stopped, "compressed reader stopped");
        if (active || completed == 0) {
            auto wasEmpty = completed == 0 && !active;
            poison();
            fail(wasEmpty ? CompressedReason.empty : CompressedReason.truncated,
                wasEmpty ? "empty compressed archive" : "truncated compressed member");
        }
        stopped = true;
        closeZlib();
    }

    /// Idempotent explicit release for callers that abandon a stream.
    void close() {
        if (inCallback) fail(CompressedReason.reentrant, "reentrant compressed reader call");
        poison();
    }
    ~this() { releaseNative(); closeZlib(); }

    private void loadSystemZlib() {
        zlibHandle = dlopen("/usr/lib/libz.1.dylib", RTLD_NOW | RTLD_FIRST);
        if (zlibHandle is null)
            fail(CompressedReason.unsupported, "macOS system libz unavailable");
        zInflateInit = cast(InflateInit2) dlsym(zlibHandle, "inflateInit2_");
        zInflate = cast(Inflate) dlsym(zlibHandle, "inflate");
        zInflateEnd = cast(InflateEnd) dlsym(zlibHandle, "inflateEnd");
        zVersion = cast(ZlibVersion) dlsym(zlibHandle, "zlibVersion");
        if (zInflateInit is null || zInflate is null || zInflateEnd is null ||
            zVersion is null) {
            closeZlib();
            fail(CompressedReason.unsupported, "macOS system libz ABI unavailable");
        }
    }

    private void closeZlib() {
        if (zlibHandle !is null) {
            dlclose(zlibHandle);
            zlibHandle = null;
        }
    }

    private void beginMember() {
        parser = new WarcReader(key, (WarcRecord record) {
            if (hasStaged) fail(CompressedReason.invalidWarc, "multiple records in compressed member");
            staged = record;
            hasStaged = true;
            return true;
        });
        compressed = expanded = 0;
        active = true;
        if (format == Compression.gzip) {
            gzip = z_stream.init;
            if (zInflateInit(&gzip, 31, zVersion(), cast(int) z_stream.sizeof) != Z_OK)
                fail(CompressedReason.unsupported, "system zlib initialization failed");
        } else {
            zstdHeader = [];
            zstdHeaderReady = false;
        }
    }

    private size_t decodeGzip(const(ubyte)[] bytes) {
        auto room = compressedMemberLimit - compressed;
        if (room == 0) fail(CompressedReason.overCap, "gzip member byte cap");
        auto offered = bytes.length < room ? bytes.length : room;
        gzip.next_in = bytes.ptr;
        gzip.avail_in = cast(uint) offered;
        size_t consumed;
        do {
            ubyte[compressedOutputChunk] output;
            gzip.next_out = output.ptr;
            gzip.avail_out = cast(uint) output.length;
            auto before = gzip.avail_in;
            auto result = zInflate(&gzip, Z_NO_FLUSH);
            auto used = before - gzip.avail_in;
            consumed += used;
            compressed += used;
            auto produced = output.length - gzip.avail_out;
            appendPlain(output[0 .. produced]);
            if (result == Z_STREAM_END) {
                completeMember();
                return consumed;
            }
            if (result != Z_OK) {
                auto message = gzip.msg is null ? "" : fromStringz(gzip.msg);
                if (result == Z_DATA_ERROR &&
                    (message == "incorrect data check" || message == "incorrect length check"))
                    fail(CompressedReason.checksum, "gzip footer checksum or size mismatch");
                fail(CompressedReason.unsupported, "invalid or unsupported gzip member");
            }
            if (used == 0 && produced == 0) {
                if (gzip.avail_in == 0) break;
                fail(CompressedReason.unsupported, "gzip decoder made no progress");
            }
        } while (gzip.avail_in != 0 || gzip.avail_out == 0);
        if (compressed == compressedMemberLimit)
            fail(CompressedReason.overCap, "gzip member byte cap");
        return consumed;
    }

    private size_t collectZstdHeader(const(ubyte)[] bytes) {
        size_t used;
        while (used < bytes.length) {
            if (compressed == compressedMemberLimit)
                fail(CompressedReason.overCap, "zstd frame byte cap");
            zstdHeader ~= bytes[used++];
            ++compressed;
            ZstdFrameHeader header;
            auto result = ZSTD_getFrameHeader(&header, zstdHeader.ptr, zstdHeader.length);
            if (ZSTD_isError(result)) fail(CompressedReason.unsupported, "invalid zstd frame header");
            if (result > 18) fail(CompressedReason.unsupported, "oversized zstd frame header");
            if (result != 0) continue;
            if (header.frameType != zstdFrame || header.dictID != 0 ||
                header.checksumFlag != 1 || header.frameContentSize == ulong.max ||
                header.frameContentSize == ulong.max - 1)
                fail(CompressedReason.unsupported, "unsupported zstd frame metadata");
            if (header.frameContentSize > warcRecordLimit ||
                header.windowSize > zstdWindowLimit)
                fail(CompressedReason.overCap, "zstd declared size or window cap");
            zstdHeaderReady = true;
            zstd = ZSTD_createDStream();
            if (zstd is null) fail(CompressedReason.unsupported, "zstd context allocation failed");
            if (ZSTD_isError(ZSTD_DCtx_setParameter(zstd, zstdWindowLogMax, 17)) ||
                ZSTD_isError(ZSTD_initDStream(zstd)))
                fail(CompressedReason.unsupported, "zstd window setup failed");
            // Header was already counted against the compressed cap.
            auto headerLength = zstdHeader.length;
            if (decodeZstd(zstdHeader, true) != headerLength)
                fail(CompressedReason.unsupported, "incomplete zstd header decode");
            return used;
        }
        return used;
    }

    private size_t decodeZstd(const(ubyte)[] bytes, bool countedHeader) {
        auto room = compressedMemberLimit - compressed;
        if (!countedHeader && room == 0) fail(CompressedReason.overCap, "zstd frame byte cap");
        auto offered = countedHeader ? bytes.length : (bytes.length < room ? bytes.length : room);
        ZstdInBuffer input = ZstdInBuffer(bytes.ptr, offered, 0);
        size_t previous;
        do {
            ubyte[compressedOutputChunk] output;
            ZstdOutBuffer outBuffer = ZstdOutBuffer(output.ptr, output.length, 0);
            previous = input.pos;
            auto result = ZSTD_decompressStream(zstd, &outBuffer, &input);
            if (ZSTD_isError(result)) {
                auto name = fromStringz(ZSTD_getErrorName(result));
                if (name == "Restored data doesn't match checksum")
                    fail(CompressedReason.checksum, "zstd checksum mismatch");
                fail(CompressedReason.unsupported, "invalid zstd frame");
            }
            if (!countedHeader) compressed += input.pos - previous;
            appendPlain(output[0 .. outBuffer.pos]);
            if (result == 0) {
                completeMember();
                return input.pos;
            }
            if (input.pos == previous && outBuffer.pos == 0) {
                if (input.pos == input.size) break;
                fail(CompressedReason.unsupported, "zstd decoder made no progress");
            }
            if (input.pos == input.size && outBuffer.pos < outBuffer.size) break;
        } while (true);
        if (!countedHeader && compressed == compressedMemberLimit)
            fail(CompressedReason.overCap, "zstd frame byte cap");
        return input.pos;
    }

    private void appendPlain(const(ubyte)[] bytes) {
        if (bytes.length == 0) return;
        if (bytes.length > warcRecordLimit - expanded)
            fail(CompressedReason.overCap, "expanded record byte cap");
        expanded += bytes.length;
        if (expanded > compressed * expansionRatioLimit)
            fail(CompressedReason.ratio, "compressed expansion ratio cap");
        // The plain reader permits adjacent records. Feed one byte at a time
        // here so no second record/header can grow beside the staged first.
        foreach (at; 0 .. bytes.length) {
            if (hasStaged)
                fail(CompressedReason.invalidWarc, "bytes after WARC record in member");
            try parser.feed(bytes[at .. at + 1]);
            catch (WarcError error) fail(CompressedReason.invalidWarc, error.msg);
        }
    }

    private void completeMember() {
        try parser.finish();
        catch (WarcError error) fail(CompressedReason.invalidWarc, error.msg);
        if (!hasStaged) fail(CompressedReason.invalidWarc, "no WARC record in member");
        if (completed == size_t.max) fail(CompressedReason.overCap, "record ordinal overflow");
        auto record = staged;
        record.ordinal = completed + 1;
        releaseNative();
        active = false;
        parser = null;
        staged = WarcRecord.init;
        hasStaged = false;
        inCallback = true;
        scope(exit) inCallback = false;
        if (!visit(record)) fail(CompressedReason.cancelled, "record callback cancelled");
        ++completed;
    }

    private void releaseNative() {
        if (zstd !is null) {
            ZSTD_freeDStream(zstd);
            zstd = null;
        }
        if (format == Compression.gzip && gzip.state !is null) {
            zInflateEnd(&gzip);
            gzip = z_stream.init;
        }
        zstdHeader = null;
        zstdHeaderReady = false;
    }

    private void poison() {
        releaseNative();
        parser = null;
        staged = WarcRecord.init;
        hasStaged = active = false;
        stopped = true;
        closeZlib();
    }

    private static void fail(CompressedReason reason, string detail) {
        throw new CompressedWarcError(reason, detail);
    }
}
