#!/usr/bin/env bash
# Thin build+run wrapper for experiments/corpus_crawl/crawl.d (issue #305).
# Matches the precedent style of experiments/html_main_content/fetch_held_out.sh
# and experiments/jetstream/run.sh for "real but not shipped" tooling: this
# script is outside the normal `dub build`/`dub test`/release-active-checker
# path entirely, and nothing in that path depends on it or on anything it
# produces.
#
# This tool makes REAL network requests to the owner-approved seed sites
# listed in experiments/corpus_crawl/seeds.txt (see that file and
# experiments/corpus_crawl/README.md for the acquisition policy this
# matches). Running it against the real seed list is expected and
# intentional; it is not accidental network access.
#
# Usage:
#   experiments/corpus_crawl/run.sh CORPUS_DIR [--min-host-delay-ms N] [--seeds FILE]
#
# CORPUS_DIR is required and is never defaulted into a path under this
# repository: the corpus this tool produces is real third-party page bytes
# that must never be vendored into git history or shipped in the release
# binary/package (same posture already recorded on issue #229's 2026-09-26
# "public package acquisition boundary" decision -- see README.md). Pick a
# directory outside this working tree (e.g. under $TMPDIR or your home
# directory); this script does not create or touch a .gitignore entry, so it
# never assumes any particular path is safe to leave inside the repository.
#
# Requirements: ldc2, curl-dev headers/library (libcurl), and this
# repository's already-built native Lexbor static library (run
# `dub build --build=release` from the repository root first if you have not
# already).

set -euo pipefail

here="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(CDPATH= cd -- "$here/../.." && pwd)"

if [[ $# -lt 1 || "$1" == -* ]]; then
  echo "usage: $0 CORPUS_DIR [--min-host-delay-ms N] [--seeds FILE]" >&2
  exit 2
fi
corpus_dir="$1"
shift

seeds_file="$here/seeds.txt"
extra_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --seeds)
      if [[ $# -lt 2 ]]; then
        echo "run.sh: --seeds requires a FILE argument" >&2
        exit 2
      fi
      seeds_file="$2"
      shift 2
      ;;
    *)
      extra_args+=("$1")
      shift
      ;;
  esac
done

lexbor_lib="$repo_root/.dub/lexbor/liblexbor_static.a"
if [[ ! -f "$lexbor_lib" ]]; then
  echo "run.sh: $lexbor_lib not found." >&2
  echo "Run 'dub build --build=release' from the repository root first." >&2
  exit 2
fi
for tool in ldc2; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "run.sh: required tool '$tool' not found on PATH." >&2
    exit 2
  fi
done

scratch="$(mktemp -d -t scrubbed-corpus-crawl.XXXXXX)"
cleanup() { rm -rf "$scratch"; }
trap cleanup EXIT

binary="$scratch/corpus-crawl"
echo "run.sh: compiling experiments/corpus_crawl/crawl.d (ldc2 -O -release)..." >&2
ldc2 -O -release -preview=dip1000 -I"$repo_root/source" -of="$binary" \
  "$here/crawl.d" \
  "$repo_root/source/domain/job_queue.d" \
  "$repo_root/source/domain/frontier_contract.d" \
  "$repo_root/source/domain/url_frontier.d" \
  "$repo_root/source/effects/html_discovery.d" \
  "$repo_root/source/effects/html_tree.d" \
  "$repo_root/source/effects/lexbor_ffi.d" \
  "$repo_root/source/text/decoding.d" \
  "$repo_root/source/effects/web_url.d" \
  "$repo_root/source/effects/http_fetch.d" \
  "$repo_root/source/effects/curl_ffi.d" \
  "$repo_root/source/crypto/sha256.d" \
  "$repo_root/source/crypto/sha256_arm64.d" \
  "$repo_root/source/crypto/sha256_x86_64.d" \
  "$lexbor_lib" -L-lcurl >&2

echo "run.sh: running against $seeds_file -> $corpus_dir ..." >&2
# Not `exec`: the trap above must still fire to remove the scratch directory
# (including the compiled binary) once this process exits.
"$binary" --seeds "$seeds_file" --corpus-dir "$corpus_dir" \
  ${extra_args[@]+"${extra_args[@]}"}
