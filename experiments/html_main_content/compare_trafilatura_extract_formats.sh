#!/usr/bin/env bash
# Issue #481 acceptance-criteria evidence: a real, pinned trafilatura==2.2.0
# comparison for EACH of the three new `extract --format=...` values
# (csv/xml/xml-tei), plus real TEI DTD validation and a real CSV round-trip,
# on real held-out pages. Mirrors this repository's already-established
# pinned-external-tool idiom exactly (`fetch_held_out.sh`'s real-page
# acquisition; `compare_trafilatura_block_fidelity.sh`/
# `compare_comments_trafilatura.sh`'s `uv venv` + `uv pip install --python
# <venv>/bin/python trafilatura==2.2.0` + `uv pip freeze` pin verification)
# rather than inventing a new one.
#
# What it does:
#   1. Builds scrubbed (release, so the CLI is fast) and resolves the real
#      20-page held-out corpus via `fetch_held_out.sh --emit-corpus-dir`.
#   2. Creates a throwaway `uv venv`, installs pinned `trafilatura==2.2.0`,
#      verifies the exact pin via `uv pip freeze`.
#   3. For every held-out page: runs `scrubbed extract --format=csv|xml|
#      xml-tei` and pinned `trafilatura --output-format csv|xml|xmltei`
#      (fed on stdin -- `-i`/`--input-file` is trafilatura's own batch
#      URL-list mode, not single-file HTML extraction, on this pinned
#      version; same real, verified constraint `external_comparator.d`'s own
#      `trafilatura_batch_script` documents), and reports both outputs'
#      real structural signal (paragraph/table/list/code counts) side by
#      side -- a structural comparison, not a byte-diff (the two tools'
#      schemas are deliberately different; see the ticket's own PR for the
#      design-latitude rationale).
#   4. Validates every one of scrubbed's own `xml-tei` outputs against
#      pinned trafilatura's OWN bundled real TEI P5 DTD
#      (`trafilatura/data/tei_corpus.dtd`) using the same real mechanism
#      trafilatura's own `--validate-tei` uses (`lxml.etree.DTD(...).
#      validate(...)`) -- acceptance criterion 2.
#   5. Round-trips every one of scrubbed's own `csv` outputs through
#      Python's real `csv` module and asserts every column, and the real
#      table/quote/comma-bearing text this script's own synthetic
#      quote-stress fixture adds, comes back byte-for-byte -- acceptance
#      criterion 3.
#
# Not required to pass, or even to run, for a change to land -- like
# `fetch_held_out.sh`/`compare_trafilatura_block_fidelity.sh`, this sits
# outside `dub build`/`dub test` entirely: it is a real, reviewer-rerunnable
# evidence-gathering comparator, not a CI gate, and it touches the network
# (git clone via `fetch_held_out.sh` + `uv pip install`).
#
# Usage: experiments/html_main_content/compare_trafilatura_extract_formats.sh
# Requirements: git, ldc2, uv, curl, an internet connection, and this
# repository's already-built native Lexbor static library (`dub build
# --build=release` first if not already built).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
lexbor_lib="$root/.dub/lexbor/liblexbor_static.a"
if [[ ! -f "$lexbor_lib" ]]; then
  echo "compare_trafilatura_extract_formats.sh: $lexbor_lib not found." >&2
  echo "Run 'dub build --build=release' from the repository root first." >&2
  exit 2
fi
for tool in git ldc2 uv curl python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "compare_trafilatura_extract_formats.sh: required tool '$tool' not found on PATH." >&2
    exit 2
  fi
done

scratch="$(mktemp -d -t scrubbed-extract-formats-comparison.XXXXXX)"
cleanup() { rm -rf "$scratch"; }
trap cleanup EXIT

echo "== building scrubbed (release) ==" >&2
( cd "$root" && dub build --compiler=ldc2 --build=release >&2 )
scrubbed="$root/scrubbed"

echo "== creating a throwaway uv venv and installing pinned trafilatura==2.2.0 ==" >&2
uv venv --quiet "$scratch/venv" >&2
uv pip install --quiet --python "$scratch/venv/bin/python" trafilatura==2.2.0 lxml >&2
freeze="$(uv pip freeze --python "$scratch/venv/bin/python")"
pinned_row="$(printf '%s\n' "$freeze" | grep -E '^trafilatura==' || true)"
if [[ "$pinned_row" != "trafilatura==2.2.0" ]]; then
  echo "compare_trafilatura_extract_formats.sh: pinned-version verification FAILED." >&2
  echo "  expected: trafilatura==2.2.0" >&2
  echo "  uv pip freeze row: ${pinned_row:-<absent>}" >&2
  exit 1
fi
echo "pinned-version verification OK: $pinned_row" >&2
trafilatura_bin="$scratch/venv/bin/trafilatura"
trafilatura_version="$("$trafilatura_bin" --version)"
echo "$trafilatura_version" >&2
case "$trafilatura_version" in
  "Trafilatura "*) ;;
  *) echo "compare_trafilatura_extract_formats.sh: --version output not in the expected shape" >&2; exit 1;;
esac

echo "== resolving the real 20-page held-out corpus ==" >&2
corpus_dir="$scratch/held-out-corpus"
"$root/experiments/html_main_content/fetch_held_out.sh" \
  --emit-corpus-dir "$corpus_dir" "$scratch/held-out-report.json" >&2

echo "== running scrubbed and pinned trafilatura on every held-out page, all three new formats ==" >&2
mkdir -p "$scratch/scrubbed-out" "$scratch/trafilatura-out"
site_packages="$("$scratch/venv/bin/python" -c 'import trafilatura, os; print(os.path.dirname(os.path.dirname(trafilatura.__file__)))')"
tei_dtd="$site_packages/trafilatura/data/tei_corpus.dtd"
if [[ ! -f "$tei_dtd" ]]; then
  echo "compare_trafilatura_extract_formats.sh: expected bundled TEI DTD not found at $tei_dtd" >&2
  exit 1
fi
echo "using pinned trafilatura's own bundled TEI schema: $tei_dtd" >&2

for page in "$corpus_dir"/*.html; do
  base="$(basename "$page" .html)"
  "$scrubbed" extract -i "$page" -o "$scratch/scrubbed-out/$base.csv" --format=csv 2>/dev/null || true
  "$scrubbed" extract -i "$page" -o "$scratch/scrubbed-out/$base.xml" --format=xml 2>/dev/null || true
  "$scrubbed" extract -i "$page" -o "$scratch/scrubbed-out/$base.tei.xml" --format=xml-tei 2>/dev/null || true
  # --formatting/--links/--images: full-fidelity flags, matching this
  # ticket's own scrubbed output (which always preserves this content), so
  # the structural comparison below is apples-to-apples rather than
  # comparing scrubbed's real links/formatting against trafilatura's own
  # default (stripped) shape.
  "$trafilatura_bin" --output-format csv --formatting --links --images \
    < "$page" > "$scratch/trafilatura-out/$base.csv" 2>/dev/null || true
  "$trafilatura_bin" --output-format xml --formatting --links --images \
    < "$page" > "$scratch/trafilatura-out/$base.xml" 2>/dev/null || true
  "$trafilatura_bin" --output-format xmltei --formatting --links --images \
    < "$page" > "$scratch/trafilatura-out/$base.tei.xml" 2>/dev/null || true
done

echo "== a real, synthetic quote/comma-stress page for the CSV round-trip proof ==" >&2
cat > "$scratch/quote-stress.html" << 'HTMLEOF'
<html><head><title>Quote Stress Test</title></head><body>
<nav>Home About</nav>
<article>
<h1>A report with quoted table data</h1>
<p>This report contains a table with cells that include double quotes and
commas, which is exactly the kind of content a real CSV round-trip test
needs to exercise thoroughly and repeatedly to be genuinely convincing as
evidence rather than a superficial smoke test of the happy path alone.</p>
<table>
<tr><th>Label</th><th>Value</th></tr>
<tr><td>He said &quot;hello, world&quot; loudly</td><td>42, or so</td></tr>
<tr><td>Another "quoted" cell, with a comma</td><td>plain</td></tr>
</table>
<p>The report continues with more prose after the table, to keep the
selection thresholds happy and realistic for extraction purposes overall,
matching the length of a genuine real-world article body.</p>
</article>
</body></html>
HTMLEOF
"$scrubbed" extract -i "$scratch/quote-stress.html" -o "$scratch/quote-stress.csv" --format=csv

echo "== structural comparison + real TEI validation + real CSV round-trip ==" >&2
"$scratch/venv/bin/python" "$root/experiments/html_main_content/compare_trafilatura_extract_formats.py" \
  "$scratch/scrubbed-out" "$scratch/trafilatura-out" "$tei_dtd" "$scratch/quote-stress.csv"
