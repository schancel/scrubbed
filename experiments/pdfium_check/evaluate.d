// Issue #297 evidence harness: proves (or disproves) that a real,
// unmodified bblanchon/pdfium-binaries prebuilt `libpdfium.dylib` can be
// dlopen()'d from D, that its public `fpdfview.h`/`fpdf_text.h` C symbols
// resolve and are callable through D-declared function-pointer types, and
// that real text extraction against this repository's own pinned,
// CC0-1.0, issue-#67 PDF fixtures (`experiments/document_adapters/
// fixtures/*.pdf`, hashes pinned in `samples.tsv`) matches the exact
// expected tokens already pinned in `experiments/document_adapters/
// ground_truth.tsv`.
//
// This is evaluation code only: it is outside `dub.json`'s `sourcePaths`
// (which lists only `source`), so it is never compiled into the shipped
// binary and never becomes an importable dependency. It does not vendor
// PDFium; the caller must supply the path to an already-downloaded
// `libpdfium.dylib` (see docs/pdfium-evaluation.md for exact provenance
// and download instructions). Nothing here is wired to any stage or CLI
// command.
//
// This harness uses release-active `check()` failures, not `assert`, so
// an optimized `-release` build cannot silently pass a broken probe.

import core.stdc.config : c_ulong;
import core.stdc.stdlib : malloc, free;
import core.sys.posix.dlfcn : dlopen, dlsym, dlclose, dlerror, RTLD_NOW, RTLD_LOCAL;
import std.conv : to;
import std.file : exists;
import std.stdio : writefln, writeln, stderr;
import std.string : toStringz, fromStringz;

extern (C) alias FPDF_InitLibrary_t = void function();
extern (C) alias FPDF_DestroyLibrary_t = void function();
extern (C) alias FPDF_GetLastError_t = c_ulong function();
extern (C) alias FPDF_LoadDocument_t = void* function(const(char)*, const(char)*);
extern (C) alias FPDF_CloseDocument_t = void function(void*);
extern (C) alias FPDF_GetPageCount_t = int function(void*);
extern (C) alias FPDF_LoadPage_t = void* function(void*, int);
extern (C) alias FPDF_ClosePage_t = void function(void*);
extern (C) alias FPDFText_LoadPage_t = void* function(void*);
extern (C) alias FPDFText_ClosePage_t = void function(void*);
extern (C) alias FPDFText_CountChars_t = int function(void*);
extern (C) alias FPDFText_GetText_t = int function(void*, int, int, ushort*);

int failures = 0;

void check(bool condition, string label)
{
    if (condition)
    {
        writefln("PASS: %s", label);
    }
    else
    {
        writefln("FAIL: %s", label);
        failures++;
    }
}

void* mustResolve(void* handle, string name)
{
    auto sym = dlsym(handle, name.toStringz);
    check(sym !is null, "dlsym resolves " ~ name);
    return sym;
}

string extractAsciiText(FPDFText_LoadPage_t loadTextPage, FPDFText_ClosePage_t closeTextPage,
    FPDFText_CountChars_t countChars, FPDFText_GetText_t getText, void* page)
{
    auto textPage = loadTextPage(page);
    if (textPage is null)
        return null;
    scope (exit)
        closeTextPage(textPage);

    immutable int charCount = countChars(textPage);
    auto buf = cast(ushort*) malloc((charCount + 1) * ushort.sizeof);
    scope (exit)
        free(buf);
    immutable int written = getText(textPage, 0, charCount, buf);

    char[] ascii;
    foreach (i; 0 .. written)
    {
        if (i >= charCount)
            break;
        auto u = buf[i];
        ascii ~= (u < 128) ? cast(char) u : '?';
    }
    return cast(string) ascii;
}

int main(string[] args)
{
    if (args.length < 2)
    {
        stderr.writefln("usage: %s <path-to-libpdfium.dylib> [fixtures-dir]", args[0]);
        return 2;
    }
    immutable dylibPath = args[1];
    immutable fixturesDir = args.length >= 3
        ? args[2] : "experiments/document_adapters/fixtures";

    check(exists(dylibPath), "artifact path exists: " ~ dylibPath);

    auto handle = dlopen(dylibPath.toStringz, RTLD_NOW | RTLD_LOCAL);
    check(handle !is null, "dlopen succeeds");
    if (handle is null)
    {
        stderr.writefln("dlopen error: %s", dlerror().fromStringz);
        writefln("TOTAL FAILURES: %d", failures + 1);
        return 1;
    }
    scope (exit)
        dlclose(handle);

    auto initLib = cast(FPDF_InitLibrary_t) mustResolve(handle, "FPDF_InitLibrary");
    auto destroyLib = cast(FPDF_DestroyLibrary_t) mustResolve(handle, "FPDF_DestroyLibrary");
    auto lastError = cast(FPDF_GetLastError_t) mustResolve(handle, "FPDF_GetLastError");
    auto loadDoc = cast(FPDF_LoadDocument_t) mustResolve(handle, "FPDF_LoadDocument");
    auto closeDoc = cast(FPDF_CloseDocument_t) mustResolve(handle, "FPDF_CloseDocument");
    auto pageCount = cast(FPDF_GetPageCount_t) mustResolve(handle, "FPDF_GetPageCount");
    auto loadPage = cast(FPDF_LoadPage_t) mustResolve(handle, "FPDF_LoadPage");
    auto closePage = cast(FPDF_ClosePage_t) mustResolve(handle, "FPDF_ClosePage");
    auto loadTextPage = cast(FPDFText_LoadPage_t) mustResolve(handle, "FPDFText_LoadPage");
    auto closeTextPage = cast(FPDFText_ClosePage_t) mustResolve(handle, "FPDFText_ClosePage");
    auto countChars = cast(FPDFText_CountChars_t) mustResolve(handle, "FPDFText_CountChars");
    auto getText = cast(FPDFText_GetText_t) mustResolve(handle, "FPDFText_GetText");

    if (failures > 0)
    {
        writefln("TOTAL FAILURES: %d (symbol resolution failed, aborting)", failures);
        return 1;
    }

    initLib();
    writeln("FPDF_InitLibrary() called through a dlsym'd pointer, OK");

    // Positive case: this repo's own pinned pdf-training.pdf fixture
    // (CC0-1.0, hash pinned in experiments/document_adapters/samples.tsv).
    // Expected tokens are pinned independently in
    // experiments/document_adapters/ground_truth.tsv:
    //   pdf-training  TRAINING|PDF|ALPHA|ONE|BETA|TWO
    {
        immutable path = fixturesDir ~ "/pdf-training.pdf";
        check(exists(path), "fixture exists: " ~ path);
        auto doc = loadDoc(path.toStringz, null);
        check(doc !is null, "FPDF_LoadDocument succeeds on pdf-training.pdf");
        if (doc !is null)
        {
            immutable pages = pageCount(doc);
            check(pages == 1, "pdf-training.pdf has exactly one page");
            auto page = loadPage(doc, 0);
            check(page !is null, "FPDF_LoadPage(0) succeeds");
            if (page !is null)
            {
                auto text = extractAsciiText(loadTextPage, closeTextPage, countChars, getText, page);
                writefln("extracted text: %s", text);
                foreach (token; ["TRAINING", "PDF", "ALPHA", "ONE", "BETA", "TWO"])
                {
                    import std.algorithm : canFind;

                    check(text.canFind(token), "extracted text contains pinned token '" ~ token ~ "'");
                }
                closePage(page);
            }
            closeDoc(doc);
        }
    }

    // Positive case: the held-out two-column layout fixture. This does not
    // assert a formal geometry-hit score (that predicate logic is owned by
    // experiments/document_adapters/check.d and is not reimplemented
    // here); it only checks that PDFium's plain FPDFText_GetText output
    // contains the pinned tokens in the pinned left-column/right-column/
    // footer semantic order.
    {
        immutable path = fixturesDir ~ "/pdf-heldout-layout.pdf";
        check(exists(path), "fixture exists: " ~ path);
        auto doc = loadDoc(path.toStringz, null);
        check(doc !is null, "FPDF_LoadDocument succeeds on pdf-heldout-layout.pdf");
        if (doc !is null)
        {
            auto page = loadPage(doc, 0);
            if (page !is null)
            {
                auto text = extractAsciiText(loadTextPage, closeTextPage, countChars, getText, page);
                writefln("extracted text: %s", text);
                import std.algorithm : countUntil;

                // Semantic order per ground_truth.tsv: LEFT A, LEFT B,
                // RIGHT A, RIGHT B, FOOTER END (left column, then right
                // column, then footer -- not row-interleaved).
                immutable leftA = text.countUntil("LEFT A");
                immutable leftB = text.countUntil("LEFT B");
                immutable rightA = text.countUntil("RIGHT A");
                immutable rightB = text.countUntil("RIGHT B");
                immutable footer = text.countUntil("FOOTER END");
                check(leftA >= 0 && leftB >= 0 && rightA >= 0 && rightB >= 0 && footer >= 0,
                    "all five pinned layout tokens are present");
                check(leftA < leftB && leftB < rightA && rightA < rightB && rightB < footer,
                    "layout tokens appear in left-column/right-column/footer semantic order (no row-interleaving)");
                closePage(page);
            }
            closeDoc(doc);
        }
    }

    // Negative case: the malformed fixture must fail closed with
    // FPDF_ERR_FORMAT (3), never crash, never return a document.
    {
        immutable path = fixturesDir ~ "/pdf-malformed.pdf";
        check(exists(path), "fixture exists: " ~ path);
        auto doc = loadDoc(path.toStringz, null);
        check(doc is null, "FPDF_LoadDocument rejects pdf-malformed.pdf (returns NULL)");
        if (doc is null)
        {
            immutable err = lastError();
            check(err == 3, "FPDF_GetLastError() == FPDF_ERR_FORMAT (3), got " ~ err.to!string);
        }
        else
        {
            closeDoc(doc);
        }
    }

    destroyLib();
    writeln("FPDF_DestroyLibrary() called OK");

    writefln("TOTAL FAILURES: %d", failures);
    return failures == 0 ? 0 : 1;
}
