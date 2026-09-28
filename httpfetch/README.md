# HttpFetch

Bounded, injection-safe, cancellable D HTTP(S) fetch: one call, one fetch.
No shared connection pool, no persistent handle across calls.

## Headline API: `fetchHttp`

`httpfetch.http_fetch` exposes one entry point:

```d
import httpfetch.http_fetch;

FetchOutcome outcome = fetchHttp(FetchRequest(url));
```

`FetchRequest.url` is an `httpfetch.web_url.WebUrl` — a URL-identity type
that restricts the scheme to `http`/`https` and rejects embedded userinfo
credentials at construction, so a `FetchRequest` can never carry
`user:pass@host`.

Other request fields:

- `ifNoneMatch` — sent as `If-None-Match`.
- `resolveEntries` (`host:port:address`) — pins a connection target's
  address via `CURLOPT_RESOLVE`. Pins the target only; never weakens
  verification.
- `caFile` — trusts an *additional* CA bundle via `CURLOPT_CAINFO`. Changes
  which store is checked, never disables the check.
- `shardRoot` — enables content-addressed body persistence.
- `limits` (`FetchLimits`) — see [Caps](#caps-fetchlimits).
- `shouldCancel` — a cooperative cancellation delegate, checked on libcurl's
  progress callback.

Every request sends a fixed `User-Agent` identifying the caller; see the
module doc comment in `source/httpfetch/http_fetch.d` for the exact string.

### Outcome

`FetchOutcome` is either a `FetchEvidence` (success) or a `FetchFailure`
(failure).

`FetchEvidence` carries `requestedUrl`, `finalUrl`, `redirectChain`,
`status`, `notModified`, selected response headers (`contentType`,
`contentEncoding`, `etag`, `lastModified`, `retryAfter`,
`contentLengthHeader`), a SHA-256 `bodyDigest`, `bodyBytes`/`bodyStored`/
`shardPath`, and `startedAt`/`finishedAt`.

`FetchFailure` carries only a `FetchFailureReason` enum, a numeric
`curlCode`, and a numeric `httpStatus` — no string field, so it structurally
cannot carry a URL, header, or body byte. `.category()` classifies each
reason as `retryable` or `permanent`. See the module doc comment for the
full reason table.

### Caps (`FetchLimits`)

`connectTimeoutMs`, `totalTimeoutMs`, `maxRedirects`, `maxHeaderBytes`,
`maxEncodedBytes`, `maxDecodedBytes`, `maxConcurrentFetches`. Every cap
rejects with a typed, content-free `FetchFailure` — never a raw libcurl
error string, and never the header/body bytes that triggered it.

### TLS

Verification is on unconditionally: `CURLOPT_SSL_VERIFYPEER=1` and
`CURLOPT_SSL_VERIFYHOST=2` are set on every request, in one place, with no
request field, flag, or internal code path that can turn either off.

## Secondary API: `httpfetch.curl_ffi`

`httpfetch.curl_ffi` declares the raw `extern(C)` libcurl entry points this
package's `fetchHttp` implementation uses (easy/multi handle lifecycle, the
`CURLOPT_*`/`CURLINFO_*` values it sets or reads). It's available for
callers who want low-level libcurl access, but it's secondary — reach for
`httpfetch.http_fetch`'s `fetchHttp` first.

## Platform support

Verified today: **macOS arm64 only**, against the host-provided dynamic
`libcurl` (`/usr/lib/libcurl.4.dylib`). Both `curl_ffi.d` and `web_url.d`'s
lexbor-backed URL parser gate on `version (OSX) { version (AArch64) {} }`
and fail to compile elsewhere.

libcurl's `CURLoption`/`CURLINFO` enum values are part of curl's own
long-stable public ABI and ship on effectively every Linux distribution
too, so this platform gate is very likely overly conservative — but that
has not been proven on real Linux hardware from this package. Linux/other-
platform readiness tracks the upstream `scrubbed` project's own
cross-platform libcurl findings (scrubbed issue #353) rather than being
independently re-solved here.

## Build

```sh
cd httpfetch
dub build
dub test
```

The build vendors and statically links
[Lexbor](https://github.com/lexbor/lexbor)'s WHATWG URL parser (used by
`httpfetch.web_url`) via a `preBuildCommands` CMake step — see
`THIRD_PARTY_NOTICES.md` for its license. Everything else is Phobos plus the
host-provided dynamic `libcurl`.

This package has zero dependency on `scrubbed`'s own `dub.json`/`source/`
tree; it builds and tests entirely standalone.

## Not yet published

This package is not published to code.dlang.org yet — that's a separate,
later decision.
