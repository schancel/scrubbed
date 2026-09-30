# WSL2 support evaluation (issue #568)

## What this is, and what it is not

This documents real testing of whether the existing Linux x86_64 build
(tarball path, and the `.deb` from #500) runs unmodified inside WSL2.

**No genuine WSL2 or Windows host was available in the sandbox this
evaluation ran in** (a macOS/Apple Silicon machine with no Windows
install and no WSL2). Per issue #568's own fallback instructions, this
used the closest available proxy instead: a real Ubuntu 24.04 Linux
container built for `linux/amd64` (Docker Desktop for Mac, which runs
containers inside its own lightweight Linux VM on an Apple Silicon
aarch64 host, so the `x86_64` code path itself ran under QEMU user-mode
emulation, not natively).

That proxy shares WSL2's one most load-bearing architectural property —
a genuine Linux kernel running inside a lightweight VM under a
non-Linux host OS, not a syscall-translation shim (that's WSL1, out of
scope here too) — which is exactly the property issue #568 reasons
should make this work. It does **not** reproduce WSL2 itself: different
host OS, different VM stack (Apple's Virtualization framework here vs.
Hyper-V), none of WSL2's own interop surface (win32 PATH interop, WSLg,
Windows Defender scanning WSL-visible files, `wsl.exe` itself), and the
x86_64 execution was emulated rather than native.

**Conclusion up front: this is real, positive evidence that the
existing Linux x86_64 build and `.deb` work correctly in a real Linux
kernel with the same general shape as WSL2's — not a genuine WSL2
verification.** Do not cite this doc, or README.md/site/index.html
language it motivated, as "WSL2-verified." A follow-up pass on an actual
WSL2 Ubuntu instance is still needed to close that out; this evaluation
is what made that follow-up cheap (the build, the corpus run, and the
`.deb` install path are all already proven to work on *a* real Linux
kernel under the same isolation shape).

## Build: real `dub build --compiler=ldc2 --build=release`, x86_64, Ubuntu 24.04

Compiler pinned to match `.github/workflows/release.yml`'s
`linux-x86_64` job exactly: `ldc-1.43.0` on `ubuntu:24.04`.

```
$ uname -a
Linux d86931132175 6.12.67-linuxkit #1 SMP ... x86_64 x86_64 x86_64 GNU/Linux
$ dub --version
DUB version 1.42.0, built on Aug 30 2026
$ ldc2 --version | head -3
LDC - the LLVM D compiler (1.43.0):
  based on DMD v2.113.0 and LLVM 22.1.8

$ dub build --compiler=ldc2 --build=release
...
     Linking scrubbed
=== dub build DONE ===

$ readelf -h ./scrubbed | grep -E "Class|Machine"
  Class:                             ELF64
  Machine:                           Advanced Micro Devices X86-64
```

Full build (dependency fetch, `preBuildCommands` -- SQLite `cc`
compile, `cmake`+`make` Lexbor static lib, `make` zstd, then the D
compile/link) completed cleanly end to end, ~4 minutes wall clock under
QEMU emulation.

## `--version` / `--help`

```
$ ./scrubbed --version
scrubbed 0.0.0-dev
$ ./scrubbed --help | head -20
Usage: scrubbed [-h] <command> [<args>]

Sanitize text through a bounded filter pipeline.

Available commands:
  run,clean             Run the bounded filter pipeline.
  ...
```

## `clean-web-document` on real multi-file corpora

Single file (the flagship example's own fixture):

```
$ ./scrubbed clean-web-document \
    --input examples/corpus/clean-web-document/inputs/single-file/hydrology-notebook.html \
    --output /tmp/scrubbed-cwd/hydrology-notebook.txt
job: job:v3:d94bad6d8893293771f6a203262c7b3d0e326628967a76e1890ff18ddef05160
done. 1 succeeded, 0 failed.
```
Output (439 bytes) and the `document-metadata.json` sidecar both produced
correctly (mojibake-repaired, main-content-extracted body text; standard
title/author fields populated).

Directory tree (the flagship example's own 3-file fixture):

```
$ ./scrubbed clean-web-document \
    --input examples/corpus/clean-web-document/inputs/directory-tree \
    --output /tmp/scrubbed-cwd-tree
job: job:v3:d94bad6d8893293771f6a203262c7b3d0e326628967a76e1890ff18ddef05160
done. 3 succeeded, 0 failed.
```
All 3 outputs plus 3 sidecars written correctly under the mirrored
output/`.document-metadata/` tree.

Real-world 20-file corpus (`examples/pipeline-benchmark/corpus/`, real
scraped pages used by issue #315's benchmark, not synthetic fixtures):

```
$ ./scrubbed clean-web-document \
    --input examples/pipeline-benchmark/corpus \
    --output /tmp/scrubbed-bench-out --threads 4
job: job:v3:d94bad6d8893293771f6a203262c7b3d0e326628967a76e1890ff18ddef05160
done. 20 succeeded, 0 failed.
```
20/20 outputs and 20/20 sidecars produced, 0 failures.

## `.deb` install path (issue #500's package), on a *separate, clean* container

`packaging/debian/build.sh` run against the release binary above:

```
$ dpkg --print-architecture
amd64
$ packaging/debian/build.sh . ./scrubbed /build/debout
build.sh: building experiments/package_core/check.d checker
build.sh: assembling + self-verifying release package tree
package create/check PASS
package verify/negative controls PASS
dpkg-deb: building package 'scrubbed' in '/build/debout/scrubbed_0.0.0~dev-1_amd64.deb'.
build.sh: built /build/debout/scrubbed_0.0.0~dev-1_amd64.deb
```

Then, in a **freshly started, unrelated `ubuntu:24.04` container with no
build tools installed** (a real clean-machine install, not the build
container reused):

```
$ apt-get update -qq
$ apt-get install -y ./scrubbed_0.0.0~dev-1_amd64.deb
...
Setting up scrubbed (0.0.0~dev-1) ...
$ scrubbed --version
scrubbed 0.0.0-dev
$ scrubbed clean-web-document --input /corpus/directory-tree --output /tmp/out/tree
job: job:v3:d94bad6d8893293771f6a203262c7b3d0e326628967a76e1890ff18ddef05160
done. 3 succeeded, 0 failed.
```

`apt` correctly resolved and installed the `libcurl4t64` runtime
dependency from `control.in`'s alternation, exactly as documented in
`packaging/debian/README.md`'s cross-distro evidence. The installed
binary ran a real corpus job correctly with zero prior setup beyond the
single `apt-get install`.

## Filesystem-boundary quirks (proxy for WSL2's `/mnt/c`)

Issue #568 specifically calls out that files crossing the Windows-host
<-> WSL-Linux filesystem boundary (`/mnt/c/...`, backed by DrvFs) are a
realistic use case worth checking even under a real kernel. No genuine
DrvFs mount was available to test against, so this used the nearest
proxy in this sandbox: a Docker Desktop for Mac bind mount (a macOS host
directory exposed into the Linux container over its own host-filesystem
bridge). `mount` inside the container shows it as its own distinct
mount type, not the container's native `overlay` root:

```
$ mount | grep hostlike
/run/host_mark/private on /hostlike type fakeowner (rw,nosuid,nodev,relatime,fakeowner)
```

Reading and writing through that mount worked correctly: `clean-web-
document` both wrote real output/sidecar files onto it and read a real
multi-file corpus from it, with no errors.

One real, reproducible quirk did show up: **the bridged mount was
case-insensitive.** Creating `CaseProbe.txt` then `caseprobe.txt` in the
same directory collapsed to a single entry (the first name won) instead
of creating two files:

```
$ touch CaseProbe.txt caseprobe.txt
$ ls | grep -i caseprobe
CaseProbe.txt
```

This is a real behavior of this specific bridge (macOS APFS is
case-insensitive-but-case-preserving by default), not of Linux itself —
but it is the same *category* of surprise a WSL2 user would hit on
`/mnt/c`: Windows' NTFS is also case-insensitive by default, and a tool
that assumes POSIX case-sensitive paths (e.g. writing both `Foo.txt` and
`foo.txt` outputs into the same `/mnt/c/...` directory) would silently
collide there too. `clean-web-document`'s own output naming (mirrors the
input file's own name, one output per input, no case-only variants
generated) does not hit this in practice, but it's worth a user's
awareness if their corpus itself contains case-only-distinct filenames
and they're running against a `/mnt/c` path. This finding is suggestive,
not a substitute for testing against a real DrvFs mount.

Permission bits came back as `600` (owner read/write only) on files
`clean-web-document` wrote through the bridge -- consistent with the
binary's own atomic-output-write default, not evidence of anything
mount-specific.

## What's proven vs. what's still open

**Proven, with real commands and real output, in this sandbox's best
available proxy:**
- The Linux x86_64 release build compiles and runs correctly end to end.
- `clean-web-document` processes real single-file, small-tree, and
  20-file real-world corpora correctly (0 failures across 24 documents).
- The `.deb` from #500 installs cleanly via `apt-get install
  ./scrubbed*.deb` on an unrelated clean container and the installed
  binary runs a real corpus job correctly.
- Reading/writing through a bridged, non-native filesystem mount works;
  one real quirk (case-insensitivity) was found and is documented above.

**Still open, and explicitly not claimed here:**
- Genuine WSL2 (or WSL1) was never actually run. Everything above is
  real evidence *for* WSL2 working, on the strength of WSL2 also being a
  genuine Linux kernel in a lightweight VM -- it is not itself a WSL2
  result.
- A real `/mnt/c` (DrvFs) mount was never tested; the case-insensitivity
  finding above is a plausible, not confirmed, analog.
- A native Windows `.exe` port remains explicitly out of scope, per
  issue #568 and the existing POSIX-specific-subsystem rationale
  (`dlopen` for zlib, `sigaction`-based `SIGINT` handling, `mmap`-based
  zero-copy reads) -- nothing here changes that.
