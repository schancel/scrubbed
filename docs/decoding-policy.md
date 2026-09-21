# Raw-byte decoding policy

`text.decoding.decodeBytes` is a standalone D facade under `source/text`.
It accepts a borrowed `const(ubyte)[]`, an optional declared charset, and a
caller-supplied source label. It returns either owned, valid UTF-8 text with
selected encoding, BOM, declaration, source, and consumed byte count, or a
typed quarantine with reason, source, original byte count, BOM/declaration
evidence, and an absolute offending byte offset where the failure identifies
one. Quarantine retains no raw byte slice or whole-input copy; the caller owns
the original bytes and must retain them separately if later inspection needs
them. The source label is not parsed as a path or identity.

The no-evidence default is strict UTF-8. UTF-8 (`utf-8`, `utf8`), UTF-16LE
(`utf-16le`, `utf16le`), and UTF-16BE (`utf-16be`, `utf16be`) are supported,
ASCII case-insensitively with surrounding ASCII whitespace ignored. The
generic labels `utf-16` and `utf16` require a UTF-16 BOM to resolve byte
order; without one they quarantine as ambiguous. Other labels, including
Latin-1 and CP1252, quarantine as unsupported. An explicitly supplied blank
or unrecognized label does not silently become the default.

A UTF-8 or UTF-16LE/BE BOM selects the encoding and is consumed, not emitted
as text. A declaration must match that selection; conflict quarantines before
the payload is decoded. An unsupported declaration quarantines even when a
BOM is present. Generic UTF-16 agrees with either UTF-16 BOM but conflicts
with a UTF-8 BOM. Without BOM, a supported endian-specific declaration
selects that encoding. Empty input and BOM-only input decode to empty text
when declaration evidence is compatible.

Malformed, overlong, truncated, surrogate, and out-of-range sequences
quarantine; there is no replacement character, legacy-codepage fallback, or
normalization pass. The first invalid byte (or the lead byte of a truncated
UTF-8 sequence) is reported; UTF-16 reports the first byte of an incomplete
unit, unpaired high surrogate, or forbidden scalar, and the first byte of a
non-low unit after a high surrogate. Binary evidence is deliberately limited
to the selected forbidden Unicode controls: U+0000–U+001F except tab, line
feed, and carriage return, plus U+007F (DEL). C1 controls U+0080–U+009F are
not treated as binary evidence because they can occur in legitimate Unicode
text. A forbidden control's first source byte is reported as
`binaryControl`. This permits ordinary whitespace while rejecting NUL and
escape/control streams. It does not use density or language heuristics.

An undeclared legacy byte such as `E9` is invalid UTF-8, hence quarantined;
an ASCII-compatible byte stream that happens to be from another charset is
undecidable and remains UTF-8. No detector attempts to infer it. The current
CLI, pipeline, filters, stages, and `Content` do not call this facade; a later
integration ticket owns that switch. Future charset support belongs at this
byte boundary with explicit policy and tests, not inside text filters. The
facade can be removed without stored-data migration; no durable record shape
changes here.
