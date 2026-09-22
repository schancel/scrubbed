/// Opt-in canonical JSONL projection for structured chunks; no index or I/O.
module effects.chunk_jsonl;

import domain.document : DocumentId;
import domain.structured_chunks : ChunkId, ChunkMetadata, StructuredChunk,
    chunkId, chunkSchema, maxChunkBytes, maxMetadataBytes,
    maxStructuredTextBytes;
import std.conv : to;
import std.exception : enforce;
import std.json : JSONType, JSONValue, parseJSON;
import std.utf : validate;

enum size_t maxChunkJsonlBytes = 16 * 1024;

private string quoted(string value) { return JSONValue(value).toString; }

private string numbers(const(uint)[] values) {
    string result = "[";
    foreach (i, value; values) {
        if (i) result ~= ",";
        result ~= value.to!string;
    }
    return result ~ "]";
}

private string paths(const(uint[][]) values) {
    string result = "[";
    foreach (i, value; values) {
        if (i) result ~= ",";
        result ~= numbers(value);
    }
    return result ~ "]";
}

private void checkChunk(const ref StructuredChunk chunk) {
    enforce(chunk.documentId.text.length != 0 &&
        chunk.contentRevision.length > 0 && chunk.contentRevision.length <= 128 &&
        chunk.path.length >= 2 && chunk.path.length <= 33 &&
        chunk.sectionPaths.length + chunk.pagePaths.length <= 32 &&
        chunk.text.length > 0 && chunk.text.length <= maxChunkBytes &&
        chunk.start < chunk.end && chunk.end <= maxStructuredTextBytes &&
        chunk.end - chunk.start == chunk.text.length &&
        chunk.metadata.language.length <= maxMetadataBytes &&
        chunk.metadata.title.length <= maxMetadataBytes &&
        chunk.metadata.sourceLabel.length <= maxMetadataBytes,
        "chunk JSONL: invalid chunk bounds");
    validate(chunk.contentRevision);
    validate(chunk.text);
    validate(chunk.metadata.language);
    validate(chunk.metadata.title);
    validate(chunk.metadata.sourceLabel);
    bool[33] usedDepth;
    size_t previousDepth;
    foreach (path; chunk.sectionPaths) {
        enforce(path.length > 0 && path.length < chunk.path.length - 1 &&
            chunk.path[0 .. path.length] == path &&
            path.length > previousDepth && !usedDepth[path.length],
            "chunk JSONL: invalid ancestry");
        usedDepth[path.length] = true;
        previousDepth = path.length;
    }
    previousDepth = 0;
    foreach (path; chunk.pagePaths) {
        enforce(path.length > 0 && path.length < chunk.path.length - 1 &&
            chunk.path[0 .. path.length] == path &&
            path.length > previousDepth && !usedDepth[path.length],
            "chunk JSONL: invalid ancestry");
        usedDepth[path.length] = true;
        previousDepth = path.length;
    }
    enforce(chunk.id == chunkId(chunk.documentId, chunk.path, chunk.text),
        "chunk JSONL: identity mismatch");
}

/// One deterministic row including LF. Caller decides whether and where to write.
string encodeChunkJsonl(const ref StructuredChunk chunk) {
    checkChunk(chunk);
    auto row = "{\"schema\":\"structured-chunk:v1\",\"version\":" ~
        chunkSchema.to!string ~ ",\"document_id\":" ~ quoted(chunk.documentId.text) ~
        ",\"content_revision\":" ~ quoted(chunk.contentRevision) ~
        ",\"chunk_id\":" ~ quoted(chunk.id.text) ~
        ",\"start\":" ~ chunk.start.to!string ~
        ",\"end\":" ~ chunk.end.to!string ~
        ",\"path\":" ~ numbers(chunk.path) ~
        ",\"section_paths\":" ~ paths(chunk.sectionPaths) ~
        ",\"page_paths\":" ~ paths(chunk.pagePaths) ~
        ",\"metadata\":{\"language\":" ~ quoted(chunk.metadata.language) ~
        ",\"title\":" ~ quoted(chunk.metadata.title) ~
        ",\"source_label\":" ~ quoted(chunk.metadata.sourceLabel) ~
        "},\"text\":" ~ quoted(chunk.text) ~ "}\n";
    enforce(row.length <= maxChunkJsonlBytes,
        "chunk JSONL: row too large");
    return row;
}

private string fieldString(JSONValue value) {
    enforce(value.type == JSONType.string, "chunk JSONL: invalid field");
    return value.str;
}

private size_t fieldOffset(JSONValue value) {
    enforce(value.type == JSONType.integer && value.integer >= 0 &&
        value.integer <= 1024 * 1024, "chunk JSONL: invalid offset");
    return cast(size_t)value.integer;
}

private uint[] readPath(JSONValue value) {
    enforce(value.type == JSONType.array && value.array.length <= 33,
        "chunk JSONL: invalid path");
    uint[] result;
    foreach (member; value.array) {
        enforce(member.type == JSONType.integer && member.integer >= 0 &&
            member.integer <= uint.max, "chunk JSONL: invalid path");
        result ~= cast(uint)member.integer;
    }
    return result;
}

private uint[][] readPaths(JSONValue value) {
    enforce(value.type == JSONType.array && value.array.length <= 32,
        "chunk JSONL: invalid ancestry");
    uint[][] result;
    foreach (member; value.array) result ~= readPath(member);
    return result;
}

/// Strict canonical reader: re-encoding rejects alternate schema, key order,
/// whitespace, duplicate/unknown fields and noncanonical escaping.
StructuredChunk decodeChunkJsonl(string row) {
    enforce(row.length <= maxChunkJsonlBytes && row.length > 0,
        "chunk JSONL: row too large or empty");
    try {
        // The deepest canonical value is root -> path array -> ordinal array
        // -> number. std.json counts the scalar as a level too.
        // std.json's default (-1) permits attacker-controlled recursion.
        auto value = parseJSON(row, 3);
        enforce(value.type == JSONType.object &&
            fieldString(value["schema"]) == "structured-chunk:v1" &&
            value["version"].type == JSONType.integer &&
            value["version"].integer == chunkSchema,
            "chunk JSONL: unsupported schema");
        StructuredChunk chunk;
        chunk.documentId = DocumentId.fromCanonicalText(fieldString(value["document_id"]));
        chunk.contentRevision = fieldString(value["content_revision"]);
        chunk.id = ChunkId.fromCanonicalText(fieldString(value["chunk_id"]));
        chunk.start = fieldOffset(value["start"]);
        chunk.end = fieldOffset(value["end"]);
        chunk.path = readPath(value["path"]);
        chunk.sectionPaths = readPaths(value["section_paths"]);
        chunk.pagePaths = readPaths(value["page_paths"]);
        auto metadata = value["metadata"];
        enforce(metadata.type == JSONType.object,
            "chunk JSONL: invalid metadata");
        chunk.metadata = ChunkMetadata(fieldString(metadata["language"]),
            fieldString(metadata["title"]), fieldString(metadata["source_label"]));
        chunk.text = fieldString(value["text"]);
        enforce(encodeChunkJsonl(chunk) == row, "chunk JSONL: noncanonical row");
        return chunk;
    } catch (Exception) {
        throw new Exception("chunk JSONL: invalid row");
    }
}
