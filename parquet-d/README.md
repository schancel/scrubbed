# parquet-d

A native D Parquet writer for flat tables. `parquet.writer.ParquetWriter`
buffers rows in memory and serializes one complete Parquet file with a single
row group. It has zero dependency on scrubbed's own `dub.json` or `source/`
tree and builds and tests entirely on its own.

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

## Modules

- `parquet.thrift_codec` -- the `parquet.thrift` struct subset above, encoded
  with a vendored, unmodified copy of Apache Thrift's own D
  `TCompactProtocol` (`third_party/thrift`, six files from tag `v0.24.0`).
  See [`third_party/thrift/README.md`](third_party/thrift/README.md) for the
  pin, hashes, and why it is vendored instead of depending on the
  `apache-thrift` dub package (libevent/openssl).
- `parquet.writer` -- file framing, PLAIN encoding, the RLE/bit-packing hybrid
  encoder, and footer offset bookkeeping.
- `parquet.zstd_ffi` -- one-shot compression over the vendored zstd v1.5.7
  (`third_party/zstd`, a byte-identical copy of scrubbed's pinned zstd).

## Build and test

```sh
cd parquet-d
dub build --compiler=ldc2
dub test --compiler=ldc2
```

Both build the pinned zstd archives and the six-file Thrift archive
(`.dub/thrift/libthrift_compact.a`) from vendored source, with no network
access. `dub test` runs the codec's hand-derived compact-protocol byte
vectors, the bit-packing known-answer vector from the Parquet encodings spec,
a randomized hybrid encode/decode check, a zstd round trip, and whole-file
structural checks in `tests/writer_checks.d`.

### External-reader proof

```sh
parquet-d/tests/external_verify.sh
```

creates a pinned `uv` venv (`pyarrow==25.0.1`, `duckdb==1.5.6`, exact pins
re-checked with `uv pip freeze`) under `.dub/external-verify`, builds the
`external-fixture` configuration, writes zstd and uncompressed versions of
three tables (a 1037-row mixed table with every column type, null/empty/
non-empty strings and long null and empty-string runs; a zero-row table; an
all-null column), and has both pyarrow and DuckDB read every file and compare
every value, type, nullability, and footer codec against the expected rows.
This step needs network access once, for the pinned wheels.

## Platform support

Verified on macOS arm64 with LDC 1.43.0 only.

## Not published

This package is **not** published to code.dlang.org. That is held for a
separate go-ahead.

## License

MIT for this package's own code (see `LICENSE`). Vendored code: Apache
Thrift under Apache-2.0 (`third_party/thrift/LICENSE`, `NOTICE`) and
Zstandard under its BSD-style license (`third_party/zstd/LICENSE`); see
`THIRD_PARTY_NOTICES.md`.
