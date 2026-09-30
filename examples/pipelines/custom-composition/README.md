# Custom `--stage` composition + `language-id-detect` example

**This demonstrates composability, not a new preset.** `run --stage` lets a
caller order arbitrary registered stages into their own pipeline, instead of
being limited to a sealed preset like `clean-web-document` or the `extract`
subcommand. The three stages chained here --
[`text-transform`](../../../source/stages/text_transform.d) (with the
`fix-mojibake` filter), [`language-id-detect`](../../../docs/language-id.md),
and `document-metadata-publish` -- are **one illustrative composition among
many valid ones**, chosen to also give `language-id-detect` its own worked
example as a standalone stage. Nothing about this order, these three stages,
or these fixtures is a new sealed preset, and no other combination of
registered stages is somehow disallowed; see
[docs/cli-commands.md](../../../docs/cli-commands.md) for the full stage/
filter registry and `scrubbed run --list-filters`.

## Why this composition

- **`text-transform` + `fix-mojibake`** repairs Latin-1/Windows-1252 mojibake
  ahead of language detection -- the same filter
  [`examples/pipelines/quickstart/`](../quickstart/) uses, chosen here to
  make the composition do real, visible work (not just pass content through)
  before the stage of interest runs.
- **`language-id-detect`** (issue #311, wired onto the frozen, pre-existing
  `domain.language_id` classifier -- see [docs/language-id.md](../../../docs/language-id.md))
  is an ANNOTATE-ONLY v3 stage: it scores `StageDocument.content`'s raw bytes
  directly (no HTML parsing) and writes an encoded
  `LanguageIdentityRecord` into the shared `StageDocument.metadata`
  accumulator as an extension field. It does **not** publish its own side
  output.
- **`document-metadata-publish`** is required *after* `language-id-detect` in
  the same job for that annotation to actually reach a sidecar file via
  `--sidecar-output`. This is the same non-terminal-annotate-stage wiring
  `pii-four-class` needs (see
  [`examples/pipelines/pii-policy/`](../pii-policy/) and
  [docs/pii-four-class-stage.md](../../../docs/pii-four-class-stage.md)'s own
  "Audit sidecar" section) -- omitting the publish stage after an
  annotate-only stage is a known real mistake (it is what left
  `benchmarks/pii_pipeline_check.d` stale); this example exists in part to
  give `language-id-detect` a second, current, checked worked example of the
  same wiring rule.

```sh
scrubbed run --input clean.txt --output clean.out.txt \
  --sidecar-output clean.document-metadata.json \
  --stage clean=text-transform --filter fix-mojibake \
  --filter-option encodings=text:latin1,cp1252 \
  --filter-option max-passes=integer:2 \
  --stage detect=language-id-detect \
  --stage pub=document-metadata-publish
```

The equivalent canonical v3 JSON job
([`pipeline.json`](pipeline.json) in this directory):

```json
{"version":3,"stages":[
  {"id":"clean","implementation":"text-transform","options":{},
   "filters":[{"name":"fix-mojibake","options":{"encodings":"latin1,cp1252","max-passes":2}}]},
  {"id":"detect","implementation":"language-id-detect","options":{},"filters":[]},
  {"id":"pub","implementation":"document-metadata-publish","options":{},"filters":[]}
]}
```

```sh
scrubbed run --input clean.txt --output clean.out.txt \
  --sidecar-output clean.document-metadata.json \
  --config pipeline.json
```

Both forms compile to the identical job and produce byte-identical primary
output and sidecar bytes; the checker below runs both, for every fixture.

## Fixtures and expected `language-id-detect` behavior

[`examples/corpus/custom-composition/inputs/`](../../corpus/custom-composition/inputs/)
holds three short, wholly-authored synthetic text fixtures. See
[`examples/corpus/custom-composition/manifest.json`](../../corpus/custom-composition/manifest.json)
for exact provenance, license, and hash records, following the same schema
shape as
[`examples/corpus/quickstart/manifest.json`](../../corpus/quickstart/manifest.json).

| Fixture | Content | `fix-mojibake` | `language-id-detect` result |
| --- | --- | --- | --- |
| `clean.txt` | A short, plain, already-clean UTF-8 Spanish passage. | No-op (no mojibake present). | **Detected, `es`** -- one of the 17 supported languages, confidently. |
| `repair.txt` | A short English passage, with every byte double-mojibake-corrupted (its UTF-8 bytes reinterpreted as Latin-1, then re-encoded as UTF-8 -- the same construction [`examples/corpus/quickstart/inputs/text/repair.txt`](../../corpus/quickstart/inputs/text/repair.txt) uses). | Actually repairs the text -- output bytes differ from input bytes. | **Detected, `en`**, on the *repaired* text -- proving the composed stage ahead of `language-id-detect` does real work, not just pass-through. |
| `short.txt` | A deliberately too-short plain-English snippet (`"Not now, thanks."` -- 3 words, well under the classifier's 60-total-n-gram floor). | No-op. | **Abstained, reason `tooShort`** -- proof abstention is real, typed data, not a silently guessed language and not an error. |

`language-id-detect` supports 17 languages
(`en, es, fr, de, pt, it, nl, tr, vi, pl, id, hi, bn, ta, te, gu, pa` -- 11
Latin-script plus 6 Brahmic-family) and seven typed abstention reasons
(`emptyText`, `oversizeText`, `invalidUtf8`, `tooShort`, `unsupportedScript`,
`mixedOrAmbiguous`, `belowConfidenceThreshold`); see
[docs/language-id.md](../../../docs/language-id.md) for the full classifier,
provenance, and wire-format reference. **Every one of these seven reasons is
written as ordinary successful data, never a quarantine or an error exit** --
`short.txt` above demonstrates this directly: the job still exits 0 and
still produces a well-formed sidecar record, just one whose `status` is
`"abstained"` rather than `"detected"`.

## The sidecar

`--sidecar-output` receives the `document-metadata-publish` stage's wire
record. Because `language-id-detect` writes an **extension field**
(`key: "language-id"`, `sourceStage: "language-id-detect"`) into the shared
metadata accumulator -- not a *structured section*, the mechanism
`pii-four-class`'s larger audit payload uses -- and nothing else in this
composition writes a structured section either, `document-metadata-publish`
always picks the plain `document-metadata:v1` wire shape for every fixture
here (see
[`source/effects/document_metadata_publish_stage.d`](../../../source/effects/document_metadata_publish_stage.d)'s
own doc comment on how it picks v1 vs. v2 per document).

The extension field's `value` is a hex-encoded, binary-framed
`LanguageIdentityRecord` (`domain.language_id.encodeLanguageIdentity`'s wire
format -- see [docs/language-id.md](../../../docs/language-id.md)'s "Wire
format" section), not JSON text -- unlike `pii-four-class`'s own
JSON-payload structured section. The checker below decodes it with the same
`domain.language_id.decodeLanguageIdentity` function the stage's own unit
tests use, bound to the sidecar's own `documentId` and to the primary
output's own SHA-256 (the exact text `language-id-detect` scored, since
`content` passes through every stage in this composition unmodified).

## Checker

```sh
ldc2 -O3 -release -preview=dip1000 -i -Isource \
  -of=.dub/custom-composition-check examples/pipelines/custom-composition/check.d
dub build -b release
.dub/custom-composition-check ./scrubbed
```

The checker validates the corpus manifest (schema, license hash, per-artifact
provenance/license/hash) and a handful of negative manifest mutants, then
runs all three fixtures' recipes -- and their JSON `--config` equivalent --
from a clean temporary directory against the release binary, and for each:

- diffs the primary output against its pinned golden (`expected/<id>.txt`)
- structurally verifies the sidecar envelope (`document-metadata:v1`, one
  extension field owned by `language-id-detect`) and decodes it via
  `domain.language_id.decodeLanguageIdentity`
- diffs a small, stable descriptor of the decoded result (status, language
  or `null`, per-mille confidence or `null`, abstention reason) against its
  pinned golden (`expected/<id>.language-id.json`)
- asserts `clean.txt`'s output is byte-identical to its input (mojibake
  no-op) and `repair.txt`'s is not (mojibake actually repaired)
- asserts `clean.txt` and `repair.txt` each name the correct one of the 17
  supported languages, and `short.txt` genuinely **abstains** with a
  populated, non-`"none"` `tooShort` reason -- never a guess
- asserts the `--config` JSON form's output and sidecar are byte-identical to
  the `--stage`-token form's, for every fixture

## Fixture provenance

Every fixture in
[`examples/corpus/custom-composition/`](../../corpus/custom-composition/) is
wholly new, short, synthetic text authored from scratch for issue #505 by
Shammah Chancellor, MIT-licensed like the rest of this repository -- see
`manifest.json`'s per-artifact `provenance`/`license` fields. None of it is
reused from `examples/pipeline-benchmark/corpus/` (real third-party pages,
vendored under issue #315's distinct, narrower accepted-risk posture, not for
this public example gallery) or from any other corpus in this repository.
