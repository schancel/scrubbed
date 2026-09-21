# File failure policy

The opt-in local manifest is the durable failure ledger. An admitted file may
fail its read, decode, filter, or sink step and allow later files to continue
only after its exact `DocumentId`/sink row becomes `failed` or `uncertain` and
the injected failure-record port acknowledges it. The current default port
acknowledges by reading that manifest row back; a future error-file format is
not part of this policy. The row is `uncertain` whenever sink publication may
have begun, even if no destination file is ultimately visible.

An acknowledgment or manifest write failure, output-policy violation,
unclassifiable pre-plan input failure, scheduler failure, or missing durable
ledger is fatal. Admission stops, active work drains, and the command exits 2.
Previously committed rows remain intact. A completed run exits 0; a run with
acknowledged per-document failures or unresolved retry decisions exits 1.

`--explain` shows one decision per file. For acknowledged failures it includes
the exact document ID and sink key in `detail`; the summary counts include
each processed file once. The failure row itself remains the restart authority.

The release-active fault harness is `experiments/failure_policy/check.d`.
Build a release binary with `DFLAGS=-d-version=FailurePolicyHarness dub build
--build=release --compiler=ldc2 --force`, then compile that D checker with
`ldc2 -I=source -of=/tmp/scrubbed-failure-check
experiments/failure_policy/check.d source/effects/sqlite_ffi.d
third_party/sqlite/sqlite3.o` and run it against `./scrubbed`.
