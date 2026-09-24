# Frozen template-profile Stage 0 evaluation

## Recommendation

Proceed only to a separately specified parser-backed prototype, not production
adoption. Use explicit normalized origin plus a versioned, path-derived template
family rule; require at least three distinct training pages; and freeze a
content-addressed structural profile before publication. A profile may add
evidence to the future #26 single-page decision, but recurrence must never be a
removal rule by itself. Unknown families, fewer than three samples, unseen
layout revisions, or a removal score below 3 must abstain and fall back to #26.

This recommendation is boundary evidence from a small synthetic corpus. It
does not establish live-web accuracy, parser integration, a durable schema, or
a production threshold. Those remain unready until #26 exists and a new
contract defines parsing, persistence, rollout, and representative
rights-cleared evaluation.

## Corpus and method

The experiment contains 15 authored saved HTML pages and 75 independently
authored human-reviewed block spans. Ten pages train four profiles; five pages
are held out. The sets have disjoint page identities. The immutable manifest
binds each page's explicit origin, path-derived family, layout revision, split,
filename, and SHA-256 digest. No live or private corpus is used.

The corpus has two template families (`article` and `gallery`) on one origin,
a `guide` family on another origin, a one-sample `report` family, and an unseen
article layout revision. Dynamic navigation, cookies, advertisements,
recommendations, account controls, timestamps, and footers vary their text.
Repeated meaningful tables, infoboxes, citations, captions, code, structured
lists, and article-series content are labelled content, not chrome.

Each fixture exposes bounded observations for a block: tag, semantic role,
structural DOM path, coarse position, text density, and link density. This is
deliberately not an HTML parser claim. The profile fingerprint excludes exact
text. Training counts each structural signature at most once per page.

A candidate removal requires all of:

- recurrence on at least two of three training pages (threshold `0.66`);
- a chrome-evidence score of at least 3, where chrome role contributes 2 and
  edge position, low text density, and high link density contribute 1 each;
- no semantic preservation veto for article/main, table, infobox, citation,
  caption, code, or structured-list roles.

Every decision records one bounded reason plus its recurrence and score. The
checker recomputes decisions from fixture bytes; human truth is read only when
scoring the held-out result.

## Results

Three sufficiently sampled, revision-matched held-out pages were scored. They
contain 6 content spans and 9 chrome spans. Content precision and recall were
both `1.000`; chrome precision and recall were both `1.000`. Two other held-out
pages explicitly abstained: the one-sample report family and the unseen article
layout revision. Abstentions are excluded from the precision/recall
denominators and reported separately, so they cannot inflate quality silently.

The comparison and mutants were:

| Choice or mutant | Observed outcome | Decision |
| --- | --- | --- |
| Origin-only grouping | 3 training pages assigned to the wrong first-seen family on the shared origin | Reject |
| Origin + explicit path-family rule | 0 family errors in the authored manifest | Retain for the next prototype |
| One training page | Report family cannot distinguish recurrence from coincidence; 1 held-out page abstained | Reject as insufficient |
| Three distinct training pages | All 3 eligible families produced a frozen profile | Minimum for the next prototype, not a production claim |
| Exact-text recurrence | Missed 12 dynamic chrome spans, including the drift probe | Reject |
| Structural recurrence + score >= 3 + veto | 6/6 content and 9/9 chrome decisions correct on scored held-out pages | Best evaluated candidate |
| Recurrence alone | Deleted 6 repeated meaningful content spans | Reject; invariant violation |
| Unseen revision | 1 page abstained rather than applying a stale profile | Required drift behavior |
| Reversed input order | Identical profile identities and aggregate results | Pass |
| Poisoned held-out metadata | Training profile identities unchanged | Pass leakage control |

The perfect scored-page result is not an estimate of population accuracy. The
fixtures were authored to test decisions and failure modes, not sampled to
represent the web. The score threshold of 3 is a conservative evaluated
starting point: it requires recurrence plus multiple independent chrome cues.
The next stage must sweep thresholds on a larger rights-cleared corpus and
report confidence intervals and per-family error distributions before choosing
a production value.

## Frozen representation proposal

The preferred future representation is an immutable, canonical,
content-addressed record containing:

- normalized origin and the exact versioned family rule;
- sorted training page identities, layout revisions, and fixture/source
  digests, never held-out identities;
- algorithm version and canonical options, including minimum samples,
  recurrence threshold, score threshold, and preservation policy;
- sorted structural signature counts and bounded aggregate evidence; and
- an evidence digest, followed by the profile identity digest.

The experiment's identity binds origin, family rule, family, sorted training
identities/revisions/digests, algorithm/options, and evidence digest. Sorting
makes fetch, worker, and input order irrelevant. Publication would select a
frozen identity before extraction; no worker may mutate it online.

Persistence options considered were a mutable per-origin record, a generic log
of all DOM features, and the immutable versioned record above. Mutable online
learning makes publication order observable and rollback ambiguous. A generic
feature store creates a schema and privacy surface before evidence warrants it.
The immutable record best supports the known next requirement—multiple
templates and revisions per origin—and can be deleted or superseded without
rewriting published documents. This is a representation recommendation only;
no durable store is added here.

## Limits, risks, and next gate

The fixtures provide attributes instead of exercising the production parser,
and their coarse roles/densities are authored rather than inferred. The family
rule is declared rather than discovered. Three samples can demonstrate
variation but cannot establish a generally safe minimum. The corpus is too
small for confidence intervals, rare layouts, localization, personalization,
or adversarial markup. An infobox is exercised only in the insufficient-sample
abstention family, while the other named meaningful structures are exercised
on scored or drift-held-out pages.

Any next stage needs a fresh Tier 3 contract after #26 defines the fallback
boundary. It should derive observations through the selected parser, use a
larger rights-cleared multi-origin corpus, keep train/held-out provenance
immutable, sweep family and confidence thresholds, and specify durable record
compatibility and rollback. Deleting `experiments/template_profiles/**` and
this document completely rolls back Stage 0.

## Reproduction

From the repository root:

```console
ldc2 -i -I=experiments/template_profiles -O3 -release \
  experiments/template_profiles/check.d \
  -of=/tmp/template-profile-check
/tmp/template-profile-check experiments/template_profiles
```
