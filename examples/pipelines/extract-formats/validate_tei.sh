#!/usr/bin/env bash
# Issue #504 acceptance evidence: real TEI P5 DTD validation of this
# example's pinned `field-notes.tei.xml` golden against pinned
# trafilatura==2.2.0's own bundled tei_corpus.dtd -- the same real
# mechanism (`lxml.etree.DTD(...).validate(...)`) trafilatura's own
# `--validate-tei` uses, and the same idiom `experiments/html_main_content/
# compare_trafilatura_extract_formats.sh` already established in this
# repository (`uv venv` + `uv pip install --python <venv>/bin/python
# trafilatura==2.2.0` + `uv pip freeze` pin verification) rather than
# inventing a new one.
#
# Not part of `examples/pipelines/extract-formats/check.d` (the release-
# active D checker that gates every ordinary build): like the experiments-
# dir comparator scripts, this sits outside `dub build`/`dub test` and
# requires `uv` plus network access to install the pinned package the
# first time it runs. `check.d` itself only proves well-formedness (via
# dxml, already a pinned repository dependency -- no network required);
# this script proves the stronger, real-DTD-validity claim.
#
# Usage: examples/pipelines/extract-formats/validate_tei.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
tei_golden="$root/examples/corpus/extract-formats/expected/field-notes.tei.xml"
validator="$root/examples/pipelines/extract-formats/validate_tei.py"

for tool in uv python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "validate_tei.sh: required tool '$tool' not found on PATH." >&2
    exit 2
  fi
done

scratch="$(mktemp -d -t scrubbed-extract-formats-tei-validation.XXXXXX)"
cleanup() { rm -rf "$scratch"; }
trap cleanup EXIT

echo "== creating a throwaway uv venv and installing pinned trafilatura==2.2.0 ==" >&2
uv venv --quiet "$scratch/venv" >&2
uv pip install --quiet --python "$scratch/venv/bin/python" trafilatura==2.2.0 lxml >&2
freeze="$(uv pip freeze --python "$scratch/venv/bin/python")"
pinned_row="$(printf '%s\n' "$freeze" | grep -E '^trafilatura==' || true)"
if [[ "$pinned_row" != "trafilatura==2.2.0" ]]; then
  echo "validate_tei.sh: pinned-version verification FAILED." >&2
  echo "  expected: trafilatura==2.2.0" >&2
  echo "  uv pip freeze row: ${pinned_row:-<absent>}" >&2
  exit 1
fi
echo "pinned-version verification OK: $pinned_row" >&2

site_packages="$("$scratch/venv/bin/python" -c 'import trafilatura, os; print(os.path.dirname(os.path.dirname(trafilatura.__file__)))')"
tei_dtd="$site_packages/trafilatura/data/tei_corpus.dtd"
if [[ ! -f "$tei_dtd" ]]; then
  echo "validate_tei.sh: pinned trafilatura's own bundled tei_corpus.dtd not found at $tei_dtd" >&2
  exit 1
fi

echo "== validating $tei_golden against $tei_dtd ==" >&2
"$scratch/venv/bin/python" "$validator" "$tei_golden" "$tei_dtd"
