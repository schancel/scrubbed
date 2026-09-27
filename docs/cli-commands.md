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

Exit 0 means help, list, validation or processing success. Exit 1 means an
acknowledged per-document failure or unresolved retry decision in opt-in
manifest mode. Exit 2 means a run-fatal invocation, config, output-policy,
resource/admission, traversal, lost-acknowledgment, or unrecorded worker error
(including a late symlink or a no-manifest worker failure). Existing path,
resource-limit and config/filter exclusivity checks remain in the processing
boundary.

To reproduce the release-active checks after building in release mode:

```sh
dub build --compiler=ldc2 --build=release
ldc2 -O -of=.dub/cli-command-check examples/cli/check.d
.dub/cli-command-check ./scrubbed
```
# Dispatch v4

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
