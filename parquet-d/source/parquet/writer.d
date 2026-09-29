/// Flat-schema, single-row-group Parquet writer.
///
/// File layout produced (Parquet format spec, "File Format"):
///
/// ```
/// "PAR1"
/// for each column: PageHeader (Thrift compact) + one data page (v1)
/// FileMetaData (Thrift compact)
/// footer length (4-byte little-endian)
/// "PAR1"
/// ```
///
/// Each column chunk is exactly one v1 data page. The page body is
/// `[definition levels][PLAIN values]`, compressed together as a unit when a
/// codec is selected. Nullable columns carry definition levels (max level 1,
/// bit width 1) in the RLE/bit-packing hybrid encoding, prefixed by their
/// 4-byte little-endian byte length; required columns carry none. A null and
/// an empty string are therefore distinct on the wire: a null is definition
/// level 0 with no value, an empty string is definition level 1 with a
/// zero-length `BYTE_ARRAY` value.
///
/// Footer offsets depend on final (compressed) page sizes, so rows are
/// buffered per column in memory until `finish`, which builds every column
/// chunk first and only then computes offsets and serializes the footer.
/// There is no streaming or multi-row-group mode: memory use is proportional
/// to the whole table.
module parquet.writer;

import parquet.thrift_codec;
import parquet.zstd_ffi : zstdCompress, minZstdLevel, maxZstdLevel;

import std.array : Appender;
import std.exception : enforce;

/// Logical column types this writer supports, and their Parquet mapping.
enum ColumnType {
    /// `BYTE_ARRAY` annotated `STRING` (UTF-8, validated on append).
    string_,
    /// `INT32`.
    int32,
    /// `INT64`.
    int64,
    /// `DOUBLE`.
    double_,
    /// `BOOLEAN`.
    boolean,
}

/// One flat (top-level, non-repeated) column.
struct ColumnSpec {
    string name;
    ColumnType type;
    /// `OPTIONAL` (nulls allowed, definition levels written) when true,
    /// `REQUIRED` otherwise.
    bool nullable = true;
}

/// Page compression.
enum Compression {
    uncompressed,
    zstd,
}

/// Writer options.
struct WriterOptions {
    Compression compression = Compression.zstd;
    /// zstd level, `minZstdLevel .. maxZstdLevel`; ignored when uncompressed.
    int zstdLevel = 3;
    /// Written to `FileMetaData.created_by`.
    string createdBy = "parquet-d";
}

/// A single cell value. Construct with `ParquetValue.null_`, or the
/// `string`/`long`/`double`/`bool` constructors.
struct ParquetValue {
    enum Kind { null_, string_, integer, real_, boolean }

    Kind kind = Kind.null_;
    string text;
    long integer;
    double real_;
    bool boolean;

    /// The null value.
    static ParquetValue null_() { return ParquetValue.init; }

    this(string v) { kind = Kind.string_; text = v; }
    this(int v) { kind = Kind.integer; integer = v; }
    /// ditto
    this(long v) { kind = Kind.integer; integer = v; }
    this(double v) { kind = Kind.real_; real_ = v; }
    this(bool v) { kind = Kind.boolean; boolean = v; }

    bool isNull() const { return kind == Kind.null_; }
}

/// Buffers rows for one row group and serializes a complete Parquet file.
final class ParquetWriter {
    private ColumnSpec[] columns_;
    private ColumnBuffer[] buffers_;
    private WriterOptions options_;
    private long rows_;
    private bool finished_;

    this(const ColumnSpec[] columns, WriterOptions options = WriterOptions.init) {
        enforce(columns.length > 0, "parquet schema needs at least one column");
        foreach (i, ref c; columns) {
            enforce(c.name.length > 0, "parquet column name must be non-empty");
            foreach (ref d; columns[0 .. i])
                enforce(d.name != c.name, "duplicate parquet column name: " ~ c.name);
        }
        if (options.compression == Compression.zstd)
            enforce(options.zstdLevel >= minZstdLevel && options.zstdLevel <= maxZstdLevel,
                "zstd level out of range");
        columns_ = columns.dup;
        buffers_ = new ColumnBuffer[columns.length];
        options_ = options;
    }

    /// Rows appended so far.
    long rowCount() const { return rows_; }

    /// Appends one row. The row is validated as a whole before any column is
    /// touched, so a rejected row leaves the writer unchanged.
    void addRow(const ParquetValue[] row) {
        enforce(!finished_, "parquet writer already finished");
        enforce(row.length == columns_.length, "parquet row has wrong column count");
        // A single data page's value count is a Thrift i32.
        enforce(rows_ < int.max, "parquet row group row limit reached");
        foreach (i, ref v; row) validate(columns_[i], v);
        foreach (i, ref v; row) buffers_[i].append(columns_[i].type, v);
        ++rows_;
    }

    /// Serializes the complete file. The writer cannot be used afterwards.
    ubyte[] finish() {
        enforce(!finished_, "parquet writer already finished");
        finished_ = true;

        static immutable ubyte[4] magic = ['P', 'A', 'R', '1'];
        Appender!(ubyte[]) file;
        file.put(magic[]);

        // Pass 1: build every column chunk (header + final page bytes) so
        // that all sizes are known. Pass 2: lay them out and record offsets.
        auto chunks = new ColumnChunk[columns_.length];
        long totalUncompressed, totalCompressed;
        foreach (i, ref col; columns_) {
            auto built = buildChunk(col, buffers_[i]);
            const offset = cast(long) file.data.length;
            file.put(built.bytes);

            ColumnMetaData meta;
            meta.type = physicalType(col.type);
            meta.encodings = col.nullable ? [Encoding.plain, Encoding.rle] : [Encoding.plain];
            meta.pathInSchema = [col.name];
            meta.codec = options_.compression == Compression.zstd
                ? CompressionCodec.zstd : CompressionCodec.uncompressed;
            meta.numValues = rows_;
            meta.totalUncompressedSize = built.uncompressedSize;
            meta.totalCompressedSize = built.bytes.length;
            meta.dataPageOffset = offset;
            chunks[i] = ColumnChunk(0, meta);
            totalUncompressed += built.uncompressedSize;
            totalCompressed += built.bytes.length;
        }
        buffers_ = null;

        FileMetaData meta;
        meta.version_ = 1;
        meta.schema = schemaElements();
        meta.numRows = rows_;
        RowGroup group;
        group.columns = chunks;
        group.totalByteSize = totalUncompressed;
        group.numRows = rows_;
        group.fileOffset = chunks[0].metaData.dataPageOffset;
        group.totalCompressedSize = totalCompressed;
        group.ordinal = 0;
        meta.rowGroups = [group];
        meta.createdBy = options_.createdBy;

        const footer = encodeFileMetaData(meta);
        enforce(footer.length <= uint.max, "parquet footer too large");
        file.put(footer);
        putLE!uint(file, cast(uint) footer.length);
        file.put(magic[]);
        return file.data;
    }

    /// `finish()` and write the result to `path`.
    void writeFile(string path) {
        import std.file : write;
        write(path, finish());
    }

    private SchemaElement[] schemaElements() const {
        auto elems = new SchemaElement[columns_.length + 1];
        elems[0].name = "schema";
        elems[0].hasNumChildren = true;
        elems[0].numChildren = cast(int) columns_.length;
        foreach (i, ref c; columns_) {
            auto e = &elems[i + 1];
            e.name = c.name;
            e.hasType = true;
            e.type = physicalType(c.type);
            e.hasRepetition = true;
            e.repetition = c.nullable ? Repetition.optional : Repetition.required;
            e.utf8String = c.type == ColumnType.string_;
        }
        return elems;
    }

    private static struct BuiltChunk {
        ubyte[] bytes;          // page header + (possibly compressed) page
        long uncompressedSize;  // page header + uncompressed page
    }

    private BuiltChunk buildChunk(ref const ColumnSpec col, ref ColumnBuffer buf) {
        Appender!(ubyte[]) page;
        if (col.nullable) {
            const levels = encodeRleBitPackedHybrid(buf.defLevels, 1);
            enforce(levels.length <= uint.max, "parquet definition levels too large");
            putLE!uint(page, cast(uint) levels.length);
            page.put(levels);
        }
        if (col.type == ColumnType.boolean)
            page.put(bitPack(buf.bools, 1));
        else
            page.put(buf.values.data);

        const raw = page.data;
        const body = options_.compression == Compression.zstd
            ? zstdCompress(raw, options_.zstdLevel) : raw;
        enforce(raw.length <= int.max && body.length <= int.max,
            "parquet data page exceeds the i32 page-size limit");

        PageHeader header;
        header.type = PageType.dataPage;
        header.uncompressedPageSize = cast(int) raw.length;
        header.compressedPageSize = cast(int) body.length;
        header.dataPageHeader = DataPageHeader(cast(int) rows_, Encoding.plain,
            Encoding.rle, Encoding.rle);
        auto headerBytes = encodePageHeader(header);
        return BuiltChunk(headerBytes ~ body, headerBytes.length + raw.length);
    }
}

private struct ColumnBuffer {
    uint[] defLevels;
    Appender!(ubyte[]) values;  // PLAIN bytes, all types except boolean
    uint[] bools;               // boolean values (0/1), bit-packed at finish

    void append(ColumnType type, ref const ParquetValue v) {
        defLevels ~= v.isNull ? 0 : 1;
        if (v.isNull) return;
        final switch (type) {
        case ColumnType.string_:
            enforce(v.text.length <= uint.max, "parquet string value too large");
            putLE!uint(values, cast(uint) v.text.length);
            values.put(cast(const(ubyte)[]) v.text);
            break;
        case ColumnType.int32:
            putLE!int(values, cast(int) v.integer);
            break;
        case ColumnType.int64:
            putLE!long(values, v.integer);
            break;
        case ColumnType.double_:
            putLE!ulong(values, *cast(const(ulong)*) &v.real_);
            break;
        case ColumnType.boolean:
            bools ~= v.boolean ? 1 : 0;
            break;
        }
    }
}

private void validate(ref const ColumnSpec col, ref const ParquetValue v) {
    import std.utf : validate;
    alias K = ParquetValue.Kind;
    if (v.isNull) {
        enforce(col.nullable, "null in required parquet column " ~ col.name);
        return;
    }
    final switch (col.type) {
    case ColumnType.string_:
        enforce(v.kind == K.string_, "parquet column " ~ col.name ~ " expects a string");
        validate(v.text);
        break;
    case ColumnType.int32:
        enforce(v.kind == K.integer && v.integer >= int.min && v.integer <= int.max,
            "parquet column " ~ col.name ~ " expects an int32");
        break;
    case ColumnType.int64:
        enforce(v.kind == K.integer, "parquet column " ~ col.name ~ " expects an int64");
        break;
    case ColumnType.double_:
        enforce(v.kind == K.real_, "parquet column " ~ col.name ~ " expects a double");
        break;
    case ColumnType.boolean:
        enforce(v.kind == K.boolean, "parquet column " ~ col.name ~ " expects a boolean");
        break;
    }
}

private PhysicalType physicalType(ColumnType t) {
    final switch (t) {
    case ColumnType.string_: return PhysicalType.byteArray;
    case ColumnType.int32: return PhysicalType.int32;
    case ColumnType.int64: return PhysicalType.int64;
    case ColumnType.double_: return PhysicalType.double_;
    case ColumnType.boolean: return PhysicalType.boolean;
    }
}

private void putLE(T, A)(ref A sink, T value) {
    import std.bitmanip : nativeToLittleEndian;
    sink.put(nativeToLittleEndian(value)[]);
}

private void putUleb128(ref Appender!(ubyte[]) sink, ulong v) {
    do {
        ubyte b = v & 0x7f;
        v >>= 7;
        if (v) b |= 0x80;
        sink.put(b);
    } while (v);
}

/// Packs `values` at `bitWidth` bits each, LSB-first: value 0 occupies the
/// lowest bits of byte 0, and a value straddling a byte boundary continues
/// in the low bits of the next byte (Parquet "bit-packed" encoding, as used
/// by the RLE/bit-packing hybrid and by PLAIN booleans). A trailing partial
/// byte is zero-padded.
package ubyte[] bitPack(const(uint)[] values, uint bitWidth) {
    assert(bitWidth >= 1 && bitWidth <= 32);
    auto outBytes = new ubyte[(values.length * bitWidth + 7) / 8];
    size_t pos;
    ulong acc;
    uint nbits;
    foreach (v; values) {
        assert(bitWidth == 32 || v < (1u << bitWidth), "value exceeds bit width");
        acc |= cast(ulong) v << nbits;
        nbits += bitWidth;
        while (nbits >= 8) {
            outBytes[pos++] = cast(ubyte) acc;
            acc >>= 8;
            nbits -= 8;
        }
    }
    if (nbits > 0) outBytes[pos++] = cast(ubyte) acc;
    assert(pos == outBytes.length);
    return outBytes;
}

/// Encodes `values` with the Parquet RLE/bit-packing hybrid (without the
/// 4-byte length prefix that data pages v1 put in front of it).
///
/// Runs of at least 8 equal values become RLE runs (header `count << 1`,
/// value in `ceil(bitWidth / 8)` little-endian bytes); everything else is
/// bit-packed in groups of 8 (header `groups << 1 | 1`). A bit-packed run
/// only ends on a group boundary, so a long run that starts mid-group first
/// tops the group up. The final group is zero-padded; readers stop at the
/// page's value count. Bit-packed runs are capped at 63 groups so every run
/// header is a single byte.
package ubyte[] encodeRleBitPackedHybrid(const(uint)[] values, uint bitWidth) {
    assert(bitWidth >= 1 && bitWidth <= 32);
    enum maxGroupsPerRun = 63;
    Appender!(ubyte[]) sink;
    uint[] pending;

    void flushPacked(bool final_) {
        while (pending.length >= 8 || (final_ && pending.length > 0)) {
            size_t take = pending.length / 8 * 8;
            if (take == 0) take = pending.length; // final partial group
            if (take > maxGroupsPerRun * 8) take = maxGroupsPerRun * 8;
            const groups = (take + 7) / 8;
            auto chunk = pending[0 .. take].dup;
            chunk.length = groups * 8; // zero-pad the final group
            putUleb128(sink, (cast(ulong) groups << 1) | 1);
            sink.put(bitPack(chunk, bitWidth));
            pending = pending[take .. $];
        }
    }

    size_t i;
    while (i < values.length) {
        size_t run = 1;
        while (i + run < values.length && values[i + run] == values[i]) ++run;
        if (run >= 8 && pending.length % 8 == 0) {
            flushPacked(false);
            putUleb128(sink, cast(ulong) run << 1);
            const width = (bitWidth + 7) / 8;
            foreach (b; 0 .. width) sink.put(cast(ubyte)(values[i] >> (8 * b)));
            i += run;
        } else if (run >= 8) {
            const k = 8 - pending.length % 8;
            pending ~= values[i .. i + k];
            i += k;
        } else {
            pending ~= values[i .. i + run];
            i += run;
        }
    }
    flushPacked(true);
    return sink.data;
}

// Known-answer vector from the Parquet encodings spec ("Bit-packed"): 0..7
// at bit width 3 is 10001000 11000110 11111010.
unittest {
    assert(bitPack([0, 1, 2, 3, 4, 5, 6, 7], 3) == [0x88, 0xC6, 0xFA]);
    // LSB-first single bits: first value is bit 0 of byte 0.
    assert(bitPack([1, 0, 0, 0, 0, 0, 0, 0, 1], 1) == [0x01, 0x01]);
    assert(bitPack([0, 1, 1, 0, 1, 0, 0, 1], 1) == [0x96]);
}

// Hybrid run selection and headers.
unittest {
    // 10 ones: a single RLE run, header 10 << 1 = 20, value in one byte.
    assert(encodeRleBitPackedHybrid([1, 1, 1, 1, 1, 1, 1, 1, 1, 1], 1) == [20, 1]);
    // Short mixed input: one bit-packed group (header 1 << 1 | 1), padded.
    assert(encodeRleBitPackedHybrid([1, 0, 1], 1) == [3, 0x05]);
    // Mixed prefix, then a long run: the prefix is topped up to 8 from the
    // run, then the remainder of the run is RLE.
    // values: 0 1 0 then 13 ones -> pending [0 1 0 1 1 1 1 1] (0xFA), RLE 8 ones.
    uint[] v = [0, 1, 0];
    foreach (_; 0 .. 13) v ~= 1;
    assert(encodeRleBitPackedHybrid(v, 1) == [3, 0xFA, 16, 1]);
    // Wider bit width RLE value is little-endian over ceil(w/8) bytes.
    uint[] w;
    foreach (_; 0 .. 9) w ~= 0x0102;
    assert(encodeRleBitPackedHybrid(w, 9) == [18, 0x02, 0x01]);
}

// Hybrid output decodes back to the input (independent reference decoder).
unittest {
    import std.random : Random, uniform;

    static uint[] decode(const(ubyte)[] data, uint bitWidth, size_t count) {
        uint[] result;
        size_t p;
        while (result.length < count) {
            ulong header; uint shift;
            for (;;) {
                const b = data[p++];
                header |= cast(ulong)(b & 0x7f) << shift;
                shift += 7;
                if (!(b & 0x80)) break;
            }
            if (header & 1) {
                const n = (header >> 1) * 8;
                foreach (k; 0 .. n) {
                    uint v;
                    foreach (bit; 0 .. bitWidth) {
                        const abs = k * bitWidth + bit;
                        v |= ((data[p + abs / 8] >> (abs % 8)) & 1) << bit;
                    }
                    if (result.length < count) result ~= v;
                }
                p += (header >> 1) * bitWidth;
            } else {
                uint v;
                foreach (b; 0 .. (bitWidth + 7) / 8) v |= data[p++] << (8 * b);
                foreach (k; 0 .. header >> 1) result ~= v;
            }
        }
        assert(p == data.length);
        return result;
    }

    auto rng = Random(391);
    foreach (width; [1u, 2, 3, 7, 8, 9, 13, 17]) {
        foreach (trial; 0 .. 50) {
            uint[] vals;
            const n = uniform(0, 1500, rng);
            while (vals.length < n) {
                const v = uniform(0u, 1u << width, rng);
                const rep = uniform(0, 3, rng) == 0 ? uniform(1, 40, rng) : 1;
                foreach (_; 0 .. rep) vals ~= v;
            }
            assert(decode(encodeRleBitPackedHybrid(vals, width), width, vals.length) == vals);
        }
    }
}
