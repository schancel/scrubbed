/// Opt-in, revision-bound C01 persistence for four-class PII findings.
module effects.pii_overlay;

import domain.pii_patterns;
import domain.shard_format : AnnotationField, AnnotationRecord, ShardDocument,
    maxAnnotationPayload;
import effects.document_shards : DocumentShardReader, OverlayReader, OverlayWriter,
    PublishFault, shardDigest;
import core.stdc.errno : errno, ENOENT;
import core.sys.posix.sys.stat : lstat, stat_t;
import std.exception : enforce;
import std.string : toStringz;
import std.utf : validate;

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
    // C01 protects the destination inode and immutable source. A regular
    // existing overlay is replaceable only when it belongs to this analyzer
    // and exact source shard. This prevents overwriting another analyzer's
    // otherwise-safe single-link file. The output directory has one writer.
    stat_t targetInfo;
    if (lstat(overlayPath.toStringz, &targetInfo) == 0) {
        auto existing = new OverlayReader(overlayPath);
        scope(exit) existing.closeReader();
        require(existing.header.analyzerKey == piiAnalyzerKey &&
            existing.header.sourceShardDigest == shardDigest(shardPath),
            "destination belongs to another analyzer or shard");
        existing.closeReader();
    } else require(errno == ENOENT, "cannot inspect destination");
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
    auto overlay = new OverlayReader(overlayPath);
    scope(exit) overlay.closeReader();
    require(overlay.header.analyzerKey == piiAnalyzerKey &&
        overlay.header.analyzerVersion == analyzerVersion &&
        overlay.header.sourceShardDigest == shardDigest(shardPath),
        "conflicting analyzer version or source shard");
    // Keep the validated overlay descriptor open throughout replay. Reopening
    // by path after a separate header check could consume a different version
    // following a legitimate atomic rename, especially on an empty shard.
    auto documents = new DocumentShardReader(shardPath);
    scope(exit) documents.closeReader();
    ShardDocument source;
    AnnotationRecord annotation;
    while (documents.next(source)) {
        require(source.content.length <= maxPiiInputBytes,
            "source exceeds scanner cap");
        try validate(cast(string) source.content);
        catch (Exception) throw new Exception("pii overlay: invalid UTF-8 source");
        require(overlay.next(annotation) &&
            annotation.documentId == source.id.text &&
            annotation.contentDigest == source.contentDigest,
            "missing, orphan, or stale finding annotation");
        require(annotation.fields.length == 1 &&
            annotation.fields[0].key == piiFieldKey,
            "missing or malformed finding annotation");
        visit(source.id.text, decodePiiFindings(annotation.fields[0].value,
            locale, source.content.length));
    }
    require(!overlay.next(annotation), "orphan finding annotation");
}
