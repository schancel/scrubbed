# Current architecture

Scrubbed is a D executable, not a library with a separate document or job API.
The [source guide](../source/README.md) describes the current boundary, and
the [filter guide](../source/filters/README.md) is the shortest path to adding
one transform.

```text
app (process exit)
  -> cli (arguments, filesystem, workers, input mappings, output writes)
       -> pipeline (filter registry and ordered chain)
       -> filters/* (imported so their module constructors register)
filters/* -> pipeline (registration and filter types)
filters.entities -> filters.mojibake (CP1252 character mapping)
domain.document (standalone typed identity/view facade; no current CLI caller)
content.pieces -> domain.document (checked borrowed content; no current CLI caller)
stages.contract -> content.pieces, domain.document (standalone stage contract)
stages.config -> stages.registry -> stages.contract (unwired v2 config API)
effects.runner -> stages.contract, content.pieces, domain.document (standalone effect composition)
```

Keep orchestration and filesystem effects in `cli`, chain composition in
`pipeline`, and text transforms with their registrations in `filters`. The
filter/pipeline dependency runs toward `pipeline`; `pipeline` does not import
individual filters. The current `entities` to `mojibake` helper import is a
specific existing cross-filter dependency, not a general layering rule.

`cli.processOne` maps a nonempty input with `MmFile`, runs the chain while the
mapping is open, and closes it before writing. A filter may return an unchanged
or sliced view of that mapping; `processOne` copies such a result before the
mapping closes. No borrowed view may outlive its `MmFile`. Empty files take a
separate path without a mapping. Output is written to a temporary file beside
the destination and then renamed into place; an existing destination's
attributes are copied to the temporary file before rename. This supports
same-file input/output and prevents a partially written destination from being
observed. The CLI rejects unsafe symlink paths and an output tree nested in
the input tree.

`dub test` exercises module tests, including the CLI's same-file, empty-file,
parallel-tree, invalid-input, and symlink cases. `dub build --build=release`
builds the executable; both commands are defined by the current `dub.json`.

The new `domain.document` module defines `SourceLocator`, `DocumentId`,
`OutputName`, `Document`, and an owner-checked borrowed view. It has no import
from `cli`, `pipeline`, or `filters`; none of those modules imports it yet.
`DocumentId` is a durable logical-record key, not a path, output name, worker
assignment, source revision, or content hash. Its `doc:v1:` text consists of
lowercase SHA-256 hex of `scrubbed:document-id:v1\0`, followed by three
UTF-8 fields (dataset namespace, source key, record key), each prefixed with
a four-byte unsigned big-endian byte length. Fields must be nonempty valid
UTF-8 without NUL and are NFC-normalized. Case and path-like spelling remain
significant: no case-folding, slash cleanup, absolute-path resolution, or
provider-specific source interpretation occurs here. This leaves annotation
joins and shard reassignment stable without defining S3/WARC identity policy.
`OutputName` is separate and does not enter the key.
`effects.mapped_file.openMappedFile` opens a mapping and transfers its opaque
lifetime lease to `DocumentViewOwner` until `close`; checked `at`/iteration
borrows bytes without an eager whole-file copy or an escaping slice.
The in-memory constructor borrows a GC-owned array instead, which the caller
must not manually free or reallocate while open. `copy` explicitly retains
only the selected range; all view access is rejected after owner close. The
current CLI retains its own mapping-lifetime logic and is not wired to this
facade.

`content.pieces` is the standalone ordered byte-content facade. A
`ContentPiece` is exactly one checked borrowed `DocumentView` subrange or one
independently retained owned replacement; a default piece is invalid. `Content`
keeps ordered descriptors with byte offsets, supports range replacement and
deletion without flattening source bytes, and streams into a caller sink using
a bounded temporary buffer (default 8 KiB). Borrowed access, including length
and streaming after owner closure, fails; owned pieces remain valid. Sinks
must consume each chunk before returning because the buffer is reused. This
`Content.pieces()` also exposes a lazy Phobos InputRange over a snapshot of
descriptors: it does not flatten bytes, preserves empty pieces, and checks a
borrowed owner's lifetime when `front` or `popFront` touches that descriptor.
Edits after obtaining the range do not alter that descriptor snapshot.
The content module points only toward `domain.document`; neither CLI nor
filters use it yet.

`stages.contract` accepts a document range and makes one complete decision per
visited document: map (same identity), reject with reason, quarantine with
reason, or split into one or more children. The result carries ordered events;
split children occupy their parent's position and have a deterministic,
domain-separated `child:v1:` ID derived from the immediate parent ID, stage
key and zero-based ordinal, plus explicit parent ID/ordinal provenance.
Output names do not
define child identity, but inputs and emitted documents must have a valid
initialized output name. A cancellation callback is checked before a lazy
range's `front` and after its complete decision is recorded; cancellation
never removes an
already recorded event. The result's processed count is the next input index
for a caller that owns its own replay cursor. `singlePass` and `resumable` are
declarations only: resumable allows replay from that boundary, but neither
mode creates a checkpoint, reserves resources, or rolls back an external sink.
Resource needs (CPU slots, memory bytes, exclusive names) are validated and
descriptive. This module has no CLI or filter import, and no scheduler, join,
global dedup or persistence implementation.

`stages.registry` records each concrete stage's declaration, typed option
schema, factory and relative `before`/`after` constraints. Stage modules
self-register when imported; the registry does not import their names.
`stages.config.buildConfigV2` accepts only a nested version-2 object with an
ordered `stages` array. It rejects unknown keys/names, duplicate stage names,
missing required options, incorrect JSON option types and relative-order
violations before any document is run. A test-only fixture self-registers from
its own module. This builds typed transforms but is not an executable v2 CLI
path; the existing v1 `--config` format and `max-passes` semantics are unchanged.
There is no plugin loading or resource scheduler here. F04's ordered-list
high-edit scaling and event materialization still require production
backpressure/representation measurement.

The [wired D stage experiment](../experiments/stages/README.md) measures the
actual ordered-list `Content.replace` path through `runStage`; it does not
substitute the isolated rope prototype. Job scheduling and provider transport
boundaries remain proposals.

The [D-only content experiment](../experiments/content/README.md) compares an
ordered piece list against a randomized-priority rope on an identical edit
trace. It is representation evidence, not a production rope framework or a
corpus-scale throughput claim. The ordered list remains a private, reversible
representation pending review of the measured wired caller above; its
high-edit scaling is not assumed adequate for production throughput.

`effects.runner` is an unwired composition root. A `Source` yields one typed
record and view owner, a `Parser` produces checked `Content`, and a `Sink`
synchronously consumes each ordered stage event. `runEffects` calls the F04
decision contract for one document at a time, then delivers all its events
before fetching another record. A record's view owner stays open through sink
calls and closes afterward; retained borrowed content rejects access after
closure. `Content.stream` chunks must be consumed before callback return.
Cancellation is checked before source fetch, before parse/stage evaluation,
and before the next fetch after complete delivery. A sink exception reports
wholly delivered decisions and the failing event ordinal with partial-write
uncertainty; it promises no rollback, checkpoint, or successful completion.

Only in-memory/faulting adapters exercise the runner path. The separate mapped
file opener is not a runner `Source` or CLI switch; no S3/parser-library adapter
is added. F04 materializes events per
document and ordered-list content has poor high-edit scaling; production
callers must measure representation and backpressure before using this seam
for corpus throughput. The checker rejects direct imports from
domain/content/stages into effects or known concrete file, mmap, socket,
network, stdio, and process modules; effects may import concrete I/O. This is
a direct-import check, not proof of transitive I/O independence. Its additional
D unittests and generated good/bad fixtures run with:

```sh
ldc2 -unittest -main -d-version=moduleCheckRunner -of=/tmp/scrubbed-module-edge-tests scripts/check_modules.d
/tmp/scrubbed-module-edge-tests
```
