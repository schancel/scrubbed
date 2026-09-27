# Document metadata: bounded standard + extension fields (v1)

**Status: first slice, plus #285's integration slice.** `domain.document_metadata`
itself (the value type, its functional mutators, and the `document-metadata:v1`
encode/decode pair) is a frozen v1 type from the first slice, unchanged here.
The integration slice wires it into `stages.contract.StageDocument` and adds
two self-registering stages so a document can carry accumulated metadata
across multiple stages in one compiled job:

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
  and the `document-metadata:v1` encoder/decoder. Frozen v1; unchanged by
  the integration slice.
- `experiments/document_metadata/check.d` — first-slice focused D checker:
  pinned wire bytes, decoder rejection paths, cap boundaries, a canary-byte
  leak scan, and a synthetic (non-`StageDocument`) stage-chain harness.
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
now depend on `domain.document_metadata`.

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

`domain.document_metadata` itself remains frozen v1 and unchanged. Not a
resolution of extension-key namespacing or a per-job-instance `sourceStage`
provenance mechanism — both remain explicitly deferred, per the issue's own
"Notes for later integration." Not a CLI or config surface beyond automatic
self-registration reachability. Not a change to `metadata-json:v1`/`v2`'s
own evidence/candidate format, and not a duplicate of #283's
`rights`/`MetadataField` machinery, which this module's v1 standard-key set
deliberately excludes. Not a change to `html_metadata_stage.d`
(`html-metadata`, issue #284's separate, disjoint fix) or to
`stages.pii_four_class.d`, `composition/compiler.d`, or
`composition/job_executor.d` — none of the four were touched by this slice.
