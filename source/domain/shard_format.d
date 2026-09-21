/// Binary v1 document shards and analyzer-overlay record values. No filesystem effects.
module domain.shard_format;

import domain.document : DocumentId, OutputName, SourceLocator;
import std.digest.sha : sha256Of;
import std.exception : enforce;
import std.string : indexOf;
import std.uni : normalize;
import std.utf : validate;

enum ubyte[] documentMagic = cast(ubyte[]) "SCRBDOC1";
enum ubyte[] overlayMagic = cast(ubyte[]) "SCRBANN1";
enum uint maxDocumentPayload = 1024 * 1024;
enum uint maxAnnotationPayload = 64 * 1024;
enum uint maxOverlayMetadata = 4096;
enum size_t maxOverlayFanIn = 32;

struct ShardDocument {
    SourceLocator source;
    OutputName outputName;
    ubyte[] content;
    DocumentId id() const { return DocumentId.from(source); }
    ubyte[32] contentDigest() const { return sha256Of(content); }
}

struct AnnotationField {
    string key;
    ubyte[] value;
}

struct AnnotationRecord {
    string documentId;
    ubyte[32] contentDigest;
    AnnotationField[] fields;
}

struct OverlayHeader {
    string analyzerKey;
    string analyzerVersion;
    ubyte[32] sourceShardDigest;
}

private void require(bool okay, string reason) {
    enforce(okay, "shard format: " ~ reason);
}

string canonical(string value) {
    require(value.length != 0 && value.length <= ushort.max, "empty or oversized metadata field");
    validate(value);
    require(value.indexOf('\0') < 0 && normalize(value) == value, "noncanonical metadata field");
    return value;
}

private void u16(ref ubyte[] outBytes, size_t value) {
    require(value <= ushort.max, "u16 overflow");
    outBytes ~= cast(ubyte)(value >> 8);
    outBytes ~= cast(ubyte)value;
}

private void u32(ref ubyte[] outBytes, size_t value) {
    require(value <= uint.max, "u32 overflow");
    foreach_reverse (shift; [0, 8, 16, 24]) outBytes ~= cast(ubyte)(value >> shift);
}

private void text16(ref ubyte[] outBytes, string value) {
    canonical(value);
    u16(outBytes, value.length);
    outBytes ~= cast(const(ubyte)[])value;
}

private void budget(ref size_t remaining, size_t amount) {
    require(amount <= remaining, "payload exceeds cap");
    remaining -= amount;
}

private struct Cursor {
    const(ubyte)[] bytes;
    size_t at;
    this(const(ubyte)[] bytes) { this.bytes = bytes; }
    const(ubyte)[] take(size_t amount) {
        require(amount <= bytes.length - at, "truncated payload");
        auto result = bytes[at .. at + amount];
        at += amount;
        return result;
    }
    size_t read16() {
        auto b = take(2);
        return (cast(size_t)b[0] << 8) | b[1];
    }
    size_t read32() {
        auto b = take(4);
        return (cast(size_t)b[0] << 24) | (cast(size_t)b[1] << 16) |
            (cast(size_t)b[2] << 8) | b[3];
    }
    string readText16() {
        auto b = take(read16());
        auto value = cast(string)b.idup;
        return canonical(value);
    }
    void end() { require(at == bytes.length, "trailing payload bytes"); }
}

ubyte[] encodeDocument(ShardDocument record) {
    // Validate the complete encoded size before copying opaque caller content.
    size_t remaining = maxDocumentPayload;
    foreach (field; [record.source.datasetNamespace, record.source.sourceKey,
            record.source.recordKey, record.outputName.text]) {
        canonical(field);
        budget(remaining, 2);
        budget(remaining, field.length);
    }
    budget(remaining, 4);
    budget(remaining, record.content.length);
    ubyte[] payload;
    text16(payload, record.source.datasetNamespace);
    text16(payload, record.source.sourceKey);
    text16(payload, record.source.recordKey);
    text16(payload, record.outputName.text);
    u32(payload, record.content.length);
    payload ~= record.content;
    require(payload.length <= maxDocumentPayload, "document payload exceeds cap");
    return payload;
}

ShardDocument decodeDocument(const(ubyte)[] payload) {
    require(payload.length <= maxDocumentPayload, "document payload exceeds cap");
    auto cursor = Cursor(payload);
    auto ns = cursor.readText16();
    auto source = cursor.readText16();
    auto key = cursor.readText16();
    auto name = cursor.readText16();
    auto content = cursor.take(cursor.read32()).dup;
    cursor.end();
    return ShardDocument(SourceLocator(ns, source, key), OutputName(name), content);
}

private bool canonicalId(string value) {
    if (value.length != 71 || value[0 .. 7] != "doc:v1:") return false;
    foreach (c; value[7 .. $])
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
    return true;
}

ubyte[] encodeAnnotation(AnnotationRecord record) {
    require(canonicalId(record.documentId), "noncanonical source document ID");
    require(record.fields.length <= ushort.max, "too many annotation fields");
    // Preflight every key and opaque value before allocating the frame payload.
    size_t remaining = maxAnnotationPayload;
    budget(remaining, 2 + record.documentId.length);
    budget(remaining, 32 + 2);
    string previous;
    foreach (field; record.fields) {
        canonical(field.key);
        require(previous.length == 0 || previous < field.key, "fields not strictly sorted");
        previous = field.key;
        budget(remaining, 2 + field.key.length);
        budget(remaining, 4);
        budget(remaining, field.value.length);
    }
    ubyte[] payload;
    text16(payload, record.documentId);
    payload ~= record.contentDigest[];
    u16(payload, record.fields.length);
    foreach (field; record.fields) {
        text16(payload, field.key);
        u32(payload, field.value.length);
        payload ~= field.value;
    }
    require(payload.length <= maxAnnotationPayload, "annotation payload exceeds cap");
    return payload;
}

AnnotationRecord decodeAnnotation(const(ubyte)[] payload) {
    require(payload.length <= maxAnnotationPayload, "annotation payload exceeds cap");
    auto cursor = Cursor(payload);
    AnnotationRecord record;
    record.documentId = cursor.readText16();
    require(canonicalId(record.documentId), "noncanonical source document ID");
    record.contentDigest[] = cursor.take(32)[];
    auto count = cursor.read16();
    string previous;
    foreach (_; 0 .. count) {
        auto key = cursor.readText16();
        require(previous.length == 0 || previous < key, "fields not strictly sorted");
        previous = key;
        record.fields ~= AnnotationField(key, cursor.take(cursor.read32()).dup);
    }
    cursor.end();
    return record;
}

ubyte[] encodeOverlayHeader(OverlayHeader header) {
    canonical(header.analyzerKey);
    canonical(header.analyzerVersion);
    size_t remaining = maxOverlayMetadata;
    budget(remaining, 2 + header.analyzerKey.length);
    budget(remaining, 2 + header.analyzerVersion.length);
    budget(remaining, 32);
    ubyte[] metadata;
    text16(metadata, header.analyzerKey);
    text16(metadata, header.analyzerVersion);
    metadata ~= header.sourceShardDigest[];
    require(metadata.length <= maxOverlayMetadata, "overlay metadata exceeds cap");
    ubyte[] bytes = overlayMagic.dup;
    u16(bytes, metadata.length);
    bytes ~= metadata;
    bytes ~= sha256Of(bytes)[];
    return bytes;
}

OverlayHeader decodeOverlayHeader(const(ubyte)[] bytes) {
    require(bytes.length >= 10 + 32 && bytes[0 .. 8] == overlayMagic,
        "bad overlay magic or short header");
    auto length = (cast(size_t)bytes[8] << 8) | bytes[9];
    require(length <= maxOverlayMetadata && bytes.length == 10 + length + 32,
        "bad overlay metadata length");
    require(sha256Of(bytes[0 .. 10 + length])[] == bytes[10 + length .. $],
        "overlay header digest mismatch");
    auto cursor = Cursor(bytes[10 .. 10 + length]);
    OverlayHeader header;
    header.analyzerKey = cursor.readText16();
    header.analyzerVersion = cursor.readText16();
    header.sourceShardDigest[] = cursor.take(32)[];
    cursor.end();
    return header;
}

ubyte[] frame(const(ubyte)[] payload, uint limit) {
    require(payload.length <= limit, "frame exceeds cap");
    ubyte[] bytes;
    u32(bytes, payload.length);
    bytes ~= payload;
    bytes ~= sha256Of(payload)[];
    return bytes;
}
