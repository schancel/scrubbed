/// D-side structural checks on whole files produced by `parquet.writer`.
/// These cover framing, footer bookkeeping and input validation; the proof
/// that the files are actually valid Parquet is the external pyarrow/DuckDB
/// read in `tests/external_verify.sh`, not these checks.
module tests.writer_checks;

import parquet.writer;
import std.bitmanip : littleEndianToNative;
import std.exception : assertThrown;

private uint footerLength(const(ubyte)[] file) {
    ubyte[4] b = file[$ - 8 .. $ - 4];
    return littleEndianToNative!uint(b);
}

private ubyte[] sample(Compression c) {
    auto w = new ParquetWriter([
        ColumnSpec("id", ColumnType.int64, false),
        ColumnSpec("text", ColumnType.string_),
    ], WriterOptions(c));
    w.addRow([ParquetValue(1L), ParquetValue("a")]);
    w.addRow([ParquetValue(2L), ParquetValue.null_]);
    w.addRow([ParquetValue(3L), ParquetValue("")]);
    return w.finish();
}

unittest {
    foreach (c; [Compression.uncompressed, Compression.zstd]) {
        const file = sample(c);
        assert(file[0 .. 4] == "PAR1" && file[$ - 4 .. $] == "PAR1");
        const len = footerLength(file);
        assert(len > 0 && 8 + len + 4 <= file.length);
        // First column chunk starts right after the leading magic: its page
        // header begins with field 1 (type, i32) = DATA_PAGE.
        assert(file[4 .. 6] == [0x15, 0x00]);
    }
}

// Uncompressed: the nullable string page body is exactly
// [len=4 LE][hybrid levels 1 0 1 -> one bit-packed group 0b101][PLAIN values].
unittest {
    const file = sample(Compression.uncompressed);
    const ubyte[] expectedBody = [
        2, 0, 0, 0, 0x03, 0x05,         // def levels: length 2, header 3, bits 101
        1, 0, 0, 0, 'a',                // "a"
        0, 0, 0, 0,                     // ""  (the null has no value)
    ];
    import std.algorithm.searching : canFind;
    assert((cast(const(ubyte)[]) file).canFind(expectedBody));
}

// Validation: wrong arity, wrong type, null in required column, bad UTF-8,
// int32 overflow; rejected rows leave the writer unchanged.
unittest {
    auto w = new ParquetWriter([
        ColumnSpec("n", ColumnType.int32, false),
        ColumnSpec("s", ColumnType.string_),
    ], WriterOptions(Compression.uncompressed));
    assertThrown(w.addRow([ParquetValue(1)]));
    assertThrown(w.addRow([ParquetValue("x"), ParquetValue("y")]));
    assertThrown(w.addRow([ParquetValue.null_, ParquetValue("y")]));
    assertThrown(w.addRow([ParquetValue(1), ParquetValue(cast(string) [cast(char) 0xff])]));
    assertThrown(w.addRow([ParquetValue(long(int.max) + 1), ParquetValue("y")]));
    assert(w.rowCount == 0);
    w.addRow([ParquetValue(1), ParquetValue.null_]);
    assert(w.rowCount == 1);
    w.finish();
    assertThrown(w.finish());
    assertThrown(w.addRow([ParquetValue(1), ParquetValue.null_]));
}

// Schema validation.
unittest {
    assertThrown(new ParquetWriter([]));
    assertThrown(new ParquetWriter([ColumnSpec("", ColumnType.int64)]));
    assertThrown(new ParquetWriter([ColumnSpec("a", ColumnType.int64),
        ColumnSpec("a", ColumnType.string_)]));
    assertThrown(new ParquetWriter([ColumnSpec("a", ColumnType.int64)],
        WriterOptions(Compression.zstd, 0)));
}
