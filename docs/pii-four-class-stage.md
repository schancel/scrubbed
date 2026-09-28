# `pii-four-class` stage

Importing `stages.pii_four_class` registers the `pii-four-class`
stage — the CLI-facing wrapper around the scanner and policy modules
described in [pii-patterns.md](pii-patterns.md) and
[pii-policy.md](pii-policy.md). It's bounded pattern handling for email,
US/GB phone, payment-card, and IPv4 — not complete de-identification,
name/address recognition, or model-backed NER.

The stage accepts the ordinary typed v3 stage options, so the same stage
object can be used unchanged as a v4 `common` stage.

## Options

| Option | Type | Default | Accepted values |
| --- | --- | --- | --- |
| `locale` | text | `US` | `US`, `GB` |
| `policy` | text | `report` | `report`, `mask`, `redact` |
| `categories` | text | `email,phone,card,ip` | a nonempty subset, in that order |
| `confidences` | text | `high,ambiguous` | a nonempty subset, in that order |
| `max-input-bytes` | integer | `1048576` | `1..1048576` |
| `max-findings` | integer | `4096` | `1..4096` |
| `audit-sink` | text | `sidecar-json-v1` | `sidecar-json-v1` |
| `allow-redact` | boolean | `false` | `false`, `true` |

## Policies

- `report` — the non-destructive default; returns the original content
  object.
- `mask` — replaces every byte in each finding union with `*`, preserving
  byte length and original offsets.
- `redact` — replaces each maximal overlapping union with `[REDACTED]`;
  fails at compile time unless `allow-redact=true` is also set.

`categories` and `confidences` filter the scanner's ordered typed findings
without reclassifying them.

## Audit sidecar

**Updated for issue #300 Slice 3** (landed `384f404`): `pii-four-class` is no
longer terminal itself (`SideOutputCapability.none`). Every successful
document writes its audit into the shared `DocumentMetadata` accumulator as
a structured section, keyed the same stable name this table always used:

| | |
| --- | --- |
| structured-section id | `pii-audit` |
| schema (of the section's own payload) | `scrubbed-pii-audit-v1` |

A later `document-metadata-publish` stage in the same job (see
[docs/document-metadata.md](document-metadata.md)) publishes it, alongside
whatever else (e.g. `html-metadata-annotate`'s title/author/date/url) also
wrote into the same accumulator, as one `document-metadata:v2` terminal side
output. `clean-web-document`'s own sidecar path for this is
`.document-metadata.json`/`.document-metadata` — see
[docs/cli-commands.md](cli-commands.md).

The canonical JSON payload binds the document ID, whole-input revision
SHA-256, analyzer and policy versions, normalized options, whole-output
SHA-256, and ordered union/contributor offsets and finite enums. It does not
contain matched values, snippets, source bytes or locators, per-match
hashes, or content-derived diagnostics. An empty finding set still writes
the bound audit record into the accumulator.

Publication and destination policy are owned by the generic side-output
adapters — see [docs/cli-commands.md](cli-commands.md) for the
`clean-web-document`/`run` sidecar-path rules.

## Proof

The release-active stage proof covers policy goldens, both locales, category
and confidence selection, ambiguity, scanner overlap, multilingual context,
false-positive controls, invalid UTF-8, exact caps, fixed option failures,
caller-storage preservation, concurrent compiled-plan reuse, and equal v3
and v4-common behavior:

```sh
ldc2 -O3 -release -preview=dip1000 -i -Isource \
  -of=.dub/pii-pipeline-check experiments/pii_pipeline/check.d
.dub/pii-pipeline-check
```

The separate [bounded actual-binary evidence](pii-pipeline.md) records the
clean and finding-cap workloads, strict mutation controls, route matrix, and
exact synthetic downstream handoff. Its timings are local observations, not a
performance claim.
