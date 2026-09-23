# Embedding cluster feasibility experiment

This directory is an evidence-only, non-production comparison between a sparse
lexical baseline and one local dense embedding candidate. It does not add a
runtime dependency or propose adoption.

## Frozen inputs

`generate_fixtures.d` deterministically authors 36 CC0 test documents and 18
pair judgments using production `DocumentId` construction. Train and held-out
sets each contain duplicate, related, unrelated, and explicit abstention cases.
The held-out labels are never inputs to threshold selection. The checked-in
fixture hashes are enforced by `check.d`.

## Pinned external candidate

`provenance.tsv` records the sources, versions, byte sizes, licenses, license
hashes, and artifact hashes. The experiment used llama.cpp b11115's official
macOS arm64 archive and the F16 GGUF model layer from Ollama's immutable
`all-minilm:22m` manifest. The tool is MIT licensed and the model is
Apache-2.0. Neither downloaded artifact is redistributed here.

Before extraction, acquisition was stopped unless the archive was at most 16
MiB and its SHA-256 matched. Extraction occurred in private temporary scratch
and was stopped unless the resulting tree stayed below 96 MiB. Model download
was stopped unless its declared and received size stayed below 64 MiB and its
SHA-256 matched. Total scratch was capped at 192 MiB. Actual sizes were
11,205,309 bytes for the archive, 28,131,328 bytes unpacked, 45,949,216 bytes
for the model, and 86,634,496 bytes total scratch.

The exact runtime options and limits are in `options.tsv`. `contract.d` owns
the complete ordered provenance/options bytes, server argument vector, artifact
hashes, and limits consumed by the runner, crash parent, and verifier. The
runner verifies the binary and model hashes before starting, binds only
localhost, disables devices and the web UI, limits CPU/log/output/HTTP/wall
resources, and uses a 10 ms macOS `proc_pid_rusage` guard that kills the process
group above 512 MiB RSS. Inputs are serialized directly into four-row shards,
one decoded server response at a time. Scoring reloads only the two vectors for
the current pair from immutable shards; the runner admits every decoded vector
before allocation and releases each bounded window.

## Reproduction

With the pinned binary and model already in private scratch:

```text
ldc2 -O3 -release -Isource -of=/tmp/embedding-fixtures \
  experiments/embedding_clusters/generate_fixtures.d source/domain/document.d
/tmp/embedding-fixtures experiments/embedding_clusters/fixtures

ldc2 -O3 -release -of=/tmp/embedding-run \
  experiments/embedding_clusters/run_evaluation.d \
  experiments/embedding_clusters/contract.d
ldc2 -O3 -release -of=/tmp/embedding-crash \
  experiments/embedding_clusters/crash_resume.d \
  experiments/embedding_clusters/contract.d
/tmp/embedding-crash /tmp/embedding-run LLAMA_SERVER MODEL \
  experiments/embedding_clusters/fixtures/corpus.tsv \
  experiments/embedding_clusters/fixtures/labels-train.tsv \
  experiments/embedding_clusters/fixtures/labels-heldout.tsv \
  NEW_EVIDENCE_DIR PRIVATE_CRASH_SCRATCH \
  7c879bfce0552b1e644857ef6950130537e16b6fa3703737be8b3c334f660799

ldc2 -O3 -release -of=/tmp/embedding-check \
  experiments/embedding_clusters/check.d \
  experiments/embedding_clusters/contract.d
/tmp/embedding-check
```

Both evidence and crash-scratch paths must be new. The D parent owns and reaps
the server, abruptly sends SIGKILL to the evaluator at pending, orphan, and
committed publication boundaries, then runs restart/replay.

The verifier recomputes fixture, index, shard, preserved-byte, score, threshold,
prediction, edge, cluster, summary, and result digests. Release-active negative
controls reject label leakage, duplicate/missing IDs, incorrect index version,
incorrect shard digest, replay drift, over-ceiling buffering, a false quality
claim, any metadata row drift, false artifact size/source/license, non-loopback
bind, device enablement, and changed resource caps.
