# Document metadata: bounded standard + extension fields (v1)

**Status: first slice of issue #285.** This is a pure, repository-local
value type and wire format, not a completion of #285. It adds a bounded,
functional-style `DocumentMetadata` with an independent v1 standard-key set
(`title`, `author`, `date`, `url`) plus open, opaque, caller-chosen extension
fields, and a `document-metadata:v1` encode/decode pair. It does **not**
touch `stages.contract.StageDocument`, any `composition/*` file,
`stages.registry`, or any shipped stage — there is no wiring into the
pipeline in this slice. `domain.document_metadata` is self-contained:
nothing else in `source/` imports it, and the ordinary shipping binary has
no reachability into it.

## Files

- `source/domain/document_metadata.d` — the value, its functional mutators,
  and the `document-metadata:v1` encoder/decoder.
- `experiments/document_metadata/check.d` — focused D checker: pinned wire
  bytes, decoder rejection paths, cap boundaries, a canary-byte leak scan,
  and a synthetic stage-chain harness.
- This document.

Rollback is deleting these three files; nothing else references them.

## The value

`StandardMetadataKey` is a small, independent v1 enum (`title`, `author`,
`date`, `url`). It does **not** import or reuse `effects.html_metadata`'s
`HtmlMetadata` field taxonomy — the two are deliberately separate, and this
enum excludes `rights` (`effects.html_metadata`'s own field, unrelated to
this issue; see #283). Extension fields are an open, caller-chosen string
key mapped to an opaque, bounded byte value that this module never
interprets — the same "opaque bounded payload" shape as
`stages.contract.TerminalSideOutput.bytes()` and
`domain.frontier_contract.CandidateInput.provenance`.

Every entry, standard or extension, also carries a bounded, nonempty
`sourceStage` provenance string. This slice does not define how a stage
would obtain its own identity to populate that string (see "Notes for later
integration" on the issue); the checker's harness supplies literal strings,
which is sufficient to prove the type and wire format.

`DocumentMetadata.empty()` is the only constructor. `.withStandardField(key,
value, sourceStage)` and `.withExtensionField(key, value, sourceStage)` each
return a **new** value; the receiver is never mutated in place. Writing an
already-present standard or extension key is a construction-time failure
(an exception), never last-write-wins and never a "conflict" status field.

### Bounds (v1 identity; checked eagerly, at the write call)

| Cap | Value |
| --- | --- |
| `maxStandardValueBytes` | 512 |
| `maxExtensionKeyBytes` | 64 |
| `maxExtensionValueBytes` | 512 |
| `maxExtensionFields` | 32 |
| `maxSourceStageBytes` | 128 |
| `maxTotalEncodedBytes` | 64 KiB |

Every cap is enforced at the mutating call that would exceed it, not
deferred to encode time. `withStandardField`/`withExtensionField` internally
re-render the field-set (with a fixed-length placeholder in place of the
not-yet-bound `DocumentId`) through the same bounded `Writer` used by
`encodeDocumentMetadataV1`, so the aggregate `maxTotalEncodedBytes` cap is
also checked eagerly at construction time, not only at encode.

In practice, the combination of the five per-field caps already bounds any
legitimately constructible value's wire form to well under 64 KiB (roughly
44 KiB at 32 maximally-sized extension fields plus 4 maximally-sized
standard fields), so `maxTotalEncodedBytes` cannot be driven to its own
boundary through the public API alone. The checker proves this cap's
exactly-at/one-over boundary at `decodeDocumentMetadataV1`'s own upfront
length gate instead, using raw byte buffers, the same way
`effects.html_metadata`'s `Writer` unittest proves its cap in isolation
rather than via a maximal semantic document.

## Encode/decode and identity binding

`DocumentId` is never an input to any `DocumentMetadata` mutator, and
`DocumentMetadata` is never an input to `DocumentId.from`/`DocumentId.childOf`
— this holds by construction (the two are simply never wired together), not
because of new guard code added to `domain.document` (which this slice does
not touch).

`encodeDocumentMetadataV1(DocumentId id, const DocumentMetadata metadata)`
binds the id only at this boundary, mirroring
`effects.html_metadata.serializeHtmlMetadata(DocumentId id, const HtmlMetadata
metadata)` exactly. The wire, `document-metadata:v1`, is a fixed-key-order,
JSON-shaped text record with one trailing LF:

```
{"version":"document-metadata:v1","documentId":"<id>",
 "standard":{"title":<field|null>,"author":<field|null>,
             "date":<field|null>,"url":<field|null>},
 "extension":[{"key":"<key>","value":"<hex>","sourceStage":"<stage>"}, ...]}
```

(shown wrapped for readability; the actual wire has no inserted whitespace).
Each present standard field is `{"value":"<text>","sourceStage":"<stage>"}`;
an absent one is `null`. Extension values are opaque bytes and are
hex-encoded so the whole record stays plain text; they are never otherwise
interpreted.

`decodeDocumentMetadataV1(expectedId, wire)` fails closed — never open — on:
a wire bound to a different `DocumentId`; a standard key the fixed v1 grammar
does not recognize; a duplicate extension key; any cap violation, checked at
both the exactly-at (accepted) and one-over (rejected) boundary; and
malformed UTF-8 (the whole wire is UTF-8-validated before any parsing).
Every rejection raises a fixed, content-free diagnostic — no raw payload or
canary byte from the wire is ever echoed into an exception message.

## Proof (focused checker)

`experiments/document_metadata/check.d`:

- **Exact canonical wire bytes**, pinned for the empty value and for a
  representative standard-plus-extension combination, plus a full
  encode/decode round trip.
- **No silent overwrite** — a second write to an already-set standard or
  extension key is refused at construction time.
- **Decoder rejection** — wrong bound `DocumentId`, unknown standard key,
  duplicate extension key, and malformed UTF-8 (including UTF-8 corruption
  placed immediately adjacent to a canary-bearing field, to pin that
  proximity to a canary does not itself change the diagnostic).
- **Every cap, both sides of the boundary** — standard value bytes,
  extension key bytes, extension value bytes, extension field count, and
  source-stage bytes, each accepted exactly at the cap and rejected one
  byte/field over; the aggregate `maxTotalEncodedBytes` cap proved at
  decode's own size gate as described above.
- **Canary-byte scan** — a distinguishing marker placed in one extension
  value is confirmed to appear, hex-encoded, exactly once in the wire (never
  in its raw ASCII form), and every rejection-path diagnostic collected
  during the run is confirmed to contain neither the marker's ASCII nor its
  hex form.
- **Synthetic (non-production) stage-chain harness** — local structs and
  functions defined only in the checker, not `stages.contract.StageDocument`
  or any pipeline stage: a passthrough that never touches metadata carries
  it forward unchanged; a chain that writes a standard field then two
  extension fields accumulates correctly; a synthetic split into two
  children proves explicit per-child forwarding with no cross-child leakage
  of a child-only addition; a real `DocumentId` used as the synthetic
  document's identity token is confirmed unchanged across every step above,
  demonstrating (alongside the type's own never-wired construction) that
  identity and metadata do not perturb each other.

Because this checker builds with LDC `-O3 -release`, it uses plain runtime
comparisons rather than the `assert` statement (which `-release` elides) to
report each check, so nothing the proof depends on can be compiled away.

Run:

```sh
ldc2 -O3 -release -Isource -Iexperiments -of=.dub/document-metadata-check \
  experiments/document_metadata/check.d source/domain/document_metadata.d \
  source/domain/document.d source/crypto/sha256.d source/crypto/sha256_arm64.d \
  source/crypto/sha256_x86_64.d
.dub/document-metadata-check
```

The domain module's own `unittest` block (`ldc2 -unittest -Isource -main
-of=... source/domain/document_metadata.d source/domain/document.d
source/crypto/sha256.d source/crypto/sha256_arm64.d
source/crypto/sha256_x86_64.d`) exercises the same wire pinning, no-overwrite,
rejection, and cap-boundary paths as fast in-process regression coverage;
the checker above is the release/O3-built proof with the canary scan and the
synthetic stage-chain harness. The checker imports only
`domain.document_metadata`, `domain.document`, and Phobos — no filesystem,
network, registry, or pipeline-stage reachability.

## What this is not

Not wired into `StageDocument`, any pipeline stage, the compiler, the job
executor, or `stages.registry`. Not a CLI or config surface. Not a
resolution of `sourceStage` provenance mechanism, extension-key namespacing,
or `TerminalSideOutput` coexistence — those are explicitly deferred to a
separately groomed integration slice, per the issue's own "Notes for later
integration." Not a change to `metadata-json:v1`/`v2`'s own evidence/
candidate format, and not a duplicate of #283's `rights`/`MetadataField`
machinery, which this module's v1 standard-key set deliberately excludes.
