# Deterministic PII pattern scanner

`domain.pii_patterns.scanPii` finds four bounded, ASCII-oriented PII patterns
in UTF-8 bytes. It's pure — no I/O, no storage, no CLI.

```d
scanPii(bytes, locale)   // locale is "US" or "GB"
```

- Input cap: 1 MiB; input must be valid UTF-8.
- Returns findings sorted by starting byte, ending byte, category.
- Spans are half-open byte offsets into the original content.
- Overlapping findings are retained — this scanner makes no redaction
  decision. See [pii-policy.md](pii-policy.md) for the layer that does.

## What it recognizes

| Category | Rule | Confidence | Example |
| --- | --- | --- | --- |
| email | ASCII-domain email | high | `name@example.com` |
| phone | US/GB national format | ambiguous | `202-555-0142`, `(415) 555-0199`, `020 7946 0958` |
| phone | US/GB international format | high | `+1-202-555-0142`, `+1 (415) 555-0199`, `+44 20 7946 0958` |
| card | issuer-prefix + Luhn-valid, 13–19 digits | ambiguous | `4111 1111 1111 1111` |
| ip | canonical dotted IPv4 | high | `192.0.2.9` |

National phone and card matches are always `ambiguous`: formatting or a
checksum alone doesn't establish that the bytes identify a person or a
payment card. Every finding carries its rule and locale.

## Edge cases

- A terminal period ending a sentence is excluded from the match span.
- Malformed numeric extensions and chained `@` addresses are rejected.
- A card candidate followed by a separator and digit (looks like one more
  group) is conservatively not emitted — even if that following token
  independently matches an IP address, the IP finding is still emitted. A
  punctuation delimiter such as `;` preserves both findings.

## Limits

Unsupported locale, invalid UTF-8, input over 1 MiB, or more than 4096
findings all throw a fixed diagnostic message with no matched text.

## Not included

This is not complete de-identification, NER, policy masking, or universal
locale support. It neither reads nor writes a shard or overlay — the
effects-layer overlay built on top lives in
[pii-annotations.md](pii-annotations.md). Additional identifiers need a
separate owner decision.

Never log source content or interpolate matched substrings when integrating
this API.

## Release-active check

```sh
ldc2 -O3 -release -Isource -of=.dub/pii-patterns-check \
  experiments/pii_patterns/check.d source/domain/pii_patterns.d \
  source/domain/encoding_failure.d
.dub/pii-patterns-check
```
