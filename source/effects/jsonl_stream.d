/// Bounded, synchronous JSONL effects adapter. No CLI policy is owned here.
module effects.jsonl_stream;

import domain.document : DocumentId, SourceLocator;
import std.array : Appender, appender;
import std.conv : to;
import std.json : JSONType, JSONValue, parseJSON;
import std.utf : validate;

alias ReadBytes = size_t delegate(ubyte[] destination);
alias WriteBytes = void delegate(const(ubyte)[] bytes);
alias TextTransform = string delegate(string field, string text, DocumentId id);
alias DocumentTransform = string delegate(string field, string text,
    SourceLocator source);
/// Called synchronously only after the complete encoded record was accepted
/// by the writer; framing/output failures never call it for the current line.
alias DocumentCommit = void delegate(SourceLocator source);

enum JsonlFailureKind {
    inputLimit, malformedJson, invalidText, outputLimit, reader, writer,
    rejected, quarantined, unsupportedFanout,
}

enum JsonlDecisionKind { rejected, quarantined, unsupportedFanout }

/// A selected-field adapter can report a typed document decision without
/// teaching the JSON framing layer how that decision was produced.
final class JsonlDecisionFailure : Exception {
    JsonlDecisionKind kind;

    this(JsonlDecisionKind kind, string detail) {
        super(detail);
        this.kind = kind;
    }
}

final class JsonlFailure : Exception {
    JsonlFailureKind kind;
    size_t line;
    DocumentId documentId;
    size_t completedRecords;
    bool partialOutputPossible;
    Exception original;
    string unitName;

    this(JsonlFailureKind kind, size_t line, DocumentId id, size_t completed,
        bool partial, string detail, Exception original = null,
        string unitName = "record") {
        super(detail);
        this.kind = kind;
        this.line = line;
        documentId = id;
        completedRecords = completed;
        partialOutputPossible = partial;
        this.original = original;
        this.unitName = unitName;
    }
}

struct JsonlLimits {
    size_t rawLineBytes;
    size_t outputRecordBytes;
}

/// The caller supplies a stable logical source key; transport/output names are not IDs.
/// A failing record stops processing. Earlier completed records remain written.
size_t processJsonl(ReadBytes read, WriteBytes write, string datasetNamespace,
    string sourceKey, const(string)[] fields, TextTransform transform,
    JsonlLimits limits) {
    if (transform is null)
        throw new Exception("JSONL callbacks and byte caps must be configured");
    return processJsonlDocuments(read, write, datasetNamespace, sourceKey, fields,
        (string field, string text, SourceLocator source) =>
            transform(field, text, DocumentId.from(source)), limits);
}

/// Variant for typed document execution. The line locator is constructed once
/// at the framing boundary and remains the selected field's document identity.
size_t processJsonlDocuments(ReadBytes read, WriteBytes write,
    string datasetNamespace, string sourceKey, const(string)[] fields,
    DocumentTransform transform, JsonlLimits limits,
    scope DocumentCommit committed = null) {
    if (read is null || write is null || transform is null || !limits.rawLineBytes ||
        !limits.outputRecordBytes)
        throw new Exception("JSONL callbacks and byte caps must be configured");
    // Validate identity before reading or writing.
    SourceLocator(datasetNamespace, sourceKey, "1");
    foreach (field; fields) validate(field);

    size_t lineNumber, completed;
    ubyte[] line;
    ubyte[4096] chunk;
    for (;;) {
        size_t n;
        try n = read(chunk[]);
        catch (Exception error) {
            auto ordinal = lineNumber + 1;
            throw new JsonlFailure(JsonlFailureKind.reader, ordinal,
                DocumentId.from(SourceLocator(datasetNamespace, sourceKey,
                    ordinal.to!string)), completed, false,
                "JSONL reader failed: " ~ error.msg);
        }
        if (n > chunk.length) throw new Exception("JSONL reader exceeded its buffer");
        foreach (c; chunk[0 .. n]) {
            if (c == '\n') {
                ++lineNumber;
                processLine(line, lineNumber, completed, write, datasetNamespace,
                    sourceKey, fields, transform, limits, committed);
                line.length = 0;
                ++completed;
            } else {
                // One optional terminal CR is framing, not part of the JSON text.
                // Permit that one byte beyond the raw JSON cap, but no other growth.
                if (line.length >= limits.rawLineBytes &&
                    !(line.length == limits.rawLineBytes && c == '\r'))
                    throw new JsonlFailure(JsonlFailureKind.inputLimit, lineNumber + 1,
                        DocumentId.from(SourceLocator(datasetNamespace, sourceKey,
                            (lineNumber + 1).to!string)), completed, false,
                        "JSONL raw line exceeds byte cap");
                line ~= c;
            }
        }
        if (!n) break;
    }
    if (line.length) {
        ++lineNumber;
        processLine(line, lineNumber, completed, write, datasetNamespace,
            sourceKey, fields, transform, limits, committed);
        ++completed;
    }
    return completed;
}

private void processLine(ubyte[] raw, size_t ordinal, size_t completed,
    WriteBytes write, string datasetNamespace, string sourceKey,
    const(string)[] fields, DocumentTransform transform, JsonlLimits limits,
    scope DocumentCommit committed) {
    if (raw.length && raw[$ - 1] == '\r') raw = raw[0 .. $ - 1];
    auto source = SourceLocator(datasetNamespace, sourceKey, ordinal.to!string);
    auto id = DocumentId.from(source);
    if (raw.length > limits.rawLineBytes)
        throw new JsonlFailure(JsonlFailureKind.inputLimit, ordinal, id, completed,
            false, "JSONL raw line exceeds byte cap");
    JSONValue record;
    try {
        auto text = cast(string) raw;
        validate(text);
        auto scanner = JsonSafety(text);
        scanner.check();
        record = parseJSON(text);
        if (record.type != JSONType.object) throw new Exception("record is not an object");
    } catch (Exception error) {
        throw new JsonlFailure(JsonlFailureKind.malformedJson, ordinal, id,
            completed, false, "invalid JSONL object: " ~ error.msg);
    }
    foreach (field; fields) {
        auto found = field in record.object;
        if (found is null) continue;
        if (found.type != JSONType.string)
            throw new JsonlFailure(JsonlFailureKind.invalidText, ordinal, id,
                completed, false, "selected field is not text: " ~ field,
                null, field);
        try {
            auto changed = transform(field, found.str, source);
            validate(changed);
            if (changed.length > limits.outputRecordBytes)
                throw new JsonlFailure(JsonlFailureKind.outputLimit, ordinal, id,
                    completed, false, "transformed text exceeds output cap",
                    null, field);
            *found = JSONValue(changed);
        } catch (JsonlFailure error) { throw error; }
        catch (JsonlDecisionFailure error) {
            JsonlFailureKind kind;
            final switch (error.kind) {
            case JsonlDecisionKind.rejected:
                kind = JsonlFailureKind.rejected;
                break;
            case JsonlDecisionKind.quarantined:
                kind = JsonlFailureKind.quarantined;
                break;
            case JsonlDecisionKind.unsupportedFanout:
                kind = JsonlFailureKind.unsupportedFanout;
                break;
            }
            throw new JsonlFailure(kind, ordinal, id, completed, false, error.msg);
        }
        catch (Exception error) {
            throw new JsonlFailure(JsonlFailureKind.invalidText, ordinal, id,
                completed, false, "selected text rejected: " ~ error.msg,
                error, field);
        }
    }
    auto encoded = appender!string();
    try {
        encodeBounded(record, encoded, limits.outputRecordBytes - 1);
    } catch (Exception error) {
        throw new JsonlFailure(JsonlFailureKind.outputLimit, ordinal, id,
            completed, false, "serialized JSONL record exceeds output cap: " ~ error.msg);
    }
    auto output = encoded.data ~ "\n";
    try write(cast(const(ubyte)[]) output);
    catch (Exception error) {
        throw new JsonlFailure(JsonlFailureKind.writer, ordinal, id,
            completed, true, "JSONL writer failed; current record may be partial: " ~ error.msg);
    }
    if (committed !is null) committed(source);
}

private void putBounded(ref Appender!string output, string piece, size_t cap) {
    if (piece.length > cap - output.data.length)
        throw new Exception("byte cap reached");
    output.put(piece);
}

private void quotedBounded(ref Appender!string output, string value, size_t cap) {
    // JSON quoting expands by at most six bytes per input byte. Refuse a
    // too-large string before calling std.json's allocating scalar encoder.
    if (value.length > cap - output.data.length)
        throw new Exception("string exceeds remaining byte cap");
    putBounded(output, JSONValue(value).toString(), cap);
}

private void encodeBounded(JSONValue value, ref Appender!string output, size_t cap) {
    final switch (value.type) {
        case JSONType.object:
            putBounded(output, "{", cap);
            bool first = true;
            foreach (key, child; value.object) {
                if (!first) putBounded(output, ",", cap);
                first = false;
                quotedBounded(output, key, cap);
                putBounded(output, ":", cap);
                encodeBounded(child, output, cap);
            }
            putBounded(output, "}", cap);
            return;
        case JSONType.array:
            putBounded(output, "[", cap);
            foreach (i, child; value.array) {
                if (i) putBounded(output, ",", cap);
                encodeBounded(child, output, cap);
            }
            putBounded(output, "]", cap);
            return;
        case JSONType.string:
            quotedBounded(output, value.str, cap);
            return;
        case JSONType.integer:
        case JSONType.uinteger:
        case JSONType.float_:
        case JSONType.true_:
        case JSONType.false_:
        case JSONType.null_:
            putBounded(output, value.toString(), cap);
            return;
    }
}

/// Preflight ambiguous values that std.json would otherwise silently collapse:
/// duplicate decoded keys at any depth and numbers outside exact signed/unsigned
/// 64-bit integer semantics. Decimal/exponent forms are deliberately rejected.
private struct JsonSafety {
    string input;
    size_t at;
    size_t depth;

    void check() {
        value();
        space();
        if (at != input.length) throw new Exception("trailing JSON content");
    }

    void space() {
        while (at < input.length && (input[at] == ' ' || input[at] == '\t' ||
            input[at] == '\r' || input[at] == '\n')) ++at;
    }

    void need(char c) {
        space();
        if (at == input.length || input[at] != c) throw new Exception("invalid JSON punctuation");
        ++at;
    }

    string quoted() {
        space();
        auto start = at;
        need('"');
        bool escape;
        while (at < input.length) {
            auto c = input[at++];
            if (escape) { escape = false; continue; }
            if (c == '\\') { escape = true; continue; }
            if (c == '"') return parseJSON(input[start .. at]).str;
        }
        throw new Exception("unterminated JSON string");
    }

    void value() {
        space();
        if (at == input.length) throw new Exception("missing JSON value");
        if (input[at] == '"') { quoted(); return; }
        if (input[at] == '{' || input[at] == '[') {
            if (++depth > 64) throw new Exception("JSON nesting exceeds 64");
            auto object = input[at++] == '{';
            space();
            if (at < input.length && input[at] == (object ? '}' : ']')) {
                ++at; --depth; return;
            }
            bool[string] keys;
            for (;;) {
                if (object) {
                    auto key = quoted();
                    if (key in keys) throw new Exception("duplicate JSON object key");
                    keys[key] = true;
                    need(':');
                }
                value();
                space();
                if (at < input.length && input[at] == ',') { ++at; continue; }
                need(object ? '}' : ']');
                --depth;
                return;
            }
        }
        auto start = at;
        while (at < input.length && input[at] != ',' && input[at] != '}' &&
            input[at] != ']' && input[at] != ' ' && input[at] != '\t' &&
            input[at] != '\r' && input[at] != '\n') ++at;
        auto token = input[start .. at];
        if (token.length && (token[0] == '-' || (token[0] >= '0' && token[0] <= '9'))) {
            foreach (c; token)
                if (c == '.' || c == 'e' || c == 'E')
                    throw new Exception("decimal/exponent number is not lossless");
            // parseJSON validates lexical grammar and integer range.
        }
        parseJSON(token);
    }
}
