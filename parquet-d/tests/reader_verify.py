"""Reader-side external proof for parquet-d: compares parquet.reader's decode
of a Parquet file against pyarrow's own decode of the same file.

Usage:
  python reader_verify.py generate <dir>
      Writes pyarrow-produced edge-case fixtures to <dir> (codecs, v1/v2
      pages, dictionary fallback, tiny pages, nulls in every type, required
      columns, RLE booleans) and to <dir>/unsupported (features the reader
      must reject cleanly). <dir>/unsupported/expected.json maps each
      unsupported file to the message fragment the reader must print.
  python reader_verify.py compare <file.parquet> <dump.jsonl>
      Checks the D reader's dump (see tests/reader_dump.d) against pyarrow:
      row count, per-row-group row counts, column names and physical types,
      and every value of every row. Byte arrays are compared as exact bytes
      (hex), FLOAT/DOUBLE as exact IEEE bit patterns, integers by value in
      their physical width, and nulls as nulls -- so a null and an empty
      string are distinct. Prints per-column null / empty counts and a
      SHA-256 over each column's canonical values. Exits non-zero on the
      first mismatch.
"""

import hashlib
import json
import os
import random
import sys

import pyarrow as pa
import pyarrow.parquet as pq


def fail(msg):
    print("FAIL: " + msg, file=sys.stderr)
    sys.exit(1)


# --------------------------------------------------------------------------
# pyarrow value -> the dump's physical representation
# --------------------------------------------------------------------------

def signed(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


def canonical(arr, physical, where):
    t = arr.type
    if pa.types.is_dictionary(t):
        arr = arr.dictionary_decode()
        t = arr.type
    if physical in ("BYTE_ARRAY", "FIXED_LEN_BYTE_ARRAY"):
        if pa.types.is_string(t):
            arr = arr.cast(pa.binary())
        elif pa.types.is_large_string(t):
            arr = arr.cast(pa.large_binary())
        elif not (pa.types.is_binary(t) or pa.types.is_large_binary(t)
                  or pa.types.is_fixed_size_binary(t)):
            fail(f"{where}: comparator does not handle arrow type {t} for {physical}")
        return [None if v is None else v.hex() for v in arr.to_pylist()]
    if physical == "BOOLEAN":
        if not pa.types.is_boolean(t):
            fail(f"{where}: arrow type {t} for BOOLEAN")
        return arr.to_pylist()
    if physical in ("INT32", "INT64"):
        bits = 32 if physical == "INT32" else 64
        if pa.types.is_integer(t):
            return [None if v is None else signed(v, bits) for v in arr.to_pylist()]
        if (pa.types.is_temporal(t) and t.bit_width == bits):
            view = arr.view(pa.int32() if bits == 32 else pa.int64())
            return view.to_pylist()
        fail(f"{where}: comparator does not handle arrow type {t} for {physical}")
    if physical == "FLOAT":
        if not pa.types.is_float32(t):
            fail(f"{where}: arrow type {t} for FLOAT")
        # Bit-exact (NaN payloads, -0.0) via a same-width integer view.
        return [None if v is None else v.to_bytes(4, "little").hex()
                for v in arr.view(pa.uint32()).to_pylist()]
    if physical == "DOUBLE":
        if not pa.types.is_float64(t):
            fail(f"{where}: arrow type {t} for DOUBLE")
        return [None if v is None else v.to_bytes(8, "little").hex()
                for v in arr.view(pa.uint64()).to_pylist()]
    fail(f"{where}: comparator does not handle physical type {physical}")


def compare(path, dump_path):
    name = os.path.basename(path)
    pf = pq.ParquetFile(path)
    md = pf.metadata
    schema = pf.schema

    with open(dump_path, encoding="utf-8") as f:
        header = json.loads(f.readline())
        d_rows = [json.loads(line) for line in f]

    if header["num_rows"] != md.num_rows or len(d_rows) != md.num_rows:
        fail(f"{name}: rows: D header {header['num_rows']}, D lines {len(d_rows)}, "
             f"pyarrow {md.num_rows}")
    want_groups = [md.row_group(i).num_rows for i in range(md.num_row_groups)]
    if header["row_groups"] != want_groups:
        fail(f"{name}: row groups D {header['row_groups']} pyarrow {want_groups}")
    if len(header["columns"]) != len(schema):
        fail(f"{name}: {len(header['columns'])} columns, pyarrow {len(schema)}")

    table = pf.read()
    codecs = sorted({md.row_group(g).column(c).compression
                     for g in range(md.num_row_groups) for c in range(len(schema))})
    encodings = sorted({e for g in range(md.num_row_groups) for c in range(len(schema))
                        for e in md.row_group(g).column(c).encodings})
    print(f"{name}: created_by {md.created_by!r}; codecs {codecs}; encodings {encodings}; "
          f"{md.num_rows} rows in {md.num_row_groups} row group(s)")

    for ci, dcol in enumerate(header["columns"]):
        pcol = schema.column(ci)
        where = f"{name} column {pcol.name!r}"
        if dcol["name"] != pcol.name or dcol["physical"] != pcol.physical_type:
            fail(f"{where}: D says {dcol['name']}/{dcol['physical']}, "
                 f"pyarrow {pcol.name}/{pcol.physical_type}")
        want_nullable = pcol.max_definition_level > 0
        if dcol["nullable"] != want_nullable:
            fail(f"{where}: nullable D {dcol['nullable']} pyarrow {want_nullable}")
        arr = table.column(pcol.name).combine_chunks()
        want = canonical(arr, pcol.physical_type, where)
        got = [row[ci] for row in d_rows]
        if got != want:
            for i, (g, w) in enumerate(zip(got, want)):
                if g != w:
                    fail(f"{where}: row {i}: D {str(g)[:120]} != pyarrow {str(w)[:120]}")
            fail(f"{where}: length mismatch")
        nulls = sum(1 for v in got if v is None)
        if nulls != arr.null_count:
            fail(f"{where}: D nulls {nulls} != pyarrow null_count {arr.null_count}")
        digest = hashlib.sha256(json.dumps(got).encode()).hexdigest()[:16]
        extra = ""
        if pcol.physical_type == "BYTE_ARRAY":
            extra = f", empty={sum(1 for v in got if v == '')}"
        print(f"  {pcol.name}: {pcol.physical_type} OK -- {len(got)} values, "
              f"nulls={nulls} (pyarrow null_count={arr.null_count}){extra}, sha256[:16]={digest}")
    print(f"{name}: MATCH (every value of every row equals pyarrow's decode)")


# --------------------------------------------------------------------------
# Edge-case fixtures written by the pinned pyarrow
# --------------------------------------------------------------------------

def edge_table(n, seed):
    rng = random.Random(seed)
    words = ["parquet", "snappy", "dictionary", "été", "中文", "\U0001f600",
             "mojibake Ã©", "a" * 300]

    def maybe(v, p=0.15):
        return None if rng.random() < p else v

    def text(i):
        if 400 <= i < 700:
            return None  # long null run spanning pages
        r = rng.random()
        if r < 0.1:
            return ""
        if r < 0.2:
            return None
        k = rng.randrange(1, 40)
        return " ".join(rng.choice(words) for _ in range(k))

    f32_special = [float("nan"), float("inf"), float("-inf"), -0.0, 1e-45, 3.4e38]
    f64_special = [float("nan"), float("inf"), float("-inf"), -0.0, 5e-324, 1.7e308]
    cols = {
        "text": pa.array([text(i) for i in range(n)], pa.string()),
        "blob": pa.array([maybe(bytes(rng.randrange(256) for _ in range(rng.randrange(0, 20))))
                          for _ in range(n)], pa.binary()),
        "i32": pa.array([maybe(rng.choice([-2**31, 2**31 - 1, 0, rng.randrange(-1000, 1000)]))
                         for _ in range(n)], pa.int32()),
        "i64": pa.array([maybe(rng.choice([-2**63, 2**63 - 1, rng.randrange(-2**40, 2**40)]))
                         for _ in range(n)], pa.int64()),
        "f32": pa.array([maybe(rng.choice(f32_special + [rng.uniform(-1e6, 1e6)]))
                         for _ in range(n)], pa.float32()),
        "f64": pa.array([maybe(rng.choice(f64_special + [rng.uniform(-1e6, 1e6)]))
                         for _ in range(n)], pa.float64()),
        "flag": pa.array([maybe(rng.random() < 0.5) for _ in range(n)], pa.bool_()),
        "fixed": pa.array([maybe(bytes(rng.randrange(256) for _ in range(16)))
                           for _ in range(n)], pa.binary(16)),
        "category": pa.array([maybe(rng.choice(["en", "fr", "de", "zh"]), 0.3)
                              for _ in range(n)], pa.string()),
        "ts": pa.array([maybe(rng.randrange(0, 2**50)) for _ in range(n)], pa.timestamp("us")),
        "u32": pa.array([maybe(rng.choice([0, 2**32 - 1, 2**31, rng.randrange(2**32)]))
                         for _ in range(n)], pa.uint32()),
        "i8": pa.array([maybe(rng.randrange(-128, 128)) for _ in range(n)], pa.int8()),
        "all_null": pa.array([None] * n, pa.string()),
        "req_id": pa.array(list(range(n)), pa.int64()),
        "req_text": pa.array([f"doc-{i}" for i in range(n)], pa.string()),
    }
    fields = [pa.field(k, v.type, nullable=not k.startswith("req_")) for k, v in cols.items()]
    return pa.table(list(cols.values()), schema=pa.schema(fields))


def generate(out):
    os.makedirs(out, exist_ok=True)
    unsupported = os.path.join(out, "unsupported")
    os.makedirs(unsupported, exist_ok=True)
    t = edge_table(5000, 392)
    small = dict(row_group_size=1500, data_page_size=4096)
    variants = {
        "edge.snappy.v1": dict(compression="snappy", data_page_version="1.0", **small),
        "edge.snappy.v2": dict(compression="snappy", data_page_version="2.0", **small),
        "edge.zstd.v1": dict(compression="zstd", data_page_version="1.0", **small),
        "edge.gzip.v2": dict(compression="gzip", data_page_version="2.0", **small),
        "edge.none.v1": dict(compression="none", data_page_version="1.0", **small),
        "edge.snappy.plain": dict(compression="snappy", use_dictionary=False, **small),
        # Tiny dictionary limit: writers fall back from RLE_DICTIONARY to
        # PLAIN mid-chunk, so one chunk mixes both encodings.
        "edge.snappy.dict_fallback": dict(compression="snappy", dictionary_pagesize_limit=256,
                                          **small),
        # Tiny pages: many pages per chunk, runs split across page edges.
        "edge.snappy.tiny_pages": dict(compression="snappy", data_page_size=64,
                                       write_batch_size=7, row_group_size=5000),
        "edge.snappy.rle_bool": dict(compression="snappy", use_dictionary=False,
                                     column_encoding={"flag": "RLE"}, data_page_version="2.0",
                                     **small),
    }
    for name, kw in variants.items():
        pq.write_table(t, os.path.join(out, name + ".parquet"), **kw)
    pq.write_table(t.slice(0, 0), os.path.join(out, "edge.empty.parquet"), compression="snappy")

    expected = {}

    def reject(name, table, needle, **kw):
        pq.write_table(table, os.path.join(unsupported, name + ".parquet"), **kw)
        expected[name + ".parquet"] = needle

    reject("delta_binary_packed", t.select(["i64"]), "DELTA_BINARY_PACKED",
           use_dictionary=False, column_encoding={"i64": "DELTA_BINARY_PACKED"})
    reject("byte_stream_split", t.select(["f64"]), "BYTE_STREAM_SPLIT",
           use_dictionary=False, column_encoding={"f64": "BYTE_STREAM_SPLIT"})
    reject("lz4", t.select(["text"]), "LZ4", compression="lz4")
    reject("brotli", t.select(["text"]), "BROTLI", compression="brotli")
    reject("nested_list", pa.table({"xs": pa.array([[1, 2], None, []], pa.list_(pa.int64()))}),
           "nested schemas are not supported")
    with open(os.path.join(unsupported, "expected.json"), "w") as f:
        json.dump(expected, f, indent=1, sort_keys=True)
    print(f"generated {len(variants) + 1} edge fixtures and {len(expected)} unsupported "
          f"fixtures with pyarrow {pa.__version__}")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "generate":
        generate(sys.argv[2])
    elif len(sys.argv) == 4 and sys.argv[1] == "compare":
        compare(sys.argv[2], sys.argv[3])
    else:
        print(__doc__, file=sys.stderr)
        sys.exit(64)
