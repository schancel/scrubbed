# Commands and shell completion

`scrubbed run` (alias `clean`) and `scrubbed repair` (alias `fix`) execute the
existing bounded filter pipeline. Running without a verb remains supported:
prior long options and defaults remain available, including `--list-filters`,
`--validate`, `--dry-run` and `--explain`. Failure exits follow the policy below.
Use `scrubbed --help` or `<verb> --help` for argparse-generated help and option
names.

```sh
scrubbed --input input.txt --output clean.txt
scrubbed run --input input.txt --output clean.txt --filters normalize-line-endings
scrubbed repair -i input.txt -o clean.txt --dry-run --explain
scrubbed clean --input input.txt --output clean.txt --validate
scrubbed --list-filters
```

Ordinary local file/tree runs also accept ordered v3 composition:

```sh
scrubbed run -i input.txt -o clean.txt \
  --stage clean=text-transform --filter normalize-line-endings
scrubbed run -i input.txt -o clean.txt --config job-v3.json
```

Composition tokens are mutually exclusive with `--filters` and `--config`.
Equivalent v3 tokens and JSON compile once to the same job. Selected-field
JSONL and durable manifest/error-journal routes use the same compiled job.

`extract` (alias `x`) exports a bounded selected HTML parse tree or Markdown.
It requires `--input`, `--output`, and `--format=tree-json|markdown`; the
format-specific extraction limits and provenance behavior are documented in
the HTML parser and Markdown guides. Its single selected HTML stage is likewise
compiled from canonical v3 configuration.

## `clean-web-document`

`clean-web-document` is the first named top-level preset command: a fixed,
versioned (`clean-web-document/v1`), **sealed** four-stage v3 job --
`text-transform`'s `fix-mojibake` filter, then `html-metadata-annotate`,
`html-main-content`, and terminal `pii-four-class` -- run through the same
compiler and job executor `run` uses. It shares one generic preset-dispatch
mechanism with `run`/`repair`/`extract`, not a parallel implementation: the
fixed token list lives in `source/job/presets.d` and lowers through the same
`job.cli_tokens` parser and `composition.compiler.compileJob` that a
hand-written `run --stage ...` invocation of the same four stages does.

```sh
scrubbed clean-web-document --input page.html --output page.txt
scrubbed clean-web-document --input pages/ --output clean/ --threads 4
scrubbed clean-web-document --emit-config
```

It accepts only `--input`, `--output`, `--threads`, `--max-queued-docs`,
`--max-input-bytes`, `--max-open-inputs`, and `--emit-config`. It does **not**
accept `--stage`, `--filter`, `--stage-option`, `--filter-option`, or any
other composition/dispatch token -- the chain is fixed for this version; use
`run` for custom stage/filter composition.

**Automatic PII-audit sidecar.** `pii-four-class` always produces a terminal
audit record, which `run`'s local-file execution path always requires an
explicit `--sidecar-output` destination for. Since `clean-web-document`'s
flag list is deliberately fixed and has no `--sidecar-output` flag,
`clean-web-document` derives that destination automatically from `--output`:

- `--output` a file: the sidecar is written to `<output>.pii-audit.json`.
- `--output` a directory (tree mode): the sidecar root is `<output>.pii-audit/`,
  mirroring the input tree exactly like a hand-written `--sidecar-output`
  directory root would (one `<name>.pii-audit.json` per processed file).

This is a new pattern with no other precedent in this codebase: it creates a
file the user did not name on the command line. To make sure that is never a
surprise, `clean-web-document` refuses to run -- before touching the input,
the output, or the sidecar path in any way -- if something already exists at
the derived sidecar path. It never silently overwrites it. Remove or move the
existing path aside, or choose a different `--output`, and retry.

**`--emit-config`.** Prints the compiled canonical v3 job JSON for
`clean-web-document/v1` (the same `canonicalJobJson` a hand-written
equivalent `run --stage ...` invocation would compile to) and exits 0. It
touches no input, output, or sidecar path at all -- not even to check
whether they exist -- and its output is deterministic for a fixed preset
version. This is provable structurally, not just empirically: the
`--emit-config` code path only ever reaches `job.presets`, the existing
`job.cli_tokens`/`job.json` parsers, and the existing, unmodified
`composition.compiler.compileJob`, none of which `scripts/check_modules.d`'s
existing module-layering rule permits to import `effects` or any concrete
I/O module (`std.file`, `std.stdio`, `std.socket`, `std.net`,
`std.process`).

Any unknown or malformed `clean-web-document` option, and any attempt to
pass a composition token, fails with exit 2 before any I/O, naming `run` as
the escape hatch for custom composition.

The built-in argparse completer supplies command and option **names only**;
it does not complete paths, filter names or argument values. Generate setup
for your shell:

```sh
source <(scrubbed completion init --bash)
# In zsh, enable `compinit` and `bashcompinit`, then:
source <(scrubbed completion init --zsh)
# In fish:
scrubbed completion init --fish | source
```

The generated setup calls the same `scrubbed` executable for candidates.
For direct checks, `scrubbed completion complete --fish -- re` emits `repair`,
and `scrubbed completion complete --zsh -- repair --th` emits `--threads`.
All three shells use the same nested `completion complete` surface. Zsh uses
Bash completion through `bashcompinit`; no native Zsh candidate generator is
claimed. Hidden top-level completion forms remain accepted only so setup
generated by older releases continues to work; they are not part of the public
interface or newly generated setup.

Exit codes:

- `0` — help, list, validation, or processing success.
- `1` — an acknowledged per-document failure, or an unresolved retry decision
  in opt-in manifest mode.
- `2` — a run-fatal invocation, config, output-policy, resource/admission,
  traversal, lost-acknowledgment, or unrecorded worker error (including a
  late symlink or a no-manifest worker failure).

Path, resource-limit and config/filter exclusivity checks remain in the
processing boundary.

To reproduce the release-active checks after building in release mode:

```sh
dub build --compiler=ldc2 --build=release
ldc2 -O -of=.dub/cli-command-check examples/cli/check.d
.dub/cli-command-check ./scrubbed
```

## `crawl`

`crawl` is a top-level command, not a `run`/`repair`/`extract` pipeline
variant: it dispatches straight to its own hand-rolled parser
(`source/effects/crawl_cli.d`) the same way `clean-web-document` dispatches
to its own preset path, before argparse's `run`/`repair`/`extract` machinery
is ever involved. It fetches pages over HTTP, discovers further same-crawl
links in each fetched HTML page, and saves the raw bytes to disk with a
concurrent, resumable frontier. **It is not a document-processing pipeline.**
No mojibake repair, no metadata/main-content extraction, no PII detection,
no `StageDocument` involvement anywhere in this command -- cleaning the raw
output it produces is a separate, later pass, e.g. `clean-web-document`
pointed at the `raw/` directory `crawl` wrote.

```sh
scrubbed crawl --seed https://example.com/ --corpus-dir ./corpus
scrubbed crawl --seeds seeds.txt --corpus-dir ./corpus \
  --concurrency 8 --max-pages 500 --scope same-origin
```

It accepts:

- `--seed <url>` -- an individual seed URL; repeatable.
- `--seeds <path>` -- a newline-delimited file of seed URLs; repeatable.
  Blank lines and lines starting with `#` are skipped; every remaining line
  must parse as an absolute URL. At least one `--seed` or `--seeds` is
  required.
- `--corpus-dir <path>` -- **required.** Output directory: `raw/` (fetched
  bodies), `manifest.jsonl` (one record per finished fetch attempt), and,
  unless `--in-memory` is given, `frontier.sqlite3` (the durable frontier
  database).
- `--db <path>` -- SQLite frontier database path. Default
  `<corpus-dir>/frontier.sqlite3`. Mutually exclusive with `--in-memory`.
- `--in-memory` -- use a non-durable in-memory frontier instead of SQLite.
  This is an explicit opt-out of resumability (see below); there is no
  database file to resume from afterward.
- `--max-pages <n>` -- maximum distinct admitted pages. Default `200`.
- `--max-pages-per-host <n>` -- maximum pages admitted per host. Default `50`.
- `--max-depth <n>` -- maximum discovery depth from a seed (a seed is depth
  `0`). Default `3`.
- `--concurrency <n>` -- number of concurrent worker OS threads, and the
  frontier's `maxActiveLeases` ceiling. Default `4`.
- `--min-host-delay-ms <n>` -- minimum delay, in milliseconds, between two
  requests to the same host. Default `3000`.
- `--scope <allowed-domain|same-origin|one-hop-external>` -- discovery scope
  policy. Default `allowed-domain`.
  - `allowed-domain`: a discovered link is only followed if its origin is an
    exact match (scheme + host + port; no suffix or subdomain matching)
    against the core origin set -- every seed's origin, plus any
    `--allowed-origin` values.
  - `same-origin`: a discovered link is only followed if its origin exactly
    equals the referring page's own origin.
  - `one-hop-external`: any discovered link is fetched and saved regardless
    of origin, but a page outside the core origin set is never itself a
    source of further discoveries -- external pages are reached at most one
    hop away from an in-scope page, never chained.
- `--allowed-origin <origin>` -- an extra origin added to the core origin set
  used by `allowed-domain` and `one-hop-external` scope; repeatable. Default:
  just the seeds' own origins.

**Resumability is real, not just "the command can be re-run."** By default
(no `--in-memory`) the frontier is a SQLite database at
`<corpus-dir>/frontier.sqlite3` (or `--db`'s path). If a crawl is killed --
including a hard `kill -9` mid-fetch -- and the same command is run again
against the same corpus directory (or `--db` path), it resumes rather than
restarting:

- Seeds that were already admitted come back `duplicate` on re-admission and
  are silently skipped; they are never re-fetched.
- Any candidate that was `leased` (fetch in flight) at the moment of the kill
  is durably stuck in that state in the database -- nothing else ever times
  a lease out on its own. Every `crawl` run therefore recovers orphaned
  leases before any worker starts, reclaiming every candidate still marked
  `leased` from a prior run so it becomes leasable again. Without this step,
  enough kills over time would eventually exhaust `--concurrency`'s active-
  lease ceiling and stall the crawl permanently.
- The frontier is deliberately never sealed at the end of a run, so a later
  invocation against the same database can keep expanding a crawl that
  merely ran out of `--max-pages` or was interrupted, not one the frontier
  considers exhausted.

`--in-memory` opts out of all of this on purpose: there is no database to
resume from, and a killed or restarted `--in-memory` crawl starts over from
its seeds.

**Failed fetches are recorded, never silently dropped.** Every finished
fetch attempt -- success or failure -- appends exactly one line to
`<corpus-dir>/manifest.jsonl`, opened in append mode so a resumed run keeps
prior history instead of truncating it. A successful line carries `url`,
`depth`, `discoveredFrom`, `fetchedAtUtc`, `finalUrl`, `httpStatus`,
`contentSha256`, `bodyBytes`, `contentType`, and `shardPath` (where the raw
body was written under `raw/`). A failed line carries `url`, `depth`,
`discoveredFrom`, `fetchedAtUtc`, `httpStatus`, `failureReason`, and
`failureCategory` -- inspect this file directly to see every page `crawl`
tried and failed on, rather than inferring failures from what's missing on
disk.

`crawl` exits `0` on a normal run, including one that resumes into an
already-fully-drained frontier and does no new work. Invalid or malformed
arguments (missing `--corpus-dir`, no seeds, an unknown flag, or
`--in-memory` combined with `--db`) exit `2` with `scrubbed:
crawl-invalid-arguments` on stderr, before any I/O. A run-fatal failure
(an unparsable seed URL, or a frontier that fails to open) exits `2` with
`scrubbed: crawl-refused`. There is no per-document exit-code signal like
`clean-web-document`'s `1`: individual fetch failures are recorded in the
manifest, not surfaced through the process exit code.

**Non-goals.** `crawl` is single-machine only -- there is no distributed or
sharded crawling across multiple processes or hosts against one frontier.
It does not render JavaScript or drive a headless browser; it fetches raw
HTTP responses and parses the HTML it gets back, nothing more.

## Dispatch v4

`run` and `repair` accept explicit dispatch v4 either through a version-4
`--config` or through `--dispatch-option`, `--route`, `--route-option`, and
`--action`, followed by `--common`. These tokens cannot be mixed with
`--config` or `--filters`. See [job-spec-v4.md](job-spec-v4.md) and the root
`scrubbed.dispatch.example.json`. Existing no-config, filter, legacy, and v3
invocations are unchanged.

```sh
scrubbed run --input input.txt --output clean.txt \
  --config scrubbed.dispatch.example.json --explain
scrubbed run --input input.txt --output clean.txt \
  --config scrubbed.dispatch.example.json --validate
```

The checked-in example routes only detected UTF-8 plain text through the
shipping `core-plain-text/v1` extractor and rejects all other outcomes. V4 is
also available to selected-field JSONL and the opt-in manifest-v2 and
failure-journal-v3 local routes. JSONL v4 explain records go to stderr;
ordinary local and durable diagnostics retain their existing streams. No
Office, PDF, image, OCR, or general archive extractor is registered.
