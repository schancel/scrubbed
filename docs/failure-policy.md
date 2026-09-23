# File failure policy

Canonical durable execution records one planned root and its complete ordered
final-event set. Sink failures bind the exact root and stable event sink;
failure before publication intent is `failed`, while failure after intent is
`uncertain`. Acknowledged document/stage/sink failures may allow later roots to
continue. Output-policy, resource, scheduler, ledger acknowledgment,
event-set, and destination-ownership failures are run-fatal. Failure-journal
v3 exposes only opaque public sink IDs; targeted retry selects matching
outstanding state for the current canonical config and never renders private
sink labels. The predecessor policy below remains relevant to retained v1/v2
offline state but is no longer the canonical durable writer.

The opt-in local manifest is the durable failure ledger. An admitted file may
fail its read, decode, filter, or sink step and allow later files to continue
only after its exact `DocumentId`/sink row becomes `failed` or `uncertain` and
the injected failure-record port acknowledges it. The current default port
acknowledges by reading that manifest row back; a future error-file format is
not part of this policy. The row is `uncertain` whenever sink publication may
have begun, even if no destination file is ultimately visible.

An acknowledgment or manifest write failure, output-policy violation,
unclassifiable pre-plan input failure, scheduler failure, missing durable
ledger, or sink `ENOSPC`/`EDQUOT`/`EMFILE`/`ENFILE` resource error is fatal.
Ordinary sink `EACCES`/`EIO` errors retain per-document classification when
their uncertain manifest state and failure record are acknowledged. On fatal
errors, admission stops, active work drains, and the command exits 2.
Previously committed rows remain intact. A completed run exits 0; a run with
acknowledged per-document failures or unresolved retry decisions exits 1.

`--explain` shows one decision per file. Every keyed manifest decision includes
exact `document_id` and `sink_key` fields. Acknowledged failures include the
count of prior terminal acknowledged manifest decisions in `detail`; failed
state/log acknowledgment is instead `unacknowledged`, never a claimed terminal
`failed` or `uncertain` state. The summary counts include each processed file
once. The failure row itself remains the restart authority. Pre-plan open/read
faults cannot be assigned an exact manifest key and therefore remain fatal;
the injected read/decode probes exercise post-plan routing only.

The release-active fault harness is `experiments/failure_policy/check.d`.
Build a release binary with `DFLAGS=-d-version=FailurePolicyHarness dub build
--build=release --compiler=ldc2 --force`, then compile that D checker with
`ldc2 -I=source -of=/tmp/scrubbed-failure-check
experiments/failure_policy/check.d source/effects/sqlite_ffi.d
third_party/sqlite/sqlite3.o` and run it against `./scrubbed`.
