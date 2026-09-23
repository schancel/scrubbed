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
and `scrubbed --fish -- repair --th` emits `--threads`. Zsh uses Bash
completion through `bashcompinit`; no native Zsh candidate generator is
claimed.

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
