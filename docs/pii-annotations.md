# Four-class PII C01 overlay

`effects.pii_overlay.publishPiiFindings` is an opt-in effects facade. It reads
one C01 document frame at a time, calls the pure `scanPii` once per document
with an explicit `US` or `GB` locale, and publishes a replacement overlay only
after all documents succeed. The version is `four-class:v1:locale=US` or
`four-class:v1:locale=GB`, under analyzer key `pii.four-class`. No CLI route is
installed. The source shard and other analyzer overlays are not changed.

Every document, including one with zero findings, has one annotation field
named `findings`. Its bytes are ASCII `PII1`, one locale byte (`01` US, `02`
GB), a big-endian 16-bit finding count, then nine bytes per finding: big-endian
32-bit half-open UTF-8 start and end offsets and one rule code. Rule codes
are `01` ASCII-domain email/high, `02` national phone/ambiguous, `03`
international phone/high, `04` Luhn card/ambiguous, and `05` IPv4/high.
Category, rule, locale, and confidence derive unambiguously from those codes.
Findings retain the pure scanner's strict order and overlaps. No source or
matched text, value hash, or source-specific metadata is stored in the value.
The C01 record binds document ID and content digest; its header binds the
source-shard digest, analyzer key, and version. The decoder validates lengths,
spans, order, rule codes, locale, and frame budget. A different locale or
version is rejected even for an empty shard.

`visitPiiFindings` validates the C01 join and supplies only document ID and
typed findings to the callback, without source bytes. It does not rescan.
Callers must not interpret a finding as a policy or redaction decision.
Scanner and overlay errors use fixed, non-content-bearing text. The scanner's
1 MiB input and 4096-finding caps apply; C01's 64 KiB annotation-frame cap is
checked before publication, with no truncation. Publication is atomic under
C01's trusted exclusive-directory premise, not a hostile-directory-race or
parent-directory-fsync durability guarantee. The opt-in facade and generated
overlay can be removed without changing source shards or the pure scanner.

`experiments/pii_patterns/overlay_check.d` has a separate synthetic held-out
corpus from the pure scanner check. The fixture is authored directly in that
checker, sorted only to meet C01's ID order, and pinned by SHA-256
`3908aac7dbe24ad6db53e0bf65b69e1c07aac6ee4648bf2fd8cc424f1ada25f8`
over concatenated canonical document payloads. The first annotation value's
exact bytes are
`50494931010002000000000000000c02000000000000001801`.
Neither test corpus nor overlay contains private real-world samples.

Release-active standalone check:

```sh
ldc2 -O3 -release -Isource -of=.dub/pii-overlay-check \
  experiments/pii_patterns/overlay_check.d source/domain/document.d \
  source/domain/shard_format.d source/domain/pii_patterns.d \
  source/effects/document_shards.d source/effects/pii_overlay.d
.dub/pii-overlay-check
```
