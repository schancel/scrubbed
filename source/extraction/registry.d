/// The explicit finite registry shipped by the core executable.
module extraction.registry;

import extraction.container : ZipInspectionLimitsV1;
import extraction.contracts : DetectionOutcomeV1;
import extraction.ooxml_route : configureOoxmlWordV1,
    ooxmlWordImplementationV1, ooxmlWordVersionV1;
import extraction.plain_text : configureCorePlainTextV1,
    corePlainTextImplementationV1, corePlainTextScratchBytesV1,
    corePlainTextVersionV1, maxCorePlainTextOutputBytesV1,
    maxOutputBytesOptionV1;
import extraction.port : ExtractorOptionDeclarationV1, ExtractorOptionTypeV1,
    ExtractorRegistrationV1, ExtractorRegistryV1, ExtractorResourcesV1;

/// A generous but bounded resource estimate for the ooxml-word route:
/// `word/document.xml`'s decompressed bytes are already bounded by ZIP
/// admission's own `maxExpandedBytes` budget (see `extraction.container`);
/// the walked document tree and rendered text stay roughly proportional to
/// that, so this mirrors `extraction.container`'s own default expanded-byte
/// ceiling rather than inventing an unrelated constant.
private enum size_t ooxmlWordResourceBytesV1 =
    ZipInspectionLimitsV1.defaultExpandedBytes * 2;

ExtractorRegistryV1 coreExtractorRegistryV1() {
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
}
