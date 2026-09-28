# warc-reader

A minimal, zero-dependency, pure-D incremental reader for **uncompressed**
WARC/1.1 record streams. `WarcReader` accepts arbitrary byte chunks through
`feed`, then requires one `finish` call, emitting one fully validated, owned
`WarcRecord` per callback.

This package depends only on Phobos (`std.string`, `std.utf`) -- no
scrubbed domain types, no platform-specific code, no FFI. It was extracted
unchanged from [scrubbed](https://github.com/schancel/scrubbed)'s
`source/effects/warc_reader.d`.

## Scope: what this package does NOT do

This is a deliberately narrow first slice. It reads **uncompressed WARC/1.1
byte streams only**. The following are explicitly excluded from this
package, on purpose:

- **Compressed WARC (gzip/zstd) support.** Scrubbed's own
  `effects.warc_compressed` layers gzip/zstd decompression on top of this
  same reader, but does so through a macOS-only `dlopen` binding onto the
  system `libz` (a real, separate platform lock, tracked upstream as
  scrubbed issue #353). That dependency was **not** brought into this
  package. Adding compressed-stream support here is real, separate future
  work, pending a design decision on injecting decompression as an
  optional, caller-supplied dependency rather than a hard compile-time
  import (mirroring scrubbed's own `extraction.container` pattern of an
  injected `ZipInflateV1`-style callback) -- not a design question this
  package answers.
- **Local-file transport.** Scrubbed's `effects.warc_file` reads a WARC
  archive off a trusted local filesystem root. That transport layer imports
  `effects.warc_compressed` directly, so it inherits the same platform
  entanglement above; it was excluded from this package for the same
  reason. Callers of this package are responsible for their own I/O:
  hand `WarcReader.feed` whatever uncompressed bytes you already have, from
  any source (an in-memory buffer, a file you opened yourself, a network
  stream, etc).

If you need gzip/zstd-compressed WARC input or a ready-made local-file
reader today, use scrubbed's `effects.warc_compressed`/`effects.warc_file`
directly (macOS only, for now) rather than this package.

## Usage

```d
import warc_reader;

auto reader = new WarcReader("dataset/archive-source-key", (WarcRecord record) {
    // Store or process this record. The record owns its block and fields.
    return true;
});
reader.feed(inputChunk);
reader.finish();
```

- The callback returns `false` to cancel. Exceptions propagate.
- After cancellation, exception, or `finish`, the reader cannot be reused.
- Earlier completed callbacks are not rolled back on a later failure.
- Callbacks cannot call `feed`/`finish` on the same reader -- a reentrant
  call fails without changing parser state; the callback may catch that and
  return normally, or let it propagate and stop the reader.

The caller must supply a nonempty, stable UTF-8 source key, independent of
transport filename or target URL. Record identity is the tuple `(sourceKey,
WARC-Record-ID, ordinal)`; the ordinal is one-based and distinguishes
duplicate record IDs within a source. Neither target URI nor filename alone
is identity.

- `recordId` preserves the original angle-bracketed WARC value.
- `fields` preserves field order, original name casing, and raw value bytes
  after each colon.
- `block` is the exact declared octets, including any HTTP headers or
  binary bytes.

A retained record retains at most its own bounded block and fields.
Retaining many records is the caller's memory policy.

### Format scope

An intentionally limited reader against the
[IIPC WARC/1.1 format](https://iipc.github.io/warc-specifications/specifications/warc-format/warc-1.1/):

- Exact `WARC/1.1` and CRLF framing; mandatory record ID, date, type, and
  decimal Content-Length.
- Case-insensitive field names; unknown header fields are retained.
- `warcinfo` forbids Target-URI, `metadata` permits it, other supported
  record types require it.
- Extension field names use the IIPC ASCII `token` grammar; header values
  reject control characters other than horizontal tab used as linear
  whitespace.
- URI-structured WARC fields preserve query bytes even when they resemble a
  complete encoded-word; other fields accept a literal `=?` that is not a
  complete encoded-word. The URI check is a conservative syntax screen, not
  full RFC 3986 validation. Date values are retained, not normalized.

Rejected: folded fields, RFC 2047 encoded-word in text-valued fields, and
segmented fields. Not supported: WARC/1.0, compression, recovery/
resynchronization, HTTP payload extraction, or full WARC conformance.

### WET-style conversion text

`conversionText()` is available only for a `conversion` record with exactly
`Content-Type: text/plain` and valid UTF-8 block bytes. This is a WET-style
conversion seam, not a Common Crawl compatibility claim -- a `response`
block is never silently treated as extracted text. The reader validates
conversion UTF-8 against the owned block without another whole-block copy;
calling `conversionText()` returns an independent text copy owned by the
caller.

### Limits

Fixed, release-active caps, per record (not per feed -- a single feed may
contain multiple valid records and exceed the combined budget):

| Limit | Value |
| --- | --- |
| Source key (UTF-8, checked before copying) | 4 KiB |
| Header | 4 KiB |
| Header fields | 128 |
| Declared block | 64 KiB |
| Combined key/header/block budget | 128 KiB |

The reader does not copy an entire input chunk. Callbacks can retain
records, so total process memory is not bounded by the parser's one-record
limit.

## Building and testing

This package is entirely standalone: it has no dependency on the parent
`scrubbed` repository's own `dub.json`/`source/` tree.

```sh
dub build
dub test
```

`dub test` runs this package's own unit tests, ported unchanged in behavior
from scrubbed's `experiments/warc_reader/production_check.d` (its
release-active integration check for `effects.warc_reader`): chunk-invariant
bounding (1-byte/127-byte/whole-feed/irregular-chunk equivalence over a
>128 KiB, two-record aggregate archive), record-type recognition
(`warcinfo`/`metadata`/`response`/`conversion`/`revisit` target-URI rules),
and `WARC-Record-ID` handling (ownership, duplicate rejection, and
angle-bracket preservation), plus the reader's full rejection surface
(truncation, malformed/overflowing content lengths, duplicate or missing
required fields, corrupt terminators, control characters, folded fields,
invalid UTF-8, RFC 2047 encoded-word fields, segmentation, and header/field
caps), reentrancy and cancellation handling, and conversion-text allocation
behavior.

## Publishing

This package is **not** published to code.dlang.org yet -- that is held for
a separate, explicit go-ahead.

## License

MIT. See this package's own `LICENSE` file.
