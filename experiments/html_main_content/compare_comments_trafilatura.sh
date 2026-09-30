#!/usr/bin/env bash
# Issue #475's real, pinned trafilatura==2.2.0 comment/non-comment split
# comparison (acceptance criterion 1). A separate, non-gating,
# network-and-pip-using acquisition tier -- mirroring
# `fetch_held_out.sh`'s own "outside the normal dub build/dub test path
# entirely" convention exactly (restated here, not shared, per this
# directory's existing layering idiom) and `benchmarks/external_comparator.d`'s
# own pinned-package acquisition pattern (`uv venv` + `uv pip install
# --python <venv>/bin/python <pkg>==<exact version>`, verified via
# `uv pip freeze` at run time; nothing vendored).
#
# What it does:
#   1. Builds `comments_check.d` (this directory's own real-corpus regression
#      driver for issue #475) and runs it with `--json` to get scrubbed's own
#      per-page comment/non-comment split over a fixed set of real,
#      already-checked-into-this-repo corpus pages
#      (`examples/pipeline-benchmark/corpus/`).
#   2. Creates a throwaway `uv venv`, installs pinned `trafilatura==2.2.0`
#      into it, and verifies the exact pin via `uv pip freeze`.
#   3. Runs `compare_comments_trafilatura.py` with that venv's Python: it
#      extracts real trafilatura's own comment/non-comment split
#      (`trafilatura.extract(..., include_comments=True)`'s `"comments"`
#      JSON field) over the identical files and compares against scrubbed's
#      own split from step 1.
#   4. Deletes the whole throwaway venv (and its cached wheels) on exit,
#      succeeding or not; nothing from this script is ever vendored into
#      this repository's git history or shipped in the release
#      binary/package (identical policy to #229's 2026-09-26 "public package
#      acquisition boundary" decision, `fetch_held_out.sh`'s own already-
#      established precedent for this repository).
#
# Not required to pass, or even to run, for a change to land -- like
# `fetch_held_out.sh`, this sits outside `dub build`/`dub test` entirely.
# `dub test`'s own real gate for this ticket is `html_main_content.d`'s own
# `unittest` blocks plus `comments_check.d`'s real-fixture regression (see
# that file's own doc comment).
#
# Usage: experiments/html_main_content/compare_comments_trafilatura.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
corpus_dir="$root/examples/pipeline-benchmark/corpus"

scratch="$(mktemp -d -t scrubbed-comments-trafilatura-compare.XXXXXX)"
cleanup() { rm -rf "$scratch"; }
trap cleanup EXIT

echo "== building comments_check.d =="
ldc2 -O3 -release -I"$root/source" -of="$scratch/comments-check" \
    "$root/experiments/html_main_content/comments_check.d" \
    "$root/source/effects/html_main_content.d" \
    "$root/source/effects/html_tree.d" \
    "$root/source/effects/lexbor_ffi.d" \
    "$root/source/text/decoding.d" \
    "$root/.dub/lexbor/liblexbor_static.a"

echo "== scrubbed's own real-corpus comment/non-comment split =="
"$scratch/comments-check" --root "$corpus_dir" --json | tee "$scratch/scrubbed.jsonl"

echo "== acquiring pinned trafilatura==2.2.0 into a throwaway venv =="
uv venv "$scratch/venv"
uv pip install --python "$scratch/venv/bin/python" trafilatura==2.2.0

pinned="$(uv pip freeze --python "$scratch/venv/bin/python" | grep -x 'trafilatura==2.2.0' || true)"
if [[ "$pinned" != "trafilatura==2.2.0" ]]; then
    echo "pinned-version verification failed: expected exactly trafilatura==2.2.0" >&2
    uv pip freeze --python "$scratch/venv/bin/python" >&2
    exit 1
fi
echo "verified: $pinned"

echo "== comparing against real pinned trafilatura==2.2.0 =="
"$scratch/venv/bin/python" "$root/experiments/html_main_content/compare_comments_trafilatura.py" \
    "$corpus_dir" "$scratch/scrubbed.jsonl"
