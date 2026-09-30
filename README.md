# scrubbed

A single native binary that cleans web/corpus text for training and
evaluation pipelines. `clean-web-document` bundles encoding repair, HTML
main-content extraction, and PII scanning into one pass per document;
dedup and language ID run as separate stages on the same pipeline, not
that same pass yet. No interpreter, no `pip install` -- though not a
fully static binary either: it dynamically links the system's libcurl,
and `dlopen`s libz at runtime for the code paths that need it (WARC gzip
members, DOCX's DEFLATE entries). Fast to run.

## Why

The usual way to clean a scraped corpus is a chain of separate Python
tools glued together with intermediate files: [ftfy](https://github.com/rspeer/python-ftfy)
for encoding repair, [trafilatura](https://github.com/adbar/trafilatura)
for extraction, langdetect for language ID, Presidio for PII, a dedup
script — each its own interpreter startup, each reading and writing the
whole document, each copying the string again.

scrubbed replaces that chain with one native pipeline: mojibake repair,
HTML main-content extraction, PII scanning, language ID, and dedup in a
single process per document, zero-copy where the data allows it, real
OS-thread parallelism across the whole corpus, no intermediate files
between stages. Where a case is covered, it's built and verified to match
the reference tool's output — see [Verified against the tools it
replaces](#verified-against-the-tools-it-replaces) below. Coverage is
still growing; the bar for anything shipped is drop-in correctness on
what it claims to cover, not "close enough."

## Quick start

```sh
dub build --build=release

# The whole pipeline in one command: mojibake repair -> main-content
# extraction -> PII scan, with an audit sidecar written automatically.
./scrubbed clean-web-document --input page.html --output page.txt
./scrubbed clean-web-document --input pages/ --output clean/ --threads 4

# Or compose your own stage/filter pipeline:
./scrubbed run --list-filters
./scrubbed run --input path/to/docs --output path/to/clean \
    --filters normalize-line-endings,strip-control

# Print the version and exit:
./scrubbed --version
```

See [docs/cli-commands.md](docs/cli-commands.md) for the full command and
flag reference (JSON config, JSONL streaming, `--dry-run`/`--explain`,
error journaling and resumable manifests, shell completion, and more).

## Installing a prebuilt binary

[`.github/workflows/release.yml`](.github/workflows/release.yml) builds
and publishes `.tar.gz` release archives (macOS arm64, Linux
x86_64/aarch64) plus a `SHA256SUMS` manifest automatically on every `v*`
tag. No versioned release has been cut yet, so there's nothing at the URL
below until the first tag ships; today, build from source with the `Quick
start` steps above. Once a release exists, install with the one-line
installer:

```sh
curl -fsSL https://raw.githubusercontent.com/schancel/scrubbed/main/packaging/install.sh | sh
```

This detects your platform (macOS arm64, Linux x86_64/aarch64), downloads
the matching release tarball, verifies its SHA-256 against the release's
published `SHA256SUMS`, and installs the binary plus bash/zsh/fish
completions to `/usr/local` (falling back to `$HOME/.local` if that isn't
writable and no `sudo` is available). It's proven end to end -- real
download, real checksum verification (including the rejection path), real
install, real `--version` run -- against a local fixture server in
[`.github/workflows/install-script-check.yml`](.github/workflows/install-script-check.yml).
See [`packaging/install.sh`](packaging/install.sh)'s own header comment
for the environment-variable overrides (`SCRUBBED_VERSION` to pin a
version, `SCRUBBED_INSTALL_BASE_URL`, `SCRUBBED_INSTALL_PREFIX`,
`SCRUBBED_INSTALL_NO_SUDO`).

A `.deb`, a Homebrew tap, and an `.rpm` are also built from that same
release tree, each with its own build script and a real clean-machine
install test, but none is wired into an automated publish step yet (the
Homebrew tap in particular has no live tap repository) -- see
[`packaging/debian/README.md`](packaging/debian/README.md) and
[`packaging/homebrew/README.md`](packaging/homebrew/README.md) for the
current state of each, and [`packaging/rpm/build.sh`](packaging/rpm/build.sh)
/ [`packaging/rpm/scrubbed.spec`](packaging/rpm/scrubbed.spec) for the
`.rpm` (no README there yet).

## Windows: via WSL2, not a native port

There's no native Windows `.exe` build, and none is planned as a drop-in
port -- POSIX-specific subsystems run throughout (`dlopen` for zlib, a
`sigaction`-based `SIGINT` handler, `mmap`-based zero-copy reads), none
of which map directly to Windows APIs.

WSL2 is a different story: it runs a genuine Linux kernel, not a
syscall-translation shim. The *existing* Linux x86_64 build and `.deb`
package (build, a real multi-file `clean-web-document` corpus run, and a
clean-machine `.deb` install) ran correctly end to end against a real
Linux kernel running the same way WSL2 does -- a real kernel inside a
lightweight VM, not native Windows hardware itself. That's strong
supporting evidence, not a genuine-WSL2-verified claim: the evaluation
couldn't reach an actual WSL2/Windows host. See
[docs/wsl2-evaluation.md](docs/wsl2-evaluation.md) for the exact commands
and output, including what's still unverified (a real `/mnt/c` mount).

## Verified against the tools it replaces

- **Encoding repair vs. ftfy** — on its Latin-1/Windows-1252 scope,
  scrubbed's mojibake repair matches ftfy exactly against ftfy's own test
  corpus: all 39 corrupted cases in scope fixed, all 48 clean cases left
  untouched. Other encodings and general mixed-encoding detection aren't
  covered yet.
- **Language ID vs. langdetect** — 100% classification agreement (11/11)
  on a real held-out fixture run, across scrubbed's 17 supported languages
  (11 Latin-script, plus 6 Brahmic-family: Hindi, Bengali, Tamil, Telugu,
  Gujarati, Punjabi). See [docs/language-id.md](docs/language-id.md).
- **Main-content extraction vs. trafilatura** — matches trafilatura's
  held-out gold answers on the pages it successfully parses today. Full
  methodology and the current, actively-tracked coverage gap are in
  [docs/html-main-content.md](docs/html-main-content.md).

## Performance

On a `-O3`/release build, an exact-output mojibake-repair run over
131,072 repeated lines: scrubbed at 0.152–0.156s vs. pinned ftfy at
3.698–4.076s (roughly 24–27x). This is one task-specific benchmark, not a
general corpus-speed claim — see [benchmarks/README.md](benchmarks/README.md)
for the full methodology and more (allocation microbenchmarks, a
quality-gated local-tree harness, dispatch-shipping comparisons).

## What it does

- **Mojibake/encoding repair** for Latin-1/Windows-1252, with a
  conservative badness scorer that only fixes evidenced spans and leaves
  ambiguous ones alone.
- **HTML main-content extraction** (link-density/tag-table heuristics,
  boilerplate/nav/ad/footer removal), with three bounded mechanical export
  formats from `extract --format=...`:
  - `main-content-markdown` — the boilerplate-stripped article **as
    Markdown** (headings, lists, links, emphasis), not just flattened
    plain text. Same selection as `clean-web-document`/`html-main-content`,
    rendered by the same converter as whole-page `markdown` below, scoped
    to only the winning subtree.
  - `markdown` — the *whole page*, unfiltered, converted to Markdown
    (nav/ad/footer included as-is; use `main-content-markdown` above for a
    clean article).
  - `tree-json` — the bounded selected parse tree as JSON.
- **Four-class PII scanner** (email/phone/card/IPv4) with report, mask,
  and opt-in redact modes, publishing a content-free audit sidecar. This
  is deterministic pattern matching, not complete de-identification, name
  recognition, or model-backed NER.
- **Exact-byte deduplication** across a corpus, via an overlay on the
  document-shard API.
- **Deterministic, model-free language identification** — no embedded
  model, no network call — reachable from the same generic pipeline as
  every other stage (`run --stage id=language-id-detect`).
- **Per-document quality signal**: order-0 token entropy plus compression
  ratio, for flagging degenerate/repetitive text
  ([docs/compressibility-annotate.md](docs/compressibility-annotate.md)).
- **HTML entity decoding** (all 2,231 WHATWG named references),
  smart-quote and line-ending normalization, and a JSONL streaming mode
  (`--input - --output -`) for pipelines that only need specific text
  fields touched.
- **Real parallelism** across files (OS threads, not green threads),
  zero-copy mmap reads, atomic output writes, and an opt-in SQLite-backed
  error journal/manifest for resuming interrupted local runs.
- **Crawling**: a `crawl` subcommand (fetch, discover links, and save raw
  HTML with a concurrent, resumable frontier) built on a bounded WARC/1.1
  reader (plain, gzip, and zstd-compressed; read-only), a durable crawl
  frontier with permanent duplicate-rejection, bounded HTTP fetch, and
  HTML link discovery. Fetch + discover + save raw only — no mojibake
  repair or metadata/main-content/PII stages; use `clean-web-document` as
  a separate later pass over the raw output.
- **Metadata, tags, rights, and chunking**: deterministic title/author/
  date/URL extraction, declared topical-tag extraction, a source-rights
  policy engine for permission/takedown decisions, and structured
  chunking with stable content-addressed chunk IDs and JSONL output
  (library-only; no CLI path yet for the last two).

## Status

Phases 0–2 (encoding repair, extraction, filter pipeline) are usable
within the documented scope; JSON/JSONL configuration is implemented.
Not yet proven at multi-terabyte scale — that's the focus of ongoing
work. See [TODO.md](TODO.md) for the precise, current list of what's done
vs. next, and [docs/release-execution-plan.md](docs/release-execution-plan.md)
for the ordered path to a first public release.

Deeper engineering write-ups (native HTML parser selection, S3
capability, WARC compression, packaging) live under [docs/](docs/).

## License

MIT.
