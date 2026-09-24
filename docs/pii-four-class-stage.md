# Four-class PII terminal stage

Importing `stages.pii_four_class` registers the terminal `pii-four-class`
stage. It exposes the existing deterministic email, US/GB phone,
payment-card, and IPv4 scanner and policy APIs. It is bounded pattern handling,
not complete de-identification, name/address recognition, or model-backed NER.

The stage accepts the ordinary typed v3 stage options, and therefore the same
stage object can be used unchanged as a v4 `common` stage:

| Option | Type | Default | Accepted values |
| --- | --- | --- | --- |
| `locale` | text | `US` | `US`, `GB` |
| `policy` | text | `report` | `report`, `mask`, `redact` |
| `categories` | text | `email,phone,card,ip` | A nonempty subset in that order |
| `confidences` | text | `high,ambiguous` | A nonempty subset in that order |
| `max-input-bytes` | integer | `1048576` | `1..1048576` |
| `max-findings` | integer | `4096` | `1..4096` |
| `audit-sink` | text | `sidecar-json-v1` | `sidecar-json-v1` |
| `allow-redact` | boolean | `false` | `false`, `true` |

`report` is the non-destructive default and returns the original content
object. `mask` replaces every byte in each finding union with `*`, preserving
byte length and original offsets. `redact` replaces each maximal overlapping
union with `[REDACTED]`; it fails during compilation unless
`allow-redact=true` is also present. Category and confidence selection filters
the scanner's ordered typed findings without reclassifying them.

Every successful document emits one immutable terminal side output with key
`pii-audit`, schema `scrubbed-pii-audit-v1`, and suffix
`.pii-audit.json`. The canonical JSON binds the document ID, whole-input
revision SHA-256, analyzer and policy versions, normalized options,
whole-output SHA-256, and ordered union/contributor offsets and finite enums.
It does not contain matched values, snippets, source bytes or locators,
per-match hashes, or content-derived diagnostics. An empty finding set still
emits the bound audit record. Publication and destination policy are owned by
the separate generic side-output adapters.

The release-active stage proof covers policy goldens, both locales, category
and confidence selection, ambiguity, scanner overlap, multilingual context,
false-positive controls, invalid UTF-8, exact caps, fixed option failures,
caller-storage preservation, concurrent compiled-plan reuse, and equal v3 and
v4-common behavior:

```sh
ldc2 -O3 -release -preview=dip1000 -i -Isource \
  -of=.dub/pii-pipeline-check experiments/pii_pipeline/check.d
.dub/pii-pipeline-check
```
