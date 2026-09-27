# Four-class PII findings overlay

`effects.pii_overlay.publishPiiFindings` is an opt-in effects facade that
persists [`scanPii`](pii-patterns.md) findings as a C01 annotation overlay.
No CLI route uses it today.

## What it does

- Reads one C01 document frame at a time, calls the pure `scanPii` once per
  document with an explicit `US` or `GB` locale.
- Publishes a replacement overlay only after every document in the shard
  succeeds.
- Analyzer key `pii.four-class`; version `four-class:v1:locale=US` or
  `four-class:v1:locale=GB`.
- Leaves the source shard and every other analyzer's overlay untouched. An
  existing destination must already be this analyzer's overlay for the same
  source shard — the facade refuses to replace an unrelated overlay.

## Wire format

Every document — including one with zero findings — gets one `findings`
annotation field:

| Bytes | Meaning |
| --- | --- |
| `PII1` (4) | ASCII tag |
| 1 | locale (`01` US, `02` GB) |
| 2 | big-endian finding count |
| 9 × count | one record per finding |

Each finding record is big-endian 32-bit start offset, big-endian 32-bit
end offset (half-open), then one rule byte:

| Rule code | Meaning | Confidence |
| --- | --- | --- |
| `01` | email, ASCII domain | high |
| `02` | phone, national | ambiguous |
| `03` | phone, international | high |
| `04` | card, Luhn | ambiguous |
| `05` | IPv4 | high |

Category, confidence, and locale all derive from these codes — no matched
text, value hash, or source-specific metadata is ever stored in the value.
Findings retain the pure scanner's strict order and overlaps.

The C01 record binds document ID and content digest; its header binds the
source-shard digest, analyzer key, and version. A different locale or version
is rejected even for an empty shard.

## Reading it back

`visitPiiFindings` validates the header and every record on one open overlay
descriptor — so a legitimate path replacement can't change the version
mid-replay — then hands the callback only the document ID and typed
findings, never source bytes. It validates source UTF-8 but does not
rescan for findings.

Findings are not a policy or redaction decision — see
[pii-policy.md](pii-policy.md) and
[pii-policy-overlay.md](pii-policy-overlay.md) for that layer. Scanner and
overlay errors use fixed, non-content-bearing text.

## Limits

- Scanner limits apply: 1 MiB input, 4096 findings.
- C01's 64 KiB annotation-frame cap is checked before publication, with no
  truncation.
- Publication is atomic under C01's trusted exclusive-directory premise —
  not a hostile-directory-race or parent-directory-fsync durability
  guarantee.

Removing the opt-in facade and its generated overlay doesn't change source
shards or the pure scanner.

## Test corpus

`experiments/pii_patterns/overlay_check.d` uses its own synthetic held-out
corpus, separate from the pure-scanner check — authored directly in the
checker, sorted only to meet C01's ID order, and pinned by SHA-256
`3908aac7dbe24ad6db53e0bf65b69e1c07aac6ee4648bf2fd8cc424f1ada25f8` over
concatenated canonical document payloads. The first annotation value's exact
bytes are `50494931010002000000000000000c02000000000000001801`. Neither the
test corpus nor the overlay contains real-world samples.

## Release-active standalone check

```sh
ldc2 -O3 -release -Isource -of=.dub/pii-overlay-check \
  experiments/pii_patterns/overlay_check.d source/domain/document.d \
  source/domain/shard_format.d source/domain/pii_patterns.d \
  source/effects/document_shards.d source/effects/pii_overlay.d
.dub/pii-overlay-check
```
