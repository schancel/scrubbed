#!/usr/bin/env bash
# External-reader proof for parquet-d: write fixture files with this package,
# then read them back with real pyarrow and DuckDB from a pinned uv-managed
# venv (same `uv venv` + `uv pip install` + exact `uv pip freeze` pin check
# pattern as scrubbed's benchmarks/README.md "Shared external-tool
# comparator" and examples/pipeline-benchmark/run.sh).
#
# Usage (from anywhere): parquet-d/tests/external_verify.sh
# All state lives under parquet-d/.dub/external-verify (gitignored).
set -euo pipefail

pkg_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$pkg_dir/.dub/external-verify"
venv="$work/venv"
out="$work/out"
pins=(pyarrow==25.0.1 duckdb==1.5.6)

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

(cd "$pkg_dir" && dub build --compiler=ldc2 --config=external-fixture >&2)
rm -rf "$out"
"$pkg_dir/parquet-external-fixture" "$out"
"$venv/bin/python" "$pkg_dir/tests/external_verify.py" "$out"
