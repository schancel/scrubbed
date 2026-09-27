# Third-party notices

## Zstandard decompressor and compressor

The pinned Zstandard v1.5.7 source -- both the original decompression-only
subset and, for issue #168's `compressibility-annotate` stage, an added
compression-side subset pinned to the exact same `v1.5.7` release -- is
statically compiled for macOS arm64. The source is dual-offered under
BSD-style or GPLv2 terms; this project explicitly selects the BSD-style
alternative and does **not** select GPLv2. The complete upstream
[`LICENSE`](third_party/zstd/LICENSE), source-file copyright notices, exact
release tarball SHA-256, per-file hash manifest (now covering both the
decompression and compression subsets), omitted modules, and no-network build
are documented in [`third_party/zstd/README.md`](third_party/zstd/README.md).
The included xxHash implementation is credited to Yann Collet / Meta in its
source files and shares that license alternative. No separately licensed
transitive library is included in the linked decompression or compression
graph. The compressed-WARC adapter uses the same pinned decompression static
archive; it does not add a dynamic libzstd. The new compression archive
(`libzstd_compress.a`) omits the compressor's multithreading translation unit
entirely (this project never defines `ZSTD_MULTITHREAD`) and omits the
dictionary builder, legacy decoder, and x86 assembly, matching the
decompression archive's own existing omissions; `effects
.compressibility_annotate_stage` uses only the fixed-level (19), non-streaming,
non-dictionary one-shot buffer compression API from it.

The compressed adapter dynamically opens macOS system
`/usr/lib/libz.1.dylib` with `dlopen`/`RTLD_FIRST`, resolves only that image's
symbols through `dlsym`, and closes its handle on terminal paths. There is no
standalone-static package claim. On the supported build host (macOS 26.6.2
arm64), the release-built D probe's `dladdr` identifies that exact image and
its `zlibVersion()` returns **1.2.12**. The SDK `zlib.h` and the system
`/usr/bin/gzip` load-command metadata (`otool -L`) also show 1.2.12. The probe
itself has no libz load
command in `otool -L`, because the binding is explicit at runtime. Phobos may
bundle independent zlib symbols in a D binary; those symbols are not used by
this adapter. The library provided by each supported macOS installation is a
platform dependency. zlib is copyright 1995–2022 Jean-loup
Gailly and Mark Adler under the permissive zlib license shown in the platform
SDK's `zlib.h`: use, modification and redistribution are permitted, with no
warranty; redistributors must not misrepresent origin, must mark altered
source, and must preserve the notice in source distributions. This project
does not copy or modify zlib source.

## Lexbor

The pinned Lexbor v3.0.0 source builds as a static archive, and the FFI/ABI
unit-test binary links it. The shipping CLI does not yet link Lexbor; that
awaits the restricted production wrapper in the next slice. Lexbor is
copyright 2018–2026 Alexander Borisov and licensed under Apache 2.0. The complete
upstream [`LICENSE`](third_party/lexbor/LICENSE) and
[`NOTICE`](third_party/lexbor/NOTICE) are bundled. Exact commit, source-tree
identity, copied-file hashes, omitted upstream material, static build and
supported platform are recorded in
[`third_party/lexbor/README.md`](third_party/lexbor/README.md).

Lexbor's numeric-conversion source includes BSD-style notices attributed to
NGINX, Inc.; F5, Inc.; Igor Sysoev; Dmitry Volyntsev; Alexander Borisov; and
Vadim Zhestikov. Those complete notices are preserved in the unmodified
`source/lexbor/core/{diyfp,dtoa,strtod}.{c,h}` files, including the binary
redistribution condition. The pinned CMake archive also includes Lexbor's
other source modules; no independently licensed bundled library or build-time
network dependency was found in the copied source/build graph. This is a
source/license inventory, not legal approval for a published binary package.

## SQLite

The standalone local manifest API statically links SQLite 3.53.4's unmodified
`sqlite3.c` amalgamation. SQLite core code is public domain; no copyright
license is imposed on these source files. Upstream public-domain statement:
https://www.sqlite.org/copyright.html. The pinned release archive and SHA3-256,
per-file hashes, and static build flags are recorded in
[`third_party/sqlite/README.md`](third_party/sqlite/README.md). No system
`libsqlite3` is linked for this API.

## libcurl

`source/effects/curl_ffi.d`/`source/effects/http_fetch.d` dynamically link
the host-provided `/usr/lib/libcurl.4.dylib` via `-lcurl` (a `libs` entry in
`dub.json`); no libcurl source is vendored or statically linked, and no
OpenSSL/TLS/compression library is bundled by this project. This follows the
`ADOPT_DYNAMIC` verdict of the loopback capability/licensing/packaging
evaluation in [`docs/http-fetch-evaluation.md`](docs/http-fetch-evaluation.md)
(`experiments/http_fetch/check.d`), which recorded provenance on the
supported macOS 26.6.2 arm64 build host: the linked library reports
`libcurl/8.7.1 (SecureTransport) LibreSSL/3.3.6 zlib/1.2.12 nghttp2/1.68.1`
via `curl_version()`, and `otool -L` on the built binary shows only
`/usr/lib/libcurl.4.dylib`, `/usr/lib/libSystem.B.dylib`, and
`/usr/lib/libobjc.A.dylib` as direct runtime links.

The Command Line Tools SDK's installed `curl/curl.h` header attributes
copyright to "Daniel Stenberg, `<daniel@haxx.se>`, et al.", states the
software "is licensed as described in the file COPYING", and declares
`SPDX-License-Identifier: curl`; that `COPYING` file is not present beside
the installed SDK header on this host, and this project does not reproduce
its full text here for that reason. The `curl` SPDX identifier corresponds
to a short, permissive (MIT/X11-style) license; the authoritative text is
published at https://curl.se/docs/copyright.html. This is a license/
provenance inventory, matching the evaluation's own posture, not independent
legal clearance or proof of the complete source corresponding to Apple's
binary; see `docs/http-fetch-evaluation.md` for the fuller recorded
provenance, including exact header/`.tbd` SHA-256 values.

## PDFium (`bblanchon/pdfium-binaries`)

`source/effects/pdfium_ffi.d` (issue #156) `dlopen()`s a `libpdfium.dylib`
built and published by the third-party distributor
[`bblanchon/pdfium-binaries`](https://github.com/bblanchon/pdfium-binaries).
This is a fourth, distinct trust pattern from every other native dependency
in this project (see `source/effects/pdfium_ffi.d`'s own module doc
comment): the artifact is **never fetched, vendored, statically linked, or
assumed by scrubbed's own build or runtime**. The operator supplies its path
explicitly at call time; provenance of that exact file is entirely the
operator's own responsibility. This project selects and evaluated exactly
one pinned release, `chromium/8066` (published 2026-09-21T12:48:25Z, build
commit `f2e9a1c45bb17b85b540abf1af30146ef65416ac`), macOS arm64 asset
`pdfium-mac-arm64.tgz`, SHA-256
`336219e80580b93c6523f44db7dc1de59cc497b13a7390ddac84223f68ca162b` --
independently re-confirmed byte-for-byte identical on a fresh download
during issue #156's own implementation, and cross-checked against that
release's own GitHub Artifact Attestation (Sigstore/SLSA), which verifies
build `https://github.com/bblanchon/pdfium-binaries/actions/runs/35584475700/attempts/1`
from that exact commit. Full reproduction steps, cost/license evaluation,
and functional verification are recorded in
[`docs/pdfium-evaluation.md`](docs/pdfium-evaluation.md).

### `bblanchon/pdfium-binaries`'s own license (MIT)

The distributor's own `LICENSE` file inside the archive (SHA-256
`ba26c1263131696b86c10496b5066b918a20b7161822a80c274d0080105f6c93`), verbatim:

```
Copyright 2014-2025 Benoit Blanchon

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to
deal in the Software without restriction, including without limitation the
rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
sell copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
IN THE SOFTWARE.

This package also includes third-party software. See the licenses/
directory for their respective licenses.
```

### PDFium's own license

PDFium itself is copyright The PDFium Authors (originally Google Inc.). The
bundled `licenses/pdfium.txt` inside the distributor's archive and the
canonical `LICENSE` file at PDFium's own pinned commit
(`a84323421e94f484faca52dd9d027934eba42ab8`, SHA-256
`1fe9dea718fbd75cf149adaf4d8a22a4335604d964ddb76d1b45383dec8668c9`) both
contain the same content: a BSD-3-Clause-style grant, verbatim:

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

**Disclosed, unresolved discrepancy** (see `docs/pdfium-evaluation.md` for
the full account, not re-derived here): the same upstream `LICENSE` file
also contains the complete, separate Apache License 2.0 text immediately
following the BSD-style grant above. `docs/pdfium-evaluation.md` flags this
as unexplained and unresolved; this project treats the BSD-style header as
the operative grant (it is the license every checked PDFium source file,
including `public/fpdfview.h`, actually points to), consistent with
`bblanchon/pdfium-binaries`'s own `licenses/pdfium.txt` reproducing the same
text, but this is an engineering license-text reading, not independent legal
clearance.

### Bundled third-party licenses inside the prebuilt artifact

The `pdfium-mac-arm64.tgz` archive statically links the following further
third-party libraries into the one `libpdfium.dylib`, per its own
`licenses/` directory (full inventory and per-file license family already
recorded in `docs/pdfium-evaluation.md`): Abseil (Apache-2.0), Anti-Grain
Geometry 2.3 (permissive), fast_float (MIT), FreeType (FreeType Project
LICENSE), ICU (Unicode License v3), Little CMS (MIT-style),
libjpeg-turbo (IJG License + compatible BSD-style terms), libopenjpeg
(2-clause BSD), libpng (PNG Reference Library License v2), LLVM-libc
(Apache-2.0 with LLVM Exceptions), simdutf (MIT), and zlib (zlib License).
Every bundled dependency identified is permissive; none is copyleft. This is
a license/provenance inventory, matching `docs/pdfium-evaluation.md`'s own
posture, not independent legal clearance -- a real shipping/distribution
decision should verify each bundled version's exact upstream commit and
reproduce the full per-file `licenses/` text, not just this summary.

## argparse

The shipping `scrubbed` executable uses `argparse` version 2.0.2 by Andrey
Zherikov (Copyright © 2021, Andrey Zherikov). It is licensed under the Boost
Software License 1.0 (BSL-1.0). The complete license is in
[`third_party/argparse-LICENSE.txt`](third_party/argparse-LICENSE.txt).

Source: https://github.com/andrey-zherikov/argparse/tree/v2.0.2
Pinned upstream commit: `10b7bce1cc813e9930ed85bcc6d54a89c0cb65f9`.
DUB dependency: `argparse ==2.0.2` in `dub.json` and `dub.selections.json`.
The installed DUB package's complete `source/` tree matches the upstream tag
byte-for-byte (`diff -qr`), and the copied license matches upstream (`cmp`).
DUB adds a version field to its cached manifest.

## WHATWG HTML named character references

`source/filters/entities_data.d` is a generated D representation of the
[WHATWG HTML Standard's named character references](https://html.spec.whatwg.org/entities.json)
(2,231 names). The pinned JSON bytes have SHA-256
`d741d877ac77c4194c4ad526b5b4a19aef8dfe411ab840a466891cdbb9f362e6`;
the source data was fetched on 2026-09-20. The applicable upstream
[LICENSE](https://github.com/whatwg/html/blob/24434a064e09609a0c91342dceb34ebaa689b2b8/LICENSE)
at revision `24434a064e09609a0c91342dceb34ebaa689b2b8` says portions
incorporated into source code are licensed under BSD 3-Clause.
The generated data is incorporated into D source code and has not been
modified beyond format conversion.

From a clean checkout at the repository root, regenerate or check the table
with the committed D generator (requires LDC and `curl`):

```sh
curl -fsSL https://html.spec.whatwg.org/entities.json -o /tmp/scrubbed-whatwg-entities.json
ldc2 -of=/tmp/scrubbed-generate-entities scripts/generate_entities.d
/tmp/scrubbed-generate-entities --check /tmp/scrubbed-whatwg-entities.json
/tmp/scrubbed-generate-entities --write /tmp/scrubbed-whatwg-entities.json
```

The generator rejects input whose SHA-256 differs from the pinned digest;
if the live WHATWG endpoint changes, retrieve the matching published snapshot
before regenerating. `--check` compares exact generated bytes with the
checked-in D table and exits nonzero on drift. `--write` intentionally replaces
that table.

Copyright © WHATWG (Apple, Google, Mozilla, Microsoft).

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

## ftfy

The mojibake detector design and selected regression-test inputs in
`source/filters/mojibake.d` are adapted from the public test suite and badness
model of [ftfy](https://github.com/rspeer/python-ftfy), copyright 2023 Robyn
Speer, licensed under the Apache License 2.0.

scrubbed's implementation is independently written in D and currently covers
only reversible Latin-1 and Windows-1252/UTF-8 round trips. It is not a full
port of ftfy.

The upstream ftfy copyright/license notice is included at
`third_party/ftfy-LICENSE.txt`, and the complete Apache License 2.0 terms are
included at `third_party/Apache-2.0.txt`. Corpus results use upstream revision
`74dd0452b48286a3770013b3a02755313bd5575e`.

## software-factory

The vendored workflow skills under `.agents/` come from
[software-factory](https://github.com/schancel/software-factory), copyright
2026 Shammah Chancellor, licensed under the MIT License. A copy is included at
`third_party/software-factory-LICENSE.txt`. The pristine `.agents/.factory-base`
snapshot is upstream revision `06aeca7fe1f6fb6f3bffe70ff8fe340a9fcfb54e`;
the active copy adds a local maintainer-label authorization gate for public
GitHub issue queues and fetches GitHub's full supported dependency count.
