# Deterministic HTML metadata (`html-metadata`)

Opt-in v3 stage that extracts `<head>` metadata from an HTML document and
publishes it as a side output, without touching the document's content.

## Usage

Import `effects.html_metadata_stage` to register the stage, then select
`html-metadata` in a job. It:

- Maps the same typed `DocumentId`; input `Content` passes through
  unmodified.
- Carries the extracted UTF-8 `metadata-json:v2` bytes as a single
  `TerminalSideOutput` (schema `metadata-json-v2`) — it does not overwrite
  the document, and needs no paired file, output sink, network fetch, or
  model.
- Registers `StageCardinality.oneToOne` and `SideOutputCapability.terminal`,
  so a quarantined/rejected event still carries a (payload-empty) side
  output internally, to satisfy that capability's per-event invariant
  (`composition/executor.d`'s `validateCapabilities`, unconditional over
  every event regardless of kind). That placeholder is not filtered out
  automatically — each publication path is responsible for gating on
  `event.kind == EventKind.emitted` before publishing a side output.
  `metadata_route_cli.d` does this for its own quarantine handling, and
  `cli.d`'s general `run`-command publication loop does the same (fixed in
  #294; before that fix, the general `run` command published the
  placeholder as a spurious empty sidecar file for quarantined/rejected
  events).
- Reads through the existing restricted `HtmlTree` boundary: 64 KiB
  raw/decoded, plus its node, depth, and attribute limits.

`route-metadata` (see [docs/metadata-route.md](metadata-route.md)) does
*not* use this stage or its side output for its metadata sink — it compiles
`html-metadata-annotate` + `document-metadata-publish` instead, and reads
that job's `document-metadata:v1` terminal side output. This stage's own
`metadata-json:v2` format remains live through other paths (for example
`cli.d`'s generic `--stage id=html-metadata` composition), just not through
`route-metadata`.

## Fields and priority

Only `<head>` evidence is considered, in this fixed wire order. Lower
priority number wins:

| Field | Priority 0 | Priority 1 | Priority 2 |
| --- | --- | --- | --- |
| `title` | `meta property=og:title` | `<title>` text | |
| `author` | `meta name=author` | `meta property=article:author` | |
| `date` | `meta property=article:published_time` | `meta name=date` | |
| `url` | `link rel=canonical` | `meta property=og:url` | |
| `rights` | `link rel=license` | `meta name=dc.rights` | `meta name=copyright` |

Matching is exact — attribute name and kind both matter (`property=og:title`
never matches `name=og:title`), with no permissive token, case, or
schema.org interpretation.

Within one priority, identical values deduplicate for selection, but every
observation stays a candidate. Distinct values at the winning priority make
the field `ambiguous` (abstains). A lower-priority disagreement sets
`conflict: true` while the higher-priority value still wins. Candidates keep
tree order and are capped at 16 per field; more evidence makes the field
`overflow` (abstains). Nothing is inferred from a local path or
`SourceLocator`.

## Validation

- **Text fields** (`title`, `author`): Unicode whitespace collapsed and
  trimmed, capped at 512 UTF-8 bytes.
- **`date`**: a valid calendar `YYYY-MM-DD`, or an ISO-style timestamp with
  seconds and an explicit `Z`/numeric offset. Timestamps emit only their
  date portion — no timezone conversion.
- **`url`**: absolute `http://`/`https://` only, nonempty non-bracketed
  host, numeric port 1–65535 if present. No whitespace, userinfo, quotes, or
  backslashes; relative URLs abstain. Bracketed IP-literal authorities
  (including valid IPv6) are unsupported and abstain in this slice — a
  valid lower-priority `og:url` can still win. This is a deliberately narrow
  rule, not a general URL canonicalizer.
- **`rights`**: `link rel=license`'s `href` uses the exact same absolute-URL
  rule as `url` (same abstention behavior on relative/userinfo/malformed
  port/bracketed-IP-literal), so an invalid `link:license` href abstains and
  a valid lower-priority `dc.rights`/`copyright` can still win. `dc.rights`
  and `copyright` are free text — same whitespace/512-byte rule as the other
  text fields, no URL shape requirement, since both are typically prose
  (e.g. `"© 2024 Example Corp. All rights reserved."`). `rights` stores the
  declared value or link as-is; this slice does not fetch, interpret, or
  classify license terms, and an absent declaration stays `absent`, never
  defaulted.

Empty or invalid observations set `invalidEvidence`. If no valid candidate
remains, status is `invalid` (rejected evidence was present) or `absent`
(none was). Malformed/unsupported-charset documents, invalid UTF-8, and
parser/resource-limit failures quarantine the whole document with bounded
reason codes; one invalid field does not quarantine the others. Reasons
never include source bytes or paths.

## Wire format: `metadata-json:v2`

Fixed key order, no insignificant spaces, one trailing LF. Top-level keys:
`version`, `documentId`, `fields`. Each field has `status`, `value`, `rule`,
`node`, `conflict`, `invalidEvidence`, `overflow`, `candidates`; a candidate
has `value`, `rule`, `node`. `value`/`rule`/`node` are null unless selected.
Nodes are selected-tree preorder ordinals — evidence pointers, not source
offsets. The payload omits source locator and output name.

The complete output is capped at 32 KiB; exceeding it quarantines as
`outputLimit`.

`metadata-json:v1` had four fields (no `rights`). `v2` is additive at the
field level: `rights` appends after `url`; the other four fields' semantics,
priority, and JSON shape are unchanged. A later format needs its own
version — JSON-LD/schema.org evidence, rights enforcement, and model-based
inference are explicitly out of scope for `v2`.

## Testing

`experiments/metadata/check.d` is the D-only checker. Compile with an
optimized release LDC build linked to the existing Lexbor static library
after project dependencies are built. Its small, pinned synthetic hold-out
reports field precision among selected values and abstention — a regression
fixture, not a live-web quality estimate.

`experiments/metadata/fetch_held_out.sh` is a separate, held-out real-page
evaluation tier alongside that synthetic fixture — deliberately outside the
`dub build`/`dub test`/release-active-checker path, with no pass/fail gate,
mirroring `experiments/html_main_content/fetch_held_out.sh`'s exact
acquisition idiom (issue #229's acquisition-boundary decision: real
third-party content usable for test-only reporting, pinned by an exact
upstream commit, fetched transiently, never vendored). It clones
`adbar/trafilatura` at the same pinned commit #26 already uses
(`1e31e3e9eb2e4f6fbfd4bc04355bc74005a780e6`) and scores this module's real,
unmodified `extractHtmlMetadata`/`parseHtml` against a fixed 43-URL subset
of that corpus's own `tests/evaldata.json` gold annotations: every 20th
entry (by lexicographic key order) among the 851 of 990 total entries (at
that commit) whose value has all three of `"author"`, `"title"`, and
`"date"` present as keys — a fresh selection from the metadata-bearing
entries, not a reuse of #26's own 20-URL main-content subset. Multi-value
`"author"` gold (a JSON array) is joined with `"; "` before comparison,
matching trafilatura's own `tests/eval_authors.py` convention.

A real run of that 43-URL subset measured: `title` 21/41 exact matches with
gold present (51.2%, 40/43 selected, 2 ambiguous), `date` 16/37 (43.2%,
17/43 selected, 1 invalid), `author` 3/28 (10.7%, 9/43 selected), and `url`
39/42 (92.9%, 41/43 selected) — one of the 43 pages
(`maescot.de.schafskunde.html`) failed this codebase's own `HtmlTree`
decode step (quarantine reason `decode`) and is excluded from every
field's count (42 resolved). `url`'s gold is each entry's own corpus dict key, which a correct
`link:canonical`/`og:url` extraction can legitimately disagree with
(redirects, scheme/`www` normalization, tracking-parameter stripping), so
that field's number is a lower bound on real canonical-extraction quality,
not a defect count in itself — its high match rate here is a genuine
result, not a sign the metric is too easy. `author` and `date`'s low
numbers are real too, and this slice does not investigate why (a plausible
factor, not independently confirmed here: this stage only reads `<head>`
evidence against a fixed, narrow set of meta/link names, while a real
page's byline or dateline is often only present in body text or under a
tag name this priority table doesn't match) — this is an honest measurement
of how the shipped, unmodified rule set performs on real third-party pages,
not a live-web ceiling estimate, and nothing here is acted on: no
threshold, priority, or extraction-logic change follows from these numbers
in this slice.

Gold-set quirks disclosed by that run (see the script's own header comment
and its report's `quirks` object for the full accounting): one corpus entry
that has all three gold keys present but an empty string for some of them
(counted as `goldEmpty`, excluded from that field's accuracy denominator);
one entry whose evaldata.json dict key carries a verbatim trailing space
(the driver intentionally does not trim `urls_file` lines before corpus
lookup, unlike #26's driver, specifically so this key still resolves); and
elsewhere in the corpus, a small number of gold `date` values that are not
zero-padded ISO shape (e.g. `"2022-11-1"`) — this module's own `validDate`
never emits such a value, so those can only ever miss on exact-match,
independent of extraction quality.

Rollback is removing this opt-in module and its registration; no persisted
record or existing CLI behavior changes.
