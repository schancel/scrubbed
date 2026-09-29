/// #397: the reader must detect Parquet's modular-encryption markers and
/// reject them with a clear, explicit message -- never a silent misread of
/// encrypted bytes as plaintext, and never a generic/confusing low-level
/// parse error.
///
/// Real encrypted Parquet files are not needed for this: Parquet defines
/// two encryption modes, and both are detectable from framing/metadata
/// alone, without decrypting anything.
///
///  - "Encrypted footer" mode: the trailing magic is `PARE` instead of
///    `PAR1`. Already covered by `tests/reader_checks.d`'s framing-errors
///    unittest; not repeated here.
///  - "Plaintext footer" mode: the footer decodes normally, but
///    `FileMetaData.encryption_algorithm` (field 8) is set, and/or a
///    `ColumnChunk` carries `crypto_metadata` (field 8) or
///    `encrypted_column_metadata` (field 9). This module hand-crafts
///    minimal footers with those fields set, byte for byte, following the
///    same Thrift compact-protocol derivation `thrift_codec.d`'s own
///    hand-derived unittests use (field header byte = (idDelta << 4) |
///    compactType; struct/list bodies reset the delta baseline to 0;
///    zigzag(n) = 2n for the small non-negative values used here).
module tests.encryption_checks;

import parquet.exception : ParquetFormatException;
import parquet.reader;

/// Wraps a Thrift-encoded `FileMetaData` body in the `PAR1 ... len PAR1`
/// framing `ParquetReader` expects.
private ubyte[] frame(const ubyte[] footer) {
    import std.bitmanip : nativeToLittleEndian;

    ubyte[] file = cast(ubyte[]) "PAR1".dup;
    file ~= footer;
    file ~= nativeToLittleEndian(cast(uint) footer.length);
    file ~= cast(ubyte[]) "PAR1".dup;
    return file;
}

// FileMetaData.encryption_algorithm (field 8) set: "plaintext footer" mode.
// Minimal footer otherwise -- empty schema (root only, num_children = 0),
// no row groups -- so the only thing that can reject it is the new check.
unittest {
    const ubyte[] footer = [
        0x15, 0x00,                   // field 1 version (i32) = 0
        0x19, 0x1c,                   // field 2 schema: list<struct> size 1
        //   root SchemaElement: name (field 4) = "s", num_children (field 5) = 0
        0x48, 0x01, 's', 0x15, 0x00, 0x00,
        0x16, 0x00,                   // field 3 num_rows (i64) = 0
        0x19, 0x0c,                   // field 4 row_groups: list<struct> size 0
        0x4c, 0x00,                   // field 8 encryption_algorithm: empty struct
        0x00,                         // stop (FileMetaData)
    ];
    const file = frame(footer);

    bool threw;
    try {
        cast(void) new ParquetReader(file);
    } catch (ParquetFormatException e) {
        threw = true;
        assert(e.msg == "encrypted Parquet files are not supported", e.msg);
    }
    assert(threw, "encryption_algorithm marker was not rejected");
}

// ColumnChunk.crypto_metadata (field 8) set on the file's one column, with
// no file-level encryption_algorithm marker: a per-column key (Parquet
// column-key encryption). One real row group/column/ColumnMetaData, built
// the same way, so the rejection is proven against a chunk that otherwise
// looks like ordinary, valid metadata.
unittest {
    const ubyte[] footer = [
        0x15, 0x00,                   // field 1 version (i32) = 0
        0x19, 0x2c,                   // field 2 schema: list<struct> size 2
        //   root: name (field 4) = "s", num_children (field 5) = 1
        0x48, 0x01, 's', 0x15, 0x02, 0x00,
        //   leaf: type (field 1) = INT32, repetition_type (field 3) = REQUIRED,
        //   name (field 4) = "c"
        0x15, 0x02, 0x25, 0x00, 0x18, 0x01, 'c', 0x00,
        0x16, 0x00,                   // field 3 num_rows (i64) = 0
        0x19, 0x1c,                   // field 4 row_groups: list<struct> size 1
        //   RowGroup: columns (field 1) = list<struct> size 1
        0x19, 0x1c,
        //     ColumnChunk: file_offset (field 2) = 0
        0x26, 0x00,
        //     meta_data (field 3, struct):
        0x1c,
        //       ColumnMetaData: type (field 1) = INT32,
        //       encodings (field 2) = list<i32> size 0,
        //       path_in_schema (field 3) = list<string> size 1 ["c"],
        //       codec (field 4) = UNCOMPRESSED, num_values (field 5) = 0,
        //       total_compressed_size (field 7) = 0, data_page_offset (field 9) = 4
        0x15, 0x02,
        0x19, 0x05,
        0x19, 0x18, 0x01, 'c',
        0x15, 0x00,
        0x16, 0x00,
        0x26, 0x00,
        0x26, 0x08,
        0x00,                         // stop (ColumnMetaData)
        //     crypto_metadata (field 8, struct): empty -- THE MARKER
        0x5c, 0x00,
        0x00,                         // stop (ColumnChunk)
        //   RowGroup: num_rows (field 3) = 0
        0x26, 0x00,
        0x00,                         // stop (RowGroup)
        0x00,                         // stop (FileMetaData)
    ];
    const file = frame(footer);

    bool threw;
    try {
        cast(void) new ParquetReader(file);
    } catch (ParquetFormatException e) {
        threw = true;
        assert(e.msg == "row group 0 column 0: encrypted Parquet files are not supported", e.msg);
    }
    assert(threw, "crypto_metadata marker was not rejected");
}

// Same column-chunk footer, but without the crypto_metadata field (byte
// 0x5c, 0x00 removed and the delta on ColumnChunk's own stop adjusted
// accordingly): must parse cleanly. Proves the new check is specific to the
// encryption markers, not an accidental rejection of every ColumnChunk with
// a struct field after meta_data, and that ordinary metadata this shape
// still round-trips.
unittest {
    const ubyte[] footer = [
        0x15, 0x00,
        0x19, 0x2c,
        0x48, 0x01, 's', 0x15, 0x02, 0x00,
        0x15, 0x02, 0x25, 0x00, 0x18, 0x01, 'c', 0x00,
        0x16, 0x00,
        0x19, 0x1c,
        0x19, 0x1c,
        0x26, 0x00,
        0x1c,
        0x15, 0x02,
        0x19, 0x05,
        0x19, 0x18, 0x01, 'c',
        0x15, 0x00,
        0x16, 0x00,
        0x26, 0x00,
        0x26, 0x08,
        0x00,                         // stop (ColumnMetaData)
        0x00,                         // stop (ColumnChunk) -- no crypto_metadata this time
        0x26, 0x00,
        0x00,                         // stop (RowGroup)
        0x00,                         // stop (FileMetaData)
    ];
    const file = frame(footer);

    auto r = new ParquetReader(file);
    assert(r.numRows == 0 && r.numRowGroups == 1 && r.columns.length == 1);
    assert(r.columns[0].name == "c");
}
