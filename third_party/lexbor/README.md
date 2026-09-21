# Pinned Lexbor source

This is the unmodified source and build input for Lexbor v3.0.0, Git commit
`2ae88a1c6b5261830eff73ee12bb3cdf805f3cfe`. It is built as a static
archive by the local DUB pre-build command, without network access or a system
Lexbor installation. Only macOS arm64 is verified. The build deliberately
disables shared libraries, tests, examples, benchmarks, utilities and WASM.

The copied `source/` directory has 484 tracked files and matches upstream
byte-for-byte (`diff -qr` was empty). Its upstream Git tree object is
`4f1cd4a9f5762439e3c22a1c9fa8ca73467c610a`. A locally generated
`git archive --format=tar` of the exact commit has SHA-256
`b738cffc343868268d59109be5a1378dc854bfc06ddd5564954060398d3016e6`;
this is not a GitHub-generated tarball digest. The copied root inputs have
these SHA-256 digests:

| File | SHA-256 |
| --- | --- |
| `LICENSE` | `7321caa1f366dfbebf799b6c6c2604772dbb12ef10ed6a6b7cbb384b3401c4dd` |
| `NOTICE` | `b87f965fd2eba846a0a502d633dd7e7a680b93de5c514c404c948ccf1e5c9dc7` |
| `CMakeLists.txt` | `1f406b574548e8c12125c038e7e191a9a56a31bb5f1289e88a262e6010d9af71` |
| `config.cmake` | `80015cfd2721c39390d31ea73346a30e9602822513ea835c722ea8ecbbc3e8e4` |
| `feature.cmake` | `4d459751f725b4359f84fdaaa985f5934253fc5534903df52e64aaab6b0de720` |
| `lexbor-config.cmake.in` | `f7868566001e3b6d189a5386f27cdced9cf52af61defbfd16e698b78352d0c00` |
| `lexbor.pc.in` | `76ca81299ae5d9765fb779fc67f6c020bb9e2edb35a9c1e8748f51a177a4d650` |
| `version` | `6c4ca09e0d3549711034c2ce201cd27153bdd686cd57a60db8d7aed76068e087` |

No upstream file is modified. Upstream tests, examples, benchmarks, images,
packaging, docs, utilities, WASM, and auxiliary root scripts are omitted;
they are not needed by the static library build. The upstream CMake build
includes all `source/` modules in the archive, even though the linker pulls
only reachable objects into `scrubbed`. This retains the pinned upstream
build graph rather than silently pruning a dependency closure by hand.

For a clean checkout, `dub test --compiler=ldc2` and
`dub build --build=release` configure and build `.dub/lexbor/liblexbor_static.a`.
The `source/effects/lexbor_ffi.d` layout checks and native parser smoke test
are the narrow verified ABI surface; they do not prove other platforms. To
exercise that ABI probe as a standalone static-linked test executable:

```sh
ldc2 -unittest -main -Isource source/effects/lexbor_ffi.d .dub/lexbor/liblexbor_static.a -of=/tmp/scrubbed-lexbor-ffi-test
/tmp/scrubbed-lexbor-ffi-test
otool -L /tmp/scrubbed-lexbor-ffi-test
```

The shipping CLI currently has no Lexbor caller and does not include Lexbor
symbols. The restricted production wrapper and its accessor goldens are the
next independently reviewed slice.
