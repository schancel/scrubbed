#!/usr/bin/env bash
# External proof for parquet-d, against real pyarrow (and DuckDB) from a
# pinned uv-managed venv (same `uv venv` + `uv pip install` + exact
# `uv pip freeze` pin check pattern as scrubbed's benchmarks/README.md
# "Shared external-tool comparator" and examples/pipeline-benchmark/run.sh).
#
# writer: write fixture files with this package, then read them back with
#         pyarrow and DuckDB (tests/external_verify.py).
# reader: read real Hugging Face-published Parquet files (pinned revisions,
#         SHA-256 checked) and pyarrow-written edge-case files with
#         parquet.reader, and compare every value against pyarrow's decode of
#         the same file (tests/reader_verify.py); check that unsupported
#         features are rejected cleanly; mutation-fuzz the real files.
#
# Usage (from anywhere): parquet-d/tests/external_verify.sh [writer|reader|all]
# All state lives under parquet-d/.dub/external-verify (gitignored). Network
# is needed once for the pinned wheels and the real fixture downloads.
set -euo pipefail

pkg_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$pkg_dir/.dub/external-verify"
venv="$work/venv"
out="$work/out"
pins=(pyarrow==25.0.1 duckdb==1.5.6)
mode="${1:-all}"
case "$mode" in writer|reader|all) ;; *) echo "usage: $0 [writer|reader|all]" >&2; exit 64;; esac

mkdir -p "$work"
if [[ ! -x "$venv/bin/python" ]]; then
  uv venv "$venv" >&2
fi
uv pip install --python "$venv/bin/python" "${pins[@]}" >&2

freeze="$(uv pip freeze --python "$venv/bin/python" | grep -v '^Using Python ')"
for pin in "${pins[@]}"; do
  if ! grep -qxF "$pin" <<<"$freeze"; then
    echo "external_verify.sh: pin verification FAILED: expected exact row '$pin'; got:" >&2
    echo "$freeze" >&2
    exit 1
  fi
done
py="$venv/bin/python"

if [[ "$mode" != reader ]]; then
  (cd "$pkg_dir" && dub build --compiler=ldc2 --config=external-fixture >&2)
  rm -rf "$out"
  "$pkg_dir/parquet-external-fixture" "$out"
  "$py" "$pkg_dir/tests/external_verify.py" "$out"
fi

[[ "$mode" == writer ]] && exit 0

# ---------------------------------------------------------------------------
# Reader proof
# ---------------------------------------------------------------------------

# Real files published on the Hugging Face Hub, pinned to a repository
# revision and a SHA-256 (the Hub's own LFS oid). name|url|sha256
hf=https://huggingface.co/datasets
real_fixtures=(
  # The file inspected when #392 was scoped: HF's parquet conversion of the
  # rotten_tomatoes validation split (SNAPPY, PLAIN/RLE/RLE_DICTIONARY).
  "rotten_tomatoes.validation.parquet|$hf/cornell-movie-review-data/rotten_tomatoes/resolve/a2b32381b51e711ccca777c4b295adf3212c4a2f/default/validation/0000.parquet|3ea894e394cd24413b781790683924a2598507d146da9b4ad0a2a01830c77b00"
  # A native FineWeb shard as published by datatrove (smallest file of the
  # CC-MAIN-2013-20 dump, 592 KB, 374 documents).
  "fineweb.CC-MAIN-2013-20.004_00004.parquet|$hf/HuggingFaceFW/fineweb/resolve/9bb295ddab0e05d785b879661af7260fed5140fc/data/CC-MAIN-2013-20/004_00004.parquet|f3ed5eca3e8673c7b763f7c43f000e8430ce7ad652ef90b3b0ccab9bcb5ae89a"
  # A 10k-document C4 sample as pushed to the Hub (13.6 MB, 10 row groups,
  # dictionary fallback to PLAIN inside the text column).
  "c4-10k.train.parquet|$hf/NeelNanda/c4-10k/resolve/bdb17e3672308890562fe8f5ebe5d07bc88d764a/data/train-00000-of-00001-f6f21d3dc6d657fc.parquet|ed2d10ef7028adbce5add01785c89791a18b3551622c9fc70620de2874f2b016"
  # Real nulls: 34 of 100 max_stars_count values are null.
  "the-stack-smol-xs.agda.parquet|$hf/bigcode/the-stack-smol-xs/resolve/d5a9ef8c04c07813e75d50aab80eb5d560d15b41/agda/train/0000.parquet|a045265734fbcf9bfe52effc82529df1ff4184e68e9cb3a5311c526975efc6d5"
)

real="$work/real"
synth="$work/synth"
dumps="$work/dumps"
mkdir -p "$real"
rm -rf "$synth" "$dumps"
mkdir -p "$dumps"

sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }

for entry in "${real_fixtures[@]}"; do
  IFS='|' read -r name url want <<<"$entry"
  dest="$real/$name"
  if [[ ! -f "$dest" || "$(sha256 "$dest")" != "$want" ]]; then
    echo "fetching $name" >&2
    curl -sSfL --retry 3 --max-time 600 -o "$dest.part" "$url"
    mv "$dest.part" "$dest"
  fi
  got="$(sha256 "$dest")"
  if [[ "$got" != "$want" ]]; then
    echo "external_verify.sh: $name SHA-256 mismatch: got $got, pinned $want" >&2
    exit 1
  fi
done

(cd "$pkg_dir" && dub build --compiler=ldc2 --config=reader-dump >&2)
dump_bin="$pkg_dir/parquet-reader-dump"
"$py" "$pkg_dir/tests/reader_verify.py" generate "$synth"

checked=0
for file in "$real"/*.parquet "$synth"/*.parquet; do
  jsonl="$dumps/$(basename "$file").jsonl"
  "$dump_bin" dump "$file" "$jsonl"
  "$py" "$pkg_dir/tests/reader_verify.py" compare "$file" "$jsonl"
  checked=$((checked + 1))
done

# A page over 256 MiB, as default-settings pyarrow writes for long documents.
# Generated on the fly (about 14 MB on disk thanks to compressible text),
# compared by SHA-256 rather than a text dump, and deleted afterwards.
large="$work/large"
rm -rf "$large"
mkdir -p "$large"
trap 'rm -rf "$large"' EXIT
"$py" "$pkg_dir/tests/reader_verify.py" generate-large "$large/large_page.parquet"
"$dump_bin" digest "$large/large_page.parquet" "$large/digest.txt"
"$py" "$pkg_dir/tests/reader_verify.py" compare-digest "$large/large_page.parquet" "$large/digest.txt"
set +e
msg="$("$dump_bin" digest "$large/large_page.parquet" /dev/null 268435456 2>&1)"
rc=$?
set -e
if [[ $rc -ne 2 || "$msg" != *maxPageBytes* ]]; then
  echo "external_verify.sh: large-page fixture does not contain a page over 256 MiB ($rc: $msg)" >&2
  exit 1
fi
echo "large page confirmed over 256 MiB (a 256 MiB maxPageBytes rejects it: $msg)"
rm -rf "$large"
checked=$((checked + 1))

# Negative control: the comparator must notice a single altered value.
control="$dumps/negative-control.jsonl"
"$py" - "$dumps/rotten_tomatoes.validation.parquet.jsonl" "$control" <<'EOF'
import json, sys
lines = open(sys.argv[1]).read().splitlines()
row = json.loads(lines[500])
row[0] = row[0][:-2] + ("00" if row[0][-2:] != "00" else "01")
lines[500] = json.dumps(row)
open(sys.argv[2], "w").write("\n".join(lines) + "\n")
EOF
if "$py" "$pkg_dir/tests/reader_verify.py" compare "$real/rotten_tomatoes.validation.parquet" \
    "$control" >/dev/null 2>&1; then
  echo "external_verify.sh: negative control FAILED: an altered value went unnoticed" >&2
  exit 1
fi
echo "negative control: comparator rejects a dump with one altered byte"

# Unsupported features must be rejected with exit 2 and a message naming them.
while IFS=$'\t' read -r name needle; do
  set +e
  msg="$("$dump_bin" dump "$synth/unsupported/$name" /dev/null 2>&1)"
  rc=$?
  set -e
  if [[ $rc -ne 2 || "$msg" != *"$needle"* ]]; then
    echo "external_verify.sh: $name: expected exit 2 mentioning '$needle', got $rc: $msg" >&2
    exit 1
  fi
  echo "rejected as expected: $msg"
done < <("$py" -c 'import json,sys; [print(k + "\t" + v) for k, v in sorted(json.load(open(sys.argv[1])).items())]' \
  "$synth/unsupported/expected.json")

# Mutation fuzzing of the real files: every mutation must decode or raise
# ParquetFormatException; any other exception or D Error fails the run.
for file in "$real"/*.parquet; do
  "$dump_bin" fuzz "$file" 1000 392
done

echo "reader external verification passed: $checked files match pyarrow"
