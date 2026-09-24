/// Effects-layer facade for the canonical content-free PII audit value.
module effects.pii_audit;

// The pure terminal stage owns encoding so stages never depend upward on
// effects. Publication adapters consume this facade without duplicating the
// schema or introducing a process-global callback.
public import stages.pii_four_class : PiiAuditOptionsV1, encodePiiAuditV1,
    maxPiiAuditBytesV1, piiAnalyzerNameV1, piiAnalyzerVersionV1,
    piiAuditKeyV1, piiAuditSchemaV1, piiAuditSinkV1, piiAuditSuffixV1,
    piiPolicyVersionV1;
