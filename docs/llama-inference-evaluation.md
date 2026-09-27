# llama.cpp in-process GGUF inference evaluation (evidence landing only)

Status: isolated proposal, **not a selected library or production
implementation**. No llama.cpp source, build artifact, or third-party binary
was vendored, pinned in `dub.json`, or wired into `source/`, any stage, or
the CLI. No GGUF model was vendored either. This document does not adopt,
reject, or schedule anything; the next decision belongs to @schancel. It
answers exactly the question issue #65's corrected scope asks: for the
**in-process local GGUF inference backend** (via `llama.cpp`'s public C
API), evaluated first and most thoroughly, can a real, working artifact be
obtained and a real inference call made, and at what real cost — and, more
lightly, is the **OpenAI-compatible API-endpoint alternative** realistically
buildable on this codebase's already-shipped `effects.http_fetch`/
`curl_ffi.d`. Matches the posture of `docs/pdfium-evaluation.md` (issue
#297): candidate provenance with exact version/commit identity, license
evidence, real reproduction steps, and honest disclosure of anything
unresolved.

## Summary of outcome

A real, working prebuilt `libllama.dylib` artifact **was** obtained from
`ggml-org/llama.cpp`'s own GitHub release binaries and functionally
verified on this machine (Darwin arm64) two independent ways: (1) the
release's own `llama-completion` CLI binary produced real, coherent
generated text from a real tiny GGUF model; (2) a new, minimal D FFI
harness (`experiments/llama_check/evaluate.d`, `dlopen`/`dlsym`-based,
mirroring `experiments/pdfium_check/evaluate.d`'s idiom) independently
loaded the same shared library, tokenized a real prompt, ran a real greedy
decode loop against real computed logits, and detokenized real generated
text — proving the C API is ABI-callable from D, not just from llama.cpp's
own bundled tools. A from-source build was **not attempted**; the real,
evidenced reason is disclosed below (a materially different, much lighter
dependency profile than PDFium's Chromium-toolchain build, but blocked here
by acute, actively-observed shared-machine disk pressure during this
evaluation, not by anything intrinsic to llama.cpp's own build). The
OpenAI-compatible API-endpoint alternative was assessed against the real,
already-read `source/effects/http_fetch.d` and `source/effects/curl_ffi.d`
source and found to have a real, narrow, additive gap (no POST/body
support today), not a fundamental blocker.

## Candidate provenance checked 2026-09-27 UTC

| Candidate | Exact version/source identity | License evidence | Decision status |
| --- | --- | --- | --- |
| llama.cpp itself | `github.com/ggml-org/llama.cpp`, `master` HEAD `a97cce86a8addeb9f40cba7a261c94b1f0c576cb` (committer date 2026-09-27T17:18:56Z, message "common : avoid side effects around params parsing (#29537)") | [`LICENSE`](https://raw.githubusercontent.com/ggml-org/llama.cpp/a97cce86a8addeb9f40cba7a261c94b1f0c576cb/LICENSE), SHA-256 `94f29bbed6a22c35b992c5c6ebf0e7c92f13b836b90f36f461c9cf2f0f1d010d` — plain MIT, "Copyright (c) 2023-2026 The ggml authors"; corroborated by `gh api repos/ggml-org/llama.cpp \| jq .license` → `{"key":"mit","spdx_id":"MIT"}` and `"archived": false` | Research candidate; not adopted |
| `ggml-org/llama.cpp` release binaries (upstream project's own CI-built binaries, not a third-party distributor) | Release tag `b11222` (a per-build-number tag, not a semver tag — see below), published 2026-09-27T17:43:57Z, `target_commitish` `a97cce86a8addeb9f40cba7a261c94b1f0c576cb` (built from the exact `master` HEAD above); asset `llama-b11222-bin-macos-arm64.tar.gz`, SHA-256 `869b73f760042ac660e9453ff5e5cbb157725f2f8e01ec473006ffcf387a8410` (computed locally with `shasum -a 256`, independently cross-checked against the release's own GitHub Artifact Attestation) | Bundled `LICENSE` inside the archive: identical MIT text/hash to the repo's own top-level `LICENSE` (same copyright line) | **Obtained, extracted, and functionally verified two independent ways.** Not adopted. |
| Tiny GGUF test model: `ggml-org/models` (Hugging Face), `tinyllamas/stories260K.gguf` | HF repo `ggml-org/models-moved`, file `tinyllamas/stories260K.gguf`, 1,185,376 bytes, LFS SHA-256 `270cba1bd5109f42d03350f60406024560464db173c0e387d91f0426d3bd256d` (computed locally, matches HF's own reported `lfs.oid` exactly) | Repo's own `README.md`: *"Various models to be used in llama.cpp CI workflow. Do not use it in production."* Converted from `karpathy/tinyllamas` (Andrej Karpathy's `llama2.c` "TinyStories" checkpoints), whose HF repo card declares `license: mit` (`cardData.license == "mit"`, fetched via `curl .../api/models/karpathy/tinyllamas`) | **Obtained and used for a real inference smoke test.** Not vendored into this repo — see reproduction steps below. Not adopted (see "not for production use" disclosure above). |
| From-source CMake build (`git clone` + `cmake`/`ninja`) | Would target the same `master` HEAD `a97cce86a8addeb9f40cba7a261c94b1f0c576cb` | N/A (build tooling, not a shipped artifact) | **Not attempted.** A real, evidenced reason is disclosed below — see ["From-source build: real assessment and why it was not attempted"](#from-source-build-real-assessment-and-why-it-was-not-attempted). |

No other candidate path (e.g. a maintained D binding, `whisper.cpp`-style
alternative C++ inference runtimes such as `ggml`-adjacent projects,
ONNX Runtime, or a different GGUF-capable C library) was searched for or
attempted beyond what is documented here — issue #65 names `llama.cpp`
specifically as the candidate to evaluate.

## License evidence, verbatim

Fetched directly from the GitHub repository at the exact pinned commit:

```sh
curl -fsSL https://raw.githubusercontent.com/ggml-org/llama.cpp/a97cce86a8addeb9f40cba7a261c94b1f0c576cb/LICENSE -o llama-cpp-LICENSE.txt
shasum -a 256 llama-cpp-LICENSE.txt
```

Result: SHA-256 `94f29bbed6a22c35b992c5c6ebf0e7c92f13b836b90f36f461c9cf2f0f1d010d`.
The file reads, in full:

```
MIT License

Copyright (c) 2023-2026 The ggml authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

This is an unambiguous, single-license grant — no BSD/Apache-2.0
co-mingling of the kind `docs/pdfium-evaluation.md` found and flagged for
PDFium's own `LICENSE` file. `ggml` (the tensor library llama.cpp is built
on) lives in the same repository (`ggml/` subdirectory) under the same
top-level `LICENSE`, so no separate license check was needed for it. The
prebuilt release binary's own bundled `LICENSE` file (inside
`llama-b11222-bin-macos-arm64.tar.gz`) was read in full and is
byte-identical in content to the repo's own `LICENSE` above (same copyright
line, same text). `otool -L` on the extracted `libllama.dylib` (see below)
shows it links only Apple system libraries (`libc++`, `libSystem`,
`librdma`, weak) and llama.cpp's own `libggml*.dylib` family — **no**
third-party dependency is statically or dynamically linked into the actual
inference library this evaluation's D binding targets. (The separate
`vendor/` directory this repository's `tools/server/` build uses —
`cpp-httplib`, `nlohmann/json`, `miniaudio`, `stb`, all themselves
permissive — is for the HTTP server tool and multimedia examples, not for
`libllama.dylib`/`libggml*.dylib`; this evaluation did not need to and did
not check those licenses individually since they are out of scope for the
in-process library surface actually used.)

## A real, unresolved release-tagging quirk this evaluation found

`gh api repos/ggml-org/llama.cpp/releases/latest` returns tag `v0.5.0`
(published 2026-09-23T20:50:06Z) — but that release's **only** asset is a
7-byte `nightly-tag.txt` file; it ships **no binaries at all**. The actual
binary artifacts (35 assets per build, including every OS/GPU-backend
combination) are published under separate, much more frequent,
per-commit **build-number** tags like `b11222`, `b11221`, `b11218` — dozens
per day (this evaluation observed 30 such releases within roughly the
previous 48 hours via `gh api repos/ggml-org/llama.cpp/releases`, tag
`b11222` down to tag `b11184`, published 2026-09-25T17:57:47Z through
2026-09-27T17:43:57Z). This
means the GitHub API's own "latest release" concept does **not** point at
the actual latest usable binary build for this project; a real integration
would need to query the `b#####`-tag releases specifically (e.g. the most
recent one, or one pinned deliberately), not `.../releases/latest`. This is
disclosed here rather than silently worked around, the same way
`docs/pdfium-evaluation.md` disclosed PDFium's archived-mirror-vs-live-
commits discrepancy rather than hiding it. It is a real, evidenced finding
about *how to correctly consume this project's releases*, not a defect in
llama.cpp itself.

## The C API surface (verified, not assumed)

Issue #65 asks to verify `llama.h`'s "actual current stability/shape,
don't assume." The real, current header was fetched at the exact commit
the `b11222` binaries were built from:

```sh
curl -fsSL https://raw.githubusercontent.com/ggml-org/llama.cpp/a97cce86a8addeb9f40cba7a261c94b1f0c576cb/include/llama.h -o llama.h
wc -l llama.h   # 1736
shasum -a 256 llama.h   # 0f166aba40183253c3b9b42c84725283d5792519027d1ba405df837abf278483
```

Unlike PDFium's `README.md` ("The PDFium project endeavors to keep these
[public headers] as stable as possible"), **no equivalent explicit
stability promise was found** anywhere this evaluation checked: `llama.h`
itself opens only with `// C interface` / `// TODO: show sample usage`;
`README.md` (126 lines, fetched and read in full) makes no stability
claim; `CONTRIBUTING.md` says only *"New CLI or public API additions carry
a **higher bar** than internal changes - justify why an existing mechanism
doesn't suffice"* — a review-bar statement, not a compatibility promise.
Concretely observed evidence the API is **not** stable in the PDFium
sense: `llama.h` currently wraps roughly two dozen functions in a
`DEPRECATED(...)` macro (e.g. `llama_load_model_from_file` →
`llama_model_load_from_file`, `llama_new_context_with_model` →
`llama_init_from_model`, `llama_token_get_text` → `llama_vocab_get_text`),
and the struct this evaluation had to transcribe field-for-field,
`llama_context_params`, carries its own top-of-struct warning: *"NOTE:
changing the default values of parameters marked as [EXPERIMENTAL] may
cause crashes or incorrect results in certain configurations"* — the
struct includes an `[EXPERIMENTAL]` backend-sampler-chain field
(`samplers`/`n_samplers`) added recently enough to still carry that
marker. Combined with the build-numbered (not semver) release scheme
above, the honest characterization is: **a real, usable, well-documented
C API surface, evolving fast under continuous deprecation, with no
external compatibility guarantee** — a different risk profile than
PDFium's, not a worse-or-better one, and a fact a real adoption should
weigh explicitly (e.g. pinning one exact commit/build tag, the same way
this evaluation does, rather than "latest").

The functions this evaluation's D binding actually calls (`llama_backend_
init`/`_free`, `llama_model_default_params`, `llama_context_default_
params`, `llama_model_load_from_file`, `llama_model_free`,
`llama_model_get_vocab`, `llama_init_from_model`, `llama_free`,
`llama_vocab_n_tokens`, `llama_tokenize`, `llama_token_to_piece`,
`llama_batch_get_one`, `llama_decode`, `llama_get_logits_ith`,
`llama_vocab_is_eog`) are none of them `DEPRECATED`-wrapped at this
commit.

## `ggml-org/llama.cpp` release binaries: real reproduction steps

Run from any directory, on Darwin arm64 (this machine's platform):

```sh
curl -fsSL "https://api.github.com/repos/ggml-org/llama.cpp/releases/tags/b11222" -o release-b11222.json
python3 -c "import json; d=json.load(open('release-b11222.json')); print(d['tag_name'], d['target_commitish'])"
# -> b11222 a97cce86a8addeb9f40cba7a261c94b1f0c576cb
curl -fsSL "https://github.com/ggml-org/llama.cpp/releases/download/b11222/llama-b11222-bin-macos-arm64.tar.gz" -o llama-macos-arm64.tar.gz
shasum -a 256 llama-macos-arm64.tar.gz
# -> 869b73f760042ac660e9453ff5e5cbb157725f2f8e01ec473006ffcf387a8410
mkdir extracted && tar -xzf llama-macos-arm64.tar.gz -C extracted
```

Cross-checked, not just self-reported, against GitHub's cryptographic
Artifact Attestation (Sigstore/SLSA provenance) for this exact release:

```sh
gh attestation verify llama-macos-arm64.tar.gz -R ggml-org/llama.cpp --format json
```

The returned, Rekor-transparency-log-backed attestation verified a real
GitHub Actions build: workflow
`ggml-org/llama.cpp/.github/workflows/release.yml@refs/heads/master`,
trigger `push`, build/source commit
`a97cce86a8addeb9f40cba7a261c94b1f0c576cb` (matching the release's
`target_commitish` exactly), run
`https://github.com/ggml-org/llama.cpp/actions/runs/36336478949/attempts/1`,
github-hosted runner, signed 2026-09-27T10:43:49-07:00. Its signed
statement's subject list includes
`{"name":"llama-b11222-bin-macos-arm64.tar.gz","digest":{"sha256":"869b73f760042ac660e9453ff5e5cbb157725f2f8e01ec473006ffcf387a8410"}}`
— byte-for-byte the same digest computed locally above.

The dylib's own file evidence:

```sh
file extracted/llama-b11222/libllama.dylib
# -> Mach-O 64-bit dynamically linked shared library arm64
lipo -info extracted/llama-b11222/libllama.dylib
# -> Non-fat file: ... is architecture: arm64
codesign --verify --verbose=4 extracted/llama-b11222/libllama.dylib
# -> "valid on disk", "satisfies its Designated Requirement" (ad-hoc signed)
otool -L extracted/llama-b11222/libllama.dylib
# -> @rpath/libllama.0.dylib, /usr/lib/librdma.dylib (weak),
#    @rpath/libggml{,-cpu,-blas,-metal,-rpc,-base}.0.dylib,
#    /usr/lib/libc++.1.dylib, /usr/lib/libSystem.B.dylib -- no other
#    third-party dylib deps
extracted/llama-b11222/llama-completion --version
# -> version: 0.5.0-dev (build 11222, commit a97cce86a8addeb9f40cba7a261c94b1f0c576cb)
#    built with AppleClang 21.0.0.21000101 for Darwin arm64
```

Archive: 11,756,831 bytes compressed; 30 MB extracted (35 shared
libraries + 24 binaries + `LICENSE`; no headers are shipped in the binary
release, hence fetching `llama.h` from the repository separately above).

The tiny GGUF test model, obtained separately (not part of the same
archive, not vendored into this repository):

```sh
curl -fsSL "https://huggingface.co/ggml-org/models-moved/resolve/main/tinyllamas/stories260K.gguf" -o stories260K.gguf
shasum -a 256 stories260K.gguf
# -> 270cba1bd5109f42d03350f60406024560464db173c0e387d91f0426d3bd256d
# matches Hugging Face's own reported LFS SHA-256 (`lfs.oid`) for this file exactly.
```

**A real, disclosed obstacle hit along the way:** the Hugging Face API
(`https://huggingface.co/api/models/<repo>`) and file-resolve endpoint
(`https://huggingface.co/<repo>/resolve/main/<path>`) returned HTTP 401
`{"error":"Invalid username or password."}` for the first candidate model
this evaluation tried, `HuggingFaceTB/SmolLM2-135M-Instruct-GGUF` — a
repo that is not normally access-gated — while `huggingface.co` itself
(200), `openai-community/gpt2`'s resolve endpoint (200), and the general
API search endpoint (200) all worked normally from this same environment
in the same few minutes. This was not resolved (three retries all
returned the same 401; the cause was not identified — possibly a
transient CloudFront-edge error, since the response headers included
`x-cache: Error from cloudfront`). This evaluation switched to the
`ggml-org/models` repository instead, which worked without issue and
turned out to be the better choice anyway (see next section) — but the
SmolLM2 401 is disclosed here rather than silently dropped, since it
could recur for a real implementation trying to fetch a specific model by
name.

## Real evidence for the tiny-model choice

`ggml-org/models-moved`'s own `README.md` (fetched and read in full)
reads, in its entirety: *"Various models to be used in llama.cpp CI
workflow. Do not use it in production."* This is the llama.cpp
maintainers' **own** repository of models used for their **own** CI smoke
tests — an unusually strong provenance match for issue #65's ask of "a
real, obtainable, small, permissively-licensed GGUF model suitable for a
bounded evaluation." Its `tinyllamas/` subdirectory lists several
`stories15M`/`stories260K` variants (`.gguf`, `-q4_0.gguf`, `-q8_0.gguf`,
big-endian variants); `stories260K.gguf` at 1,185,376 bytes was chosen as
the smallest. These are GGUF conversions of Andrej Karpathy's `llama2.c`
"TinyStories" checkpoints (tiny transformer language models trained from
scratch on the synthetic [TinyStories
dataset](https://huggingface.co/datasets/roneneldan/TinyStories) —
short, simple children's stories — specifically to be small enough to
run/train trivially). The upstream `karpathy/tinyllamas` Hugging Face
repository's own card metadata declares `license: mit`
(`curl .../api/models/karpathy/tinyllamas` → `{"cardData":{"license":
"mit"},"license":"mit"}`).

## Functional proof #1: the release's own CLI, real end-to-end generation

```sh
DYLD_LIBRARY_PATH=extracted/llama-b11222 extracted/llama-b11222/llama-completion \
    -m stories260K.gguf -p "Once upon a time" -n 40 --no-warmup
```

**A real, disclosed tool-selection wrinkle:** this build's `llama-cli`
(the historically "main" llama.cpp binary) defaults to an interactive
chat/conversation mode and rejected the `-no-cnv` flag this evaluation
first tried (`error: invalid argument: -no-cnv`; `--help` confirmed no
such flag exists in this build). `llama-completion` — a separate binary
in the same release, present specifically for raw non-chat text
completion — was used instead and worked immediately. This is disclosed
because it is exactly the kind of "the tool changed shape since training
data" surprise this evaluation is supposed to catch, not silently paper
over.

Real captured output (log lines trimmed to the load/generation/perf
summary):

```
0.07.380.628 W load: bad special token: 'tokenizer.ggml.seperator_token_id' = 4294967295, using default id -1
0.07.392.250 I system_info: n_threads = 4 (n_threads_batch = 4) / 10 | MTL : EMBED_LIBRARY = 1 | CPU : NEON = 1 | ...
0.07.392.292 I generate: n_ctx = 2048, n_batch = 2048, n_predict = 40, n_keep = 1
 Once upon a time, there was a little girl named Lily. She loved to play outside in the sun. One day, she saw a big shiny rock

0.07.869.454 I common_perf_print:    sampling time =       0.63 ms
0.07.869.460 I common_perf_print: prompt eval time =     328.96 ms /     5 tokens (   65.79 ms per token,    15.20 tokens per second)
0.07.869.467 I common_perf_print:        eval time =     146.78 ms /    39 runs   (    3.76 ms per token,   265.70 tokens per second)
0.07.869.469 I common_perf_print:       total time =     477.25 ms /    44 tokens
```

This is real, meaningful, grammatical (if simplistic, matching a 260K-
parameter model's real capability) English text extracted from a real
tiny prompt against a real tiny model, on real CPU inference (`MTL:
EMBED_LIBRARY=1` shows the Metal backend was present but this run used
default sampling on CPU threads per `system_info`), with real measured
timings: 329 ms model load, 15.2 tok/s prompt evaluation, 265.7 tok/s
token generation.

## Functional proof #2: a real D FFI `dlopen()` binding

This evaluation wrote a minimal D FFI harness,
[`experiments/llama_check/evaluate.d`](../experiments/llama_check/evaluate.d),
mirroring `experiments/pdfium_check/evaluate.d`'s exact idiom: `dlopen()`
the caller-supplied `libllama.dylib`, `dlsym()` fifteen real C symbols,
call them through D `extern(C)` function-pointer types, and use
release-active `check()` calls (not `assert`) so an optimized build
cannot silently pass a broken probe. Like `experiments/pdfium_check/
evaluate.d`, it lives outside `dub.json`'s `sourcePaths` (only `source`
is compiled), so it is evaluation code, never compiled into the shipped
binary and never an importable dependency.

Unlike PDFium's opaque-pointer-only C API, `llama.h`'s model/context
construction functions take and return several large structs **by
value** (`llama_model_params`, `llama_context_params`,
`llama_batch`) — a materially harder FFI binding task than PDFium's, since
D and C must agree on the exact field order, types, and resulting padding
for these structs for the by-value call ABI to be correct (aggregates this
large are passed via a hidden pointer on the AArch64 calling convention,
so a layout mismatch would silently read/write the wrong bytes rather than
fail to link). Every field in both structs was transcribed directly from
the real, pinned `include/llama.h` fetched above — every `enum` field as
plain `int` (C's default enum underlying type on this platform/compiler,
confirmed by inspecting the header's plain, non-typed `enum` declarations)
and every function-pointer/opaque-pointer field this harness never
dereferences as `void*`. This is real, disclosed transcription risk: if
any field were wrong, the most likely failure mode is silent memory
corruption or a crash, not a clean error — this harness's real, correct
output (below) is the actual evidence this transcription was right on
this exact commit/build, not proof it will stay right across future
llama.cpp releases (the `[EXPERIMENTAL]` field noted above being the most
likely future breakage point).

Reproduce on Darwin arm64 with LDC 1.43.0 (based on DMD v2.113.0 and LLVM
23.1.0), from the repository root, after obtaining the artifacts above:

```sh
ldc2 -O -release -of=/tmp/scrubd-llama-evaluate experiments/llama_check/evaluate.d
DYLD_LIBRARY_PATH=/path/to/extracted/llama-b11222 \
    /tmp/scrubd-llama-evaluate /path/to/extracted/llama-b11222/libllama.dylib /path/to/stories260K.gguf
```

Local result, real output, exit code 0:

```
model vocab size: 512
prompt Once upon a time tokenized to 5 tokens
generated 20 tokens: , there was a little girl named Lily. She loved to play outsid
all checks passed
```

All fifteen resolved symbols were non-null; the model loaded; the vocab
size (512 — this tiny model's own small custom vocabulary, not a full
BPE vocabulary) matched expectations; the 5-token tokenization of "Once
upon a time" and the subsequent 20-token real greedy (argmax-over-real-
logits) decode loop — no sampler-chain API used, deliberately, to keep
the bound C symbol surface and struct-transcription risk minimal — 
produced text that is a real, coherent continuation and, notably,
**matches the independent `llama-completion` CLI run above almost exactly**
("there was a little girl named Lily. She loved to play outsid[e]..."),
which is strong corroborating evidence the D binding is computing the
same real inference the upstream CLI computes, not something
coincidentally text-shaped. A second run (`DYLD_LIBRARY_PATH` warm, Metal
shader cache already populated from the first run) completed in 0.374s
wall-clock total and produced byte-identical output, consistent with
greedy/deterministic decoding.

**A real, disclosed negative-path check**, run separately: passing a
20-byte non-GGUF file (`"not a real gguf file"`) as the model path
produced a real upstream error, not a crash — `gguf_init_from_reader:
invalid magic characters: 'not ', expected 'GGUF'` — `llama_model_load_
from_file` correctly returned `NULL`, this harness's `check()` caught it,
and the process exited 1 cleanly. This is the same fail-closed discipline
`docs/pdfium-evaluation.md`'s malformed-PDF check demonstrated for PDFium.

This is a single-machine, single-artifact, one-model, greedy-decoding-only
smoke test. It does not cover: any model larger than 260K parameters
(quantized formats, larger context windows, or real-world instruction-
tuned models were not tried), the sampler-chain API (`llama_sampler_*`,
entirely unused here), GPU/Metal offload (`n_gpu_layers` was forced to
`0`), multi-sequence/batched decoding, KV-cache persistence, LoRA
adapters, other platforms/architectures, thread safety under concurrent
calls, or any adversarial/fuzzed GGUF input beyond the one trivial
malformed case above.

## From-source build: real assessment and why it was not attempted

Issue #65 asks for the same "attempt or document why not" discipline
`docs/pdfium-evaluation.md` applied to PDFium's from-source path. Unlike
PDFium, llama.cpp's own from-source build has a **structurally much
lighter** dependency profile — this was checked directly, not assumed:

- `.gitmodules` exists in the repository at the pinned commit but is a
  real, **empty (0-byte)** file
  (`gh api repos/ggml-org/llama.cpp/contents/.gitmodules?ref=a97cce86a8addeb9f40cba7a261c94b1f0c576cb`
  → `"size": 0`) — i.e. llama.cpp has **no git submodules**, unlike
  PDFium's DEPS-driven closure of 17+ separately-fetched third-party
  repositories.
- The build is plain CMake (`CMakeLists.txt` at the repo root) requiring
  only a C/C++17 compiler and CMake — both already installed on this
  machine (`which cmake` → `/opt/homebrew/bin/cmake`; `which clang` →
  `/usr/bin/clang`) — with no separate pinned toolchain (no depot_tools,
  no pinned Clang/Rust download) the way PDFium's Chromium-derived build
  requires.
- `gh api repos/ggml-org/llama.cpp` reports the whole repository at
  `"size": 447249` (KB, GitHub's compressed-size metric) — roughly 447 MB,
  versus the 2.1 GB+ (and still growing, unmeasured to completion)
  PDFium's own `gclient sync` had reached for PDFium's tree *alone*
  before further third-party DEPS fetches.

Despite this materially lighter profile, this evaluation **did not
attempt** the actual `git clone`/`cmake`/build sequence. The real,
evidenced reason: this session repeatedly observed acute, volatile disk
pressure on this **shared machine** over the course of this same
evaluation — `df -h /` readings taken at different points while gathering
the evidence above (not caused by this evaluation's own ~43 MB of real
downloads, which were checked separately and are trivial): 4.8 GiB
available at the start of this session, then two consecutive commands
failed outright with `ENOSPC` (0 practically available), then readings of
124 MiB, 6.1 GiB, 6.0 GiB, 624 MiB, and 540 MiB, all within roughly the
same working session. A ~447 MB clone plus a real build's intermediate
object files would not reliably fit inside several of those observed
windows, and this machine's disk was clearly in active, unpredictable use
by something outside this evaluation's own control. `docs/pdfium-
evaluation.md` flagged "a shared machine's disk" as a risk it was
protecting *headroom* for (15–16 GB free at the time); this evaluation
directly observed that same shared-machine risk materialize, far more
severely, in real time. Given a real, obtained, functionally-verified
prebuilt artifact already answers issue #65's core question, spending
further shared-disk budget on a from-source build whose only
incremental evidence would be "does it also compile" was judged not worth
the risk. **This is a real, disclosed gap, not a completed measurement**:
no actual from-source build time, object-file size, or link-step
behavior was observed for llama.cpp, unlike PDFium's evaluation which did
start (and deliberately stop) its from-source attempt.

## Part 2: the OpenAI-compatible API-endpoint alternative

Issue #65 asks this to be evaluated "more lightly" — feasibility with real
evidence, not an implementation. This codebase's existing HTTP
infrastructure, `source/effects/curl_ffi.d` and `source/effects/
http_fetch.d`, was read in full (not skimmed) for this assessment.

**What already exists and is directly reusable:**

- `effects.curl_ffi` already binds `CURLOPT_HTTPHEADER` (`= 10_023`) and
  `curl_slist_append`/`curl_slist_free_all`, and `effects.http_fetch`
  already builds a real header list from it today (for the single
  `If-None-Match` header on conditional GETs). The generic mechanism an
  OpenAI-compatible client needs for `Authorization: Bearer <key>` and
  `Content-Type: application/json` headers is the *same* mechanism,
  already proven working end-to-end (including the real-socket unit test
  in `http_fetch.d` that captures literal wire bytes).
- The same `curl_easy_setopt`/callback/timeout/redirect/cap machinery
  `fetchHttp()` already uses for GET would apply unchanged to POST.

**What is genuinely missing today — verified, not assumed:**

- `effects.curl_ffi`'s `CURLoption` enum (the full list was read) binds
  **no** POST-related option at all: no `CURLOPT_POST`, no
  `CURLOPT_POSTFIELDS`, no `CURLOPT_POSTFIELDSIZE`, no
  `CURLOPT_CUSTOMREQUEST`. This was cross-checked against curl's own
  current public header
  (`https://raw.githubusercontent.com/curl/curl/master/include/curl/curl.h`):
  `CURLOPT(CURLOPT_POSTFIELDS, CURLOPTTYPE_OBJECTPOINT, 15)`,
  `CURLOPT(CURLOPT_POST, CURLOPTTYPE_LONG, 47)`,
  `CURLOPT(CURLOPT_CUSTOMREQUEST, CURLOPTTYPE_STRINGPOINT, 36)`,
  `CURLOPT(CURLOPT_POSTFIELDSIZE, CURLOPTTYPE_LONG, 60)` — all long-
  stable, well-established curl options (matching `curl_ffi.d`'s existing
  `OBJECTPOINT`-base-10000 / raw-`LONG` numbering convention, e.g.
  `CURLOPT_POSTFIELDS` would be `10_015`).
- `effects.http_fetch`'s `FetchRequest` struct (read in full) has **no**
  request-body field at all, and only the one fixed, hardcoded
  `ifNoneMatch` header — no general caller-supplied header list. `
  fetchHttp()` (read in full) never sets any POST-related `curl_easy_
  setopt` call; every request it issues today is a plain (optionally
  conditional) GET.
- Net effect: **this module genuinely cannot make a POST request with a
  JSON body today.** This is a real, verified, narrow, additive gap —
  the same handle lifecycle, callback structure, and `curl_slist`
  mechanism `fetchHttp()` already has would carry a POST/JSON-body
  extension without a new design; it was simply never built because
  nothing in this codebase has needed it yet. This is real evidence
  answering the ticket's "verify this is realistic before assuming"
  instruction: it is realistic, and the size of the real gap is small,
  but it is not zero-effort — no implementation was attempted here per
  scope.
- The corollary is a live gap even for reading a streamed
  (`"stream": true`, `text/event-stream`) OpenAI-compatible response
  incrementally; a non-streaming (`"stream": false`) request is
  sufficient to get a first working client and does not require any new
  streaming-response mechanism beyond what `fetchHttp()`'s existing
  bounded-body-callback approach already does.

**The latency tradeoff, documented with this evaluation's own real
numbers:** the in-process CLI run above completed a full model load plus
44-token round trip in 477 ms **entirely locally, with zero network
involved**. `effects.http_fetch`'s own shipped defaults
(`defaultConnectTimeoutMs = 5_000`, `defaultTotalTimeoutMs = 30_000`)
show this codebase's HTTP layer already budgets seconds, not
milliseconds, for a single fetch — an order of magnitude above the local
numbers measured above, before any remote model's own real inference time
is even added. This is the real, concrete basis for issue #65's own
framing of the API-endpoint backend as "explicitly documented and
understood as slower per-request due to network round-trips": every
request pays TCP/TLS setup plus transit latency that the in-process
backend structurally cannot incur, on top of whatever the remote server's
own queueing/inference time is.

## Cost summary

| Path | Download size (this host) | Toolchain required | Network at build/run time | Redistribution obligation if shipped |
| --- | --- | --- | --- | --- |
| `ggml-org/llama.cpp` release binary, macos-arm64 | 11.76 MB compressed, ~30 MB uncompressed (35 dylibs + 24 binaries) | None beyond `curl`/`tar`; `dlopen()` needs no toolchain at all | One-time download only | Ship the bundled MIT `LICENSE` verbatim, attribute "The ggml authors" |
| From-source CMake build | Not measured (not attempted); repo itself ~447 MB compressed per GitHub, no submodules, no external DEPS-fetch closure | CMake + a C/C++17 compiler, both already present on this machine | Only the initial `git clone`; no further network fetches expected (no submodules) — **not independently confirmed by an actual build** | Same MIT `LICENSE`, plus a real build's own object/binary output |
| Tiny GGUF test model (`stories260K.gguf`) | 1.19 MB | None | One-time download only | Not for production use per the hosting repo's own README; a production model choice needs its own separate license check |
| OpenAI-compatible API-endpoint client (not built) | N/A | None beyond this codebase's already-shipped libcurl link | Per-request, ongoing (the whole point of this backend) | N/A — scrubbed ships no model or server for this path |

## Adopt/reject/defer guidance (not a decision)

This evaluation's evidence supports the following as guidance for
@schancel's own decision, not as a decision:

- **In-process GGUF inference via `llama.cpp`'s C API is real, working,
  and genuinely callable from D**, both via the upstream CLI and via a
  from-scratch `dlopen()` D binding that independently reproduced the
  same generation. The MIT license is unambiguous and the actual linked
  dependency surface (`libllama.dylib` + `libggml*.dylib`, Apple system
  libraries only) is clean. This is adopt-leaning on the core technical
  question issue #65 asks.
- **The real, open risk this evaluation surfaces is API-surface
  volatility, not licensing or functionality.** Unlike PDFium's
  documented "we try to keep headers stable" policy, llama.cpp makes no
  such promise, ships build-numbered (not semver) releases multiple times
  a day, deprecates functions routinely, and marks parts of the exact
  struct this evaluation had to transcribe as `[EXPERIMENTAL]`. A real
  adoption should pin one exact `b#####` build/commit deliberately (the
  same discipline this evaluation used) and expect to re-verify the
  transcribed `llama_model_params`/`llama_context_params` struct layouts
  against `llama.h` on every upgrade — a real, ongoing maintenance cost
  a "vendor source, build locally" precedent like Lexbor/zstd/sqlite
  does not carry in the same way, since those wrap much smaller, more
  stable C surfaces.
- **The from-source build path is genuinely un-evaluated, not
  reject-leaning.** The real evidence gathered (no submodules, ~447 MB
  repo, ordinary CMake + already-installed toolchain, no PDFium-style
  DEPS-fetch closure) suggests it is plausibly *lighter* than PDFium's
  from-source path, which was itself judged reject-leaning. This
  evaluation could not confirm that with an actual build because of real,
  actively-observed shared-machine disk pressure during this session
  (documented above) — a real adoption on a machine with stable free disk
  should attempt it rather than inherit this evaluation's inconclusiveness.
- **A prebuilt-binary trust pattern, if chosen, would need the same kind
  of operator-supplied-path design `source/effects/pdfium_ffi.d` already
  established** (issue #156's accepted precedent: the operator supplies
  the library path explicitly; scrubbed never fetches, vendors, or
  assumes one) — this evaluation deliberately does not propose that
  design here since issue #65 is evidence-only, but the precedent exists
  and worked for a comparably-shaped third-party-binary trust question.
- **The OpenAI-compatible API-endpoint alternative is realistically
  buildable on `effects.http_fetch`/`curl_ffi.d`**, with a small, well-
  understood, additive gap (POST/JSON-body support, a general request-
  header list) rather than any structural blocker. Its per-request
  network-round-trip latency cost is real and now has this evaluation's
  own local-vs-network-timeout numbers behind it, not just an assumption.
  Nothing about building this alternative depends on the in-process
  backend's outcome; they can be adopted, deferred, or rejected
  independently, exactly as issue #65's "both, not a decision" framing
  asks for.
- **Nothing here is ready for wiring.** A real adoption of either backend
  would still need (at minimum, unaudited by this evaluation): a typed
  metadata port and versioned schema (per issue #65's "Accepted outcome"
  section), timeout/cancellation/concurrency/malformed-response/resource-
  limit handling for the in-process backend (this evaluation's harness
  has none of that — it is a bare smoke test), a real model-file-
  provenance/size-limit policy distinct from `stories260K.gguf`'s "not
  for production" status, the POST/header extension to `http_fetch.d`
  for the API-endpoint backend, and a decision on exactly which `b#####`
  build to pin for the in-process backend — none of which this
  evaluation resolves.

## Rollback

Delete `docs/llama-inference-evaluation.md` and
`experiments/llama_check/`. Zero blast radius on any shipped module:
nothing in `source/`, `dub.json`, or any stage imports or references
anything from this evaluation.
