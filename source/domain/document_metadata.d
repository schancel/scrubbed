/// Bounded, immutable-style document metadata: an independent v1 standard-key
/// set plus open, opaque extension fields, each with bounded provenance and a
/// versioned wire format. This type is deliberately unwired: it does not
/// import `effects.html_metadata` and nothing in `source/stages` or
/// `source/composition` references it. `DocumentId` is bound only at the
/// `encodeDocumentMetadataV1`/`decodeDocumentMetadataV1` boundary, never
/// inside the in-flight value, mirroring `effects.html_metadata`'s
/// `serializeHtmlMetadata(DocumentId id, const HtmlMetadata metadata)`.
///
/// `document-metadata:v2` (issue #300 Slice 1) adds one additive capability
/// on top of the above, unchanged v1 shape: a bounded "structured section"
/// entry (`StructuredSectionEntry`, `.withStructuredSection`,
/// `encodeDocumentMetadataV2`/`decodeDocumentMetadataV2`) sized to hold a
/// PII-scale opaque payload rather than a small scalar. See
/// `docs/document-metadata.md` for the full numeric bounds and their
/// justification. This slice is domain-only: no stage, executor, compiler,
/// or preset wires this capability to anything yet.
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

// ---------------------------------------------------------------------------
// `document-metadata:v2` structured-section caps. Independent of, and in
// addition to, the frozen v1 caps above -- see docs/document-metadata.md for
// the full worked-out numeric justification. Summary: `stages.pii_four_class`
// (`maxPiiAuditBytesV1 = 1024 * 1024`, ~144 bytes/finding, ~80 bytes/union
// envelope) is the real-world payload this capability is sized against, per
// issue #300's Slice 1 contract.
// ---------------------------------------------------------------------------

/// A structured section's caller-chosen identity string, bounded the same
/// way `maxExtensionKeyBytes` bounds an extension key -- a small, opaque
/// caller-chosen label, not a payload.
enum size_t maxStructuredSectionIdentityBytes = 64;

/// At most this many structured sections per `DocumentMetadata` value. Kept
/// deliberately small: this capability exists for large, per-producer
/// payloads (one section per producer, e.g. a future pii-four-class,
/// language-id-detect, or topical-tags-extract convergence), not as a
/// second general-purpose small-field mechanism like extension fields. Four
/// covers the three named future convergence candidates plus one spare.
enum size_t maxStructuredSections = 4;

/// Per-section raw payload cap: exactly 2x `stages.pii_four_class`'s own
/// existing `maxPiiAuditBytesV1` (1024*1024 = 1 MiB), i.e. 2 MiB. PII's own
/// cap already carries built-in headroom over its naive worst-case estimate
/// (4096 max findings * (144 + 80) bytes =~ 917,504 bytes, ~128 KiB under
/// PII's own 1 MiB cap); doubling PII's cap again here gives a second,
/// independent margin so this capability is not the tightest constraint if
/// a future producer's per-record cost or record count grows moderately
/// before this cap is revisited.
enum size_t maxStructuredSectionPayloadBytes = 2 * 1024 * 1024;

/// Aggregate raw payload budget across *all* structured sections in one
/// `DocumentMetadata` value. Deliberately the same order of magnitude as
/// the per-section cap (not `maxStructuredSections` times it): in practice
/// only one producer is expected to need a PII-scale payload in a given
/// document at once, so the whole capability is budgeted once, at PII scale
/// x2, rather than multiplying by section count and allowing an unbounded
/// blow-up if `maxStructuredSections` is ever raised.
enum size_t maxStructuredSectionsAggregatePayloadBytes = 2 * 1024 * 1024;

/// Full `document-metadata:v2` wire cap. A closed-form sum of independently
/// justified sub-budgets, not a rounded guess: the full v1 aggregate budget
/// (`maxTotalEncodedBytes`, reserved untouched for standard + scalar-
/// extension fields, unaffected by structured sections -- see
/// `withStandardField`/`withExtensionField`, which still check only the v1
/// budget), plus the structured-section aggregate payload budget hex-encoded
/// (`putHex` always doubles raw bytes, a fixed, non-escaping 2x expansion),
/// plus a worst-case JSON-escaped section identity and punctuation allowance
/// per section slot. Because the v1 budget and the structured-section
/// budget are each independently, unconditionally enforced regardless of
/// mutation order, their sum can never be exceeded by any value constructed
/// through the public API -- this cap and its own eager mutation-time check
/// in `withStructuredSection` are defense in depth, matching every other
/// `.withX` mutator's idiom exactly, not the only thing preventing overrun.
enum size_t maxTotalEncodedBytesV2 = maxTotalEncodedBytes
    + 2 * maxStructuredSectionsAggregatePayloadBytes
    + maxStructuredSections * (maxStructuredSectionIdentityBytes * 6 + 64);

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

/// One caller-chosen, independently-bounded `document-metadata:v2`
/// structured section. The payload is raw opaque bytes and is never
/// interpreted by this module -- the same "opaque bounded payload" contract
/// as `ExtensionEntry.value`, but budgeted on a completely separate, much
/// larger scale (see the `maxStructuredSection*` caps above) because a
/// structured section is meant to hold something PII-scale, not a small
/// scalar.
struct StructuredSectionEntry {
    string sectionId;
    immutable(ubyte)[] payload;
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
    private StructuredSectionEntry[] structuredSectionEntries;

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

    /// Reject a second write to an already-set section identity at
    /// construction time; enforce every `document-metadata:v2` cap eagerly,
    /// matching `withExtensionField`'s idiom exactly. Adding a structured
    /// section never touches, and is never bounded by, the frozen v1
    /// `maxTotalEncodedBytes` budget reserved for standard + scalar-
    /// extension fields (`withStandardField`/`withExtensionField` are
    /// unchanged by this addition) -- it has its own independent
    /// per-section, aggregate, and count caps, plus the combined
    /// `maxTotalEncodedBytesV2` full-wire cap checked here as defense in
    /// depth.
    DocumentMetadata withStructuredSection(string sectionId, immutable(ubyte)[] payload,
            string sourceStage) pure {
        checkSourceStage(sourceStage);
        enforce(sectionId.length != 0 && sectionId.length <= maxStructuredSectionIdentityBytes,
            "document metadata: malformed structured section id");
        validateUtf8Field(sectionId);
        enforce(payload.length <= maxStructuredSectionPayloadBytes,
            "document metadata: structured section payload too long");
        enforce(structuredSectionEntries.length < maxStructuredSections,
            "document metadata: structured section capacity exceeded");
        foreach (entry; structuredSectionEntries)
            enforce(entry.sectionId != sectionId,
                "document metadata: structured section id already set");
        size_t existingAggregate;
        foreach (entry; structuredSectionEntries) existingAggregate += entry.payload.length;
        enforce(existingAggregate + payload.length <= maxStructuredSectionsAggregatePayloadBytes,
            "document metadata: structured section aggregate payload capacity exceeded");
        DocumentMetadata result = this;
        result.structuredSectionEntries =
            structuredSectionEntries ~ StructuredSectionEntry(sectionId, payload, sourceStage);
        encodeBodyV2(maxDocumentIdPlaceholder, result); // eager aggregate cap check
        return result;
    }

    size_t structuredSectionCount() const pure { return structuredSectionEntries.length; }

    const(StructuredSectionEntry)[] structuredSections() const pure { return structuredSectionEntries; }
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
    // v1's `encodeBody` never sets this, so it keeps its exact original
    // `maxTotalEncodedBytes` (64 KiB) limit and byte-for-byte behavior;
    // `encodeBodyV2` overrides it to `maxTotalEncodedBytesV2` before any
    // `put` call.
    size_t limit = maxTotalEncodedBytes;

    void put(scope const(char)[] value) pure {
        if (value.length > limit - bytes.length)
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

// Shared by `encodeBody` (v1) and `encodeBodyV2`: writes the identical
// `"standard":{...},"extension":[...]` shape both versions carry unchanged.
// Extracting this common piece (rather than duplicating it) is what makes
// v1's byte-for-byte-unchanged guarantee mechanically enforced instead of
// merely asserted by inspection.
private void putStandardAndExtensionFields(ref Writer writer, const DocumentMetadata metadata) pure {
    writer.put(`"standard":{`);
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
    writer.put(`]`);
}

private immutable(char)[] encodeBody(string idText, const DocumentMetadata metadata) pure {
    Writer writer;
    writer.put(`{"version":"document-metadata:v1","documentId":`);
    writer.quoted(idText);
    writer.put(`,`);
    putStandardAndExtensionFields(writer, metadata);
    writer.put("}\n");
    return writer.bytes.idup;
}

/// Fixed key order and one trailing LF are `document-metadata:v1`'s canonical
/// wire. `DocumentId` is bound only here, at the encode boundary. Fails
/// closed (rather than silently dropping data) if `metadata` carries any
/// `document-metadata:v2`-only structured section: v1 has no wire shape for
/// them. This guard sits only in the public entry point, not in the private
/// `encodeBody` helper that `withStandardField`/`withExtensionField` also
/// call internally for their own eager v1-shape cap check -- a value built
/// via `.withStructuredSection(...).withStandardField(...)` must still be
/// constructible; only actually encoding it as `document-metadata:v1` is
/// refused.
string encodeDocumentMetadataV1(DocumentId id, const DocumentMetadata metadata) pure {
    enforce(metadata.structuredSectionEntries.length == 0,
        "document metadata: v1 cannot encode structured sections");
    return cast(string) encodeBody(id.text, metadata);
}

// ---------------------------------------------------------------------------
// Wire format `document-metadata:v2`: additive over v1 -- identical
// `"standard"`/`"extension"` shape (see `putStandardAndExtensionFields`),
// plus a trailing `"structuredSections"` array. v1's own encode/decode pair
// above is untouched by this addition.
// ---------------------------------------------------------------------------

private immutable(char)[] encodeBodyV2(string idText, const DocumentMetadata metadata) pure {
    Writer writer;
    writer.limit = maxTotalEncodedBytesV2;
    writer.put(`{"version":"document-metadata:v2","documentId":`);
    writer.quoted(idText);
    writer.put(`,`);
    putStandardAndExtensionFields(writer, metadata);
    writer.put(`,"structuredSections":[`);
    foreach (i, entry; metadata.structuredSectionEntries) {
        if (i) writer.put(",");
        writer.put(`{"sectionId":`);
        writer.quoted(entry.sectionId);
        writer.put(`,"payload":"`);
        writer.putHex(entry.payload);
        writer.put(`","sourceStage":`);
        writer.quoted(entry.sourceStage);
        writer.put(`}`);
    }
    writer.put("]}\n");
    return writer.bytes.idup;
}

/// `document-metadata:v2` adds one trailing `"structuredSections"` array
/// after v1's unchanged `"standard"`/`"extension"` shape. `DocumentId` is
/// bound only here, at the encode boundary, exactly as in v1.
string encodeDocumentMetadataV2(DocumentId id, const DocumentMetadata metadata) pure {
    return cast(string) encodeBodyV2(id.text, metadata);
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

/// Fails closed on everything `decodeDocumentMetadataV1` does (a wrong bound
/// `DocumentId`, an unknown standard key, a duplicate extension key, any cap
/// violation, malformed UTF-8) plus, for the added `"structuredSections"`
/// array: a malformed or unrecognized section entry shape (the strict
/// `Cursor.expect` literal for the `"sectionId"`/`"payload"`/`"sourceStage"`
/// keys rejects any other key name or missing/unversioned section-entry
/// shape the same way it already rejects an unknown standard key), a
/// truncated section body, and a duplicate section identity. Diagnostics
/// are content-free: no raw payload/canary bytes are echoed into any
/// exception message.
DocumentMetadata decodeDocumentMetadataV2(DocumentId expectedId, string wire) pure {
    enforce(wire.length <= maxTotalEncodedBytesV2,
        "document metadata: wire exceeds size limit");
    try {
        validate(wire);
    } catch (UTFException) {
        throw new Exception("document metadata: malformed utf-8");
    }

    auto cursor = Cursor(wire, 0);
    cursor.expect(`{"version":"document-metadata:v2","documentId":`);
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
    cursor.expect(`,"structuredSections":[`);

    if (!cursor.tryLiteral("]")) {
        while (true) {
            cursor.expect(`{"sectionId":`);
            auto sectionId = cursor.parseQuotedString();
            cursor.expect(`,"payload":`);
            auto payload = cursor.parseHexBytes();
            cursor.expect(`,"sourceStage":`);
            auto sourceStage = cursor.parseQuotedString();
            cursor.expect(`}`);
            metadata = metadata.withStructuredSection(sectionId, payload, sourceStage);
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

// ---------------------------------------------------------------------------
// `document-metadata:v2` structured-section coverage (issue #300 Slice 1).
// The unittest above is entirely unmodified: this is a new, separate block,
// proving the additive capability without touching a single byte of the v1
// regression proof.
// ---------------------------------------------------------------------------
unittest {
    import domain.document : SourceLocator;
    import std.array : replicate;
    import std.conv : to;
    import std.exception : assertThrown, assertNotThrown;

    auto id = DocumentId.from(SourceLocator("ns", "src", "rec"));
    auto otherId = DocumentId.from(SourceLocator("ns", "src", "other"));

    // v2 empty value round-trips, canonical wire pinned.
    auto empty = DocumentMetadata.empty();
    auto emptyWireV2 = encodeDocumentMetadataV2(id, empty);
    assert(emptyWireV2 ==
        `{"version":"document-metadata:v2","documentId":"` ~ id.text ~
        `","standard":{"title":null,"author":null,"date":null,"url":null},` ~
        `"extension":[],"structuredSections":[]}` ~ "\n");
    auto decodedEmptyV2 = decodeDocumentMetadataV2(id, emptyWireV2);
    assert(decodedEmptyV2.structuredSectionCount == 0);

    // Representative standard + extension + one structured section, exact byte pin.
    auto meta = DocumentMetadata.empty()
        .withStandardField(StandardMetadataKey.title, "Hello \"World\"", "stage-a")
        .withExtensionField("ext-key", cast(immutable(ubyte)[]) [0xde, 0xad, 0xbe, 0xef], "stage-b")
        .withStructuredSection("pii-audit-v1", cast(immutable(ubyte)[]) [0x01, 0x02, 0x03], "stage-c");
    auto wireV2 = encodeDocumentMetadataV2(id, meta);
    assert(wireV2 ==
        `{"version":"document-metadata:v2","documentId":"` ~ id.text ~
        `","standard":{"title":{"value":"Hello \"World\"","sourceStage":"stage-a"},` ~
        `"author":null,"date":null,"url":null},` ~
        `"extension":[{"key":"ext-key","value":"deadbeef","sourceStage":"stage-b"}],` ~
        `"structuredSections":[{"sectionId":"pii-audit-v1","payload":"010203","sourceStage":"stage-c"}]}` ~ "\n");
    auto decodedV2 = decodeDocumentMetadataV2(id, wireV2);
    assert(decodedV2.standardValue(StandardMetadataKey.title) == "Hello \"World\"");
    assert(decodedV2.extensionFieldCount == 1);
    assert(decodedV2.structuredSectionCount == 1);
    assert(decodedV2.structuredSections[0].sectionId == "pii-audit-v1");
    assert(decodedV2.structuredSections[0].payload == cast(immutable(ubyte)[]) [0x01, 0x02, 0x03]);
    assert(decodedV2.structuredSections[0].sourceStage == "stage-c");

    // v1's own encode/decode are untouched: a pure-v1-shape value (no
    // structured section) still produces the exact v1 wire from the
    // original unittest block above.
    auto v1Combo = DocumentMetadata.empty()
        .withStandardField(StandardMetadataKey.title, "Hello \"World\"", "stage-a")
        .withExtensionField("ext-key", cast(immutable(ubyte)[]) [0xde, 0xad, 0xbe, 0xef], "stage-b");
    assert(encodeDocumentMetadataV1(id, v1Combo) ==
        `{"version":"document-metadata:v1","documentId":"` ~ id.text ~
        `","standard":{"title":{"value":"Hello \"World\"","sourceStage":"stage-a"},` ~
        `"author":null,"date":null,"url":null},` ~
        `"extension":[{"key":"ext-key","value":"deadbeef","sourceStage":"stage-b"}]}` ~ "\n");
    // A value that DOES use the v2-only capability cannot be silently
    // dropped into a v1 wire.
    assertThrown(encodeDocumentMetadataV1(id, meta));
    // But it remains fully constructible even after mixing in more v1-shape
    // fields on top of the structured section (internal v1 eager cap check
    // must not itself choke on a present structured section).
    assertNotThrown(meta.withStandardField(StandardMetadataKey.author, "more", "stage-d"));

    // --- ~1 MiB-class structured-section fixture: many small fixed-size
    // records, the same "plausible worst-case shape" pii-four-class's own
    // maxPiiAuditBytesV1 is sized against. 4096 records * 256 bytes each =
    // 1,048,576 bytes exactly (== maxPiiAuditBytesV1), comfortably under
    // this slice's own maxStructuredSectionPayloadBytes (2 MiB). ----------
    enum size_t recordSize = 256;
    enum size_t recordCount = 4096;
    static assert(recordSize * recordCount == 1024 * 1024);
    ubyte[] largeBuilder;
    largeBuilder.reserve(recordSize * recordCount);
    foreach (i; 0 .. recordCount) {
        ubyte[recordSize] record;
        record[0] = cast(ubyte) (i & 0xff);
        record[1] = cast(ubyte) ((i >> 8) & 0xff);
        record[2 .. $] = cast(ubyte) 0xab;
        largeBuilder ~= record[];
    }
    immutable(ubyte)[] largePayload = largeBuilder.idup;
    assert(largePayload.length == 1024 * 1024);
    auto largeMeta = DocumentMetadata.empty()
        .withStructuredSection("pii-audit-v1", largePayload, "stage-pii");
    auto largeWire = encodeDocumentMetadataV2(id, largeMeta);
    auto decodedLarge = decodeDocumentMetadataV2(id, largeWire);
    assert(decodedLarge.structuredSectionCount == 1);
    assert(decodedLarge.structuredSections[0].payload == largePayload);

    // --- Cap-boundary fixtures: exactly-at-cap accepted, one byte over
    // rejected, eager at mutation time. ----------------------------------
    auto atSectionId = replicate("s", maxStructuredSectionIdentityBytes);
    assertNotThrown(DocumentMetadata.empty()
        .withStructuredSection(atSectionId, cast(immutable(ubyte)[]) [1], "s"));
    auto overSectionId = replicate("s", maxStructuredSectionIdentityBytes + 1);
    assertThrown(DocumentMetadata.empty()
        .withStructuredSection(overSectionId, cast(immutable(ubyte)[]) [1], "s"));

    immutable(ubyte)[] atSectionPayload =
        cast(immutable(ubyte)[]) replicate(cast(immutable(ubyte)[]) [7], maxStructuredSectionPayloadBytes);
    assertNotThrown(DocumentMetadata.empty().withStructuredSection("s", atSectionPayload, "s"));
    immutable(ubyte)[] overSectionPayload =
        cast(immutable(ubyte)[]) replicate(cast(immutable(ubyte)[]) [7], maxStructuredSectionPayloadBytes + 1);
    assertThrown(DocumentMetadata.empty().withStructuredSection("s", overSectionPayload, "s"));

    // Aggregate payload cap: two sections whose individual sizes are each
    // comfortably under the per-section cap, but whose sum sits exactly at,
    // then one byte over, maxStructuredSectionsAggregatePayloadBytes.
    immutable(ubyte)[] firstAtAggregate =
        cast(immutable(ubyte)[]) replicate(cast(immutable(ubyte)[]) [1],
            maxStructuredSectionsAggregatePayloadBytes - 1);
    assertNotThrown(DocumentMetadata.empty()
        .withStructuredSection("first", firstAtAggregate, "s")
        .withStructuredSection("second", cast(immutable(ubyte)[]) [2], "s"));
    assertThrown(DocumentMetadata.empty()
        .withStructuredSection("first", firstAtAggregate, "s")
        .withStructuredSection("second", cast(immutable(ubyte)[]) [2, 3], "s"));

    // Section count cap: exactly at accepted, one over rejected.
    DocumentMetadata atSectionCount = DocumentMetadata.empty();
    foreach (i; 0 .. maxStructuredSections)
        atSectionCount = atSectionCount.withStructuredSection(
            "sec" ~ to!string(i), cast(immutable(ubyte)[]) [1], "s");
    assert(atSectionCount.structuredSectionCount == maxStructuredSections);
    assertThrown(atSectionCount.withStructuredSection("overflow", cast(immutable(ubyte)[]) [1], "s"));

    // No silent overwrite: duplicate section identity refused at construction time.
    assertThrown(meta.withStructuredSection("pii-audit-v1", cast(immutable(ubyte)[]) [9], "stage-x"));

    // --- Decode fails closed. --------------------------------------------

    // Wrong bound id.
    assertThrown(decodeDocumentMetadataV2(otherId, wireV2));

    // Duplicate section identity in raw wire.
    auto dupSectionWire =
        `{"version":"document-metadata:v2","documentId":"` ~ id.text ~
        `","standard":{"title":null,"author":null,"date":null,"url":null},"extension":[],` ~
        `"structuredSections":[{"sectionId":"dup","payload":"ab","sourceStage":"s"},` ~
        `{"sectionId":"dup","payload":"cd","sourceStage":"s"}]}` ~ "\n";
    assertThrown(decodeDocumentMetadataV2(id, dupSectionWire));

    // Unknown/unversioned section identity: the wire uses a key other than
    // the recognized "sectionId" literal for a section entry.
    auto unknownSectionKeyWire =
        `{"version":"document-metadata:v2","documentId":"` ~ id.text ~
        `","standard":{"title":null,"author":null,"date":null,"url":null},"extension":[],` ~
        `"structuredSections":[{"unversionedId":"x","payload":"ab","sourceStage":"s"}]}` ~ "\n";
    assertThrown(decodeDocumentMetadataV2(id, unknownSectionKeyWire));

    // Malformed section wire: payload hex string with a non-hex character.
    auto malformedSectionWire =
        `{"version":"document-metadata:v2","documentId":"` ~ id.text ~
        `","standard":{"title":null,"author":null,"date":null,"url":null},"extension":[],` ~
        `"structuredSections":[{"sectionId":"s","payload":"zz","sourceStage":"s"}]}` ~ "\n";
    assertThrown(decodeDocumentMetadataV2(id, malformedSectionWire));

    // Truncated section body: wire cut off mid-section, before the closing brace.
    auto truncatedSectionWire =
        `{"version":"document-metadata:v2","documentId":"` ~ id.text ~
        `","standard":{"title":null,"author":null,"date":null,"url":null},"extension":[],` ~
        `"structuredSections":[{"sectionId":"s","payload":"ab"`;
    assertThrown(decodeDocumentMetadataV2(id, truncatedSectionWire));

    // Unknown standard key still rejected under v2 (same fixed grammar).
    auto unknownKeyWireV2 =
        `{"version":"document-metadata:v2","documentId":"` ~ id.text ~
        `","standard":{"rights":null,"author":null,"date":null,"url":null},"extension":[],` ~
        `"structuredSections":[]}` ~ "\n";
    assertThrown(decodeDocumentMetadataV2(id, unknownKeyWireV2));

    // Malformed UTF-8.
    auto badBytesV2 = cast(ubyte[]) wireV2.dup;
    badBytesV2[$ - 3] = 0xff;
    assertThrown(decodeDocumentMetadataV2(id, cast(string) badBytesV2));

    // Oversize wire: one byte over maxTotalEncodedBytesV2 rejected at the
    // upfront size gate.
    auto oversizeBuffer = new ubyte[maxTotalEncodedBytesV2 + 1];
    oversizeBuffer[] = cast(ubyte) 'x';
    assertThrown(decodeDocumentMetadataV2(id, cast(string) oversizeBuffer));
}
