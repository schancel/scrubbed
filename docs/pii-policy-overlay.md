# Four-class PII policy overlay (opt-in)

`effects.pii_policy_overlay` composes an immutable C01 source shard, its
`pii.four-class` findings overlay, and the pure `domain.pii_policy` decision.
It writes a separate `pii.policy` C01 overlay through `publishPiiPolicy`.
There is no CLI route or transformed-corpus output in this stage.

The caller chooses `US` or `GB`, `report`, `mask`, or `redact`, and an explicit
`allowRedact` flag. Redact requires that flag at both publication and replay.
Report returns a copy of original bytes; mask replaces matched bytes with
ASCII `*` without changing length; redact replaces each maximal overlapping
union with one `[REDACTED]` marker. These are four-class scanner decisions,
not a guarantee of complete de-identification. Ambiguous phone and card
findings remain present in the typed audit.

The policy header pins the exact source-shard SHA-256, `pii.four-class`
version/locale, policy code, and this overlay format version. Each source
document has exactly one `decision` field. Its canonical `PIP1` value has a
policy byte (1 report, 2 mask, 3 redact), locale byte (1 US, 2 GB), 32-byte
SHA-256 of the derived output, a big-endian 16-bit union count, then union
records. A union record contains big-endian 32-bit half-open start/end byte
offsets and a big-endian 16-bit contributor count. Each contributor has
big-endian 32-bit start/end offsets and one finite rule byte: 1 email ASCII
domain/high, 2 national phone/ambiguous, 3 international phone/high, 4 Luhn
card/ambiguous, 5 IPv4/high. Locale applies to all contributors in the value.
The typed category, confidence, and outcome are uniquely derived from these
codes, so no raw matched or transformed bytes are stored.

Publish validates the findings header even for an empty shard and joins
every source document by ID and revision. Missing, orphan, malformed,
wrong-version, or stale findings fail before the atomic rename. Replay
recomputes the pure result from source bytes and findings, and checks the
entire canonical value—including digest and audit—before yielding that
record's output and audit to an explicit callback. A later corrupt record can
still cause failure after earlier callbacks; callers needing all-or-nothing
consumption must stage their own output. The 64 KiB C01 annotation limit is
hard, and overlarge audit values refuse publication.

The destination must be distinct from source and findings by inode, and an
existing destination must belong to the exact same policy, locale, and shard.
A nonregular, hard-linked, or wrong-owner destination refuses replacement.
C01's temporary-file fsync and rename retain the prior destination bytes and
inode on failures before rename. Source, findings, and unrelated overlays
are never written. This does not promise a cross-file transaction, directory
fsync/power-loss durability, or protection from hostile concurrent directory
mutation.
