# lexbor-d

A bounded, D-idiomatic wrapper over the vendored [Lexbor](https://github.com/lexbor/lexbor)
HTML5 parser. `lexbor_d.html_tree.parseHtml` turns validated, bounded input
into a flat pre-order `HtmlTree` of D-owned nodes, or a typed `HtmlFailure` --
never a raw Lexbor pointer or a borrowed native slice.

This package is a standalone extraction of `html_tree.d` + `lexbor_ffi.d`
(+ their `lexbor_d/decoding.d` dependency) from
[scrubbed](https://github.com/schancel/scrubbed), a text sanitization CLI.
It has zero dependency on scrubbed's own `dub.json` or `source/` tree and
builds and tests entirely on its own.

## What this wraps

- Real typed public surface: `HtmlTree`/`HtmlNode`/`HtmlAttribute`/
  `HtmlOutcome`/`HtmlFailure`/`HtmlFailureReason`/`HtmlNodeKind`. No raw
  Lexbor pointer or native handle appears in any public type.
- Real bounding on every dimension: `maxRawBytes`, `maxDecodedBytes`,
  `maxDepth` (128), `maxNodes` (8192), `maxAttributesPerNode` (256), and
  `maxObservationBytes`, each enforced during traversal with a typed
  `HtmlFailureReason` (`depthLimit`/`nodeLimit`/`attributeLimit`/
  `observationLimit`) rather than an unbounded walk or a crash.
- Native bytes never escape uncopied: every native string is copied out of
  Lexbor's buffers (`.idup`) and UTF-8-validated (`std.utf.validate`) before
  it ever reaches a `HtmlNode`, converting a `UTFException` into a typed
  `HtmlFailureReason.nativeData` outcome rather than propagating a raw
  exception or leaving a dangling native slice.
- Safe, `enforce`-guarded accessors: `HtmlOutcome.tree()`/`.failure()` both
  guard against reading the wrong variant.
- Foreign-namespace pruning: inline `<svg>`/`<math>` subtrees are excluded
  at tree-construction time, not left for every downstream consumer to
  re-implement.

Lexbor's own C source is vendored in full under `third_party/lexbor` and
built from source via `cmake` as part of this package's `preBuildCommands`
-- no network fetch, no system-installed Lexbor.

## Platform support

**Verified today: macOS arm64 only.** `source/lexbor_d/lexbor_ffi.d` declares
the native ABI (struct layouts mirroring Lexbor's C structs, checked
byte-for-byte via `static assert`) only for macOS arm64; every other
platform hits a `static assert(0, "Lexbor ABI is only verified for macOS
arm64")` at compile time rather than silently miscompiling.

This is a **static-link ABI-verification** gate, not a build-mechanism
limitation: Lexbor's vendored C source builds via `cmake` on any platform
`cmake` and a C compiler are available. The gap is that the D `extern(C)`
struct layouts in `lexbor_ffi.d` have only been checked against the
macOS-arm64-compiled layout. Verifying and extending that ABI check to other
platforms is tracked separately in scrubbed's
[issue #353](https://github.com/schancel/scrubbed/issues/353) and is **not**
solved by this package -- it inherits whatever platform status
`lexbor_ffi.d` had at the time it was extracted, and re-verifying other
platforms is explicitly out of scope here.

## Build and test

```sh
cd lexbor-d
dub build
dub test
```

Both build the pinned static Lexbor archive (`.dub/lexbor/liblexbor_static.a`)
from the vendored source with no network access, then link it into the
library (`dub build`) or a `-unittest` test binary (`dub test`).

`dub test` runs, unmodified from their scrubbed origin (aside from the
package's own file layout): the `lexbor_d.html_tree` unittest suite (parsing,
attribute decoding, foreign-namespace pruning) plus `tests/html_tree_checks.d`,
which ports scrubbed's release-active production check
(`experiments/html_parser/production_check.d`) into `dub test`-native
`unittest` blocks covering bounding limits (raw/decoded/depth/node/attribute/
observation), fault-injection paths through the private `Fault` enum
(`verifyHtmlFaults()`, gated behind the `htmlTreeProductionCheck` version
this package's `unittest` configuration sets), foreign-namespace pruning, and
native-byte-copy/UTF-8-validation (mutating the caller's raw input after
native document destroy must not affect already-copied output).

## Not published

This package is **not** published to code.dlang.org. That is held for a
separate go-ahead.

## License

MIT for the D wrapper code in this repository (see `LICENSE`). The vendored
Lexbor source under `third_party/lexbor` is Apache-2.0; see
`third_party/lexbor/LICENSE` and `third_party/lexbor/NOTICE`.
