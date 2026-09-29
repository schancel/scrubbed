/// Minimal `extern(C)` surface over this package's vendored zstd v1.5.7
/// (`third_party/zstd`, a byte-identical copy of scrubbed's pinned
/// `third_party/zstd`): one-shot compression for Parquet data pages written
/// by `parquet.writer`, and exact-size one-shot decompression for ZSTD pages
/// read by `parquet.reader`.
module parquet.zstd_ffi;

extern(C) @nogc nothrow {
    uint ZSTD_versionNumber();
    pure uint ZSTD_isError(size_t result);
    const(char)* ZSTD_getErrorName(size_t result);
    pure size_t ZSTD_compressBound(size_t srcSize);
    pure size_t ZSTD_compress(void* dst, size_t dstCapacity, const(void)* src,
        size_t srcSize, int compressionLevel);
    size_t ZSTD_decompress(void* dst, size_t dstCapacity, const(void)* src,
        size_t compressedSize);
    /// Upper bound on the decompressed size of all frames in `src`: exact
    /// for frames that record their content size (parquet-cpp's do),
    /// otherwise block count x 128 KiB. Declared in zstd.h's
    /// `ZSTD_STATIC_LINKING_ONLY` section, which is fine against this
    /// pinned, statically linked v1.5.7.
    ulong ZSTD_decompressBound(const(void)* src, size_t srcSize);
}

/// `ZSTD_CONTENTSIZE_ERROR`.
private enum ulong zstdContentSizeError = 0UL - 2;

/// Pinned release this package was built and verified against.
enum uint pinnedZstdVersion = 10_507;

/// zstd's documented valid compression-level range for v1.5.7 (negative
/// "fast" levels are excluded on purpose: they are not needed here).
enum int minZstdLevel = 1;
/// ditto
enum int maxZstdLevel = 22;

/// Compresses `src` into a new zstd frame at `level`.
ubyte[] zstdCompress(const(ubyte)[] src, int level) {
    import std.exception : enforce;
    import std.string : fromStringz;

    enforce(level >= minZstdLevel && level <= maxZstdLevel,
        "zstd level out of range");
    const bound = ZSTD_compressBound(src.length);
    enforce(!ZSTD_isError(bound), "zstd compressBound failed");
    auto dst = new ubyte[bound];
    const n = ZSTD_compress(dst.ptr, dst.length, src.ptr, src.length, level);
    enforce(!ZSTD_isError(n), fromStringz(ZSTD_getErrorName(n)).idup);
    return dst[0 .. n];
}

/// Decompresses `src` (one or more zstd frames) into exactly
/// `expectedLength` bytes, as Parquet page headers declare. Any zstd error
/// or length disagreement throws `ParquetFormatException`. The declared
/// length is checked against what the frames can actually produce before
/// the output buffer is allocated, so a forged page header cannot force a
/// large allocation.
ubyte[] zstdDecompress(const(ubyte)[] src, size_t expectedLength) {
    import parquet.exception : ParquetFormatException;
    import std.string : fromStringz;

    // Format bound first: ZSTD_decompressBound trusts a frame header's
    // recorded content size, which a forged frame can set to anything. Per
    // RFC 8878, every block has a 3-byte header and produces at most
    // Block_Maximum_Size <= 128 KiB. A raw block of n bytes costs 3 + n
    // input bytes for n output bytes; an RLE block, 4 bytes for up to
    // 128 KiB; a compressed block needs at least a literals-section and a
    // sequences-section header byte (>= 5 bytes); frame headers and
    // skippable frames only add input. So each output-producing block
    // costs >= 4 input bytes and total output is <= (len / 4) x 128 KiB.
    // The + 1 is slack; the arithmetic is 64-bit.
    enum ulong blockMax = 128 * 1024;
    if (cast(ulong) expectedLength > (cast(ulong) src.length / 4 + 1) * blockMax)
        throw new ParquetFormatException(
            "zstd: page header declares more bytes than the input could produce");
    const bound = ZSTD_decompressBound(src.ptr, src.length);
    if (bound == zstdContentSizeError)
        throw new ParquetFormatException("zstd: corrupt or truncated frame");
    if (expectedLength > bound)
        throw new ParquetFormatException(
            "zstd: page header declares more bytes than the frames can produce");
    auto dst = new ubyte[expectedLength];
    const n = ZSTD_decompress(dst.ptr, dst.length, src.ptr, src.length);
    if (ZSTD_isError(n))
        throw new ParquetFormatException("zstd: " ~ fromStringz(ZSTD_getErrorName(n)).idup);
    if (n != expectedLength)
        throw new ParquetFormatException("zstd: decompressed size disagrees with the page header");
    return dst;
}

unittest {
    import parquet.exception : ParquetFormatException;
    import std.exception : assertThrown;

    auto input = cast(const(ubyte)[]) "zstd zstd zstd zstd zstd zstd";
    auto frame = zstdCompress(input, 3);
    assert(zstdDecompress(frame, input.length) == input);
    assertThrown!ParquetFormatException(zstdDecompress(frame, input.length - 1));
    assertThrown!ParquetFormatException(zstdDecompress(frame, input.length + 1));
    assertThrown!ParquetFormatException(zstdDecompress(frame[0 .. $ - 1], input.length));
    // A forged 1 GiB size is refused before allocating.
    assertThrown!ParquetFormatException(zstdDecompress(frame, 1 << 30));
    assertThrown!ParquetFormatException(zstdDecompress([1, 2, 3, 4, 5, 6, 7, 8], 1 << 30));
    // Forged frame recording a 1 GiB content size (FHD 0xA0: single segment,
    // 4-byte content size) followed by one 1-byte raw last block. The
    // recorded size alone satisfies ZSTD_decompressBound, so only the format
    // bound stops the 1 GiB allocation.
    assert(ZSTD_decompressBound(forgedContentSizeFrame.ptr, forgedContentSizeFrame.length)
        == 1UL << 30);
    assertThrown!ParquetFormatException(zstdDecompress(forgedContentSizeFrame, 1 << 30));
}

/// Test vector for the unittest above (tests/reader_checks.d repeats it).
private immutable ubyte[] forgedContentSizeFrame = [
    0x28, 0xb5, 0x2f, 0xfd,     // magic
    0xa0,                       // FHD: FCS flag 2 (4 bytes), single segment
    0x00, 0x00, 0x00, 0x40,     // content size 2^30
    0x09, 0x00, 0x00,           // block header: last, raw, size 1
    0x61,
];

unittest {
    import std.exception : enforce;

    enforce(ZSTD_versionNumber() == pinnedZstdVersion, "wrong linked zstd version");
    auto input = cast(const(ubyte)[]) "parquet parquet parquet parquet parquet";
    auto frame = zstdCompress(input, 3);
    auto output = new ubyte[input.length];
    const n = ZSTD_decompress(output.ptr, output.length, frame.ptr, frame.length);
    enforce(!ZSTD_isError(n) && n == input.length && output == input,
        "zstd round trip failed");
    // Empty input still yields a valid (non-empty) frame.
    assert(zstdCompress(null, 3).length > 0);
}
