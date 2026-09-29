/// Thrift compact-protocol encoding of the Parquet metadata structs this
/// package writes, on top of the vendored Apache Thrift `TCompactProtocol`
/// (`third_party/thrift`, v0.24.0 -- see its README for provenance).
///
/// This is deliberately not a general Thrift layer: it mirrors only the
/// subset of `parquet.thrift` (apache/parquet-format) that a flat,
/// single-row-group, PLAIN-encoded, statistics-free writer needs --
/// `FileMetaData`, `SchemaElement`, `RowGroup`, `ColumnChunk`,
/// `ColumnMetaData`, `PageHeader` and `DataPageHeader`. Field ids and enum
/// values below are the ones `parquet.thrift` assigns; every optional field
/// this package never sets is simply omitted from the wire encoding, which
/// is exactly what the compact protocol's field-delta scheme permits.
///
/// The vendored protocol does all byte-level work (field headers with delta
/// ids, zigzag varints, list headers, length-prefixed binary); this module
/// only decides which fields go in which order.
module parquet.thrift_codec;

import thrift.protocol.base : TField, TList, TStruct, TType;
import thrift.protocol.compact : TCompactProtocol;
import thrift.transport.memory : TMemoryBuffer;

/// `parquet.thrift` `Type` (physical type).
enum PhysicalType : int {
    boolean = 0,
    int32 = 1,
    int64 = 2,
    int96 = 3,
    float_ = 4,
    double_ = 5,
    byteArray = 6,
    fixedLenByteArray = 7,
}

/// `parquet.thrift` `FieldRepetitionType`.
enum Repetition : int {
    required = 0,
    optional = 1,
    repeated = 2,
}

/// `parquet.thrift` `ConvertedType` (only the value this package emits).
enum ConvertedType : int {
    utf8 = 0,
}

/// `parquet.thrift` `Encoding` (only the values this package emits).
enum Encoding : int {
    plain = 0,
    rle = 3,
}

/// `parquet.thrift` `CompressionCodec` (only the values this package emits).
enum CompressionCodec : int {
    uncompressed = 0,
    zstd = 6,
}

/// `parquet.thrift` `PageType` (only the value this package emits).
enum PageType : int {
    dataPage = 0,
}

/// `parquet.thrift` `SchemaElement` subset. The root element carries
/// `numChildren` and no type; leaf elements carry a type and repetition.
struct SchemaElement {
    string name;
    bool hasType;
    PhysicalType type;
    bool hasRepetition;
    Repetition repetition;
    bool hasNumChildren;
    int numChildren;
    /// When set, emits both `converted_type = UTF8` and
    /// `logicalType = STRING` so old and new readers agree on UTF-8 strings.
    bool utf8String;
}

/// `parquet.thrift` `ColumnMetaData` subset (no statistics, no dictionary).
struct ColumnMetaData {
    PhysicalType type;
    Encoding[] encodings;
    string[] pathInSchema;
    CompressionCodec codec;
    long numValues;
    long totalUncompressedSize;
    long totalCompressedSize;
    long dataPageOffset;
}

/// `parquet.thrift` `ColumnChunk` subset: metadata always inline in the
/// footer, never in a separate file.
struct ColumnChunk {
    /// Deprecated upstream; `parquet.thrift` says writers should set 0 when no
    /// ColumnMetaData is written outside the footer, which is always the case
    /// here.
    long fileOffset;
    ColumnMetaData metaData;
}

/// `parquet.thrift` `RowGroup` subset.
struct RowGroup {
    ColumnChunk[] columns;
    long totalByteSize;
    long numRows;
    long fileOffset;
    long totalCompressedSize;
    short ordinal;
}

/// `parquet.thrift` `FileMetaData` subset.
struct FileMetaData {
    int version_;
    SchemaElement[] schema;
    long numRows;
    RowGroup[] rowGroups;
    string createdBy;
}

/// `parquet.thrift` `DataPageHeader` subset (no statistics).
struct DataPageHeader {
    int numValues;
    Encoding encoding;
    Encoding definitionLevelEncoding;
    Encoding repetitionLevelEncoding;
}

/// `parquet.thrift` `PageHeader` subset (data pages only, no CRC).
struct PageHeader {
    PageType type;
    int uncompressedPageSize;
    int compressedPageSize;
    DataPageHeader dataPageHeader;
}

/// Encodes `meta` as a Thrift compact-protocol struct (the Parquet footer
/// body, without the trailing length or magic).
ubyte[] encodeFileMetaData(ref const FileMetaData meta) {
    auto enc = Encoder.make();
    enc.fileMetaData(meta);
    return enc.finish();
}

/// Encodes a data-page header as a Thrift compact-protocol struct.
ubyte[] encodePageHeader(ref const PageHeader header) {
    auto enc = Encoder.make();
    enc.pageHeader(header);
    return enc.finish();
}

private struct Encoder {
    TMemoryBuffer buffer;
    TCompactProtocol!TMemoryBuffer proto;

    static Encoder make() {
        Encoder e;
        e.buffer = new TMemoryBuffer;
        e.proto = new TCompactProtocol!TMemoryBuffer(e.buffer);
        return e;
    }

    ubyte[] finish() {
        // getContents() aliases the transport's malloc'd buffer, which the
        // transport frees in its destructor: copy before letting it go.
        return buffer.getContents().dup;
    }

    // Field names are passed only because the vendored protocol keys its
    // pending-bool-field state on a non-null name; they never reach the wire.
    void begin(string name) { proto.writeStructBegin(TStruct(name)); }
    void end() { proto.writeFieldStop(); proto.writeStructEnd(); }
    void field(string name, TType type, short id) {
        proto.writeFieldBegin(TField(name, type, id));
    }

    void i32Field(string name, short id, int value) {
        field(name, TType.I32, id);
        proto.writeI32(value);
        proto.writeFieldEnd();
    }

    void i64Field(string name, short id, long value) {
        field(name, TType.I64, id);
        proto.writeI64(value);
        proto.writeFieldEnd();
    }

    void i16Field(string name, short id, short value) {
        field(name, TType.I16, id);
        proto.writeI16(value);
        proto.writeFieldEnd();
    }

    void stringField(string name, short id, string value) {
        field(name, TType.STRING, id);
        proto.writeString(value);
        proto.writeFieldEnd();
    }

    void listBegin(string name, short id, TType elemType, size_t size) {
        field(name, TType.LIST, id);
        proto.writeListBegin(TList(elemType, size));
    }

    void listEnd() {
        proto.writeListEnd();
        proto.writeFieldEnd();
    }

    void fileMetaData(ref const FileMetaData m) {
        begin("FileMetaData");
        i32Field("version", 1, m.version_);
        listBegin("schema", 2, TType.STRUCT, m.schema.length);
        foreach (ref const s; m.schema) schemaElement(s);
        listEnd();
        i64Field("num_rows", 3, m.numRows);
        listBegin("row_groups", 4, TType.STRUCT, m.rowGroups.length);
        foreach (ref const g; m.rowGroups) rowGroup(g);
        listEnd();
        if (m.createdBy !is null) stringField("created_by", 6, m.createdBy);
        end();
    }

    void schemaElement(ref const SchemaElement s) {
        begin("SchemaElement");
        if (s.hasType) i32Field("type", 1, s.type);
        if (s.hasRepetition) i32Field("repetition_type", 3, s.repetition);
        stringField("name", 4, s.name);
        if (s.hasNumChildren) i32Field("num_children", 5, s.numChildren);
        if (s.utf8String) {
            i32Field("converted_type", 6, ConvertedType.utf8);
            // logicalType (10) is the LogicalType union; its STRING member is
            // field 1, an empty StringType struct.
            field("logicalType", TType.STRUCT, 10);
            begin("LogicalType");
            field("STRING", TType.STRUCT, 1);
            begin("StringType");
            end();
            proto.writeFieldEnd();
            end();
            proto.writeFieldEnd();
        }
        end();
    }

    void rowGroup(ref const RowGroup g) {
        begin("RowGroup");
        listBegin("columns", 1, TType.STRUCT, g.columns.length);
        foreach (ref const c; g.columns) columnChunk(c);
        listEnd();
        i64Field("total_byte_size", 2, g.totalByteSize);
        i64Field("num_rows", 3, g.numRows);
        i64Field("file_offset", 5, g.fileOffset);
        i64Field("total_compressed_size", 6, g.totalCompressedSize);
        i16Field("ordinal", 7, g.ordinal);
        end();
    }

    void columnChunk(ref const ColumnChunk c) {
        begin("ColumnChunk");
        i64Field("file_offset", 2, c.fileOffset);
        field("meta_data", TType.STRUCT, 3);
        columnMetaData(c.metaData);
        proto.writeFieldEnd();
        end();
    }

    void columnMetaData(ref const ColumnMetaData m) {
        begin("ColumnMetaData");
        i32Field("type", 1, m.type);
        listBegin("encodings", 2, TType.I32, m.encodings.length);
        foreach (e; m.encodings) proto.writeI32(e);
        listEnd();
        listBegin("path_in_schema", 3, TType.STRING, m.pathInSchema.length);
        foreach (p; m.pathInSchema) proto.writeString(p);
        listEnd();
        i32Field("codec", 4, m.codec);
        i64Field("num_values", 5, m.numValues);
        i64Field("total_uncompressed_size", 6, m.totalUncompressedSize);
        i64Field("total_compressed_size", 7, m.totalCompressedSize);
        i64Field("data_page_offset", 9, m.dataPageOffset);
        end();
    }

    void pageHeader(ref const PageHeader h) {
        begin("PageHeader");
        i32Field("type", 1, h.type);
        i32Field("uncompressed_page_size", 2, h.uncompressedPageSize);
        i32Field("compressed_page_size", 3, h.compressedPageSize);
        field("data_page_header", TType.STRUCT, 5);
        begin("DataPageHeader");
        i32Field("num_values", 1, h.dataPageHeader.numValues);
        i32Field("encoding", 2, h.dataPageHeader.encoding);
        i32Field("definition_level_encoding", 3, h.dataPageHeader.definitionLevelEncoding);
        i32Field("repetition_level_encoding", 4, h.dataPageHeader.repetitionLevelEncoding);
        end();
        proto.writeFieldEnd();
        end();
    }
}

// Hand-derived compact-protocol bytes for a DataPageHeader-bearing
// PageHeader, independent of the vendored encoder: field header byte is
// (delta << 4) | ctype, i32 is zigzag varint (ctype 5), struct is ctype 12,
// stop is 0.
unittest {
    PageHeader h;
    h.type = PageType.dataPage;
    h.uncompressedPageSize = 100;   // zigzag 200 -> varint c8 01
    h.compressedPageSize = 3;       // zigzag 6
    h.dataPageHeader = DataPageHeader(5, Encoding.plain, Encoding.rle, Encoding.rle);
    const bytes = encodePageHeader(h);
    const ubyte[] expected = [
        0x15, 0x00,             // field 1 (i32) = 0
        0x15, 0xc8, 0x01,       // field 2 (i32) = 100
        0x15, 0x06,             // field 3 (i32) = 3
        0x2c,                   // field 5 (delta 2, struct)
        0x15, 0x0a,             //   field 1 (i32) = 5
        0x15, 0x00,             //   field 2 (i32) = PLAIN
        0x15, 0x06,             //   field 3 (i32) = RLE
        0x15, 0x06,             //   field 4 (i32) = RLE
        0x00,                   //   stop (DataPageHeader)
        0x00,                   // stop (PageHeader)
    ];
    assert(bytes == expected);
}

// Nested LogicalType union and list headers, hand-derived.
unittest {
    FileMetaData m;
    m.version_ = 1;
    SchemaElement root = { name: "s", hasNumChildren: true, numChildren: 1 };
    SchemaElement leaf = { name: "c", hasType: true, type: PhysicalType.byteArray,
        hasRepetition: true, repetition: Repetition.optional, utf8String: true };
    m.schema = [root, leaf];
    m.numRows = 0;
    const bytes = encodeFileMetaData(m);
    const ubyte[] expected = [
        0x15, 0x02,             // field 1 version (i32) = 1
        0x19, 0x2c,             // field 2 list<struct>, size 2
        //   root: name (field 4), num_children (field 5)
        0x48, 0x01, 's', 0x15, 0x02, 0x00,
        //   leaf: type=6, repetition=1, name, converted_type=0, logicalType{STRING{}}
        0x15, 0x0c, 0x25, 0x02, 0x18, 0x01, 'c', 0x25, 0x00,
        0x4c, 0x1c, 0x00, 0x00, 0x00,
        0x16, 0x00,             // field 3 num_rows (i64) = 0
        0x19, 0x0c,             // field 4 list<struct>, size 0
        0x00,                   // stop
    ];
    assert(bytes == expected);
}
