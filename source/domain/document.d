module domain.document;

import std.array : Appender, appender;
import crypto.sha256 : sha256Of;
import std.digest : LetterCase, toHexString;
import std.exception : enforce;
import std.conv : to;
import std.string : indexOf;
import std.uni : normalize;
import std.utf : validate;

/// A logical source record. Keys are opaque, not filesystem paths or transport URLs.
struct SourceLocator {
    private string namespaceValue;
    private string sourceValue;
    private string recordValue;

    this(string datasetNamespace, string sourceKey, string recordKey) pure {
        namespaceValue = canonicalField(datasetNamespace);
        sourceValue = canonicalField(sourceKey);
        recordValue = canonicalField(recordKey);
    }

    string datasetNamespace() const pure { return namespaceValue; }
    string sourceKey() const pure { return sourceValue; }
    string recordKey() const pure { return recordValue; }
}

/// A presentation name. It never participates in DocumentId derivation.
struct OutputName {
    private string value;

    this(string name) pure { value = canonicalField(name); }
    string text() const pure { return value; }
}

/// Versioned SHA-256 key for a logical source record or a derived child.
struct DocumentId {
    private string value;

    private this(string digest) pure { value = digest; }
    string text() const pure { return value; }

    /// Parse an already-stored typed ID without deriving new provenance.
    static DocumentId fromCanonicalText(string text) {
        auto prefix = text.length == 71 ? "doc:v1:" : "child:v1:";
        bool canonical = text.length == prefix.length + 64 &&
            text[0 .. prefix.length] == prefix;
        if (canonical) {
            foreach (ch; text[prefix.length .. $]) {
                if (!((ch >= '0' && ch <= '9') ||
                    (ch >= 'a' && ch <= 'f'))) {
                    canonical = false;
                    break;
                }
            }
        }
        enforce(canonical, "document ID: invalid canonical text");
        return DocumentId(text.idup);
    }

    static DocumentId from(SourceLocator source) pure {
        enforce(source.datasetNamespace.length != 0 && source.sourceKey.length != 0 &&
            source.recordKey.length != 0, "source locator is not initialized");
        auto bytes = appender!(ubyte[]);
        bytes.put(cast(const(ubyte)[]) "scrubbed:document-id:v1\0");
        appendField(bytes, source.datasetNamespace);
        appendField(bytes, source.sourceKey);
        appendField(bytes, source.recordKey);
        return DocumentId("doc:v1:" ~ toHexString!(LetterCase.lower)(sha256Of(bytes.data)).idup);
    }

    private static DocumentId childOf(DocumentId parent, string stageKey, size_t ordinal) {
        enforce(parent.text.length != 0, "parent document ID is not initialized");
        // Separate from source IDs: domain tag, then length-prefixed parent ID,
        // NFC stage key, and decimal ordinal. No caller-owned locator can
        // produce the visibly distinct child:v1: kind.
        auto bytes = appender!(ubyte[]);
        bytes.put(cast(const(ubyte)[]) "scrubbed:child-document-id:v1\0");
        appendField(bytes, parent.text);
        appendField(bytes, canonicalField(stageKey));
        appendField(bytes, ordinal.to!string);
        return DocumentId("child:v1:" ~
            toHexString!(LetterCase.lower)(sha256Of(bytes.data)).idup);
    }
}

/// Identity and presentation are separate values; revision/hash are not identity.
struct Document {
    private SourceLocator sourceValue;
    OutputName outputName;
    private DocumentId childId;

    this(SourceLocator source, OutputName outputName) pure {
        DocumentId.from(source); // Reject invalid provenance at construction.
        this.sourceValue = source;
        this.outputName = outputName;
    }

    /// Return a value, never a writable alias to identity provenance.
    @property SourceLocator source() const pure {
        return SourceLocator(sourceValue.datasetNamespace, sourceValue.sourceKey,
            sourceValue.recordKey);
    }

    /// A child retains source provenance but has an ID outside the source-ID
    /// namespace. A nested child derives from its immediate parent's ID.
    static Document derivedChild(Document parent, string stageKey,
        size_t ordinal, OutputName outputName) {
        enforce(outputName.text.length != 0, "child output name is not initialized");
        auto parentId = parent.id; // Also validates a derived parent's provenance.
        auto child = Document(parent.sourceValue, outputName);
        child.childId = DocumentId.childOf(parentId, stageKey, ordinal);
        return child;
    }

    DocumentId id() const pure {
        auto sourceId = DocumentId.from(sourceValue);
        return childId.text.length != 0 ? childId : sourceId;
    }
}

private string canonicalField(string input) pure {
    enforce(input.length != 0, "identity/name field must not be empty");
    validate(input);
    enforce(input.indexOf('\0') < 0, "identity/name field must not contain NUL");
    return normalize(input).idup;
}

private void appendField(ref Appender!(ubyte[]) bytes, string field) pure {
    enforce(field.length <= uint.max, "identity field too long");
    auto length = cast(uint) field.length;
    foreach_reverse (shift; [0, 8, 16, 24])
        bytes.put(cast(ubyte) (length >> shift));
    bytes.put(cast(const(ubyte)[]) field);
}

/// Owns the backing lifetime for borrowed byte ranges. Effects may transfer
/// an opaque release callback with borrowed bytes; no concrete I/O is opened
/// here. Close invalidates every view, including copies of a view struct.
final class DocumentViewOwner {
    private const(ubyte)[] bytes;
    private void delegate() releaseBacking;
    private bool closed;

    /// Borrow GC-owned bytes without copying. The caller must not free or
    /// reallocate the array while this owner is open; mutation remains visible.
    this(ubyte[] bytes) { this.bytes = bytes; }

    /// Take a checked byte view and its backing lifetime together. The caller
    /// must not independently release or mutate the backing after transfer.
    /// The callback is invoked once by close; it does not escape this owner.
    this(const(ubyte)[] bytes, void delegate() releaseBacking) {
        enforce(releaseBacking !is null, "borrowed backing needs a release callback");
        this.bytes = bytes;
        this.releaseBacking = releaseBacking;
    }

    DocumentView view(size_t start, size_t length) {
        enforce(!closed, "document view owner is closed");
        enforce(start <= bytes.length && length <= bytes.length - start,
            "document view outside owner range");
        return DocumentView(this, start, length);
    }

    void close() {
        if (closed) return;
        closed = true;
        bytes = null;
        auto release = releaseBacking;
        releaseBacking = null;
        if (release !is null) release();
    }
}

/// Checked access never exposes a raw borrowed slice. Copy explicitly when
/// bytes must remain usable after owner closure.
struct DocumentView {
    private DocumentViewOwner owner;
    private size_t start;
    private size_t length;

    private this(DocumentViewOwner owner, size_t start, size_t length) {
        this.owner = owner;
        this.start = start;
        this.length = length;
    }

    size_t size() const pure {
        enforce(owner !is null && !owner.closed, "document view owner is closed");
        return length;
    }

    ubyte at(size_t index) const pure {
        enforce(index < size, "document view index out of range");
        return owner.bytes[start + index];
    }

    /// Copy a checked subrange without exposing the borrowed backing slice.
    void copyTo(size_t sourceOffset, ubyte[] destination) const pure {
        auto checkedSize = size;
        enforce(sourceOffset <= checkedSize &&
            destination.length <= checkedSize - sourceOffset,
            "document view copy outside range");
        destination[] = owner.bytes[
            start + sourceOffset .. start + sourceOffset + destination.length];
    }

    int opApply(scope int delegate(ubyte) visit) const {
        foreach (index; 0 .. size) {
            auto result = visit(at(index));
            if (result) return result;
        }
        return 0;
    }

    ubyte[] copy() const {
        auto checkedSize = size;
        return owner.bytes[start .. start + checkedSize].dup;
    }
}

unittest {
    import std.array : replicate;
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
    auto original = document.id.text.dup;
    auto parsed = DocumentId.fromCanonicalText(cast(string)original);
    assert(parsed == document.id);
    original[0] = 'x';
    assert(parsed == document.id); // Parser owns a copy, not caller storage.
    assert(DocumentId.fromCanonicalText("child:v1:" ~ "a".replicate(64)).text.length == 73);
    foreach (bad; ["", "doc:v1:", "other:v1:" ~ "a".replicate(64),
            "doc:v1:" ~ "A".replicate(64), "doc:v1:" ~ "g".replicate(64),
            "doc:v1:" ~ "a".replicate(63), "doc:v1:" ~ "a".replicate(65)]) {
        try DocumentId.fromCanonicalText(bad);
        catch (Exception error) {
            assert(error.msg == "document ID: invalid canonical text");
            continue;
        }
        assert(0, "expected canonical ID refusal");
    }
}

unittest {
    import std.exception : assertThrown;

    static assert(!__traits(compiles, {
        auto document = Document(SourceLocator("a", "b", "c"), OutputName("name"));
        document.source = SourceLocator("other", "source", "record");
    }));

    auto parent = Document(SourceLocator("archive", "bundle", "record"),
        OutputName("original"));
    auto child = Document.derivedChild(parent, "split:stage|1", 0, OutputName("part"));
    assert(child.id.text ==
        "child:v1:17f0922cd16212a59c775405caa7b62699118778b3de07c67870a4f4af5d5413");
    assert(child.id == Document.derivedChild(parent, "split:stage|1", 0,
        OutputName("another name")).id);
    assert(child.id != Document.derivedChild(parent, "split:stage|1", 1,
        OutputName("part")).id);
    assert(child.id != Document.derivedChild(parent, "split:stage", 10,
        OutputName("part")).id);
    assert(child.id != Document.derivedChild(parent, "split:stage|10", 0,
        OutputName("part")).id);
    auto renamed = child;
    renamed.outputName = OutputName("renamed");
    assert(renamed.id == child.id);
    assert(child.source == parent.source);
    auto provenanceCopy = child.source;
    provenanceCopy = SourceLocator("other", "source", "record");
    assert(child.source == parent.source && child.source != provenanceCopy);

    // The old textual child tuple is a valid caller-owned source key. Its
    // source ID must never collide with the derived child ID.
    auto oldTuple = "stage-child:v1:" ~ parent.id.text ~ ":split:stage|1:0";
    auto adversarial = Document(SourceLocator("archive", "bundle", oldTuple),
        OutputName("original source"));
    assert(adversarial.id.text[0 .. "doc:v1:".length] == "doc:v1:");
    assert(adversarial.id != child.id);

    auto nested = Document.derivedChild(child, "next", 2, OutputName("nested"));
    assert(nested.id != Document.derivedChild(parent, "next", 2,
        OutputName("nested")).id);
    assert(nested.id == Document.derivedChild(renamed, "next", 2,
        OutputName("renamed nested")).id);
    assert(Document.derivedChild(parent, "caf\u00e9", 3, OutputName("part")).id ==
        Document.derivedChild(parent, "cafe\u0301", 3, OutputName("part")).id);
    assertThrown(Document.derivedChild(parent, "", 0, OutputName("part")));
    assertThrown(Document.derivedChild(parent, "bad\0key", 0, OutputName("part")));
    assertThrown(Document.derivedChild(Document.init, "stage", 0, OutputName("part")));
    assertThrown(Document.derivedChild(parent, "stage", 0, OutputName.init));
    assertThrown(Document(SourceLocator.init, OutputName("part")));
    auto corrupted = child;
    corrupted.sourceValue = SourceLocator.init; // Same-module fault injection.
    assertThrown(corrupted.id);
    assertThrown(corrupted.source);
    assertThrown(Document.derivedChild(corrupted, "next", 0, OutputName("part")));
}

unittest {
    import core.memory : GC;
    import std.exception : assertThrown;

    ubyte[] backing = [1, 2, 3, 4];
    auto owner = new DocumentViewOwner(backing);
    auto view = owner.view(1, 2);
    assert(view.at(0) == 2);
    backing[1] = 5; // zero-copy alias while the owner is open
    assert(view.at(0) == 5);
    ubyte[] iterated;
    foreach (value; view) iterated ~= value;
    assert(iterated == [cast(ubyte) 5, 3]);
    auto retained = view.copy();
    ubyte[2] copied;
    view.copyTo(0, copied[]);
    assert(copied[] == [cast(ubyte) 5, 3]);
    assertThrown(view.copyTo(1, copied[]));
    backing[1] = 2;
    assert(retained == [cast(ubyte) 5, 3]);
    retained[0] = 9;
    assert(view.at(0) == 2);
    owner.close();
    assert(retained == [cast(ubyte) 9, 3]);
    assertThrown(view.at(0));
    assertThrown(view.copy());
    assertThrown(view.copyTo(0, copied[]));
    assertThrown(owner.view(0, 1));
    assertThrown((new DocumentViewOwner(backing)).view(4, 1));

    auto large = new ubyte[32 * 1024 * 1024];
    auto before = GC.stats().usedSize;
    auto largeOwner = new DocumentViewOwner(large);
    assert(GC.stats().usedSize <= before + 1024 * 1024);
    assert(largeOwner.view(0, 1024).size == 1024);
    largeOwner.close();

    size_t releases;
    auto leased = new DocumentViewOwner(cast(const(ubyte)[]) backing,
        () { ++releases; });
    auto borrowed = leased.view(0, 1);
    auto copiedView = borrowed;
    leased.close();
    leased.close();
    assert(releases == 1);
    assertThrown(borrowed.at(0));
    assertThrown(copiedView.size);
}
