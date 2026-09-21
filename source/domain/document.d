module domain.document;

import std.array : Appender, appender;
import std.digest.sha : sha256Of;
import std.digest : LetterCase, toHexString;
import std.exception : enforce;
import std.string : indexOf;
import std.uni : normalize;
import std.utf : validate;

/// A logical source record. Keys are opaque, not filesystem paths or transport URLs.
struct SourceLocator {
    private string namespaceValue;
    private string sourceValue;
    private string recordValue;

    this(string datasetNamespace, string sourceKey, string recordKey) {
        namespaceValue = canonicalField(datasetNamespace);
        sourceValue = canonicalField(sourceKey);
        recordValue = canonicalField(recordKey);
    }

    string datasetNamespace() const { return namespaceValue; }
    string sourceKey() const { return sourceValue; }
    string recordKey() const { return recordValue; }
}

/// A presentation name. It never participates in DocumentId derivation.
struct OutputName {
    private string value;

    this(string name) { value = canonicalField(name); }
    string text() const { return value; }
}

/// Versioned SHA-256 key for a logical source record.
struct DocumentId {
    private string value;

    private this(string digest) { value = digest; }
    string text() const { return value; }

    static DocumentId from(SourceLocator source) {
        enforce(source.datasetNamespace.length != 0 && source.sourceKey.length != 0 &&
            source.recordKey.length != 0, "source locator is not initialized");
        auto bytes = appender!(ubyte[]);
        bytes.put(cast(const(ubyte)[]) "scrubbed:document-id:v1\0");
        appendField(bytes, source.datasetNamespace);
        appendField(bytes, source.sourceKey);
        appendField(bytes, source.recordKey);
        return DocumentId("doc:v1:" ~ toHexString!(LetterCase.lower)(sha256Of(bytes.data)).idup);
    }
}

/// Identity and presentation are separate values; revision/hash are not identity.
struct Document {
    SourceLocator source;
    OutputName outputName;

    DocumentId id() const { return DocumentId.from(source); }
}

private string canonicalField(string input) {
    enforce(input.length != 0, "identity/name field must not be empty");
    validate(input);
    enforce(input.indexOf('\0') < 0, "identity/name field must not contain NUL");
    return normalize(input).idup;
}

private void appendField(ref Appender!(ubyte[]) bytes, string field) {
    enforce(field.length <= uint.max, "identity field too long");
    auto length = cast(uint) field.length;
    foreach_reverse (shift; [0, 8, 16, 24])
        bytes.put(cast(ubyte) (length >> shift));
    bytes.put(cast(const(ubyte)[]) field);
}

/// Owner for borrowed byte ranges. It copies input so a caller may release a
/// mapping independently. Close invalidates every view, including view copies.
final class DocumentViewOwner {
    private const(ubyte)[] bytes;
    private bool closed;

    this(const(ubyte)[] bytes) { this.bytes = bytes.dup; }

    DocumentView view(size_t start, size_t length) {
        enforce(!closed, "document view owner is closed");
        enforce(start <= bytes.length && length <= bytes.length - start,
            "document view outside owner range");
        return DocumentView(this, start, length);
    }

    void close() {
        closed = true;
        bytes = null;
    }
}

/// No raw borrowed slice escapes. Reading always returns an independent copy.
struct DocumentView {
    private DocumentViewOwner owner;
    private size_t start;
    private size_t length;

    private this(DocumentViewOwner owner, size_t start, size_t length) {
        this.owner = owner;
        this.start = start;
        this.length = length;
    }

    ubyte[] read() const {
        enforce(owner !is null && !owner.closed, "document view owner is closed");
        return owner.bytes[start .. start + length].dup;
    }
}

unittest {
    import std.conv : to;
    import std.exception : assertThrown;

    auto locator = SourceLocator("archive", "folder/a:b", "record|1");
    auto document = Document(locator, OutputName("first.txt"));
    assert(document.id.text ==
        "doc:v1:489f01dcef5067959e03264b17467e6774c6b95e93bbbeb6cbb4784d15567a30");
    assert(document.id == Document(locator, OutputName("renamed.txt")).id);
    // Worker count is run metadata, never a SourceLocator input.
    foreach (workerCount; [1, 4, 16])
        assert(Document(locator, OutputName("run-" ~ workerCount.to!string)).id == document.id);
    assert(document.id != DocumentId.from(SourceLocator("archive", "folder/a:b", "record|2")));
    assert(DocumentId.from(SourceLocator("a:b", "c", "d")).text ==
        "doc:v1:3a3c9758df9ffe5d0b93b159a112d99cb644fc6b0417ceb9e3fe741b27bbbbc2");
    assert(DocumentId.from(SourceLocator("a", "b:c", "d")).text ==
        "doc:v1:262e42c87d1f7e1fc4d16c9b5c26f74b7e05bfb6eba3b8f16da68eef86301ffc");
    assert(DocumentId.from(SourceLocator("archive", "A", "r")).text ==
        "doc:v1:e4735613fce2214fafb18425f50225e0ef86b0010611ee3799b10248e6e8ab6c");
    assert(DocumentId.from(SourceLocator("archive", "a", "r")).text ==
        "doc:v1:5db3bb77fc3752a205ad5acebaf589c484e65e79000214732dd1464d61106110");
    assert(DocumentId.from(SourceLocator("archive", "caf\u00e9", "r")).text ==
        "doc:v1:a9846c4addff44fc083419f6bcd0b368f43e9093c60b148b76a730a4f2f56b47");
    assert(DocumentId.from(SourceLocator("archive", "caf\u00e9", "r")) ==
        DocumentId.from(SourceLocator("archive", "cafe\u0301", "r")));
    assert(DocumentId.from(SourceLocator("archive", "a/../b", "r")).text ==
        "doc:v1:cf8018611655f67399d2235ad25e1a5fdf811e99d70225c83d73bb65bd5d8dc0");
    assert(DocumentId.from(SourceLocator("archive", "b", "r")).text ==
        "doc:v1:953add25a9911a1b45ef5411ab81d89c8687b6a6be65cd8d07f9b5e5e88fd671");
    assertThrown(SourceLocator("", "source", "record"));
    assertThrown(SourceLocator("archive", "", "record"));
    assertThrown(SourceLocator("archive", "source", "bad\0record"));
    assertThrown(SourceLocator("archive", cast(string) [cast(char) 0xff], "record"));
    assertThrown(OutputName(""));
    assertThrown(DocumentId.from(SourceLocator.init));
}

unittest {
    import std.exception : assertThrown;

    ubyte[] backing = [1, 2, 3, 4];
    auto owner = new DocumentViewOwner(backing);
    auto view = owner.view(1, 2);
    backing[] = 0; // simulates release or reuse of caller-owned storage
    auto retained = view.read();
    assert(retained == [cast(ubyte) 2, 3]);
    retained[0] = 9;
    assert(view.read() == [cast(ubyte) 2, 3]);
    owner.close();
    assert(retained == [cast(ubyte) 9, 3]);
    assertThrown(view.read());
    assertThrown(owner.view(0, 1));
    assertThrown((new DocumentViewOwner(backing)).view(4, 1));
}
