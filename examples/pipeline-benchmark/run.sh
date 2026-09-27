#!/usr/bin/env bash
# examples/pipeline-benchmark/run.sh
#
# Single runnable entry point for issue #315's whole-pipeline comparison:
# the real `scrubbed clean-web-document` release binary vs. an equivalent,
# pinned Python chain (ftfy -> trafilatura -> langdetect -> Presidio, no
# dedup step -- explicitly dropped from this slice) over the same small,
# fixed, checked-in corpus at examples/pipeline-benchmark/corpus/.
#
# This script does not invent a new scoring methodology: text agreement
# uses experiments/html_main_content/token_overlap.d's existing word-level
# multiset-overlap metric (issue #26), and the language-id/PII decoding
# reuses domain.language_id/the plain pii-audit JSON shape exactly as
# benchmarks/external_comparator.d already does for its own per-tool cases.
# See examples/pipeline-benchmark/score_helper.d for the reused pieces.
#
# Timing methodology mirrors benchmarks/external_comparator.d's own
# A/B/A/B interleave: four whole-corpus samples, alternating scrubbed and
# the Python chain, starting with scrubbed. Each tool's own two samples
# must reproduce byte-identical (or line-identical) output, matching that
# same file's existing reproducibility-gate idiom.
#
# Usage: examples/pipeline-benchmark/run.sh [WORK_DIR]
#   WORK_DIR is created if missing and kept after the run (default: a
#   fresh mktemp directory, printed at the start of the run).
#
# Requirements: dub, ldc2, uv, curl, python3, shasum, a POSIX shell.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
corpus_dir="$script_dir/corpus"

work_root="${1:-}"
if [[ -z "$work_root" ]]; then
  work_root="$(mktemp -d /tmp/scrubbed-pipeline-benchmark.XXXXXX)"
fi
mkdir -p "$work_root"
echo "run.sh: work directory: $work_root" >&2

for tool in dub ldc2 uv curl python3 shasum; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "run.sh: required tool '$tool' not found on PATH" >&2
    exit 2
  fi
done

corpus_files=("$corpus_dir"/*.html)
corpus_count=${#corpus_files[@]}
corpus_bytes=$(cat "${corpus_files[@]}" | wc -c | tr -d ' ')
echo "run.sh: corpus: $corpus_count pages, $corpus_bytes bytes (examples/pipeline-benchmark/manifest.json documents provenance; see NOTICE.md for the redistribution-risk decision and manifest.json's fetchOutcomeSummary for the 6 originally-pinned URLs that could not be fetched)." >&2

# ---- 1. Build the real scrubbed release binary ----
scrubbed_bin="$repo_root/scrubbed"
echo "run.sh: building scrubbed (dub build --build=release --compiler=ldc2)..." >&2
(cd "$repo_root" && dub build --build=release --compiler=ldc2) >&2
[[ -x "$scrubbed_bin" ]] || { echo "run.sh: build did not produce $scrubbed_bin" >&2; exit 2; }

# ---- 2. Build the scoring helper (reuses existing D scoring/decoding code) ----
score_helper="$work_root/score_helper"
echo "run.sh: building score_helper (reuses token_overlap.d and domain.language_id)..." >&2
ldc2 -O3 -release -i -I"$repo_root/source" -I"$repo_root" \
  "$script_dir/score_helper.d" -of="$score_helper" >&2

# ---- 3. Pinned Python venvs (same uv venv + uv pip install pattern as ----
# ----    benchmarks/README.md's "Shared external-tool comparator" section) ----
venv_root="$work_root/venvs"
mkdir -p "$venv_root"

setup_venv() {
  local name="$1"; shift
  local venv_dir="$venv_root/$name"
  if [[ ! -x "$venv_dir/bin/python" ]]; then
    echo "run.sh: creating venv '$name'..." >&2
    uv venv "$venv_dir" >&2
  fi
  echo "run.sh: installing pinned packages into '$name': $*" >&2
  uv pip install --python "$venv_dir/bin/python" "$@" >&2
}

setup_venv ftfy ftfy==6.3.1 wcwidth==0.8.4
setup_venv trafilatura trafilatura==2.2.0
setup_venv langdetect langdetect==1.0.9
setup_venv presidio presidio-analyzer==2.2.364 presidio-anonymizer==2.2.364
setup_venv presidio "https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl"

# ---- 4. Verify pins (same uv-pip-freeze verification idiom as ----
# ----    benchmarks/external_comparator.d's verifyPinnedPackages) ----
freeze_of() {
  uv pip freeze --python "$venv_root/$1/bin/python" | grep -v '^Using Python '
}
require_pin() {
  local venv="$1" row="$2" freeze
  freeze="$(freeze_of "$venv")"
  if ! grep -qxF "$row" <<<"$freeze"; then
    echo "run.sh: pin verification FAILED for '$venv': expected exact row '$row'; got:" >&2
    echo "$freeze" >&2
    exit 1
  fi
}
require_pin ftfy "ftfy==6.3.1"
require_pin ftfy "wcwidth==0.8.4"
require_pin trafilatura "trafilatura==2.2.0"
require_pin langdetect "langdetect==1.0.9"
require_pin presidio "presidio-analyzer==2.2.364"
require_pin presidio "presidio-anonymizer==2.2.364"
require_pin presidio "en-core-web-sm @ https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl"
echo "run.sh: all pinned package versions verified." >&2

ftfy_bin="$venv_root/ftfy/bin/ftfy"
trafilatura_bin="$venv_root/trafilatura/bin/trafilatura"
langdetect_python="$venv_root/langdetect/bin/python"
presidio_python="$venv_root/presidio/bin/python"

# Presidio scope re-verification (empirical, not assumed -- same guarantee
# benchmarks/README.md documents for presidio_driver.py).
presidio_scope="$("$presidio_python" "$repo_root/benchmarks/presidio_driver.py" --print-scope)"
expected_scope="CREDIT_CARD,EMAIL_ADDRESS,IP_ADDRESS,PHONE_NUMBER"
if [[ "$presidio_scope" != "$expected_scope" ]]; then
  echo "run.sh: presidio_driver.py scope drift: expected '$expected_scope', got '$presidio_scope'" >&2
  exit 1
fi

# ---- 5. Whole-pipeline chain definitions ----

# One full pass over the corpus with scrubbed's fixed clean-web-document/v1
# preset (text-transform(fix-mojibake) -> html-metadata-annotate ->
# html-main-content -> pii-four-class). `clean-web-document` exits 1
# whenever any input is quarantined by html-main-content -- this real
# corpus's content legitimately does that for some pages (see
# docs/html-main-content.md) -- so 0 or 1 are both a clean invocation here,
# matching benchmarks/external_comparator.d's own main-content case.
run_scrubbed_pipeline() {
  local out_dir="$1"
  rm -rf "$out_dir" "${out_dir}.pii-audit"
  mkdir -p "$out_dir"
  set +e
  "$scrubbed_bin" clean-web-document --input "$corpus_dir" --output "$out_dir" --threads 4 \
    >"$out_dir.stdout.log" 2>"$out_dir.stderr.log"
  local status=$?
  set -e
  if [[ $status -ne 0 && $status -ne 1 ]]; then
    echo "run.sh: scrubbed clean-web-document exited $status (neither clean nor a content-driven quarantine)" >&2
    cat "$out_dir.stderr.log" >&2
    exit 1
  fi
}

# One full pass over the corpus with the equivalent Python chain: ftfy ->
# trafilatura -> langdetect -> Presidio, no dedup step (explicitly out of
# scope for this slice -- see the issue's owner decision). Intermediate
# ftfy and trafilatura outputs are kept per file so the correctness section
# below can score each stage without a second timed pass.
run_python_pipeline() {
  local out_dir="$1"
  rm -rf "$out_dir"
  mkdir -p "$out_dir"
  local f stem status=0
  for f in "${corpus_files[@]}"; do
    stem="$(basename "$f" .html)"
    "$ftfy_bin" --preserve-entities -n none < "$f" > "$out_dir/$stem.ftfy.html" || status=$?
    "$trafilatura_bin" --output-format txt < "$out_dir/$stem.ftfy.html" > "$out_dir/$stem.txt" || status=$?
    "$langdetect_python" "$repo_root/benchmarks/langdetect_driver.py" "$out_dir/$stem.txt" \
      > "$out_dir/$stem.lang" || status=$?
    "$presidio_python" "$repo_root/benchmarks/presidio_driver.py" "$out_dir/$stem.txt" \
      > "$out_dir/$stem.pii" || status=$?
  done
  if [[ $status -ne 0 ]]; then
    echo "run.sh: python pipeline chain reported a nonzero step exit ($status)" >&2
    exit 1
  fi
}

tree_signature() {
  # Deterministic sha256 over every regular file's relative path and bytes,
  # for the reproducibility gate below (same purpose as
  # external_comparator.d's directorySignature, reimplemented here in
  # shell rather than imported since it is `private` to that module).
  local dir="$1"
  ( cd "$dir" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256 ) | shasum -a 256 | awk '{print $1}'
}

now_seconds() { python3 -c 'import time; print(f"{time.time():.6f}")'; }

# ---- 6. Interleaved A/B/A/B whole-pipeline timing ----
echo "run.sh: running interleaved A/B/A/B whole-pipeline timing (scrubbed, python, scrubbed, python)..." >&2
declare -a sample_tool sample_seconds
scrubbed_dirs=()
python_dirs=()
for i in 0 1 2 3; do
  if (( i % 2 == 0 )); then
    tool=scrubbed
    out_dir="$work_root/scrubbed-sample-$i"
    start="$(now_seconds)"
    run_scrubbed_pipeline "$out_dir"
    end="$(now_seconds)"
    scrubbed_dirs+=("$out_dir")
  else
    tool=python
    out_dir="$work_root/python-sample-$i"
    start="$(now_seconds)"
    run_python_pipeline "$out_dir"
    end="$(now_seconds)"
    python_dirs+=("$out_dir")
  fi
  elapsed="$(python3 -c "print(f'{$end - $start:.6f}')")"
  sample_tool[i]="$tool"
  sample_seconds[i]="$elapsed"
  echo "run.sh: sample $i ($tool): ${elapsed}s" >&2
done

# ---- 7. Reproducibility gate: each tool's own two timed samples must ----
# ----    produce identical output (matching every existing comparator case) ----
scrubbed_sig_a="$(tree_signature "${scrubbed_dirs[0]}")"
scrubbed_sig_b="$(tree_signature "${scrubbed_dirs[1]}")"
if [[ "$scrubbed_sig_a" != "$scrubbed_sig_b" ]]; then
  echo "run.sh: scrubbed produced non-reproducible output between its own two timed samples" >&2
  exit 1
fi
python_sig_a="$(tree_signature "${python_dirs[0]}")"
python_sig_b="$(tree_signature "${python_dirs[1]}")"
if [[ "$python_sig_a" != "$python_sig_b" ]]; then
  echo "run.sh: the python chain produced non-reproducible output between its own two timed samples" >&2
  exit 1
fi
echo "run.sh: both tools reproduced byte-identical output across their own two timed samples." >&2

# ---- 8. Non-timed correctness/agreement pass over the same corpus ----
# clean-web-document's chain is fixed and exposes no intermediate output,
# so per-stage agreement (mojibake-equivalent, main-content extraction,
# language-id, PII) is scored from separate, single-stage `scrubbed run`
# invocations -- the same `--stage clean=...`/`--stage content=...`/
# `--stage id=...` shapes benchmarks/external_comparator.d's own per-tool
# cases already use -- against sample 0's already-captured Python chain
# output (no extra Python invocations needed).
echo "run.sh: running per-stage correctness/agreement pass (not timed)..." >&2
py_dir="${python_dirs[0]}"
score_dir="$work_root/scrubbed-stage-scores"
rm -rf "$score_dir"
mkdir -p "$score_dir/mojibake" "$score_dir/main-content" "$score_dir/langid-sidecar" "$score_dir/pii-sidecar"

mojibake_matches=0
mc_selected=0
mc_abstained=0
langid_agree=0
langid_disagree=0
langid_d_abstain=0
langid_py_error=0
# Plain scalar counters (not associative arrays) for portability: this
# script targets macOS's stock /bin/bash 3.2, which has no `declare -A`.
# The four category names are fixed by pii-four-class's own implemented
# categories (docs/pii-patterns.md), not discovered at run time.
pii_d_email=0; pii_d_phone=0; pii_d_card=0; pii_d_ip=0
pii_py_email=0; pii_py_phone=0; pii_py_card=0; pii_py_ip=0

for f in "${corpus_files[@]}"; do
  stem="$(basename "$f" .html)"

  # (a) ftfy-equivalent: exact-byte style, same command family as
  # benchmarks/external_comparator.d's mojibake case.
  "$scrubbed_bin" run --stage clean=text-transform --filter fix-mojibake \
    --input "$f" --output "$score_dir/mojibake/$stem.html" --threads 1 >/dev/null
  diff_result="$("$score_helper" mojibake-diff "$score_dir/mojibake/$stem.html" "$py_dir/$stem.ftfy.html")"
  [[ "$diff_result" == "match" ]] && mojibake_matches=$((mojibake_matches + 1))

  # (b) main-content extraction agreement (token overlap vs. trafilatura).
  set +e
  "$scrubbed_bin" run --input "$f" --output "$score_dir/main-content/$stem.txt" \
    --stage content=html-main-content --threads 1 >/dev/null 2>"$score_dir/main-content/$stem.err"
  mc_status=$?
  set -e
  if [[ $mc_status -ne 0 && $mc_status -ne 1 ]]; then
    echo "run.sh: unexpected html-main-content exit $mc_status for $stem" >&2
    exit 1
  fi
  if [[ -s "$score_dir/main-content/$stem.txt" ]]; then
    mc_selected=$((mc_selected + 1))
    overlap_json="$("$score_helper" text-overlap "$score_dir/main-content/$stem.txt" "$py_dir/$stem.txt")"
    echo "$overlap_json" > "$score_dir/main-content/$stem.overlap.json"

    # (c) language-id agreement: scrubbed on its own extracted text vs.
    # langdetect on trafilatura's extracted text (each tool scored on its
    # own upstream stage's output -- a true whole-chain comparison).
    "$scrubbed_bin" run --input "$score_dir/main-content/$stem.txt" \
      --output "$score_dir/langid-sidecar/$stem.out" \
      --sidecar-output "$score_dir/langid-sidecar/$stem.sidecar" \
      --stage id=language-id-detect --threads 1 >/dev/null
    d_lang_line="$("$score_helper" decode-langid "$score_dir/langid-sidecar/$stem.sidecar" \
      "$score_dir/main-content/$stem.txt")"
    py_lang_line="$(cat "$py_dir/$stem.lang")"
    d_lang_status="${d_lang_line%% *}"
    d_lang_code="$(awk '{print $2}' <<<"$d_lang_line")"
    py_lang_code="${py_lang_line%% *}"
    py_lang_is_error=0
    case "$py_lang_code" in
      error:*) py_lang_is_error=1 ;;
    esac
    if [[ "$d_lang_status" == "detected" ]]; then
      if [[ "$py_lang_is_error" -eq 0 && "$d_lang_code" == "$py_lang_code" ]]; then
        langid_agree=$((langid_agree + 1))
      else
        langid_disagree=$((langid_disagree + 1))
      fi
    else
      langid_d_abstain=$((langid_d_abstain + 1))
    fi
    [[ "$py_lang_is_error" -eq 1 ]] && langid_py_error=$((langid_py_error + 1))

    # (d) PII agreement: scrubbed's pii-four-class on its own extracted
    # text vs. Presidio on trafilatura's extracted text, per category.
    "$scrubbed_bin" run --input "$score_dir/main-content/$stem.txt" \
      --output "$score_dir/pii-sidecar/$stem.out" \
      --sidecar-output "$score_dir/pii-sidecar/$stem.sidecar" \
      --stage id=pii-four-class --threads 1 >/dev/null
    while read -r category count; do
      [[ -z "$category" ]] && continue
      case "$category" in
        email) pii_d_email=$((pii_d_email + count)) ;;
        phone) pii_d_phone=$((pii_d_phone + count)) ;;
        card)  pii_d_card=$((pii_d_card + count)) ;;
        ip)    pii_d_ip=$((pii_d_ip + count)) ;;
      esac
    done < <("$score_helper" pii-summary "$score_dir/pii-sidecar/$stem.sidecar")
    while read -r line; do
      [[ -z "$line" ]] && continue
      category="${line%% *}"
      case "$category" in
        email) pii_py_email=$((pii_py_email + 1)) ;;
        phone) pii_py_phone=$((pii_py_phone + 1)) ;;
        card)  pii_py_card=$((pii_py_card + 1)) ;;
        ip)    pii_py_ip=$((pii_py_ip + 1)) ;;
      esac
    done < "$py_dir/$stem.pii"
  else
    mc_abstained=$((mc_abstained + 1))
  fi
done

# ---- 9. Report ----
mean_scrubbed=$(python3 -c "print(f'{(${sample_seconds[0]} + ${sample_seconds[2]}) / 2:.4f}')")
mean_python=$(python3 -c "print(f'{(${sample_seconds[1]} + ${sample_seconds[3]}) / 2:.4f}')")
throughput_scrubbed=$(python3 -c "print(f'{$corpus_bytes / ${mean_scrubbed} / 1024:.1f}')")
throughput_python=$(python3 -c "print(f'{$corpus_bytes / ${mean_python} / 1024:.1f}')")
pages_per_sec_scrubbed=$(python3 -c "print(f'{$corpus_count / ${mean_scrubbed}:.2f}')")
pages_per_sec_python=$(python3 -c "print(f'{$corpus_count / ${mean_python}:.2f}')")

mc_overlap_report="$score_dir/main-content-overlap-summary.py"
main_content_summary="$(python3 - "$score_dir/main-content" "${corpus_files[@]}" <<'PYEOF'
import json, sys, os
score_dir = sys.argv[1]
files = sys.argv[2:]
precisions = []
recalls = []
for f in files:
    stem = os.path.splitext(os.path.basename(f))[0]
    path = os.path.join(score_dir, stem + ".overlap.json")
    if not os.path.exists(path):
        continue
    data = json.load(open(path))
    precisions.append(data["aVsB"]["precision"])
    recalls.append(data["aVsB"]["recall"])
if precisions:
    print(f"meanPrecisionVsTrafilatura={sum(precisions)/len(precisions):.4f} "
          f"meanRecallVsTrafilatura={sum(recalls)/len(recalls):.4f} n={len(precisions)}")
else:
    print("meanPrecisionVsTrafilatura=n/a meanRecallVsTrafilatura=n/a n=0")
PYEOF
)"

cat <<REPORT

================ examples/pipeline-benchmark report ================
Corpus: $corpus_count pages, $corpus_bytes bytes (examples/pipeline-benchmark/corpus/;
  see manifest.json and NOTICE.md for provenance and the 6 originally
  pinned URLs that could not be fetched).

--- Whole-pipeline timing (A/B/A/B interleaved, wall clock) ---
scrubbed clean-web-document samples: ${sample_seconds[0]}s, ${sample_seconds[2]}s (mean ${mean_scrubbed}s)
python chain (ftfy->trafilatura->langdetect->presidio) samples: ${sample_seconds[1]}s, ${sample_seconds[3]}s (mean ${mean_python}s)
Both tools reproduced byte-identical output across their own two samples.

Throughput:
  scrubbed:      ${throughput_scrubbed} KiB/s, ${pages_per_sec_scrubbed} pages/s
  python chain:  ${throughput_python} KiB/s, ${pages_per_sec_python} pages/s

--- Correctness / agreement summary (not gated; descriptive only) ---
[ftfy-equivalent, exact-byte match style]
  fix-mojibake vs ftfy --preserve-entities -n none: $mojibake_matches/$corpus_count pages byte-identical
  (a low count on real-world HTML is expected and not a bug: ftfy's default
  fixes -- e.g. line-break normalization -- are broader than scrubbed's
  narrowly-scoped mojibake/encoding repair; see README.md "Interpreting the
  output" for the observed byte-level diff shape.)

[main-content extraction, token-overlap agreement style]
  html-main-content selected (non-quarantined): $mc_selected/$corpus_count pages
  html-main-content abstained/quarantined:      $mc_abstained/$corpus_count pages
  $main_content_summary
  (word-level, case-normalized, whitespace-tokenized multiset overlap between
  scrubbed's and trafilatura's own extracted text on the SAME raw page --
  issue #26's metric, imported unmodified; neither tool is the other's gold.)

[language-id, agreement style]
  agree:              $langid_agree
  disagree:           $langid_disagree
  scrubbed abstained:  $langid_d_abstain
  langdetect errored:  $langid_py_error
  (out of $mc_selected pages that had a main-content extraction to classify;
  each tool classifies its own upstream extraction, so this compares two
  full chains end to end, not a shared fixed input.)

[PII (email/phone/card/ip), per-category count agreement style]
REPORT
printf '  %-6s scrubbed=%-4s presidio=%-4s\n' email "$pii_d_email" "$pii_py_email"
printf '  %-6s scrubbed=%-4s presidio=%-4s\n' phone "$pii_d_phone" "$pii_py_phone"
printf '  %-6s scrubbed=%-4s presidio=%-4s\n' card "$pii_d_card" "$pii_py_card"
printf '  %-6s scrubbed=%-4s presidio=%-4s\n' ip "$pii_d_ip" "$pii_py_ip"
cat <<REPORT
  (counts are total reported findings across all $mc_selected classified pages,
  each tool scored on its own upstream extracted text; this is a descriptive
  count comparison, not a gold-span precision/recall claim -- this real
  corpus has no authored gold PII spans.)

Full intermediate artifacts are kept under: $work_root
=======================================================================
REPORT
echo "run.sh: done." >&2
