# W01 native HTML parser evaluation — evidence landing only

This evaluates two native parsers from a standalone D harness. It neither pins
nor redistributes a production dependency. @schancel owns the later adoption,
publication/license, and version decision. No private corpus was used.

## Reproduction and provenance

The measurements below were taken on Darwin arm64, Apple clang 21.0.0 and LDC
1.43.0. Clone each official upstream at the exact commit, outside this repo:

| Candidate | Upstream tag and exact source commit | Primary-source license evidence |
| --- | --- | --- |
| [Lexbor](https://github.com/lexbor/lexbor/releases/tag/v3.0.0) | `v3.0.0`, `2ae88a1c6b5261830eff73ee12bb3cdf805f3cfe` | [LICENSE](https://github.com/lexbor/lexbor/blob/v3.0.0/LICENSE) Apache-2.0, SHA-256 `7321caa1f366dfbebf799b6c6c2604772dbb12ef10ed6a6b7cbb384b3401c4dd`; [NOTICE](https://github.com/lexbor/lexbor/blob/v3.0.0/NOTICE) present, SHA-256 `b87f965fd2eba846a0a502d633dd7e7a680b93de5c514c404c948ccf1e5c9dc7` |
| [Gumbo](https://github.com/google/gumbo-parser/releases/tag/v0.10.1) | `v0.10.1`, `3973c58d759574f2899528d2b3379e17d66dbcad` | [COPYING](https://github.com/google/gumbo-parser/blob/v0.10.1/COPYING) Apache-2.0, SHA-256 `c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4`; no tracked `NOTICE` at this revision |

The Gumbo repository is [archived/read-only](https://github.com/google/gumbo-parser)
as of January 2026. The license observations are source facts, not a legal or
redistribution decision. Neither source tree nor native binary is committed.

For a checkout with those commits in `/tmp/scrubd-lexbor-v3-eval` and
`/tmp/scrubd-gumbo-v0101-eval`, the exact local build/link/run sequence was:

```sh
git clone --depth 1 --branch v3.0.0 https://github.com/lexbor/lexbor.git /tmp/scrubd-lexbor-v3-eval
git clone --depth 1 --branch v0.10.1 https://github.com/google/gumbo-parser.git /tmp/scrubd-gumbo-v0101-eval
git -C /tmp/scrubd-lexbor-v3-eval rev-parse HEAD
git -C /tmp/scrubd-gumbo-v0101-eval rev-parse HEAD
cmake -S /tmp/scrubd-lexbor-v3-eval -B /tmp/scrubd-lexbor-v3-eval-build -DCMAKE_BUILD_TYPE=Release -DLEXBOR_BUILD_TESTS=OFF -DLEXBOR_BUILD_EXAMPLES=OFF -DLEXBOR_BUILD_BENCHMARKS=OFF -DCMAKE_INSTALL_PREFIX=/tmp/scrubd-lexbor-v3-eval-install
cmake --build /tmp/scrubd-lexbor-v3-eval-build -j4
cmake --install /tmp/scrubd-lexbor-v3-eval-build
cc -O2 -fPIC -dynamiclib /tmp/scrubd-gumbo-v0101-eval/src/string_piece.c /tmp/scrubd-gumbo-v0101-eval/src/tokenizer.c /tmp/scrubd-gumbo-v0101-eval/src/parser.c /tmp/scrubd-gumbo-v0101-eval/src/tag.c /tmp/scrubd-gumbo-v0101-eval/src/error.c /tmp/scrubd-gumbo-v0101-eval/src/utf8.c /tmp/scrubd-gumbo-v0101-eval/src/char_ref.c /tmp/scrubd-gumbo-v0101-eval/src/attribute.c /tmp/scrubd-gumbo-v0101-eval/src/vector.c /tmp/scrubd-gumbo-v0101-eval/src/util.c /tmp/scrubd-gumbo-v0101-eval/src/string_buffer.c -I /tmp/scrubd-gumbo-v0101-eval/src -o /tmp/scrubd-gumbo-v0101-eval/libgumbo.dylib
ldc2 -O -release -enable-asserts=true experiments/html_parser/evaluate.d /tmp/scrubd-lexbor-v3-eval-install/lib/liblexbor_static.a /tmp/scrubd-gumbo-v0101-eval/libgumbo.dylib -of=/tmp/scrubd-html-evaluate
/tmp/scrubd-html-evaluate lexbor 30
/tmp/scrubd-html-evaluate gumbo 30
```

`./autogen.sh` for Gumbo failed because `aclocal` was absent; the direct C
compile above uses exactly the C translation units in its `Makefile.am` and
does not introduce an authored C wrapper. It emitted two cast warnings. LDC
emitted a missing optional LLVM clang search-path warning. Neither was a
compile failure. A release adoption would need an independent build-system
and supported-platform audit.

## FFI and quality boundary

The D harness directly declares the narrow C layouts/functions it reads.
Lexbor owns its document/tree, destroyed by `lxb_html_document_destroy`;
its node text is copied into D strings before destruction. Gumbo's
[`gumbo.h`](https://github.com/google/gumbo-parser/blob/v0.10.1/src/gumbo.h)
explicitly requires the input buffer to outlive the tree because original
text/tag slices can point into it; the D input remains live until
`gumbo_destroy_output`. Gumbo's error-vector length is reported. The simple
Lexbor parse API returns a status but this harness does not extract a parse
error count, so that column is **unsupported**, not zero. Both process runs
completed without a crash; this is not fuzzing or a memory-sanitizer proof.

Observations are the same D-owned format for both candidates: element start/end
names and decoded text leaves, in tree order. Attributes, comments, namespace,
doctype and source spans are intentionally excluded, so this is selected tree
semantics, not full DOM parity. The Gumbo binding uses
`gumbo_normalized_tagname`; unknown/custom tags become empty names in this
observation, so custom-tag parity is untested. The first four small cases use
exact goldens;
the charset case checks only structural/text prefix because the decoded bytes
diverge; deep/wide cases assert 256/512 corresponding start tags and end text.
Each iteration's output must equal that candidate's first output. The harness
asserts a deliberately bad output fails its quality gate, with assertions
enabled even for optimized compilation. The quality gate precedes any
performance interpretation.

## Raw local run (30 iterations per case and candidate)

Each row is one cold invocation and the arithmetic mean of 29 warm invocations
within the same process, including parse, D observation copy, and tree destroy.
CPU is user+system time for all 30 iterations. `process_peak_rss_bytes` is
macOS `getrusage` high-water RSS: cumulative across case order within each
candidate process, **not** incremental per-case retained memory. Both candidates
were separate processes. Timings below are microseconds, too short and noisy
for a general speed claim; cold Gumbo times varied notably across runs. Lexbor
was linked statically and Gumbo dynamically, and candidate order was fixed;
the RSS and cold rows are not an apples-to-apples production comparison.

| Case | Lexbor quality / errors / cold / warm / CPU / peak RSS | Gumbo quality / errors / cold / warm / CPU / peak RSS | Observation |
| --- | --- | --- | --- |
| broken nesting | pass / unsupported / 207 / 5 / 395 / 3,276,800 | pass / 3 / 1,212 / 2 / 338 / 2,867,200 | exact parity |
| table foster | pass / unsupported / 8 / 4 / 160 / 3,309,568 | pass / 1 / 4 / 2 / 87 / 2,949,120 | exact parity |
| entity + UTF-8 | pass / unsupported / 17 / 4 / 149 / 3,342,336 | pass / 1 / 168 / 1 / 174 / 3,112,960 | exact parity |
| embedded NUL + truncated tag | pass / unsupported / 4 / 4 / 133 / 3,358,720 | pass / 4 / 2 / 1 / 52 / 3,129,344 | exact parity; both discard NUL in selected text |
| charset meta + Latin-1 byte | pass (weak) / unsupported / 7 / 4 / 146 / 3,375,104 | pass (weak) / 2 / 4 / 3 / 113 / 3,145,728 | **different observation hashes**: Lexbor `ff5da2f0...`, Gumbo `06255689...`; transcoding not validated |
| deep 256 | pass / unsupported / 83 / 82 / 2,477 / 4,177,920 | pass / 257 / 370 / 347 / 10,445 / 4,653,056 | matching full observation SHA-256 `0f7b26c2...` |
| wide 512 | pass / unsupported / 140 / 125 / 3,801 / 4,915,200 | pass / 1 / 288 / 315 / 9,343 / 5,439,488 | matching full observation SHA-256 `d807c147...` |

The first four exact observations share full hashes across parsers (printed by
the executable). Negative quality control was rejected on both runs. The
charset row's visible replacement glyph is not evidence of byte equality.

## Second evidence slice: charset, custom elements, ownership

The follow-up `evaluate.d` mode uses the **same** pinned upstream commits and
libraries. Build it with the LDC command above (change the output path if
desired), then run `evaluate lexbor evidence` and `evaluate gumbo evidence`.
The three new malformed snippets are authored for this experiment; no external
page text is copied, so no third-party fixture redistribution permission is
asserted. Their input strings and exact goldens are in D, and the optimized
executable throws on a bad golden or on a deliberately bad quality control;
this does not depend on D `assert` surviving release compilation.

The [HTML Standard input-byte-stream rules](https://html.spec.whatwg.org/multipage/parsing.html#the-input-byte-stream)
require encoding sniffing and byte-to-character decoding *before* tokenization;
`meta charset` can influence that decoding. The
[Encoding Standard](https://encoding.spec.whatwg.org/#names-and-labels) maps
the `iso-8859-1` label to `windows-1252`. At the tested API boundary,
[Gumbo's pinned header](https://github.com/google/gumbo-parser/blob/v0.10.1/src/gumbo.h)
requires UTF-8 input, and [Lexbor's encoding example](https://lexbor.com/modules/encoding/)
shows conversion to UTF-8 before `lxb_html_document_parse`. The raw `E9`
byte was intentionally **not decoded** by this harness. Thus the original
charset discrepancy is an invalid-input/API-boundary test, not evidence that
the parsers disagree about HTML encoding sniffing. The prior report's phrase
"visible replacement glyph" hid the crucial byte distinction: Lexbor's
selected text retained single byte `E9`, while Gumbo emitted UTF-8 replacement
`EF BF BD`. When the D fixture supplies the corresponding UTF-8 bytes `C3 A9`,
both produce `{café}` with SHA-256
`6cd3b8589e7357640a2bc60a6fc3cf7c43918d847168b626d1ed50abb529a6c3`.
Both raw-byte outcomes are exact *observational* goldens, not standards-conformance
passes. An actual byte-sniff/decode pipeline remains untested here.

The new observation mode copies qualified element names and decoded attributes
into D-owned strings before either native tree is freed. Gumbo uses its pinned
`gumbo_tag_from_original_text` API when a normalized custom-tag name is empty;
the original tag slice remains live until `gumbo_destroy_output`. This fallback
does not establish names for parser-inserted unknown elements with no original
slice. The selected observations below match and are exact goldens for both
parsers (SHA-256 of the full observation):

| Authored malformed case | Observation SHA-256 | What it pins |
| --- | --- | --- |
| `<x-note data-id='a&amp;b' disabled>Hi</x-note>` | `01707e60c4730639347df25b13742a091c87e2387e0643283d671cd547834a83` | custom tag, entity-decoded attribute, empty-valued boolean attribute |
| misnested `<a><b>…</a>…</b>` | `dfbf8a268328d12e3e4bc69f80f8e7ddf9a324f756cc5c9fcde36a7690d55e75` | formatting-element reconstruction and `href` |
| omitted `</li>` list | `7ef210348064d303fdabaaf9ac2d39c9ba15e32cc987de7bcf3520ef5ead2972` | implied ends and `class` |

The mode then runs eight D threads, each constructing, observing, and
destroying 100 independent native trees from one read-only input. Both
candidate runs matched SHA-256
`5a448ed3366b5994b7dafd3669f26ce3d34fcbfb08fe27da5c81b6fce22d8d33`;
this is a bounded reentrancy/ownership probe, not a thread-safety guarantee
for shared trees or a race-detector result. Namespaces, source spans, duplicate
attributes, parser-inserted custom names, actual page corpus, other platforms,
and lifecycle failure injection remain unsupported.

On Darwin arm64 with Apple clang 21.0.0 and LDC 1.43.0, I also built the
**same revisions** with native ASan+UBSan instrumentation. Lexbor's separate
CMake build used `RelWithDebInfo` and
`-DCMAKE_C_FLAGS='-fsanitize=address,undefined -fno-omit-frame-pointer'`,
then `--target lexbor_static`. Gumbo used the exact C source list above with
`cc -O1 -g -fPIC -fsanitize=address,undefined -fno-omit-frame-pointer -dynamiclib`.
The D executable was optimized/release with assertions enabled and linked to
these instrumented libraries and Apple's
`libclang_rt.asan_osx_dynamic.dylib` and
`libclang_rt.ubsan_osx_dynamic.dylib` from
`/Library/Developer/CommandLineTools/usr/lib/clang/21/lib/darwin`, with that
directory passed as linker `-rpath`. Both `evidence` runs exited 0 with the
same observation hashes and no sanitizer diagnostic. This probes the native
parse/observe/destroy path, not D-runtime memory safety, full fuzz coverage,
ThreadSanitizer, or a release binary. No native instrumented artifact was
committed. The Gumbo build emitted its existing pointer-to-enum cast warnings;
LDC emitted an optional LLVM clang search-path warning.

## Recommendation and next decision

Lexbor is the better **candidate to investigate next**, not a production
selection: it is current upstream and its D FFI path completed this small
HTML5-like corpus. Gumbo remains a useful independent output oracle, but its
archive status and explicit input/tree lifetime coupling raise maintenance and
integration costs. The second slice provides only bounded native sanitizer,
independent-tree concurrency, and selected attribute evidence. Neither
candidate has passed representative real-page corpus, namespace/source-span
parity, actual encoding conversion, other-platform coverage, or license/NOTICE
redistribution review. The
next reviewed continuation under #24 should resolve those gaps and obtain
@schancel's adoption decision before any parser enters `source/`, the package
lock, or a release artifact. Rollback of this landing deletes only this report
and `experiments/html_parser/evaluate.d`.
