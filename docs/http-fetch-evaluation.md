# Host libcurl HTTP-fetch evaluation

Status: evidence only. This does not add a production dependency, select a
fetch policy, or make a package/release claim. Production adoption remains a
separate owner decision and contract.

## Observed host and dependency identity

The probe was built and run on 2026-09-24 on macOS 26.6.2 (build 25G83,
Darwin 25.6.0), arm64. The compiler was LDC 1.43.0 (DMD 2.113.0, LLVM
23.1.0), targeting `arm64-apple-darwin25.6.0`; Apple clang was 21.0.0.

The arm64 probe called the linked library's `curl_version()` and observed:

```text
libcurl/8.7.1 (SecureTransport) LibreSSL/3.3.6 zlib/1.2.12 nghttp2/1.68.1
```

Thus the demonstrated TLS backend is SecureTransport, with the runtime also
reporting LibreSSL 3.3.6; the demonstrated compression backend is zlib 1.2.12.
`curl-config --feature` reports SSL, MultiSSL, libz, HTTP2, AsynchDNS, and
`threadsafe`. It does not report brotli or zstd. `curl-config --protocols`
advertises many protocols, but the probe sets both the initial and redirect
protocol allowlists to exactly `http,https`.

An optimized probe is a Mach-O 64-bit arm64 executable. `otool -L` reports
these direct runtime links:

```text
/usr/lib/libcurl.4.dylib (compatibility 7.0.0, current 9.0.0)
/usr/lib/libSystem.B.dylib (compatibility 1.0.0, current 1356.0.0)
/usr/lib/libobjc.A.dylib (compatibility 1.0.0, current 228.0.0)
```

The Command Line Tools SDK 26.5 supplies `curl/curl.h` (SHA-256
`bc859632290c0495e45d80157ebb97bb296f7391d7efa054d127c7cf14469190`) and the
`libcurl.4.tbd` linker stub for x86_64 and arm64e macOS/Mac Catalyst; the OS
supplies the runtime library through the dyld shared cache. The stub SHA-256 is
`1b6d181ac7c9f13cbd270d8b1c81738ebefa45308baf53f82912b5f127006116`. The SDK header
identifies the license as SPDX `curl`, carries the upstream permission and
warranty notice, and points to upstream `COPYING`; that `COPYING` file is not
present beside the installed SDK header. This is license provenance, not
legal clearance or proof of the complete source corresponding to Apple's
binary. Homebrew metadata on this host offers keg-only formula `curl` 8.22.0,
but it is not installed and was neither linked nor tested. OpenSSL 3.6.4 was
used only as the loopback TLS fixture server and is not a dependency of the
probe executable.

## Demonstrated behavior

`experiments/http_fetch/check.d` creates a D HTTP server bound to
`127.0.0.1` and disables libcurl proxy use. It atomically creates an
unpredictable mode-0700 directory with `mkdtemp`, generates a one-day
certificate and private key there, starts `openssl s_server` bound to an
ephemeral `127.0.0.1` port, and removes the material after the run. The private
key is never committed. A deterministic injected failure after TLS-server
spawn proves the child is terminated and reaped and the directory removed;
cleanup is idempotent. A regression preplants the old predictable directory
shape with key/certificate symlinks and proves their sentinel target is
unchanged and the actual directory differs. No live or non-loopback request
is made.

The optimized run passed 23 checks:

| Boundary | Demonstrated result |
| --- | --- |
| HTTP and HTTPS | HTTP returned 200 and five decoded bytes. HTTPS returned 200 with peer and IP-host verification against the ephemeral CA fixture. The same self-signed endpoint without its CA and with its CA but a mismatched `mismatch.invalid` name both failed with `CURLE_PEER_FAILED_VERIFICATION` (60). `CURLOPT_RESOLVE` pins that mismatch name and ephemeral port to `127.0.0.1`, so the test neither depends on `localhost` special handling nor performs external DNS. Every `curl_easy_setopt` result is checked. An opt-in mutant that disables peer and host verification fails the untrusted-certificate regression (`expected=60 actual=0`). |
| Protocols | A direct `file:` request and an HTTP redirect to `file:` both failed with `CURLE_UNSUPPORTED_PROTOCOL` (1). HTTP remained usable. |
| Redirects | One relative redirect reached 200. A loop with `MAXREDIRS=2` failed with `CURLE_TOO_MANY_REDIRECTS` (47). |
| Timeouts | A response stall exceeded a 60 ms total timeout and failed with `CURLE_OPERATION_TIMEDOUT` (28). A loopback TCP peer that stalled the TLS handshake exceeded a 60 ms connect timeout while the total timeout was 1,000 ms and returned the same code in under 250 ms. A mutant disabling the connect timeout runs until the total timeout (about 1,000 ms) and fails the elapsed-time assertion. Verification is disabled only in this deliberately incomplete-handshake case; the successful HTTPS case verifies the fixture certificate and hostname. |
| Header cap | A 512-byte cap rejected the oversized header callback with `CURLE_WRITE_ERROR` (23); only 17 header bytes were accepted before the oversized line. |
| Encoded cap | A 512-byte progress cap stopped a chunked 4,096-byte identity response with `CURLE_ABORTED_BY_CALLBACK` (42). The observed wire counter was 768 bytes, establishing one 256-byte fixture-chunk overshoot. |
| Decoded cap and expansion | A 44-byte gzip fixture expands to 8,192 bytes. With a 1,024-byte decoded cap, the first 8,192-byte callback was rejected in full, zero decoded bytes were accepted, and libcurl returned `CURLE_WRITE_ERROR` (23). |
| Cancellation | The progress callback cancelled a streaming response with `CURLE_ABORTED_BY_CALLBACK` (42). |
| Conditional retrieval | An initial request returned 200, five body bytes, and exactly one bounded, valid ETag. The checker constructs `If-None-Match` from that captured value; the second request returned 304 and zero body bytes. Removing or changing the initial fixture ETag makes the corresponding mutant fail. |
| Bounded concurrency | A fresh dedicated server and one multi handle containing exactly four easy handles completed all four requests; the server observed a peak of four concurrent requests, never more than the configured handle count. Each easy handle retained the same protocol, timeout, callback, and proxy restrictions. The server retains and joins request workers, requires zero active workers before resetting only peak/failure counters, propagates send failures, and is stopped and joined on scope exit. Timeout/cap/cancellation workers on the earlier server are drained before exit and cannot corrupt the concurrency count. A fault immediately after the first easy handle is added proves one initialized easy, one added handle, and one header list are respectively cleaned, removed, and freed before the multi handle is cleaned; macOS `leaks --atExit` reports zero leaks for that path. |
| Callback failure | A deliberately failing body callback produced `CURLE_WRITE_ERROR` (23). |
| Resource cleanup | D exceptions, rather than C `exit`, carry fixed failures to a catch outside the scoped probe body, so scope guards run before `main` returns 1. TLS child and directory cleanup is idempotent and covered by the injected-failure check. Constructor faults after listen and after accept-thread start prove that the listener is closed, the possibly-started accept thread is joined without rethrow, and both ports can immediately be rebound. Worker faults immediately before and after `Thread.start` prove that the accepted socket is closed, the retained worker is removed, a possibly-started worker is joined without rethrow, and the accept loop still serves a subsequent request. Server shutdown records join failures but always drains request workers. |
| Diagnostics | Publication output consists of fixed case labels, fixed `E_*` failure labels, numeric expected/actual values, and non-secret version/cap measurements. Distinct credential, request-header, response-body, and URL-path canaries do not occur in captured stdout or stderr. Raw libcurl error strings, URLs, response headers, bodies, and certificate paths are not printed. |

The cap results also expose an important implementation constraint: callbacks
receive chunks. A production boundary must reject a chunk before copying it,
and an encoded progress cap needs an explicitly accepted bounded overshoot (or
a lower-level socket accounting mechanism). It must not claim byte-perfect
cessation at the configured threshold.

## Reproduce

From the repository root on the observed host, this recipe fails immediately
on a checker or evidence mismatch and reproduces every input recorded above:

```sh
set -eu
probe_dir=$(mktemp -d /tmp/scrubd-http-fetch.XXXXXX)
trap 'rm -rf "$probe_dir"' EXIT

test "$(sw_vers -productVersion)" = 26.6.2
test "$(sw_vers -buildVersion)" = 25G83
test "$(uname -r)" = 25.6.0
test "$(arch)" = arm64
ldc2 --version | rg -F 'LDC - the LLVM D compiler (1.43.0)'
ldc2 --version | rg -F 'based on DMD v2.113.0 and LLVM 23.1.0'
ldc2 --version | rg -F 'Default target: arm64-apple-darwin25.6.0'
clang --version | rg -F 'Apple clang version 21.0.0'
test "$(xcrun --show-sdk-version)" = 26.5
test "$(curl-config --version)" = 'libcurl 8.7.1'
curl-config --feature | rg -Fx 'MultiSSL'
curl-config --feature | rg -Fx 'SSL'
curl-config --feature | rg -Fx 'libz'
curl-config --feature | rg -Fx 'HTTP2'
curl-config --feature | rg -Fx 'AsynchDNS'
curl-config --feature | rg -Fx 'threadsafe'
if curl-config --feature | rg -q '^(brotli|zstd)$'; then exit 1; fi
curl-config --protocols | rg -Fx 'HTTP'
curl-config --protocols | rg -Fx 'HTTPS'
curl-config --configure | rg -F -- '--with-secure-transport'
curl-config --configure | rg -F -- '--with-ssl=/usr/local/libressl'
openssl version | rg -F 'OpenSSL 3.6.4 25 Aug 2026'

sdk=$(xcrun --show-sdk-path)
test "$(shasum -a 256 "$sdk/usr/include/curl/curl.h" | awk '{print $1}')" = \
  bc859632290c0495e45d80157ebb97bb296f7391d7efa054d127c7cf14469190
test "$(shasum -a 256 "$sdk/usr/lib/libcurl.4.tbd" | awk '{print $1}')" = \
  1b6d181ac7c9f13cbd270d8b1c81738ebefa45308baf53f82912b5f127006116
rg -F 'SPDX-License-Identifier: curl' "$sdk/usr/include/curl/curl.h"
test ! -e "$sdk/usr/include/curl/COPYING"
test "$(HOMEBREW_NO_AUTO_UPDATE=1 brew info --json=v2 curl | jq -r \
  '.formulae[0] | [.name,.versions.stable,(.keg_only|tostring),([.installed[].version]|join(","))] | @tsv')" = \
  $'curl\t8.22.0\ttrue\t'

ldc2 -O -release experiments/http_fetch/check.d \
  -of="$probe_dir/http-fetch-check" -L-lcurl
"$probe_dir/http-fetch-check" >"$probe_dir/stdout" 2>"$probe_dir/stderr"
test "$(rg -c '^PASS ' "$probe_dir/stdout")" -eq 24
rg -Fx 'PASS all 23 checks' "$probe_dir/stdout"
rg -Fx 'HOST_LIBCURL libcurl/8.7.1 (SecureTransport) LibreSSL/3.3.6 zlib/1.2.12 nghttp2/1.68.1' "$probe_dir/stdout"
connect_elapsed=$(sed -n 's/^MEASURE connect_timeout_config_ms=60 elapsed_ms=\([0-9][0-9]*\) total_timeout_ms=1000$/\1/p' "$probe_dir/stdout")
test -n "$connect_elapsed"
test "$connect_elapsed" -lt 250
rg -Fx 'MEASURE header_cap=512 accepted=17' "$probe_dir/stdout"
rg -Fx 'MEASURE encoded_cap=512 observed=768' "$probe_dir/stdout"
rg -Fx 'MEASURE decoded_cap=1024 accepted=0 offered=8192 fixture_encoded=44' "$probe_dir/stdout"
rg -Fx 'MEASURE multi_fault initialized=1 added=1 removed=1 cleaned=1 headers=1 multi=1 errors=0' "$probe_dir/stdout"
rg -Fx 'MEASURE multi_peak=4 multi_limit=4' "$probe_dir/stdout"
rg -Fx 'MEASURE server_ctor_closed=2 accept_joined=1 worker_sockets_closed=2 workers_removed=2 workers_joined=1' "$probe_dir/stdout"
test ! -s "$probe_dir/stderr"

if SCRUBD_HTTP_FETCH_TLS_MUTANT=1 "$probe_dir/http-fetch-check" \
    >"$probe_dir/mutant.stdout" 2>"$probe_dir/mutant.stderr"; then
  exit 1
fi
rg -Fx 'FAIL https_untrusted_rejected expected=60 actual=0' \
  "$probe_dir/mutant.stderr"

if SCRUBD_HTTP_FETCH_CONNECT_TIMEOUT_MUTANT=1 "$probe_dir/http-fetch-check" \
    >"$probe_dir/connect-mutant.stdout" 2>"$probe_dir/connect-mutant.stderr"; then
  exit 1
fi
rg '^FAIL E_CONNECT_TIMEOUT_ELAPSED expected=249 actual=[0-9]+$' \
  "$probe_dir/connect-mutant.stderr"

if SCRUBD_HTTP_FETCH_ETAG_MUTANT=remove "$probe_dir/http-fetch-check" \
    >"$probe_dir/etag-remove.stdout" 2>"$probe_dir/etag-remove.stderr"; then
  exit 1
fi
rg -Fx 'FAIL E_CONDITIONAL_ETAG_COUNT expected=1 actual=0' \
  "$probe_dir/etag-remove.stderr"

if SCRUBD_HTTP_FETCH_ETAG_MUTANT=change "$probe_dir/http-fetch-check" \
    >"$probe_dir/etag-change.stdout" 2>"$probe_dir/etag-change.stderr"; then
  exit 1
fi
rg -Fx 'FAIL E_CONDITIONAL_304 expected=304 actual=200' \
  "$probe_dir/etag-change.stderr"

SCRUBD_HTTP_FETCH_MULTI_FAULT=1 MallocStackLogging=1 \
  /usr/bin/leaks --atExit -- "$probe_dir/http-fetch-check" \
  >"$probe_dir/multi-leaks.stdout" 2>"$probe_dir/multi-leaks.stderr"
rg -F 'FAIL E_MULTI_CLEANUP_INJECTED expected=0 actual=0' \
  "$probe_dir/multi-leaks.stdout" "$probe_dir/multi-leaks.stderr"
rg '0 leaks for 0 total leaked bytes[.]$' \
  "$probe_dir/multi-leaks.stdout" "$probe_dir/multi-leaks.stderr"

for canary in PATH_CANARY_238_7d13 HEADER_CANARY_238_92ac \
  BODY_CANARY_238_b641 CREDENTIAL_CANARY_238_e50f; do
  if rg -q "$canary" "$probe_dir"/*.stdout "$probe_dir"/*.stderr; then
    exit 1
  fi
done

file "$probe_dir/http-fetch-check" | rg -F 'Mach-O 64-bit executable arm64'
lipo -archs "$probe_dir/http-fetch-check" | rg -Fx 'arm64'
test "$(otool -L "$probe_dir/http-fetch-check" | tail -n +2 | sed 's/^[[:space:]]*//')" = \
  $'/usr/lib/libcurl.4.dylib (compatibility version 7.0.0, current version 9.0.0)\n/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1356.0.0)\n/usr/lib/libobjc.A.dylib (compatibility version 1.0.0, current version 228.0.0)'
test "$(otool -l "$probe_dir/http-fetch-check" | awk \
  '/cmd LC_BUILD_VERSION/{on=1} on{print $1 "=" $2} on && /ntools/{exit}')" = \
  $'cmd=LC_BUILD_VERSION\ncmdsize=32\nplatform=1\nminos=26.0\nsdk=26.5\nntools=1'
```

The checker depends on `ldc2`, the macOS SDK/system libcurl, and `openssl` for
the test run. Its HTTP server, payloads, redirects, stalls, conditional
responses, and compression bomb are local fixtures. It does not download or
vendor anything.

## Proposed production boundary and consequences

The demonstrated seam supports a later production design with an opaque
request object, strict `http,https` allowlists on both original and redirected
URLs, proxy policy chosen explicitly, verified TLS, separate connect/total
timeouts, header/encoded/decoded caps, cooperative cancellation, validators,
a fixed maximum number of multi-handle transfers, and fixed content-free
public diagnostics. This paragraph is a proposal, not implemented production
behavior.

Dynamic adoption on the currently supported macOS arm64 target would add
`/usr/lib/libcurl.4.dylib` as a direct runtime dependency and `-lcurl` plus D
bindings at build time. Packaging would rely on Apple's OS library and inherit
its OS-serviced version/TLS behavior; it would not bundle a curl dylib or
OpenSSL. The release process would still need an owner-approved license/notice
decision, deployment-minimum compatibility testing, and independent TLS,
supply-chain, and resource-bound review. A pinned-source choice has no evidence
here: source provenance, hashes, build integration, transitive dependencies,
licenses, patch servicing, and artifact size were intentionally not evaluated.

Only macOS 26.6.2 arm64 with the named toolchain/runtime is demonstrated.
Earlier macOS releases, macOS x86_64, Linux, Windows, proxies, public PKI,
DNS, IPv6, HTTP/2 behavior, authentication, retries, rate limits, partial-file
cleanup, and live interoperability are unsupported by this evidence. Rollback
is deletion of this experiment and report.

ADOPT_DYNAMIC
