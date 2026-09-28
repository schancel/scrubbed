# Deterministic main-content-vs-boilerplate selection

`effects.html_main_content.extractMainContent(const ref HtmlTree)` is a pure,
deterministic scoring/selection algorithm over `effects.html_tree`'s
restricted, bounded, D-owned selected tree. It answers the *selection*
question the other three HTML consumers (`html-metadata`, `html-markdown`,
`html-tree-json`) don't make: is this subtree the article, or is it
nav/ad/footer/related-links chrome?

**Wired and shipped**, not a standalone seam. `source/effects/html_main_content_stage.d`
registers `extractMainContent` as the self-registering v3 stage
`html-main-content` (commit `03d9a02`, issue #26's next-slice — see [v3 stage
registration](#v3-stage-registration) below). Two real consumers today:

- `benchmarks/external_comparator.d`'s `main-content/scrubbed-vs-trafilatura`
  case, which invokes it via `--stage content=html-main-content`.
- `source/job/presets.d`'s sealed `clean-web-document/v1` preset, in the
  chain `text-transform -> html-metadata-annotate -> html-main-content ->
  pii-four-class`.

What's still absent: a v4 `extraction.ExtractorRegistrationV1` registration.
That remains a documented [non-goal](#non-goals), not a gap in wiring.

## Algorithm

One bounded pass walks `tree.nodes` in **reverse pre-order index order** (no
recursion). Because the tree is flat pre-order, every descendant of a node is
the contiguous run of higher indices immediately following it; walking
backwards guarantees a child is fully scored — and has pushed its totals into
its parent's accumulators — before that parent's own turn in the loop.

Per node, purely from already-observed `HtmlNode` data, the pass tracks:

- **Cumulative text length** — total text under the subtree. Script/style/
  template/head-descended text is excluded: script/style are checked
  precisely (HTML5 RAWTEXT elements with only ever a direct text child);
  template/head are checked only one level deep as a documented
  simplification, unlike `html_markdown.d`'s full ancestor walk used for the
  final text-extraction step below.
- **Link density** — cumulative text inside any `<a>` element divided by
  cumulative text overall. The strongest established deterministic
  boilerplate signal, so it *discounts* the rest of the score
  (`finalScore = base * (1 - linkDensity)`) rather than being an independent
  additive term.
- **Own direct text** — text length contributed only by a node's immediate
  text-node children (not recursive). This is what lets a container win over
  the whole document: a generic wrapper (`html`, `body`, an unclassed `div`)
  has no own direct text and gets no credit just for containing everything
  beneath it.
- **Paragraph-sibling clustering** — the summed cumulative text of direct
  `<p>` children that individually clear a 40-byte floor, plus a small flat
  bonus per qualifying paragraph (capped at 12). This is what lets a
  container wrapping several substantial paragraphs (an `<article>`, a
  `<div class="post-content">`) outscore any single paragraph inside it.
- A fixed **content-vs-boilerplate tag-name table** — `article`/`main`/
  `section`/`p` each add a flat bonus; `nav`/`aside`/`footer`/`header`/
  `form`/`button`/`figure` each subtract the same amount.
- A fixed **class/id keyword table**, matched as an ASCII case-insensitive
  substring of the node's `class` or `id` attribute value:
  - Adds a bonus: `content`/`article`/`main`/`post`/`body`/`entry`.
  - Subtracts it: `nav`/`sidebar`/`footer`/`header`/`comment`/`menu`/`ad`/
    `advert`/`promo`/`share`/`social`/`related`/`widget`/`breadcrumb`/
    `registration-banner`.
  - A short keyword such as `ad` is a blunt substring match (for example
    `thread` contains `ad`); this is the fixed table the contract specifies,
    not a smarter word-boundary matcher. `experiments/html_main_content/check.d`
    pins its exact membership so an edit is caught as a drift.
- **Negative-tag-ancestor suppression** (issue #27) — a node nested at *any*
  depth inside a negative-tag container (`nav`/`aside`/`footer`/`header`/
  `form`/`button`/`figure`) never gets credit for its *own* positive tag or
  keyword match; only the positive-side contribution is zeroed, never turned
  into a new penalty, and a node's genuinely negative tag/keyword match on
  itself is untouched either way. Before this, a negative-tag container's own
  score was suppressed but that suppression never reached a descendant
  scored independently on its own terms — the real bug behind
  `france.attac.org`'s held-out failure, where a mailing-list signup form's
  own boilerplate legal paragraph (`<p class="explication">`, no keyword
  match either way, but nested inside that page's `<form>`) outscored the
  real article lede purely on raw text length plus the flat `<p>` tag bonus.
  Language-independent by construction (it keys off tag names, not any
  keyword table), so it also generalizes to that page's French-language
  content, unlike a keyword-table entry would.
- **Boilerplate exclusion during text collection** (issue #27) — collecting
  the selected subtree's text (not scoring) now also skips any descendant
  whose own class/id matches a negative keyword, the same way
  script/style/template/head are already skipped, plus one narrow structural
  case: a keyword-*neutral* element is skipped too when *both* its immediate
  previous and next sibling (any intervening pretty-printed whitespace text
  node is not itself a sibling for this purpose) independently carry a
  negative keyword match. This closes `for-me-online.de`'s held-out failure:
  a `registration-banner`/`registration-banner__text`/`registration-banner__button`
  -classed promotional run sits as direct `<p>` siblings inside the very same
  `<li>` as real article text (a malformed-markup CMS insertion, not a
  separate sidebar/footer block), including one bare, unclassed `<p>` sitting
  between two `registration-banner*`-classed ones that no keyword-table
  entry alone could reach.

Both tables and every weight/threshold constant are private to
`source/effects/html_main_content.d`; `positiveContentTags`,
`negativeContentTags`, `positiveKeywords`, and `negativeKeywords` are exported
so the checker can assert their exact membership, in addition to asserting
specific scores that would change if a weight drifted.

## Selection and abstention

Selection is one documented rule: the highest-scoring element node wins.
Three abstentions, mirroring `html_metadata.d`'s typed-decision/abstention
idiom, are explicit rather than a best-effort guess:

- `abstainedNoCandidate` — no element node exists at all. Only reachable from
  a degenerate/empty `HtmlTree`; real parsed HTML always has at least a root
  element, so this status is a defensive floor, not something the authored
  fixtures below exercise.
- `abstainedBelowThreshold` — the top-scoring candidate's cumulative text is
  under 200 bytes, or its score is under 150, whichever binds first. Both
  sub-conditions are exercised separately: a page that is almost entirely
  navigation links (high raw text, but link-density- and tag-suppressed to a
  near-zero score) fails on score with its length already sufficient; a
  short, correctly `<article class="article-content">`-tagged update (a
  strong score signal) fails on length with its score already sufficient.
- `abstainedTie` — the top score is shared by more than one candidate (for
  example, two structurally and textually identical `<article>` blocks).

`MainContentResult` reuses `html_metadata.d`'s `MetadataField`-style typed
decision shape: a status, the winning node index and score when selected, and
a bounded top-16 candidate list (`maxMainContentCandidates`) for audit —
useful for inspecting a nav/ad/footer near-miss even when it did not win —
plus a `candidatesOverflow` flag when more than 16 element nodes were scored.
Candidates carry only a node index, score, cumulative text length, and tag
name — never raw page text — so the candidate list is safe to log or report
even for real third-party pages. This is a deliberate strengthening over
`html_metadata.d`'s plain-string `status` field: the contract calls for "a
status enum," so `MainContentStatus` is a real D `enum` rather than a string,
while keeping the same decision shape (status, selection, bounded
candidates).

Selected text is owned, whitespace-collapsed (including across text-node and
element boundaries, with control/format characters dropped) UTF-8, capped at
4 MiB — the same order of magnitude as `html_markdown.d`'s `maxMarkdownBytes`
— using the same bounded throw-on-overflow `Writer` idiom used throughout
`source/effects/`. `extractMainContent` throws `HtmlMainContentOutputLimit`
before returning any result if the selected node's collapsed text would
exceed the cap, so no partial text is ever observable.

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

- Exact selected node index, score, and collapsed text for every selected
  case, and exact status for every abstention case, including both
  `abstainedBelowThreshold` sub-conditions and `abstainedTie`.
- Repeat-call determinism for every fixture.
- The fixed tag/keyword table membership and specific scores that would
  change if a weight drifted (golden drift detection).
- The 4 MiB output cap throwing before any partial text is observable, and
  staying stable across a repeat call on the same tree.
- The top-16 candidate bound and its overflow flag under 41 element
  candidates.

`source/effects/html_main_content.d` also carries its own `unittest` block
against hand-built `HtmlTree`/`HtmlNode` values (no native parser
dependency), covering the same abstention paths plus a direct proof that
`script` text never contributes to a score or leaks into extracted text. Both
are exercised by `dub test --build=release-unittest`, which needs no extra
flags for this module.

## Held-out real-page tier (separate, non-gating)

`experiments/html_main_content/fetch_held_out.sh` is a **separate**
acquisition-and-reporting script, outside the normal `dub build`/`dub
test`/release-active-checker path entirely (mirroring how `cli_baseline.d`'s
`uv pip install` sits outside the normal build/test gate). It is not required
to pass, or even to run, for a change to land — the authored-fixture-tier
proof above is what gates the release-active checker.

What it does:

1. `git clone`s `adbar/trafilatura` at one pinned commit
   (`1e31e3e9eb2e4f6fbfd4bc04355bc74005a780e6`) into a private temporary
   directory and verifies the checked-out commit matches.
2. Reads a fixed, reproducible selection of 20 held-out URLs out of that
   clone's own `tests/evaldata.json` (trafilatura's own published eval
   corpus and annotations, Apache-2.0 licensed, fetched for a run and never
   vendored into this repository's git history or shipped in the release
   binary/package — identical to the policy already recorded on #229's
   2026-09-26 "public package acquisition boundary" decision).
3. Resolves each page's saved HTML from that clone's `tests/cache`/`tests/eval`.
4. Compiles a throwaway D driver into that same temporary directory (also
   never committed), scores each page with `extractMainContent`, and prints
   one JSON report.
5. Deletes the entire temporary directory (including the cloned corpus) on
   exit.

```sh
dub build --build=release   # once, so the native Lexbor library exists
experiments/html_main_content/fetch_held_out.sh
# or: experiments/html_main_content/fetch_held_out.sh /path/to/report.json
```

**Metric.** Word-level, case-normalized, whitespace-tokenized multiset
overlap: `precision = |overlap|/|extracted tokens|`,
`recall = |overlap|/|gold tokens|` — the same family trafilatura's own
benchmark script (`tests/eval_common.py`) uses, for comparable numbers.
trafilatura's real corpus annotates each page with short `with` (must appear)
and `without` (must not appear) probe phrases rather than a full annotated
gold article, so "gold tokens" here is the concatenated `with` phrases for
that page, not the whole article. Precision against that small a gold set
reads low by construction (a correct, much longer extraction still has a
tiny token-count denominator match); the report's own `metricNote` field says
this, and **recall** and **`withoutLeakTotal`** (a substring leak count of
`without` chrome phrases into the selected text) are the more informative
signals from this corpus's actual shape. This is quality-matched reporting,
not a trafilatura-parity claim.

**A real run against the 20 pinned pages** (2026-09-27, after #308 and #309
landed, before #27's fix): selected 19, abstained 1
(`homify.de-Tischdecke.html`, `abstainedBelowThreshold`), could not parse 0.
Across the 19 scored pages: mean precision ≈0.051 (expected, per the
gold-set-size caveat above), mean recall ≈0.79, and `withoutLeakTotal` was
2 — both leaks on the same page, `for-me-online.de-pubertät.html` (2 of its 3
`without` chrome phrases leaked into the selected text; every other scored
page had zero leaks). `france.attc.org-privatisations.html` selected a lone
`<p>` element with precision 0.0 and recall 0.0, missing the real article
content.

**After #27's fix** (2026-09-27, negative-tag-ancestor score suppression plus
keyword-table-and-sibling-aware text-collection exclusion, see above):
selected 19, abstained 1 (same page, same reason), could not parse 0 —
unchanged. Across the 19 scored pages: mean precision ≈0.069 (up from
≈0.051), mean recall ≈0.839 (up from ≈0.79), and `withoutLeakTotal` is now
**0** (down from 2). A real, page-by-page comparison against the pre-fix
report confirms no regression on any of the 18 pages that were already
correct: 13 are byte-for-byte unchanged, and 5 (including
`france.attc.org-privatisations.html` and `for-me-online.de-pubertät.html`
themselves) improved with recall never dropping and `withoutLeaks` never
increasing on any page. In detail:

- `france.attc.org-privatisations.html`: real root cause was different from
  the grooming pass's own hypothesis — direct inspection (`ldc2`-compiled
  diagnostic driver against the resolved page, not speculation) showed the
  actual pre-fix winner was **not** the `soutenez` donation call-to-action
  box (which scored 341, well below several other candidates) but a
  same-site mailing-list signup dialog's own boilerplate legal/privacy
  paragraph, `<p class="explication">` (score 621), nested inside a `<form>`
  several levels down inside an `<aside class="aside secondary">` sidebar.
  After the fix, that paragraph's positive `<p>` tag credit is suppressed
  (nested inside a negative-tag `<form>` ancestor), dropping it to score
  334.5; the real `<div class="crayon article-chapo-6869 chapo
  surlignable"><p>...</p></div>` lede's own `<p>` (no competing keyword
  match, but `article`+`content` both matched on its parent `div`, itself
  unaffected) now wins outright at score 510. Precision 0.0 → 0.346, recall
  0.0 → **1.0** (all three `with` gold phrases now present).
- `for-me-online.de-pubertät.html`: the winning node (a large `<div>`
  wrapping the whole article body) does not change — the fix does not touch
  which node is *selected* here, only what text is *collected* from within
  it. `withoutLeaks` 2 → **0**: `"Jetzt registrieren"` (inside
  `<p class="registration-banner__button">`) is now excluded directly by the
  extended keyword table, and `"erhalten Sie exklusive"` (inside a bare,
  unclassed `<p>` sitting as a direct sibling between
  `<p class="registration-banner__text">` and
  `<p class="registration-banner__button">` inside the same `<li>` as real
  article text) is now excluded by the sandwich rule. Recall stays 1.0;
  precision is essentially unchanged (0.02589 → 0.02645 — this page's
  winning node is a large container, so removing ~30 bytes of promo text out
  of ~4,200 moves precision only slightly).
- Five other already-correct pages (`kleinegruenemonster.wordpress.com`,
  `utopia.de-Werbung`, `laweekly.com-Cultivation`, `tofugu.com.dezuka-suisan`)
  show small precision deltas (all within ±0.005) from the same text-
  collection exclusion trimming a small amount of negative-keyword-classed
  chrome text that happened to be nested inside their own winning node;
  recall and `withoutLeaks` are unchanged on every one of them. The
  remaining 13 scored pages are byte-for-byte identical before and after.

### Disclosed finding: `experiments/html_main_content/check.d` has pre-existing, unrelated golden drift

While verifying issue #27's fix against `check.d` (the separate,
network-free, non-gating structural checker — see Proof above), four of its
hand-authored fixture goldens (`news-article-shaped`, `blog-post-shaped`,
`docs-page-shaped`, `forum-thread-shaped`: both the exact `score` and exact
`text` assertions) and one threshold assertion (`nav-heavy-near-empty`'s
"fails on score, not length" check) were already failing against unmodified
`origin/main`, confirmed by reverting this ticket's changes entirely and
rerunning `check.d` unchanged. The text mismatches are consistent with
issue #335's later paragraph-break formatting (`check.d`'s expected strings
predate the `"\n\n"` block-boundary output); the score mismatches are
consistent with `content`/`article` both matching the shared
`article-content` class substring, double-counting a keyword bonus `check.d`
last measured before that overlap existed. Confirmed this is **not**
introduced by issue #27's own change: with `check.d`'s score/text/threshold
assertions bypassed for isolation, every other assertion (table-membership
drift including this fix's own `registration-banner` addition, the tag/
keyword numeric goldens, both abstention paths, the output cap, and the
candidate-bound proof) passes against the fixed code. Out of this ticket's
scope to repair (a pre-existing, unrelated drift, not a regression this fix
caused); `experiments/html_main_content/check.d`'s own `negativeKeywords`
golden list is updated here only for the one entry this ticket intentionally
adds.

No raw held-out page bytes and no `with`/`without` annotation text are ever
placed into the report or into any exception/diagnostic, in either the shell
script or the driver it compiles: only bounded counts, status/reason names,
node tag names, and numeric scores.

The script also accepts one additive, optional flag, `--emit-corpus-dir DIR`,
that additionally materializes the resolved fixtures' HTML and a `gold.json`
into a durable directory (absent, behavior is byte-identical to before the
flag existed). Its scoring formula lives in one pure, shared module,
`experiments/html_main_content/token_overlap.d`. Both exist for
[`benchmarks/external_comparator.d`'s `main-content/scrubbed-vs-trafilatura`
case](../benchmarks/README.md#shared-external-tool-comparator) (issue #229's
trafilatura next-slice), which reuses this exact corpus, commit, and metric
to score the real `scrubbed` CLI's `html-main-content` v3 stage end to end
against the real pinned trafilatura CLI — see that document for the full
CLI-invocation and report-shape detail.

## v3 stage registration

`source/effects/html_main_content_stage.d` (issue #26's next-slice) is a v3
self-registering stage, `"html-main-content"`, mirroring
`html_markdown_stage.d`'s existing pattern:

- Enforces a raw-byte cap (`quarantine("rawLimit")`), calls `parseHtml`, and
  on a parse failure quarantines using the same `HtmlFailureReason.to!string`
  convention as `html-metadata`/`html-markdown`.
- On a successful parse, calls `extractMainContent(outcome.tree)` — this
  module's own frozen, unmodified scoring function.
- On `MainContentStatus.selected`, replaces `input.content` with the
  selected subtree's plain text and maps. `input.metadata` (written by any
  prior stage) passes through completely untouched, since this stage never
  reads or writes it.
- On any abstention status, quarantines with the exact status-name string
  (`result.status.to!string`) — a single, undifferentiated code path for all
  three statuses.
- On `HtmlMainContentOutputLimit` (the 4 MiB cap), quarantines
  `"outputLimit"`.
- Carries no `TerminalSideOutput` and stays `SideOutputCapability.none`, so
  it remains freely composable before a later terminal stage. Options match
  `html-markdown-stage`'s `charset`/`max-html-bytes` shape.

Per an explicit owner decision (issue #26), an abstention quarantines the
*whole* document, including any metadata an earlier stage already wrote —
matching quarantine's existing all-or-nothing semantics elsewhere, rather
than a hard `.reject`.

The stage is registered with **explicit** `StageCardinality.oneToOne` and
explicit `SideOutputCapability.none` — not left at their unspecified
defaults — matching its real, always-map-or-quarantine, never-split
behavior (the same reasoning as `html-metadata-annotate`'s own registration,
#285). `composition/compiler.d`'s admission rule requires every stage
preceding a terminal stage to be *registered* `oneToOne`. This stage
precedes the terminal `pii-four-class` stage in its required chain
(`[text-transform] -> [html-metadata-annotate] -> [html-main-content] ->
[pii-four-class]`), so leaving it at the default `maySplit` would make that
chain fail to compile. Metadata-annotation runs *before* main-content
extraction because it reads `<head>` evidence, and main-content extraction's
successful map fully replaces `content` with the selected body subtree's
plain text, discarding `<head>` entirely; `html-metadata-annotate` returns
`content` completely unmodified, so running it first costs nothing.

**Proof.** `experiments/html_main_content_stage/check.d` proves, through the
compiled stage boundary (`composition.compiler`/`composition.executor`):
successful selection replaces content and preserves any prior `.metadata`;
both reachable abstention statuses (`abstainedBelowThreshold`,
`abstainedTie`) quarantine with the exact status-name reason; a parse
failure quarantines with a nonempty reason; the raw-byte cap quarantines
`"rawLimit"`; a document large enough to approach the 4 MiB collected-text
cap quarantines `"observationLimit"`, not `"outputLimit"` (see the disclosed
finding below). `abstainedNoCandidate` is not exercised there either, for
the same reason: it is unreachable through real parsed HTML, and the
stage's quarantine branch has no per-status code path for it to diverge
from.

```sh
ldc2 -O3 -release -preview=dip1000 -i -Isource \
  experiments/html_main_content_stage/check.d \
  .dub/lexbor/liblexbor_static.a -of=.dub/html-main-content-stage-check
.dub/html-main-content-stage-check
```

`experiments/document_metadata_integration/check.d` (#285's own integration
checker) is extended with two more proofs:

- Proof D chains `[text-transform(fix-mojibake), html-metadata-annotate,
  html-main-content, pii-four-class(terminal, last)]` end to end, confirming
  the final content is `pii-four-class`'s output over the mojibake-repaired,
  main-content-only text while `payload.metadata` still carries exactly what
  `html-metadata-annotate` wrote.
- A second proof confirms that when `html-main-content` abstains, the whole
  document is quarantined, no `TerminalSideOutput` is ever produced, and
  `pii-four-class` never runs — checked two ways. With the three-stage
  prefix alone (no terminal stage in that job), `runCompiledJob` gracefully
  returns a single quarantined event with no side output, as expected.

Run it exactly as #285's own command (`docs/document-metadata.md`),
unchanged:

```sh
ldc2 -O3 -release -preview=dip1000 -i -Isource \
  experiments/document_metadata_integration/check.d \
  .dub/lexbor/liblexbor_static.a \
  -of=.dub/document-metadata-integration-check
.dub/document-metadata-integration-check
```

### Disclosed finding: `outputLimit` is unreachable through real byte input

Unlike `html-markdown-stage`'s own `"outputLimit"`, this stage's
`"outputLimit"` handling (`HtmlMainContentOutputLimit`, item 6 of the
contract) is implemented exactly as specified but is **not reachable through
any real byte input**. `html_tree.d`'s native-observation accounting
(`maxObservationBytes`, a fixed 1 MiB cap on total bytes observed while
building the parsed tree, independent of and unaffected by this stage's own
configurable `max-html-bytes` option) always binds first for any document
large enough to approach `maxMainContentTextBytes` (4 MiB), failing parse
with `HtmlFailureReason.observationLimit` before `extractMainContent` ever
runs — confirmed experimentally while building the acceptance fixture.

Markdown rendering can structurally *amplify* a small parsed tree past 4 MiB
(for example, nested-list indentation duplicated per output line), which is
why `html-markdown-stage`'s own output cap genuinely is reachable;
main-content's plain-text collection only concatenates and
whitespace-collapses already-observed text, so it can never produce more
output bytes than were observed as input, and 1 MiB always fits under 4 MiB.
`html_tree.d` is out of this slice's allowed scope to change, so this is
disclosed here rather than patched around — the same class of documented,
out-of-scope-to-fix unreachability `abstainedNoCandidate` already has for the
underlying pure function. The code path is retained (not deleted) because it
is correct, matches the contract's explicit instruction, and would become
reachable if a future, separately-scoped change ever raised
`maxObservationBytes` past 4 MiB.

### Disclosed finding: quarantine-upstream-of-terminal executor gap

Appending the terminal `pii-four-class` stage to the three-stage prefix
surfaces a second disclosed finding: `composition/job_executor.d`'s
post-loop invariant requires *any* job containing a
`SideOutputCapability.terminal` stage anywhere to end with exactly one side
output, regardless of whether that terminal stage ever actually ran — it
does not special-case a job whose sole event already quarantined upstream.
It raises `CompiledJobFailure` (attributed to the terminal stage's id)
instead of a graceful quarantined event.

This is a real, pre-existing gap in the executor's own invariant, orthogonal
to this slice's stage logic and never previously exercised (#285's own
Proofs A/B never quarantine upstream of a terminal stage); the executor is
out of this slice's allowed scope (prohibited, not merely unmodified), so it
is disclosed here rather than patched around. Either way, `pii-four-class`
categorically never produces a side output for this document, so no
metadata ever reaches a later stage or publish point — both proofs confirm
the owner's "drop together" decision.

Both proofs use the same local `StageRegistry` workaround #285 established
for `text-transform`'s own separate, pre-existing cardinality gap (issue
#293, not fixed here); `html-main-content` itself needs no such workaround,
since it is already correctly registered in production.

## Non-goals

- No v4 extractor registration; no `cli.d`/`app.d` change beyond automatic
  self-registration reachability; no `benchmarks/external_comparator.d`
  change beyond what issue #229 already added.
- No network fetch inside any release-active checker.
- No trafilatura-parity claim; no Mozilla-Readability/jusText/
  readability-library port; no model/LLM extraction.
- No change to `html_main_content.d`'s own scoring/selection algorithm
  (frozen), or to `html_metadata.d`, `html_metadata_annotate_stage.d`,
  `html_markdown.d`, `html_tree.d`, `html_tree_export.d`, `pii_four_class.d`,
  the compiler, or the executor.
- `abstainedNoCandidate` is exercised only by
  `source/effects/html_main_content.d`'s own unit test against an empty
  `HtmlTree`, not by an authored HTML fixture (through the pure function or
  through the stage), since real parsed HTML always yields at least one
  element candidate.
- Script/style hidden-text exclusion during scoring checks only the
  immediate parent tag (correct for script/style, which are HTML5 RAWTEXT
  elements); template/head exclusion during scoring is a one-level-deep
  simplification, unlike the full ancestor walk `html_markdown.d` uses and
  that this module's own final text-extraction step also uses.
- No structured candidate-audit side output (flagged, deferred to a future
  terminal publish stage).
- `text-transform`'s own registration cardinality gap (issue #293) remains
  unfixed and out of scope here.
