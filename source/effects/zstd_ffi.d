/// ABI declarations for the pinned zstd 1.5.7 archive: the original
/// decompressor declarations, plus the compression-side one-shot buffer API
/// (`ZSTD_compressBound`/`ZSTD_compress`) added for `effects
/// .compressibility_annotate_stage`. Both sides link the same pinned 1.5.7
/// release (`third_party/zstd/README.md`); the compression side additionally
/// requires `.dub/zstd/libzstd_compress.a` (see that archive's own doc
/// comment in `third_party/zstd/Makefile` for why it depends on
/// `libzstd_decompress.a` also being linked).
module effects.zstd_ffi;

// ABI declarations for pinned zstd 1.5.7, third_party/zstd/zstd.h.
// ZSTD_FrameHeader is an advanced API, valid here only with our static archive.
extern(C) @nogc nothrow {
    struct ZstdDStream;

    struct ZstdInBuffer {
        const(void)* src;
        size_t size;
        size_t pos;
    }

    struct ZstdOutBuffer {
        void* dst;
        size_t size;
        size_t pos;
    }

    struct ZstdFrameHeader {
        ulong frameContentSize;
        ulong windowSize;
        uint blockSizeMax;
        int frameType;
        uint headerSize;
        uint dictID;
        uint checksumFlag;
        uint reserved1;
        uint reserved2;
    }

    uint ZSTD_versionNumber();
    // Declared `pure`: deterministic given `result` alone, no reachable
    // mutable state -- required so `effects.compressibility_annotate_stage`'s
    // `StageApply` (which the registry requires to be `pure`) can call it.
    // Existing non-pure callers (e.g. `effects.warc_compressed`) are
    // unaffected: a pure-declared function may always be called from
    // impure code.
    pure uint ZSTD_isError(size_t result);
    const(char)* ZSTD_getErrorName(size_t result);
    size_t ZSTD_getFrameHeader(ZstdFrameHeader* header, const(void)* src, size_t srcSize);
    ZstdDStream* ZSTD_createDStream();
    size_t ZSTD_freeDStream(ZstdDStream* stream);
    size_t ZSTD_initDStream(ZstdDStream* stream);
    size_t ZSTD_DCtx_setParameter(ZstdDStream* stream, int parameter, int value);
    size_t ZSTD_decompressStream(ZstdDStream* stream, ZstdOutBuffer* output, ZstdInBuffer* input);

    // Compression-side one-shot buffer API (`third_party/zstd/zstd.h`'s
    // "Simple API"): sufficient for a single bounded in-memory document, so
    // no streaming compressor/explicit `ZSTD_CCtx` is declared here. Level is
    // always a fixed schema constant at every call site (19, "bounded
    // standard max, not ultra" per the accepted contract) -- never a
    // caller-tunable parameter. Both declared `pure` for the same reason as
    // `ZSTD_isError` above: deterministic given their arguments, with no
    // dictionary, no multithreading, and no reachable mutable state.
    pure size_t ZSTD_compressBound(size_t srcSize);
    pure size_t ZSTD_compress(void* dst, size_t dstCapacity, const(void)* src,
        size_t srcSize, int compressionLevel);
}

enum zstdWindowLogMax = 100;
enum zstdFrame = 0;

unittest {
    import core.stdc.string : memcmp;
    import std.exception : enforce;

    static assert(ZstdInBuffer.sizeof == 3 * size_t.sizeof);
    static assert(ZstdOutBuffer.sizeof == 3 * size_t.sizeof);
    static assert(ZstdFrameHeader.sizeof == 48);
    version (ZstdAbiNegativeControl) enum expectedVersion = 0;
    else enum expectedVersion = 10507;
    enforce(ZSTD_versionNumber() == expectedVersion, "wrong linked zstd version");

    // Small single-segment raw-block frame for "hello"; checks the advanced
    // header's field offsets and the streaming decoder's buffer ABI.
    ubyte[14] frame = [0x28, 0xB5, 0x2F, 0xFD, 0x20, 0x05,
                       0x29, 0x00, 0x00, 'h', 'e', 'l', 'l', 'o'];
    ZstdFrameHeader header;
    enforce(ZSTD_getFrameHeader(&header, frame.ptr, frame.length) == 0, "frame-header ABI mismatch");
    enforce(header.frameContentSize == 5, "frame content-size ABI mismatch");
    enforce(header.windowSize == 5, "frame window-size ABI mismatch");
    enforce(header.frameType == zstdFrame, "frame type ABI mismatch");
    enforce(header.headerSize == 6, "frame header-size ABI mismatch");
    enforce(header.dictID == 0, "frame dictionary ABI mismatch");
    enforce(header.checksumFlag == 0, "frame checksum ABI mismatch");
    auto badFrame = frame;
    badFrame[0] = 0;
    enforce(ZSTD_isError(ZSTD_getFrameHeader(&header, badFrame.ptr, badFrame.length)) != 0,
            "invalid zstd magic was accepted");

    auto stream = ZSTD_createDStream();
    enforce(stream !is null, "cannot create zstd stream");
    scope(exit) enforce(ZSTD_freeDStream(stream) == 0, "cannot free zstd stream");
    enforce(ZSTD_isError(ZSTD_DCtx_setParameter(stream, zstdWindowLogMax, 17)) == 0,
            "cannot set zstd window limit");
    enforce(ZSTD_isError(ZSTD_initDStream(stream)) == 0, "cannot initialize zstd stream");
    ubyte[16] outputBytes;
    ZstdInBuffer input = ZstdInBuffer(frame.ptr, frame.length, 0);
    ZstdOutBuffer output = ZstdOutBuffer(outputBytes.ptr, outputBytes.length, 0);
    enforce(ZSTD_decompressStream(stream, &output, &input) == 0, "zstd decode failed");
    enforce(input.pos == frame.length && output.pos == 5, "zstd buffer ABI mismatch");
    enforce(memcmp(outputBytes.ptr, "hello".ptr, 5) == 0, "zstd output mismatch");
}

// Compression-side ABI: round-trips a real payload through
// `ZSTD_compressBound`/`ZSTD_compress` (level 19) and back through the
// already-proven streaming decompressor above, checking both the produced
// bytes and byte-for-byte determinism across two independent compress calls.
unittest {
    import std.exception : enforce;

    string original = "hello hello hello hello hello world";
    auto srcBytes = cast(const(ubyte)[]) original;
    auto bound = ZSTD_compressBound(srcBytes.length);
    enforce(!ZSTD_isError(bound), "compressBound failed");
    auto compressed = new ubyte[bound];
    auto compressedSize = ZSTD_compress(compressed.ptr, compressed.length,
        srcBytes.ptr, srcBytes.length, 19);
    enforce(!ZSTD_isError(compressedSize), "zstd compress failed");
    enforce(compressedSize > 0 && compressedSize < srcBytes.length,
        "level-19 compression of a repetitive payload did not shrink it");

    // Determinism: a second independent call over the same bytes is
    // byte-identical, not merely same-length.
    auto compressedAgain = new ubyte[bound];
    auto compressedSizeAgain = ZSTD_compress(compressedAgain.ptr,
        compressedAgain.length, srcBytes.ptr, srcBytes.length, 19);
    enforce(compressedSizeAgain == compressedSize &&
        compressed[0 .. compressedSize] == compressedAgain[0 .. compressedSizeAgain],
        "zstd compression is not deterministic across repeated calls");

    // Round-trip through the streaming decompressor already proven above.
    auto stream = ZSTD_createDStream();
    enforce(stream !is null, "cannot create zstd stream");
    scope(exit) enforce(ZSTD_freeDStream(stream) == 0, "cannot free zstd stream");
    enforce(ZSTD_isError(ZSTD_initDStream(stream)) == 0, "cannot initialize zstd stream");
    ubyte[128] decompressed;
    ZstdInBuffer input = ZstdInBuffer(compressed.ptr, compressedSize, 0);
    ZstdOutBuffer output = ZstdOutBuffer(decompressed.ptr, decompressed.length, 0);
    enforce(ZSTD_decompressStream(stream, &output, &input) == 0, "zstd decode failed");
    enforce(output.pos == srcBytes.length &&
        decompressed[0 .. output.pos] == srcBytes, "compress/decompress round trip mismatch");

    // An empty input still produces a valid, decodable frame -- exercised
    // directly here since `compressibility-annotate`'s floor abstention still
    // runs compression on empty content (see that stage's own fixtures).
    auto emptyBound = ZSTD_compressBound(0);
    auto emptyCompressed = new ubyte[emptyBound];
    auto emptyCompressedSize = ZSTD_compress(emptyCompressed.ptr,
        emptyCompressed.length, null, 0, 19);
    enforce(!ZSTD_isError(emptyCompressedSize), "zstd failed to compress empty input");
    enforce(emptyCompressedSize > 0, "empty-input zstd frame must still occupy some bytes");
}
