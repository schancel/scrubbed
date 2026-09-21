# WARC/WET compressed reader: prerequisite evidence

Status: scoped **uncompressed and compressed WARC/1.1 production candidates**
live in [`effects.warc_reader`](../source/effects/warc_reader.d) and
[`effects.warc_compressed`](../source/effects/warc_compressed.d), with API and
limits in [warc-reader.md](warc-reader.md). The older experiment evidence below
is retained as historical context; the new release-active adapter proof is
`experiments/warc_reader/compressed_check.d`. Issue #30 stays open: there is
no production archive file/source adapter, CLI command, or S3 integration.

## Normative boundary

[IIPC WARC 1.1](https://iipc.github.io/warc-specifications/specifications/warc-format/warc-1.1/)
defines a record as header, CRLF, `Content-Length` octets, then CRLF CRLF;
`WARC-Record-ID`, `WARC-Date`, `WARC-Type`, and `Content-Length` are mandatory.
Its Annex D recommends independently decompressible gzip members for seeking;
that is not mandatory uncompressed WARC record grammar.
The [IIPC zstd-WARC document](https://iipc.github.io/warc-specifications/specifications/warc-zstd/)
is explicitly **proposed/experimental**, not a standard: frames contain one
record or part of one record, require frame content size/checksum, and may use
dictionary or extension frames. We evaluate only dictionary-free,
single-frame-per-record files; no broader compatibility claim follows.
[Common Crawl's WET documentation](https://commoncrawl.org/get-started)
describes WET files as text extracted from WARC pages; the fixture models a
`conversion` text record, not a real Common Crawl archive or drop-in Common
Crawl compatibility: current public examples include WARC/1.0, outside this
fixture's WARC/1.1-only scope. Preserve archive
source key and `WARC-Record-ID` as separate fields; neither a filename nor a
presentation URL is assigned as canonical document identity here.

## Observed on macOS arm64

The D-only [probe](../experiments/warc_reader/check.d) generates two main records
and checks plain, gzip-member, and zstd-frame decoded records for equal ID,
URI, date, kind, source key, header SHA-256, body SHA-256, and block length.
The response contains HTTP header bytes plus `hi\0there`; the WET-style
conversion contains UTF-8 `café`. Separate positive fixtures exercise
`warcinfo` without a Target-URI and with a bracketed non-URN HTTPS record ID
through plain, gzip, and zstd decode, plus `metadata` with optional absent
Target-URI. The parser checks a record-ID URI scheme's basic character shape;
it does **not** fully validate RFC 3986 URIs. Exact main-fixture hashes observed:

| Authored fixture | Content-Type | Target-URI | Content-Length |
| --- | --- | --- | --- |
| response | `application/http` | required, nonempty | computed HTTP block bytes |
| conversion (WET-style) | `text/plain` | required, nonempty | computed UTF-8 text bytes |
| warcinfo | `application/warc-fields` | absent; even an empty field is rejected | computed `software:` field bytes |
| metadata | `application/warc-fields` | absent in positive; empty field rejected | computed `via:` field bytes |

All fixture lengths are decimal byte counts computed from the authored block,
not character counts. Presence is tracked independently of value, so an
empty first field cannot disguise a duplicate mandatory field. These are
format-consistent positive fixtures, not a claim of full WARC validation.

| Record ID suffix | Header SHA-256 | Body SHA-256 |
| --- | --- | --- |
| `...0001` | `1AF48705DC634605AD10FBEE02711C2635FA429B3E7271E74D6AB5FD7B8E3420` | `39AD3DAD2662D694C233E7BA171EDCB439020FBEBAFB8D8127C11EDFE7A411E4` |
| `...0002` | `E6CB6BE0F41709D716C8D871E8AFF0A60D310FEAACF69784FE1DB617E02F97DF` | `1F359813ACDD5E1A8BB0EF7AA6EBF46E477889FD0387BFD5050A1B0FF6A01D61` |

Release-active rejection covers invalid/missing/overflow/oversized
`Content-Length`, oversized header, truncated record, truncated/corrupt gzip
member, truncated/corrupt zstd frame, compressed-input cap, and a highly
compressible oversized block for each codec. These are code checks via
exceptions, not D `assert`, so `-release` does not remove them. One-byte input
chunks and 127-byte output chunks stress progress and boundary handling.
Plain WARC, gzip WARC, and zstd WARC reject zero-record input; the compressed
entry checks also reject empty input when the supplied parser already holds
records from an earlier call.
Unknown fields are ignored. The probe requires Target-URI for every evaluated
type except `warcinfo` (forbidden) and `metadata` (optional), consistent with
the WARC 1.1 field rule. Field names are handled case-insensitively, but
folded UTF-8 headers and RFC 2047 encoded-word decoding required of full
WARC/1.1 readers are not implemented. A failure rejects the entire archive, not a
best-effort skip; no resynchronization is promised. The parser can retain
earlier or current records when a late gzip/zstd checksum fails; release-active
negative cases prove this partial state. A caller **must discard the parser
and all its records on any decode error**. There is no atomic rollback claim.
The release-built `--negative-control` invocation deliberately feeds corrupt
gzip without catching the rejection and exits nonzero.

Bounds precede potentially large decompression output: at most 1 MiB
compressed input in memory; fixed 127-byte inflate output; at most 128 KiB
record pending; at most 4 KiB header and 64 KiB declared body. The zstd frame
content size is checked before decompression, and libzstd's streaming window
is capped at 128 KiB through `ZSTD_d_windowLogMax`. An additional 64:1 ratio
check applies during decoding and is exercised by separate 60 KiB repeated-
byte fixtures. On one macOS arm64 run, 100 repeated gzip decodes reported max RSS
2,392,064 to 6,651,904 bytes, GC used 352 to 18,768 bytes after collection,
and `/dev/fd` entries 4 before/after. A D-authored compressed fixture also
round-trips through a temp `File` with 127-byte reads and checks FD count 4,
5, 4 before/open/after explicit close. These are observations, not resource
budgets: max RSS is process high-water mark, and **descriptor lifetime across
error paths in a real archive reader remains unproven**. This is therefore not evidence that
a production reader can process arbitrarily large archives or preserve an
overall memory bound across I/O, callbacks, or concurrent work. No huge
decompressed output is allocated for the negative case (65 KiB is enough to
trigger the body cap), but the fixture generator allocates its 65 KiB input.

External zstd is upstream v1.5.7 tarball SHA-256
`eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3`,
statically built only in an isolated temp directory, under upstream's
BSD-style alternative. The exact acquisition/build commands and caveat are in
the [experiment instructions](../experiments/warc_reader/README.md). D's
Phobos is not used for decoding: the probe uses explicit zlib `inflate` and
libzstd `ZSTD_decompressStream` FFI to cap each output call.

## Production decisions still open

Before Issue #30 can close, a real archive source/CLI integration and its file
descriptor lifetime, corpus tolerance, and resource evidence still need a
separate accepted scope. The current memory-input adapter proves only the
bounded WARC/1.1 subset, not WARC/1.0, large segmented records, proposed
zstd dictionaries/multi-frame records, or all-platform packaging. Its
process-level RSS/GC/FD observations do not prove real-file descriptor
closure, archive-scale memory behavior, or recovery after corruption. The
source-key/record-ID/ordinal identity policy remains explicit, with no
archive-wide uniqueness index. Rollback of this adapter slice is deletion of
`source/effects/warc_compressed.d` and
`experiments/warc_reader/compressed_check.d`, plus restoration of their
documentation changes; the separately merged plain reader and pinned zstd
prerequisite remain in place.
