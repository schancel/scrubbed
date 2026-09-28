# llama.cpp Linux x86_64/aarch64 prebuilt-binary evaluation (evidence landing only)

Status: isolated proposal, **not a selected library or production
implementation**. No llama.cpp source, build artifact, or third-party
binary was vendored, pinned in `dub.json`, or wired into `source/`, any
stage, or the CLI. This document does not adopt, reject, or schedule
anything; the next decision belongs to @schancel. It answers exactly the
Linux-artifact half of what issue #379 scoped.

## A note on this document's scope, corrected from the ticket's own premise

Issue #379's body says an "equivalent evaluation for llama.cpp" to
`docs/pdfium-evaluation.md`'s macOS PDFium evaluation "was done," without
naming a file, and its own Strong-lane solution contract instructs:
"confirm this file [`docs/llama-cpp-evaluation.md`] genuinely doesn't
already exist before creating it." Both were checked directly
(`grep -ri llama docs/*.md`, then a full read of the match). **A macOS
llama.cpp evaluation does already exist**, at
[`docs/llama-inference-evaluation.md`](llama-inference-evaluation.md) —
just under a different filename than the ticket assumed. That document
already covers, for macOS arm64: candidate provenance, a from-source-build
assessment, the C API surface/stability finding, real reproduction steps,
two independent functional-verification methods (the release's own CLI
and a from-scratch D `dlopen()` harness at
`experiments/llama_check/evaluate.d`), a tiny-GGUF-model provenance check,
an OpenAI-compatible-API-endpoint feasibility assessment, and a cost
summary — pinned to `ggml-org/llama.cpp` release tag `b11222`, commit
`a97cce86a8addeb9f40cba7a261c94b1f0c576cb`.

This document does **not** duplicate that work. Per this task's own
instructions ("If a macOS llama.cpp evaluation truly doesn't exist yet
anywhere, don't invent one... If it does exist, don't duplicate it"),
this document is scoped narrowly to what issue #379 actually asks for and
`llama-inference-evaluation.md` does not yet cover: **Linux x86_64 and
aarch64 prebuilt-binary candidate provenance**, at the same discipline.
Anything about macOS, the from-source build, the C API stability finding,
or the OpenAI-compatible-endpoint alternative should be read from
`llama-inference-evaluation.md` directly rather than re-derived or
re-summarized here.

This machine (Darwin arm64) cannot execute Linux ELF binaries, so **no
functional/dlopen verification was performed** for either Linux artifact
— only archive integrity, license text, and file-format/ABI
identification. Windows is out of scope per issue #379's own instructions
(scrubbed does not build for Windows).

## Candidate provenance checked 2026-09-28 UTC

Both Linux assets checked here come from **the exact same pinned release**
`llama-inference-evaluation.md` already pinned for macOS: `ggml-org/
llama.cpp` release tag `b11222`, `target_commitish`
`a97cce86a8addeb9f40cba7a261c94b1f0c576cb`, confirmed still present and
unmodified as of this check (`gh api repos/ggml-org/llama.cpp/releases/
tags/b11222` returns the identical `target_commitish` and asset list). It
is **no longer the distributor's current latest** as of this check — `gh
api repos/ggml-org/llama.cpp/releases` shows `b11236` (published
2026-09-28T18:31:25Z) is now newest, fourteen build-tags ahead of `b11222`
(published 2026-09-27T17:43:57Z) — but this is expected, disclosed
behavior given `llama-inference-evaluation.md`'s own already-recorded
finding that this project ships "dozens" of build-tagged releases per
day; `b11222` is roughly a day old, not stale or abandoned.

| Candidate | Exact version/source identity | License evidence | Decision status |
| --- | --- | --- | --- |
| `ggml-org/llama.cpp` release binaries, Linux x86_64 (CPU build) | Same release `b11222` / commit `a97cce86a8addeb9f40cba7a261c94b1f0c576cb` already pinned for macOS in `llama-inference-evaluation.md`; asset `llama-b11222-bin-ubuntu-x64.tar.gz` (the CPU-only Ubuntu build — CUDA/ROCm/Vulkan/SYCL/OpenVINO variants exist as separate assets and were not evaluated, to match the macOS artifact's own CPU-only build), SHA-256 `cfd2323f9ffec9657ca247140129be68df62d98f30a8448b20b1ca7a1796e1cb` (computed locally with `shasum -a 256`) | Bundled `LICENSE`, SHA-256 `94f29bbed6a22c35b992c5c6ebf0e7c92f13b836b90f36f461c9cf2f0f1d010d` — byte-identical to the macOS artifact's own bundled `LICENSE` (same hash `llama-inference-evaluation.md` already recorded) | **Obtained, extracted, license-verified, symbol-verified via `nm`/`objdump`. Not functionally executed (cannot run Linux ELF on this Darwin arm64 host). Not adopted.** |
| `ggml-org/llama.cpp` release binaries, Linux aarch64 (CPU build) | Same release `b11222` / commit `a97cce86a8addeb9f40cba7a261c94b1f0c576cb`; asset `llama-b11222-bin-ubuntu-arm64.tar.gz` (CPU-only; a separate `-cuda-13.4-arm64` GPU variant exists and was not evaluated), SHA-256 `9099b2dd5fbd8391b4e189d78c117d263e4afe23717af92f8349fc1b67e4d40d` (computed locally) | Bundled `LICENSE`, SHA-256 `94f29bbed6a22c35b992c5c6ebf0e7c92f13b836b90f36f461c9cf2f0f1d010d` — identical to both the x86_64 asset above and the macOS artifact | **Obtained, extracted, license-verified, symbol-verified via `nm`/`objdump`. Not functionally executed (same reason). Not adopted.** |

No other candidate path (a different distributor, a from-source Linux
build, a different GPU-backend variant) was searched for or attempted;
issue #379 scopes this evaluation to the same upstream release-binary
path `llama-inference-evaluation.md` already evaluated for macOS.

## License evidence, verbatim

The bundled `LICENSE` inside both Linux archives is the identical MIT
text already quoted in full in `llama-inference-evaluation.md`'s own
"License evidence, verbatim" section (same SHA-256
`94f29bbed6a22c35b992c5c6ebf0e7c92f13b836b90f36f461c9cf2f0f1d010d`,
confirmed by direct local read):

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

Identical, unambiguous, single-license MIT grant on both Linux
architectures — no license discrepancy of the kind `docs/
pdfium-evaluation.md` found and flagged for PDFium.

## Real reproduction steps

```sh
curl -fsSL "https://github.com/ggml-org/llama.cpp/releases/download/b11222/llama-b11222-bin-ubuntu-x64.tar.gz" -o llama-linux-x64.tar.gz
curl -fsSL "https://github.com/ggml-org/llama.cpp/releases/download/b11222/llama-b11222-bin-ubuntu-arm64.tar.gz" -o llama-linux-arm64.tar.gz
shasum -a 256 llama-linux-x64.tar.gz llama-linux-arm64.tar.gz
# -> cfd2323f9ffec9657ca247140129be68df62d98f30a8448b20b1ca7a1796e1cb  llama-linux-x64.tar.gz
# -> 9099b2dd5fbd8391b4e189d78c117d263e4afe23717af92f8349fc1b67e4d40d  llama-linux-arm64.tar.gz
mkdir -p extracted/x64 extracted/arm64
tar -xzf llama-linux-x64.tar.gz -C extracted/x64
tar -xzf llama-linux-arm64.tar.gz -C extracted/arm64
```

Cross-checked against GitHub's cryptographic Artifact Attestation, the
same way `llama-inference-evaluation.md` verified the macOS asset:

```sh
gh attestation verify llama-linux-x64.tar.gz -R ggml-org/llama.cpp --format json
gh attestation verify llama-linux-arm64.tar.gz -R ggml-org/llama.cpp --format json
```

Both verified successfully (exit 0). Both attestations are the **same
signed statement** already verified for the macOS asset — one provenance
document per release covering all 35 platform/backend assets, workflow
`ggml-org/llama.cpp/.github/workflows/release.yml@refs/heads/master`,
build/source commit `a97cce86a8addeb9f40cba7a261c94b1f0c576cb`, run
`https://github.com/ggml-org/llama.cpp/actions/runs/36336478949/attempts/1`
— and each Linux asset's listed digest in that statement
(`llama-b11222-bin-ubuntu-x64.tar.gz` → `cfd2323f...`,
`llama-b11222-bin-ubuntu-arm64.tar.gz` → `9099b2dd...`) matches the
locally computed hash above byte-for-byte. This is the same build run
that produced the already-pinned macOS artifact, not a different or later
build.

Archive sizes: 17.40 MB compressed / 43 MB extracted (x86_64), 13.50 MB
compressed / 31 MB extracted (aarch64) — both noticeably larger than the
macOS artifact (11.76 MB compressed / ~30 MB uncompressed), explained
below.

## File format / ABI identification (`file`(1), `nm`, `objdump`)

This machine cannot execute either binary. What **was** checked, directly,
on the real downloaded files:

```sh
file extracted/x64/llama-b11222/libllama.so.0.5.0
# -> ELF 64-bit LSB shared object, x86-64, version 1 (GNU/Linux), dynamically linked, BuildID[sha1]=f15076db72dc7015577b9dddd5dc1a95126bdce1, not stripped
file extracted/arm64/llama-b11222/libllama.so.0.5.0
# -> ELF 64-bit LSB shared object, ARM aarch64, version 1 (GNU/Linux), dynamically linked, BuildID[sha1]=a56ca47f4f3ce352378a9d0bfe752e3ac5b5ebfd, not stripped
```

Both report the correct, distinct target architecture — no cross-arch
mislabeling. Neither is a `Mach-O` (the macOS artifact's format).

Runtime dependency closure (`objdump -p`, since this host has no
`readelf`):

```sh
objdump -p extracted/x64/llama-b11222/libllama.so.0.5.0 | grep -i needed
# -> libggml.so.0  libggml-base.so.0  libstdc++.so.6  libm.so.6  libgcc_s.so.1  libc.so.6  ld-linux-x86-64.so.2
objdump -p extracted/x64/llama-b11222/libggml-base.so.0.25.3 | grep -i needed
# -> libgomp.so.1  libstdc++.so.6  libm.so.6  libgcc_s.so.1  libc.so.6
```

`libllama.so` depends only on llama.cpp's own `libggml*.so` family plus
ordinary glibc/libstdc++/libgcc_s — the same clean-dependency shape the
macOS `otool -L` check already found (`@rpath/libggml*.dylib` plus Apple
system libraries only). One genuinely new, disclosed finding for Linux:
`libggml-base.so` additionally links `libgomp.so.1` (GNU OpenMP), a
runtime dependency with no equivalent entry in the macOS artifact's
`otool -L` output — a real, Linux-specific system-library requirement any
future Linux wiring would need (glibc systems ship `libgomp` as part of
GCC's runtime, so this is not expected to be an extra install step on a
typical Linux host, but it was not present to check on macOS and is
recorded here rather than assumed away).

A second, larger disclosed difference: **both Linux archives ship
multiple microarchitecture-specific CPU backend shared libraries** —
14 `libggml-cpu-*.so` variants in the x86_64 archive (`alderlake`,
`cannonlake`, `cascadelake`, `cooperlake`, `haswell`, `icelake`,
`ivybridge`, `piledriver`, `sandybridge`, `sapphirerapids`, `skylakex`,
`sse42`, `x64`, `zen4`) and 8 in the aarch64 archive (`armv8.0_1` through
`armv9.2_2`), versus the macOS `otool -L` record showing only a single
`libggml-cpu.0.dylib`-family entry. None of these variant `.so` files
appears in `libllama.so`'s or `libggml-base.so`'s own `NEEDED` list
(confirmed by `objdump -p` above) — they are not link-time dependencies,
consistent with llama.cpp's documented runtime CPU-feature-dispatch design
(selecting the best-matching backend at `llama_backend_init()` time,
likely via its own internal `dlopen`). This is real, disclosed
architectural complexity specific to the Linux build that this
evaluation could not resolve further without executing the library: a
real Linux deployment must ship (or at minimum not delete) the full set
of `libggml-cpu-*.so` files alongside `libllama.so`, not just the one
`.so` a naive "copy the needed libraries" step might assume from the
`NEEDED` list alone. This is disclosed here rather than silently missed,
the same way `docs/pdfium-evaluation.md` and `llama-inference-evaluation.md`
disclose other real surprises found along the way rather than smoothing
them over. It is also the direct explanation for the larger-than-macOS
archive sizes noted above.

Symbol resolution (`nm -D`, dynamic symbol table): all fifteen symbols
`experiments/llama_check/evaluate.d` resolves and
`source/effects/llama_ffi.d` `dlsym`s were confirmed **present and
exported** in both Linux artifacts' `libllama.so.0.5.0`:

```
llama_backend_init llama_backend_free llama_model_default_params
llama_context_default_params llama_model_load_from_file llama_model_free
llama_model_get_vocab llama_init_from_model llama_free
llama_vocab_n_tokens llama_tokenize llama_token_to_piece
llama_batch_get_one llama_decode llama_get_logits_ith llama_vocab_is_eog
```

All fifteen present (`nm -D ... | grep " T <symbol>$"` matched) in both
`llama-b11222-bin-ubuntu-x64.tar.gz` and
`llama-b11222-bin-ubuntu-arm64.tar.gz`. This confirms the exact symbol
surface this codebase's existing macOS FFI module already depends on is
exported by the Linux binaries too. **This is static evidence the same
symbol names link, not proof the by-value struct ABI (`llama_model_params`
/ `llama_context_params` / `llama_batch`) matches** —
`llama-inference-evaluation.md` already disclosed that this by-value
struct-passing is a materially harder FFI binding correctness question
than PDFium's opaque-pointer-only API, and that risk is not reduced at all
by this section's static-only Linux check: a struct-layout mismatch would
not show up as a missing symbol, it would show up as silent memory
corruption at call time, which this evaluation had no way to detect
without actually calling the function on a real Linux host.

## Cost summary (Linux, both architectures)

| Path | Download size (this host) | Toolchain required | Network at build time | Functional verification performed |
| --- | --- | --- | --- | --- |
| `ggml-org/llama.cpp` release binary, ubuntu-x64 (CPU) | 17.40 MB compressed, ~43 MB uncompressed | None beyond `curl`/`tar` | One-time download only | **None** — archive integrity, license text, `file`/`nm`/`objdump` static identification only; cannot execute Linux ELF on this Darwin arm64 host |
| `ggml-org/llama.cpp` release binary, ubuntu-arm64 (CPU) | 13.50 MB compressed, ~31 MB uncompressed | None beyond `curl`/`tar` | One-time download only | **None** — same reason |

## What this document does and does not establish

**Checked and confirmed real**: both assets exist at the exact pinned
release already trusted for macOS in `llama-inference-evaluation.md`,
download and extract cleanly, carry a GitHub Artifact Attestation
verifying the same build run that produced the macOS asset, ship the
byte-identical MIT `LICENSE`, report the correct distinct target
architecture via `file`(1), depend only on ordinary glibc/libstdc++/
libgomp system libraries with no third-party dynamic dependency beyond
llama.cpp's own `libggml*` family, and statically export every one of the
fifteen C symbols this codebase's existing macOS FFI module
(`llama_ffi.d`) and its evaluation harness
(`experiments/llama_check/evaluate.d`) already rely on.

**Not checked, and not claimed**: no Linux binary was ever loaded, called,
or executed on any machine during this evaluation — no `dlopen`, no
`llama_backend_init` call, no tokenization, no decode, on either
architecture. This machine's inability to run foreign-arch/foreign-OS ELF
binaries is the reason. In particular, the by-value struct ABI risk
`llama-inference-evaluation.md` already flagged as this project's central
open FFI-correctness question is **not addressed at all** by this
document's static checks — that risk can only be retired by actually
calling into the library on a real Linux host. Nor was the
runtime-CPU-dispatch mechanism (the `libggml-cpu-*.so` family) exercised;
this evaluation only confirmed the files exist and are not link-time
`NEEDED` dependencies, not that the dispatch logic correctly selects and
loads one at runtime.

## Recommendation (not a decision)

The evidence gathered here is **adopt-leaning for further work, not yet
adopt-ready** — narrower than PDFium's Linux evidence in one respect: the
license and provenance picture is equally clean (identical MIT text,
identical attested build run), but llama.cpp's own by-value-struct FFI
surface (already the single largest disclosed risk in
`llama-inference-evaluation.md`'s macOS evaluation) and the newly-disclosed
Linux-specific runtime-CPU-dispatch multi-`.so` deployment shape are two
real, unretired risks that this Darwin-arm64-only static check could not
reduce at all. The concrete next step, if @schancel decides to pursue
Linux support, is running `experiments/llama_check/evaluate.d`'s existing
harness (or an equivalent) against these exact two artifacts — including
verifying the `libggml-cpu-*.so` runtime-dispatch files are correctly
discovered — on a real Linux x86_64 and a real Linux aarch64 host, before
widening `llama_ffi.d`'s version gate. No `dub.json` or `source/` change
was made by this evaluation.

## Rollback

Delete `docs/llama-cpp-evaluation.md`. Zero blast radius on any shipped
module: nothing in `source/`, `dub.json`, or any stage imports or
references anything from this evaluation. `docs/llama-inference-
evaluation.md` (the pre-existing macOS evaluation) is unaffected — this
document does not modify it.
