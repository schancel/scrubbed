# Compressibility annotation (issue #168)

**Status: opt-in v3 stage, `compressibility-annotate`.** Not wired into any
default chain -- a caller must name it explicitly in a job's `stages` list.
It never makes a keep/reject/quarantine decision and never feeds the
separate, pre-existing `quality_features`/`quality_overlay` gate.

## What this is, and what it is not

This stage measures two independent, named, versioned proxies related to a
document's "compressibility," and writes them into one compact
`compressibility` extension field via #285's `StageDocument.metadata` API,
to be published later by the existing, unmodified `document-metadata-publish`
terminal stage:

1. **Order-0 token-frequency entropy** (`domain.token_entropy.tokenEntropy`):
   `H = -sum(p_i * log2(p_i))` over lowercased Unicode letter/number/
   underscore token runs (minimum 2 codepoints; digits retained). This is a
   proxy correlated with lexical diversity, computed over the document's own
   content bytes reinterpreted as text.
2. **zstd level-19 compressed/raw byte ratio**, named exactly
   `compressedToRawRatio` (never bare `ratio`; smaller means more
   compressible), computed with the vendored, statically-linked zstd 1.5.7
   release already used for decompression elsewhere in this project.

Neither metric is, or claims to be, Kolmogorov complexity, which is
uncomputable. The extension field is named `compressibility`, never
`kolmogorov_complexity`, anywhere in the implementation or its documentation.
No corpus-wide or pairwise normalized compression distance is computed --
this stage only ever measures one document against itself.

**Anti-comparison rule.** A `compressedToRawRatio` or `entropy` value is only
ever comparable to another value produced under the exact same
`schema`/`compressorVersion`/`compressorLevel`/`tokenizerVersion` identity
recorded alongside it in the same field. A value from a different schema
version, a different zstd level, or a retokenized entropy rule is never
comparable, even where the field name looks the same.

## The deliberate entropy/ratio asymmetry

Entropy **requires valid UTF-8** -- tokenization cannot run over arbitrary
bytes, so invalid UTF-8 makes entropy abstain (`EntropyStatus.invalidUtf8`).
The compression ratio **does not require UTF-8 validity** -- zstd compresses
whatever raw bytes the stage receives, valid text or not. This means invalid
UTF-8 input still produces a fully valid annotation: entropy abstains while
the ratio still computes normally over the same bytes. This asymmetry is
intentional and is proven directly by a dedicated fixture in
`source/effects/compressibility_annotate_stage.d`.

## Abstention, never quarantine, for either metric

- **Entropy** abstains as `noTokens` only at zero qualifying tokens (a real,
  independent case -- distinct from `invalidUtf8`). `0.0` is itself a
  legitimate computed entropy value (a document reduced to one repeated
  token), never a sentinel for "nothing measured": the typed status enum is
  always the authoritative signal, never the numeric field's value.
- **Ratio** abstains as `belowFloor` under 64 raw bytes or `aboveCap` over 1
  MiB raw bytes -- both fixed schema constants, never caller-tunable. Below
  the floor, zstd's fixed per-frame overhead dominates any real signal;
  above the cap, cross-run comparability of one fixed schema identity
  matters more than measuring arbitrarily large documents. In both
  abstention cases, `rawBytes`/`compressedBytes` are still recorded
  truthfully -- compression still actually runs; only the normalized ratio
  itself is withheld.
- The **only** quarantine this stage ever raises is `rawLimit`, from the
  `max-input-bytes` option below -- a resource/DoS bound, not a
  "compressibility could not be computed" case.
  `source/effects/compressibility_annotate_stage.d`'s own unittests prove
  this directly: an exactly-63-byte input (one byte under the ratio floor) still
  emits a normal, non-quarantined annotation with `belowFloor` status.

## `max-input-bytes`

The stage's one caller-tunable option, declared and read inline in
`source/effects/compressibility_annotate_stage.d` exactly as
`effects.topical_tags_extract_stage`'s own `max-html-bytes` precedent does --
no separate CLI-wiring file. Content larger than this bound quarantines with
reason `rawLimit` before either metric runs. Default: 1 MiB. Configurable
range: 1 byte to 8 MiB (`compressibilityMaxConfigurableInputBytes`). This is
independent of, and may be raised past, the fixed 1 MiB ratio cap above: a
caller who raises `max-input-bytes` can process larger documents (with their
real byte counts recorded) while the ratio itself still correctly abstains
above the fixed 1 MiB cap. No other compressor parameter (level, window,
strategy) is exposed -- all are fixed schema constants, required for
cross-run comparability.

## The extension field

Schema `scrubbed-compressibility-v1`, one field named `compressibility`,
written via #285's `DocumentMetadata.withExtensionField`. It carries: the
schema version; the tokenizer version
(`domain.token_entropy.tokenEntropyTokenizerVersion`); the entropy status,
value (`null` unless `computed`), token count, and distinct token count; the
compression status, `compressedToRawRatio` (`null` unless `computed`),
`rawBytes`, `compressedBytes`, compressor name/version/level; and a sha256
digest of the exact raw content bytes this stage measured
(`contentRevisionSha256`), binding the whole annotation to that specific
content revision.
`source/effects/compressibility_annotate_stage.encodeCompressibilityV1`/
`decodeCompressibilityV1` are the encode/decode pair (decode is test-only --
the field is opaque to every other module, `document-metadata-publish`
included, which never interprets it). A
dedicated unittest pins the worst-case encoded length (longest status names,
maximal digit counts at the 8 MiB configurable ceiling) under
`domain.document_metadata.maxExtensionValueBytes` (512 bytes).

## Pipeline placement

This is a non-terminal v3 stage (`SideOutputCapability.none`,
`StageCardinality.oneToOne`), the same shape as `html-metadata-annotate`. It
reads whatever `StageDocument.content` bytes it receives at its position in
the compiled chain -- it does not own text extraction or mojibake repair.
Placing it after a mojibake-repairing filter means entropy sees repaired
text; placing it before or without one means entropy sees the raw bytes
as-is (and still abstains cleanly, never quarantining, if those bytes are
not valid UTF-8). `content` passes through this stage completely unmodified.
It routes through the existing, unmodified `document-metadata-publish`
terminal stage -- no new plumbing was added for this slice.

## Determinism

Two runs over the same input bytes produce byte-identical extension-field
bytes: fixed `%.6f` numeric formatting, a single fixed zstd level (19, no
dictionary, no multithreading), and no ambient/system randomness anywhere in
either metric.

## Golden fixtures (real computed numbers)

All of the following are proven with real, computed values in
`source/effects/compressibility_annotate_stage.d`'s unittests (not merely
type-correctness):

- **Empty input**: entropy `noTokens`; ratio `belowFloor` at `rawBytes=0`,
  with a real nonzero `compressedBytes` for the empty zstd frame.
- **All-zero bytes** (2000 bytes): entropy `noTokens` (0x00 is not a token
  character); ratio `computed`, compressing to under 100 bytes
  (`compressedToRawRatio < 0.05`).
- **Highly repetitive text** (one 8-distinct-word phrase repeated 200
  times): token-frequency entropy is exactly `log2(8) == 3.0` -- "high-ish,"
  not near zero, because order-0 entropy has no notion of *sequence*
  repetition -- while the zstd ratio is near-floor (measured well under
  0.05) because it directly exploits the verbatim repeated phrase. Both real
  numbers are asserted side by side, demonstrating the two metrics are not
  interchangeable.
- **Natural-language text**: entropy ~4.50 bits over 24 real tokens; ratio
  ~0.74 (measured).
- **Uniform-random-like bytes** (deterministic fixed-seed xorshift, 4096
  bytes): with overwhelming probability invalid UTF-8, so entropy abstains,
  while the ratio still computes near 1.0 (measured in the 0.95-1.2 range,
  allowing zstd's small fixed frame overhead on incompressible input).
- **Multilingual UTF-8** (Latin, Japanese, and a non-BMP emoji): entropy and
  ratio both compute over real multi-script tokens (12 tokens, 8 distinct).
- **Invalid UTF-8** (a well-formed-ASCII document with one embedded
  overlong/invalid UTF-8 sequence, above the 64-byte floor): entropy
  abstains `invalidUtf8`; the ratio still computes normally over the same
  raw bytes, with real, nonzero `rawBytes`/`compressedBytes`.
- **Cap/floor boundaries**: exactly-64-byte and exactly-1-MiB inputs both
  compute the ratio; exactly-63-byte and (with `max-input-bytes` raised)
  1-MiB-plus-1-byte inputs both abstain -- proven at the exact byte
  boundary, and proven to emit rather than quarantine either way.
- **Resource quarantine**: exceeding `max-input-bytes` itself (distinct from
  the fixed ratio floor/cap) does quarantine with reason `rawLimit`.
- **Reachability**: `[compressibility-annotate, document-metadata-publish]`
  compiles and runs as one job via `compileJob`/`runCompiledJob`; the
  terminal `document-metadata-v1` side output's decoded metadata carries
  exactly the `compressibility` field this stage wrote, with real,
  independently-verified numbers (including the content-revision sha256).

## Benchmark

`benchmarks/compressibility_annotate.d` (O3/release) runs the same
`compileJob`/`runCompiledJob` path over a synthetic 500-document corpus,
stage disabled (`document-metadata-publish` alone) vs enabled
(`[compressibility-annotate, document-metadata-publish]`), reporting real OS
wall/user/CPU time and peak RSS (via `/usr/bin/time -l`) alongside in-process
throughput and GC allocation delta:

```sh
ldc2 -O3 -release -preview=dip1000 -Isource -i \
  benchmarks/compressibility_annotate.d .dub/lexbor/liblexbor_static.a \
  .dub/zstd/libzstd_compress.a .dub/zstd/libzstd_decompress.a \
  third_party/sqlite/sqlite3.o -L-lcurl \
  -of=/tmp/scrubbed-compressibility-bench
/tmp/scrubbed-compressibility-bench
```

A representative measured run on the macOS arm64 development host (500
documents, ~1.23 MB total, level-19 zstd on every document):

```
mode=baseline documents=500 emitted=500 totalBytes=1232091 elapsedMs=1.476 docsPerSec=338868.2 mbPerSec=796.349 gcAllocatedDeltaBytes=4688640 gcAllocatedPerDocBytes=9377.3
mode=baseline osRealSec=0.010 osUserSec=0.010 osSysSec=0.000 osMaxRssBytes=14106624 osMaxRssMB=13.45
mode=enabled documents=500 emitted=500 totalBytes=1232091 elapsedMs=202.298 docsPerSec=2471.6 mbPerSec=5.808 gcAllocatedDeltaBytes=26178128 gcAllocatedPerDocBytes=52356.3
mode=enabled osRealSec=0.210 osUserSec=0.200 osSysSec=0.000 osMaxRssBytes=19464192 osMaxRssMB=18.56
delta: osRealSecPerDoc=0.000400 osMaxRssDeltaBytes=5357568 gcAllocatedDeltaPerDocBytes=42979.0
```

Enabling the stage costs roughly 0.4 ms/document of real wall time on this
corpus (dominated by zstd level 19, a deliberately strong, non-"ultra"
compression level chosen for reproducibility over speed), about 5.1 MB of
additional peak RSS, and roughly 43 KB of additional GC allocation per
document (compression output buffers and tokenization). This is a real
measurement on real hardware, not a placeholder, and is expected to vary by
host and corpus; it is not a claim of a fixed, portable throughput number.

## Estimator limitations

- Neither metric is Kolmogorov complexity, which is uncomputable; both are
  named, bounded, versioned proxies only.
- Token-frequency entropy has no notion of sequence/structural repetition --
  see the "highly repetitive text" fixture above, where entropy is
  "high-ish" while the compression ratio is near-floor on the exact same
  input. The two metrics measure genuinely different things.
- Values are never comparable across a different schema version, compressor
  version/level, or tokenizer version, even when the field name is the same.
- This stage makes no keep/reject/quarantine decision from either metric.
