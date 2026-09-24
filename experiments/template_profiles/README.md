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
