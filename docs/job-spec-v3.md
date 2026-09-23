# Canonical job specification v3

The v3 job specification is the common typed model for `run` composition
tokens and persistent JSON configuration. The shipping CLI accepts it for
ordinary local file/tree processing. JSONL and manifest/error-journal routes
remain deferred and reject v3 before reading input or mutating output.

```json
{
  "version": 3,
  "stages": [
    {
      "id": "clean",
      "implementation": "text-transform",
      "options": {},
      "filters": [
        {
          "name": "fix-mojibake",
          "options": {
            "encodings": "latin1,cp1252",
            "max-passes": 2
          }
        },
        {
          "name": "normalize-line-endings",
          "options": {}
        }
      ]
    }
  ]
}
```

`id` identifies this occurrence in the job. `implementation` is the
self-registering stage-factory lookup used by the pure compiler. They are
separate so the same
implementation can appear more than once without colliding in provenance or
future graph references. Stage IDs are unique; filter order is significant.
Options are JSON text, signed 64-bit integer, or boolean values. Floating
point, null, arrays, objects, duplicate keys, unknown schema keys, and
noncanonical names are rejected.

Canonical serialization fixes field order, sorts option keys, removes
insignificant whitespace, and always emits explicit `options` and `filters`.
The lowercase SHA-256 digest of those UTF-8 bytes is exposed as
`job:v3:<64 hex digits>`. JSON member spelling and whitespace therefore do not
change identity, while stage/filter order and typed values do.

## Ordered command-line form

The corresponding composition tokens are:

```sh
--stage clean=text-transform \
  --filter fix-mojibake \
    --filter-option encodings=text:latin1,cp1252 \
    --filter-option max-passes=integer:2 \
  --filter normalize-line-endings
```

A `--stage ID=IMPLEMENTATION` opens a stage. Its `--stage-option` tokens must
come before its first filter. Each `--filter NAME` attaches to the open stage;
following `--filter-option` tokens attach to that filter. Option values use
`text:`, `integer:`, or `boolean:` explicitly, so `text:001` and `integer:1`
cannot acquire the same identity by inference. Shell quoting is needed only
when a value itself contains shell metacharacters or whitespace.

Argparse advertises these shipping flags and preserves their original
interleaved order for the pure parser. The JSON route and tokens compile to the
same model; neither surface owns a second grammar.

## Compatibility lowering and scope

The no-selector default, predecessor `--filters`, and v1 `filters` JSON lower
to one stage with ID `legacy-text` and implementation `text-transform`.
Legacy scalar JSON types are retained in the v3 model. The predecessor parser
remains live only until actual-binary equivalence and removal proofs pass.

This format is currently a linear document pipeline, not a general workflow
language. #155 may add a bounded one-of dispatch declaration: detect the input
media/container type, choose exactly one named extraction subpipeline, then
converge on the common text-document contract. That is not
`StageDecision.split`, fan-out, a join, or a general DAG. The current schema
does not yet implement or accept it. Machine scheduling, transport,
credentials, model downloads, and arbitrary plugin code do not belong in the
local composition root.
