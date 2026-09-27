# Pinned zstd decompressor and compressor

Source: upstream Zstandard release `v1.5.7`,
`https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz`.
The exact release tarball has SHA-256
`eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3`.
`UPSTREAM_FILES.sha256` inventories every copied upstream file and its byte
identity; source paths are the release tarball's `lib/` paths, except `LICENSE`
which is the release root's file. No copied upstream file was modified. The
compression-side `compress/*.c`/`compress/*.h` files added for issue #168's
`compressibility-annotate` stage are pinned to this exact same `v1.5.7`
release tarball -- no version mismatch between the decompression and
compression sides.

The project selects the release's complete BSD-style alternative in
[`LICENSE`](LICENSE), **not** GPLv2. Copyright notices in each source file are
retained. The included `common/xxhash.{c,h}` credits Yann Collet / Meta and
uses the same BSD-style alternative. The source graph contains no independent
vendored library or transitive package. The release contains no separate
upstream NOTICE for this `lib/` subset. Project distribution notices are in
[`THIRD_PARTY_NOTICES.md`](../../THIRD_PARTY_NOTICES.md).

`Makefile` compiles the ten required common/decompression C translation units
to `.dub/zstd/libzstd_decompress.a`, and the thirteen required compression
translation units to `.dub/zstd/libzstd_compress.a`. Both archives exclude the
dictionary builder, legacy decoder, multithreading, and x86 assembly. The
compression archive specifically omits `compress/zstdmt_compress.c`
(multithreading): every `ZSTDMT_*` reference inside `compress/zstd_compress.c`
is compiled out behind `#ifdef ZSTD_MULTITHREAD`, which this build never
defines, matching upstream's own default single-threaded static-library
configuration exactly -- this is not a functional reduction versus a
single-threaded upstream build. The compression archive also omits
`common/*.c` entirely: those five translation units are already compiled into
`libzstd_decompress.a` with identical flags, and `dub.json` always links both
archives together, so `libzstd_compress.a` is not usable standalone. Neither
archive creates or links a shared libzstd, invokes a package manager, or
fetches from the network. The explicit support guard is macOS arm64 only.
`dub.json` makes both archives available to D builds; `effects
.warc_compressed` uses the decompression archive for the bounded in-process
WARC/1.1 adapter, and `effects.compressibility_annotate_stage` uses the
compression archive's one-shot buffer API (`ZSTD_compressBound`/
`ZSTD_compress`, level 19 only -- no streaming compressor, no dictionary, no
caller-tunable compressor parameters) for its zstd compression-ratio metric.
This does not claim a CLI, real-file source, or other-platform integration.
The D ABI declarations and live header/stream/compress round-trip tests are
in `source/effects/zstd_ffi.d`.

To verify provenance, download the release URL above, check its SHA-256, and
compare each listed file to the corresponding tarball path. To inspect native
linkage, run `otool -L` on the D unit-test binary and `nm` on each static
archive; no dynamic libzstd should appear. This is a source/package inventory,
not legal approval for a published binary.

The release-active ABI unit tests run with
`dub test --compiler=ldc2 --build=release-unittest`; its negative control is
`dub test --compiler=ldc2 --build=release-unittest --d-version=ZstdAbiNegativeControl`,
which must fail with `wrong linked zstd version`.
