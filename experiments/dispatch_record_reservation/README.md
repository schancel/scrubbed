# Dispatch-record `Appender!string` reservation (issue #234)

**Outcome: rejected. No production change.** A conservative lower-bound
`output.reserve(...)` was implemented for both dispatch-record builders in
`source/effects/dispatch_record.d`, measured across all seven contracted
record shapes, and reverted after the evidence showed it regresses the
`maximum-valid` shape's retained/final capacity -- the exact failure mode
this ticket was scoped to detect (the prior error-export Appender
experiment: fewer growth steps or a lower average cost is not sufficient if
total allocation or retained spare capacity worsens on a representative
shape).

## What was tried

Both private builders (`canonicalDispatchRecord` and
`canonicalDispatchProblemRecordV1`) got an `output.reserve(estimate)` call
immediately after `auto output = appender!string;`. The estimate used only:

- fixed schema/syntax literals (`.length` of the exact tokens the writer
  emits, so the estimate can't drift from the real format),
- already-available O(1) field lengths (`event.jobIdentity.length`,
  `event.routeName.length`, `event.reason.length`, etc.) and flags
  (`hasContainer`, `hasProvenance`),
- a fixed digit-width bound (20, the decimal-digit count of `ulong.max`) for
  every numeric accounting field, since computing an exact digit count would
  mean calling `to!string` a second time just to measure it -- an extra
  allocation this reservation exists to avoid,
- a fixed 64-byte contribution for `reason_hash` (always a SHA-256 hex
  digest, regardless of the reason string's length),
- checked/capped (saturating) arithmetic throughout, with the final estimate
  clamped to `maxDispatchRecordBytesV1` (16 KiB).

`event.warnings` was **never traversed or summed**. Warning content bytes
are not part of the estimate at all -- only the fixed `[`/`]` bracket
syntax is counted. Summing warning lengths would require iterating the
array, which the accepted contract explicitly forbids.

The validation/16 KiB-cap check, serializer architecture, public API, and
canonical byte output were all left untouched. The full diff that was
measured and then reverted is preserved at the bottom of this file for
reproducibility.

## Method

`check.d` in this directory calls only the public API
(`canonicalDispatchRecordV1` / `canonicalDispatchFailureRecordV1`), never
duplicates builder internals, and drives seven representative
`DispatchExecutionEventV1` fixtures through the **real** dispatch pipeline
(`composition.dispatch_executor` + `composition.dispatch_compiler` +
`extraction.detector`/`refinement`, with the real `core-plain-text`
extractor plus one throwaway echo extractor registered locally for
`generic-zip` routing) because the struct has no public constructor by
design -- every field is genuinely observed, not hand-poked:

| shape | how it's produced |
|---|---|
| `minimal` | clean 8-byte PNG signature, policy-rejected, 0 warnings, no route/container/provenance |
| `routed` | plain ASCII text routed through the real `core-plain-text` extractor, 0 warnings |
| `warning-heavy` | content engineered to trip 4 distinct detector warnings (truncated signature, prefix-limited, malformed filename hint, untrusted hint) without a route |
| `container` | the documented 22-byte empty-EOCD ZIP fixture (admitted, `hasContainer`), policy-rejected |
| `provenance` | routed plain text with one conflicting-extension-hint warning |
| `rejection` | the scalar `canonicalDispatchFailureRecordV1` builder directly (no event) |
| `maximum-valid` | the empty-EOCD ZIP routed through a custom extractor: container + route + provenance + 1 conflicting-hint warning together, emitted (not rejected) |

For each shape, `check.d`:

1. Calls the builder twice and asserts byte-for-byte equality (determinism)
   and the 16 KiB cap.
2. Records the exact length and a SHA-256 hex digest of the output.
3. Reads `core.memory.GC.sizeOf(result.ptr)` for the **final retained
   capacity** of the backing block, and `capacity - length` for **spare
   (wasted) capacity** -- a precise, black-box measurement that needs no
   access to `Appender` internals.
4. Disables the collector, calls the builder 10,000 times in two timed
   halves, and reads `GC.allocatedInCurrentThread()` deltas. Because
   collection is off, this delta counts every byte the GC ever handed out
   during the loop, including any abandoned buffer from an `Appender`
   reallocation -- not just what survives -- giving a genuine cumulative
   **allocation/growth/copy** measurement per call, comparable between
   halves as a leak/warm-up guard (both halves matched exactly in every run
   below).

To compare base vs. candidate, the *same* `check.d` is compiled twice: once
against `dispatch_record.d` at the merged base commit, once against
`dispatch_record.d` with the reservation patch applied, via LDC's
import-path shadowing (`-I=<base-copy> -I=source`, first match wins):

```sh
# base (shipped): production dispatch_record.d as merged
ldc2 -i -Isource -O3 -release -preview=dip1000 \
  third_party/sqlite/sqlite3.o .dub/lexbor/liblexbor_static.a .dub/zstd/libzstd_decompress.a \
  experiments/dispatch_record_reservation/check.d -of=/tmp/dispatch-record-reservation-base
/tmp/dispatch-record-reservation-base

# candidate: apply the diff at the bottom of this file to
# source/effects/dispatch_record.d, then:
ldc2 -i -Isource -O3 -release -preview=dip1000 \
  third_party/sqlite/sqlite3.o .dub/lexbor/liblexbor_static.a .dub/zstd/libzstd_decompress.a \
  experiments/dispatch_record_reservation/check.d -of=/tmp/dispatch-record-reservation-candidate
/tmp/dispatch-record-reservation-candidate
```

Both binaries are release/O3 (`-O3 -release`, matching the shipped
`release`/`release-unittest` `dub.json` build types).

## Results

`sha256` matched exactly for every shape between base and candidate --
the reservation never changed a canonical byte, key order, escaping, the
16 KiB cap, or exception behavior. `bytes_per_call` was identical between
the two measured halves in every run (no leak, no warm-up artifact).

| shape | base capacity | candidate capacity | base spare | candidate spare | base bytes/call | candidate bytes/call |
|---|---:|---:|---:|---:|---:|---:|
| minimal | 1024 | **816** | 455 | **247** | 2960 | **2192** |
| routed | 1024 | **816** | 394 | **186** | 2960 | **2192** |
| warning-heavy | 1024 | **816** | 321 | **113** | 2960 | **2192** |
| container | 1024 | 1024 | 200 | 200 | 2960 | **2400** |
| provenance | 1024 | **816** | 355 | **147** | 2960 | **2192** |
| rejection | 1024 | **816** | 455 | **247** | 2064 | **848** |
| maximum-valid | 1024 | **1360 (worse)** | 122 | **458 (worse)** | 2960 | 2736 |

Six of seven shapes improve on every axis: smaller final capacity, less
retained spare capacity, and lower cumulative bytes allocated per call
(roughly 19-59% less, depending on shape). The scalar `rejection` builder
in particular improves the most (2064 -> 848 bytes/call, -59%), because its
accounting block is a fixed all-zero literal and every other field is a
tight O(1) length -- there is almost no lower-bound slack to pay for.

`maximum-valid` -- the shape combining route, container, provenance, and a
warning, i.e. the record closest to the 16 KiB ceiling and the one most
representative of a "worst case" -- **regresses**. Its final retained
capacity grows from 1024 to 1360 bytes (+33%) and its spare (wasted)
capacity nearly quadruples, from 122 to 458 bytes. The cumulative
allocation-bytes-per-call metric still looks slightly better (2736 vs.
2960), which is precisely why the contract required checking *both*
metrics together: a call-count/average-bytes view alone would have hidden
this regression.

The cause: `maximum-valid` carries 9 numeric accounting fields (3 base +
6 container fields). Each one is bounded by the reservation at the proven
but generic 20-decimal-digit cap (`ulong.max` width), while the real values
in this fixture are 1-4 digits. That slack compounds across 9 fields into
enough over-reservation that the GC's block-size-class rounding lands the
`reserve()` call in a strictly larger bucket than the one the *unreserved*
growth path settles into naturally. Fewer/no growth steps did not offset a
larger final allocation -- the same class of failure the prior
error-export Appender experiment found for compiler-coalesced
concatenation vs. a hand-reserved `Appender`.

## Decision

Per the accepted contract: *"Reject the production edit if any
representative shape materially regresses allocation/copies/capacity or if
improvement exists only in source/IR shape."* `maximum-valid` materially
regresses retained/final capacity. **The reservation is rejected and
`source/effects/dispatch_record.d` is unchanged from the merged base.**
This experiment and its evidence are the only artifacts this ticket adds.

A narrower version that special-cases (or drops) the numeric-field bound
only when `hasContainer` is true might avoid the regression, but that
starts trading the "no guessing, no second traversal" simplicity this
contract required for a shape-specific tuning exercise -- out of scope for
this bounded evaluation. If a future ticket wants to revisit this, the
`maximum-valid` shape above is the one to re-check first.

## Reproducing: the measured (and reverted) candidate diff

```diff
--- a/source/effects/dispatch_record.d
+++ b/source/effects/dispatch_record.d
@@ -28,6 +28,7 @@ private string canonicalDispatchRecord(ref DispatchExecutionEventV1 event,
         DispatchUnitDomainV1 domain, size_t selectedOrdinal) {
     auto output = appender!string;
+    output.reserve(dispatchRecordReserveEstimateV1(event));
     output.put(`{"schema":`); putQuoted(output, dispatchRecordSchemaV1);
@@ -129,6 +130,8 @@ private string canonicalDispatchProblemRecordV1(string jobIdentity,
         size_t selectedOrdinal) {
     auto output = appender!string;
+    output.reserve(dispatchProblemRecordReserveEstimateV1(jobIdentity, document,
+        status, outcome, phase, code));
     output.put(`{"schema":`); putQuoted(output, dispatchRecordSchemaV1);
@@ -152,6 +155,97 @@ private void putQuoted(ref Appender!string output, string value) {
     JSONValue(value).toString(output);
 }
+
+private size_t addCapped(size_t total, size_t delta) pure @safe {
+    auto sum = total + delta;
+    return sum < total ? size_t.max : sum;
+}
+
+private size_t dispatchRecordReserveEstimateV1(ref DispatchExecutionEventV1 event) {
+    enum size_t numericDigitsV1 = 20; // decimal digits in ulong.max
+    enum size_t unitIdBytesV1 = `"unit:v1:`.length + 64 + 1;
+    size_t total = `{"schema":`.length + 2 + dispatchRecordSchemaV1.length;
+    total = addCapped(total, `,"job_identity":`.length + 2 + event.jobIdentity.length);
+    total = addCapped(total, `,"document_id":`.length + 2 +
+        event.source.document.id.text.length);
+    total = addCapped(total, `,"unit_id":`.length + unitIdBytesV1);
+    total = addCapped(total, `,"status":`.length + 2 + statusName(event.kind).length);
+    total = addCapped(total, `,"outcome":`.length + 2 +
+        outcomeName(event.detection.outcome).length);
+    total = addCapped(total, `,"action":`.length + 2 +
+        actionName(event.action.kind).length);
+    total = addCapped(total, `,"detector_version":`.length + 2 +
+        event.detection.detectorVersion.length);
+    total = addCapped(total, `,"warning_codes":[`.length + `]`.length);
+    if (event.routeName.length) {
+        total = addCapped(total, `,"route":`.length + 2 + event.routeName.length);
+        total = addCapped(total, `,"extractor":`.length + 2 + event.extractor.length);
+        total = addCapped(total, `,"extractor_version":`.length + 2 +
+            event.extractorVersion.length);
+    }
+    if (event.hasContainer) {
+        auto container = event.container;
+        total = addCapped(total, `,"container_status":`.length + 2 +
+            (container.status == ZipInspectionStatusV1.admitted
+                ? "admitted".length : "refused".length));
+        total = addCapped(total, `,"container_reason":`.length + 2 +
+            containerReason(container.reason).length);
+    }
+    if (event.reason.length)
+        total = addCapped(total, `,"reason_hash":`.length + 2 + 64);
+    if (event.hasProvenance) {
+        auto provenance = event.provenance;
+        total = addCapped(total, `,"provenance":{"route":`.length + 2 +
+            provenance.routeName.length + `,"source_bytes":`.length +
+            numericDigitsV1 + `}`.length);
+    }
+    total = addCapped(total, `,"accounting":{"available_bytes":`.length + numericDigitsV1);
+    total = addCapped(total, `,"bytes_inspected":`.length + numericDigitsV1);
+    total = addCapped(total, `,"inspection_limit":`.length + numericDigitsV1);
+    if (event.hasContainer) {
+        total = addCapped(total, `,"container_source_bytes":`.length + numericDigitsV1);
+        total = addCapped(total, `,"container_bytes_examined":`.length + numericDigitsV1);
+        total = addCapped(total, `,"container_compressed_bytes":`.length + numericDigitsV1);
+        total = addCapped(total, `,"container_expanded_bytes":`.length + numericDigitsV1);
+        total = addCapped(total, `,"container_entries":`.length + numericDigitsV1);
+        total = addCapped(total, `,"container_max_depth":`.length + numericDigitsV1);
+    }
+    total = addCapped(total, `}}`.length);
+    return total > maxDispatchRecordBytesV1 ? maxDispatchRecordBytesV1 : total;
+}
+
+private size_t dispatchProblemRecordReserveEstimateV1(string jobIdentity,
+        DocumentId document, string status, DetectionOutcomeV1 outcome,
+        string phase, string code) {
+    enum size_t unitIdBytesV1 = `"unit:v1:`.length + 64 + 1;
+    size_t total = `{"schema":`.length + 2 + dispatchRecordSchemaV1.length;
+    total = addCapped(total, `,"job_identity":`.length + 2 + jobIdentity.length);
+    total = addCapped(total, `,"document_id":`.length + 2 + document.text.length);
+    total = addCapped(total, `,"unit_id":`.length + unitIdBytesV1);
+    total = addCapped(total, `,"status":`.length + 2 + status.length);
+    total = addCapped(total, `,"outcome":`.length + 2 + outcomeName(outcome).length);
+    total = addCapped(total,
+        `,"action":"failure","detector_version":"unknown","warning_codes":[]`.length);
+    total = addCapped(total, `,"phase":`.length + 2 + phase.length);
+    total = addCapped(total, `,"code":`.length + 2 + code.length);
+    total = addCapped(total, `,"reason_hash":`.length + 2 + 64);
+    total = addCapped(total,
+        `,"accounting":{"available_bytes":0,"bytes_inspected":0,"inspection_limit":0}}`.length);
+    return total > maxDispatchRecordBytesV1 ? maxDispatchRecordBytesV1 : total;
+}
```
