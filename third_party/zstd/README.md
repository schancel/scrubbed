# Pinned zstd decompressor

Source: upstream Zstandard release `v1.5.7`,
`https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz`.
The exact release tarball has SHA-256
`eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3`.
`UPSTREAM_FILES.sha256` inventories every copied upstream file and its byte
identity; source paths are the release tarball's `lib/` paths, except `LICENSE`
which is the release root's file. No copied upstream file was modified.

The project selects the release's complete BSD-style alternative in
[`LICENSE`](LICENSE), **not** GPLv2. Copyright notices in each source file are
retained. The included `common/xxhash.{c,h}` credits Yann Collet / Meta and
uses the same BSD-style alternative. The source graph contains no independent
vendored library or transitive package. The release contains no separate
upstream NOTICE for this `lib/` subset. Project distribution notices are in
[`THIRD_PARTY_NOTICES.md`](../../THIRD_PARTY_NOTICES.md).

`Makefile` compiles only the ten required common/decompression C translation
units to `.dub/zstd/libzstd_decompress.a`; it excludes the compressor,
dictionary builder, legacy decoder, multithreading and x86 assembly. It does
not create or link a shared libzstd, invoke a package manager, or fetch from
the network. The explicit support guard is macOS arm64 only. `dub.json` makes
the archive available to D builds; `effects.warc_compressed` uses it for the
bounded in-process WARC/1.1 adapter. This does not claim a CLI, real-file
source, or other-platform integration. The D ABI declarations and a live
header/stream decode test are in `source/effects/zstd_ffi.d`.

To verify provenance, download the release URL above, check its SHA-256, and
compare each listed file to the corresponding tarball path. To inspect native
linkage, run `otool -L` on the D unit-test binary and `nm` on the static
archive; no dynamic libzstd should appear. This is a source/package inventory,
not legal approval for a published binary.

The release-active ABI unit test runs with
`dub test --compiler=ldc2 --build=release-unittest`; its negative control is
`dub test --compiler=ldc2 --build=release-unittest --d-version=ZstdAbiNegativeControl`,
which must fail with `wrong linked zstd version`.
