# Pure-D AWS SigV4 evaluation (evidence, not adoption)

Status: isolated evidence slice for issue #46's owner decision (2026-09-27
grooming note: "properly evaluate pure-D SigV4 before #46's decision is
made"). No AWS account, real credentials, or production wiring. This does not
commit to a pure-D S3 client and does not close #46; the decision remains
@schancel's. It complements, and should be read alongside,
`docs/s3-capability-evaluation.md`, which evaluated three other candidates
(a C++ SDK bridge, a C SDK bridge, and a GPLv3/unverifiable-source D binding)
and explicitly never attempted request signing.

## What was built

- `source/crypto/hmac_sha256.d` -- a pure HMAC-SHA256 implementation (RFC 2104
  keyed-hash construction), built directly on the existing incremental
  `crypto.sha256.Sha256` struct (`source/crypto/sha256.d`). It does not
  reimplement SHA-256; it only adds the standard inner/outer-padding wrapper
  around the primitive that already exists in this codebase.
- `experiments/sigv4_check/sigv4.d` -- a pure D implementation of AWS
  Signature Version 4 request signing: canonical request construction (method,
  canonical URI, canonical query string, canonical headers, signed-headers
  list, hex `SHA256(payload)`), the string-to-sign, the four-step signing-key
  derivation (`kDate -> kRegion -> kService -> kSigning`), and the final
  hex-encoded signature plus `Authorization` header assembly.
- `experiments/sigv4_check/evaluate.d` -- a standalone harness (no `dub`
  wiring; not part of `dub build`/`dub test`) that loads real AWS SigV4 test
  vectors from `experiments/sigv4_check/fixtures/` and asserts the signer's
  canonical request, string-to-sign and final `Authorization` header match
  AWS's own published output byte-for-byte.

### Why SigV4 lives under `experiments/`, not `source/`

`crypto.hmac_sha256` is a generic, reusable cryptographic primitive with the
same shape as the existing `crypto.sha256` -- it belongs in the production
crypto namespace regardless of what #46 decides, the same way `sha256.d` does.

The SigV4 *signer*, by contrast, is S3/AWS-request-shaped evaluation code with
no caller: #46 has not decided whether this codebase adopts a pure-D S3 path
at all, and wiring a signer into `source/` would misrepresent an untested,
non-adopted algorithm as part of the production surface. It is also not yet
wired to `effects.http_fetch`/`effects.curl_ffi` (explicitly out of scope for
this slice) and has not been exercised end-to-end against a real or fake S3
endpoint the way `docs/s3-capability-evaluation.md`'s local loopback harness
was. Keeping it in `experiments/sigv4_check/` matches this repository's
established posture for exploratory candidates (e.g.
`experiments/pdfium_check`, `experiments/llama_check`, `experiments/s3_capability`)
and keeps `dub build`/`dub test` unaffected, since `dub.json`'s `sourcePaths`
is `["source"]` only.

## Does the algorithm's complexity fit a bounded evaluation?

Yes, confirmed rather than assumed. SigV4 is fully specified and
deterministic (no negotiation, no vendor-specific behavior): a canonical-form
transform of the request, one SHA-256 hash, four chained HMAC-SHA256 calls for
key derivation, and one final HMAC-SHA256. The whole signer, including header
canonicalization, URI encoding and query-string sorting, is 196 lines of pure D
(`experiments/sigv4_check/sigv4.d`) with no external dependencies beyond the
two crypto primitives already in this repo. The trickiest parts in practice
were faithfully reproducing AWS's exact canonicalization edge cases (duplicate
header folding, header value whitespace collapsing, per-segment URI encoding,
query-parameter sorting) -- not the cryptography itself, which is a thin
wrapper around HMAC.

## HMAC-SHA256 verification: RFC 4231

`source/crypto/hmac_sha256.d`'s `unittest` block runs RFC 4231 Section 4 test
cases TC1-TC4, TC6 and TC7 (the full published set of HMAC-SHA-256 vectors,
excluding TC5, which specifies HMAC-SHA-256-**128**, a 128-bit truncation of
the digest, and is therefore not a vector for this function's full 256-bit
output). Source: <https://www.rfc-editor.org/rfc/rfc4231.txt>, fetched
2026-09-27.

Before trusting these as the expected outputs (rather than trusting my own
recollection of them), each was independently recomputed with Python 3.14's
standard-library `hmac.new(key, data, hashlib.sha256).hexdigest()` against the
RFC's stated key/data byte patterns. All six matched exactly:

| Case | RFC 4231 section | Result |
| --- | --- | --- |
| TC1 | 4.2 | OK (`b0344c61...2cff7`) |
| TC2 | 4.3 | OK (`5bdcc146...c3843`) |
| TC3 | 4.4 | OK (`773ea91e...565fe`) |
| TC4 | 4.5 | OK (`82558a38...9665b`) |
| TC6 | 4.7 | OK (`60e43159...37f54`) |
| TC7 | 4.8 | OK (`9b09ffa7...a35e2`) |

`ldc2 -I=source -unittest ... source/crypto/hmac_sha256.d` and the full
`dub test --build=release-unittest` run (81 modules passed unittests, this one
included) both execute these assertions; a failing digest would fail the
build. This is a **direct, independently-recomputed comparison**, not a
compiles-therefore-correct claim.

## SigV4 verification: which source, and how strong

**Source used:** the AWS-published SigV4 test suite, historically documented
at
<https://docs.aws.amazon.com/general/latest/gr/signature-v4-test-suite.html>.
That live AWS page did not return usable test-file content when fetched
2026-09-27 (a `WebFetch` of it returned no page body). The actual `.req`/
`.creq`/`.sts`/`.authz` test files were instead retrieved from
<https://github.com/saibotsivad/aws-sig-v4-test-suite>, whose README states
plainly: "These are the test suite files found in the AWS documentation... The
raw request files from AWS have been parsed and exported as objects", under an
Apache-2.0 license inherited from AWS for the test files themselves (the
repository's own wrapper code/JSON export uses a separate license). This was
verified directly, not taken on the README's word alone: the repository's
`raw/aws-sig-v4-test-suite/` directory contains the original, unmodified
per-case `.req`/`.creq`/`.sts`/`.authz` quadruples (fetched via GitHub's
`git/trees` API and `raw.githubusercontent.com`, 2026-09-27), and its
`index.json` carries a `config` object
(`accessKeyId`/`secretAccessKey`/`region`/`service`) that both matches the
`Credential=` fields embedded in every fetched `.authz` file and is what makes
the signatures verify (see the correction below).

**Confidence:** this is a genuine multi-case third-party-mirrored copy of
AWS's own test suite, not a single hand-copied worked example -- the stronger
of the two evidence tiers #46's owner decision asked to distinguish between.
It is one level removed from AWS's own live page (mirrored via a third-party
GitHub repository, since that live page did not yield content on the day of
this evaluation), so provenance rests on that repository's own README claim
plus internal consistency (the `.sts` files are, in every case actually used
here, the exact SHA-256 hash of the paired `.creq` file's bytes, which is only
true if the fixtures are self-consistent products of a real algorithm run and
not fabricated).

**What was checked:** 8 of the suite's fixture cases, copied byte-for-byte
into `experiments/sigv4_check/fixtures/`:

| Fixture | Exercises |
| --- | --- |
| `get-vanilla` | Baseline GET, empty payload |
| `get-vanilla-query` | (identical baseline request in this suite) |
| `post-vanilla` | POST method |
| `get-unreserved` | RFC 3986 unreserved-character URI path, no encoding needed |
| `get-vanilla-query-order-key-case` | Query-parameter alphabetical sorting |
| `get-header-key-duplicate` | Duplicate header names folded with `,` |
| `get-header-value-order` | Duplicate header value ordering preserved |
| `get-header-value-trim` | Internal whitespace collapsing in header values |

`experiments/sigv4_check/evaluate.d` parses each `.req` file into a request,
runs it through `sigv4.signRequest`, and asserts the **canonical request**,
**string-to-sign**, and **final `Authorization` header** (which embeds the
signature) all match the corresponding `.creq`/`.sts`/`.authz` file
byte-for-byte. Reproduce from the repository root:

```sh
ldc2 -i -I=source -O -release experiments/sigv4_check/evaluate.d \
    experiments/sigv4_check/sigv4.d -of=/tmp/sigv4-evaluate
/tmp/sigv4-evaluate
```

Result: **8/8 PASS**, all three layers (canonical request, string-to-sign,
signature) byte-exact.

### A mistake this process caught, and one it did not paper over

Two honesty notes belong here, not just a pass count:

1. My first attempt used the wrong secret access key
   (`wJalrXUtnFEMI/K7MDENG**/**bPxRfiCYEXAMPLEKEY`, a `/` I mis-recalled from
   general familiarity with AWS's example credentials). The canonical request
   and string-to-sign matched immediately -- they don't depend on the secret
   -- but every final signature was wrong. The actual test suite's
   `index.json` uses a `+` in that position
   (`wJalrXUtnFEMI/K7MDENG**+**bPxRfiCYEXAMPLEKEY`). Only checking the
   downloaded fixture's own `config` object, rather than trusting memory,
   caught this. This is direct evidence for why this evaluation insisted on
   fetching real files instead of hand-typing "known" AWS example values.
2. A ninth candidate fixture, `post-x-www-form-urlencoded` (POST with a
   non-empty body, exercising the payload-hash path), was pulled from the same
   repository and found to be **internally inconsistent**: SHA-256 of its own
   `.creq` file's bytes does not equal the hash embedded in its own paired
   `.sts` file (independently recomputed with both Python's `hashlib` and this
   evaluation's own `sha256Hex`, in agreement with each other, disagreeing
   with the fixture). Its `.authz` file also signs a `SignedHeaders` list that
   omits `content-length`, which is present in its `.creq`'s signed-headers
   line -- a second internal contradiction. This is consistent with the
   upstream repository's own README, which separately discloses three *other*
   named test cases it excluded for AWS-side specification inconsistencies
   (`get-header-value-multiline`, `get-utf8`, `get-space`); this appears to be
   a further such case the README's list does not mention. Rather than force
   a match or quietly drop the discrepancy, it was excluded from this
   evaluation's verified set and is disclosed here. The empty-body payload
   hash (`e3b0c44...`) is otherwise exercised by all 8 verified fixtures and
   independently matches the well-known SHA-256 of the empty string, so the
   payload-hashing code path is not unverified overall -- only the specific
   non-empty-body fixture was rejected as bad ground truth.

## What is still unresolved

- **Path normalization** (`.` / `..` segment collapsing, per RFC 3986 section
  5.2.4) is part of the general SigV4 canonical-URI spec but was not
  implemented or tested; the suite's `normalize-path` fixture directory
  returned `404` when fetched and was not substituted with another source.
  `canonicalUri` in `experiments/sigv4_check/sigv4.d` assumes an
  already-normalized path.
- **UTF-8 / percent-double-encoding edge cases**: the upstream suite's own
  `get-utf8` and `get-space` cases are the two of its three disclosed
  "AWS spec inconsistencies" that touch path encoding; they were excluded
  upstream and not independently re-derived here.
- **Query-string values with `=` inside them**, STS temporary-credential
  (`X-Amz-Security-Token`) signing, and multi-region SigV4a were not
  implemented or tested; only classic long-term-credential SigV4 was.
- **No end-to-end exercise**: unlike `docs/s3-capability-evaluation.md`'s
  local loopback+TLS harness, this evaluation never sent a signed request
  anywhere, real or fake. It proves the *signature math* is correct against
  AWS's own test data, not that a full request built this way would be
  accepted by S3 (header selection, chunked/streaming payloads,
  `UNSIGNED-PAYLOAD`, and multipart semantics are all untested).
- The AWS live documentation page for the test suite did not render for this
  evaluation; a maintainer with working access to
  <https://docs.aws.amazon.com/general/latest/gr/signature-v4-test-suite.html>
  could re-verify the mirror repository against the primary source directly,
  which this evaluation could not do.

## Honest comparison against the three prior candidates

`docs/s3-capability-evaluation.md` weighed three options, verified as follows:

| Candidate | Verified license | Verified provenance | FFI/build cost |
| --- | --- | --- | --- |
| AWS SDK for C++ bridge | Apache-2.0 (GitHub repo license report) | Pinned release tag + commit hash | Requires a D/C++ bridge, ABI management, and building/linking a large C++ SDK with its own transitive dependency graph |
| AWS Common Runtime C S3 client bridge | Apache-2.0 (GitHub repo license report) | Pinned release tag + commit hash | Requires a D/C bridge and multiple AWS Common Runtime C libraries (aws-c-common/io/http/auth/s3, etc.) as transitive dependencies |
| Legacy D `s3`/libs3 binding | GPLv3 (registry-advertised) | **Unverifiable** -- linked source repository 404'd | No bridge needed (already D), but license and source both unverified |

Pure-D SigV4, verified in this evaluation:

- **License**: none needed -- it is original code written for this repository
  under this repository's own MIT license (`dub.json`). This genuinely avoids
  both the GPLv3 exposure and the Apache-2.0-but-still-third-party-dependency
  status of the other two real candidates.
- **Provenance**: fully verifiable -- every line is in this repository, in
  this commit, reviewable like any other change. This genuinely avoids the
  unverifiable-source problem the GPLv3 binding carries.
- **FFI/bridge cost**: the signing algorithm itself needed **zero** FFI --
  it is pure D calling pure D (`crypto.sha256`, `crypto.hmac_sha256`). This
  claim was checked, not assumed: `experiments/sigv4_check/sigv4.d` imports
  only `crypto.hmac_sha256`, `crypto.sha256`, and Phobos (`std.*`); it needs
  no C or C++ library, and does not touch `effects.http_fetch`/
  `effects.curl_ffi` at all in this slice (those remain the pre-existing,
  already-D, already-shipped HTTP/TLS transport this codebase uses for
  everything else, per the owner decision's framing).
- **What this does *not* avoid**: signing is one component of an S3 client,
  not the whole thing. The three prior candidates were full SDKs/bindings
  (bucket listing, multipart upload, retry policy, S3 XML error parsing,
  etc.); this evaluation only closes the specific gap
  `docs/s3-capability-evaluation.md` flagged ("the test does not sign a
  request... cannot prove AWS SigV4 canonicalization"). A complete pure-D S3
  client would still need an HTTP transport (this repository already has
  `effects.http_fetch`/`effects.curl_ffi`, unmodified by this slice) and an
  XML parser for S3's response bodies (this repository already depends on
  `dxml` 0.4.5 for OOXML parsing, per `dub.json`; whether it is adequate for
  S3's specific response XML schema is **not evaluated here** and would need
  its own check). So: pure-D SigV4 removes the specific licensing and
  FFI-bridge costs the three prior candidates carried, and the codebase
  already has D-native building blocks for the remaining pieces (transport,
  XML), but "the remaining pieces already exist" is a favorable-looking
  inventory, not a tested claim that they compose into a working S3 client.

## Verdict

**Defer, leaning toward "viable candidate worth carrying into #46's
decision"** -- not an adoption, and not @schancel's call to make by proxy.

What this evaluation adds to #46: it closes the one concrete gap the prior
evaluation named ("cannot prove AWS SigV4 canonicalization") with real,
byte-exact verification against AWS's own test data, and it verifies -- rather
than assumes -- that doing so avoids the GPLv3 and FFI-bridge costs of the
other two real candidates. It does not resolve #46, does not authorize a
production S3 client, and does not unblock S02-S05 (#47-#50), which stay
exactly as gated as before. The unresolved items above (path normalization,
STS tokens, end-to-end exercise against any endpoint, S3 XML compatibility)
are real gaps a production decision would need to close, not swept under the
evaluation's "PASS" count.
