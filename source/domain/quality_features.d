/// Pure, bounded quality measurements and replayable policy decisions.
module domain.quality_features;

import domain.document : DocumentId, OutputName, SourceLocator;
import domain.shard_format : ShardDocument, maxDocumentPayload;
import crypto.sha256 : sha256Of;
import core.exception : UnicodeException;
import std.exception : enforce;
import std.uni : unicode;

enum uint featureSchema = 1;
enum uint policySchema = 1;
enum uint partsPerMillion = 1_000_000;

enum FeatureStatus : ubyte { valid, invalidUtf8 }
enum Disposition : ubyte { keep, drop, quarantine }
enum Reason : ubyte { invalidUtf8, tooShort, tooManyControls,
    tooManyReplacements, tooManyDuplicateLines }

/// Counts describe the exact opaque content revision named by the digest.
struct MeasuredFeatures {
    DocumentId documentId;
    ubyte[32] contentDigest;
    uint schema = featureSchema;
    FeatureStatus status;
    uint byteLength;
    uint scalarCount;
    uint lineCount;
    uint letterCount;
    uint controlCount;
    uint replacementCount;
    uint duplicateLineCount;
}

/// Thresholds are independent. Ratios use exact integer comparison, not floats.
struct QualityPolicy {
    private bool initialized;
    private uint minimumScalars;
    private uint maximumControlPpm;
    private uint maximumReplacementPpm;
    private uint maximumDuplicateLinePpm;

    this(uint minimumScalars, uint maximumControlPpm,
        uint maximumReplacementPpm, uint maximumDuplicateLinePpm) {
        enforce(minimumScalars <= maxDocumentPayload &&
            maximumControlPpm <= partsPerMillion &&
            maximumReplacementPpm <= partsPerMillion &&
            maximumDuplicateLinePpm <= partsPerMillion,
            "quality policy: threshold out of range");
        this.minimumScalars = minimumScalars;
        this.maximumControlPpm = maximumControlPpm;
        this.maximumReplacementPpm = maximumReplacementPpm;
        this.maximumDuplicateLinePpm = maximumDuplicateLinePpm;
        this.initialized = true;
    }

    /// Stable v1 domain tag plus big-endian fixed-width fields.
    ubyte[] canonicalBytes() const {
        enforce(initialized, "quality policy: uninitialized policy");
        ubyte[] result = cast(ubyte[])"scrubbed:quality-policy:v1\0".dup;
        append32(result, policySchema);
        append32(result, minimumScalars);
        append32(result, maximumControlPpm);
        append32(result, maximumReplacementPpm);
        append32(result, maximumDuplicateLinePpm);
        return result;
    }

    ubyte[32] digest() const { return sha256Of(canonicalBytes()); }

    static QualityPolicy fromCanonicalBytes(const(ubyte)[] bytes) {
        auto prefix = cast(const(ubyte)[])"scrubbed:quality-policy:v1\0";
        enforce(bytes.length == prefix.length + 20 && bytes[0 .. prefix.length] == prefix,
            "quality policy: malformed canonical identity");
        auto at = prefix.length;
        enforce(read32(bytes, at) == policySchema,
            "quality policy: unsupported schema");
        return QualityPolicy(read32(bytes, at), read32(bytes, at),
            read32(bytes, at), read32(bytes, at));
    }

    uint minScalars() const { return minimumScalars; }
    uint maxControlPpm() const { return maximumControlPpm; }
    uint maxReplacementPpm() const { return maximumReplacementPpm; }
    uint maxDuplicateLinePpm() const { return maximumDuplicateLinePpm; }
}

/// Fixed-width v1 measurement value for a C01 annotation field. The caller
/// supplies the typed source ID and exact content digest obtained from C01's
/// join, so a field cannot silently attach to another revision.
ubyte[] encodeMeasured(MeasuredFeatures value) {
    checkMeasured(value);
    ubyte[] result = cast(ubyte[])"scrubbed:quality-features:v1\0".dup;
    result ~= cast(const(ubyte)[])value.documentId.text;
    result ~= value.contentDigest[];
    append32(result, value.schema);
    result ~= cast(ubyte)value.status;
    append32(result, value.byteLength);
    append32(result, value.scalarCount);
    append32(result, value.lineCount);
    append32(result, value.letterCount);
    append32(result, value.controlCount);
    append32(result, value.replacementCount);
    append32(result, value.duplicateLineCount);
    return result;
}

MeasuredFeatures decodeMeasured(const(ubyte)[] bytes, DocumentId sourceId,
    ubyte[32] contentDigest) {
    auto prefix = cast(const(ubyte)[])"scrubbed:quality-features:v1\0";
    enforce(sourceId.text.length == 71 && bytes.length == prefix.length + 71 + 32 + 4 + 1 + 28 &&
        bytes[0 .. prefix.length] == prefix &&
        bytes[prefix.length .. prefix.length + 71] == cast(const(ubyte)[])sourceId.text &&
        bytes[prefix.length + 71 .. prefix.length + 103] == contentDigest[],
        "quality features: malformed or revision-mismatched measurement");
    MeasuredFeatures result;
    result.documentId = sourceId;
    result.contentDigest = contentDigest;
    auto at = prefix.length + 103;
    result.schema = read32(bytes, at);
    result.status = cast(FeatureStatus)bytes[at++];
    result.byteLength = read32(bytes, at);
    result.scalarCount = read32(bytes, at);
    result.lineCount = read32(bytes, at);
    result.letterCount = read32(bytes, at);
    result.controlCount = read32(bytes, at);
    result.replacementCount = read32(bytes, at);
    result.duplicateLineCount = read32(bytes, at);
    checkMeasured(result);
    return result;
}

struct QualityDecision {
    Disposition disposition;
    Reason[] reasons;
    MeasuredFeatures measured;
    ubyte[32] policyDigest;
    ubyte[32] analyzerIdentity;
}

private void append32(ref ubyte[] bytes, uint value) {
    foreach_reverse (shift; [0, 8, 16, 24])
        bytes ~= cast(ubyte)(value >> shift);
}

private uint read32(const(ubyte)[] bytes, ref size_t at) {
    uint value;
    foreach (_; 0 .. 4) value = (value << 8) | bytes[at++];
    return value;
}

/// The only operation in this module that examines content. Input must fit C01's cap.
MeasuredFeatures measure(ShardDocument source) {
    enforce(source.content.length <= maxDocumentPayload,
        "quality features: source content exceeds shard cap");
    MeasuredFeatures result;
    result.documentId = source.id;
    result.contentDigest = source.contentDigest;
    result.byteLength = cast(uint)source.content.length;
    auto text = cast(string)source.content;
    static immutable letters = unicode("Letter");
    // Scalar iteration is the strict UTF-8 validation pass as well as the
    // feature pass; do not decode every valid document once before counting.
    uint scalarCount;
    uint letterCount;
    uint controlCount;
    uint replacementCount;
    try {
        foreach (dchar scalar; text) {
            ++scalarCount;
            if (scalar in letters) ++letterCount;
            if (scalar <= 0x1f || (scalar >= 0x7f && scalar <= 0x9f))
                ++controlCount;
            if (scalar == 0xfffd) ++replacementCount;
        }
    } catch (UnicodeException) {
        result.status = FeatureStatus.invalidUtf8;
        return result;
    }
    result.scalarCount = scalarCount;
    result.letterCount = letterCount;
    result.controlCount = controlCount;
    result.replacementCount = replacementCount;
    // Lines are LF-delimited non-phantom segments. The final unterminated
    // segment counts; a trailing LF does not create an extra empty line.
    bool[string] seen;
    size_t start;
    foreach (index, byteValue; source.content) {
        if (byteValue != '\n') continue;
        auto line = cast(string)source.content[start .. index];
        if (line in seen) ++result.duplicateLineCount;
        else seen[line] = true;
        ++result.lineCount;
        start = index + 1;
    }
    if (start < source.content.length) {
        auto line = cast(string)source.content[start .. $];
        if (line in seen) ++result.duplicateLineCount;
        ++result.lineCount;
    }
    return result;
}

/// Refuse malformed or foreign measurements before making a durable decision.
private void checkMeasured(ref const MeasuredFeatures value) {
    enforce(value.schema == featureSchema && value.documentId.text.length != 0 &&
        value.byteLength <= maxDocumentPayload,
        "quality features: unsupported or unbound measurement");
    if (value.status == FeatureStatus.invalidUtf8) {
        enforce(value.byteLength != 0 && value.scalarCount == 0 && value.lineCount == 0 &&
            value.letterCount == 0 && value.controlCount == 0 &&
            value.replacementCount == 0 && value.duplicateLineCount == 0,
            "quality features: invalid UTF-8 measurement has text counts");
    } else {
        enforce(value.status == FeatureStatus.valid &&
            value.scalarCount <= value.byteLength &&
            value.letterCount <= value.scalarCount &&
            value.controlCount <= value.scalarCount &&
            value.replacementCount <= value.scalarCount &&
            cast(ulong)value.letterCount + value.controlCount +
                value.replacementCount <= value.scalarCount &&
            value.lineCount <= value.scalarCount &&
            (value.byteLength == 0 ? value.lineCount == 0 : value.lineCount != 0) &&
            (value.lineCount == 0 ? value.duplicateLineCount == 0 :
                value.duplicateLineCount < value.lineCount),
            "quality features: inconsistent measurement");
    }
}

private bool exceeds(uint count, uint total, uint maximumPpm) {
    return total != 0 && cast(ulong)count * partsPerMillion >
        cast(ulong)maximumPpm * total;
}

/// Replay uses only the stored measurement and supplied policy, never source text.
QualityDecision decide(MeasuredFeatures measured, QualityPolicy policy) {
    checkMeasured(measured);
    // A default-initialized policy is valid but not an implicit universal score.
    QualityDecision result;
    result.measured = measured;
    result.policyDigest = policy.digest;
    ubyte[] identity = cast(ubyte[])"scrubbed:quality-decision:v1\0".dup;
    append32(identity, featureSchema);
    identity ~= cast(const(ubyte)[])measured.documentId.text;
    identity ~= measured.contentDigest[];
    identity ~= result.policyDigest[];
    result.analyzerIdentity = sha256Of(identity);
    if (measured.status == FeatureStatus.invalidUtf8) {
        result.disposition = Disposition.quarantine;
        result.reasons = [Reason.invalidUtf8];
        return result;
    }
    if (measured.scalarCount < policy.minScalars)
        result.reasons ~= Reason.tooShort;
    if (exceeds(measured.controlCount, measured.scalarCount, policy.maxControlPpm))
        result.reasons ~= Reason.tooManyControls;
    if (exceeds(measured.replacementCount, measured.scalarCount,
            policy.maxReplacementPpm))
        result.reasons ~= Reason.tooManyReplacements;
    if (exceeds(measured.duplicateLineCount, measured.lineCount,
            policy.maxDuplicateLinePpm))
        result.reasons ~= Reason.tooManyDuplicateLines;
    result.disposition = result.reasons.length ? Disposition.drop : Disposition.keep;
    return result;
}

unittest {
    auto doc = ShardDocument(SourceLocator("unit", "source", "one"),
        OutputName("one"), cast(ubyte[])"x\nx".dup);
    auto measured = measure(doc);
    assert(measured.byteLength == 3 && measured.lineCount == 2 &&
        measured.duplicateLineCount == 1);
    auto invalid = ShardDocument(SourceLocator("unit", "source", "bad"),
        OutputName("bad"), [cast(ubyte)0xef, 0xbf, 0xbd, '\t', 'A', 0xc3]);
    auto invalidMeasured = measure(invalid);
    assert(invalidMeasured.status == FeatureStatus.invalidUtf8 &&
        invalidMeasured.byteLength == 6 && invalidMeasured.scalarCount == 0 &&
        invalidMeasured.letterCount == 0 && invalidMeasured.controlCount == 0 &&
        invalidMeasured.replacementCount == 0 && invalidMeasured.lineCount == 0 &&
        invalidMeasured.duplicateLineCount == 0);
    auto unicodeDoc = ShardDocument(SourceLocator("unit", "source", "unicode"),
        OutputName("unicode"), cast(ubyte[])"é�\né�".dup);
    auto unicodeMeasured = measure(unicodeDoc);
    assert(unicodeMeasured.status == FeatureStatus.valid &&
        unicodeMeasured.byteLength == 11 && unicodeMeasured.scalarCount == 5 &&
        unicodeMeasured.letterCount == 2 && unicodeMeasured.controlCount == 1 &&
        unicodeMeasured.replacementCount == 2 &&
        unicodeMeasured.lineCount == 2 &&
        unicodeMeasured.duplicateLineCount == 1);
    auto stored = encodeMeasured(measured);
    auto replayed = decodeMeasured(stored, doc.id, doc.contentDigest);
    auto permissive = QualityPolicy(0, partsPerMillion, partsPerMillion,
        partsPerMillion);
    auto strict = QualityPolicy(4, partsPerMillion, partsPerMillion, 0);
    assert(decide(replayed, permissive).disposition == Disposition.keep);
    assert(decide(replayed, strict).reasons ==
        [Reason.tooShort, Reason.tooManyDuplicateLines]);
}
