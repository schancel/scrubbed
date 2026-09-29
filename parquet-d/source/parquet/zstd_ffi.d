/// Minimal `extern(C)` surface over this package's vendored zstd v1.5.7
/// (`third_party/zstd`, a byte-identical copy of scrubbed's pinned
/// `third_party/zstd`): one-shot compression for Parquet data pages, plus the
/// one-shot decompressor used only by this package's own tests.
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
}

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
