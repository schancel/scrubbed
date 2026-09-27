# HTTP(S) fetch (`effects.http_fetch`)

One call, one bounded fetch: no shared connection pool, no persistent handle
across calls.

**Not yet wired in.** Nothing in `source/cli.d`, `composition/**`, or
`stages/**` imports this module — that wiring is a separate, later slice.

- Production module: `source/effects/http_fetch.d`, `source/effects/curl_ffi.d`.
- Feasibility record: [http-fetch-evaluation.md](http-fetch-evaluation.md) —
  the earlier loopback probe (verdict `ADOPT_DYNAMIC`) this slice turns into
  production code.
- Module-boundary rules: [architecture.md](architecture.md).

## Shape

- `curl_ffi.d` declares exactly the `extern(C)` libcurl entry points the
  evaluation probe exercised (easy/multi handle lifecycle, the
  `CURLOPT_*`/`CURLINFO_*` values it set or read). Gated to macOS arm64 only
  — the same `version (OSX) { version (AArch64) {} else static assert(0) }`
  pattern `effects/lexbor_ffi.d` uses, matching the platform this build
  already ships.
- `http_fetch.d` exposes one entry point: `fetchHttp(FetchRequest) ->
  FetchOutcome`.

## Request

`FetchRequest.url` is an `effects.web_url.WebUrl` — the same URL-identity
type used elsewhere in this repo. `WebUrl` already restricts the scheme to
`http`/`https` and rejects embedded userinfo credentials at construction, so
a `FetchRequest` can never carry `user:pass@host`: that class of leak is
prevented one layer below this module.

Other fields:

- `ifNoneMatch` — sent as `If-None-Match`; see [Conditional
  retrieval](#conditional-retrieval).
- `resolveEntries` (`host:port:address`) — pins a connection target's
  address via `CURLOPT_RESOLVE`. Pins the target only; never weakens
  verification.
- `caFile` — trusts an *additional* CA bundle via `CURLOPT_CAINFO`. Changes
  which store is checked, never disables the check.
- `shardRoot` — enables content-addressed body persistence; see
  [Persistence](#persistence).
- `limits` (`FetchLimits`) — see [Caps](#caps-fetchlimits).
- `shouldCancel` — a cooperative cancellation delegate, checked on libcurl's
  progress callback.

**Every request sends a fixed `User-Agent`:**

```
scrubbed/0.1 (+https://github.com/schancel/scrubbed)
```

This shipped in #307 after #305's review found real corpus crawls against
Wikipedia coming back HTTP 403 for sending no `User-Agent` at all. It's
honest crawler self-identification — name/version plus a URL for more info,
the same pattern as Googlebot — never a spoofed browser string. It's a fixed
literal rather than a derived release version, since `dub.json` carries no
`version` field today.

## Outcome

`FetchOutcome` is either a `FetchEvidence` (success) or a `FetchFailure`
(failure) — the same discriminated-outcome shape `WebUrlOutcome` and
`HtmlOutcome` already use in this repo.

`FetchEvidence` carries:

- `requestedUrl`, `finalUrl`, `redirectChain` — the chain is the
  intermediate hop targets, excluding both endpoints. It's reconstructed by
  resolving each hop's captured `Location` header against the previous hop's
  URL (`effects.web_url.resolveWebUrl`, the same relative-URL resolution
  used for HTML-discovered links), while libcurl itself follows the
  redirects, enforces `CURLOPT_MAXREDIRS`, and applies the
  `CURLOPT_REDIR_PROTOCOLS_STR` allowlist.
- `status`, `notModified` (`status == 304`).
- Selected response headers — `contentType`, `contentEncoding`, `etag`,
  `lastModified`, `retryAfter`, `contentLengthHeader` — read only from the
  *final* hop's response (a fresh status line resets what's tracked), never
  from an intermediate redirect response.
- `bodyDigest` — a SHA-256 digest via the existing `crypto.sha256.sha256Of`
  facade, not a reimplementation.
- `bodyBytes`, `bodyStored`, `shardPath` — `shardPath` is populated only
  when `shardRoot` was set and the body was persisted.
- `startedAt` / `finishedAt` (`std.datetime.SysTime`).

`FetchFailure` carries only a `FetchFailureReason` enum, a numeric
`curlCode`, and a numeric `httpStatus` — no string field, so it structurally
cannot carry a URL, header, or body byte. `.category()` classifies each
reason as `retryable` or `permanent`:

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
| `decodedBodyCapExceeded` | permanent | Decoded body bytes exceeded `maxDecodedBytes` (also the compression-bomb defense). |
| `tlsVerificationFailed` | permanent | Certificate or hostname verification failed. |
| `cancelled` | permanent | The caller's `shouldCancel` delegate returned `true`. |
| `invalidResponse` | permanent | A captured redirect target could not be resolved to a valid `WebUrl`. |

**Known taxonomy limitation, by design:** libcurl reports connect-timeout and
total-timeout exhaustion as the same `CURLE_OPERATION_TIMEDOUT` result. The
evaluation probe only told them apart by measuring wall-clock time from
outside — a test technique, not a production signal — so `fetchHttp` doesn't
fabricate a distinction libcurl doesn't actually expose: both caps collapse
to the single `timedOut` reason. `connectTimeoutMs` and `totalTimeoutMs`
remain two independently enforced libcurl options; only the *failure label*
is shared. The seam checker's `checkConnectTimeout`/`checkTotalTimeout`
still prove both caps independently, by wall-clock measurement, the same way
the evaluation probe did.

## Caps (`FetchLimits`)

`connectTimeoutMs`, `totalTimeoutMs`, `maxRedirects`, `maxHeaderBytes`,
`maxEncodedBytes`, `maxDecodedBytes`, `maxConcurrentFetches`.

- Every cap rejects with a typed, content-free `FetchFailure` — never a raw
  libcurl error string, and never the header/body bytes that triggered it.
- The encoded/decoded/header caps mirror the evaluation probe's
  already-measured behavior: libcurl callbacks are chunked, so a cap can
  accept a bounded *overshoot* within one already-in-flight chunk (a
  boundary can reject a chunk before copying it, but can't un-receive bytes
  already handed to the callback) — not byte-perfect cessation at the exact
  configured threshold.
- `maxConcurrentFetches` is enforced with a single process-wide atomic
  counter, checked and incremented before any libcurl handle is created and
  released on every exit path. Over-cap calls are rejected immediately
  (`concurrencyLimit`), never queued.

## TLS

Verification is on unconditionally: `CURLOPT_SSL_VERIFYPEER=1` and
`CURLOPT_SSL_VERIFYHOST=2` are set on every request, in one place, with no
request field, flag, or internal code path that can turn either off.

The only TLS-related request fields:

- `caFile` (`CURLOPT_CAINFO`) — trusts an *additional* CA bundle. Changes
  which store is checked; never disables the check.
- `resolveEntries` (`CURLOPT_RESOLVE`) — pins a connection target's address.
  Doesn't affect which certificate name is checked against the connection's
  hostname.

## Persistence

`FetchRequest.shardRoot`, when set, persists the raw (decoded) body under
`<shardRoot>/<lowercase-hex-sha256>`, reusing
`effects.document_shards`'s bounded POSIX publication *mechanics*: an
unpredictably-named temporary file created with
`O_CREAT|O_EXCL|O_NOFOLLOW`, `fsync`, close, then a hard link into the
digest-named destination — never a rename over an existing path.

One decision here is new, not reused: a losing `link()` that fails with
`EEXIST` is trusted as proof that identical content is already durably
stored under that digest, rather than treated as an error. This relies on
SHA-256's collision resistance ("hash equality implies content equality"),
standard practice for content-addressed stores — but it's a new trust
decision for *this* module, not `effects.document_shards`'s existing
behavior: `DocumentShardWriter.publish` fails closed on *any* nonzero
`link()` result, including `EEXIST`; `OverlayWriter.publish` uses `rename()`
with an explicit target-identity guard instead. This is a new, narrow
read/write path within this slice's scope, not a change to
`effects.document_shards` itself.

## Conditional retrieval

`FetchRequest.ifNoneMatch`, when set, is sent as `If-None-Match`. A `304`
response is a *success* (`FetchOutcome.succeeded == true`) with
`evidence.notModified == true` and `evidence.bodyBytes == 0` — a cache hit
is not a fetch failure.

## Re-proof

`experiments/http_fetch_seam/check.d` is a new, separate checker (the
earlier `experiments/http_fetch/check.d` probe is untouched historical
evidence) that calls `effects.http_fetch.fetchHttp` directly, reusing the
probe's loopback HTTP-server and ephemeral openssl-backed TLS-fixture idiom.
It proves:

- basic fetch, redirect chain/loop bound, the protocol allowlist on a
  redirect target;
- connect timeout distinct from total timeout (by wall-clock measurement,
  same technique the probe used);
- header/encoded/decoded caps, including the gzip compression-bomb case;
- cancellation and conditional retrieval;
- the retryable-vs-permanent category mapping and bounded concurrency
  enforcement;
- TLS verification (untrusted cert, hostname/SAN mismatch via a pinned
  loopback address, and a verified success);
- recovery after a failed fetch, credentials rejected at URL construction;
- content-free diagnostics with embedded secret-shaped canaries;
- a typed storage failure, and content-addressed persistence (including
  idempotent re-fetch of identical bytes).

Build it the same way the evaluation probe is built (see the comment at the
top of the checker file), after `dub build` has produced
`.dub/lexbor/liblexbor_static.a`.
