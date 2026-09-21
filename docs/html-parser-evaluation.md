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
semantics, not full DOM parity. The first four small cases use exact goldens;
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

## Recommendation and next decision

Lexbor is the better **candidate to investigate next**, not a production
selection: it is current upstream and its D FFI path completed this small
HTML5-like corpus. Gumbo remains a useful independent output oracle, but its
archive status and explicit input/tree lifetime coupling raise maintenance and
integration costs. Neither candidate has passed real-page corpus tests,
sanitizers, thread/concurrency tests, attribute/namespace parity, encoding
conversion, platform coverage, or license/NOTICE redistribution review. The
next reviewed continuation under #24 should resolve those gaps and obtain
@schancel's adoption decision before any parser enters `source/`, the package
lock, or a release artifact. Rollback of this landing deletes only this report
and `experiments/html_parser/evaluate.d`.
