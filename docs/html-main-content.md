# Deterministic main-content-vs-boilerplate selection

`effects.html_main_content.extractMainContent(const ref HtmlTree)` is a pure,
deterministic scoring/selection algorithm over `effects.html_tree`'s existing
restricted, bounded, D-owned selected tree. It answers the genuine *selection*
question the three existing HTML consumers (`html-metadata`, `html-markdown`,
`html-tree-json`) do not make: is this subtree the article, or is it
nav/ad/footer/related-links chrome? This is a pure, unwired seam: it registers
no v3 `stages.registry` transform and no v4
`extraction.ExtractorRegistrationV1`, and does not change `source/cli.d` or
`benchmarks/external_comparator.d`. The stable, versioned function signature
and result type are the candidate interface a later wiring slice and the
saved-HTML comparator case on #229 are waiting on — not full #26 completion.

## Algorithm

One bounded pass walks `tree.nodes` in **reverse pre-order index order** (no
recursion). Because the tree is flat pre-order, every descendant of a node is
the contiguous run of higher indices immediately following it; walking
backwards guarantees a child is fully scored, and has pushed its totals into
its parent's accumulators, before that parent's own turn in the loop. Per
node this tracks, purely from already-observed `HtmlNode` data:

- **cumulative text length**: total text under the subtree (script/style/
  template/head-descended text excluded — script/style are checked precisely
  since they are HTML5 RAWTEXT elements with only ever a direct text child;
  template/head are checked only one level deep as a documented
  simplification, unlike `html_markdown.d`'s full ancestor walk used for the
  final text-extraction step below);
- **link density**: cumulative text inside any `<a>` element divided by
  cumulative text overall — the strongest established deterministic
  boilerplate signal, so it *discounts* the rest of the score
  (`finalScore = base * (1 - linkDensity)`) rather than being an independent
  additive term;
- **own direct text**: text length contributed only by a node's immediate
  text-node children (not recursive) — this is what lets a container win
  over the whole document: a generic wrapper (`html`, `body`, an unclassed
  `div`) has no own direct text of its own and gets no credit just for
  containing everything beneath it;
- **paragraph-sibling clustering**: the summed cumulative text of direct
  `<p>` children that individually clear a 40-byte floor, plus a small flat
  bonus per qualifying paragraph (capped at 12) — this is what lets a
  container that wraps several substantial paragraphs (an `<article>`, a
  `<div class="post-content">`) outscore any single paragraph inside it;
- a fixed **content-vs-boilerplate tag-name table**: `article`/`main`/
  `section`/`p` each add a flat bonus; `nav`/`aside`/`footer`/`header`/
  `form`/`button`/`figure` each subtract the same amount;
- a fixed **class/id keyword table**, matched as an ASCII case-insensitive
  substring of the node's `class` or `id` attribute value: `content`/
  `article`/`main`/`post`/`body`/`entry` each add a bonus;
  `nav`/`sidebar`/`footer`/`header`/`comment`/`menu`/`ad`/`advert`/`promo`/
  `share`/`social`/`related`/`widget`/`breadcrumb` each subtract it. A short
  keyword such as `ad` is a blunt substring match (for example `thread`
  contains `ad`); this is the fixed table the contract specifies, not a
  smarter word-boundary matcher, and `experiments/html_main_content/check.d`
  pins its exact membership so an edit is caught as a drift.

Both tables and every weight/threshold constant are private to
`source/effects/html_main_content.d`; `positiveContentTags`,
`negativeContentTags`, `positiveKeywords`, and `negativeKeywords` are
exported so the checker can assert their exact membership directly, in
addition to asserting specific scores that would change if a weight drifted.

## Selection and abstention

Selection is one documented rule: the highest-scoring element node wins.
Three abstentions, mirroring `html_metadata.d`'s typed-decision/abstention
idiom, are explicit rather than a best-effort guess:

- `abstainedNoCandidate` — no element node exists at all (only reachable
  from a degenerate/empty `HtmlTree`; real parsed HTML always has at least
  a root element, so this status is a defensive floor, not something the
  authored fixtures below exercise);
- `abstainedBelowThreshold` — the top-scoring candidate's cumulative text is
  under 200 bytes, or its score is under 150, whichever binds first. Both
  sub-conditions are exercised separately: a page that is almost entirely
  navigation links (high raw text, but link-density- and tag-suppressed to
  a near-zero score) fails on score with its length already sufficient; a
  short, correctly `<article class="article-content">`-tagged update (a
  strong score signal) fails on length with its score already sufficient;
- `abstainedTie` — the top score is shared by more than one candidate (for
  example two structurally and textually identical `<article>` blocks).

`MainContentResult` reuses `html_metadata.d`'s `MetadataField`-style typed
decision shape: a status, the winning node index and score when selected,
and a bounded top-16 candidate list (`maxMainContentCandidates`) for audit —
useful for inspecting a nav/ad/footer near-miss even when it did not win —
plus a `candidatesOverflow` flag when more than 16 element nodes were
scored. Candidates carry only a node index, score, cumulative text length,
and tag name: never raw page text, so the candidate list is safe to log or
report even for real third-party pages. This is a deliberate strengthening
over `html_metadata.d`'s plain-string `status` field: the contract calls for
"a status enum", so `MainContentStatus` is a real D `enum` rather than a
string, while keeping the same decision shape (status, selection, bounded
candidates).

Selected text is owned, whitespace-collapsed (including across text-node and
element boundaries, with control/format characters dropped) UTF-8, capped at
4 MiB — the same order of magnitude as `html_markdown.d`'s
`maxMarkdownBytes` — using the same bounded throw-on-overflow `Writer`
idiom used throughout `source/effects/`. `extractMainContent` throws
`HtmlMainContentOutputLimit` before returning any result if the selected
node's collapsed text would exceed the cap, so no partial text is ever
observable.

## Proof

`experiments/html_main_content/check.d` is D-only, network-free, and has no
dependency on the held-out acquisition tier below (it is never invoked by
`fetch_held_out.sh`, and `fetch_held_out.sh` is never invoked by it or by
`dub test`/`dub build`). Build and run it from the repository root after DUB
has built the native Lexbor library:

```sh
ldc2 -O3 -release -Isource -of=/tmp/html-main-content-check \
  experiments/html_main_content/check.d source/effects/html_main_content.d \
  source/effects/html_tree.d source/effects/lexbor_ffi.d \
  source/text/decoding.d .dub/lexbor/liblexbor_static.a
/tmp/html-main-content-check
```

It checks, against the authored, synthetic, hashed-by-source-control
fixtures in `experiments/html_main_content/fixtures/**` (news-article-shaped,
blog-post-shaped, docs-page-shaped, forum-thread-shaped, plus three
adversarial cases: nav-heavy near-empty body, two competing article blocks,
and a below-minimum-length article):

- exact selected node index, score, and collapsed text for every selected
  case, and exact status for every abstention case, including both
  `abstainedBelowThreshold` sub-conditions and `abstainedTie`;
- repeat-call determinism for every fixture;
- the fixed tag/keyword table membership and specific scores that would
  change if a weight drifted (golden drift detection);
- the 4 MiB output cap throwing before any partial text is observable, and
  staying stable across a repeat call on the same tree;
- the top-16 candidate bound and its overflow flag under 41 element
  candidates.

`source/effects/html_main_content.d` also carries its own `unittest` block
against hand-built `HtmlTree`/`HtmlNode` values (no native parser
dependency), covering the same abstention paths plus a direct proof that
`script` text never contributes to a score or leaks into extracted text.
Both are exercised by `dub test --build=release-unittest`, which needs no
extra flags for this module.

## Held-out real-page tier (separate, non-gating)

`experiments/html_main_content/fetch_held_out.sh` is a **separate**
acquisition-and-reporting script, outside the normal `dub build`/`dub
test`/release-active-checker path entirely (mirroring how `cli_baseline.d`'s
`uv pip install` sits outside the normal build/test gate). It is not required
to pass, or even to run, for this ticket to land; the authored-fixture-tier
proof above is what gates the release-active checker.

It `git clone`s `adbar/trafilatura` at one pinned commit
(`1e31e3e9eb2e4f6fbfd4bc04355bc74005a780e6`) into a private temporary
directory, verifies the checked-out commit matches, reads a fixed,
reproducible selection of 20 held-out URLs out of that clone's own
`tests/evaldata.json` (trafilatura's own published eval corpus and
annotations, Apache-2.0 licensed, fetched for a run and never vendored into
this repository's git history or shipped in the release binary/package —
identical to the policy already recorded on #229's 2026-09-26 "public
package acquisition boundary" decision), resolves each page's saved HTML
from that clone's `tests/cache`/`tests/eval`, compiles a throwaway D driver
into that same temporary directory (also never committed), scores each page
with `extractMainContent`, and prints one JSON report before deleting the
entire temporary directory (including the cloned corpus) on exit:

```sh
dub build --build=release   # once, so the native Lexbor library exists
experiments/html_main_content/fetch_held_out.sh
# or: experiments/html_main_content/fetch_held_out.sh /path/to/report.json
```

The metric is word-level, case-normalized, whitespace-tokenized multiset
overlap: `precision = |overlap|/|extracted tokens|`,
`recall = |overlap|/|gold tokens|` — the same family trafilatura's own
benchmark script (`tests/eval_common.py`) uses, for comparable numbers.
trafilatura's real corpus annotates each page with short `with` (must
appear) and `without` (must not appear) probe phrases rather than a full
annotated gold article, so "gold tokens" here is the concatenated `with`
phrases for that page, not the whole article. Precision against that small a
gold set reads low by construction (a correct, much longer extraction still
has a tiny token-count denominator match); the report's own `metricNote`
field says this, and **recall** and **`withoutLeakTotal`** (a substring leak
count of `without` chrome phrases into the selected text) are the more
informative signals from this corpus's actual shape. This is quality-matched
reporting, not a trafilatura-parity claim.

A real run against the 20 pinned pages (2026-09-26, this ticket's
implementation) selected 12, abstained 0, and could not parse 8 — every
`parseFailed` case was `unsupportedNamespace`, i.e. `html_tree.d`'s existing,
out-of-scope-to-change restriction to the HTML namespace rejecting a page
with embedded SVG, not a defect in this module. Across the 12 scored pages:
mean precision ≈0.053 (expected, per the gold-set-size caveat above), mean
recall ≈0.78, and `withoutLeakTotal` was 0 — no `without` chrome phrase
leaked into any selected extraction. One page (`france.attc.org-privatisations.html`)
selected a `<select>` element with recall 0.11, a clear, named nav/ad/footer-
style failure example: a real page whose actual main content this first-
slice algorithm did not find.

No raw held-out page bytes and no `with`/`without` annotation text are ever
placed into the report or into any exception/diagnostic, in either the
shell script or the driver it compiles: only bounded counts, status/reason
names, node tag names, and numeric scores.

## Non-goals

No v3/v4 stage or extractor registration of any kind; no `cli.d`/`app.d`
change; no `benchmarks/external_comparator.d` change; no network fetch
inside the release-active checker itself; no trafilatura-parity claim; no
Mozilla-Readability/jusText/readability-library port; no model/LLM
extraction; no change to `html_metadata.d`, `html_markdown.d`, `html_tree.d`,
or `html_tree_export.d` or their stages. The `abstainedNoCandidate` status is
exercised only by `source/effects/html_main_content.d`'s own unit test
against an empty `HtmlTree`, not by an authored HTML fixture, since real
parsed HTML always yields at least one element candidate. Script/style
hidden-text exclusion during scoring checks only the immediate parent tag
(correct for script/style, which are HTML5 RAWTEXT elements); template/head
exclusion during scoring is a one-level-deep simplification, unlike the full
ancestor walk `html_markdown.d` uses and that this module's own final
text-extraction step also uses. This is a first slice: the v3-vs-v4
registration/wiring decision, CLI/comparator reachability, and the pinned
trafilatura quality comparison itself remain for later, separately-scoped
work.
