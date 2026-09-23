/// Pure post-extraction chunking of caller-supplied UTF-8 structure.
module domain.structured_chunks;

import domain.document : DocumentId;
import std.conv : to;
import std.digest : LetterCase, toHexString;
import crypto.sha256 : sha256Of;
import std.exception : enforce;
import std.utf : UTFException, validate;

enum uint chunkSchema = 1;
enum size_t maxChunkBytes = 4096;
enum size_t maxStructuredTextBytes = 1024 * 1024;
enum size_t maxMetadataBytes = 1024;

enum SpanKind : ubyte { section, page, paragraph }

/// Descriptive metadata only. Absence inherits; this type cannot grant rights.
struct ChunkMetadata {
    string language;
    string title;
    string sourceLabel;
}

/// Preorder tree node. Paths are nonempty ordinal sequences; a direct child
/// extends its parent's path by one ordinal. Paragraphs are leaves.
struct StructuredSpan {
    SpanKind kind;
    size_t start;
    size_t end;
    uint[] path;
    ChunkMetadata metadata;
}

struct ChunkId {
    private string value;
    private this(string value) { this.value = value; }
    string text() const { return value; }

    static ChunkId fromCanonicalText(string text) {
        bool valid = text.length == 73 && text[0 .. 9] == "chunk:v1:";
        if (valid) foreach (c; text[9 .. $])
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) valid = false;
        enforce(valid, "structured chunks: invalid chunk ID");
        return ChunkId(text.idup);
    }
}

/// Owned chunk text, source byte offsets, and the exact structural ancestry.
struct StructuredChunk {
    DocumentId documentId;
    string contentRevision;
    ChunkId id;
    size_t start;
    size_t end;
    uint[] path; // paragraph path plus deterministic split ordinal
    uint[][] sectionPaths;
    uint[][] pagePaths;
    ChunkMetadata metadata;
    string text;
}

private void append32(ref ubyte[] bytes, uint value) {
    foreach_reverse (shift; [0, 8, 16, 24]) bytes ~= cast(ubyte)(value >> shift);
}

private void appendField(ref ubyte[] bytes, string value) {
    enforce(value.length <= uint.max, "structured chunks: field too long");
    append32(bytes, cast(uint)value.length);
    bytes ~= cast(const(ubyte)[])value;
}

/// Identity excludes offsets, metadata, revision and iteration order. Every
/// structural path includes the split ordinal; all lengths are unambiguous.
ChunkId chunkId(DocumentId documentId, const(uint)[] path, string exactText) {
    enforce(documentId.text.length != 0 && path.length != 0 &&
        path.length <= 33 && exactText.length <= maxChunkBytes,
        "structured chunks: invalid identity input");
    validateText(exactText);
    ubyte[] bytes = cast(ubyte[])"scrubbed:structured-chunk-id:v1\0".dup;
    appendField(bytes, documentId.text);
    append32(bytes, cast(uint)path.length);
    foreach (ordinal; path) append32(bytes, ordinal);
    appendField(bytes, exactText);
    return ChunkId("chunk:v1:" ~
        toHexString!(LetterCase.lower)(sha256Of(bytes)).idup);
}

private bool prefix(const(uint)[] parent, const(uint)[] child) {
    return child.length == parent.length + 1 && child[0 .. parent.length] == parent;
}

private bool boundary(string text, size_t at) {
    return at == 0 || at == text.length ||
        (cast(ubyte)text[at] & 0xc0) != 0x80;
}

private ChunkMetadata inherit(ChunkMetadata parent, ChunkMetadata local) {
    if (local.language.length) parent.language = local.language.idup;
    if (local.title.length) parent.title = local.title.idup;
    if (local.sourceLabel.length) parent.sourceLabel = local.sourceLabel.idup;
    return parent;
}

private void validateText(string value) {
    try validate(value);
    catch (UTFException) throw new Exception("structured chunks: invalid UTF-8");
}

private void validateMetadata(ChunkMetadata value) {
    enforce(value.language.length <= maxMetadataBytes &&
        value.title.length <= maxMetadataBytes &&
        value.sourceLabel.length <= maxMetadataBytes,
        "structured chunks: metadata too large");
    validateText(value.language);
    validateText(value.title);
    validateText(value.sourceLabel);
}

private struct Frame {
    StructuredSpan span;
    ChunkMetadata metadata;
}

private uint[][] copyPaths(const(uint[][]) paths) {
    uint[][] result;
    foreach (path; paths) result ~= path.dup;
    return result;
}

/// Reject malformed trees before emitting any chunk. Containers may nest in
/// either section/page order; paragraph leaves must cover every source byte.
StructuredChunk[] chunkStructured(DocumentId documentId, string contentRevision,
    immutable(char)[] text, const(StructuredSpan)[] spans,
    ChunkMetadata rootMetadata = ChunkMetadata.init, size_t byteCap = maxChunkBytes) {
    enforce(documentId.text.length != 0 && contentRevision.length != 0,
        "structured chunks: missing document identity or revision");
    enforce(contentRevision.length <= 128 &&
        text.length <= maxStructuredTextBytes && byteCap > 0 &&
        byteCap <= maxChunkBytes, "structured chunks: byte cap exceeded");
    validateText(contentRevision);
    validateText(cast(string)text);
    validateMetadata(rootMetadata);
    enforce(spans.length <= 65_536 &&
        (text.length == 0 ? spans.length == 0 : spans.length != 0),
        "structured chunks: missing or unexpected spans");

    StructuredChunk[] result;
    rootMetadata = ChunkMetadata(rootMetadata.language.idup,
        rootMetadata.title.idup, rootMetadata.sourceLabel.idup);
    Frame[] stack;
    size_t covered;
    bool[string] seen;
    uint[string] lastOrdinal;
    bool[string] hasOrdinal;
    foreach (span; spans) {
        enforce(span.kind == SpanKind.section || span.kind == SpanKind.page ||
            span.kind == SpanKind.paragraph, "structured chunks: invalid kind");
        enforce(span.path.length != 0 && span.path.length <= 32 &&
            span.start < span.end &&
            span.end <= text.length && boundary(cast(string)text, span.start) &&
            boundary(cast(string)text, span.end),
            "structured chunks: invalid span bounds");
        validateMetadata(span.metadata);
        while (stack.length && span.start >= stack[$ - 1].span.end) {
            enforce(covered == stack[$ - 1].span.end,
                "structured chunks: container coverage gap");
            stack.length = stack.length - 1;
        }
        enforce(stack.length == 0 ? span.path.length == 1 &&
            span.start == covered :
            stack[$ - 1].span.kind != SpanKind.paragraph &&
            prefix(stack[$ - 1].span.path, span.path) &&
            span.start >= stack[$ - 1].span.start &&
            span.end <= stack[$ - 1].span.end,
            "structured chunks: invalid nesting or ordering");
        auto key = span.path.to!string;
        enforce((key in seen) is null, "structured chunks: duplicate path");
        seen[key] = true;
        auto parentKey = span.path[0 .. $ - 1].to!string;
        auto ordinal = span.path[$ - 1];
        enforce((parentKey in hasOrdinal) is null ||
            ordinal > lastOrdinal[parentKey],
            "structured chunks: unordered sibling path");
        hasOrdinal[parentKey] = true;
        lastOrdinal[parentKey] = ordinal;
        auto metadata = inherit(stack.length ? stack[$ - 1].metadata : rootMetadata,
            span.metadata);
        if (span.kind != SpanKind.paragraph) {
            stack ~= Frame(StructuredSpan(span.kind, span.start, span.end,
                span.path.dup, ChunkMetadata.init), metadata);
            continue;
        }
        enforce(span.start == covered,
            "structured chunks: paragraph overlap or coverage gap");
        uint[][] sections, pages;
        foreach (frame; stack) {
            if (frame.span.kind == SpanKind.section) sections ~= frame.span.path.dup;
            else pages ~= frame.span.path.dup;
        }
        size_t start = span.start;
        uint splitOrdinal;
        while (start < span.end) {
            enforce(result.length < 65_536,
                "structured chunks: too many chunks");
            size_t end = start + (span.end - start < byteCap ? span.end - start : byteCap);
            while (end > start && !boundary(cast(string)text, end)) --end;
            enforce(end > start, "structured chunks: byte cap cannot fit one UTF-8 scalar");
            auto path = span.path.dup ~ splitOrdinal++;
            auto part = cast(string)text[start .. end];
            result ~= StructuredChunk(documentId, contentRevision.idup,
                chunkId(documentId, path, part), start, end, path,
                copyPaths(sections), copyPaths(pages), metadata, part.idup);
            start = end;
        }
        covered = span.end;
    }
    foreach (frame; stack)
        enforce(covered == frame.span.end,
            "structured chunks: container coverage gap");
    enforce(covered == text.length, "structured chunks: paragraph coverage gap");
    return result;
}
