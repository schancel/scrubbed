# Exact dependency and notice bill

| Component | Pin and integrity | Evaluation use | License / notice |
| --- | --- | --- | --- |
| `nats.c` | v3.14.0, commit `6cb096a7fd24a1927037fd2a2ca2c6fbc5d64e47`, source archive SHA-256 `1f8b450bc295d0c94be201e34713ca0b515aae2c0d1b279273c3e6e0e72fe005` | Built from source as static `libnats_static.a`; TLS and JetStream enabled; shared library, legacy Streaming, sodium, examples, and experimental APIs disabled | Apache-2.0 `LICENSE`, Git blob `f49a4e16e68b128803cc2dcea614603632b04eac`; dependency manifest blob `d284d83081af397b7370ce43ad273d4de8aca0ad`; no `NOTICE` file in the tagged root |
| `nats-server` | v2.15.0, commit `eb763679aa3c24a40dcd3012aa046ad1996d851c`; archive and corresponding SPDX SBOM hashes are in `versions.env` | Official prebuilt single-server executable, file-backed JetStream, loopback only | Apache-2.0 `LICENSE`, Git blob `261eeb9e9f8b2b4b0d119366dda99c6fd7d35c64`; dependency manifest blob `fb3717a578cb8c99a148de93735d8149adbf7825`; no `NOTICE` file in the tagged root |
| OpenSSL | Host-provided; version, prefix, `.pc` directory, and link flags come from the exact `pkg-config openssl` module; CMake requires >=1.1.1 | Dynamic TLS dependency of the statically linked probe and build-time certificate tool | Apache-2.0 since OpenSSL 3; older host versions retain their own upstream license obligations |
| POSIX threads and platform C runtime | Host-provided | Runtime dependencies of `nats.c` | Platform system libraries |

Exact official server archive SHA-256 values:

| Platform | SHA-256 |
| --- | --- |
| macOS x86_64 | `5bd8b59ca5bf93fab3da2c5843cf564cd6e2e291e22ae3b861746e7ebe259b95` |
| macOS arm64 | `e1c4e22d70bd44abfa0bcb3c16f7cf0c66f648c2e728c58924e8a1ce88913cc8` |
| Linux x86_64 | `5d2c51caca950333aba84911df7d377f826f3a59ec36061c6539105084f65c92` |
| Linux arm64 | `cdc208f5a3f42963a52b6ab06ef65626bb870315dc936e26ba571780c6351112` |

The evaluated static link does not include protobuf-c (legacy Streaming is
off) or libsodium (the bundled signing implementation is selected). It does
retain dynamic OpenSSL and system-library dependencies; inspect the resulting
ephemeral probe with `otool -L` on macOS or `ldd` on Linux when turning this
evaluation into a package. A downstream binary distribution must reproduce
the Apache-2.0 license texts and any notices present in the exact dependency
artifacts; there are no upstream root `NOTICE` files to reproduce for these
two pins.

`server-sbom.expected.tsv` is the exact package/version/license inventory from
the official v2.15.0 SPDX release artifact. The runner downloads the SBOM that
matches the selected server platform, checks its recorded SHA-256, and compares
that inventory before executing the binary. `NOASSERTION` for the Go standard
library means the release SBOM is not by itself sufficient notice material; a
production package would also need the Go BSD-3-Clause text and the dependency
license texts named in that inventory.
