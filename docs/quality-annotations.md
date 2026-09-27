# Quality annotations (opt-in D API)

`effects.quality_overlay` publishes two separate C01 overlays for per-document
quality: a feature overlay and a policy-decision overlay. Both are opt-in —
no CLI command exists yet.

## Usage

1. `publishMeasurements(shard, featureOverlay)` — measure every document
   once, write the feature overlay.
2. `dryRun(shard, featureOverlay, policy)` or
   `publishDecisions(shard, featureOverlay, decisionOverlay, policy)` —
   replay stored features against a policy.

Replay decodes the stored `measurement` bytes and never calls the
content-measurement function again, so re-scoring a corpus under a new
policy doesn't re-touch source text. `dryRun` writes nothing.
`publishDecisions` writes the decision overlay only after every record
validates.

Publication is atomic **per overlay**, via C01's `OverlayWriter`. It is not
a transaction across both overlays, and it does not fsync the parent
directory or protect against a hostile directory race.

## Storage format

| Overlay | Analyzer key | Version |
| --- | --- | --- |
| Features | `quality.features` | `features:v1:schema=1` |
| Decisions | `quality.decisions` | `decisions:v1:feature=1:decision=1:policy=<lowercase SHA-256>` |

- Every C01 header carries the exact source-shard digest; every record
  binds the typed document ID and exact content digest.
- The decision value stores the canonical policy bytes, their SHA-256, the
  encoded measured feature value, the disposition, the ordered reasons, and
  the pure API's per-document analyzer identity — that identity lives in
  the value, not the overlay-wide header.
- Changing the policy changes the decision version and value; feature
  overlay bytes are unchanged.

Validation:

- Missing, stale, wrong-version, unexpected-field, or malformed
  measurements fail explicitly; a failed publish leaves any prior decision
  overlay in place.
- A decision destination can't alias its own feature-overlay input by
  normalized path or existing inode; C01 still rejects unsafe
  symlink/hardlink targets.
- Analyzer key/version and policy are validated even for an empty source
  shard, before any record callback or decision publication.

## Features and bins

Seven fixed-integer-count features, five bins each: `0`, `1–4`, `5–15`,
`16–63`, `64+`.

- Byte length
- Scalar count *
- Line count *
- Letter count *
- Control count *
- Replacement count *
- Duplicate line count *

The six starred (text-derived) features also have an `unavailable` bucket
for invalid UTF-8 documents; byte length stays available regardless.

## Dry-run report

`DryRunReport` counts every document exactly once as KEEP, DROP, or
QUARANTINE. Reason counts may overlap for DROP (one document can trip
several reasons) and are reported in `Reason` enum order. A quarantine is
never silently treated as zero text.

Processing streams one C01 frame at a time with bounded per-document
memory — it does not buffer the corpus. This is not a TB-scale throughput
claim.

## Proof (release-active checker)

`experiments/quality/check.d` builds a synthetic six-document overlay
corpus: `train` keys `empty`/`plain`, held-out keys
`repeat`/`invalid`/`control`/`replacement`.

- Full-corpus SHA-256 (sorted, C01-encoded payloads):
  `e49f8e9ca1dc7633fb33fcc7fbe6ea5a077cc2f3dd5f1ca9e9d90aea6f10fba7`
- Held-out-only SHA-256:
  `f0ceced0dfee7bee2b5d270bdc8a0b2d7d084877868d8dda54775dcad61aeba8`

It pins exact held-out-only and full-split distribution/reason goldens,
two-policy replay over identical stored feature bytes, source and
unrelated-overlay invariance, identity rejection, an injected prepublish
failure, and repeated 1,024-document memory/descriptor checks.

These are boundary examples, not measured web-quality accuracy: short
legitimate pages can be false positives under a minimum-length policy, and
long spam/boilerplate can be false negatives, because these features don't
assess meaning or provenance.

## Rollback

Stop using and remove the opt-in quality overlays/effects module. The C01
shard format and the pure feature API are unaffected.
