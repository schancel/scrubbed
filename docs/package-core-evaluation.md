# Current text-core package feasibility (#61 prerequisite)

This is an evidence-only local directory package, **not** a release or an
installer. It packages the current text CLI, not HTML extraction: #24 has no
adopted native parser. The accepted #61 Linux/macOS/Windows text-and-HTML
outcome remains open. Do not publish this directory as a supported artifact.

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

The D runner creates the directory only if absent, copies the binary and all
six shipping notice/provenance files, writes `SHA256SUMS`, then verifies exact
source-pinned notice bytes, every member checksum, a closed member inventory,
and exact `--help` and `line\r\n` → `line\n` local text behavior. It runs the
packaged binary by absolute path while `PATH` points to an empty temporary
directory; this proves no D, DUB, Python, shell, or helper executable is
needed on `PATH` for those operations. It does **not** prove a fully static
binary, a clean machine with no system libraries, or all CLI operations.
`verify` repeats the check and runs seventeen release-active negatives: missing
and corrupt binary, checksum manifest, and every bundled notice, plus an extra
empty directory. It permits only the structural `third_party` and
`third_party/sqlite` directories, rejecting other directories, symlinks,
nonregular entries, unexpected files, and missing members.
`bench` records the median elapsed `--help` process time over 21 samples after
five warmups; it is a local observation, not a performance target.

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
