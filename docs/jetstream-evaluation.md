# JetStream / nats.c frontier evaluation

## Decision

**Reject direct production adoption as a `scrubbed.frontier` v1 backend.** The
pinned client and server are packageable on the tested host and the broker
provides useful bounded, durable, authenticated at-least-once primitives. It
does not provide the mandatory #251 transaction and state-machine semantics:
in particular, finishing a producing lease and admitting all discoveries is
not one broker transaction, stale lease generations cannot return the typed
contract result, and WorkQueue retention deletes the terminal history needed
for exact snapshots and counts. Implementing those guarantees above JetStream
would be a custom distributed coordination protocol, which is outside this
evaluation and explicitly not authorized.

This decision adds no dependency and no production adapter. A future owner may
reopen the candidate only with separate authority for a concrete protocol that
passes the shared conformance suite without weakening the contract. Deleting
`experiments/jetstream/` and this report completely rolls back the spike.

## Reproducible evidence

From the repository root, run:

```sh
experiments/jetstream/run.sh
```

The 2026-09-24 run on macOS 26.6.2 arm64 used Apple clang 21.0.0, CMake
4.0.2, and OpenSSL 3.6.4 as reported by the same `pkg-config` metadata that
supplied CMake's prefix and the probe's link flags. The committed
`expected.tsv` is compared byte for byte before success. The observed result
was:

```text
plaintext-control correct-token-plaintext-accepted=true tls-listener-advertised=false client-rlimit=64 outer-deadline-s=15
auth correct-token-plaintext-rejected=true tls-listener-advertised=true token-rejected=true trusted-token=true connect-timeout-ms=300 client-rlimit=64 outer-deadline-s=15
setup admit=true duplicate=true nak-redelivery-before-ack-expiry=true causal-ack-wait-ms=10000 max-ack-pending-blocks-second=true ack-releases-second=true restart-ack-wait-ms=500 ack=true payload-limit=512 stream-limit=4 inflight-limit=1 fetch-timeout-window-ms=150..1000 pending-restart=true client-rlimit=64 outer-deadline-s=15
restart durable-identity=true redelivery=true state-survived=true fetch-timeout-ms=200 fetch-timeout-window-ms=150..1000 drained=true client-rlimit=64 outer-deadline-s=15
reconnect disconnected=true reconnected=true publish-after-reconnect=true client-rlimit=64 outer-deadline-s=15
resources platform=darwin-arm64 server-fds=7/64 client-fds=6/64 store-bytes=0/4194304 scratch-bytes=51142656/268435456 runtime-processes=2 build-jobs=2
packaging nats-c=3.14.0-static nats-server=2.15.0-official-binary openssl-pkgconfig=3.6.4-dynamic openssl-pc-dir=/opt/homebrew/lib/pkgconfig/../../Cellar/openssl@3/3.6.4/lib/pkgconfig sbom-verified=true
cleanup server-stopped=true client-stopped=true active-probe-interrupt=true failure-trap=true scratch-removed=true ephemeral-secrets-removed=true
```

The runner downloads the selected official artifacts into a fresh scratch
directory, checks SHA-256 before extraction, verifies the official SPDX
package inventory, builds the client, generates throwaway authentication/TLS
material, and runs only on `127.0.0.1`. It records every spawned client and
server PID. Shutdown sends signals only to those PIDs; no pattern kill or live
external service is used.

## Pins, build, linkage, and notices

The exact archive, commit, license-file, dependency-manifest, server-platform,
and SPDX hashes are in
[`experiments/jetstream/DEPENDENCIES.md`](../experiments/jetstream/DEPENDENCIES.md)
and `versions.env`. In summary:

- `nats.c` v3.14.0 at commit
  `6cb096a7fd24a1927037fd2a2ca2c6fbc5d64e47`, source archive SHA-256
  `1f8b450bc295d0c94be201e34713ca0b515aae2c0d1b279273c3e6e0e72fe005`.
- `nats-server` v2.15.0 at commit
  `eb763679aa3c24a40dcd3012aa046ad1996d851c`; the tested macOS arm64
  archive SHA-256 is
  `e1c4e22d70bd44abfa0bcb3c16f7cf0c66f648c2e728c58924e8a1ce88913cc8`.
- Both projects are Apache-2.0 and neither tagged root has a `NOTICE` file.
  The official server SBOM adds MIT, BSD-3-Clause, and Apache-2.0 dependency
  obligations; the exact package/version/license rows are pinned in
  `server-sbom.expected.tsv`.

The recipe builds release `libnats_static.a` with TLS and hostname validation
on, and shared-library, legacy Streaming/protobuf-c, libsodium, examples, and
experimental APIs off. The probe links `nats.c` statically but OpenSSL and the
platform runtime dynamically. The runner rejects an unexpected dynamic
`libnats`, missing `libssl`/`libcrypto`, wrong client version, or wrong server
version. OpenSSL's recorded version and `.pc` directory come from the exact
`pkg-config openssl` module used for `OPENSSL_ROOT_DIR` and linker flags, not an
unrelated executable on `PATH`. The official Go server is a separate runtime
executable, not linked into `scrubbed`.

No production package should copy the evaluation's host OpenSSL implicitly.
If a later proposal distributes a client binary, it must pin or constrain the
OpenSSL ABI, reproduce all applicable license texts, and repeat dependency and
linkage checks on each shipping target.

## Resource and security envelope

| Resource | Enforced evaluation bound |
| --- | --- |
| Network | loopback only; a sequential plaintext-control port, then one TLS server-selected port reused for restart/reconnect |
| Processes | one server plus at most one probe client at runtime |
| Build concurrency | two jobs |
| File descriptors | every server and probe client asserts `RLIMIT_NOFILE` 64; observed live TLS server use 7 and reconnect client use 6 (required range 4..64) |
| Payload | 512 bytes per stream message; the 513-byte probe is refused |
| Stored messages | four; `DiscardNew` refuses the fifth without eviction |
| Stream bytes | 4,096 bytes |
| Server stores | 4 MiB file, 1 MiB memory; file-backed stream only |
| In-flight work | one durable-consumer ack pending and one-message pull batches |
| Time | 300 ms connect, 10 s causal-Nak ack wait, 500 ms restart ack wait, 100 ms reconnect wait × 40 attempts, 500 ms publish/API, 200--1,000 ms fetch, monotonic 150--1,000 ms assertion around every 200 ms empty fetch, 2 s client teardown, 5 s process start/stop, 15 s client self-alarm plus 16 s exact-PID harness deadline, 5 s active-probe interrupt readiness bound |
| Scratch | 256 MiB; observed 51,142,656 bytes including downloads, SBOM, linkage evidence, and build |

The evaluated server requires TLS and a token. A raw socket first sends the
correct-token plaintext NATS `CONNECT` and `PING` to a non-TLS control and
receives `PONG`. The same raw bytes and token receive no `PONG` from the
listener whose `INFO` advertises `tls_required=true`; this distinguishes TLS
enforcement from certificate or authentication failure. The trusted positive
path validates a generated CA and the `localhost` certificate name, and a
separate TLS path proves the wrong token fails. The random token, CA private
key, server key, payloads, store, logs, and binaries exist only below a
mode-0700 scratch directory. They
are never passed on a command line or copied into evidence. Normal and error
traps stop recorded PIDs and remove the directory. An active-probe interrupt
fixture keeps a real, connected reconnect probe client running against the
already-started fixed-config server, sends `TERM` to the nested harness
subshell that owns it, and proves that the exact client PID was reaped and its
nested scratch directory and ephemeral token copy are both gone. A separate
intentional failure fixture starts the real pinned server, writes throwaway
content, exits nonzero, and proves that its exact PID and nested scratch are
gone. The successful run also checks that the outer directory no longer
exists.

## Mapping to the fixed Frontier / JobQueue contract

JetStream facts below describe the evaluated pins. They do not redefine job or
pipeline semantics and do not turn mandatory behavior into optional behavior.

| #251 operation or invariant | Observed JetStream primitive | Contract verdict |
| --- | --- | --- |
| Open with process durability | File-backed stream and durable consumer survived an exact-PID server stop/restart with the pending payload intact | `processDurable = true` is supportable for this configuration, but it does not make the backend conforming overall |
| Admit and duplicate | Synchronous publish returns a storage acknowledgement; `Nats-Msg-Id` returned the same sequence with `Duplicate=true` | Partial mismatch: deduplication is bounded by the configured 60-second window, while frontier identity remains authoritative for the queue lifetime |
| Page, host, depth, provenance, queue, and stored-byte admission | Stream `MaxMsgs`, `MaxBytes`, `MaxMsgSize`, and `DiscardNew` refused broker storage overflow | Mismatch: this is not V1 queue saturation. V1 admits otherwise-valid work as `admittedDeferred` when `maxQueued` is full, then promotes it in FIFO order. The broker also has no native policy/locator identity, per-host/page/depth/provenance accounting, or typed `AdmissionCode` |
| Claim / active bound | Durable pull consumer, explicit ack, one-message batch, and `MaxAckPending=1`; with two distinct queued messages, holding the first unacked made the second fetch time out, then acking the first released the second | Primitive and broker-side in-flight bound are available. They do not themselves produce the contract's typed candidate plus opaque lease token |
| Ack | `AckSync` confirmed successful removal under WorkQueue retention | Primitive available, but deletion loses the completed state and exact snapshot/count history required by v1 |
| Nak / retry | With `AckWait=10s`, a flushed `Nak` redelivered the same message within a 1s fetch and metadata advanced `NumDelivered` from 1 to 2; the consumer was then updated to a separately asserted 500 ms ack wait for the restart probe | Causal at-least-once retry is available. The observed immediate redelivery is not the contract rule that reclaimed/retryable work joins the FIFO tail |
| Durable identity / restart redelivery | Named consumer `SCRUBBED_FRONTIER_V1` survived restart; an unacked message returned with `NumDelivered >= 2` | Useful transport identity. It is not `(policyId, canonicalLocator)` candidate identity |
| Lease generation, stale/double completion, reclaim | Delivery metadata exposes a counter | Mismatch: the ack protocol does not provide the contract's generation-checked mutation result (`staleGeneration`, `notLeased`, or `reclaimed`) at the application boundary |
| Finish-with-discovery | Publish and ack are separate JetStream operations | Blocking mismatch: there is no observed atomic boundary that applies the producer outcome and validates/admits the full discovery envelope together |
| Retryable versus permanent failure | The evaluated consumer has operational `MaxDeliver=3` | Mismatch: V1 has no retry-attempt cap; the caller explicitly selects retryable or permanent outcome. JetStream can strand an unacked message after `MaxDeliver` without producing V1's typed permanent terminal state. Dead-letter handling would add unaccepted semantics |
| Seal, cancel/resume, and truthful completion | Stream/consumer administration and broker counts exist | Mismatch/unproven: these do not directly implement the contract lifecycle, and stream sealing is not adopted as a substitute |
| Bounded snapshot / lookup | Stream and consumer info expose broker counters | Mismatch: no sorted typed candidate snapshot, exact lookup, required-item refusal, or terminal candidate states |
| Empty wait / client reconnect | Empty pulls returned `NATS_TIMEOUT` inside a monotonic 150--1,000 ms window around the configured 200 ms; a live client observed disconnect and automatic reconnect, then published and consumed successfully. Every probe had a 15 s process alarm and a 16 s exact-PID harness deadline | Transport behavior is bounded and usable, but network backoff and process termination are outside the domain contract. V1 owns queue lifecycle and truthful completion only |

The shared contract currently has one honest capability flag:
`processDurable`. This evaluation supports setting it true only after a backend
has implemented all mandatory semantics. Adding flags such as
“non-atomic-finish,” “approximate-snapshot,” or “broker-retry-order” would fork
the accepted job semantics, so this report recommends no new capability flags.

## Platform truth

- **Evidence-supported:** macOS arm64 only, with the toolchain and measurements
  above.
- **Prepared but unverified:** official server archives and SHA-256/SPDX hashes
  are pinned for macOS x86_64 and Linux x86_64/arm64, and the POSIX runner has
  platform branches for them. They are not claimed supported until the same
  fixture passes there.
- **Unsupported by this evaluation:** Windows, 32-bit systems, musl-specific
  packaging, cross-compilation, containers, clustered/multi-machine NATS,
  external certificate authorities, credential rotation, upgrades, backup,
  restore, and disaster recovery.

Single-process loopback success says nothing about clustered consistency or
operational ownership. Those are non-goals, and the semantic rejection means
there is no reason to expand into them under this ticket.
