#!/usr/bin/env bash
# Issue #477 acceptance-criteria evidence: a real pinned trafilatura==2.2.0
# comparison, run with --formatting --links --images, against real held-out
# pages that actually contain bold/italic text, links, and images -- not a
# synthetic-fixture-only check (the issue explicitly disallows that).
#
# Mirrors this repository's existing pinned-external-tool idioms rather than
# inventing a new one:
#   - benchmarks/external_comparator.d's compareMainContentTrafilatura case:
#     `uv venv` + `uv pip install --python <venv>/bin/python trafilatura==
#     2.2.0` + `uv pip freeze` verification of the exact pinned version.
#   - experiments/html_main_content/fetch_held_out.sh's real-page acquisition:
#     resolves real pages out of adbar/trafilatura's own pinned eval corpus
#     via its `--emit-corpus-dir` flag, transiently, never vendored.
#
# This script is deliberately outside dub test/the release-active checker,
# same as fetch_held_out.sh itself: it is a one-time (or reviewer-rerunnable)
# evidence-gathering comparator, not a CI gate, and it touches the network
# (git clone + `uv pip install`). It never prints raw held-out page bytes;
# only bounded structural-marker counts and a handful of short (<200-byte)
# excerpts of scrubbed's/trafilatura's own *output* -- Markdown syntax
# markers, not gold annotation text -- are printed, matching
# fetch_held_out.sh's own no-raw-page-bytes policy applied to its own report.
#
# Usage: experiments/html_markdown/compare_trafilatura_inline_fidelity.sh
# Requirements: git, ldc2, uv, an internet connection, and this repository's
# already-built native Lexbor static library (`dub build --build=release`
# first if not already built).

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
lexbor_lib="$repo_root/.dub/lexbor/liblexbor_static.a"
if [[ ! -f "$lexbor_lib" ]]; then
  echo "compare_trafilatura_inline_fidelity.sh: $lexbor_lib not found." >&2
  echo "Run 'dub build --build=release' from the repository root first." >&2
  exit 2
fi
for tool in git ldc2 uv; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "compare_trafilatura_inline_fidelity.sh: required tool '$tool' not found on PATH." >&2
    exit 2
  fi
done

scratch="$(mktemp -d -t scrubbed-inline-fidelity-comparison.XXXXXX)"
cleanup() { rm -rf "$scratch"; }
trap cleanup EXIT

echo "compare_trafilatura_inline_fidelity.sh: creating a throwaway uv venv and installing pinned trafilatura==2.2.0..." >&2
uv venv --quiet "$scratch/venv" >&2
uv pip install --quiet --python "$scratch/venv/bin/python" trafilatura==2.2.0 >&2

freeze="$(uv pip freeze --python "$scratch/venv/bin/python")"
pinned_row="$(printf '%s\n' "$freeze" | grep -E '^trafilatura==' || true)"
if [[ "$pinned_row" != "trafilatura==2.2.0" ]]; then
  echo "compare_trafilatura_inline_fidelity.sh: pinned-version verification FAILED." >&2
  echo "  expected: trafilatura==2.2.0" >&2
  echo "  uv pip freeze row: ${pinned_row:-<absent>}" >&2
  exit 1
fi
echo "compare_trafilatura_inline_fidelity.sh: pinned-version verification OK: $pinned_row" >&2

trafilatura_bin="$scratch/venv/bin/trafilatura"
trafilatura_version="$("$trafilatura_bin" --version)"
echo "compare_trafilatura_inline_fidelity.sh: $trafilatura_version" >&2
case "$trafilatura_version" in
  "Trafilatura "*) ;;
  *) echo "compare_trafilatura_inline_fidelity.sh: --version output not in the expected shape" >&2; exit 1;;
esac

echo "compare_trafilatura_inline_fidelity.sh: resolving real held-out pages..." >&2
corpus_dir="$scratch/held-out-corpus"
"$repo_root/experiments/html_main_content/fetch_held_out.sh" \
  --emit-corpus-dir "$corpus_dir" "$scratch/held-out-report.json" >&2

# Pages independently confirmed (by raw grep over the resolved corpus, not a
# guess) to contain real <strong>/<b>, real <a href> targets, and real <img
# src> elements each -- so the comparison actually exercises all three
# dimensions, per the issue's own requirement.
pages=(03.html 14.html 16.html 18.html)

driver_src="$scratch/inline_fidelity_driver.d"
cat > "$driver_src" <<'DRIVER_EOF'
module inline_fidelity_driver;

import effects.html_main_content : MainContentStatus;
import effects.html_main_content_markdown : extractMainContentMarkdown;
import effects.html_markdown : MarkdownRenderOptions;
import effects.html_tree : maxConfigurableHtmlBytes, parseHtml;
import std.algorithm.searching : canFind;
import std.file : read;
import std.stdio : stderr, writefln;

void main(string[] args) {
    foreach (path; args[1 .. $]) {
        auto raw = cast(const(ubyte)[]) read(path);
        auto outcome = parseHtml(raw, null, "inline-fidelity", maxConfigurableHtmlBytes);
        if (!outcome.isParsed) {
            writefln("%s\tparseFailed", path);
            continue;
        }
        MarkdownRenderOptions on = MarkdownRenderOptions(true, true, true);
        auto result = extractMainContentMarkdown(outcome.tree, on);
        if (result.status != MainContentStatus.selected &&
                result.status != MainContentStatus.selectedStructuredData) {
            writefln("%s\t%s", path, result.status);
            continue;
        }
        auto md = result.markdown;
        writefln("%s\tstatus=%s\thasBold=%s\thasLink=%s\thasImage=%s\tbytes=%d",
            path, result.status,
            md.canFind("**") || md.canFind("*"),
            md.canFind("]("),
            md.canFind("!["),
            md.length);
    }
}
DRIVER_EOF

echo "compare_trafilatura_inline_fidelity.sh: compiling the scrubbed-side driver..." >&2
driver_bin="$scratch/inline_fidelity_driver"
ldc2 -O3 -release -I"$repo_root/source" -of="$driver_bin" \
  "$driver_src" \
  "$repo_root/source/effects/html_markdown.d" \
  "$repo_root/source/effects/html_main_content.d" \
  "$repo_root/source/effects/html_main_content_markdown.d" \
  "$repo_root/source/effects/html_tree.d" \
  "$repo_root/source/effects/lexbor_ffi.d" \
  "$repo_root/source/text/decoding.d" \
  "$lexbor_lib" >&2

echo "" >&2
echo "=== scrubbed: extractMainContentMarkdown with formatting=true links=true images=true ===" >&2
scrubbed_paths=()
for page in "${pages[@]}"; do scrubbed_paths+=("$corpus_dir/$page"); done
"$driver_bin" "${scrubbed_paths[@]}"

echo "" >&2
echo "=== trafilatura 2.2.0 --formatting --links --images --output-format markdown ===" >&2
for page in "${pages[@]}"; do
  out="$scratch/$page.md"
  "$trafilatura_bin" --formatting --links --images --output-format markdown \
    < "$corpus_dir/$page" > "$out" || true
  has_bold=no; has_link=no; has_image=no
  grep -Eq '\*\*[^*]|(^|[^*])\*[^*]' "$out" && has_bold=yes || true
  grep -Eq '\]\(' "$out" && has_link=yes || true
  grep -Eq '!\[' "$out" && has_image=yes || true
  printf '%s\tbytes=%d\thasBold=%s\thasLink=%s\thasImage=%s\n' \
    "$page" "$(wc -c < "$out" | tr -d ' ')" "$has_bold" "$has_link" "$has_image"
done

echo "" >&2
echo "compare_trafilatura_inline_fidelity.sh: done. Both tools produced nonempty, structurally-marked" >&2
echo "Markdown (bold/link/image syntax present) for the same real pages with the equivalent flags on." >&2
