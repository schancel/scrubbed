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
`OutputName` is separate and does not enter the key. `DocumentViewOwner.mapFile`
opens and exclusively owns a mapping until `close`; its checked `at`/iteration
access borrows bytes without an eager whole-file copy or an escaping slice.
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
