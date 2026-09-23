/// Revision-bound C01 annotations for pure four-class PII policy decisions.
module effects.pii_policy_overlay;

import core.stdc.errno : errno, ENOENT;
import core.sys.posix.fcntl : open, O_NOFOLLOW, O_RDONLY;
import core.sys.posix.sys.stat : fstat, lstat, stat_t, S_ISREG;
import core.sys.posix.unistd : close;
import domain.pii_patterns : PiiCategory, PiiConfidence, PiiFinding, maxPiiFindings;
import domain.pii_policy : PiiAuditContributor, PiiAuditSpan, PiiLocale,
    PiiOutcome, PiiPolicy, PiiPolicyResult, PiiRule, applyPiiPolicy;
import domain.shard_format : AnnotationField, AnnotationRecord, ShardDocument,
    maxAnnotationPayload;
import effects.document_shards : DocumentShardReader, JoinedOverlay,
    OverlayReader, OverlayWriter, PublishFault, joinShards, shardDigest;
import effects.pii_overlay : decodePiiFindings, piiAnalyzerKey,
    piiAnalyzerVersion, piiFieldKey;
import crypto.sha256 : sha256Of;
import std.exception : enforce;
import std.string : toStringz;

enum piiPolicyAnalyzerKey = "pii.policy";
enum piiPolicyFieldKey = "decision";
private enum ubyte[] valueTag = cast(ubyte[]) "PIP1";

private void require(bool okay, string reason) {
    enforce(okay, "pii policy overlay: " ~ reason);
}

private ubyte policyCode(PiiPolicy policy) {
    switch (policy) {
    case PiiPolicy.report: return 1;
    case PiiPolicy.mask: return 2;
    case PiiPolicy.redact: return 3;
    default: throw new Exception("pii policy overlay: invalid policy code");
    }
}
private PiiPolicy policyFromCode(ubyte code) {
    switch (code) {
    case 1: return PiiPolicy.report;
    case 2: return PiiPolicy.mask;
    case 3: return PiiPolicy.redact;
    default: throw new Exception("pii policy overlay: invalid policy code");
    }
}
private ubyte localeCode(string locale) {
    if (locale == "US") return 1;
    if (locale == "GB") return 2;
    throw new Exception("pii policy overlay: unsupported locale");
}
private PiiLocale localeFromCode(ubyte code) {
    switch (code) {
    case 1: return PiiLocale.us;
    case 2: return PiiLocale.gb;
    default: throw new Exception("pii policy overlay: invalid locale code");
    }
}
private PiiOutcome outcomeFor(PiiPolicy policy) {
    return policy == PiiPolicy.report ? PiiOutcome.reported :
        policy == PiiPolicy.mask ? PiiOutcome.masked : PiiOutcome.redacted;
}
private ubyte ruleCode(PiiRule rule) {
    switch (rule) {
    case PiiRule.emailAsciiDomain: return 1;
    case PiiRule.phoneNational: return 2;
    case PiiRule.phoneInternational: return 3;
    case PiiRule.cardLuhn: return 4;
    case PiiRule.ipv4: return 5;
    default: throw new Exception("pii policy overlay: invalid rule code");
    }
}
private PiiAuditContributor contributorFromCode(size_t start, size_t end,
        ubyte code, PiiLocale locale) {
    switch (code) {
    case 1: return PiiAuditContributor(start, end, PiiCategory.email,
        PiiRule.emailAsciiDomain, locale, PiiConfidence.high);
    case 2: return PiiAuditContributor(start, end, PiiCategory.phone,
        PiiRule.phoneNational, locale, PiiConfidence.ambiguous);
    case 3: return PiiAuditContributor(start, end, PiiCategory.phone,
        PiiRule.phoneInternational, locale, PiiConfidence.high);
    case 4: return PiiAuditContributor(start, end, PiiCategory.card,
        PiiRule.cardLuhn, locale, PiiConfidence.ambiguous);
    case 5: return PiiAuditContributor(start, end, PiiCategory.ip,
        PiiRule.ipv4, locale, PiiConfidence.high);
    default: throw new Exception("pii policy overlay: invalid rule code");
    }
}
private bool ordered(PiiAuditContributor previous,
        PiiAuditContributor current) {
    return previous.start < current.start ||
        (previous.start == current.start &&
            (previous.end < current.end ||
             (previous.end == current.end && previous.category < current.category)));
}
private void put16(ref ubyte[] bytes, size_t value) {
    require(value <= ushort.max, "audit count exceeds encoding");
    bytes ~= cast(ubyte)(value >> 8);
    bytes ~= cast(ubyte)value;
}
private void put32(ref ubyte[] bytes, size_t value) {
    require(value <= uint.max, "audit span exceeds encoding");
    foreach_reverse (shift; [0, 8, 16, 24]) bytes ~= cast(ubyte)(value >> shift);
}
private size_t get16(const(ubyte)[] bytes, ref size_t at) {
    require(at <= bytes.length && bytes.length - at >= 2, "truncated audit");
    size_t value = (cast(size_t)bytes[at] << 8) | bytes[at + 1];
    at += 2;
    return value;
}
private size_t get32(const(ubyte)[] bytes, ref size_t at) {
    require(at <= bytes.length && bytes.length - at >= 4, "truncated audit");
    size_t value;
    foreach (_; 0 .. 4) value = (value << 8) | bytes[at++];
    return value;
}

/// Canonical v1: tag, policy, locale, SHA-256 output digest, BE u16 union count;
/// each union has BE u32 half-open bounds, BE u16 contributor count, then
/// each contributor has BE u32 bounds and one finite rule code. Rule implies
/// category and confidence; locale is shared by the complete record.
ubyte[] encodePiiPolicyValue(PiiPolicyResult result, string locale) {
    auto localeByte = localeCode(locale);
    auto policyByte = policyCode(result.policy);
    require(result.audit.length <= maxPiiFindings, "audit exceeds cap");
    ubyte[] bytes = valueTag.dup;
    bytes ~= policyByte;
    bytes ~= localeByte;
    bytes ~= sha256Of(result.output)[];
    put16(bytes, result.audit.length);
    size_t priorEnd;
    size_t contributors;
    foreach (index, span; result.audit) {
        require(span.start < span.end && (index == 0 || priorEnd <= span.start) &&
            span.outcome == outcomeFor(result.policy) &&
            span.contributors.length > 0, "invalid union audit");
        put32(bytes, span.start);
        put32(bytes, span.end);
        put16(bytes, span.contributors.length);
        size_t maximum;
        PiiAuditContributor previous;
        foreach (j, contributor; span.contributors) {
            require(contributor.start >= span.start && contributor.end <= span.end &&
                contributor.start < contributor.end &&
                contributor.locale == localeFromCode(localeByte) &&
                (j == 0 || (contributor.start < maximum &&
                    ordered(previous, contributor))), "invalid contributor audit");
            if (j == 0) require(contributor.start == span.start, "invalid union start");
            if (contributor.end > maximum) maximum = contributor.end;
            auto code = ruleCode(contributor.rule);
            auto canonical = contributorFromCode(contributor.start,
                contributor.end, code, contributor.locale);
            require(contributor == canonical, "invalid contributor metadata");
            put32(bytes, contributor.start);
            put32(bytes, contributor.end);
            bytes ~= code;
            previous = contributor;
            ++contributors;
            require(bytes.length <= maxAnnotationPayload, "annotation exceeds frame cap");
        }
        require(maximum == span.end, "invalid union end");
        priorEnd = span.end;
    }
    require(contributors <= maxPiiFindings, "audit exceeds cap");
    // C01's outer annotation contains the fixed-width ID, digest, field key,
    // and value length in addition to these opaque value bytes.
    enum envelope = 2 + 71 + 32 + 2 + 2 + piiPolicyFieldKey.length + 4;
    require(bytes.length <= maxAnnotationPayload - envelope,
        "annotation exceeds frame cap");
    return bytes;
}

struct PiiPolicyAnnotation {
    PiiPolicy policy;
    PiiLocale locale;
    ubyte[32] outputDigest;
    PiiAuditSpan[] audit;
}

PiiPolicyAnnotation decodePiiPolicyValue(const(ubyte)[] bytes) {
    require(bytes.length >= 40 && bytes[0 .. 4] == valueTag,
        "invalid policy value tag");
    PiiPolicyAnnotation decoded;
    decoded.policy = policyFromCode(bytes[4]);
    decoded.locale = localeFromCode(bytes[5]);
    decoded.outputDigest[] = bytes[6 .. 38];
    size_t at = 38;
    auto count = get16(bytes, at);
    require(count <= maxPiiFindings && count <= (bytes.length - at) / 19,
        "invalid union count");
    size_t priorEnd;
    size_t total;
    foreach (i; 0 .. count) {
        auto start = get32(bytes, at);
        auto end = get32(bytes, at);
        auto n = get16(bytes, at);
        require(start < end && (i == 0 || priorEnd <= start) &&
            n > 0 && n <= maxPiiFindings - total &&
            n <= (bytes.length - at) / 9, "invalid union audit");
        PiiAuditSpan span;
        span.start = start;
        span.end = end;
        span.outcome = outcomeFor(decoded.policy);
        size_t maximum;
        PiiAuditContributor previous;
        foreach (j; 0 .. n) {
            auto cStart = get32(bytes, at);
            auto cEnd = get32(bytes, at);
            auto code = bytes[at++];
            auto contributor = contributorFromCode(cStart, cEnd, code,
                decoded.locale);
            require(cStart >= start && cEnd <= end && cStart < cEnd &&
                (j == 0 ? cStart == start :
                    (cStart < maximum && ordered(previous, contributor))),
                "invalid contributor audit");
            if (cEnd > maximum) maximum = cEnd;
            span.contributors ~= contributor;
            previous = contributor;
        }
        require(maximum == end, "invalid union end");
        decoded.audit ~= span;
        total += n;
        priorEnd = end;
    }
    require(at == bytes.length, "trailing policy value bytes");
    return decoded;
}

string piiPolicyAnalyzerVersion(string locale, PiiPolicy policy) {
    localeCode(locale);
    policyCode(policy);
    return "policy:v1:findings=" ~ piiAnalyzerVersion(locale) ~
        ":decision=" ~ (policy == PiiPolicy.report ? "report" :
            policy == PiiPolicy.mask ? "mask" : "redact");
}

private bool sameFile(string left, string right) {
    auto a = open(left.toStringz, O_RDONLY | O_NOFOLLOW);
    require(a >= 0, "cannot inspect input");
    scope(exit) close(a);
    auto b = open(right.toStringz, O_RDONLY | O_NOFOLLOW);
    require(b >= 0, "cannot inspect input");
    scope(exit) close(b);
    stat_t ai, bi;
    require(fstat(a, &ai) == 0 && fstat(b, &bi) == 0 &&
        S_ISREG(ai.st_mode) && S_ISREG(bi.st_mode), "nonregular input");
    return ai.st_dev == bi.st_dev && ai.st_ino == bi.st_ino;
}

private void checkPaths(string shardPath, string findingsPath,
        string destination) {
    require(!sameFile(shardPath, findingsPath), "source aliases findings");
    stat_t target;
    if (lstat(destination.toStringz, &target) == 0) {
        require(S_ISREG(target.st_mode) && target.st_nlink == 1,
            "unsafe destination");
        require(!sameFile(destination, shardPath) &&
            !sameFile(destination, findingsPath), "destination aliases input");
    } else require(errno == ENOENT, "cannot inspect destination");
}

private void checkFindingsHeader(string shardPath, string findingsPath,
        string locale) {
    auto reader = new OverlayReader(findingsPath);
    scope(exit) reader.closeReader();
    require(reader.header.analyzerKey == piiAnalyzerKey &&
        reader.header.analyzerVersion == piiAnalyzerVersion(locale) &&
        reader.header.sourceShardDigest == shardDigest(shardPath),
        "stale or wrong-version findings");
}

private void checkDestination(string shardPath, string destination,
        string expectedVersion) {
    stat_t target;
    if (lstat(destination.toStringz, &target) != 0) {
        require(errno == ENOENT, "cannot inspect destination");
        return;
    }
    auto existing = new OverlayReader(destination);
    scope(exit) existing.closeReader();
    require(existing.header.analyzerKey == piiPolicyAnalyzerKey &&
        existing.header.analyzerVersion == expectedVersion &&
        existing.header.sourceShardDigest == shardDigest(shardPath),
        "destination belongs to another policy or shard");
}

private PiiFinding[] findingsFor(ShardDocument source,
        JoinedOverlay[] joined, string locale) {
    require(joined.length == 1 && joined[0].analyzerKey == piiAnalyzerKey &&
        joined[0].analyzerVersion == piiAnalyzerVersion(locale) &&
        joined[0].present && joined[0].fields.length == 1 &&
        joined[0].fields[0].key == piiFieldKey,
        "missing or wrong-version findings");
    return decodePiiFindings(joined[0].fields[0].value, locale,
        source.content.length);
}

/// Validates every finding before atomic C01 publication. Existing policy
/// destinations may be replaced only by the same policy/locale/shard owner.
void publishPiiPolicy(string shardPath, string findingsPath,
        string destination, string locale, PiiPolicy policy,
        bool allowRedact = false, PublishFault fault = null) {
    auto expectedVersion = piiPolicyAnalyzerVersion(locale, policy);
    require(policy != PiiPolicy.redact || allowRedact, "redact requires opt-in");
    checkPaths(shardPath, findingsPath, destination);
    checkFindingsHeader(shardPath, findingsPath, locale);
    checkDestination(shardPath, destination, expectedVersion);
    auto writer = new OverlayWriter(destination, shardPath,
        piiPolicyAnalyzerKey, expectedVersion);
    scope(failure) writer.abort();
    joinShards(shardPath, [findingsPath], (ShardDocument source,
            JoinedOverlay[] joined) {
        auto findings = findingsFor(source, joined, locale);
        auto result = applyPiiPolicy(source.content, findings, policy, allowRedact);
        auto value = encodePiiPolicyValue(result, locale);
        writer.append(AnnotationRecord(source.id.text, source.contentDigest,
            [AnnotationField(piiPolicyFieldKey, value)]));
    });
    writer.publish(fault);
}

/// Streams verified outputs; each callback follows validation of that record.
/// The callback is explicit because policy outputs are never stored by C01.
void visitPiiPolicy(string shardPath, string findingsPath,
        string policyPath, string locale, PiiPolicy policy, bool allowRedact,
        scope void delegate(string documentId, PiiPolicyResult result) visit) {
    auto expectedVersion = piiPolicyAnalyzerVersion(locale, policy);
    require(policy != PiiPolicy.redact || allowRedact, "redact requires opt-in");
    checkPaths(shardPath, findingsPath, policyPath);
    checkFindingsHeader(shardPath, findingsPath, locale);
    auto policyReader = new OverlayReader(policyPath);
    scope(exit) policyReader.closeReader();
    require(policyReader.header.analyzerKey == piiPolicyAnalyzerKey &&
        policyReader.header.analyzerVersion == expectedVersion &&
        policyReader.header.sourceShardDigest == shardDigest(shardPath),
        "stale or wrong-version policy");
    joinShards(shardPath, [findingsPath], (ShardDocument source,
            JoinedOverlay[] joined) {
        auto findings = findingsFor(source, joined, locale);
        AnnotationRecord record;
        require(policyReader.next(record) &&
            record.documentId == source.id.text &&
            record.contentDigest == source.contentDigest &&
            record.fields.length == 1 &&
            record.fields[0].key == piiPolicyFieldKey,
            "missing or stale policy annotation");
        auto stored = decodePiiPolicyValue(record.fields[0].value);
        require(stored.policy == policy &&
            stored.locale == localeFromCode(localeCode(locale)),
            "wrong policy annotation");
        auto result = applyPiiPolicy(source.content, findings, policy, allowRedact);
        require(encodePiiPolicyValue(result, locale) == record.fields[0].value,
            "policy replay mismatch");
        visit(source.id.text, result);
    });
    AnnotationRecord extra;
    require(!policyReader.next(extra), "orphan policy annotation");
}
