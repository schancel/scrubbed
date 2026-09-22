# Pure four-class PII policy, stage 1

`domain.pii_policy.applyPiiPolicy` accepts caller-owned valid UTF-8 bytes,
ordered `PiiFinding` values from `scanPii` (or the typed C01 findings overlay),
an explicit `PiiPolicy`, and an optional `allowRedact`. It returns independent
output bytes plus typed audit records. It has no storage, CLI, logger, or
publication path. The caller retains the original bytes; this module does not
alter them. It is the downstream seam for a separately reviewed C01 policy
overlay and CLI/export stage, not a generic policy engine.

- `report` copies the exact input. It does not suppress findings.
- `mask` copies the input and replaces every byte in the union of finding spans
  with ASCII `*`. Length and original byte offsets remain stable. A masked
  output remains valid UTF-8 because finding endpoints must fall on UTF-8
  character boundaries.
- `redact` replaces each maximal overlapping union with one fixed
  `[REDACTED]` marker. Adjacent spans are separate unions. The call fails
  unless `allowRedact=true` is supplied. Original offsets remain in audit,
  not in the shortened output.

No default action destroys content. A redacted output is neither reversible
nor a claim of full de-identification. Consumers must make their own explicit
publication decision. Ambiguous phone/card findings contribute to unions and
remain visible in audit; the policy does not reclassify or silently drop them.

The audit holds each union's original half-open byte range, outcome, and every
contributor's original range and fixed category/rule/locale/confidence codes.
It contains no matched text, snippets, hashes, or source bytes. Exceptions
have fixed, content-free messages. The API rejects invalid UTF-8, nonboundary
or out-of-range spans, zero-width spans, non-strict scanner order, unsupported
category/rule/locale/confidence combinations, input over 1 MiB, and over 4096
findings before producing output. Findings with the same start/end but distinct
categories retain scanner order; exact duplicates are rejected.

Rollback is removal of this opt-in pure module and its tests/docs. No stored
artifact migration is needed. The parent outcome remains open until the
separately reviewed policy-overlay/publication stage lands and proves atomic
failure behavior with source and unrelated overlays preserved.

Focused release-active check:

```sh
ldc2 -O3 -release -Isource -of=.dub/pii-policy-check \
  experiments/pii_policy/check.d source/domain/pii_policy.d source/domain/pii_patterns.d
.dub/pii-policy-check
```
