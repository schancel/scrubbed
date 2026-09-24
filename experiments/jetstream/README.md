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
descriptors per child, a 4 MiB server file-store limit, 512-byte stream payloads,
one in-flight delivery, 4 stored messages, bounded 200--1500 ms operations, and
256 MiB total scratch. Compilation uses at most two jobs. The committed TSV is
the deterministic semantic result; observed resource counts are printed
separately because they vary by host.

After the semantic probes, the runner intentionally fails a nested fixture
that starts the real server and writes throwaway content. The parent verifies
that the nested trap stopped that exact PID and removed the content directory.

Tested: macOS arm64. The runner contains official-release hashes and platform
selection for macOS x86_64 and Linux x86_64/arm64, but those paths remain
unverified until run on those targets. Windows is unsupported by this POSIX
fixture.
