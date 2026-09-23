/// Pure one-shot refinement of detected ZIP media through bounded inspection.
module extraction.refinement;

import content.pieces : Content;
import extraction.container : AdmittedZipV1, ZipInspectionLimitsV1,
    ZipInspectionReasonV1, ZipInspectionResultV1, ZipInspectionStatusV1,
    ZipPackageKindV1, inspectZipContainerV1;
import extraction.contracts : DetectionOutcomeV1, DetectionResultV1,
    EvidenceKindV1, MediaEvidenceV1, maxDetectionEvidenceV1,
    maxDetectionWarningsV1;
import std.exception : enforce;

/// Refined detection plus the complete owned accounting and optional capability.
struct RefinedMediaV1 {
    private DetectionResultV1 detectionValue;
    private ZipInspectionResultV1 containerValue;
    private bool inspectedValue;
    private AdmittedZipV1 admittedValue;

    DetectionResultV1 detection() { return detectionValue; }
    bool containerInspected() const pure { return inspectedValue; }
    ZipInspectionResultV1 container() {
        enforce(inspectedValue, "media was not container-inspected");
        return containerValue;
    }
    AdmittedZipV1 admittedZip() {
        enforce(admittedValue !is null, "refined media has no admitted ZIP capability");
        return admittedValue;
    }
    bool hasAdmittedZip() const pure { return admittedValue !is null; }
}

/// Flat and ambiguous inputs never enter container inspection. A strong ZIP
/// signature is the sole authority that can grant the ZIP inspection path.
RefinedMediaV1 refineMediaV1(Content source, DetectionResultV1 detected,
        ZipInspectionLimitsV1 limits = ZipInspectionLimitsV1()) {
    enforce(source !is null, "media refinement needs source content");
    detected.validateResult;
    RefinedMediaV1 result;
    result.detectionValue = detected;
    if (detected.outcome != DetectionOutcomeV1.genericZip) return result;

    auto inspected = inspectZipContainerV1(source, limits);
    result.inspectedValue = true;
    result.containerValue = inspected;
    auto evidence = detected.evidence.dup;
    auto warnings = detected.warnings.dup;
    auto refinedVersion = detected.detectorVersion ~ "+" ~ inspected.formatVersion;
    if (inspected.status == ZipInspectionStatusV1.admitted) {
        auto outcome = inspected.packageKind == ZipPackageKindV1.ooxmlWord
            ? DetectionOutcomeV1.ooxmlWord : DetectionOutcomeV1.genericZip;
        enforce(evidence.length < maxDetectionEvidenceV1,
            "refinement evidence limit exhausted");
        evidence ~= MediaEvidenceV1(EvidenceKindV1.containerStructure,
            outcome, outcome == DetectionOutcomeV1.ooxmlWord
                ? "ooxml-word-markers" : "classic-store-zip");
        result.detectionValue = DetectionResultV1.detected(outcome, evidence,
            refinedVersion, warnings, detected.bytesInspected,
            detected.inspectionLimit, detected.availableBytes);
        result.admittedValue = inspected.admitted;
        return result;
    }

    if (warnings.length < maxDetectionWarningsV1)
        warnings ~= refusalWarning(inspected.reason);
    final switch (inspected.reason) {
    case ZipInspectionReasonV1.malformed, ZipInspectionReasonV1.unsafePath:
        result.detectionValue = DetectionResultV1.malformed(evidence, refinedVersion,
            warnings, detected.bytesInspected, detected.inspectionLimit,
            detected.availableBytes);
        break;
    case ZipInspectionReasonV1.encrypted:
        result.detectionValue = DetectionResultV1.encrypted(evidence, refinedVersion,
            warnings, detected.bytesInspected, detected.inspectionLimit,
            detected.availableBytes);
        break;
    case ZipInspectionReasonV1.physicalLimit,
         ZipInspectionReasonV1.compressedLimit,
         ZipInspectionReasonV1.expandedLimit,
         ZipInspectionReasonV1.entryLimit,
         ZipInspectionReasonV1.depthLimit,
         ZipInspectionReasonV1.ratioLimit,
         ZipInspectionReasonV1.unsupportedFeature:
        result.detectionValue = DetectionResultV1.unsupported(evidence, refinedVersion,
            warnings, detected.bytesInspected, detected.inspectionLimit,
            detected.availableBytes);
        break;
    case ZipInspectionReasonV1.admitted:
        enforce(false, "refused ZIP cannot have admitted reason");
        break;
    }
    return result;
}

private string refusalWarning(ZipInspectionReasonV1 reason) pure {
    final switch (reason) {
    case ZipInspectionReasonV1.admitted: return "zip-admitted";
    case ZipInspectionReasonV1.malformed: return "zip-malformed";
    case ZipInspectionReasonV1.unsafePath: return "zip-unsafe-path";
    case ZipInspectionReasonV1.encrypted: return "zip-encrypted";
    case ZipInspectionReasonV1.physicalLimit: return "zip-physical-limit";
    case ZipInspectionReasonV1.compressedLimit: return "zip-compressed-limit";
    case ZipInspectionReasonV1.expandedLimit: return "zip-expanded-limit";
    case ZipInspectionReasonV1.entryLimit: return "zip-entry-limit";
    case ZipInspectionReasonV1.depthLimit: return "zip-depth-limit";
    case ZipInspectionReasonV1.ratioLimit: return "zip-ratio-limit";
    case ZipInspectionReasonV1.unsupportedFeature: return "zip-unsupported-feature";
    }
}

unittest {
    import content.pieces : ContentPiece;
    import extraction.detector : detectMediaV1;

    // Empty classic ZIP: EOCD only.
    auto bytes = cast(const(ubyte)[]) [
        0x50, 0x4b, 0x05, 0x06, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    ];
    auto content = new Content([ContentPiece.own(bytes)]);
    auto detected = detectMediaV1(content);
    assert(detected.outcome == DetectionOutcomeV1.genericZip);
    auto refined = refineMediaV1(content, detected);
    assert(refined.containerInspected && refined.hasAdmittedZip);
    assert(refined.detection.outcome == DetectionOutcomeV1.genericZip);
    assert(refined.container.reason == ZipInspectionReasonV1.admitted);

    auto flat = new Content([ContentPiece.own(cast(const(ubyte)[]) "text")]);
    auto unchanged = refineMediaV1(flat, detectMediaV1(flat));
    assert(!unchanged.containerInspected && !unchanged.hasAdmittedZip);

    auto broken = new Content([ContentPiece.own([
        cast(ubyte) 0x50, 0x4b, 0x03, 0x04, 0, 1, 2, 3])]);
    auto refused = refineMediaV1(broken, detectMediaV1(broken));
    assert(refused.containerInspected && !refused.hasAdmittedZip);
    assert(refused.detection.outcome == DetectionOutcomeV1.malformed);
    assert(refused.container.reason == ZipInspectionReasonV1.malformed);
}
