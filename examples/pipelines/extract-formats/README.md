# `extract` format + structural-fidelity showcase

Demonstrates `extract`'s full `--format` surface -- `tree-json`, `markdown`,
`main-content-markdown`, `csv`, `xml`, `xml-tei` -- and everything the #471
family shipped: comment extraction (#475), inline structural fidelity
(#477: bold/italic/links/images), block structural fidelity (#478:
tables/lists/quotes/code), and the CSV/XML/XML-TEI output formats (#481).
One synthetic page, engineered to carry every structural element at once,
run through all six formats with a pinned golden for each.

Corpus and fixture are in
[`examples/corpus/extract-formats/`](../../corpus/extract-formats/); exact
provenance, media types, licenses, intended pipelines, and SHA-256 digests
are in that directory's
[`manifest.json`](../../corpus/extract-formats/manifest.json), following
the same schema shape as
[`examples/corpus/quickstart/manifest.json`](../../corpus/quickstart/manifest.json).

Build once from the repository root:

```sh
dub build --compiler=ldc2 --build=release
```

## The fixture

[`examples/corpus/extract-formats/inputs/field-notes.html`](../../corpus/extract-formats/inputs/field-notes.html)
is one small, wholly-authored synthetic page (a fictional delta survey
field-notes post) engineered to hit every structural-fidelity dimension in
one place:

- **nav/header/footer chrome** that a main-content-aware format must
  exclude, but a whole-page format must not
- **a comment section** (`<div id="comments" class="comments">` wrapping
  `<div class="commentEntry"><div class="commentContent" id="comment-NNN">`
  entries) -- the exact real-corpus shape `html_main_content.d`'s own
  `commentSectionKeywords` doc comment documents
- **bold** (`<strong>`) and *italic* (`<em>`) inline formatting
- **a link** (`<a href="https://...">`)
- **an image** (`<img src="https://..." alt="...">`)
- **a list** (`<ul><li>`)
- **a blockquote** (`<blockquote><p>`)
- **a table** with a caption and a header row (`<table><caption><tr><th>`)
- **a code block** (`<pre>`)
- one embedded double quote in the body text, deliberately, to force real
  CSV RFC 4180 quoting (see "CSV" below)

Every name, place, and reading is invented for this fixture.

## The six `extract --format=...` modes

```sh
for format in tree-json markdown main-content-markdown csv xml xml-tei; do
  ./scrubbed extract \
    --input examples/corpus/extract-formats/inputs/field-notes.html \
    --output /tmp/field-notes.$format \
    --format $format
done
```

| Format | Scope | What this fixture shows |
| --- | --- | --- |
| `tree-json` | Whole parsed tree, **not** main-content-aware | Every node, including nav/header/footer chrome and the comment section, as ordinary tree nodes |
| `markdown` | Whole page | Same chrome/comments as `tree-json`, rendered as real Markdown: `#`/`##` headings, `**bold**`/`*italic*`, `[text](url)` link, `![alt](url)` image, `-` list, `>` blockquote, a GFM pipe table, a fenced code block |
| `main-content-markdown` | Selected `<article>` subtree only | Same structural elements as `markdown`, but nav/header/footer chrome **and** the comment section (a sibling of the selected node, not part of its subtree) are excluded |
| `csv` | One metadata/content row | 11 tab-delimited columns (see "CSV" below); table/list/quote/code all fold into the flat `text` column, comments into their own `comments` column |
| `xml` | Selected content + a sibling `<comments>` | Real structured XML: `<table>`/`<row>`/`<cell>`, `<list>`/`<item>`, `<quote>`, `<code>`, `<link>`/`<image>`/`<bold>`/`<italic>`, plus `<comments>` |
| `xml-tei` | Selected content + a sibling `<div type="comments">` | TEI P5 tags (`<ab>`/`<p>`/`<list>`/`<quote>`/`<hi>`/`<ref>`/`<graphic>`); the table **degrades** to `<list rend="table">` -- see "Documented non-applicable combinations" below |

Every one of these six recipes, `--format`'s exact required/no-default
shape, and the full accepted-format list is verified directly against
`source/cli_commands.d`'s own `Extract` command struct and its
`--format`-related unittests (~line 868-885) while authoring this example.

## Why `include-comments` needs `run --stage`, not `extract`

Issue #475's real CLI/JSON wiring for the comment-extraction opt-out is
`html-main-content`'s `include-comments` boolean option (default `true`),
declared in `source/effects/html_main_content_stage.d`. **None of
`extract`'s own six format-stage registrations declare that option** --
verified by reading every one of them:

- `source/effects/html_tree_json_stage.d` (`html-tree-json`)
- `source/effects/html_markdown_stage.d` (`html-markdown`)
- `source/effects/html_main_content_markdown_stage.d`
  (`html-main-content-markdown`)
- `source/effects/extract_formats_stage.d` (`html-csv`/`html-xml`/`html-xml-tei`)

Every one of these six stages declares only `charset`/`max-html-bytes` as
options. `xml`/`xml-tei`/`csv` always call `extractMainContent(tree)` with
its default `includeComments=true` (see `effects/extract_formats.d`'s own
`renderXml`/`renderXmlTei`/`csvRow`) -- their comment section is always
computed and included when the page has one; there is no `extract`-level
flag to turn it off. `main-content-markdown` renders only the selected
node's own subtree (`renderMarkdownFrom(tree, result.node, ...)`) and never
includes the separately-detected comment text at all, in either direction
(see `effects/html_main_content_markdown.d`'s `MainContentMarkdownResult`,
which has no `.comments` field). `tree-json` is not main-content-aware at
all, so "opt out of comments" has no meaning there either -- the whole tree,
comments included, is always the output.

This is a real, disclosed wiring gap in `extract` itself, not an oversight
in this example: the manifest's `claims.extractExposesIncludeComments` is
`false`, and `check.d` rejects a manifest mutant claiming otherwise.

To demonstrate the real opt-in/opt-out mechanism, this example instead
hand-composes `html-main-content` directly with `run --stage` (the same
justification `pii-policy/README.md` already gives for its own non-preset
stage composition):

```sh
# opt-in (default): include-comments defaults to true
./scrubbed run --input field-notes.html --output on.txt \
  --sidecar-output on.document-metadata.json \
  --stage main=html-main-content \
  --stage pub=document-metadata-publish

# opt-out: comments are never scanned for at all, not merely filtered after
./scrubbed run --input field-notes.html --output off.txt \
  --sidecar-output off.document-metadata.json \
  --stage main=html-main-content \
  --stage-option include-comments=boolean:false \
  --stage pub=document-metadata-publish
```

`html-main-content`'s own primary output (`on.txt`/`off.txt`) is
**byte-identical either way** -- `include-comments` only gates whether the
comment section is scanned and recorded, never the primary flattened
content. The real, visible difference is in the sidecar:

- **opt-in** (`on.document-metadata.json`): one `extension` field, key
  `"comments"`, `sourceStage: "html-main-content"`, hex-encoded real comment
  text.
- **opt-out** (`off.document-metadata.json`): `extension` is an **empty
  array** -- not a comments field present-but-suppressed, but no scan at
  all (matching trafilatura's own `--no-comments`: "comments suppressed,
  not computed and discarded").

`documentId` is `doc:v1:sha256(scheme, --input's own absolute path,
record)` -- deterministic per invocation, but not a function of file
content (identical to `pii-policy`'s own documented behavior). The checker
and this directory's pinned goldens account for this by substituting the
run's own `documentId` for the literal token `<DOCUMENT_ID>` before
diffing.

## Metadata fields: out of this slice

Issue #476's expanded metadata fields (site name, description, categories,
tags, license, beyond title/author/date/url) are **not reachable through
`extract` at all**: `extract`'s six format stages never run
`html-metadata-annotate`/`document-metadata-publish`, and declare no
metadata-field option of their own (same verification as the
`include-comments` finding above). Those fields are wired through the
separate `route-metadata` command instead (see
[docs/metadata-route.md](../../../docs/metadata-route.md)), which is issue
#508's own sibling slice, worked separately/concurrently. This example does
not duplicate that coverage -- see the manifest's `crossReferences.
expandedMetadataFields` field for the same statement in machine-checked
form.

## CSV

```sh
./scrubbed extract --input field-notes.html --output field-notes.csv --format csv
```

One tab-delimited row, columns matching `effects/extract_formats.d`'s own
doc comment exactly (mirroring pinned trafilatura==2.2.0's real
`--output-format csv` shape): `url, id, fingerprint, hostname, title,
image, date, text, comments, license, pagetype`. In this fixture:

- `url`/`id`/`fingerprint`/`hostname`/`image`/`date`/`license`/`pagetype`
  are all `null` (not available from a local-file `extract` invocation).
- `title` is `"Delta Survey Field Notes"` (from the real `<title>`).
- `text` carries the flattened selected content, including the fixture's
  deliberately embedded double quote (`the department, which calls it the
  "reference dataset"`) -- RFC 4180-quoted with the quote doubled, a real
  CSV round-trip, independently verified against Python's own `csv` module
  while authoring this corpus.
- `comments` carries the detected comment section's flattened text (always
  on -- see "Why `include-comments` needs `run --stage`" above).

## Documented non-applicable combinations

Not every format can represent every structural element; each gap below is
a real, disclosed design choice already documented in
`effects/extract_formats.d`'s own doc comments, not a silent omission:

- **CSV has no table/list/quote/code structure at all.** A page's table
  (and every other block element) folds into the same flat, whitespace-
  collapsed `text` column as ordinary prose -- there is no per-table CSV
  row/column encoding. `check.d`'s `checkCsvStructuralFidelity` confirms the
  table's real cell text still reaches the `text` column, just as flattened
  text, not as table structure.
- **XML-TEI has no `<table>`/`<row>`/`<cell>` at all.** Pinned
  trafilatura==2.2.0's own bundled `tei_corpus.dtd` (the exact schema this
  format validates against -- see "Real TEI-DTD validation" below) has no
  declaration for those three elements; a table degrades to
  `<list rend="table">` (one `<item>` per row, cells joined by `" | "`, a
  header cell wrapped in `<hi rend="bold">`) instead. Generic `xml` is
  unaffected -- it has no DTD to satisfy and keeps full `<table>`/`<row>`/
  `<cell>` structure (confirmed in this example's own golden).
- **XML-TEI has no `<code>` element either.** `<pre>`/inline `<code>`
  degrade to `<hi rend="code">` (block code wrapped in a `<p>`), the same
  disclosed reason: not declared in the pinned DTD.
- **`main-content-markdown`/`tree-json` and the `include-comments` toggle**
  -- see "Why `include-comments` needs `run --stage`, not `extract`" above.
- **Expanded metadata fields** -- see "Metadata fields: out of this slice"
  above.

## Real TEI-DTD validation

Acceptance criterion: XML-TEI output must be checked against a **real** TEI
validator, not assumed well-formed. This example provides both levels,
mirroring issue #481's own established two-tier approach:

1. **`check.d`** (release-active, dependency-free, gates every ordinary run
   of this checker): well-formedness only, via dxml's real streaming parser
   (`dxml==0.4.5`, already a pinned repository dependency -- the exact
   mechanism `effects/extract_formats.d`'s own unittests already use for
   the same purpose). No Python, no network.
2. **`validate_tei.sh`/`validate_tei.py`** (this directory): **real DTD
   validation** of the pinned `field-notes.tei.xml` golden against pinned
   trafilatura==2.2.0's own bundled `tei_corpus.dtd`, using
   `lxml.etree.DTD(...).validate(...)` -- the same real mechanism
   trafilatura's own `--validate-tei` uses, and the same `uv venv` + pinned-
   install + `uv pip freeze` verification idiom `experiments/
   html_main_content/compare_trafilatura_extract_formats.sh` already
   established in this repository. Requires `uv` and network access (to
   install pinned `trafilatura==2.2.0`/`lxml` the first time). Like that
   experiments-dir script, it sits outside `dub build`/`dub test` -- a
   real, rerunnable evidence script, not a CI gate:

   ```sh
   examples/pipelines/extract-formats/validate_tei.sh
   ```

   Run while authoring this example: **VALID** -- pinned trafilatura==2.2.0's
   own bundled DTD accepts `field-notes.tei.xml` exactly as checked in.

## Checker

```sh
ldc2 -O -release -preview=dip1000 -i -Isource \
  $(dub describe --data=import-paths | tr ' ' '\n' | grep dxml) \
  -of=.dub/extract-formats-check examples/pipelines/extract-formats/check.d
dub build -b release
.dub/extract-formats-check ./scrubbed
```

The checker validates the corpus manifest (schema, license hash,
per-artifact provenance/license/hash, recipe argument shapes) and a
handful of negative manifest mutants (including the two disclosure claims
above), then from a clean temporary directory against the release binary:

- runs all **six** `extract --format=...` modes, byte-diffs each against
  its own pinned golden (`tree-json`'s `documentId`/`sourceKey` are
  path-dependent, not content-dependent, and are normalized to
  `<DOCUMENT_ID>`/`<SOURCE_KEY>` first -- the same normalization
  `pii-policy`/`clean-web-document`'s own checkers already apply to their
  sidecars)
- asserts real structural fidelity for every element the fixture carries
  (heading/bold/italic/link/image/list/quote/table/code), for both
  Markdown modes and both XML modes -- not just "didn't crash"
- confirms `xml`/`xml-tei` are well-formed via dxml's real parser
- decodes the `csv` row with a real, bounded RFC 4180 parser (independently
  cross-checked against Python's own `csv` module while authoring this
  corpus) and asserts the exact 11-column schema and content
- confirms `tree-json` still carries the comment section and nav chrome
  (it is not main-content-aware)
- runs the `include-comments=true`/`false` pair via `run --stage
  html-main-content`, byte-diffs the primary output (asserting it is
  identical either way) and the normalized sidecar against pinned goldens,
  and positively asserts the opt-in sidecar's one `"comments"` extension
  field and the opt-out sidecar's empty `extension` array

Adversarial self-test performed while authoring this example: corrupting
one byte of a pinned golden (`field-notes.xml`) makes the checker fail
loudly with `artifact hash drift: ...field-notes.xml` (caught by the
manifest's own pinned SHA-256, before any recipe even runs); reverting the
byte restores a clean pass.
