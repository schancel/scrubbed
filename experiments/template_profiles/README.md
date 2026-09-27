# Frozen template-profile evaluation

This evidence-only package evaluates whether multi-page structural recurrence can
help a future single-page extractor distinguish primary content from site chrome.
It does not import production modules, fetch pages, or define a persisted format.

`fixtures/pages.tsv` fixes the explicit origin, path-derived family, split,
layout revision, filename, and SHA-256 digest for each authored saved page.
`fixtures/human-spans.tsv` is the independently authored content/chrome truth;
the evaluator never uses those labels while training or deciding. HTML
`data-*` attributes expose the bounded DOM, semantic, position, text-density,
and link-density observations that a future parser-backed implementation would
have to derive.

Build and run the optimized release checker from the repository root:

```console
ldc2 -i -I=experiments/template_profiles -O3 -release \
  experiments/template_profiles/check.d \
  -of=/tmp/template-profile-check
/tmp/template-profile-check experiments/template_profiles
```

The checker verifies fixture hashes, split disjointness, truth coverage,
profile identity/order independence, held-out exclusion, minimum-sample,
low-confidence, and layout-drift abstention, grouping confusion,
structural-versus-exact-text behavior, content-variation and preservation-veto
mutants, recurrence-only deletion, bounded decision evidence, and held-out
content/chrome precision and recall.

## Production port cross-check

Issue #244's production-wiring slice ports this evaluation's training/
classification algorithm into `source/domain/template_profiles.d`, a pure
domain module operating on a real tree-plus-node-index shape instead of this
experiment's TSV/one-line-HTML fixture format. `domain_check.d` in this
directory rebuilds every fixture `Block` as a `domain.template_profiles.
BlockTree` slice (its `data-role`/`data-path`/`data-position`/`data-density`/
`data-links` become real `BlockAttribute`s) and asserts the ported module's
`classifyBlock` produces byte-identical decisions -- keep, abstain, score,
recurrence, content variation, and reason -- to this evaluation's own
`classify` on every held-out block. Build and run it alongside `check.d`:

```console
ldc2 -I=experiments/template_profiles -Isource \
  experiments/template_profiles/domain_check.d \
  experiments/template_profiles/evaluation.d \
  source/domain/template_profiles.d source/crypto/sha256.d \
  source/crypto/sha256_x86_64.d source/crypto/sha256_arm64.d \
  source/text/decoding.d \
  -of=/tmp/template-profile-domain-check
/tmp/template-profile-domain-check experiments/template_profiles
```
