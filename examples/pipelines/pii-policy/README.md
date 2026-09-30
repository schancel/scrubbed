# PII report/mask/redact policy example

Demonstrates the `pii-four-class` stage's three policy modes -- `report`,
`mask`, `redact` -- against the same synthetic input, so the visible
difference between them is easy to see and to check.

See [docs/pii-four-class-stage.md](../../../docs/pii-four-class-stage.md),
[docs/pii-patterns.md](../../../docs/pii-patterns.md), and
[docs/pii-policy.md](../../../docs/pii-policy.md) for the stage's full option
reference and the underlying scanner/policy semantics this example exercises
end to end through the shipping CLI.

## Input

[`examples/corpus/pii-policy/inputs/notice.txt`](../../corpus/pii-policy/inputs/notice.txt)
is one short, wholly-authored synthetic sentence carrying three of the four
`pii-four-class` categories:

- an **email** address at the IANA-reserved `.test` TLD
  (`agent.demo@example.test`)
- a **phone** number using the NANP `555-01XX` block reserved for
  fictional use in media (`+1-202-555-0198`)
- an **IPv4** address in the RFC 5737 TEST-NET-3 documentation range
  (`203.0.113.42`)

Every value is obviously placeholder, not harvested data. See
[examples/corpus/pii-policy/manifest.json](../../corpus/pii-policy/manifest.json)
for exact provenance, license, and hash records for every input and
expected-output artifact, following the same schema shape as
[examples/corpus/quickstart/manifest.json](../../corpus/quickstart/manifest.json).

## Why `run --stage`, not `clean-web-document`

`clean-web-document` is a sealed five-stage preset
(`text-transform -> html-metadata-annotate -> html-main-content ->
pii-four-class -> document-metadata-publish`) built for HTML pages: it always
runs HTML main-content extraction ahead of the PII scan. This example's input
is plain text, not HTML, and the point is to show `pii-four-class`'s own
three policies in isolation, so it hand-composes the two stages that matter
here directly with `run --stage`:

```sh
scrubbed run --input notice.txt --output notice.mask.txt \
  --sidecar-output notice.mask.document-metadata.json \
  --stage pii=pii-four-class --stage-option policy=text:mask \
  --stage pub=document-metadata-publish
```

`pii-four-class` itself is not terminal (issue #300 Slice 3): it writes its
audit into the shared `DocumentMetadata` accumulator as a structured
section instead of emitting its own side output, so a
`document-metadata-publish` stage must run after it in the same job for that
audit to actually reach a sidecar file. `--sidecar-output` is required
whenever the compiled plan ends in a side-output-producing stage.

## The three recipes

Each mode has both a `--stage`-token CLI form and an equivalent canonical
v3 JSON `--config` form (`report.json`, `mask.json`, `redact.json` in this
directory); the checker below runs both and asserts they compile to the same
job and produce byte-identical output.

| Mode | Extra stage options | Effect on `notice.txt` |
| --- | --- | --- |
| `report` (default) | none | Output is byte-identical to the input. Audit-only: every finding is recorded, nothing is rewritten. |
| `mask` | `policy=text:mask` | Every byte inside each of the three findings is replaced with `*`; output byte length and every other byte's offset are unchanged. |
| `redact` | `policy=text:redact`, `allow-redact=boolean:true` | Each finding is replaced with the literal marker `[REDACTED]`; output is shorter than the input. `redact` is opt-in -- compiling this job without `allow-redact=true` fails closed. |

```sh
# report: audit-only, content untouched
scrubbed run --input notice.txt --output notice.report.txt \
  --sidecar-output notice.report.document-metadata.json \
  --stage pii=pii-four-class --stage pub=document-metadata-publish

# mask: byte-length-preserving '*' substitution
scrubbed run --input notice.txt --output notice.mask.txt \
  --sidecar-output notice.mask.document-metadata.json \
  --stage pii=pii-four-class --stage-option policy=text:mask \
  --stage pub=document-metadata-publish

# redact: opt-in [REDACTED] replacement
scrubbed run --input notice.txt --output notice.redact.txt \
  --sidecar-output notice.redact.document-metadata.json \
  --stage pii=pii-four-class --stage-option policy=text:redact \
  --stage-option allow-redact=boolean:true \
  --stage pub=document-metadata-publish
```

## The audit sidecar

`--sidecar-output` receives the `document-metadata-publish` stage's
`document-metadata:v2` wire record. Its one structured section
(`sectionId: "pii-audit"`, `sourceStage: "pii-four-class"`) is a hex-encoded
`scrubbed-pii-audit-v1` payload: decoded, it binds the document ID, whole-
input/output SHA-256 revisions, analyzer/policy versions, normalized
options, and the ordered per-category finding unions -- never matched
values, snippets, or source bytes/paths (see
[docs/pii-four-class-stage.md](../../../docs/pii-four-class-stage.md)'s
"Audit sidecar" section).

`document_id` is `doc:v1:sha256(scheme, --input's own absolute path,
record)` -- deterministic per invocation, but **not** a function of file
content, so it is not reproducible byte-for-byte across machines or temp
directories. Every other audit field is fully content-deterministic. The
checker (and this directory's pinned goldens,
`examples/corpus/pii-policy/expected/*.pii-audit.json`) account for this by
substituting the run's own `document_id` for a fixed `<DOCUMENT_ID>` token
before diffing -- everything else in the audit is diffed exactly, byte for
byte.

## Checker

```sh
ldc2 -O3 -release -preview=dip1000 -i -Isource \
  -of=.dub/pii-policy-check examples/pipelines/pii-policy/check.d
dub build -b release
.dub/pii-policy-check ./scrubbed
```

The checker validates the corpus manifest (schema, license hash, per-artifact
provenance/license/hash, fixture-provenance record) and a handful of negative
manifest mutants, then runs all three policy recipes -- and their JSON
`--config` equivalents -- from a clean temporary directory against the
release binary, and for each:

- diffs the primary output against its pinned golden (`expected/<mode>.txt`)
- diffs the decoded audit sidecar (modulo `document_id`, see above) against
  its pinned golden (`expected/<mode>.pii-audit.json`)
- asserts `report`'s output is byte-identical to the input
- asserts `report`, `mask`, and `redact`'s three outputs for the same input
  are pairwise different, that `mask` preserves byte length and `redact`
  does not, and that a `redact` job compiled without `allow-redact=true` is
  rejected

## Fixture provenance

This corpus is wholly new content authored for issue #507. Two #180-adjacent
candidates were located and considered before authoring new content:

1. **`experiments/pii_pipeline/check.d`'s inline test-fixture bytes.** An
   inline literal byte string inside a D test file under `experiments/` --
   an internal/test-only location in this repo, not the public `examples/**`
   gallery -- with no standalone file, license header, or manifest/
   provenance record of its own, so it was not redistributable as-is into
   the public gallery's corpus, which requires exactly that kind of
   per-artifact provenance and license metadata (see
   `examples/corpus/quickstart/manifest.json`'s existing pattern).
2. **`benchmarks/pii-pipeline.json`'s checked-in `"handoff"` object**
   (landed in commit `15eeab5`/PR #272; issue #180's own closing comment
   describes it as the ready synthetic handoff packet published for #62 to
   land separately). This one genuinely *is* redistributable as-is: it
   carries its own explicit `"license": "CC0-1.0"` and a `"provenance"`
   record (`author`, `kind: authored-synthetic`, `network_data: false`,
   `private_data: false`). It was not reused here because its coverage
   doesn't meet this ticket's acceptance criteria on its own: only two
   categories (`email`, `ip` -- no `phone`, no `card`) and a single
   `mask`-policy golden only (no `report` or `redact` expected output/audit).
   Reusing it would still have required authoring a phone finding and
   report/redact goldens from scratch, so a coherent from-scratch
   three-category/three-policy corpus was authored instead.

This example's fixture pattern-matches #180's category coverage (email,
phone, plus IPv4 in place of #180's fourth, payment-card, category -- three
of the four is already more than one category) but every byte is newly
authored: a different local part, a different reserved test domain, a
different NANP fictional exchange, and a different RFC 5737
documentation-range IP address, distinct from both #180-adjacent fixtures
above. See `examples/corpus/pii-policy/manifest.json`'s `fixtureProvenance`
record for the same statement in machine-checked form.
