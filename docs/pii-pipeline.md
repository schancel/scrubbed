# Four-class PII pipeline evidence

The opt-in `pii-four-class` terminal stage handles four bounded pattern
classes: email, US/GB phone, Luhn-valid payment-card candidates, and IPv4.
`report` preserves the source bytes, `mask` replaces each matched byte with
`*`, and explicitly enabled `redact` replaces each maximal overlap union with
`[REDACTED]`. Every enabled policy emits a content-free, revision-bound audit
side output. Omitting the stage is the disabled control.

This is deterministic pattern handling, not complete de-identification. It
does not detect names, street addresses, or other free-form identifiers; it is
not Presidio or model-backed NER; and the evidence makes no speed, streaming,
or detector-fusion claim. Downstream users must choose policy and review the
remaining disclosure risk for their corpus.

## Bounded release evidence

[`benchmarks/pii-pipeline.json`](../benchmarks/pii-pipeline.json) is one local
O3/release observation. Its authored fixtures are exactly 1 MiB: a clean
fixture and a finding-heavy fixture with exactly 4,096 email findings. The
report records disabled/report/mask/redact wall, direct-child user/system CPU,
peak RSS, exact input/output/audit bytes and SHA-256 identities, compiler and
flags, source and binary identities, and D-runtime GC-only allocation and
collection evidence. Unsupported total-process allocation and cross-platform
performance metrics are explicit rather than represented as zero.

The same actual release binary proves CLI/JSON configuration equivalence,
`--validate`, `--dry-run`, `--explain`, local-tree and selected-field JSONL
routes, exact one/four-thread results, durable stale-sidecar refusal and retry,
and content canaries in audit and diagnostic channels. The strict checker
mutates every binding named by the evidence contract, including revision,
output, configuration, document, analyzer, policy, contributor ordering and
cardinality, privacy, malformed/oversize audit, and stale-sidecar status.

```sh
dub build --compiler=ldc2 --build=release --force
ldc2 -O3 -release benchmarks/pii_pipeline_check.d \
  -of=.dub/pii-pipeline-check
.dub/pii-pipeline-check --check benchmarks/pii-pipeline.json ./scrubbed
```

Generating a replacement report runs the bounded actual-binary matrix:

```sh
.dub/pii-pipeline-check ./scrubbed benchmarks/pii-pipeline.json
```

## Exact synthetic handoff for #62

The report's `handoff` object is the machine-readable packet: CC0-1.0,
authored-synthetic provenance, exact command, UTF-8 fixture, expected
transformed bytes, canonical audit bytes, and SHA-256 of all three. It uses a
stable JSONL namespace/source key, so the audit document ID is reproducible.
This ticket deliberately does not copy the packet into `examples/**`; #62 owns
that public example landing.
