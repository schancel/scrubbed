# scrubbed

A text-sanitization CLI in D: mojibake/encoding repair, normalization, and
(eventually) HTML->Markdown conversion, composed as a pluggable filter
pipeline and run in parallel across an input document tree.

## Why this exists, honestly

Inspired by [ftfy](https://github.com/rspeer/python-ftfy) (encoding repair)
and [trafilatura](https://github.com/adbar/trafilatura) (web text
extraction) — but this is **not** a drop-in replacement for either yet, and
being upfront about that matters more than sounding impressive:

- ftfy's real value isn't speed, it's years of tuned heuristics for
  distinguishing "this text is corrupted, fix it" from "this text is fine,
  leave it alone." scrubbed now has a conservative badness scorer for its
  Latin-1/Windows-1252 scope. Against the current ftfy JSON corpus it repairs
  all 39 passing cases mechanically reachable through those two encodings
  and preserves all 48 encoding-negative cases. It is still not ftfy: other
  encodings, lossy repairs, and localized mixed-encoding spans are not covered.
- trafilatura does DOM-based main-content extraction with boilerplate
  removal (nav bars, ads, footers) — genuinely harder than HTML->Markdown
  conversion, which is the more tractable thing actually planned here
  (`source/filters/html2md.d`, currently an unimplemented stub).

What *is* real and working right now: a pluggable filter-registry
pipeline, a CLI that walks an input directory tree and mirrors it to an
output path, parallel processing across files via `std.parallelism`'s
`TaskPool` (real OS threads, not Fibers — per-file work is CPU-parallel),
zero-copy reads via `std.mmfile.MmFile`, deterministic per-file mapping cleanup,
atomic output replacement, mojibake repair, entity decoding, smart-quote
normalization, and two basic normalization filters.
The entity decoder now includes all 2,231 WHATWG named references and explicit
text/attribute-value modes; it is still not an HTML tokenizer.
An independently tested strict UTF-8/UTF-16 byte-decoding facade also exists,
but is not yet wired into the CLI. It quarantines ambiguous, unsupported,
malformed, and binary-looking input rather than guessing an encoding.

## Why D

- Range-based, lazily-composed pipelines are one of D's most distinctive,
  well-executed features — `filters/normalize.d`'s `stripControlChars` is
  a real lazy range transform, not a buffer-copy pretending to be one.
- A single native binary with no runtime dependency (no `pip install
  lxml`/`cchardet` build chain) — easy to embed in a non-Python pipeline
  or invoke as a subprocess without interpreter-startup cost. (Empirically
  measured in a sibling project: a compiled D binary ran a comparable
  one-shot task in ~0.56s wall-clock vs. Python's much larger per-
  invocation interpreter/import overhead for the same scale of work.)
- Direct `extern(C)` FFI to fast C libraries when needed (e.g. a real HTML
  parser for `html2md.d`, or `ftfy`-equivalent statistical tables) with no
  binding-generation ceremony.

## Usage

```
dub build --build=release
./scrubbed --list-filters
./scrubbed --input path/to/docs --output path/to/clean --filters normalize-line-endings,strip-control
./scrubbed --input path/to/docs --output path/to/clean --config scrubbed.example.json
```

`--filters` is a comma-separated, ordered chain of registered filter
names. New filters register themselves via `static this()` in their own
module (see `filters/normalize.d`) — nothing in `app.d` or `pipeline.d`
needs to change to add one.

`--config` accepts JSON containing an ordered `filters` array. Entries may be
plain names or objects with `name` and `options`; see `scrubbed.example.json`.
`fix-mojibake` supports `encodings` (`latin1`, `cp1252`, or both) and
`max-passes`. Unknown option names are errors, and `--config` cannot be
combined with `--filters`. Put `uncurl-quotes` before it when typographic quotes surround
otherwise mojibaked text, because the current repair operates on whole-buffer
round-trip candidates rather than isolated spans.

Outputs are written beside their destination and atomically renamed into
place, so a clean zero-copy result is safe even when input and output are the
same path. Empty files are mirrored. Directory outputs must be outside the
input tree. It rejects symlink roots, symlink entries inside the input tree,
destination-file links, and links below the selected output root. Existing
POSIX ancestor links are resolved before containment checks; Windows ancestor
reparse points are rejected because lexical normalization cannot prove their
physical target. Any processing failure produces a nonzero exit status.

Input is already memory-mapped: the source `string` is a zero-copy view kept
alive by `MmFile`. Output-producing filters still allocate. The line-ending,
control-character, and quote transforms use composable lazy range/Voldemort
types internally. Mojibake candidates compose a lazy legacy-byte Voldemort
range with Phobos's strict UTF-8 decoder, so rejected candidates are scored
without allocation and only a winning repair is materialized. The type-erased
registry still materializes at each `string -> string` stage boundary.

For terabyte-scale corpora, mmap keeps input bytes out of the GC heap but does
not by itself make the full pipeline bounded-memory: each file is currently
mapped as one region, the complete path list is retained, and output-producing
stages may materialize whole-file strings. The explicit scale-readiness gates
in `TODO.md` cover windowed/chunked processing, bounded in-flight bytes and
descriptors, resumability, and benchmarks on datasets larger than RAM. Until
those pass, scrubbed is suitable for large collections of reasonably-sized
files, not yet a proven terabyte-scale engine.

## Status

Phases 0-2 are usable within the documented scope; JSON configuration from
Phase 3 is implemented. See `TODO.md` for precise coverage and remaining work.
The [architecture map](docs/architecture.md) and [filter guide](source/filters/README.md)
describe the current module boundaries. A typed document-identity and borrowed
view module and an ordered borrowed/owned content-piece module exist, but they
are not yet wired into the CLI or pipeline. A D module-boundary check is under
`scripts/`.
The broader corpus-curation plan is tracked in
[GitHub issues](https://github.com/schancel/scrubbed/issues); accepted tickets do
not imply the features are implemented or worker-ready.

Reproducible D correctness and allocation microbenchmarks, including the
reconstructed pre-range mojibake implementation, are under `benchmarks/`.
The first whole-CLI baseline there is sobering: on one synthetic 4,096-line
mojibake input, scrubbed took roughly 3 seconds versus roughly 0.16 seconds
for pinned ftfy. That is not a corpus-wide comparison, but it rules out a
current blanket speed claim. Full-pipeline, larger-than-RAM, and additional
quality-matched tool comparisons remain open.
