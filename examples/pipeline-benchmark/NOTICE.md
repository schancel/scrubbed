# NOTICE: third-party content in this directory

`examples/pipeline-benchmark/corpus/` permanently checks 20 real, unmodified,
third-party web pages into this repository's git history. Read this before
using, redistributing, or basing any decision on this directory.

## What this is

This corpus exists to give an external user a small, fixed, reproducible set
of real web pages to run `scrubbed clean-web-document` against and compare
with an equivalent Python tool chain (`ftfy` -> `trafilatura` -> `langdetect`
-> Presidio), documented in [`README.md`](README.md). It is one concrete,
disclosed comparison over one small corpus, not a claim of a canonical or
definitive "corpus cleaning benchmark" standard.

## Ownership and license: read this carefully

**None of the files in `corpus/` were authored by this project, and no
license grant from their original publishers is known to exist.** Copyright
in each page's content is held by its original publisher/author, not by this
project or its contributors. This directory does not claim any license over
those files, MIT or otherwise, and does not assert that redistribution here
is licensed. Per-file details (source URL, fetch date, SHA-256) are recorded
honestly in [`manifest.json`](manifest.json).

This is a **deliberate, disclosed, owner-accepted risk**, decided directly by
this repository's owner on 2026-09-27 in
[issue #315](https://github.com/schancel/scrubbed/issues/315): the owner was
told explicitly that permanently vendoring real third-party page content into
a public repository's git history is "a distinct, bigger legal call" than
this repository's existing test-fixture-licensing posture, and chose to
accept that risk knowingly rather than fetch the corpus transiently at
run time. If you fork, mirror, or otherwise redistribute this repository, you
are also redistributing this third-party content and inherit that same
posture and risk -- this notice does not transfer any right to you that the
original publishers did not already grant.

## This is a *different*, separate mechanism from issue #229's held-out corpus

This repository also contains
[`experiments/html_main_content/fetch_held_out.sh`](../../experiments/html_main_content/fetch_held_out.sh),
which fetches real third-party pages (via a pinned clone of the
`adbar/trafilatura` project, Apache-2.0 licensed) for test-only comparator
use. That script's own header is explicit: those pages are "never vendored
into git history and never shipped in the release binary/package." This
`examples/pipeline-benchmark/corpus/` directory reuses the *same 20 pinned
URLs* as its source list, but is a **new, separate, permanently-checked-in
mechanism** under its own, broader accepted risk (issue #315). Do not
conflate the two: `fetch_held_out.sh` is unmodified by this directory's
existence and remains transient-fetch-only for its own purpose.

## Corpus completeness: two different fetch methods, disclosed per file

The pinned URL list has 20 entries. As of the fetch date (2026-09-27), 6 of
those URLs have suffered real **link rot** since trafilatura's own eval
corpus was assembled: some pages have been taken down (HTTP 404), one domain
no longer resolves in DNS, and one domain now serves a TLS certificate for an
unrelated host. Named plainly, not euphemized: those 6 original pages are, as
far as this project could verify on the fetch date, gone from the live web.

For those 6, this corpus does not fall back to a web archive or invent
content. Instead it reuses `adbar/trafilatura`'s own bundled eval-corpus copy
of the same URL at the exact commit
(`1e31e3e9eb2e4f6fbfd4bc04355bc74005a780e6`) already pinned by
`experiments/html_main_content/fetch_held_out.sh` -- the same trust and
provenance source issue #229's own mechanism already relies on for these
exact pages, read here as a stored file instead of a now-dead live request.
This is still real, unmodified, third-party page content, just an older
snapshot rather than the page's current (nonexistent) live state.

Every artifact entry in [`manifest.json`](manifest.json) states which of the
two methods produced it (`"fetchMethod": "live"` or
`"fetchMethod": "trafilatura-pinned-cache"`), and the 6 cache-backfilled
entries additionally cite the exact repository path the bytes came from. See
`manifest.json`'s `fetchOutcomeSummary` and `linkRotFindings` fields for the
full detail on each of the 6.

## Removal

If you are a rights holder of any page in `corpus/` and want it removed,
contact the repository owner (see the repository's main README) with the
file path from `manifest.json`.
