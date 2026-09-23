# Embedding clustering evaluation

Status: feasibility evidence only; no production adoption is recommended by
this experiment.

## Question and design

The experiment asks whether a bounded local semantic embedding pass can improve
duplicate/related-document grouping over a sparse lexical Jaccard baseline,
while preserving stable typed identities and resumable deterministic artifacts.
It uses 36 short, authored CC0 documents split before evaluation into 18 train
and 18 held-out documents. Each split has nine judgments: three duplicates,
three related pairs, two unrelated pairs, and one abstention. Thresholds are
selected only from the eight non-abstained train judgments and then frozen for
held-out scoring.

The native candidate is llama.cpp b11115 (`d5f66492e`) serving the 384-wide
F16 `all-MiniLM-L6-v2` GGUF from the immutable Ollama `all-minilm:22m`
manifest. The exact artifact, license, and license-file hashes are recorded in
`experiments/embedding_clusters/provenance.tsv`; exact inference arguments and
caps are in `options.tsv`. The MIT tool and Apache-2.0 model remain external and
are not shipped by this repository.

## Frozen result

| Method | Duplicate threshold | Related threshold | Held-out correct | Duplicate TP/FP/FN | Related TP/FP/FN | Cluster splits/merges |
|---|---:|---:|---:|---:|---:|---:|
| MiniLM embedding | 0.713998708 | 0.255346808 | 8/8 | 3/0/0 | 3/0/0 | 0/0 |
| Lexical Jaccard | 0.229411765 | 0.000000000 | 6/8 | 3/0/0 | 3/2/0 | 0/0 |

The embedding candidate separated the two held-out unrelated paraphrase-like
cases that the tiny-corpus lexical threshold classified as related. This is a
result on an intentionally small authored feasibility corpus, not an estimate
of production accuracy or prevalence. Abstained cases are visible in scores but
excluded from threshold fitting and accuracy counts.

The combined deterministic result SHA-256 is
`7c879bfce0552b1e644857ef6950130537e16b6fa3703737be8b3c334f660799`.
The verifier independently reconstructs all pair scores, train-only thresholds,
predictions, all within-split edges, clusters, and quality counts from preserved
shard bytes.

## Resource and restart evidence

The first run was deliberately stopped with exit 86 immediately after atomically
publishing shard 0 (four stable IDs). The resumed run validated and reused that
shard, computed the remaining eight shards, and observed:

- 637 ms total runner time, including local server startup and inference;
- 136,757,248 bytes child high-water RSS, below the 512 MiB guarded ceiling;
- four maximum live embedding records, matching the shard ceiling;
- 651,346 bytes of experiment output.

The following replay reused all nine committed shards, computed none, completed
in 8 ms, and produced the same result digest. Shards are immutable versioned
payloads whose index binds model hash, corpus hash, payload hash, row count, and
first/last typed IDs. A changed version, digest, duplicate ID, missing ID, or ID
order is rejected before reuse.

Package/acquisition evidence: the signed-by-hash release archive was 11,205,309
bytes; its extracted directory was 28,131,328 bytes; the model was 45,949,216
bytes; private scratch totaled 86,634,496 bytes. No network access exists in the
evaluation runtime path.

## Limits and next decision

This evidence does not cover multilingual text, OCR noise, long documents,
adversarial embeddings, approximate-nearest-neighbor indexing, model update
governance, x86/Linux packaging, or representative production distributions.
The macOS-only RSS guard is sampled every 10 ms and terminates the model process
group on breach; another platform would require its own verified hard bound.
All-pairs graph construction is deliberately acceptable only for this 36-item
experiment and is not a scalable design.

Before any adoption decision, independently review the evidence and license
provenance, then evaluate a separately approved, representative and privacy-safe
corpus with predefined error costs and platform-specific resource isolation.
Production integration, dependency addition, network operation, and model
distribution remain explicitly out of scope.
