# Pure four-class PII policy

`domain.pii_policy.applyPiiPolicy` turns ordered `PiiFinding`s (from
[`scanPii`](pii-patterns.md) or the typed C01 findings overlay) into
independent output bytes plus a typed audit trail. It's pure — no storage,
CLI, logger, or publication path — and it never alters the caller's original
bytes.

This is the seam a separately-reviewed C01 policy overlay and CLI/export
stage build on, not a general-purpose policy engine.

## Policies

| Policy | Effect | Notes |
| --- | --- | --- |
| `report` | copies the input unchanged | default; never suppresses findings |
| `mask` | replaces every byte in each finding span with ASCII `*` | length and original byte offsets stay stable; output remains valid UTF-8 because finding endpoints always fall on UTF-8 character boundaries |
| `redact` | replaces each maximal overlapping union with one fixed `[REDACTED]` marker | requires `allowRedact=true`; adjacent (non-overlapping) spans are separate markers |

No default action destroys content. A redacted output is neither reversible
nor a claim of full de-identification — consumers make their own explicit
publication decision. Ambiguous phone/card findings still contribute to
unions and remain visible in the audit; policy never reclassifies or drops
them.

## Audit

Each audit entry holds a union's original half-open byte range, its outcome,
and every contributor's original range plus fixed category/rule/locale/
confidence codes. It contains no matched text, snippets, hashes, or source
bytes.

## Validation

Before producing output, `applyPiiPolicy` rejects: invalid UTF-8, non-boundary
or out-of-range spans, zero-width spans, non-strict scanner ordering,
unsupported category/rule/locale/confidence combinations, input over 1 MiB,
and more than 4096 findings. Findings with the same start/end but distinct
categories retain scanner order; exact duplicates are rejected. Exceptions
carry fixed, content-free messages.

## Rollback

Removing this opt-in pure module and its tests/docs needs no stored-artifact
migration. The parent outcome stays open until the separately-reviewed
policy-overlay/publication stage ([pii-policy-overlay.md](pii-policy-overlay.md))
lands and proves atomic failure behavior with source and unrelated overlays
preserved.

## Focused release-active check

```sh
ldc2 -O3 -release -Isource -of=.dub/pii-policy-check \
  experiments/pii_policy/check.d source/domain/pii_policy.d source/domain/pii_patterns.d \
  source/domain/encoding_failure.d
.dub/pii-policy-check
```
