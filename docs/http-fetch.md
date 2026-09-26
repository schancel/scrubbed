# Production HTTP(S) fetch (`effects.http_fetch`)

Status: a callable, unintegrated effects-layer capability. Nothing in
`source/cli.d`, `composition/**`, or `stages/**` imports it yet; that wiring
is a separate, later slice. This document describes the production module;
see [`docs/http-fetch-evaluation.md`](http-fetch-evaluation.md) for the
earlier loopback capability/licensing/packaging evaluation
(`experiments/http_fetch/check.d`, verdict `ADOPT_DYNAMIC`) that this slice
turns into production code, and
[`docs/architecture.md`](architecture.md) for the module-boundary rules this
slice was built inside.

## Shape

- `source/effects/curl_ffi.d`: narrow `extern(C)` declarations for exactly
  the host dynamic `libcurl.4.dylib` entry points the evaluation probe
  exercised (easy/multi handle lifecycle, the `CURLOPT_*`/`CURLINFO_*`
  values the probe set or read, `curl_easy_setopt`/`curl_easy_perform`/
  `curl_easy_getinfo`). Gated with the same
  `version (OSX) { version (AArch64) {} else static assert(0, ...); } else
  static assert(0, ...);` pattern `effects/lexbor_ffi.d` uses: macOS arm64
  only, matching the platform this build already ships.
- `source/effects/http_fetch.d`: `FetchRequest` in, `FetchOutcome` out. One
  call performs one bounded fetch; there is no shared connection pool and no
  persistent handle across calls.

## `fetchHttp(FetchRequest) -> FetchOutcome`

`FetchRequest.url` is an `effects.web_url.WebUrl` — the same URL-identity
type `effects.web_url` already provides elsewhere in this repo, reused here
rather than inventing a second URL type. `WebUrl` already restricts the
scheme to `http`/`https` and rejects a URL with embedded userinfo
credentials at construction time, so a `FetchRequest` can never carry
`user:pass@host` credentials in its URL: that class of leak is structurally
prevented one layer below this module.

`FetchOutcome` is either a `FetchEvidence` (on success) or a `FetchFailure`
(on failure), the same discriminated-outcome shape `effects.web_url.WebUrlOutcome`
and `effects.html_tree.HtmlOutcome` already use in this repo.

`FetchEvidence` carries:

- `requestedUrl`, `finalUrl` (both `WebUrl`), and `redirectChain` (the
  intermediate hop targets in between, excluding both endpoints). The chain
  is reconstructed by resolving each hop's captured `Location` header
  against the previous hop's URL with `effects.web_url.resolveWebUrl` — the
  same relative-URL resolution this repo already uses for HTML-discovered
  links — while libcurl itself performs the actual following, its
  `CURLOPT_MAXREDIRS` cap, and its `CURLOPT_REDIR_PROTOCOLS_STR` allowlist.
- `status`, `notModified` (`status == 304`).
- Selected response headers: `contentType`, `contentEncoding`, `etag`,
  `lastModified`, `retryAfter`, `contentLengthHeader`. These are read only
  from the *final* hop's response headers (a fresh status line resets what
  is tracked), not from any intermediate redirect response.
- `bodyDigest`: a SHA-256 digest computed with the existing
  `crypto.sha256` facade (`crypto.sha256.sha256Of`) — not a reimplementation.
- `bodyBytes`, `bodyStored`, `shardPath`: `shardPath` is populated only when
  `FetchRequest.shardRoot` is set and the body was persisted (see below).
- `startedAt`/`finishedAt` (`std.datetime.SysTime`).

`FetchFailure` carries only a `FetchFailureReason` enum, a numeric
`curlCode`, and a numeric `httpStatus` — no string field exists on it, so it
cannot carry a URL, header, or body byte by construction. `.category()`
classifies each reason as `retryable` or `permanent`:

| Reason | Category | Meaning |
| --- | --- | --- |
| `concurrencyLimit` | retryable | The process-wide concurrent-fetch cap was already full; no libcurl work was attempted. |
| `timedOut` | retryable | Either `connectTimeoutMs` or `totalTimeoutMs` was exceeded. |
| `transportError` | retryable | A generic libcurl failure (DNS, connection refused/reset, etc.). |
| `storageFailure` | retryable | The fetch succeeded but persisting the body content-addressably failed. |
| `tooManyRedirects` | permanent | The redirect chain exceeded `maxRedirects`. |
| `protocolNotAllowed` | permanent | A (possibly redirected-to) URL was not `http`/`https`. |
| `headerCapExceeded` | permanent | Cumulative response header bytes exceeded `maxHeaderBytes`. |
| `encodedBodyCapExceeded` | permanent | Wire (pre-decode) bytes exceeded `maxEncodedBytes`. |
| `decodedBodyCapExceeded` | permanent | Decoded body bytes exceeded `maxDecodedBytes` (this is also the compression-bomb defense). |
| `tlsVerificationFailed` | permanent | Certificate or hostname verification failed. |
| `cancelled` | permanent | The caller's `shouldCancel` delegate returned `true`. |
| `invalidResponse` | permanent | A captured redirect target could not be resolved to a valid `WebUrl`. |

**Known taxonomy limitation, by design, not oversight:** libcurl reports
connect-timeout and total-timeout exhaustion as the same
`CURLE_OPERATION_TIMEDOUT` result. The evaluation probe only told them apart
by measuring wall-clock time from outside the probe — a test technique, not
a production signal. `fetchHttp` does not fabricate a distinction the
libcurl API does not actually expose, so both caps collapse to the single
`timedOut` reason. `FetchLimits.connectTimeoutMs` and `.totalTimeoutMs`
remain two independently enforced libcurl options; only the *failure label*
is shared. The seam checker's `checkConnectTimeout`/`checkTotalTimeout`
still prove both caps independently, by wall-clock measurement, the same
way the evaluation probe did.

## Caps (`FetchLimits`)

`connectTimeoutMs`, `totalTimeoutMs`, `maxRedirects`, `maxHeaderBytes`,
`maxEncodedBytes`, `maxDecodedBytes`, `maxConcurrentFetches`. Every cap
rejects with a typed, content-free `FetchFailure` — never a raw libcurl
error string, and never the header/body bytes that triggered it. The
encoded/decoded/header caps mirror the evaluation probe's already-measured
behavior: a cap can accept a bounded *overshoot* within one already-in-flight
chunk (libcurl callbacks are chunked; a boundary can reject a chunk before
copying it, but cannot un-receive bytes already handed to the callback), not
byte-perfect cessation at the exact configured threshold.

`maxConcurrentFetches` is enforced with a single process-wide atomic
counter, checked and incremented before any libcurl handle is created and
released on every exit path. Over-cap calls are rejected immediately
(`concurrencyLimit`) rather than queued.

## TLS

TLS verification is on unconditionally: `CURLOPT_SSL_VERIFYPEER=1` and
`CURLOPT_SSL_VERIFYHOST=2` are set on every request, in one place, with no
request field, flag, or internal code path that can turn either off. The
only TLS-related request fields are:

- `caFile` (`CURLOPT_CAINFO`): trusts an *additional* CA bundle. This
  changes which store is checked against; it never disables the check.
- `resolveEntries` (`CURLOPT_RESOLVE`, `host:port:address`): pins a
  connection target's address, e.g. to avoid a second DNS lookup or to
  pin against DNS rebinding. It does not affect which certificate name is
  checked against the connection's hostname.

## Persistence

`FetchRequest.shardRoot`, when set, persists the raw (decoded) body under
`<shardRoot>/<lowercase-hex-sha256>`, reusing
`effects.document_shards`'s bounded POSIX publication *mechanics*: an
unpredictably-named temporary file created with
`O_CREAT|O_EXCL|O_NOFOLLOW`, `fsync`, close, then a hard link into the
digest-named destination (never a rename over an existing path).

One decision here is new, not reused: a losing `link()` that fails with
`EEXIST` is trusted as proof that identical content is already durably
stored under that digest, rather than treated as an error. This relies on
SHA-256's collision resistance ("hash equality implies content equality"),
which is standard practice for content-addressed stores, but it is a new
trust decision for *this* module — it does not match
`effects.document_shards`'s existing behavior. `DocumentShardWriter.publish`
fails closed on any nonzero `link()` result, including `EEXIST`
(`require(link(...) == 0, "immutable shard already exists or link failed")`,
without inspecting `errno`); `OverlayWriter.publish` uses `rename()` with an
explicit `checkReplaceTarget` guard, a different mechanism entirely. Neither
existing writer trusts an `EEXIST` race as identical-content proof. This is
a new, narrow read/write path within the allowed scope of this slice, not a
change to `effects.document_shards` itself.

## Conditional retrieval

`FetchRequest.ifNoneMatch`, when set, is sent as `If-None-Match`. A `304`
response is a success (`FetchOutcome.succeeded == true`) with
`evidence.notModified == true` and `evidence.bodyBytes == 0`, not a
`FetchFailure` — a cache hit is not a fetch failure.

## What re-proves this against production code

`experiments/http_fetch_seam/check.d` is a new, separate checker (the
earlier `experiments/http_fetch/check.d` probe is untouched historical
evidence) that calls `effects.http_fetch.fetchHttp` directly, reusing the
probe's loopback HTTP-server and ephemeral openssl-backed TLS-fixture idiom.
It re-proves: basic fetch, redirect chain/loop bound, the protocol allowlist
on a redirect target, connect timeout distinct from total timeout (by
wall-clock measurement, same technique the probe used), header/encoded/
decoded caps (including the gzip compression-bomb case), cancellation,
conditional retrieval, the retryable-vs-permanent category mapping, bounded
concurrency enforcement, TLS verification (untrusted cert, hostname/SAN
mismatch via a pinned loopback address, and a verified success), recovery
after a failed fetch, credentials rejected at URL construction, content-free
diagnostics with embedded secret-shaped canaries, a typed storage failure,
and content-addressed persistence (including idempotent re-fetch of
identical bytes).

Build it the same way the evaluation probe is built (see the comment at the
top of the checker file), after `dub build` has produced
`.dub/lexbor/liblexbor_static.a`.
