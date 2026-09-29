# parquet-d

A native D Parquet writer and reader for flat tables.
`parquet.writer.ParquetWriter` buffers rows in memory and serializes one
complete Parquet file with a single row group. `parquet.reader.ParquetReader`
reads flat Parquet files produced by other writers -- in particular the
pyarrow/parquet-cpp output that Hugging Face Hub corpora (FineWeb, C4, HF
`datasets` exports) are published as. The package has zero dependency on
scrubbed's own `dub.json` or `source/` tree and builds and tests entirely on
its own.

```d
import parquet.writer;

auto w = new ParquetWriter([
    ColumnSpec("id", ColumnType.int64, false),   // REQUIRED
    ColumnSpec("text", ColumnType.string_),      // OPTIONAL (nullable)
], WriterOptions(Compression.zstd));
w.addRow([ParquetValue(1L), ParquetValue("hello")]);
w.addRow([ParquetValue(2L), ParquetValue("")]);          // empty string
w.addRow([ParquetValue(3L), ParquetValue.null_]);        // null
w.writeFile("out.parquet");                              // or: ubyte[] bytes = w.finish();
```

## What it writes

- `PAR1` framing, Thrift compact-protocol footer (`FileMetaData` /
  `RowGroup` / `ColumnChunk` / `ColumnMetaData`), 4-byte little-endian footer
  length, trailing `PAR1`.
- One row group; one v1 data page per column.
- Column types: `string_` (`BYTE_ARRAY` + `STRING`/`UTF8`, UTF-8 validated on
  append), `int32`, `int64`, `double_`, `boolean`. Each column is `REQUIRED`
  or `OPTIONAL`; nested and repeated columns are not supported.
- `PLAIN` values. Nullable columns carry definition levels in the
  RLE/bit-packing hybrid encoding (bit-packed LSB-first), so a null and an
  empty string are distinct: pyarrow and DuckDB read them back as `None`/
  `NULL` and `""` respectively.
- zstd (default, level 3) or uncompressed pages.
- No dictionary encoding, no statistics, no page index, no Snappy.

Because footer offsets depend on the final compressed page sizes, the whole
row group is buffered until `finish()`: memory use is proportional to the
table. A column's page is limited to the Thrift `i32` page-size field
(< 2 GiB) and a table to `int.max` rows; both are checked with an exception
rather than overflowing.

## Reading

```d
import parquet.reader;

auto r = ParquetReader.open("corpus.parquet");   // mmap; or new ParquetReader(bytes)
const text = r.columnIndex("text");
foreach (g; 0 .. r.numRowGroups) {
    auto col = r.readColumn(g, text);            // one column chunk
    foreach (row; 0 .. col.length)
        if (!col.isNull(row)) process(col.text(row)); // exact stored bytes
}
r.close();
```

What it reads:

- Any number of row groups and pages; data pages v1 and v2; dictionary
  pages; index pages skipped.
- Flat schemas only: a root group of `REQUIRED`/`OPTIONAL` leaves. Nested
  groups and `REPEATED` fields are rejected.
- All eight physical types, returned in physical form (`ColumnValues`:
  one typed array plus a per-row null flag). Logical annotations
  (`STRING`, timestamps, ...) are reported on `ColumnDescriptor`, not
  applied. String bytes are returned exactly as stored, not UTF-8
  validated.
- Value encodings `PLAIN`, `PLAIN_DICTIONARY`/`RLE_DICTIONARY`, and `RLE`
  booleans; definition levels in the RLE/bit-packing hybrid. Nulls and empty
  strings stay distinct.
- Codecs `SNAPPY` (native decoder, `parquet.snappy`), `ZSTD` (vendored
  zstd), `GZIP` (the zlib inside D's Phobos runtime), and `UNCOMPRESSED`.
- Not supported, rejected with a `ParquetFormatException` that names the
  feature: `DELTA_BINARY_PACKED`, `DELTA_LENGTH_BYTE_ARRAY`,
  `DELTA_BYTE_ARRAY`, `BYTE_STREAM_SPLIT`, deprecated `BIT_PACKED` levels,
  `LZ4`/`LZ4_RAW`/`BROTLI`/`LZO`, encrypted files, and column data in
  external files. None of these appear in pyarrow's defaults or in the
  corpora verified below.

Input is treated as hostile: every offset, length, count, and dictionary
index from the file is checked explicitly (not left to D bounds checks,
which release builds drop), the Thrift decode guards the vendored protocol
against invalid type nibbles, forged sizes, and unbounded nesting, and
`ReaderOptions.maxRowGroupRows` (default 2^26) and
`ReaderOptions.maxPageBytes` (default 256 MiB, declared uncompressed page
size) refuse forged row counts and page sizes before allocating for them;
dictionary pages may not declare more entries than their chunk has values,
and `FIXED_LEN_BYTE_ARRAY` widths must be positive. Malformed input raises `ParquetFormatException`,
never a D `Error`. Decoded values never alias the input buffer.

### Why Snappy is a native decoder

Parquet uses Snappy's raw block format, whose decoder is one varint preamble
plus a four-case tag loop (literal, and three copy forms), about 100 lines
in `parquet.snappy`. Google's snappy library is C++, not C: pyarrow's own
`libarrow` exports it as C++ symbols (`snappy::RawUncompress(...)`), and
building it needs a C++ toolchain, CMake-generated headers
(`snappy-stubs-public.h`) and linking the C++ runtime into D binaries --
far more build surface than zstd's plain-C `make` here, for a decompressor
this small. The native decoder is checked against hand-derived vectors, a
randomized independent encoder in its unit tests, and -- the real proof --
every SNAPPY page of the files below, which pyarrow wrote with Google's
snappy.

## Modules

- `parquet.thrift_codec` -- the `parquet.thrift` struct subset above, encoded
  with a vendored, unmodified copy of Apache Thrift's own D
  `TCompactProtocol` (`third_party/thrift`, six files from tag `v0.24.0`).
  See [`third_party/thrift/README.md`](third_party/thrift/README.md) for the
  pin, hashes, and why it is vendored instead of depending on the
  `apache-thrift` dub package (libevent/openssl).
  It also decodes footers and page headers for the reader, through the same
  protocol over a zero-copy slice transport.
- `parquet.writer` -- file framing, PLAIN encoding, the RLE/bit-packing hybrid
  encoder, and footer offset bookkeeping.
- `parquet.reader` -- footer/schema validation, page iteration, PLAIN and
  dictionary decoding, the RLE/bit-packing hybrid decoder, null placement.
- `parquet.snappy` -- raw Snappy block decompression.
- `parquet.exception` -- `ParquetFormatException`.
- `parquet.zstd_ffi` -- one-shot compression and exact-size decompression
  over the vendored zstd v1.5.7 (`third_party/zstd`, a byte-identical copy
  of scrubbed's pinned zstd).

## Build and test

```sh
cd parquet-d
dub build --compiler=ldc2
dub test --compiler=ldc2
```

Both build the pinned zstd archives and the six-file Thrift archive
(`.dub/thrift/libthrift_compact.a`) from vendored source, with no network
access. `dub test` runs the codec's hand-derived compact-protocol byte
vectors (encode and decode, plus malformed-metadata cases), the bit-packing
known-answer vector from the Parquet encodings spec, randomized hybrid
encode/decode checks against two independent encoders, Snappy vectors and a
randomized independent Snappy encoder, zstd round trips, whole-file
structural checks in `tests/writer_checks.d`, and writer-to-reader round
trips plus mutation fuzzing in `tests/reader_checks.d`.

### External proof (writer and reader)

```sh
parquet-d/tests/external_verify.sh          # or: ... writer | ... reader
```

creates a pinned `uv` venv (`pyarrow==25.0.1`, `duckdb==1.5.6`, exact pins
re-checked with `uv pip freeze`) under `.dub/external-verify`, builds the
`external-fixture` configuration, writes zstd and uncompressed versions of
three tables (a 1037-row mixed table with every column type, null/empty/
non-empty strings and long null and empty-string runs; a zero-row table; an
all-null column), and has both pyarrow and DuckDB read every file and compare
every value, type, nullability, and footer codec against the expected rows.

The reader half then downloads four real Hugging Face Hub files, each pinned
to a repository revision and SHA-256 (not committed; they stay under
`.dub/external-verify/real`, and each dataset keeps its own license):

| File | Source | Size | Why |
| --- | --- | --- | --- |
| `rotten_tomatoes.validation.parquet` | `cornell-movie-review-data/rotten_tomatoes`, HF parquet conversion, validation split | 90 KB | the file inspected when #392 was scoped |
| `fineweb.CC-MAIN-2013-20.004_00004.parquet` | `HuggingFaceFW/fineweb`, `data/CC-MAIN-2013-20/004_00004.parquet` (datatrove output) | 593 KB | a native FineWeb shard |
| `c4-10k.train.parquet` | `NeelNanda/c4-10k`, `data/train-00000-of-00001-*.parquet` | 13.6 MB | C4 text; 10 row groups; dictionary-to-PLAIN fallback |
| `the-stack-smol-xs.agda.parquet` | `bigcode/the-stack-smol-xs`, HF parquet conversion, `agda` config | 179 KB | real nulls (34 of 100 `max_stars_count`) |

All are SNAPPY with `PLAIN`/`RLE`/`RLE_DICTIONARY`. It also has the pinned
pyarrow write edge-case files (SNAPPY/ZSTD/GZIP/uncompressed, v1 and v2
pages, 64-byte pages, dictionary fallback, RLE booleans, NaN/-0.0/extreme
values, nulls in every type, `REQUIRED` columns, an all-null column, an
empty file). For every file, `parquet-reader-dump` (the `reader-dump`
configuration) writes each row's physical values and `tests/reader_verify.py`
compares them with pyarrow's decode of the same file: byte arrays byte for
byte, floats bit for bit, nulls as nulls. A negative control confirms the
comparison notices one altered byte; files using unsupported features must
be rejected with a message naming the feature; and 1000 mutations of each
real file must each decode or raise `ParquetFormatException`, never
anything else.

Network access is needed once, for the pinned wheels and the real files.

## Pipeline wiring plan (follow-up, not implemented here)

The reader is only the format layer; scrubbed cannot yet take a Parquet
corpus as input. The intended wiring, to be its own ticket:

- **Surface.** `scrubbed run --input corpus.parquet --parquet-fields text`,
  mirroring the existing `--jsonl-fields` record mode rather than
  `clean-web-document`'s file-per-document HTML input: a Parquet row is a
  record, and each selected `STRING` column value is one document sent
  through the same compiled job as a selected JSONL field
  (`effects/jsonl_job.d`'s `runJsonlFieldOutcome`). The flag, not the file
  extension, selects the adapter (as `--jsonl-fields` does today); the
  adapter also checks the `PAR1` magic and refuses non-string columns.
  `--dataset-namespace`/`--source-key` identity extends with row group and
  row index, so manifests and the error journal can address one row.
- **Semantics.** Null cells pass through as null, never as `""`;
  unselected columns pass through unchanged; a selected value that is not
  valid UTF-8 is a per-document failure recorded in the error journal
  (the reader deliberately does not validate).
- **Bounded memory.** The adapter streams with `readColumn` one row group
  at a time and checks the row group's `total_byte_size` against
  `--max-input-bytes` before decoding it.
- **Output.** JSONL output works with the existing sinks. Parquet output
  needs the writer to gain streaming, multi-row-group output (it currently
  buffers one row group for the whole file), which is a separate
  prerequisite ticket for FineWeb-sized (2 GB) shards.
- **Build.** scrubbed and parquet-d both link a vendored zstd v1.5.7
  archive; adding parquet-d as a path dependency needs one of them to use
  the other's archive to avoid duplicate symbols.
- **Preset.** A sealed top-level preset (mojibake repair plus the
  four-class PII scan on already extracted text, without
  `clean-web-document`'s HTML stages) is the natural next step once the
  adapter exists.

## Platform support

Verified on macOS arm64 with LDC 1.43.0 only.

## Not published

This package is **not** published to code.dlang.org. That is held for a
separate go-ahead.

## License

MIT for this package's own code (see `LICENSE`), including the Snappy
decoder, written from the format description with no Snappy code vendored.
Vendored code: Apache Thrift under Apache-2.0 (`third_party/thrift/LICENSE`,
`NOTICE`) and Zstandard under its BSD-style license
(`third_party/zstd/LICENSE`); see `THIRD_PARTY_NOTICES.md`.
