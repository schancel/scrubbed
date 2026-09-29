/// Thrift compact-protocol encoding of the Parquet metadata structs this
/// package writes, on top of the vendored Apache Thrift `TCompactProtocol`
/// (`third_party/thrift`, v0.24.0 -- see its README for provenance).
///
/// Decoding (`decodeFileMetaData`, `decodePageHeader`) reads the same
/// structs back through the same vendored `TCompactProtocol`, plus the
/// decode-only fields a reader of externally produced files needs
/// (dictionary pages, v2 data pages, `type_length`, annotations, and the
/// Parquet modular-encryption presence markers `FileMetaData.hasEncryptionAlgorithm`
/// / `ColumnChunk.hasCryptoMetadata` / `ColumnChunk.hasEncryptedColumnMetadata`
/// -- contents unused, `parquet.reader` rejects any file where one is set).
/// Unknown fields are skipped; see the "Decoding" section below for the
/// hostile-input guards layered around the vendored protocol.
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

import parquet.exception : ParquetFormatException, check;
import thrift.protocol.base : TField, TList, TStruct, TType;
import thrift.protocol.compact : TCompactProtocol;
import thrift.transport.base : TBaseTransport, TTransportException;
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

/// `parquet.thrift` `Encoding`. The writer emits only `plain` and `rle`;
/// the other values exist so the reader can name what a file uses. Decoded
/// values outside this list are kept as-is (never `final switch` on them).
enum Encoding : int {
    plain = 0,
    plainDictionary = 2,
    rle = 3,
    bitPacked = 4,
    deltaBinaryPacked = 5,
    deltaLengthByteArray = 6,
    deltaByteArray = 7,
    rleDictionary = 8,
    byteStreamSplit = 9,
}

/// `parquet.thrift` `CompressionCodec`. The writer emits only
/// `uncompressed` and `zstd`; the reader also decodes `snappy` and `gzip`.
enum CompressionCodec : int {
    uncompressed = 0,
    snappy = 1,
    gzip = 2,
    lzo = 3,
    brotli = 4,
    lz4 = 5,
    zstd = 6,
    lz4Raw = 7,
}

/// `parquet.thrift` `PageType`. The writer emits only `dataPage`.
enum PageType : int {
    dataPage = 0,
    indexPage = 1,
    dictionaryPage = 2,
    dataPageV2 = 3,
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
    /// On decode, set when either annotation marks the column as a string.
    bool utf8String;

    // Decode-only fields (the encoder never emits them).
    bool hasTypeLength;
    /// `type_length` (field 2): byte width of a `FIXED_LEN_BYTE_ARRAY`.
    int typeLength;
    bool hasConvertedType;
    /// Raw `converted_type` (field 6) value.
    int convertedType;
    /// Field id of the `logicalType` (field 10) union member that is set, or
    /// 0 when absent (1 = STRING, 2 = MAP, ... per `parquet.thrift`).
    int logicalType;
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

    // Decode-only fields (the encoder never emits them).
    bool hasDictionaryPageOffset;
    /// `dictionary_page_offset` (field 11).
    long dictionaryPageOffset;
}

/// `parquet.thrift` `ColumnChunk` subset: metadata always inline in the
/// footer, never in a separate file.
struct ColumnChunk {
    /// Deprecated upstream; `parquet.thrift` says writers should set 0 when no
    /// ColumnMetaData is written outside the footer, which is always the case
    /// here.
    long fileOffset;
    ColumnMetaData metaData;

    // Decode-only fields (the encoder always writes `meta_data` inline and
    // never a `file_path`).
    /// Whether `meta_data` (field 3) was present.
    bool hasMetaData;
    /// `file_path` (field 1): column data lives in another file when set.
    string filePath;

    // Decode-only, Parquet modular-encryption markers (the encoder never
    // writes them; this reader does not support encrypted files -- see
    // `parquet.reader.parseFooter`, which rejects a chunk where either is
    // set).
    /// Whether `crypto_metadata` (field 8, the `ColumnCryptoMetaData` union)
    /// was present.
    bool hasCryptoMetadata;
    /// Whether `encrypted_column_metadata` (field 9, binary) was present.
    bool hasEncryptedColumnMetadata;
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

    // Decode-only (the encoder never writes it; this reader does not
    // support encrypted files -- see `parquet.reader.parseFooter`).
    /// Whether `encryption_algorithm` (field 8, the `EncryptionAlgorithm`
    /// union) was present. Parquet's modular encryption sets this in
    /// "plaintext footer" mode (footer readable, column data encrypted); the
    /// "encrypted footer" mode instead swaps the trailing magic to `PARE`,
    /// which is rejected before the footer is even decoded.
    bool hasEncryptionAlgorithm;
}

/// `parquet.thrift` `DataPageHeader` subset (no statistics).
struct DataPageHeader {
    int numValues;
    Encoding encoding;
    Encoding definitionLevelEncoding;
    Encoding repetitionLevelEncoding;
}

/// `parquet.thrift` `DictionaryPageHeader` (decode-only).
struct DictionaryPageHeader {
    int numValues;
    Encoding encoding;
    bool isSorted;
}

/// `parquet.thrift` `DataPageHeaderV2` subset, no statistics (decode-only).
struct DataPageHeaderV2 {
    int numValues;
    int numNulls;
    int numRows;
    Encoding encoding;
    int definitionLevelsByteLength;
    int repetitionLevelsByteLength;
    /// Defaults to true in `parquet.thrift`.
    bool isCompressed = true;
}

/// `parquet.thrift` `PageHeader` subset (no CRC, no statistics). The
/// encoder writes only `type`, the sizes, and `dataPageHeader`; the other
/// members are filled in by `decodePageHeader`.
struct PageHeader {
    PageType type;
    int uncompressedPageSize;
    int compressedPageSize;
    DataPageHeader dataPageHeader;

    // Decode-only fields.
    bool hasDataPageHeader;
    bool hasDictionaryPageHeader;
    DictionaryPageHeader dictionaryPageHeader;
    bool hasDataPageHeaderV2;
    DataPageHeaderV2 dataPageHeaderV2;
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

// ---------------------------------------------------------------------------
// Decoding
//
// Parquet footers and page headers come from arbitrary external writers, so
// decoding treats them as hostile. The vendored `TCompactProtocol` does the
// byte-level work; this layer adds the guards it lacks:
//
// - A `SliceTransport` over the caller's bytes (no copy, and it reports how
//   many bytes a page header occupied, which the page data follows). Reading
//   past the end throws.
// - `TCompactProtocol` maps a field-header or list-header type nibble through
//   a `final switch`, which is an `Error` (or, with `-release`, undefined
//   behaviour) for the three unassigned nibble values 13..15. Every field and
//   list header is peeked and validated before the protocol sees it.
// - Container and string sizes are capped at the input length (each element
//   needs at least one byte), so a forged size cannot trigger a huge
//   allocation before the short read is noticed.
// - The upstream `skip()` recurses without limit; nesting depth here is
//   capped, so a footer of nested empty structs cannot overflow the stack.
// - Maps are rejected: `parquet.thrift` has none.
// - Anything the protocol throws is rethrown as `ParquetFormatException`.
// ---------------------------------------------------------------------------

/// Maximum struct/list nesting accepted while decoding. `parquet.thrift`'s
/// deepest real path (FileMetaData > RowGroup > ColumnChunk > ColumnMetaData
/// > Statistics / LogicalType > member) is well under this.
private enum maxNestingDepth = 32;

/// Decodes a Parquet footer body (the bytes between the last data byte and
/// the 4-byte footer length).
FileMetaData decodeFileMetaData(const(ubyte)[] bytes) {
    FileMetaData m;
    size_t consumed;
    decodeWith(bytes, consumed, (ref Decoder d) { d.fileMetaData(m); });
    return m;
}

/// Decodes the page header at the start of `bytes`; `consumed` is set to
/// its encoded length (the page body follows immediately).
PageHeader decodePageHeader(const(ubyte)[] bytes, out size_t consumed) {
    PageHeader h;
    decodeWith(bytes, consumed, (ref Decoder d) { d.pageHeader(h); });
    return h;
}

private void decodeWith(const(ubyte)[] bytes, out size_t consumed,
        scope void delegate(ref Decoder) body) {
    auto d = Decoder.make(bytes);
    try {
        body(d);
    } catch (ParquetFormatException e) {
        throw e;
    } catch (Exception e) {
        throw new ParquetFormatException("malformed Thrift metadata: " ~ e.msg);
    }
    consumed = d.trans.pos;
}

/// Read-only, zero-copy transport over a byte slice.
private final class SliceTransport : TBaseTransport {
    const(ubyte)[] data;
    size_t pos;

    this(const(ubyte)[] data) { this.data = data; }

    override bool isOpen() @property { return true; }
    override bool peek() { return pos < data.length; }
    override void open() {}
    override void close() {}

    override size_t read(ubyte[] buf) {
        const n = buf.length < data.length - pos ? buf.length : data.length - pos;
        buf[0 .. n] = data[pos .. pos + n];
        pos += n;
        return n;
    }

    override void readAll(ubyte[] buf) {
        if (buf.length > data.length - pos)
            throw new TTransportException(TTransportException.Type.END_OF_FILE);
        buf[] = data[pos .. pos + buf.length];
        pos += buf.length;
    }

    override const(ubyte)[] borrow(ubyte* buf, size_t len) {
        return len <= data.length - pos ? data[pos .. $] : null;
    }

    override void consume(size_t len) {
        check(len <= data.length - pos, "thrift: consume past end of input");
        pos += len;
    }

    /// Next byte without consuming it, or -1 at end of input.
    int peekByte() const { return pos < data.length ? data[pos] : -1; }
}

private struct Decoder {
    SliceTransport trans;
    TCompactProtocol!SliceTransport proto;
    uint depth;

    static Decoder make(const(ubyte)[] bytes) {
        Decoder d;
        d.trans = new SliceTransport(bytes);
        // 0 would mean "unlimited" to the protocol; 1 is as good as 0 bytes.
        const limit = bytes.length == 0 ? 1
            : bytes.length > int.max ? int.max : cast(int) bytes.length;
        d.proto = new TCompactProtocol!SliceTransport(d.trans, limit, limit);
        return d;
    }

    private void checkNibble(uint nibble, string what) {
        // CType values 0 (STOP) .. 12 (STRUCT) are assigned; 13..15 are not.
        check(nibble <= 12, "thrift: invalid compact type in " ~ what);
    }

    TField fieldBegin() {
        const b = trans.peekByte();
        check(b >= 0, "thrift: truncated struct");
        checkNibble(b & 0x0f, "field header");
        return proto.readFieldBegin();
    }

    TList listBegin() {
        const b = trans.peekByte();
        check(b >= 0, "thrift: truncated list");
        checkNibble(b & 0x0f, "list header");
        return proto.readListBegin();
    }

    void structBegin() {
        check(++depth <= maxNestingDepth, "thrift: metadata nested too deeply");
        proto.readStructBegin();
    }

    void structEnd() {
        proto.readStructEnd();
        --depth;
    }

    void skip(TType type) {
        switch (type) {
        case TType.BOOL: proto.readBool(); break;
        case TType.BYTE: proto.readByte(); break;
        case TType.I16: proto.readI16(); break;
        case TType.I32: proto.readI32(); break;
        case TType.I64: proto.readI64(); break;
        case TType.DOUBLE: proto.readDouble(); break;
        case TType.STRING: proto.readBinary(); break;
        case TType.STRUCT:
            structBegin();
            for (;;) {
                const f = fieldBegin();
                if (f.type == TType.STOP) break;
                skip(f.type);
            }
            structEnd();
            break;
        case TType.LIST:
        case TType.SET:
            // Set and list headers share one compact encoding.
            check(++depth <= maxNestingDepth, "thrift: metadata nested too deeply");
            const l = listBegin();
            foreach (_; 0 .. l.size) skip(l.elemType);
            --depth;
            break;
        default:
            throw new ParquetFormatException("thrift: unexpected value type in metadata");
        }
    }

    /// True when `f` has type `t`; otherwise skips its value and returns
    /// false (a field with an unexpected type is treated as unknown, as
    /// Thrift-generated code does).
    bool accept(const TField f, TType t) {
        if (f.type == t) return true;
        skip(f.type);
        return false;
    }

    /// Reads a `list<T>` whose element type must be `elem`.
    T[] list(T)(TType elem, scope T delegate() readOne) {
        check(++depth <= maxNestingDepth, "thrift: metadata nested too deeply");
        const l = listBegin();
        check(l.size == 0 || l.elemType == elem, "thrift: list has unexpected element type");
        auto result = new T[l.size];
        foreach (ref r; result) r = readOne();
        --depth;
        return result;
    }

    void fileMetaData(ref FileMetaData m) {
        bool hasSchema, hasNumRows, hasRowGroups;
        structBegin();
        for (;;) {
            const f = fieldBegin();
            if (f.type == TType.STOP) break;
            switch (f.id) {
            case 1: if (accept(f, TType.I32)) m.version_ = proto.readI32(); break;
            case 2:
                if (accept(f, TType.LIST)) {
                    m.schema = list!SchemaElement(TType.STRUCT, () {
                        SchemaElement s; schemaElement(s); return s; });
                    hasSchema = true;
                }
                break;
            case 3: if (accept(f, TType.I64)) { m.numRows = proto.readI64(); hasNumRows = true; } break;
            case 4:
                if (accept(f, TType.LIST)) {
                    m.rowGroups = list!RowGroup(TType.STRUCT, () {
                        RowGroup g; rowGroup(g); return g; });
                    hasRowGroups = true;
                }
                break;
            case 6: if (accept(f, TType.STRING)) m.createdBy = proto.readString(); break;
            case 8:
                if (accept(f, TType.STRUCT)) {
                    skip(TType.STRUCT); // contents unused: presence alone is rejected
                    m.hasEncryptionAlgorithm = true;
                }
                break;
            default: skip(f.type);
            }
        }
        structEnd();
        check(hasSchema && hasNumRows && hasRowGroups,
            "FileMetaData is missing a required field (schema, num_rows, row_groups)");
    }

    void schemaElement(ref SchemaElement s) {
        bool hasName;
        structBegin();
        for (;;) {
            const f = fieldBegin();
            if (f.type == TType.STOP) break;
            switch (f.id) {
            case 1: if (accept(f, TType.I32)) { s.type = cast(PhysicalType) proto.readI32(); s.hasType = true; } break;
            case 2: if (accept(f, TType.I32)) { s.typeLength = proto.readI32(); s.hasTypeLength = true; } break;
            case 3: if (accept(f, TType.I32)) { s.repetition = cast(Repetition) proto.readI32(); s.hasRepetition = true; } break;
            case 4: if (accept(f, TType.STRING)) { s.name = proto.readString(); hasName = true; } break;
            case 5: if (accept(f, TType.I32)) { s.numChildren = proto.readI32(); s.hasNumChildren = true; } break;
            case 6: if (accept(f, TType.I32)) { s.convertedType = proto.readI32(); s.hasConvertedType = true; } break;
            case 10: if (accept(f, TType.STRUCT)) s.logicalType = unionMember(); break;
            default: skip(f.type);
            }
        }
        structEnd();
        check(hasName, "SchemaElement is missing its name");
        s.utf8String = (s.hasConvertedType && s.convertedType == ConvertedType.utf8)
            || s.logicalType == 1;
    }

    /// Reads a union struct, returning the field id of its (first) member.
    int unionMember() {
        int member;
        structBegin();
        for (;;) {
            const f = fieldBegin();
            if (f.type == TType.STOP) break;
            if (member == 0) member = f.id;
            skip(f.type);
        }
        structEnd();
        return member;
    }

    void rowGroup(ref RowGroup g) {
        bool hasColumns, hasNumRows;
        structBegin();
        for (;;) {
            const f = fieldBegin();
            if (f.type == TType.STOP) break;
            switch (f.id) {
            case 1:
                if (accept(f, TType.LIST)) {
                    g.columns = list!ColumnChunk(TType.STRUCT, () {
                        ColumnChunk c; columnChunk(c); return c; });
                    hasColumns = true;
                }
                break;
            case 2: if (accept(f, TType.I64)) g.totalByteSize = proto.readI64(); break;
            case 3: if (accept(f, TType.I64)) { g.numRows = proto.readI64(); hasNumRows = true; } break;
            case 5: if (accept(f, TType.I64)) g.fileOffset = proto.readI64(); break;
            case 6: if (accept(f, TType.I64)) g.totalCompressedSize = proto.readI64(); break;
            case 7: if (accept(f, TType.I16)) g.ordinal = proto.readI16(); break;
            default: skip(f.type);
            }
        }
        structEnd();
        check(hasColumns && hasNumRows, "RowGroup is missing a required field (columns, num_rows)");
    }

    void columnChunk(ref ColumnChunk c) {
        structBegin();
        for (;;) {
            const f = fieldBegin();
            if (f.type == TType.STOP) break;
            switch (f.id) {
            case 1: if (accept(f, TType.STRING)) c.filePath = proto.readString(); break;
            case 2: if (accept(f, TType.I64)) c.fileOffset = proto.readI64(); break;
            case 3: if (accept(f, TType.STRUCT)) { columnMetaData(c.metaData); c.hasMetaData = true; } break;
            case 8:
                if (accept(f, TType.STRUCT)) {
                    skip(TType.STRUCT); // contents unused: presence alone is rejected
                    c.hasCryptoMetadata = true;
                }
                break;
            case 9:
                if (accept(f, TType.STRING)) {
                    proto.readBinary(); // contents unused: presence alone is rejected
                    c.hasEncryptedColumnMetadata = true;
                }
                break;
            default: skip(f.type);
            }
        }
        structEnd();
    }

    void columnMetaData(ref ColumnMetaData m) {
        bool hasType, hasCodec, hasNumValues, hasCompressed, hasDataOffset;
        structBegin();
        for (;;) {
            const f = fieldBegin();
            if (f.type == TType.STOP) break;
            switch (f.id) {
            case 1: if (accept(f, TType.I32)) { m.type = cast(PhysicalType) proto.readI32(); hasType = true; } break;
            case 2:
                if (accept(f, TType.LIST))
                    m.encodings = list!Encoding(TType.I32, () => cast(Encoding) proto.readI32());
                break;
            case 3:
                if (accept(f, TType.LIST))
                    m.pathInSchema = list!string(TType.STRING, () => proto.readString());
                break;
            case 4: if (accept(f, TType.I32)) { m.codec = cast(CompressionCodec) proto.readI32(); hasCodec = true; } break;
            case 5: if (accept(f, TType.I64)) { m.numValues = proto.readI64(); hasNumValues = true; } break;
            case 6: if (accept(f, TType.I64)) m.totalUncompressedSize = proto.readI64(); break;
            case 7: if (accept(f, TType.I64)) { m.totalCompressedSize = proto.readI64(); hasCompressed = true; } break;
            case 9: if (accept(f, TType.I64)) { m.dataPageOffset = proto.readI64(); hasDataOffset = true; } break;
            case 11:
                if (accept(f, TType.I64)) {
                    m.dictionaryPageOffset = proto.readI64();
                    m.hasDictionaryPageOffset = true;
                }
                break;
            default: skip(f.type);
            }
        }
        structEnd();
        check(hasType && hasCodec && hasNumValues && hasCompressed && hasDataOffset,
            "ColumnMetaData is missing a required field");
    }

    void pageHeader(ref PageHeader h) {
        bool hasType, hasUncompressed, hasCompressed;
        structBegin();
        for (;;) {
            const f = fieldBegin();
            if (f.type == TType.STOP) break;
            switch (f.id) {
            case 1: if (accept(f, TType.I32)) { h.type = cast(PageType) proto.readI32(); hasType = true; } break;
            case 2: if (accept(f, TType.I32)) { h.uncompressedPageSize = proto.readI32(); hasUncompressed = true; } break;
            case 3: if (accept(f, TType.I32)) { h.compressedPageSize = proto.readI32(); hasCompressed = true; } break;
            case 5: if (accept(f, TType.STRUCT)) { dataPageHeader(h.dataPageHeader); h.hasDataPageHeader = true; } break;
            case 7: if (accept(f, TType.STRUCT)) { dictionaryPageHeader(h.dictionaryPageHeader); h.hasDictionaryPageHeader = true; } break;
            case 8: if (accept(f, TType.STRUCT)) { dataPageHeaderV2(h.dataPageHeaderV2); h.hasDataPageHeaderV2 = true; } break;
            default: skip(f.type);
            }
        }
        structEnd();
        check(hasType && hasUncompressed && hasCompressed,
            "PageHeader is missing a required field (type, page sizes)");
    }

    void dataPageHeader(ref DataPageHeader h) {
        bool hasNumValues, hasEncoding;
        structBegin();
        for (;;) {
            const f = fieldBegin();
            if (f.type == TType.STOP) break;
            switch (f.id) {
            case 1: if (accept(f, TType.I32)) { h.numValues = proto.readI32(); hasNumValues = true; } break;
            case 2: if (accept(f, TType.I32)) { h.encoding = cast(Encoding) proto.readI32(); hasEncoding = true; } break;
            case 3: if (accept(f, TType.I32)) h.definitionLevelEncoding = cast(Encoding) proto.readI32(); break;
            case 4: if (accept(f, TType.I32)) h.repetitionLevelEncoding = cast(Encoding) proto.readI32(); break;
            default: skip(f.type);
            }
        }
        structEnd();
        check(hasNumValues && hasEncoding, "DataPageHeader is missing a required field");
    }

    void dictionaryPageHeader(ref DictionaryPageHeader h) {
        bool hasNumValues, hasEncoding;
        structBegin();
        for (;;) {
            const f = fieldBegin();
            if (f.type == TType.STOP) break;
            switch (f.id) {
            case 1: if (accept(f, TType.I32)) { h.numValues = proto.readI32(); hasNumValues = true; } break;
            case 2: if (accept(f, TType.I32)) { h.encoding = cast(Encoding) proto.readI32(); hasEncoding = true; } break;
            case 3: if (accept(f, TType.BOOL)) h.isSorted = proto.readBool(); break;
            default: skip(f.type);
            }
        }
        structEnd();
        check(hasNumValues && hasEncoding, "DictionaryPageHeader is missing a required field");
    }

    void dataPageHeaderV2(ref DataPageHeaderV2 h) {
        uint seen;
        structBegin();
        for (;;) {
            const f = fieldBegin();
            if (f.type == TType.STOP) break;
            switch (f.id) {
            case 1: if (accept(f, TType.I32)) { h.numValues = proto.readI32(); seen |= 1; } break;
            case 2: if (accept(f, TType.I32)) { h.numNulls = proto.readI32(); seen |= 2; } break;
            case 3: if (accept(f, TType.I32)) { h.numRows = proto.readI32(); seen |= 4; } break;
            case 4: if (accept(f, TType.I32)) { h.encoding = cast(Encoding) proto.readI32(); seen |= 8; } break;
            case 5: if (accept(f, TType.I32)) { h.definitionLevelsByteLength = proto.readI32(); seen |= 16; } break;
            case 6: if (accept(f, TType.I32)) { h.repetitionLevelsByteLength = proto.readI32(); seen |= 32; } break;
            case 7: if (accept(f, TType.BOOL)) h.isCompressed = proto.readBool(); break;
            default: skip(f.type);
            }
        }
        structEnd();
        check(seen == 63, "DataPageHeaderV2 is missing a required field");
    }
}

// Encoder output decodes back to the same structs, and decode reports the
// exact header length so trailing page bytes are left alone.
unittest {
    PageHeader h;
    h.type = PageType.dataPage;
    h.uncompressedPageSize = 100;
    h.compressedPageSize = 3;
    h.dataPageHeader = DataPageHeader(5, Encoding.plain, Encoding.rle, Encoding.rle);
    const bytes = encodePageHeader(h);
    size_t consumed;
    const got = decodePageHeader(bytes ~ cast(const(ubyte)[]) [0xde, 0xad], consumed);
    assert(consumed == bytes.length);
    assert(got.type == PageType.dataPage && got.uncompressedPageSize == 100
        && got.compressedPageSize == 3 && got.hasDataPageHeader);
    assert(got.dataPageHeader == h.dataPageHeader);

    FileMetaData m;
    m.version_ = 1;
    SchemaElement root = { name: "schema", hasNumChildren: true, numChildren: 1 };
    SchemaElement leaf = { name: "text", hasType: true, type: PhysicalType.byteArray,
        hasRepetition: true, repetition: Repetition.optional, utf8String: true };
    m.schema = [root, leaf];
    m.numRows = 7;
    ColumnMetaData cm;
    cm.type = PhysicalType.byteArray;
    cm.encodings = [Encoding.plain, Encoding.rle];
    cm.pathInSchema = ["text"];
    cm.codec = CompressionCodec.zstd;
    cm.numValues = 7;
    cm.totalCompressedSize = 40;
    cm.dataPageOffset = 4;
    RowGroup g;
    g.columns = [ColumnChunk(0, cm)];
    g.numRows = 7;
    m.rowGroups = [g];
    m.createdBy = "parquet-d";
    const d = decodeFileMetaData(encodeFileMetaData(m));
    assert(d.version_ == 1 && d.numRows == 7 && d.createdBy == "parquet-d");
    assert(d.schema.length == 2 && d.schema[1].name == "text" && d.schema[1].utf8String
        && d.schema[1].convertedType == ConvertedType.utf8 && d.schema[1].logicalType == 1
        && d.schema[1].repetition == Repetition.optional && d.schema[0].numChildren == 1);
    assert(d.rowGroups.length == 1 && d.rowGroups[0].columns[0].hasMetaData);
    const dm = d.rowGroups[0].columns[0].metaData;
    assert(dm.pathInSchema == ["text"] && dm.codec == CompressionCodec.zstd
        && dm.encodings == [Encoding.plain, Encoding.rle] && dm.dataPageOffset == 4
        && !dm.hasDictionaryPageOffset);
}

// Hand-derived decode of fields the encoder never writes: a dictionary page
// header (field 7) with a bool, and an unknown field (id 4, crc) skipped.
unittest {
    const ubyte[] bytes = [
        0x15, 0x04,             // field 1 type = DICTIONARY_PAGE (2)
        0x15, 0x10,             // field 2 uncompressed = 8
        0x15, 0x0c,             // field 3 compressed = 6
        0x15, 0x7f,             // field 4 crc (i32, unknown here) = -64
        0x3c,                   // field 7 (delta 3) struct
        0x15, 0x04,             //   num_values = 2
        0x15, 0x00,             //   encoding = PLAIN
        0x11,                   //   field 3 bool true
        0x00,                   //   stop
        0x00,                   // stop
    ];
    size_t consumed;
    const h = decodePageHeader(bytes, consumed);
    assert(consumed == bytes.length);
    assert(h.type == PageType.dictionaryPage && h.hasDictionaryPageHeader
        && h.dictionaryPageHeader.numValues == 2 && h.dictionaryPageHeader.isSorted);
}

// Hostile input: invalid type nibbles, deep nesting, forged sizes, and
// truncation all raise ParquetFormatException, never an Error.
unittest {
    import std.exception : assertThrown;

    alias E = ParquetFormatException;
    size_t c;
    assertThrown!E(decodePageHeader([], c));
    assertThrown!E(decodePageHeader([0x1d], c));             // type nibble 13
    assertThrown!E(decodePageHeader([0x1f, 0x00], c));       // type nibble 15
    assertThrown!E(decodePageHeader([0x19, 0xfd], c));       // list of nibble 13
    assertThrown!E(decodePageHeader([0x18, 0xff, 0xff, 0xff, 0xff, 0x07], c)); // huge string
    assertThrown!E(decodePageHeader([0x19, 0xfc, 0xff, 0xff, 0xff, 0x07], c)); // huge list
    assertThrown!E(decodePageHeader([0x1b, 0x00], c));       // map
    assertThrown!E(decodePageHeader([0x15, 0x00], c));       // truncated
    assertThrown!E(decodePageHeader([0x15, 0x00, 0x00], c)); // missing required fields
    // 10 000 nested empty structs: rejected by depth, not a stack overflow.
    ubyte[] deep;
    foreach (_; 0 .. 10_000) deep ~= 0x1c;
    assertThrown!E(decodePageHeader(deep, c));
    assertThrown!E(decodeFileMetaData(deep));
    // Random garbage never escapes as an Error.
    import std.random : Random, uniform;
    auto rng = Random(392);
    foreach (_; 0 .. 20_000) {
        auto junk = new ubyte[uniform(0, 64, rng)];
        foreach (ref b; junk) b = cast(ubyte) uniform(0, 256, rng);
        try decodePageHeader(junk, c); catch (E) {}
        try decodeFileMetaData(junk); catch (E) {}
    }
}
