# Pinned zstd compressor

Source: upstream Zstandard release `v1.5.7`,
`https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz`.
The exact release tarball has SHA-256
`eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3`.
`UPSTREAM_FILES.sha256` inventories every copied upstream file and its byte
identity; source paths are the release tarball's `lib/` paths, except `LICENSE`
which is the release root's file. No copied upstream file was modified.

This directory is a byte-identical copy (`diff -r` empty) of scrubbed's own
pinned `third_party/zstd` -- same release, same file inventory, same
`Makefile` -- so that `parquet-d` builds standalone, the same way `lexbor-d`
carries its own copy of scrubbed's pinned Lexbor rather than reaching outside
its package directory. Only this README differs.

The project selects the release's complete BSD-style alternative in
[`LICENSE`](LICENSE), **not** GPLv2. Copyright notices in each source file are
retained. The included `common/xxhash.{c,h}` credits Yann Collet / Meta and
uses the same BSD-style alternative. The release contains no separate
upstream NOTICE for this `lib/` subset.

`Makefile` (invoked by `dub.json`'s pre-build step) compiles the common and
decompression translation units to `../../.dub/zstd/libzstd_decompress.a` and
the compression translation units to `../../.dub/zstd/libzstd_compress.a`,
excluding the dictionary builder, legacy decoder, multithreading and x86
assembly; the compression archive relies on the decompression archive for the
shared `common/*.c` objects, and `dub.json` always links both. No shared
libzstd is created or linked, no package manager is invoked, nothing is
fetched. The Makefile's platform gate allows macOS arm64 and Linux
x86_64/aarch64; only macOS arm64 is verified for this package.

`parquet.zstd_ffi` uses the one-shot `ZSTD_compressBound`/`ZSTD_compress`
API for Parquet data pages (level from `WriterOptions.zstdLevel`, default 3),
and `ZSTD_decompress` only in its own round-trip unittest, which also asserts
the linked library reports version `10507`.

To verify provenance, download the release URL above, check its SHA-256, and
compare each listed file to the corresponding tarball path
(`shasum -a 256 -c UPSTREAM_FILES.sha256` checks the local copy against the
inventory). To inspect native linkage, run `otool -L` on the unit-test binary;
no dynamic libzstd should appear.
