# scrubbed roadmap

Status key: [x] done and verified, [~] partially done, [ ] not started.

Planning status (2026-09-20): [67 accepted GitHub issues](https://github.com/schancel/scrubd/issues)
cover the broader corpus-curation roadmap with 136 native dependency edges.
Acceptance is not an implementation claim; worker readiness is tracked per
issue. This file remains the status record for implemented work.

## Phase 0 — scaffold
- [x] dub project, MIT license, git repo
- [x] `pipeline.d`: named filter registry + ordered chain builder
- [x] `filters/normalize.d`: line-ending normalization, control-char
      stripping (real lazy range transforms, tested against real input —
      caught and fixed a `cast(string)` vs `to!string` UTF-32->UTF-8
      transcoding bug this way, not by code review alone)
- [x] `cli.d`: input-tree walk, output-tree mirroring, `TaskPool`-parallel
      per-file processing, `MmFile`-backed zero-copy reads, deterministic
      mapping/descriptor cleanup, empty-file handling, atomic destination
      replacement, trusted failure counts/exit status, and rejection of
      nested output trees and symlink traversal within selected trees
- [x] End-to-end smoke test (see git log / commit for the exact repro)
- [ ] Upstream software-factory follow-up: replace `.claude/skills` directory
      symlinks with an installer-owned portable representation. The canonical
      installer layout works on POSIX and symlink-enabled Git checkouts, but
      Claude skill discovery is unavailable when Windows checks out symlinks
      as plain text (`core.symlinks=false`). Do not add local wrappers until
      the upstream reinstall/upgrade path knows how to maintain them.

## Phase 1 — mojibake repair (the main substantive work item)
- [x] `filters/mojibake.d`: `latin1RoundTrip` / `cp1252RoundTrip` — the
      mechanical, reversible re-encode-as-legacy-then-decode-as-UTF8
      transform. CP1252's 0x80-0x9F table pulled directly from
      unicode.org/Public/MAPPINGS/VENDORS/MICSFT/WINDOWS/CP1252.TXT, not
      from memory.
- [x] Plausibility scorer: given the original text and 0-2 round-trip
      candidates, decide which is most likely correct (including "the
      original was already fine"). Starting heuristics are sketched as a
      comment in `mojibake.d` — verify them against real fixtures, don't
      just trust intuition. Concretely: pull a real corpus of known
      mojibake examples (ftfy's own test suite is public and is the
      obvious source — check its license before vendoring fixtures
      directly vs. writing new ones inspired by the same cases) and
      benchmark correctness, not just plausibility-in-the-abstract. Implemented
      as a conservative ftfy-style badness model; full-corpus D harness result:
      39/39 in-scope positive cases fixed and 48/48 encoding-negative cases
      preserved (September 2026 checkout of ftfy's public JSON fixtures).
- [x] `fixMojibake(string) -> string` entry point, registered as
      `fix-mojibake`; supports up to four improving passes for multilayer damage.
- [x] Make candidate evaluation lazy: Unicode-to-legacy byte Voldemort ranges
      feed Phobos's strict lazy UTF-8 decoder; losing candidates allocate no
      output buffer and only the selected repair is materialized.
- [ ] Decide how many legacy encodings to support beyond Latin-1/CP1252
      (ftfy covers ~10: CP1251, CP1250, ISO-8859-2, MacRoman, CP437,
      etc.) — each needs its own verified table like CP1252's. Don't
      guess these from memory; pull each from an authoritative source the
      way CP1252's was pulled here.
- [x] Unit tests with known before/after pairs (a few are sketched in
      `mojibake.d`'s TODO comment — there should be many more, covering
      both "fix this" and "don't touch this" cases, since the latter is
      the more dangerous failure mode). Selected fixtures are attributed in
      `THIRD_PARTY_NOTICES.md` under ftfy's Apache-2.0 license.
- [ ] Localized repair inside text that cannot round-trip as one buffer (for
      example, intentional punctuation or emoji surrounding a damaged span).

## Phase 2 — more normalization filters
- [~] HTML entity decoding (`&amp;` etc.) as its own filter, separate
      from `html2md` — useful standalone for non-HTML text that still has
      stray entities. `decode-html-entities` handles numeric references with
      HTML's CP1252 compatibility mapping and 15 common named references; the
      complete WHATWG named-reference table is not yet included.
- [x] Curly-quote / smart-punctuation normalization (ftfy's
      `uncurl_quotes`-equivalent), implemented as a lazy range. It can run
      before mojibake repair when intentional curly quotes would otherwise
      prevent a whole-buffer legacy-encoding round trip.
- [x] Tighten `normalizeLineEndings` to a real zero-allocation range
      transform. It is now a function-local Voldemort range and composes
      lazily with `stripControlChars`; registry adapters materialize strings.

## Phase 3 — configurability
- [x] Config file using JSON via Phobos `std.json` (no added dependency),
      specifying the filter chain and per-filter options. Implemented with
      ordered string/object entries; mojibake exposes `encodings` and
      `max-passes`; unknown keys are rejected by registry-owned option
      schemas. See `scrubbed.example.json`.
- [ ] `--dry-run` / diff mode: show what would change without writing
      output, useful for validating the mojibake scorer against a new
      corpus before trusting it on real data.
- [ ] Evaluate D `argparse` 2.x for a Cobra-like command tree: generated
      root/subcommand help, typed options, validation, and shell completion.
      Keep today's flags working while adding proposed `repair`/`extract`/`run`
      verbs; test help text, errors, and exit codes. Parser choice should not
      be confused with per-document throughput.

## Phase 4 — HTML->Markdown (`filters/html2md.d`, currently a stub)
- [ ] Check code.dlang.org for an existing D HTML/XML parser before
      writing one.
- [ ] Tag->markdown mapping (see the stub's TODO comment for the concrete
      list: headings, links, emphasis, lists, code, blockquotes, images;
      tables deferred/flattened if not worth the complexity).
- [ ] Explicitly NOT attempting trafilatura's boilerplate-detection
      problem (nav/ad/footer removal) in this phase — that's a
      substantially harder, separate problem (main-content vs.
      boilerplate classification, not a mechanical tag mapping). If it's
      wanted later, scope it as its own phase, not a "while I'm in here"
      addition to html2md.

## Phase 5 — correctness + performance validation
- [x] Correctness: benchmark the mojibake fixer against ftfy's own public
      test cases (respecting its license for any vendored fixtures). The
      checked-in D harness reports 39/39 in-scope positives and 48/48
      encoding-negative cases; see `benchmarks/ftfy_corpus.d`.
- [ ] Throughput: benchmark against Python ftfy/trafilatura on both a
      controlled document tree and a corpus larger than RAM. Report wall
      time, CPU time, peak RSS, bytes/sec, files/sec, allocation volume, and
      cold/warm-cache runs on the same storage. This is the actual claim
      ("D version could be faster") that has not been established yet.
- [~] Allocation benchmark: `benchmarks/mojibake_ranges.d` compares the
      reconstructed eager implementation, eager plus the clean-input guard,
      and lazy candidates using GC allocation counters. The independent guard
      explains clean-input zero allocation; ranges save about 36-39% versus
      the guarded control on the damaged short-input workloads. Extend this to
      mmap input, fused transforms, and representative full documents.
- [x] Make the cross-thread failure counter atomic and return nonzero when
      any file fails.

### Phase 5A — terabyte-corpus operational readiness

These are release gates for claiming terabyte-scale support. Whole-file mmap
is useful, but it is not sufficient on its own.

- [ ] Replace eager collection of every input pathname with a bounded
      producer/consumer walk; cap both queued files and total in-flight input
      bytes rather than scheduling solely by thread count.
- [ ] Add windowed mmap or buffered chunks for very large individual files.
      Preserve UTF-8 codepoint boundaries and filter state across windows
      (including CRLF pairs, HTML entities, and mojibake candidate spans), with
      adversarial boundary fixtures.
- [ ] Define which filters are truly streaming and which require document
      context. Fuse compatible range stages so the registry boundary does not
      force a whole-file allocation after every stage; give contextual stages
      explicit bounded-memory/spill behavior.
- [ ] Add backpressure-aware output and configurable concurrency for storage
      topology (local SSD, network filesystem, object-store staging). Verify
      descriptor and mapping counts stay bounded under low OS limits.
- [ ] Add a durable run manifest with input identity/checksum, selected filter
      config, success/failure state, and safe resume/retry. Atomic output alone
      prevents partial files but does not make a multi-day corpus run resumable.
- [ ] Stress interruption, disk-full, invalid UTF-8, permission failures,
      changing inputs, and process restart. Never report success for skipped or
      partially written data; emit a machine-readable failure manifest.
- [ ] Benchmark representative many-small-file and few-huge-file corpora at
      10 GiB, >RAM, and 1 TiB scales before calling the tool terabyte-ready.
      Publish hardware/filesystem details and retain comparable Python-tool
      baselines.

## Phase 6 — trafilatura-equivalent extraction

Begin only after the correctness corpus, allocation measurements, throughput
benchmarks, and Phase 5A bounded-resource/resume gates are checked in and
repeatable. This is a larger target than Phase 4's mechanical HTML-to-Markdown
conversion.

- [ ] Define parity against a pinned trafilatura release and its evaluation
      corpus: main-text precision/recall, failure cases, and output fixtures.
- [ ] Implement main-content versus boilerplate classification, including
      precision/recall modes and fallback extraction for short/difficult pages.
- [ ] Extract comments and structured metadata (title, author, date, URL,
      site name, description, categories/tags, language, and license).
- [ ] Preserve configurable structure: formatting, links, images, tables,
      lists, quotations, and code.
- [ ] Add segment/document deduplication and configurable pruning.
- [ ] Support the relevant structured output formats after the extraction
      model is correct; benchmark each supported mode against trafilatura.
- [ ] Treat crawling, feeds/sitemaps, network politeness, and language-model
      add-ons as separately scoped capabilities rather than silently bundling
      them into text extraction.

## Explicitly out of scope for now
- Full trafilatura-equivalent boilerplate/main-content extraction until the
  Phase 5 gates are complete; it is now explicitly planned as Phase 6.
- The other ~8 legacy encodings ftfy supports beyond Latin-1/CP1252,
  until their value and false-positive cost are evaluated explicitly.
