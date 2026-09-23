/// Versioned, pure contracts for bounded media detection and text extraction.
module extraction.contracts;

import content.pieces : Content, ContentPiece;
import domain.document : Document, DocumentId, OutputName;
import std.exception : enforce;
import std.string : indexOf;
import std.utf : validate;

/// Normalized outcomes understood by the finite dispatch boundary.
enum DetectionOutcomeV1 : ubyte {
    unknown,
    plainText,
    html,
    pdf,
    png,
    jpeg,
    gif,
    ambiguous,
    malformed,
    encrypted,
    unsupported
}

/// Why a detector associated an input with a normalized outcome.
enum EvidenceKindV1 : ubyte {
    signature,
    textualContent,
    declaredMediaType,
    fileExtension
}

/// One bounded, normalized item of detector evidence.
struct MediaEvidenceV1 {
    EvidenceKindV1 kind;
    DetectionOutcomeV1 outcome;
    private string detailValue;

    this(EvidenceKindV1 kind, DetectionOutcomeV1 outcome, string detail) {
        enforce(kind >= EvidenceKindV1.min && kind <= EvidenceKindV1.max,
            "invalid evidence kind");
        enforce(isConcreteMediaV1(outcome), "evidence needs a concrete media outcome");
        detailValue = checkedLabel(detail, "evidence detail", 128);
        this.kind = kind;
        this.outcome = outcome;
    }

    string detail() const pure { return detailValue; }

    private void validateEvidence() const {
        enforce(kind >= EvidenceKindV1.min && kind <= EvidenceKindV1.max,
            "invalid evidence kind");
        enforce(isConcreteMediaV1(outcome), "evidence needs a concrete media outcome");
        enforce(detailValue.length != 0, "uninitialized detector evidence");
    }
}

enum size_t maxDetectionEvidenceV1 = 16;
enum size_t maxDetectionWarningsV1 = 8;
enum size_t maxWarningBytesV1 = 256;

/// A normalized result with stable evidence order and explicit scan accounting.
struct DetectionResultV1 {
    private enum BuildToken { value }
    private DetectionOutcomeV1 outcomeValue;
    private MediaEvidenceV1[] evidenceValue;
    private string detectorVersionValue;
    private string[] warningsValue;
    private size_t bytesInspectedValue;
    private size_t inspectionLimitValue;
    private size_t availableBytesValue;

    /// Build a media, unknown, or ambiguous result. Authoritative evidence
    /// must agree with the normalized outcome.
    static DetectionResultV1 detected(DetectionOutcomeV1 outcome,
            MediaEvidenceV1[] evidence, string detectorVersion,
            string[] warnings, size_t bytesInspected,
            size_t inspectionLimit, size_t availableBytes) {
        enforce(isConcreteMediaV1(outcome) ||
            outcome == DetectionOutcomeV1.unknown ||
            outcome == DetectionOutcomeV1.ambiguous,
            "detected result needs a media, unknown, or ambiguous outcome");
        return build(outcome, evidence, detectorVersion, warnings,
            bytesInspected, inspectionLimit, availableBytes);
    }

    /// Explicit policy outcomes are reserved for detectors that can prove them.
    static DetectionResultV1 malformed(MediaEvidenceV1[] evidence,
            string detectorVersion, string[] warnings, size_t bytesInspected,
            size_t inspectionLimit, size_t availableBytes) {
        return build(DetectionOutcomeV1.malformed, evidence, detectorVersion,
            warnings, bytesInspected, inspectionLimit, availableBytes);
    }

    static DetectionResultV1 encrypted(MediaEvidenceV1[] evidence,
            string detectorVersion, string[] warnings, size_t bytesInspected,
            size_t inspectionLimit, size_t availableBytes) {
        return build(DetectionOutcomeV1.encrypted, evidence, detectorVersion,
            warnings, bytesInspected, inspectionLimit, availableBytes);
    }

    static DetectionResultV1 unsupported(MediaEvidenceV1[] evidence,
            string detectorVersion, string[] warnings, size_t bytesInspected,
            size_t inspectionLimit, size_t availableBytes) {
        return build(DetectionOutcomeV1.unsupported, evidence, detectorVersion,
            warnings, bytesInspected, inspectionLimit, availableBytes);
    }

    DetectionOutcomeV1 outcome() const pure { return outcomeValue; }
    bool ambiguous() const pure { return outcomeValue == DetectionOutcomeV1.ambiguous; }
    const(MediaEvidenceV1)[] evidence() const pure { return evidenceValue; }
    string detectorVersion() const pure { return detectorVersionValue; }
    const(string)[] warnings() const pure { return warningsValue; }
    size_t bytesInspected() const pure { return bytesInspectedValue; }
    size_t inspectionLimit() const pure { return inspectionLimitValue; }
    size_t availableBytes() const pure { return availableBytesValue; }

    /// Reject default or corrupted values before they cross the boundary.
    void validateResult() const {
        enforce(outcomeValue >= DetectionOutcomeV1.min &&
            outcomeValue <= DetectionOutcomeV1.max, "invalid detection outcome");
        enforce(detectorVersionValue.length != 0,
            "detector result needs a version");
        enforce(evidenceValue.length <= maxDetectionEvidenceV1 &&
            warningsValue.length <= maxDetectionWarningsV1,
            "detector result exceeds bounded records");
        enforce(inspectionLimitValue > 0, "detector result needs an inspection limit");
        auto expected = availableBytesValue < inspectionLimitValue
            ? availableBytesValue : inspectionLimitValue;
        enforce(bytesInspectedValue <= expected,
            "detector byte accounting exceeds the available inspection cap");
        bool[cast(size_t) DetectionOutcomeV1.max + 1] authoritative;
        foreach (item; evidenceValue) {
            item.validateEvidence;
            if (item.kind == EvidenceKindV1.signature ||
                    item.kind == EvidenceKindV1.textualContent)
                authoritative[cast(size_t) item.outcome] = true;
        }
        foreach (warning; warningsValue)
            validateLabel(warning, "detector warning", maxWarningBytesV1);
        size_t authoritativeOutcomes;
        foreach (present; authoritative) if (present) ++authoritativeOutcomes;
        if (isConcreteMediaV1(outcomeValue)) {
            enforce(authoritativeOutcomes == 1 &&
                authoritative[cast(size_t) outcomeValue],
                "concrete outcome must match its sole authoritative evidence");
        } else if (outcomeValue == DetectionOutcomeV1.ambiguous) {
            enforce(authoritativeOutcomes >= 2,
                "ambiguous outcome needs conflicting authoritative evidence");
        } else if (outcomeValue == DetectionOutcomeV1.unknown) {
            enforce(authoritativeOutcomes == 0,
                "unknown outcome cannot hide authoritative evidence");
        } else {
            enforce(outcomeValue == DetectionOutcomeV1.malformed ||
                outcomeValue == DetectionOutcomeV1.encrypted ||
                outcomeValue == DetectionOutcomeV1.unsupported,
                "invalid policy outcome");
        }
    }

    private static DetectionResultV1 build(DetectionOutcomeV1 outcome,
            MediaEvidenceV1[] evidence, string detectorVersion,
            string[] warnings, size_t bytesInspected,
            size_t inspectionLimit, size_t availableBytes) {
        return DetectionResultV1(BuildToken.value, outcome, evidence,
            detectorVersion, warnings, bytesInspected, inspectionLimit,
            availableBytes);
    }

    private this(BuildToken token, DetectionOutcomeV1 outcome,
            MediaEvidenceV1[] evidence, string detectorVersion,
            string[] warnings, size_t bytesInspected,
            size_t inspectionLimit, size_t availableBytes) {
        enforce(evidence.length <= maxDetectionEvidenceV1,
            "too many detector evidence records");
        enforce(warnings.length <= maxDetectionWarningsV1,
            "too many detector warnings");
        outcomeValue = outcome;
        evidenceValue = evidence.dup;
        detectorVersionValue = checkedLabel(detectorVersion,
            "detector version", 128);
        warningsValue = checkedLabels(warnings, "detector warning",
            maxWarningBytesV1);
        bytesInspectedValue = bytesInspected;
        inspectionLimitValue = inspectionLimit;
        availableBytesValue = availableBytes;
        validateResult;
    }
}

/// A finite dispatch decision. Policies are explicit and cannot carry a route.
enum RouteActionKindV1 : ubyte { route, reject, quarantine, passThrough }

struct RouteActionV1 {
    private RouteActionKindV1 kindValue;
    private string routeValue;
    private string reasonValue;

    static RouteActionV1 route(string name) {
        RouteActionV1 result;
        result.kindValue = RouteActionKindV1.route;
        result.routeValue = checkedLabel(name, "route name", 128);
        return result;
    }

    static RouteActionV1 reject(string reason) {
        return policy(RouteActionKindV1.reject, reason);
    }

    static RouteActionV1 quarantine(string reason) {
        return policy(RouteActionKindV1.quarantine, reason);
    }

    static RouteActionV1 passThrough(string reason) {
        return policy(RouteActionKindV1.passThrough, reason);
    }

    RouteActionKindV1 kind() const pure { return kindValue; }
    string routeName() const pure { return routeValue; }
    string reason() const pure { return reasonValue; }

    private static RouteActionV1 policy(RouteActionKindV1 kind, string reason) {
        RouteActionV1 result;
        result.kindValue = kind;
        result.reasonValue = checkedLabel(reason, "route policy reason", 256);
        return result;
    }

    private void validate() const {
        enforce(kindValue >= RouteActionKindV1.min && kindValue <= RouteActionKindV1.max,
            "invalid route action");
        if (kindValue == RouteActionKindV1.route) {
            enforce(routeValue.length != 0 && reasonValue.length == 0,
                "route action needs only a route name");
        } else {
            enforce(routeValue.length == 0 && reasonValue.length != 0,
                "policy action needs only a reason");
        }
    }
}

struct RouteRuleV1 {
    DetectionOutcomeV1 outcome;
    RouteActionV1 action;

    this(DetectionOutcomeV1 outcome, RouteActionV1 action) {
        enforce(outcome >= DetectionOutcomeV1.min && outcome <= DetectionOutcomeV1.max,
            "invalid route-rule outcome");
        action.validate;
        this.outcome = outcome;
        this.action = action;
    }
}

/// A complete outcome table. Input declaration order cannot affect selection.
struct RouteDeclarationV1 {
    private enum size_t outcomeCount = cast(size_t) DetectionOutcomeV1.max + 1;
    private RouteActionV1[outcomeCount] actions;

    this(RouteRuleV1[] rules) {
        enforce(rules.length == outcomeCount,
            "route declaration needs exactly one rule for every outcome");
        bool[outcomeCount] seen;
        foreach (rule; rules) {
            auto index = cast(size_t) rule.outcome;
            enforce(index < outcomeCount && !seen[index],
                "duplicate or invalid route outcome");
            rule.action.validate;
            actions[index] = rule.action;
            seen[index] = true;
        }
        foreach (present; seen)
            enforce(present, "route declaration is incomplete");
    }

    RouteActionV1 actionFor(DetectionOutcomeV1 outcome) const {
        auto index = cast(size_t) outcome;
        enforce(index < outcomeCount, "invalid dispatch outcome");
        auto action = actions[index];
        action.validate;
        return action;
    }

    RouteRuleV1[] canonicalRules() const {
        RouteRuleV1[] result;
        foreach (index; 0 .. outcomeCount) {
            auto outcome = cast(DetectionOutcomeV1) index;
            result ~= RouteRuleV1(outcome, actions[index]);
        }
        return result;
    }
}

/// Source-to-text facts retained after a successful extraction route.
struct ExtractionProvenanceV1 {
    DetectionOutcomeV1 sourceOutcome;
    private string routeValue;
    size_t sourceBytes;

    this(DetectionOutcomeV1 sourceOutcome, string routeName, size_t sourceBytes) {
        enforce(isConcreteMediaV1(sourceOutcome),
            "text provenance needs a concrete source outcome");
        this.sourceOutcome = sourceOutcome;
        routeValue = checkedLabel(routeName, "provenance route", 128);
        this.sourceBytes = sourceBytes;
    }

    string routeName() const pure { return routeValue; }
}

/// A structurally snapshotted, read-only view of owned Content pieces.
struct TextContentV1 {
    private Content snapshot;

    private this(Content source) {
        ContentPiece[] pieces;
        foreach (offset, piece; source) {
            enforce(piece.isOwned,
                "text content requires owned pieces; borrowed content needs a retained lease");
            pieces ~= piece;
        }
        snapshot = new Content(pieces);
    }

    size_t size() const pure {
        enforce(snapshot !is null, "text content is not initialized");
        return snapshot.size;
    }

    /// The chunk is temporary and the read-only wrapper exposes no edit API.
    void stream(scope void delegate(const(ubyte)[]) pure sink,
            size_t chunkSize = 8192) const pure {
        enforce(snapshot !is null, "text content is not initialized");
        snapshot.stream(sink, chunkSize);
    }
}

/// Checked stable UTF-8 text plus unchanged source identity and presentation.
struct TextDocumentV1 {
    private Document documentValue;
    private TextContentV1 contentValue;
    private DetectionResultV1 detectionValue;
    private string extractorValue;
    private string extractorVersionValue;
    private string[] warningsValue;
    private ExtractionProvenanceV1 provenanceValue;

    this(Document document, Content content, DetectionResultV1 detection,
            string extractor, string extractorVersion, string[] warnings,
            ExtractionProvenanceV1 provenance) {
        auto id = document.id;
        enforce(id.text.length != 0 && document.outputName.text.length != 0,
            "text document needs initialized identity and output name");
        enforce(content !is null, "text document content is required");
        auto stableContent = TextContentV1(content);
        enforce(validUtf8(stableContent.snapshot),
            "text document content must be valid UTF-8");
        detection.validateResult;
        enforce(isConcreteMediaV1(detection.outcome),
            "text document needs a concrete detection outcome");
        enforce(detection.outcome == provenance.sourceOutcome,
            "text provenance must match detection outcome");
        enforce(detection.availableBytes == provenance.sourceBytes,
            "text provenance must match detected source byte count");
        enforce(warnings.length <= maxDetectionWarningsV1,
            "too many extraction warnings");

        documentValue = document;
        contentValue = stableContent;
        detectionValue = detection;
        extractorValue = checkedLabel(extractor, "extractor name", 128);
        extractorVersionValue = checkedLabel(extractorVersion,
            "extractor version", 128);
        warningsValue = checkedLabels(warnings, "extraction warning",
            maxWarningBytesV1);
        provenanceValue = provenance;
    }

    Document document() const pure { return documentValue; }
    DocumentId id() const pure { return documentValue.id; }
    OutputName outputName() const pure { return documentValue.outputName; }
    const(TextContentV1) content() const pure { return contentValue; }
    const(DetectionResultV1) detection() const pure { return detectionValue; }
    string extractor() const pure { return extractorValue; }
    string extractorVersion() const pure { return extractorVersionValue; }
    const(string)[] warnings() const pure { return warningsValue; }
    ExtractionProvenanceV1 provenance() const pure { return provenanceValue; }
}

bool isConcreteMediaV1(DetectionOutcomeV1 outcome) pure {
    return outcome >= DetectionOutcomeV1.plainText && outcome <= DetectionOutcomeV1.gif;
}

private string checkedLabel(string value, string field, size_t maxBytes) {
    validateLabel(value, field, maxBytes);
    return value.idup;
}

private void validateLabel(string value, string field, size_t maxBytes) {
    enforce(value.length != 0 && value.length <= maxBytes,
        field ~ " must be nonempty and bounded");
    validate(value);
    enforce(value.indexOf('\0') < 0, field ~ " must not contain NUL");
}

private string[] checkedLabels(string[] values, string field, size_t maxBytes) {
    auto result = new string[values.length];
    foreach (index, value; values)
        result[index] = checkedLabel(value, field, maxBytes);
    return result;
}

/// Validate incrementally so a checked text boundary does not flatten Content.
private bool validUtf8(Content content) {
    size_t remaining;
    ubyte nextMin = 0x80;
    ubyte nextMax = 0xbf;
    bool valid = true;
    foreach (offset, piece; content) {
        foreach (index; 0 .. piece.size) {
            auto value = piece.at(index);
            if (remaining) {
                if (value < nextMin || value > nextMax) {
                    valid = false;
                    break;
                }
                --remaining;
                nextMin = 0x80;
                nextMax = 0xbf;
                continue;
            }
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
                valid = false;
                break;
            }
        }
        if (!valid) break;
    }
    return valid && remaining == 0;
}

unittest {
    import content.pieces : ContentPiece;
    import domain.document : Document, OutputName, SourceLocator;
    import std.algorithm.mutation : reverse;
    import std.exception : assertThrown;

    RouteRuleV1[] rules;
    foreach (index; 0 .. cast(size_t) DetectionOutcomeV1.max + 1) {
        auto outcome = cast(DetectionOutcomeV1) index;
        auto action = isConcreteMediaV1(outcome)
            ? RouteActionV1.route("extract")
            : RouteActionV1.quarantine("not extractable");
        rules ~= RouteRuleV1(outcome, action);
    }
    auto forward = RouteDeclarationV1(rules);
    rules.reverse;
    auto reversed = RouteDeclarationV1(rules);
    foreach (index; 0 .. cast(size_t) DetectionOutcomeV1.max + 1) {
        auto outcome = cast(DetectionOutcomeV1) index;
        assert(forward.actionFor(outcome).kind == reversed.actionFor(outcome).kind);
        assert(forward.actionFor(outcome).routeName == reversed.actionFor(outcome).routeName);
        assert(forward.actionFor(outcome).reason == reversed.actionFor(outcome).reason);
    }
    assert(forward.canonicalRules.length == rules.length);
    assertThrown(RouteDeclarationV1(rules[0 .. $ - 1]));
    auto duplicate = rules.dup;
    duplicate[0] = duplicate[1];
    assertThrown(RouteDeclarationV1(duplicate));
    assertThrown(RouteActionV1.route(""));
    assertThrown(RouteActionV1.reject(""));
}

unittest {
    import content.pieces : ContentPiece;
    import domain.document : Document, OutputName, SourceLocator;
    import std.exception : assertThrown;

    auto document = Document(SourceLocator("test", "extract", "one"),
        OutputName("original.txt"));
    char[] resultWarning = "result-warning".dup;
    auto detection = DetectionResultV1.detected(DetectionOutcomeV1.plainText,
        [MediaEvidenceV1(EvidenceKindV1.textualContent,
            DetectionOutcomeV1.plainText, "valid-utf8")],
        "test:v1", [cast(string) resultWarning], 5, 5, 5);
    resultWarning[0] = cast(char) 0xff;
    assert(detection.warnings[0] == "result-warning");
    auto provenance = ExtractionProvenanceV1(DetectionOutcomeV1.plainText,
        "plain-text", 5);
    auto content = new Content([
        ContentPiece.own([cast(ubyte) 0xe2]),
        ContentPiece.own([cast(ubyte) 0x82, 0xac])
    ]);
    char[] textWarning = "text-warning".dup;
    auto text = TextDocumentV1(document, content, detection, "identity",
        "identity:v1", [cast(string) textWarning], provenance);
    textWarning[0] = cast(char) 0xff;
    assert(text.warnings[0] == "text-warning");
    assert(text.id == document.id);
    assert(text.outputName == document.outputName);
    assert(text.document.id == document.id);
    assert(text.content.size == 3);
    ubyte[] stableBytes;
    text.content.stream((const(ubyte)[] chunk) { stableBytes ~= chunk; }, 1);
    assert(stableBytes == [cast(ubyte) 0xe2, 0x82, 0xac]);
    assert(text.provenance.routeName == "plain-text");
    // Replacing the caller's Content cannot mutate the stable text boundary.
    content.replace(0, content.size,
        [ContentPiece.own(cast(const(ubyte)[]) "changed")]);
    stableBytes.length = 0;
    text.content.stream((const(ubyte)[] chunk) { stableBytes ~= chunk; }, 2);
    assert(stableBytes == [cast(ubyte) 0xe2, 0x82, 0xac]);
    assertThrown(TextDocumentV1(document,
        new Content([ContentPiece.own([cast(ubyte) 0xe2, 0x28, 0xa1])]),
        detection, "identity", "identity:v1", null, provenance));
    assertThrown(TextDocumentV1(document, content,
        DetectionResultV1.detected(DetectionOutcomeV1.unknown, null,
            "test:v1", null, 5, 5, 5),
        "identity", "identity:v1", null, provenance));

    import domain.document : DocumentViewOwner;
    auto owner = new DocumentViewOwner(cast(ubyte[]) "borrowed".dup);
    auto borrowed = new Content([ContentPiece.borrow(owner.view(0, 8))]);
    assertThrown(TextDocumentV1(document, borrowed, detection, "identity",
        "identity:v1", null, provenance));
    owner.close();
    assertThrown(TextDocumentV1(document, borrowed, detection, "identity",
        "identity:v1", null, provenance));

    auto pdfEvidence = [MediaEvidenceV1(EvidenceKindV1.signature,
        DetectionOutcomeV1.pdf, "pdf-header")];
    assert(DetectionResultV1.encrypted(pdfEvidence, "container:v1",
        ["encrypted"], 8, 8, 20).outcome == DetectionOutcomeV1.encrypted);
    assert(DetectionResultV1.unsupported(pdfEvidence, "container:v1",
        ["unsupported"], 8, 8, 20).outcome == DetectionOutcomeV1.unsupported);
    assert(DetectionResultV1.malformed(null, "container:v1",
        ["malformed"], 8, 8, 20).outcome == DetectionOutcomeV1.malformed);

    assertThrown(DetectionResultV1.detected(DetectionOutcomeV1.pdf,
        [MediaEvidenceV1(EvidenceKindV1.textualContent,
            DetectionOutcomeV1.plainText, "text")],
        "test:v1", null, 3, 5, 3));
    assertThrown(DetectionResultV1.detected(DetectionOutcomeV1.unknown,
        pdfEvidence, "test:v1", null, 3, 5, 3));
    assertThrown(DetectionResultV1.detected(DetectionOutcomeV1.ambiguous,
        pdfEvidence, "test:v1", null, 3, 5, 3));
    auto early = DetectionResultV1.detected(DetectionOutcomeV1.unknown,
        null, "test:v1", null, 2, 5, 3);
    assert(early.bytesInspected == 2);
    assertThrown(DetectionResultV1.detected(DetectionOutcomeV1.unknown,
        null, "test:v1", null, 4, 5, 3));
    assertThrown(DetectionResultV1.detected(DetectionOutcomeV1.unknown,
        null, "test:v1", null, 4, 3, 10));
}
