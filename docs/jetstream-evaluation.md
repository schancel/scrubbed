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
4.0.2, and OpenSSL 3.6.4. The committed `expected.tsv` is compared byte for
byte before success. The observed result was:

```text
auth tls-required=true token-rejected=true trusted-token=true connect-timeout-ms=300
setup admit=true duplicate=true nak-redelivery=true ack=true payload-limit=512 stream-limit=4 inflight-limit=1 pending-restart=true
restart durable-identity=true redelivery=true state-survived=true fetch-timeout-ms=200 drained=true
reconnect disconnected=true reconnected=true publish-after-reconnect=true
resources platform=darwin-arm64 server-fds=7/64 store-bytes=0/4194304 scratch-bytes=50737152/268435456 runtime-processes=2 build-jobs=2
packaging nats-c=3.14.0-static nats-server=2.15.0-official-binary openssl=3.6.4-dynamic sbom-verified=true
cleanup server-stopped=true client-stopped=true failure-trap=true scratch-removed=true ephemeral-secrets-removed=true
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
version. The official Go server is a separate runtime executable, not linked
into `scrubbed`.

No production package should copy the evaluation's host OpenSSL implicitly.
If a later proposal distributes a client binary, it must pin or constrain the
OpenSSL ABI, reproduce all applicable license texts, and repeat dependency and
linkage checks on each shipping target.

## Resource and security envelope

| Resource | Enforced evaluation bound |
| --- | --- |
| Network | loopback only; one server-selected port, reused for restart/reconnect |
| Processes | one server plus at most one probe client at runtime |
| Build concurrency | two jobs |
| File descriptors | child `RLIMIT_NOFILE` 64; observed server use 7 |
| Payload | 512 bytes per stream message; the 513-byte probe is refused |
| Stored messages | four; `DiscardNew` refuses the fifth without eviction |
| Stream bytes | 4,096 bytes |
| Server stores | 4 MiB file, 1 MiB memory; file-backed stream only |
| In-flight work | one durable-consumer ack pending and one-message pull batches |
| Time | 300 ms connect, 100 ms reconnect wait × 40 attempts, 500 ms publish/API, 200--1,000 ms fetch, 2 s client teardown, 5 s process start/stop |
| Scratch | 256 MiB; observed 50,737,152 bytes including downloads, SBOM, linkage evidence, and build |

The server requires TLS and a token. The positive path validates a generated
CA and the `localhost` certificate name; negative paths prove that plaintext
and a wrong token fail. The random token, CA private key, server key, payloads,
store, logs, and binaries exist only below a mode-0700 scratch directory. They
are never passed on a command line or copied into evidence. Normal and error
traps stop recorded PIDs and remove the directory. An intentional failure
fixture starts the real pinned server, writes throwaway content, exits nonzero,
and proves that its exact PID and nested scratch are gone. The successful run
also checks that the outer directory no longer exists.

## Mapping to the fixed Frontier / JobQueue contract

JetStream facts below describe the evaluated pins. They do not redefine job or
pipeline semantics and do not turn mandatory behavior into optional behavior.

| #251 operation or invariant | Observed JetStream primitive | Contract verdict |
| --- | --- | --- |
| Open with process durability | File-backed stream and durable consumer survived an exact-PID server stop/restart with the pending payload intact | `processDurable = true` is supportable for this configuration, but it does not make the backend conforming overall |
| Admit and duplicate | Synchronous publish returns a storage acknowledgement; `Nats-Msg-Id` returned the same sequence with `Duplicate=true` | Partial mismatch: deduplication is bounded by the configured 60-second window, while frontier identity remains authoritative for the queue lifetime |
| Page, host, depth, provenance, queue, and stored-byte refusal before mutation | Stream `MaxMsgs`, `MaxBytes`, `MaxMsgSize`, and `DiscardNew` refused broker capacity overflow | Mismatch: the broker has no native policy/locator identity, per-host/page/depth/provenance accounting, or typed `AdmissionCode`; those cannot be inferred from a publish acknowledgement |
| Claim / active bound | Durable pull consumer, explicit ack, one-message batch, and `MaxAckPending=1` | Primitive available. It does not itself produce the contract's typed candidate plus opaque lease token |
| Ack | `AckSync` confirmed successful removal under WorkQueue retention | Primitive available, but deletion loses the completed state and exact snapshot/count history required by v1 |
| Nak / retry | `Nak` redelivered the same message and metadata advanced `NumDelivered` from 1 to 2 | At-least-once retry is available. The observed immediate redelivery is not the contract rule that reclaimed/retryable work joins the FIFO tail |
| Durable identity / restart redelivery | Named consumer `SCRUBBED_FRONTIER_V1` survived restart; an unacked message returned with `NumDelivered >= 2` | Useful transport identity. It is not `(policyId, canonicalLocator)` candidate identity |
| Lease generation, stale/double completion, reclaim | Delivery metadata exposes a counter | Mismatch: the ack protocol does not provide the contract's generation-checked mutation result (`staleGeneration`, `notLeased`, or `reclaimed`) at the application boundary |
| Finish-with-discovery | Publish and ack are separate JetStream operations | Blocking mismatch: there is no observed atomic boundary that applies the producer outcome and validates/admits the full discovery envelope together |
| Retry exhaustion / permanent failure | `MaxDeliver=3` bounds attempts | Mismatch: exhaustion and poison handling do not create the contract's typed permanent terminal state; a dead-letter workflow would be additional semantics |
| Seal, cancel/resume, and truthful completion | Stream/consumer administration and broker counts exist | Mismatch/unproven: these do not directly implement the contract lifecycle, and stream sealing is not adopted as a substitute |
| Bounded snapshot / lookup | Stream and consumer info expose broker counters | Mismatch: no sorted typed candidate snapshot, exact lookup, required-item refusal, or terminal candidate states |
| Empty wait / client reconnect | Empty pull returned at 200 ms; a live client observed disconnect and automatic reconnect, then published and consumed successfully | Transport behavior is bounded and usable; application backoff/termination semantics remain owned by the contract |

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
