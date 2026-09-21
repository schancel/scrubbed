# Restricted HTML tree boundary

`effects.html_tree.parseHtml(raw, declaredCharset, source)` is a D API for
small, explicitly decoded HTML records. It returns either a flat pre-order
`HtmlTree` of D-owned selected nodes or a typed `HtmlFailure`. The tree records
parent indices (`size_t.max` for the root), element qualified names, ordered
decoded attribute names/values, and text leaves. No native pointer or borrowed
input slice appears in the result. This is not wired to the CLI or extractor.

The public entry caps raw input at 64 KiB **before** calling the existing
`text.decoding.decodeBytes`. Quarantine preserves that decoder's reason and
offending offset. A decoded outcome must fit 64 KiB of UTF-8; the boundary
then makes and validates another owned UTF-8 copy before Lexbor sees it. It
accepts no HTML `meta charset` sniffing and no replacement decoding. Native
parse errors and unsupported/resource outcomes have distinct failure reasons.

Traversal rejects native depth above 128, more than 8,192 visited native
nodes, more than 256 attributes on one element, non-HTML element namespaces,
and more than 1 MiB of D-owned selected observation. The observation budget
counts each copied name/value/text byte plus the logical `HtmlNode.sizeof`
and `HtmlAttribute.sizeof` for each appended record, charged **before** each
append or copy. It does not promise an exact GC heap ceiling: dynamic-array
capacity and temporary decoded strings can be larger. The native parser may
allocate substantially more than these post-parse traversal limits; there is
no strict native RSS bound. A rejected traversal returns no partial tree.

The native document has one local owner, destroyed exactly once on success,
native status failure, traversal/copy failure, and injected D control-flow
failures. The returned strings are copied while the document is live. No tree
is shared across threads; the release check runs independent native trees on
eight threads. The ABI/build is verified only for macOS arm64. DUB fails its
platform guard elsewhere rather than inferring support.

Unselected and unsupported: comments, doctypes, namespace fidelity,
source spans, duplicate-attribute fidelity, parser-inserted unknown-element
semantics, unrestricted HTML5 conformance, script execution, large pages,
other-platform ABI/build, extraction quality, and TB-scale throughput. This
module is a restricted selected observation, not a browser DOM.

From a clean macOS arm64 checkout, `dub test --compiler=ldc2` and
`dub build --build=release` build the pinned static Lexbor archive with no
network fetch. The optimized release-active D check runs as follows (optional
WPT path is the uncommitted exact fixture named below):

```sh
ldc2 -O -release -d-version=htmlTreeProductionCheck -Isource -of=/tmp/scrubbed-html-production-check experiments/html_parser/production_check.d source/effects/html_tree.d source/effects/lexbor_ffi.d source/text/decoding.d .dub/lexbor/liblexbor_static.a
/tmp/scrubbed-html-production-check /tmp/scrubd-wpt-amp-final.html
otool -L /tmp/scrubbed-html-production-check
nm /tmp/scrubbed-html-production-check | grep lxb_html_document
```

The optional WPT page is
[`ambiguous-ampersand.html`](https://github.com/web-platform-tests/wpt/blob/532766fee262a2b41054665505b9dc37bd7c0a25/html/syntax/parsing/ambiguous-ampersand.html)
at commit `532766fee262a2b41054665505b9dc37bd7c0a25`, SHA-256
`c10358bda1648db3138d1a20c5bc21961cef0eee0f613f8718a317650240efe1`.
It is checked by exact hash and selected name/attribute/text values, not
redistributed or claimed as a full browser-test pass. The check also covers
authored exact goldens and a rejected wrong golden,
raw/decoded/node/depth/attribute/observation limits,
decode quarantine, input mutation after native destroy, injected native-status
and traversal failures, independent-tree concurrency, and local peak RSS/GC
observations. One macOS arm64 non-sanitized run reported process
high-water RSS 9,764,864 bytes and GC live bytes 83,472 after 900 small
parses; these are local measurements, not enforced bounds. Native ASan+UBSan
of the same check passed with no diagnostic; its instrumented high-water RSS
was 196,984,832 bytes.

The check executable resolves Lexbor symbols from the vendored static archive
and has no Lexbor dynamic dependency. The shipping CLI has no HTML-tree caller
yet; `nm scrubbed` consequently does not show Lexbor symbols. This is a
source-level production seam for the next separately specified consumer, not
an end-user parser command. Rollback removes this wrapper, its check, and
this document; the earlier pinned dependency can remain for a new consumer
decision or be removed in a separate reviewed cleanup.
