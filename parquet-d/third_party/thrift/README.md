# Pinned Apache Thrift D compact protocol

This is an unmodified six-file subset of the Apache Thrift D library
(`lib/d/src/thrift/` in https://github.com/apache/thrift) at tag `v0.24.0`.
The tag is annotated: tag object `c84d4b41733f7cccefebcaba78bb7f211e73b517`
peels to Git commit `6d2ec95f450b4ce404afb8929ff479e68770141a`
(`git ls-remote https://github.com/apache/thrift 'refs/tags/v0.24.0*'`).
Each file was fetched from
`https://raw.githubusercontent.com/apache/thrift/6d2ec95f450b4ce404afb8929ff479e68770141a/<path>`
and re-checked byte-for-byte (`cmp`) against the same path fetched by tag
name (`.../apache/thrift/v0.24.0/<path>`). The files are laid out under this
directory exactly as under upstream `lib/d/src/thrift/`, so that
`-Ithird_party` resolves `import thrift.protocol.compact;` and friends. They
have these SHA-256 digests:

| File | Upstream path | SHA-256 |
| --- | --- | --- |
| `base.d` | `lib/d/src/thrift/base.d` | `2c23e8ab75d2756ff65a6d108454b2d186e94d27b5c490461eec224c5faa221e` |
| `internal/endian.d` | `lib/d/src/thrift/internal/endian.d` | `99738db978fb03967b272f61b989f1c657cdc5f9041762d4019520965f301ba4` |
| `protocol/base.d` | `lib/d/src/thrift/protocol/base.d` | `2476d1abd09f6667c5839151e35e6e0688d74829d5d1b18572b47d73e541f63c` |
| `protocol/compact.d` | `lib/d/src/thrift/protocol/compact.d` | `e8ddb9d17b8f229fa19eba18c55a3034caebbc693e48946e8a2d150ac214ec1b` |
| `transport/base.d` | `lib/d/src/thrift/transport/base.d` | `ee6df2cb5b0eff9733dbd2e06488f58c99d68503946dbbd81dff96097942b06f` |
| `transport/memory.d` | `lib/d/src/thrift/transport/memory.d` | `1632f41498300feb9ddcd10e08ec8460c6d8ce020604ae0f2087f098229e3f78` |
| `LICENSE` | `LICENSE` | `89aa7b27868669299bd8a6c53b72ec4beadce42dad6c8336797cc26e1e8df98d` |
| `NOTICE` | `NOTICE` | `c2534e065069887565f871f0648b013a7e5f4a422809faf4ae3c590b7c0bf561` |

No upstream file is modified. [`LICENSE`](LICENSE) is upstream's root
`LICENSE` verbatim: the Apache License 2.0 text (its first 11358 bytes are
byte-identical to scrubbed's `third_party/Apache-2.0.txt`) followed by
upstream's "SOFTWARE DISTRIBUTED WITH THRIFT" appendix, none of whose
subcomponents (Erlang, autoconf, Node.js and similar files) is among the six
files here. [`NOTICE`](NOTICE) is upstream's root `NOTICE`, carried as
Apache-2.0 section 4(d) requires. Each vendored file retains its ASF license
header.

## Why vendored instead of the published `apache-thrift` dub package

`apache-thrift` on the dub registry is this same upstream `lib/d` library,
but its `dub.json` declares an unconditional dependency on libevent (for
Thrift's async RPC server machinery) plus a per-configuration openssl
dependency (for its TLS transports). Neither is needed to encode Parquet
metadata. This was checked empirically while scoping scrubbed issue #391
(2026-09-28): adding `apache-thrift` as an ordinary dub dependency fails
dependency resolution outright -- dub cannot choose between the package's
two mutually exclusive openssl sub-configurations -- before any code
compiles. Compiling only the six files this package needs, directly and
outside dub's whole-package dependency declaration, compiles and links with
no libevent or openssl involvement at all.

The six files are the closure `thrift.protocol.compact` actually imports
(`protocol/base`, `transport/base`, `internal/endian`, `base`) plus the
in-memory transport `transport/memory` that `parquet.thrift_codec` encodes
into. `protocol/compact.d` has one unittest that imports the non-vendored
`thrift.internal.test.protocol`; the files are therefore never compiled as
root modules of a `-unittest` build. Instead, `dub.json`'s pre-build step
compiles exactly these six files, without `-unittest`, into
`.dub/thrift/libthrift_compact.a`, and `third_party` is only an import path
for this package's own sources (template instantiations such as
`TCompactProtocol!TMemoryBuffer` are emitted in `parquet.thrift_codec`).

## Verifying the pin

To verify provenance, re-fetch each upstream path at commit
`6d2ec95f450b4ce404afb8929ff479e68770141a` and compare it and its SHA-256 to
the table above (`shasum -a 256 base.d internal/endian.d protocol/*.d
transport/*.d LICENSE NOTICE`).

To verify the clean link, build the unit-test binary (`dub test
--compiler=ldc2` from `parquet-d/`) and inspect it:

```sh
otool -L parquet-d-test-unittest       # only /usr/lib/libSystem and libobjc
nm parquet-d-test-unittest | grep -c event_                      # 0
nm parquet-d-test-unittest | grep -cE 'SSL_|EVP_|OPENSSL|evbuffer' # 0
nm parquet-d-test-unittest | grep -c 6thrift                     # > 0: Thrift is linked
```

Only macOS arm64 with LDC 1.43.0 is verified. The pre-build step uses dub's
`$DC`, so the archive is always built by the same compiler as its consumer.

## Bumping upstream

Moving to a newer Thrift tag is a deliberate, re-verified action, not an
assumption that newer is safe: re-fetch these same six paths (and `LICENSE`/
`NOTICE`) at the new tag, check whether `thrift.protocol.compact`'s import
closure changed, record the new tag, peeled commit and per-file SHA-256s
here, re-run `dub test --compiler=ldc2`, the `otool -L`/`nm` check above, and
`tests/external_verify.sh` (real pyarrow/DuckDB reads of written files).
