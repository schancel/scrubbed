# `clean-web-document` flagship example

Demonstrates the sealed `clean-web-document/v1` preset -- mojibake repair,
then `html-metadata-annotate`, `html-main-content`, `pii-four-class`, and the
terminal `document-metadata-publish` sidecar -- in both single-file and
directory-tree modes. Corpus and fixtures are in
[`examples/corpus/clean-web-document/`](../../corpus/clean-web-document/);
exact provenance, media types, licenses, intended outcomes, and SHA-256
digests are in that directory's
[`manifest.json`](../../corpus/clean-web-document/manifest.json).

This is a scope note, not project-wide documentation: `docs/task-examples.md`
documents issue #259's `quickstart` example separately and is intentionally
left untouched by this ticket (out of its allowed file scope).

Build once from the repository root:

```sh
dub build --compiler=ldc2 --build=release
```

## Single-file mode

The canonical, sealed CLI form:

```sh
./scrubbed clean-web-document \
  --input examples/corpus/clean-web-document/inputs/single-file/hydrology-notebook.html \
  --output /tmp/scrubbed-cwd/hydrology-notebook.txt
```

Its byte-equivalent JSON-configuration form runs the same five stages
through the general-purpose `run` command instead of the sealed preset, using
the canonical v3 job this directory checks in
([`clean-web-document.json`](clean-web-document.json), itself produced
byte-for-byte by `clean-web-document --emit-config`):

```sh
./scrubbed run \
  --input examples/corpus/clean-web-document/inputs/single-file/hydrology-notebook.html \
  --output /tmp/scrubbed-cwd-cli/hydrology-notebook.txt \
  --sidecar-output /tmp/scrubbed-cwd-cli/hydrology-notebook.txt.document-metadata.json \
  --config examples/pipelines/clean-web-document/clean-web-document.json
```

Run from the identical resolved `--input` path, both forms compile to the
same canonical job identity and produce byte-identical content and sidecar
output -- see `check.d`'s own direct proof of this.

## Directory-tree mode

Identical shape, pointed at a directory instead of a file:

```sh
./scrubbed clean-web-document \
  --input examples/corpus/clean-web-document/inputs/directory-tree \
  --output /tmp/scrubbed-cwd-tree
```

Each input file's selected main content is published at
`<output>/<relative-name>` (the mirrored file keeps its input's `.html` name
even though its content is now plain text -- `run`/`clean-web-document`
never rename files by content type, unlike `extract`). The sidecar tree is a
sibling directory, `<output>.document-metadata/`, mirroring the input tree
with `.document-metadata.json` appended to each file's own output name.

## What the sidecar carries

`clean-web-document` automatically derives and writes a
`document-metadata:v2` sidecar beside `--output`:

- `<output>.document-metadata.json` for a file, or
- `<output>.document-metadata/` (mirroring the input tree) for a directory.

It **fails before touching anything** -- no input read, no output or sidecar
write -- if that derived path already exists; see the `clean-web-document-
sidecar-occupied` fixture in `check.d` for a real, executed proof (pre-create
the path, run the command, confirm exit 2, the pre-existing file left
byte-for-byte unchanged, and no primary output written at all).

Each sidecar carries, in one JSON blob:

- `standard`: `title`/`author`/`date`/`url`, each either `null` (no evidence
  was selected -- see `examples/corpus/clean-web-document/inputs/directory-
  tree/clean-record.html`, which has only a `<title>`) or `{"value":...,
  "sourceStage":"html-metadata-annotate"}`.
- `extension`: additive fields (e.g. a real comment section); empty for
  every fixture in this corpus.
- `structuredSections`: one `"pii-audit"` section (hex-encoded JSON payload,
  `sourceStage":"pii-four-class"`) with the four-class PII audit --
  `unions`, each a maximal overlap span with its `category` (`email`/
  `phone`/`card`/`ip`), matched `rule`, `locale`, `confidence`
  (`high`/`ambiguous`), and `outcome` (`reported` under the preset's default
  `report` policy -- content is never modified by this preset).

`document-metadata:v2`'s `documentId` field is a SHA-256 of (among other
inputs) the *resolved absolute filesystem path* passed as `--input`, so it is
different on every machine and every run; `check.d`'s own
`normalizeDocumentId` explains and handles this when byte-diffing sidecars
against the checked-in golden files.

## Corpus

Three directory-tree fixtures span a realistic mix in a small directory:
clean content with only a `<title>` (no PII, no mojibake), a mojibake-only
case (title and body both repaired), and a PII-only case (a synthetic US
phone number, flagged at `ambiguous` confidence). The single-file fixture
combines full title/author/date/url metadata, a mojibake byline, and a
synthetic email address in one page, so it alone exercises every stage's
positive path. All PII is synthetic (`example.org`/`(415) 555-01xx`, a
reserved fictional-use exchange) authored for this ticket -- see
`examples/corpus/quickstart/inputs`'s own "FranÃ§ois" mojibake fixture for
the identical repair pattern reused here.

## Disclosed, unsupported limitations

- `clean-web-document` is a **sealed** preset: no `--stage`/`--filter`/
  `--stage-option`/`--filter-option` override is accepted, by design (use
  `run` for custom stage/filter composition -- this example's own JSON form
  above is exactly that path).
- The default policy is `report`, not `mask`/`redact`: PII stays in the
  published content. This is a detection/audit demo, not a general-purpose
  anonymization tool (the manifest's `claims.generalPurposeAnonymization` is
  `false` and `check.d` rejects a manifest mutant claiming otherwise).
- `pii-four-class` recognizes exactly four ASCII forms (email, phone,
  payment-card, IPv4) with deterministic, bounded recognizers -- see
  `docs/pii-four-class-stage.md` -- not general PII/NER detection, and it
  never scans non-selected boilerplate (only the selected main content is
  scanned, since `pii-four-class` runs after `html-main-content` in the
  sealed chain).
- `html-main-content` selection has a real abstention floor
  (`minSelectableTextBytes`, 200 bytes of candidate text under the default
  `standard` extraction mode): a short or link-only page is quarantined with
  `abstainedBelowThreshold`, not force-published. Every fixture in this
  corpus is written well above that floor.
- Mojibake repair (`fix-mojibake`, default `latin1`/`cp1252`/`windows1251`
  encodings, 4 passes) is a conservative, scored repair, not general
  encoding detection -- it can only fix the mojibake shapes it recognizes.
- This is a tiny (well under 1 MiB), reproducible teaching corpus, not a
  training-ready dataset (`claims.trainingReady` is `false`).

## Reproduce the checked results

The release-active D checker validates the manifest and required negative
mutants, then runs both the sealed-preset CLI form and the byte-equivalent
JSON-config form -- in both single-file and directory-tree modes -- against
the real shipping binary from a clean temporary directory (never the dev
tree), byte-diffing real output and sidecar bytes against the checked-in
golden files. It also asserts the PII audit actually flags the synthetic
findings in the fixtures that carry them (not an empty union list) and that
the sidecar-occupied path fails cleanly without touching anything.

```sh
ldc2 -O -release \
  -of=.dub/clean-web-document-check examples/pipelines/clean-web-document/check.d
.dub/clean-web-document-check ./scrubbed
```
