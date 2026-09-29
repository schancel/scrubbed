/// D-side structural checks on whole files produced by `parquet.writer`.
/// These cover framing, footer bookkeeping and input validation; the proof
/// that the files are actually valid Parquet is the external pyarrow/DuckDB
/// read in `tests/external_verify.sh`, not these checks.
module tests.writer_checks;

import parquet.writer;
import parquet.reader : ParquetReader;
import std.bitmanip : littleEndianToNative;
import std.conv : to;
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
    auto zeroTarget = WriterOptions.init;
    zeroTarget.rowGroupTargetBytes = 0;
    assertThrown(new ParquetWriter([ColumnSpec("a", ColumnType.int64)], zeroTarget));
}

// A 300-byte filler so a handful of rows cross a small rowGroupTargetBytes.
private immutable string filler = {
    string s;
    foreach (i; 0 .. 300) s ~= cast(char)('a' + i % 26);
    return s;
}();

// #399: a small target byte size forces multiple row groups well below the
// writer's 128 MiB default, and every row still round-trips through
// parquet.reader correctly across the row-group boundaries.
unittest {
    auto opts = WriterOptions(Compression.uncompressed);
    opts.rowGroupTargetBytes = 4096; // deliberately tiny: see `filler`
    auto w = new ParquetWriter([
        ColumnSpec("id", ColumnType.int64, false),
        ColumnSpec("text", ColumnType.string_),
    ], opts);
    enum n = 2000;
    foreach (i; 0 .. n)
        w.addRow([ParquetValue(cast(long) i), ParquetValue("row-" ~ i.to!string ~ "-" ~ filler)]);
    assert(w.rowGroupCount > 1, "expected multiple row groups before finish()");
    const preFinishGroups = w.rowGroupCount;
    const file = w.finish();
    assert(w.rowGroupCount == preFinishGroups || w.rowGroupCount == preFinishGroups + 1);

    auto r = new ParquetReader(file);
    assert(r.numRowGroups > 1, "expected multiple row groups in the footer");
    assert(r.numRows == n);
    long seen;
    foreach (g; 0 .. r.numRowGroups) {
        auto cols = r.readRowGroup(g);
        const ids = cols[0];
        const texts = cols[1];
        assert(ids.length == texts.length);
        foreach (row; 0 .. ids.length) {
            assert(!ids.isNull(row) && ids.int64s[row] == seen,
                "row group " ~ g.to!string ~ " row " ~ row.to!string ~ ": id mismatch");
            assert(texts.text(row) == "row-" ~ seen.to!string ~ "-" ~ filler,
                "row group " ~ g.to!string ~ " row " ~ row.to!string ~ ": text mismatch");
            ++seen;
        }
    }
    assert(seen == n);
}

// #399: every row group's uncompressed size stays close to
// rowGroupTargetBytes regardless of total corpus size -- the structural
// proof that peak per-row-group buffering does not grow with the corpus.
// `RowGroup.totalByteSize` (page headers + uncompressed page bytes) is a
// direct proxy for what was buffered in `ColumnBuffer` just before the
// flush that produced it.
unittest {
    enum target = 4096;
    auto opts = WriterOptions(Compression.uncompressed);
    opts.rowGroupTargetBytes = target;
    auto w = new ParquetWriter([
        ColumnSpec("id", ColumnType.int64, false),
        ColumnSpec("text", ColumnType.string_),
    ], opts);
    foreach (i; 0 .. 5000)
        w.addRow([ParquetValue(cast(long) i), ParquetValue("row-" ~ i.to!string ~ "-" ~ filler)]);
    const file = w.finish();

    auto r = new ParquetReader(file);
    // 5000 rows at ~320 bytes/row against a 4 KiB target: dozens of row
    // groups, not one -- rules out a no-op flush trigger.
    assert(r.numRowGroups > 20, "expected many row groups, got " ~ r.numRowGroups.to!string);
    // One row's worth of overshoot (addRow flushes strictly after crossing
    // the target, so the triggering row is already buffered) plus small
    // per-column page-header overhead, generously bounded.
    foreach (g; 0 .. r.numRowGroups) {
        const size = r.metadata.rowGroups[g].totalByteSize;
        assert(size <= target + 2000,
            "row group " ~ g.to!string ~ " grew past the bound: " ~ size.to!string ~ " bytes");
    }
}

// Small input still produces exactly one row group: #399's flush trigger
// does not change behavior below its target (unaffected by the default
// 128 MiB target, and explicit here rather than only implied by the other
// single-row-group checks above still passing unmodified).
unittest {
    auto w = new ParquetWriter([ColumnSpec("id", ColumnType.int64, false)]);
    foreach (i; 0 .. 5) w.addRow([ParquetValue(cast(long) i)]);
    assert(w.rowGroupCount == 1);
    const file = w.finish();
    assert(w.rowGroupCount == 1);
    auto r = new ParquetReader(file);
    assert(r.numRowGroups == 1);
    assert(r.numRows == 5);
}

// A zero-row corpus still produces exactly one (empty) row group, matching
// the writer's pre-#399 behavior.
unittest {
    auto w = new ParquetWriter([ColumnSpec("id", ColumnType.int64, false)]);
    const file = w.finish();
    auto r = new ParquetReader(file);
    assert(r.numRowGroups == 1);
    assert(r.numRows == 0);
    assert(r.rowGroupNumRows(0) == 0);
}
