# Inspect a pipeline without writing output

These flags also work under the generated `run`/`clean` and `repair`/`fix`
commands. See [cli-commands.md](cli-commands.md) for command syntax, help and
shell completion.

The existing no-verb CLI accepts three additive flags:

- `--validate` checks the invocation, registered filters and their options, and
  input/output roots, then exits without visiting documents or creating output.
- `--dry-run` visits documents and runs the configured filter chain, but creates
  no output directory, destination file, or temporary file. Source files are
  unchanged, including when input and output name the same file.
- `--explain` writes one `EXPLAIN` record per visited file. It works with normal
  processing and dry-run. With `--validate`, no files are visited, so there are
  no records.

For example:

```sh
scrubbed --input ./incoming --output ./cleaned --config examples/inspection.json --validate
scrubbed --input ./incoming --output ./cleaned --config examples/inspection.json --dry-run --explain
```

Records are tab-separated with fixed fields:

```text
EXPLAIN<TAB>input="..."<TAB>output="..."<TAB>chain="..."<TAB>status=... [<TAB>reason="..."] [<TAB>detail="..."]
```

The quoted values are JSON strings, so tabs, newlines and other special
characters in paths or reasons cannot create extra fields or lines. Input and
output are absolute paths; avoid `--explain` if those paths are sensitive.
`changed` and `unchanged` compare filter output to input, including in dry-run;
normal processing still writes successful files even when unchanged. File mode
uses `changed`, `unchanged`, `failure`, or `canceled`; opt-in manifest mode also
uses `failed`, `uncertain`, `retry-required`, `retry`, `skipped`,
`dry-run-changed`, and `dry-run-unchanged`. Failures and cancellations include
a reason. Manifest failures and unresolved retry decisions include the exact
document ID and sink key in `detail`; acknowledged failures also include the
completed prefix. Parallel completion may reorder whole
records, but the field format is stable and records are not buffered for
whole-tree sorting.

Exit status is `0` for success, `1` for acknowledged manifest per-document
failures or unresolved retry decisions, and `2` for invocation/configuration,
output-policy, resource/admission, traversal, lost-acknowledgment, or
unrecorded worker failures. A discovered file rejected from admission after a
worker-fatal event receives `status=canceled` with reason `canceled after fatal
processing failure`; pending files canceled by a traversal error receive
`status=failure` with reason `canceled after traversal error`.
Validation is a preflight of config and roots,
not a transactional scan of an entire tree. A later traversal error, such as a
symlink discovered after earlier files, does not roll back earlier normal-mode
outputs. The existing `--threads` and input-resource limits still apply.
