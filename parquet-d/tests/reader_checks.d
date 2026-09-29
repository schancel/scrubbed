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
