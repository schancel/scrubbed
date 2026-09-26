/// Bounded, immutable-style document metadata: an independent v1 standard-key
/// set plus open, opaque extension fields, each with bounded provenance and a
/// versioned wire format. This type is deliberately unwired: it does not
/// import `effects.html_metadata` and nothing in `source/stages` or
/// `source/composition` references it. `DocumentId` is bound only at the
/// `encodeDocumentMetadataV1`/`decodeDocumentMetadataV1` boundary, never
/// inside the in-flight value, mirroring `effects.html_metadata`'s
/// `serializeHtmlMetadata(DocumentId id, const HtmlMetadata metadata)`.
module domain.document_metadata;

import domain.document : DocumentId;
import std.exception : enforce;
import std.utf : validate, UTFException;

enum size_t maxStandardValueBytes = 512;
enum size_t maxExtensionKeyBytes = 64;
enum size_t maxExtensionValueBytes = 512;
enum size_t maxExtensionFields = 32;
enum size_t maxSourceStageBytes = 128;
enum size_t maxTotalEncodedBytes = 64 * 1024;

/// v1 standard metadata keys. Deliberately independent of, and simpler than,
/// `effects.html_metadata`'s `HtmlMetadata` field taxonomy.
enum StandardMetadataKey : ubyte { title, author, date, url }

private enum standardKeyCount = StandardMetadataKey.max + 1;

private struct StandardEntry {
    bool present;
    string value;
    string sourceStage;
}

/// One caller-chosen, opaque extension entry. The value is raw bounded bytes
/// and is never interpreted by this module.
struct ExtensionEntry {
    string key;
    immutable(ubyte)[] value;
    string sourceStage;
}

private void checkSourceStage(string sourceStage) pure {
    enforce(sourceStage.length != 0 && sourceStage.length <= maxSourceStageBytes,
        "document metadata: malformed source stage");
    validateUtf8Field(sourceStage);
}

private void validateUtf8Field(string value) pure {
    try {
        validate(value);
    } catch (UTFException) {
        throw new Exception("document metadata: malformed utf-8 field");
    }
}

/// A bounded, functional-style value: `.empty()` plus `.withStandardField`/
/// `.withExtensionField`, each returning a new value. Writing an
/// already-present key (standard or extension) is a construction-time
/// failure, never last-write-wins. `DocumentId` is never an input to any
/// mutator here.
struct DocumentMetadata {
    private StandardEntry[standardKeyCount] standardEntries;
    private ExtensionEntry[] extensionEntries;

    static DocumentMetadata empty() pure {
        return DocumentMetadata.init;
    }

    /// Reject a second write to an already-set standard key at construction
    /// time; enforce every cap eagerly, not at encode time.
    DocumentMetadata withStandardField(StandardMetadataKey key, string value,
            string sourceStage) pure {
        checkSourceStage(sourceStage);
        enforce(value.length <= maxStandardValueBytes,
            "document metadata: standard field value too long");
        validateUtf8Field(value);
        auto index = cast(size_t) key;
        enforce(!standardEntries[index].present,
            "document metadata: standard field already set");
        DocumentMetadata result = this;
        result.standardEntries[index] = StandardEntry(true, value, sourceStage);
        encodeBody(maxDocumentIdPlaceholder, result); // eager aggregate cap check
        return result;
    }

    /// Reject a second write to an already-set extension key at construction
    /// time; enforce every cap eagerly, not at encode time.
    DocumentMetadata withExtensionField(string key, immutable(ubyte)[] value,
            string sourceStage) pure {
        checkSourceStage(sourceStage);
        enforce(key.length != 0 && key.length <= maxExtensionKeyBytes,
            "document metadata: malformed extension key");
        validateUtf8Field(key);
        enforce(value.length <= maxExtensionValueBytes,
            "document metadata: extension field value too long");
        enforce(extensionEntries.length < maxExtensionFields,
            "document metadata: extension field capacity exceeded");
        foreach (entry; extensionEntries)
            enforce(entry.key != key, "document metadata: extension key already set");
        DocumentMetadata result = this;
        result.extensionEntries = extensionEntries ~ ExtensionEntry(key, value, sourceStage);
        encodeBody(maxDocumentIdPlaceholder, result); // eager aggregate cap check
        return result;
    }

    bool hasStandardField(StandardMetadataKey key) const pure {
        return standardEntries[cast(size_t) key].present;
    }

    string standardValue(StandardMetadataKey key) const pure {
        auto entry = standardEntries[cast(size_t) key];
        enforce(entry.present, "document metadata: standard field not set");
        return entry.value;
    }

    string standardSourceStage(StandardMetadataKey key) const pure {
        auto entry = standardEntries[cast(size_t) key];
        enforce(entry.present, "document metadata: standard field not set");
        return entry.sourceStage;
    }

    size_t extensionFieldCount() const pure { return extensionEntries.length; }

    const(ExtensionEntry)[] extensionFields() const pure { return extensionEntries; }
}

// ---------------------------------------------------------------------------
// Wire format `document-metadata:v1`: fixed key order, one trailing LF, built
// with the same bounded cap-enforcing Writer idiom used by
// `effects.html_metadata.serializeHtmlMetadata`. Extension values are opaque
// bytes and are hex-encoded on the wire so the whole record stays plain text.
// ---------------------------------------------------------------------------

/// Thrown when building the wire form would exceed `maxTotalEncodedBytes`.
/// Mirrors `effects.html_metadata.HtmlMetadataOutputLimit`.
class DocumentMetadataOutputLimit : Exception {
    this() pure { super("document metadata: output limit exceeded"); }
}

private struct Writer {
    char[] bytes;

    void put(scope const(char)[] value) pure {
        if (value.length > maxTotalEncodedBytes - bytes.length)
            throw new DocumentMetadataOutputLimit;
        bytes ~= value;
    }

    void quoted(string value) pure {
        enum hex = "0123456789abcdef";
        put("\"");
        size_t runStart;
        foreach (i, c; value) {
            if (cast(ubyte) c >= 0x20 && c != '"' && c != '\\') continue;
            if (runStart < i) put(value[runStart .. i]);
            switch (c) {
                case '"': put(`\"`); break;
                case '\\': put(`\\`); break;
                case '\b': put(`\b`); break;
                case '\f': put(`\f`); break;
                case '\n': put(`\n`); break;
                case '\r': put(`\r`); break;
                case '\t': put(`\t`); break;
                default:
                    auto byteValue = cast(ubyte) c;
                    char[6] escaped = ['\\', 'u', '0', '0',
                        hex[byteValue >> 4], hex[byteValue & 0xf]];
                    put(escaped[]);
            }
            runStart = i + 1;
        }
        if (runStart < value.length) put(value[runStart .. $]);
        put("\"");
    }

    void putHex(immutable(ubyte)[] value) pure {
        enum hex = "0123456789abcdef";
        char[2] pair;
        foreach (b; value) {
            pair[0] = hex[b >> 4];
            pair[1] = hex[b & 0xf];
            put(pair[]);
        }
    }
}

// `DocumentId.text()` is either "doc:v1:" + 64 hex chars (71) or "child:v1:"
// + 64 hex chars (73) on current `domain.document`. This placeholder is a
// deliberately worst-case-length stand-in used only to make the aggregate
// `maxTotalEncodedBytes` cap check eager at mutation time, before any real
// `DocumentId` is bound. It never appears in a real wire record.
private enum string maxDocumentIdPlaceholder =
    "child:v1:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";

static assert(maxDocumentIdPlaceholder.length == 73);

private void putStandardField(ref Writer writer, string name, StandardEntry entry) pure {
    writer.put(`"`);
    writer.put(name);
    writer.put(`":`);
    if (entry.present) {
        writer.put(`{"value":`);
        writer.quoted(entry.value);
        writer.put(`,"sourceStage":`);
        writer.quoted(entry.sourceStage);
        writer.put(`}`);
    } else {
        writer.put("null");
    }
}

private immutable(char)[] encodeBody(string idText, const DocumentMetadata metadata) pure {
    Writer writer;
    writer.put(`{"version":"document-metadata:v1","documentId":`);
    writer.quoted(idText);
    writer.put(`,"standard":{`);
    putStandardField(writer, "title", metadata.standardEntries[cast(size_t) StandardMetadataKey.title]);
    writer.put(",");
    putStandardField(writer, "author", metadata.standardEntries[cast(size_t) StandardMetadataKey.author]);
    writer.put(",");
    putStandardField(writer, "date", metadata.standardEntries[cast(size_t) StandardMetadataKey.date]);
    writer.put(",");
    putStandardField(writer, "url", metadata.standardEntries[cast(size_t) StandardMetadataKey.url]);
    writer.put(`},"extension":[`);
    foreach (i, entry; metadata.extensionEntries) {
        if (i) writer.put(",");
        writer.put(`{"key":`);
        writer.quoted(entry.key);
        writer.put(`,"value":"`);
        writer.putHex(entry.value);
        writer.put(`","sourceStage":`);
        writer.quoted(entry.sourceStage);
        writer.put(`}`);
    }
    writer.put("]}\n");
    return writer.bytes.idup;
}

/// Fixed key order and one trailing LF are `document-metadata:v1`'s canonical
/// wire. `DocumentId` is bound only here, at the encode boundary.
string encodeDocumentMetadataV1(DocumentId id, const DocumentMetadata metadata) pure {
    return cast(string) encodeBody(id.text, metadata);
}

private struct Cursor {
    string text;
    size_t pos;

    void expect(string literal) pure {
        enforce(pos + literal.length <= text.length &&
            text[pos .. pos + literal.length] == literal,
            "document metadata: malformed wire");
        pos += literal.length;
    }

    bool tryLiteral(string literal) pure {
        if (pos + literal.length <= text.length &&
                text[pos .. pos + literal.length] == literal) {
            pos += literal.length;
            return true;
        }
        return false;
    }

    private static ubyte hexNibble(char c) pure {
        if (c >= '0' && c <= '9') return cast(ubyte) (c - '0');
        if (c >= 'a' && c <= 'f') return cast(ubyte) (c - 'a' + 10);
        throw new Exception("document metadata: malformed wire");
    }

    string parseQuotedString() pure {
        enforce(pos < text.length && text[pos] == '"', "document metadata: malformed wire");
        ++pos;
        char[] result;
        while (true) {
            enforce(pos < text.length, "document metadata: truncated wire");
            auto c = text[pos];
            if (c == '"') { ++pos; return result.idup; }
            if (c != '\\') {
                enforce(cast(ubyte) c >= 0x20, "document metadata: malformed wire");
                result ~= c;
                ++pos;
                continue;
            }
            ++pos;
            enforce(pos < text.length, "document metadata: truncated wire");
            auto esc = text[pos];
            switch (esc) {
                case '"': result ~= '"'; ++pos; break;
                case '\\': result ~= '\\'; ++pos; break;
                case 'b': result ~= '\b'; ++pos; break;
                case 'f': result ~= '\f'; ++pos; break;
                case 'n': result ~= '\n'; ++pos; break;
                case 'r': result ~= '\r'; ++pos; break;
                case 't': result ~= '\t'; ++pos; break;
                case 'u':
                    enforce(pos + 4 < text.length, "document metadata: truncated wire");
                    enforce(text[pos + 1] == '0' && text[pos + 2] == '0',
                        "document metadata: malformed wire");
                    auto hi = hexNibble(text[pos + 3]);
                    auto lo = hexNibble(text[pos + 4]);
                    result ~= cast(char) ((hi << 4) | lo);
                    pos += 5;
                    break;
                default:
                    throw new Exception("document metadata: malformed wire");
            }
        }
    }

    immutable(ubyte)[] parseHexBytes() pure {
        enforce(pos < text.length && text[pos] == '"', "document metadata: malformed wire");
        ++pos;
        ubyte[] result;
        while (true) {
            enforce(pos < text.length, "document metadata: truncated wire");
            if (text[pos] == '"') { ++pos; return result.idup; }
            enforce(pos + 1 < text.length, "document metadata: truncated wire");
            auto hi = hexNibble(text[pos]);
            auto lo = hexNibble(text[pos + 1]);
            result ~= cast(ubyte) ((hi << 4) | lo);
            pos += 2;
        }
    }
}

private DocumentMetadata parseStandardField(ref Cursor cursor, DocumentMetadata metadata,
        StandardMetadataKey key, string name) pure {
    cursor.expect(`"` ~ name ~ `":`);
    if (cursor.tryLiteral("null")) return metadata;
    cursor.expect(`{"value":`);
    auto value = cursor.parseQuotedString();
    cursor.expect(`,"sourceStage":`);
    auto sourceStage = cursor.parseQuotedString();
    cursor.expect(`}`);
    return metadata.withStandardField(key, value, sourceStage);
}

/// Fails closed on a wrong bound `DocumentId`, an unknown standard key, a
/// duplicate extension key, any cap violation (both sides of every
/// boundary), or malformed UTF-8. Diagnostics are content-free: no raw
/// payload/canary bytes are echoed into any exception message.
DocumentMetadata decodeDocumentMetadataV1(DocumentId expectedId, string wire) pure {
    enforce(wire.length <= maxTotalEncodedBytes,
        "document metadata: wire exceeds size limit");
    try {
        validate(wire);
    } catch (UTFException) {
        throw new Exception("document metadata: malformed utf-8");
    }

    auto cursor = Cursor(wire, 0);
    cursor.expect(`{"version":"document-metadata:v1","documentId":`);
    auto idText = cursor.parseQuotedString();
    enforce(idText == expectedId.text, "document metadata: bound document id mismatch");
    cursor.expect(`,"standard":{`);

    auto metadata = DocumentMetadata.empty();
    metadata = parseStandardField(cursor, metadata, StandardMetadataKey.title, "title");
    cursor.expect(",");
    metadata = parseStandardField(cursor, metadata, StandardMetadataKey.author, "author");
    cursor.expect(",");
    metadata = parseStandardField(cursor, metadata, StandardMetadataKey.date, "date");
    cursor.expect(",");
    metadata = parseStandardField(cursor, metadata, StandardMetadataKey.url, "url");
    cursor.expect(`},"extension":[`);

    if (!cursor.tryLiteral("]")) {
        while (true) {
            cursor.expect(`{"key":`);
            auto key = cursor.parseQuotedString();
            cursor.expect(`,"value":`);
            auto value = cursor.parseHexBytes();
            cursor.expect(`,"sourceStage":`);
            auto sourceStage = cursor.parseQuotedString();
            cursor.expect(`}`);
            metadata = metadata.withExtensionField(key, value, sourceStage);
            if (cursor.tryLiteral(",")) continue;
            cursor.expect(`]`);
            break;
        }
    }
    cursor.expect("}\n");
    enforce(cursor.pos == wire.length, "document metadata: trailing data");
    return metadata;
}

unittest {
    import domain.document : SourceLocator;
    import std.exception : assertThrown, assertNotThrown;

    auto id = DocumentId.from(SourceLocator("ns", "src", "rec"));
    auto otherId = DocumentId.from(SourceLocator("ns", "src", "other"));

    // Empty value round-trips.
    auto empty = DocumentMetadata.empty();
    auto emptyWire = encodeDocumentMetadataV1(id, empty);
    assert(emptyWire ==
        `{"version":"document-metadata:v1","documentId":"` ~ id.text ~
        `","standard":{"title":null,"author":null,"date":null,"url":null},"extension":[]}` ~ "\n");
    auto decodedEmpty = decodeDocumentMetadataV1(id, emptyWire);
    assert(decodedEmpty.extensionFieldCount == 0);
    assert(!decodedEmpty.hasStandardField(StandardMetadataKey.title));

    // Representative standard + extension combination, exact byte pin.
    auto meta = DocumentMetadata.empty()
        .withStandardField(StandardMetadataKey.title, "Hello \"World\"", "stage-a")
        .withExtensionField("ext-key", cast(immutable(ubyte)[]) [0xde, 0xad, 0xbe, 0xef], "stage-b");
    auto wire = encodeDocumentMetadataV1(id, meta);
    assert(wire ==
        `{"version":"document-metadata:v1","documentId":"` ~ id.text ~
        `","standard":{"title":{"value":"Hello \"World\"","sourceStage":"stage-a"},` ~
        `"author":null,"date":null,"url":null},` ~
        `"extension":[{"key":"ext-key","value":"deadbeef","sourceStage":"stage-b"}]}` ~ "\n");
    auto decoded = decodeDocumentMetadataV1(id, wire);
    assert(decoded.standardValue(StandardMetadataKey.title) == "Hello \"World\"");
    assert(decoded.standardSourceStage(StandardMetadataKey.title) == "stage-a");
    assert(decoded.extensionFieldCount == 1);
    assert(decoded.extensionFields[0].key == "ext-key");
    assert(decoded.extensionFields[0].value == cast(immutable(ubyte)[]) [0xde, 0xad, 0xbe, 0xef]);

    // Full-byte-range extension-value round-trip (#287): 0x00, 0xFF, 0x80,
    // 0xC0 (an invalid UTF-8 lead byte, included as a realistic adversarial
    // single-byte case even though extension values are never UTF-8-validated),
    // and a full 0-255 sweep in one extension value, all as real opaque
    // extension values round-tripped through withExtensionField -> encode ->
    // decode. Distinct from the malformed-UTF-8 case above, which corrupts
    // the whole wire buffer with 0xff to prove decode rejection, not value
    // round-trip.
    immutable(ubyte)[] zeroByteValue = cast(immutable(ubyte)[]) [0x00];
    immutable(ubyte)[] ffByteValue = cast(immutable(ubyte)[]) [0xff];
    immutable(ubyte)[] highBitByteValue = cast(immutable(ubyte)[]) [0x80];
    immutable(ubyte)[] invalidLeadByteValue = cast(immutable(ubyte)[]) [0xc0];
    ubyte[] sweepBuilder;
    foreach (b; 0 .. 256) sweepBuilder ~= cast(ubyte) b;
    immutable(ubyte)[] fullSweepValue = sweepBuilder.idup;

    auto byteRangeMeta = DocumentMetadata.empty()
        .withExtensionField("ext-zero", zeroByteValue, "stage-range")
        .withExtensionField("ext-ff", ffByteValue, "stage-range")
        .withExtensionField("ext-80", highBitByteValue, "stage-range")
        .withExtensionField("ext-c0", invalidLeadByteValue, "stage-range")
        .withExtensionField("ext-sweep", fullSweepValue, "stage-range");
    auto byteRangeWire = encodeDocumentMetadataV1(id, byteRangeMeta);
    auto decodedByteRange = decodeDocumentMetadataV1(id, byteRangeWire);
    assert(decodedByteRange.extensionFieldCount == 5);
    assert(decodedByteRange.extensionFields[0].value == zeroByteValue);
    assert(decodedByteRange.extensionFields[1].value == ffByteValue);
    assert(decodedByteRange.extensionFields[2].value == highBitByteValue);
    assert(decodedByteRange.extensionFields[3].value == invalidLeadByteValue);
    assert(decodedByteRange.extensionFields[4].value == fullSweepValue);

    // No silent overwrite.
    assertThrown(meta.withStandardField(StandardMetadataKey.title, "again", "stage-c"));
    assertThrown(meta.withExtensionField("ext-key", cast(immutable(ubyte)[]) [1], "stage-c"));

    // Wrong bound id.
    assertThrown(decodeDocumentMetadataV1(otherId, wire));

    // Duplicate extension key in raw wire.
    auto dupWire =
        `{"version":"document-metadata:v1","documentId":"` ~ id.text ~
        `","standard":{"title":null,"author":null,"date":null,"url":null},` ~
        `"extension":[{"key":"k","value":"ab","sourceStage":"s"},` ~
        `{"key":"k","value":"cd","sourceStage":"s"}]}` ~ "\n";
    assertThrown(decodeDocumentMetadataV1(id, dupWire));

    // Unknown standard key.
    auto unknownKeyWire =
        `{"version":"document-metadata:v1","documentId":"` ~ id.text ~
        `","standard":{"rights":null,"author":null,"date":null,"url":null},"extension":[]}` ~ "\n";
    assertThrown(decodeDocumentMetadataV1(id, unknownKeyWire));

    // Malformed UTF-8: an invalid standalone byte anywhere in the wire fails
    // the upfront whole-wire UTF-8 validation.
    auto badBytes = cast(ubyte[]) wire.dup;
    badBytes[$ - 3] = 0xff;
    assertThrown(decodeDocumentMetadataV1(id, cast(string) badBytes));

    // Caps: exactly-at accepted, one-over rejected.
    import std.array : replicate;

    auto atStandardCap = replicate("a", maxStandardValueBytes);
    assertNotThrown(DocumentMetadata.empty()
        .withStandardField(StandardMetadataKey.title, atStandardCap, "s"));
    auto overStandardCap = replicate("a", maxStandardValueBytes + 1);
    assertThrown(DocumentMetadata.empty()
        .withStandardField(StandardMetadataKey.title, overStandardCap, "s"));

    auto atSourceStage = replicate("a", maxSourceStageBytes);
    assertNotThrown(DocumentMetadata.empty()
        .withStandardField(StandardMetadataKey.title, "v", atSourceStage));
    auto overSourceStage = replicate("a", maxSourceStageBytes + 1);
    assertThrown(DocumentMetadata.empty()
        .withStandardField(StandardMetadataKey.title, "v", overSourceStage));

    auto atExtKey = replicate("k", maxExtensionKeyBytes);
    assertNotThrown(DocumentMetadata.empty()
        .withExtensionField(atExtKey, cast(immutable(ubyte)[]) [1], "s"));
    auto overExtKey = replicate("k", maxExtensionKeyBytes + 1);
    assertThrown(DocumentMetadata.empty()
        .withExtensionField(overExtKey, cast(immutable(ubyte)[]) [1], "s"));

    immutable(ubyte)[] atExtValue = cast(immutable(ubyte)[]) replicate(cast(immutable(ubyte)[]) [7], maxExtensionValueBytes);
    assertNotThrown(DocumentMetadata.empty().withExtensionField("k", atExtValue, "s"));
    immutable(ubyte)[] overExtValue = cast(immutable(ubyte)[]) replicate(cast(immutable(ubyte)[]) [7], maxExtensionValueBytes + 1);
    assertThrown(DocumentMetadata.empty().withExtensionField("k", overExtValue, "s"));

    import std.conv : to;

    DocumentMetadata atFieldCount = DocumentMetadata.empty();
    foreach (i; 0 .. maxExtensionFields)
        atFieldCount = atFieldCount.withExtensionField("k" ~ to!string(i), cast(immutable(ubyte)[]) [1], "s");
    assert(atFieldCount.extensionFieldCount == maxExtensionFields);
    assertThrown(atFieldCount.withExtensionField("overflow", cast(immutable(ubyte)[]) [1], "s"));
}
