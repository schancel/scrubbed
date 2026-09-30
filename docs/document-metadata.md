# Document metadata: bounded standard + extension fields (v1), plus a
# structured-section capability (v2)

**Status: first slice, #285's integration slice, plus #300's Slice 1.**
`domain.document_metadata`'s v1 value type, its functional mutators
(`.empty()`, `.withStandardField`, `.withExtensionField`), and the
`document-metadata:v1` encode/decode pair are frozen and byte-for-byte
unchanged by #300 Slice 1 -- see "`document-metadata:v2`: the structured-
section capability (#300 Slice 1)" below for what was added on top, and
"What this is not" for what #300 Slice 1 explicitly does not do (no stage,
executor, compiler, or preset wiring; no bug fix to `clean-web-document`'s
live metadata-loss gap). The integration slice wires v1 into
`stages.contract.StageDocument` and adds two self-registering stages so a
document can carry accumulated metadata across multiple stages in one
compiled job:

- `effects.html_metadata_annotate_stage` (`html-metadata-annotate`,
  non-terminal) reuses `parseHtml`/`extractHtmlMetadata` exactly as
  `effects.html_metadata_stage` does, but writes each "selected" standard
  field into `StageDocument.metadata` instead of producing a side output.
- `effects.document_metadata_publish_stage` (`document-metadata-publish`,
  terminal) encodes whatever metadata a job accumulated by that point into a
  single `TerminalSideOutput`.

No compiler or executor change was needed: `composition/compiler.d`'s
terminal-stage rule only ever prevented two stages from both being terminal
in one job; it never prevented a plain non-terminal stage from running
earlier in a chain before a terminal one. See "Integration slice: wiring
into `StageDocument`" below for the two required proofs.

## Files

- `source/domain/document_metadata.d` — the value, its functional mutators,
  and the `document-metadata:v1` encoder/decoder (frozen; unchanged by the
  integration slice or by #300 Slice 1), plus the additive
  `document-metadata:v2` structured-section type, mutator, and
  encoder/decoder (#300 Slice 1).
- `experiments/document_metadata/check.d` — first-slice focused D checker:
  pinned wire bytes, decoder rejection paths, cap boundaries, a canary-byte
  leak scan, and a synthetic (non-`StageDocument`) stage-chain harness, plus
  (#300 Slice 1) the equivalent v2 coverage: pinned v2 wire bytes, a
  ~1 MiB-class structured-section round trip, structured-section cap
  boundaries, v2 decoder rejection paths, and a v2 canary-leak scan.
- `source/stages/contract.d` — adds `DocumentMetadata metadata;` as a new
  trailing field on `StageDocument` (integration slice).
- `source/effects/html_metadata_annotate_stage.d` — the
  `html-metadata-annotate` stage (integration slice).
- `source/effects/document_metadata_publish_stage.d` — the
  `document-metadata-publish` terminal stage (integration slice).
- `experiments/document_metadata_integration/check.d` — focused D checker
  for the integration slice's two required proofs (below).
- This document.

Rolling back only the first slice means deleting the first three items in
this list, since the integration slice's two new stages and `StageDocument`
now depend on `domain.document_metadata`. Rolling back #300 Slice 1 alone
(leaving the first slice and the integration slice intact) means reverting
only the v2 additions inside `source/domain/document_metadata.d` and
`experiments/document_metadata/check.d`: Slice 1 touches no other file, and
nothing outside `domain.document_metadata` depends on the v2 capability yet
(see "What this is not").

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

The naive additive estimate above (roughly 44 KiB at 32 maximally-sized
extension fields plus 4 maximally-sized standard fields) assumes plain
printable-ASCII content. It understates the real encoded size for
legitimately constructible values: `withStandardField`/`withExtensionField`
render standard values, extension keys, and every entry's `sourceStage`
through the same `Writer.quoted()` used by `encodeDocumentMetadataV1`, which
JSON-escapes any byte outside `0x20..0x7E`/`"`/`\` as a 6-byte `\u00XX`
sequence. Escape-heavy content (e.g. non-printable filler bytes) in
max-length fields can inflate the encoded size well past the naive estimate
and legitimately drive `maxTotalEncodedBytes` to its own boundary through
ordinary public-API calls alone. In that case it is the mutator-side eager
`encodeBody` check inside `withStandardField`/`withExtensionField` — not
`decodeDocumentMetadataV1`'s upfront length gate — that enforces the cap,
and it does so correctly (rejecting cleanly, no corruption). The checker
proves both: a mutator-driven rejection via escape-heavy content, and
decode's independent upfront length gate at the exactly-at/one-over
boundary using raw byte buffers, the same way `effects.html_metadata`'s
`Writer` unittest proves its cap in isolation rather than via a maximal
semantic document.

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

## `document-metadata:v2`: the structured-section capability (#300 Slice 1)

Issue #300 found a real prerequisite gap: `pii-four-class`'s audit payload
(up to 4,096 findings, each up to ~144 bytes, plus up to ~80 bytes per union
envelope — `source/stages/pii_four_class.d`'s own `maxPiiAuditBytesV1 =
1024 * 1024`, a 1 MiB terminal cap) does not fit v1's flat scalar-extension
shape (`maxExtensionValueBytes = 512` per value, `maxTotalEncodedBytes = 64
KiB` aggregate) at any reasonable finding count. Converging `pii-four-class`
onto the shared-accumulator pattern that `html-metadata-annotate` /
`compressibility-annotate` already use — the actual fix for
`clean-web-document`'s live metadata-loss bug (verified real, but **not**
fixed by this slice; see "What this is not") — needs `DocumentMetadata` to
be able to hold something PII-scale first. This section is that
prerequisite: **additive only**, no stage/executor/compiler/preset change,
proven only through synthetic fixtures (`experiments/document_metadata/
check.d`), exactly as `docs/document-metadata.md`'s own #300 contract
specifies.

### The capability

A **structured section** (`StructuredSectionEntry`) is a caller-chosen
`sectionId` string plus an opaque, independently-bounded byte `payload`,
plus a `sourceStage` provenance string (the same three-part shape as
`ExtensionEntry`, but budgeted on a completely different scale).
`.withStructuredSection(sectionId, payload, sourceStage)` returns a new
value, exactly like `.withStandardField`/`.withExtensionField`; writing an
already-present `sectionId` is a construction-time failure, never
last-write-wins. **`withStandardField`/`withExtensionField` are entirely
unmodified by this addition** — they still check only the frozen v1
`maxTotalEncodedBytes` budget, unaware of and unaffected by any structured
section present on the same value.

### Bounds (v2 structured sections; checked eagerly, at the write call)

| Cap | Value | Justification |
| --- | --- | --- |
| `maxStructuredSectionIdentityBytes` | 64 | Matches `maxExtensionKeyBytes`'s existing precedent for a small, caller-chosen label — it identifies a section, it is not itself a payload. |
| `maxStructuredSections` | 4 | Deliberately small: this capability is for large, per-producer payloads (one section per producer), not a second general-purpose small-field mechanism like extension fields. Four covers the three convergence candidates issue #300 itself names (`pii-four-class`, `language-id-detect`, `topical-tags-extract`) plus one spare. |
| `maxStructuredSectionPayloadBytes` | 2 MiB (`2 * 1024 * 1024`) | Exactly **2x** `pii_four_class.d`'s own `maxPiiAuditBytesV1` (1024×1024 = 1 MiB). PII's own terminal cap already carries built-in headroom over its naive worst case (4,096 findings × (144 + 80) bytes ≈ 917,504 bytes, ~128 KiB under PII's 1 MiB cap); doubling PII's cap again here is a second, independent margin so this capability isn't the tightest constraint if a future producer's per-record cost or record count grows moderately before this cap is revisited. Not an arbitrary round number: it is anchored to the one concrete number the issue supplies, doubled for headroom. |
| `maxStructuredSectionsAggregatePayloadBytes` | 2 MiB (`2 * 1024 * 1024`) | Same order of magnitude as the per-section cap, **not** `maxStructuredSections` × the per-section cap. In practice only one producer is expected to need a PII-scale payload in a given document at once, so the whole capability is budgeted once, at "2x PII scale," rather than multiplicatively — this avoids an unbounded blow-up if `maxStructuredSections` is ever raised later. |
| `maxTotalEncodedBytesV2` | `maxTotalEncodedBytes + 2 * maxStructuredSectionsAggregatePayloadBytes + maxStructuredSections * (maxStructuredSectionIdentityBytes * 6 + 64)` = 4,261,632 bytes (≈4.06 MiB) | A closed-form sum of independently justified sub-budgets, not a rounded guess: the full v1 aggregate budget (reserved untouched for standard + scalar-extension fields — see above), plus the structured-section aggregate payload budget **hex-encoded** (`putHex` always doubles raw bytes — a fixed, non-escaping 2x expansion, unlike `Writer.quoted()`'s variable escape inflation), plus a worst-case JSON-escaped section identity (`\u00XX`, 6 bytes per source byte) and punctuation allowance per section slot. Because the v1 budget and the structured-section budget are each independently, unconditionally enforced regardless of mutation order, their sum can never be exceeded by any value built through the public API — this cap, and its own eager check inside `withStructuredSection`, are defense in depth, matching every other `.withX` mutator's eager-check idiom, not the only thing preventing overrun. |

A payload sized to `maxPiiAuditBytesV1` (1 MiB) fits with 50% headroom to
spare under `maxStructuredSectionPayloadBytes` (2 MiB) — the checker proves
exactly this with a synthetic ~1 MiB payload (see "Proof" below).

### v2 wire format

`document-metadata:v2` is additive over v1: the identical `"standard"`/
`"extension"` shape, plus a trailing `"structuredSections"` array.

```
{"version":"document-metadata:v2","documentId":"<id>",
 "standard":{"title":<field|null>,"author":<field|null>,
             "date":<field|null>,"url":<field|null>},
 "extension":[{"key":"<key>","value":"<hex>","sourceStage":"<stage>"}, ...],
 "structuredSections":[{"sectionId":"<id>","payload":"<hex>",
                         "sourceStage":"<stage>"}, ...]}
```

(shown wrapped for readability; the actual wire has no inserted whitespace).
`encodeDocumentMetadataV2`/`decodeDocumentMetadataV2` bind `DocumentId` only
at the encode boundary, exactly as v1 does. `decodeDocumentMetadataV2` fails
closed on everything `decodeDocumentMetadataV1` does, plus: a malformed
section entry (non-hex `payload` characters), an unknown/unversioned section
identity (the wire uses a key other than the strict `"sectionId"` literal —
this hand-rolled parser has no unknown-key tolerance, the same reason v1
itself needed a version bump rather than an in-place extension), a
truncated section body, and a duplicate section identity. As with v1, every
rejection raises a fixed, content-free diagnostic.

`encodeDocumentMetadataV1` itself gained one guard: it now refuses (rather
than silently dropping) a value that carries any structured section, since
v1 has no wire shape to represent one. This guard lives only in the public
`encodeDocumentMetadataV1` entry point, not in the internal `encodeBody`
helper `withStandardField`/`withExtensionField` also call for their own
eager v1-shape cap check — so a value built via
`.withStructuredSection(...).withStandardField(...)` remains fully
constructible; only actually encoding it as `document-metadata:v1` is
refused. No existing caller passes a v2-capability-bearing value to
`encodeDocumentMetadataV1` today (nothing outside this module can construct
one yet), so this is a forward-looking safety guard, not a behavior change
for any value reachable before this slice.

### A second convergence: `similarity-signature-v1` (issue #564)

`effects.similarity_signature_annotate_stage` is the second real producer to
converge onto `.withStructuredSection`, after `pii-four-class`'s
`pii-audit-v1`. It publishes a document-level `domain.similarity_signature
.SimilaritySignature` -- `hasKeys`, the canonical 64-lane MinHash array, the
algorithm-version tag, and the document's raw content length -- under section id
`similarity-signature-v1`, sourced from the same reasoning that moved
`pii-four-class` here: the 64-lane array alone is 512 bytes, exactly
`maxExtensionValueBytes`'s scalar cap, with zero room left for any other
field. Derived band hashes are recomputed from the lanes by the versioned
phase-2 reader rather than persisted as a second authority. The encoded
payload is roughly 547 bytes, comfortably inside the 2 MiB per-section cap.
See `docs/corpus-stages.md` for the corpus-level
`prune-near-duplicates` stage that reads this section back out of a
published sidecar.

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

**#300 Slice 1 additions (v2), same checker, same style:**

- **Exact canonical v2 wire bytes**, pinned for the empty value and for a
  representative standard-plus-extension-plus-structured-section
  combination, plus a full encode/decode round trip.
- **V1 regression, checked in the same run** — the exact same pre-#300
  `combo` value's `encodeDocumentMetadataV1` output is re-asserted
  byte-identical, and a value that *does* carry a structured section is
  confirmed to be refused (not silently truncated) by
  `encodeDocumentMetadataV1`.
- **A ~1 MiB-class structured-section fixture** — 4,096 synthetic
  fixed-size 256-byte records (a plausible worst-case shape, chosen to land
  on exactly `maxPiiAuditBytesV1` = 1,048,576 bytes), round-tripping
  byte-for-byte through `encodeDocumentMetadataV2`/`decodeDocumentMetadataV2`.
- **Every new v2 cap, both sides of the boundary** — structured section
  identity bytes, per-section payload bytes, the cross-section aggregate
  payload budget (proved with two sections whose individual sizes each stay
  under the per-section cap but whose sum crosses the aggregate cap,
  mirroring the existing escape-heavy-vs-field-count proof style), and
  section count, each accepted exactly at the cap and rejected one
  byte/section over — always eagerly, at the mutating call, never deferred
  to encode.
- **No silent overwrite** — a second write to an already-set section
  identity is refused at construction time.
- **V2 decoder rejection** — wrong bound `DocumentId`, duplicate section
  identity, unknown/unversioned section identity key, malformed section wire
  (non-hex payload), truncated section body, an unknown standard key (same
  fixed v1 grammar, still enforced under v2), malformed UTF-8, and an
  oversize wire (over `maxTotalEncodedBytesV2`).
- **V2 canary-byte scan** — the same canary discipline as v1, this time with
  the marker placed inside a structured section's payload rather than an
  extension value, confirming it appears hex-encoded exactly once and never
  leaks (ASCII or hex) into any rejection diagnostic collected during the
  run, v1 and v2 combined.

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

## Integration slice: wiring into `StageDocument`

`StageDocument` (`source/stages/contract.d`) gained `DocumentMetadata
metadata;` as a new trailing field. Every `StageDocument(...)` construction
site in the repository (82, at landing time) uses the 2-positional-arg
`(document, content)` form, so D's compiler-generated field-wise constructor
defaults the new field to `DocumentMetadata.init` and no existing call site
changed behavior.

Two new self-registering stages:

- **`html-metadata-annotate`** (`effects.html_metadata_annotate_stage`,
  `StageCardinality.oneToOne`, `SideOutputCapability.none`) reuses
  `parseHtml`/`extractHtmlMetadata` exactly as `html-metadata`
  (`effects.html_metadata_stage`, issue #284's separate, disjoint stage,
  untouched by this slice) does. For each of title/author/date/url whose
  `MetadataField.status == "selected"`, it calls `input.metadata =
  input.metadata.withStandardField(key, value, "html-metadata-annotate")`.
  A non-"selected" status leaves that standard key unset — the same "final
  decided value only" decision as the first slice. `content` is returned
  completely unmodified. `sourceStage` provenance is always this stage's own
  static implementation-key literal; there is no per-job-instance
  provenance mechanism in this slice.
- **`document-metadata-publish`** (`effects.document_metadata_publish_stage`,
  `StageCardinality.oneToOne`, `SideOutputCapability.terminal`, registered
  the same shape as `stages.pii_four_class`'s terminal registration) calls
  `encodeDocumentMetadataV1(input.document.id, input.metadata)` and wraps
  the result as the job's single `TerminalSideOutput` (schema
  `document-metadata-v1`). `content` passes through unchanged. It produces a
  valid, well-formed (if entirely empty) wire record even when no prior
  stage wrote any field, since `encodeDocumentMetadataV1` already
  round-trips `DocumentMetadata.empty()`.

**No compiler or executor change.** `composition/compiler.d`'s
terminal-stage admission rule requires (a) a terminal/side-output stage be
the last stage in the job, and (b) every stage in the job — including every
stage preceding the terminal one — be *registered* `StageCardinality
.oneToOne`. It was already true, before this slice, that this rule permits
any number of ordinary non-terminal `oneToOne` stages ahead of one terminal
stage; it only ever rejects a second stage that is also terminal-capable,
or a stage registered `maySplit` anywhere ahead of a terminal stage. Both
new stages are registered `oneToOne`, so a job chaining them ahead of an
existing terminal stage (or ending in the new terminal stage) is admissible
under the unchanged rule.

### Required proofs

`experiments/document_metadata_integration/check.d` (LDC `-O3 -release`,
same `expect`-not-`assert` pattern as the first-slice checker) proves, over
an authored fixture with CP1252-mojibake in an HTML `<title>`/`<meta
name="author">` and in body text, plus a synthetic PII email address:

- **Proof A** — compiling `[text-transform (fix-mojibake filter),
  html-metadata-annotate, pii-four-class (terminal, last)]`: the final
  `content` is `pii-four-class`'s output built from the mojibake-*repaired*
  text (byte-identical to an independently computed `scanPii`/
  `applyPiiPolicy` call over the repaired text, and explicitly *not* equal
  to the same computation over the raw mojibake bytes); exactly one
  `TerminalSideOutput` exists, and it is `pii-four-class`'s own unchanged
  `scrubbed-pii-audit-v1` schema; `payload.metadata` carries exactly what
  `html-metadata-annotate` wrote and is still present, byte-for-byte
  unchanged, after `pii-four-class` runs (`stages.pii_four_class.d`
  references `.metadata` nowhere — confirmed both by source inspection and
  by this exact-equality check).
- **Proof B** — compiling `[text-transform (fix-mojibake filter),
  html-metadata-annotate, document-metadata-publish (terminal, last)]`:
  `content` is unchanged from the mojibake-repaired text; exactly one
  `TerminalSideOutput` exists whose bytes exactly equal
  `encodeDocumentMetadataV1` computed independently for the
  actually-extracted fields.
- A **regression case** compiles a job naming both `pii-four-class` and
  `document-metadata-publish` as terminal stages (in both orders) and
  confirms the compiler still rejects it — a pre-existing cap, unchanged by
  this slice, not new behavior.
- A **no-metadata-written case** compiles `[document-metadata-publish]`
  alone and confirms it still emits one well-formed, empty
  `document-metadata-v1` side output.

`source/stages/text_transform.d`'s production registration never sets
`StageCardinality`, so it defaults to `maySplit`, even though the stage
always maps and never splits. That default is a pre-existing gap unrelated
to this slice (reproducible by compiling `[text-transform, pii-four-class]`
alone against the production registry, with no #285 stage involved at all):
the compiler's rule reads the *registered* cardinality, not runtime
behavior, so a `maySplit`-declared stage ahead of any terminal stage is
rejected regardless. The checker works around this only inside its own
local `StageRegistry` copy — it copies `text-transform`'s exact production
registration (same declaration, same factory, same filter placement) and
corrects only the `cardinality` field to `oneToOne`, matching what the
stage already, always does. This changes no production file and is not a
compiler or executor change; correcting the production registration itself
is out of this slice's scope and is left as a residual finding.

Run:

```sh
ldc2 -O3 -release -preview=dip1000 -i -Isource \
  experiments/document_metadata_integration/check.d \
  .dub/lexbor/liblexbor_static.a \
  -of=.dub/document-metadata-integration-check
.dub/document-metadata-integration-check
```

## What this is not

`domain.document_metadata`'s v1 shape itself remains frozen and unchanged
(#300 Slice 1 only adds v2 alongside it). Not a resolution of extension-key
namespacing or a per-job-instance `sourceStage` provenance mechanism — both
remain explicitly deferred, per the issue's own "Notes for later
integration." Not a CLI or config surface beyond automatic self-registration
reachability. Not a change to `metadata-json:v1`/`v2`'s own
evidence/candidate format, and not a duplicate of #283's
`rights`/`MetadataField` machinery, which this module's v1 standard-key set
deliberately excludes. Not a change to `html_metadata_stage.d`
(`html-metadata`, issue #284's separate, disjoint fix) or to
`stages.pii_four_class.d`, `composition/compiler.d`, or
`composition/job_executor.d` — none of the four were touched by the
integration slice above.

## What #300 Slice 1 is not

**Update (2026-09-27): Slice 3 has since landed** (`384f404`) and did exactly
the two things this section originally described as deferred/out-of-scope
for Slice 1 alone — `pii-four-class` now converges onto
`.withStructuredSection`, and `clean-web-document`'s live metadata-loss bug
is fixed. The bullets below accurately describe Slice 1's own boundaries at
the time it landed; they are historical from Slice 3 onward, not a
description of the current state. See the issue's own Slice 3 comment
thread and `docs/pii-four-class-stage.md`'s "Audit sidecar" section for the
current, landed shape.

The `document-metadata:v2` structured-section capability documented above is
domain-only and deliberately narrow. It is explicitly **not**, as of Slice 1
alone:

- **A stage, executor, compiler, or preset change.** No file under
  `source/stages`, `source/effects`, `source/composition`, or
  `source/job/presets.d` was touched. `domain.document_metadata` remains
  "deliberately unwired" per its own module doc comment: it imports nothing
  from `effects.html_metadata`, and nothing in `source/stages` or
  `source/composition` imports it, unchanged by this slice.
- **A convergence of `pii-four-class`, `language-id-detect`, or
  `topical-tags-extract`** onto the shared-accumulator pattern. This slice
  only makes that convergence *possible* for `pii-four-class` (the one that
  actually needs the new capability); no producer stage uses
  `.withStructuredSection` yet. That convergence, in that order, is deferred
  to later slices per the issue's own slicing decision.
- **A fix for `clean-web-document`'s live metadata-loss bug.** That bug is
  real (`html-metadata-annotate` runs non-terminally before the terminal
  `pii-four-class` stage, so its written metadata is silently discarded
  every run) and was verified against current source as part of scoping
  this work, but fixing it requires `pii-four-class` to stop being
  independently terminal — out of scope here, deferred to the
  `pii-four-class` convergence slice.
- **A relaxation of `document-metadata-publish`'s always-emits behavior** or
  of the executor's one-side-output-per-stage invariant
  (`composition/executor.d`) — both remain exactly as they were.
- **A new CLI or stage-option surface**, and no real registered stage of any
  kind is added. Everything above is proven only through
  `experiments/document_metadata/check.d`'s synthetic, non-`StageDocument`
  harness style.
