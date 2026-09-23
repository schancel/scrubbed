# Source ownership

The executable entry is [`app.d`](app.d): `main(string[] args)` calls the
[`cli_commands.d`](cli_commands.d) argparse command adapter, reports an
uncaught exception, and returns exit code 2. The adapter routes implemented
`run`/`repair` and legacy no-verb flags into `cli.runApp`; opt-in `extract`
routes local HTML to `cli.runExtract` for selected tree-JSON or Markdown output.
Command/option-name completion is supported;
document processing stays in `cli`.

[`cli.d`](cli.d) owns argument and JSON-config parsing, path validation,
incremental directory traversal, scheduling, and output policy.
[`effects/bounded_input.d`](effects/bounded_input.d) owns the local queue and
independent queued-document, reserved-byte, and file-work callback limits;
descriptor tokens are granted in submission order so canonical publication
cannot deadlock behind a later input. Its callback invokes the compiled local
adapter for ordinary and durable routes.
`runApp(string[] args)` compiles the selected local route's canonical job once
before walking files. A reject or quarantine is an acknowledged per-document
outcome, publishes no root output, and yields exit 1; run-fatal failures and
collisions are reported as `FATAL` and exit 2; a completed mapped run exits 0.
The module imports the implemented filter modules so their `static this()`
registrations run. It does not contain the filter algorithms.

[`pipeline.d`](pipeline.d) owns the injectable name-to-filter registry and
ordered `Pipeline`. Filters register with `registerFilter` for a plain
`string -> string` function or a typed option-schema factory. The canonical
compiler alone calls `Pipeline.buildTyped`, which resolves v3 scalar types
without coercion. The global registry is read-only to consumers, while explicit
`FilterRegistry` instances support isolated composition tests. Unknown names,
options, missing required values, and type mismatches fail while building the
chain. Configured whole-buffer factories retain only a pure context-free function
pointer plus transitive-immutable parsed configuration; mutable streaming
state is created anew by each run. `Pipeline.run` passes whole-buffer results
between materialization
barriers; consecutive bounded scalar registrations share one lazy traversal.

[`job/`](job/README.md) owns the pure v3 linear-job model and additive explicit
v4 dispatch root. Strict v3 JSON, ordered composition tokens, and predecessor
filter-only forms lower to the same typed stages, ordered filters, and scalar
options; canonical bytes own a stable `job:v3:` identity. Strict v4 JSON and
dispatch tokens bind finite detector/container limits, routes, actions, and a
complete v3 common plan into `job:v4:`. This subtree has no registry or I/O
import. Ordinary local file/tree, durable file/tree, and selected-field JSONL
shipping consume the selected v3 or v4 runtime plan through effects bridges.

[`composition/`](composition/README.md) compiles that model through injected
stage and filter registries without importing concrete implementations. It
retains stage-instance identity and validates exact option types, relative
stage order, and declared before/after/no-filter placement. The pure one-stage
executor applies before/after filters over checked
`Content`. A pure one-record job executor now carries emitted documents through
every compiled stage, retaining terminal decisions, split order and immediate
parent provenance, and returns only final/terminal events. The effects runner
can now apply that compiled job once per typed source record, synchronously
deliver its ordered final events, and close the transferred content owner.
`composition.runtime_plan` is the closed choice between unchanged v3 and
explicit v4. The dispatch compiler resolves bounded detection, routes, the
extractor registry, and the nested common job; its executor produces exactly
one route/pass/reject/quarantine result. Ordinary local file/tree, durable
file/tree, and selected-field JSONL shipping are wired to both plans.

[`filters/`](filters/README.md) owns text transforms and local registration.
The intended dependency direction is `app -> cli -> pipeline`, with `cli`
also importing filter modules for registration and filters importing
`pipeline`'s registration API. `pipeline` does not depend on `cli` or concrete
filters. The current `filters.entities` import of `filters.mojibake` is only
for its CP1252 mapping helper.

[`domain/document.d`](domain/document.d) is the typed domain
facade for logical `SourceLocator`/`DocumentId` identity, distinct `OutputName`,
and owner-checked zero-copy byte views with explicit selected-range copying.
It supplies stable line-ordinal IDs to JSONL CLI mode and root-relative IDs
to local file/tree processing. Compiled JSONL and all current local execution
use this facade. Its
canonical key format and lifetime rule are in the
[architecture map](../docs/architecture.md); transport-specific source keys
and content/job stages are not implemented here.

[`content/pieces.d`](content/pieces.d) provides ordered borrowed/owned byte
pieces. Canonical compiled local, durable, extract, metadata, and selected-field
JSONL routes carry stage content through this representation. It depends on
`domain.document`'s
checked view, not CLI mapping internals. Edits use byte offsets; `replace`
can insert, delete, or replace without copying untouched source bytes. `stream`
emits bounded, temporary chunks to a sink. Text filters remain explicit
materialization barriers inside compiled stages.

`Content.pieces()` is a lazy Phobos InputRange of checked piece descriptors.
It preserves empty descriptors and borrowing checks without flattening bytes.
[`stages/contract.d`](stages/contract.d) defines ordered document-range
map/reject/quarantine/split decisions, child provenance, cancellation safe
points, and validated descriptive resources. Its pass-mode metadata describes
single-pass or resumable stage behavior; it does not implement checkpoints or
scheduling. Canonical compiled v3 jobs and the v3 common plan inside v4 execute
these contracts for shipping file/tree and JSONL routes.

[`stages/registry.d`](stages/registry.d) adds typed stage declarations, option
schemas, factory registration, and relative ordering metadata. A concrete
stage registers itself in its own module constructor; consumers import that
module to make it available. The deleted v2 `stages.config` facade has no
shipping or test consumer; canonical v3 parsing and compilation own stage
resolution. Registry factories return a pure context-free function pointer paired
with transitive-immutable parsed configuration, so resolved execution can be
reused concurrently without rebuilding factories. Its
[`stages/fixture.d`](stages/fixture.d) registration exists only in unittest
builds. [`effects/html_tree_json_stage.d`](effects/html_tree_json_stage.d) is a concrete
effects-owned, self-registering stage used by `extract`; that route compiles a
canonical v3 job. Its 32 MiB resource
declaration is descriptive, not an enforced RSS limit. Registration and parsing do not reserve resources or establish
production document-stage backpressure; F04's high-edit content path still
needs measurement. The CLI's bounded local file queue is a separate seam.
[`stages/text_transform.d`](stages/text_transform.d) is the self-registering
no-op document map used by compiled jobs whose content work is an ordered
filter chain. Compiled execution applies its declared `before` placement before
the document map.

[`effects/runner.d`](effects/runner.d) defines typed `Source`, `Parser`, and
`Sink` ports and the one-document-at-a-time `runEffects` composition root.
The source transfers each record's view owner to the runner, which closes it
after the stage decision is synchronously delivered; borrowed content cannot
be retained by the sink without an explicit copy. Faults surface phase,
completed-decision count, and possible partial sink-write uncertainty.
Cancellation never fetches the next lazy input after it is observed. Memory
and faulting D test adapters use this same path. [`effects/local_job.d`](effects/local_job.d)
binds one admitted local file to that bridge and synchronously publishes final
events. It does not establish corpus-throughput readiness.

[`effects/windowed_input.d`](effects/windowed_input.d) is a separate POSIX
single-active-lease mmap reader with checked borrows, bounded owning carry,
and mapped-byte counters. [`effects/atomic_piece_sink.d`](effects/atomic_piece_sink.d)
streams `Content.pieces()` through a bounded buffer to one atomic local
destination. Canonical local and durable file/tree execution uses the atomic
piece sink; the mapped windowed input remains standalone. Their resource bounds do not make
context-heavy filters streaming.

[`effects/html_tree_export.d`](effects/html_tree_export.d) serializes the
restricted D-owned selected parse tree to deterministic, versioned JSON with
a 4 MiB pre-publication cap. `extract` uses the local bounded scheduler,
explicit charset/BOM decode, and F08 atomic piece sink. It does not perform
article selection, Markdown conversion, metadata extraction, or restart.

[`effects/jsonl_stream.d`](effects/jsonl_stream.d) and
[`effects/stdio_stream.d`](effects/stdio_stream.d) provide standalone bounded
JSONL selected-field and stream adapters with semantic-value preservation of
untouched fields. The command adapter now routes explicit paired `--input -`
and `--output -` `run`/`repair` mode through them, with caller-provided stable
namespace/source keys and line-ordinal `DocumentId`s. There is no JSONL
checkpoint or graceful signal cancellation.
[`effects/jsonl_job.d`](effects/jsonl_job.d) is the narrow selected-field
facade over `effects.runner`: it assigns the field as `OutputName`, transfers
one checked content owner, executes the selected runtime plan, copies the sole
mapped result synchronously, and refuses rejection, quarantine, or fanout
without emitting the current record. V4 explain records use the configured
field ordinal and are written to stderr by the CLI wrapper.

[`effects/durable_job.d`](effects/durable_job.d) owns canonical compiled-job
durability: manifest v2 and failure-journal v3 root records, complete ordered
final-event plans, per-event publication intents, exact retry, and root-last
completion. It accepts caller-derived v3 or v4 plan identity and never imports
`job`. An incoming v4 plan requires every existing row to carry its exact plan
and executable binding, so existing v3 or changed-v4 rows refuse it before
mutation. Incoming v3 preserves the historical multi-configuration behavior
and may coexist with earlier v4 rows.
[`effects/local_manifest.d`](effects/local_manifest.d) remains the predecessor
v1 API for offline copy and retained consumers; canonical `--manifest` runs
refuse it rather than upgrading it. See
[local manifest restart behavior and crash limits](../docs/local-manifest.md).

[`effects/zstd_ffi.d`](effects/zstd_ffi.d) declares the narrow ABI for the
vendored static zstd decompressor used by the WARC codec adapter.

[`domain/shard_format.d`](domain/shard_format.d) defines the standalone binary-v1
immutable source-document and keyed analyzer-overlay records.
[`effects/document_shards.d`](effects/document_shards.d) streams their bounded
frames, performs version/revision-checked joins, and publishes source shards
create-only or replaces one overlay atomically. No CLI or SQLite route uses
these artifacts yet; see the [format and publication limits](../docs/document-shards.md).

For mapping and output-commit details, see the [architecture map](../docs/architecture.md).
For filter work, start with the [filter guide](filters/README.md), then run
`dub test` and `dub build --build=release` from the repository root.

Local-manifest file failures and fatal exits are described in
[`docs/failure-policy.md`](../docs/failure-policy.md).
