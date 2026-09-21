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

Document/content/input/output/job boundaries discussed in the roadmap are
proposals, not modules or APIs in this checkout. Do not depend on them when
extending a current filter.
