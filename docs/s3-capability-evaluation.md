# S01 direct S3 client/auth capability evaluation (evidence landing)

Status: isolated proposal, **not a selected client or production implementation**. No
AWS credentials, AWS account, paid endpoint, third-party package, or production
dependency was used. The next decision belongs to @schancel and needs its own
reviewed implementation landing; this document does not close #46.

## Candidate provenance checked 2026-09-21 UTC

| Option | Exact version/source identity | License evidence | Decision status |
| --- | --- | --- | --- |
| AWS SDK for C++ via a narrow D/C++ bridge | Official [`aws/aws-sdk-cpp` release `1.11.896`](https://github.com/aws/aws-sdk-cpp/releases/tag/1.11.896), published 2026-09-18; tag resolves to commit `8fa1fe5c8b758eeba5427f66f70c4fd6a7c67f25` | GitHub repository license reports Apache-2.0, license blob `8dada3edaf50dbc082c9a125058f25def75e625a` | Credible maintained upstream, but bridge ABI/build complexity and transitive licenses/build cost need evaluation. Not adopted. |
| AWS Common Runtime C S3 client via a D/C bridge | Official [`awslabs/aws-c-s3` release `v1.1.2`](https://github.com/awslabs/aws-c-s3/releases/tag/v1.1.2), published 2026-09-15; annotated tag resolves to commit `4edf76c24c810ef2fce1f791358df729245e81e1` | GitHub repository license reports Apache-2.0, license blob `67db8588217f266eb561f75fae738656325deac9` | Credible native C interface but its CRT dependency graph, lifecycle and feature coverage need proof. Not adopted. |
| Legacy D `s3`/libs3 binding | [DUB registry package `s3` 1.0.1](https://code.dlang.org/packages/s3) advertises underlying libs3 3.2.0 and GPLv3 for library and bindings; linked `YusukeSuzuki/libs3-d` GitHub repository returned 404 during this check, so an immutable source commit/hash could **not** be verified | GPLv3 is advertised by package's own registry description; repository source/license was unavailable | Rejected as an adoption candidate pending owner/legal decision and verifiable source. Do not treat this registry text as legal clearance. |

The [AWS S3 SDK reference](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Reference.html)
lists supported language SDKs but no D SDK. The C++ and C options above are
research candidates, not evidence that either can be linked in this D project
or published under this project's license. The exact Git commit identities
above come from the upstream GitHub tag/release API; no upstream source was
vendored. Transitive dependency license and vulnerability review remains open.

## Proposed narrow boundary

`Credentials` is an opaque access-key/secret/token value, obtained from a typed
`AuthSource` (explicit, environment, profile, missing). The test model accepts
only a **complete pair** and proposes explicit > environment > profile as the
precedence for these three sources. This follows AWS's documented general
[settings precedence](https://docs.aws.amazon.com/sdkref/latest/guide/settings-reference.html),
but the actual SDK-specific provider chain, session token, refresh/expiry,
assumed roles, web identity, metadata service, profile parsing and process
providers are **not implemented or tested** here. A partial pair at a higher
precedence source fails closed; it never silently falls through to a lower
source. The production implementation
must use its selected SDK's verified chain or explicitly document a smaller one.

`Endpoint` carries host, port, region and a typed path/virtual-host addressing
mode. `Route` derives host, path and signing region. The local test asserts
`/bucket/object` with the endpoint host, and tests the virtual-host proposal
`bucket.s3.us-west-2.amazonaws.com/object`; [AWS documents both addressing
styles](https://docs.aws.amazon.com/AmazonS3/latest/userguide/VirtualHosting.html).
The test does not sign a request. Production must validate endpoint and bucket
syntax at the edge, ensure TLS peer **and hostname** verification, handle DNS,
redirects and region errors, and bind the configured region into actual SigV4
signing. [AWS says SigV4 is the default for its SDKs and required for most S3
regions](https://docs.aws.amazon.com/AmazonS3/latest/developerguide/specify-signature-version.html).

`Capability` currently names `getObject`, `listObjectsV2`, and `unsupported`;
the latter fails closed before request dispatch. These are proposed types, not
a claim that the candidates support the operation. Public `Failure` codes are
fixed labels (`missing_credentials`, `incomplete_credentials`,
`unsupported_capability`, `bad_auth`, `tls_untrusted`, `endpoint_failure`).
The fake-endpoint probe parses an exact
HTTP/1.1 status-code token: 200 is success, 403 is bad auth, and 404, 500 or
malformed status lines (including `200bogus` and a missing second separator
space) are endpoint failures; it does not infer that every
non-200 response is an authentication failure. Raw transport exception text,
request headers, URLs, environment values, credential fields and certificate details
must not be copied into publication-safe errors or logs. Structured diagnostics
may later carry an operation code and non-secret request id only after review.

## Reproduce local evidence

Run from the repository root on a machine with LDC, OpenSSL and curl:

```sh
ldc2 -O -release experiments/s3_capability/evaluate.d -of=/tmp/s3-capability-evaluate
/tmp/s3-capability-evaluate
```

The probe is D-only. It starts a D loopback HTTP fault endpoint using fake
credentials and verifies precedence, path/host/region derivation, 200 vs 403
mapping, unsupported/missing-auth rejection and fixed-label redaction. Its
`X-Fake-Access` header deliberately is **not** AWS SigV4 or an AWS credential.
For TLS it has OpenSSL create an ephemeral loopback-only certificate and starts
`openssl s_server` bound explicitly to `127.0.0.1:<ephemeral port>`; `lsof`
checks the actual listening socket is that loopback address, not a wildcard.
curl's default peer verification rejects the self-signed
certificate, `--cacert` accepts that certificate with matching IP SAN, and a
hostname mismatch fails. No `-k`/`--insecure` flag is used. The D harness checks
process results in release builds with `check()`; D `assert` elision cannot
turn a failed probe green. It suppresses the underlying curl/OpenSSL output so
publication output contains only fixed test labels. Subprocesses inherit only
`PATH`, not ambient AWS credentials, proxy settings or CA overrides; curl's
user configuration is disabled and all calls bypass proxies. Ephemeral
key/cert files are deleted after the run.

Verified local tool versions: LDC 1.43.0 (DMD 2.113.0), DUB 1.42.0,
OpenSSL 3.6.4, Apple curl 8.7.1 with SecureTransport. Local TLS behavior is
platform/stack-specific; the harness also requires `lsof`. Repeat with the
chosen production transport and supported deployment platforms.

The loopback server proves only *our proposed boundary behavior*. It cannot
prove AWS SigV4 canonicalization, IAM authorization, actual S3 error XML,
bucket region redirects, virtual-host DNS/wildcard certificate behavior,
session-token refresh, multipart/streaming semantics, retry or rate-limit
behavior, AWS-compatible-provider parity, availability, throughput, or live
AWS interoperability. A later owner-approved production selection must pin
all source/transitive licenses and hashes, test those behaviors against the
selected client's real API, and separately decide whether a scoped live-service
gate with real-account authority is warranted. Until then, #46 remains open.
