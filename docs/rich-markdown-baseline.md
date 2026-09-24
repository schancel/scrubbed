# Rich HTML-to-Markdown behavior baseline

This document records the current `HtmlTree` to Markdown behavior. It is an
evidence slice, not a proposed rich-Markdown format. The converter, parser,
main-content boundary, caps, and emitted Markdown bytes are unchanged.

The authored fixtures are deliberately Wikipedia-like and ordinary-page
examples rather than downloaded pages. Their exact `.md` files pin the output
without importing third-party page content:

- `wikipedia-like.html` covers an infobox, merged-cell metadata, a figure,
  image attributes, internal IDs/fragments, citation-like markup, a hatnote,
  navigation-like content, and image-fallback mathematics.
- `ordinary-page.html` covers an aside-like notice, figure, rectangular and
  non-rectangular rows, internal fragments, and unsafe link/image targets.
- `malformed.html` records the parser-repaired table and unclosed caption/box
  result.
- `mathml.html` and `oversized-depth.html` pin typed parser abstentions.

## Current gap matrix

| Structure | Current exact behavior | Information retained | Gap or abstention |
| --- | --- | --- | --- |
| Rectangular tables | Every `tr` is a separate `- ` bullet; direct cells are joined by a pipe separator. Header and data cells render alike. | Cell visible text and row source order. | No rectangular grid, alignment, header identity, or GFM delimiter row. |
| Merged/non-rectangular tables | `rowspan` and `colspan` are ignored; rows may have different field counts. | Visible text in each parser-repaired row. | Span relationships and a trustworthy rectangular interpretation are lost. |
| Figure/caption | `figure` and `figcaption` are unknown wrappers, so visible children are emitted in order without a figure boundary. | Image Markdown, caption text, and safe caption links. | Caption role and image/caption association are lost. |
| Image attributes | A safe `src` plus escaped `alt` becomes `![alt](<src>)`. An unsafe or absent source emits alt text only. | Safe source and alt text. | Width, height, `srcset`, loading/referrer attributes, title, file identity, and provenance are dropped. |
| IDs and fragments | Every `id` is dropped. A safe `href="#id"` is emitted unchanged. | Fragment spelling on source links. | No target anchor is emitted, so an otherwise preserved fragment can dangle. |
| Citation-like markup | `sup` and citation spans unwrap; a safe fragment link remains an ordinary link; a references `ol` remains an ordinary numbered list. | Label text, reference text, source order, and safe fragment destination. | Citation identity, backlink/target semantics, and source/reference association are lost. |
| MathML | A real MathML namespace causes the whole selected parse to abstain with `unsupportedNamespace`. A common image fallback is treated as an ordinary image. | For an image fallback, safe source and alt text only. | Native MathML structure has no Markdown result; display/inline role and formula semantics are unavailable. |
| Box-like regions | Unknown `aside`/span wrappers unwrap; `div` creates a generic block. Classes such as hatnote, notice, navbox, and infobox are not classified. | Visible children, including navigation-like text. | Content boxes cannot be distinguished from page chrome; box identity and role are lost. |
| Malformed structure | Lexbor repairs the tree, then the converter renders the repaired order deterministically. | Visible repaired-tree text. | The Markdown does not signal that repair occurred or recover discarded span/role information. |
| Oversized structure/input | The depth fixture abstains with `depthLimit`; a raw input of `maxRawBytes + 1` abstains with `rawLimit`. | Typed failure reason only. | No partial Markdown or structural fallback is returned. |
| Oversized Markdown | Escaping a synthetic owned text node past 4 MiB throws `HtmlMarkdownOutputLimit`. | No partial output. | There is no truncated Markdown fallback. |

Exact goldens also pin leading whitespace currently produced by unwrapped
unknown wrappers. That whitespace is observed behavior, not a recommended
future representation.

## Evidence

The optimized checker compares all three successful conversions byte for byte,
renders each twice, and asserts the expected typed failures for MathML and
excessive nesting. It additionally checks:

- unsafe `javascript:` and `data:` destinations remain inert while visible
  link labels and image alt text survive;
- the authored exact outputs contain no unrecorded/invented prose;
- caller input can be overwritten after parsing without changing the owned
  tree's output;
- raw-input cap+1 and escaped-output cap+1 fail without partial Markdown; and
- rich attributes and box/ID roles remain absent rather than silently gaining
  semantics.

Run it from the repository root after DUB has built the native Lexbor library:

```sh
ldc2 -O3 -release -Isource \
  -of=.dub/rich-structure-baseline \
  experiments/html_markdown/rich_structure_baseline.d \
  source/effects/html_markdown.d source/effects/html_tree.d \
  source/effects/lexbor_ffi.d source/text/decoding.d \
  .dub/lexbor/liblexbor_static.a
.dub/rich-structure-baseline
```

## Decisions still owned by @schancel

The evidence does not select among these representation and fallback choices.
Before production work, the owner should answer each question with exact
emitted syntax and bounds:

1. For a rectangular table, should output use a GFM pipe table, bounded raw
   HTML, or the existing linear row form? What is the exact fallback when a
   cell contains blocks, a row is ragged, or row/column/cell counts exceed
   their bounds?
2. For `rowspan`/`colspan`, should a bounded raw HTML table preserve the
   spans, should cells be expanded/duplicated into a grid, or should the table
   explicitly fall back to linear rows? Which malformed span values force
   abstention rather than repair?
3. Which structural and attribute evidence makes an infobox/aside/callout
   content rather than chrome? What exact representation identifies a kept
   box, and does ambiguous or over-bound content unwrap, disappear, or cause
   the containing document to abstain?
4. Should bounded MathML be emitted as raw `<math>`, translated to a selected
   math syntax, reduced to authored alternative text, or cause a typed
   abstention? Define inline/display handling plus byte, depth, node, and
   attribute bounds and the exact over-bound fallback.
5. Should a figure use ordinary image Markdown plus a separately marked
   caption, bounded raw `<figure>`, or another exact syntax? Where do width,
   height, selected source/`srcset`, title, original URL, and capture
   provenance live, and which are omitted when untrusted or over-bound?
6. Should source IDs become raw `<a id="...">` anchors, an explicitly chosen
   Markdown attribute syntax, or a deterministic rewritten identifier? How
   are collisions and unsafe IDs handled, and must local fragment links be
   rewritten or dropped when their target is absent?
7. Do citation-like source/target pairs become a selected footnote syntax,
   remain ordinary links and anchors, or retain bounded HTML? What happens to
   duplicate labels, missing targets, backlinks, nested markup, and citations
   beyond the configured bound?

Rollback for this slice is deletion of this document, the checker, and the
`fixtures/rich` directory. No production compatibility or migration promise
is created by these baselines.
