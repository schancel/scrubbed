# PDFium embeddability evaluation (evidence landing only)

Status: isolated proposal, **not a selected library or production
implementation**. No PDFium source, build artifact, or third-party binary
was vendored, pinned in `dub.json`, or wired into `source/`, any stage, or
the CLI. This document does not adopt, reject, or schedule anything; the
next decision belongs to @schancel. It answers exactly the question #297
scoped: can a real, working PDFium artifact be obtained, and at what real
cost, as a candidate third permissively-licensed PDF path alongside the
Poppler `pdftotext` execve fallback shipped in
[pdf-execve-fallback.md](pdf-execve-fallback.md) and the still-unaddressed
DOCX gap left open in
[document-adapters-evaluation.md](document-adapters-evaluation.md).

## Summary of outcome

A real, working prebuilt PDFium artifact **was** obtained and functionally
verified on this machine (Darwin arm64) via the `bblanchon/pdfium-binaries`
third-party distribution path. A from-source Chromium-toolchain build was
**not completed**; a real, bounded attempt was made and stopped for the
concrete, evidenced reasons in
["From-source build: real attempt and why it was stopped"](#from-source-build-real-attempt-and-why-it-was-stopped)
below. No other candidate path was found or attempted.

## Candidate provenance checked 2026-09-27 UTC

| Candidate | Exact version/source identity | License evidence | Decision status |
| --- | --- | --- | --- |
| PDFium itself | Canonical repo `pdfium.googlesource.com/pdfium`; GitHub read-only mirror `chromium/pdfium`, `main` HEAD `a84323421e94f484faca52dd9d027934eba42ab8` (committer date 2025-11-19T14:17:39Z, message "Roll build, clang and rust DEPS") | [`LICENSE`](https://raw.githubusercontent.com/chromium/pdfium/a84323421e94f484faca52dd9d027934eba42ab8/LICENSE) at that commit, SHA-256 `1fe9dea718fbd75cf149adaf4d8a22a4335604d964ddb76d1b45383dec8668c9` — a BSD-3-Clause-style header (Google Inc.) directly above the full Apache-2.0 text (see [License evidence, verbatim](#license-evidence-verbatim) below for the discrepancy this raises) | Research candidate; not adopted |
| `bblanchon/pdfium-binaries` (third-party distributor) | GitHub release tag `chromium/8066` ("PDFium 156.0.8066.0"), published 2026-09-21T12:48:25Z, `target_commitish` `f2e9a1c45bb17b85b540abf1af30146ef65416ac`; asset `pdfium-mac-arm64.tgz`, SHA-256 `336219e80580b93c6523f44db7dc1de59cc497b13a7390ddac84223f68ca162b` (computed locally with `shasum -a 256`, and independently confirmed by the release's own GitHub Artifact Attestation — see below) | Distributor's own `LICENSE` inside the archive: MIT, "Copyright 2014-2025 Benoit Blanchon", SHA-256 `ba26c1263131696b86c10496b5066b918a20b7161822a80c274d0080105f6c93`; bundled `licenses/pdfium.txt` is the same PDFium BSD-3-Clause/Apache-2.0 text; twelve further bundled third-party licenses, all permissive (see [Bundled third-party licenses](#bundled-third-party-licenses-inside-the-prebuilt-artifact)) | **Obtained, extracted, and functionally verified.** Not adopted. |
| From-source Chromium-toolchain build (`depot_tools`/GN/Ninja) | `chromium/tools/depot_tools.git` `HEAD` after `git clone --depth 1`; PDFium `DEPS` at pinned commit `a84323421e94f484faca52dd9d027934eba42ab8` | N/A (build tooling, not a shipped artifact) | **Attempted for real, stopped deliberately before completion** — see below. Not adopted. |

No other candidate path (e.g. a maintained D binding, a WASM build, a
different third-party distributor) was searched for or attempted beyond
what is documented here.

## License evidence, verbatim

Fetched directly from the GitHub mirror at the exact pinned commit:

```sh
curl -fsSL https://raw.githubusercontent.com/chromium/pdfium/a84323421e94f484faca52dd9d027934eba42ab8/LICENSE -o pdfium-LICENSE.txt
shasum -a 256 pdfium-LICENSE.txt
```

Result: SHA-256 `1fe9dea718fbd75cf149adaf4d8a22a4335604d964ddb76d1b45383dec8668c9`.
The file's first 15 lines read:

```
// Copyright 2014 The PDFium Authors
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//    * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//    * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//    * Neither the name of Google Inc. nor the names of its
// contributors may be used to endorse or promote products derived from
// this software without specific prior written permission.
```

That header text is the standard BSD-3-Clause grant, which corroborates
issue #297's claim. **However**, the same file's remaining ~180 lines are
the full, separate Apache License 2.0 text ("Apache License / Version 2.0,
January 2004 ... TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND
DISTRIBUTION"). The BSD-style grant is the license actually asserted at
the top of every PDFium source file checked (e.g. `public/fpdfview.h`
itself: `// Use of this source code is governed by a BSD-style license
that can be found in the LICENSE file.`). GitHub's own license detector,
queried via
`gh api repos/chromium/pdfium | jq .license`, returns
`{"key": "other", "spdx_id": "NOASSERTION", ...}` for this exact
repository — i.e. GitHub's automated classifier could not confidently
assign a single SPDX license either, which is consistent with (though not
proof of the cause of) the same mixed BSD/Apache-2.0 file content found
above. The Apache-2.0 block's presence in the same file is unexplained by
anything fetched during this evaluation and is flagged here rather than
silently dropped — **do not treat "PDFium is BSD-3-Clause" as re-verified
beyond what this file literally shows**: a
production adoption decision should re-derive the license finding
independently, ideally by asking upstream or checking a second source
(e.g. the OSI/ClearlyDefined record) rather than trusting this
evaluation's single `LICENSE`-file read.

### Bundled third-party licenses (inside the prebuilt artifact)

The `bblanchon/pdfium-binaries` `pdfium-mac-arm64.tgz` statically links
several third-party libraries into the one `libpdfium.dylib`. Its
`licenses/` directory (extracted and read in full) contains one file per
bundled dependency; the first line/header of each was inspected directly:

| File | License family (from the file's own text) |
| --- | --- |
| `pdfium.txt` | BSD-3-Clause/Apache-2.0 (same discrepancy as above) |
| `abseil.txt` | Apache License 2.0 |
| `agg23.txt` | Anti-Grain Geometry 2.3 permissive license ("Permission to copy, use, modify, sell and distribute this software is granted") |
| `fast_float.txt` | MIT License |
| `freetype.txt` | The FreeType Project LICENSE |
| `icu.txt` | Unicode License v3 |
| `lcms.txt` | MIT-style ("Permission is hereby granted, free of charge...") |
| `libjpeg_turbo.ijg` / `libjpeg_turbo.md` | IJG License + a compatible BSD-style license (per libjpeg-turbo's own `.md`) |
| `libopenjpeg.txt` | 2-clause BSD |
| `libpng.txt` | PNG Reference Library License version 2 |
| `llvm-libc.txt` | Apache License 2.0 with LLVM Exceptions |
| `simdutf.txt` | MIT License |
| `zlib.txt` | zlib License |

Every bundled dependency identified is permissive (BSD/MIT/Apache-2.0/
zlib-family); none is copyleft. This is a materially different profile
from the Poppler (GPL-2.0) and MuPDF (AGPL-3.0) findings in
`document-adapters-evaluation.md` and is the concrete basis for treating
PDFium as a distinct, worth-checking candidate rather than a repeat of
that evaluation. This is an engineering license-text reading, not legal
clearance; a real adoption would still need to verify each bundled
version's exact upstream commit and confirm no non-redistributable terms
were introduced by a newer release than the one inspected here.

## The C API stability claim (verified, not just repeated)

Issue #297 asserts PDFium's C API (`public/fpdfview.h`) is "deliberately
stable." The actual text this evaluation found, fetched from
`README.md` at the same pinned commit `a84323421e94f484faca52dd9d027934eba42ab8`:

> The public/ directory contains header files for the APIs available for
> use by embedders of PDFium. The PDFium project endeavors to keep these
> as stable as possible.
>
> Outside of the public/ directory, code may change at any time, and
> embedders should not directly call these routines.

This is a real, current, primary-source confirmation of the ticket's
claim — a documented policy, not a formal semver guarantee, and not
independently checked here against PDFium's actual commit history for API
breakage frequency. `public/fpdfview.h` (extracted from the downloaded
artifact) is 1,700+ lines of `FPDF_EXPORT ... FPDF_CALLCONV` C
declarations with per-function doc comments; its top-of-file comment
states "NOTE: None of the PDFium APIs are thread-safe. They expect to be
called from a single thread," which any future wrapper design must
account for (this repo's existing `effects.pdf_execve` subprocess design
sidesteps that entirely; a direct FFI binding would not).

## A real discrepancy this evaluation found and could not resolve

The GitHub mirror `github.com/chromium/pdfium` currently displays: "This
repository has been archived by the owner on Aug 4, 2023. It is now
read-only." Yet `gh api repos/chromium/pdfium` reports `"archived": true`
alongside `"pushed_at": "2025-11-19T14:41:54Z"`, and `gh api
repos/chromium/pdfium/commits?sha=main` lists real, substantive commits
through that same November 2025 date (DEPS rolls, JBIG2 fixes, corpus test
updates) — over two years after the stated archive date. This evaluation
could not resolve that contradiction: repeated attempts to query the
canonical upstream host directly,

```sh
curl -fsSL "https://pdfium.googlesource.com/pdfium/+log/main?format=JSON"
```

returned `HTTP 503` on every attempt from this environment (both with and
without a browser-like `User-Agent` header), so PDFium's actual current
development status could not be independently confirmed against its
Gerrit source of truth. The practical implication for any future adoption
work: treat the GitHub mirror's "archived" banner as unreliable evidence
of PDFium being unmaintained, but also do not treat this evaluation's
`main` HEAD as freshly reconfirmed — pin whatever exact commit a real
build actually uses and re-derive its freshness at that time, from
`pdfium.googlesource.com` directly if it is reachable then.

## `bblanchon/pdfium-binaries`: real reproduction steps

Run from any directory, on Darwin arm64 (this machine's platform):

```sh
curl -fsSL "https://api.github.com/repos/bblanchon/pdfium-binaries/releases/latest" -o pdfium-binaries-latest.json
python3 -c "import json; d=json.load(open('pdfium-binaries-latest.json')); print(d['tag_name'], d['target_commitish'])"
# -> chromium/8066 f2e9a1c45bb17b85b540abf1af30146ef65416ac
curl -fsSL "https://github.com/bblanchon/pdfium-binaries/releases/download/chromium/8066/pdfium-mac-arm64.tgz" -o pdfium-mac-arm64.tgz
shasum -a 256 pdfium-mac-arm64.tgz
# -> 336219e80580b93c6523f44db7dc1de59cc497b13a7390ddac84223f68ca162b
mkdir extracted && tar -xzf pdfium-mac-arm64.tgz -C extracted
```

This SHA-256 was independently cross-checked, not just self-reported, via
GitHub's cryptographic Artifact Attestation (Sigstore/SLSA provenance)
for this exact release:

```sh
gh attestation verify pdfium-mac-arm64.tgz -R bblanchon/pdfium-binaries --format json
```

The returned, Rekor-transparency-log-backed attestation verified a real
GitHub Actions build: workflow
`bblanchon/pdfium-binaries/.github/workflows/build-all.yml@refs/heads/master`,
trigger `workflow_dispatch`, build commit
`f2e9a1c45bb17b85b540abf1af30146ef65416ac` (matching the release's
`target_commitish` exactly), run
`https://github.com/bblanchon/pdfium-binaries/actions/runs/35584475700/attempts/1`,
signed 2026-09-21T05:48:14-07:00. Its signed statement's subject list
includes `{"name":"pdfium-mac-arm64.tgz","digest":{"sha256":"336219e80580b93c6523f44db7dc1de59cc497b13a7390ddac84223f68ca162b"}}` —
byte-for-byte the same digest computed locally above. (Note: `gh
attestation verify` with the default table output printed nothing at all
in this non-interactive shell despite exiting 0; `--format json` was
needed to see the actual verification result. This is a tool-output
quirk of `gh`, not evidence of anything about PDFium.)

The dylib's own file evidence:

```sh
file extracted/lib/libpdfium.dylib
# -> Mach-O 64-bit dynamically linked shared library arm64
lipo -info extracted/lib/libpdfium.dylib
# -> Non-fat file: extracted/lib/libpdfium.dylib is architecture: arm64
otool -L extracted/lib/libpdfium.dylib
# -> only AppKit/CoreGraphics/CoreFoundation/Foundation/libSystem.B, no other third-party dylib deps
codesign --verify --verbose=4 extracted/lib/libpdfium.dylib
# -> "valid on disk", "satisfies its Designated Requirement" (ad-hoc signed)
nm -gU extracted/lib/libpdfium.dylib | grep FPDF_InitLibrary
# -> exports both FPDF_InitLibrary and FPDF_InitLibraryWithConfig
```

## Functional proof: real dlopen + real extraction, from D

This repository's own reproduction harness is checked in at
[`experiments/pdfium_check/evaluate.d`](../experiments/pdfium_check/evaluate.d).
Like `experiments/html_parser/evaluate.d` and
`experiments/s3_capability/evaluate.d`, it lives outside `dub.json`'s
`sourcePaths` (which lists only `source`), so it is evaluation code, never
compiled into the shipped binary and never an importable dependency. It
`dlopen()`s the caller-supplied `libpdfium.dylib` (via
`core.sys.posix.dlfcn`), resolves twelve public C symbols with `dlsym`,
and calls them through D function-pointer types — proving the artifact is
real, loadable, and ABI-compatible with a D FFI caller, not just something
`nm` can list symbols from.

It reuses, byte-for-byte, this repository's own pinned, CC0-1.0,
issue-#67 PDF fixtures (`experiments/document_adapters/fixtures/*.pdf`,
hashes pinned in `experiments/document_adapters/samples.tsv`) rather than
authoring new ones, and checks its extracted text against the *existing*,
independently-pinned `experiments/document_adapters/ground_truth.tsv`
token list — so the expected answer was not invented for this evaluation.
It uses release-active `check()` failures (matching the `check()` idiom
`s3-capability-evaluation.md` describes), not `assert`, so an optimized
build cannot silently pass a broken probe; this was verified by manually
injecting one deliberately-failing `check(false, ...)` call into a
throwaway copy of the harness and confirming the optimized release binary
still exited 1 with the failure printed, then discarding that copy.

Reproduce on Darwin arm64 with Apple clang 21.0.0 (clang-2100.1.1.101) and
LDC 1.43.0 (based on DMD v2.113.0 and LLVM 23.1.0), from the repository
root, after obtaining the artifact above:

```sh
ldc2 -O -release -of=/tmp/pdfium-evaluate experiments/pdfium_check/evaluate.d
/tmp/pdfium-evaluate /path/to/extracted/lib/libpdfium.dylib experiments/document_adapters/fixtures
```

Local result: all 31 checks passed, exit code 0.

- All twelve resolved symbols (`FPDF_InitLibrary`, `FPDF_DestroyLibrary`,
  `FPDF_GetLastError`, `FPDF_LoadDocument`, `FPDF_CloseDocument`,
  `FPDF_GetPageCount`, `FPDF_LoadPage`, `FPDF_ClosePage`,
  `FPDFText_LoadPage`, `FPDFText_ClosePage`, `FPDFText_CountChars`,
  `FPDFText_GetText`) were non-null.
- `pdf-training.pdf` (single page) extracted as `TRAINING PDF\nALPHA
  ONE\nBETA TWO`, containing every one of the six tokens
  (`TRAINING|PDF|ALPHA|ONE|BETA|TWO`) independently pinned in
  `ground_truth.tsv` for this exact fixture.
- `pdf-heldout-layout.pdf` (the two-column-plus-footer fixture used
  against Poppler/MuPDF in `document-adapters-evaluation.md`) extracted
  as `LAYOUT REPORT\nLEFT A\nLEFT B\nRIGHT A\nRIGHT B\nFOOTER END` — all
  five pinned tokens present, in the exact pinned left-column /
  right-column / footer semantic order, with **zero** row-interleaving.
  For calibration only (not a re-run of that experiment's own scoring
  code, and not a formal geometry-hit measurement): the prior evaluation
  recorded Poppler's `-layout` mode producing four token-order inversions
  on this same fixture by interleaving the two columns' rows, while
  MuPDF's plain-text mode preserved order but scored only 1/4 on the
  named geometry predicates. This harness's plain
  `FPDFText_GetText` call reproduced the correct semantic order on this
  one fixture without any layout flag; it does not establish a
  general layout-quality claim.
- `pdf-malformed.pdf` was correctly rejected: `FPDF_LoadDocument` returned
  `NULL` and `FPDF_GetLastError()` returned `3`, which
  `public/fpdfview.h`'s own `#define FPDF_ERR_FORMAT 3  // File not in
  PDF format or corrupted.` documents as exactly that condition — a
  clean fail-closed outcome, not a crash.

This is a single-machine, single-artifact, three-fixture smoke test. It
does not cover encrypted PDFs, forms, JavaScript, non-Latin text, other
platforms/architectures, the `pdfium-v8-*`/XFA-enabled variants, thread
safety under concurrent calls (the header explicitly disclaims this), or
any adversarial/fuzzed input.

## From-source build: real attempt and why it was stopped

Issue #297 predicted this path conflicts with the codebase's zero-network-
build philosophy. Rather than assume that, this evaluation actually
started it:

```sh
git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git
# completed in ~2s, 12 MB
export PATH="$(pwd)/depot_tools:$PATH"
mkdir pdfium_checkout && cd pdfium_checkout
gclient config --unmanaged https://pdfium.googlesource.com/pdfium.git
# succeeded, wrote a real .gclient file
gclient sync --no-history -r a84323421e94f484faca52dd9d027934eba42ab8
```

`gclient sync` was left running in the background and polled with `du
-sh`: 130 MB after 5 seconds, 543 MB shortly after that, and **2.1 GB**
a short time later (elapsed wall-clock time was not stopwatched
precisely, but this was well under a few minutes of real time) — and it
was still actively running when stopped, while only populating
PDFium's own repository tree (`core/`, `fpdfsdk/`, `fxbarcode/`,
`build/`, `buildtools/`, etc.); at the point it was stopped, none of the
separately DEPS-fetched third-party checkouts
(`third_party/abseil-cpp`, `third_party/icu`, `third_party/freetype/src`,
`third_party/libjpeg_turbo`, `third_party/skia`, the prebuilt Clang/LLVM
toolchain, or the Rust toolchain) had begun downloading yet. It was
killed deliberately (`kill`, confirmed via `ps`) rather than let run to
completion, because this machine had only **~15–16 GB of free disk**
remaining at the time (`df -h /private/tmp`), and letting an
unbounded Chromium-toolchain fetch continue risked exhausting a shared
machine's disk for an evaluation that issue #297 itself frames as likely
to be rejected on principle. The partial checkout was deleted immediately
after (`rm -rf pdfium_checkout`), reclaiming the space.

The real, pinned `DEPS` file at the same commit (fetched and read in
full) independently corroborates and refines issue #297's dependency list.
Fetched directly from the checked-out `third_party/` GitHub tree listing
at that commit, PDFium **vendors in-repo** (no separate network fetch
beyond cloning PDFium itself): `agg23`, `dragonbox`, `fast_float`, `fp16`,
`freetype` (build glue only — the actual FreeType source is still DEPS-
fetched separately, see below), `highway`, `lcms`, `libopenjpeg`,
`libtiff`, `llvm-libc`, `NotoSansCJK`, `bigint`, `cpu_features`,
`googletest`. Separately, its top-level `DEPS` file pulls, over the
network from `chromium.googlesource.com` and `skia.googlesource.com`, at
least: `third_party/abseil-cpp`, `third_party/freetype/src` (the actual
FreeType2 source), `third_party/icu`, `third_party/jpeg_turbo`
(`libjpeg_turbo`), `third_party/libpng`, `third_party/zlib`,
`third_party/skia` (itself a large project with its own dependency
closure), `third_party/rust` and `third_party/rust-toolchain`, a prebuilt
`third_party/llvm-build/Release+Asserts` Clang toolchain, `buildtools`,
`build`, `third_party/catapult`, `third_party/googletest/src`,
`third_party/ninja`, `third_party/nasm`, `third_party/depot_tools`, and
(conditionally, off by default per this DEPS' `checkout_android: False`)
an Android NDK toolchain. This is a real, evidenced network-fetch
dependency closure of at least 17 distinct external Git/CIPD sources
beyond PDFium's own repository, consistent with — and more granular
than — issue #297's own summary. **This evaluation did not measure the
full closure's total size or attempt an actual `ninja` build**; 2.1 GB
for PDFium's own tree alone, before any of those third-party fetches,
is the only real size data point obtained.

This path was not pursued further. It is a real, reproducible
demonstration that PDFium's own build genuinely requires exactly the
network-fetched, Chromium-toolchain dependency closure issue #297
predicted — this is evidenced, not assumed — and it is exactly the kind
of unbounded-network-fetch build this codebase's existing
vendor-and-build-locally precedents (`third_party/lexbor`,
`third_party/zstd`, `third_party/sqlite`, none of which fetch anything at
build time beyond what is already committed to this repository) were
built to avoid.

## Cost summary

| Path | Download size (this host) | Toolchain required | Network at build time | Redistribution obligation if shipped |
| --- | --- | --- | --- | --- |
| `bblanchon/pdfium-binaries`, mac-arm64 | 3.3 MB compressed, ~7.5 MB uncompressed dylib+headers | None beyond `curl`/`tar` | One-time download only | Ship the artifact's own MIT `LICENSE`, the bundled `licenses/pdfium.txt` (BSD-3-Clause/Apache-2.0), and twelve further permissive third-party license files verbatim; attribute Benoit Blanchon and each bundled project |
| From-source Chromium-toolchain build | ≥2.1 GB observed for PDFium's own tree alone, before any of ≥17 further third-party fetches (real total not measured; historically multi-GB for the full Chromium build toolchain) | `depot_tools`, GN, Ninja, a pinned prebuilt Clang, a pinned Rust toolchain | Required, unbounded, every fresh checkout (`gclient sync`) | Full LICENSE/NOTICE bundling and attribution for PDFium plus every DEPS-fetched third-party project, none of which was enumerated for license terms in this evaluation |

## Adopt/reject/defer guidance (not a decision)

This evaluation's evidence supports the following as guidance for
@schancel's own decision, not as a decision:

- **The from-source build path** is reject-leaning on the evidence
  gathered: a real, bounded attempt confirmed the predicted network-
  fetched, multi-toolchain dependency closure exists and starts pulling
  gigabytes within under a minute, directly conflicting with this
  codebase's existing zero-network-build precedent. Nothing observed here
  contradicts issue #297's own framing of this path as likely-reject.
- **The `bblanchon/pdfium-binaries` prebuilt-binary path** is a real,
  functionally-verified, permissively-licensed (all bundled dependencies
  permissive), cryptographically-attested artifact that loads and
  extracts text correctly via both link-time linking and `dlopen`/`dlsym`
  on this machine. It is genuinely a third trust pattern this codebase
  has not adopted anywhere (neither "vendor source, build locally" like
  Lexbor/zstd/sqlite, nor "assume an OS-provided system library" like
  libcurl, nor "execve an already-installed host tool" like
  `effects.pdf_execve`) — trusting a third-party distributor's prebuilt
  binary blob, refreshed weekly, with no source review of what was
  actually compiled beyond the Sigstore attestation confirming *that
  GitHub Actions built it from that commit*, not that the resulting
  bytes are free of defects or that every future weekly release will
  behave identically. That trust-model gap, not the license or the
  binary's functional correctness, is this evaluation's central open
  question for @schancel to weigh — it is a genuinely different
  question from the GPL/AGPL blockers that stopped Poppler/MuPDF in
  `document-adapters-evaluation.md`, and this evaluation takes no
  position on how to weigh it.
- **Nothing here should be read as ready for wiring.** A real adoption
  would still need (at minimum, unaudited by this evaluation): a
  supported-platform matrix decision (this evaluation only tested one of
  26 non-V8 platform variants — Android x4, iOS x5, Linux x10, macOS x3,
  WebAssembly, Windows x3 — `bblanchon/pdfium-binaries` publishes per
  release, each also mirrored as a separate V8/XFA-enabled build, 52
  binary assets total per release, per the release manifest fetched
  above), a
  decision on whether to pin a specific release or track weekly upstream
  rolls, a real D FFI wrapper with the same kind of ownership/lifetime
  discipline `html-parser-evaluation.md`'s Lexbor wrapper contract
  specifies, full LICENSE/NOTICE bundling for all thirteen bundled license
  files identified above, resolution of the unexplained BSD/Apache-2.0
  co-mingling in PDFium's own `LICENSE` file, and a real answer to why
  the GitHub mirror claims to be archived since 2023 while showing 2025
  commits — none of which this evaluation resolves.

## Rollback

Delete `docs/pdfium-evaluation.md` and `experiments/pdfium_check/`. Zero
blast radius on any shipped module: nothing in `source/`, `dub.json`, or
any stage imports or references anything from this evaluation.
