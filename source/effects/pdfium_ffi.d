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
/// **Flag-name decision, recorded here so it is not re-litigated later**
/// (owner decision, issue #156, 2026-09-27): any future stage/CLI wiring
/// slice that exposes this module's library-path requirement to an operator
/// MUST name that flag `--pdfium-library` exactly (an explicit, required,
/// discoverable flag -- never an environment variable, never a bare
/// positional argument, matching this codebase's existing "every option is
/// an explicit flag, nothing implicit/ambient" convention, e.g.
/// `clean-web-document`'s sealed flag list and `--sidecar-output`).
/// `experiments/pdfium_extract/check.d` already follows this convention at
/// the checker level.
///
/// This slice has **no stage/CLI/dispatch wiring**: nothing in `source/`
/// other than this module's own future callers imports it yet. PDFium's own
/// C API (`public/fpdfview.h`) documents itself as not thread-safe ("None of
/// the PDFium APIs are thread-safe. They expect to be called from a single
/// thread"); this module does no locking of its own and inherits that
/// constraint onto its caller.
module effects.pdfium_ffi;

import core.stdc.config : c_ulong;
import core.sys.posix.dlfcn : dlclose, dlopen, dlsym, RTLD_LOCAL, RTLD_NOW;
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
