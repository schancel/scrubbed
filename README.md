# scrubd

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
  leave it alone" (their own docs report under 1 false positive per
  million tweets). `source/filters/mojibake.d` has the *mechanical* half
  done correctly (the reversible round-trip transform for Latin-1/CP1252
  mis-decoding, CP1252's table verified against the Unicode Consortium's
  own mapping file) — the scoring heuristic that decides which candidate
  fix is actually right is **not implemented yet**. See the TODO in that
  file.
- trafilatura does DOM-based main-content extraction with boilerplate
  removal (nav bars, ads, footers) — genuinely harder than HTML->Markdown
  conversion, which is the more tractable thing actually planned here
  (`source/filters/html2md.d`, currently an unimplemented stub).

What *is* real and working right now: a pluggable filter-registry
pipeline, a CLI that walks an input directory tree and mirrors it to an
output path, parallel processing across files via `std.parallelism`'s
`TaskPool` (real OS threads, not Fibers — see the note in `app.d` on why),
zero-copy reads via `std.mmfile.MmFile`, and two working normalization
filters (line-ending normalization, control-character stripping).

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
./scrubd --list-filters
./scrubd --input path/to/docs --output path/to/clean --filters normalize-line-endings,strip-control
```

`--filters` is a comma-separated, ordered chain of registered filter
names. New filters register themselves via `static this()` in their own
module (see `filters/normalize.d`) — nothing in `app.d` or `pipeline.d`
needs to change to add one.

## Status

Early scaffold. See `TODO.md` for the actual roadmap and what's real vs.
stubbed.
