# Third-party notices

## Apache Thrift

`third_party/thrift` vendors six unmodified files of the
[Apache Thrift](https://github.com/apache/thrift) D library (tag `v0.24.0`),
used by `parquet.thrift_codec` for Thrift compact-protocol encoding of
Parquet metadata. Apache Thrift is copyright The Apache Software Foundation
and licensed under Apache 2.0. The complete upstream `LICENSE` and `NOTICE`
are bundled at `third_party/thrift/LICENSE` and `third_party/thrift/NOTICE`;
provenance and hashes are in `third_party/thrift/README.md`.

## Zstandard

`third_party/zstd` vendors the `lib/` subset of
[Zstandard](https://github.com/facebook/zstd) release `v1.5.7`, used by
`parquet.zstd_ffi` for zstd page compression. Zstandard is copyright Meta
Platforms, Inc. and affiliates, used under its BSD-style license (not GPLv2);
see `third_party/zstd/LICENSE` and `third_party/zstd/README.md`.

This package's own code (everything under `source/` and `tests/`) is
MIT-licensed; see `LICENSE`.
