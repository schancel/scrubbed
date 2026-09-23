# Embedding intrinsic-dimension evaluation

This directory is a repository-only, D-only evaluation of `twonn-mle:v1` over
immutable embedding shards. It is evidence, not a production feature or a
mandatory embedding pass. The result belongs to the named corpus, shard, or
cluster population; it is never copied onto each member document.

`evaluation.d` validates the #66 index, model, dimension, row counts, boundary
IDs, and every shard digest before evaluation. IDs and shard digests are then
canonicalized, so an index traversal permutation does not change the result.
For each selected ID the evaluator repeatedly scans the immutable rows and
holds only the current decoded vector and one candidate. Admission occurs
before allocation. The O(point-count) retained state is IDs, hashes, and one
scalar log-ratio per usable point—never a corpus vector array or vector map.

`generate_fixtures.d` authors distinct train and held-out line, plane, and 5-D
linear-manifold controls, duplicate/degenerate and too-small controls, and a
384-point material fixture. `check.d` independently recomputes the held-out
line formula, validates frozen evidence, exercises sensitivity and typed
abstention, permutes shard order, invalidates identities, and runs the
one-vector retained-buffer mutant. `crash_resume.d` SIGKILLs the evaluator
after adjacent pending output exists and proves the prior result survives,
then proves restart and replay bytes. `measure.d` records wall/CPU time, process
peak RSS, current-thread GC allocations, input disk bytes, throughput, and the
decoded-vector peak. Resource observations vary by host and are not included in
the byte-stable checker.

## Reproduction

Run from the repository root on a machine with LDC:

```text
ldc2 -O3 -release -i -I. -of=/tmp/embedding-dimension-generate \
  experiments/embedding_dimension/generate_fixtures.d
/tmp/embedding-dimension-generate /tmp/embedding-dimension-fixtures
diff -ru experiments/embedding_dimension/fixtures \
  /tmp/embedding-dimension-fixtures

ldc2 -O3 -release -i -I. -of=/tmp/embedding-dimension-run \
  experiments/embedding_dimension/run_evaluation.d
ldc2 -O3 -release -i -I. -of=/tmp/embedding-dimension-check \
  experiments/embedding_dimension/check.d
/tmp/embedding-dimension-check experiments/embedding_dimension

ldc2 -O3 -release -i -I. -of=/tmp/embedding-dimension-crash \
  experiments/embedding_dimension/crash_resume.d
/tmp/embedding-dimension-crash /tmp/embedding-dimension-run \
  experiments/embedding_dimension/fixtures/heldout-line/index.tsv \
  /tmp/embedding-dimension-crash-result.tsv

ldc2 -O3 -release -i -I. -of=/tmp/embedding-dimension-measure \
  experiments/embedding_dimension/measure.d
/tmp/embedding-dimension-measure experiments/embedding_dimension \
  /tmp/embedding-dimension-resources.tsv
```

To regenerate deterministic result tables after an intentional estimator or
fixture change, run the checker once with `--write-evidence`, inspect the diff,
then rerun it without that flag. `resources.tsv` is regenerated only by the
optimized measurement command and must be read as a dated machine observation.
