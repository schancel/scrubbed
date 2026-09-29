/// Reader-side driver for `tests/external_verify.sh`.
///
///   parquet-reader-dump dump <in.parquet> <out.jsonl>
///     Reads every row group with `parquet.reader` and writes a canonical
///     dump for `tests/reader_verify.py` to compare against pyarrow:
///     line 1 is a JSON header (row count, per-row-group row counts, and the
///     column descriptors); every further line is one row, a JSON array
///     with one entry per column: `null`, or the physical value --
///     integers as JSON numbers, booleans as JSON booleans, and FLOAT /
///     DOUBLE / BYTE_ARRAY / FIXED_LEN_BYTE_ARRAY / INT96 as lowercase hex of
///     their exact little-endian bytes, so the comparison is byte-exact.
///     Exits 2 with the message on stderr if the reader rejects the file.
///
///   parquet-reader-dump digest <in.parquet> <out.txt>
///     As `dump`, but writes only the header line and then the lowercase
///     hex SHA-256 of all row lines (each followed by "\n"), for fixtures
///     too large to dump as text (pages over 256 MiB). An optional fourth
///     argument sets `ReaderOptions.maxPageBytes`, so a run can prove a
///     fixture really contains a page larger than that.
///
///   parquet-reader-dump fuzz <in.parquet> <iterations> <seed>
///     Mutates the file (byte flips, footer and page-header corruption,
///     truncation) and reads each variant fully. Any outcome other than a
///     clean decode or `ParquetFormatException` -- another exception, or a D
///     `Error` such as a bounds violation -- is reported and exits 1.
module tests.reader_dump;

import parquet.exception : ParquetFormatException;
import parquet.reader;
import parquet.thrift_codec : PhysicalType;

import std.array : Appender;
import std.conv : to;
import std.format : format;
import std.stdio : File, stderr, writeln;

int main(string[] args) {
    if (args.length == 4 && args[1] == "dump") return dump(args[2], args[3], false);
    if (args.length == 4 && args[1] == "digest") return dump(args[2], args[3], true);
    if (args.length == 5 && args[1] == "digest")
        return dump(args[2], args[3], true, args[4].to!long);
    if (args.length == 5 && args[1] == "fuzz")
        return fuzz(args[2], args[3].to!size_t, args[4].to!uint);
    stderr.writeln("usage: parquet-reader-dump dump|digest <in.parquet> <out>\n"
        ~ "       parquet-reader-dump fuzz <in.parquet> <iterations> <seed>");
    return 64;
}

private int dump(string input, string output, bool digestOnly,
        long maxPageBytes = ReaderOptions.init.maxPageBytes) {
    import std.digest.sha : SHA256, toHexString;
    import std.string : toLower;

    SHA256 sha;
    sha.start();
    ParquetReader r;
    ColumnValues[][] groups;
    try {
        ReaderOptions opts;
        opts.maxPageBytes = maxPageBytes;
        r = ParquetReader.open(input, opts);
        foreach (g; 0 .. r.numRowGroups) groups ~= r.readRowGroup(g);
    } catch (ParquetFormatException e) {
        stderr.writeln("parquet-reader-dump: ", input, ": ", e.msg);
        return 2;
    }

    auto f = File(output, "w");
    Appender!(char[]) line;
    line.put(`{"num_rows":`);
    line.put(r.numRows.to!string);
    line.put(`,"row_groups":[`);
    foreach (g; 0 .. r.numRowGroups) {
        if (g) line.put(",");
        line.put(r.rowGroupNumRows(g).to!string);
    }
    line.put(`],"columns":[`);
    foreach (i, ref c; r.columns) {
        if (i) line.put(",");
        line.put(format(`{"name":%s,"physical":"%s","nullable":%s,"string":%s,"type_length":%d}`,
            jsonString(c.name), physicalName(c.type), c.nullable, c.isString, c.typeLength));
    }
    line.put("]}");
    f.writeln(line.data);

    foreach (cols; groups) {
        const rows = cols.length ? cols[0].length : 0;
        foreach (row; 0 .. rows) {
            line.clear();
            line.put("[");
            foreach (ci, ref col; cols) {
                if (ci) line.put(",");
                if (col.isNull(row)) { line.put("null"); continue; }
                final switch (col.type) {
                case PhysicalType.boolean: line.put(col.booleans[row] ? "true" : "false"); break;
                case PhysicalType.int32: line.put(col.int32s[row].to!string); break;
                case PhysicalType.int64: line.put(col.int64s[row].to!string); break;
                case PhysicalType.float_: hex(line, (cast(const(ubyte)*) &col.floats[row])[0 .. 4]); break;
                case PhysicalType.double_: hex(line, (cast(const(ubyte)*) &col.doubles[row])[0 .. 8]); break;
                case PhysicalType.int96:
                case PhysicalType.byteArray:
                case PhysicalType.fixedLenByteArray:
                    hex(line, col.binaries[row]);
                    break;
                }
            }
            line.put("]\n");
            if (digestOnly) sha.put(cast(const(ubyte)[]) line.data);
            else f.write(line.data);
        }
    }
    if (digestOnly) f.writeln(toHexString(sha.finish()).idup.toLower);
    r.close();
    return 0;
}

version (LittleEndian) {} else static assert(0, "dump assumes a little-endian host");

private void hex(ref Appender!(char[]) sink, const(ubyte)[] bytes) {
    static immutable digits = "0123456789abcdef";
    sink.put('"');
    foreach (b; bytes) {
        sink.put(digits[b >> 4]);
        sink.put(digits[b & 15]);
    }
    sink.put('"');
}

private string jsonString(string s) {
    Appender!string o;
    o.put('"');
    foreach (char ch; s) {
        if (ch == '"' || ch == '\\') { o.put('\\'); o.put(ch); }
        else if (ch < 0x20) o.put(format(`\u%04x`, ch));
        else o.put(ch);
    }
    o.put('"');
    return o.data;
}

private string physicalName(PhysicalType t) {
    final switch (t) {
    case PhysicalType.boolean: return "BOOLEAN";
    case PhysicalType.int32: return "INT32";
    case PhysicalType.int64: return "INT64";
    case PhysicalType.int96: return "INT96";
    case PhysicalType.float_: return "FLOAT";
    case PhysicalType.double_: return "DOUBLE";
    case PhysicalType.byteArray: return "BYTE_ARRAY";
    case PhysicalType.fixedLenByteArray: return "FIXED_LEN_BYTE_ARRAY";
    }
}

private int fuzz(string input, size_t iterations, uint seed) {
    import std.file : read;
    import std.random : Random, uniform;

    const good = cast(const(ubyte)[]) read(input);
    auto rng = Random(seed);
    ReaderOptions opts;
    opts.maxRowGroupRows = 1 << 20;
    size_t decoded, rejected;
    foreach (iter; 0 .. iterations) {
        auto f = good.dup;
        const footerLen = f.length >= 8
            ? f[$ - 8] | (f[$ - 7] << 8) | (f[$ - 6] << 16) | (f[$ - 5] << 24) : 0;
        const footerStart = footerLen + 8 <= f.length ? f.length - 8 - footerLen : 0;
        switch (uniform(0, 5, rng)) {
        case 0: // flip bytes anywhere
            foreach (_; 0 .. uniform(1, 8, rng))
                f[uniform(0, f.length, rng)] ^= cast(ubyte) uniform(1, 256, rng);
            break;
        case 1: // corrupt the Thrift footer
            if (footerStart + 8 < f.length)
                foreach (_; 0 .. uniform(1, 6, rng))
                    f[uniform(footerStart, f.length - 8, rng)] = cast(ubyte) uniform(0, 256, rng);
            break;
        case 2: // corrupt the first page header / dictionary page
            foreach (_; 0 .. uniform(1, 6, rng))
                f[uniform(4, f.length < 64 ? f.length : 64, rng)] = cast(ubyte) uniform(0, 256, rng);
            break;
        case 3: // corrupt compressed page bytes in bulk
            {
                const at = uniform(4, footerStart > 5 ? footerStart : 5, rng);
                foreach (k; at .. (at + 32 < f.length ? at + 32 : f.length))
                    f[k] = cast(ubyte) uniform(0, 256, rng);
            }
            break;
        default: // truncate the data region, keep the footer
            if (footerStart > 4) {
                const cut = uniform(4, footerStart, rng);
                f = f[0 .. cut] ~ good[footerStart .. $];
            }
            break;
        }
        try {
            auto r = new ParquetReader(f, opts);
            foreach (g; 0 .. r.numRowGroups) r.readRowGroup(g);
            ++decoded;
        } catch (ParquetFormatException) {
            ++rejected;
        } catch (Throwable t) {
            stderr.writeln("parquet-reader-dump fuzz: iteration ", iter, " of ", input,
                " escaped as ", typeid(t).name, ": ", t.msg);
            return 1;
        }
    }
    writeln("fuzz ", input, ": ", iterations, " mutations, ", decoded, " decoded, ",
        rejected, " rejected with ParquetFormatException, 0 other failures");
    return 0;
}
