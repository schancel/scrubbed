# Four-class PII pipeline evidence

The opt-in `pii-four-class` terminal stage
([pii-four-class-stage.md](pii-four-class-stage.md)) handles four bounded
pattern classes: email, US/GB phone, Luhn-valid payment-card candidates, and
IPv4.

- `report` preserves the source bytes.
- `mask` replaces each matched byte with `*`.
- `redact`, explicitly enabled, replaces each maximal overlap union with
  `[REDACTED]`.
- Every enabled policy emits a content-free, revision-bound audit side
  output.
- Omitting the stage is the disabled control.

This is deterministic pattern handling, not complete de-identification. It
does not detect names, street addresses, or other free-form identifiers; it
is not Presidio or model-backed NER; and the evidence makes no speed,
streaming, or detector-fusion claim. Downstream users must choose policy and
review the remaining disclosure risk for their corpus.

## Bounded release evidence

[`benchmarks/pii-pipeline.json`](../benchmarks/pii-pipeline.json) is one
local O3/release observation.

- Fixtures are authored at exactly 1 MiB: a clean fixture and a
  finding-heavy fixture with exactly 4,096 email findings.
- The report records disabled/report/mask/redact wall time, direct-child
  user/system CPU, peak RSS, exact input/output/audit byte counts and
  SHA-256 identities, compiler and flags, source and binary identities, and
  D-runtime GC-only allocation and collection evidence.
- Unsupported total-process allocation and cross-platform performance
  metrics are stated as unsupported, not represented as zero.
- Byte counts and content hashes are exact. Variable wall/CPU measurements
  must stay within 300 seconds and a symmetric 20x-plus-one-second
  fresh-rerun envelope; peak RSS must stay below 8 GiB and within a
  symmetric 4x-plus-256-MiB fresh-rerun envelope. D-runtime GC evidence is
  rerun exactly. These are deliberately broad integrity bounds against
  fabricated extremes, not a performance guarantee.
- Tree sidecar manifest digests canonicalize only the root-derived
  `document_id` to zeros; every other audit byte and the original byte
  count stays bound.
- The lowercase 40-hex `source_revision` identifies the evidence source used
  for both the target and the checker. Generation builds only from its exact
  Git archive in private scratch.
- The receipt binds that archive and immutable tree, the DUB recipe and
  lock, compiler and build-tool executables/versions, build arguments,
  normalization tools, and the final artifact hash.
- On Darwin the build strips debug data, replaces the Mach-O UUID with the
  receipt's fixed value, and applies a fresh ad-hoc signature; an ordinary
  `dub build` is not claimed to produce the same bytes.

The same actual release binary also proves CLI/JSON configuration
equivalence, `--validate`, `--dry-run`, `--explain`, local-tree and
selected-field JSONL routes, exact one/four-thread results, durable
stale-sidecar refusal and retry, and content canaries across output, audit,
and diagnostic channels.

The strict checker:

1. Repeats the archived-source build and requires its normalized bytes and
   receipt to match.
2. Reruns the exact 2-by-4 deterministic byte/hash matrix and the complete
   bounded actual-binary route matrix, in fresh owner-only scratch, against
   the named artifact. Two strict checks run concurrently as the
   scratch-isolation regression.
3. Requires complete sorted four-file primary and sidecar manifests for one
   and four threads.
4. Applies every privacy canary separately to dry, explain, and
   stale-durable diagnostics.
5. Mutates every binding named by the evidence contract — revision/tree,
   fixture/policy uniqueness, bytes, output, configuration, document,
   analyzer, policy, contributor ordering and cardinality, privacy,
   malformed/oversize audit, and stale-sidecar status.

Compile the checker at the frozen source commit. Generation requires a new
artifact path and both builds and measures that exact artifact. Keep the
generated artifact for later strict checking; it's intentionally not
committed:

```sh
ldc2 -O3 -release benchmarks/pii_pipeline_check.d \
  -of=.dub/pii-pipeline-check
mkdir -p .dub/pii-pipeline-artifact
.dub/pii-pipeline-check --generate benchmarks/pii-pipeline.json \
  .dub/pii-pipeline-artifact/scrubbed
.dub/pii-pipeline-check --check benchmarks/pii-pipeline.json \
  .dub/pii-pipeline-artifact/scrubbed
```

## Exact synthetic handoff for #62

The report's `handoff` object is a machine-readable packet: CC0-1.0,
canonical authored-synthetic provenance, exact executable/argument vector
and stdin, expected JSONL stdout and transformed bytes, canonical audit
bytes, and their SHA-256 identities.

The checker executes that bounded packet with the named binary and requires
byte-for-byte stdout and audit equality. It uses a stable JSONL
namespace/source key, so the audit document ID is reproducible.

This ticket deliberately does not copy the packet into `examples/**`; #62
owns that public example landing.
