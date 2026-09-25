# Offline task examples

This small, MIT-licensed corpus demonstrates three shipping paths without a
network connection: saved-HTML tree conversion, conservative text repair, and
selected-field JSONL repair. All pages and records were authored for this
repository. Exact provenance, media types, licenses, intended outcomes, and
SHA-256 digests are in
[`examples/corpus/quickstart/manifest.json`](../examples/corpus/quickstart/manifest.json).
The corpus is a reproducible teaching fixture, not a training-ready corpus.

Build once from the repository root:

```sh
dub build --compiler=ldc2 --build=release
```

## Saved HTML to Markdown

The canonical configuration form is:

```sh
./scrubbed extract \
  --input examples/corpus/quickstart/inputs/html \
  --output /tmp/scrubbed-html \
  --format markdown \
  --config examples/pipelines/quickstart/html-markdown.json
```

Its equivalent CLI form is:

```sh
./scrubbed extract \
  --input examples/corpus/quickstart/inputs/html \
  --output /tmp/scrubbed-html-cli \
  --format markdown \
  --max-html-bytes 1048576
```

Tree inputs retain their relative paths and append `.md`, so `campus/index.html`
becomes `campus/index.html.md`. The malformed deep fixture is quarantined with
exit 1 and produces no partial file; the two admitted pages are still
published. Compare the resulting tree with
`examples/corpus/quickstart/expected/html`.

This is mechanical DOM-to-Markdown conversion, not main-content extraction.
Headers, navigation, and footers are deliberately visible in the golden
output. Unsafe link and image destinations become inert, but that behavior is
not a general web-page sanitizer, browser, or boilerplate-removal algorithm.

Raw and decoded HTML default to a 1 MiB cap; the supported configured maximum
is 8 MiB. Raising that cap does not raise the independent selected-tree,
Markdown-output, depth, node, attribute, or observation caps. Each accepted
file is atomically replaced at its destination, but the output tree is not a
multi-file transaction. `extract` has no manifest, checkpoint, or restart
mode, so rerunning starts the requested tree operation again.

## Text repair

Run the canonical configuration:

```sh
./scrubbed repair \
  --input examples/corpus/quickstart/inputs/text \
  --output /tmp/scrubbed-text \
  --config examples/pipelines/quickstart/text-repair.json \
  --threads 1
```

The equivalent ordered CLI composition is:

```sh
./scrubbed repair \
  --input examples/corpus/quickstart/inputs/text \
  --output /tmp/scrubbed-text-cli \
  --stage clean=text-transform \
  --filter fix-mojibake \
  --filter-option encodings=text:latin1,cp1252 \
  --filter-option max-passes=integer:2 \
  --threads 1
```

The clean UTF-8 fixture is byte-preserved; the other fixture demonstrates a
changed, conservative Latin-1/Windows-1252 repair. This does not imply general
encoding detection or correction.

## Selected-field JSONL

The canonical configuration form repairs only the top-level `text` and
`title` string values:

```sh
./scrubbed run --input - --output - \
  --jsonl-fields text,title \
  --dataset-namespace scrubbed-quickstart-v1 \
  --source-key records \
  --max-jsonl-line-bytes 1048576 \
  --max-jsonl-output-bytes 2097152 \
  --config examples/pipelines/quickstart/text-repair.json \
  < examples/corpus/quickstart/inputs/records.jsonl \
  > /tmp/scrubbed-records.jsonl
```

Replace the `--config` line with the following ordered tokens for the
byte-identical CLI form:

```sh
  --stage clean=text-transform \
  --filter fix-mojibake \
  --filter-option encodings=text:latin1,cp1252 \
  --filter-option max-passes=integer:2
```

JSON object spelling and key order are canonicalized; untouched values are
preserved semantically rather than byte-for-byte. JSONL stdout has no atomic
rollback, checkpoint, or restart guarantee.

## Reproduce the checked results

The release-active D checker validates the manifest and required negative
mutants, then runs both forms of every recipe twice from fresh temporary state
with opposite fixture-creation order. It requires the release binary and makes
no network requests:

```sh
ldc2 -O -release \
  -of=.dub/quickstart-check examples/pipelines/quickstart/check.d
.dub/quickstart-check ./scrubbed
```

It compares exact relative paths, bytes, and hashes with the checked-in
expected tree. It also rejects hash drift, missing attribution or licensing,
stale configurations or commands, path escape, undeclared output, and any
manifest claim of main-content extraction or training readiness.
