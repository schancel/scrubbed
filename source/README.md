# Source ownership

The executable entry is [`app.d`](app.d): `main(string[] args)` calls the
[`cli_commands.d`](cli_commands.d) argparse command adapter, reports an
uncaught exception, and returns exit code 2. The adapter routes implemented
`run`/`repair` and legacy no-verb flags into `cli.runApp`; `extract` fails
explicitly as unavailable. Command/option-name completion is supported;
document processing stays in `cli`.

[`cli.d`](cli.d) owns argument and JSON-config parsing, path validation,
incremental directory traversal, input `MmFile` lifetime, and atomic output
replacement. [`effects/bounded_input.d`](effects/bounded_input.d) owns the
local queue and independent queued-document, reserved-byte, and file-work
callback limits; it invokes `cli.processOne` or the opt-in manifest processor
through a supplied callback.
`runApp(string[] args)` builds a `Pipeline` before walking files. A file failure is
reported as `SKIP`; `runApp` returns 1 if any file failed and 0 otherwise.
The module imports the implemented filter modules so their `static this()`
registrations run. It does not contain the filter algorithms.

[`pipeline.d`](pipeline.d) owns the private name-to-filter registry and
ordered `Pipeline`. Filters register with `registerFilter` for a plain
`string -> string` function or `registerFilterFactory` for an option-aware
factory. `Pipeline.build` resolves names; `Pipeline.buildConfigured` resolves
`FilterSpec` entries and parses factory options once, before file processing.
Unknown names or options fail while building the chain. `Pipeline.run` passes
the whole returned string to the next stage in order. Individual filters may
use lazy ranges internally, but the registered stage boundary is a string.

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
to opt-in local manifest file/tree mode. The document-stage pipeline does not
use it yet. Its
canonical key format and lifetime rule are in the
[architecture map](../docs/architecture.md); transport-specific source keys
and content/job stages are not implemented here.

[`content/pieces.d`](content/pieces.d) provides ordered borrowed/owned byte
pieces. The opt-in manifest CLI wraps the existing string pipeline's output
as an owned piece for F08 publication; future text and output stages are not
wired. It depends on `domain.document`'s
checked view, not CLI mapping internals. Edits use byte offsets; `replace`
can insert, delete, or replace without copying untouched source bytes. `stream`
emits bounded, temporary chunks to a sink. The filters and no-manifest CLI
do not use this facade.

`Content.pieces()` is a lazy Phobos InputRange of checked piece descriptors.
It preserves empty descriptors and borrowing checks without flattening bytes.
[`stages/contract.d`](stages/contract.d) defines ordered document-range
map/reject/quarantine/split decisions, child provenance, cancellation safe
points, and validated descriptive resources. Its pass-mode metadata describes
single-pass or resumable stage behavior; it does not implement checkpoints or
scheduling. These stages are not wired to the current string pipeline or CLI.

[`stages/registry.d`](stages/registry.d) adds typed stage declarations, option
schemas, factory registration, and relative ordering metadata. A concrete
stage registers itself in its own module constructor; consumers import that
module to make it available. [`stages/config.d`](stages/config.d) strictly
parses the nested `{"version":2,"stages":[{"name":"...","options":{...}}]}`
API format and resolves typed transforms before document execution. Its
[`stages/fixture.d`](stages/fixture.d) registration exists only in unittest
builds. V2 is not accepted by the CLI; the existing v1 `--config` path remains
unchanged. Registration and parsing do not reserve resources or establish
production document-stage backpressure; F04's high-edit content path still
needs measurement. The CLI's bounded local file queue is a separate seam.

[`effects/runner.d`](effects/runner.d) defines typed `Source`, `Parser`, and
`Sink` ports and the one-document-at-a-time `runEffects` composition root.
The source transfers each record's view owner to the runner, which closes it
after the stage decision is synchronously delivered; borrowed content cannot
be retained by the sink without an explicit copy. Faults surface phase,
completed-decision count, and possible partial sink-write uncertainty.
Cancellation never fetches the next lazy input after it is observed. Memory
and faulting D test adapters use this same path. It is not wired to CLI, and
does not establish production backpressure or corpus-throughput readiness.

[`effects/windowed_input.d`](effects/windowed_input.d) is a separate POSIX
single-active-lease mmap reader with checked borrows, bounded owning carry,
and mapped-byte counters. [`effects/atomic_piece_sink.d`](effects/atomic_piece_sink.d)
streams `Content.pieces()` through a bounded buffer to one atomic local
destination. The opt-in manifest file/tree CLI uses the atomic piece sink;
the mapped windowed input remains standalone. Neither is wired to the future
document-stage runner; their resource bounds do not make
context-heavy filters streaming.

[`effects/jsonl_stream.d`](effects/jsonl_stream.d) and
[`effects/stdio_stream.d`](effects/stdio_stream.d) provide standalone bounded
JSONL selected-field and stream adapters with semantic-value preservation of
untouched fields. The command adapter now routes explicit paired `--input -`
and `--output -` `run`/`repair` mode through them, with caller-provided stable
namespace/source keys and line-ordinal `DocumentId`s. There is no JSONL
checkpoint or graceful signal cancellation.

[`effects/local_manifest.d`](effects/local_manifest.d) is a standalone,
versioned local SQLite sink ledger with independent per-sink states and bounded
replay. It verifies observed output bytes before a committed skip. The
file/tree CLI wires it only in opt-in `--manifest PATH` mode; see
[local manifest restart behavior and crash limits](../docs/local-manifest.md).

For mapping and output-commit details, see the [architecture map](../docs/architecture.md).
For filter work, start with the [filter guide](filters/README.md), then run
`dub test` and `dub build --build=release` from the repository root.

Local-manifest file failures and fatal exits are described in
[`docs/failure-policy.md`](../docs/failure-policy.md).
