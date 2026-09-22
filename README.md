# scrubbed

A text-sanitization CLI in D: mojibake/encoding repair, normalization, and
opt-in mechanical HTML->Markdown conversion, composed as a pluggable filter
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
./scrubbed extract --input page.html --output page.md --format markdown --max-html-bytes 1048576
./scrubbed extract --input page.html --output page.md --format markdown --config html-extract.json
./scrubbed run --input - --output - --jsonl-fields text,title --dataset-namespace corpus-v1 --source-key shard-0001 --max-jsonl-line-bytes 1048576 --max-jsonl-output-bytes 2097152 < input.jsonl > clean.jsonl
./scrubbed errors-init --journal path/to/errors-v2.db
./scrubbed run --input path/to/docs --output path/to/clean --filters normalize-line-endings --error-journal path/to/errors-v2.db
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

A pure [canonical v3 job specification](docs/job-spec-v3.md) now models
stable stage instances, registered implementations, ordered filters, and
typed options identically for JSON and ordered CLI tokens. It is the migration
target, not a shipping input yet; the commands above continue to use the
documented predecessor forms until #148's execution switch is reviewed. The
filter registry now has an injectable typed-schema path for that compiler;
`fix-mojibake` is migrated while retaining its exact predecessor adapter. The
pure compiler now resolves injected stage/filter registries and canonical job
identity. Its pure one-stage executor proves declared before/after filter
placement over checked content, but the shipping commands do not use the v3
job or expose its flags yet.

For `extract`, `--max-html-bytes` sets one raw-input and decoded-UTF-8 cap
(default 1,048,576; maximum 8,388,608). Alternatively, `extract --config` reads a
v2 JSON config containing exactly one `html-tree-json` or `html-markdown` stage
matching `--format`; its `options` may include `max-html-bytes` and `charset`.
The extract config is distinct from `run`'s filter-chain config, and cannot be
combined with extract's `--max-html-bytes` or `--charset` flags. Raising the cap
does not raise the separate tree/Markdown output limits or guarantee a native
parser memory ceiling.

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
The optional existing-v2 `--error-journal` records sanitized local file/tree
failures and publication intent; add `--error-retry` only when explicitly
reprocessing unresolved output. Add `--error-targeted` with both flags to
retry only outstanding local-primary file/tree targets; changed input or
configuration is refused before output mutation. Non-seekable sources and
other sinks are not selected by this mode. The default remains the v1 path.
Exported error-event JSONL and its SHA-256 sidecar are individually atomically
replaced, not an atomic pair. See the [error journal guide](docs/error-events.md).
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
control-character, and quote transforms register bounded scalar transducers.
Consecutive transducers are fused by the registry into one caller-owned
Voldemort range traversal and one final string materialization; contextual
filters remain explicit materialization barriers. Mojibake candidates compose
a lazy legacy-byte Voldemort range with Phobos's strict UTF-8 decoder, so rejected candidates are scored
without allocation and only a winning repair is materialized. This removes
intermediate whole-string buffers for the three scalar filters, not the final
output allocation or whole-document requirements of contextual algorithms.

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
shipping `run`/`repair` path defaults to the v1 ledger. An [opt-in v2 failure
journal](docs/error-events.md), explicit CLI init/copy/export/verify commands,
and bounded JSONL history/outstanding export with SHA-256 sidecars now exist;
`--error-journal` and `--error-retry` select live local file/tree v2 processing.
An [opt-in independent local-sinks adapter](docs/independent-sinks.md) can
commit caller-supplied content and metadata payloads separately. The
[`route-metadata` CLI](docs/metadata-route.md) now feeds it filtered HTML
content and [deterministic stage-derived metadata](docs/metadata-extraction.md)
for title, author, date, and URL under mirrored local output paths; paired
input and model extraction are not required. The
[C01 shard API](docs/document-shards.md) now also has opt-in
[quality-decision](docs/quality-annotations.md) and
[exact-byte dedup](docs/exact-dedup.md) overlay facades. A bounded
[structured-chunk facade](docs/structured-chunks.md) emits stable byte-offset
chunks and canonical JSONL from caller-supplied paragraph/section/page spans;
process-isolated maximum-payload and maximum-chunk-count checks enforce a
256-MiB RSS ceiling, but no CLI path invokes it. A bounded
[four-class PII scanner](docs/pii-patterns.md) is a pure D API with an
[opt-in C01 findings overlay](docs/pii-annotations.md) and a
[pure report/mask/opt-in redact policy](docs/pii-policy.md) plus a
[revision-bound C01 policy overlay](docs/pii-policy-overlay.md), not CLI
redaction or complete de-identification.
None of these APIs establishes
corpus-scale throughput or main-content extraction.

## Status

Phases 0-2 are usable within the documented scope; JSON configuration from
Phase 3 is implemented. See `TODO.md` for precise coverage and remaining work.
The [release execution plan](docs/release-execution-plan.md) orders the work
from one canonical CLI/JSON document pipeline through transform completeness,
quality-matched optimization, and clean-machine packages; direct S3 and
distributed execution are not on the first-release critical path.
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
The first whole-CLI baseline was sobering: on one synthetic 4,096-line
mojibake input, scrubbed took roughly 3 seconds versus roughly 0.16 seconds
for pinned ftfy. Profiling exposed a scorer hot path; after optimizing it, a
separate `-O3` exact-output run on 131,072 repeated mojibake lines measured
scrubbed at 0.152–0.156 s versus ftfy at 3.698–4.076 s after a second
profile-guided source pass. That pass added an ASCII fixed-point scan, folded
plausibility into one Unicode traversal, classified each scalar once, and
materialized an already-validated legacy-byte range without decoding and
re-encoding it. That is a task-specific
result, not a broad corpus speed claim; see [benchmark details](benchmarks/README.md).
A newer [quality-gated local pipeline harness](docs/benchmark-pipeline.md)
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
Direct object-store credentials and transport are deliberately deferred;
near-term deployments should stage local files/manifests with a specialized
parallel transfer tool. Any future adapter must preserve record framing rather
than treating concatenated multi-object stdout as document boundaries.
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
