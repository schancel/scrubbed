# `crawl` example: a bounded crawl against a local fixture server

Demonstrates the top-level `scrubbed crawl` command (issue #329) end to end
against a small, synthetic, 5-page fixture site served by a real HTTP server
this example's own checker starts and stops -- bound to `127.0.0.1` only,
never a real external network endpoint. Corpus and fixtures are in
[`examples/corpus/crawl/`](../../corpus/crawl/); exact provenance, media
types, licenses, intended outcomes, and SHA-256 digests are in that
directory's [`manifest.json`](../../corpus/crawl/manifest.json).

Build once from the repository root:

```sh
dub build --compiler=ldc2 --build=release
```

## Running it yourself

`crawl` takes URL seeds, not a local file/directory, so trying this example
by hand means serving the fixture pages yourself first. The simplest way is
Python's built-in server, from the fixture directory:

```sh
cd examples/corpus/crawl/inputs/site
python3 -m http.server 8000 --bind 127.0.0.1
```

Then, from the repository root, in another terminal:

```sh
./scrubbed crawl \
  --seed http://127.0.0.1:8000/index.html \
  --corpus-dir /tmp/scrubbed-crawl-demo \
  --max-pages 10 --max-pages-per-host 10 --max-depth 3 \
  --concurrency 2 --min-host-delay-ms 10 --scope allowed-domain
```

`--min-host-delay-ms 10` is a **local-only override for this demo**, not a
production recommendation: the real network-facing default is `3000`ms (see
`scrubbed crawl --help`), chosen for politeness against real remote hosts.
Talking to a fixture server on your own machine has no such concern, so this
example lowers it to keep the recipe fast; a real crawl against the public
internet should use the default (or something even more conservative), never
this value.

This should discover and fetch exactly 5 pages (see "The fixture site"
below), write their raw bytes into `/tmp/scrubbed-crawl-demo/raw/` under
content-addressed (SHA-256) filenames, append one line per fetch to
`/tmp/scrubbed-crawl-demo/manifest.jsonl`, and persist frontier state to
`/tmp/scrubbed-crawl-demo/frontier.sqlite3`.

## The fixture site

Five pages, authored for this ticket (issue #509), with a real internal link
graph and one deliberately out-of-scope external-looking link:

```
index.html (depth 0, the seed)
 |-- about.html (depth 1)
 |    `-- team.html (depth 2)
 |         `-- resources.html (depth 3 -- exactly this recipe's --max-depth)
 |-- contact.html (depth 1, a terminal leaf: no outbound links)
 `-- https://blog.external-example.test/feed  (a different origin entirely --
      must never be admitted or fetched under --scope allowed-domain)
```

Every page also links back to `index.html` via its own nav bar; the frontier
correctly treats each of those as a harmless duplicate of the already-
admitted seed, not a second admission. `resources.html` sits exactly at
`--max-depth 3`: it is itself discovered (proving discovery does not stop one
hop too early), but even though it has no outbound links of its own, this
also proves discovery would correctly stop expanding a depth-3 page rather
than merely happening to have nothing further to discover.

The external link is never even attempted: `effects.html_discovery`'s scope
check runs before a candidate is ever admitted to the frontier, so a crawl
that ignored `--scope` would have to attempt a genuine DNS lookup against
`blog.external-example.test` -- and this example's own checker proves that
never happens (an exact 5-line `manifest.jsonl`, not 6, whether the leaked
attempt would have succeeded or failed).

`index.html`'s title carries a literal `&amp;` HTML entity, and `about.html`
carries the same mojibake byte pattern already established in
[`examples/corpus/clean-web-document`](../clean-web-document/) and
[`examples/corpus/quickstart`](../../corpus/quickstart/) (`FranÃ§ois`, UTF-8
`François` misread as Latin-1/CP1252) -- both left completely untouched by
`crawl` itself. See "What `crawl` does and does not do" below.

## What `crawl` does and does not do

Per `scrubbed crawl --help`'s own words: *"Fetch, discover links, and save
raw HTML with a concurrent, resumable frontier. Fetch + discover + save raw
only: no mojibake repair, no metadata/main-content/PII stages."* This
example's checker proves that concretely, not just by quoting the help text:
the raw shard bytes it fetches are byte-for-byte identical to the fixture
site's own source files, entities and mojibake fully intact.

Cleaning is a separate, later pass. This example demonstrates that directly
by running the sealed `clean-web-document/v1` preset (issue #503; see
[`examples/pipelines/clean-web-document/`](../clean-web-document/), whose own
fixtures are cross-referenced here rather than duplicated) over the raw
`about.html` bytes `crawl` just fetched: the mojibake that was still present
going in (`FranÃ§ois`) is repaired coming out (`François`).

## Resumability: proven as an idempotent second run

This example proves a second full `crawl` run against the identical
`--corpus-dir`/`--db` is a correct no-op, not interrupt-and-resume
mid-fetch. That is a deliberate scope choice: reliably killing the real
shipping binary partway through a fetch from an external checker process is
high-effort and flaky, whereas `effects.crawl_orchestrator`'s own existing
unit-level tests already directly exercise exactly that scenario (a lease
orphaned by a simulated process kill, recovered on the next run -- see
`recoverOrphanedLeases` and its own unittest there).

What this example proves instead, end to end against the real binary: the
second run reports `attempts=0`/`completed=0` (nothing is re-attempted), the
fixture server sees not one additional real request for any page, and
`manifest.jsonl` (append-only) gains zero new lines. `frontier.sqlite3` is
reopened directly and its own durable counts are asserted unchanged across
both runs.

## The fixture server

The checker's own fixture HTTP server is a small `std.socket`-based static
responder -- one accept thread plus one daemon handler thread per
connection -- modeled directly on the identical real-loopback-server pattern
already established and reviewed in this codebase
(`effects.crawl_orchestrator`'s own `TestServer` unittest helper, and
`effects.http_fetch`'s own unittest loopback listeners), rather than a new
invention or a checked-in script in another language. It is bound to
`127.0.0.1` only -- verified directly from the live socket, never assumed --
and the checker further proves it is unreachable from a real, non-loopback
local address before ever starting a crawl against it.

## Reproduce the checked results

The release-active D checker validates the manifest and its required
negative mutants, starts the loopback-only fixture server, runs the full
recipe above against the real shipping binary from a clean temporary
directory (never the dev tree), and checks the raw output, `manifest.jsonl`,
and `frontier.sqlite3` against the pinned expected discovered-page set in
[`examples/corpus/crawl/expected/discovered-pages.json`](../../corpus/crawl/expected/discovered-pages.json).
It imports `effects.sqlite_frontier` directly (to reopen and inspect the
durable frontier database), which pulls in this project's embedded sqlite3 C
sources the same way the main `scrubbed` target does -- so, unlike a checker
that only imports pure-D modules, this one also links the object file
`dub build` already produced at `third_party/sqlite/sqlite3.o`:

```sh
ldc2 -O3 -release -preview=dip1000 -i -Isource \
  -of=.dub/crawl-check examples/pipelines/crawl/check.d \
  third_party/sqlite/sqlite3.o
.dub/crawl-check ./scrubbed
```
