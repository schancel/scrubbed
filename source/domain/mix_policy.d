/// Pure, revision-agnostic selection over caller-validated C02/C04 annotations.
module domain.mix_policy;

import domain.document : DocumentId;
import domain.quality_features : Disposition, QualityDecision;
import domain.exact_dedup : ExactDuplicateLink, exactBytesVersion;
import std.algorithm.sorting : sort;
import crypto.sha256 : sha256Of;

enum mixPolicyVersion = "mix-policy:v1";
enum uint maxSampleDenominator = 1_000_000;
enum size_t maxMixBatch = 4096;
enum uint unsampledBucket = uint.max;

enum MissingAnnotation : ubyte { fail, exclude }
enum MixReason : ubyte { selected, sampledOut, qualityDrop, qualityQuarantine,
    duplicate, missingQuality, missingDedup }

class MixPolicyException : Exception {
    this(string reason) { super("mix policy: " ~ reason); }
}

private void require(bool okay, string reason) {
    if (!okay) throw new MixPolicyException(reason);
}

/// Sixteen lowercase hexadecimal digits are the canonical fixed-width seed.
struct MixPolicy {
    private bool initialized;
    private ubyte[8] seed;
    private uint numerator;
    private uint denominator;
    private MissingAnnotation missing;

    this(string seedHex, uint numerator, uint denominator,
            MissingAnnotation missing = MissingAnnotation.fail) {
        require(seedHex.length == 16, "noncanonical seed");
        foreach (i; 0 .. 8) {
            auto high = hex(seedHex[2 * i]);
            auto low = hex(seedHex[2 * i + 1]);
            require(high >= 0 && low >= 0, "noncanonical seed");
            seed[i] = cast(ubyte)((high << 4) | low);
        }
        require(denominator != 0 && denominator <= maxSampleDenominator &&
            numerator <= denominator, "invalid sample fraction");
        require(missing == MissingAnnotation.fail ||
            missing == MissingAnnotation.exclude, "invalid missing policy");
        this.numerator = numerator;
        this.denominator = denominator;
        this.missing = missing;
        initialized = true;
    }

    ubyte[] canonicalBytes() const {
        require(initialized, "uninitialized policy");
        ubyte[] result = cast(ubyte[])"scrubbed:mix-policy:v1\0".dup;
        result ~= seed[];
        append32(result, numerator);
        append32(result, denominator);
        result ~= cast(ubyte)missing;
        return result;
    }

    uint sampleNumerator() const { require(initialized, "uninitialized policy"); return numerator; }
    uint sampleDenominator() const { require(initialized, "uninitialized policy"); return denominator; }
    MissingAnnotation missingAnnotation() const { require(initialized, "uninitialized policy"); return missing; }
    const(ubyte)[] seedBytes() const { require(initialized, "uninitialized policy"); return seed[].dup; }
}

private int hex(char ch) {
    if (ch >= '0' && ch <= '9') return ch - '0';
    if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
    return -1;
}

private void append32(ref ubyte[] bytes, uint value) {
    bytes ~= cast(ubyte)(value >> 24);
    bytes ~= cast(ubyte)(value >> 16);
    bytes ~= cast(ubyte)(value >> 8);
    bytes ~= cast(ubyte)value;
}

struct MixInput {
    DocumentId id;
    const(QualityDecision)* quality;
    const(ExactDuplicateLink)* dedup;
}

struct MixDecision {
    DocumentId id;
    bool include;
    MixReason reason;
    uint sampleBucket = unsampledBucket;

    /// Stable v1 bytes for replay comparisons; no source content or locator.
    ubyte[] canonicalBytes() const {
        require(validId(id), "invalid document ID");
        require((reason == MixReason.selected) == include &&
            cast(uint)reason <= cast(uint)MixReason.missingDedup,
            "invalid decision");
        ubyte[] result = cast(ubyte[])"scrubbed:mix-decision:v1\0".dup;
        result ~= cast(ubyte)id.text.length;
        result ~= cast(const(ubyte)[])id.text;
        result ~= cast(ubyte)include;
        result ~= cast(ubyte)reason;
        append32(result, sampleBucket);
        return result;
    }
}

private bool validId(DocumentId id) {
    auto value = id.text;
    auto prefix = value.length == 71 ? "doc:v1:" : "child:v1:";
    if (value.length != prefix.length + 64 || value[0 .. prefix.length] != prefix)
        return false;
    foreach (ch; value[prefix.length .. $]) if (hex(ch) < 0) return false;
    return true;
}

/// The caller joins revision-bound overlays before supplying these values.
MixDecision decideMix(MixInput input, MixPolicy policy) {
    policy.canonicalBytes();
    require(validId(input.id), "invalid document ID");
    if (input.quality !is null) {
        require(input.quality.measured.documentId == input.id &&
            cast(uint)input.quality.disposition <= cast(uint)Disposition.quarantine,
            "invalid quality evidence");
    }
    if (input.dedup !is null) {
        auto d = input.dedup;
        require(d.documentId == input.id && validId(d.representativeId) &&
            d.canonicalVersion == exactBytesVersion && d.groupCardinality > 0 &&
            d.duplicate == (d.documentId != d.representativeId) &&
            d.representativeId.text <= d.documentId.text &&
            (!d.duplicate || d.groupCardinality > 1),
            "invalid dedup evidence");
    }
    MixDecision result;
    result.id = input.id;
    if (input.quality is null || input.dedup is null) {
        require(policy.missingAnnotation == MissingAnnotation.exclude,
            "missing annotation");
        result.reason = input.quality is null ? MixReason.missingQuality : MixReason.missingDedup;
    } else if (input.quality.disposition == Disposition.drop) {
        result.reason = MixReason.qualityDrop;
    } else if (input.quality.disposition == Disposition.quarantine) {
        result.reason = MixReason.qualityQuarantine;
    } else if (input.dedup.duplicate) {
        result.reason = MixReason.duplicate;
    } else {
        ubyte[] material = cast(ubyte[])"scrubbed:mix-sample:v1\0".dup;
        material ~= policy.seedBytes;
        material ~= cast(const(ubyte)[])input.id.text;
        auto digest = sha256Of(material);
        ulong first;
        foreach (i; 0 .. 8) first = (first << 8) | digest[i];
        result.sampleBucket = cast(uint)(first % policy.sampleDenominator);
        result.include = result.sampleBucket < policy.sampleNumerator;
        result.reason = result.include ? MixReason.selected : MixReason.sampledOut;
    }
    return result;
}

struct MixBatch {
    MixDecision[] decisions;
    ulong[7] counts;
    DocumentId[] selectedIds;
}

/// Bounded fixture/consumer helper; streaming consumers own cross-batch IDs.
MixBatch decideMixBatch(const(MixInput)[] inputs, MixPolicy policy) {
    policy.canonicalBytes();
    require(inputs.length <= maxMixBatch, "batch exceeds cap");
    bool[string] seen;
    MixBatch result;
    foreach (input; inputs) {
        require(validId(input.id), "invalid document ID");
        require((input.id.text in seen) is null, "duplicate document ID");
        seen[input.id.text] = true;
        auto decision = decideMix(input, policy);
        result.decisions ~= decision;
        ++result.counts[cast(size_t)decision.reason];
        if (decision.include) result.selectedIds ~= decision.id;
    }
    result.decisions.sort!((a, b) => a.id.text < b.id.text);
    result.selectedIds.sort!((a, b) => a.text < b.text);
    return result;
}
