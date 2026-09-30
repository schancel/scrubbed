/// Real, `dlopen()`-backed binding to an operator-supplied prebuilt PDFium
/// (`bblanchon/pdfium-binaries`) shared library, plus a bounded, in-memory
/// page-text extraction function built on it. Issue #156's second slice on
/// top of `docs/pdfium-evaluation.md`'s real, independently-reproduced
/// artifact/symbol evidence (issue #297, `experiments/pdfium_check/
/// evaluate.d`), and the first module in this codebase using a *fourth*
/// trust pattern, distinct from every existing FFI precedent:
///
///   - `effects.curl_ffi`: link-time-links the OS-provided libcurl via
///     `dub.json`'s `"libs"` array.
///   - `effects.zlib_ffi`: `dlopen()`s a *pinned system path*
///     (`/usr/lib/libz.1.dylib`), always present on macOS.
///   - `effects.pdf_execve` (see `docs/pdf-execve-fallback.md`): `execve`s
///     an already-installed host tool (Poppler `pdftotext`) found via PATH.
///   - **This module**: PDFium has no canonical, always-present system
///     install path and is not OS-provided. `libpdfium.dylib`'s path is
///     never fetched, vendored, guessed, or read from an environment
///     variable by this module or anything else in `source/` -- it is
///     supplied explicitly by the *operator*, as a caller-provided string,
///     at the call site of `PdfiumLibrary.open`. The artifact's entire
///     provenance is the operator's own responsibility; this module places
///     no more trust in it than "resolves the exact symbols this module
///     calls, or is rejected outright" (see `PdfiumLibrary.open` below).
///
/// **Flag-name decision (issue #156, 2026-09-27), corrected by the PDF-wiring
/// slice (issue #156, 2026-09-30 owner decision).** The original decision
/// recorded here required a dedicated `--pdfium-library` CLI flag for any
/// future wiring slice. That decision predated the DOCX/OOXML wiring slice
/// (#583) establishing `ExtractorOptionDeclarationV1`/`--route-option` as
/// this codebase's real per-extractor-option delivery mechanism -- the PDF
/// wiring slice's own accepted contract corrected this explicitly: the
/// option *key* (`pdfium-library`) is preserved, but it is delivered via
/// `--route-option pdfium-library=text:<path>` (see
/// `extraction.pdf_pdfium_route.pdfiumLibraryOptionV1`), not a dedicated
/// flag. `experiments/pdfium_extract/check.d` still uses its own
/// standalone `--pdfium-library` flag -- that checker is not the CLI, has
/// no `--route-option` concept, and is unaffected by this correction.
///
/// **Wiring status (issue #156, PDF-wiring slice).** This module is now
/// reachable from `scrubbed run` via the `pdf-pdfium` v4 dispatch route
/// (`extraction.pdf_pdfium_route`, registered in
/// `extraction.registry.coreExtractorRegistryV1`). PDFium's own C API
/// (`public/fpdfview.h`) documents itself as not thread-safe ("None of the
/// PDFium APIs are thread-safe. They expect to be called from a single
/// thread"); `PdfiumLibrary`/`extractPdfTextV1` below still do no locking of
/// their own and still inherit that constraint onto their direct caller --
/// but `scrubbed run` genuinely calls into one shared, process-lifetime
/// `PdfiumLibrary` from multiple `--threads` worker threads concurrently, so
/// no *direct* caller of this module's own primitives may be multi-threaded
/// without its own serialization. `LockedPdfiumLibraryV1` below is that
/// serialization: it wraps exactly one `PdfiumLibrary` and one
/// `core.sync.mutex.Mutex`, and is the only PDFium entry point
/// `extraction.pdf_pdfium_route`'s injected `PdfBytesExtractV1` ever calls
/// into -- see that module's own doc comment, "Concurrency" section, for
/// the full disclosed reasoning (including why this is a real fix, not the
/// gap `effects.llama_metadata_annotate_stage.d`'s comparable shared handle
/// left unaddressed).
///
/// Portability (issue #353): excluded from the Linux build via `dub.json`'s
/// `excludedSourceFiles-linux`, unlike `effects.curl_ffi`/`effects.zlib_ffi`/
/// `effects.lexbor_ffi`. Those wrap either an OS-provided system library or
/// this repo's own locally-compiled vendored source; this module instead
/// wraps an *operator-supplied prebuilt binary* artifact
/// (`bblanchon/pdfium-binaries`) that was independently evaluated and
/// pinned specifically for macOS arm64 (`docs/pdfium-evaluation.md`, issue
/// #297). Widening this module's version gate without an equivalent
/// Linux-artifact evaluation would assert a verification that was never
/// done, so it stays macOS-only for now; a real Linux PDFium binary
/// evaluation is separate, unstarted follow-up work, not part of this
/// ticket's scope. Since nothing yet imports this module (see above), the
/// exclusion changes no observable Linux behavior.
module effects.pdfium_ffi;

import core.stdc.config : c_ulong;
import core.sync.mutex : Mutex;
import core.sys.posix.dlfcn : dlclose, dlopen, dlsym, RTLD_LOCAL, RTLD_NOW;
import extraction.port : PdfBytesExtractOutcomeV1, PdfBytesExtractResultV1,
    PdfBytesExtractV1;
import std.string : toStringz;
import std.utf : toUTF8;

version (OSX) {
    version (AArch64) {} else static assert(0,
        "PDFium (bblanchon/pdfium-binaries) ABI is only verified for macOS arm64");
} else static assert(0,
    "PDFium (bblanchon/pdfium-binaries) ABI is only verified for macOS arm64");

// extern(C) function-pointer typedefs. The first twelve are exactly the
// symbols `experiments/pdfium_check/evaluate.d` already proved real,
// loadable, and ABI-compatible with a D FFI caller (see
// docs/pdfium-evaluation.md's "Functional proof" section); signatures
// verified directly against the real, pinned `public/fpdfview.h` /
// `public/fpdf_text.h` headers (commit
// `a84323421e94f484faca52dd9d027934eba42ab8`, the same commit
// `docs/pdfium-evaluation.md` pins). `FPDF_LoadMemDocument`
// is the thirteenth: the in-memory-load API this slice actually calls
// instead of `FPDF_LoadDocument`'s file-path form (which the evaluation
// harness used only for its own on-disk-fixture convenience). Both are
// resolved so this module's proven symbol surface stays exactly the
// evaluation's set, plus the one addition this slice's design requires.
private alias FPDF_InitLibrary_t = extern (C) void function();
private alias FPDF_DestroyLibrary_t = extern (C) void function();
private alias FPDF_GetLastError_t = extern (C) c_ulong function();
private alias FPDF_LoadDocument_t = extern (C) void* function(const(char)*, const(char)*);
private alias FPDF_LoadMemDocument_t = extern (C) void* function(const(void)*, int, const(char)*);
private alias FPDF_CloseDocument_t = extern (C) void function(void*);
private alias FPDF_GetPageCount_t = extern (C) int function(void*);
private alias FPDF_LoadPage_t = extern (C) void* function(void*, int);
private alias FPDF_ClosePage_t = extern (C) void function(void*);
private alias FPDFText_LoadPage_t = extern (C) void* function(void*);
private alias FPDFText_ClosePage_t = extern (C) void function(void*);
private alias FPDFText_CountChars_t = extern (C) int function(void*);
private alias FPDFText_GetText_t = extern (C) int function(void*, int, int, ushort*);

/// `FPDF_GetLastError()` codes this module distinguishes, from the real
/// `public/fpdfview.h` (`#define FPDF_ERR_* ...`). Only the two outcomes
/// this module's typed result distinguishes are named; every other nonzero
/// code (`FPDF_ERR_UNKNOWN` 1, `FPDF_ERR_FILE` 2, `FPDF_ERR_SECURITY` 5,
/// `FPDF_ERR_PAGE` 6) folds into the generic `malformed` outcome.
private enum c_ulong fpdfErrFormat = 3;
private enum c_ulong fpdfErrPassword = 4;

/// A content-free diagnostic for `PdfiumLibrary.open` failure: never
/// includes the operator-supplied path, `dlerror()` text, or any detail
/// about which symbol (if any) failed to resolve -- only that the load
/// failed closed. Matches `effects.zlib_ffi.SystemZlib.open`'s discipline of
/// returning `null` on any load/link failure rather than a partial binding.
enum string pdfiumLoadFailureMessage =
    "PDFium library failed to load: the supplied path does not exist, is "
    ~ "not a valid PDFium dynamic library for this platform, or is missing "
    ~ "a required symbol.";

/// Real `dlopen()`/`dlsym()`-backed PDFium binding lifecycle. Construct via
/// `open`, never directly. Owns exactly one native library handle.
final class PdfiumLibrary {
    private void* handle;
    private FPDF_InitLibrary_t fInitLibrary;
    private FPDF_DestroyLibrary_t fDestroyLibrary;
    private FPDF_GetLastError_t fGetLastError;
    private FPDF_LoadDocument_t fLoadDocument;
    private FPDF_LoadMemDocument_t fLoadMemDocument;
    private FPDF_CloseDocument_t fCloseDocument;
    private FPDF_GetPageCount_t fGetPageCount;
    private FPDF_LoadPage_t fLoadPage;
    private FPDF_ClosePage_t fClosePage;
    private FPDFText_LoadPage_t fTextLoadPage;
    private FPDFText_ClosePage_t fTextClosePage;
    private FPDFText_CountChars_t fTextCountChars;
    private FPDFText_GetText_t fTextGetText;

    private this() {}

    /// `dlopen()`s the operator-supplied `libraryPath` -- never fetched,
    /// vendored, guessed, or read from an environment variable by this
    /// module -- and `dlsym()`s every symbol this module uses. Returns
    /// `null` on any load or link failure: a missing path, a non-PDFium or
    /// wrong-architecture image, or any single missing symbol all fail
    /// closed identically, and never as a partial binding (every resolved
    /// symbol pointer is discarded and the handle is `dlclose()`d before
    /// returning `null`). Calls `FPDF_InitLibrary()` exactly once, only on
    /// a fully successful load.
    static PdfiumLibrary open(string libraryPath) {
        auto handle = dlopen(libraryPath.toStringz, RTLD_NOW | RTLD_LOCAL);
        if (handle is null) return null;

        auto initLibrary = cast(FPDF_InitLibrary_t) dlsym(handle, "FPDF_InitLibrary");
        auto destroyLibrary = cast(FPDF_DestroyLibrary_t) dlsym(handle, "FPDF_DestroyLibrary");
        auto getLastError = cast(FPDF_GetLastError_t) dlsym(handle, "FPDF_GetLastError");
        auto loadDocument = cast(FPDF_LoadDocument_t) dlsym(handle, "FPDF_LoadDocument");
        auto loadMemDocument = cast(FPDF_LoadMemDocument_t) dlsym(handle, "FPDF_LoadMemDocument");
        auto closeDocument = cast(FPDF_CloseDocument_t) dlsym(handle, "FPDF_CloseDocument");
        auto getPageCount = cast(FPDF_GetPageCount_t) dlsym(handle, "FPDF_GetPageCount");
        auto loadPage = cast(FPDF_LoadPage_t) dlsym(handle, "FPDF_LoadPage");
        auto closePage = cast(FPDF_ClosePage_t) dlsym(handle, "FPDF_ClosePage");
        auto textLoadPage = cast(FPDFText_LoadPage_t) dlsym(handle, "FPDFText_LoadPage");
        auto textClosePage = cast(FPDFText_ClosePage_t) dlsym(handle, "FPDFText_ClosePage");
        auto textCountChars = cast(FPDFText_CountChars_t) dlsym(handle, "FPDFText_CountChars");
        auto textGetText = cast(FPDFText_GetText_t) dlsym(handle, "FPDFText_GetText");

        if (initLibrary is null || destroyLibrary is null || getLastError is null ||
                loadDocument is null || loadMemDocument is null || closeDocument is null ||
                getPageCount is null || loadPage is null || closePage is null ||
                textLoadPage is null || textClosePage is null ||
                textCountChars is null || textGetText is null) {
            dlclose(handle);
            return null;
        }

        auto lib = new PdfiumLibrary();
        lib.handle = handle;
        lib.fInitLibrary = initLibrary;
        lib.fDestroyLibrary = destroyLibrary;
        lib.fGetLastError = getLastError;
        lib.fLoadDocument = loadDocument;
        lib.fLoadMemDocument = loadMemDocument;
        lib.fCloseDocument = closeDocument;
        lib.fGetPageCount = getPageCount;
        lib.fLoadPage = loadPage;
        lib.fClosePage = closePage;
        lib.fTextLoadPage = textLoadPage;
        lib.fTextClosePage = textClosePage;
        lib.fTextCountChars = textCountChars;
        lib.fTextGetText = textGetText;
        lib.fInitLibrary();
        return lib;
    }

    /// Calls `FPDF_DestroyLibrary()` and `dlclose()`s the native handle.
    /// Safe to call at most once; safe to omit (the destructor performs the
    /// same cleanup as a safety net, matching `effects.zlib_ffi.SystemZlib`).
    /// The caller owns lifetime -- there is no reference counting.
    void close() {
        if (handle is null) return;
        fDestroyLibrary();
        dlclose(handle);
        handle = null;
    }

    ~this() {
        if (handle !is null) {
            fDestroyLibrary();
            dlclose(handle);
            handle = null;
        }
    }
}

/// Outcome of one `extractPdfTextV1` call. Exactly one of these five, never
/// a thrown exception for any of malformed/encrypted/over-limit input --
/// matching this codebase's fail-closed-with-typed-reason idiom already
/// established by `extraction.ooxml_document.OoxmlWalkStatusV1` and
/// `effects.html_tree.HtmlFailureReason`.
enum PdfExtractOutcomeV1 : ubyte {
    /// The document loaded, its real page count was within `maxPages`, and
    /// every page's extracted text was within `maxBytesPerPage`.
    ok,
    /// `FPDF_LoadMemDocument` returned `NULL` for a reason other than a
    /// password (typically `FPDF_ERR_FORMAT`, corrupt/non-PDF bytes), or the
    /// loaded document reported a negative page count.
    malformed,
    /// `FPDF_LoadMemDocument` returned `NULL` and `FPDF_GetLastError() ==
    /// FPDF_ERR_PASSWORD`: the document requires a password this module
    /// never supplies.
    encrypted,
    /// The document's real page count exceeded the caller's `maxPages`
    /// bound. No page is extracted or returned; this is a closed refusal,
    /// not a truncated partial result.
    pageLimitExceeded,
    /// Some page's character count exceeded the caller's `maxBytesPerPage`
    /// bound (charged as UCS-2 code units, 2 bytes each, before any text is
    /// copied out). No text is extracted or returned; this is a closed
    /// refusal, not a truncated partial result.
    textLimitExceeded,
}

/// Result of one `extractPdfTextV1` call.
struct PdfExtractResultV1 {
    PdfExtractOutcomeV1 outcome;
    /// One entry per real page, in document order. Meaningful iff
    /// `outcome == PdfExtractOutcomeV1.ok`; empty otherwise.
    string[] pages;
}

/// Loads `pdfBytes` from memory via `FPDF_LoadMemDocument` (never
/// `FPDF_LoadDocument`'s file-path form -- this module performs no
/// filesystem I/O of its own) and extracts plain text per page, up to
/// `maxPages` pages, each bounded by `maxBytesPerPage`. Never throws: every
/// failure mode -- a malformed/corrupt document, an encrypted document, or
/// either bound being exceeded -- is the corresponding typed
/// `PdfExtractOutcomeV1`, never an uncaught exception or a crash. `lib` must
/// already be open (see `PdfiumLibrary.open`); this function performs no
/// `dlopen`/`dlsym` of its own.
PdfExtractResultV1 extractPdfTextV1(PdfiumLibrary lib, const(ubyte)[] pdfBytes,
        size_t maxPages, size_t maxBytesPerPage) {
    PdfExtractResultV1 result;

    // FPDF_LoadMemDocument's size parameter is a plain `int`; a caller
    // supplying more bytes than that can hold cannot be loaded through this
    // API at all. Folded into `malformed` rather than adding a sixth
    // outcome for what is, in practice, an unreachable bound given this
    // codebase's existing per-record input-size limits upstream of any
    // extractor.
    if (pdfBytes.length > int.max) {
        result.outcome = PdfExtractOutcomeV1.malformed;
        return result;
    }

    auto doc = lib.fLoadMemDocument(pdfBytes.ptr, cast(int) pdfBytes.length, null);
    if (doc is null) {
        immutable err = lib.fGetLastError();
        result.outcome = (err == fpdfErrPassword)
            ? PdfExtractOutcomeV1.encrypted : PdfExtractOutcomeV1.malformed;
        return result;
    }
    scope (exit) lib.fCloseDocument(doc);

    immutable pageCount = lib.fGetPageCount(doc);
    if (pageCount < 0) {
        result.outcome = PdfExtractOutcomeV1.malformed;
        return result;
    }
    if (cast(size_t) pageCount > maxPages) {
        result.outcome = PdfExtractOutcomeV1.pageLimitExceeded;
        return result;
    }

    // Charged in UCS-2 code units (2 bytes each), matching
    // FPDFText_GetText's own unit -- before any text is copied out, not
    // after, so an over-limit page never gets materialized.
    immutable maxChars = maxBytesPerPage / 2;

    string[] pages;
    pages.reserve(cast(size_t) pageCount);
    foreach (index; 0 .. pageCount) {
        auto page = lib.fLoadPage(doc, index);
        if (page is null) {
            pages ~= "";
            continue;
        }
        scope (exit) lib.fClosePage(page);

        auto textPage = lib.fTextLoadPage(page);
        if (textPage is null) {
            pages ~= "";
            continue;
        }
        scope (exit) lib.fTextClosePage(textPage);

        immutable charCount = lib.fTextCountChars(textPage);
        if (charCount <= 0) {
            pages ~= "";
            continue;
        }
        if (cast(size_t) charCount > maxChars) {
            result.outcome = PdfExtractOutcomeV1.textLimitExceeded;
            return result;
        }

        auto buffer = new ushort[](charCount + 1);
        immutable written = lib.fTextGetText(textPage, 0, charCount, buffer.ptr);
        // FPDFText_GetText's return includes the trailing UCS-2 terminator;
        // drop it before decoding.
        immutable usable = written > 0 ? written - 1 : 0;
        pages ~= ucs2ToUtf8(buffer[0 .. usable]);
    }

    result.outcome = PdfExtractOutcomeV1.ok;
    result.pages = pages;
    return result;
}

/// Decodes a UCS-2/UTF-16 code-unit buffer (PDFium's `FPDFText_GetText`
/// output) to UTF-8. Never throws: a valid surrogate pair decodes to its
/// real code point, and a lone/invalid surrogate decodes to U+FFFD, rather
/// than raising `UTFException` the way a strict UTF-16 decoder would --
/// this is best-effort text-content decoding, distinct from this module's
/// document-level malformed/encrypted refusal, the same way
/// `effects.html_tree`'s node text is not itself a source of document-level
/// failure.
private string ucs2ToUtf8(const(ushort)[] units) pure {
    dchar[] codepoints;
    codepoints.reserve(units.length);
    size_t i = 0;
    while (i < units.length) {
        immutable c = units[i];
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < units.length &&
                units[i + 1] >= 0xDC00 && units[i + 1] <= 0xDFFF) {
            immutable lo = units[i + 1];
            codepoints ~= cast(dchar)(0x10000 + ((c - 0xD800) << 10) + (lo - 0xDC00));
            i += 2;
        } else if (c >= 0xD800 && c <= 0xDFFF) {
            codepoints ~= cast(dchar) 0xFFFD;
            i += 1;
        } else {
            codepoints ~= cast(dchar) c;
            i += 1;
        }
    }
    return codepoints.toUTF8();
}

unittest {
    // Pure decode-helper coverage: plain ASCII/BMP, a valid non-BMP
    // surrogate pair (U+1F600 GRINNING FACE), and a lone/invalid surrogate
    // (must substitute U+FFFD, never throw).
    assert(ucs2ToUtf8([]) == "");
    assert(ucs2ToUtf8(['T', 'W', 'O']) == "TWO");
    ushort[2] emoji = [0xD83D, 0xDE00]; // U+1F600 as a UTF-16 surrogate pair
    assert(ucs2ToUtf8(emoji) == "\U0001F600");
    ushort[1] loneHigh = [0xD800];
    assert(ucs2ToUtf8(loneHigh) == "�");
    ushort[1] loneLow = [0xDC00];
    assert(ucs2ToUtf8(loneLow) == "�");
}

unittest {
    // Fails-closed, never crashes: no such path exists on disk.
    auto missing = PdfiumLibrary.open("/nonexistent/path/does/not/exist/libpdfium.dylib");
    assert(missing is null);
}

unittest {
    // A real, always-present-on-macOS dynamic library that genuinely
    // dlopen()s but exposes none of PDFium's symbols: proves the "opens but
    // missing a required symbol" path fails closed too (never a partial
    // binding), distinctly from the "doesn't open at all" path above. This
    // does not require the real, operator-supplied libpdfium.dylib PDFium
    // artifact (which `dub test` cannot assume is present) -- only libSystem,
    // which every macOS host already has.
    auto wrongLibrary = PdfiumLibrary.open("/usr/lib/libSystem.B.dylib");
    assert(wrongLibrary is null);
}

// ---------------------------------------------------------------------------
// Concurrency-safety wrapper and the module-level PDF-wiring boundary (issue
// #156's PDF-wiring slice). See this module's own header doc, "Wiring
// status" section, and `extraction.pdf_pdfium_route`'s own doc comment,
// "Concurrency" section, for the full disclosed reasoning.
// ---------------------------------------------------------------------------

/// Serializes every call into a shared `PdfiumLibrary`: PDFium's own C API
/// documents itself as single-thread-only (see this module's header doc),
/// but `scrubbed run`'s real production execution model genuinely calls
/// into a shared, process-lifetime `PdfiumLibrary` from multiple
/// `--threads` worker threads concurrently
/// (`composition.dispatch_executor.d`'s own two-thread concurrent-dispatch
/// unittest already proves this happens for every registered extractor).
/// This is the mandatory, non-deferrable concurrency-safety resolution
/// issue #156's owner decision (2026-09-30) requires -- a real
/// `core.sync.mutex.Mutex` around every call, not a documentation-only
/// disclosure. Real concurrent-call proof lives in `cli.d`'s own manually
/// run (not `dub test`-gated, since it needs a real operator-supplied
/// library -- see below) end-to-end test, per this module's established
/// "real-artifact proof lives outside dub test" convention
/// (`PdfiumLibrary.open`'s own two unittests above deliberately avoid
/// needing the real artifact for the same reason).
final class LockedPdfiumLibraryV1 {
    private PdfiumLibrary lib;
    private Mutex mutex;

    this(PdfiumLibrary lib) {
        this.lib = lib;
        this.mutex = new Mutex();
    }

    /// Serialized real extraction call. Never throws for ordinary
    /// malformed/encrypted/over-limit input -- `extractPdfTextV1` itself
    /// already fails closed with a typed outcome for all of those; this
    /// method adds no new failure mode of its own beyond mutual exclusion.
    PdfExtractResultV1 extract(const(ubyte)[] pdfBytes, size_t maxPages,
            size_t maxBytesPerPage) {
        synchronized (mutex) {
            return extractPdfTextV1(lib, pdfBytes, maxPages, maxBytesPerPage);
        }
    }

    /// Calls `PdfiumLibrary.close()` under the same mutex, so a call
    /// racing a concurrent `extract` either completes first or observes a
    /// closed library cleanly rather than tearing one down mid-call. Not
    /// called by this module's own `installPdfiumLibraryV1` (the installed
    /// library is process-lifetime, matching `PdfiumLibrary`'s own
    /// GC-finalized-at-process-exit discipline); provided for callers (e.g.
    /// a future test harness) that need explicit, deterministic teardown.
    void close() {
        synchronized (mutex) {
            lib.close();
        }
    }
}

/// See `extraction.pdf_pdfium_route`'s own doc comment, "The injection"
/// section, for why this is a module-global slot rather than a closure, and
/// why that is safe under this codebase's real usage (set once, on the CLI
/// main thread, before any worker thread exists). Not `__gshared`, for the
/// same single-threaded-access reason `extraction.pdf_pdfium_route`'s own
/// mirroring slot is not.
private LockedPdfiumLibraryV1 activePdfiumLibraryV1;

/// `dlopen()`s/`dlsym()`s the operator-supplied PDFium library at
/// `libraryPath` (via `PdfiumLibrary.open`, unchanged), wraps it with a
/// serializing `Mutex` (`LockedPdfiumLibraryV1`), and installs it as this
/// module's single active library -- the one `pdfBytesExtractV1` (below)
/// calls into. Must be called at most once per process, on the CLI's own
/// main thread, before any document is dispatched to the `pdf-pdfium`
/// route (`cli.d`'s own `resolvePdfBytesExtractV1` is the one real caller).
/// Returns `true` on success, `false` on any dlopen/dlsym/init failure --
/// content-free, matching `PdfiumLibrary.open`'s own discipline; the caller
/// (`cli.d`) turns a `false` return into `pdfiumLoadFailureMessage` before
/// any document is processed.
bool installPdfiumLibraryV1(string libraryPath) {
    auto lib = PdfiumLibrary.open(libraryPath);
    if (lib is null) return false;
    activePdfiumLibraryV1 = new LockedPdfiumLibraryV1(lib);
    return true;
}

/// The real implementation behind `extraction.port.PdfBytesExtractV1`,
/// translating `effects.pdfium_ffi`'s own `PdfExtractResultV1`/
/// `PdfExtractOutcomeV1` into `extraction.port`'s byte-stable mirror
/// (`extraction/` may not import `effects/`, so the two enums cannot be the
/// same type -- see `extraction.port.PdfBytesExtractOutcomeV1`'s own doc).
private PdfBytesExtractResultV1 pdfBytesExtractImpl(const(ubyte)[] pdfBytes,
        size_t maxPages, size_t maxBytesPerPage) {
    import std.exception : enforce;

    enforce(activePdfiumLibraryV1 !is null,
        "pdfBytesExtractV1 called before installPdfiumLibraryV1");
    auto raw = activePdfiumLibraryV1.extract(pdfBytes, maxPages, maxBytesPerPage);
    PdfBytesExtractResultV1 result;
    final switch (raw.outcome) {
    case PdfExtractOutcomeV1.ok: result.outcome = PdfBytesExtractOutcomeV1.ok; break;
    case PdfExtractOutcomeV1.malformed: result.outcome = PdfBytesExtractOutcomeV1.malformed; break;
    case PdfExtractOutcomeV1.encrypted: result.outcome = PdfBytesExtractOutcomeV1.encrypted; break;
    case PdfExtractOutcomeV1.pageLimitExceeded: result.outcome = PdfBytesExtractOutcomeV1.pageLimitExceeded; break;
    case PdfExtractOutcomeV1.textLimitExceeded: result.outcome = PdfBytesExtractOutcomeV1.textLimitExceeded; break;
    }
    result.pages = raw.pages;
    return result;
}

/// The single documented `pure`-cast boundary (see this module's header
/// doc, "Wiring status" section, and `extraction.pdf_pdfium_route`'s own
/// doc comment, "Concurrency" section, for the full reasoning): honest in
/// the same sense `effects.zlib_ffi.zipInflateV1`'s cast is -- the
/// function's result is a deterministic function of its arguments once
/// mutual exclusion into the shared `PdfiumLibrary` is guaranteed, and
/// `LockedPdfiumLibraryV1`'s `Mutex` is exactly what makes that guarantee
/// real rather than assumed.
immutable PdfBytesExtractV1 pdfBytesExtractV1 = cast(PdfBytesExtractV1) &pdfBytesExtractImpl;
