/// Opt-in, revision-bound C01 persistence for four-class PII findings.
module effects.pii_overlay;

import domain.pii_patterns;
import domain.shard_format : AnnotationField, AnnotationRecord, ShardDocument,
    maxAnnotationPayload;
import effects.document_shards : DocumentShardReader, JoinedOverlay, OverlayReader,
    OverlayWriter, PublishFault, joinShards;
import std.exception : enforce;

enum piiAnalyzerKey = "pii.four-class";
enum piiFieldKey = "findings";
private enum ubyte[] valueTag = cast(ubyte[]) "PII1";

private void require(bool condition, string reason) {
    enforce(condition, "pii overlay: " ~ reason);
}

private ubyte localeCode(string locale) {
    if (locale == "US") return 1;
    if (locale == "GB") return 2;
    throw new Exception("pii overlay: unsupported locale");
}

string piiAnalyzerVersion(string locale) {
    localeCode(locale);
    return "four-class:v1:locale=" ~ locale;
}

private ubyte ruleCode(PiiFinding finding) {
    switch (finding.category) {
    case PiiCategory.email:
        require(finding.rule == "email.ascii-domain.v1" &&
            finding.confidence == PiiConfidence.high, "invalid email rule");
        return 1;
    case PiiCategory.phone:
        if (finding.rule == "phone.national.ambiguous.v1" &&
            finding.confidence == PiiConfidence.ambiguous) return 2;
        if (finding.rule == "phone.international.v1" &&
            finding.confidence == PiiConfidence.high) return 3;
        throw new Exception("pii overlay: invalid phone rule");
    case PiiCategory.card:
        require(finding.rule == "card.luhn.ambiguous.v1" &&
            finding.confidence == PiiConfidence.ambiguous, "invalid card rule");
        return 4;
    case PiiCategory.ip:
        require(finding.rule == "ip.v4.v1" &&
            finding.confidence == PiiConfidence.high, "invalid IP rule");
        return 5;
    default:
        throw new Exception("pii overlay: invalid category");
    }
}

private bool ordered(PiiFinding previous, PiiFinding current) {
    return previous.start < current.start ||
        (previous.start == current.start && (previous.end < current.end ||
        (previous.end == current.end && previous.category < current.category)));
}

private PiiFinding fromRule(ubyte code, size_t start, size_t end, string locale) {
    switch (code) {
    case 1: return PiiFinding(start, end, PiiCategory.email,
        "email.ascii-domain.v1", locale, PiiConfidence.high);
    case 2: return PiiFinding(start, end, PiiCategory.phone,
        "phone.national.ambiguous.v1", locale, PiiConfidence.ambiguous);
    case 3: return PiiFinding(start, end, PiiCategory.phone,
        "phone.international.v1", locale, PiiConfidence.high);
    case 4: return PiiFinding(start, end, PiiCategory.card,
        "card.luhn.ambiguous.v1", locale, PiiConfidence.ambiguous);
    case 5: return PiiFinding(start, end, PiiCategory.ip,
        "ip.v4.v1", locale, PiiConfidence.high);
    default: throw new Exception("pii overlay: invalid rule code");
    }
}

private void put32(ref ubyte[] bytes, size_t value) {
    require(value <= uint.max, "span exceeds encoding");
    foreach_reverse (shift; [0, 8, 16, 24]) bytes ~= cast(ubyte)(value >> shift);
}

private size_t get32(const(ubyte)[] bytes, ref size_t at) {
    require(bytes.length - at >= 4, "truncated finding");
    size_t value;
    foreach (_; 0 .. 4) value = (value << 8) | bytes[at++];
    return value;
}

/// Canonical bytes: ASCII PII1, locale byte (US=1, GB=2), BE u16 count,
/// then BE u32 start/end and one rule byte per finding. No matched text.
ubyte[] encodePiiFindings(const(PiiFinding)[] findings, string locale,
        size_t contentLength) {
    auto code = localeCode(locale);
    require(findings.length <= maxPiiFindings && findings.length <= ushort.max,
        "findings exceed cap");
    require(contentLength <= maxPiiInputBytes, "input exceeds cap");
    // C01 adds 2+71 document-ID bytes, 32 digest bytes, 2 field-count bytes,
    // 2+key bytes and 4 value-length bytes around this value.
    enum size_t envelope = 2 + 71 + 32 + 2 + 2 + piiFieldKey.length + 4;
    require(findings.length <= (maxAnnotationPayload - envelope - 7) / 9,
        "annotation exceeds frame cap");
    ubyte[] bytes = valueTag.dup;
    bytes ~= code;
    bytes ~= cast(ubyte)(findings.length >> 8);
    bytes ~= cast(ubyte)findings.length;
    foreach (index, finding; findings) {
        require(finding.locale == locale && finding.start < finding.end &&
            finding.end <= contentLength, "invalid finding span or locale");
        require(index == 0 || ordered(findings[index - 1], finding),
            "findings not strictly ordered");
        auto rule = ruleCode(finding);
        put32(bytes, finding.start);
        put32(bytes, finding.end);
        bytes ~= rule;
    }
    return bytes;
}

/// Defensively decode only typed spans and rule metadata for a known revision.
PiiFinding[] decodePiiFindings(const(ubyte)[] bytes, string locale,
        size_t contentLength) {
    auto code = localeCode(locale);
    require(contentLength <= maxPiiInputBytes && bytes.length >= 7 &&
        bytes[0 .. 4] == valueTag && bytes[4] == code, "invalid value tag or locale");
    size_t count = (cast(size_t)bytes[5] << 8) | bytes[6];
    require(count <= maxPiiFindings && count <= (maxAnnotationPayload - 7) / 9 &&
        bytes.length == 7 + count * 9, "invalid finding count or length");
    PiiFinding[] findings;
    size_t at = 7;
    foreach (_; 0 .. count) {
        auto start = get32(bytes, at);
        auto end = get32(bytes, at);
        require(start < end && end <= contentLength, "invalid finding span");
        auto finding = fromRule(bytes[at++], start, end, locale);
        require(findings.length == 0 || ordered(findings[$ - 1], finding),
            "findings not strictly ordered");
        findings ~= finding;
    }
    return findings;
}

/// Scan each document once; C01 publishes only after the complete shard passes.
void publishPiiFindings(string shardPath, string overlayPath, string locale,
        PublishFault fault = null) {
    auto analyzerVersion = piiAnalyzerVersion(locale);
    auto reader = new DocumentShardReader(shardPath);
    scope(exit) reader.closeReader();
    auto writer = new OverlayWriter(overlayPath, shardPath, piiAnalyzerKey, analyzerVersion);
    scope(failure) writer.abort();
    ShardDocument source;
    while (reader.next(source)) {
        auto findings = scanPii(source.content, locale);
        auto encoded = encodePiiFindings(findings, locale, source.content.length);
        writer.append(AnnotationRecord(source.id.text, source.contentDigest,
            [AnnotationField(piiFieldKey, encoded)]));
    }
    writer.publish(fault);
}

/// Callback sees only identity and typed findings; never raw source content.
void visitPiiFindings(string shardPath, string overlayPath, string locale,
        scope void delegate(string documentId, PiiFinding[] findings) visit) {
    auto analyzerVersion = piiAnalyzerVersion(locale);
    auto reader = new OverlayReader(overlayPath);
    scope(exit) reader.closeReader();
    require(reader.header.analyzerKey == piiAnalyzerKey &&
        reader.header.analyzerVersion == analyzerVersion, "conflicting analyzer version");
    reader.closeReader();
    joinShards(shardPath, [overlayPath], (ShardDocument source, JoinedOverlay[] joined) {
        require(joined.length == 1 && joined[0].present &&
            joined[0].fields.length == 1 && joined[0].fields[0].key == piiFieldKey,
            "missing or malformed finding annotation");
        visit(source.id.text, decodePiiFindings(joined[0].fields[0].value,
            locale, source.content.length));
    });
}
