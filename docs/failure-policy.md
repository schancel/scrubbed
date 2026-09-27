# File failure policy

## Durable execution model

Canonical durable execution records one planned root and its complete
ordered final-event set. Sink failures bind the exact root and stable event
sink: failure before publication intent is `failed`, while failure after
intent is `uncertain`. Acknowledged document/stage/sink failures may allow
later roots to continue.

Run-fatal: output-policy, resource, scheduler, ledger acknowledgment,
event-set, and destination-ownership failures.

Failure-journal v3 exposes only opaque public sink IDs; targeted retry
selects matching outstanding state for the current canonical config and
never renders private sink labels.

The predecessor policy below remains relevant to retained v1/v2 offline
state but is no longer the canonical durable writer.

## Explicit v4 dispatch

Explicit v4 dispatch follows the same root-last durable policy:

- Reject and quarantine are acknowledged document outcomes with no output.
- Route and pass publish exactly one root.
- Detection/refinement/extractor/common failures map to bounded
  inspect/decode/filter phases and stable codes.

Explain/error records may carry bounded outcome/provenance/accounting, but
never raw paths, hints, source bytes, extracted bytes, archive entry names,
private sink keys, or free-form exception text. V3 behavior and exit
meanings are unchanged.

## Local manifest (opt-in durable failure ledger)

The opt-in local manifest is the durable failure ledger. An admitted file
may fail its read, decode, filter, or sink step and allow later files to
continue only after its exact `DocumentId`/sink row becomes `failed` or
`uncertain` **and** the injected failure-record port acknowledges it. The
current default port acknowledges by reading that manifest row back; a
future error-file format is not part of this policy.

The row is `uncertain` whenever sink publication may have begun, even if no
destination file is ultimately visible.

## What's fatal vs. per-document

Fatal (admission stops, active work drains, command exits 2):

- An acknowledgment or manifest write failure
- An output-policy violation
- An unclassifiable pre-plan input failure
- A scheduler failure
- A missing durable ledger
- Sink `ENOSPC`/`EDQUOT`/`EMFILE`/`ENFILE` resource errors

Per-document (retains classification): ordinary sink `EACCES`/`EIO` errors,
when their uncertain manifest state and failure record are acknowledged.

Previously committed rows remain intact after a fatal exit. A completed run
exits 0; a run with acknowledged per-document failures or unresolved retry
decisions exits 1.

## `--explain` output

`--explain` shows one decision per file.

- Every keyed manifest decision includes exact `document_id` and `sink_key`
  fields.
- Acknowledged failures include the count of prior terminal acknowledged
  manifest decisions in `detail`.
- Failed state/log acknowledgment is instead `unacknowledged` — never a
  claimed terminal `failed` or `uncertain` state.
- Summary counts include each processed file once.

The failure row itself remains the restart authority. Pre-plan open/read
faults cannot be assigned an exact manifest key and therefore remain fatal;
the injected read/decode probes exercise post-plan routing only.

## Harness

The release-active fault harness is `experiments/failure_policy/check.d`.
Build a release binary, then compile and run the checker against it:

```sh
DFLAGS=-d-version=FailurePolicyHarness dub build --build=release --compiler=ldc2 --force
ldc2 -I=source -of=/tmp/scrubbed-failure-check \
  experiments/failure_policy/check.d source/effects/sqlite_ffi.d \
  third_party/sqlite/sqlite3.o
/tmp/scrubbed-failure-check ./scrubbed
```
