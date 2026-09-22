# Execution plan to the first public package release

This is the critical path for making scrubbed a single-binary replacement for
the common *local* corpus-curation tool chain. It deliberately excludes the
claims listed under **Deferred and integrated, not reimplemented** below. The
living implementation status remains in [`TODO.md`](../TODO.md); GitHub issues
own scoped contracts and review evidence.

## Release outcome

A user can describe one ordered document pipeline through either CLI flags or
JSON, run it over local files, directory trees, JSONL, or supported WARC/WET
inputs, and produce content plus independently routed metadata/annotations.
The same document bytes should not need to bounce through several Python
processes and intermediate files for Unicode repair, HTML extraction,
normalization, metadata, language/quality/PII decisions, deduplication,
chunking, and export.

The release claim requires exact-output/quality gates, bounded failure and
restart behavior, representative full-pipeline benchmarks, clean-machine
packages, checksums, license notices, and executable examples. A fast
microbenchmark alone is not a release claim.

## Critical path

### R1 — one configuration and composition root

Parent: [#148](https://github.com/schancel/scrubbed/issues/148).

1. **Pin behavior.** Add golden tests for the current v1 filter JSON and CLI
   ordering/options before changing orchestration.
2. **Create the canonical specification.** CLI tokens and JSON lower to one
   typed, versioned document-stage specification. Each stage owns its ordered
   filters and typed options. The durable JSON shape leaves explicit places
   for stage options and filters, but does not introduce branch/join or a
   general workflow framework.
3. **Switch execution.** Wire local file/tree and JSONL processing through
   typed `Document`, checked `Content`, stage decisions, and effects. Preserve
   mmap lifetime through synchronous consumers. Scalar filters retain fused
   range execution; contextual filters are named materialization barriers.
4. **Delete divergence.** Lower legacy `--filters` and v1 JSON to one implicit
   stage during a documented compatibility window, then remove duplicate
   parsing/orchestration once equivalence and migration tests prove the new
   path. One config fact must have one owner.

Gate: actual-binary CLI/JSON equivalence, identity/output routing, invalid
ordering/options, empty/no-op/same-file inputs, split/reject/quarantine,
concurrent reuse, restart/error reporting, and an exact-output before/after
resource benchmark.

### R2 — complete the built-in transform path

All already-implemented filters and analyzers must be selectable through R1,
with no command-specific parallel pipeline:

- Unicode/byte decoding, mojibake, entities, punctuation, line endings, and
  control cleanup;
- restricted HTML parsing, mechanical HTML-to-Markdown, deterministic HTML
  metadata, and a bounded safe Markdown-to-basic-HTML subset;
- PII report/mask/redact policy, exact dedup decisions, quality annotations,
  structured chunks, source-rights propagation, and independent content and
  metadata sinks;
- plain/gzip/zstd WARC/WET input and early WAT/source selection.

Every transform declares whether it is scalar-streamable, bounded-lookahead,
piecewise, or whole-document. Only measured compatible transforms are fused.
No stage may silently raise an input/output/resource cap.

Gate: per-transform authored and upstream-derived correctness fixtures plus
combined-order tests proving that fusion and barriers preserve exact results.

### R3 — extraction and curation parity

1. [#26](https://github.com/schancel/scrubbed/issues/26): baseline saved-HTML
   main-content versus boilerplate extraction with human-reviewed fixtures.
2. [#27](https://github.com/schancel/scrubbed/issues/27): difficult-page and
   fallback modes, benchmarked rather than assumed.
3. [#28](https://github.com/schancel/scrubbed/issues/28) then
   [#65](https://github.com/schancel/scrubbed/issues/65): deterministic
   metadata first; optional `llama-server` primary and explicit local-GGUF
   backend behind the same schema/provenance contract.
4. [#34](https://github.com/schancel/scrubbed/issues/34): language with
   confidence and abstention.
5. [#36](https://github.com/schancel/scrubbed/issues/36) then
   [#37](https://github.com/schancel/scrubbed/issues/37): disk-backed
   similarity candidates and near-duplicate decisions. Optional embeddings
   and clustering remain a separately measurable backend under #66.
6. Finish rights, quality/code routing, mixing, JSONL and Parquet/Arrow
   interchange under #43, #44, #45, #40 and #41.

Gate: quality-matched comparisons. Unsupported fields/modes are reported as
unsupported, never scored as successes or silently omitted.

### R4 — profile and tune complete pipelines

Parent: [#59](https://github.com/schancel/scrubbed/issues/59).

Freeze representative mixed-text and saved-HTML corpora before tuning. Measure
many-small and few-large layouts, warm and safely obtainable cold runs,
startup and steady-state throughput, wall/CPU/RSS, allocation volume, open
descriptors, and actual bytes where the platform can prove them. Compare only
quality-matched tasks against ftfy, Trafilatura, jusText/readability-style
extractors, language/PII/dedup tools, and composed Python pipelines.

Optimize from profiles: redundant Unicode decoding, intermediate string and
`ContentPiece` copies, HTML tree ownership, output buffering, allocator/GC
pressure, hashing, scheduler contention, and only then SIMD/vectorization.
Each optimization keeps an exact-output or quality gate and its before/after
evidence. Prove a safely provisioned 1-TiB local run under #60 before using
“terabyte-ready” language.

### R5 — packages, examples, and release

1. [#61](https://github.com/schancel/scrubbed/issues/61): named Linux and
   macOS clean-machine packages first; Windows only when its POSIX-dependent
   paths have an explicit port contract. Bundle exact native/transitive
   licenses, checksums, completions, and clean-`PATH` execution tests.
2. [#62](https://github.com/schancel/scrubbed/issues/62): executable examples
   for repair, saved HTML, WARC/WET, metadata, dedup/PII/quality decisions,
   chunking, and exports. CLI and JSON examples must describe the same plans.
3. Publish signed/checksummed GitHub release artifacts and the package-manager
   manifests justified by the proven platform matrix. Publish benchmark raw
   data and limitations with the release.

Gate: a clean machine can install, run every advertised example, verify
checksums/notices, and reproduce the documented supported-task results without
D, DUB, Python, or an implicit model download.

## Deferred and integrated, not reimplemented

These do not block the first public package release:

- direct S3 credentials, multipart transport, distributed shard ownership,
  and multi-machine finalization (#46–#57, #63, #64); use explicit local
  staging with specialist transfer tools until a later accepted contract;
- crawling, JavaScript rendering, robots/politeness, feeds and sitemap
  discovery;
- wholesale Apache Tika/Office/PDF/OCR format parsing; expose bounded adapters
  to specialist tools instead;
- general-purpose DOM programming, complete Pandoc/CommonMark/GFM parity, or
  every Presidio entity/model;
- operating llama.cpp servers, bundling model weights, or implicit downloads;
- complete API parity with DataTrove, Dolma, NeMo Curator, Trafilatura, ftfy,
  or their distributed/plugin ecosystems.

Deferred work must not leak credentials, transport assumptions, or generic
workflow abstractions into the local composition root.

## Execution rule

Work in dependency order, keeping one reviewed, benchmarkable landing per
behavioral boundary. When implementation reveals a required migration, land
tests, then the refactor/switch, then deletion. Keep README, TODO, command help,
examples, and benchmark claims synchronized after every landing.
