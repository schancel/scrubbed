#!/usr/bin/env bash
# examples/pipeline-benchmark/run_throughput.sh
#
# Complementary, steady-state THROUGHPUT sibling to run.sh (issue #315).
#
# run.sh's own README already discloses a methodology gap in its timing:
# its Python side spawns a fresh interpreter twice per page (once for
# benchmarks/langdetect_driver.py, once for benchmarks/presidio_driver.py),
# each paying full interpreter-startup plus, on the Presidio side, a
# one-time spaCy en_core_web_sm model load -- repeated on every single page.
# That gap says more about process-startup/interpreter overhead in that
# specific comparison shape than about ftfy/trafilatura/langdetect/Presidio's
# own per-call speed once warm. This script measures the complementary
# number: steady-state throughput once that one-time cost is amortized over
# a corpus-scale run, in one warm Python process
# (examples/pipeline-benchmark/throughput_driver.py), against one real
# scrubbed composition that performs the same four task families:
# mojibake repair, main-content extraction, language ID, and four-class PII.
#
# It does NOT fetch, vendor, or otherwise add any new third-party content.
# It reuses the existing, already-accepted 20-page corpus at
# examples/pipeline-benchmark/corpus/ (see NOTICE.md and manifest.json,
# unmodified by this script) by replicating it N times into a scratch
# directory, to reach a file count where one-time model-load cost stops
# dominating total wall time. Replicating already-checked-in content is not
# the same "distinct, bigger legal call" issue #315 made about permanently
# vendoring new third-party content, and this script does not reopen that
# decision.
#
# Usage: examples/pipeline-benchmark/run_throughput.sh [WORK_DIR]
#   WORK_DIR is created if missing and kept after the run (default: a
#   fresh mktemp directory, printed at the start of the run).
#
# Requirements: dub, ldc2, uv, curl, python3, shasum, a POSIX shell -- same
# as run.sh.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
corpus_dir="$script_dir/corpus"

work_root="${1:-}"
if [[ -z "$work_root" ]]; then
  work_root="$(mktemp -d /tmp/scrubbed-pipeline-throughput.XXXXXX)"
fi
mkdir -p "$work_root"
echo "run_throughput.sh: work directory: $work_root" >&2

for tool in dub ldc2 uv curl python3 shasum; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "run_throughput.sh: required tool '$tool' not found on PATH" >&2
    exit 2
  fi
done

corpus_files=("$corpus_dir"/*.html)
corpus_count=${#corpus_files[@]}
echo "run_throughput.sh: source corpus: $corpus_count pages (examples/pipeline-benchmark/corpus/; see NOTICE.md -- no new third-party content is fetched or vendored by this script)." >&2

# ---- 1. Build the real scrubbed release binary (same step as run.sh) ----
scrubbed_bin="$repo_root/scrubbed"
echo "run_throughput.sh: building scrubbed (dub build --build=release --compiler=ldc2)..." >&2
(cd "$repo_root" && dub build --build=release --compiler=ldc2) >&2
[[ -x "$scrubbed_bin" ]] || { echo "run_throughput.sh: build did not produce $scrubbed_bin" >&2; exit 2; }

# ---- 2. Materialize a replicated corpus (same 20 pages, N unique copies) ----
# REPLICAS=20 gives 20 * 20 = 400 files, inside the ~300-500 target range.
# Rough justification: spaCy's en_core_web_sm model load (the dominant
# one-time cost on the Python side) is typically 1-3 seconds; a real ftfy ->
# trafilatura -> langdetect -> presidio pass over one small (~10-200 KiB)
# real HTML page, warm, is expected to be a low-single-digit number of
# milliseconds to a few tens of milliseconds. At 400 documents, steady-state
# loop time should therefore be at least several seconds -- comfortably
# larger than the one-time 1-3s model-load cost -- so the reported
# steady-state throughput is not itself dominated by amortized startup.
replicas=20
replicated_dir="$work_root/replicated-corpus"
rm -rf "$replicated_dir"
mkdir -p "$replicated_dir"
for f in "${corpus_files[@]}"; do
  stem="$(basename "$f" .html)"
  for i in $(seq -w 1 "$replicas"); do
    cp "$f" "$replicated_dir/${stem}.copy${i}.html"
  done
done
replicated_files=("$replicated_dir"/*.html)
replicated_count=${#replicated_files[@]}
replicated_bytes=$(cat "${replicated_files[@]}" | wc -c | tr -d ' ')
echo "run_throughput.sh: replicated corpus: $replicated_count files (${replicas}x the $corpus_count-page source corpus), $replicated_bytes bytes, at $replicated_dir" >&2

# ---- 3. One combined pinned Python venv (throughput_driver.py imports ----
# ----    every pinned package in a single warm process, unlike run.sh's ----
# ----    four separate per-tool venvs) ----
venv_root="$work_root/venvs"
mkdir -p "$venv_root"

setup_venv() {
  local name="$1"; shift
  local venv_dir="$venv_root/$name"
  if [[ ! -x "$venv_dir/bin/python" ]]; then
    echo "run_throughput.sh: creating venv '$name'..." >&2
    uv venv "$venv_dir" >&2
  fi
  echo "run_throughput.sh: installing pinned packages into '$name': $*" >&2
  uv pip install --python "$venv_dir/bin/python" "$@" >&2
}

setup_venv throughput ftfy==6.3.1 wcwidth==0.8.4 trafilatura==2.2.0 langdetect==1.0.9 \
  presidio-analyzer==2.2.364 presidio-anonymizer==2.2.364
setup_venv throughput "https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl"

freeze_of() {
  uv pip freeze --python "$venv_root/$1/bin/python" | grep -v '^Using Python '
}
require_pin() {
  local venv="$1" row="$2" freeze
  freeze="$(freeze_of "$venv")"
  if ! grep -qxF "$row" <<<"$freeze"; then
    echo "run_throughput.sh: pin verification FAILED for '$venv': expected exact row '$row'; got:" >&2
    echo "$freeze" >&2
    exit 1
  fi
}
require_pin throughput "ftfy==6.3.1"
require_pin throughput "wcwidth==0.8.4"
require_pin throughput "trafilatura==2.2.0"
require_pin throughput "langdetect==1.0.9"
require_pin throughput "presidio-analyzer==2.2.364"
require_pin throughput "presidio-anonymizer==2.2.364"
require_pin throughput "en-core-web-sm @ https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl"
echo "run_throughput.sh: all pinned package versions verified." >&2

throughput_python="$venv_root/throughput/bin/python"

# Presidio scope re-verification, same empirical guarantee run.sh applies to
# its own presidio venv, reusing the exact same driver and its --print-scope
# mode (throughput_driver.py imports this same build_analyzer()).
presidio_scope="$("$throughput_python" "$repo_root/benchmarks/presidio_driver.py" --print-scope)"
expected_scope="CREDIT_CARD,EMAIL_ADDRESS,IP_ADDRESS,PHONE_NUMBER"
if [[ "$presidio_scope" != "$expected_scope" ]]; then
  echo "run_throughput.sh: presidio_driver.py scope drift: expected '$expected_scope', got '$presidio_scope'" >&2
  exit 1
fi

now_seconds() { python3 -c 'import time; print(f"{time.time():.6f}")'; }

# CPU seconds (user+sys) from a /usr/bin/time report mixed into a log file
# (its own report lines are distinctive and safe to grep out of scrubbed's
# ordinarily-near-empty stderr). Unlike wall-clock, this isn't inflated by
# scheduling delay when other processes are competing for CPU on this host.
cpu_seconds_from_time_log() {
  local log="$1"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    local user sys
    user="$(grep -m1 '^user ' "$log" | awk '{print $2}')"
    sys="$(grep -m1 '^sys ' "$log" | awk '{print $2}')"
    python3 -c "print(f'{${user:-0} + ${sys:-0}:.6f}')"
  else
    local user sys
    user="$(grep -m1 'User time (seconds):' "$log" | awk '{print $NF}')"
    sys="$(grep -m1 'System time (seconds):' "$log" | awk '{print $NF}')"
    python3 -c "print(f'{${user:-0} + ${sys:-0}:.6f}')"
  fi
}

time_wrapper() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "/usr/bin/time -l -p"
  else
    echo "/usr/bin/time -v"
  fi
}

tree_signature() {
  # Same deterministic sha256-over-relative-path-and-bytes idiom as run.sh's
  # own tree_signature, reimplemented here rather than sourced since run.sh
  # is a standalone script, not a library.
  local dir="$1"
  ( cd "$dir" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256 ) | shasum -a 256 | awk '{print $1}'
}

# ---- 4. Time scrubbed: single timed invocation over the replicated ----
# ----    corpus, no startup-amortization issue on this side (already one ----
# ----    process) -- run twice, matching this repo's reproducibility- ----
# ----    minded convention. ----
run_scrubbed_throughput() {
  local sample_root="$1"
  local primary_dir="$sample_root/primary"
  local metadata_dir="$sample_root/metadata"
  rm -rf "$sample_root"
  mkdir -p "$primary_dir"
  set +e
  # shellcheck disable=SC2046  # time_wrapper's two-token output is meant to split
  $(time_wrapper) "$scrubbed_bin" run --input "$replicated_dir" --output "$primary_dir" \
    --sidecar-output "$metadata_dir" --threads 4 \
    --stage clean=text-transform --filter fix-mojibake \
    --stage content=html-main-content \
    --stage language=language-id-detect \
    --stage pii=pii-four-class \
    --stage publish=document-metadata-publish \
    >"$sample_root.stdout.log" 2>"$sample_root.stderr.log"
  local status=$?
  set -e
  if [[ $status -ne 0 && $status -ne 1 ]]; then
    echo "run_throughput.sh: scrubbed comparison pipeline exited $status (neither clean nor a content-driven quarantine)" >&2
    cat "$sample_root.stderr.log" >&2
    exit 1
  fi
}

echo "run_throughput.sh: timing scrubbed's matched four-task pipeline over $replicated_count files (2 samples)..." >&2
declare -a scrubbed_seconds scrubbed_cpu_seconds
scrubbed_dirs=()
for i in 0 1; do
  out_dir="$work_root/scrubbed-throughput-sample-$i"
  start="$(now_seconds)"
  run_scrubbed_throughput "$out_dir"
  end="$(now_seconds)"
  scrubbed_dirs+=("$out_dir")
  scrubbed_seconds[i]="$(python3 -c "print(f'{$end - $start:.6f}')")"
  scrubbed_cpu_seconds[i]="$(cpu_seconds_from_time_log "$out_dir.stderr.log")"
  echo "run_throughput.sh: scrubbed sample $i: wall ${scrubbed_seconds[i]}s, cpu ${scrubbed_cpu_seconds[i]}s" >&2
done

scrubbed_sig_a="$(tree_signature "${scrubbed_dirs[0]}")"
scrubbed_sig_b="$(tree_signature "${scrubbed_dirs[1]}")"
if [[ "$scrubbed_sig_a" != "$scrubbed_sig_b" ]]; then
  echo "run_throughput.sh: scrubbed produced non-reproducible output between its own two timed samples" >&2
  exit 1
fi

# ---- 5. Time throughput_driver.py: one warm-process invocation per ----
# ----    sample over the whole replicated corpus -- run twice. ----
echo "run_throughput.sh: timing throughput_driver.py over $replicated_count files (2 samples)..." >&2
declare -a python_seconds python_model_load python_loop python_loop_cpu python_doc_count python_total_bytes
declare -a python_docs_per_sec python_kib_per_sec
python_logs=()
for i in 0 1; do
  out_log="$work_root/python-throughput-sample-$i.log"
  start="$(now_seconds)"
  "$throughput_python" "$script_dir/throughput_driver.py" "$replicated_dir" \
    >"$out_log" 2>"$work_root/python-throughput-sample-$i.stderr.log"
  end="$(now_seconds)"
  python_logs+=("$out_log")
  python_seconds[i]="$(python3 -c "print(f'{$end - $start:.6f}')")"

  one_time_line="$(grep '^THROUGHPUT_DRIVER_ONE_TIME' "$out_log")"
  loop_line="$(grep '^THROUGHPUT_DRIVER_LOOP' "$out_log")"
  if [[ -z "$one_time_line" || -z "$loop_line" ]]; then
    echo "run_throughput.sh: throughput_driver.py sample $i did not print the expected THROUGHPUT_DRIVER_* lines; see $out_log" >&2
    exit 1
  fi

  model_load="$(grep -o 'model_load_seconds=[0-9.]*' <<<"$one_time_line" | cut -d= -f2)"
  loop_seconds="$(grep -o 'loop_seconds=[0-9.]*' <<<"$loop_line" | cut -d= -f2)"
  loop_cpu_seconds="$(grep -o 'loop_cpu_seconds=[0-9.]*' <<<"$loop_line" | cut -d= -f2)"
  doc_count="$(grep -o 'doc_count=[0-9]*' <<<"$loop_line" | cut -d= -f2)"
  total_bytes="$(grep -o 'total_bytes=[0-9]*' <<<"$loop_line" | cut -d= -f2)"
  docs_per_sec="$(grep -o 'docs_per_sec=[0-9.]*' <<<"$loop_line" | cut -d= -f2)"
  kib_per_sec="$(grep -o 'kib_per_sec=[0-9.]*' <<<"$loop_line" | cut -d= -f2)"

  python_model_load[i]="$model_load"
  python_loop[i]="$loop_seconds"
  python_loop_cpu[i]="$loop_cpu_seconds"
  python_doc_count[i]="$doc_count"
  python_total_bytes[i]="$total_bytes"
  python_docs_per_sec[i]="$docs_per_sec"
  python_kib_per_sec[i]="$kib_per_sec"
  echo "run_throughput.sh: python sample $i: wall ${python_seconds[i]}s (model_load ${model_load}s + loop ${loop_seconds}s, loop cpu ${loop_cpu_seconds}s), $doc_count docs, $total_bytes bytes" >&2
done

# Reproducibility substitute for the python side: throughput_driver.py
# processes everything in memory and writes no output tree to hash, so
# instead its own reported doc_count/total_bytes/PII totals must match
# exactly between its own two timed samples.
py_diff_fields="doc_count total_bytes pii_email pii_phone pii_card pii_ip extraction_failures lang_errors"
for field in $py_diff_fields; do
  v0="$(grep -o "${field}=[0-9]*" "${python_logs[0]}" | tail -1 | cut -d= -f2)"
  v1="$(grep -o "${field}=[0-9]*" "${python_logs[1]}" | tail -1 | cut -d= -f2)"
  if [[ "$v0" != "$v1" ]]; then
    echo "run_throughput.sh: python throughput driver produced non-reproducible '$field' between its own two timed samples ($v0 vs $v1)" >&2
    exit 1
  fi
done
echo "run_throughput.sh: both tools reproduced consistent output/counts across their own two timed samples." >&2

# ---- 6. Report ----
mean_scrubbed=$(python3 -c "print(f'{(${scrubbed_seconds[0]} + ${scrubbed_seconds[1]}) / 2:.4f}')")
mean_scrubbed_cpu=$(python3 -c "print(f'{(${scrubbed_cpu_seconds[0]} + ${scrubbed_cpu_seconds[1]}) / 2:.4f}')")
mean_model_load=$(python3 -c "print(f'{(${python_model_load[0]} + ${python_model_load[1]}) / 2:.4f}')")
mean_loop=$(python3 -c "print(f'{(${python_loop[0]} + ${python_loop[1]}) / 2:.4f}')")
mean_loop_cpu=$(python3 -c "print(f'{(${python_loop_cpu[0]} + ${python_loop_cpu[1]}) / 2:.4f}')")
mean_python_amortized=$(python3 -c "print(f'{${mean_model_load} + ${mean_loop}:.4f}')")

scrubbed_docs_per_sec=$(python3 -c "print(f'{$replicated_count / ${mean_scrubbed}:.2f}')")
scrubbed_kib_per_sec=$(python3 -c "print(f'{$replicated_bytes / ${mean_scrubbed} / 1024:.1f}')")
python_steady_docs_per_sec=$(python3 -c "print(f'{$replicated_count / ${mean_loop}:.2f}')")
python_steady_kib_per_sec=$(python3 -c "print(f'{$replicated_bytes / ${mean_loop} / 1024:.1f}')")
python_amortized_docs_per_sec=$(python3 -c "print(f'{$replicated_count / ${mean_python_amortized}:.2f}')")
python_amortized_kib_per_sec=$(python3 -c "print(f'{$replicated_bytes / ${mean_python_amortized} / 1024:.1f}')")

speedup_steady_state=$(python3 -c "print(f'{${mean_loop} / ${mean_scrubbed}:.2f}')")
speedup_amortized=$(python3 -c "print(f'{${mean_python_amortized} / ${mean_scrubbed}:.2f}')")
# CPU-time speedup: robust to scheduling-delay contamination from other
# processes competing for CPU on this host, unlike the wall-clock figures
# above. Compare the two to see how much load contaminated this run.
speedup_steady_state_cpu=$(python3 -c "print(f'{${mean_loop_cpu} / ${mean_scrubbed_cpu}:.2f}')")
scrubbed_wall_vs_cpu_pct=$(python3 -c "print(f'{(${mean_scrubbed} - ${mean_scrubbed_cpu}) / ${mean_scrubbed_cpu} * 100:.1f}')")
python_wall_vs_cpu_pct=$(python3 -c "print(f'{(${mean_loop} - ${mean_loop_cpu}) / ${mean_loop_cpu} * 100:.1f}')")

cat <<REPORT

======== examples/pipeline-benchmark/run_throughput.sh report ========
Source corpus: $corpus_count pages (examples/pipeline-benchmark/corpus/; see
  NOTICE.md/manifest.json -- unmodified, no new content vendored).
Replicated corpus: $replicated_count files (${replicas}x replication of the
  same $corpus_count pages, unique filenames), $replicated_bytes bytes, at
  $replicated_dir.

--- scrubbed matched four-task pipeline (single warm process; 2 samples) ---
fix-mojibake -> html-main-content -> language-id-detect -> pii-four-class
samples: ${scrubbed_seconds[0]}s, ${scrubbed_seconds[1]}s (mean wall ${mean_scrubbed}s, mean cpu ${mean_scrubbed_cpu}s)
throughput: ${scrubbed_docs_per_sec} docs/s, ${scrubbed_kib_per_sec} KiB/s
Reproduced byte-identical output across its own two timed samples.

--- python chain via throughput_driver.py (single warm process; 2 samples) ---
one-time model/engine construction (isolated, NOT included in loop timing):
  samples: ${python_model_load[0]}s, ${python_model_load[1]}s (mean ${mean_model_load}s)
steady-state loop (excludes the one-time cost above):
  samples: ${python_loop[0]}s, ${python_loop[1]}s (mean wall ${mean_loop}s, mean cpu ${mean_loop_cpu}s)
  throughput: ${python_steady_docs_per_sec} docs/s, ${python_steady_kib_per_sec} KiB/s
amortized-with-startup (one-time cost + loop, as a single process would see it once):
  mean total: ${mean_python_amortized}s
  throughput: ${python_amortized_docs_per_sec} docs/s, ${python_amortized_kib_per_sec} KiB/s
Reproduced consistent doc_count/total_bytes/PII totals across its own two
timed samples (no output tree to hash: this driver processes everything
in memory).

--- Speedup: scrubbed vs. python, two different denominators ---
steady-state, wall-clock (loop time only, startup excluded):  ${speedup_steady_state}x
steady-state, CPU time (robust to other load on this host):   ${speedup_steady_state_cpu}x
amortized-with-startup (one-time cost included, wall-clock):  ${speedup_amortized}x

wall-vs-CPU divergence this run (large values mean this host had other
load competing for CPU while this ran -- trust the CPU-time speedup above
over the wall-clock ones when this is large):
  scrubbed: ${scrubbed_wall_vs_cpu_pct}%    python steady-state: ${python_wall_vs_cpu_pct}%

These numbers are reported side by side deliberately: run.sh's own
per-file-subprocess methodology pays the one-time Python startup/model-load
cost on every single page, which inflates its reported gap. This script
shows how much of that gap is genuinely steady-state per-call speed
(the "steady-state" ratios above) versus how much was process-startup
overhead specific to that comparison shape (the difference between the
wall-clock steady-state and amortized ratios). Neither number is rounded
up or presented as better than observed; if the steady-state ratio is much
smaller than run.sh's own reported figure, that is the honest result, not
an error. CPU time (via /usr/bin/time's user+sys, and Python's own
resource.getrusage for its in-process loop) isolates actual compute from
scheduling-delay noise, so it stays meaningful even when this host has
other concurrent work running -- confirmed to matter in practice (see
benchmarks/mojibake_scale.d's commit history for a worked example where
wall-clock alone would have understated a speedup by ~50% under load).

Full intermediate artifacts are kept under: $work_root
=======================================================================
REPORT
echo "run_throughput.sh: done." >&2
