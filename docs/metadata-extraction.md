# Deterministic HTML metadata slice

Import `effects.html_metadata_stage` to register the opt-in `html-metadata`
stage, then select it in a canonical version-3 job. It accepts HTML `Content`
and maps the same typed `DocumentId` to UTF-8 `metadata-json:v2` `Content`; it
does not need a paired file, output sink, network fetch, or model. The input
follows the existing restricted `HtmlTree` boundary and its 64 KiB raw/decoded,
node, depth, attribute, and observation limits.

Only `<head>` evidence is considered. The five fields are `title`, `author`, `date`, `url`, and `rights`, in that wire order. Rules and priority (lower number wins):

| Field | Priority 0 | Priority 1 | Priority 2 |
| --- | --- | --- | --- |
| title | `meta property=og:title` | `<title>` text | |
| author | `meta name=author` | `meta property=article:author` | |
| date | `meta property=article:published_time` | `meta name=date` | |
| url | `link rel=canonical` | `meta property=og:url` | |
| rights | `link rel=license` | `meta name=dc.rights` | `meta name=copyright` |

Names, attribute kinds, and values are matched exactly as selected by the HTML tree: `property=og:title` does not mean `name=og:title`. There is no permissive token, case, or schema.org interpretation. Within a priority, identical values deduplicate for selection but every observation remains a candidate. Distinct values at the winning priority make the field `ambiguous` and abstain. A lower-priority disagreement sets `conflict: true` while the higher-priority value wins. Candidates remain in tree order, capped at 16 per field; further evidence makes that field `overflow` and abstain. Nothing is inferred from a local path or `SourceLocator`.

Values collapse Unicode whitespace and trim the edges, with a 512-byte UTF-8 cap. Dates must be a valid calendar `YYYY-MM-DD` or an ISO-style timestamp with seconds and explicit `Z` or numeric offset; timestamps emit their written date portion, without timezone conversion. URLs require an absolute `http://` or `https://` authority with a nonempty non-bracketed host and, if present, a numeric port from 1 to 65535. Bracketed IP-literal authorities, including valid IPv6, are unsupported and abstain in this slice; a valid lower-priority `og:url` can then win. URLs also reject whitespace, userinfo, quotes, and backslashes; relative URLs abstain. These are deliberately narrow validation rules, not a general URL canonicalizer. Empty or invalid observations set `invalidEvidence`; if no valid candidates remain, status is `invalid` for nonempty rejected evidence or `absent` otherwise. Malformed or unsupported-charset documents, invalid UTF-8, and parser/resource limit failures quarantine the whole document with bounded reason codes; an invalid field does not quarantine other fields. Reasons never include source bytes or paths.

`rights`'s priority-0 evidence, `link rel=license`'s `href`, is validated with the exact same absolute-URL rule as `url`'s `link rel=canonical` (including the same relative/userinfo/malformed-port/bracketed-IP-literal abstention behavior), so an invalid `link:license` href abstains and a valid lower-priority `dc.rights` or `copyright` value can still win. `dc.rights` and `copyright` are free text: they are validated only by the same whitespace-collapse-plus-512-byte-cap rule as the other free-text fields, with no URL shape requirement, since both conventions are typically prose (for example "© 2024 Example Corp. All rights reserved.") rather than a link. `rights` stores the declared value or link as-is; this slice does not fetch, interpret, or classify license terms, and an absent declaration stays `absent`, never defaulted.

`metadata-json:v2` has a fixed key order, no insignificant spaces, and one trailing LF. Top-level keys are `version`, `documentId`, `fields`. Each field has `status`, `value`, `rule`, `node`, `conflict`, `invalidEvidence`, `overflow`, `candidates`; a candidate has `value`, `rule`, `node`. `value`, `rule`, and `node` are null unless selected. Nodes are selected-tree preorder ordinals and are evidence pointers, not source offsets. The complete output is capped at 32 KiB; exceeding it quarantines as `outputLimit`. The payload omits source locator and output name. `metadata-json:v1` had four fields (no `rights`); `v2` is additive at the field level, appending `rights` after `url`, with the other four fields' semantics, priority, and JSON shape unchanged. Later fields require a versioned format; JSON-LD/`schema.org` evidence, rights enforcement, and model-based inference are explicitly out of scope for this format.

The D-only checker is `experiments/metadata/check.d`. Compile with an optimized release LDC build linked to the existing Lexbor static library after project dependencies are built. Its small, pinned synthetic hold-out reports field precision among selected values and abstention; that report is a regression fixture, not a live-web quality estimate. Rollback is removal of this opt-in module and its registration; no persisted record or existing CLI behavior changes.
