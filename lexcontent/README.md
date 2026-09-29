# lexcontent

Standalone D library for HTML main-content extraction (boilerplate removal)
and Markdown rendering, built on the [`lexbor-d`](../lexbor-d) dub package's
statically-linked [Lexbor](https://github.com/lexbor/lexbor) HTML5 parser.

Extracted from [schancel/scrubbed](https://github.com/schancel/scrubbed)
issue [#361](https://github.com/schancel/scrubbed/issues/361) (same
standalone-packaging treatment as that repo's `s3lite`, issue #46). The
extraction/rendering algorithm itself is unchanged from scrubbed's
`effects.html_main_content` / `effects.html_main_content_markdown` /
`effects.html_markdown` (issue #335 Slice 2) -- only the module paths and
package boundary are new. This package has zero dependency on scrubbed's own
`dub.json` or `source/` tree, and scrubbed does not (yet) depend on this
package either; wiring scrubbed itself to use `lexcontent` is a separate,
later decision, not part of this extraction.

## What it does

Given parsed HTML (via the bundled Lexbor-backed `parseHtml`), `lexcontent`:

- Scores element subtrees by a heuristic (link density, tag weight,
  keyword hints, negative-tag-ancestor suppression for `nav`/`aside`/
  `footer`/etc.) to pick the single most likely "main content" subtree,
  or explicitly abstains when no candidate clears the floor.
- Extracts that subtree's flattened text (`extractMainContent`) or renders
  it as structured Markdown (`extractMainContentMarkdown`,
  `renderMarkdown`/`renderMarkdownFrom`) -- headings, paragraph breaks,
  links, emphasis, code, etc.

See `source/lexcontent/package.d` for the full public surface.

## Platform support -- read this before depending on it

`lexbor-d`'s `lexbor_d.lexbor_ffi` hard-codes the native struct layouts
(`NativeNode`, `NativeText`, etc.) that mirror Lexbor's own C structs,
verified byte-for-byte against what Lexbor's C compiler actually produces.
That verification has only been done for **macOS arm64**, which is what
this package's `dub build` / `dub test` were run and passed on today
(2026-09-27). Every other platform hits a hard `static assert(0, "Lexbor ABI
is only verified for macOS arm64")` at compile time in `lexbor_ffi.d` -- it
will not silently produce wrong results on an unverified platform; it will
not compile at all.

This is **not** a `dlopen`-a-hardcoded-path problem: Lexbor's full C source
is vendored under `lexbor-d/third_party/lexbor` (this package depends on
the `lexbor-d` dub package, issue #375) and built via `cmake` (a genuinely
cross-platform build tool) into a static library linked at compile time, so
the build mechanism itself is not macOS-specific. The gate exists purely
because nobody has yet re-verified the D `extern(C)` struct layouts against
Lexbor's compiled layout on Linux or other platforms.

scrubbed's own main binary links the same vendored Lexbor and has the exact
same ABI-verification gate. Widening Lexbor's cross-platform ABI coverage is
**tracked in scrubbed's issue #353**, a separate, parallel effort -- this
package's own Linux/other-platform readiness rides on whatever #353 finds,
rather than being solved independently here. This slice does not attempt to
fix or re-verify the ABI on any platform other than macOS arm64.

## Building and testing standalone

```sh
cd lexcontent
dub build
dub test
```

Both commands pull in the `lexbor-d` dub package (a sibling path dependency,
`../lexbor-d`), which vendors and statically builds Lexbor via `cmake` as its
own `preBuildCommands` step (`lexbor-d/third_party/lexbor`, pinned Lexbor
v3.0.0 source) -- no external Lexbor installation is required, and nothing
here depends on scrubbed's own `dub.json` or `source/` tree.

## Publishing

This package is **not** published to code.dlang.org as part of this work.
That step is deliberately held for a separate, explicit go-ahead.

## License

MIT (see `dub.json`). The vendored Lexbor source under
`lexbor-d/third_party/lexbor` (pulled in via the `lexbor-d` dub dependency)
retains its own upstream license (see `lexbor-d/third_party/lexbor/LICENSE`).
