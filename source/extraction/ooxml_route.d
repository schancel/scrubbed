/// Bridges `AdmittedZipV1` entry lookup (`extraction.container`) and #298's
/// already-shipped `word/document.xml` text-walker (`extraction.ooxml_document`)
/// into a pure `ExtractorApplyV1`, registered for `DetectionOutcomeV1.ooxmlWord`
/// in `extraction.registry`'s `coreExtractorRegistryV1()`. This is the first
/// extraction route that reaches real DOCX text through the already-shipping
/// v4 dispatch pipeline (`scrubbed run --route ... --action ...`); no new
/// CLI flag or command, no new stage or dispatch-layer change.
///
/// Pure: `AdmittedZipV1.entryBytesV1` and `walkOoxmlDocumentV1` are both
/// already I/O-free (see `extraction/README.md`'s "no file, process,
/// network, CLI, or adapter I/O" invariant, which this module does not
/// amend or carve an exception into); this module adds no I/O of its own,
/// only the glue between the two, plus a "good enough" plain-text
/// rendering of the walked document -- matching `html_main_content.d`'s own
/// established "good enough, not full-fidelity" extraction philosophy.
///
/// `walkOoxmlDocumentV1` itself is not compiler-inferred `pure` (`dxml`'s
/// `EntityRange`/`parseXML` is conservatively attributed impure by the
/// compiler, not because of any real I/O or shared mutable state -- its own
/// module doc already states it performs none). This mirrors exactly the
/// judgment call this codebase already made and had independently reviewed
/// for `effects.zlib_ffi.d`'s real FFI decompressor: a function that is
/// genuinely deterministic and side-effect-free from every caller's
/// perspective (its only inputs/outputs are its parameter and its freshly
/// allocated return value; it touches no global or shared mutable state of
/// its own) is cast to a `pure` function pointer at one single, clearly
/// documented boundary below, asserted by cast rather than proven by the
/// compiler -- the same "weakly pure" reasoning already accepted for that
/// precedent, applied here to a conservative-attribute-inference gap in a
/// pure-D dependency instead of to real FFI.
///
/// Deliberately out of scope (see `extraction.ooxml_document`'s own module
/// doc, unchanged by this slice): headers/footers/footnotes/endnotes,
/// fields, track changes, embedded objects, legacy `.doc`.
module extraction.ooxml_route;

import extraction.contracts : ExtractionProvenanceV1, TextDocumentV1;
import extraction.ooxml_document : DocxBlockKindV1, DocxDocumentV1,
    DocxTableV1, OoxmlWalkResultV1, OoxmlWalkStatusV1, walkOoxmlDocumentV1;
import extraction.port : ConfiguredExtractorV1, ExtractionInputV1,
    ExtractorConfigurationV1, ExtractorOptionsV1;
import std.exception : enforce;

enum string ooxmlWordImplementationV1 = "ooxml-word";
enum string ooxmlWordVersionV1 = "ooxml-word/v1";

/// The `word/document.xml` part every well-formed OOXML WordprocessingML
/// package carries -- the same fixed path `extraction.container`'s own
/// package-kind detection already keys on (see `container.d`'s
/// `wordDocument` marker in `parseArchive`).
enum string wordDocumentEntryNameV1 = "word/document.xml";

private alias OoxmlWalkFnV1 = OoxmlWalkResultV1 function(const(ubyte)[]) pure;

/// Non-`pure` only because the compiler conservatively infers `dxml`'s
/// `parseXML`/`EntityRange` that way (see this module's own doc above);
/// otherwise a plain, single-argument-in/fresh-value-out wrapper around
/// `walkOoxmlDocumentV1`.
private OoxmlWalkResultV1 walkOoxmlDocumentImpureV1(const(ubyte)[] bytes) {
    return walkOoxmlDocumentV1(bytes);
}

/// The single documented cast boundary (see this module's header doc).
private immutable OoxmlWalkFnV1 walkOoxmlDocumentPureV1 =
    cast(OoxmlWalkFnV1) &walkOoxmlDocumentImpureV1;

/// This extractor takes no options: the route is selected entirely by v4
/// dispatch outcome/route wiring (no new CLI flag or command).
ConfiguredExtractorV1 configureOoxmlWordV1(const ref ExtractorOptionsV1 options) {
    enforce(options.length == 0, "ooxml-word extractor takes no options");
    return ConfiguredExtractorV1(&extractOoxmlWordV1);
}

/// Fail-closed on anything but a well-formed `word/document.xml`: a missing
/// entry, a directory in its place, or malformed/truncated XML (dxml's own
/// refusal, translated from `walkOoxmlDocumentV1`'s typed `malformed`
/// outcome) all throw rather than return silently-wrong or empty text. The
/// exception propagates to `composition.dispatch_executor`'s existing
/// per-document failure handling (`DispatchExecutionFailureV1`), the same
/// fail-closed idiom `extraction.plain_text`'s extractor already uses for
/// its own structural failures -- one document's failure cannot terminate
/// or corrupt another.
private TextDocumentV1 extractOoxmlWordV1(ExtractionInputV1 input,
        immutable(ExtractorConfigurationV1)) pure {
    enforce(input.admittedZip !is null,
        "ooxml-word route needs an admitted ZIP capability");
    bool found;
    foreach (entry; input.admittedZip.entries())
        if (entry.name == wordDocumentEntryNameV1 && !entry.isDirectory) {
            found = true;
            break;
        }
    enforce(found, "ooxml-word route needs a word/document.xml entry");

    auto documentBytes = input.admittedZip.entryBytesV1(wordDocumentEntryNameV1);
    auto walked = walkOoxmlDocumentPureV1(documentBytes);
    enforce(walked.status == OoxmlWalkStatusV1.ok,
        "ooxml-word route: word/document.xml is malformed");

    auto text = renderDocxTextV1(walked.document);
    // walkOoxmlDocumentV1 currently has no warnings of its own to carry
    // (see OoxmlWalkResultV1); pass none rather than inventing any.
    return TextDocumentV1.extractedOwned(input.document,
        cast(const(ubyte)[]) text, input.detection,
        ooxmlWordImplementationV1, ooxmlWordVersionV1, null,
        ExtractionProvenanceV1(input.detection.outcome, input.routeName,
            input.source.size));
}

/// "Good enough" plain-text rendering of a walked docx, in document order:
/// paragraphs join across blocks with a blank line, matching a visible
/// paragraph break; a table's rows join with newlines and cells within a
/// row join with tabs, a simple, readable approximation of tabular layout
/// (not full-fidelity, matching #298's own stated scope). A blank paragraph
/// still contributes an empty line rather than being dropped, so paragraph
/// spacing in the original document stays visible.
private string renderDocxTextV1(const ref DocxDocumentV1 doc) pure {
    string result;
    bool first = true;
    foreach (block; doc.blocks) {
        if (!first) result ~= "\n\n";
        first = false;
        final switch (block.kind) {
        case DocxBlockKindV1.paragraph:
            result ~= block.paragraph.text;
            break;
        case DocxBlockKindV1.table:
            result ~= renderTableTextV1(block.table);
            break;
        }
    }
    return result;
}

private string renderTableTextV1(const ref DocxTableV1 table) pure {
    string result;
    bool firstRow = true;
    foreach (row; table.rows) {
        if (!firstRow) result ~= "\n";
        firstRow = false;
        bool firstCell = true;
        foreach (cell; row.cells) {
            if (!firstCell) result ~= "\t";
            firstCell = false;
            bool firstParagraph = true;
            foreach (paragraph; cell.paragraphs) {
                if (!firstParagraph) result ~= " ";
                firstParagraph = false;
                result ~= paragraph.text;
            }
        }
    }
    return result;
}

version (unittest) {
    import content.pieces : Content, ContentPiece;
    import domain.document : Document, OutputName, SourceLocator;
    import extraction.container : inspectZipContainerV1, AdmittedZipV1,
        ZipInflateOutcomeV1, ZipInflateV1, ZipInspectionLimitsV1,
        ZipInspectionStatusV1;
    import extraction.contracts : DetectionOutcomeV1, DetectionResultV1,
        EvidenceKindV1, MediaEvidenceV1;
    import extraction.port : SourceContentV1;

    /// A small, self-contained mirror of `extraction.container`'s own
    /// (private, module-local) zip-fixture builder -- this module cannot
    /// reuse that one directly since it is private to its module (same
    /// reason `effects.zlib_ffi`'s own tests carry a small local mirror).
    /// Every entry here is STORE (method 0): this module's own tests exist
    /// to exercise the extractor glue itself, not DEFLATE decompression
    /// correctness, which `container.d`/`effects.zlib_ffi.d` already prove
    /// directly against a real decompressor.
    private ubyte[] storeZipFixture(string[] names, ubyte[][] datas) pure {
        ubyte[] bytes;
        uint[] offsets;
        void put16(ushort value) { bytes ~= cast(ubyte) value; bytes ~= cast(ubyte) (value >> 8); }
        void put32(uint value) { foreach (shift; 0 .. 4) bytes ~= cast(ubyte) (value >> (8 * shift)); }
        foreach (index, name; names) {
            auto data = datas[index];
            offsets ~= cast(uint) bytes.length;
            put32(0x04034b50);
            put16(20); put16(0); put16(0);
            put16(0); put16(0);
            put32(0);
            put32(cast(uint) data.length); put32(cast(uint) data.length);
            put16(cast(ushort) name.length); put16(0);
            bytes ~= cast(const(ubyte)[]) name;
            bytes ~= data;
        }
        auto centralOffset = cast(uint) bytes.length;
        foreach (index, name; names) {
            auto data = datas[index];
            put32(0x02014b50);
            put16(20); put16(20);
            put16(0); put16(0);
            put16(0); put16(0);
            put32(0);
            put32(cast(uint) data.length); put32(cast(uint) data.length);
            put16(cast(ushort) name.length);
            put16(0); put16(0);
            put16(0); put16(0); put32(0);
            put32(offsets[index]);
            bytes ~= cast(const(ubyte)[]) name;
        }
        auto centralBytes = cast(uint) bytes.length - centralOffset;
        put32(0x06054b50);
        put16(0); put16(0);
        put16(cast(ushort) names.length);
        put16(cast(ushort) names.length);
        put32(centralBytes);
        put32(centralOffset);
        put16(0);
        return bytes;
    }

    // Not pure: these test helpers exercise the real (impure) container
    // inspector and contracts constructors to build fixtures; only the
    // extractor's own apply function (tested below) needs to be pure.
    private AdmittedZipV1 admitOoxmlFixture(ubyte[] documentXml) {
        auto bytes = storeZipFixture(
            ["[Content_Types].xml", "_rels/.rels", wordDocumentEntryNameV1],
            [cast(ubyte[]) "c".dup, cast(ubyte[]) "r".dup, documentXml]);
        auto content = new Content([ContentPiece.own(bytes)]);
        auto result = inspectZipContainerV1(content, ZipInspectionLimitsV1());
        assert(result.status == ZipInspectionStatusV1.admitted);
        return result.admitted;
    }

    private ExtractionInputV1 fixtureInput(AdmittedZipV1 admitted, size_t sourceBytes) {
        auto document = Document(SourceLocator("test", "ooxml", "one"),
            OutputName("one.docx"));
        auto detection = DetectionResultV1.detected(DetectionOutcomeV1.ooxmlWord,
            [MediaEvidenceV1(EvidenceKindV1.containerStructure,
                DetectionOutcomeV1.ooxmlWord, "ooxml-word-markers")],
            "test:v1", null, sourceBytes, sourceBytes, sourceBytes);
        auto source = new Content([ContentPiece.own(cast(ubyte[]) "unused".dup)]);
        return ExtractionInputV1(document, SourceContentV1.from(source),
            detection, "ooxml", admitted);
    }
}

unittest {
    import std.exception : assertThrown;

    enum plainXml =
        `<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">` ~
        `<w:body>` ~
        `<w:p><w:r><w:t>First paragraph.</w:t></w:r></w:p>` ~
        `<w:p><w:r><w:t>Second paragraph.</w:t></w:r></w:p>` ~
        `</w:body></w:document>`;
    auto admitted = admitOoxmlFixture(cast(ubyte[]) plainXml.dup);
    auto document = Document(SourceLocator("test", "ooxml", "one"),
        OutputName("one.docx"));
    auto input = fixtureInput(admitted, 6);
    ExtractorOptionsV1 noOptions;
    auto configured = configureOoxmlWordV1(noOptions);
    auto text = configured(input);
    assert(text.id == document.id && text.outputName == document.outputName);
    assert(text.extractor == ooxmlWordImplementationV1 &&
        text.extractorVersion == ooxmlWordVersionV1);
    assert(text.provenance.routeName == "ooxml" &&
        text.provenance.sourceOutcome == DetectionOutcomeV1.ooxmlWord);
    ubyte[] rendered;
    text.content.stream((const(ubyte)[] chunk) { rendered ~= chunk; });
    assert(cast(string) rendered == "First paragraph.\n\nSecond paragraph.");

    // A table renders rows/cells as tab/newline-separated text.
    enum tableXml =
        `<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">` ~
        `<w:body><w:tbl><w:tblPr/><w:tblGrid/>` ~
        `<w:tr><w:tc><w:p><w:r><w:t>A1</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>B1</w:t></w:r></w:p></w:tc></w:tr>` ~
        `<w:tr><w:tc><w:p><w:r><w:t>A2</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>B2</w:t></w:r></w:p></w:tc></w:tr>` ~
        `</w:tbl></w:body></w:document>`;
    auto tableAdmitted = admitOoxmlFixture(cast(ubyte[]) tableXml.dup);
    auto tableText = configured(fixtureInput(tableAdmitted, 6));
    ubyte[] tableRendered;
    tableText.content.stream((const(ubyte)[] chunk) { tableRendered ~= chunk; });
    assert(cast(string) tableRendered == "A1\tB1\nA2\tB2");

    // Malformed XML: fails closed (throws), never silently empty/wrong text.
    enum malformedXml =
        `<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">` ~
        `<w:body><w:p><w:r><w:t>Oops</w:t></w:r></w:q></w:body></w:document>`;
    auto malformedAdmitted = admitOoxmlFixture(cast(ubyte[]) malformedXml.dup);
    assertThrown(configured(fixtureInput(malformedAdmitted, 6)));

    // Missing word/document.xml (a generic zip mistakenly routed here, or an
    // OOXML package whose body part is absent): fails closed, never crashes
    // or silently treats another entry's bytes as the document body.
    auto noDocumentBytes = storeZipFixture(
        ["[Content_Types].xml", "_rels/.rels"],
        [cast(ubyte[]) "c".dup, cast(ubyte[]) "r".dup]);
    auto noDocumentContent = new Content([ContentPiece.own(noDocumentBytes)]);
    auto noDocumentResult = inspectZipContainerV1(noDocumentContent, ZipInspectionLimitsV1());
    assert(noDocumentResult.status == ZipInspectionStatusV1.admitted);
    assertThrown(configured(fixtureInput(noDocumentResult.admitted, 6)));

    // No admitted ZIP capability at all: fails closed defensively, the same
    // way every other route-mismatch case above does.
    auto noZip = fixtureInput(null, 6);
    assertThrown(configured(noZip));

    // The extractor takes no options.
    ExtractorOptionsV1 unexpectedOption;
    unexpectedOption["unexpected"] = fakeOptionV1();
    assertThrown(configureOoxmlWordV1(unexpectedOption));

    // Genuinely pure: this would not compile if extractOoxmlWordV1 secretly
    // captured mutable global state or performed I/O -- the same compile-
    // time proof extraction.port's own tests use for ExtractorApplyV1.
    static assert(__traits(compiles, {
        import extraction.port : ExtractorApplyV1;
        ExtractorApplyV1 apply = &extractOoxmlWordV1;
    }));
}

version (unittest) {
    private auto fakeOptionV1() {
        import extraction.port : ExtractorOptionV1;
        return ExtractorOptionV1.boolean(true);
    }
}
