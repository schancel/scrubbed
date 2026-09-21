# scrubd roadmap

Status key: [x] done and verified, [~] partially done, [ ] not started.

## Phase 0 — scaffold
- [x] dub project, MIT license, git repo
- [x] `pipeline.d`: named filter registry + ordered chain builder
- [x] `filters/normalize.d`: line-ending normalization, control-char
      stripping (real lazy range transforms, tested against real input —
      caught and fixed a `cast(string)` vs `to!string` UTF-32->UTF-8
      transcoding bug this way, not by code review alone)
- [x] `app.d`: input-tree walk, output-tree mirroring, `TaskPool`-parallel
      per-file processing, `MmFile`-backed zero-copy reads
- [x] End-to-end smoke test (see git log / commit for the exact repro)

## Phase 1 — mojibake repair (the main substantive work item)
- [x] `filters/mojibake.d`: `latin1RoundTrip` / `cp1252RoundTrip` — the
      mechanical, reversible re-encode-as-legacy-then-decode-as-UTF8
      transform. CP1252's 0x80-0x9F table pulled directly from
      unicode.org/Public/MAPPINGS/VENDORS/MICSFT/WINDOWS/CP1252.TXT, not
      from memory.
- [ ] Plausibility scorer: given the original text and 0-2 round-trip
      candidates, decide which is most likely correct (including "the
      original was already fine"). Starting heuristics are sketched as a
      comment in `mojibake.d` — verify them against real fixtures, don't
      just trust intuition. Concretely: pull a real corpus of known
      mojibake examples (ftfy's own test suite is public and is the
      obvious source — check its license before vendoring fixtures
      directly vs. writing new ones inspired by the same cases) and
      benchmark correctness, not just plausibility-in-the-abstract.
- [ ] `fixMojibake(string) -> string` entry point, registered as a filter.
- [ ] Decide how many legacy encodings to support beyond Latin-1/CP1252
      (ftfy covers ~10: CP1251, CP1250, ISO-8859-2, MacRoman, CP437,
      etc.) — each needs its own verified table like CP1252's. Don't
      guess these from memory; pull each from an authoritative source the
      way CP1252's was pulled here.
- [ ] Unit tests with known before/after pairs (a few are sketched in
      `mojibake.d`'s TODO comment — there should be many more, covering
      both "fix this" and "don't touch this" cases, since the latter is
      the more dangerous failure mode).

## Phase 2 — more normalization filters
- [ ] HTML entity decoding (`&amp;` etc.) as its own filter, separate
      from `html2md` — useful standalone for non-HTML text that still has
      stray entities.
- [ ] Curly-quote / smart-punctuation normalization (ftfy's
      `uncurl_quotes`-equivalent) — straightforward, well-scoped, a good
      second filter to add after mojibake.
- [ ] Tighten `normalizeLineEndings` to a real zero-allocation range
      transform (it currently builds an intermediate `char[]` — noted as
      a known simplification in the code, revisit if profiling at real
      corpus scale shows it matters).

## Phase 3 — configurability
- [ ] Config file (TOML or JSON — check what's already a dependency
      before picking; don't add a new one gratuitously) specifying the
      filter chain AND per-filter options (e.g. mojibake's candidate
      encoding list, scorer thresholds) — CLI flags currently only
      support the ordered-name-list form, not per-filter config.
- [ ] `--dry-run` / diff mode: show what would change without writing
      output, useful for validating the mojibake scorer against a new
      corpus before trusting it on real data.

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
- [ ] Correctness: benchmark the mojibake fixer against ftfy's own public
      test cases (respecting its license for any vendored fixtures).
- [ ] Throughput: benchmark against Python ftfy/trafilatura on a
      realistically-sized document tree (megabytes-to-low-gigabytes, not
      a handful of files) — this is the actual claim ("D version could be
      faster") that hasn't been tested yet, only argued for.
- [ ] Fix the benign-race `failed` counter in `app.d` (currently a plain
      `size_t` incremented from multiple `TaskPool` threads — fine for a
      rough progress number, not fine if anything downstream needs to
      trust it exactly) with `core.atomic`.

## Explicitly out of scope for now
- Full trafilatura-equivalent boilerplate/main-content extraction (see
  Phase 4 note).
- The other ~8 legacy encodings ftfy supports beyond Latin-1/CP1252,
  until Phase 1's scorer is validated on the two most common cases first.
