# Restricted HTML tree boundary

`effects.html_tree.parseHtml(raw, declaredCharset, source)` is a D API for
small, explicitly decoded HTML records. It returns either a flat pre-order
`HtmlTree` of D-owned selected nodes or a typed `HtmlFailure`. The tree records
parent indices (`size_t.max` for the root), element qualified names, ordered
decoded attribute names/values, and text leaves. No native pointer or borrowed
input slice appears in the result. The opt-in `extract --input FILE|TREE
--output PATH --format=tree-json` command exports only this selected tree.

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
and has no Lexbor dynamic dependency. The shipping CLI calls the restricted
wrapper only on the `extract` route. The concrete `effects.html_tree_json_stage`
module self-registers its typed v2 stage; its own `htmlTreeJsonPlan` resolves
it through `buildConfigV2`. There is no general v2-config CLI option. The
stage maps one source `DocumentId` to the same ID or quarantines it with its
parser/decode reason.

`tree-json:v1` is deterministic UTF-8 JSON with one LF: top-level keys in
order `version`, `documentId`, `source`, `outputName`, `nodes`. Source keys are
`namespace`, `sourceKey`, `recordKey`; nodes are flat pre-order records with
`kind`, `parent` (null at root), `name`, ordered `attributes` name/value pairs,
and `text`. Strings use JSON control/quote/backslash escaping. Local source
namespace is `local-html:v1`; `sourceKey` is the canonical resolved input
directory root and `recordKey` is the normalized root-relative filename.
Renaming/moving the root intentionally changes identity. The output name is
the root-relative filename plus `.tree.json`, even when a single input is
written to an explicitly chosen output file. No child identity or native
pointer is serialized.

The CLI does not sniff HTML meta charset. `--charset` explicitly declares
UTF-8, UTF-16LE, or UTF-16BE; a BOM can select a supported encoding without
that option. An unsupported/conflicting declaration quarantines the document,
preserving decode reason and byte offset when available. Raw input is at most
64 KiB before allocation/native parse; decoded UTF-8 is at most 64 KiB;
selected observation has the limits above; serialized JSON is at most 4 MiB
before any output publication. The `html-tree-json` stage declares a 32 MiB
descriptive planning estimate; it is not a reservation or process/native RSS
limit. The local file walk uses one bounded worker,
one reserved input, and one held descriptor. A quarantined file is skipped,
earlier published files remain, and the command returns incomplete exit 1.
I/O, path/policy, and resource failures are run-fatal exit 2. Static symlink
and hard-link aliases are rejected, including symlinks discovered during the
tree walk. This route assumes trusted input/output directory ownership: it
does not snapshot path components or guarantee safety against hostile
concurrent path replacement. F08 publishes
each complete output atomically, retaining any prior destination on failure.
There is no manifest/restart path, article extraction, Markdown, metadata,
boilerplate algorithm, archive input, or throughput claim.

Release-active actual-binary check:

```sh
dub build --build=release
ldc2 -O -release -Isource -of=.dub/html-cli-check experiments/html_parser/cli_check.d source/domain/document.d source/content/pieces.d source/stages/contract.d source/stages/config.d source/stages/registry.d source/effects/html_tree_json_stage.d source/effects/html_tree_export.d source/effects/html_tree.d source/effects/lexbor_ffi.d source/text/decoding.d .dub/lexbor/liblexbor_static.a
.dub/html-cli-check ./scrubbed
```

The D check reports child-process peak RSS; one local macOS arm64 run observed
14,860,288 bytes across its small/cap fixtures. This is a measurement, not an
enforced native heap or archive-throughput bound. At the extract boundary,
the admitted raw input is at most 64 KiB; `ContentPiece.own`, the stage input
copy, decoded UTF-8, and the native wrapper's validation copy each retain
their own bounded buffers. The selected tree is charged to 1 MiB logical
observation, and the serializer is checked to 4 MiB before its owned content
copy and F08's 64 KiB output buffer. Runtime allocator capacity and Lexbor
allocation are not included in those logical charges. The shipping-binary D
check proves the 1 MiB observation cap is reachable: 4,000 authored
`<br a b c d e>` elements (56,000 raw bytes) publish; 4,600 (64,400 raw
bytes) quarantine as `observationLimit` without replacing the prior output.
No admitted-input CLI fixture has reached `outputLimit` under the current
raw/observation caps; reachability is unproven, so no actual-binary
`outputLimit` claim is made. A separate release-active D serializer check
constructs a 700,000-byte logical text observation whose JSON escaping
exceeds 4 MiB and asserts `HtmlTreeOutputLimit` before publication.

Rollback removes the opt-in route, stage, and serializer; the pinned native
boundary can remain for a separately reviewed consumer.
