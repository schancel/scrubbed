/// Finite core UTF-8 plain-text extractor for dispatch v4.
module extraction.plain_text;

import content.pieces : Content, ContentPiece;
import extraction.contracts : ExtractionProvenanceV1, OwnedTextPiecesV1,
    TextDocumentV1;
import extraction.port : ConfiguredExtractorV1, ExtractionInputV1,
    ExtractorConfigurationV1, ExtractorOptionsV1;
import std.exception : enforce;

enum string corePlainTextImplementationV1 = "core-plain-text";
enum string corePlainTextVersionV1 = "core-plain-text/v1";
enum string maxOutputBytesOptionV1 = "max-output-bytes";
enum size_t maxCorePlainTextOutputBytesV1 = 256UL * 1024 * 1024;
enum size_t corePlainTextScratchBytesV1 = 8192;

private final class PlainTextConfigurationV1 : ExtractorConfigurationV1 {
    size_t maxOutputBytes;
    this(size_t maxOutputBytes) immutable {
        this.maxOutputBytes = maxOutputBytes;
    }
}

ConfiguredExtractorV1 configureCorePlainTextV1(
        const ref ExtractorOptionsV1 options) {
    auto selected = maxOutputBytesOptionV1 in options;
    enforce(selected !is null && options.length == 1,
        "core plain text requires max-output-bytes only");
    auto value = selected.asInteger;
    enforce(value > 0 && value <= maxCorePlainTextOutputBytesV1,
        "max-output-bytes must be in 1..268435456");
    return ConfiguredExtractorV1(&extractCorePlainTextV1,
        new immutable PlainTextConfigurationV1(cast(size_t)value));
}

private TextDocumentV1 extractCorePlainTextV1(ExtractionInputV1 input,
        immutable(ExtractorConfigurationV1) raw) pure {
    auto configuration = cast(immutable(PlainTextConfigurationV1)) raw;
    enforce(configuration !is null, "invalid core plain-text configuration");
    OwnedTextPiecesV1 pieces;
    size_t outputBytes;
    input.source.stream((const(ubyte)[] chunk) {
        enforce(chunk.length <= configuration.maxOutputBytes - outputBytes,
            "plain-text output exceeds max-output-bytes");
        // ContentPiece.own is the sole payload retention. The TextDocumentV1
        // constructor snapshots only descriptors and validates UTF-8 by stream.
        pieces.append(chunk);
        outputBytes += chunk.length;
    }, corePlainTextScratchBytesV1);
    return TextDocumentV1.extractedOwnedPieces(input.document, pieces,
        input.detection,
        corePlainTextImplementationV1, corePlainTextVersionV1, null,
        ExtractionProvenanceV1(input.detection.outcome,
            input.routeName, input.source.size));
}

unittest {
    import domain.document : Document, DocumentViewOwner, OutputName, SourceLocator;
    import extraction.contracts : DetectionOutcomeV1, DetectionResultV1,
        EvidenceKindV1, MediaEvidenceV1;
    import extraction.port : ExtractorOptionV1, SourceContentV1;
    import std.exception : assertThrown;

    auto owner = new DocumentViewOwner(cast(ubyte[])"hello".dup);
    scope(exit) owner.close();
    auto source = new Content([
        ContentPiece.borrow(owner.view(0, 2)),
        ContentPiece.borrow(owner.view(2, 3))
    ]);
    auto detection = DetectionResultV1.detected(DetectionOutcomeV1.plainText,
        [MediaEvidenceV1(EvidenceKindV1.textualContent,
            DetectionOutcomeV1.plainText, "valid-utf8-text-prefix")],
        "test:v1", null, 5, 8, 5);
    auto document = Document(SourceLocator("test", "plain", "1"),
        OutputName("one.txt"));
    ExtractorOptionsV1 options;
    options[maxOutputBytesOptionV1] = ExtractorOptionV1.integer(5);
    auto configured = configureCorePlainTextV1(options);
    auto text = configured(ExtractionInputV1(document,
        SourceContentV1.from(source), detection, "text", null));
    assert(text.id == document.id && text.outputName == document.outputName &&
        text.content.size == 5 && text.provenance.sourceBytes == 5);
    auto retained = text.content.toContent.pieces;
    assert(!retained.empty && retained.front.size == 5);

    options[maxOutputBytesOptionV1] = ExtractorOptionV1.integer(4);
    auto tooSmall = configureCorePlainTextV1(options);
    assertThrown(tooSmall(ExtractionInputV1(document,
        SourceContentV1.from(source), detection, "text", null)));
    owner.close();
    assert(text.content.size == 5);
    options[maxOutputBytesOptionV1] = ExtractorOptionV1.integer(0);
    assertThrown(configureCorePlainTextV1(options));
    options[maxOutputBytesOptionV1] = ExtractorOptionV1.integer(
        maxCorePlainTextOutputBytesV1 + 1UL);
    assertThrown(configureCorePlainTextV1(options));

    auto invalidOwner = new DocumentViewOwner([cast(ubyte) 0xc3, 0x28]);
    scope(exit) invalidOwner.close();
    auto invalidSource = new Content([ContentPiece.borrow(
        invalidOwner.view(0, 2))]);
    auto invalidDetection = DetectionResultV1.detected(
        DetectionOutcomeV1.plainText,
        [MediaEvidenceV1(EvidenceKindV1.textualContent,
            DetectionOutcomeV1.plainText, "bounded-prefix")],
        "test:v1", null, 1, 1, 2);
    options[maxOutputBytesOptionV1] = ExtractorOptionV1.integer(2);
    auto invalidExtractor = configureCorePlainTextV1(options);
    assertThrown(invalidExtractor(ExtractionInputV1(document,
        SourceContentV1.from(invalidSource), invalidDetection, "text", null)));

    ubyte[] largeBytes = new ubyte[corePlainTextScratchBytesV1 + 1];
    largeBytes[] = 'x';
    auto largeOwner = new DocumentViewOwner(largeBytes);
    auto largeSource = new Content([ContentPiece.borrow(
        largeOwner.view(0, largeBytes.length))]);
    auto largeDetection = DetectionResultV1.detected(
        DetectionOutcomeV1.plainText,
        [MediaEvidenceV1(EvidenceKindV1.textualContent,
            DetectionOutcomeV1.plainText, "valid-utf8-text-prefix")],
        "test:v1", null, largeBytes.length, largeBytes.length,
        largeBytes.length);
    options[maxOutputBytesOptionV1] = ExtractorOptionV1.integer(largeBytes.length);
    auto largeText = configureCorePlainTextV1(options)(ExtractionInputV1(document,
        SourceContentV1.from(largeSource), largeDetection, "text", null));
    auto largePieces = largeText.content.toContent.pieces;
    assert(largePieces.front.size == corePlainTextScratchBytesV1);
    largePieces.popFront;
    assert(largePieces.front.size == 1);
    largePieces.popFront;
    assert(largePieces.empty);
    largeOwner.close();
    assert(largeText.content.size == largeBytes.length);
}
