/// Release-active proof for issue #298's minimal `dxml`-based OOXML
/// text-walker (`extraction.ooxml_document`): paragraphs (`w:p`), runs
/// (`w:r`), plain text (`w:t`), and basic table structure
/// (`w:tbl`/`w:tr`/`w:tc`), with `w:br`/`w:tab` folded in as text
/// separators. This checker builds and runs with no network access: every
/// fixture below is an in-memory constant.
///
/// Proof A authors synthetic `word/document.xml` fixtures directly and
/// walks them: plain paragraphs, a single visual word Word split across
/// multiple `w:r` runs (reassembled correctly across the run boundary), a
/// hyperlink (structurally transparent, its wrapped run still contributes
/// text), a simple table, and malformed/truncated XML -- rejected outright,
/// never silently repaired, the whole reason `dxml` was chosen over the
/// vendored `lexbor` HTML5 parser for this (see `extraction.ooxml_document`'s
/// module doc).
///
/// Proof B goes further than a synthetic XML string handed directly to the
/// walker: a real classic ZIP container, with `word/document.xml` genuinely
/// raw-DEFLATE compressed the way Word/LibreOffice/Google Docs actually
/// produce it (`documentDeflate` below is a real raw-DEFLATE stream for
/// `documentXml`, generated offline via Python's
/// `zlib.compressobj(9, zlib.DEFLATED, -15)` -- the same reference-
/// implementation round trip `effects.zlib_ffi`'s own unittest already uses
/// for exactly this kind of docx-shaped fixture). The container is admitted
/// through `extraction.container`'s real ZIP inspector and
/// `word/document.xml`'s real compressed bytes are decompressed through
/// `effects.zlib_ffi`'s real system-zlib-backed decoder -- not a fake or
/// synthetic decompressor -- and checked byte-for-byte against the original
/// plaintext before ever reaching the walker.
module experiments.ooxml_document_walker.check;

import content.pieces : Content, ContentPiece;
import effects.zlib_ffi : zipInflateV1;
import extraction.container : inspectZipContainerV1, ZipEvidenceV1,
    ZipInspectionLimitsV1, ZipInspectionReasonV1, ZipInspectionStatusV1,
    ZipPackageKindV1;
import extraction.ooxml_document : DocxBlockKindV1, OoxmlWalkStatusV1,
    walkOoxmlDocumentV1;
import std.algorithm.searching : canFind;
import std.stdio : writeln;

private int failures;

/// Not `assert`: this checker builds with LDC `-O3 -release`, which elides
/// the `assert` language construct -- mirrors the idiom established by
/// `experiments/document_metadata/check.d`. Every check here is a plain
/// runtime comparison so nothing this proof depends on can be compiled away.
private void expect(bool condition, string label) {
    if (condition) {
        writeln("ok   ", label);
    } else {
        writeln("FAIL ", label);
        ++failures;
    }
}

private void proofA_syntheticFixtures() {
    // --- Plain paragraphs. --------------------------------------------
    enum plainXml =
        `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` ~
        `<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">` ~
        `<w:body>` ~
        `<w:p><w:r><w:t>First paragraph.</w:t></w:r></w:p>` ~
        `<w:p><w:r><w:t>Second paragraph.</w:t></w:r></w:p>` ~
        `</w:body></w:document>`;
    auto plain = walkOoxmlDocumentV1(cast(const(ubyte)[]) plainXml);
    expect(plain.status == OoxmlWalkStatusV1.ok, "plain paragraphs: walk ok");
    expect(plain.document.blocks.length == 2, "plain paragraphs: two blocks");
    expect(plain.document.blocks[0].paragraph.text == "First paragraph.",
        "plain paragraphs: first text");
    expect(plain.document.blocks[1].paragraph.text == "Second paragraph.",
        "plain paragraphs: second text");

    // --- Runs split mid-word: real Word behavior. A single visual word is
    // frequently split across multiple w:r elements by spell-check/
    // formatting boundaries; the walker must reassemble it across the run
    // boundary, not treat each run's text as independently meaningful.
    enum splitXml =
        `<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">` ~
        `<w:body><w:p>` ~
        `<w:r><w:rPr><w:b/></w:rPr><w:t>Extraordi</w:t></w:r>` ~
        `<w:r><w:t>nary</w:t></w:r>` ~
        `<w:r><w:t xml:space="preserve"> claim.</w:t></w:r>` ~
        `</w:p></w:body></w:document>`;
    auto split = walkOoxmlDocumentV1(cast(const(ubyte)[]) splitXml);
    expect(split.status == OoxmlWalkStatusV1.ok, "mid-word split: walk ok");
    expect(split.document.blocks[0].paragraph.runs.length == 3,
        "mid-word split: three runs preserved individually");
    expect(split.document.blocks[0].paragraph.runs[0].text == "Extraordi",
        "mid-word split: first run text alone is not a whole word");
    expect(split.document.blocks[0].paragraph.text == "Extraordinary claim.",
        "mid-word split: reassembled across the run boundary");

    // --- A hyperlink: transparent, its wrapped run still contributes text.
    enum hyperlinkXml =
        `<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" ` ~
        `xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">` ~
        `<w:body><w:p>` ~
        `<w:r><w:t>See </w:t></w:r>` ~
        `<w:hyperlink r:id="rId7"><w:r><w:rPr><w:u w:val="single"/></w:rPr><w:t>the docs</w:t></w:r></w:hyperlink>` ~
        `<w:r><w:t> for more.</w:t></w:r>` ~
        `</w:p></w:body></w:document>`;
    auto hyperlink = walkOoxmlDocumentV1(cast(const(ubyte)[]) hyperlinkXml);
    expect(hyperlink.status == OoxmlWalkStatusV1.ok, "hyperlink: walk ok");
    expect(hyperlink.document.blocks[0].paragraph.runs.length == 3,
        "hyperlink: wrapped run flattened into paragraph's run list");
    expect(hyperlink.document.blocks[0].paragraph.text == "See the docs for more.",
        "hyperlink: full paragraph text including the wrapped run");

    // --- A simple table: 2 rows x 2 cells.
    enum tableXml =
        `<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">` ~
        `<w:body><w:tbl><w:tblPr/><w:tblGrid/>` ~
        `<w:tr><w:tc><w:p><w:r><w:t>A1</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>B1</w:t></w:r></w:p></w:tc></w:tr>` ~
        `<w:tr><w:tc><w:p><w:r><w:t>A2</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>B2</w:t></w:r></w:p></w:tc></w:tr>` ~
        `</w:tbl></w:body></w:document>`;
    auto table = walkOoxmlDocumentV1(cast(const(ubyte)[]) tableXml);
    expect(table.status == OoxmlWalkStatusV1.ok, "table: walk ok");
    expect(table.document.blocks[0].kind == DocxBlockKindV1.table, "table: block kind");
    auto rows = table.document.blocks[0].table.rows;
    expect(rows.length == 2 && rows[0].cells.length == 2 && rows[1].cells.length == 2,
        "table: 2x2 structure");
    expect(rows[0].cells[0].paragraphs[0].text == "A1" &&
        rows[0].cells[1].paragraphs[0].text == "B1" &&
        rows[1].cells[0].paragraphs[0].text == "A2" &&
        rows[1].cells[1].paragraphs[0].text == "B2",
        "table: cell text in row-major order");

    // --- w:br/w:tab: text separators, never dropped, never a real
    // paragraph/run boundary of their own.
    enum breakXml =
        `<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">` ~
        `<w:body><w:p>` ~
        `<w:r><w:t>Line one</w:t></w:r>` ~
        `<w:r><w:br/></w:r>` ~
        `<w:r><w:t>Line two, then</w:t></w:r>` ~
        `<w:r><w:tab/></w:r>` ~
        `<w:r><w:t>a tabbed tail.</w:t></w:r>` ~
        `</w:p></w:body></w:document>`;
    auto breaks = walkOoxmlDocumentV1(cast(const(ubyte)[]) breakXml);
    expect(breaks.status == OoxmlWalkStatusV1.ok, "br/tab: walk ok");
    expect(breaks.document.blocks[0].paragraph.text ==
        "Line one\nLine two, then\ta tabbed tail.",
        "br/tab: folded in as separators, not dropped");

    // --- Malformed/truncated XML: rejected outright, never silently
    // repaired. This is the whole reason dxml was chosen over lexbor.
    enum mismatchedXml =
        `<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">` ~
        `<w:body><w:p><w:r><w:t>Oops</w:t></w:r></w:q></w:body></w:document>`;
    expect(walkOoxmlDocumentV1(cast(const(ubyte)[]) mismatchedXml).status ==
        OoxmlWalkStatusV1.malformed, "mismatched end tag: rejected");

    enum truncatedXml =
        `<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">` ~
        `<w:body><w:p><w:r><w:t>Cut off mid-stream`;
    expect(walkOoxmlDocumentV1(cast(const(ubyte)[]) truncatedXml).status ==
        OoxmlWalkStatusV1.malformed, "truncated at EOF: rejected");

    expect(walkOoxmlDocumentV1(null).status == OoxmlWalkStatusV1.malformed,
        "empty input: rejected");

    // Invalid UTF-8 (a lone continuation byte) is refused before dxml ever
    // sees it.
    ubyte[] invalidUtf8 = cast(ubyte[]) "<w:p>".dup ~ cast(ubyte) 0x80 ~ cast(ubyte[]) "</w:p>".dup;
    expect(walkOoxmlDocumentV1(invalidUtf8).status == OoxmlWalkStatusV1.malformed,
        "invalid UTF-8: rejected");
}

/// A real raw-DEFLATE stream for `documentXml`, generated offline via
/// Python's `zlib.compressobj(9, zlib.DEFLATED, -15)` (wbits -15 selects
/// raw DEFLATE, the same framing ZIP local entries use) -- the same
/// reference-implementation-round-trip technique `effects.zlib_ffi`'s own
/// unittest already uses for a docx-shaped fixture, not a hand-authored
/// byte pattern.
private enum string documentXml =
    "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">\n<w:body>\n<w:p><w:r><w:t>Plain paragraph text.</w:t></w:r></w:p>\n<w:p><w:r><w:t>Hel</w:t></w:r><w:r><w:t>lo, wor</w:t></w:r><w:r><w:t>ld!</w:t></w:r></w:p>\n<w:p><w:r><w:t>Visit </w:t></w:r><w:hyperlink r:id=\"rId1\"><w:r><w:t>our site</w:t></w:r></w:hyperlink><w:r><w:t> today.</w:t></w:r></w:p>\n<w:tbl>\n<w:tr><w:tc><w:p><w:r><w:t>A1</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>B1</w:t></w:r></w:p></w:tc></w:tr>\n<w:tr><w:tc><w:p><w:r><w:t>A2</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>B2</w:t></w:r></w:p></w:tc></w:tr>\n</w:tbl>\n<w:p><w:r><w:t>Line one</w:t></w:r><w:r><w:br/></w:r><w:r><w:t>Line two after break, and a</w:t></w:r><w:r><w:tab/></w:r><w:r><w:t>tab-separated tail.</w:t></w:r></w:p>\n<w:sectPr><w:pgSz w:w=\"12240\" w:h=\"15840\"/></w:sectPr>\n</w:body>\n</w:document>\n";

private immutable ubyte[] documentDeflate = [
        149, 83, 75, 79, 195, 48, 12, 190, 243, 43, 76, 206, 176, 108, 21, 32,
        52, 173, 69, 32, 132, 64, 226, 128, 196, 227, 158, 54, 222, 26, 145, 38,
        145, 99, 40, 227, 215, 147, 118, 19, 140, 61, 120, 92, 220, 52, 254, 30,
        182, 28, 79, 206, 222, 26, 11, 175, 72, 209, 120, 151, 139, 209, 96, 40,
        0, 93, 229, 181, 113, 179, 92, 60, 62, 92, 29, 158, 10, 136, 172, 156,
        86, 214, 59, 204, 197, 28, 163, 56, 43, 246, 38, 237, 88, 251, 234, 165,
        65, 199, 144, 20, 92, 28, 183, 185, 168, 153, 195, 88, 202, 88, 213, 216,
        168, 56, 240, 1, 93, 202, 77, 61, 53, 138, 211, 47, 205, 100, 235, 73,
        7, 242, 21, 198, 152, 12, 26, 43, 179, 225, 240, 68, 54, 202, 56, 177,
        148, 161, 191, 200, 248, 233, 212, 84, 120, 185, 44, 96, 33, 66, 104, 21,
        167, 38, 98, 109, 66, 20, 125, 133, 165, 215, 243, 254, 16, 138, 20, 168,
        11, 92, 220, 217, 228, 6, 65, 145, 154, 145, 10, 53, 48, 190, 241, 96,
        34, 187, 84, 23, 169, 143, 97, 131, 118, 141, 246, 27, 232, 51, 97, 253,
        1, 164, 182, 118, 36, 245, 254, 239, 210, 79, 38, 26, 134, 53, 129, 122,
        30, 144, 172, 113, 207, 64, 99, 163, 115, 65, 55, 122, 36, 86, 72, 254,
        133, 32, 209, 112, 93, 254, 147, 183, 130, 5, 246, 90, 205, 119, 52, 201,
        165, 93, 124, 23, 224, 170, 88, 171, 238, 124, 180, 201, 235, 111, 170, 237,
        248, 139, 31, 240, 178, 183, 249, 209, 45, 251, 167, 91, 246, 187, 155, 252,
        106, 114, 149, 122, 107, 28, 66, 122, 211, 219, 38, 87, 146, 220, 152, 101,
        143, 231, 214, 131, 154, 50, 18, 148, 132, 234, 249, 0, 210, 102, 128, 218,
        58, 124, 85, 110, 106, 164, 203, 195, 136, 221, 227, 99, 212, 192, 202, 216,
        29, 83, 137, 88, 241, 93, 79, 10, 179, 251, 119, 104, 187, 245, 26, 101,
        217, 81, 90, 207, 52, 227, 116, 62, 62, 77, 231, 133, 193, 18, 219, 55,
        186, 124, 242, 242, 107, 61, 139, 189, 15
];

private void put16(ref ubyte[] bytes, ushort value) {
    bytes ~= cast(ubyte) value;
    bytes ~= cast(ubyte) (value >> 8);
}

private void put32(ref ubyte[] bytes, uint value) {
    foreach (shift; 0 .. 4) bytes ~= cast(ubyte) (value >> (8 * shift));
}

/// Minimal single-disk classic ZIP: STORE entries for `[Content_Types].xml`
/// and `_rels/.rels` (so `extraction.container` recognizes the OOXML Word
/// package markers), plus one DEFLATE (method 8) `word/document.xml` entry.
/// A small, self-contained mirror of `effects.zlib_ffi`'s own (private,
/// module-local) `buildSingleDeflateEntryZip` test helper -- this checker
/// cannot reuse that one directly since it is private to its module.
private ubyte[] buildDocxZip(string deflateName, const(ubyte)[] deflateData,
        uint declaredExpanded) {
    ubyte[] bytes;
    struct Written { string name; uint offset; ushort method; uint compressed; uint expanded; }
    Written[] written;

    void writeStoreEntry(string name) {
        auto offset = cast(uint) bytes.length;
        put32(bytes, 0x04034b50);
        put16(bytes, 20); put16(bytes, 0); put16(bytes, 0);
        put16(bytes, 0); put16(bytes, 0);
        put32(bytes, 0);
        put32(bytes, 0); put32(bytes, 0);
        put16(bytes, cast(ushort) name.length); put16(bytes, 0);
        bytes ~= cast(const(ubyte)[]) name;
        written ~= Written(name, offset, 0, 0, 0);
    }

    void writeDeflateEntry(string name, const(ubyte)[] data, uint expanded) {
        auto offset = cast(uint) bytes.length;
        put32(bytes, 0x04034b50);
        put16(bytes, 20); put16(bytes, 0); put16(bytes, 8);
        put16(bytes, 0); put16(bytes, 0);
        put32(bytes, 0);
        put32(bytes, cast(uint) data.length); put32(bytes, expanded);
        put16(bytes, cast(ushort) name.length); put16(bytes, 0);
        bytes ~= cast(const(ubyte)[]) name;
        bytes ~= data;
        written ~= Written(name, offset, 8, cast(uint) data.length, expanded);
    }

    writeStoreEntry("[Content_Types].xml");
    writeStoreEntry("_rels/.rels");
    writeDeflateEntry(deflateName, deflateData, declaredExpanded);

    auto centralOffset = cast(uint) bytes.length;
    foreach (entry; written) {
        put32(bytes, 0x02014b50);
        put16(bytes, 20); put16(bytes, 20);
        put16(bytes, 0); put16(bytes, entry.method);
        put16(bytes, 0); put16(bytes, 0);
        put32(bytes, 0);
        put32(bytes, entry.compressed); put32(bytes, entry.expanded);
        put16(bytes, cast(ushort) entry.name.length);
        put16(bytes, 0); put16(bytes, 0);
        put16(bytes, 0); put16(bytes, 0); put32(bytes, 0);
        put32(bytes, entry.offset);
        bytes ~= cast(const(ubyte)[]) entry.name;
    }
    auto centralBytes = cast(uint) bytes.length - centralOffset;
    put32(bytes, 0x06054b50);
    put16(bytes, 0); put16(bytes, 0);
    put16(bytes, cast(ushort) written.length);
    put16(bytes, cast(ushort) written.length);
    put32(bytes, centralBytes);
    put32(bytes, centralOffset);
    put16(bytes, 0);
    return bytes;
}

private void proofB_realZipRoundTrip() {
    auto docx = buildDocxZip("word/document.xml", documentDeflate,
        cast(uint) documentXml.length);
    auto content = new Content([ContentPiece.own(docx)]);
    auto result = inspectZipContainerV1(content, ZipInspectionLimitsV1(), zipInflateV1);
    expect(result.status == ZipInspectionStatusV1.admitted,
        "real docx zip: admitted by extraction.container's real ZIP inspector");
    expect(result.packageKind == ZipPackageKindV1.ooxmlWord,
        "real docx zip: OOXML Word package markers detected");
    expect(result.evidence.canFind(ZipEvidenceV1.deflatePresent),
        "real docx zip: DEFLATE evidence recorded");

    bool foundDocument;
    foreach (entry; result.admitted.entries)
        if (entry.name == "word/document.xml") {
            foundDocument = true;
            expect(entry.isDeflate, "real docx zip: word/document.xml recorded as DEFLATE");
            expect(entry.expandedBytes == documentXml.length,
                "real docx zip: inflate-discovered size matches the real plaintext length");
        }
    expect(foundDocument, "real docx zip: word/document.xml entry present");

    // Decompress the entry's real compressed bytes through
    // effects.zlib_ffi's real system-zlib-backed decoder directly (the same
    // injected ZipInflateV1 boundary extraction.container uses internally,
    // but invoked here to actually retain the produced bytes -- this
    // slice's container.d does not yet expose DEFLATE entry bytes through
    // its own streaming capability; see extraction.container's
    // ZipEntryEvidenceV1.isDeflate doc). This is a real decompression of a
    // real DEFLATE stream, not a synthetic bypass.
    ubyte[] decompressed;
    auto outcome = zipInflateV1(documentDeflate,
        (const(ubyte)[] chunk) { decompressed ~= chunk; });
    expect(decompressed == cast(const(ubyte)[]) documentXml,
        "real docx zip: decompressed bytes are byte-for-byte identical to the original plaintext");

    // Now feed those genuinely-inflated bytes -- not a synthetic XML string
    // -- into the walker and confirm full extraction.
    auto walked = walkOoxmlDocumentV1(decompressed);
    expect(walked.status == OoxmlWalkStatusV1.ok,
        "real docx zip: walker accepts the genuinely-inflated bytes");
    auto blocks = walked.document.blocks;
    expect(blocks.length == 5, "real docx zip: five top-level blocks");
    expect(blocks.length > 0 && blocks[0].paragraph.text == "Plain paragraph text.",
        "real docx zip: plain paragraph text");
    expect(blocks.length > 1 && blocks[1].paragraph.text == "Hello, world!",
        "real docx zip: mid-word split runs reassembled ('Hel'+'lo, wor'+'ld!')");
    expect(blocks.length > 2 && blocks[2].paragraph.text == "Visit our site today.",
        "real docx zip: hyperlink's wrapped run flattened into paragraph text");
    expect(blocks.length > 3 && blocks[3].kind == DocxBlockKindV1.table &&
        blocks[3].table.rows.length == 2 &&
        blocks[3].table.rows[0].cells[0].paragraphs[0].text == "A1" &&
        blocks[3].table.rows[1].cells[1].paragraphs[0].text == "B2",
        "real docx zip: 2x2 table structure");
    expect(blocks.length > 4 && blocks[4].paragraph.text ==
        "Line one\nLine two after break, and a\ttab-separated tail.",
        "real docx zip: w:br/w:tab folded in as separators");
}

int main() {
    proofA_syntheticFixtures();
    proofB_realZipRoundTrip();

    if (failures) {
        writeln("FAILED: ", failures, " check(s)");
        return 1;
    }
    writeln("ooxml_document_walker check: ok");
    return 0;
}
