# Source ownership

The executable entry is [`app.d`](app.d): `main(string[] args)` calls
`cli.runApp`, prints an uncaught exception, and returns exit code 2. Its only
application dependency is `cli`.

[`cli.d`](cli.d) owns argument and JSON-config parsing, path validation,
directory traversal, parallel per-file work, input `MmFile` lifetime, and
atomic output replacement. `runApp(string[] args)` builds a `Pipeline` before
walking files, then calls `processOne` for each file. A file failure is
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

For mapping and output-commit details, see the [architecture map](../docs/architecture.md).
For filter work, start with the [filter guide](filters/README.md), then run
`dub test` and `dub build --build=release` from the repository root.
