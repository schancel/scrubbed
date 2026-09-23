module generate_fixtures;

import std.array : appender, join;
import std.conv : to;
import std.file : mkdirRecurse, write;
import std.format : formattedWrite;
import std.path : buildPath;
import std.string : representation;
import std.zip : ArchiveMember, CompressionMethod, ZipArchive;

private string pdfEscape(string value)
{
    string escaped;
    foreach (character; value)
    {
        if (character == '(' || character == ')' || character == '\\')
            escaped ~= '\\';
        escaped ~= character;
    }
    return escaped;
}

private void writePdf(string path, string[] operators)
{
    const stream = operators.join("\n") ~ "\n";
    string[] objects = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " ~
            "/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
        "<< /Length " ~ stream.length.to!string ~ " >>\nstream\n" ~ stream ~ "endstream",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ];

    auto output = appender!string();
    // NUL in the binary marker keeps version-control whitespace checks from
    // treating fixed-width xref records as text with trailing whitespace.
    output.put("%PDF-1.4\n%\0 synthetic CC0 fixture\n");
    size_t[] offsets;
    foreach (index, object; objects)
    {
        offsets ~= output.data.length;
        output.formattedWrite("%s 0 obj\n%s\nendobj\n", index + 1, object);
    }
    const xrefOffset = output.data.length;
    output.formattedWrite("xref\n0 %s\n0000000000 65535 f \n", objects.length + 1);
    foreach (offset; offsets)
        output.formattedWrite("%010d 00000 n \n", offset);
    output.formattedWrite(
        "trailer\n<< /Size %s /Root 1 0 R >>\nstartxref\n%s\n%%%%EOF\n",
        objects.length + 1,
        xrefOffset,
    );
    write(path, output.data);
}

private string textAt(int x, int y, string text)
{
    return "BT /F1 12 Tf " ~ x.to!string ~ " " ~ y.to!string ~
        " Td (" ~ pdfEscape(text) ~ ") Tj ET";
}

private void addMember(ZipArchive archive, string name, string contents)
{
    auto member = new ArchiveMember();
    member.name = name;
    member.expandedData(contents.dup.representation);
    member.compressionMethod = CompressionMethod.deflate;
    archive.addMember(member);
}

private void writeDocx(string path, string body)
{
    auto archive = new ZipArchive();
    addMember(archive, "[Content_Types].xml", q"XML
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>
XML");
    addMember(archive, "_rels/.rels", q"XML
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>
XML");
    addMember(archive, "word/document.xml",
        `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` ~
        `<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>` ~
        body ~ `<w:sectPr/></w:body></w:document>`);
    write(path, archive.build());
}

private string paragraph(string value)
{
    return `<w:p><w:r><w:t>` ~ value ~ `</w:t></w:r></w:p>`;
}

private string cell(string value)
{
    return `<w:tc><w:tcPr/><w:p><w:r><w:t>` ~ value ~
        `</w:t></w:r></w:p></w:tc>`;
}

void main(string[] arguments)
{
    const root = arguments.length == 2 ? arguments[1] :
        "experiments/document_adapters/fixtures";
    mkdirRecurse(root);

    writePdf(buildPath(root, "pdf-training.pdf"), [
        textAt(72, 720, "TRAINING PDF"),
        textAt(72, 690, "ALPHA ONE"),
        textAt(72, 670, "BETA TWO"),
    ]);
    writePdf(buildPath(root, "pdf-heldout-layout.pdf"), [
        textAt(72, 740, "LAYOUT REPORT"),
        textAt(72, 700, "LEFT A"),
        textAt(72, 680, "LEFT B"),
        textAt(330, 700, "RIGHT A"),
        textAt(330, 680, "RIGHT B"),
        textAt(72, 620, "FOOTER END"),
    ]);
    write(buildPath(root, "pdf-malformed.pdf"), "%PDF-1.7\n1 0 obj\nBROKEN");

    writeDocx(buildPath(root, "docx-training.docx"),
        paragraph("TRAINING DOCX") ~ paragraph("GAMMA THREE") ~
        paragraph("DELTA FOUR"));
    writeDocx(buildPath(root, "docx-heldout-layout.docx"),
        paragraph("OFFICE LAYOUT") ~
        `<w:tbl><w:tblPr/><w:tblGrid><w:gridCol w:w="3000"/><w:gridCol w:w="3000"/></w:tblGrid>` ~
        `<w:tr>` ~ cell("ROW1 LEFT") ~ cell("ROW1 RIGHT") ~ `</w:tr>` ~
        `<w:tr>` ~ cell("ROW2 LEFT") ~ cell("ROW2 RIGHT") ~ `</w:tr></w:tbl>` ~
        paragraph("OFFICE END"));
    write(buildPath(root, "docx-malformed.docx"), "PK\x03\x04BROKEN");
}
