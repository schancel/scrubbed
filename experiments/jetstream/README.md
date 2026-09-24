# Bounded JetStream evaluation fixture

Run from the repository root:

```sh
experiments/jetstream/run.sh
```

The fixture downloads only the pinned archives in `versions.env`, verifies
their SHA-256 digests before extraction, builds a static TLS-enabled `nats.c`,
and runs one JetStream server on loopback. It generates a one-day CA,
certificate, and random token in a mode-0700 scratch directory. The trap stops
only the exact recorded client/server PIDs and removes that directory on every
exit path.

The runtime envelope is one server plus at most one client process, 64 file
descriptors for every server and client, a 4 MiB server file-store limit, 512-byte stream payloads,
one in-flight delivery, 4 stored messages, bounded 200--1,000 ms operations, and
256 MiB total scratch. Compilation uses at most two jobs. The committed TSV is
the deterministic semantic result; observed resource counts are printed
separately because they vary by host.

The auth check first proves that a raw correct-token plaintext NATS handshake
succeeds against a sequential non-TLS control. It then sends the same raw
handshake to the TLS-required listener and requires rejection, independently
of the nats.c client's automatic TLS behavior. Each client asserts its own
effective descriptor limit, and the long-lived reconnect client is measured
while its TLS socket is open.

The delivery controls use a 10-second ack wait to prove that a flushed `Nak`
causes generation-two delivery inside a one-second fetch, well before expiry.
They enqueue two distinct messages, hold the first unacked, require a timed-out
second fetch, then ack the first and require release of the second. Every 200 ms
empty fetch is checked against a monotonic 150--1,000 ms window. Every probe has
a 15-second self-alarm and is also tracked by exact PID under a 16-second
harness deadline.

After the semantic probes, the runner intentionally fails a nested fixture
that starts the real server and writes throwaway content. The parent verifies
that the nested trap stopped that exact PID and removed the content directory.

Tested: macOS arm64. The runner contains official-release hashes and platform
selection for macOS x86_64 and Linux x86_64/arm64, but those paths remain
unverified until run on those targets. Windows is unsupported by this POSIX
fixture.
