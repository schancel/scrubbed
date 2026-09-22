/// Pure decisions over validated four-class PII findings and original UTF-8 bytes.
module domain.pii_policy;

import domain.pii_patterns : PiiCategory, PiiConfidence, PiiFinding,
    maxPiiFindings, maxPiiInputBytes;
import std.utf : validate;

enum PiiPolicy { report, mask, redact }
enum PiiRule { emailAsciiDomain, phoneNational, phoneInternational, cardLuhn, ipv4 }
enum PiiLocale { us, gb }
enum PiiOutcome { reported, masked, redacted }

struct PiiAuditContributor {
    size_t start;
    size_t end;
    PiiCategory category;
    PiiRule rule;
    PiiLocale locale;
    PiiConfidence confidence;
}

/// One maximal overlapping union. Adjacent spans form separate records.
struct PiiAuditSpan {
    size_t start;
    size_t end;
    PiiAuditContributor[] contributors;
    PiiOutcome outcome;
}

struct PiiPolicyResult {
    ubyte[] output;
    PiiPolicy policy;
    PiiAuditSpan[] audit;
}

class PiiPolicyException : Exception {
    this(string reason) { super("pii policy: " ~ reason); }
}

private PiiLocale localeCode(string locale) {
    if (locale == "US") return PiiLocale.us;
    if (locale == "GB") return PiiLocale.gb;
    throw new PiiPolicyException("unsupported locale");
}

private PiiRule ruleCode(PiiFinding finding) {
    switch (finding.category) {
    case PiiCategory.email:
        if (finding.rule == "email.ascii-domain.v1" &&
            finding.confidence == PiiConfidence.high) return PiiRule.emailAsciiDomain;
        break;
    case PiiCategory.phone:
        if (finding.rule == "phone.national.ambiguous.v1" &&
            finding.confidence == PiiConfidence.ambiguous) return PiiRule.phoneNational;
        if (finding.rule == "phone.international.v1" &&
            finding.confidence == PiiConfidence.high) return PiiRule.phoneInternational;
        break;
    case PiiCategory.card:
        if (finding.rule == "card.luhn.ambiguous.v1" &&
            finding.confidence == PiiConfidence.ambiguous) return PiiRule.cardLuhn;
        break;
    case PiiCategory.ip:
        if (finding.rule == "ip.v4.v1" &&
            finding.confidence == PiiConfidence.high) return PiiRule.ipv4;
        break;
    default:
        break;
    }
    throw new PiiPolicyException("unsupported rule or confidence");
}

private bool boundary(const(ubyte)[] bytes, size_t at) {
    return at == 0 || at == bytes.length || (bytes[at] & 0xc0) != 0x80;
}

private bool ordered(PiiFinding a, PiiFinding b) {
    return a.start < b.start || (a.start == b.start &&
        (a.end < b.end || (a.end == b.end && a.category < b.category)));
}

/// Copies output; never mutates source or findings. Throws fixed, content-free diagnostics.
PiiPolicyResult applyPiiPolicy(const(ubyte)[] source,
        const(PiiFinding)[] findings, PiiPolicy policy,
        bool allowRedact = false) {
    if (policy != PiiPolicy.report && policy != PiiPolicy.mask &&
        policy != PiiPolicy.redact) throw new PiiPolicyException("unsupported policy");
    if (policy == PiiPolicy.redact && !allowRedact)
        throw new PiiPolicyException("redact requires opt-in");
    if (source.length > maxPiiInputBytes) throw new PiiPolicyException("input exceeds cap");
    if (findings.length > maxPiiFindings) throw new PiiPolicyException("findings exceed cap");
    try validate(cast(string) source);
    catch (Exception) throw new PiiPolicyException("invalid UTF-8");

    PiiPolicyResult result;
    result.policy = policy;
    PiiOutcome outcome = policy == PiiPolicy.report ? PiiOutcome.reported :
        policy == PiiPolicy.mask ? PiiOutcome.masked : PiiOutcome.redacted;
    foreach (i, finding; findings) {
        if (finding.start >= finding.end || finding.end > source.length ||
            !boundary(source, finding.start) || !boundary(source, finding.end))
            throw new PiiPolicyException("invalid finding span");
        if (i > 0 && !ordered(findings[i - 1], finding))
            throw new PiiPolicyException("findings not strictly ordered");
        auto locale = localeCode(finding.locale);
        auto rule = ruleCode(finding);
        auto contributor = PiiAuditContributor(finding.start, finding.end,
            finding.category, rule, locale, finding.confidence);
        if (result.audit.length == 0 || finding.start >= result.audit[$ - 1].end) {
            result.audit ~= PiiAuditSpan(finding.start, finding.end, [contributor], outcome);
        } else {
            auto span = &result.audit[$ - 1];
            if (finding.end > span.end) span.end = finding.end;
            span.contributors ~= contributor;
        }
    }

    if (policy == PiiPolicy.redact) {
        enum marker = cast(const(ubyte)[]) "[REDACTED]";
        size_t cursor;
        foreach (span; result.audit) {
            result.output ~= source[cursor .. span.start];
            result.output ~= marker;
            cursor = span.end;
        }
        result.output ~= source[cursor .. $];
    } else {
        result.output = source.dup;
        if (policy == PiiPolicy.mask)
            foreach (span; result.audit)
                foreach (at; span.start .. span.end) result.output[at] = '*';
    }
    return result;
}
