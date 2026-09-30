# Extraction boundary

This directory owns the pure, versioned boundary between source bytes and a
single text document. It imports only `domain`, `content`, and its own modules;
it performs no file, process, network, CLI, or adapter I/O.

- `contracts.d` defines normalized detector evidence and outcomes, complete
  finite route declarations, explicit policy actions, and the checked UTF-8
  `TextDocumentV1` boundary. Its read-only text surface structurally snapshots
  owned pieces without flattening them and rejects borrowed pieces until a
  retained-lease contract exists. A text document retains the original
  `Document` identity and `OutputName` together with detector/extractor
  versions, bounded warnings, and source-to-text provenance.
- `detector.d` inspects a configured bounded prefix. Content signatures and
  leading textual evidence are authoritative; MIME and filename extensions
  are capped, validated, retained as untrusted evidence, and never select a
  type by themselves. Conflicting strong evidence is an explicit ambiguous
  outcome. Results record the producer's inspection limit, available byte
  count, and exact bounded bytes inspected.
- `dispatch.d` selects exactly one route or policy from a complete table.
  Rules are indexed in canonical outcome order, so declaration order cannot
  change precedence.
- `container.d` inspects a deliberately narrow classic, single-disk ZIP
  subset (STORE and DEFLATE methods only) before any entry bytes are
  exposed. It validates the central/local index and canonical paths, applies
  cumulative byte, ratio, count, and nesting limits, and reports generic ZIP
  or exact OOXML Word marker evidence. A DEFLATE entry's real expanded byte
  count is discovered and charged incrementally during an injected
  `ZipInflateV1` decompressor's admission-time pass, never trusted from the
  ZIP header's declared (attacker-controlled) size. Accepted results
  snapshot piece descriptors and owned entry names. `streamEntry` serves
  STORE entry bytes as scoped, read-only logical windows capped at 64 KiB
  (unchanged, still STORE-only); `entryBytesV1` additionally returns one
  admitted entry's complete logical bytes regardless of compression method,
  for a DEFLATE entry by re-invoking the same injected decompressor and
  bounding the output at the already-charged expanded-byte budget (no new
  bomb surface, no unbounded copy beyond what decompression structurally
  requires). Retained windows never alias a reusable buffer, while borrowed
  backing stays caller-owned and closing its owner invalidates access.
- `ooxml_route.d` bridges `container.d`'s admitted ZIP entries and
  `ooxml_document.d`'s text walker into a pure `ExtractorApplyV1`, registered
  in `registry.d` as `ooxml-word` for `DetectionOutcomeV1.ooxmlWord`: it
  locates `word/document.xml`, reads it via `entryBytesV1`, walks it, and
  renders a "good enough" plain-text join of paragraphs and tables,
  preserving source identity/provenance and failing closed (throwing) on a
  missing part or malformed XML. This is the first DOCX route reachable
  through the already-shipping v4 CLI dispatch surface (`--route`/
  `--action`), with no new flag or command.
- `ooxml_document.d` walks already-decompressed `word/document.xml` bytes
  (via `dxml`, a pure-D, Boost-1.0, range-based XML 1.0 parser) into
  paragraphs, runs, plain text, and basic table structure, with
  `w:br`/`w:tab` folded in as text separators. It resolves element names
  against the namespace scope actually declared in the document rather than
  matching a literal `"w:"` prefix, and rejects ill-formed or truncated XML
  outright instead of repairing it (see its module doc for why `dxml` was
  chosen over the vendored `lexbor` HTML5 parser for this). It has no ZIP,
  FFI, or file-I/O awareness of its own; a caller resolves the real bytes
  first (e.g. via `container.d`'s admitted ZIP entries plus an injected
  `effects`-layer DEFLATE decompressor).
- `pdf_pdfium_route.d` bridges an injected `PdfBytesExtractV1` capability
  (the real, `effects.pdfium_ffi`-backed, mutex-serialized PDFium binding,
  injected from `cli.d` -- this module itself performs no I/O) into a pure
  `ExtractorApplyV1`, registered in `registry.d` as `pdf-pdfium` for
  `DetectionOutcomeV1.pdf`: it reads the whole source via
  `ExtractionInputV1.source.stream(...)` (no ZIP/container involvement --
  `DetectionOutcomeV1.pdf` is a direct signature match, never
  container-inspected), calls the injected capability, and translates its
  typed outcome (`ok`/`malformed`/`encrypted`/`pageLimitExceeded`/
  `textLimitExceeded`) into either a rendered `TextDocumentV1` or a
  fail-closed throw, preserving source identity/provenance the same way
  `ooxml_route.d` does. See that module's own doc comment for the real
  reasoning behind its module-global injection slot (no closure context is
  available across the `extraction`/`effects` layer boundary) and its
  concurrency resolution (a real `Mutex` around the shared `PdfiumLibrary`
  in `effects.pdfium_ffi.LockedPdfiumLibraryV1`, since PDFium's own C API is
  genuinely not safe to call from more than one thread at a time, unlike
  `ooxml_route.d`'s own conservative-purity-inference cast). This is the
  second concrete non-plain-text extraction route reachable through the
  already-shipping v4 CLI dispatch surface, delivered via the existing
  `--route-option pdfium-library=text:<path>` mechanism -- no new flag or
  command.
- `refinement.d` admits only a strong generic-ZIP detection to one bounded
  container inspection, maps the closed refusal vocabulary to normalized
  policy outcomes, and retains the inspector's complete accounting and
  optional admitted-byte capability.
- `port.d` defines the injected finite extractor registry. Registrations carry
  canonical implementation/version identity, accepted outcomes, descriptive
  resources, a typed option schema, and one configured source-to-text apply
  function. Extractor input is a descriptor-snapshotted read-only source view,
  configured apply functions are compiler-enforced pure, and owned UTF-8
  output has a pure checked `TextDocumentV1` construction path. There is no
  global registry or discovery mechanism.

These contracts still have no concrete image or OCR adapter, fan-out, join,
or general workflow graph. DOCX/OOXML (`ooxml_route.d`) and PDF
(`pdf_pdfium_route.d`) are both wired end to end now; headers/footers/
footnotes, fields, track changes, embedded objects, and legacy `.doc` remain
explicit DOCX non-goals, and Poppler/execve PDF wiring
(`effects.pdf_execve`) remains unwired -- a separate, later slice, per issue
#156's own established one-real-thing-per-slice discipline.

**Resolved (issue #587):** the real (`effects`-layer-injected) `ZipInflateV1`
decompressor is now wired into `refinement.d`'s live call into
`inspectZipContainerV1`, reached from `composition.dispatch_executor` on
every `scrubbed run`. `refineMediaV1` and `composition.dispatch_compiler`'s
`compileDispatchJobV1`/`CompiledDispatchJobV1` both gained an optional,
default-`null` `ZipInflateV1` parameter/field that is threaded straight
through, unchanged, to `inspectZipContainerV1` -- this subtree still
performs no I/O and constructs no decompressor itself. `source/cli.d`'s
`selectedRuntimePlan` (the real v4 compile path every `scrubbed run`
invocation uses) injects the real `effects.zlib_ffi.zipInflateV1`, so a
genuinely DEFLATE-compressed real-world `.docx` now reaches the
`ooxml-word` route through the live CLI end to end -- proven directly
against the real repo fixture `docx-training.docx` in `source/cli.d`'s own
`ooxml-word` dispatch tests (one STORE-compressed, one genuinely
DEFLATE-compressed). Real DEFLATE decompression correctness itself remains
separately proven, byte-for-byte against the real system decompressor,
directly at the `container.d`/`effects.zlib_ffi` layer.

# Shipping extractor

`registry.d` constructs the executable's finite registry on demand. It
contains `core-plain-text/v1`, whose required `max-output-bytes` is capped at
256 MiB; `ooxml-word/v1` (see `ooxml_route.d` above), which takes no options;
and `pdf-pdfium/v1` (see `pdf_pdfium_route.d` above), whose required
`pdfium-library` option is a presence/type check only -- the real
`dlopen()` of the operator-supplied path happens once in `cli.d`, before the
registry is even built (see `coreExtractorRegistryV1`'s own doc comment for
why). `plain_text.d` streams the read-only source once into independently
owned pieces and validates UTF-8 without flattening a second whole payload.
