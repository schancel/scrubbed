# SQLite local manifest prerequisite (F09 #13)

This is evidence for a separately reviewed production decision, not manifest
adoption. The clean starting tree had no durable run manifest. The experiment
uses upstream SQLite 3.53.4, archive
[`sqlite-amalgamation-3530400.zip`](https://www.sqlite.org/2026/sqlite-amalgamation-3530400.zip),
published SHA3-256
`628a44cfe82c66aed1ccbbe85a562d2e33ebe64b3288981ed76285612227934e`.
The extracted header reports source ID
`2026-07-24 19:02:57 bf7c7f30031888f4e796e429ab3978879485813aaca6f641c7b33e4e09459bcc`.
The archive hash was verified locally before compilation. SQLite's
[copyright statement](https://www.sqlite.org/copyright.html) says the core is
public domain. The [download page](https://www.sqlite.org/download.html)
identifies this archive as the official amalgamation. Exact build and hash
verification instructions are in
[`experiments/sqlite_manifest/README.md`](../experiments/sqlite_manifest/README.md).

The proposed v1 row has key `(DocumentId, input digest, config digest, sink key)`;
the output presentation name is not an identity. `planned`, `committed`,
`failed`, and `uncertain` are database-constrained states. The composite primary
key supports exact lookup; the state/key index plus `LIMIT 16` supports bounded
replay. `PRAGMA user_version=1` is the prototype version marker. One local
writer is assumed. The harness checks WAL and `synchronous=FULL`, rejects an
invalid state in release mode, demonstrates a competing writer cannot begin,
and runs a TRUNCATE checkpoint on named `main`, asserting its defined 0/0
frame counters. [SQLite's checkpoint API](https://www.sqlite.org/c3ref/wal_checkpoint_v2.html)
leaves those counters undefined if the database name is null, even when the
call succeeds. It inserts 10,002 rows, then checks exact
lookup of a late row and a 16-row replay bound. This does not yet define
production migrations, digest algorithms, DocumentId encoding, or retention.

The crash proof invokes a separate child process that exits without cleanup at
four boundaries. It uses the existing F08 atomic piece sink for the publish,
then begins a SQLite transaction only after publish. The database and sink are
reopened by the parent; assertions are active under `ldc2 -release`.

| Interrupted child boundary | Reopened sink | Reopened DB row | Recovery decision |
| --- | --- | --- | --- |
| Before sink publish | absent | planned | safe to retry |
| After sink publish, before DB transaction | complete bytes | planned | mark uncertain; reconcile |
| After DB update, before DB commit | complete bytes | planned (rollback) | mark uncertain; reconcile |
| After DB commit | complete bytes | committed | skip only if identity/digests still match |

The harness checks unchanged input/config with committed sink A can skip while
failed sink B retries independently. A different input digest, config digest,
or DocumentId has no commit to reuse. An uncertain sink is not silently
treated as committed; later production logic must verify output digest and
sink-specific state before deciding whether to preserve, replace, or retry it.
No CLI resume behavior or provider-specific identity policy is claimed.

On macOS/APFS with LDC 1.43.0, a release-active run reported 10,002 rows,
16 replay rows, and D GC live bytes rising from 10,544 to 85,088 (delta
74,544). This is a bounded local observation, not a proof of constant total
RSS, SQLite page-cache bounds, TB-scale behavior, or general throughput. The
database is local and small. Production should measure RSS, page cache,
checkpoint latency, and lookup tail latency at realistic row counts.

SQLite's [WAL documentation](https://www.sqlite.org/wal.html) permits concurrent
readers but only one writer, requires same-host shared memory, and does not
support ordinary network-filesystem use. `synchronous=FULL` gives stronger WAL
sync behavior than NORMAL, but this test kills a process, not power or kernel;
it cannot establish power-loss durability. F08 syncs the output file before
rename but not the containing directory, so even the publish side lacks a
post-power-loss rename guarantee. Cross-database atomicity, distributed
coordination, and network filesystem support are outside this evidence.

The next contract, owned by @schancel after independent review, must choose
the production file format/version migration policy, digest and DocumentId
representation, API/CLI boundary, sink reconciliation policy, directory-sync
semantics, lifecycle and checkpoint owner, and platform support. Those choices
have migration cost; the evidence deliberately refuses a database adapter
framework, distributed coordinator, or speculative network-FS support.
Rollback of this landing deletes only this document and
`experiments/sqlite_manifest/`; no production dependency or schema is present.
