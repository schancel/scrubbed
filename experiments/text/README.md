# Local mojibake trace

From the repository root:

```sh
ldc2 -O -release -enable-inlining -Isource experiments/text/local_mojibake.d \
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

`compare_cli.d` reads two JSON reports from the unchanged A00 D CLI harness,
requires identical fixture/harness hashes and byte-exact successful outputs,
then prints the five raw mojibake wall-time samples. It performs no benchmark
run itself. Compile with `ldc2 -O -release experiments/text/compare_cli.d
-of=/tmp/scrubbed-compare-cli`, then pass the base and candidate report paths.
