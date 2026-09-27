# Current architecture

Scrubbed is a D executable, not a supported library API. Its linear v3 job
model and explicit opt-in v4 dispatch root are the shipping formats for
ordinary and durable local file/tree plus selected-field JSONL processing.
The [source guide](../source/README.md) describes the current boundary, and
the [filter guide](../source/filters/README.md) is the shortest path to
adding one transform.

## Module dependency diagram

```text
app (process exit)
  -> cli (arguments, filesystem, workers, input mappings, output writes)
       -> pipeline (filter registry and ordered chain)
       -> filters/* (imported so their module constructors register)
filters/* -> pipeline (registration and filter types)
filters.entities -> filters.mojibake (CP1252 character mapping)
job.* (pure canonical v3 plus additive v4 dispatch specifications and lowering,
  including versioned CLI-token presets in job.presets)
composition.compiler/executor/job_executor -> job, pipeline, stages
  (pure registry compilation and one-record execution)
composition.dispatch_compiler/dispatch_executor/runtime_plan -> job, extraction, composition
extraction.detector/container/refinement/plain_text -> content, domain.document
  (container.d holds the ZIP-admission inspection; refinement.d holds the
  bounded ZIP-refinement limits the v4 root enforces)
domain.* (typed identity/view facade plus independent pure value types;
  no import from any other project layer)
content.pieces -> domain.document (checked borrowed content)
stages.contract -> content.pieces, domain.document (standalone stage contract)
stages.registry -> stages.contract (self-registered typed stage factories)
effects.local_job -> effects.runner, mapped_file, atomic_piece_sink
effects.durable_job -> domain.document, sqlite_ffi, local_manifest path/hash primitives
effects.jsonl_job -> effects.runner, effects.jsonl_stream
effects.*_stage / effects.*_overlay -> stages.contract, stages.registry,
  domain.*, content, other effects.* (self-registering concrete v3 stages and
  read-only join facades; see "Effects" below)
```

Orchestration and filesystem effects stay in `cli`, chain composition in
`pipeline`, and text transforms with their registrations in `filters`. The
filter/pipeline dependency runs toward `pipeline`; `pipeline` does not import
individual filters. The `entities` -> `mojibake` helper import is a specific
existing cross-filter dependency, not a general layering rule.

`scripts/check_modules.d` enforces the layering above by direct-import
analysis (not full parsing) and requires every module to declare itself and
carry a doc comment or `README.md` entry. Its rules, in the order it applies
them:

- `app` may import only `cli` among project modules.
- `job`, `domain`, `content`, `extraction`, and `stages` must never import
  `effects` or a concrete I/O module (`std.file`, `std.mmfile`, `std.socket`,
  `std.net`, `std.stdio`, `std.process`).
- `job` may import only `job`.
- `domain` may import only `domain` (stricter than "no cli/pipeline/filters
  import" -- domain modules are independent of every other project layer,
  including `content`, `extraction`, `stages`, and `effects`).
- `content` may import only `domain` and `content`.
- `extraction` may import only `extraction`, `domain`, and `content`.
- `stages` may import only `stages`, `domain`, and `content`.
- `composition` may import only `job`, `pipeline`, `stages`, `extraction`,
  `domain`, and `content`.
- `effects` may import only `effects`, `composition`, `job`, `stages`,
  `extraction`, `domain`, and `content`.
- `pipeline` must not import `app`, `cli`, or a concrete filter.
- `filters` must not import `app` or `cli`; cross-filter imports are limited
  to `entities` -> `entities_data`/`mojibake`.

Run its own checks with:

```sh
ldc2 -unittest -main -d-version=moduleCheckRunner -of=/tmp/scrubbed-module-edge-tests scripts/check_modules.d
/tmp/scrubbed-module-edge-tests
```

`dub test` exercises module tests, including the CLI's same-file, empty-file,
parallel-tree, invalid-input, and symlink cases. `dub build --build=release`
builds the executable; both commands are defined by the current `dub.json`.

## Filters and the pipeline registry

- The registry has two execution contracts. Whole-buffer filters retain the
  original `string -> string` boundary and are materialization barriers.
  Bounded UTF-8-scalar transducers additionally register push/finish
  callbacks; consecutive transducers are composed at runtime into one
  function-local Voldemort `InputRange`. Its fixed-capacity stage array,
  state, and pending scalar queues live in the returned value on the caller
  side, with no per-group stage heap allocation.
- The source remains borrowed and must outlive consumption. `Pipeline.run`
  returns the borrowed input when it is the complete fused result, and
  otherwise materializes once from the first differing byte. Runs longer
  than 16 transducers split at another fused-run boundary to bound recursive
  pull depth; that boundary materializes only when its result differs.
  Canonical compiled v3 and v4 common plans invoke this filter machinery at
  explicit `Content` materialization barriers rather than through a second
  orchestration path.
- Filter lookup is injectable through `FilterRegistry`; the process-global
  instance is exposed read-only after module-constructor registration. The
  v3 factory path declares exact text/integer/boolean option schemas and
  rejects a type mismatch before processing input. `fix-mojibake` uses that
  path. Version-1 configuration is converted by the edge lowerer before
  registry lookup; no separate string-option factory remains. The registry
  does not import the `job` model; composition owns conversion.

## CLI file handling

`cli.processOne` maps a nonempty input with `MmFile`, runs the chain while
the mapping is open, and closes it before writing. A filter may return an
unchanged or sliced view of that mapping; `processOne` copies such a result
before the mapping closes -- no borrowed view may outlive its `MmFile`.
Empty files take a separate path without a mapping. Output is written to a
temporary file beside the destination and then renamed into place; an
existing destination's attributes are copied to the temporary file before
rename. This supports same-file input/output and prevents a partially
written destination from being observed. The CLI rejects unsafe symlink
paths and an output tree nested in the input tree.

## Job specifications: v3 (linear) and v4 (dispatch)

- **v3 (`job.spec`)**: one linear `JobSpec` -- stable stage-instance ID,
  registered implementation name, typed stage options, and ordered filters
  with typed options. Strict JSON and ordered CLI composition tokens lower
  to that model, while v1/default compatibility inputs lower to one implicit
  `legacy-text=text-transform` stage. `job.presets` adds a third source of
  the same ordered tokens: a fixed, named, versioned list (for example
  `clean-web-document/v1`) that expands to plain composition tokens with no
  registry lookup or I/O of its own -- `cli_commands.d` compiles the result
  through the existing `composition.compiler.compileJob`, exactly as it
  would any other token list. Canonical fixed-order JSON with sorted option
  keys owns the `job:v3:` digest. Duplicate/unknown keys, duplicate stage
  IDs, ambiguous/orphan CLI options, and non-scalar JSON values fail at this
  boundary. `job.*` neither resolves registries nor performs I/O; the CLI
  lowers at its edge and compiles before opening local document content. See
  the [v3 format guide](job-spec-v3.md).
- **v4 (`job.dispatch_spec`)**: the additive dispatch root owns bounded
  detector and ZIP-refinement limits, finite routes, an explicit action for
  every detection outcome, and one complete v3 `common` plan. Strict JSON
  and ordered dispatch tokens canonicalize to the same `job:v4:` identity.
  `composition.dispatch_compiler` resolves the detector, extractor, and
  common plan through injected registries; `runtime_plan` is the closed
  shipping choice between unchanged linear v3 and explicit dispatch v4. The
  executor makes exactly one route/pass/reject/quarantine decision while
  preserving document identity and output name. Routed content crosses the
  versioned extracted-text contract, then runs the common plan once. Only
  `core-plain-text/v1` ships (`extraction.registry`); recognizing another
  signature permits explicit policy for it and does not imply that its
  extractor exists.

## Composition

- `composition.compiler` is the only conversion point from `JobOption` to
  the registry-owned stage/filter scalar types. It resolves injected
  registries, invokes factories once, validates relative implementation
  order, and retains only pure context-free executable function pointers
  plus transitive-immutable parsed configuration. Shallow compiled-plan
  copies are therefore safe for deterministic sequential or concurrent
  reuse; streaming state remains local to each pipeline run. The
  stage-instance ID and canonical job identity remain behind read-only
  compiled views. Stage registrations declare filter placement as none,
  before, or after; compilation rejects unsupported filters.
  `stages.text_transform` is a self-registering no-op map with `before`
  placement.
- `composition.executor` proves one compiled stage's declared placement over
  checked `Content`: nonempty chains are explicit UTF-8 materialization
  barriers, while empty chains preserve borrowed content.
  `composition.job_executor` applies those compiled stages to one source
  record in order, advances only emitted events, preserves terminal
  decisions and split-child lineage, and returns only final/terminal
  events.

## Domain and content facades

- **`domain.document`** defines `SourceLocator`, `DocumentId`, `OutputName`,
  `Document`, and an owner-checked borrowed view. Shipping effects and CLI
  adapters depend on this domain facade, never the reverse. `DocumentId` is
  a durable logical-record key, not a path, output name, worker assignment,
  source revision, or content hash: its `doc:v1:` text is lowercase SHA-256
  hex of `scrubbed:document-id:v1\0`, followed by three UTF-8 fields
  (dataset namespace, source key, record key), each prefixed with a
  four-byte unsigned big-endian byte length. Fields must be nonempty valid
  UTF-8 without NUL and are NFC-normalized. Case and path-like spelling
  remain significant: no case-folding, slash cleanup, absolute-path
  resolution, or provider-specific source interpretation occurs here. This
  leaves annotation joins and shard reassignment stable without defining
  S3/WARC identity policy (tracked: does not yet separate URL identity,
  fetch identity, and content identity for a raw artifact -- see
  [issue #337](https://github.com/schancel/scrubbed/issues/337)).
  `OutputName` is separate and does not enter the key.
- Beyond `domain.document`, the `domain` layer also holds independent,
  effects-free value types and pure logic for later stages/overlays to
  consume -- among them `pii_patterns`/`pii_policy`, `quality_features`,
  `token_entropy`, `language_id`, `topical_tags`, `source_rights`,
  `mix_policy`, `exact_dedup`, `similarity_signature`, `structured_chunks`,
  `document_metadata`, and `shard_format`. Each is self-contained under the
  "domain imports only domain" rule above; nothing here reaches `cli`,
  `pipeline`, `filters`, `effects`, or the network.
- **`effects.mapped_file.openMappedFile`** opens a mapping and transfers its
  opaque lifetime lease to `DocumentViewOwner` until `close`; checked
  `at`/iteration borrows bytes without an eager whole-file copy or an
  escaping slice. The in-memory constructor borrows a GC-owned array
  instead, which the caller must not manually free or reallocate while
  open. `copy` explicitly retains only the selected range; all view access
  is rejected after owner close. Canonical local execution uses this facade
  through `effects.local_job`.
- **`content.pieces`** is the standalone ordered byte-content facade. A
  `ContentPiece` is exactly one checked borrowed `DocumentView` subrange or
  one independently retained owned replacement; a default piece is invalid.
  `Content` keeps ordered descriptors with byte offsets, supports range
  replacement and deletion without flattening source bytes, and streams
  into a caller sink using a bounded temporary buffer (default 8 KiB).
  Borrowed access, including length and streaming after owner closure,
  fails; owned pieces remain valid. Sinks must consume each chunk before
  returning because the buffer is reused. `Content.pieces()` also exposes a
  lazy Phobos `InputRange` over a snapshot of descriptors: it does not
  flatten bytes, preserves empty pieces, and checks a borrowed owner's
  lifetime when `front` or `popFront` touches that descriptor. Edits after
  obtaining the range do not alter that descriptor snapshot. The content
  module points only toward `domain.document`; canonical local, durable,
  extract, metadata, and selected-field JSONL execution use it through
  their effects adapters.

## Stage contract and registry

- **`stages.contract`** accepts a document range and makes one complete
  decision per visited document: map (same identity), reject with reason,
  quarantine with reason, or split into one or more children. The result
  carries ordered events; split children occupy their parent's position and
  have a deterministic, domain-separated `child:v1:` ID derived from the
  immediate parent ID, stage key, and zero-based ordinal, plus explicit
  parent ID/ordinal provenance. Output names do not define child identity,
  but inputs and emitted documents must have a valid initialized output
  name. A cancellation callback is checked before a lazy range's `front` and
  after its complete decision is recorded; cancellation never removes an
  already recorded event. The result's processed count is the next input
  index for a caller that owns its own replay cursor. `singlePass` and
  `resumable` are declarations only: resumable allows replay from that
  boundary, but neither mode creates a checkpoint, reserves resources, or
  rolls back an external sink. Resource needs (CPU slots, memory bytes,
  exclusive names) are validated and descriptive. This module has no CLI or
  filter import, and no scheduler, join, global dedup, or persistence
  implementation.
- **`stages.registry`** records each concrete stage's declaration, typed
  option schema, factory, and relative `before`/`after` constraints. Stage
  modules self-register when imported; the registry does not import their
  names. A factory returns a pure context-free stage function and
  transitive-immutable typed configuration rather than a configured
  delegate. Canonical version-3 JSON and CLI tokens, including the v3
  `common` plan nested inside v4, compile through this registry. The
  compiler rejects unknown names, missing or mistyped options, duplicate
  stage IDs, invalid filter placement, and relative-order violations before
  any document is read. The predecessor v2 config facade is deleted. There
  is no plugin loading or resource scheduler here. `stages.fixture` is a
  test-only fixture that self-registers from its own module.
- F04's ordered-list high-edit scaling and event materialization still
  require production backpressure/representation measurement.

## Effects

- **`effects.runner`** is the shared composition root: it bridges a compiled
  job to its typed source/parser/sink ports one record at a time, preserving
  root commit and failure accounting while closing the transferred content
  owner after synchronous delivery. A `Source` yields one typed record and
  view owner, a `Parser` produces checked `Content`, and a `Sink`
  synchronously consumes each ordered stage event. `runEffects` calls the
  F04 decision contract for one document at a time, then delivers all its
  events before fetching another record. A record's view owner stays open
  through sink calls and closes afterward; retained borrowed content rejects
  access after closure. `Content.stream` chunks must be consumed before
  callback return. Cancellation is checked before source fetch, before
  parse/stage evaluation, and before the next fetch after complete delivery.
  A sink exception reports wholly delivered decisions and the failing event
  ordinal with partial-write uncertainty; it promises no rollback,
  checkpoint, or successful completion.
- **`effects.local_job`** binds an admitted local record to that bridge.
  **`effects.durable_job`** plans the root after the trustworthy input
  digest, executes the job once, then exposes the complete ordered
  final-event set while borrowed content remains live; it records
  manifest-v2 or journal-v3 root/event state before publication and commits
  the root only after every output is committed and every no-output
  terminal is acknowledged. In-memory/faulting adapters and the local-file
  shipping adapter exercise the runner path; the local adapter maps one
  admitted input, keeps its owner live through synchronous atomic
  publication, and releases it before completion. No S3/parser-library
  adapter is added. F04 materializes events per document and ordered-list
  content has poor high-edit scaling; production callers must measure
  representation and backpressure before using this seam for corpus
  throughput.
- **Self-registering stage and overlay modules** (`effects.*_stage`,
  `effects.*_overlay`): most concrete v3 stages beyond
  `stages.text_transform`/`stages.pii_four_class`/`stages.fixture` live in
  the effects layer rather than `stages/`, because they need capabilities
  (HTML parsing via `effects.html_tree`, FFI, or reading another overlay)
  the pure `stages` import rule (`stages`, `domain`, `content` only)
  forbids. Importing one of these modules self-registers it into
  `stages.registry`, exactly like the pure `stages.*` modules. Current
  content-mapping (non-terminal) stages: `effects.html_main_content_stage`
  (`html-main-content`), `effects.html_markdown_stage`/
  `effects.html_tree_json_stage` (selected-tree Markdown/JSON export),
  `effects.html_metadata_annotate_stage` (writes standard fields into
  `StageDocument.metadata`), and `effects.compressibility_annotate_stage`
  (writes an order-0-entropy/zstd-ratio extension field into the same
  metadata map). Current terminal side-output producers:
  `effects.document_metadata_publish_stage` (`document-metadata-publish`,
  encodes whatever metadata a job accumulated by that point),
  `effects.language_id_detect_stage` (`language-id-detect`, wires the
  unmodified `domain.language_id` classifier in), and
  `effects.topical_tags_extract_stage` (`topical-tags-extract`,
  declared-tag extraction from a page's own HTML only -- no
  controlled-vocabulary inference is wired), alongside the pre-existing
  `stages.pii_four_class` (`pii-four-class`). Each of these is today its own
  independent terminal or metadata-writing producer; none joins another's
  output beyond the shared `StageDocument.metadata` extension-field
  mechanism `document-metadata-publish` reads. Separate, opt-in read-only
  join facades (`effects.pii_overlay`, `effects.quality_overlay`,
  `effects.mix_overlay`, `effects.exact_dedup_overlay`,
  `effects.source_rights_overlay`) persist or combine C01-shard-joined
  evidence outside the per-document stage chain.
- As the layering rules above state, `job`/`composition`/`domain`/`content`/
  `extraction`/`stages` may not import `effects` or a concrete I/O module,
  while `effects` itself may import concrete I/O freely. This is a
  direct-import check, not proof of transitive I/O independence.

## Experiments

- The [wired D stage experiment](../experiments/stages/README.md) measures
  the actual ordered-list `Content.replace` path through `runStage`; it does
  not substitute the isolated rope prototype. Job scheduling and provider
  transport boundaries remain proposals.
- The [D-only content experiment](../experiments/content/README.md)
  compares an ordered piece list against a randomized-priority rope on an
  identical edit trace. It is representation evidence, not a production
  rope framework or a corpus-scale throughput claim. The ordered list
  remains a private, reversible representation pending review of the
  measured wired caller above; its high-edit scaling is not assumed
  adequate for production throughput.
