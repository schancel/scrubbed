# Local mojibake trace

From the repository root:

```sh
ldc2 -O -release -preview=dip1000 -enable-inlining -Isource experiments/text/local_mojibake.d \
  source/filters/mojibake.d source/pipeline.d -of=/tmp/scrubbed-local-mojibake
/tmp/scrubbed-local-mojibake
```

The D trace pins three inputs and checks the former whole-string strategy
against the local strategy before timing either. Each line reports 100
iterations in the same optimized binary, elapsed microseconds, and the change
in `GC.stats().usedSize` after a collection before the loop. That heap delta
is retained GC memory, not a count of all allocations or a throughput claim.
Run-to-run timing and GC collection can vary. The trace does not replace the
F01 or T03 quality gates.
Both expected-output checks remain active under `-release`. Run
`/tmp/scrubbed-local-mojibake --probe-wrong-old-expected` and
`/tmp/scrubbed-local-mojibake --probe-wrong-new-expected` to deliberately
substitute a wrong expected output; each must exit nonzero before timing the
mixed sample.

`compare_cli.d` reads JSON reports produced by
[`benchmarks/external_comparator.d`](../../benchmarks/README.md#shared-external-tool-comparator)
(schema `scrubbed-external-comparator-v1`), requires identical fixture/harness
hashes and byte-exact successful outputs for the pinned
`mojibake/scrubbed-vs-ftfy` case, then prints its four A/B/A/B wall and CPU
(user plus system) samples per run, tagged by tool, with binary hashes. It
performs no benchmark run itself. This reads the *current* external
comparator report shape only; it does not read the retired
`scrubbed-cli-baseline-v1` (A00) shape that `benchmarks/cli_baseline.d`
emitted before the ftfy case moved out of it, and the two are intentionally
not interchangeable (see the report-format-break note in
[`benchmarks/README.md`](../../benchmarks/README.md#shared-external-tool-comparator)).
Compile with `ldc2 -O -release experiments/text/compare_cli.d
-of=/tmp/scrubbed-compare-cli`, then pass the base and candidate report paths.
The comparator uses release-active checks, including exactly four samples in
A/B/A/B order per report. To verify rejection rather than trust those checks,
`bad_cli_report.d` changes one field in an otherwise valid comparator report:

```sh
ldc2 -O -release experiments/text/bad_cli_report.d -of=/tmp/scrubbed-bad-cli-report
/tmp/scrubbed-bad-cli-report base.json bad.json harness
/tmp/scrubbed-compare-cli base.json bad.json # must exit nonzero
```

Modes `harness`, `fixture`, `expected`, `case`, `exact`, `count`, `status`,
and `output` exercise `compare_cli.d`'s release-mode rejection checks. Two
further modes, `tool-order` (swaps the first two samples' `tool` tags) and
`acquisition-order` (reorders the recorded pinned-package acquisition list),
plus `duplicate-case` (appends a second case with the same name), are not
policed by `compare_cli.d` itself; they exist so
[`benchmarks/external_comparator_check.d --check`](../../benchmarks/README.md#shared-external-tool-comparator)
can be proven to reject them, since that release-active D-only checker, not
this inspection utility, is the required negative-control proof for the
new report shape.
