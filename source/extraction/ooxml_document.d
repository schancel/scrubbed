/// Minimal, "good enough" `word/document.xml` text-walker: paragraphs
/// (`w:p`), runs (`w:r`), plain text (`w:t`), and basic table structure
/// (`w:tbl`/`w:tr`/`w:tc`), matching this codebase's extraction philosophy
/// already established by `html_main_content.d` -- not full-fidelity OOXML.
///
/// Built on `dxml` (pure D, Boost-1.0, range-based StAX/DOM XML 1.0 parser)
/// rather than the vendored `lexbor` HTML5 parser: empirical testing found a
/// real lexbor correctness bug on OOXML (self-closing elements mis-nested by
/// HTML5-specific tree-construction rules) and silent HTML5 error-recovery
/// on malformed input -- the opposite of this codebase's explicit-refusal
/// philosophy (see `extraction.container`'s closed refusal vocabulary).
/// `dxml` rejects ill-formed XML outright instead of repairing it.
///
/// This module does its own element-qualified-name resolution against the
/// declared `xmlns`/`xmlns:*` scope in force at each element, rather than
/// matching the literal `"w:..."` prefix string: a document that bound the
/// WordprocessingML namespace to a different prefix would still be walked
/// correctly. `dxml` itself has no namespace awareness (it is a plain XML
/// 1.0 parser); the resolution happens here.
///
/// Pure XML parsing over already-decompressed bytes: no FFI, `dlopen`, or
/// file/network/process I/O of its own (see `extraction/README.md`). The
/// real bytes for `word/document.xml` come from a caller that has already
/// resolved them (e.g. via `extraction.container`'s admitted ZIP entries
/// plus an injected `effects`-layer DEFLATE decompressor); this module never
/// touches a ZIP container or the filesystem itself.
///
/// Deliberately out of scope (see issue #298): headers/footers/footnotes/
/// endnotes (separate zip parts and relationship resolution), fields
/// (`w:fldSimple`/`w:fldChar`/`w:instrText`), track changes (`w:ins`/
/// `w:del`), embedded objects, and legacy `.doc`. Any element this walker
/// does not recognize -- including all of the above -- is silently skipped
/// as an opaque subtree, never surfaced as text and never treated as an
/// error; only ill-formed XML itself is refused.
module extraction.ooxml_document;

import dxml.parser : EntityType, parseXML, simpleXML, XMLParsingException;
import dxml.util : decodeXML;
import std.exception : enforce;
import std.string : indexOf;
import std.utf : UTFException, validate;

/// The WordprocessingML main namespace. Every recognized element name below
/// is resolved against this URI, not against a literal `"w:"` prefix.
private enum string wordprocessingNamespaceV1 =
    "http://schemas.openxmlformats.org/wordprocessingml/2006/main";

/// One run (`w:r`). `text` already has `w:t` content decoded
/// (predefined entity references and character references resolved via
/// `dxml.util.decodeXML`) and has `w:br`/`w:tab` folded in as plain
/// separators (`"\n"`/`"\t"`) in document order -- never dropped, never
/// treated as a paragraph/run boundary of their own.
struct DocxRunV1 {
    string text;
}

/// One paragraph (`w:p`). `w:hyperlink` is structurally transparent: its
/// child runs are flattened directly into the paragraph's run list in
/// document order, since relationship-target resolution is out of scope
/// (see issue #298 non-goals) but the run text it wraps is still real
/// paragraph content.
struct DocxParagraphV1 {
    DocxRunV1[] runs;

    /// The paragraph's full text, reassembled across every run boundary --
    /// including a single visual word Word split across multiple `w:r`
    /// elements (a routine spell-check/formatting artifact, not a real word
    /// boundary).
    string text() const pure {
        string result;
        foreach (run; runs) result ~= run.text;
        return result;
    }
}

/// One table cell (`w:tc`). Only direct child paragraphs are collected; a
/// nested `w:tbl` inside a cell is skipped like any other unrecognized
/// subtree (basic table structure only, per issue #298).
struct DocxTableCellV1 {
    DocxParagraphV1[] paragraphs;
}

/// One table row (`w:tr`).
struct DocxTableRowV1 {
    DocxTableCellV1[] cells;
}

/// One table (`w:tbl`).
struct DocxTableV1 {
    DocxTableRowV1[] rows;
}

/// Discriminates `DocxBlockV1`'s payload.
enum DocxBlockKindV1 : ubyte { paragraph, table }

/// One direct child of `w:body`: either a paragraph or a table, in document
/// order.
struct DocxBlockV1 {
    DocxBlockKindV1 kind;
    DocxParagraphV1 paragraph; // meaningful iff kind == paragraph
    DocxTableV1 table; // meaningful iff kind == table
}

/// The walked document: every recognized `w:body` child, in document order.
struct DocxDocumentV1 {
    DocxBlockV1[] blocks;
}

/// `ok` means the input was well-formed XML 1.0 and was walked (regardless
/// of whether it happened to contain any recognized WordprocessingML
/// structure -- an XML document with no `w:document`/`w:body` walks to an
/// empty `DocxDocumentV1`, which is not an error). `malformed` covers both
/// invalid UTF-8 and any ill-formed XML dxml itself refuses to parse
/// (mismatched tags, truncated input, invalid entity references, and so
/// on): rejected outright, never silently repaired.
enum OoxmlWalkStatusV1 : ubyte { ok, malformed }

/// Outcome of one walk attempt.
struct OoxmlWalkResultV1 {
    OoxmlWalkStatusV1 status;
    DocxDocumentV1 document; // meaningful iff status == ok
}

/// Walks already-decompressed `word/document.xml` bytes. Never throws:
/// every failure mode is the coded `OoxmlWalkStatusV1.malformed` outcome,
/// the same discipline `extraction.container`'s refusal vocabulary already
/// follows for this codebase's ZIP inspector.
OoxmlWalkResultV1 walkOoxmlDocumentV1(const(ubyte)[] documentXmlBytes) {
    OoxmlWalkResultV1 result;
    string xml;
    try {
        xml = cast(string) documentXmlBytes.idup;
        validate(xml);
    } catch (UTFException) {
        result.status = OoxmlWalkStatusV1.malformed;
        return result;
    }
    try {
        auto range = parseXML!simpleXML(xml);
        result.document = walkTopLevel(range);
        result.status = OoxmlWalkStatusV1.ok;
    } catch (XMLParsingException) {
        result.status = OoxmlWalkStatusV1.malformed;
    }
    return result;
}

private alias NsScope = string[string];

private struct ResolvedNameV1 {
    string uri;
    string local;
}

/// Resolves a raw `dxml` qualified name (e.g. `"w:p"` or `"p"`) against the
/// namespace scope in force, the way a namespace-aware XML consumer must:
/// by declared `xmlns`/`xmlns:*` bindings, never by matching the literal
/// prefix text. An unresolved prefix or no in-scope default namespace
/// yields an empty `uri`, which simply never matches a recognized element
/// -- the same fail-closed default as any other unrecognized subtree.
private ResolvedNameV1 resolveQName(string qname, const(NsScope) scope_) {
    auto colon = qname.indexOf(':');
    if (colon >= 0) {
        auto prefix = qname[0 .. colon];
        auto local = qname[colon + 1 .. $];
        auto found = prefix in scope_;
        return ResolvedNameV1(found ? *found : "", local);
    }
    auto found = "" in scope_;
    return ResolvedNameV1(found ? *found : "", qname);
}

/// Extends `parentScope` with the `xmlns`/`xmlns:*` declarations carried on
/// `entity` itself -- per the XML namespaces spec, declarations on an
/// element apply starting with that same element's own name.
private NsScope extendScope(Entity)(Entity entity, const(NsScope) parentScope) {
    NsScope result;
    foreach (prefix, uri; parentScope) result[prefix] = uri;
    foreach (attr; entity.attributes) {
        if (attr.name == "xmlns")
            result[""] = attr.value.idup;
        else if (attr.name.length > 6 && attr.name[0 .. 6] == "xmlns:")
            result[attr.name[6 .. $].idup] = attr.value.idup;
    }
    return result;
}

/// Consumes one complete, unrecognized element subtree -- called with
/// `range.front.type == EntityType.elementStart` for that element, not yet
/// consumed. Recurses into any nested element rather than tracking depth by
/// hand: `dxml` guarantees a well-formed stream (or throws), so the next
/// `elementEnd` seen after every nested `elementStart` has itself been
/// fully consumed is always this element's own closing tag.
private void skipElement(R)(ref R range) {
    range.popFront(); // the element's own start tag
    while (range.front.type != EntityType.elementEnd) {
        if (range.front.type == EntityType.elementStart)
            skipElement(range);
        else
            range.popFront();
    }
    range.popFront(); // the element's own end tag
}

private DocxDocumentV1 walkTopLevel(R)(ref R range) {
    DocxDocumentV1 doc;
    NsScope rootScope;
    while (!range.empty) {
        if (range.front.type != EntityType.elementStart) {
            range.popFront();
            continue;
        }
        auto scope_ = extendScope(range.front, rootScope);
        auto resolved = resolveQName(range.front.name, scope_);
        if (resolved.uri == wordprocessingNamespaceV1 && resolved.local == "document")
            doc = walkDocumentElement(range, scope_);
        else
            skipElement(range);
    }
    return doc;
}

private DocxDocumentV1 walkDocumentElement(R)(ref R range, const(NsScope) scope_) {
    DocxDocumentV1 doc;
    range.popFront(); // <w:document>
    while (range.front.type != EntityType.elementEnd) {
        if (range.front.type != EntityType.elementStart) {
            range.popFront();
            continue;
        }
        auto childScope = extendScope(range.front, scope_);
        auto resolved = resolveQName(range.front.name, childScope);
        if (resolved.uri == wordprocessingNamespaceV1 && resolved.local == "body")
            doc.blocks = walkBody(range, childScope);
        else
            skipElement(range);
    }
    range.popFront(); // </w:document>
    return doc;
}

private DocxBlockV1[] walkBody(R)(ref R range, const(NsScope) scope_) {
    DocxBlockV1[] blocks;
    range.popFront(); // <w:body>
    while (range.front.type != EntityType.elementEnd) {
        if (range.front.type != EntityType.elementStart) {
            range.popFront();
            continue;
        }
        auto childScope = extendScope(range.front, scope_);
        auto resolved = resolveQName(range.front.name, childScope);
        if (resolved.uri == wordprocessingNamespaceV1 && resolved.local == "p") {
            DocxBlockV1 block;
            block.kind = DocxBlockKindV1.paragraph;
            block.paragraph = walkParagraph(range, childScope);
            blocks ~= block;
        } else if (resolved.uri == wordprocessingNamespaceV1 && resolved.local == "tbl") {
            DocxBlockV1 block;
            block.kind = DocxBlockKindV1.table;
            block.table = walkTable(range, childScope);
            blocks ~= block;
        } else {
            skipElement(range);
        }
    }
    range.popFront(); // </w:body>
    return blocks;
}

private DocxParagraphV1 walkParagraph(R)(ref R range, const(NsScope) scope_) {
    DocxParagraphV1 para;
    range.popFront(); // <w:p>
    while (range.front.type != EntityType.elementEnd) {
        if (range.front.type != EntityType.elementStart) {
            range.popFront();
            continue;
        }
        auto childScope = extendScope(range.front, scope_);
        auto resolved = resolveQName(range.front.name, childScope);
        if (resolved.uri == wordprocessingNamespaceV1 && resolved.local == "r") {
            para.runs ~= walkRun(range, childScope);
        } else if (resolved.uri == wordprocessingNamespaceV1 && resolved.local == "hyperlink") {
            para.runs ~= walkHyperlink(range, childScope);
        } else {
            skipElement(range);
        }
    }
    range.popFront(); // </w:p>
    return para;
}

/// `w:hyperlink` is structurally transparent (see `DocxParagraphV1`): its
/// child runs are returned to be spliced directly into the enclosing
/// paragraph's run list.
private DocxRunV1[] walkHyperlink(R)(ref R range, const(NsScope) scope_) {
    DocxRunV1[] runs;
    range.popFront(); // <w:hyperlink>
    while (range.front.type != EntityType.elementEnd) {
        if (range.front.type != EntityType.elementStart) {
            range.popFront();
            continue;
        }
        auto childScope = extendScope(range.front, scope_);
        auto resolved = resolveQName(range.front.name, childScope);
        if (resolved.uri == wordprocessingNamespaceV1 && resolved.local == "r")
            runs ~= walkRun(range, childScope);
        else
            skipElement(range);
    }
    range.popFront(); // </w:hyperlink>
    return runs;
}

private DocxRunV1 walkRun(R)(ref R range, const(NsScope) scope_) {
    DocxRunV1 run;
    range.popFront(); // <w:r>
    while (range.front.type != EntityType.elementEnd) {
        if (range.front.type != EntityType.elementStart) {
            range.popFront();
            continue;
        }
        auto childScope = extendScope(range.front, scope_);
        auto resolved = resolveQName(range.front.name, childScope);
        if (resolved.uri == wordprocessingNamespaceV1 && resolved.local == "t") {
            run.text ~= walkText(range);
        } else if (resolved.uri == wordprocessingNamespaceV1 &&
                (resolved.local == "br" || resolved.local == "tab")) {
            run.text ~= resolved.local == "tab" ? "\t" : "\n";
            skipElement(range);
        } else {
            skipElement(range);
        }
    }
    range.popFront(); // </w:r>
    return run;
}

private string walkText(R)(ref R range) {
    string text;
    range.popFront(); // <w:t>
    while (range.front.type != EntityType.elementEnd) {
        if (range.front.type == EntityType.text || range.front.type == EntityType.cdata) {
            text ~= decodeXML(range.front.text);
            range.popFront();
        } else if (range.front.type == EntityType.elementStart) {
            skipElement(range); // not expected inside w:t; ignore defensively
        } else {
            range.popFront();
        }
    }
    range.popFront(); // </w:t>
    return text;
}

private DocxTableV1 walkTable(R)(ref R range, const(NsScope) scope_) {
    DocxTableV1 table;
    range.popFront(); // <w:tbl>
    while (range.front.type != EntityType.elementEnd) {
        if (range.front.type != EntityType.elementStart) {
            range.popFront();
            continue;
        }
        auto childScope = extendScope(range.front, scope_);
        auto resolved = resolveQName(range.front.name, childScope);
        if (resolved.uri == wordprocessingNamespaceV1 && resolved.local == "tr")
            table.rows ~= walkTableRow(range, childScope);
        else
            skipElement(range); // w:tblPr, w:tblGrid, ...
    }
    range.popFront(); // </w:tbl>
    return table;
}

private DocxTableRowV1 walkTableRow(R)(ref R range, const(NsScope) scope_) {
    DocxTableRowV1 row;
    range.popFront(); // <w:tr>
    while (range.front.type != EntityType.elementEnd) {
        if (range.front.type != EntityType.elementStart) {
            range.popFront();
            continue;
        }
        auto childScope = extendScope(range.front, scope_);
        auto resolved = resolveQName(range.front.name, childScope);
        if (resolved.uri == wordprocessingNamespaceV1 && resolved.local == "tc")
            row.cells ~= walkTableCell(range, childScope);
        else
            skipElement(range); // w:trPr, ...
    }
    range.popFront(); // </w:tr>
    return row;
}

private DocxTableCellV1 walkTableCell(R)(ref R range, const(NsScope) scope_) {
    DocxTableCellV1 cell;
    range.popFront(); // <w:tc>
    while (range.front.type != EntityType.elementEnd) {
        if (range.front.type != EntityType.elementStart) {
            range.popFront();
            continue;
        }
        auto childScope = extendScope(range.front, scope_);
        auto resolved = resolveQName(range.front.name, childScope);
        if (resolved.uri == wordprocessingNamespaceV1 && resolved.local == "p")
            cell.paragraphs ~= walkParagraph(range, childScope);
        else
            skipElement(range); // w:tcPr, a nested w:tbl (out of scope), ...
    }
    range.popFront(); // </w:tc>
    return cell;
}

unittest {
    // --- Plain paragraphs. ------------------------------------------------
    enum plainXml =
        `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` ~
        `<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">` ~
        `<w:body>` ~
        `<w:p><w:r><w:t>First paragraph.</w:t></w:r></w:p>` ~
        `<w:p><w:r><w:t>Second paragraph.</w:t></w:r></w:p>` ~
        `</w:body></w:document>`;
    auto plain = walkOoxmlDocumentV1(cast(const(ubyte)[]) plainXml);
    assert(plain.status == OoxmlWalkStatusV1.ok);
    assert(plain.document.blocks.length == 2);
    assert(plain.document.blocks[0].kind == DocxBlockKindV1.paragraph);
    assert(plain.document.blocks[0].paragraph.text == "First paragraph.");
    assert(plain.document.blocks[1].paragraph.text == "Second paragraph.");

    // --- Runs split mid-word: real Word behavior (spell-check/formatting
    // boundaries routinely split one visual word across multiple w:r
    // elements). The walker must reassemble the word across the run
    // boundary, not treat each run as independent text.
    enum splitXml =
        `<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">` ~
        `<w:body><w:p>` ~
        `<w:r><w:rPr><w:b/></w:rPr><w:t>Extraordi</w:t></w:r>` ~
        `<w:r><w:t>nary</w:t></w:r>` ~
        `<w:r><w:t xml:space="preserve"> claim.</w:t></w:r>` ~
        `</w:p></w:body></w:document>`;
    auto split = walkOoxmlDocumentV1(cast(const(ubyte)[]) splitXml);
    assert(split.status == OoxmlWalkStatusV1.ok);
    assert(split.document.blocks.length == 1);
    assert(split.document.blocks[0].paragraph.runs.length == 3);
    assert(split.document.blocks[0].paragraph.runs[0].text == "Extraordi");
    assert(split.document.blocks[0].paragraph.runs[1].text == "nary");
    // The whole word is only correctly readable once runs are reassembled.
    assert(split.document.blocks[0].paragraph.text == "Extraordinary claim.");

    // --- A hyperlink: transparent, its wrapped run still contributes text,
    // and the relationship id (r:id) is never resolved (out of scope).
    enum hyperlinkXml =
        `<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" ` ~
        `xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">` ~
        `<w:body><w:p>` ~
        `<w:r><w:t>See </w:t></w:r>` ~
        `<w:hyperlink r:id="rId7"><w:r><w:rPr><w:u w:val="single"/></w:rPr><w:t>the docs</w:t></w:r></w:hyperlink>` ~
        `<w:r><w:t> for more.</w:t></w:r>` ~
        `</w:p></w:body></w:document>`;
    auto hyperlink = walkOoxmlDocumentV1(cast(const(ubyte)[]) hyperlinkXml);
    assert(hyperlink.status == OoxmlWalkStatusV1.ok);
    assert(hyperlink.document.blocks[0].paragraph.runs.length == 3);
    assert(hyperlink.document.blocks[0].paragraph.text == "See the docs for more.");

    // --- A simple table: 2 rows x 2 cells, each cell holding one paragraph.
    enum tableXml =
        `<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">` ~
        `<w:body><w:tbl><w:tblPr/><w:tblGrid/>` ~
        `<w:tr><w:tc><w:p><w:r><w:t>A1</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>B1</w:t></w:r></w:p></w:tc></w:tr>` ~
        `<w:tr><w:tc><w:p><w:r><w:t>A2</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>B2</w:t></w:r></w:p></w:tc></w:tr>` ~
        `</w:tbl></w:body></w:document>`;
    auto table = walkOoxmlDocumentV1(cast(const(ubyte)[]) tableXml);
    assert(table.status == OoxmlWalkStatusV1.ok);
    assert(table.document.blocks.length == 1);
    assert(table.document.blocks[0].kind == DocxBlockKindV1.table);
    auto rows = table.document.blocks[0].table.rows;
    assert(rows.length == 2 && rows[0].cells.length == 2 && rows[1].cells.length == 2);
    assert(rows[0].cells[0].paragraphs[0].text == "A1");
    assert(rows[0].cells[1].paragraphs[0].text == "B1");
    assert(rows[1].cells[0].paragraphs[0].text == "A2");
    assert(rows[1].cells[1].paragraphs[0].text == "B2");

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
    assert(breaks.status == OoxmlWalkStatusV1.ok);
    assert(breaks.document.blocks.length == 1);
    assert(breaks.document.blocks[0].paragraph.text ==
        "Line one\nLine two, then\ta tabbed tail.");

    // --- Predefined entity references and a decimal character reference
    // are decoded in w:t text.
    enum entityXml =
        `<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">` ~
        `<w:body><w:p><w:r><w:t>Terms &amp; Conditions &#169;</w:t></w:r></w:p></w:body></w:document>`;
    auto entity = walkOoxmlDocumentV1(cast(const(ubyte)[]) entityXml);
    assert(entity.status == OoxmlWalkStatusV1.ok);
    assert(entity.document.blocks[0].paragraph.text == "Terms & Conditions ©");

    // --- Malformed/truncated XML: rejected outright, never silently
    // repaired (the whole reason dxml was chosen over lexbor for this).
    enum mismatchedXml =
        `<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">` ~
        `<w:body><w:p><w:r><w:t>Oops</w:t></w:r></w:q></w:body></w:document>`;
    assert(walkOoxmlDocumentV1(cast(const(ubyte)[]) mismatchedXml).status ==
        OoxmlWalkStatusV1.malformed);

    enum truncatedXml =
        `<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">` ~
        `<w:body><w:p><w:r><w:t>Cut off mid-stream`;
    assert(walkOoxmlDocumentV1(cast(const(ubyte)[]) truncatedXml).status ==
        OoxmlWalkStatusV1.malformed);

    enum unclosedAttrXml =
        `<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">` ~
        `<w:body><w:p><w:r><w:t xml:space="preserve>broken attribute</w:t></w:r></w:p></w:body></w:document>`;
    assert(walkOoxmlDocumentV1(cast(const(ubyte)[]) unclosedAttrXml).status ==
        OoxmlWalkStatusV1.malformed);

    assert(walkOoxmlDocumentV1(null).status == OoxmlWalkStatusV1.malformed);
    assert(walkOoxmlDocumentV1(cast(const(ubyte)[]) "not xml at all").status ==
        OoxmlWalkStatusV1.malformed);

    // Invalid UTF-8 (a lone continuation byte) is refused before dxml ever
    // sees it, not treated as a crash or an empty document.
    ubyte[] invalidUtf8 = cast(ubyte[]) "<w:p>".dup ~ cast(ubyte) 0x80 ~ cast(ubyte[]) "</w:p>".dup;
    assert(walkOoxmlDocumentV1(invalidUtf8).status == OoxmlWalkStatusV1.malformed);

    // --- Genuine namespace-URI resolution, not literal "w:" prefix
    // matching: a document that bound the WordprocessingML namespace to a
    // different prefix is still walked correctly, and an element merely
    // named "p"/"r"/"t" in some *other* namespace (or no namespace) is
    // correctly left unrecognized.
    enum renamedPrefixXml =
        `<doc:document xmlns:doc="http://schemas.openxmlformats.org/wordprocessingml/2006/main">` ~
        `<doc:body><doc:p><doc:r><doc:t>Renamed prefix still resolves.</doc:t></doc:r></doc:p></doc:body></doc:document>`;
    auto renamedPrefix = walkOoxmlDocumentV1(cast(const(ubyte)[]) renamedPrefixXml);
    assert(renamedPrefix.status == OoxmlWalkStatusV1.ok);
    assert(renamedPrefix.document.blocks.length == 1);
    assert(renamedPrefix.document.blocks[0].paragraph.text == "Renamed prefix still resolves.");

    enum wrongNamespaceXml =
        `<w:document xmlns:w="urn:not-wordprocessingml">` ~
        `<w:body><w:p><w:r><w:t>Should not be recognized.</w:t></w:r></w:p></w:body></w:document>`;
    auto wrongNamespace = walkOoxmlDocumentV1(cast(const(ubyte)[]) wrongNamespaceXml);
    assert(wrongNamespace.status == OoxmlWalkStatusV1.ok);
    // w:document itself did not resolve to the real WordprocessingML
    // namespace, so it was skipped as an unrecognized element: no blocks.
    assert(wrongNamespace.document.blocks.length == 0);
}
