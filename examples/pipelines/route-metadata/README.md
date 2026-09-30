# `route-metadata` command example

Demonstrates the standalone `route-metadata` command: "Route local HTML
content and stage metadata to independent sinks." Unlike
[`run`](../../../docs/cli-commands.md)/[`extract`](../../../docs/cli-commands.md),
`route-metadata` is not a compiled stage pipeline you configure -- it is its
own opt-in local effect (`source/effects/metadata_route_cli.d`), dispatched
directly from `source/cli_commands.d`'s `runCommands()` before argparse's
generic parse. Given one HTML file (or a directory tree of them), it writes
each file's **content** and its **extracted metadata** to two separate,
independently addressable output roots, tracked in a local SQLite manifest.

See [`source/effects/metadata_route_cli.d`](../../../source/effects/metadata_route_cli.d)
for the command's full option parsing, path-safety validation, and manifest
wiring.

## No JSON-config form exists for this command

Every other example in this gallery
([`quickstart`](../quickstart/), [`pii-policy`](../pii-policy/),
[`custom-composition`](../custom-composition/)) shows a `--stage`/legacy
CLI-token recipe next to a byte-identical canonical v3 JSON `--config`
equivalent. `route-metadata` has no such form: it is dispatched before
argparse's `run`/`extract` machinery ever runs, and its own `parseOptions()`
recognizes only `--input`, `--content-output`, `--metadata-output`,
`--manifest`, `--filters`, and `--retry` -- there is no `--config` flag and
no JSON-loading code path anywhere in `metadata_route_cli.d`. This was
confirmed by reading the module in full and grepping `source/job/*.d` for
any route-metadata-specific JSON wiring: none exists. This is a real,
current limitation of the command itself, not a gap in this example (see
`examples/corpus/route-metadata/manifest.json`'s `commandNote`).

In place of a CLI/JSON equivalence proof, this example proves something
just as concrete: **CLI-token determinism across two separate real process
runs**. The checker below launches the identical `route-metadata` command
twice, as two independent invocations of the release binary against the
same `--input` path (but distinct output roots), and diffs both sinks
byte-for-byte between the two runs.

## The command

```sh
scrubbed route-metadata \
  --input dispatch-note.html \
  --content-output ./content \
  --metadata-output ./metadata \
  --manifest ./manifest.sqlite3
```

`--content-output` and `--metadata-output` must already exist as real,
non-symlink directories (the command's own `--help` text: "Existing content
root" / "Existing metadata root") -- `route-metadata` does not create its
own roots, only relative subdirectories nested inside them. `--filters`
defaults to `normalize-line-endings,strip-control` (the same default legacy
filter pair `job.legacy.defaultLegacyFilters` uses) and was left at its
default for this example.

## Independent sinks, concretely

Both sinks are written under the *same* relative name as the input file
(`dispatch-note.html` in, `dispatch-note.html` out, in each of the two
roots) but are otherwise fully independent: `effects.independent_sinks`
refuses to construct if the content and metadata roots alias each other,
and each sink is delivered and manifest-committed on its own, so a failure
or absence of one never implies anything about the other.

The checker does not just assert that two files exist -- it demonstrates
the independence directly, on a real completed run:

- deletes the **content** sink outright, then re-reads the **metadata**
  sink from disk and confirms it is still present and still byte-identical
  to its pinned golden;
- separately, moves the **metadata** sink out of its root entirely, then
  re-reads the **content** sink and confirms it is still present and still
  byte-identical to its pinned golden.

Neither sink's correctness ever depended on the other's continued
existence.

## The fixture

[`examples/corpus/route-metadata/inputs/dispatch-note.html`](../../corpus/route-metadata/inputs/dispatch-note.html)
is one short, wholly-authored synthetic HTML page carrying a real
title/author/date/url/site-name/description metadata block worth routing
separately from its content, plus a CRLF and a lone-CR line ending inside
its body text, so `route-metadata`'s default content filters do real,
visible work rather than a no-op pass-through. See
[`examples/corpus/route-metadata/manifest.json`](../../corpus/route-metadata/manifest.json)
for exact provenance, license, and hash records, following the same schema
shape as
[`examples/corpus/quickstart/manifest.json`](../../corpus/quickstart/manifest.json).

| Sink | What lands there |
| --- | --- |
| content (`./content/dispatch-note.html`) | The input bytes, unchanged, except every CRLF/lone-CR line ending normalized to a single LF (`normalize-line-endings`). No control bytes were present in the fixture to strip. HTML markup and every metadata-bearing tag pass through completely unmodified -- `route-metadata`'s content filters never parse or alter HTML structure at all. |
| metadata (`./metadata/dispatch-note.html`) | A `document-metadata:v1` wire record (JSON text, despite the shared `.html` name -- `route-metadata` reuses the input's relative name for both sinks, it does not rename by content type) with four standard fields (`title`, `author`, `date`, `url`) and two extension fields (`site-name`, `description`) selected from the fixture's `<title>`, `<meta>`, and `<link rel="canonical">` markup. |

## The metadata sink's wire format

The metadata job compiled inside `runMetadataRoute` is always exactly
`html-metadata-annotate -> document-metadata-publish`
(`source/effects/metadata_route_cli.d`'s `runMetadataRoute`) -- this is not
configurable via any flag. `html-metadata-annotate` never writes a
structured section, so `document-metadata-publish` always takes the
`document-metadata:v1` wire path for every file this command processes
(see
[`source/effects/document_metadata_publish_stage.d`](../../../source/effects/document_metadata_publish_stage.d)'s
own doc comment, which calls out `route-metadata` by name as one of its
permanently-v1 callers).

`documentId` is `doc:v1:sha256("local-html:v1", --input's own resolved
absolute path, the file's relative name)` -- deterministic per invocation,
but **not** a function of file content, so it is not byte-for-byte
reproducible across machines or temp directories (the same shape
[`pii-policy`](../pii-policy/)'s own audit sidecar document ID has, for the
same underlying reason: see `domain.document.DocumentId.from`). The
checker's pinned golden
(`examples/corpus/route-metadata/expected/dispatch-note.metadata.json`)
substitutes the run's own document ID for a fixed `<DOCUMENT_ID>` token
before diffing, the same technique `pii-policy`'s checker uses -- everything
else in the record is diffed exactly, byte for byte. Because the checker's
own two runs share the identical `--input` path, their two metadata sinks'
`documentId` fields are additionally diffed against *each other* with no
substitution at all, proving the determinism claim in its strongest form.

## Checker

```sh
ldc2 -O3 -release -preview=dip1000 -i -Isource \
  -of=.dub/route-metadata-check examples/pipelines/route-metadata/check.d
dub build -b release
.dub/route-metadata-check ./scrubbed
```

The checker validates the corpus manifest (schema, license hash,
per-artifact provenance/license/hash, the `jsonConfigForm`/
`hasJsonConfigForm: false` claims) and a handful of negative manifest
mutants, then runs the fixture's recipe **twice** -- two separate real
process launches of the release binary, sharing one `--input` path -- from
a clean temporary directory, and:

- asserts both runs exit 0 and each sink lands at the documented,
  independently addressable path;
- diffs the content sink and the metadata sink **between the two runs**,
  byte-for-byte (the CLI-token determinism proof, in place of the
  CLI/JSON-config equivalence proof this command has no JSON form for);
- diffs the content sink against its pinned golden, and asserts it is
  genuinely not a pass-through of the raw input (no stray `\r` byte
  survives; `normalize-line-endings` did real work);
- diffs the metadata sink against its pinned golden, modulo the
  `<DOCUMENT_ID>` substitution described above, and asserts the expected
  title/author/site-name/description fields are present;
- deletes the first run's content sink and confirms its metadata sink is
  unaffected; moves the second run's metadata sink aside and confirms its
  content sink is unaffected -- the concrete independent-sinks proof.

## Fixture provenance

Every artifact in
[`examples/corpus/route-metadata/`](../../corpus/route-metadata/) is
wholly new, short, synthetic content authored from scratch for issue #508
by Shammah Chancellor, MIT-licensed like the rest of this repository -- see
`manifest.json`'s per-artifact `provenance`/`license` fields. None of it is
reused from `examples/pipeline-benchmark/corpus/` (real third-party pages,
vendored under issue #315's distinct, narrower accepted-risk posture, not
for this public example gallery) or from any other corpus in this
repository.
