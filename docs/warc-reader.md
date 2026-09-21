# WARC/1.1 readers

`effects.warc_reader.WarcReader` accepts arbitrary byte chunks through `feed`,
then requires one `finish` call. It emits one fully validated, owned `WarcRecord`
per callback. The callback returns `false` to cancel. Exceptions propagate;
after cancellation, exception, or `finish`, the reader cannot be reused.
Earlier completed callbacks are not rolled back on a later failure.
Callbacks cannot call `feed` or `finish` on the same reader; such reentrant
calls fail without changing parser state. A callback may catch that rejection
and return normally, or let it propagate and stop the reader.

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
`block` is the exact declared octets, including any HTTP headers or binary bytes.
A retained record
retains at most its own bounded block and fields. Retaining many records is the
caller's memory policy.

This is an intentionally limited reader against the [IIPC WARC/1.1 format](https://iipc.github.io/warc-specifications/specifications/warc-format/warc-1.1/):
exact `WARC/1.1` and CRLF framing; mandatory record ID, date, type,
and decimal Content-Length; case-insensitive field names; warcinfo forbids
Target-URI, metadata permits it, and other supported record types require it.
Unknown header fields are retained. The reader rejects folded, RFC 2047
encoded-word in text-valued fields, and segmented fields. URI-structured WARC
fields preserve query bytes even when they resemble a complete encoded-word;
other fields accept a literal `=?` that is not a complete encoded-word. Its URI
check is a conservative syntax screen, not full RFC 3986 validation; date values are
retained, not normalized.
Extension field names use the IIPC ASCII `token` grammar, and header values
reject control characters other than horizontal tab used as linear whitespace.
It does not support WARC/1.0, compression, recovery/resynchronization, HTTP
payload extraction, or full WARC conformance.

`conversionText()` is available only for a `conversion` record with exactly
`Content-Type: text/plain` and valid UTF-8 block bytes. This is a WET-style
conversion seam, not a Common Crawl compatibility claim. A `response` block is
never silently treated as extracted text.
The reader validates conversion UTF-8 against the owned block without making
another whole-block copy. Calling `conversionText()` explicitly returns an
independent text copy owned by the caller.

Fixed, release-active caps are 4 KiB UTF-8 source key (checked before copying),
4 KiB header, 128 header fields, 64 KiB declared block, and 128 KiB combined
key/header/block record budget. Limits apply per record, not per feed; a single feed
may contain multiple valid records and exceed 128 KiB. The reader does not copy
an entire input chunk. Callbacks can retain records, so total process memory
is not bounded by the parser's one-record limit.

The production regression is D-only:
`ldc2 -O3 -release -i -Isource experiments/warc_reader/production_check.d -of=<binary> && <binary>`.

## Bounded gzip/zstd adapter

`effects.warc_compressed.WarcCompressedReader` accepts `Compression.gzip` or
`Compression.zstd`, a stable `sourceKey`, and the same `WarcVisit` callback.
Feed arbitrary compressed chunks, then call `finish()`. `close()` explicitly
abandons the stream and releases owned native state; a failed, cancelled, or
finished adapter cannot be reused. A completed callback may catch a rejected
reentrant `feed`/`finish` call. Uncaught callback exceptions poison the adapter.

The supported subset is one independently compressed gzip member or one
dictionary-free zstd frame with declared content size and checksum **per
complete WARC/1.1 record**. Adjacent members/frames in a feed are valid and
preserve global ordinal order. The adapter uses a fresh `WarcReader` per
member, stages at most one parsed record, checks the native gzip footer or
zstd frame checksum and exact one-record boundary, then invokes the caller.
It feeds the plain reader byte by byte so a second record cannot grow beside
the one staged record.
A corrupt current member emits nothing; earlier completed members are not
rolled back. It never copies a whole archive and has no resynchronization.

Fixed limits per member are 1 MiB compressed bytes, 128 KiB expanded bytes,
and a conservative cumulative `expanded <= 64 * consumed compressed` rule.
The native decoder writes at most 16 KiB per call; the parser retains its own
bounded record. Zstd frame content size and window must be at most 128 KiB,
with `ZSTD_d_windowLogMax` set to 17 before decoding. Gzip uses system zlib's
gzip-only window mode. Missing zstd content size/checksum, dictionaries,
skippable/extension frames, large windows, invalid WARC, extra records in one
member, corrupt checksums, truncation and trailing junk are rejected. A lone
trailing byte that could begin a gzip header is reported as truncated.
`CompressedWarcError.reason` distinguishes empty, truncated, checksum,
over-cap, ratio, unsupported, invalid-WARC, cancellation, stopped and
reentrancy outcomes. The adapter does not claim WARC/1.0, segmented records,
Common Crawl compatibility, archive-wide rollback, or TB-scale throughput.

The D-authored release check is:
`ldc2 -O3 -release -i -Isource experiments/warc_reader/compressed_check.d .dub/zstd/libzstd_decompress.a -of=<binary> && <binary>`.
It compares exact source-key/ordinal/record-ID/type/block SHA-256 output with
plain WARC for response and WET-style conversion records under 1-byte,
127-byte, 16-KiB and whole-feed chunks. It also exercises late corruption,
truncation, unsupported metadata, byte/window/ratio/record caps, cancellation,
reentrancy, and process-level GC/RSS/FD observations.
Both response and WET parity additionally run through pinned, genuinely
compressed zstd-block goldens (block type 2, not raw blocks), whose frame
SHA-256, content size, checksum flag and first-block type are checked under
`-release`. They were produced by the official zstd v1.5.7 CLI built from the
release tarball with SHA-256
`eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3`.
The D harness authors the WARC bytes and offers
`<binary> --emit-zstd-golden <pinned-upstream>/programs/zstd` to reproduce the
Base64 and frame hashes after building upstream's `zstd` target. Normal
release checks use embedded goldens and do not invoke a compressor or network.
Run `<binary> --negative-control` to force an uncaught late gzip checksum
error under `-release`; a nonzero exit with `gzip footer checksum or size
mismatch` is required. On one macOS arm64 run of 400 sequential decoders,
process high-water RSS was 8,617,984 bytes, GC used bytes after collection
were 1,058,096 before and 5,952 after, and `/dev/fd` entries were 4
before/after.
Those are process-level observations, not per-record or real-file bounds; no
file adapter is included in this slice.

The supported native build is macOS arm64. zstd is the separately pinned
static v1.5.7 decompressor. Gzip explicitly opens macOS system
`/usr/lib/libz.1.dylib` with `dlopen`/`RTLD_FIRST` and calls its symbols through
`dlsym`; it closes the handle on finish, error, cancellation or explicit
`close()`. The release probe's `dladdr` identifies the actual decoder image as
that path and its `zlibVersion()` as 1.2.12. The SDK header and dylib current
version metadata are also 1.2.12. Because this is runtime dynamic loading,
`otool -L` on the probe does **not** list libz as a link-time load command;
the D runtime may itself contain separate bundled zlib symbols, which the
adapter does not call. No standalone-static package claim is made.

## Local-file transport (partial W06 slice)

`effects.warc_file.readWarcFile(root, relativePath, format, sourceKey, visit)`
streams one local regular file through the plain, gzip, or zstd reader. The
caller supplies a trusted input root and a stable source key; the relative path
is not used as record identity. The function returns the exact count of
callbacks that returned true. It opens each relative path component with
`openat` and no-follow semantics, rejects absolute paths, empty/dot/dot-dot
components, NUL, symlinks, directories, and non-regular leaves, and verifies
the opened leaf with `fstat`. A FIFO leaf is opened nonblocking before being
rejected, so it cannot hang the caller. The trusted root itself is opened as a
no-follow directory; its own ancestor path is trusted by the caller.

The transport reads into a fixed 16 KiB buffer and keeps the opened file
descriptor through EOF, then calls the reader's `finish`. Compressed native
state and the descriptor are explicitly released on success, parser failure,
callback cancellation, and thrown callback exceptions. `WarcFileError`
reports `phase` (`path`, `open`, `read`, `parser`, `cancel`, or `callback`),
`completed`, and the original parser/callback exception when applicable.
Earlier successful callbacks remain visible after a late error: there is no
archive-wide rollback or resynchronization. A callback returning false is
not counted as completed. The parser still checks compressed checksums before
each member's callback, and preserves source key, ordinal, headers, and block.

The adapter does **not** snapshot contents of a regular file modified by
another process while it is open. It has no file-discovery, CLI, S3, WARC/1.0,
Common Crawl, or throughput guarantee. Gzip retains the explicit macOS
runtime system-zlib dependency. The release-active D on-disk probe is
`ldc2 -O3 -release -i -Isource experiments/warc_reader/file_check.d .dub/zstd/libzstd_decompress.a -of=<binary> && <binary>`.
