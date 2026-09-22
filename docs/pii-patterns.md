# Deterministic PII pattern slice

`domain.pii_patterns.scanPii` takes C01 opaque content bytes and an explicit
`US` or `GB` locale. It first checks the 1 MiB input cap and valid UTF-8,
then returns findings sorted by starting byte, ending byte, and category.
Spans are half-open byte offsets into the original content. Overlaps are
retained for the later policy layer; callers must not assume findings are a
redaction decision.
An ordinary terminal period delimits a finding and is excluded from its span;
malformed numeric extensions and chained `@` addresses are rejected.
For grouped cards, a following space or hyphen and digit is conservatively
treated as a possible extra group: no card candidate is emitted, even when
the following token independently matches an IP address. That IP finding is
still emitted. A punctuation delimiter such as `;` preserves both findings.

The first slice recognizes conservative ASCII email domains, US/GB telephone
formats, issuer-prefix and Luhn-valid 13–19 digit card candidates, and canonical dotted IPv4.
US numbers use `202-555-0142` or `+1-202-555-0142`; GB numbers use
`020 7946 0958` or `+44 20 7946 0958`. National phone forms and card
candidates are explicitly `ambiguous`: formatting or a checksum alone does
not establish that the bytes identify a person or a payment card. The rule
and locale travel with every finding. Unsupported locale, invalid UTF-8,
input overflow, and more than 4096 findings throw fixed diagnostic messages
without matched text.

This is not complete de-identification, NER, policy masking, or universal
locale support. It neither reads nor writes a shard or overlay. The subsequent
effects-layer overlay remains a separate landing; additional identifiers
require an owner decision. Do not log source content or interpolate matched
substrings when integrating this API.

Release-active check:

```sh
ldc2 -O3 -release -Isource -of=.dub/pii-patterns-check \
  experiments/pii_patterns/check.d source/domain/pii_patterns.d
.dub/pii-patterns-check
```
