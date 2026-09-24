/// Self-registering terminal four-class PII stage and content-free audit.
module stages.pii_four_class;

import content.pieces : Content, ContentPiece;
import crypto.sha256 : sha256Of;
import domain.document : DocumentId;
import domain.pii_patterns : PiiCategory, PiiConfidence, PiiFinding,
    maxPiiFindings, maxPiiInputBytes, scanPii;
import domain.pii_policy : PiiAuditSpan, PiiLocale, PiiOutcome, PiiPolicy,
    PiiPolicyResult, PiiRule, applyPiiPolicy;
import stages.contract : PassMode, ResourceDeclaration, StageDecision,
    StageDeclaration, StageDocument, TerminalSideOutput;
import stages.registry : ConfiguredStageTransform, FilterPlacement,
    OptionDeclaration, OptionType, SideOutputCapability, StageCardinality,
    StageConfiguration, StageOptions, StageRegistration, registerStage;
import std.array : split;
import std.conv : to;
import std.digest : LetterCase, toHexString;
import std.exception : enforce;

enum piiAuditSchemaV1 = "scrubbed-pii-audit-v1";
enum piiAuditKeyV1 = "pii-audit";
enum piiAuditSuffixV1 = ".pii-audit.json";
enum piiAuditSinkV1 = "sidecar-json-v1";
enum piiAnalyzerNameV1 = "pii.four-class";
enum piiAnalyzerVersionV1 = "four-class:v1";
enum piiPolicyVersionV1 = "pii-policy:v1";
enum size_t maxPiiAuditBytesV1 = 1024 * 1024;

/// Already-normalized finite configuration. The stage factory owns validation.
struct PiiAuditOptionsV1 {
    string locale;
    string policy;
    string categories;
    string confidences;
    size_t maxInputBytes;
    size_t maxFindings;
    string auditSink;
    bool allowRedact;
}

private string hexDigest(ubyte[32] digest) pure {
    return toHexString!(LetterCase.lower)(digest).idup;
}

private string categoryName(PiiCategory value) pure {
    final switch (value) {
    case PiiCategory.email: return "email";
    case PiiCategory.phone: return "phone";
    case PiiCategory.card: return "card";
    case PiiCategory.ip: return "ip";
    }
}

private string confidenceName(PiiConfidence value) pure {
    final switch (value) {
    case PiiConfidence.high: return "high";
    case PiiConfidence.ambiguous: return "ambiguous";
    }
}

private string ruleName(PiiRule value) pure {
    final switch (value) {
    case PiiRule.emailAsciiDomain: return "email.ascii-domain.v1";
    case PiiRule.phoneNational: return "phone.national.ambiguous.v1";
    case PiiRule.phoneInternational: return "phone.international.v1";
    case PiiRule.cardLuhn: return "card.luhn.ambiguous.v1";
    case PiiRule.ipv4: return "ip.v4.v1";
    }
}

private string localeName(PiiLocale value) pure {
    final switch (value) {
    case PiiLocale.us: return "US";
    case PiiLocale.gb: return "GB";
    }
}

private string outcomeName(PiiOutcome value) pure {
    final switch (value) {
    case PiiOutcome.reported: return "reported";
    case PiiOutcome.masked: return "masked";
    case PiiOutcome.redacted: return "redacted";
    }
}

private bool validContributor(const ref PiiAuditSpan span, size_t index,
        string configuredLocale) pure {
    auto contributor = span.contributors[index];
    if (contributor.start < span.start || contributor.start >= contributor.end ||
            contributor.end > span.end || localeName(contributor.locale) != configuredLocale)
        return false;
    if (index) {
        auto prior = span.contributors[index - 1];
        if (!(prior.start < contributor.start ||
                prior.start == contributor.start &&
                    (prior.end < contributor.end ||
                    prior.end == contributor.end &&
                        prior.category < contributor.category)))
            return false;
    }
    final switch (contributor.category) {
    case PiiCategory.email:
        return contributor.rule == PiiRule.emailAsciiDomain &&
            contributor.confidence == PiiConfidence.high;
    case PiiCategory.phone:
        return contributor.rule == PiiRule.phoneNational &&
                contributor.confidence == PiiConfidence.ambiguous ||
            contributor.rule == PiiRule.phoneInternational &&
                contributor.confidence == PiiConfidence.high;
    case PiiCategory.card:
        return contributor.rule == PiiRule.cardLuhn &&
            contributor.confidence == PiiConfidence.ambiguous;
    case PiiCategory.ip:
        return contributor.rule == PiiRule.ipv4 &&
            contributor.confidence == PiiConfidence.high;
    }
}

/// Encode only identity, revision/policy bindings and typed offsets/enums.
/// No input bytes or caller-provided exception strings enter this record.
immutable(ubyte)[] encodePiiAuditV1(DocumentId documentId,
        const(ubyte)[] input, const(ubyte)[] output,
        const(PiiAuditSpan)[] audit, const ref PiiAuditOptionsV1 options) pure {
    enforce(documentId.text.length != 0, "pii audit: document ID is required");
    enforce(options.locale == "US" || options.locale == "GB",
        "pii audit: invalid locale");
    enforce(options.policy == "report" || options.policy == "mask" ||
        options.policy == "redact", "pii audit: invalid policy");
    enforce(options.auditSink == piiAuditSinkV1, "pii audit: invalid sink");

    size_t contributorCount;
    auto expectedOutcome = options.policy == "report" ? "reported" :
        options.policy == "mask" ? "masked" : "redacted";
    foreach (spanIndex, span; audit) {
        enforce(span.start < span.end && span.end <= input.length,
            "pii audit: invalid union");
        enforce(spanIndex == 0 || span.start >= audit[spanIndex - 1].end,
            "pii audit: unions are not ordered");
        enforce(span.contributors.length != 0 &&
            outcomeName(span.outcome) == expectedOutcome,
            "pii audit: invalid union metadata");
        size_t contributorEnd;
        foreach (index; 0 .. span.contributors.length) {
            enforce(validContributor(span, index, options.locale),
                "pii audit: invalid contributor");
            if (span.contributors[index].end > contributorEnd)
                contributorEnd = span.contributors[index].end;
        }
        enforce(span.contributors[0].start == span.start &&
            contributorEnd == span.end, "pii audit: union is not maximal");
        enforce(span.contributors.length <= size_t.max - contributorCount,
            "pii audit: contributor count overflow");
        contributorCount += span.contributors.length;
    }
    // With bounded input offsets and finite enums, a contributor encodes to
    // fewer than 144 bytes and a union envelope to fewer than 80 bytes.
    // Reject this conservative upper bound before building the final JSON.
    enforce(audit.length <= (maxPiiAuditBytesV1 - 2048) / 80 &&
        contributorCount <= (maxPiiAuditBytesV1 - 2048 - audit.length * 80) / 144,
        "pii audit: output exceeds cap");

    string encoded = `{"schema":"` ~ piiAuditSchemaV1 ~
        `","document_id":"` ~ documentId.text ~
        `","input_revision_sha256":"` ~ hexDigest(sha256Of(input)) ~
        `","analyzer":{"name":"` ~ piiAnalyzerNameV1 ~
        `","version":"` ~ piiAnalyzerVersionV1 ~
        `"},"policy_version":"` ~ piiPolicyVersionV1 ~
        `","options":{"locale":"` ~ options.locale ~
        `","policy":"` ~ options.policy ~
        `","categories":"` ~ options.categories ~
        `","confidences":"` ~ options.confidences ~
        `","max_input_bytes":` ~ options.maxInputBytes.to!string ~
        `,"max_findings":` ~ options.maxFindings.to!string ~
        `,"audit_sink":"` ~ options.auditSink ~
        `","allow_redact":` ~ (options.allowRedact ? "true" : "false") ~
        `},"output_sha256":"` ~ hexDigest(sha256Of(output)) ~
        `","unions":[`;
    foreach (spanIndex, span; audit) {
        if (spanIndex) encoded ~= ',';
        encoded ~= `{"start":` ~ span.start.to!string ~
            `,"end":` ~ span.end.to!string ~
            `,"outcome":"` ~ outcomeName(span.outcome) ~
            `","contributors":[`;
        foreach (contributorIndex, contributor; span.contributors) {
            if (contributorIndex) encoded ~= ',';
            encoded ~= `{"start":` ~ contributor.start.to!string ~
                `,"end":` ~ contributor.end.to!string ~
                `,"category":"` ~ categoryName(contributor.category) ~
                `","rule":"` ~ ruleName(contributor.rule) ~
                `","locale":"` ~ localeName(contributor.locale) ~
                `","confidence":"` ~ confidenceName(contributor.confidence) ~ `"}`;
        }
        encoded ~= `]}`;
    }
    encoded ~= `]}`;
    enforce(encoded.length <= maxPiiAuditBytesV1,
        "pii audit: output exceeds cap");
    return cast(immutable(ubyte)[]) encoded.idup;
}

private class PiiFourClassConfiguration : StageConfiguration {
    string locale;
    PiiPolicy policy;
    string policyName;
    bool[4] categories;
    bool[2] confidences;
    string categoryNames;
    string confidenceNames;
    size_t maxInputBytes;
    size_t maxFindings;
    bool allowRedact;

    this(string locale, PiiPolicy policy, string policyName,
            bool[4] categories, bool[2] confidences,
            string categoryNames, string confidenceNames,
            size_t maxInputBytes, size_t maxFindings,
            bool allowRedact) immutable {
        this.locale = locale;
        this.policy = policy;
        this.policyName = policyName;
        this.categories = categories;
        this.confidences = confidences;
        this.categoryNames = categoryNames;
        this.confidenceNames = confidenceNames;
        this.maxInputBytes = maxInputBytes;
        this.maxFindings = maxFindings;
        this.allowRedact = allowRedact;
    }
}

private string textOption(const ref StageOptions options,
        string key, string defaultValue) {
    auto selected = key in options;
    return selected is null ? defaultValue : selected.asText;
}

private long integerOption(const ref StageOptions options,
        string key, long defaultValue) {
    auto selected = key in options;
    return selected is null ? defaultValue : selected.asInteger;
}

private bool booleanOption(const ref StageOptions options,
        string key, bool defaultValue) {
    auto selected = key in options;
    return selected is null ? defaultValue : selected.asBoolean;
}

private bool[4] categoriesFor(string value) {
    enum names = ["email", "phone", "card", "ip"];
    bool[4] selected;
    enforce(value.length != 0, "pii-four-class: categories must not be empty");
    size_t previous;
    bool havePrevious;
    foreach (part; value.split(',')) {
        size_t index = names.length;
        foreach (candidate, name; names)
            if (part == name) index = candidate;
        enforce(index < names.length, "pii-four-class: unsupported category");
        enforce(!selected[index], "pii-four-class: duplicate category");
        enforce(!havePrevious || index > previous,
            "pii-four-class: categories are not in canonical order");
        selected[index] = true;
        previous = index;
        havePrevious = true;
    }
    return selected;
}

private bool[2] confidencesFor(string value) {
    enum names = ["high", "ambiguous"];
    bool[2] selected;
    enforce(value.length != 0, "pii-four-class: confidences must not be empty");
    size_t previous;
    bool havePrevious;
    foreach (part; value.split(',')) {
        size_t index = names.length;
        foreach (candidate, name; names)
            if (part == name) index = candidate;
        enforce(index < names.length, "pii-four-class: unsupported confidence");
        enforce(!selected[index], "pii-four-class: duplicate confidence");
        enforce(!havePrevious || index > previous,
            "pii-four-class: confidences are not in canonical order");
        selected[index] = true;
        previous = index;
        havePrevious = true;
    }
    return selected;
}

private PiiPolicy policyFor(string value) {
    if (value == "report") return PiiPolicy.report;
    if (value == "mask") return PiiPolicy.mask;
    if (value == "redact") return PiiPolicy.redact;
    throw new Exception("pii-four-class: unsupported policy");
}

// The existing domain APIs are deterministic and effects-free but predate the
// configured-stage pure function boundary. Keep that assertion local instead
// of changing their public signatures in this landing.
private PiiFinding[] scanPiiPure(const(ubyte)[] source, string locale)
        pure @trusted {
    alias PureScan = PiiFinding[] function(const(ubyte)[], string) pure;
    return (cast(PureScan) &scanPii)(source, locale);
}

private PiiPolicyResult applyPiiPolicyPure(const(ubyte)[] source,
        const(PiiFinding)[] findings, PiiPolicy policy, bool allowRedact)
        pure @trusted {
    alias PurePolicy = PiiPolicyResult function(const(ubyte)[],
        const(PiiFinding)[], PiiPolicy, bool) pure;
    return (cast(PurePolicy) &applyPiiPolicy)(source, findings, policy,
        allowRedact);
}

private ConfiguredStageTransform factory(const ref StageOptions options) {
    auto locale = textOption(options, "locale", "US");
    enforce(locale == "US" || locale == "GB",
        "pii-four-class: unsupported locale");
    auto policyName = textOption(options, "policy", "report");
    auto policy = policyFor(policyName);
    auto categoryNames = textOption(options, "categories", "email,phone,card,ip");
    auto confidenceNames = textOption(options, "confidences", "high,ambiguous");
    auto maxInput = integerOption(options, "max-input-bytes", maxPiiInputBytes);
    auto maxFindingCount = integerOption(options, "max-findings", maxPiiFindings);
    auto auditSink = textOption(options, "audit-sink", piiAuditSinkV1);
    auto allowRedact = booleanOption(options, "allow-redact", false);
    enforce(maxInput > 0 && maxInput <= maxPiiInputBytes,
        "pii-four-class: max-input-bytes is out of range");
    enforce(maxFindingCount > 0 && maxFindingCount <= maxPiiFindings,
        "pii-four-class: max-findings is out of range");
    enforce(auditSink == piiAuditSinkV1,
        "pii-four-class: unsupported audit sink");
    enforce(policy != PiiPolicy.redact || allowRedact,
        "pii-four-class: redact requires allow-redact=true");
    return ConfiguredStageTransform(&applyPiiFourClass,
        new immutable PiiFourClassConfiguration(locale, policy, policyName,
            categoriesFor(categoryNames), confidencesFor(confidenceNames),
            categoryNames, confidenceNames, cast(size_t) maxInput,
            cast(size_t) maxFindingCount, allowRedact));
}

private StageDecision applyPiiFourClass(StageDocument input,
        immutable(StageConfiguration) raw) pure {
    auto configured = cast(immutable(PiiFourClassConfiguration)) raw;
    enforce(configured !is null, "pii-four-class: invalid configuration");
    enforce(input.content.size <= configured.maxInputBytes,
        "pii-four-class: input exceeds configured cap");
    auto source = input.content.copy();
    // This is the sole scanner invocation. Selection operates on its ordered result.
    auto scanned = scanPiiPure(source, configured.locale);
    enforce(scanned.length <= configured.maxFindings,
        "pii-four-class: findings exceed configured cap");
    PiiFinding[] selected;
    foreach (finding; scanned)
        if (configured.categories[cast(size_t) finding.category] &&
                configured.confidences[cast(size_t) finding.confidence])
            selected ~= finding;
    auto result = applyPiiPolicyPure(source, selected, configured.policy,
        configured.allowRedact);
    auto auditOptions = PiiAuditOptionsV1(configured.locale,
        configured.policyName, configured.categoryNames,
        configured.confidenceNames, configured.maxInputBytes,
        configured.maxFindings, piiAuditSinkV1, configured.allowRedact);
    auto audit = encodePiiAuditV1(input.document.id, source, result.output,
        result.audit, auditOptions);
    if (configured.policy != PiiPolicy.report)
        input.content = new Content([ContentPiece.retainImmutable(result.output.idup)]);
    auto sideOutput = TerminalSideOutput(piiAuditKeyV1, piiAuditSchemaV1,
        piiAuditSuffixV1, audit);
    return StageDecision.map(input, [sideOutput]);
}

static this() {
    registerStage(StageRegistration(StageDeclaration("pii-four-class",
        PassMode.singlePass, ResourceDeclaration(1, 16 * 1024 * 1024)), [
            OptionDeclaration("locale", OptionType.text),
            OptionDeclaration("policy", OptionType.text),
            OptionDeclaration("categories", OptionType.text),
            OptionDeclaration("confidences", OptionType.text),
            OptionDeclaration("max-input-bytes", OptionType.integer),
            OptionDeclaration("max-findings", OptionType.integer),
            OptionDeclaration("audit-sink", OptionType.text),
            OptionDeclaration("allow-redact", OptionType.boolean),
        ], null, null, &factory, FilterPlacement.none,
        StageCardinality.oneToOne, SideOutputCapability.terminal));
}
