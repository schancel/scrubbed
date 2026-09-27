/// Opt-in, non-terminal v3 stage (`quality-ratios-annotate`, issue #347's
/// accepted contract): measures Gopher/C4-style deterministic heuristic
/// quality ratios over whatever raw content bytes this stage receives at its
/// position in the compiled chain and writes one compact `quality-ratios`
/// extension field into `StageDocument.metadata` (#285's existing API), to
/// be published later by the existing, unmodified
/// `document-metadata-publish` terminal stage -- no new plumbing. `content`
/// passes through completely unmodified. This is the direct sibling of
/// `effects.compressibility_annotate_stage` (#168), mirrored exactly:
/// same opt-in/non-terminal/single-extension-field shape, same
/// `max-input-bytes` inline-option idiom, same
/// "feature-vector-not-opaque-score" philosophy.
///
/// **Six independent feature groups, deliberately never combined into one
/// score** (all computed by the pure, independently-unit-tested
/// `domain.quality_ratios.computeQualityRatios` -- see that module's own doc
/// comment for the full sourcing/verification discipline and every
/// deliberate, disclosed deviation from the verified reference):
///
/// 1. **Word count** -- whitespace-delimited.
/// 2. **Mean word length** -- mean codepoint length across those words.
/// 3. **Symbol-to-word ratios** -- hash (`#`) count and non-overlapping
///    ellipsis (`"..."`) count, each independently over word count. Two
///    separate named sub-fields, never merged.
/// 4. **Alphabetic-word fraction** -- fraction of words containing at least
///    one alphabetic codepoint.
/// 5. **Stop-word presence** -- count (0-8) of `domain.quality_ratios
///    .stopWordListV1`'s 8 fixed words present at least once, verified
///    against HuggingFace `datatrove`'s `GopherQualityFilter.STOP_WORDS`
///    (Rae et al. 2021, "Scaling Language Models... Gopher," DeepMind,
///    Appendix A.1) -- see the domain module doc for the exact citation.
/// 6. **Multi-scale repetition fractions** -- duplicate-line/-paragraph
///    fraction and character fraction, top-n-gram character fraction
///    (n=2,3,4), duplicate-n-gram character fraction (n=5..10), verified
///    against `datatrove`'s `GopherRepetitionFilter` and its
///    `find_duplicates`/`find_top_duplicate`/`find_all_duplicate`/
///    `get_n_grams` helpers -- see the domain module doc for the exact
///    citation and every formula's provenance.
///
/// **No threshold, pass/fail, or accept/reject decision logic anywhere in
/// this stage.** Every value above is a raw, named, versioned numeric field
/// in the `quality-ratios` extension field -- exactly mirroring
/// `compressibility`'s `compressedToRawRatio`/`tokenEntropy` fields, which
/// are also never combined into one score or gated. A future, separate,
/// owner-approved policy slice decides what to do with these numbers, if
/// anything.
///
/// **Never quarantines solely because a feature abstains.** Every
/// abstention in `domain.quality_ratios.QualityRatiosResult` (invalid UTF-8,
/// zero words, empty content, too few words for a given n-gram size) is a
/// typed status or a `Nullable` `null`, never a quarantine. The only
/// quarantine this stage ever raises is `rawLimit`, the same
/// `max-input-bytes` resource bound every other annotate-shaped stage in
/// this codebase has (see `effects.compressibility_annotate_stage`).
///
/// **Every feature requires valid UTF-8**, unlike `compressibility-
/// annotate`'s deliberate entropy/ratio asymmetry: every feature here
/// operates on decoded text (words, lines, paragraphs), so invalid UTF-8
/// abstains every field in this stage's extension field at once
/// (`domain.quality_ratios.Utf8Status.invalidUtf8`), while `rawBytes` is
/// still recorded truthfully.
module effects.quality_ratios_annotate_stage;

import crypto.sha256 : sha256Of;
import domain.quality_ratios : QualityRatiosResult, Utf8Status, WordStatus,
    computeQualityRatios, qualityRatiosSchemaV1;
import stages.contract : PassMode, ResourceDeclaration, StageDecision,
    StageDeclaration, StageDocument;
import stages.registry : ConfiguredStageTransform, FilterPlacement,
    OptionDeclaration, OptionType, SideOutputCapability, StageCardinality,
    StageConfiguration, StageOptions, StageRegistration, registerStage;
import std.exception : enforce;
import std.format : format;

enum qualityRatiosAnnotateStageKeyV1 = "quality-ratios-annotate";
enum qualityRatiosExtensionKeyV1 = "quality-ratios";

/// `max-input-bytes` default and sanity ceiling, mirroring
/// `effects.compressibility_annotate_stage`'s own default/ceiling pair
/// exactly (same 1 MiB default, same 8 MiB configurable ceiling).
enum size_t qualityRatiosDefaultMaxInputBytes = 1024 * 1024;
enum size_t qualityRatiosMaxConfigurableInputBytes = 8 * 1024 * 1024;

private string hexEncode(const(ubyte)[] bytes) pure {
    enum hex = "0123456789abcdef";
    char[] result;
    result.reserve(bytes.length * 2);
    foreach (b; bytes) {
        result ~= hex[b >> 4];
        result ~= hex[b & 0xf];
    }
    return result.idup;
}

/// `null` if `value.isNull`, else `%.4f` -- 4 decimal digits is ample
/// precision for these bounded ratios/fractions and keeps the encoded
/// field's worst-case length predictable (see this module's own boundary
/// unittest below, which pins the worst-case length under
/// `domain.document_metadata.maxExtensionValueBytes`).
private string numberOrNull(T)(T value) pure {
    import std.typecons : Nullable;

    static if (is(T : Nullable!double)) {
        return value.isNull ? "null" : format!"%.4f"(value.get);
    } else {
        return format!"%.4f"(value);
    }
}

/// Encodes `r` as this stage's `scrubbed-quality-ratios-v1` extension-field
/// bytes. A `Nullable!double` field's wire value is JSON `null` exactly when
/// that `Nullable` `isNull` -- the same "typed abstention, not a sentinel"
/// rule `compressibility_annotate_stage.encodeCompressibilityV1` already
/// established. Field names are deliberately short (see the module doc's
/// mapping in each `QualityRatiosResult` field's own doc comment for the
/// full name) to keep the worst-case encoded length safely under the
/// 512-byte extension-field cap despite this stage's much larger field
/// count than `compressibility`'s.
immutable(ubyte)[] encodeQualityRatiosV1(const QualityRatiosResult r,
        ubyte[32] contentRevisionSha256) pure {
    string wire = format!(
        `{"schema":"%s","u8":"%s","rb":%s,"rc":%s,` ~
        `"ws":"%s","wc":%s,"mwl":%s,"hashR":%s,"ellR":%s,"alphaF":%s,"stopN":%s,` ~
        `"dupLnF":%s,"dupLnCF":%s,"dupParaF":%s,"dupParaCF":%s,` ~
        `"top2":%s,"top3":%s,"top4":%s,` ~
        `"dup5":%s,"dup6":%s,"dup7":%s,"dup8":%s,"dup9":%s,"dup10":%s,` ~
        `"rev":"%s"}`)(
        qualityRatiosSchemaV1, r.utf8Status, r.rawBytes, r.rawChars,
        r.wordStatus, r.wordCount, numberOrNull(r.meanWordLength),
        numberOrNull(r.hashToWordRatio), numberOrNull(r.ellipsisToWordRatio),
        numberOrNull(r.alphabeticWordFraction), r.stopWordPresentCount,
        numberOrNull(r.duplicateLineFraction), numberOrNull(r.duplicateLineCharFraction),
        numberOrNull(r.duplicateParagraphFraction), numberOrNull(r.duplicateParagraphCharFraction),
        numberOrNull(r.topNGramCharFraction[0]), numberOrNull(r.topNGramCharFraction[1]),
        numberOrNull(r.topNGramCharFraction[2]),
        numberOrNull(r.duplicateNGramCharFraction[0]), numberOrNull(r.duplicateNGramCharFraction[1]),
        numberOrNull(r.duplicateNGramCharFraction[2]), numberOrNull(r.duplicateNGramCharFraction[3]),
        numberOrNull(r.duplicateNGramCharFraction[4]), numberOrNull(r.duplicateNGramCharFraction[5]),
        hexEncode(contentRevisionSha256[]));
    return cast(immutable(ubyte)[]) wire;
}

/// Decodes this module's own `encodeQualityRatiosV1` wire, for this
/// module's unittests only (the field is opaque to every other module,
/// including `document-metadata-publish`, which never interprets it).
private struct DecodedQualityRatios {
    QualityRatiosResult r;
    ubyte[32] contentRevisionSha256;
}

private DecodedQualityRatios decodeQualityRatiosV1(immutable(ubyte)[] wire) {
    import std.conv : to;
    import std.json : JSONType, JSONValue, parseJSON;
    import std.typecons : Nullable, nullable;

    auto root = parseJSON(cast(string) wire);
    enforce(root["schema"].str == qualityRatiosSchemaV1, "unexpected quality-ratios schema");
    DecodedQualityRatios decoded;

    static Nullable!double numOrNull(JSONValue v) {
        if (v.type == JSONType.null_) return Nullable!double.init;
        return nullable(v.floating);
    }

    decoded.r.utf8Status = to!Utf8Status(root["u8"].str);
    decoded.r.rawBytes = cast(size_t) root["rb"].integer;
    decoded.r.rawChars = cast(size_t) root["rc"].integer;
    decoded.r.wordStatus = to!WordStatus(root["ws"].str);
    decoded.r.wordCount = cast(size_t) root["wc"].integer;
    decoded.r.meanWordLength = numOrNull(root["mwl"]);
    decoded.r.hashToWordRatio = numOrNull(root["hashR"]);
    decoded.r.ellipsisToWordRatio = numOrNull(root["ellR"]);
    decoded.r.alphabeticWordFraction = numOrNull(root["alphaF"]);
    decoded.r.stopWordPresentCount = cast(size_t) root["stopN"].integer;
    decoded.r.duplicateLineFraction = root["dupLnF"].floating;
    decoded.r.duplicateLineCharFraction = numOrNull(root["dupLnCF"]);
    decoded.r.duplicateParagraphFraction = root["dupParaF"].floating;
    decoded.r.duplicateParagraphCharFraction = numOrNull(root["dupParaCF"]);
    decoded.r.topNGramCharFraction[0] = numOrNull(root["top2"]);
    decoded.r.topNGramCharFraction[1] = numOrNull(root["top3"]);
    decoded.r.topNGramCharFraction[2] = numOrNull(root["top4"]);
    decoded.r.duplicateNGramCharFraction[0] = numOrNull(root["dup5"]);
    decoded.r.duplicateNGramCharFraction[1] = numOrNull(root["dup6"]);
    decoded.r.duplicateNGramCharFraction[2] = numOrNull(root["dup7"]);
    decoded.r.duplicateNGramCharFraction[3] = numOrNull(root["dup8"]);
    decoded.r.duplicateNGramCharFraction[4] = numOrNull(root["dup9"]);
    decoded.r.duplicateNGramCharFraction[5] = numOrNull(root["dup10"]);

    auto revisionHex = root["rev"].str;
    enforce(revisionHex.length == 64, "malformed content-revision digest");
    foreach (i; 0 .. 32) {
        decoded.contentRevisionSha256[i] = cast(ubyte)(
            (hexNibble(revisionHex[2 * i]) << 4) | hexNibble(revisionHex[2 * i + 1]));
    }
    return decoded;
}

private ubyte hexNibble(char c) pure {
    if (c >= '0' && c <= '9') return cast(ubyte)(c - '0');
    if (c >= 'a' && c <= 'f') return cast(ubyte)(c - 'a' + 10);
    throw new Exception("quality-ratios: malformed hex digest");
}

/// Bounds-checks a configured `max-input-bytes` value, mirroring
/// `effects.compressibility_annotate_stage
/// .checkedCompressibilityMaxInputBytes`'s exact shape.
size_t checkedQualityRatiosMaxInputBytes(ulong limit) pure {
    enforce(limit > 0 && limit <= qualityRatiosMaxConfigurableInputBytes,
        "quality-ratios max-input-bytes must be between 1 and 8388608");
    return cast(size_t) limit;
}

private class QualityRatiosAnnotateConfiguration : StageConfiguration {
    size_t maxInputBytes;
    this(size_t maxInputBytes) immutable { this.maxInputBytes = maxInputBytes; }
}

private StageDecision applyQualityRatiosAnnotate(StageDocument input,
        immutable(StageConfiguration) configuration) pure {
    auto configured = cast(immutable(QualityRatiosAnnotateConfiguration)) configuration;
    enforce(configured !is null, "invalid quality-ratios-annotate configuration");
    if (input.content.size > configured.maxInputBytes)
        return StageDecision.quarantine("rawLimit");
    auto raw = input.content.copy();

    try {
        auto contentRevision = sha256Of(raw);
        auto result = computeQualityRatios(raw);
        auto encoded = encodeQualityRatiosV1(result, contentRevision);
        input.metadata = input.metadata.withExtensionField(qualityRatiosExtensionKeyV1,
            encoded, qualityRatiosAnnotateStageKeyV1);
    } catch (Exception) {
        // A genuine internal-invariant failure (e.g. the extension field
        // capacity/duplicate-key cap already exhausted by a prior stage) --
        // never raised merely because a feature itself could not be
        // computed; every feature above always degrades to a typed
        // abstention instead of throwing. Mirrors
        // `compressibility_annotate_stage`'s own `annotationBuildFailure`
        // catch-all for the same reason.
        return StageDecision.quarantine("annotationBuildFailure");
    }
    // `content` is returned completely unmodified.
    return StageDecision.map(input);
}

private ConfiguredStageTransform factory(const ref StageOptions options) {
    auto chosen = "max-input-bytes" in options;
    auto maxInputBytes = chosen is null ? qualityRatiosDefaultMaxInputBytes :
        checkedQualityRatiosMaxInputBytes(chosen.asInteger());
    return ConfiguredStageTransform(&applyQualityRatiosAnnotate,
        new immutable QualityRatiosAnnotateConfiguration(maxInputBytes));
}

static this() {
    registerStage(StageRegistration(StageDeclaration(qualityRatiosAnnotateStageKeyV1,
        PassMode.singlePass, ResourceDeclaration(1, 32 * 1024 * 1024)),
        [OptionDeclaration("max-input-bytes", OptionType.integer)], null, null, &factory,
        FilterPlacement.none, StageCardinality.oneToOne, SideOutputCapability.none));
}

// ---------------------------------------------------------------------------
// Unit tests. Every fixture asserts real computed numbers, not merely
// type-correctness, per the accepted #347 contract's acceptance criteria.
// ---------------------------------------------------------------------------

version (unittest) {
    import composition.compiler : compileJob;
    import composition.executor : runCompiledStage;
    import composition.job_executor : runCompiledJob;
    import content.pieces : Content, ContentPiece;
    import domain.document : Document, OutputName, SourceLocator;
    import domain.document_metadata : decodeDocumentMetadataV1;
    import effects.document_metadata_publish_stage : documentMetadataPublishKeyV1;
    import job.json : parseJobJson;
    import stages.contract : EventKind, StageEvent;
    import std.conv : to;

    private Document fixtureDocument() {
        return Document(SourceLocator("local:v1", "/tmp", "a.bin"), OutputName("a.bin.out"));
    }

    private StageEvent runQualityRatiosAnnotate(const(ubyte)[] bytes,
            string jobOptionsJson = "{}") {
        auto spec = parseJobJson(`{"version":3,"stages":[{"id":"annotate",` ~
            `"implementation":"` ~ qualityRatiosAnnotateStageKeyV1 ~ `",` ~
            `"options":` ~ jobOptionsJson ~ `,"filters":[]}]}`);
        auto plan = compileJob(spec);
        auto input = StageDocument(fixtureDocument(), new Content([ContentPiece.own(bytes)]));
        auto result = runCompiledStage([input], plan.stages[0]);
        assert(result.events.length == 1);
        return result.events[0];
    }

    private DecodedQualityRatios decodedFrom(StageEvent event) {
        assert(event.kind == EventKind.emitted);
        auto fields = event.payload.metadata.extensionFields;
        assert(fields.length == 1);
        assert(fields[0].key == qualityRatiosExtensionKeyV1);
        assert(fields[0].sourceStage == qualityRatiosAnnotateStageKeyV1);
        return decodeQualityRatiosV1(fields[0].value);
    }
}

// Boundary: the worst-case encoded field (longest status names, maximal
// digit counts at the 8 MiB configurable ceiling) stays safely under
// `domain.document_metadata.maxExtensionValueBytes` (512), despite this
// stage's much larger field count than `compressibility`'s two metrics.
unittest {
    import domain.document_metadata : maxExtensionValueBytes;
    import std.typecons : nullable;

    QualityRatiosResult worstCase;
    worstCase.utf8Status = Utf8Status.invalidUtf8; // "invalidUtf8" is the longer status name
    worstCase.rawBytes = qualityRatiosMaxConfigurableInputBytes;
    worstCase.rawChars = qualityRatiosMaxConfigurableInputBytes;
    worstCase.wordStatus = WordStatus.computed; // "computed" is the longer status name
    worstCase.wordCount = qualityRatiosMaxConfigurableInputBytes;
    worstCase.meanWordLength = nullable(cast(double) qualityRatiosMaxConfigurableInputBytes);
    worstCase.hashToWordRatio = nullable(cast(double) qualityRatiosMaxConfigurableInputBytes);
    worstCase.ellipsisToWordRatio = nullable(cast(double) qualityRatiosMaxConfigurableInputBytes);
    worstCase.alphabeticWordFraction = nullable(0.9999);
    worstCase.stopWordPresentCount = 8;
    worstCase.duplicateLineFraction = 0.9999;
    worstCase.duplicateLineCharFraction = nullable(0.9999);
    worstCase.duplicateParagraphFraction = 0.9999;
    worstCase.duplicateParagraphCharFraction = nullable(0.9999);
    foreach (ref v; worstCase.topNGramCharFraction) v = nullable(1.9999);
    foreach (ref v; worstCase.duplicateNGramCharFraction) v = nullable(1.9999);

    ubyte[32] contentRevision;
    contentRevision[] = 0xab;
    auto encoded = encodeQualityRatiosV1(worstCase, contentRevision);
    assert(encoded.length <= maxExtensionValueBytes,
        "worst-case quality-ratios field exceeds the 512-byte extension cap: " ~
        encoded.length.to!string);
}

// Determinism: two independent runs over the same input produce
// byte-identical extension-field bytes.
unittest {
    string text = "Determinism must hold across repeated runs on the same input.";
    auto first = runQualityRatiosAnnotate(cast(const(ubyte)[]) text);
    auto second = runQualityRatiosAnnotate(cast(const(ubyte)[]) text);
    assert(first.payload.metadata.extensionFields[0].value ==
        second.payload.metadata.extensionFields[0].value);
}

// Content-revision digest: the recorded sha256 is exactly the sha256 of the
// raw bytes this stage actually received.
unittest {
    string text = "content revision binding fixture";
    auto event = runQualityRatiosAnnotate(cast(const(ubyte)[]) text);
    auto decoded = decodedFrom(event);
    assert(decoded.contentRevisionSha256 == sha256Of(cast(const(ubyte)[]) text));
}

// Resource-safety quarantine: exceeding `max-input-bytes` itself (a genuine
// input-size gate, distinct from any feature-level abstention) does
// quarantine with reason `rawLimit`, the same idiom every other stage in
// this codebase uses -- this is not a "feature could not be computed" case.
unittest {
    auto oversized = new ubyte[qualityRatiosDefaultMaxInputBytes + 1];
    auto event = runQualityRatiosAnnotate(oversized);
    assert(event.kind == EventKind.quarantined);
    assert(event.reason == "rawLimit");
}

// Invalid UTF-8: every feature abstains at once, and the stage still emits
// (never quarantines) -- `rawBytes` is still recorded truthfully.
unittest {
    ubyte[] invalid = cast(ubyte[]) "well formed ascii text then, well above ".dup;
    invalid ~= [cast(ubyte) 0xC0, cast(ubyte) 0x80]; // overlong/invalid UTF-8
    invalid ~= cast(ubyte[]) " and more ascii after that.".dup;
    auto event = runQualityRatiosAnnotate(invalid);
    assert(event.kind == EventKind.emitted);
    auto decoded = decodedFrom(event);
    assert(decoded.r.utf8Status == Utf8Status.invalidUtf8);
    assert(decoded.r.rawBytes == invalid.length);
}

// Reachability: `[quality-ratios-annotate, document-metadata-publish]`
// compiles and runs as one job via `compileJob`/`runCompiledJob`, and the
// terminal `document-metadata-v1` side output's decoded metadata carries
// exactly the `quality-ratios` field this stage wrote.
unittest {
    auto spec = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"annotate","implementation":"` ~ qualityRatiosAnnotateStageKeyV1 ~
        `","options":{},"filters":[]},` ~
        `{"id":"publish","implementation":"document-metadata-publish",` ~
        `"options":{},"filters":[]}]}`);
    auto plan = compileJob(spec);
    string text = "reachability fixture text for the quality ratios annotate chain";
    auto document = fixtureDocument();
    auto input = StageDocument(document, new Content([ContentPiece.own(cast(const(ubyte)[]) text)]));
    auto events = runCompiledJob(input, plan);
    assert(events.length == 1 && events[0].kind == EventKind.emitted);
    assert(events[0].sideOutputs.length == 1);
    auto sideOutput = events[0].sideOutputs[0];
    assert(sideOutput.key == documentMetadataPublishKeyV1);
    auto decodedMetadata = decodeDocumentMetadataV1(document.id, cast(string) sideOutput.bytes());
    assert(decodedMetadata.extensionFieldCount == 1);
    auto field = decodedMetadata.extensionFields[0];
    assert(field.key == qualityRatiosExtensionKeyV1);
    assert(field.sourceStage == qualityRatiosAnnotateStageKeyV1);
    auto decoded = decodeQualityRatiosV1(field.value);
    assert(decoded.r.utf8Status == Utf8Status.computed);
    assert(decoded.r.rawBytes == text.length);
    assert(decoded.contentRevisionSha256 == sha256Of(cast(const(ubyte)[]) text));
}

// ---------------------------------------------------------------------------
// Required #347 proof: three real, hand-constructed fixtures whose computed
// feature values are correctly, visibly differentiated -- demonstrating
// this stage catches the real coverage gap the ticket names (fluent,
// non-repetitive-looking, low-value text that reads as "statistically
// normal" to `compressibility-annotate`'s entropy/compression signal alone).
// ---------------------------------------------------------------------------

// Fixture A: normal, well-formed prose. Baseline for comparison below.
unittest {
    string normalProse =
        "The history of the small coastal town began with a handful of " ~
        "fishermen who settled along the sheltered bay. Over the decades " ~
        "that followed, the community grew slowly but steadily, and the " ~
        "harbor became a modest center of trade with neighboring villages. " ~
        "Visitors today can still walk along the old stone quay and " ~
        "imagine the quiet rhythm of that earlier life, when the tide " ~
        "itself set the pace of every working day.";
    auto event = runQualityRatiosAnnotate(cast(const(ubyte)[]) normalProse);
    auto decoded = decodedFrom(event);
    auto r = decoded.r;
    assert(r.utf8Status == Utf8Status.computed);
    assert(r.wordStatus == WordStatus.computed);
    // Real prose contains several of the 8 Gopher stop words ("the", "of",
    // "that", "with", "and" all appear) -- a high stop-word presence count.
    assert(r.stopWordPresentCount >= 5,
        "normal-prose stop word presence unexpectedly low: " ~ r.stopWordPresentCount.to!string);
    // No hash symbols, no ellipses, in ordinary prose.
    assert(r.hashToWordRatio.get == 0.0);
    assert(r.ellipsisToWordRatio.get == 0.0);
    // Ordinary prose words are almost entirely alphabetic.
    assert(r.alphabeticWordFraction.get > 0.95,
        "normal-prose alphabetic fraction unexpectedly low: " ~ r.alphabeticWordFraction.get.to!string);
    // No repeated lines/paragraphs/n-grams at all in flowing prose with no
    // line breaks: single line, single paragraph, both fractions exactly 0.
    assert(r.duplicateLineFraction == 0.0);
    assert(r.duplicateParagraphFraction == 0.0);

    // Print the real computed numbers for this fixture (visible in `dub
    // test` output) so the three-fixture differentiation proof is directly
    // inspectable, not just asserted.
    import std.stdio : writefln;
    writefln("[quality-ratios fixture A: normal prose] wordCount=%s meanWordLength=%.4f " ~
        "hashToWordRatio=%.4f ellipsisToWordRatio=%.4f alphabeticWordFraction=%.4f " ~
        "stopWordPresentCount=%s dupLineFraction=%.4f dupParaFraction=%.4f",
        r.wordCount, r.meanWordLength.get, r.hashToWordRatio.get, r.ellipsisToWordRatio.get,
        r.alphabeticWordFraction.get, r.stopWordPresentCount, r.duplicateLineFraction,
        r.duplicateParagraphFraction);
}

// Fixture B: keyword-stuffed / SEO-spam-like text. Fluent-looking enough
// that neither order-0 token entropy nor zstd compression ratio
// (`compressibility-annotate`) would necessarily flag it as degenerate --
// each keyword phrase is distinct, not verbatim-repeated -- but it reads as
// obviously low-value to a human, and to these new features: low stop-word
// presence (spam keyword strings omit function words almost entirely) and
// elevated hash/digit-adjacent symbol density.
unittest {
    string spam =
        "#BestPriceOnline #CheapDeals2024 #BuyNowSale #DiscountCode50 " ~
        "#TopRatedProduct #FreeShipping247 #LimitedTimeOffer #ClickHereNow " ~
        "#BestPriceOnline #CheapDeals2024 #BuyNowSale #DiscountCode50 " ~
        "#TopRatedProduct2024 #FreeShipping365 #LimitedOffer99 #ClickNow247";
    auto event = runQualityRatiosAnnotate(cast(const(ubyte)[]) spam);
    auto decoded = decodedFrom(event);
    auto r = decoded.r;
    assert(r.utf8Status == Utf8Status.computed);
    assert(r.wordStatus == WordStatus.computed);
    // None of the 16 hashtag-style words is a lowercase Gopher stop word.
    assert(r.stopWordPresentCount == 0,
        "spam-fixture stop word presence unexpectedly nonzero: " ~ r.stopWordPresentCount.to!string);
    // Every one of the 16 words starts with '#': hashToWordRatio == 1.0,
    // dramatically higher than normal prose's 0.0 above.
    assert(r.hashToWordRatio.get == 1.0,
        "spam-fixture hash ratio: " ~ r.hashToWordRatio.get.to!string);

    import std.stdio : writefln;
    writefln("[quality-ratios fixture B: spam-like] wordCount=%s meanWordLength=%.4f " ~
        "hashToWordRatio=%.4f ellipsisToWordRatio=%.4f alphabeticWordFraction=%.4f " ~
        "stopWordPresentCount=%s dupLineFraction=%.4f dupParaFraction=%.4f",
        r.wordCount, r.meanWordLength.get, r.hashToWordRatio.get, r.ellipsisToWordRatio.get,
        r.alphabeticWordFraction.get, r.stopWordPresentCount, r.duplicateLineFraction,
        r.duplicateParagraphFraction);

    // The coverage-gap proof itself: stop-word presence sharply
    // differentiates the spam fixture from the normal-prose fixture above
    // (0 vs. >=5), and hash-to-word ratio sharply differentiates it too
    // (1.0 vs. 0.0) -- exactly the gap #347 names: fluent-looking,
    // non-verbatim-repeated text that entropy/compression alone would not
    // necessarily flag.
}

// Fixture C: highly repetitive text (verbatim-repeated lines and a
// verbatim-repeated multi-word phrase). High duplicate-line and
// duplicate-n-gram fractions vs. the normal-prose fixture's all-zero
// repetition fractions above.
unittest {
    string line = "This exact sentence is repeated verbatim many times over.";
    string repetitive;
    foreach (i; 0 .. 8) repetitive ~= line ~ "\n";
    auto event = runQualityRatiosAnnotate(cast(const(ubyte)[]) repetitive);
    auto decoded = decodedFrom(event);
    auto r = decoded.r;
    assert(r.utf8Status == Utf8Status.computed);
    // 8 lines total (the trailing "\n" makes 9 split results, the 9th
    // empty); the first "line" occurrence is not itself a duplicate, the
    // remaining 7 are -- a high duplicate-line fraction, dramatically
    // higher than the normal-prose fixture's exact 0.0 above.
    assert(r.duplicateLineFraction > 0.5,
        "repetitive-text duplicate line fraction unexpectedly low: " ~
        r.duplicateLineFraction.to!string);
    assert(!r.duplicateLineCharFraction.isNull);
    assert(r.duplicateLineCharFraction.get > 0.5,
        "repetitive-text duplicate line char fraction unexpectedly low: " ~
        r.duplicateLineCharFraction.get.to!string);
    // The whole 10-word sentence itself is a repeated 5..10-gram: the
    // duplicate-5-gram (and higher) character fractions must be high too.
    assert(!r.duplicateNGramCharFraction[0].isNull); // n=5
    assert(r.duplicateNGramCharFraction[0].get > 0.3,
        "repetitive-text duplicate-5-gram char fraction unexpectedly low: " ~
        r.duplicateNGramCharFraction[0].get.to!string);

    import std.stdio : writefln;
    writefln("[quality-ratios fixture C: highly repetitive] wordCount=%s " ~
        "dupLineFraction=%.4f dupLineCharFraction=%.4f dup5GramCharFraction=%.4f " ~
        "dup10GramCharFraction=%s",
        r.wordCount, r.duplicateLineFraction, r.duplicateLineCharFraction.get,
        r.duplicateNGramCharFraction[0].get,
        r.duplicateNGramCharFraction[5].isNull ? "null" : r.duplicateNGramCharFraction[5].get.to!string);

    // The coverage-gap proof: duplicate-line/-n-gram fractions sharply
    // differentiate this fixture from the normal-prose fixture above (>0.5
    // and >0.3 respectively, vs. exact 0.0) -- the multi-scale repetition
    // signal #347 names, complementing (not duplicating)
    // `compressibility-annotate`'s own zstd-ratio-based repetition signal.
}
