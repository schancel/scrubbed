/// Deterministic bounded detection from signatures, text and untrusted hints.
module extraction.detector;

import content.pieces : Content;
import extraction.contracts : DetectionOutcomeV1, DetectionResultV1,
    EvidenceKindV1, MediaEvidenceV1, maxDetectionEvidenceV1,
    maxDetectionWarningsV1;
import std.algorithm.searching : canFind;
import std.exception : enforce;
import std.utf : UTFException, validate;

enum string boundedDetectorVersionV1 = "bounded-signatures:v1";
enum size_t maxDetectionPrefixBytesV1 = 64 * 1024;
enum size_t maxMediaTypeHintBytesV1 = 256;
enum size_t maxFileNameHintBytesV1 = 1024;

private enum Utf8PrefixState { complete, incomplete, invalid }

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
    enforce(prefix.length == inspected,
        "bounded detector must inspect the complete declared prefix");

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
        auto candidate = prefix[textStart .. $];
        html = startsWithAsciiCI(candidate, "<!doctype html") ||
            startsWithAsciiCI(candidate, "<html") ||
            startsWithAsciiCI(candidate, "<head") ||
            startsWithAsciiCI(candidate, "<body");
        if (html)
            addStrong(DetectionOutcomeV1.html, EvidenceKindV1.textualContent,
                "leading-html-markup");
    }

    auto incompleteSignature =
        (partialPdfHeader(prefix) ||
         partialSignature(prefix, [cast(ubyte) 0x89, 0x50, 0x4e, 0x47,
             0x0d, 0x0a, 0x1a, 0x0a]) ||
         partialSignature(prefix, [cast(ubyte) 0xff, 0xd8, 0xff]) ||
         partialSignature(prefix, cast(const(ubyte)[]) "GIF87a") ||
         partialSignature(prefix, cast(const(ubyte)[]) "GIF89a"));
    auto signatureCount = countStrong(strong);
    auto utf8State = utf8TextPrefixState(prefix);
    auto textCompatible = utf8State == Utf8PrefixState.complete ||
        (utf8State == Utf8PrefixState.incomplete && totalBytes > inspected);
    if (signatureCount == 0 && !incompleteSignature && textCompatible)
        addStrong(DetectionOutcomeV1.plainText, EvidenceKindV1.textualContent,
            "valid-utf8-text-prefix");

    if (incompleteSignature) {
        addWarning(totalBytes == inspected ? "truncated-known-signature" :
            "bounded-incomplete-signature");
    }
    if (utf8State == Utf8PrefixState.incomplete)
        addWarning(totalBytes == inspected ? "truncated-utf8-scalar" :
            "bounded-incomplete-utf8-scalar");
    if (totalBytes > inspected) addWarning("inspection-prefix-limited");

    string mimeWarning;
    auto mimeOutcome = mediaTypeOutcome(declaredMediaType, mimeWarning);
    if (mimeWarning.length) addWarning(mimeWarning);
    if (mimeOutcome != DetectionOutcomeV1.unknown)
        addEvidence(EvidenceKindV1.declaredMediaType, mimeOutcome, "declared-mime");
    string fileWarning;
    auto extensionOutcome = extensionMediaOutcome(fileName, fileWarning);
    if (fileWarning.length) addWarning(fileWarning);
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

    return DetectionResultV1.detected(outcome, evidence, boundedDetectorVersionV1,
        warnings, inspected, limits.prefixBytes, totalBytes);
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
    return input.length > 0 && input.length < signature.length &&
        input == signature[0 .. input.length];
}

/// A PDF header may begin at any byte offset through 1024. Only a matching
/// suffix that ends at the inspection boundary is incomplete.
private bool partialPdfHeader(const(ubyte)[] input) pure {
    auto signature = cast(const(ubyte)[]) "%PDF-";
    if (!input.length) return false;
    auto earliest = input.length >= signature.length
        ? input.length - (signature.length - 1) : 0;
    auto latest = input.length - 1;
    if (latest > 1024) latest = 1024;
    if (earliest > latest) return false;
    foreach (start; earliest .. latest + 1)
        if (partialSignature(input[start .. $], signature)) return true;
    return false;
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

private bool startsWithAsciiCI(const(ubyte)[] input, string expected) pure {
    if (input.length < expected.length) return false;
    foreach (index, value; expected)
        if (!asciiEqualCI(input[index], cast(ubyte) value)) return false;
    return true;
}

private Utf8PrefixState utf8TextPrefixState(const(ubyte)[] input) pure {
    size_t remaining;
    ubyte nextMin = 0x80;
    ubyte nextMax = 0xbf;
    foreach (value; input) {
        if (remaining) {
            if (value < nextMin || value > nextMax) return Utf8PrefixState.invalid;
            --remaining;
            nextMin = 0x80;
            nextMax = 0xbf;
            continue;
        }
        if (value == 0) return Utf8PrefixState.invalid;
        if (value < 0x20 && value != '\t' && value != '\n' && value != '\r')
            return Utf8PrefixState.invalid;
        if (value <= 0x7f) continue;
        if (value >= 0xc2 && value <= 0xdf) {
            remaining = 1;
        } else if (value >= 0xe0 && value <= 0xef) {
            remaining = 2;
            if (value == 0xe0) nextMin = 0xa0;
            if (value == 0xed) nextMax = 0x9f;
        } else if (value >= 0xf0 && value <= 0xf4) {
            remaining = 3;
            if (value == 0xf0) nextMin = 0x90;
            if (value == 0xf4) nextMax = 0x8f;
        } else {
            return Utf8PrefixState.invalid;
        }
    }
    return remaining ? Utf8PrefixState.incomplete : Utf8PrefixState.complete;
}

private DetectionOutcomeV1 mediaTypeOutcome(string mediaType, out string warning) {
    if (!mediaType.length) return DetectionOutcomeV1.unknown;
    if (mediaType.length > maxMediaTypeHintBytesV1) {
        warning = "ignored-overlong-media-type-hint";
        return DetectionOutcomeV1.unknown;
    }
    if (!validMediaTypeHint(mediaType)) {
        warning = "ignored-malformed-media-type-hint";
        return DetectionOutcomeV1.unknown;
    }
    size_t start;
    while (start < mediaType.length && asciiWhitespace(mediaType[start])) ++start;
    auto end = start;
    while (end < mediaType.length && mediaType[end] != ';') ++end;
    while (end > start && asciiWhitespace(mediaType[end - 1])) --end;
    auto token = mediaType[start .. end];
    if (asciiEqualsCI(token, "text/plain")) return DetectionOutcomeV1.plainText;
    if (asciiEqualsCI(token, "text/html")) return DetectionOutcomeV1.html;
    if (asciiEqualsCI(token, "application/pdf")) return DetectionOutcomeV1.pdf;
    if (asciiEqualsCI(token, "image/png")) return DetectionOutcomeV1.png;
    if (asciiEqualsCI(token, "image/jpeg")) return DetectionOutcomeV1.jpeg;
    if (asciiEqualsCI(token, "image/gif")) return DetectionOutcomeV1.gif;
    return DetectionOutcomeV1.unknown;
}

private DetectionOutcomeV1 extensionMediaOutcome(string fileName,
        out string warning) {
    if (!fileName.length) return DetectionOutcomeV1.unknown;
    if (fileName.length > maxFileNameHintBytesV1) {
        warning = "ignored-overlong-filename-hint";
        return DetectionOutcomeV1.unknown;
    }
    if (!validHint(fileName)) {
        warning = "ignored-malformed-filename-hint";
        return DetectionOutcomeV1.unknown;
    }
    auto slash = fileName.length;
    foreach_reverse (index; 0 .. fileName.length) {
        if (fileName[index] == '/' || fileName[index] == '\\') {
            slash = index + 1;
            break;
        }
    }
    auto dot = fileName.length;
    foreach_reverse (index; slash .. fileName.length) {
        if (fileName[index] == '.') {
            dot = index;
            break;
        }
    }
    if (dot == fileName.length) return DetectionOutcomeV1.unknown;
    auto suffix = fileName[dot .. $];
    if (asciiEqualsCI(suffix, ".txt")) return DetectionOutcomeV1.plainText;
    if (asciiEqualsCI(suffix, ".html") || asciiEqualsCI(suffix, ".htm"))
        return DetectionOutcomeV1.html;
    if (asciiEqualsCI(suffix, ".pdf")) return DetectionOutcomeV1.pdf;
    if (asciiEqualsCI(suffix, ".png")) return DetectionOutcomeV1.png;
    if (asciiEqualsCI(suffix, ".jpg") || asciiEqualsCI(suffix, ".jpeg"))
        return DetectionOutcomeV1.jpeg;
    if (asciiEqualsCI(suffix, ".gif")) return DetectionOutcomeV1.gif;
    return DetectionOutcomeV1.unknown;
}

private bool validHint(string hint) {
    if (hint.canFind('\0')) return false;
    try validate(hint);
    catch (UTFException) return false;
    return true;
}

private bool validMediaTypeHint(string hint) {
    if (!validHint(hint)) return false;
    foreach (value; hint) {
        auto byteValue = cast(ubyte) value;
        if (byteValue > 0x7f ||
                (byteValue < 0x20 && !asciiWhitespace(value)))
            return false;
    }
    return true;
}

private bool asciiWhitespace(char value) pure {
    return value == ' ' || value == '\t' || value == '\r' || value == '\n';
}

private bool asciiEqualCI(ubyte left, ubyte right) pure {
    if (left >= 'A' && left <= 'Z') left += 'a' - 'A';
    if (right >= 'A' && right <= 'Z') right += 'a' - 'A';
    return left == right;
}

private bool asciiEqualsCI(string input, string expected) pure {
    if (input.length != expected.length) return false;
    foreach (index; 0 .. input.length)
        if (!asciiEqualCI(cast(ubyte) input[index], cast(ubyte) expected[index]))
            return false;
    return true;
}

unittest {
    import content.pieces : ContentPiece;
    import std.array : replicate;
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
    assert(misleading.inspectionLimit == 4096);
    assert(misleading.availableBytes == 9);
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
    auto offsetTruncated = detected(cast(const(ubyte)[]) "a%P");
    assert(offsetTruncated.outcome == DetectionOutcomeV1.unknown);
    assert(offsetTruncated.warnings.canFind("truncated-known-signature"));
    auto offsetBounded = detected(cast(const(ubyte)[]) "a%PDF-1.7",
        null, null, 3);
    assert(offsetBounded.outcome == DetectionOutcomeV1.unknown);
    assert(offsetBounded.warnings.canFind("bounded-incomplete-signature"));

    auto legalOffsetPartial = new ubyte[1026];
    legalOffsetPartial[0 .. 1024] = cast(ubyte) 'a';
    legalOffsetPartial[1024] = '%';
    legalOffsetPartial[1025] = 'P';
    auto legalPartial = detected(legalOffsetPartial);
    assert(legalPartial.outcome == DetectionOutcomeV1.unknown);
    assert(legalPartial.warnings.canFind("truncated-known-signature"));
    auto outsideOffsetPartial = new ubyte[1027];
    outsideOffsetPartial[0 .. 1025] = cast(ubyte) 'a';
    outsideOffsetPartial[1025] = '%';
    outsideOffsetPartial[1026] = 'P';
    auto outsidePartial = detected(outsideOffsetPartial);
    assert(outsidePartial.outcome == DetectionOutcomeV1.plainText);
    assert(!outsidePartial.warnings.canFind("truncated-known-signature"));

    auto legalOffsetFull = new ubyte[1029];
    legalOffsetFull[0 .. 1024] = cast(ubyte) 'a';
    legalOffsetFull[1024 .. $] = cast(const(ubyte)[]) "%PDF-";
    assert(detected(legalOffsetFull).outcome == DetectionOutcomeV1.pdf);
    auto outsideOffsetFull = new ubyte[1030];
    outsideOffsetFull[0 .. 1025] = cast(ubyte) 'a';
    outsideOffsetFull[1025 .. $] = cast(const(ubyte)[]) "%PDF-";
    assert(detected(outsideOffsetFull).outcome == DetectionOutcomeV1.plainText);

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

    auto splitScalar = new ubyte[4098];
    splitScalar[0 .. 4095] = cast(ubyte) 'a';
    splitScalar[4095 .. $] = [cast(ubyte) 0xe2, 0x82, 0xac];
    auto boundedScalar = detected(splitScalar);
    assert(boundedScalar.outcome == DetectionOutcomeV1.plainText);
    assert(boundedScalar.bytesInspected == 4096);
    assert(boundedScalar.warnings.canFind("bounded-incomplete-utf8-scalar"));
    assert(boundedScalar.warnings.canFind("inspection-prefix-limited"));

    auto invalidContinuation = detected([cast(ubyte) 0xe2, 0x28, 0xa1]);
    assert(invalidContinuation.outcome == DetectionOutcomeV1.unknown);
    auto eofScalar = detected([cast(ubyte) 0xe2]);
    assert(eofScalar.outcome == DetectionOutcomeV1.unknown);
    assert(eofScalar.warnings.canFind("truncated-utf8-scalar"));

    auto boundedPdf = detected(cast(const(ubyte)[]) "%PDF-1.7", null, null, 2);
    assert(boundedPdf.outcome == DetectionOutcomeV1.unknown);
    assert(boundedPdf.warnings.canFind("bounded-incomplete-signature"));
    assert(!boundedPdf.warnings.canFind("truncated-known-signature"));
    auto boundedPng = detected([cast(ubyte) 0x89, 0x50, 0x4e, 0x47,
        0x0d, 0x0a, 0x1a, 0x0a], null, null, 4);
    assert(boundedPng.outcome == DetectionOutcomeV1.unknown);
    assert(boundedPng.warnings.canFind("bounded-incomplete-signature"));
    auto boundedJpeg = detected([cast(ubyte) 0xff, 0xd8, 0xff, 0xe0],
        null, null, 2);
    assert(boundedJpeg.outcome == DetectionOutcomeV1.unknown);
    assert(boundedJpeg.warnings.canFind("bounded-incomplete-signature"));
    auto boundedGif = detected(cast(const(ubyte)[]) "GIF89a...", null, null, 3);
    assert(boundedGif.outcome == DetectionOutcomeV1.unknown);
    assert(boundedGif.warnings.canFind("bounded-incomplete-signature"));

    auto caseHints = detected(cast(const(ubyte)[]) "hello",
        " TEXT/PLAIN; charset=UTF-8 ", "folder/NAME.TXT");
    assert(caseHints.outcome == DetectionOutcomeV1.plainText);
    assert(caseHints.evidence.length == 3);
    auto overlongHints = detected(cast(const(ubyte)[]) "hello",
        "x".replicate(maxMediaTypeHintBytesV1 + 1),
        "x".replicate(maxFileNameHintBytesV1 + 1));
    assert(overlongHints.outcome == DetectionOutcomeV1.plainText);
    assert(overlongHints.evidence.length == 1);
    assert(overlongHints.warnings.canFind("ignored-overlong-media-type-hint"));
    assert(overlongHints.warnings.canFind("ignored-overlong-filename-hint"));
    auto malformedHints = detected(cast(const(ubyte)[]) "hello",
        cast(string) [cast(char) 0xff], cast(string) [cast(char) 0xff]);
    assert(malformedHints.outcome == DetectionOutcomeV1.plainText);
    assert(malformedHints.evidence.length == 1);
    assert(malformedHints.warnings.canFind("ignored-malformed-media-type-hint"));
    assert(malformedHints.warnings.canFind("ignored-malformed-filename-hint"));

    assertThrown(DetectionLimitsV1(0));
    assertThrown(DetectionLimitsV1(maxDetectionPrefixBytesV1 + 1));
    assertThrown(detectMediaV1(new Content, null, null,
        DetectionLimitsV1.init));
}
