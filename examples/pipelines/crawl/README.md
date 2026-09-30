# `crawl` example: bounded crawl against a local fixture server

Demonstrates `scrubbed crawl` -- concurrent, resumable frontier fetch +
discover + save raw HTML -- against a small, wholly synthetic fixture site
served by a local, loopback-only HTTP server that this example's own checker
starts and stops. No real network dependency anywhere in this example: the
crawl target is `127.0.0.1` only, never a real external domain.

Corpus and fixtures are in
[`examples/corpus/crawl/`](../../corpus/crawl/); exact provenance, media
types, licenses, and SHA-256 digests are in that directory's
[`manifest.json`](../../corpus/crawl/manifest.json). The pinned, exact
expected discovered-page set (path/depth/discoveredFrom/content hash,
origin-normalized so it stays port-independent) is
[`expected/discovered-pages.json`](../../corpus/crawl/expected/discovered-pages.json).

## Why a fixture server, not a static-file check

`crawl` takes URL seeds and fetches over real HTTP (`effects.http_fetch`,
libcurl-backed) -- there is nothing to point it at except a live server. This
is the first example in this repository whose checker manages a live
process (well, a live in-process listener) rather than diffing static files,
so its structure necessarily deviates a little from the other pipeline
examples' pure-file-diff pattern while keeping the same rigor: a clean temp
directory, a pinned manifest with hashes and provenance, and adversarial
self-testing.

The fixture server ([`check.d`](check.d)'s `FixtureServer`) is a minimal
`std.socket`-based static responder -- one accept thread, one handler thread
per connection -- deliberately modeled on
`effects.crawl_orchestrator`'s own proven `TestServer` unittest helper
(including its Darwin/Linux-safe `stop()`, which pokes a real loopback
connection before closing the listener; a plain `close()` alone does not
reliably unblock a thread parked in `accept()` on Linux -- see that module's
comment on issue #353). It serves the checked-in fixture pages read from
disk, is bound to `127.0.0.1` on an ephemeral port, and is never bound to
`0.0.0.0`/`INADDR_ANY` or any real external interface.

## Fixture site

Five small, wholly original, synthetic HTML pages
([`inputs/site/`](../../corpus/crawl/inputs/site/)) with a real link graph:

```
index.html (depth 0, the seed)
  -> about.html (depth 1)
       -> team.html (depth 2)
            -> resources.html (depth 3, exactly this recipe's --max-depth)
  -> contact.html (depth 1, a terminal leaf)
  -> https://blog.external-example.test/feed  (out of crawl scope -- never fetched)
```

Every page also links back toward pages already discovered (e.g. `about.html`
and `team.html` both link back home), which exercises the frontier's own
duplicate-admission dedup: `admit()` is called on that reference again but
returns `duplicate`, so provenance/depth are recorded once, at first
admission, and no page is ever fetched twice.

`about.html` carries the same Latin-1/CP1252 mojibake byte pattern
("FranÃ§ois", the UTF-8 bytes of "François" misread and re-encoded) already
established in `examples/corpus/clean-web-document`'s own
`hydrology-notebook.html` fixture (same name, same surrounding phrase) --
reused deliberately rather than inventing a new, unproven mojibake shape.
`index.html`'s title carries a literal `&amp;` entity. `crawl` leaves both
completely untouched in the raw saved bytes; see "What crawl does NOT do"
below.

`https://blog.external-example.test/feed` uses the RFC 2606 reserved
`.test` TLD and a name that is obviously synthetic -- it is never resolved
or fetched by this example (the discovery-scope check excludes it before any
candidate is even created, let alone leased), and it is not a real host.

## Running it

Build once from the repository root:

```sh
dub build --compiler=ldc2 --build=release
```

Then, against a fixture server bound at `http://127.0.0.1:<port>` (the real
checker below picks an ephemeral port and substitutes it for you):

```sh
./scrubbed crawl \
  --seed http://127.0.0.1:<port>/index.html \
  --corpus-dir /tmp/scrubbed-crawl-example \
  --max-pages 10 --max-pages-per-host 10 --max-depth 3 \
  --concurrency 2 --min-host-delay-ms 10 --scope allowed-domain
```

Produces `/tmp/scrubbed-crawl-example/{raw/,manifest.jsonl,frontier.sqlite3}`
-- five content-addressed raw shards, five manifest lines, and a durable
SQLite frontier recording the completed crawl.

### `--min-host-delay-ms 10`: a local-only override, never a production value

`crawl`'s real network-facing default is `--min-host-delay-ms 3000` (3
seconds between requests to the same host) -- a genuinely polite default for
crawling a real, shared web server. Against a fixture target that only this
checker's own process talks to, on loopback, that default would make this
example's five-page crawl take over ten seconds for no protective benefit
whatsoever, so this example explicitly overrides it down to 10ms. **This is
a local-fixture-only override.** Do not copy `--min-host-delay-ms 10` (or
anything close to it) into a real crawl against a real host -- see `crawl
--help`'s own default and this project's crawl documentation for why 3000ms
is the real recommended floor.

### `--scope allowed-domain`: the discovery boundary this example proves

`--scope allowed-domain` (the real CLI default) admits a discovered link only
when its exact origin is in the allow-list -- which `effects.crawl_cli`
defaults to exactly the seeds' own origins when no `--allowed-origin` is
given. Since every seed here is `http://127.0.0.1:<port>`, that is the only
admitted origin, and `https://blog.external-example.test/feed` -- a
different origin entirely -- is excluded at discovery time, before any
candidate for it is ever created. `check.d` proves this concretely: the
resulting manifest never contains a single reference to
`external-example`, and the fixture server (which is not even the
target `blog.external-example.test` would resolve to) never receives a
request for it either.

## What `crawl` does NOT do

Per `crawl --help`'s own text (verified verbatim against the real compiled
binary's help output in `check.d`, not just this repository's source):

> Fetch, discover links, and save raw HTML with a concurrent, resumable
> frontier. Fetch + discover + save raw only: no mojibake repair, no
> metadata/main-content/PII stages. Use 'clean-web-document' as a separate
> later pass over the raw output.

`check.d` proves this concretely, not just by quoting the help text: the raw
`about.html` shard `crawl` saves still contains the literal, unrepaired
`"FranÃ§ois"` mojibake byte sequence -- byte-for-byte identical to the
fixture site's own source file. A separate, later pass with the sealed
`clean-web-document/v1` preset (documented in
[`examples/pipelines/clean-web-document/`](../clean-web-document/), which
this example cross-references rather than duplicates -- its own fixtures and
corpus are untouched by this ticket) repairs it:

```sh
./scrubbed clean-web-document \
  --input /tmp/scrubbed-crawl-example/raw/<about.html's content hash> \
  --output /tmp/scrubbed-crawl-cleaned/about.txt
```

(`check.d` copies the raw shard to a `.html`-suffixed path first, matching
how a real downstream user would name it, since `clean-web-document` mirrors
its input's own filename to its output.)

## Resumability: which proof this example uses

The acceptance criteria for this example allow either (a) a real
interrupt-and-resume simulation, or (b) at minimum, proving a second full run
against the same `--corpus-dir`/`--db` is a correct no-op. **This example
uses (b): idempotent re-run.** Reliably killing the real shipping binary at a
precise mid-fetch moment from an external checker process is high-effort and
inherently flaky (exact timing against a process this checker does not
control), and `effects.crawl_orchestrator` already carries its own dedicated,
deterministic unit-level proof of exactly the interrupt-and-resume scenario
(`recoverOrphanedLeases`, exercised by that module's own "Resumability proof
#2" unittest: a lease is taken and the process handle is dropped without
`finish()`, simulating a kill, then a fresh handle recovers the orphaned
lease and completes the crawl with zero extra fetches). Re-proving that exact
mechanism end-to-end through this example's checker would duplicate existing,
already-rigorous coverage without adding real confidence.

What this example's `check.d` proves instead, end to end against the real
release binary: running the identical `crawl` command a second time against
the already-fully-drained `--corpus-dir`/`--db`

- exits 0 and reports `attempts=0 completed=0` (every seed comes back
  `duplicate`, nothing is re-leased),
- fetches nothing further from the fixture server (every page's hit count
  stays exactly 1),
- appends no new lines to `manifest.jsonl`, and
- leaves the durable `frontier.sqlite3` counts (`pages`/`completed`)
  unchanged.

## Reproduce the checked results

The release-active D checker starts the loopback-only fixture server,
verifies its bound address and that it is unreachable from a non-loopback
local address (a real failed connect attempt, not just a source-code
assertion), validates the manifest and its required negative mutants, runs
the real shipping binary through the full recipe above (twice, to prove
idempotent resumability), diffs the exact discovered-page set/paths/depths/
provenance against the pinned golden, confirms the raw bytes are byte-for-
byte unrepaired, runs the follow-on `clean-web-document` contrast, and
finally stops the fixture server and proves the port was genuinely released
(a fresh bind to the identical port succeeds immediately afterward).

```sh
ldc2 -O3 -release -preview=dip1000 -i -Isource \
  -of=.dub/crawl-check examples/pipelines/crawl/check.d \
  third_party/sqlite/sqlite3.o
.dub/crawl-check ./scrubbed
```

(This checker imports `effects.sqlite_frontier` directly, to reopen and
inspect the durable frontier database after each run -- unlike a checker
that only imports pure-D modules, it must also link the `third_party/sqlite/
sqlite3.o` object file `dub build` already produces; build `scrubbed` at
least once first so that object file exists.)

## Disclosed, unsupported limitations

- Five pages is a deliberately tiny fixture graph for a fast, deterministic
  example -- not a demonstration of `crawl` at any real scale.
- `--min-host-delay-ms 10` and `--scope allowed-domain` with no extra
  `--allowed-origin` are this example's own recipe choices for a
  single-origin loopback target; a real crawl over multiple real hosts needs
  its own considered `--min-host-delay-ms`, `--scope`, and
  `--allowed-origin` values.
- This example's resumability proof is idempotent-rerun, not a real
  interrupt-and-resume simulation -- see "Resumability" above for why, and
  see `effects.crawl_orchestrator`'s own unit tests for the dedicated
  interrupt/orphaned-lease proof.
- The fixture server's "unreachable from outside 127.0.0.1" proof is
  best-effort: it depends on the environment having a real, routable,
  non-loopback local address to attempt a connect from. In a fully offline
  sandbox with none, `check.d` falls back to the direct, deterministic bound-
  address inspection alone (which does not depend on the environment at
  all) and says so.
