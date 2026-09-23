# Native document adapter feasibility

This bounded experiment does not adopt a parser. It asks whether specialist
PDF and DOCX engines can be isolated behind a subprocess and whether their
accuracy, license, dependency, startup, memory, and package costs justify a
later production design. The result is **no production recommendation yet**:
the PDF engines extract this corpus but both have strong-copyleft obligations,
and no acceptable native DOCX library path was established.

## Frozen corpus and method

The D fixture generator authors six deterministic, CC0-1.0 samples: training,
held-out layout, and malformed cases for both PDF and DOCX. The two layout
documents freeze content and geometry expectations before the candidate runs.
`samples.tsv` records their hashes; the release checker recomputes every hash.
The held-out PDF is a two-column page with a footer. Its semantic reading order
is left column, right column, footer. The held-out DOCX is a two-column table
whose semantic order is row-major, followed by a footer.

The corpus is deliberately tiny and synthetic. It can expose ordering,
omission, isolation, and packaging differences; it cannot support a general
accuracy claim for real-world documents, fonts, encodings, OCR, forms,
spreadsheets, presentations, macros, or encrypted files.

Every probe ran cold on arm64 macOS 26.6.2 through the D `run_limited.d` process
boundary: five CPU seconds, 16 MiB output, a 5 s wall limit for Poppler, MuPDF,
and Pandoc, and a 10 s wall limit for LibreOffice. `/usr/bin/time -l` outside
the boundary measured peak RSS. The boundary kills the complete process group
on timeout. Sanitized diagnostics retain only an error category. Inputs and
engines never used a network runtime path.

The exact evidence is in
[`experiments/document_adapters`](../experiments/document_adapters/README.md).
`observations.tsv` preserves the exact adapter argument vectors, sanitized
subprocess outcomes, and lossless hex of every extracted output. The
release-active checker decodes those bytes and recomputes all output hashes,
token streams, occurrence counts, token-order inversions, and layout scores;
`results.tsv` must match. Thirteen deliberate negative controls cover wrong
text/order, missing sample/hash/provenance/observation/arguments, malformed
success, crash, timeout, fabricated output hash/tokens/geometry, unknown
geometry structure, and malformed preserved bytes.

## Candidate provenance and licensing

| Candidate | Exact artifact | License finding | Installed/unpacked footprint |
| --- | --- | --- | ---: |
| Poppler `pdftotext` 26.02.0_1 | executable SHA-256 `a103b42f...ab55`; [pinned Homebrew formula](https://github.com/Homebrew/homebrew-core/blob/4ee5c1b81622e890f413a5eee4a2c144a42c3ceb/Formula/p/poppler.rb), source SHA-256 `dded8621...b77` | GPL-2.0-only; 48 receipt-listed runtime formulae need redistribution review | 32,676 KiB plus 237,836 KiB shared dependencies |
| MuPDF `mutool` 1.28.4 | executable SHA-256 `010caf0f...8717`; arm64 bottle SHA-256 `822f4ec6...74a1` | AGPL-3.0-or-later; upstream explicitly requires AGPL compliance or a commercial license | 104,876 KiB, self-contained; 41,785,560-byte executable |
| Pandoc 3.8.3 | executable SHA-256 `a8073327...78f8`; [pinned Homebrew formula](https://github.com/Homebrew/homebrew-core/blob/540199bb447f88e760f09f92090ff63c976e29ed/Formula/p/pandoc.rb), source SHA-256 `064775f5...8640` | GPL-2.0-or-later; native executable, but not a D-callable document library | 270,948 KiB plus 3,392 KiB GMP |
| LibreOffice Writer 26.8.0.3 | official aarch64 DMG SHA-256 `8858d805...9f89`; launcher SHA-256 `820ce37c...4bf` | MPL-2.0 primary license; its embedded third-party inventory is heterogeneous and unresolved for redistribution | 823,764 KiB application; 298,773,447-byte DMG |

The Poppler formula also pins `poppler-data` and lists the exact transitive
formula boundary. MuPDF was fetched as the immutable Homebrew bottle and
unpacked in private scratch. LibreOffice's official signed disk image was
mounted read-only in scratch, not installed. Upstream license references are
[MuPDF releases and licensing](https://mupdf.com/releases),
[Pandoc's user guide](https://pandoc.org/MANUAL.html), and
[LibreOffice licensing](https://www.libreoffice.org/licenses/).
These are engineering provenance findings, not legal advice.

## Measurements

Text accuracy is matched expected token occurrences over total expected
occurrences. Order errors are inversions against the frozen semantic order.
Geometry hits are four explicitly named, fixture-specific predicates derived
from line structure in the preserved output bytes. PDF checks are
`pdf_row_a_columns`, `pdf_row_b_columns`, `pdf_right_column_aligned`, and
`pdf_footer_after_columns`. DOCX checks are `docx_row1_cells`,
`docx_row2_cells`, `docx_right_column_aligned`, and
`docx_footer_after_table`. They describe this command output only, not source
document coordinates. Times and RSS are single cold observations, not
performance benchmarks.

| Candidate / held-out sample | Text | Order errors | Geometry | Cold elapsed | Peak RSS | Malformed case |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| Poppler / PDF layout | 12/12 | 4 | 4/4 | 38 ms | 9,863,168 B | rejected, exit 1 in 15 ms |
| MuPDF / PDF layout | 12/12 | 0 | 1/4 | 14 ms | 5,029,888 B | rejected, exit 1 in 10 ms |
| Pandoc / DOCX table | 12/12 | 0 | 4/4 | 99 ms | 43,974,656 B | rejected, exit 63 in 45 ms |
| LibreOffice / DOCX table | no output | not scored | not scored | isolated at 10,017 ms | 98,107,392 B | isolated at 10,015 ms |

Poppler's `-layout` output retained the two visual columns but interleaved the
rows, producing four token-order inversions against column-major reading.
MuPDF preserved semantic order but its plain-text mode carried no horizontal
column evidence; only the footer-after-columns line-order predicate passed.
Pandoc retained the DOCX table's row-major structure. Training documents were
also complete and ordered for all three feasible candidates.

LibreOffice timed out on training, held-out, and malformed DOCX inputs in the
same fresh-profile, read-only-image setup. Each process group was terminated at
the boundary, with no output. That is exact unsupported evidence, not an
accuracy score: this setup cannot establish LibreOffice as a viable adapter.

## Decision and residual risk

- PDF has two technically feasible isolated executables on this corpus.
  Neither is approved for production: Poppler requires GPL distribution
  analysis, while MuPDF's AGPL/commercial terms are a stronger blocker. A later
  decision must choose a licensing posture before engineering an adapter.
- DOCX remains unsupported. Pandoc can extract this fixture, but its GPL,
  268-MiB package, and lack of a stable D-native library surface make it poor
  production evidence. LibreOffice failed the boundary and adds an 804-MiB
  application plus unresolved embedded licenses.
- No safe native candidate was demonstrated for legacy DOC, XLS/XLSX,
  PPT/PPTX, ODT, OCR, or image-based PDF. None may inherit a zero cost or error
  rate from this experiment.
- Subprocess isolation bounds CPU, wall time, and output size, but this run did
  not establish a portable address-space cap, syscall sandbox, decompression
  ratio limit, or adversarial parser security. Synthetic malformed files do not
  replace a fuzz corpus or a security review.
- Package footprints are host observations. Poppler dependencies may already
  be shared; MuPDF's bottle is self-contained; LibreOffice embeds dependencies.
  These numbers are not cross-platform release estimates.

The narrow next decision is licensing, not implementation: decide whether an
optional separately installed GPL/AGPL process is acceptable. If it is, a new
ticket should evaluate real, rights-cleared documents and an OS sandbox. If it
is not, close the native PDF path. For Office, first identify a redistributable,
maintained library with a stable C ABI or explicitly accept an external Pandoc
process; do not build production support from this corpus.

Rollback deletes the experiment directory and this report. No production
dependency, format, CLI, workflow, or persistent state changed.
