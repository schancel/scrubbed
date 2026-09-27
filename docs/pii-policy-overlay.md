# Four-class PII policy overlay (opt-in)

`effects.pii_policy_overlay` composes an immutable C01 source shard, its
`pii.four-class` findings overlay ([pii-annotations.md](pii-annotations.md)),
and the pure [`domain.pii_policy`](pii-policy.md) decision, then writes a
separate `pii.policy` C01 overlay through `publishPiiPolicy`. There's no CLI
route or transformed-corpus output at this stage.

## Choosing a policy

The caller picks `US` or `GB` locale, `report`/`mask`/`redact`, and an
explicit `allowRedact` flag — redact requires that flag at both publication
and replay. These are four-class scanner decisions, not a guarantee of
complete de-identification; ambiguous phone and card findings remain present
in the typed audit regardless of policy.

## Wire format

The header pins the exact source-shard SHA-256, `pii.four-class`
version/locale, policy code, and overlay format version.

Each source document has exactly one `decision` field, canonical tag `PIP1`:

| Field | Bytes |
| --- | --- |
| policy byte | 1 report / 2 mask / 3 redact |
| locale byte | 1 US / 2 GB |
| output digest | 32-byte SHA-256 of the derived output |
| union count | big-endian u16 |
| union records | see below |

Each union record: big-endian u32 half-open start/end offsets, big-endian
u16 contributor count, then per contributor a big-endian u32 start/end pair
and one finite rule byte (`1` email ASCII domain/high, `2` national
phone/ambiguous, `3` international phone/high, `4` Luhn card/ambiguous, `5`
IPv4/high). Locale applies to every contributor in the value. Category,
confidence, and outcome are all uniquely derived from these codes, so no raw
matched or transformed bytes are stored.

## Publish

- Validates the findings header even for an empty shard, and joins every
  source document by ID and revision.
- Fails before the atomic rename on missing, orphan, malformed,
  wrong-version, or stale findings.
- The destination must be distinct from source and findings by inode; an
  existing destination must belong to the exact same policy, locale, and
  shard. A nonregular, hard-linked, or wrong-owner destination is refused.
- C01's temporary-file fsync-and-rename retains the prior destination bytes
  and inode on failure, before rename. Source, findings, and unrelated
  overlays are never written.
- The 64 KiB C01 annotation limit is hard; an overlarge audit value refuses
  publication.

Not promised: a cross-file transaction, directory fsync/power-loss
durability, or protection from hostile concurrent directory mutation.

## Replay

Replay recomputes the pure result from source bytes and findings, and checks
the entire canonical value — including digest and audit — before yielding
that record's output and audit to an explicit callback. A later corrupt
record can still cause failure after earlier callbacks ran; callers needing
all-or-nothing consumption must stage their own output.
