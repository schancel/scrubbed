# Commands and shell completion

`scrubbed run` (alias `clean`) and `scrubbed repair` (alias `fix`) execute the
existing bounded filter pipeline. Running without a verb remains supported:
all prior long options, defaults, `--list-filters`, `--validate`, `--dry-run`
and `--explain` retain their processing and exit behavior. Use `scrubbed
--help` or `<verb> --help` for argparse-generated help and option names.

```sh
scrubbed --input input.txt --output clean.txt
scrubbed run --input input.txt --output clean.txt --filters normalize-line-endings
scrubbed repair -i input.txt -o clean.txt --dry-run --explain
scrubbed clean --input input.txt --output clean.txt --validate
scrubbed --list-filters
```

`extract` (alias `x`) appears in generated help but is not implemented.
Executing it exits 2 with `scrubbed: extract is not yet available` on stderr
and creates no output. No extraction format is processed yet.

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

Exit 0 means help, list, validation or processing success; exit 1 means one
or more input files failed; exit 2 means an invocation, config, preflight or
traversal error (including a late symlink). Existing path, resource-limit and
config/filter exclusivity checks remain in the processing boundary.

To reproduce the release-active checks after building in release mode:

```sh
dub build --compiler=ldc2 --build=release
ldc2 -O -of=.dub/cli-command-check examples/cli/check.d
.dub/cli-command-check ./scrubbed
```
