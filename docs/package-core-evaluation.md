# Current text-core package feasibility (#61 prerequisite)

This is an evidence-only local directory package, **not** a release or an
installer. It packages the current text CLI, not HTML extraction: at the time
of this evaluation, #24 had not yet adopted a native parser, so this package
predates and does not exercise the Lexbor wrapper that #24 later shipped (see
[html-parser-evaluation.md](html-parser-evaluation.md)). The accepted #61
Linux/macOS/Windows text-and-HTML outcome remains open. Do not publish this
directory as a supported artifact.

## Reproduce on macOS arm64

From this checkout root, with LDC, DUB and a C compiler available for the
*build*, run:

```sh
dub test --compiler=ldc2
dub build -b release --compiler=ldc2
package61_tmp=$(mktemp -d /tmp/scrubbed-package-evidence.XXXXXX)
ldc2 -O3 -release experiments/package_core/check.d -of="$package61_tmp/check"
"$package61_tmp/check" create "$PWD" "$PWD/scrubbed" "$package61_tmp/package"
"$package61_tmp/check" verify "$package61_tmp/package"
"$package61_tmp/check" bench "$package61_tmp/package"
file "$package61_tmp/package/scrubbed"
otool -L "$package61_tmp/package/scrubbed"
nm "$package61_tmp/package/scrubbed" | rg ' _sqlite3_close$'
```

The D runner has three modes:

- `create` — makes the directory only if absent, copies the binary and all
  six shipping notice/provenance files, and writes `SHA256SUMS`.
- `verify` — checks exact source-pinned notice bytes, every member checksum,
  a closed member inventory, and exact `--help` and `line\r\n` → `line\n`
  local text behavior; it also runs seventeen release-active negatives
  (missing and corrupt binary, checksum manifest, and every bundled notice,
  plus an extra empty directory), and permits only the structural
  `third_party` and `third_party/sqlite` directories, rejecting other
  directories, symlinks, nonregular entries, unexpected files, and missing
  members.
- `bench` — records the median elapsed `--help` process time over 21 samples
  after five warmups; it is a local observation, not a performance target.

`create`/`verify` run the packaged binary by absolute path while `PATH`
points to an empty temporary directory; this proves no D, DUB, Python, shell,
or helper executable is needed on `PATH` for those operations. It does
**not** prove a fully static binary, a clean machine with no system
libraries, or all CLI operations.

The package contains project `LICENSE` (MIT),
`THIRD_PARTY_NOTICES.md` (including WHATWG BSD-3 binary redistribution terms),
`third_party/argparse-LICENSE.txt` (BSL-1.0),
`third_party/ftfy-LICENSE.txt` (upstream copyright/notice),
`third_party/Apache-2.0.txt` (full Apache-2.0 terms), and
`third_party/sqlite/README.md` (SQLite 3.53.4 public-domain statement,
upstream archive SHA3-256
`628a44cfe82c66aed1ccbbe85a562d2e33ebe64b3288981ed76285612227934e`,
source-file hashes and build flags). The exact bytes of these six files are
hard-pinned in the runner and independently listed in `SHA256SUMS`. The SQLite
source is compiled from the checked-in upstream amalgamation; it is not
redistributed in this binary-only package. The manifest lists every shipping
file other than itself. `THIRD_PARTY_NOTICES.md` also records argparse 2.0.2
upstream revision and the WHATWG entity-source digest. Provenance cannot be
reduced to a generic license name.

## Observed platform matrix on 2026-09-21

| Target | Actual result | Boundary |
| --- | --- | --- |
| macOS arm64 (Darwin 25.6.0 host) | PASS, current text core | LDC 1.43.0 (DMD 2.113.0), DUB 1.42.0, `dub build -b release --compiler=ldc2`; `dub.json` prebuild `cc -O2 -DSQLITE_THREADSAFE=1 -DSQLITE_OMIT_LOAD_EXTENSION` and release `releaseMode,optimize,inline`, plus declared `-g` D flag. Second Mach-O arm64 binary 4,051,384 bytes; SHA-256 `cad316a855cd874bf0a0e618b827e38aab70a34d8c07ae5761e6f3e92c502440`; median `--help` 9,173 µs (21 samples, five warmups). `otool -L` shows `/usr/lib/libSystem.B.dylib` and `/usr/lib/libobjc.A.dylib`; no `libsqlite3`. `nm` shows `_sqlite3_close` defined (`T`), corroborating compiled-in SQLite. |
| Linux x86_64 glibc, locally available Docker amd64 image | BUILD BLOCKED in emulated container; runtime untested | Docker server linux/aarch64 ran `dlang2/ldc-ubuntu:latest` image `sha256:445f1745615e16b0a38af4c257ae79987a2fc274d77603aec550e621a1eb5f50` under `--platform linux/amd64` (Ubuntu glibc 2.27). Its LDC 1.26.0 / DMD 2.096.1 and DUB 1.25.0 cannot parse pinned argparse 2.0.2 (`alias this = dispatcher` etc.); `dub build -b release --compiler=ldc2` exits 2 before application build. This says nothing about a modern Linux toolchain or native host. No Linux binary or clean-runtime result was produced. |
| Windows x86_64 | UNTESTED | No actual Windows toolchain/runner was available to this slice. POSIX-only source is a suspected portability risk, not a proven blocker here. No Windows build/install claim. |

The macOS check used the actual package directory in `/tmp`; no release
artifact is committed. The observed dependency graph remains dynamically
linked to the named system libraries, even though SQLite itself has no dynamic
`libsqlite3` dependency. A prior build of the same checkout produced the same
4,051,384-byte size but SHA-256
`cbf0f233aed454fdad6ad8c0c458732534e91300d76ae2161e776d54caaeefbc`
and a different Mach-O `LC_UUID` (first `FAB90C80-C778-3628-B0B1-E146156D4D43`,
second `AF930BF2-365A-3CB4-B408-D0DDE5E7321C`). The package manifest pins
each actual binary, but the build is **not demonstrated bit-for-bit
reproducible**; a release process must investigate this before claiming it.
A future release pass needs a modern Linux build and
separate clean runtime/container, actual Windows compile and runtime evidence,
HTML parser adoption and license inventory, versioned artifact/install policy,
and independent platform/security/license review. The rollback for this
prerequisite is deleting only this experiment and evaluation document.

## Issue #499 extension: real release workflow and Linux proof (2026-09-30)

This slice replaced the hard-pinned six-file notice list above with a
two-directional closure check (`experiments/package_core/check.d`,
`verifyNoticeClosure`): every `third_party/...` path
`THIRD_PARTY_NOTICES.md` references must exist, and every real
license/notice-shaped file under `third_party/` (`LICENSE`, `LICENSE.txt`,
`NOTICE`, `*-LICENSE.txt`) must be referenced by the doc. This closed the
exact gap this document's six-file list had accumulated since 2026-09-21:
`third_party/lexbor/LICENSE`, `third_party/lexbor/NOTICE`, and
`third_party/zstd/LICENSE` are now part of the live-derived closure (along
with `third_party/lexbor/README.md` and `third_party/zstd/README.md`,
which the notices doc also references for provenance). The shipped closure
is now 12 files: root `LICENSE` and `THIRD_PARTY_NOTICES.md`, plus 10
`third_party/**` paths, computed fresh every run -- nothing is pinned by
hash any more, so a future undocumented dependency fails loudly instead of
shipping quietly incomplete.

`.github/workflows/release.yml` (new) fires on `v*` tags, builds all three
named targets, stamps the tag into `VERSION` at build time only (never
committed), packages each with the checker above plus generated
`completions/scrubbed.{bash,zsh,fish}`, and publishes a GitHub Release
(draft until every target succeeds) with a combined `SHA256SUMS`.

A real, disposable test tag, `v0.0.1-test1`, was pushed against this
slice's own commit and exercised the actual workflow end to end (run
[36680526080](https://github.com/schancel/scrubbed/actions/runs/36680526080)).
Both the release and the tag were deleted immediately after the evidence
below was collected; nothing from this test run remains published.

| Target | Result | Evidence |
| --- | --- | --- |
| macOS arm64 (`macos-15` runner) | PASS | Build+package+self-verify in workflow (1m56s). Locally downloaded the real release asset into an isolated `/tmp` directory (no repo files alongside it) and, with `PATH` reduced to `/usr/bin:/bin`: `sha256sum -c SHA256SUMS` all `OK`; `./scrubbed --version` printed `scrubbed 0.0.1-test1` (the real tag, not the dev placeholder); `--help` exits 0; a Windows-1252/UTF-8 mojibake round trip (`repair --filters normalize-line-endings,fix-mojibake`) correctly produced `Café naïve`; an HTML `<main>` extraction (`extract --format markdown`) correctly produced `# Title` / `Hello world`. All 12 bundled notice files matched the checked-out repo tree byte-for-byte (`cmp`). Bundled `completions/scrubbed.bash`/`.zsh` source cleanly and register `complete -F _scrubbed_completion scrubbed`; `fish` was not available on this host to complete the third-shell proof locally (covered on Linux below, same generation code path). |
| Linux x86_64 (`ubuntu-24.04` runner) | PASS | Build+package+self-verify in workflow (2m13s). Verified in a **fresh `ubuntu:24.04` Docker container** with no D/DUB/Python preinstalled (only `libcurl4t64`, `zsh`, `fish` added afterward as ordinary runtime/shell packages, matching the documented dynamic-libcurl dependency): `sha256sum -c SHA256SUMS` all `OK`; `--version` printed the real tag; the same mojibake-repair and HTML-to-Markdown goldens passed; all 12 notice files matched the source tree byte-for-byte. With the extracted binary installed at `/usr/local/bin/scrubbed` (the conventional path the bundled completions are generated against), sourcing each of `completions/scrubbed.{bash,zsh,fish}` and actually invoking completion (`_scrubbed_completion` for bash, `complete -p`/`complete -C` for zsh/fish) returned real candidates (`--filter --filter-option --filters`) from the installed binary in all three shells -- a genuine end-to-end completion proof, not just script-registration. |
| Linux aarch64 (`ubuntu-24.04-arm` runner) | PASS | Build+package+self-verify in workflow (2m33s). Identical fresh-container proof as x86_64 above (`ubuntu:24.04` under `--platform linux/arm64`, native on this arm64 Docker host): checksums, `--version`, mojibake repair, HTML-to-Markdown, all 12 notice bytes, and all three shells' completions with real candidates from the installed binary all passed. |
| Windows x86_64 | Still UNTESTED | Unchanged from 2026-09-21; explicitly out of scope for #499 (no POSIX port contract, matches `dub.json`'s platform gate). |

This closes the Linux x86_64/aarch64 gap this document's 2026-09-21 pass
left open (issue #353's compiler-support prerequisite had since landed,
which is exactly what made this proof possible). Bit-for-bit build
reproducibility is still not claimed. Windows remains untested and out of
scope. `.deb`/`.rpm`/Homebrew packaging remain separate, later slices
(#500/#501/#502).
