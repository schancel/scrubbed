"""Warm, single-process driver for examples/pipeline-benchmark/run_throughput.sh
(issue #315's steady-state-throughput follow-up to run.sh).

run.sh's own README already discloses its timing methodology's biggest
confound: it spawns a fresh Python interpreter *twice per page* (once for
`benchmarks/langdetect_driver.py`, once for `benchmarks/presidio_driver.py`),
each paying full interpreter startup plus, for the Presidio process,
spaCy `en_core_web_sm` model load -- a one-time cost repeated on every single
page. That says more about process-startup/interpreter overhead in that
specific comparison shape than about ftfy/trafilatura/langdetect/Presidio's
own per-call speed once warm. This driver isolates that one-time cost from
steady-state throughput: it imports every pinned library exactly once, builds
the Presidio analyzer (which triggers the spaCy model load) exactly once, and
then loops over every `.html` file under a directory (argv[1], intended to be
a replicated-N-times copy of the same 20-page corpus at
examples/pipeline-benchmark/corpus/ -- see NOTICE.md; no new third-party
content is read, fetched, or vendored by this file) entirely in one warm
process, running the same four-stage chain run.sh's per-file subprocess loop
runs: ftfy repair -> trafilatura extraction -> langdetect -> Presidio.

Reused, not reimplemented, from this repository's existing pinned drivers:
  - benchmarks/presidio_driver.py's `build_analyzer()` (the exact same
    Email/Phone/CreditCard/Ip-only `RecognizerRegistry` scoping, small
    `en_core_web_sm` model, same `TARGET_ENTITIES`/`CATEGORY_NAME` tables) is
    imported directly and called once, so PII scoping cannot silently drift
    between this benchmark and run.sh's.
  - benchmarks/langdetect_driver.py is imported directly for its own
    module-level `DetectorFactory.seed = 0` (required: langdetect's algorithm
    is not otherwise deterministic run to run) and its already-imported
    `detect_langs`/`LangDetectException` names, for the same reason.
Both files have no import-time side effect beyond that determinism/scoping
setup (their `argv`-reading logic lives inside `main()`, guarded by
`if __name__ == "__main__":`), so importing them here is safe and does not
run their own CLI paths.

ftfy and trafilatura have no existing repo-local wrapper (run.sh shells out to
their real CLIs directly), so this file calls their *library* APIs directly,
verified against the installed ftfy==6.3.1/trafilatura==2.2.0 packages' own
CLI source (not assumed from memory) to reproduce run.sh's exact CLI
invocations with no output drift:
  - `ftfy --preserve-entities -n none` (ftfy/cli.py) builds
    `TextFixerConfig(unescape_html=False, normalization=None)` and calls
    `fix_file(file, encoding="utf-8", config=config)` on a binary-mode file
    object, decoding and fixing input line by line. This driver calls the
    same `ftfy.fix_file` on the same kind of binary-mode file object with the
    same `TextFixerConfig`, rather than `ftfy.fix_text` on a pre-decoded
    whole-file string, specifically to avoid any per-line-vs-whole-text
    behavioral drift from what the CLI actually does.
  - `trafilatura --output-format txt` (trafilatura/cli_utils.py's `examine`)
    resolves to `trafilatura.extract(htmlstring, options=options)` where
    `options` is `Extractor(output_format="txt", ...)` with every other
    field at its CLI argparse default (`fast=False`, `formatting=None`,
    `precision=False`, `recall=False`, `comments=True`, `tables=True`,
    `images=False`, `links=False`, `dedup=False`, `lang=None`,
    `with_metadata=False`, `only_with_metadata=False`,
    `tei_validation=False`) -- exactly `trafilatura.extract(htmlstring,
    output_format="txt")`'s own defaults, verified field by field against
    trafilatura/settings.py's `args_to_extractor`/`Extractor.__init__`, so no
    named argument here diverges from an unstated CLI default. The CLI reads
    its input as raw bytes (`sys.stdin.buffer.read()`), so this driver
    encodes the ftfy-fixed text back to UTF-8 bytes before calling
    `trafilatura.extract`, matching what the real CLI process actually
    receives on its stdin.

Usage:
  throughput_driver.py CORPUS_DIR

Prints two machine-parseable lines to stdout:
  THROUGHPUT_DRIVER_ONE_TIME model_load_seconds=... import_seconds=...
    analyzer_build_seconds=...
  THROUGHPUT_DRIVER_LOOP loop_seconds=... doc_count=... total_bytes=...
    docs_per_sec=... kib_per_sec=... extraction_failures=... lang_errors=...
    pii_email=... pii_phone=... pii_card=... pii_ip=...

The one-time line is printed, and its underlying `time.monotonic()` samples
taken, strictly before the per-file loop starts; the loop line's timing
excludes every one-time cost. The caller (run_throughput.sh) is responsible
for reporting both numbers separately rather than conflating them into one
"total" figure that would hide how much of run.sh's already-disclosed ~139x
gap is startup cost rather than steady-state per-call speed.
"""
import os
import sys
import time

# First executable statement: every import below this line (including the
# heavy ftfy/trafilatura/langdetect/presidio_analyzer libraries and, via
# presidio_driver, spaCy itself) is timed as this process's one-time
# "import_seconds" cost, measured before any file is read.
_t_process_start = time.monotonic()

import ftfy  # noqa: E402
from ftfy import TextFixerConfig  # noqa: E402
import trafilatura  # noqa: E402

_benchmarks_dir = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "benchmarks"
)
if _benchmarks_dir not in sys.path:
    sys.path.insert(0, _benchmarks_dir)

import langdetect_driver  # noqa: E402  (sets DetectorFactory.seed = 0 as an import-time side effect; reused unmodified, not reimplemented)
import presidio_driver  # noqa: E402  (build_analyzer()/TARGET_ENTITIES/CATEGORY_NAME reused unmodified, not reimplemented)

_t_imports_done = time.monotonic()

# Mirrors `ftfy --preserve-entities -n none` exactly -- see the module
# docstring above for the exact ftfy/cli.py flag-to-config mapping this was
# verified against.
FTFY_CONFIG = TextFixerConfig(unescape_html=False, normalization=None)


def process_one(path: str, analyzer) -> tuple[int, bool, bool, dict]:
    """Run the full ftfy -> trafilatura -> langdetect -> presidio chain over
    one file, entirely in this already-warm process. Returns
    (byte_size, extraction_failed, lang_errored, pii_counts)."""
    byte_size = os.path.getsize(path)

    with open(path, "rb") as handle:
        fixed_text = "".join(
            ftfy.fix_file(handle, encoding="utf-8", config=FTFY_CONFIG)
        )

    extracted = trafilatura.extract(fixed_text.encode("utf-8"), output_format="txt")
    extraction_failed = extracted is None
    if extraction_failed:
        # Matches what a real trafilatura CLI process piped through an empty
        # stdout would leave behind on disk: an empty text file for the
        # downstream stages to read.
        extracted = ""

    lang_errored = False
    try:
        langdetect_driver.detect_langs(extracted)
    except langdetect_driver.LangDetectException:
        lang_errored = True

    pii_counts = {"email": 0, "phone": 0, "card": 0, "ip": 0}
    try:
        results = analyzer.analyze(
            text=extracted, entities=presidio_driver.TARGET_ENTITIES, language="en"
        )
    except Exception:
        results = []
    for result in results:
        category = presidio_driver.CATEGORY_NAME.get(result.entity_type)
        if category is not None:
            pii_counts[category] += 1

    return byte_size, extraction_failed, lang_errored, pii_counts


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: throughput_driver.py CORPUS_DIR", file=sys.stderr, flush=True)
        return 2
    corpus_dir = sys.argv[1]
    try:
        names = sorted(f for f in os.listdir(corpus_dir) if f.endswith(".html"))
    except OSError as error:
        print(f"throughput_driver.py: {error}", file=sys.stderr, flush=True)
        return 2
    if not names:
        print(
            f"throughput_driver.py: no .html files found under {corpus_dir}",
            file=sys.stderr,
            flush=True,
        )
        return 2

    # ---- One-time model/engine construction (measured before the loop) ----
    t_analyzer_start = time.monotonic()
    analyzer = presidio_driver.build_analyzer()
    t_analyzer_done = time.monotonic()

    import_seconds = _t_imports_done - _t_process_start
    analyzer_build_seconds = t_analyzer_done - t_analyzer_start
    model_load_seconds = import_seconds + analyzer_build_seconds

    print(
        f"THROUGHPUT_DRIVER_ONE_TIME model_load_seconds={model_load_seconds:.6f} "
        f"import_seconds={import_seconds:.6f} "
        f"analyzer_build_seconds={analyzer_build_seconds:.6f}",
        flush=True,
    )

    # ---- Steady-state loop (timed separately; excludes everything above) ----
    total_bytes = 0
    doc_count = 0
    extraction_failures = 0
    lang_errors = 0
    pii_totals = {"email": 0, "phone": 0, "card": 0, "ip": 0}

    t_loop_start = time.monotonic()
    for name in names:
        path = os.path.join(corpus_dir, name)
        byte_size, extraction_failed, lang_errored, pii_counts = process_one(
            path, analyzer
        )
        total_bytes += byte_size
        doc_count += 1
        if extraction_failed:
            extraction_failures += 1
        if lang_errored:
            lang_errors += 1
        for category, count in pii_counts.items():
            pii_totals[category] += count
    t_loop_done = time.monotonic()

    loop_seconds = t_loop_done - t_loop_start
    docs_per_sec = doc_count / loop_seconds if loop_seconds > 0 else float("inf")
    kib_per_sec = (
        (total_bytes / 1024.0) / loop_seconds if loop_seconds > 0 else float("inf")
    )

    print(
        f"THROUGHPUT_DRIVER_LOOP loop_seconds={loop_seconds:.6f} "
        f"doc_count={doc_count} total_bytes={total_bytes} "
        f"docs_per_sec={docs_per_sec:.4f} kib_per_sec={kib_per_sec:.4f} "
        f"extraction_failures={extraction_failures} lang_errors={lang_errors} "
        f"pii_email={pii_totals['email']} pii_phone={pii_totals['phone']} "
        f"pii_card={pii_totals['card']} pii_ip={pii_totals['ip']}",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
