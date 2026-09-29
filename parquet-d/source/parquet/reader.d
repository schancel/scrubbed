/// Flat-schema Parquet reader for externally produced files (pyarrow /
/// parquet-cpp, datatrove, HF `datasets` exports, and this package's own
/// writer).
///
/// Supported:
///
/// - Framing: `PAR1` at both ends, 4-byte little-endian footer length,
///   Thrift compact `FileMetaData` decoded by `parquet.thrift_codec` (the
///   same vendored `TCompactProtocol` the writer uses). Any number of row
///   groups; any number of pages per column chunk.
/// - Schema: a root group whose children are all leaves (`REQUIRED` or
///   `OPTIONAL`). Nested groups and `REPEATED` fields are rejected.
/// - Physical types: all eight (`BOOLEAN`, `INT32`, `INT64`, `INT96`,
///   `FLOAT`, `DOUBLE`, `BYTE_ARRAY`, `FIXED_LEN_BYTE_ARRAY`). Values are
///   returned in their physical representation; logical annotations are
///   reported on the `ColumnDescriptor` but not applied.
/// - Pages: dictionary pages, data pages v1 and v2; index pages are skipped.
/// - Value encodings: `PLAIN`, `PLAIN_DICTIONARY` / `RLE_DICTIONARY`, and
///   `RLE` for booleans. Definition levels: `RLE` (the RLE/bit-packing
///   hybrid). The `DELTA_*` and `BYTE_STREAM_SPLIT` encodings and the
///   deprecated `BIT_PACKED` level encoding are rejected with a
///   `ParquetFormatException` naming them.
/// - Codecs: `UNCOMPRESSED`, `SNAPPY` (native decoder, `parquet.snappy`),
///   `ZSTD` (vendored zstd), `GZIP` (the zlib bundled in D's Phobos runtime).
///   `LZ4`, `LZ4_RAW`, `BROTLI`, and `LZO` are rejected by name.
///
/// Every length, offset, count, and index read from the file is checked
/// explicitly; malformed input raises `ParquetFormatException` (never a D
/// `Error`), and decoded values never alias the input buffer, so they stay
/// valid after the reader is closed.
module parquet.reader;

import parquet.exception : ParquetFormatException, check;
import parquet.snappy : snappyDecompress;
import parquet.thrift_codec;
import parquet.zstd_ffi : zstdDecompress;

import std.bitmanip : littleEndianToNative;
import std.conv : to;

/// Reader limits for hostile input.
struct ReaderOptions {
    /// Largest row count accepted for one row group. Page and level buffers
    /// are sized from counts in the file, and the RLE hybrid can claim
    /// billions of values in a few bytes, so a forged count is refused before
    /// anything is allocated for it. Real corpus row groups are far smaller
    /// (HF exports: 1-100k rows).
    long maxRowGroupRows = 1L << 26;

    /// Largest declared uncompressed page size accepted. ZSTD and GZIP pages
    /// are inflated into a buffer of the declared size, so a few forged
    /// header bytes could otherwise demand up to 2 GiB before the codec
    /// notices the data is short. Real corpus pages are around 1 MiB
    /// (pyarrow's default data and dictionary page limits); raise this only
    /// for files with single values larger than the default.
    long maxPageBytes = 256L << 20;
}

/// One leaf column of a flat schema.
struct ColumnDescriptor {
    string name;
    PhysicalType type;
    /// Byte width of a `FIXED_LEN_BYTE_ARRAY` column (12 for `INT96`).
    int typeLength;
    /// `OPTIONAL` (may contain nulls) rather than `REQUIRED`.
    bool nullable;
    /// `BYTE_ARRAY` annotated `STRING` (logical type) or `UTF8` (converted
    /// type). The reader does not validate UTF-8; see `ColumnValues.text`.
    bool isString;
    bool hasConvertedType;
    /// Raw `converted_type` annotation.
    int convertedType;
    /// `logicalType` union member id (0 = none, 1 = STRING, ...).
    int logicalType;
}

/// Decoded values of one column over one row group, in physical form. Only
/// the array matching `type` is populated; it has one entry per row, and a
/// null row holds that type's `.init` value (check `isNull`).
struct ColumnValues {
    PhysicalType type;
    /// One flag per row.
    bool[] nulls;
    bool[] booleans;
    int[] int32s;
    long[] int64s;
    float[] floats;
    double[] doubles;
    /// `BYTE_ARRAY`, `FIXED_LEN_BYTE_ARRAY`, and `INT96` (12 raw bytes).
    const(ubyte)[][] binaries;

    size_t length() const { return nulls.length; }
    bool isNull(size_t row) const { return nulls[row]; }

    /// A `BYTE_ARRAY` value viewed as text. The bytes are exactly what the
    /// file stored; callers that need valid UTF-8 must validate.
    const(char)[] text(size_t row) const { return cast(const(char)[]) binaries[row]; }
}

/// Reads a Parquet file held in memory (or memory-mapped via `open`).
final class ParquetReader {
    private const(ubyte)[] file_;
    private Object mapping_; // keeps an MmFile alive when opened from a path
    private FileMetaData meta_;
    private ColumnDescriptor[] columns_;
    private ReaderOptions options_;

    /// Parses and validates the footer and schema of `file`. The slice must
    /// stay valid while columns are read; decoded values never alias it.
    this(const(ubyte)[] file, ReaderOptions options = ReaderOptions.init) {
        file_ = file;
        options_ = options;
        parseFooter();
    }

    /// Memory-maps `path` read-only and parses its footer.
    static ParquetReader open(string path, ReaderOptions options = ReaderOptions.init) {
        import std.file : getSize;
        import std.mmfile : MmFile;

        if (getSize(path) == 0)
            throw new ParquetFormatException(path ~ ": empty file is not Parquet");
        auto mm = new MmFile(path);
        auto reader = new ParquetReader(cast(const(ubyte)[]) mm[], options);
        reader.mapping_ = mm;
        return reader;
    }

    /// Releases a mapping made by `open`. Values already decoded stay valid;
    /// the reader cannot read further columns.
    void close() {
        file_ = null;
        if (mapping_ !is null) {
            destroy(mapping_);
            mapping_ = null;
        }
    }

    /// The decoded footer.
    ref const(FileMetaData) metadata() const return { return meta_; }
    /// The flat schema's leaf columns, in file order.
    const(ColumnDescriptor)[] columns() const { return columns_; }
    long numRows() const { return meta_.numRows; }
    size_t numRowGroups() const { return meta_.rowGroups.length; }
    long rowGroupNumRows(size_t rowGroup) const { return meta_.rowGroups[rowGroup].numRows; }

    /// Index of the column called `name`, or `size_t.max`.
    size_t columnIndex(string name) const {
        foreach (i, ref c; columns_) if (c.name == name) return i;
        return size_t.max;
    }

    /// Decodes every column of one row group.
    ColumnValues[] readRowGroup(size_t rowGroup) {
        auto result = new ColumnValues[columns_.length];
        foreach (i; 0 .. columns_.length) result[i] = readColumn(rowGroup, i);
        return result;
    }

    /// Decodes one column chunk.
    ColumnValues readColumn(size_t rowGroup, size_t column) {
        import std.exception : enforce;

        enforce(file_ !is null, "parquet reader is closed");
        enforce(rowGroup < meta_.rowGroups.length, "row group index out of range");
        enforce(column < columns_.length, "column index out of range");
        const group = &meta_.rowGroups[rowGroup];
        const col = &columns_[column];
        const chunk = &group.columns[column];
        const where = "row group " ~ rowGroup.to!string ~ " column '" ~ col.name ~ "': ";

        check(chunk.filePath is null, where ~ "column data in an external file is not supported");
        check(chunk.hasMetaData, where ~ "column chunk has no metadata (encrypted?)");
        const cm = &chunk.metaData;
        check(cm.type == col.type, where ~ "column chunk type disagrees with the schema");
        check(cm.pathInSchema.length == 1 && cm.pathInSchema[0] == col.name,
            where ~ "column chunk path disagrees with the schema");
        const rows = group.numRows;
        check(cm.numValues == rows, where ~ "value count disagrees with the row group's row count");
        if (rows == 0) {
            // Nothing to decode. pyarrow writes zero-row chunks with only a
            // dictionary page and `data_page_offset = 0`, so their offsets
            // are not meaningful enough to validate.
            ColumnValues empty;
            empty.type = col.type;
            return empty;
        }

        // A dictionary page, when present, precedes the first data page.
        long start = cm.dataPageOffset;
        if (cm.hasDictionaryPageOffset && cm.dictionaryPageOffset > 0
                && cm.dictionaryPageOffset < start)
            start = cm.dictionaryPageOffset;
        const dataEnd = file_.length - 8 - footerLength();
        check(start >= 4 && cast(ulong) start <= dataEnd
            && cm.totalCompressedSize >= 0
            && cast(ulong) cm.totalCompressedSize <= dataEnd - start,
            where ~ "column chunk lies outside the file's data region");
        const bytes = file_[cast(size_t) start .. cast(size_t)(start + cm.totalCompressedSize)];

        try {
            return decodeChunk(*col, cm.codec, bytes, cast(size_t) rows, options_);
        } catch (ParquetFormatException e) {
            throw new ParquetFormatException(where ~ e.msg, e.file, e.line);
        }
    }

    private uint footerLength() const {
        ubyte[4] b = file_[$ - 8 .. $ - 4];
        return littleEndianToNative!uint(b);
    }

    private void parseFooter() {
        check(file_.length >= 12, "file too small to be Parquet");
        check(file_[0 .. 4] == "PAR1", "missing leading PAR1 magic");
        check(file_[$ - 4 .. $] != "PARE", "encrypted Parquet files are not supported");
        check(file_[$ - 4 .. $] == "PAR1", "missing trailing PAR1 magic");
        const len = footerLength();
        check(len <= file_.length - 12, "footer length exceeds the file");
        const footerStart = file_.length - 8 - len;
        meta_ = decodeFileMetaData(file_[footerStart .. $ - 8]);

        // Flat schema: root group + leaves only.
        check(meta_.schema.length >= 1, "schema is empty");
        const root = &meta_.schema[0];
        check(!root.hasType, "schema root is not a group");
        const leaves = meta_.schema.length - 1;
        check(root.hasNumChildren && root.numChildren >= 0 && root.numChildren == leaves,
            "nested schemas are not supported (root children do not match the leaf count)");
        columns_ = new ColumnDescriptor[leaves];
        foreach (i, ref e; meta_.schema[1 .. $]) {
            check(!(e.hasNumChildren && e.numChildren > 0) && e.hasType,
                "column '" ~ e.name ~ "': nested schemas are not supported");
            check(!(e.hasRepetition && e.repetition == Repetition.repeated),
                "column '" ~ e.name ~ "': repeated fields are not supported");
            check(e.type >= PhysicalType.boolean && e.type <= PhysicalType.fixedLenByteArray,
                "column '" ~ e.name ~ "': unknown physical type");
            auto c = &columns_[i];
            c.name = e.name;
            c.type = e.type;
            c.nullable = e.hasRepetition && e.repetition == Repetition.optional;
            c.isString = e.type == PhysicalType.byteArray && e.utf8String;
            c.hasConvertedType = e.hasConvertedType;
            c.convertedType = e.convertedType;
            c.logicalType = e.logicalType;
            if (e.type == PhysicalType.fixedLenByteArray) {
                // pyarrow also refuses width 0; allowing it would let a
                // PLAIN page claim any number of values without data.
                check(e.hasTypeLength && e.typeLength > 0,
                    "column '" ~ e.name ~ "': FIXED_LEN_BYTE_ARRAY without a valid type_length");
                c.typeLength = e.typeLength;
            } else if (e.type == PhysicalType.int96) {
                c.typeLength = 12;
            }
        }

        check(meta_.numRows >= 0, "negative row count");
        long total;
        foreach (gi, ref g; meta_.rowGroups) {
            check(g.numRows >= 0 && g.numRows <= options_.maxRowGroupRows,
                "row group " ~ gi.to!string ~ ": row count "
                ~ g.numRows.to!string ~ " is negative or exceeds ReaderOptions.maxRowGroupRows");
            check(g.columns.length == leaves,
                "row group " ~ gi.to!string ~ ": column count disagrees with the schema");
            total += g.numRows;
        }
        check(total == meta_.numRows, "row group row counts do not sum to the file's num_rows");
    }
}

// ---------------------------------------------------------------------------
// Column chunk decoding
// ---------------------------------------------------------------------------

/// Typed value arrays without null bookkeeping (page values, dictionaries).
private struct Values {
    bool[] booleans;
    int[] int32s;
    long[] int64s;
    float[] floats;
    double[] doubles;
    const(ubyte)[][] binaries;
}

private ColumnValues decodeChunk(ref const ColumnDescriptor col, CompressionCodec codec,
        const(ubyte)[] chunk, size_t rows, ref const ReaderOptions options) {
    ColumnValues result;
    result.type = col.type;
    result.nulls.reserve(rows);

    Values dict;
    size_t dictCount;
    bool haveDict, sawData;
    size_t pos, levelsRead;

    while (levelsRead < rows) {
        check(pos < chunk.length, "column chunk ended after " ~ levelsRead.to!string
            ~ " of " ~ rows.to!string ~ " values");
        size_t headerLen;
        const header = decodePageHeader(chunk[pos .. $], headerLen);
        pos += headerLen;
        check(header.compressedPageSize >= 0 && header.uncompressedPageSize >= 0,
            "negative page size");
        check(header.uncompressedPageSize <= options.maxPageBytes,
            "page size " ~ header.uncompressedPageSize.to!string
            ~ " exceeds ReaderOptions.maxPageBytes");
        check(cast(size_t) header.compressedPageSize <= chunk.length - pos,
            "page extends past the column chunk");
        const payload = chunk[pos .. pos + header.compressedPageSize];
        pos += header.compressedPageSize;
        const remaining = rows - levelsRead;

        switch (header.type) {
        case PageType.dictionaryPage: {
            check(header.hasDictionaryPageHeader, "dictionary page without its header");
            check(!haveDict && !sawData, "dictionary page after data or a second dictionary page");
            const dh = header.dictionaryPageHeader;
            check(dh.encoding == Encoding.plain || dh.encoding == Encoding.plainDictionary,
                "dictionary page encoding " ~ encodingName(dh.encoding) ~ " is not supported");
            // A chunk's dictionary cannot usefully hold more entries than the
            // chunk has values; this also bounds allocation for entries that
            // take no bytes (empty strings).
            check(dh.numValues >= 0 && dh.numValues <= rows,
                "dictionary size is negative or exceeds the column chunk's value count");
            const raw = decompress(codec, payload, header.uncompressedPageSize);
            decodePlain(dict, col, raw, dh.numValues);
            dictCount = dh.numValues;
            haveDict = true;
            break;
        }
        case PageType.dataPage: {
            check(header.hasDataPageHeader, "data page without its header");
            const dh = header.dataPageHeader;
            check(dh.numValues >= 0 && dh.numValues <= remaining,
                "data page value count exceeds the column chunk's remaining rows");
            const n = cast(size_t) dh.numValues;
            const raw = decompress(codec, payload, header.uncompressedPageSize);
            size_t p;
            uint[] defs;
            if (col.nullable) {
                check(dh.definitionLevelEncoding == Encoding.rle,
                    "definition level encoding " ~ encodingName(dh.definitionLevelEncoding)
                    ~ " is not supported");
                check(raw.length >= 4, "data page too short for its definition levels");
                const len = readLE!uint(raw, 0);
                check(len <= raw.length - 4, "definition levels extend past the page");
                defs = decodeRleBitPackedHybrid(raw[4 .. 4 + len], 1, n);
                p = 4 + len;
            }
            decodeDataValues(result, col, dh.encoding, raw[p .. $], n, defs,
                haveDict ? &dict : null, dictCount);
            levelsRead += n;
            sawData = true;
            break;
        }
        case PageType.dataPageV2: {
            check(header.hasDataPageHeaderV2, "v2 data page without its header");
            const h2 = header.dataPageHeaderV2;
            check(h2.numValues >= 0 && h2.numValues <= remaining,
                "data page value count exceeds the column chunk's remaining rows");
            check(h2.repetitionLevelsByteLength == 0,
                "repetition levels in a flat column");
            check(h2.definitionLevelsByteLength >= 0
                && cast(size_t) h2.definitionLevelsByteLength <= payload.length,
                "definition levels extend past the page");
            const defLen = cast(size_t) h2.definitionLevelsByteLength;
            check(cast(size_t) header.uncompressedPageSize >= defLen,
                "v2 page uncompressed size smaller than its levels");
            const n = cast(size_t) h2.numValues;
            uint[] defs;
            if (col.nullable) {
                defs = decodeRleBitPackedHybrid(payload[0 .. defLen], 1, n);
            } else {
                check(defLen == 0, "definition levels in a required column");
            }
            const body = payload[defLen .. $];
            const bodySize = header.uncompressedPageSize - defLen;
            const raw = h2.isCompressed
                ? decompress(codec, body, bodySize)
                : decompress(CompressionCodec.uncompressed, body, bodySize);
            decodeDataValues(result, col, h2.encoding, raw, n, defs,
                haveDict ? &dict : null, dictCount);
            levelsRead += n;
            sawData = true;
            break;
        }
        default:
            // Index pages (and page types added later) carry no row data.
            break;
        }
    }
    return result;
}

/// Decodes one data page's values and appends them (with nulls) to `result`.
private void decodeDataValues(ref ColumnValues result, ref const ColumnDescriptor col,
        Encoding encoding, const(ubyte)[] data, size_t n, const(uint)[] defs,
        const(Values)* dict, size_t dictCount) {
    size_t nonNull = n;
    if (defs !is null) {
        nonNull = 0;
        foreach (d; defs) nonNull += d; // bit width 1: levels are 0 or 1
    }

    Values page;
    switch (encoding) {
    case Encoding.plain:
        decodePlain(page, col, data, nonNull);
        break;
    case Encoding.plainDictionary:
    case Encoding.rleDictionary: {
        check(dict !is null, "dictionary-encoded page without a dictionary page");
        check(data.length >= 1 || nonNull == 0, "dictionary page data is missing its bit width");
        const indices = nonNull == 0 ? null
            : decodeRleBitPackedHybrid(data[1 .. $], checkedBitWidth(data[0]), nonNull);
        foreach (idx; indices)
            check(idx < dictCount, "dictionary index out of range");
        gather(page, col.type, *dict, indices);
        break;
    }
    case Encoding.rle: {
        check(col.type == PhysicalType.boolean, "RLE value encoding is only defined for booleans");
        check(data.length >= 4, "RLE boolean data is missing its length");
        const len = readLE!uint(data, 0);
        check(len <= data.length - 4, "RLE boolean data extends past the page");
        foreach (v; decodeRleBitPackedHybrid(data[4 .. 4 + len], 1, nonNull))
            page.booleans ~= v != 0;
        break;
    }
    default:
        throw new ParquetFormatException("value encoding " ~ encodingName(encoding)
            ~ " is not supported");
    }

    final switch (col.type) {
    case PhysicalType.boolean: scatter(result.booleans, page.booleans, defs); break;
    case PhysicalType.int32: scatter(result.int32s, page.int32s, defs); break;
    case PhysicalType.int64: scatter(result.int64s, page.int64s, defs); break;
    case PhysicalType.float_: scatter(result.floats, page.floats, defs); break;
    case PhysicalType.double_: scatter(result.doubles, page.doubles, defs); break;
    case PhysicalType.int96:
    case PhysicalType.byteArray:
    case PhysicalType.fixedLenByteArray:
        scatter(result.binaries, page.binaries, defs);
        break;
    }
    if (defs is null) {
        foreach (_; 0 .. n) result.nulls ~= false;
    } else {
        foreach (d; defs) result.nulls ~= d == 0;
    }
}

/// Appends `src` to `dst`, inserting `T.init` wherever the definition level
/// marks a null. `defs` null means every row is present.
private void scatter(T)(ref T[] dst, const(T)[] src, const(uint)[] defs) {
    if (defs is null) {
        dst ~= src;
        return;
    }
    size_t k;
    foreach (d; defs) {
        if (d) dst ~= src[k++];
        else dst ~= T.init;
    }
}

private void gather(ref Values page, PhysicalType type, ref const Values dict,
        const(uint)[] indices) {
    final switch (type) {
    case PhysicalType.boolean: foreach (i; indices) page.booleans ~= dict.booleans[i]; break;
    case PhysicalType.int32: foreach (i; indices) page.int32s ~= dict.int32s[i]; break;
    case PhysicalType.int64: foreach (i; indices) page.int64s ~= dict.int64s[i]; break;
    case PhysicalType.float_: foreach (i; indices) page.floats ~= dict.floats[i]; break;
    case PhysicalType.double_: foreach (i; indices) page.doubles ~= dict.doubles[i]; break;
    case PhysicalType.int96:
    case PhysicalType.byteArray:
    case PhysicalType.fixedLenByteArray:
        foreach (i; indices) page.binaries ~= dict.binaries[i];
        break;
    }
}

/// Decodes `count` PLAIN values of `col.type` from `data`.
private void decodePlain(ref Values v, ref const ColumnDescriptor col,
        const(ubyte)[] data, size_t count) {
    static void fixed(T)(ref T[] outArr, const(ubyte)[] data, size_t count) {
        check(count <= data.length / T.sizeof, "PLAIN values extend past the page");
        outArr.reserve(outArr.length + count);
        foreach (i; 0 .. count) outArr ~= readLE!T(data, i * T.sizeof);
    }

    final switch (col.type) {
    case PhysicalType.boolean:
        check(count <= data.length * 8, "PLAIN booleans extend past the page");
        v.booleans.reserve(v.booleans.length + count);
        foreach (i; 0 .. count) v.booleans ~= ((data[i >> 3] >> (i & 7)) & 1) != 0;
        break;
    case PhysicalType.int32: fixed(v.int32s, data, count); break;
    case PhysicalType.int64: fixed(v.int64s, data, count); break;
    case PhysicalType.float_: fixed(v.floats, data, count); break;
    case PhysicalType.double_: fixed(v.doubles, data, count); break;
    case PhysicalType.int96:
    case PhysicalType.fixedLenByteArray: {
        const width = cast(size_t) col.typeLength;
        check(width > 0 && count <= data.length / width, "PLAIN values extend past the page");
        v.binaries.reserve(v.binaries.length + count);
        foreach (i; 0 .. count) v.binaries ~= data[i * width .. (i + 1) * width];
        break;
    }
    case PhysicalType.byteArray: {
        size_t p;
        foreach (i; 0 .. count) {
            check(data.length - p >= 4, "PLAIN byte array length extends past the page");
            const len = readLE!uint(data, p);
            p += 4;
            check(len <= data.length - p, "PLAIN byte array extends past the page");
            v.binaries ~= data[p .. p + len];
            p += len;
        }
        break;
    }
    }
}

/// Decompresses one page body into a fresh buffer of exactly
/// `uncompressedSize` bytes (always a copy, never an alias of the input).
private const(ubyte)[] decompress(CompressionCodec codec, const(ubyte)[] src,
        long uncompressedSize) {
    check(uncompressedSize >= 0 && uncompressedSize <= int.max, "invalid uncompressed page size");
    const size = cast(size_t) uncompressedSize;
    switch (codec) {
    case CompressionCodec.uncompressed:
        check(src.length == size, "uncompressed page size disagrees with its data");
        return src.dup;
    case CompressionCodec.snappy:
        return snappyDecompress(src, size);
    case CompressionCodec.zstd:
        return zstdDecompress(src, size);
    case CompressionCodec.gzip:
        return gunzip(src, size);
    default:
        throw new ParquetFormatException("compression codec " ~ codecName(codec)
            ~ " is not supported");
    }
}

/// Inflates a gzip (RFC 1952) member into exactly `size` bytes with the
/// zlib that ships inside D's Phobos runtime.
private ubyte[] gunzip(const(ubyte)[] src, size_t size) {
    import etc.c.zlib;

    check(src.length <= uint.max, "gzip page too large");
    auto dst = new ubyte[size];
    z_stream z;
    check(inflateInit2(&z, 15 + 16) == Z_OK, "gzip: inflateInit2 failed");
    scope (exit) inflateEnd(&z);
    z.next_in = cast(ubyte*) src.ptr;
    z.avail_in = cast(uint) src.length;
    // One spare byte distinguishes "exactly size" from "more than size".
    ubyte spare;
    z.next_out = dst.ptr;
    z.avail_out = cast(uint) size;
    auto rc = inflate(&z, Z_FINISH);
    if (rc != Z_STREAM_END && z.avail_out == 0) {
        z.next_out = &spare;
        z.avail_out = 1;
        rc = inflate(&z, Z_FINISH);
    }
    check(rc == Z_STREAM_END, "gzip: corrupt or truncated stream");
    check(z.total_out == size, "gzip: decompressed size disagrees with the page header");
    return dst;
}

// ---------------------------------------------------------------------------
// RLE / bit-packing hybrid
// ---------------------------------------------------------------------------

/// Decodes exactly `count` values from the Parquet RLE/bit-packing hybrid
/// encoding (without a length prefix) at `bitWidth` (0..32) bits.
///
/// Each run starts with a ULEB128 header. Header bit 0 clear: an RLE run of
/// `header >> 1` copies of one value stored in `ceil(bitWidth / 8)`
/// little-endian bytes. Bit 0 set: `header >> 1` groups of 8 bit-packed
/// values, `bitWidth` bytes per group, packed LSB-first (value 0 starts at
/// bit 0 of byte 0; a value straddling a byte boundary continues in the low
/// bits of the next byte).
///
/// Robustness rules, for encoders other than this package's own:
/// - runs may end mid-way through the needed values (the next run
///   continues) and may produce more values than needed (the excess, e.g.
///   the zero padding of a final group, is ignored);
/// - a final bit-packed run may be shorter than its header claims as long
///   as every value actually needed is present (some writers truncate
///   trailing padding bytes);
/// - RLE values wider than `bitWidth`, headers over 32 bits, and running
///   out of input before `count` values are errors;
/// - bytes after the last needed value are ignored.
package(parquet) uint[] decodeRleBitPackedHybrid(const(ubyte)[] data, uint bitWidth,
        size_t count) {
    check(bitWidth <= 32, "hybrid bit width over 32");
    auto result = new uint[count];
    size_t filled, p;
    const valueBytes = (bitWidth + 7) / 8;
    const ulong mask = bitWidth == 32 ? uint.max : (1UL << bitWidth) - 1;

    while (filled < count) {
        // ULEB128 run header, at most 5 bytes / 32 bits.
        ulong header;
        uint shift;
        for (;;) {
            check(p < data.length, "hybrid data ended after " ~ filled.to!string
                ~ " of " ~ count.to!string ~ " values");
            check(shift < 35, "hybrid run header longer than 5 bytes");
            const b = data[p++];
            header |= cast(ulong)(b & 0x7f) << shift;
            shift += 7;
            if (!(b & 0x80)) break;
        }
        check(header <= uint.max, "hybrid run header exceeds 32 bits");
        const runLength = header >> 1;

        if ((header & 1) == 0) {
            check(data.length - p >= valueBytes, "hybrid RLE run value is truncated");
            ulong value;
            foreach (i; 0 .. valueBytes) value |= cast(ulong) data[p + i] << (8 * i);
            p += valueBytes;
            check(value <= mask, "hybrid RLE value exceeds the bit width");
            const take = runLength < count - filled ? cast(size_t) runLength : count - filled;
            result[filled .. filled + take] = cast(uint) value;
            filled += take;
        } else {
            const nValues = runLength * 8;                  // <= 2^34
            const nBytes = runLength * bitWidth;            // <= 2^36
            const avail = nBytes < data.length - p ? cast(size_t) nBytes : data.length - p;
            const want = nValues < count - filled ? cast(size_t) nValues : count - filled;
            if (bitWidth == 0) {
                result[filled .. filled + want] = 0;
            } else {
                check(want <= avail * 8 / bitWidth, "hybrid bit-packed run is truncated");
                const run = data[p .. p + avail];
                foreach (k; 0 .. want) {
                    const bit = cast(ulong) k * bitWidth;
                    const byteIdx = cast(size_t)(bit >> 3);
                    const off = cast(uint)(bit & 7);
                    // At most 5 bytes cover off (<= 7) + bitWidth (<= 32) bits.
                    ulong acc;
                    const last = byteIdx + 5 < run.length ? byteIdx + 5 : run.length;
                    foreach (j; byteIdx .. last) acc |= cast(ulong) run[j] << (8 * (j - byteIdx));
                    result[filled + k] = cast(uint)((acc >> off) & mask);
                }
            }
            filled += want;
            p += avail;
        }
    }
    return result;
}

private uint checkedBitWidth(ubyte width) {
    check(width <= 32, "dictionary index bit width over 32");
    return width;
}

private T readLE(T)(const(ubyte)[] data, size_t offset) {
    ubyte[T.sizeof] b = data[offset .. offset + T.sizeof];
    static if (is(T == float)) {
        const bits = littleEndianToNative!uint(b);
        return *cast(const(float)*) &bits;
    } else static if (is(T == double)) {
        const bits = littleEndianToNative!ulong(b);
        return *cast(const(double)*) &bits;
    } else {
        return littleEndianToNative!T(b);
    }
}

private string encodingName(Encoding e) {
    switch (e) {
    case Encoding.plain: return "PLAIN";
    case Encoding.plainDictionary: return "PLAIN_DICTIONARY";
    case Encoding.rle: return "RLE";
    case Encoding.bitPacked: return "BIT_PACKED";
    case Encoding.deltaBinaryPacked: return "DELTA_BINARY_PACKED";
    case Encoding.deltaLengthByteArray: return "DELTA_LENGTH_BYTE_ARRAY";
    case Encoding.deltaByteArray: return "DELTA_BYTE_ARRAY";
    case Encoding.rleDictionary: return "RLE_DICTIONARY";
    case Encoding.byteStreamSplit: return "BYTE_STREAM_SPLIT";
    default: return "#" ~ (cast(int) e).to!string;
    }
}

private string codecName(CompressionCodec c) {
    switch (c) {
    case CompressionCodec.uncompressed: return "UNCOMPRESSED";
    case CompressionCodec.snappy: return "SNAPPY";
    case CompressionCodec.gzip: return "GZIP";
    case CompressionCodec.lzo: return "LZO";
    case CompressionCodec.brotli: return "BROTLI";
    case CompressionCodec.lz4: return "LZ4";
    case CompressionCodec.zstd: return "ZSTD";
    case CompressionCodec.lz4Raw: return "LZ4_RAW";
    default: return "#" ~ (cast(int) c).to!string;
    }
}

// Hybrid decode: the Parquet encodings spec's bit-packing vector, RLE
// values wider than one byte, bit width 0, split runs, trailing padding,
// truncated final groups, and malformed headers.
unittest {
    import std.exception : assertThrown;

    // Spec example: 0..7 at width 3 is one group, bytes 88 C6 FA.
    assert(decodeRleBitPackedHybrid([0x03, 0x88, 0xC6, 0xFA], 3, 8) == [0, 1, 2, 3, 4, 5, 6, 7]);
    // Fewer values needed than the group holds: padding ignored.
    assert(decodeRleBitPackedHybrid([0x03, 0x88, 0xC6, 0xFA], 3, 5) == [0, 1, 2, 3, 4]);
    // Final group truncated after the needed bytes (5 values * 3 bits = 2 bytes).
    assert(decodeRleBitPackedHybrid([0x03, 0x88, 0xC6], 3, 5) == [0, 1, 2, 3, 4]);
    assertThrown!ParquetFormatException(decodeRleBitPackedHybrid([0x03, 0x88], 3, 5));
    // RLE value over two bytes (width 9): 3 x 0x0102, then a bit-packed group.
    assert(decodeRleBitPackedHybrid([0x06, 0x02, 0x01], 9, 3) == [0x102, 0x102, 0x102]);
    // RLE run longer than needed, and runs split across the requested count.
    assert(decodeRleBitPackedHybrid([0x14, 0x01], 1, 3) == [1, 1, 1]);
    assert(decodeRleBitPackedHybrid([0x04, 0x01, 0x04, 0x00, 0x03, 0x05], 1, 7)
        == [1, 1, 0, 0, 1, 0, 1]);
    // Bit width 0: RLE values take no bytes; everything is 0.
    assert(decodeRleBitPackedHybrid([0x08], 0, 4) == [0, 0, 0, 0]);
    assert(decodeRleBitPackedHybrid([0x03], 0, 8) == [0, 0, 0, 0, 0, 0, 0, 0]);
    // Width 32 values straddling byte boundaries.
    assert(decodeRleBitPackedHybrid([0x03, 0xff, 0xff, 0xff, 0xff, 0x01, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], 32, 2)
        == [uint.max, 1]);
    // Multi-byte ULEB128 header: 64 RLE values = header 128 = 0x80 0x01.
    assert(decodeRleBitPackedHybrid([0x80, 0x01, 0x01], 1, 64).length == 64);
    // Trailing bytes after the needed values are ignored.
    assert(decodeRleBitPackedHybrid([0x02, 0x01, 0xff, 0xff], 1, 1) == [1]);
    // Empty request reads nothing.
    assert(decodeRleBitPackedHybrid([], 5, 0) == []);

    alias E = ParquetFormatException;
    assertThrown!E(decodeRleBitPackedHybrid([], 1, 1));                  // no data
    assertThrown!E(decodeRleBitPackedHybrid([0x02], 1, 1));              // missing RLE value
    assertThrown!E(decodeRleBitPackedHybrid([0x02, 0x02], 1, 1));        // value too wide
    assertThrown!E(decodeRleBitPackedHybrid([0x80, 0x80, 0x80, 0x80, 0x80, 0x01], 1, 1)); // 6-byte header
    assertThrown!E(decodeRleBitPackedHybrid([0xff, 0xff, 0xff, 0xff, 0x7f, 0x01], 1, 1)); // > 32 bits
    assertThrown!E(decodeRleBitPackedHybrid([0x02, 0x01], 33, 1));       // width > 32
    // Zero-length runs cannot loop forever: each consumes its header.
    assertThrown!E(decodeRleBitPackedHybrid([0x00, 0x00, 0x01, 0x00], 1, 1));
}

// Randomized, against two independent encoders: the writer's own hybrid
// encoder, and a bit-by-bit encoder written here that mixes RLE runs,
// bit-packed runs of varying group counts, multi-byte headers, and
// truncated final groups -- choices this package's writer never makes.
unittest {
    import parquet.writer : encodeRleBitPackedHybrid;
    import std.random : Random, uniform;

    static void uleb(ref ubyte[] o, ulong v) {
        do { ubyte b = v & 0x7f; v >>= 7; if (v) b |= 0x80; o ~= b; } while (v);
    }

    static ubyte[] otherEncoder(const(uint)[] vals, uint width, ref Random rng) {
        ubyte[] o;
        size_t i;
        while (i < vals.length) {
            if (uniform(0, 2, rng) == 0) {
                // RLE run of the current value, possibly padded header width.
                size_t run = 1;
                while (i + run < vals.length && vals[i + run] == vals[i]) ++run;
                uleb(o, cast(ulong) run << 1);
                foreach (b; 0 .. (width + 7) / 8) o ~= cast(ubyte)(vals[i] >> (8 * b));
                i += run;
            } else {
                const groups = uniform(1, 20, rng);
                const take = groups * 8 < vals.length - i ? groups * 8 : vals.length - i;
                uleb(o, (cast(ulong)((take + 7) / 8) << 1) | 1);
                auto bytes = new ubyte[((take + 7) / 8) * width];
                foreach (k; 0 .. take)
                    foreach (bit; 0 .. width)
                        if ((vals[i + k] >> bit) & 1) {
                            const abs = k * width + bit;
                            bytes[abs / 8] |= cast(ubyte)(1 << (abs % 8));
                        }
                // Last run: optionally drop padding bytes past the last value.
                if (i + take == vals.length && uniform(0, 2, rng) == 0)
                    bytes = bytes[0 .. (take * width + 7) / 8];
                o ~= bytes;
                i += take;
            }
        }
        return o;
    }

    auto rng = Random(392);
    foreach (width; [0u, 1, 2, 3, 5, 7, 8, 9, 12, 16, 17, 24, 31, 32]) {
        foreach (trial; 0 .. 40) {
            uint[] vals;
            const n = uniform(0, 1200, rng);
            while (vals.length < n) {
                const v = width == 0 ? 0
                    : width == 32 ? uniform!uint(rng) : uniform(0u, 1u << width, rng);
                const rep = uniform(0, 3, rng) == 0 ? uniform(1, 40, rng) : 1;
                foreach (_; 0 .. rep) vals ~= v;
            }
            vals = vals[0 .. n];
            assert(decodeRleBitPackedHybrid(otherEncoder(vals, width, rng), width, n) == vals);
            if (width >= 1)
                assert(decodeRleBitPackedHybrid(encodeRleBitPackedHybrid(vals, width), width, n)
                    == vals);
        }
    }
}
