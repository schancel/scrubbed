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

A fourth status, `selectedStructuredData` (issue #411), is a second success
path, not a fourth abstention: once the DOM candidate pass above has
abstained for any of the three reasons, a bounded JSON-LD structured-data
fallback (`structuredDataFallbackText`) gets one more chance to recover
real content from a `<script type="application/ld+json">` schema.org block
the DOM pass structurally cannot see (content delivered only as JSON, not
DOM text/elements — see "`www-homify-de.html`" below for the real page this
was built from). It only overrides an abstention when the recovered text
clears the same `minSelectableTextBytes` floor an ordinary candidate must
clear; `.node` stays `size_t.max` (there is no tree node this text was
selected from) and `.score` stays `0.0`.

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

## Comment-section extraction (issue #475)

Before this ticket, comment-section markup (`<div class="comments">`, a
WordPress-style `<div id="comments">` thread, a Disqus embed) was either
absorbed into the winning candidate's text or scored down by the existing
`"comment"` entry in `negativeKeywords` and simply discarded -- treated
identically to an ad or a share widget, with no way to tell "this page has
comments and here they are" from "this page has boilerplate we dropped".
This ticket adds a genuinely new output category: `MainContentResult` gains
`commentsExtracted` (`bool`) and `comments` (`string`), populated by a
second, independent scan of the whole document, distinct from the ordinary
DOM candidate-scoring pass above (no interaction with `.text`/`.node`/
`.score`/`.status` either way).

**Real survey, not a guess.** `commentSectionKeywords`
(`source/effects/html_main_content.d`) is grounded in a direct grep-and-read
survey of this repo's own 20-page held-out corpus
(`examples/pipeline-benchmark/corpus/`, the same corpus #411's own 20/20
check uses), documented in that table's own doc comment:

- `archiv-krimiblog-de.html`: `<div id="comments">` wrapping
  `<div class="commentEntry"><div class="commentContent" id="comment-2310">`.
- `kleinegruenemonster-wordpress-com.html`: `<div id="comments">` wrapping
  `<div id="comment-75">`.
- `scienceblogs-de.html`: `<div id="comments">` wrapping 140 real
  `<div id="comment-NNNNNN" class="comment ... reply">` entries -- this
  corpus's largest real comment thread.
- `france-attac-org.html`: `<div class="comments">` containing only two bare
  `<a id="comments">`/`<a id="forum">` fragment-link anchors, no comment text
  at all -- a real "structurally comment-shaped but empty" page.
- `www-tofugu-com.html`: a `<i class="fa fa-comments">` comment-*count*
  glyph icon inside nav chrome, not a comment section at all.

A single keyword, `"comment"`, covers every real pattern above (it is a
substring of "comments", "commentEntry", "commentContent", "comment-75",
"comment-NNNNNN", etc.). `"disqus"` is not present anywhere in this corpus;
it is added because the issue's own acceptance criteria explicitly name
Disqus embeds (`<div id="disqus_thread">`) as a pattern to detect, disclosed
in the table's own doc comment as issue-instructed rather than
corpus-observed. Detection is restricted to real block-container tags
(`div`/`section`/`aside`/`ol`/`ul`, matching real trafilatura's own
`htmlprocessing.py` comment-XPath restriction to `div`/`section`/`list`
shapes) rather than any element -- this is exactly what keeps the
`fa-comments` glyph icon (`<i>`, not a block container) and the bare
`<a id="comments">` anchor (`<a>`, not a block container) from being
misidentified as comment *sections*.

**Algorithm.** One forward pre-order pass (the flat tree is already
pre-order): each element whose tag is a real block container and whose
class/id matches `commentSectionKeywords` becomes a comment-section root, and
its whole subtree is claimed (`endOf`) -- a nested match inside an
already-claimed root (e.g. `scienceblogs-de.html`'s individual
`<div id="comment-NNNNNN">` entries inside the page's own outer
`<div id="comments">`) is not treated as a second root. `commentsExtracted`
is `true` whenever at least one root was found, even when the recovered text
is empty (`france-attac-org.html`'s real shape above) -- a different, more
honest fact than a page with no comment markup at all. Text collection
(`collectPlainSubtreeText`) shares `collectText`'s hidden-tag/block-boundary
logic but not its sandwich-exclusion rule (issue #27's Case 2 exists to
strip a small embedded promotional run out of an *article* container; a
comment section has no such "real content vs. embedded boilerplate"
distinction to make once identified as a comment section in full).

**Deliberately weaker output-cap invariant than main content.**
`extractMainContent`'s own 4 MiB cap throws before returning any result so
the *selected* main content is never observed truncated. Comments text
instead catches its own overflow and returns whatever was collected before
the cap, truncated rather than fatal: comments are a supplementary,
independently-identified output, and a single real page's discussion thread
growing past 4 MiB (plausible -- this corpus's own largest real thread,
`scienceblogs-de.html`'s 140 entries, produces 156,620 bytes, comfortably
under it, but a highly-discussed post elsewhere would not be) must not turn
into a hard failure that quarantines the whole document over a part of the
page nothing else depends on.

**Default-on, with an opt-out** (issue #475's own acceptance criterion,
matching trafilatura's `--no-comments` shape): `extractMainContent`'s new
`includeComments` parameter defaults `true`; passing `false` suppresses
comment scanning entirely (never merely filtering the output) --
`commentsExtracted` stays `false` and `.comments` stays empty regardless of
what markup the page actually carries. `html_main_content_stage.d` exposes
the identical default/opt-out shape as a real, hyphenated boolean stage
option, `include-comments` (matching `pii-four-class`'s own `allow-redact`
as this repo's existing precedent for a hyphenated boolean stage option,
parsed through the same `key in options` / default-value idiom, restated
locally rather than shared since that helper is private to
`pii_four_class.d`).

**Real fixture proof.**
[`experiments/html_main_content/comments_check.d`](../experiments/html_main_content/comments_check.d)
is a real-fixture regression check (network-free, reads only this
repository's own already-checked-in corpus HTML) satisfying acceptance
criterion 2 directly: it asserts `commentsExtracted`/`.comments` against
eight real corpus pages with ground truth drawn from the same survey above
(four with real comment content, `france-attac-org.html`'s structurally-
present-but-empty case, and three genuinely comment-free pages, including
the `fa-comments`-glyph page), and that `includeComments=false` suppresses
detection without perturbing main-content selection on the identical page.
Run it exactly like `check.d`:

```sh
ldc2 -O3 -release -Isource -of=/tmp/html-main-content-comments-check \
  experiments/html_main_content/comments_check.d source/effects/html_main_content.d \
  source/effects/html_tree.d source/effects/lexbor_ffi.d \
  source/text/decoding.d .dub/lexbor/liblexbor_static.a
/tmp/html-main-content-comments-check
```

**Real pinned trafilatura==2.2.0 comparison** (acceptance criterion 1),
[`experiments/html_main_content/compare_comments_trafilatura.sh`](../experiments/html_main_content/compare_comments_trafilatura.sh):
a separate, non-gating, network-and-pip-using acquisition tier (outside
`dub build`/`dub test` entirely, mirroring `fetch_held_out.sh`'s own
established convention) that installs pinned `trafilatura==2.2.0` into a
throwaway `uv venv`, verifies the exact pin via `uv pip freeze`, and compares
scrubbed's own comment/non-comment split (`commentsExtracted && comments.length
> 0`) against real trafilatura's own `"comments"` JSON output field
(`trafilatura.extract(..., include_comments=True)`) over the identical eight
real corpus pages `comments_check.d` uses. A real run (2026-09-29,
`trafilatura==2.2.0` verified via `uv pip freeze`): **8/8 agreement** -- both
tools agree on which of the four comment-bearing pages have comments and
which of the four comment-free/textless-comment pages don't, with no
disagreement on any page. One honest, disclosed nuance: on
`scienceblogs-de.html` both tools agree comments are present, but real
trafilatura's own extraction recovers only its section heading
("Kommentare (140)", 16 bytes) while scrubbed recovers the full 140-entry
thread (156,620 bytes) -- a difference in extraction *depth* on a page both
tools correctly classify as "has comments", not a disagreement on the
comment/non-comment split itself, which is what this criterion asks for.

**Disclosed, deliberate scope boundary.** `html_main_content_stage.d` adds
comment text to `input.metadata` as an extension field only when it fits the
existing, already-wired `document-metadata:v1` extension-field cap (512
bytes) -- real comment threads (this corpus's own 156,620-byte example)
routinely exceed it. `document-metadata:v2`'s structured-section capability
(2 MiB) would fit, but per that module's own header comment it is
"domain-only... not wired to anything yet", and wiring a new
`SideOutputCapability`/second output bucket through
`composition/compiler.d`/`composition/executor.d` is a larger, cross-cutting
change outside this ticket's allowed file scope
(`html_main_content.d`/`html_main_content_stage.d` only). Rather than
silently truncating a real thread to fit the wrong-sized cap, the stage
skips the metadata write entirely once the text doesn't fit; the full,
untruncated separation is real and already available at the
`extractMainContent` API level (`MainContentResult.comments`/
`.commentsExtracted`, this ticket's actual deliverable). Giving the compiled
v3 stage a real, unbounded second output channel is a concrete follow-up,
not silently dropped.

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
*(Stale as of 2026-09-29, issue #411: this run scored `fetch_held_out.sh`'s
own resolved bytes — `adbar/trafilatura`'s pinned `tests/cache`/`tests/eval`
copies of these pages, not a fresh fetch. `examples/pipeline-benchmark/corpus/`
is a separate, checked-in acquisition of the identical 20-URL list that did a
fresh **live** fetch on the same day, 2026-09-27 — see its `manifest.json`.
Live bytes for a comments-enabled blog and a JS-rendered-*looking* SPA
differ from an older vendored test-fixture snapshot, which is why that
checked-in corpus previously read 18/20, not 19/20: `scienceblogs-de.html`'s
live copy grew past the node-count/observation-byte caps that
`fetch_held_out.sh`'s cached copy never approached, in addition to the same
`homify.de` abstention this note already documented. Issue #411 has since
fixed both real root causes (a stale, unrevisited resource cap; real
content reachable only via JSON-LD, not DOM text) on the checked-in corpus,
which now reads 20/20 — this held-out tier's own 19/20 figure is a
separate, differently-acquired, dated snapshot this ticket does not
re-score. See "`examples/pipeline-benchmark` corpus: current 20/20 status"
below for the current, checked-in-corpus evidence that `site/index.html`'s
stat card actually cites.)*
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

## `examples/pipeline-benchmark` corpus: current 20/20 status (issue #411)

The site's extraction stat card cites `examples/pipeline-benchmark/`'s own
20-page checked-in corpus (not the held-out tier above), now **20/20**
selected. Owner request (2026-09-29, explicitly "later priority, not
urgent"): investigate the 2 non-selected pages with real evidence rather
than leave the gap as a vague aspiration.

**Correction (2026-09-29): the original "working as intended" conclusion for
both pages was wrong.** The owner directly challenged it and both claims
failed real verification against the actual pinned `trafilatura==2.2.0`
tool — it extracted real article content from both pages without issue
(4,826 bytes from `www-homify-de.html`; a clean pass over
`scienceblogs-de.html`'s full 397,702-byte file in 0.46s, both reproduced
directly against this repo's own corpus copies for issue #411's real fix,
not just cited from the prior claim). The root cause for each page turned
out to be real and fixable, not a corpus outlier or a JS-rendering gap:

- **`www-homify-de.html`**: the page's real content is delivered entirely
  as JSON — a `<script type="application/ld+json">` schema.org `HowTo`'s
  `step[].itemListElement.text` — never as DOM text/elements at all, which
  is exactly how real trafilatura recovers it too (its own `baseline.py`
  walks the identical JSON-LD property as one of its extraction
  strategies). This is not a scoring-weight/threshold miscalibration in the
  DOM candidate pass (nothing wrong was found there); it is a second
  content *source* the DOM-only candidate pass structurally cannot see.
  Fixed by adding a bounded JSON-LD structured-data fallback to
  `html_main_content.d`, invoked only once the ordinary DOM pass has
  already abstained — see "`www-homify-de.html`" below.
- **`scienceblogs-de.html`**: `html_tree.d`'s `maxNodes`/`maxObservationBytes`
  caps were introduced alongside the original 64 KiB raw-byte admission
  bound and never revisited when a later, separate change raised that bound
  to 1 MiB default / 8 MiB configurable — a real, comment-heavy blog page
  comfortably inside the *documented* 1 MiB default bound could still be
  rejected by node/observation caps still sized for a bound 16x smaller.
  Fixed by raising both caps, sized against this corpus's own real
  per-page node/observed-byte density, not just this one page — see
  "`scienceblogs-de.html`" below.

**This 20/20 count is no longer a hand-maintained citation** (issue #422,
opened after #411/#412 each independently found a citation like this one had
silently gone stale between owner questions). The source of truth for the
corpus's current per-page selected/quarantined distribution, including each
quarantined page's exact reason string, is now
[`examples/pipeline-benchmark/corpus_distribution_check.d`](../examples/pipeline-benchmark/corpus_distribution_check.d),
a pinned-expectation regression check that runs the real `scrubbed` binary
against the real corpus and fails loudly — non-zero exit, with a per-page
expected-vs-actual diff — the moment any page's outcome changes in either
direction. It is wired into CI via
[`.github/workflows/pipeline-benchmark-corpus-distribution.yml`](../.github/workflows/pipeline-benchmark-corpus-distribution.yml),
triggered on changes to the check itself, the corpus, or anything in
`source/` that could affect extraction. If that check's expected table and
this section's "20/20" figure ever disagree, the check (and a fresh
investigation of whatever page moved) is authoritative, not this prose; the
per-page root-cause writeups below remain useful evidence for the two pages
already investigated, but they describe *why* each page's outcome is what it
is, not a live claim about the current count.

Repro (either page):

```sh
./scrubbed run --input examples/pipeline-benchmark/corpus/<file>.html \
  --output /tmp/out --sidecar-output /tmp/sidecar --explain \
  --stage extract=html-main-content --stage pub=document-metadata-publish --threads 1
```

To reproduce the pinned regression check itself after building in release
mode (see `corpus_distribution_check.d`'s own header comment for the exact
invocation):

```sh
dub build --compiler=ldc2 --build=release
ldc2 -O -release -of=/tmp/corpus-distribution-check \
  examples/pipeline-benchmark/corpus_distribution_check.d
/tmp/corpus-distribution-check ./scrubbed examples/pipeline-benchmark/corpus
```

### `scienceblogs-de.html` — was `nodeLimit`, fixed by raising stale caps

`effects.html_tree.d`'s bounded-resource caps (`maxNodes`,
`maxObservationBytes`) protect the restricted HTML boundary against
unbounded native-tree memory/CPU. A diagnostic build with both caps raised
(scratch-only, not shipped) showed this page's full parsed tree needs
**10,798 nodes** and **1,159,366 observed bytes** (a raw-to-observed
amplification of ~2.92x) for its real 397,702-byte file — both real
numbers, confirmed directly, not estimated. `nodeLimit` fired first because
node-count is checked per-node before that node's bytes are charged.

The original investigation (superseded — see the correction above) treated
this as a genuine, un-fixable corpus outlier the cap correctly rejects,
without testing that claim against a real external tool. Directly running
pinned `trafilatura==2.2.0` against this repo's own copy of the file
disproves it: `trafilatura.extract()` returns 1,722 bytes of real,
on-topic German-language article text in 0.46s, no special handling, no
error — a page a real, widely-used extractor finds completely
unremarkable. The "10,798 nodes" figure the original writeup cited was
scrubbed's own internal parsed-tree representation size (a D `HtmlNode`
struct array plus each node's own string/attribute allocations), not
anything inherent to the page itself — an internal representation-overhead
artifact being mistaken for an external limitation.

Both caps were introduced (`ebae4ed`) alongside the original 64 KiB
`maxRawBytes` raw-byte admission bound and never revisited when a later,
separate change (`68e1b1c`) raised extraction's own effective raw-byte
admission to 1 MiB by default and up to 8 MiB configurable via
`--max-html-bytes` — that change's own TODO.md entry explicitly noted
"other tree/output limits... remain unchanged", a known, not hidden, gap
that was simply never closed. `scienceblogs-de.html` (397,702 raw bytes) is
comfortably inside the *documented* 1 MiB default admission bound, yet its
real node count exceeded a node cap still sized for a bound 16x smaller.

Measuring all 20 corpus pages the same way (temporarily raising both caps
and running every page through `parseHtml`) grounds the fix in real,
whole-corpus evidence rather than this one page: per-raw-KiB density across
the corpus ranges from roughly 2.3 to 27.9 nodes/KiB and 0.89x to 3.17x
observed-vs-raw bytes (both extremes on real pages in this same corpus, not
hypothetical). `maxNodes` is raised from 8,192 to **65,536** — comfortably
clearing the corpus's own densest real page (27.9 nodes/KiB, `tofugu.com`)
at a full 1 MiB (the default extract admission bound) with roughly 2x
headroom beyond that — and `maxObservationBytes` is raised from 1 MiB to
**4 MiB**, similarly clearing the corpus's own highest observed-byte ratio
(3.17x) at a full 1 MiB raw with headroom. Both stay fixed bounds (not
scaled to whatever raw-byte limit a caller configures via
`--max-html-bytes`, which remains the pre-existing, separately documented
"other limits do not scale with the configured raw cap" behavior — out of
this ticket's scope) — a real, examined, evidence-grounded increase, not an
unbounded one. Verified against the full 20-page corpus both before (18/20)
and after (20/20) this change: the 18 pages that already selected produce
byte-for-byte identical output, and `dub test` passes with no regressions.

Not attempted here, and a reasonable follow-up if it ever becomes a real
problem: reducing the ~1–3x raw-to-observed amplification itself (e.g. a
more memory-efficient `HtmlTree`/`HtmlNode` representation) rather than
raising the byte budget around it. That is a larger, structural change to
this module's core data shape, evidence for which (this corpus's own
amplification-ratio range, above) is now on record but which this ticket's
timebox did not extend to attempting.

**Residual, honestly disclosed (not hidden):** now that it selects, this
page's real word-overlap score against trafilatura (`run.sh`'s own
methodology, re-run for this ticket) is precision 0.111 / recall 0.402 —
well below the corpus's ~0.89/0.76 mean. This is not a bug in the fix above
(the page now parses and a real, on-topic `<div class="content">` subtree
wins, exactly the shape a comment-heavy blog should produce). It reflects a
separate, pre-existing scoring-*priority* question this ticket's scope does
not cover: this page's DOM contains many legitimate `class="content"` divs
(the article body plus many individual comment replies, all real prose),
and the candidate pass's fixed scoring rule picks the single
highest-scoring one by cumulative own-text/tag/keyword signal, not
necessarily the top-level article body specifically when a long comment
reply scores higher by the same rule. Not investigated further here — it is
a real, disclosed nuance for a future ticket, not a claim this page's
extraction is now perfect.

### `www-homify-de.html` — was `abstainedBelowThreshold`, fixed with a JSON-LD fallback

This is the same source URL as the held-out tier's own `homify.de-Tischdecke.html`
(`https://www.homify.de/diy/20546/wie-man-eine-runde-tischdecke-in-nur-7-schritten-herstellt`
— see `manifest.json`), so this is a previously-documented, not new,
failure. A diagnostic dump of `extractMainContent`'s scored candidates for
the live-fetched copy shows no DOM candidate clears both abstention floors
(200 selectable bytes, score 150):

| candidate | tag | class/id | score | textLen |
|---|---|---|---|---|
| top score | `<p class="message">` | app-install banner | 364 | 64 |
| keyword match | `<div id="js-content">` | — | 150 | 110 |
| most text | `<div id="js-body">` | — | 115.7 | 1,020 |

The original investigation (superseded — see the correction above) stopped
here and concluded this was a JS-rendered page with no real content in the
static HTML at all, without testing that claim against a real external
tool. Directly running pinned `trafilatura==2.2.0` against this repo's own
copy of the file disproves it: `trafilatura.extract()` returns 4,826 bytes
of real DIY-guide article text ("Um eine runde Tischdecke anzufertigen,
musst du die Maße des Tisches kennen...") — the content is present in the
static HTML.

It is present, but not as DOM text/elements: the page's real content lives
entirely inside `<script type="application/ld+json">` schema.org markup —
a `HowTo` object whose `step[].itemListElement.text` fields (8 steps,
~5.3 KB combined, HTML-escaped) carry the full DIY-guide body. (A second,
separate `<script>` block carries the identical prose again as a React
`data-react-props` JSON attribute payload; the JSON-LD block is the one
this fix reads, since attribute values are never scoring-visible text
either way.) This is exactly how real trafilatura recovers this page too —
not a coincidence: its own `baseline.py` module walks
`<script type="application/ld+json">` blocks for schema.org content
properties (`articleBody`, HowTo `step`, FAQ `acceptedAnswer`, etc.) as one
of its extraction strategies, and this page's JSON-LD is a schema.org
`HowTo` — precisely the shape that strategy targets.

This means the original "scoring/threshold tuning issue" framing this
ticket's corrected scope proposed as one hypothesis is not what was found:
nothing wrong exists in the DOM candidate-scoring pass itself (no
miscalibrated weight, no wrong tag/keyword table entry). The real content
is delivered through a second content *source* — JSON, not DOM text/
elements — that the DOM-only candidate pass structurally cannot see at
all, no matter how its weights are tuned; the 64-byte promo `<p>` winning
among DOM candidates was always going to happen once the real content
was never in the DOM-candidate contest to begin with.

Fixed by adding a bounded JSON-LD structured-data fallback to
`html_main_content.d`, invoked only once the ordinary DOM candidate pass
has already abstained (any of its three abstention reasons) — see
`structuredDataFallbackText`'s doc comment there for the full mechanism
(bounded aggregate JSON bytes scanned, bounded JSON parse depth, a fixed
schema.org property table mirrored from trafilatura's own already-validated
list, a small evidence-grounded HTML-entity decoder, and the same
`minSelectableTextBytes` floor an ordinary DOM candidate must clear before
this fallback can override an abstention). A new `MainContentStatus`
member, `selectedStructuredData`, distinguishes this success path from an
ordinary DOM-subtree `selected` result (`.node` stays `size_t.max`: there
is no tree node this text was selected from). Because the fallback only
ever runs on an abstain outcome, it cannot change behavior on any page that
was already selecting successfully — confirmed against the full 20-page
corpus: the 18 already-selecting pages produce byte-for-byte identical
output before and after this change, `scienceblogs-de.html` (fixed
separately, above) and `www-homify-de.html` now both select, and
`dub test` passes with no regressions.

Prevalence beyond this one page: 6 of this corpus's 20 real pages
(`jobsnhire-com.html`, `utopia-de.html`, `www-be-ch.html`,
`www-chemietechnik-de.html`, `www-laweekly-com.html`, `www-tofugu-com.html`,
in addition to `www-homify-de.html`) carry at least one
`application/ld+json` script block; the other 5 already select via the
ordinary DOM pass so this fallback never runs for them (confirmed
byte-for-byte unchanged, above), but it means the JSON-LD pattern itself is
common in this corpus, not unique to the one page that happened to need the
fallback to succeed.

## v3 stage registration

`source/effects/html_main_content_stage.d` (issue #26's next-slice) is a v3
self-registering stage, `"html-main-content"`, mirroring
`html_markdown_stage.d`'s existing pattern:

- Enforces a raw-byte cap (`quarantine("rawLimit")`), calls `parseHtml`, and
  on a parse failure quarantines using the same `HtmlFailureReason.to!string`
  convention as `html-metadata`/`html-markdown`.
- On a successful parse, calls `extractMainContent(outcome.tree)` — this
  module's own frozen, unmodified scoring function.
- On `MainContentStatus.selected` **or** `MainContentStatus.selectedStructuredData`
  (issue #411: a second success status — see "Selection and abstention"
  above), replaces `input.content` with the selected/recovered text and
  maps. `input.metadata` (written by any prior stage) passes through
  completely untouched, since this stage never reads or writes it.
- On any abstention status, quarantines with the exact status-name string
  (`result.status.to!string`) — a single, undifferentiated code path for all
  three abstention statuses.
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

- Reducing `html_tree.d`'s ~1–3x raw-to-observed-byte representation
  amplification itself (issue #411; see "`scienceblogs-de.html`" above for
  the real, measured per-page ratios): fixed there by raising `maxNodes`/
  `maxObservationBytes` against real corpus evidence instead, which is
  sufficient for every page in this corpus today. A more memory-efficient
  `HtmlTree`/`HtmlNode` representation remains a real, larger, structural
  follow-up if a future page's density ever exceeds the raised caps'
  margin, not attempted within this ticket's timebox.
- Making `html_main_content_markdown.d`'s Markdown combinator (issue #335
  Slice 2) render structured-data-fallback content: `extractMainContentMarkdown`
  only renders Markdown when `.status == selected` (an ordinary DOM subtree
  it can call `renderMarkdownFrom(tree, node)` on); a `selectedStructuredData`
  result has no corresponding tree node, so it currently produces empty
  `.markdown`, same as an abstention. **This is a live, currently-reachable
  gap, not a hypothetical one:** issue #431 landed real stage/CLI wiring for
  this combinator concurrently with this ticket's own fix
  (`source/effects/html_main_content_markdown_stage.d`, reachable as both
  `extract --format=main-content-markdown` and
  `run --stage X=html-main-content-markdown`), and that stage's own
  `result.status != MainContentStatus.selected` quarantine check treats
  `selectedStructuredData` as a quarantine, the same as a genuine
  abstention. Concretely: `www-homify-de.html` still quarantines
  (`reason="selectedStructuredData"`) through
  `extract --format=main-content-markdown` today, even though the plain-text
  `html-main-content`/`clean-web-document` path this ticket's own fix and
  the pinned corpus check both cover now selects it successfully. A
  follow-up ticket is warranted to give
  `html_main_content_markdown_stage.d` a real (rendering the recovered
  structured-data text as a flat Markdown paragraph run, no tree node to
  walk) or an explicitly-declined answer for `selectedStructuredData`,
  rather than leaving it as this ticket's own incidental, undocumented
  side effect.
- A real, unbounded second stage-level output channel for extracted comment
  text (issue #475): `html_main_content_stage.d` only ever writes comments
  into `.metadata` when they fit the existing `document-metadata:v1`
  extension-field cap (512 bytes) -- see "Comment-section extraction (issue
  #475)"'s own "Disclosed, deliberate scope boundary" above for the real
  corpus evidence (a 156,620-byte real thread) motivating this as a concrete
  follow-up (wiring `document-metadata:v2`'s already-defined but
  "not wired to anything yet" structured-section capability, or a new
  `SideOutputCapability`) rather than an oversight. The full, untruncated
  separation is already real at the `extractMainContent` API level.
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
