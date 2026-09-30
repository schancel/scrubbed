# Near-duplicate pruning

This example compares two similar documents and one unrelated control with the
real corpus-level stage shipped by `scrubbed run`.

```sh
scratch=$(mktemp -d)
./scrubbed run --input examples/corpus/near-dedup/inputs/ \
  --output "$scratch/output" --sidecar-output "$scratch/sidecars" \
  --stage sig=similarity-signature-annotate \
  --stage publish=document-metadata-publish \
  --stage prune=prune-near-duplicates \
  --stage-option policy=text:keep-longest
```

Use `policy=text:keep-first` to keep the lowest stable document ID instead.
Omitting `policy` defaults to `keep-first`.

Pruning is non-destructive: all three primary outputs remain. The pruned
document receives a mandatory
`*.prune-near-duplicates-decision.json` sidecar naming its surviving
representative and matching bucket. `--dry-run` is rejected because the
decision sidecar is required.

The fixtures are authored, synthetic, and MIT-licensed. They are not a
training corpus; provenance and hashes are in
[`manifest.json`](../../corpus/near-dedup/manifest.json).

## Check it

```sh
dub build --build=release --compiler=ldc2
ldc2 -O3 -release -preview=dip1000 -i -Isource \
  -of=.dub/near-dedup-check examples/pipelines/near-dedup/check.d
.dub/near-dedup-check ./scrubbed
```

The checker runs default, `keep-first`, and `keep-longest` from clean scratch
directories. It verifies the fixture manifest, unchanged primary outputs,
metadata identities, exact decision schema and bucket, policy outcomes, and
the unrelated negative control.
