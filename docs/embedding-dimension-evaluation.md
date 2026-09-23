# Embedding-space intrinsic-dimension evaluation

Status: bounded feasibility evidence only. This does not expose a CLI/config
surface, add a runtime dependency, authorize model downloads, or recommend a
mandatory production pass.

## Quantity and estimator

The evaluated quantity is the local scaling dimension of a sampled embedding
point cloud under a stated distance metric and normalization. For every point,
`twonn-mle:v1` finds the nearest and second-nearest nonzero distances `r1` and
`r2`, forms `mu = r2/r1`, and reports the pinned finite-sample maximum-
likelihood convention

```text
d_hat = (m - 1) / sum_i(log(mu_i))
```

where `m` is the count of usable ratios. This TwoNN-style estimate assumes
locally approximately uniform sampling, meaningful nearest-neighbor distances,
and enough distinct observations. It is neither exact Hausdorff dimension nor
Kolmogorov/compression complexity, and it is not a semantic quality or
intelligence score. Small authored controls establish implementation behavior;
they do not universally calibrate the estimator.

Every result binds the result/estimator versions, population kind/name, model
digest, metric, normalization, seed, sample size, stability policy, vector
dimension, sorted shard/index digests, and sorted member IDs. Consequently it
is corpus-, shard-, cluster-, or document-chunk-set-bound according to the
declared population. A corpus statistic must not be attached to every document
as though each document independently measured it.

## Sampling, uncertainty, and abstention

Sampling uses SHA-256 ranks of `(seed, member ID)` and then restores stable ID
order for scanning. The stability interval is the minimum/maximum estimate from
nine deterministic, hash-ranked 80% subsamples of the retained per-point log
ratios. It is a stability interval, not a population confidence guarantee.
The evaluator abstains on fewer than 12 points, too few valid ratios,
nonfinite/malformed/model/dimension drift, degenerate ratios, or a stability
width greater than 1.25 times the estimate. Zero-distance duplicate pairs are
skipped and explicitly warned; a wholly duplicated population abstains.

## Evidence

The train controls were available while choosing the pinned convention. Their
frozen estimates for known dimensions 1/2/5 are 1.186/2.162/5.239. The held-out
controls use separate seeds and point counts, and are reported separately:

| Population | Points | Known dimension | Estimate | Stability interval |
|---|---:|---:|---:|---:|
| line | 104 | 1 | 0.816 | 0.757–0.900 |
| plane | 136 | 2 | 1.959 | 1.814–2.073 |
| linear 5-D control in 8-D | 200 | 5 | 4.449 | 4.197–4.856 |

The 64-point duplicate control reports 21 zero-distance pairs, a warning, and
a nonzero 1.217–1.704 interval derived from 28-point subsamples of its 35 usable
ratios. A 14-point duplicate subsample has only 12 usable ratios; its 80%
resample would fall below the minimum, so it abstains with an explicit warning.
The all-duplicate 32-point control abstains as `duplicate-or-degenerate`; the
8-point control abstains as `insufficient-sample`; a deliberately strict
stability policy abstains as `unstable-resampling`. The checker independently
computes the held-out line distances and formula rather than trusting evaluator
serialization.

`evidence/sensitivity.tsv` varies 32/64/full sample size, three seeds,
Euclidean/no-normalization versus cosine/L2, and the stability threshold.
Duplicate-rate behavior is in `results.tsv`. A changed model identity is
rejected rather than silently reusing evidence. This experiment has only one
frozen real model: comparing model quality or claiming model invariance would
require a separately approved, immutable second model rather than relabeling
the same vectors.

The immutable #66 corpus has 36 points from the pinned 384-wide MiniLM shard
set. With cosine distance and L2 normalization it reports 1.530, stability
1.379–1.912, two duplicate pairs, and a two-vector decoded peak. The largest
#66 embedding cluster has two members, below the 12-point policy, so every
cluster-level evaluation abstains instead of emitting a decorative number.

## Boundedness, identity, and restart

The evaluator validates committed immutable #66 shard bytes and rescans them in
stable member-ID order. It retains only one current and one candidate decoded
vector plus O(point-count) scalar/ID metadata. The 384-point negative control
observes a peak of two; forcing the ceiling to one rejects admission before the
candidate vector allocation. Reversing index/shard traversal yields identical
result bytes. Changing shard bytes, model, metric/normalization, seed, sample
size, or stability options changes identity or rejects verification. Stability
widths use a canonical 17-significant-digit representation: thresholds only
`2e-12` apart around the observed boundary have distinct identities and the
expected opposite statuses.

Publication writes a complete adjacent `.pending` result and atomically
renames it. The crash harness sends SIGKILL after pending bytes exist, verifies
the prior committed result is unchanged, then verifies restart and replay
produce identical complete bytes.

## Resource observation and limits

The checked-in optimized macOS arm64 observation (`ldc2 -O3 -release`, one run)
reports:

| Population | Points | Wall | CPU | Peak RSS | GC allocated | Input disk | Pair throughput |
|---|---:|---:|---:|---:|---:|---:|---:|
| small | 104 | 0.398 s | 0.305 s | 3.67 MB | 16.39 MB | 16.29 KB | 26,898/s |
| material | 384 | 6.825 s | 4.437 s | 3.82 MB | 291.06 MB | 81.86 KB | 21,548/s |

Peak RSS is Darwin `getrusage` high-water RSS; allocation is cumulative current-
thread GC allocation, not retained heap; timings include shard validation and
repeated scans but not compiler startup. The quadratic exact scan and repeated
text decoding make this a bounded evaluation, not a scalable production design.
Fresh measurements will vary by host. The negative control is necessary because
low observed RSS alone does not prove the decoded-vector lifetime invariant.

Production exposure, approximate-nearest-neighbor design, representative
privacy-approved corpora, model governance, and any result schema/attachment
decision require later tickets and review.
