# Quality annotations (opt-in D API)

`effects.quality_overlay` publishes two separate C01 overlays. Call
`publishMeasurements(shard, featureOverlay)` once for a source shard, then call
`dryRun(shard, featureOverlay, policy)` or
`publishDecisions(shard, featureOverlay, decisionOverlay, policy)` for each
policy. Replaying a policy decodes the stored `measurement` bytes and never
calls the content-measurement function. Dry-run creates no file. Publication is
atomic **per overlay** through C01 `OverlayWriter`; it is not a transaction
across both overlays and does not claim parent-directory fsync or protection
against hostile directory races.

The stable analyzer keys are `quality.features` and `quality.decisions`.
Feature header version `features:v1:schema=1` binds the pure feature schema.
Decision header version `decisions:v1:feature=1:decision=1:policy=<lowercase
SHA-256>` binds both schemas and the canonical policy digest. C01's header
contains the exact source-shard digest. Each C01 annotation record also binds
the typed document ID and exact content digest. The decision value stores
canonical policy bytes, its SHA-256, the encoded measured feature value,
disposition, ordered reasons, and the pure API's per-document analyzer identity.
That identity belongs in the value, not the overlay-wide header. A different
policy changes the decision version and value, while feature overlay bytes stay
unchanged. Missing, stale, wrong-version, unexpected-field, and malformed
measurements fail explicitly; publication leaves any prior decision overlay in
place on failure. A decision destination that aliases its feature input by
normalized path or existing inode is refused before publication; C01's own
target checks still reject unsafe symlink and hardlink cases. Feature analyzer
key/version validation also runs for an empty source shard, before any record
callback or decision publication.

`DryRunReport` counts every document exactly once as KEEP, DROP, or QUARANTINE.
Reason counts may overlap for DROP and are in `Reason` enum order. All seven
named features use fixed integer bins `0`, `1–4`, `5–15`, `16–63`, `64+`.
The six text-derived features additionally have an `unavailable` bucket for
invalid UTF-8; byte length remains available. A quarantine is not silently
treated as zero text. Processing is one C01 frame at a time, with bounded
per-document memory; it does not collect the corpus. This is not a TB-scale
throughput claim.

The release-active D checker in `experiments/quality/check.d` authors a
synthetic six-document overlay corpus. `train` source keys are `empty` and
`plain`; the held-out `repeat`, `invalid`, `control`, and `replacement` keys
are distinct from the pure API's fixture corpus. SHA-256 of the sorted
concatenated C01 encoded document payloads for all six is
`e49f8e9ca1dc7633fb33fcc7fbe6ea5a077cc2f3dd5f1ca9e9d90aea6f10fba7`.
The four held-out rows are also materialized as their own shard; their sorted
encoded-payload SHA-256 is
`f0ceced0dfee7bee2b5d270bdc8a0b2d7d084877868d8dda54775dcad61aeba8`.
The checker pins exact held-out-only and full-split distribution and reason
goldens, two-policy replay over
identical stored feature bytes, source and unrelated-overlay invariance,
identity rejection, injected prepublish failure, and repeated 1,024-document
memory/descriptor checks. These synthetic examples are boundary evidence,
not measured web-quality accuracy. Short legitimate pages can be false
positives under a minimum-length policy; long spam or boilerplate can be false
negatives because these named features do not assess meaning or provenance.

Rollback is to stop using and remove the opt-in quality overlays/effects
module. C01 shard format and the pure feature API remain unchanged.
