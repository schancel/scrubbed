# Pipeline benchmark: scrubbed vs. an equivalent Python chain

This example runs the real `scrubbed clean-web-document` command against a
small, fixed, checked-in corpus of real web pages, and compares it end to
end against an equivalent, pinned Python chain: `ftfy` -> `trafilatura` ->
`langdetect` -> Presidio (no deduplication step -- see "Scope" below).

It gives you a reproducible way to run both pipelines yourself over the same
input and see real wall-clock timing and a correctness/agreement summary,
without needing any context beyond what's in this directory.

**Read [`NOTICE.md`](NOTICE.md) before using this corpus.** The 20 pages
under `corpus/` are real, unmodified, third-party web pages, permanently
checked into this repository's git history under a deliberate,
owner-accepted redistribution-risk decision. They are not licensed by this
project, and copyright in their content belongs to their original
publishers. `manifest.json` records each file's real source URL, fetch
method (live fetch, or a trafilatura-pinned-cache backfill for 6 pages that
have since suffered link rot -- see "Corpus provenance and completeness"
below), fetch date, and SHA-256.

## What this is not

- **Not a canonical benchmark standard.** This is one small, disclosed
  comparison over one small, fixed corpus -- not a claim that this is *the*
  way to measure corpus-cleaning quality or speed.
- **Not a dedup benchmark.** The Python side stops at Presidio; deduplication
  is explicitly out of scope for this comparison (there is no single obvious
  canonical Python dedup tool the way ftfy/trafilatura/langdetect/Presidio
  are obvious per-category choices).
- **Not the same thing as `experiments/html_main_content/fetch_held_out.sh`.**
  That script fetches real pages *transiently*, for test-only comparator use,
  and never vendors them into git. This directory's `corpus/` is a separate,
  new, permanently-checked-in mechanism under its own accepted risk. See
  `NOTICE.md` for the full distinction.
- **Not a claim that Python's one-time model-load cost never matters in
  practice.** `run_throughput.sh` (see "Steady-state throughput" below)
  isolates the large-corpus, warm-process case specifically. For a small or
  bursty job -- a handful of documents per invocation, a fresh process per
  request -- that one-time cost is real and is exactly what `run.sh`'s own
  per-file-subprocess timing already measures.

## Requirements

- A clone of this repository.
- `dub` and `ldc2` (to build the real `scrubbed` release binary and a small
  scoring helper).
- [`uv`](https://docs.astral.sh/uv/) (to create pinned, isolated Python
  virtual environments -- nothing is installed into your system Python).
- `curl`, `python3`, `shasum`, and a POSIX shell (`bash`). Tested against
  macOS's stock `/bin/bash` (3.2) -- no newer bash is required.
- Internet access, to install the pinned Python packages (`ftfy==6.3.1`,
  `trafilatura==2.2.0`, `langdetect==1.0.9`,
  `presidio-analyzer`/`presidio-anonymizer==2.2.364`, and the
  `en_core_web_sm` spaCy model). The corpus itself is already checked into
  the repository; running this example does not re-fetch any web pages.

## Running it

```sh
git clone https://github.com/schancel/scrubbed.git
cd scrubbed
examples/pipeline-benchmark/run.sh
```

The script prints its work directory (a fresh temporary directory by
default) and keeps every intermediate artifact there after it finishes, so
you can inspect individual outputs. You can also pass your own directory:

```sh
examples/pipeline-benchmark/run.sh /tmp/my-pipeline-benchmark-run
```

The first run installs four pinned Python virtual environments (`uv venv` +
`uv pip install`, one per tool, matching the exact pattern already used by
[`benchmarks/README.md`](../../benchmarks/README.md)'s "Shared external-tool
comparator" section) and builds the real `scrubbed` binary via
`dub build --build=release --compiler=ldc2`. Subsequent runs reuse an
existing `dub` build and, if you reuse the same work directory, the same
venvs.

## What it does

1. **Builds** the real, release-optimized `scrubbed` binary.
2. **Times both whole pipelines**, interleaved A/B/A/B (scrubbed, python,
   scrubbed, python) over the full 20-page corpus, matching
   [`benchmarks/external_comparator.d`](../../benchmarks/external_comparator.d)'s
   own interleaving methodology (this avoids cold-cache/ordering bias
   between the two tools):
   - **scrubbed**: `scrubbed clean-web-document --input corpus/ --output OUT`
     -- the shipped, fixed `clean-web-document/v1` preset:
     `text-transform(fix-mojibake)` -> `html-metadata-annotate` ->
     `html-main-content` -> `pii-four-class`.
   - **python chain**: for each page, `ftfy --preserve-entities -n none`
     piped into `trafilatura --output-format txt`, then that extracted text
     is classified by `langdetect` (via the existing pinned
     [`benchmarks/langdetect_driver.py`](../../benchmarks/langdetect_driver.py))
     and scanned by Presidio (via the existing pinned
     [`benchmarks/presidio_driver.py`](../../benchmarks/presidio_driver.py)),
     scoped to exactly the same four categories `pii-four-class` implements
     (email/phone/card/ip).
   Each tool's own two timed samples are required to reproduce
   byte-identical output before any number is reported; a mismatch fails the
   run rather than silently reporting a bad number.
3. **Scores correctness/agreement**, reusing existing, already-validated
   scoring code rather than a new metric:
   - *ftfy-equivalent step*: exact-byte comparison, the same style
     `external_comparator.d`'s own `mojibake/scrubbed-vs-ftfy` case uses.
   - *main-content extraction*: word-level, case-normalized,
     whitespace-tokenized multiset overlap (issue #26's metric, imported
     unmodified from
     [`experiments/html_main_content/token_overlap.d`](../../experiments/html_main_content/token_overlap.d))
     between scrubbed's and trafilatura's extracted text on the same raw
     page.
   - *language-id*: agreement between scrubbed's `language-id-detect` stage
     (decoded via the same `domain.language_id.decodeLanguageIdentity`
     `external_comparator.d` uses) and `langdetect`, each classifying its
     own upstream extraction.
   - *PII*: per-category (email/phone/card/ip) finding-count comparison
     between `pii-four-class` and Presidio, each scanning its own upstream
     extraction.

   None of this real corpus has authored gold labels (unlike
   `external_comparator.d`'s own fixture-based cases), so every correctness
   number here is a **descriptive agreement/disagreement observation between
   the two tools**, never a precision/recall claim against ground truth, and
   nothing here is pass/fail-gated.

## Interpreting the output

- **Timing**: `scrubbed clean-web-document` runs the whole corpus through a
  compiled, single-process, multi-threaded native binary; the Python chain
  spawns a fresh Python interpreter (twice -- once for `langdetect`, once for
  Presidio/spaCy) per page in a shell loop. Expect scrubbed to be
  substantially faster in wall-clock terms; that gap says more about
  process-startup and interpreter overhead in this specific comparison shape
  than about the underlying libraries' own per-call speed.
- **`html-main-content` abstentions**: `pii-four-class`'s upstream
  `html-main-content` stage legitimately declines to select a main-content
  region for some real pages (see
  [`docs/html-main-content.md`](../../docs/html-main-content.md)). Pages
  that abstain contribute no main-content/language-id/PII agreement row;
  the report states how many pages abstained, and this is expected content-
  driven behavior, not a crash.
- **Low ftfy-equivalent byte-match rate**: `ftfy`'s default fixes are
  intentionally broader than scrubbed's narrowly-scoped `fix-mojibake`
  filter -- for example, ftfy normalizes line breaks (CRLF/CR to LF) as part
  of its default `fix_text` behavior, which real-world HTML in this corpus
  uses heavily, while `fix-mojibake` does not touch line endings at all. A
  low byte-identical match count on this real corpus is an expected,
  disclosed observation about what each tool actually does, not evidence
  that either tool is broken. `benchmarks/external_comparator.d`'s own
  mojibake case uses a synthetic fixture specifically designed to make the
  two outputs byte-identical; this real corpus was not curated that way.
- **PII counts**: both tools are scoped to the same four categories
  (email/phone/card/ip); a nonzero difference on this small, real, 20-page
  corpus is a real, disclosed observation, not a defect report -- there is
  no accepted numeric target for either tool here, matching
  `external_comparator.d`'s own stance on its fixture-based PII case.

## Steady-state throughput (warm process, corpus-scale)

`run.sh`'s own timing above spawns a fresh Python interpreter **twice per
page** (once for `langdetect_driver.py`, once for `presidio_driver.py`), each
paying full interpreter-startup plus, on the Presidio side, a one-time spaCy
`en_core_web_sm` model load. The "Interpreting the output" section above
already discloses that this "says more about process-startup and interpreter
overhead in this specific comparison shape than about the underlying
libraries' own per-call speed" -- but `run.sh` alone does not tell you how
much of its reported gap is that startup cost versus genuine steady-state
per-call speed once Python is warm. `run_throughput.sh` is a complementary
sibling script that answers exactly that question: it runs the whole
ftfy -> trafilatura -> langdetect -> Presidio chain in **one warm Python
process** via [`throughput_driver.py`](throughput_driver.py), amortizing the
one-time import/model-load cost over a corpus-scale number of documents
instead of paying it per file.

It reuses the same 20-page corpus at `corpus/`, replicated into uniquely
named copies in a scratch directory to reach a file count (400, by default)
large enough that the one-time cost stops dominating total wall time.
**No new third-party content is fetched or vendored by this script** -- see
[`NOTICE.md`](NOTICE.md) for the corpus's existing redistribution-risk
decision, which this script does not reopen or expand.

Run it with:

```sh
examples/pipeline-benchmark/run_throughput.sh [WORK_DIR]
```

It builds the real `scrubbed` release binary (same step as `run.sh`), builds
one combined pinned Python venv (all five pinned packages together, since
`throughput_driver.py` imports them all into a single process), times each
tool twice over the replicated corpus, and reports:

- **scrubbed's throughput** (docs/s, KiB/s) -- a single warm process either
  way, so there is no startup-amortization question on this side.
- **The Python side's one-time model/engine construction cost**, isolated
  and reported separately (`throughput_driver.py` measures this itself,
  before its per-file loop starts).
- **Python's steady-state throughput** (docs/s, KiB/s), excluding that
  one-time cost -- what you'd see in the middle of a long-running batch job.
- **Python's amortized-with-startup throughput**, i.e. the one-time cost
  folded back in as a single process would experience it once.
- Two separate speedup ratios, side by side: **steady-state** (loop time
  only) and **amortized-with-startup** (one-time cost included), so you can
  see directly how much of `run.sh`'s own reported gap is process-startup
  overhead specific to its per-file-subprocess comparison shape, versus
  genuine steady-state per-call speed. Neither ratio is rounded up or
  presented as better than observed.

A live run on this corpus (20 pages replicated 20x to 400 files,
Apple M4/macOS) measured scrubbed's two samples at 0.59s and 0.21s
(mean 0.40s) against `throughput_driver.py`'s one-time model/engine
construction cost at 2.11s and 1.02s (mean 1.57s) and steady-state loop
time at 57.75s and 59.82s (mean 58.78s) -- a steady-state speedup of about
148x and an amortized-with-startup speedup of about 152x. The steady-state
number is *not* dramatically smaller than the amortized one here, because
the one-time Python cost (about 1.5 seconds) is small relative to 400 real
documents' worth of processing (nearly a minute); this is the expected shape
for a large-corpus, warm-process run, and is a separate observation from
`run.sh`'s own smaller, per-file-subprocess-dominated corpus. (Run-to-run
variance is real here -- an earlier sample on the same host measured
152x/156x; both are genuine, reproduced-within-their-own-run results, not a
discrepancy to resolve.)

## Corpus provenance and completeness

See [`manifest.json`](manifest.json) for the exact source URL, fetch method,
fetch date, HTTP status, and SHA-256 of every checked-in page, and
[`NOTICE.md`](NOTICE.md) for the redistribution-risk decision this corpus
was built under. The corpus reuses the same 20 URLs already pinned in
[`experiments/html_main_content/fetch_held_out.sh`](../../experiments/html_main_content/fetch_held_out.sh)
(itself pinned at `adbar/trafilatura` commit
`1e31e3e9eb2e4f6fbfd4bc04355bc74005a780e6`) as its source list. As of the
fetch date, 6 of those 20 URLs had suffered real link rot (dead pages, a dead
domain, and a domain now serving an unrelated TLS certificate) and could not
be fetched live; those 6 pages instead come from `adbar/trafilatura`'s own
bundled eval-corpus copy of the same URL at the exact commit above -- the
same trust/provenance source `fetch_held_out.sh` already relies on for these
exact pages, read as a stored file instead of a now-dead live request. Every
artifact entry in `manifest.json` states which of the two fetch methods
(`live` or `trafilatura-pinned-cache`) produced it, and the 6 backfilled
entries additionally cite the exact repository path the bytes came from. See
`manifest.json`'s `fetchOutcomeSummary` and `linkRotFindings` fields for the
exact list.
