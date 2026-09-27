# corpus_crawl (issue #305)

A small, **non-shipped** batch tool that runs a real frontier -> fetch ->
discover loop over three already-shipped, **unmodified** pieces --
`domain.job_queue`/`domain.frontier_contract` (#251/#253), `effects.http_fetch`
(#238), and `effects.html_discovery` over `effects.html_tree` (#239) -- to
build a real raw-HTML test corpus for R4 benchmarking. It composes those
pieces with zero changes to any of them: see `crawl.d`'s header comment for
the exact mapping.

It is explicitly **not** #240's shipped crawl-preset vision, not a
document-processing pipeline (no mojibake repair, no
metadata/main-content/PII, no `StageDocument` involvement anywhere in this
directory), not resumable/durable across process runs, and not wired into
the shipped `scrubbed` binary. `experiments/` sits outside `dub.json`'s
`sourcePaths`, and nothing in `source/**` or `dub.json` is touched by this
ticket.

## This tool makes real network requests

Running `run.sh` fetches real pages from real third-party sites over the
public internet -- Wikipedia, Hacker News, and the Python documentation. That
is expected and intentional, not an accident: this matches the same posture
already recorded on issue #229's 2026-09-26 "public package acquisition
boundary" decision (see `docs/html-main-content.md`'s "Held-out real-page
tier" section and `experiments/html_main_content/fetch_held_out.sh`, which
established the precedent this ticket follows) -- real third-party content
may be fetched transiently for test/benchmark-corpus purposes, but is never
vendored into this repository's git history and never shipped in the release
binary/package. The corpus directory this tool populates is a `--corpus-dir`
argument the caller supplies (see "Usage" below); this tool never defaults
that path into anywhere under this repository, and neither `run.sh` nor
`crawl.d` ever runs `git add` on it. If you do choose an output directory
inside this working tree for convenience, do not commit it.

## Seed list

`seeds.txt` contains exactly the owner-approved seed list from the issue
body's "Owner decision: seed list confirmed" note (`https://` added to each,
since `effects.web_url.WebUrl` requires an explicit `http`/`https` scheme; no
seed was added, removed, or substituted):

```
https://en.wikipedia.org/wiki/Web_scraping
https://en.wikipedia.org/wiki/Unicode
https://en.wikipedia.org/wiki/D_(programming_language)
https://en.wikipedia.org/wiki/Python_(programming_language)
https://news.ycombinator.com/
https://docs.python.org/3/tutorial/index.html
```

Reddit was explicitly declined by the owner (restrictive robots.txt/ToS, and
this tool is not robots.txt-aware) in favor of Hacker News for forum-style
structural diversity.

## Design (owner-accepted defaults; see the issue body for the full rationale)

- **In-memory frontier** (`openInMemoryJobQueue`): a single-shot batch run,
  not a resumable service.
- **`hostKey = WebUrl.origin`** (scheme+host+port-sensitive).
- **Politeness**: a strictly serial fetch loop (`FrontierLimits.maxActiveLeases
  = 1`) plus an explicit per-host minimum delay, enforced by this driver's own
  `HostThrottle` (default 3000ms, `--min-host-delay-ms` overridable). This is
  new orchestration-local logic only -- `effects.http_fetch` itself has no
  per-host concept and is untouched.
- **Discovery scope**: `DiscoveryScopeKind.allowedDomain`, pre-populated from
  the seed file's own distinct origins -- stays within the owner-approved
  sites.
- **Bounds**: `maxPages=200`, `maxPagesPerHost=50`, `maxDepth=3`, reusing
  `FrontierLimits` completely unchanged. This driver's own attempt loop is
  also capped at `maxPages` total lease attempts (not just distinct admitted
  candidates): `LeaseOutcome.retryableFailure` re-queues the same candidate
  for another lease (the issue's own accepted composition maps
  `FetchFailure.category()` directly onto `LeaseOutcome`), so a persistently
  (but only transport-level) failing seed could otherwise retry forever in a
  tool with no backoff. Capping total attempts at the same `maxPages` number
  is what makes "terminates on its own: frontier exhausted or `maxPages`
  hit" an actual guarantee.
- **Failed fetches get a manifest row**, never a silent drop.
- **`manifest.jsonl`** is a new, plain, append-only JSONL file -- deliberately
  not `effects.local_manifest.LocalManifest`, which is keyed on
  document-processing identity concepts this tool has no reason to import.

## Usage

```sh
dub build --build=release   # once, so the native Lexbor library exists
experiments/corpus_crawl/run.sh /path/outside/this/repo/corpus
# optional overrides:
experiments/corpus_crawl/run.sh /path/outside/this/repo/corpus --min-host-delay-ms 5000
experiments/corpus_crawl/run.sh /path/outside/this/repo/corpus --seeds /path/to/other-seeds.txt
```

`run.sh` compiles `crawl.d` directly against the already-shipped modules with
`ldc2` (the same "compile a throwaway driver against production modules"
idiom `experiments/http_fetch_seam/check.d` and
`experiments/html_main_content/fetch_held_out.sh` already use), then runs it.
It is outside the normal `dub build`/`dub test`/release-active-checker path
entirely; nothing in that path depends on it or on anything it produces.

`crawl.d` can also be built and invoked directly if preferred; see its
`getopt` usage (`--seeds`, `--corpus-dir`, `--min-host-delay-ms`) or pass
`--help`.

## Output shape

```
<corpus-dir>/
  raw/<sha256-hex>       # one file per distinct fetched body, content-addressed
                         # (effects.http_fetch's own persistContentAddressed:
                         # temp file + fsync + symlink-refusing hard link)
  manifest.jsonl         # one JSON object per line, one line per finished lease
```

Each successful-fetch manifest record has: `url`, `finalUrl`, `fetchedAtUtc`,
`httpStatus`, `contentSha256`, `bodyBytes`, `contentType`, `depth`,
`discoveredFrom`, `shardPath`. A failed-fetch record instead carries
`failureReason`/`failureCategory` (from `effects.http_fetch`'s own typed,
content-free `FetchFailure`) in place of the success-only fields; `url`,
`depth`, `discoveredFrom`, and `fetchedAtUtc` are always present.
`discoveredFrom` is the literal string `"seed"` for a seed candidate, or the
referring page's canonical URL for a discovered one.

## Crash / Ctrl-C safety

Raw-body atomicity is entirely `effects.http_fetch`'s own existing guarantee
(temp-file + fsync + hard-link into the digest-named destination): a kill at
any point can only ever leave behind an unpredictable-named, dot-prefixed
temporary file, never a file under the expected `<sha256-hex>` name that is
incomplete. `manifest.jsonl` is appended to, flushed, and `fsync`'d one
complete JSON line per finished lease, only after that lease's outcome is
fully known; a crash between two leases leaves every already-written line
complete and valid, and the in-flight lease at the moment of the crash has
not yet produced any write attempt at all.

Verified directly: a real chained local-HTTP-server run was `kill -9`'d
mid-crawl (with an inflated per-host delay so the kill reliably landed inside
the sleep between fetches). The resulting `manifest.jsonl` contained exactly
3 complete, individually JSON-parseable lines, each pointing at a `raw/`
file matching its digest byte-for-byte, and no stray or partial file existed
under any `<sha256-hex>` name in `raw/`.

## Real end-to-end run (2026-09-26, this ticket's implementation)

A real run of `run.sh` against the full seed list above (default
`--min-host-delay-ms 3000`) took 2m41s and produced:

```
corpus_crawl: attempts=57 completed=57 failed=0 pagesAdmitted=57 queueComplete=true
```

- 57 total fetch attempts, all completing at the transport level (zero
  `FetchFailure`s of any category) -- `queueComplete=true` means the frontier
  actually exhausted on its own (every reachable, in-scope, in-depth
  candidate was leased and finished; the run did not merely hit `maxPages`).
- 39 distinct raw bodies persisted under `raw/` (1.2 MB total); the
  difference from 57 attempts is legitimate content-addressed dedup (e.g.
  every Wikipedia seed in this run happened to return the same small
  rejection body -- see below -- so they collapse to one shard file).
- Per-host page counts: `en.wikipedia.org` 6, `news.ycombinator.com` 50 (hit
  `maxPagesPerHost`), `docs.python.org` 1.
- Politeness verified directly from `fetchedAtUtc` deltas: the minimum
  interval between any two consecutive requests to the same host was
  3.000-3.005s across all three hosts (50 consecutive Hacker News requests
  averaged almost exactly 3.00s apart).

Two honest, real-world findings from this run, both attributable to
already-shipped, unmodified modules' existing behavior/scope -- not to any
defect in this new orchestrator, and not something in scope for this ticket
to change:

- **All four Wikipedia seeds returned HTTP 403** with the body `"Please set a
  user-agent and respect our robot policy..."`. `effects.http_fetch` does not
  currently set a custom `User-Agent` header (there is no such option on
  `FetchRequest`), and the Wikimedia Foundation blocks requests without one.
  This is a real, correctly-recorded HTTP-level outcome (`httpStatus: 403`,
  `leaseOutcome: completed` -- the *transport* succeeded), not a
  `FetchFailure`; it simply means these four pages currently yield a small
  rejection body rather than real article HTML. Fixing this would mean
  adding a `User-Agent` option to `effects.http_fetch`, which is out of this
  ticket's explicit zero-source-changes scope.
- **`docs.python.org` yielded only its one seed page**, despite that page
  containing 28 real `<a href>` links to other same-origin documentation
  pages. Its HTML includes inline `<svg>` icons (a Sphinx theme convention),
  which trips `effects.html_tree`'s existing, already-documented
  `unsupportedNamespace` restriction to the HTML namespace (see
  `docs/html-main-content.md`'s own held-out-corpus report, which hit the
  identical restriction on a different page) -- the whole-document parse
  fails, so this driver's best-effort discovery step finds nothing further
  from that one page. The fetch itself still succeeded and is fully recorded
  in the manifest.

Neither finding blocks this ticket's acceptance criteria: every fetch
attempt (success or failure, blocked-by-remote-policy or not) got exactly
one manifest row, raw bytes were persisted content-addressed, the run
terminated on its own via genuine frontier exhaustion, and per-host
politeness held throughout.
