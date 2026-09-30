/// Bridges `effects.pdfium_ffi`'s real, `dlopen()`-backed PDFium binding
/// into a pure `ExtractorApplyV1`, registered for `DetectionOutcomeV1.pdf`
/// in `extraction.registry`'s `coreExtractorRegistryV1()`. Issue #156's PDF
/// wiring slice -- the second concrete extraction route reachable through
/// the already-shipping v4 CLI dispatch surface (`scrubbed run --route
/// ... --action ... --route-option ...`), mirroring `extraction.ooxml_route`
/// (#583)'s own shape where the underlying engine allows it, and departing
/// from it in one real, disclosed way where it does not (see "Concurrency"
/// below).
///
/// ## No container-layer work needed (unlike DOCX)
///
/// `DetectionOutcomeV1.pdf` is a single-outcome `%PDF-`-signature match
/// (`extraction.detector`); `extraction.refinement.refineMediaV1` only
/// container-inspects `DetectionOutcomeV1.genericZip`, so a PDF-routed
/// `ExtractionInputV1.admittedZip` is always `null`. This route reads raw
/// bytes via `ExtractionInputV1.source.stream(...)` instead -- the same
/// `SourceContentV1` API `extraction.plain_text` already uses -- not any ZIP
/// accessor.
///
/// ## The injection: a module-global slot, not a closure -- disclosed, not
/// silently absorbed
///
/// `extraction.port.PdfBytesExtractV1` and `extraction.port.ExtractorFactoryV1`
/// are both plain D `function` pointers (no closure/context pointer), and
/// `extraction/` itself may never import `effects/` (see `extraction/
/// README.md`'s "no file, process, network, CLI, or adapter I/O" layering
/// rule). Neither fact is new -- `extraction.container`'s `ZipInflateV1`
/// solves the same "impure effects-layer implementation behind a pure
/// extraction-layer type" problem -- but `ZipInflateV1`'s real
/// implementation (`effects.zlib_ffi.zipInflateV1`) opens a *fresh*,
/// stateless system-libz handle on every single call, so it can be a single
/// compile-time-fixed `immutable` global with no further state. PDFium
/// cannot work that way: `FPDF_InitLibrary`/`FPDF_DestroyLibrary` are
/// process-lifetime operations, not meant to be repeated per document (see
/// `effects.pdfium_ffi`'s own module doc), and the library path itself is
/// operator-supplied at *run* time (`--route-option pdfium-library=...`),
/// not a compile-time constant the way zlib's pinned system path is. So the
/// one real, already-opened `PdfiumLibrary` instance for this process run
/// must be threaded from `cli.d` (which has both layers in view) down into
/// the `pure`-typed `PdfBytesExtractV1` this module's extractor calls --
/// and since neither `ExtractorFactoryV1` nor `PdfBytesExtractV1` can close
/// over a runtime value, that value is threaded through exactly one
/// module-private slot (`installedPdfBytesExtractV1` below) instead.
///
/// This is safe under this module's own real usage discipline, not merely
/// asserted: `extraction.registry.coreExtractorRegistryV1(pdfExtract)` sets
/// the slot (via `installPdfBytesExtractV1`, `package`-visible, not a
/// general-purpose public setter) synchronously, once, on the CLI's main
/// thread, immediately before `composition.dispatch_compiler
/// .compileDispatchJobV1` reads it back (also synchronously, on the main
/// thread, inside this module's own `configurePdfPdfiumV1` factory) to build
/// the `pdf-pdfium` route's `ConfiguredExtractorV1`. Both the write and the
/// one read happen before any worker thread is spawned (`cli.d`'s own
/// `--threads` fan-out only ever calls the *already-configured* extractor,
/// never the factory again) -- so this is a genuine write-once-then-
/// read-once-on-the-same-thread pattern, not shared mutable state under
/// concurrency, despite being a module-level variable. It is not marked
/// `__gshared` specifically because it is never touched from more than one
/// thread: ordinary (thread-local) storage is the more conservative choice
/// here, not an oversight.
///
/// ## Concurrency: the real hazard this slice resolves (unlike DOCX's cast)
///
/// `extraction.ooxml_route`'s own `pure`-cast boundary (`walkOoxmlDocumentV1`)
/// is a conservative *compiler-inference* gap in a pure-D dependency -- the
/// underlying function has no real shared mutable state at all. PDFium is
/// different in kind, not degree: its own C API documents itself as "not
/// thread-safe... expect to be called from a single thread"
/// (`effects.pdfium_ffi.d`'s own header doc), yet `scrubbed run` genuinely
/// calls into one shared, process-lifetime `PdfiumLibrary` handle from
/// multiple real `--threads` worker threads concurrently
/// (`composition.dispatch_executor.d`'s own two-thread concurrent-dispatch
/// unittest already proves this happens for every registered extractor, not
/// just this one). Silently reusing the DOCX slice's cast reasoning here
/// would be dishonest -- and `effects.llama_metadata_annotate_stage.d` (#65,
/// merged `f8268bb`), the closest existing precedent for a comparably
/// shared, comparably stateful FFI handle opened once and reused across
/// documents, does *not* address this exact hazard at all (no mutex, no
/// serialization of any kind around its own shared `LlamaLibrary`) -- a real,
/// disclosed gap in that precedent this slice does not repeat.
///
/// The real resolution lives in `effects.pdfium_ffi.LockedPdfiumLibraryV1`:
/// every call into the one shared `PdfiumLibrary` is serialized through a
/// `core.sync.mutex.Mutex`, so concurrent callers observe correct,
/// independent, non-corrupted results even though the underlying PDFium C
/// API itself is never called from more than one thread at a time. The
/// `pure` cast at that module's own single documented boundary
/// (`pdfBytesExtractV1`) is honest in the same sense
/// `effects.zlib_ffi.zipInflateV1`'s is: the function's *result* is a
/// deterministic function of its arguments once mutual exclusion is
/// guaranteed -- the mutex is exactly what makes that guarantee real, not
/// just assumed.
///
/// Deliberately out of scope this slice (see the accepted contract, issue
/// #156): Poppler/execve PDF wiring, OCR, Linux PDFium support.
module extraction.pdf_pdfium_route;

import extraction.contracts : ExtractionProvenanceV1, TextDocumentV1;
import extraction.port : ConfiguredExtractorV1, ExtractionInputV1,
    ExtractorConfigurationV1, ExtractorOptionsV1, PdfBytesExtractOutcomeV1,
    PdfBytesExtractResultV1, PdfBytesExtractV1;
import std.exception : enforce;

enum string pdfPdfiumImplementationV1 = "pdf-pdfium";
enum string pdfPdfiumVersionV1 = "pdf-pdfium/v1";

/// Delivered via the existing `--route-option` v4 dispatch surface (e.g.
/// `--route-option pdfium-library=text:<path>`), not a dedicated CLI flag --
/// see `cli.d`'s own `resolvePdfBytesExtractV1` for why: the real `dlopen()`
/// happens there (the one place with both `extraction`/`effects` in view),
/// *before* this factory ever runs, so by the time this factory sees the
/// option it is purely a required-presence/type check plus a clear error if
/// something upstream skipped that step -- the actual path *value* is not
/// otherwise consumed here. This corrects `effects.pdfium_ffi.d`'s own
/// previously recorded decision (its header doc, issue #156, 2026-09-27)
/// that any future wiring slice "MUST name that flag `--pdfium-library`
/// exactly" as a dedicated flag -- the option *key* (`pdfium-library`) is
/// preserved, only its delivery *mechanism* changes, per the accepted
/// next-slice contract's own correction.
enum string pdfiumLibraryOptionV1 = "pdfium-library";

/// Fixed, not caller-tunable in this slice (no second option is declared):
/// a generous but bounded ceiling matching real-world PDFs while still
/// refusing pathological inputs closed rather than silently hanging/
/// exhausting memory. 10,000 pages and 4 MiB of extracted text per page are
/// each far beyond any legitimate document this codebase's own #67
/// evaluation corpus or fixtures exercise.
enum size_t pdfPdfiumMaxPagesV1 = 10_000;
enum size_t pdfPdfiumMaxBytesPerPageV1 = 4 * 1024 * 1024;

/// A generous but bounded resource estimate, mirroring
/// `extraction.registry`'s own `ooxmlWordResourceBytesV1` idiom: proportional
/// to the worst-case bounded output this route can ever produce
/// (`pdfPdfiumMaxPagesV1 * pdfPdfiumMaxBytesPerPageV1` would be absurdly
/// large as a *per-document* estimate, so this instead mirrors the same
/// "generous fixed ceiling, not the literal worst case" choice
/// `ooxmlWordResourceBytesV1` already made).
enum size_t pdfPdfiumResourceBytesV1 = 64 * 1024 * 1024;

/// See this module's own doc comment, "The injection" section, for why this
/// is a module-private slot rather than a closure, and why that is safe
/// under this module's real, single-threaded-at-write-and-read-time usage.
private PdfBytesExtractV1 installedPdfBytesExtractV1;

/// Called by `extraction.registry.coreExtractorRegistryV1` only -- see this
/// module's own doc comment. Not a general-purpose public setter.
package void installPdfBytesExtractV1(PdfBytesExtractV1 extract) {
    installedPdfBytesExtractV1 = extract;
}

private final class PdfPdfiumConfigurationV1 : ExtractorConfigurationV1 {
    PdfBytesExtractV1 extract;
    this(PdfBytesExtractV1 extract) immutable {
        this.extract = extract;
    }
}

/// Requires exactly one option, `pdfium-library` (text) -- see
/// `pdfiumLibraryOptionV1`'s own doc comment for why its *value* is not
/// otherwise consumed here. Fails closed with a clear message if this
/// registration's injected capability was never installed (see this
/// module's own doc comment; in correct real usage `cli.d` always installs
/// it before this factory can ever run for a job that actually routes to
/// `pdf-pdfium`).
ConfiguredExtractorV1 configurePdfPdfiumV1(const ref ExtractorOptionsV1 options) {
    enforce(options.length == 1 && (pdfiumLibraryOptionV1 in options) !is null,
        "pdf-pdfium extractor requires pdfium-library only");
    options[pdfiumLibraryOptionV1].asText(); // presence/type already enforced above
    enforce(installedPdfBytesExtractV1 !is null,
        "pdf-pdfium extractor route was compiled with no PDFium library installed "
        ~ "(see cli.d's own pdfium-library install step)");
    return ConfiguredExtractorV1(&extractPdfPdfiumV1,
        new immutable PdfPdfiumConfigurationV1(installedPdfBytesExtractV1));
}

/// Fail-closed on anything but a well-formed, unencrypted, in-bounds PDF: a
/// malformed/corrupt document, an encrypted document, or either bound being
/// exceeded all throw rather than return silently-wrong or empty text --
/// the exception propagates to `composition.dispatch_executor`'s existing
/// per-document failure handling, the same fail-closed idiom
/// `extraction.plain_text`/`extraction.ooxml_route`'s own extractors already
/// use for their structural failures.
private TextDocumentV1 extractPdfPdfiumV1(ExtractionInputV1 input,
        immutable(ExtractorConfigurationV1) raw) pure {
    auto configuration = cast(immutable(PdfPdfiumConfigurationV1)) raw;
    enforce(configuration !is null, "invalid pdf-pdfium configuration");

    ubyte[] bytes;
    input.source.stream((const(ubyte)[] chunk) { bytes ~= chunk; });

    auto result = configuration.extract(bytes, pdfPdfiumMaxPagesV1,
        pdfPdfiumMaxBytesPerPageV1);
    final switch (result.outcome) {
    case PdfBytesExtractOutcomeV1.ok:
        break;
    case PdfBytesExtractOutcomeV1.malformed:
        enforce(false, "pdf-pdfium route: document is malformed");
        break;
    case PdfBytesExtractOutcomeV1.encrypted:
        enforce(false, "pdf-pdfium route: document is encrypted");
        break;
    case PdfBytesExtractOutcomeV1.pageLimitExceeded:
        enforce(false, "pdf-pdfium route: page count exceeds the fixed limit");
        break;
    case PdfBytesExtractOutcomeV1.textLimitExceeded:
        enforce(false, "pdf-pdfium route: a page's text exceeds the fixed limit");
        break;
    }

    auto text = renderPdfTextV1(result.pages);
    return TextDocumentV1.extractedOwned(input.document,
        cast(const(ubyte)[]) text, input.detection,
        pdfPdfiumImplementationV1, pdfPdfiumVersionV1, null,
        ExtractionProvenanceV1(input.detection.outcome, input.routeName,
            input.source.size));
}

/// "Good enough" plain-text rendering of extracted pages, in document
/// order: pages join with a blank line, matching a visible page break --
/// mirrors `extraction.ooxml_route.renderDocxTextV1`'s own paragraph-join
/// idiom, adapted to pages instead of blocks.
private string renderPdfTextV1(const(string)[] pages) pure {
    string result;
    bool first = true;
    foreach (page; pages) {
        if (!first) result ~= "\n\n";
        first = false;
        result ~= page;
    }
    return result;
}

version (unittest) {
    import content.pieces : Content, ContentPiece;
    import domain.document : Document, OutputName, SourceLocator;
    import extraction.contracts : DetectionOutcomeV1, DetectionResultV1,
        EvidenceKindV1, MediaEvidenceV1;
    import extraction.port : SourceContentV1;
    import std.conv : to;

    private ExtractionInputV1 fixtureInput(ubyte[] bytes) {
        auto document = Document(SourceLocator("test", "pdf", "one"),
            OutputName("one.pdf"));
        auto detection = DetectionResultV1.detected(DetectionOutcomeV1.pdf,
            [MediaEvidenceV1(EvidenceKindV1.signature,
                DetectionOutcomeV1.pdf, "pdf-header")],
            "test:v1", null, bytes.length, bytes.length, bytes.length);
        auto source = new Content([ContentPiece.own(bytes)]);
        return ExtractionInputV1(document, SourceContentV1.from(source),
            detection, "pdf", null);
    }

    /// A deterministic, pure, entirely-fake `PdfBytesExtractV1` -- no real
    /// PDFium involved -- so this module's own wiring/outcome-translation
    /// logic is fully proven under `dub test` without any operator-supplied
    /// real library. Encodes a tiny fixed protocol in `pdfBytes` itself:
    /// the first byte selects the outcome, the rest (for `ok`) becomes the
    /// (single) page's text.
    private PdfBytesExtractResultV1 fakePdfExtract(const(ubyte)[] pdfBytes,
            size_t maxPages, size_t maxBytesPerPage) pure {
        PdfBytesExtractResultV1 result;
        enforce(pdfBytes.length > 0, "fake extractor needs a selector byte");
        final switch (cast(PdfBytesExtractOutcomeV1) pdfBytes[0]) {
        case PdfBytesExtractOutcomeV1.ok:
            result.outcome = PdfBytesExtractOutcomeV1.ok;
            result.pages = [cast(string) pdfBytes[1 .. $].idup];
            break;
        case PdfBytesExtractOutcomeV1.malformed:
            result.outcome = PdfBytesExtractOutcomeV1.malformed; break;
        case PdfBytesExtractOutcomeV1.encrypted:
            result.outcome = PdfBytesExtractOutcomeV1.encrypted; break;
        case PdfBytesExtractOutcomeV1.pageLimitExceeded:
            result.outcome = PdfBytesExtractOutcomeV1.pageLimitExceeded; break;
        case PdfBytesExtractOutcomeV1.textLimitExceeded:
            result.outcome = PdfBytesExtractOutcomeV1.textLimitExceeded; break;
        }
        return result;
    }

    private ubyte[] fakePdfBytes(PdfBytesExtractOutcomeV1 outcome, string text = null) {
        return cast(ubyte) outcome ~ cast(ubyte[]) text.dup;
    }
}

unittest {
    import std.exception : assertThrown;

    installPdfBytesExtractV1(&fakePdfExtract);
    scope(exit) installPdfBytesExtractV1(null);

    ExtractorOptionsV1 options;
    import extraction.port : ExtractorOptionV1;
    options[pdfiumLibraryOptionV1] = ExtractorOptionV1.text("/fake/path");
    auto configured = configurePdfPdfiumV1(options);

    auto document = Document(SourceLocator("test", "pdf", "one"),
        OutputName("one.pdf"));
    auto okInput = fixtureInput(fakePdfBytes(PdfBytesExtractOutcomeV1.ok, "hello pdf"));
    auto text = configured(okInput);
    assert(text.id == document.id && text.outputName == document.outputName);
    assert(text.extractor == pdfPdfiumImplementationV1 &&
        text.extractorVersion == pdfPdfiumVersionV1);
    assert(text.provenance.routeName == "pdf" &&
        text.provenance.sourceOutcome == DetectionOutcomeV1.pdf);
    ubyte[] rendered;
    text.content.stream((const(ubyte)[] chunk) { rendered ~= chunk; });
    assert(cast(string) rendered == "hello pdf");

    // Every non-ok outcome fails closed (throws), never silently empty/wrong
    // text, and each is distinctly named in the failure message -- never
    // conflated with a different outcome.
    assertThrown(configured(fixtureInput(fakePdfBytes(PdfBytesExtractOutcomeV1.malformed))));
    assertThrown(configured(fixtureInput(fakePdfBytes(PdfBytesExtractOutcomeV1.encrypted))));
    assertThrown(configured(fixtureInput(fakePdfBytes(PdfBytesExtractOutcomeV1.pageLimitExceeded))));
    assertThrown(configured(fixtureInput(fakePdfBytes(PdfBytesExtractOutcomeV1.textLimitExceeded))));

    // Wrong/missing option.
    ExtractorOptionsV1 noOptions;
    assertThrown(configurePdfPdfiumV1(noOptions));
    ExtractorOptionsV1 wrongOption;
    wrongOption["unexpected"] = ExtractorOptionV1.text("x");
    assertThrown(configurePdfPdfiumV1(wrongOption));

    // Genuinely pure: compiles as an ExtractorApplyV1, the same compile-time
    // proof extraction.ooxml_route's own tests use.
    static assert(__traits(compiles, {
        import extraction.port : ExtractorApplyV1;
        ExtractorApplyV1 apply = &extractPdfPdfiumV1;
    }));
}

// No injected capability installed: fails closed with a clear message,
// never silently succeeds or dereferences null.
unittest {
    import extraction.port : ExtractorOptionV1;
    import std.exception : assertThrown;

    installPdfBytesExtractV1(null);
    ExtractorOptionsV1 options;
    options[pdfiumLibraryOptionV1] = ExtractorOptionV1.text("/fake/path");
    assertThrown(configurePdfPdfiumV1(options));
}

// Real concurrency proof at this module's own wiring layer (mirroring
// `composition.dispatch_executor.d:523-548`'s own two-thread pattern): many
// threads call the *same configured* `pdf-pdfium` extractor concurrently,
// each with its own distinct expected text, proving the wiring itself is
// safely reentrant -- no shared mutable state at this layer corrupts a
// concurrent call. This does not by itself prove the *real* PDFium engine's
// thread-safety fix (the actual shared `PdfiumLibrary` + mutex live in
// `effects.pdfium_ffi`, which `dub test` cannot exercise without a real,
// operator-supplied library -- see that module's own real concurrent-call
// proof, run manually against the pinned real artifact and reported
// alongside this slice's landing, mirroring `effects.pdfium_ffi.d`'s own
// established "real-artifact proof lives outside dub test" convention).
unittest {
    import core.thread : Thread;

    installPdfBytesExtractV1(&fakePdfExtract);
    scope(exit) installPdfBytesExtractV1(null);

    import extraction.port : ExtractorOptionV1;
    ExtractorOptionsV1 options;
    options[pdfiumLibraryOptionV1] = ExtractorOptionV1.text("/fake/path");
    auto configured = configurePdfPdfiumV1(options);

    enum threadCount = 8;
    enum iterationsPerThread = 50;
    string[threadCount] results;
    bool[threadCount] mismatched;
    Thread[threadCount] threads;
    // A helper function, not a loop body, creates each Thread: `index` is a
    // genuine by-value function *parameter*, so each call gets its own
    // distinct closure context. Looping and declaring `auto index = i;`
    // directly inside the loop body would (and, verified directly against
    // this compiler, does) let every iteration's delegate literal share one
    // captured storage slot for `index` -- the classic loop-variable-capture
    // hazard -- which would silently make every thread extract the *last*
    // iteration's text instead of its own, defeating this test's entire
    // purpose of proving per-call independence under real concurrency.
    Thread makeWorker(size_t index) {
        return new Thread({
            auto expected = "concurrent-page-" ~ index.to!string;
            foreach (iteration; 0 .. iterationsPerThread) {
                auto input = fixtureInput(
                    fakePdfBytes(PdfBytesExtractOutcomeV1.ok, expected));
                auto text = configured(input);
                ubyte[] bytes;
                text.content.stream((const(ubyte)[] chunk) { bytes ~= chunk; });
                if (cast(string) bytes != expected) mismatched[index] = true;
            }
            results[index] = expected;
        });
    }
    foreach (i; 0 .. threadCount) threads[i] = makeWorker(i);
    foreach (t; threads) t.start;
    foreach (t; threads) t.join;
    foreach (i; 0 .. threadCount) {
        assert(!mismatched[i], "concurrent pdf-pdfium call produced wrong text for thread " ~ i.to!string);
        assert(results[i] == "concurrent-page-" ~ i.to!string);
    }
}
