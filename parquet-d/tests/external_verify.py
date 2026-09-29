"""Reads parquet-d's fixture files with real pyarrow and DuckDB and checks
every row against the fixture's expected JSONL.

Usage: python external_verify.py <fixture-output-dir>

Checks, per table and per codec (zstd, uncompressed):
  * pyarrow: the file's schema types/nullability, the per-column codec in
    the footer, and every row value (None vs "" compared exactly).
  * DuckDB: every row value via read_parquet, explicit null/empty-string
    counts via SQL, and the per-column codec via parquet_metadata().
Exits non-zero on the first mismatch.
"""

import json
import math
import os
import sys

import duckdb
import pyarrow as pa
import pyarrow.parquet as pq

EXPECTED_TYPES = {
    "id": (pa.int64(), False),
    "text": (pa.string(), True),
    "label": (pa.string(), False),
    "small": (pa.int32(), True),
    "score": (pa.float64(), True),
    "flag": (pa.bool_(), True),
    "n": (pa.int64(), False),
}
CODEC_NAMES = {"zstd": "ZSTD", "uncompressed": "UNCOMPRESSED"}


def fail(msg):
    print("FAIL: " + msg, file=sys.stderr)
    sys.exit(1)


def same(a, b):
    # Type-exact comparison so that None != "" and True != 1.
    if type(a) is not type(b):
        return False
    if isinstance(a, float):
        return a == b or (math.isnan(a) and math.isnan(b))
    return a == b


def check_rows(where, got, expected, columns):
    if len(got) != len(expected):
        fail(f"{where}: {len(got)} rows, expected {len(expected)}")
    for i, (g, e) in enumerate(zip(got, expected)):
        for c in columns:
            if not same(g[c], e[c]):
                fail(f"{where}: row {i} column {c}: got {g[c]!r}, expected {e[c]!r}")


def main():
    out = sys.argv[1]
    print(f"pyarrow {pa.__version__}, duckdb {duckdb.__version__}")
    checked = 0
    for table in ("mixed", "empty", "all_null"):
        with open(os.path.join(out, f"{table}.expected.jsonl"), encoding="utf-8") as f:
            expected = [json.loads(line) for line in f if line.strip()]
        for codec in ("zstd", "uncompressed"):
            path = os.path.join(out, f"{table}.{codec}.parquet")
            where = f"{table}.{codec}"

            # ---- pyarrow ----
            pf = pq.ParquetFile(path)
            schema = pf.schema_arrow
            columns = schema.names
            for field in schema:
                want_type, want_nullable = EXPECTED_TYPES[field.name]
                if field.type != want_type or field.nullable != want_nullable:
                    fail(f"{where}: pyarrow field {field} expected {want_type} nullable={want_nullable}")
            md = pf.metadata
            if md.num_row_groups != 1 or md.num_rows != len(expected):
                fail(f"{where}: row groups {md.num_row_groups}, rows {md.num_rows}")
            rg = md.row_group(0)
            for ci in range(rg.num_columns):
                col = rg.column(ci)
                if col.compression != CODEC_NAMES[codec]:
                    fail(f"{where}: column {col.path_in_schema} codec {col.compression}")
            arrow_rows = pf.read().to_pylist()
            check_rows(f"{where} [pyarrow]", arrow_rows, expected, columns)

            # ---- DuckDB ----
            con = duckdb.connect()
            rel = con.execute("SELECT * FROM read_parquet(?)", [path])
            names = [d[0] for d in rel.description]
            duck_rows = [dict(zip(names, r)) for r in rel.fetchall()]
            check_rows(f"{where} [duckdb]", duck_rows, expected, columns)
            if "text" in columns:
                nulls, empties = con.execute(
                    "SELECT count(*) FILTER (WHERE text IS NULL), "
                    "count(*) FILTER (WHERE text = '') FROM read_parquet(?)",
                    [path],
                ).fetchone()
                want_nulls = sum(1 for r in expected if r["text"] is None)
                want_empties = sum(1 for r in expected if r["text"] == "")
                if (nulls, empties) != (want_nulls, want_empties):
                    fail(f"{where}: duckdb null/empty counts {(nulls, empties)} "
                         f"expected {(want_nulls, want_empties)}")
                print(f"{where}: text nulls={nulls} empty-strings={empties} (duckdb SQL)")
            codecs = {
                r[0]
                for r in con.execute(
                    "SELECT compression FROM parquet_metadata(?)", [path]
                ).fetchall()
            }
            if codecs != {CODEC_NAMES[codec]}:
                fail(f"{where}: duckdb parquet_metadata compression {codecs}")
            con.close()
            print(f"{where}: OK ({len(expected)} rows, {len(columns)} columns, "
                  f"codec {CODEC_NAMES[codec]}, pyarrow + duckdb)")
            checked += 1
    print(f"external verification passed: {checked} files")


if __name__ == "__main__":
    main()
