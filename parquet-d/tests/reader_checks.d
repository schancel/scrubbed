/// D-side reader checks: round trips through this package's own writer, and
/// mutation fuzzing that proves malformed input surfaces only as
/// `ParquetFormatException`. The proof against externally produced files
/// (real Hugging Face corpora, pyarrow-written edge cases) is the pyarrow
/// comparison in `tests/external_verify.sh`, not these checks.
module tests.reader_checks;

import parquet.exception : ParquetFormatException;
import parquet.reader;
import parquet.thrift_codec : PhysicalType;
import parquet.writer;

private ParquetValue[][] sampleRows() {
    import std.conv : to;

    ParquetValue[][] rows;
    foreach (i; 0 .. 1037) {
        ParquetValue text = i % 7 == 0 ? ParquetValue.null_
            : i % 11 == 0 ? ParquetValue("")
            : ParquetValue("row " ~ i.to!string ~ " é中");
        // A long null run (200..299) crossing bit-packed/RLE boundaries.
        if (i >= 200 && i < 300) text = ParquetValue.null_;
        rows ~= [
            ParquetValue(cast(long) i),
            text,
            i % 3 == 0 ? ParquetValue.null_ : ParquetValue(cast(int)(i * 7 - 3000)),
            i % 5 == 0 ? ParquetValue.null_ : ParquetValue(i * 0.25 - 1.5),
            i % 4 == 0 ? ParquetValue.null_ : ParquetValue(i % 2 == 0),
        ];
    }
    return rows;
}

private ubyte[] sampleFile(Compression c) {
    auto w = new ParquetWriter([
        ColumnSpec("id", ColumnType.int64, false),
        ColumnSpec("text", ColumnType.string_),
        ColumnSpec("small", ColumnType.int32),
        ColumnSpec("score", ColumnType.double_),
        ColumnSpec("flag", ColumnType.boolean),
    ], WriterOptions(c));
    foreach (row; sampleRows()) w.addRow(row);
    return w.finish();
}

// Writer -> reader round trip, every value and null, both codecs.
unittest {
    const expected = sampleRows();
    foreach (c; [Compression.uncompressed, Compression.zstd]) {
        auto r = new ParquetReader(sampleFile(c));
        assert(r.numRows == expected.length && r.numRowGroups == 1);
        assert(r.columns.length == 5);
        assert(r.columns[0].name == "id" && !r.columns[0].nullable
            && r.columns[0].type == PhysicalType.int64);
        assert(r.columns[1].isString && r.columns[1].nullable);
        assert(r.columnIndex("flag") == 4 && r.columnIndex("nope") == size_t.max);
        auto cols = r.readRowGroup(0);
        foreach (i, row; expected) {
            assert(!cols[0].isNull(i) && cols[0].int64s[i] == row[0].integer);
            assert(cols[1].isNull(i) == row[1].isNull);
            if (!row[1].isNull) assert(cols[1].text(i) == row[1].text);
            assert(cols[2].isNull(i) == row[2].isNull);
            if (!row[2].isNull) assert(cols[2].int32s[i] == row[2].integer);
            assert(cols[3].isNull(i) == row[3].isNull);
            if (!row[3].isNull) assert(cols[3].doubles[i] == row[3].real_);
            assert(cols[4].isNull(i) == row[4].isNull);
            if (!row[4].isNull) assert(cols[4].booleans[i] == row[4].boolean);
        }
        // Null and empty string stay distinct.
        assert(cols[1].isNull(0) && !cols[1].isNull(11) && cols[1].text(11) == "");
    }
}

// Zero-row and all-null tables.
unittest {
    auto w = new ParquetWriter([ColumnSpec("s", ColumnType.string_)],
        WriterOptions(Compression.uncompressed));
    auto r = new ParquetReader(w.finish());
    assert(r.numRows == 0 && r.readColumn(0, 0).length == 0);

    w = new ParquetWriter([ColumnSpec("s", ColumnType.string_)]);
    foreach (_; 0 .. 50) w.addRow([ParquetValue.null_]);
    r = new ParquetReader(w.finish());
    const col = r.readColumn(0, 0);
    assert(col.length == 50);
    foreach (i; 0 .. 50) assert(col.isNull(i));
}

// Framing errors.
unittest {
    import std.exception : assertThrown;

    alias E = ParquetFormatException;
    auto good = sampleFile(Compression.uncompressed);
    assertThrown!E(new ParquetReader([]));
    assertThrown!E(new ParquetReader(cast(const(ubyte)[]) "PAR1PAR1"));
    auto bad = good.dup; bad[0] = 'X';
    assertThrown!E(new ParquetReader(bad));
    bad = good.dup; bad[$ - 1] = 'E';                       // "PARE": encrypted
    assertThrown!E(new ParquetReader(bad));
    bad = good.dup; bad[$ - 5] = 0x7f;                      // footer length > file
    assertThrown!E(new ParquetReader(bad));
    assertThrown!E(new ParquetReader(good[0 .. $ - 1]));
}

// Mutation fuzzing: byte flips, overwrites, and truncations of real
// writer output (uncompressed and zstd) either decode or raise
// ParquetFormatException -- never another exception, never an Error.
unittest {
    import std.random : Random, uniform;

    ReaderOptions opts;
    opts.maxRowGroupRows = 1 << 16;
    auto rng = Random(392);
    foreach (c; [Compression.uncompressed, Compression.zstd]) {
        const good = sampleFile(c);
        foreach (iter; 0 .. 3000) {
            auto f = good.dup;
            switch (uniform(0, 4, rng)) {
            case 0: // flip a few bytes anywhere
                foreach (_; 0 .. uniform(1, 4, rng))
                    f[uniform(0, f.length, rng)] ^= cast(ubyte) uniform(1, 256, rng);
                break;
            case 1: // corrupt the footer region specifically
                const footerStart = f.length > 400 ? f.length - 400 : 0;
                foreach (_; 0 .. uniform(1, 6, rng))
                    f[uniform(footerStart, f.length - 8, rng)] = cast(ubyte) uniform(0, 256, rng);
                break;
            case 2: // corrupt page headers / data near the start
                foreach (_; 0 .. uniform(1, 6, rng))
                    f[uniform(4, f.length < 200 ? f.length : 200, rng)] = cast(ubyte) uniform(0, 256, rng);
                break;
            default: // truncate, keeping a valid-looking tail
                const cut = uniform(0, f.length, rng);
                f = f[0 .. cut] ~ good[$ - 8 .. $];
                break;
            }
            try {
                auto r = new ParquetReader(f, opts);
                foreach (g; 0 .. r.numRowGroups) r.readRowGroup(g);
            } catch (ParquetFormatException) {
                // expected for most mutations
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Crafted hostile files (review findings on PR #394). Built directly with the
// vendored TCompactProtocol, since the package's encoder never emits the
// fields involved (type_length, dictionary page headers).
// ---------------------------------------------------------------------------

private struct Crafted {
    import thrift.protocol.base : TField, TList, TStruct, TType;
    import thrift.protocol.compact : TCompactProtocol;
    import thrift.transport.memory : TMemoryBuffer;

    TMemoryBuffer buf;
    TCompactProtocol!TMemoryBuffer p;

    static Crafted make() {
        Crafted c;
        c.buf = new TMemoryBuffer;
        c.p = new TCompactProtocol!TMemoryBuffer(c.buf);
        return c;
    }

    ubyte[] bytes() { return buf.getContents().dup; }
    void begin() { p.writeStructBegin(TStruct("s")); }
    void end() { p.writeFieldStop(); p.writeStructEnd(); }
    void field(short id, TType t) { p.writeFieldBegin(TField("f", t, id)); }
    void i32(short id, int v) { field(id, TType.I32); p.writeI32(v); p.writeFieldEnd(); }
    void i64(short id, long v) { field(id, TType.I64); p.writeI64(v); p.writeFieldEnd(); }
    void str(short id, string v) { field(id, TType.STRING); p.writeString(v); p.writeFieldEnd(); }
    void list(short id, TType elem, size_t n) { field(id, TType.LIST); p.writeListBegin(TList(elem, n)); }
    void listEnd() { p.writeListEnd(); p.writeFieldEnd(); }
    void structField(short id) { field(id, TType.STRUCT); begin(); }
    void structFieldEnd() { end(); p.writeFieldEnd(); }
}

/// `craftFile` typeLength value meaning "omit the type_length field".
private enum omitTypeLength = int.min;

/// One-column, one-row-group file: "PAR1" + `pages` + footer. When
/// `dictionaryBytes > 0`, the first that many bytes of `pages` are a
/// dictionary page and the data page follows.
private ubyte[] craftFile(int physicalType, int typeLength, int codec, long rows,
        const(ubyte)[] pages, size_t dictionaryBytes) {
    import std.bitmanip : nativeToLittleEndian;
    import thrift.protocol.base : TType;

    auto c = Crafted.make();
    c.begin();
    c.i32(1, 1);                                    // version
    c.list(2, TType.STRUCT, 2);                     // schema
    c.begin(); c.str(4, "schema"); c.i32(5, 1); c.end();
    c.begin();
    c.i32(1, physicalType);
    if (typeLength != omitTypeLength) c.i32(2, typeLength);
    c.i32(3, 0);                                    // REQUIRED
    c.str(4, "f");
    c.end();
    c.listEnd();
    c.i64(3, rows);                                 // num_rows
    c.list(4, TType.STRUCT, 1);                     // row_groups
    c.begin();
    c.list(1, TType.STRUCT, 1);                     // columns
    c.begin();
    c.i64(2, 0);
    c.structField(3);                               // meta_data
    c.i32(1, physicalType);
    c.list(2, TType.I32, 1); c.p.writeI32(0); c.listEnd();
    c.list(3, TType.STRING, 1); c.p.writeString("f"); c.listEnd();
    c.i32(4, codec);
    c.i64(5, rows);
    c.i64(6, pages.length);
    c.i64(7, pages.length);
    c.i64(9, 4 + dictionaryBytes);                  // data_page_offset
    if (dictionaryBytes) c.i64(11, 4);              // dictionary_page_offset
    c.structFieldEnd();
    c.end();
    c.listEnd();
    c.i64(3, rows);
    c.end();
    c.listEnd();
    c.end();
    const footer = c.bytes();
    return cast(ubyte[]) "PAR1" ~ pages ~ footer
        ~ nativeToLittleEndian(cast(uint) footer.length)[] ~ cast(ubyte[]) "PAR1";
}

/// Page header bytes; `dictionaryValues >= 0` makes it a dictionary page,
/// otherwise a v1 data page of `dataValues` values in `encoding`.
private ubyte[] craftPageHeader(int uncompressed, int compressed, int dictionaryValues,
        int dataValues = 1, int encoding = 0) {
    auto c = Crafted.make();
    c.begin();
    c.i32(1, dictionaryValues >= 0 ? 2 : 0);
    c.i32(2, uncompressed);
    c.i32(3, compressed);
    if (dictionaryValues >= 0) {
        c.structField(7);
        c.i32(1, dictionaryValues);
        c.i32(2, 0);                                // PLAIN
        c.structFieldEnd();
    } else {
        c.structField(5);
        c.i32(1, dataValues); c.i32(2, encoding); c.i32(3, 3); c.i32(4, 3);
        c.structFieldEnd();
    }
    c.end();
    return c.bytes();
}

private string rejection(const(ubyte)[] file) {
    try {
        auto r = new ParquetReader(file);
        foreach (g; 0 .. r.numRowGroups) r.readRowGroup(g);
    } catch (ParquetFormatException e) {
        return e.msg;
    }
    return null;
}

/// GC heap growth while running `dg`, in bytes.
private size_t heapGrowth(scope void delegate() dg) {
    import core.memory : GC;
    GC.collect();
    const before = GC.stats().usedSize;
    dg();
    const after = GC.stats().usedSize;
    return after > before ? after - before : 0;
}

// F1: FIXED_LEN_BYTE_ARRAY with type_length 0, negative (emitted
// explicitly on the wire), or missing is rejected at footer parse, before a
// dictionary page can claim ~int.max zero-width entries.
unittest {
    import std.algorithm.searching : canFind;

    enum flba = 7;
    auto dict = craftPageHeader(0, 0, int.max);
    foreach (len; [0, -1, -5, omitTypeLength]) {
        const msg = rejection(craftFile(flba, len, 0, 1, dict, dict.length));
        assert(msg !is null && msg.canFind("type_length"), msg);
    }
    // A valid width still reads.
    auto page = craftPageHeader(4, 4, -1) ~ cast(ubyte[]) "abcd";
    auto r = new ParquetReader(craftFile(flba, 4, 0, 1, page, 0));
    assert(r.readColumn(0, 0).binaries == [cast(const(ubyte)[]) "abcd"]);
}

// Dictionary pages may hold more entries than the chunk has values
// (parquet-cpp writes a DictionaryArray's whole dictionary into every chunk).
// Positive: a 5-entry INT64 dictionary in a 1-row chunk reads entry 4.
// Bounded: a dictionary claiming 64M zero-cost-looking empty strings in a
// 16-byte page fails after decoding the 4 entries its bytes can hold.
unittest {
    enum int64 = 2, byteArray = 6, rleDictionary = 8;
    ubyte[] entries;
    foreach (long v; [10, 20, 30, 40, 50])
        foreach (b; 0 .. 8) entries ~= cast(ubyte)(v >> (8 * b));
    auto dict = craftPageHeader(40, 40, 5) ~ entries;
    // bit width 3, one RLE run of 1 x index 4: header 1 << 1, value byte 4
    const ubyte[] data = [3, 0x02, 0x04];
    auto page = craftPageHeader(3, 3, -1, 1, rleDictionary) ~ data;
    auto r = new ParquetReader(craftFile(int64, omitTypeLength, 0, 1, dict ~ page, dict.length));
    assert(r.readColumn(0, 0).int64s == [50]);

    auto forged = craftPageHeader(16, 16, 64 << 20) ~ new ubyte[16];
    string msg;
    const grew = heapGrowth({
        msg = rejection(craftFile(byteArray, omitTypeLength, 0, 1, forged, forged.length));
    });
    assert(msg !is null, "forged dictionary accepted");
    assert(grew < 16 << 20, "forged dictionary allocated in proportion to its claim");
}

// Forged uncompressed page sizes are refused by each codec's own bound
// before the output buffer is allocated (no absolute page-size cap).
unittest {
    enum int64 = 2, snappy = 1, gzip = 2, zstd = 6;
    foreach (codec; [snappy, gzip, zstd]) {
        auto page = craftPageHeader(1 << 30, 8, -1) ~ new ubyte[8];
        string msg;
        const grew = heapGrowth({
            msg = rejection(craftFile(int64, omitTypeLength, codec, 1, page, 0));
        });
        assert(msg !is null, "forged page size accepted");
        assert(grew < 64 << 20, "page buffer allocated for a forged size");
    }
    // The opt-in ceiling still applies when set.
    import std.algorithm.searching : canFind;
    import std.exception : collectExceptionMsg;
    ReaderOptions opts;
    opts.maxPageBytes = 4;
    auto page = craftPageHeader(8, 8, -1) ~ new ubyte[8];
    auto r = new ParquetReader(craftFile(int64, omitTypeLength, 0, 1, page, 0), opts);
    assert(collectExceptionMsg!ParquetFormatException(r.readColumn(0, 0)).canFind("maxPageBytes"));
}
