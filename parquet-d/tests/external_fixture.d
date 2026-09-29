/// Writes the Parquet files that `tests/external_verify.py` reads back with
/// real pyarrow and DuckDB, each next to a JSONL file holding the rows the
/// reader must return. Usage: `parquet-external-fixture <output-dir>`.
///
/// Every table is written twice, zstd and uncompressed, from the same rows.
module tests.external_fixture;

import parquet.writer;
import std.conv : to;
import std.file : mkdirRecurse, write;
import std.json : JSONValue;
import std.path : buildPath;
import std.stdio : writeln;

private struct Table {
    string name;
    ColumnSpec[] schema;
    ParquetValue[][] rows;
}

private JSONValue toJson(ref const ParquetValue v) {
    final switch (v.kind) {
    case ParquetValue.Kind.null_: return JSONValue(null);
    case ParquetValue.Kind.string_: return JSONValue(v.text);
    case ParquetValue.Kind.integer: return JSONValue(v.integer);
    case ParquetValue.Kind.real_: return JSONValue(v.real_);
    case ParquetValue.Kind.boolean: return JSONValue(v.boolean);
    }
}

/// The owner-required case: null vs "" vs non-empty strings, plus runs long
/// enough to force both RLE and bit-packed definition-level runs, and every
/// supported column type in both nullable and required form.
private Table mixedTable() {
    Table t;
    t.name = "mixed";
    t.schema = [
        ColumnSpec("id", ColumnType.int64, false),
        ColumnSpec("text", ColumnType.string_),
        ColumnSpec("label", ColumnType.string_, false),
        ColumnSpec("small", ColumnType.int32),
        ColumnSpec("score", ColumnType.double_),
        ColumnSpec("flag", ColumnType.boolean),
    ];
    // Hand-picked head: the exact null/empty/non-empty distinctions.
    string[] head = [null, "", "hello", "", null, "héllo wörld ✓", "a\x00b", ""];
    foreach (i; 0 .. 1037) {
        ParquetValue text;
        if (i < head.length)
            text = head[i] is null ? ParquetValue.null_ : ParquetValue(head[i]);
        else if (i >= 100 && i < 300)
            text = ParquetValue.null_;           // long null run -> RLE 0s
        else if (i >= 300 && i < 420)
            text = ParquetValue("");             // long empty run -> RLE 1s
        else if (i % 3 == 0)
            text = ParquetValue.null_;           // alternating -> bit-packed
        else if (i % 7 == 0)
            text = ParquetValue("");
        else
            text = ParquetValue("row " ~ i.to!string);
        auto small = i % 5 == 0 ? ParquetValue.null_ : ParquetValue(cast(int)(i * 1_000_003 % 2_000_000_007 - 1_000_000_000));
        auto score = i % 4 == 1 ? ParquetValue.null_ : ParquetValue(i * 0.25 - 17.5);
        auto flag = i % 6 == 2 ? ParquetValue.null_ : ParquetValue(i % 3 == 1);
        t.rows ~= [ParquetValue(cast(long) i * 4_000_000_007L), text,
            ParquetValue(i % 2 ? "odd" : ""), small, score, flag];
    }
    return t;
}

/// Zero rows: a schema-only file with empty column chunks.
private Table emptyTable() {
    Table t;
    t.name = "empty";
    t.schema = [ColumnSpec("text", ColumnType.string_), ColumnSpec("n", ColumnType.int64, false)];
    return t;
}

/// All-null nullable column (definition levels all 0, no values at all).
private Table allNullTable() {
    Table t;
    t.name = "all_null";
    t.schema = [ColumnSpec("text", ColumnType.string_)];
    foreach (i; 0 .. 50) t.rows ~= [ParquetValue.null_];
    return t;
}

void main(string[] args) {
    if (args.length != 2) throw new Exception("usage: parquet-external-fixture <output-dir>");
    const dir = args[1];
    mkdirRecurse(dir);
    foreach (table; [mixedTable(), emptyTable(), allNullTable()]) {
        string expected;
        foreach (row; table.rows) {
            JSONValue obj = JSONValue(string[string].init);
            foreach (i, ref col; table.schema) obj[col.name] = toJson(row[i]);
            expected ~= obj.toString ~ "\n";
        }
        write(buildPath(dir, table.name ~ ".expected.jsonl"), expected);
        foreach (c; [Compression.zstd, Compression.uncompressed]) {
            auto w = new ParquetWriter(table.schema, WriterOptions(c));
            foreach (row; table.rows) w.addRow(row);
            const path = buildPath(dir, table.name ~ "." ~ c.to!string ~ ".parquet");
            w.writeFile(path);
            writeln(path);
        }
    }
}
