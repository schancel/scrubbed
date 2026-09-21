# Uncompressed WARC/1.1 reader

`effects.warc_reader.WarcReader` accepts arbitrary byte chunks through `feed`,
then requires one `finish` call. It emits one fully validated, owned `WarcRecord`
per callback. The callback returns `false` to cancel. Exceptions propagate;
after cancellation, exception, or `finish`, the reader cannot be reused.
Earlier completed callbacks are not rolled back on a later failure.

```d
auto reader = new WarcReader("dataset/archive-source-key", (WarcRecord record) {
    // Store or process this record. The record owns its block and fields.
    return true;
});
reader.feed(inputChunk);
reader.finish();
```

The caller must supply a nonempty, stable UTF-8 source key independent of
transport filename and target URL. Record identity is the tuple `(sourceKey,
WARC-Record-ID, ordinal)`. The ordinal is one-based and distinguishes duplicate
record IDs within a source. Neither target URI nor filename alone is identity.
`recordId` preserves the original angle-bracketed WARC value. `fields` preserves
field order, original name casing, and raw value bytes after each colon;
`block` is the exact
declared octets, including any HTTP headers or binary bytes. A retained record
retains at most its own bounded block and fields. Retaining many records is the
caller's memory policy.

This is an intentionally limited reader against the [IIPC WARC/1.1 format](https://iipc.github.io/warc-specifications/specifications/warc-format/warc-1.1/):
exact `WARC/1.1` and CRLF framing; mandatory unique record ID, date, type,
and decimal Content-Length; case-insensitive field names; warcinfo forbids
Target-URI, metadata permits it, and other supported record types require it.
Unknown header fields are retained. The reader rejects folded, RFC 2047
encoded-word, and segmented fields. Its URI check is a conservative syntax
screen, not full RFC 3986 validation; date values are retained, not normalized.
It does not support WARC/1.0, compression, recovery/resynchronization, HTTP
payload extraction, or full WARC conformance.

`conversionText()` is available only for a `conversion` record with exactly
`Content-Type: text/plain` and valid UTF-8 block bytes. This is a WET-style
conversion seam, not a Common Crawl compatibility claim. A `response` block is
never silently treated as extracted text.

Fixed, release-active caps are 4 KiB header, 64 KiB declared block, and 128 KiB
per-record parser state. Limits apply per record, not per feed; a single feed
may contain multiple valid records and exceed 128 KiB. The reader does not copy
an entire input chunk. Callbacks can retain records, so total process memory
is not bounded by the parser's one-record limit.

The production regression is D-only:
`ldc2 -O3 -release -i -Isource experiments/warc_reader/production_check.d -of=<binary> && <binary>`.
