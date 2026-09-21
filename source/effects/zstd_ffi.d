/// ABI declarations for the pinned zstd 1.5.7 decompressor archive.
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
    uint ZSTD_isError(size_t result);
    const(char)* ZSTD_getErrorName(size_t result);
    size_t ZSTD_getFrameHeader(ZstdFrameHeader* header, const(void)* src, size_t srcSize);
    ZstdDStream* ZSTD_createDStream();
    size_t ZSTD_freeDStream(ZstdDStream* stream);
    size_t ZSTD_initDStream(ZstdDStream* stream);
    size_t ZSTD_DCtx_setParameter(ZstdDStream* stream, int parameter, int value);
    size_t ZSTD_decompressStream(ZstdDStream* stream, ZstdOutBuffer* output, ZstdInBuffer* input);
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
