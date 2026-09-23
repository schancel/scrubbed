/// Deterministic bounded detection from signatures, text and untrusted hints.
module extraction.detector;

import content.pieces : Content;
import extraction.contracts : DetectionOutcomeV1, DetectionResultV1,
    EvidenceKindV1, MediaEvidenceV1, maxDetectionEvidenceV1,
    maxDetectionWarningsV1;
import std.algorithm.searching : canFind;
import std.exception : enforce;
import std.string : indexOf, lastIndexOf, strip;
import std.utf : UTFException, validate;

enum string boundedDetectorVersionV1 = "bounded-signatures:v1";
enum size_t maxDetectionPrefixBytesV1 = 64 * 1024;

/// Hard limits keep callers from turning detection into whole-input inspection.
struct DetectionLimitsV1 {
    size_t prefixBytes;
    size_t evidenceRecords;
    size_t warnings;

    this(size_t prefixBytes, size_t evidenceRecords = maxDetectionEvidenceV1,
            size_t warnings = maxDetectionWarningsV1) {
        enforce(prefixBytes > 0 && prefixBytes <= maxDetectionPrefixBytesV1,
            "detection prefix limit is outside the supported bound");
        enforce(evidenceRecords >= 4 && evidenceRecords <= maxDetectionEvidenceV1,
            "detection evidence limit is outside the supported bound");
        enforce(warnings >= 4 && warnings <= maxDetectionWarningsV1,
            "detection warning limit is outside the supported bound");
        this.prefixBytes = prefixBytes;
        this.evidenceRecords = evidenceRecords;
        this.warnings = warnings;
    }

    static DetectionLimitsV1 defaults() {
        return DetectionLimitsV1(4096);
    }
}

/// Inspect at most limits.prefixBytes. MIME and extension are evidence only.
DetectionResultV1 detectMediaV1(Content content, string declaredMediaType = null,
        string fileName = null,
        DetectionLimitsV1 limits = DetectionLimitsV1.defaults) {
    enforce(content !is null, "media detection needs content");
    // Revalidate default-initialized limits at the edge.
    limits = DetectionLimitsV1(limits.prefixBytes, limits.evidenceRecords,
        limits.warnings);

    auto totalBytes = content.size;
    auto inspected = totalBytes < limits.prefixBytes ? totalBytes : limits.prefixBytes;
    ubyte[] prefix;
    prefix.reserve(inspected);
    foreach (offset, piece; content) {
        foreach (index; 0 .. piece.size) {
            if (prefix.length == inspected) break;
            prefix ~= piece.at(index);
        }
        if (prefix.length == inspected) break;
    }

    MediaEvidenceV1[] evidence;
    string[] warnings;
    void addEvidence(EvidenceKindV1 kind, DetectionOutcomeV1 outcome, string detail) {
        enforce(evidence.length < limits.evidenceRecords,
            "detector evidence limit is too small for normalized evidence");
        evidence ~= MediaEvidenceV1(kind, outcome, detail);
    }
    void addWarning(string warning) {
        if (warnings.length < limits.warnings) warnings ~= warning;
    }

    bool[cast(size_t) DetectionOutcomeV1.max + 1] strong;
    void addStrong(DetectionOutcomeV1 outcome, EvidenceKindV1 kind, string detail) {
        addEvidence(kind, outcome, detail);
        strong[cast(size_t) outcome] = true;
    }

    auto pdfAt = findSequence(prefix, cast(const(ubyte)[]) "%PDF-", 1024);
    if (pdfAt >= 0)
        addStrong(DetectionOutcomeV1.pdf, EvidenceKindV1.signature, "pdf-header");
    if (startsWithBytes(prefix, [cast(ubyte) 0x89, 0x50, 0x4e, 0x47,
            0x0d, 0x0a, 0x1a, 0x0a]))
        addStrong(DetectionOutcomeV1.png, EvidenceKindV1.signature, "png-signature");
    if (startsWithBytes(prefix, [cast(ubyte) 0xff, 0xd8, 0xff]))
        addStrong(DetectionOutcomeV1.jpeg, EvidenceKindV1.signature, "jpeg-signature");
    if (startsWithBytes(prefix, cast(const(ubyte)[]) "GIF87a") ||
            startsWithBytes(prefix, cast(const(ubyte)[]) "GIF89a"))
        addStrong(DetectionOutcomeV1.gif, EvidenceKindV1.signature, "gif-signature");

    auto textStart = leadingTextOffset(prefix);
    bool html;
    if (textStart < prefix.length) {
        auto lowered = asciiLower(prefix[textStart .. $]);
        html = startsWithBytes(lowered, cast(const(ubyte)[]) "<!doctype html") ||
            startsWithBytes(lowered, cast(const(ubyte)[]) "<html") ||
            startsWithBytes(lowered, cast(const(ubyte)[]) "<head") ||
            startsWithBytes(lowered, cast(const(ubyte)[]) "<body");
        if (html)
            addStrong(DetectionOutcomeV1.html, EvidenceKindV1.textualContent,
                "leading-html-markup");
    }

    auto truncatedSignature = totalBytes == prefix.length &&
        (partialSignature(prefix, cast(const(ubyte)[]) "%PDF-") ||
         partialSignature(prefix, [cast(ubyte) 0x89, 0x50, 0x4e, 0x47,
             0x0d, 0x0a, 0x1a, 0x0a]) ||
         partialSignature(prefix, [cast(ubyte) 0xff, 0xd8, 0xff]) ||
         partialSignature(prefix, cast(const(ubyte)[]) "GIF87a") ||
         partialSignature(prefix, cast(const(ubyte)[]) "GIF89a"));
    auto signatureCount = countStrong(strong);
    if (signatureCount == 0 && !truncatedSignature && looksLikeUtf8Text(prefix))
        addStrong(DetectionOutcomeV1.plainText, EvidenceKindV1.textualContent,
            "valid-utf8-text-prefix");

    if (truncatedSignature) addWarning("truncated-known-signature");
    if (totalBytes > inspected) addWarning("inspection-prefix-limited");

    auto mimeOutcome = mediaTypeOutcome(declaredMediaType);
    if (mimeOutcome != DetectionOutcomeV1.unknown)
        addEvidence(EvidenceKindV1.declaredMediaType, mimeOutcome, "declared-mime");
    auto extensionOutcome = extensionMediaOutcome(fileName);
    if (extensionOutcome != DetectionOutcomeV1.unknown)
        addEvidence(EvidenceKindV1.fileExtension, extensionOutcome, "filename-extension");

    auto strongCount = countStrong(strong);
    DetectionOutcomeV1 outcome;
    if (strongCount > 1) {
        outcome = DetectionOutcomeV1.ambiguous;
        addWarning("conflicting-strong-evidence");
    } else if (strongCount == 1) {
        foreach (index; 0 .. strong.length)
            if (strong[index]) outcome = cast(DetectionOutcomeV1) index;
        if ((mimeOutcome != DetectionOutcomeV1.unknown && mimeOutcome != outcome) ||
                (extensionOutcome != DetectionOutcomeV1.unknown && extensionOutcome != outcome))
            addWarning("untrusted-hint-conflicts-with-content");
    } else {
        outcome = DetectionOutcomeV1.unknown;
        if (mimeOutcome != DetectionOutcomeV1.unknown ||
                extensionOutcome != DetectionOutcomeV1.unknown)
            addWarning("untrusted-hints-not-authoritative");
        else
            addWarning("no-supported-media-evidence");
    }

    return DetectionResultV1(outcome, evidence, boundedDetectorVersionV1,
        warnings, inspected);
}

private size_t countStrong(ref bool[cast(size_t) DetectionOutcomeV1.max + 1] strong) {
    size_t count;
    foreach (present; strong) if (present) ++count;
    return count;
}

private bool startsWithBytes(const(ubyte)[] input, const(ubyte)[] expected) pure {
    return input.length >= expected.length && input[0 .. expected.length] == expected;
}

private bool partialSignature(const(ubyte)[] input, const(ubyte)[] signature) pure {
    return input.length >= 2 && input.length < signature.length &&
        input == signature[0 .. input.length];
}

private ptrdiff_t findSequence(const(ubyte)[] input, const(ubyte)[] needle,
        size_t maxStart) pure {
    if (needle.length > input.length) return -1;
    auto last = input.length - needle.length;
    if (last > maxStart) last = maxStart;
    foreach (index; 0 .. last + 1)
        if (input[index .. index + needle.length] == needle)
            return cast(ptrdiff_t) index;
    return -1;
}

private size_t leadingTextOffset(const(ubyte)[] input) pure {
    size_t offset;
    if (input.length >= 3 && input[0 .. 3] == [cast(ubyte) 0xef, 0xbb, 0xbf])
        offset = 3;
    while (offset < input.length &&
            (input[offset] == ' ' || input[offset] == '\t' ||
             input[offset] == '\r' || input[offset] == '\n'))
        ++offset;
    return offset;
}

private ubyte[] asciiLower(const(ubyte)[] input) pure {
    auto result = input.dup;
    foreach (ref value; result)
        if (value >= 'A' && value <= 'Z') value += 'a' - 'A';
    return result;
}

private bool looksLikeUtf8Text(const(ubyte)[] input) {
    if (!input.length) return true;
    foreach (value; input) {
        if (value == 0) return false;
        if (value < 0x20 && value != '\t' && value != '\n' && value != '\r')
            return false;
    }
    try validate(cast(string) input);
    catch (UTFException) return false;
    return true;
}

private DetectionOutcomeV1 mediaTypeOutcome(string mediaType) {
    auto normalized = asciiLowerString(mediaType.strip);
    auto parameter = normalized.indexOf(';');
    if (parameter >= 0) normalized = normalized[0 .. parameter].strip;
    switch (normalized) {
    case "text/plain": return DetectionOutcomeV1.plainText;
    case "text/html": return DetectionOutcomeV1.html;
    case "application/pdf": return DetectionOutcomeV1.pdf;
    case "image/png": return DetectionOutcomeV1.png;
    case "image/jpeg": return DetectionOutcomeV1.jpeg;
    case "image/gif": return DetectionOutcomeV1.gif;
    default: return DetectionOutcomeV1.unknown;
    }
}

private DetectionOutcomeV1 extensionMediaOutcome(string fileName) {
    auto normalized = asciiLowerString(fileName);
    auto slash = normalized.length;
    foreach_reverse (index; 0 .. normalized.length) {
        if (normalized[index] == '/' || normalized[index] == '\\') {
            slash = index + 1;
            break;
        }
    }
    auto dot = normalized.lastIndexOf('.');
    if (dot < 0 || cast(size_t) dot < slash) return DetectionOutcomeV1.unknown;
    switch (normalized[dot .. $]) {
    case ".txt": return DetectionOutcomeV1.plainText;
    case ".html": case ".htm": return DetectionOutcomeV1.html;
    case ".pdf": return DetectionOutcomeV1.pdf;
    case ".png": return DetectionOutcomeV1.png;
    case ".jpg": case ".jpeg": return DetectionOutcomeV1.jpeg;
    case ".gif": return DetectionOutcomeV1.gif;
    default: return DetectionOutcomeV1.unknown;
    }
}

private string asciiLowerString(string input) pure {
    auto result = input.dup;
    foreach (ref value; result)
        if (value >= 'A' && value <= 'Z') value += 'a' - 'A';
    return cast(string) result;
}

unittest {
    import content.pieces : ContentPiece;
    import std.exception : assertThrown;

    DetectionResultV1 detected(const(ubyte)[] bytes, string mime = null,
            string name = null, size_t limit = 4096) {
        return detectMediaV1(new Content([ContentPiece.own(bytes)]), mime, name,
            DetectionLimitsV1(limit));
    }

    auto misleading = detected(cast(const(ubyte)[]) "%PDF-1.7\n",
        "text/plain", "report.txt");
    assert(misleading.outcome == DetectionOutcomeV1.pdf);
    assert(misleading.bytesInspected == 9);
    assert(misleading.warnings.length == 1 &&
        misleading.warnings[0] == "untrusted-hint-conflicts-with-content");
    assert(misleading.detectorVersion == boundedDetectorVersionV1);
    auto repeated = detected(cast(const(ubyte)[]) "%PDF-1.7\n",
        "text/plain", "report.txt");
    assert(repeated.outcome == misleading.outcome);
    assert(repeated.evidence.length == misleading.evidence.length);
    foreach (index, item; repeated.evidence) {
        assert(item.kind == misleading.evidence[index].kind);
        assert(item.outcome == misleading.evidence[index].outcome);
        assert(item.detail == misleading.evidence[index].detail);
    }

    assert(detected(cast(const(ubyte)[]) "hello\nworld", "application/pdf",
        "wrong.pdf").outcome == DetectionOutcomeV1.plainText);
    assert(detected(cast(const(ubyte)[]) " <!DOCTYPE HTML><p>x</p>").outcome ==
        DetectionOutcomeV1.html);
    assert(detected([cast(ubyte) 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a,
        0x1a, 0x0a]).outcome == DetectionOutcomeV1.png);
    assert(detected([cast(ubyte) 0xff, 0xd8, 0xff, 0xe0]).outcome ==
        DetectionOutcomeV1.jpeg);
    assert(detected(cast(const(ubyte)[]) "GIF89a...").outcome ==
        DetectionOutcomeV1.gif);
    assert(detected([cast(ubyte) 0, 1, 2, 3], "text/plain", "x.txt").outcome ==
        DetectionOutcomeV1.unknown);

    auto truncated = detected(cast(const(ubyte)[]) "%PD");
    assert(truncated.outcome == DetectionOutcomeV1.unknown);
    assert(truncated.warnings.canFind("truncated-known-signature"));

    // A PDF header may legally occur within the leading 1024 bytes. A leading
    // HTML document plus that header is conflicting strong evidence.
    auto conflict = detected(cast(const(ubyte)[]) "<html>%PDF-1.7");
    assert(conflict.outcome == DetectionOutcomeV1.ambiguous && conflict.ambiguous);
    assert(conflict.warnings.canFind("conflicting-strong-evidence"));

    auto bounded = detected(cast(const(ubyte)[]) "plain text continues", null,
        null, 5);
    assert(bounded.outcome == DetectionOutcomeV1.plainText);
    assert(bounded.bytesInspected == 5);
    assert(bounded.warnings.canFind("inspection-prefix-limited"));
    assertThrown(DetectionLimitsV1(0));
    assertThrown(DetectionLimitsV1(maxDetectionPrefixBytesV1 + 1));
    assertThrown(detectMediaV1(new Content, null, null,
        DetectionLimitsV1.init));
}
