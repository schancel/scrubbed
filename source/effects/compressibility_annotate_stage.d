/// Opt-in, non-terminal v3 stage (`compressibility-annotate`, issue #168's
/// accepted contract): measures whatever raw content bytes this stage
/// receives at its position in the compiled chain and writes one compact
/// `compressibility` extension field into `StageDocument.metadata` (#285's
/// existing API), to be published later by the existing, unmodified
/// `document-metadata-publish` terminal stage -- no new plumbing. `content`
/// passes through completely unmodified.
///
/// **Two independent metrics, deliberately never combined into one score:**
///
/// 1. **Order-0 token-frequency entropy** (`domain.token_entropy
///    .tokenEntropy`) over this stage's own raw content bytes, reinterpreted
///    as text. This is a proxy correlated with lexical diversity, not
///    "complexity" in any formal sense, and it **requires valid UTF-8** --
///    tokenization cannot run over arbitrary bytes.
/// 2. **zstd level-19 compressed/raw byte ratio** (`compressedToRawRatio`,
///    deliberately not bare `ratio` -- this codebase's only prior "ratio"
///    precedent, `effects.warc_compressed.expansionRatioLimit`, points the
///    opposite direction, expanded/compressed; `compressedToRawRatio` is
///    unambiguous and self-describing: **smaller means more compressible**)
///    over the same raw bytes, taken as opaque bytes. Compression **does
///    not require UTF-8 validity** -- it runs over whatever bytes this stage
///    received, valid text or not.
///
/// This asymmetry -- one metric requires valid UTF-8, the other explicitly
/// does not -- is deliberate and is the reason invalid UTF-8 input still
/// produces a fully valid annotation: entropy abstains
/// (`EntropyStatus.invalidUtf8`) while the compression ratio still computes
/// normally over the same bytes.
///
/// **Never a Kolmogorov-complexity claim.** Real Kolmogorov complexity is
/// uncomputable; both metrics here are named, versioned, bounded proxies.
/// The extension field is named `compressibility`, never
/// `kolmogorov_complexity`, anywhere in this module.
///
/// **Never quarantines solely because compressibility could not be
/// computed.** Below the 64-byte floor or above the 1 MiB cap, the
/// `compressedToRawRatio` value itself abstains (`RatioStatus.belowFloor`/
/// `RatioStatus.aboveCap`) while `rawBytes`/`compressedBytes` are still
/// recorded truthfully -- compression still runs and its real byte counts
/// are still measured; only the normalized ratio is withheld. Likewise,
/// invalid UTF-8 never quarantines -- it only changes `EntropyStatus`. The
/// only quarantine this stage ever raises is `rawLimit`, the same
/// input-size safety gate every parsing stage in this codebase has (see
/// `max-input-bytes` below); that is a resource bound, not a
/// compressibility-computation failure.
///
/// **`max-input-bytes`:** the stage's one caller-tunable option (mirroring
/// `effects.topical_tags_extract_stage`'s inline `max-html-bytes` option:
/// declared, read, and bounds-checked directly in this module, no separate
/// CLI-wiring file). Content larger than this bound quarantines with reason
/// `rawLimit` before either metric ever runs. This is independent of, and
/// generally larger than, the fixed 1 MiB `compressedToRawRatio` cap above
/// -- the cap is a schema constant fixed for cross-run comparability, never
/// caller-tunable, so a caller who raises `max-input-bytes` past 1 MiB can
/// still process larger documents (recording their real byte counts) while
/// the ratio itself correctly abstains above that fixed cap.
///
/// **No caller-tunable compressor parameters beyond `max-input-bytes`.**
/// Level (19), window, and strategy are fixed schema constants bound into
/// `compressorLevel`/the schema version -- required for cross-run
/// comparability, never exposed as options. No dictionary-based compression.
/// No corpus-wide or pairwise normalized compression distance is computed
/// here -- this stage only ever measures one document against itself.
///
/// **Anti-comparison rule.** A `compressedToRawRatio` or `entropy` value is
/// only ever comparable to another value produced by the exact same
/// `schema`/`compressorVersion`/`compressorLevel`/`tokenizerVersion`
/// identity recorded alongside it. Values from a different estimator or
/// schema identity (a future `-v2` schema, a different zstd level, a
/// retokenized entropy rule) are never comparable, even if the field name
/// looks the same.
///
/// **Not a quality gate.** This stage never makes a keep/reject/quarantine
/// decision from either metric, and never feeds the separate, pre-existing
/// `quality_features`/`quality_overlay` gate -- untouched by this slice.
module effects.compressibility_annotate_stage;

import crypto.sha256 : sha256Of;
import domain.token_entropy : EntropyStatus, tokenEntropy,
    tokenEntropyTokenizerVersion;
import effects.zstd_ffi : ZSTD_compress, ZSTD_compressBound, ZSTD_isError;
import stages.contract : PassMode, ResourceDeclaration, StageDecision,
    StageDeclaration, StageDocument;
import stages.registry : ConfiguredStageTransform, FilterPlacement,
    OptionDeclaration, OptionType, SideOutputCapability, StageCardinality,
    StageConfiguration, StageOptions, StageRegistration, registerStage;
import std.exception : enforce;
import std.format : format;

enum compressibilityAnnotateStageKeyV1 = "compressibility-annotate";
enum compressibilityExtensionKeyV1 = "compressibility";
enum compressibilitySchemaV1 = "scrubbed-compressibility-v1";

enum compressibilityCompressorName = "zstd";
enum compressibilityCompressorVersion = "1.5.7";
enum int compressibilityCompressorLevel = 19;

/// Fixed schema constants (never caller-tunable): the `compressedToRawRatio`
/// normalization is only reported within this byte range, matching
/// `domain.similarity_signature.maxSimilarityInputBytes`'s own 1 MiB cap
/// precedent. Below the floor, zstd's fixed per-frame overhead dominates any
/// real signal; above the cap, cross-run comparability of a fixed schema
/// identity matters more than measuring arbitrarily large documents.
enum size_t compressibilityRatioFloorBytes = 64;
enum size_t compressibilityRatioCapBytes = 1024 * 1024;

/// `max-input-bytes` default and sanity ceiling, mirroring
/// `effects.html_tree.defaultExtractHtmlBytes`/`maxConfigurableHtmlBytes`'s
/// own default/ceiling pair exactly.
enum size_t compressibilityDefaultMaxInputBytes = 1024 * 1024;
enum size_t compressibilityMaxConfigurableInputBytes = 8 * 1024 * 1024;

enum RatioStatus { computed, belowFloor, aboveCap }

/// The full, decoded shape of one `compressibility` extension field. Kept
/// independent of `domain.token_entropy.TokenEntropyResult`'s own shape
/// (this struct is this module's own wire-adjacent value, not a re-export).
struct CompressibilityAnnotation {
    EntropyStatus entropyStatus;
    double entropyValue = 0.0;
    size_t tokenCount;
    size_t distinctTokenCount;
    RatioStatus ratioStatus;
    double compressedToRawRatio = 0.0;
    size_t rawBytes;
    size_t compressedBytes;
    ubyte[32] contentRevisionSha256;
}

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

/// Encodes `annotation` as this stage's `scrubbed-compressibility-v1`
/// extension-field bytes. Each metric's value field is JSON `null` exactly
/// when that metric's own status is not `computed` -- the status enum, not
/// the numeric field, is always the authoritative signal (see the module
/// doc's "typed status enum, not a sentinel" framing). Fixed `%.6f`
/// formatting keeps the worst-case encoded length predictable and safely
/// under `domain.document_metadata.maxExtensionValueBytes` (512): see this
/// module's own boundary unittest below, which pins the worst-case length.
immutable(ubyte)[] encodeCompressibilityV1(const CompressibilityAnnotation a) pure {
    auto entropyValueField = a.entropyStatus == EntropyStatus.computed ?
        format!"%.6f"(a.entropyValue) : "null";
    auto ratioField = a.ratioStatus == RatioStatus.computed ?
        format!"%.6f"(a.compressedToRawRatio) : "null";
    string wire = format!(
        `{"schema":"%s","tokenizerVersion":"%s",` ~
        `"entropy":{"status":"%s","value":%s,"tokenCount":%s,"distinctTokenCount":%s},` ~
        `"compression":{"status":"%s","compressedToRawRatio":%s,"rawBytes":%s,` ~
        `"compressedBytes":%s,"compressorName":"%s","compressorVersion":"%s",` ~
        `"compressorLevel":%s},"contentRevisionSha256":"%s"}`)(
        compressibilitySchemaV1, tokenEntropyTokenizerVersion,
        a.entropyStatus, entropyValueField, a.tokenCount, a.distinctTokenCount,
        a.ratioStatus, ratioField, a.rawBytes, a.compressedBytes,
        compressibilityCompressorName, compressibilityCompressorVersion,
        compressibilityCompressorLevel, hexEncode(a.contentRevisionSha256[]));
    return cast(immutable(ubyte)[]) wire;
}

/// Decodes this module's own `encodeCompressibilityV1` wire, for this
/// module's unittests only (the field is opaque to every other module,
/// including `document-metadata-publish`, which never interprets it).
private CompressibilityAnnotation decodeCompressibilityV1(immutable(ubyte)[] wire) {
    import std.conv : to;
    import std.json : JSONType, parseJSON;

    auto root = parseJSON(cast(string) wire);
    enforce(root["schema"].str == compressibilitySchemaV1, "unexpected compressibility schema");
    enforce(root["tokenizerVersion"].str == tokenEntropyTokenizerVersion,
        "unexpected tokenizer version");
    CompressibilityAnnotation result;
    auto entropy = root["entropy"];
    result.entropyStatus = to!EntropyStatus(entropy["status"].str);
    if (entropy["value"].type != JSONType.null_)
        result.entropyValue = entropy["value"].floating;
    result.tokenCount = cast(size_t) entropy["tokenCount"].integer;
    result.distinctTokenCount = cast(size_t) entropy["distinctTokenCount"].integer;
    auto compression = root["compression"];
    result.ratioStatus = to!RatioStatus(compression["status"].str);
    if (compression["compressedToRawRatio"].type != JSONType.null_)
        result.compressedToRawRatio = compression["compressedToRawRatio"].floating;
    result.rawBytes = cast(size_t) compression["rawBytes"].integer;
    result.compressedBytes = cast(size_t) compression["compressedBytes"].integer;
    enforce(compression["compressorName"].str == compressibilityCompressorName,
        "unexpected compressor name");
    enforce(compression["compressorVersion"].str == compressibilityCompressorVersion,
        "unexpected compressor version");
    enforce(compression["compressorLevel"].integer == compressibilityCompressorLevel,
        "unexpected compressor level");
    auto revisionHex = root["contentRevisionSha256"].str;
    enforce(revisionHex.length == 64, "malformed content-revision digest");
    foreach (i; 0 .. 32) {
        result.contentRevisionSha256[i] = cast(ubyte)(
            (hexNibble(revisionHex[2 * i]) << 4) | hexNibble(revisionHex[2 * i + 1]));
    }
    return result;
}

private ubyte hexNibble(char c) pure {
    if (c >= '0' && c <= '9') return cast(ubyte)(c - '0');
    if (c >= 'a' && c <= 'f') return cast(ubyte)(c - 'a' + 10);
    throw new Exception("compressibility: malformed hex digest");
}

/// One-shot zstd level-19 buffer compression over `raw`, via the pinned
/// vendored archive's simple API (`effects.zstd_ffi`). Level is always this
/// module's fixed `compressibilityCompressorLevel` constant.
private size_t zstdCompressedSize(const(ubyte)[] raw) pure {
    auto bound = ZSTD_compressBound(raw.length);
    enforce(!ZSTD_isError(bound), "compressibility: zstd bound computation failed");
    auto dst = new ubyte[bound];
    auto srcPtr = raw.length == 0 ? null : raw.ptr;
    auto compressedSize = ZSTD_compress(dst.ptr, dst.length, srcPtr, raw.length,
        compressibilityCompressorLevel);
    enforce(!ZSTD_isError(compressedSize), "compressibility: zstd compression failed");
    return compressedSize;
}

/// Bounds-checks a configured `max-input-bytes` value, mirroring
/// `effects.html_tree.checkedHtmlByteLimit`'s exact shape and sanity-ceiling
/// idiom.
size_t checkedCompressibilityMaxInputBytes(ulong limit) pure {
    enforce(limit > 0 && limit <= compressibilityMaxConfigurableInputBytes,
        "compressibility max-input-bytes must be between 1 and 8388608");
    return cast(size_t) limit;
}

private class CompressibilityAnnotateConfiguration : StageConfiguration {
    size_t maxInputBytes;
    this(size_t maxInputBytes) immutable { this.maxInputBytes = maxInputBytes; }
}

private StageDecision applyCompressibilityAnnotate(StageDocument input,
        immutable(StageConfiguration) configuration) pure {
    auto configured = cast(immutable(CompressibilityAnnotateConfiguration)) configuration;
    enforce(configured !is null, "invalid compressibility-annotate configuration");
    if (input.content.size > configured.maxInputBytes)
        return StageDecision.quarantine("rawLimit");
    auto raw = input.content.copy();

    try {
        auto contentRevision = sha256Of(raw);
        auto entropyResult = tokenEntropy(raw);
        auto compressedBytes = zstdCompressedSize(raw);
        auto rawBytes = raw.length;

        RatioStatus ratioStatus;
        double ratioValue = 0.0;
        if (rawBytes < compressibilityRatioFloorBytes) {
            ratioStatus = RatioStatus.belowFloor;
        } else if (rawBytes > compressibilityRatioCapBytes) {
            ratioStatus = RatioStatus.aboveCap;
        } else {
            ratioStatus = RatioStatus.computed;
            ratioValue = cast(double) compressedBytes / cast(double) rawBytes;
        }

        CompressibilityAnnotation annotation;
        annotation.entropyStatus = entropyResult.status;
        annotation.entropyValue = entropyResult.entropy;
        annotation.tokenCount = entropyResult.tokenCount;
        annotation.distinctTokenCount = entropyResult.distinctTokenCount;
        annotation.ratioStatus = ratioStatus;
        annotation.compressedToRawRatio = ratioValue;
        annotation.rawBytes = rawBytes;
        annotation.compressedBytes = compressedBytes;
        annotation.contentRevisionSha256 = contentRevision;

        auto encoded = encodeCompressibilityV1(annotation);
        input.metadata = input.metadata.withExtensionField(compressibilityExtensionKeyV1,
            encoded, compressibilityAnnotateStageKeyV1);
    } catch (Exception) {
        // A genuine internal-invariant failure (e.g. the extension field
        // capacity/duplicate-key cap already exhausted by a prior stage) --
        // never raised merely because a metric itself could not be computed;
        // both metrics above always degrade to a typed abstention status
        // instead of throwing. Mirrors `topical_tags_extract_stage`'s own
        // `annotationBuildFailure` catch-all for the same reason.
        return StageDecision.quarantine("annotationBuildFailure");
    }
    // `content` is returned completely unmodified.
    return StageDecision.map(input);
}

private ConfiguredStageTransform factory(const ref StageOptions options) {
    auto chosen = "max-input-bytes" in options;
    auto maxInputBytes = chosen is null ? compressibilityDefaultMaxInputBytes :
        checkedCompressibilityMaxInputBytes(chosen.asInteger());
    return ConfiguredStageTransform(&applyCompressibilityAnnotate,
        new immutable CompressibilityAnnotateConfiguration(maxInputBytes));
}

static this() {
    registerStage(StageRegistration(StageDeclaration(compressibilityAnnotateStageKeyV1,
        PassMode.singlePass, ResourceDeclaration(1, 32 * 1024 * 1024)),
        [OptionDeclaration("max-input-bytes", OptionType.integer)], null, null, &factory,
        FilterPlacement.none, StageCardinality.oneToOne, SideOutputCapability.none));
}

// ---------------------------------------------------------------------------
// Unit tests. Every fixture asserts real computed numbers, not merely
// type-correctness, per the accepted contract's acceptance criteria.
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

    private StageEvent runCompressibilityAnnotate(const(ubyte)[] bytes,
            string jobOptionsJson = "{}") {
        auto spec = parseJobJson(`{"version":3,"stages":[{"id":"annotate",` ~
            `"implementation":"` ~ compressibilityAnnotateStageKeyV1 ~ `",` ~
            `"options":` ~ jobOptionsJson ~ `,"filters":[]}]}`);
        auto plan = compileJob(spec);
        auto input = StageDocument(fixtureDocument(), new Content([ContentPiece.own(bytes)]));
        auto result = runCompiledStage([input], plan.stages[0]);
        assert(result.events.length == 1);
        return result.events[0];
    }

    private CompressibilityAnnotation decodedAnnotation(StageEvent event) {
        assert(event.kind == EventKind.emitted);
        auto fields = event.payload.metadata.extensionFields;
        assert(fields.length == 1);
        assert(fields[0].key == compressibilityExtensionKeyV1);
        assert(fields[0].sourceStage == compressibilityAnnotateStageKeyV1);
        return decodeCompressibilityV1(fields[0].value);
    }
}

// Fixture: empty input. Ratio abstains `belowFloor` (0 < 64), entropy
// abstains `noTokens` (valid trivial UTF-8, zero tokens); compression still
// runs and reports a real, nonzero `compressedBytes` for the empty frame.
unittest {
    auto event = runCompressibilityAnnotate([]);
    auto annotation = decodedAnnotation(event);
    assert(annotation.entropyStatus == EntropyStatus.noTokens);
    assert(annotation.tokenCount == 0 && annotation.distinctTokenCount == 0);
    assert(annotation.ratioStatus == RatioStatus.belowFloor);
    assert(annotation.rawBytes == 0);
    assert(annotation.compressedBytes > 0,
        "even an empty zstd frame must occupy real bytes: got " ~
        annotation.compressedBytes.to!string);
    assert(cast(string) event.payload.content.copy() == "", "content must pass through unmodified");
}

// Fixture: all-zero bytes. Entropy abstains `noTokens` (no letter/number/
// underscore runs at all -- 0x00 is not a token character); the ratio is
// computed and, being maximally repetitive, must be near the compression
// floor (a tiny fraction of raw size) -- both real numbers are asserted, not
// merely "some value."
unittest {
    ubyte[2000] zeros; // default-initialized to 0x00
    auto event = runCompressibilityAnnotate(zeros[]);
    auto annotation = decodedAnnotation(event);
    assert(annotation.entropyStatus == EntropyStatus.noTokens);
    assert(annotation.ratioStatus == RatioStatus.computed);
    assert(annotation.rawBytes == 2000);
    assert(annotation.compressedBytes < 100,
        "2000 zero bytes must compress to well under 100 bytes: got " ~
        annotation.compressedBytes.to!string);
    assert(annotation.compressedToRawRatio < 0.05,
        "all-zeros compressedToRawRatio must be near the compression floor: got " ~
        annotation.compressedToRawRatio.to!string);
}

// Fixture: highly-repetitive natural-language text. Token-frequency entropy
// is "high-ish" (several distinct words, each recurring) because order-0
// entropy has no notion of *sequence* repetition -- but zstd's ratio is
// near-floor because it directly exploits the verbatim repeated phrase.
// Both real numbers are asserted, demonstrating the two metrics measure
// genuinely different things and are not interchangeable.
unittest {
    string phrase = "alpha bravo charlie delta echo foxtrot golf hotel. ";
    string repetitive;
    foreach (_; 0 .. 200) repetitive ~= phrase;
    auto event = runCompressibilityAnnotate(cast(const(ubyte)[]) repetitive);
    auto annotation = decodedAnnotation(event);
    assert(annotation.entropyStatus == EntropyStatus.computed);
    // 8 distinct words, each repeated exactly 200 times: a perfectly uniform
    // token-frequency distribution, so token-frequency entropy is exactly
    // log2(8) == 3.0 -- "high-ish," not near zero, even though the whole
    // document is one phrase repeated verbatim.
    assert(annotation.entropyValue > 2.999 && annotation.entropyValue < 3.001,
        "repetitive-text entropy expected exactly log2(8)==3.0: got " ~ annotation.entropyValue.to!string);
    assert(annotation.ratioStatus == RatioStatus.computed);
    assert(annotation.compressedToRawRatio < 0.05,
        "verbatim-repeated phrase must compress to a near-floor ratio: got " ~
        annotation.compressedToRawRatio.to!string);
}

// Fixture: natural-language text (non-repetitive). Both metrics compute to
// real, plausible, pinned-range numbers.
unittest {
    string text = "Scrubbed processes documents through a pipeline of stages " ~
        "and filters, repairing mojibake, extracting metadata, and annotating " ~
        "compressibility before publishing the final side output for review.";
    auto event = runCompressibilityAnnotate(cast(const(ubyte)[]) text);
    auto annotation = decodedAnnotation(event);
    assert(annotation.entropyStatus == EntropyStatus.computed);
    assert(annotation.tokenCount == 24, "token count: " ~ annotation.tokenCount.to!string);
    assert(annotation.entropyValue > 4.0 && annotation.entropyValue < 5.0,
        "natural-language entropy out of expected range: got " ~ annotation.entropyValue.to!string);
    assert(annotation.ratioStatus == RatioStatus.computed);
    assert(annotation.rawBytes == text.length);
    assert(annotation.compressedToRawRatio > 0.4 && annotation.compressedToRawRatio < 1.1,
        "natural-language ratio out of expected range: got " ~
        annotation.compressedToRawRatio.to!string);
}

// Fixture: uniform-random-like bytes (deterministic xorshift, fixed seed --
// reproducible across runs, not `std.random`'s ambient/system seed).
// Near-incompressible: the ratio must be close to 1.0 (allowing for zstd's
// small fixed frame overhead on genuinely incompressible input). Random
// bytes are also, with overwhelming probability, invalid UTF-8, so entropy
// abstains while the ratio still computes -- the deliberate asymmetry.
unittest {
    ubyte[4096] randomish;
    uint state = 0x2545F491;
    foreach (i; 0 .. randomish.length) {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        randomish[i] = cast(ubyte)(state & 0xff);
    }
    auto event = runCompressibilityAnnotate(randomish[]);
    auto annotation = decodedAnnotation(event);
    assert(annotation.ratioStatus == RatioStatus.computed);
    assert(annotation.rawBytes == 4096);
    assert(annotation.compressedToRawRatio > 0.95 && annotation.compressedToRawRatio < 1.2,
        "near-random bytes should be almost incompressible: got " ~
        annotation.compressedToRawRatio.to!string);
}

// Fixture: multilingual UTF-8 (Latin, Japanese, and an emoji outside the
// BMP). Entropy computes over real multi-script tokens; ratio computes over
// the same valid UTF-8 bytes.
unittest {
    string text = "Hello world. こんにちは 世界. " ~
        "Bonjour le monde \U0001F30D repeated: Hello world. こんにちは 世界.";
    auto event = runCompressibilityAnnotate(cast(const(ubyte)[]) text);
    auto annotation = decodedAnnotation(event);
    assert(annotation.entropyStatus == EntropyStatus.computed);
    assert(annotation.tokenCount == 12, "token count: " ~ annotation.tokenCount.to!string);
    assert(annotation.distinctTokenCount == 8,
        "distinct token count: " ~ annotation.distinctTokenCount.to!string);
    assert(annotation.ratioStatus == RatioStatus.computed);
}

// Fixture: invalid UTF-8. Entropy abstains `invalidUtf8`; the ratio still
// computes normally over the same raw bytes -- the documented asymmetry
// proven directly, with real byte counts.
unittest {
    ubyte[] invalid = cast(ubyte[]) "well formed ascii text then, well above the sixty-four byte floor, ".dup;
    invalid ~= [cast(ubyte) 0xC0, cast(ubyte) 0x80]; // overlong/invalid UTF-8
    invalid ~= cast(ubyte[]) " and more ascii after that.".dup;
    auto event = runCompressibilityAnnotate(invalid);
    auto annotation = decodedAnnotation(event);
    assert(annotation.entropyStatus == EntropyStatus.invalidUtf8);
    assert(annotation.tokenCount == 0 && annotation.distinctTokenCount == 0);
    assert(annotation.ratioStatus == RatioStatus.computed);
    assert(annotation.rawBytes == invalid.length);
    assert(annotation.compressedBytes > 0);
}

// Fixture: cap/short-input boundaries. Exactly-at-floor (64 bytes) and
// exactly-at-cap (1 MiB) both compute the ratio; one-under-floor (63 bytes)
// and one-over-cap (1 MiB + 1, with `max-input-bytes` raised so it is not
// quarantined) both abstain -- proven at the exact byte boundary, matching
// the accepted contract's required proof.
unittest {
    auto atFloor = new ubyte[64];
    auto atFloorEvent = runCompressibilityAnnotate(atFloor);
    assert(decodedAnnotation(atFloorEvent).ratioStatus == RatioStatus.computed);

    auto belowFloor = new ubyte[63];
    auto belowFloorEvent = runCompressibilityAnnotate(belowFloor);
    auto belowFloorAnnotation = decodedAnnotation(belowFloorEvent);
    assert(belowFloorAnnotation.ratioStatus == RatioStatus.belowFloor);
    assert(belowFloorAnnotation.rawBytes == 63);
    assert(belowFloorEvent.kind == EventKind.emitted,
        "one byte under the floor must still emit, not quarantine");

    auto atCap = new ubyte[1024 * 1024];
    auto atCapEvent = runCompressibilityAnnotate(atCap);
    assert(decodedAnnotation(atCapEvent).ratioStatus == RatioStatus.computed);

    auto aboveCap = new ubyte[1024 * 1024 + 1];
    auto aboveCapEvent = runCompressibilityAnnotate(aboveCap, `{"max-input-bytes":2097152}`);
    auto aboveCapAnnotation = decodedAnnotation(aboveCapEvent);
    assert(aboveCapAnnotation.ratioStatus == RatioStatus.aboveCap);
    assert(aboveCapAnnotation.rawBytes == 1024 * 1024 + 1);
    assert(aboveCapEvent.kind == EventKind.emitted,
        "one byte over the fixed cap must still emit, not quarantine, when " ~
        "max-input-bytes permits the input");
}

// Resource-safety quarantine: exceeding `max-input-bytes` itself (a genuine
// input-size gate, distinct from the fixed ratio floor/cap above) does
// quarantine with reason `rawLimit`, the same idiom every other stage in
// this codebase uses -- this is not a "compressibility could not be
// computed" case.
unittest {
    auto oversized = new ubyte[compressibilityDefaultMaxInputBytes + 1];
    auto event = runCompressibilityAnnotate(oversized);
    assert(event.kind == EventKind.quarantined);
    assert(event.reason == "rawLimit");
}

// Determinism: two independent runs over the same input produce
// byte-identical extension-field bytes.
unittest {
    string text = "Determinism must hold across repeated runs on the same input.";
    auto first = runCompressibilityAnnotate(cast(const(ubyte)[]) text);
    auto second = runCompressibilityAnnotate(cast(const(ubyte)[]) text);
    assert(first.payload.metadata.extensionFields[0].value ==
        second.payload.metadata.extensionFields[0].value);
}

// Content-revision digest: the recorded sha256 is exactly the sha256 of the
// raw bytes this stage actually received.
unittest {
    string text = "content revision binding fixture";
    auto event = runCompressibilityAnnotate(cast(const(ubyte)[]) text);
    auto annotation = decodedAnnotation(event);
    assert(annotation.contentRevisionSha256 == sha256Of(cast(const(ubyte)[]) text));
}

// Boundary: the worst-case encoded field (longest status names, maximal
// digit counts at the configurable ceiling) stays safely under
// `domain.document_metadata.maxExtensionValueBytes` (512).
unittest {
    import domain.document_metadata : maxExtensionValueBytes;

    CompressibilityAnnotation worstCase;
    worstCase.entropyStatus = EntropyStatus.invalidUtf8;
    worstCase.ratioStatus = RatioStatus.belowFloor;
    worstCase.tokenCount = compressibilityMaxConfigurableInputBytes;
    worstCase.distinctTokenCount = compressibilityMaxConfigurableInputBytes;
    worstCase.rawBytes = compressibilityMaxConfigurableInputBytes;
    worstCase.compressedBytes = compressibilityMaxConfigurableInputBytes;
    worstCase.compressedToRawRatio = 9.999999;
    worstCase.entropyValue = 23.999999;
    worstCase.contentRevisionSha256[] = 0xab;
    auto encoded = encodeCompressibilityV1(worstCase);
    assert(encoded.length <= maxExtensionValueBytes,
        "worst-case compressibility field exceeds the 512-byte extension cap: " ~
        encoded.length.to!string);
}

// Never-quarantines-for-computation-failure: an exactly-63-byte input (one
// byte under the ratio floor -- the smallest input that would make ratio
// *normalization* fail) still produces a fully valid, emitted annotation
// with a typed abstention status, proven directly through the full
// `compileJob`/`runCompiledStage` registry path, not a quarantine.
unittest {
    auto justBelowFloor = new ubyte[compressibilityRatioFloorBytes - 1];
    auto event = runCompressibilityAnnotate(justBelowFloor);
    assert(event.kind == EventKind.emitted,
        "ratio-computation abstention must never quarantine the document");
    assert(decodedAnnotation(event).ratioStatus == RatioStatus.belowFloor);
}

// Reachability: `[compressibility-annotate, document-metadata-publish]`
// compiles and runs as one job via `compileJob`/`runCompiledJob`, and the
// terminal `document-metadata-v1` side output's decoded metadata carries
// exactly the `compressibility` field this stage wrote.
unittest {
    auto spec = parseJobJson(`{"version":3,"stages":[` ~
        `{"id":"annotate","implementation":"` ~ compressibilityAnnotateStageKeyV1 ~
        `","options":{},"filters":[]},` ~
        `{"id":"publish","implementation":"document-metadata-publish",` ~
        `"options":{},"filters":[]}]}`);
    auto plan = compileJob(spec);
    string text = "reachability fixture text for the compressibility annotate chain";
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
    assert(field.key == compressibilityExtensionKeyV1);
    assert(field.sourceStage == compressibilityAnnotateStageKeyV1);
    auto annotation = decodeCompressibilityV1(field.value);
    assert(annotation.entropyStatus == EntropyStatus.computed);
    assert(annotation.ratioStatus == RatioStatus.computed);
    assert(annotation.rawBytes == text.length);
    assert(annotation.contentRevisionSha256 == sha256Of(cast(const(ubyte)[]) text));
}
