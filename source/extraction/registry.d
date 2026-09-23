/// The explicit finite registry shipped by the core executable.
module extraction.registry;

import extraction.contracts : DetectionOutcomeV1;
import extraction.plain_text : configureCorePlainTextV1,
    corePlainTextImplementationV1, corePlainTextScratchBytesV1,
    corePlainTextVersionV1, maxCorePlainTextOutputBytesV1,
    maxOutputBytesOptionV1;
import extraction.port : ExtractorOptionDeclarationV1, ExtractorOptionTypeV1,
    ExtractorRegistrationV1, ExtractorRegistryV1, ExtractorResourcesV1;

ExtractorRegistryV1 coreExtractorRegistryV1() {
    ExtractorRegistryV1 registry;
    registry.add(ExtractorRegistrationV1(corePlainTextImplementationV1,
        corePlainTextVersionV1, [DetectionOutcomeV1.plainText],
        ExtractorResourcesV1(1, maxCorePlainTextOutputBytesV1 +
            corePlainTextScratchBytesV1),
        [ExtractorOptionDeclarationV1(maxOutputBytesOptionV1,
            ExtractorOptionTypeV1.integer, true)],
        &configureCorePlainTextV1));
    return registry;
}

unittest {
    auto first = coreExtractorRegistryV1();
    auto second = coreExtractorRegistryV1();
    assert(first.find(corePlainTextImplementationV1) !is null);
    assert(second.find(corePlainTextImplementationV1) !is null);
}
