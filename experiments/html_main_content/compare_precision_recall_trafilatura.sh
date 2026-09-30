#!/usr/bin/env bash
# Issue #479's real, pinned trafilatura==2.2.0 `--precision`/`--recall`
# comparison (acceptance criterion 1). A separate, non-gating,
# network-and-pip-using acquisition tier -- mirroring
# `compare_comments_trafilatura.sh`'s own already-established "outside the
# normal dub build/dub test path entirely" convention exactly (restated
# here, not shared, per this directory's existing layering idiom) and
# `benchmarks/external_comparator.d`'s own pinned-package acquisition
# pattern (`uv venv` + `uv pip install --python <venv>/bin/python
# <pkg>==<exact version>`, verified via `uv pip freeze` at run time; nothing
# vendored).
#
# What it does:
#   1. Builds `precision_recall_check.d` (this directory's own real-corpus
#      regression driver for issue #479) and runs it with `--json` to get
#      scrubbed's own per-page, per-mode extracted-text length over a fixed
#      set of real, already-checked-into-this-repo corpus pages
#      (`examples/pipeline-benchmark/corpus/`), chosen because real pinned
#      trafilatura==2.2.0 itself shows a genuine precision/recall
#      disagreement on them (see `compare_precision_recall_trafilatura.py`'s
#      own module doc comment for the exact real numbers).
#   2. Creates a throwaway `uv venv`, installs pinned `trafilatura==2.2.0`
#      into it, and verifies the exact pin via `uv pip freeze`.
#   3. Runs `compare_precision_recall_trafilatura.py` with that venv's
#      Python: it extracts real trafilatura's own `favor_precision`/
#      `favor_recall` output lengths over the identical files and compares
#      against scrubbed's own per-mode lengths from step 1, confirming a
#      real precision/recall disagreement exists in trafilatura's own
#      output on at least one of the compared pages.
#   4. Deletes the whole throwaway venv (and its cached wheels) on exit,
#      succeeding or not; nothing from this script is ever vendored into
#      this repository's git history or shipped in the release
#      binary/package (identical policy to #229's 2026-09-26 "public package
#      acquisition boundary" decision, `fetch_held_out.sh`'s/
#      `compare_comments_trafilatura.sh`'s own already-established
#      precedent for this repository).
#
# Not required to pass, or even to run, for a change to land -- like
# `fetch_held_out.sh`/`compare_comments_trafilatura.sh`, this sits outside
# `dub build`/`dub test` entirely. `dub test`'s own real gate for this
# ticket is `html_main_content.d`'s own `unittest` blocks plus
# `precision_recall_check.d`'s real-fixture regression (see that file's own
# doc comment).
#
# Usage: experiments/html_main_content/compare_precision_recall_trafilatura.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
corpus_dir="$root/examples/pipeline-benchmark/corpus"

scratch="$(mktemp -d -t scrubbed-precision-recall-trafilatura-compare.XXXXXX)"
cleanup() { rm -rf "$scratch"; }
trap cleanup EXIT

echo "== building precision_recall_check.d =="
ldc2 -O3 -release -I"$root/source" -of="$scratch/precision-recall-check" \
    "$root/experiments/html_main_content/precision_recall_check.d" \
    "$root/source/effects/html_main_content.d" \
    "$root/source/effects/html_tree.d" \
    "$root/source/effects/lexbor_ffi.d" \
    "$root/source/text/decoding.d" \
    "$root/.dub/lexbor/liblexbor_static.a"

echo "== scrubbed's own real-corpus precision/recall extraction lengths =="
"$scratch/precision-recall-check" --root "$corpus_dir" --json | tee "$scratch/scrubbed.jsonl"

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
"$scratch/venv/bin/python" "$root/experiments/html_main_content/compare_precision_recall_trafilatura.py" \
    "$corpus_dir" "$scratch/scrubbed.jsonl"
