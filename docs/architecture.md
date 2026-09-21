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
`OutputName` is separate and does not enter the key. The view owner copies
input bytes at construction, so a caller may release a mapping independently.
`read` returns another copy, and reads of views fail after owner close. The
current CLI retains its own mapping-lifetime logic and is not wired to this
facade.

Content pieces, job/stage scheduling, and provider transport boundaries remain
proposals, not modules or APIs in this checkout. Do not depend on them when
extending a current filter.
