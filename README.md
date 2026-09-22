# scrubbed

A text-sanitization CLI in D: mojibake/encoding repair, normalization, and
(eventually in the CLI) HTML->Markdown conversion, composed as a pluggable filter
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
  encodings, lossy repairs, and general mixed-encoding detection are not covered.
  A conservative local path now repairs evidenced Latin-1/CP1252 mojibake
  spans beside emoji or other scripts while leaving ambiguous spans alone;
  this is not a general span detector or a demonstrated speedup.
- trafilatura does DOM-based main-content extraction with boilerplate
  removal (nav bars, ads, footers) — genuinely harder than mechanical
  HTML->Markdown conversion. A bounded pure converter now exists in
  `source/effects/html_markdown.d`, exposed by the opt-in
  `extract --format=markdown` route. The older `source/filters/html2md.d`
  remains an unregistered stub, not a second Markdown path.

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
./scrubbed --input path/to/docs --output path/to/clean --threads 4 --max-queued-docs 64 --max-input-bytes 268435456 --max-open-inputs 4
./scrubbed --input path/to/docs --output path/to/clean --config scrubbed.example.json --dry-run --explain
./scrubbed repair --input path/to/docs --output path/to/clean --dry-run --explain
./scrubbed extract --input page.html --output page.tree.json --format tree-json
./scrubbed extract --input page.html --output page.md --format markdown
./scrubbed run --input - --output - --jsonl-fields text,title --dataset-namespace corpus-v1 --source-key shard-0001 --max-jsonl-line-bytes 1048576 --max-jsonl-output-bytes 2097152 < input.jsonl > clean.jsonl
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

`--validate` checks the invocation, registered filter options, and roots
without visiting files or writing output. `--dry-run` runs per-file transforms
without creating output. `--explain` emits one bounded JSON-quoted, tab-separated
decision record per visited file; parallel record order is not fixed. See the
[inspection guide](docs/cli-inspection.md). A later traversal error can cancel
already-admitted files; those receive failure records, and the command exits 2.
`run` and `repair` also route to the implemented filter pipeline, with generated
help and command/option-name completion. `extract --format=tree-json` exports a
bounded selected HTML parse tree; `--format=markdown` mechanically renders that
tree without main-content selection. See the [HTML parser guide](docs/html-parser.md) and
[command guide](docs/cli-commands.md).
The explicit paired `--input - --output -` JSONL mode transforms selected
top-level text fields through the same filter chain. It requires a stable
dataset namespace, source key, and input/output record byte caps. Untouched
values are preserved semantically, not byte-for-byte or in original key order;
stdout contains records only. `--validate` does not read stdin and `--dry-run`
emits no stdout. It has no graceful cancellation, checkpoint, or restart
guarantee; OS termination can leave a partial current record. See the
[JSONL stream guide](docs/jsonl-stream.md).

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

For terabyte-scale corpora, mmap keeps input bytes out of the GC heap and the
CLI now walks paths incrementally through a bounded local task queue. Separate
limits cap queued documents, reserved input bytes, and concurrent file-work
callbacks; oversized files fail, and detected size changes are skipped. The
callback limit is not a count of every OS handle, and this is not a stable
input snapshot. Each file is still mapped as one region, output-producing
stages may materialize whole-file strings. Opt-in local file/tree restart uses
`--manifest PATH`; unflagged runs and JSONL streams have no durable resume.
The [bounded-input contract](docs/bounded-input.md) and `TODO.md` describe
the remaining scale-readiness gates. Scrubbed is not yet a proven
terabyte-scale engine.

Standalone POSIX effects now demonstrate [bounded mapped windows](docs/windowed-input.md)
and [atomic streaming of content pieces](docs/atomic-piece-output.md), including
a verified 1.075 GB output without an output-sized D allocation. Neither
effect is wired into the CLI or proves that context-heavy filters can stream.
A [statically linked local SQLite manifest](docs/local-manifest.md) now
records versioned per-sink state, verifies destination bytes before a skip,
and passes bounded replay and process-kill tests. Opt-in file/tree CLI
`--manifest PATH` serializes local work, records input/config/executable
identity, and requires explicit `--manifest-retry` for unresolved output;
unflagged and JSONL runs remain unchanged. This does not guarantee power-loss
durability, concurrent input snapshots, or bounded output materialization. The earlier
[SQLite experiment](docs/sqlite-manifest-evaluation.md) remains as prerequisite
evidence. SQLite stores the local run ledger, not the corpus or a distributed
coordinator.
The opt-in manifest path now applies a [typed file-failure policy](docs/failure-policy.md):
an isolated document failure may continue only after durable failed/uncertain
state and an injected acknowledgment; run-fatal policy, resource, and lost-ledger
errors stop with exit 2. Exit 1 means acknowledged failures or unresolved
retry decisions. Keyed `--explain` records distinguish these outcomes. The
concrete structured error-log file and replay format are still unimplemented.

## Status

Phases 0-2 are usable within the documented scope; JSON configuration from
Phase 3 is implemented. See `TODO.md` for precise coverage and remaining work.
The [architecture map](docs/architecture.md) and [filter guide](source/filters/README.md)
describe the current module boundaries. A typed document-identity and borrowed
view module, ordered borrowed/owned content-piece module with a lazy range,
standalone document stage contracts, a typed self-registering stage registry
and strict nested v2 config API, and typed source/parser/sink ports with a
per-document runner exist, but they are not yet wired into the CLI's v1
filter pipeline or its bounded local file scheduler. V2 is not a CLI mode.
The file-mapping opener now lives in the effects
layer; the CLI's own mmap path is unchanged. High-edit list scaling is not
ready for a throughput path. A D module-boundary check is under `scripts/`.
The document model distinguishes original source IDs from derived-child IDs;
split stages now use the latter, without changing original source IDs.
A standalone [binary-v1 document shard and annotation-overlay API](docs/document-shards.md)
now provides bounded, integrity-checked frames, version/revision-checked joins,
create-only immutable source publication, and atomic replacement of one
overlay. Its release-active D tests cover ordering, corruption, aliases,
faults, and concurrent no-clobber publication. No CLI, analyzer, or SQLite
route uses these artifacts yet; this is not a corpus-scale storage claim.
The broader corpus-curation plan is tracked in
[GitHub issues](https://github.com/schancel/scrubbed/issues); accepted tickets do
not imply the features are implemented or worker-ready.

Reproducible D correctness and allocation microbenchmarks, including the
reconstructed pre-range mojibake implementation, are under `benchmarks/`.
The D-only per-fix text corpus adds small exact-output and clean-preservation
gates; its two clean examples per fix are not a population-level false-positive
estimate.
The first whole-CLI baseline there is sobering: on one synthetic 4,096-line
mojibake input, scrubbed took roughly 3 seconds versus roughly 0.16 seconds
for pinned ftfy. That is not a corpus-wide comparison, but it rules out a
current blanket speed claim. A newer [quality-gated local pipeline harness](docs/benchmark-pipeline.md)
adds small-tree first/skip/retry runs, a real planned-row kill/restart probe,
and an exact-output CRLF task comparison with pinned dos2unix. A second,
capacity-gated D run adds matched many-small/few-large 16 MiB and 128 MiB
local trees with repeated samples, exact-output gates, and process CPU/RSS
measurements. It does not establish broad speed parity; larger-than-RAM,
OS-cold, FD/GC/syscall-byte metrics, and HTML extraction comparisons remain open.

An [evidence-only native HTML parser evaluation](docs/html-parser-evaluation.md)
compares pinned Lexbor and Gumbo on authored cases, then tests one pinned public
standards page through owned UTF-8 decoding, bounded Lexbor observations,
sanitizers, and a full LICENSE/NOTICE bundle dry run. Pinned Lexbor source,
a static archive, and a [restricted D-owned selected-tree wrapper](docs/html-parser.md)
now exist with release-active ownership, cap, and exact accessor checks.
The shipping CLI now has bounded `extract --format=tree-json` and
`extract --format=markdown` routes, with real-binary goldens and self-registering
stages. Neither is main-content extraction or a trafilatura replacement. HTML charset
sniffing, broader page coverage, richer DOM fidelity, bounded native RSS,
other-platform builds, and extraction-quality benchmarks remain open.
A separately tested bounded converter maps that selected tree to mechanical
Markdown ([policy and limits](docs/html-markdown.md)).
An [evidence-only S3 capability evaluation](docs/s3-capability-evaluation.md)
tests fake credentials and local endpoint/TLS behavior. It is not a direct S3
client and has not been tested against AWS or a compatible object store.
An [evidence-only WARC/WET compression probe](docs/warc-reader-evaluation.md)
tests authored WARC 1.1 records in independent gzip members and proposed
zstd-WARC frames with bounded D/native decoding. A separate
[production uncompressed WARC/1.1 reader](docs/warc-reader.md) now handles
bounded, chunk-invariant records and a validated WET-style text view. Pinned
zstd v1.5.7 source and a static decompression archive now back
[bounded gzip/zstd WARC adapters](docs/warc-reader.md) with
checksum-before-callback and genuine compressed-block tests. A local-file API
now streams regular files through those readers in fixed-size chunks with
no-follow path checks; it is not wired into the shipping CLI. Common Crawl
WARC 1.0 compatibility, real-corpus coverage, and throughput claims remain open.
A [macOS arm64 text-core packaging probe](docs/package-core-evaluation.md)
checks an isolated binary, license/notice inventory, and clean-`PATH` execution.
It is not a release or proof of Linux/Windows support, HTML packaging, a fully
static binary, or bit-for-bit reproducible builds.
