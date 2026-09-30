/// The explicit finite registry shipped by the core executable.
module extraction.registry;

import extraction.container : ZipInspectionLimitsV1;
import extraction.contracts : DetectionOutcomeV1;
import extraction.ooxml_route : configureOoxmlWordV1,
    ooxmlWordImplementationV1, ooxmlWordVersionV1;
import extraction.pdf_pdfium_route : configurePdfPdfiumV1,
    installPdfBytesExtractV1, pdfPdfiumImplementationV1,
    pdfPdfiumResourceBytesV1, pdfPdfiumVersionV1, pdfiumLibraryOptionV1;
import extraction.plain_text : configureCorePlainTextV1,
    corePlainTextImplementationV1, corePlainTextScratchBytesV1,
    corePlainTextVersionV1, maxCorePlainTextOutputBytesV1,
    maxOutputBytesOptionV1;
import extraction.port : ExtractorOptionDeclarationV1, ExtractorOptionTypeV1,
    ExtractorRegistrationV1, ExtractorRegistryV1, ExtractorResourcesV1,
    PdfBytesExtractV1;

/// A generous but bounded resource estimate for the ooxml-word route:
/// `word/document.xml`'s decompressed bytes are already bounded by ZIP
/// admission's own `maxExpandedBytes` budget (see `extraction.container`);
/// the walked document tree and rendered text stay roughly proportional to
/// that, so this mirrors `extraction.container`'s own default expanded-byte
/// ceiling rather than inventing an unrelated constant.
private enum size_t ooxmlWordResourceBytesV1 =
    ZipInspectionLimitsV1.defaultExpandedBytes * 2;

/// `pdfExtract` is issue #156's PDF-wiring injection point (see
/// `extraction.pdf_pdfium_route`'s own module doc, "The injection" section,
/// for the full real reasoning): the real, `effects.pdfium_ffi`-backed
/// capability `cli.d` constructs from the operator-supplied
/// `--route-option pdfium-library=...` path, or `null` (the default) when
/// the caller has none to inject -- e.g. every existing caller/test that
/// predates this parameter, which keeps working unchanged (the `pdf-pdfium`
/// route is still registered either way, so a job that actually routes to
/// it gets a clear "no PDFium library installed" failure rather than an
/// "unknown extractor" one; see `extraction.pdf_pdfium_route
/// .configurePdfPdfiumV1`). Setting the module-global injection slot is a
/// real, disclosed side effect of calling this function with a non-null
/// `pdfExtract` -- see `extraction.pdf_pdfium_route`'s own doc for why a
/// closure is not available here and why this is safe.
ExtractorRegistryV1 coreExtractorRegistryV1(PdfBytesExtractV1 pdfExtract = null) {
    installPdfBytesExtractV1(pdfExtract);
    ExtractorRegistryV1 registry;
    registry.add(ExtractorRegistrationV1(corePlainTextImplementationV1,
        corePlainTextVersionV1, [DetectionOutcomeV1.plainText],
        ExtractorResourcesV1(1, maxCorePlainTextOutputBytesV1 +
            corePlainTextScratchBytesV1),
        [ExtractorOptionDeclarationV1(maxOutputBytesOptionV1,
            ExtractorOptionTypeV1.integer, true)],
        &configureCorePlainTextV1));
    registry.add(ExtractorRegistrationV1(ooxmlWordImplementationV1,
        ooxmlWordVersionV1, [DetectionOutcomeV1.ooxmlWord],
        ExtractorResourcesV1(1, ooxmlWordResourceBytesV1),
        null, &configureOoxmlWordV1));
    registry.add(ExtractorRegistrationV1(pdfPdfiumImplementationV1,
        pdfPdfiumVersionV1, [DetectionOutcomeV1.pdf],
        ExtractorResourcesV1(1, pdfPdfiumResourceBytesV1),
        [ExtractorOptionDeclarationV1(pdfiumLibraryOptionV1,
            ExtractorOptionTypeV1.text, true)],
        &configurePdfPdfiumV1));
    return registry;
}

unittest {
    auto first = coreExtractorRegistryV1();
    auto second = coreExtractorRegistryV1();
    assert(first.find(corePlainTextImplementationV1) !is null);
    assert(second.find(corePlainTextImplementationV1) !is null);
    assert(first.find(ooxmlWordImplementationV1) !is null);
    assert(second.find(ooxmlWordImplementationV1) !is null);
    assert(first.find(ooxmlWordImplementationV1).accepts(DetectionOutcomeV1.ooxmlWord));
    assert(!first.find(ooxmlWordImplementationV1).accepts(DetectionOutcomeV1.genericZip));
    assert(first.find(pdfPdfiumImplementationV1) !is null);
    assert(first.find(pdfPdfiumImplementationV1).accepts(DetectionOutcomeV1.pdf));
    assert(!first.find(pdfPdfiumImplementationV1).accepts(DetectionOutcomeV1.genericZip));
}
