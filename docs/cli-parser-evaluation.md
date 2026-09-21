# CLI parser spike (issue #3)

Recommendation: **adopt `argparse` 2.0.2 for the future command tree, with a small compatibility adapter at integration time**. The isolated spike demonstrates generated command help, aliases, required/typed arguments, and command/option-name completion. It does not demonstrate argument-value completion or production processing. U02 owns integration; nothing here changes the shipping CLI.

## Reproduce

From the repository root, on Darwin arm64 with LDC 1.43.0 and DUB 1.42.0:

```sh
dub build --compiler=ldc2 --build=release --dest=.dub/cli-baseline
cd experiments/cli
dub build --compiler=ldc2 --build=release --dest=.dub/normal
dub build --compiler=ldc2 --build=release --d-version=argparse_completion --dest=.dub/complete
ldc2 -O -of=.dub/check check.d
.dub/check ../../.dub/cli-baseline/scrubbed .dub/normal/scrubbed-cli-spike .dub/complete/scrubbed-cli-spike
ldc2 -O -of=.dub/bench bench.d
.dub/bench ../../.dub/cli-baseline/scrubbed .dub/normal/scrubbed-cli-spike
wc -c ../../.dub/cli-baseline/scrubbed .dub/normal/scrubbed-cli-spike
```

The experiment pins DUB [`argparse` 2.0.2](https://code.dlang.org/packages/argparse/2.0.2), [BSL-1.0](https://github.com/andrey-zherikov/argparse/blob/v2.0.2/LICENSE.txt), in its own manifest and selection file. Its `-g` matches production `dub.json`; both applications use LDC, DUB's release build (`releaseMode`, `optimize`, `inline`), and the same host. The completion executable is a separate build of the same D source with `argparse_completion` enabled. All executables and benchmark artifacts are ignored; the spike only prints parsed arguments and never opens an input or output path.

## Reviewable output transcript

The `check.d` runner asserts 22 outcomes across baseline, spike, and completion builds. Representative captured output follows (paths and the machine-specific completion executable are abbreviated):

```text
$ baseline --help
scrubbed
          --input Input file or directory tree to process
         --output Output path (mirrors input tree structure when --input is a directory)
        --filters Comma-separated filter chain, applied in order
         --config JSON file containing an ordered filter list and per-filter options
        --threads Worker thread count for the TaskPool (default: all cores)
   --list-filters Print registered filter names and exit
-h         --help This help information.
exit=0

$ spike --help
Usage: scrubbed [-h] <command> [<args>]
Parser-only preview; no input is opened or modified.
Available commands:
  run,clean     Run the legacy file-cleaning options; also the no-verb default.
  repair,fix    Repair text in a file or directory without extracting it.
  extract,x     Extract text before applying a filter chain.
exit=0

$ spike repair --help
Usage: scrubbed repair -i INPUT -o OUTPUT [-j THREADS] [-h]
Required arguments:
  -i INPUT, --input INPUT
  -o OUTPUT, --output OUTPUT
Optional arguments:
  -j THREADS, --threads THREADS
exit=0

$ spike extract --help
Usage: scrubbed extract -i INPUT -o OUTPUT [-f FORMAT] [-h]
exit=0
$ spike run --help
Usage: scrubbed run [-i INPUT] [-o OUTPUT] [--filters FILTERS] [--config CONFIG] [--threads THREADS] [--list-filters] [-h]
exit=0

$ spike fix -i in -o out -j 3
SubCommand!(Repair, Extract, Default!(Run))(Repair("in", "out", 3))
exit=0
$ spike x -i in -o out -f html
SubCommand!(Repair, Extract, Default!(Run))(Extract("in", "out", "html"))
exit=0
$ spike --input in --output out --threads 3 --filters normalize-line-endings
SubCommand!(Repair, Extract, Default!(Run))(Run("in", "out", "normalize-line-endings", "", 3, false))
exit=0
$ spike --list-filters
SubCommand!(Repair, Extract, Default!(Run))(Run("", "", "normalize-line-endings,strip-control", "", 1, true))
exit=0

$ spike repair --input in
Error: The following argument is required: '-o'
exit=2
$ spike repair -i in -o out -j abc
Error: Unexpected 'a' when converting from type string to type uint
exit=2
$ spike repair -i in -o out --bogus
Error: Unrecognized arguments: ["--bogus"]
exit=2
$ spike unknown
Error: Unrecognized arguments: ["unknown"]
exit=2
$ spike
--input and --output are required (--list-filters to see what's available)
exit=2
```

The default `Run` subcommand accepts all old no-verb flag names (`--input`, `--output`, `--filters`, `--config`, `--threads`, `--list-filters`); the spike manually preserves the missing input/output exit-2 rule, except for `--list-filters`. `argparse`'s default error code is 1; the spike explicitly configures 2 to match the current CLI. The baseline's `--help` exits 0; the low-level `parseArgs` result must be returned via `result.exitCode` because a help request is not a parse success. This was caught by the executable checks.

## Completion probe

`argparse`'s [completion API](https://andrey-zherikov.github.io/argparse/shell-completion.html) generates a separate completer. The check runner verifies these actual outputs:

```text
$ complete init --bash --commandName scrubbed
complete -C 'eval <completer> --bash -- $COMP_LINE ---' scrubbed
$ complete init --zsh --commandName scrubbed
# Ensure that you called compinit and bashcompinit ...
complete -C 'eval <completer> --bash -- $COMP_LINE ---' scrubbed
$ complete init --fish --commandName scrubbed
complete -c scrubbed -a '(COMMAND_LINE=(commandline -p) <completer> --fish -- (commandline -op))' --no-files
$ complete complete --bash -- re
repair
$ complete complete --fish -- repair --th
--threads
```

Zsh uses Bash's completion mechanism and requires `compinit` plus `bashcompinit`; it is not a native Zsh generator. The code has not been installed into an interactive shell; the supported setup and candidate-generation paths were executed as subprocesses. **Argument-value completion is unavailable in 2.0.2's built-in completer.** A probe of `complete complete --fish -- extract --format ''` returns command/option names, not format values; the [upstream docs](https://andrey-zherikov.github.io/argparse/shell-completion.html) explicitly limit completion to names. U02 would need a separate narrow value-completion layer if that is required.

## Same-build startup and size

Measured with the commands above on this host; `bench.d` runs each `--help` executable 5 warmups and 100 timed subprocesses, reports the median, and checks a zero exit. These are rough end-to-end startup observations, not statistically isolated parser cost:

| Release executable | Median `--help` invocation | File bytes |
| --- | ---: | ---: |
| Current CLI | 5,200 µs | 1,602,296 |
| Isolated argparse spike | 5,529 µs | 1,701,472 |

The spike was 329 µs (~6.3%) slower and 99,176 bytes (~6.2%) larger in this run. The programs have different non-parser contents, so these deltas are not a causal parser-overhead estimate. The measured cost is **per CLI invocation**, not per document; it does not benchmark any file-processing path. Repeated runs varied with host load, so U02 should remeasure the integrated candidate before making a performance commitment.

## Migration and compatibility risk

- `argparse` supplies the command tree and generated help without a hand-written dispatcher; an adapter should map its parsed `Run` values into the existing `runApp` options and preserve the no-verb form. The spike is a parser-only illustration, not that adapter.
- Preserve the current special `--list-filters` behavior, default `threads = totalCPUs`, config/filter exclusivity, thread positivity, path validation, and exact processing semantics. The spike accepts the names but does not perform these production checks or print the registered filter list. `repair` uses typed `uint` for demonstration; production's `size_t` range must be considered before reusing it. The spike's `Run` uses `size_t` but a placeholder default of 1.
- Generated help will change and introduce aliases/short options; scripts that inspect help or depend on old unknown-token behavior need compatibility tests. The current CLI treats `repair --help` as root help, while the proposed CLI would treat it as repair help.
- The BSL-1.0 dependency would be new to the shipping binary; @schancel owns dependency/license acceptance and eventual integration. Rolling back this evaluation deletes `experiments/cli/` and this document; production is untouched.

This evidence supports adoption for help and command structure, with the above adapter/tests as a prerequisite. If value completion is a requirement for initial U02 delivery, retain `std.getopt` or defer adoption until the separate completion layer is scoped; `argparse` alone does not meet that requirement.
