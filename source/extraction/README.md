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
- `container.d` inspects a deliberately narrow classic, single-disk,
  STORE-only ZIP subset before any entry bytes are exposed. It validates the
  central/local index and canonical paths, applies cumulative byte, ratio,
  count, and nesting limits, and reports generic ZIP or exact OOXML Word
  marker evidence. Accepted results snapshot piece descriptors and owned entry
  names; entry bytes remain behind scoped, read-only logical windows capped at
  64 KiB. Retained windows never alias a reusable buffer, while borrowed
  backing stays caller-owned and closing its owner invalidates access.
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

These contracts still have no concrete Office, PDF, image, or OCR adapter,
shipping executor wiring, fan-out, join, DEFLATE support, or general
workflow graph. Later slices may consume them without changing shipping
behavior introduced here.
