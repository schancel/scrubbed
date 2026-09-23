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

This first slice deliberately has no ZIP/container parsing, concrete Office,
PDF, image, or OCR adapter, executor wiring, CLI/JSON syntax, fan-out, join, or
general workflow graph. Later slices may consume these contracts without
changing shipping behavior introduced here.
