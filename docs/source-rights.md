# Source-rights policy seam

`domain.source_rights` is the version-1, effect-free boundary for recording
caller-supplied source-rights evidence and deciding what a later integration
must do. It neither discovers rights nor performs quarantine or removal.

## Scope

The module accepts already-stable identifiers and typed evidence. It returns a
deterministic decision containing the resolved state, required action, reason,
affected artifact identifiers, and provenance identifiers. It does not read
document content, locators, manifests, the network, or the filesystem.

This is a policy and graph-closure contract, not legal advice. Callers remain
responsible for establishing evidence outside this module. In particular,
missing evidence is `unknown`; `unknown` always produces `denyUse` and can
never be interpreted as permission.

## Version-1 values

All decisions use the `source-rights:v1` schema. Evidence has one of these
states, in increasing fail-safe precedence:

| State | Decision action | Meaning within this seam |
| --- | --- | --- |
| `unknown` | `denyUse` | No documented grant is present. |
| `documentedPermission` | `allowUse` | Caller supplied an explicit permission record. |
| `restriction` | `restrictUse` | Caller supplied a restriction. |
| `optOut` | `quarantineRequired` | A later effect layer must quarantine the closure. |
| `takedown` | `removalRequired` | A later effect layer must remove the closure. |

The highest-precedence supplied state wins. The action names are declarative:
this module cannot change storage or publication state.

Evidence and provenance identifiers are typed, canonical, content-free
SHA-256 identifiers (`evidence:v1:<hex>` and `provenance:v1:<hex>`). Affected
artifacts are source or child `DocumentId` values, or typed annotation and
export-reference identifiers. Raw URLs, paths, account names, source keys,
and evidence text do not belong in any of these identifiers.

## Derived-artifact closure

Callers provide parent-to-child relations over stable artifact identifiers.
For a valid graph, a decision includes the root source and every reachable
child document, annotation, and export reference in canonical lexical order.
Relations are a complete snapshot for the decision, so unreachable supplied
relations are rejected as orphans rather than ignored.

The evaluator fails closed with `denyUse` and an incomplete-closure marker for:

- an uninitialized root or evidence attached to another root;
- duplicate evidence or relation records;
- conflicting parents or reused provenance;
- cycles; and
- orphan relations.

The failed decision retains sorted content-free artifact and provenance IDs so
an audit can identify the rejected input set without recording source content.

## Determinism and audit identity

`RightsDecision.canonicalBytes` uses a fixed domain tag, enum bytes, a closure
flag, and length-prefixed sorted identifier lists. Input array order therefore
does not affect the result. `RightsAuditId` is a SHA-256 digest of those bytes
under the `rights-audit:v1:` prefix.

The release-active checker freezes the canonical SHA-256 vector
`045204abd8053ec076bdd07e4929220013084991c9c46bbe463446a5b559b9c5`.
It also proves that a private raw source locator is absent from canonical bytes
and audit IDs and that evaluation does not mutate caller inputs or upstream
content bytes.

Run the focused evidence gate with:

```sh
ldc2 -O -release -Isource \
  -of=/tmp/scrubbed-source-rights-check \
  experiments/source_rights/check.d \
  source/domain/source_rights.d source/domain/document.d
/tmp/scrubbed-source-rights-check
```

## Deferred integration

Stage 2 must bind these pure decisions to the real source manifest, annotation
index, export references, and effect boundary. That work must separately prove
complete affected-ID discovery, idempotent quarantine/removal behavior,
restart safety, authorization, and operator-visible auditing. Until then,
`quarantineRequired` and `removalRequired` are policy results only; no
production path consumes them.
