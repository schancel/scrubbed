/// Release-active evidence checker for issue #156's second slice:
/// `effects.pdfium_ffi`'s `dlopen`-backed PDFium binding and bounded
/// in-memory page-text extraction (`extractPdfTextV1`). Proves the accepted
/// contract's acceptance criteria against a real, operator-supplied
/// `libpdfium.dylib` -- never fetched, vendored, or assumed by this checker
/// -- plus this repository's existing pinned PDF fixtures
/// (`experiments/document_adapters/fixtures/*.pdf` and
/// `ground_truth.tsv`, the same CC0-1.0 #67 fixtures
/// `experiments/pdfium_check/evaluate.d` already proved against) and one new
/// self-authored encrypted fixture (`fixtures/pdf-encrypted.pdf`, see below).
///
/// Criteria proved here:
///  (1) a missing/invalid `--pdfium-library` path fails closed
///      (`PdfiumLibrary.open` returns `null`), never a crash;
///  (2) real text extraction from `pdf-training.pdf` (via
///      `FPDF_LoadMemDocument`, not the file-path `FPDF_LoadDocument` the
///      evaluation harness used) contains every pinned `ground_truth.tsv`
///      token exactly;
///  (3) the two-column `pdf-heldout-layout.pdf` fixture also contains every
///      one of its pinned tokens;
///  (4) the malformed `pdf-malformed.pdf` fixture is rejected with the
///      distinct `malformed` outcome, not a crash, not silent empty output;
///  (5) `fixtures/pdf-encrypted.pdf` -- a real, non-empty-user-password
///      PDF generated offline from the pinned `pdf-training.pdf` content via
///      `pypdf` (`writer.encrypt(user_password="scrubbed-test-user-pw",
///      owner_password="scrubbed-test-owner-pw", algorithm="RC4-128")`;
///      inherits `pdf-training.pdf`'s own CC0-1.0 provenance) -- is rejected
///      with the distinct `encrypted` outcome, never conflated with
///      `malformed`;
///  (6) `maxPages`/`maxBytesPerPage` are real, closed refusals
///      (`pageLimitExceeded`/`textLimitExceeded`), not silently ignored or
///      silently truncated.
///
/// Requires the operator to supply a real PDFium dynamic library path via
/// `--pdfium-library=PATH` -- never a bare positional argument, never an
/// environment variable, matching the flag-name convention
/// `effects.pdfium_ffi`'s own module doc comment records for any future
/// stage/CLI wiring slice. No network access; no filesystem write.
module pdfium_extract.check;

import effects.pdfium_ffi : extractPdfTextV1, PdfExtractOutcomeV1, PdfiumLibrary;
import std.algorithm.searching : canFind;
import std.array : join, split;
import std.file : exists, read, readText;
import std.getopt : getopt;
import std.path : buildPath;
import std.stdio : stderr, writeln;
import std.string : splitLines;

private int failures;

/// Not `assert`: this checker builds with LDC `-O3 -release`, which elides
/// the `assert` language construct. Every check here is a plain runtime
/// comparison so nothing this proof depends on can be compiled away.
private void expect(bool condition, string label) {
    if (condition) writeln("ok   ", label);
    else { writeln("FAIL ", label); ++failures; }
}

/// Parses `sample\ttokens\tgeometry` rows (`experiments/document_adapters/
/// ground_truth.tsv`'s own format) into `sample id -> pipe-separated tokens`.
private string[string] loadGroundTruthTokens(string path) {
    string[string] tokens;
    foreach (line; readText(path).splitLines) {
        auto fields = line.split("\t");
        if (fields.length < 2 || fields[0] == "sample") continue;
        tokens[fields[0]] = fields[1];
    }
    return tokens;
}

private void checkSampleTokens(PdfiumLibrary lib, string fixturesDir,
        const(string[string]) groundTruth, string sampleId, string fixtureFile) {
    auto path = buildPath(fixturesDir, fixtureFile);
    expect(exists(path), "fixture exists: " ~ path);
    if (!exists(path)) return;

    auto bytes = cast(const(ubyte)[]) read(path);
    auto result = extractPdfTextV1(lib, bytes, 100, 1_000_000);
    expect(result.outcome == PdfExtractOutcomeV1.ok, sampleId ~ ": extraction outcome is ok");
    if (result.outcome != PdfExtractOutcomeV1.ok) return;

    auto text = result.pages.join("\n");
    writeln("     extracted text (", sampleId, "): ", text);
    auto tokensField = sampleId in groundTruth;
    expect(tokensField !is null, sampleId ~ ": ground_truth.tsv has pinned tokens for this sample");
    if (tokensField is null) return;
    foreach (token; (*tokensField).split("|"))
        expect(text.canFind(token), sampleId ~ ": extracted text contains pinned token '" ~ token ~ "'");
}

int main(string[] args) {
    string pdfiumLibrary;
    string fixturesDir = "experiments/document_adapters/fixtures";
    string groundTruthPath = "experiments/document_adapters/ground_truth.tsv";
    string ownFixturesDir = "experiments/pdfium_extract/fixtures";

    getopt(args,
        "pdfium-library", "Path to a real, operator-supplied libpdfium.dylib (required)", &pdfiumLibrary,
        "fixtures-dir", "Override the shared #67 PDF fixtures directory", &fixturesDir,
        "ground-truth", "Override the pinned ground_truth.tsv path", &groundTruthPath);

    if (pdfiumLibrary.length == 0) {
        stderr.writeln("usage: pdfium-extract-check --pdfium-library=PATH "
            ~ "[--fixtures-dir=DIR] [--ground-truth=PATH]");
        return 2;
    }

    // (1) A missing/invalid library path fails closed, never a crash --
    // proved before touching the real operator-supplied path at all.
    {
        auto missing = PdfiumLibrary.open("/nonexistent/path/definitely-not-a-real-pdfium.dylib");
        expect(missing is null, "missing library path fails closed (PdfiumLibrary.open returns null)");
    }

    auto lib = PdfiumLibrary.open(pdfiumLibrary);
    expect(lib !is null, "real operator-supplied --pdfium-library path opens successfully");
    if (lib is null) {
        stderr.writeln("cannot proceed with real-extraction checks: "
            ~ "the supplied --pdfium-library path failed to load");
        writeln("TOTAL FAILURES: ", failures);
        return failures == 0 ? 0 : 1;
    }
    scope (exit) lib.close();

    auto groundTruth = loadGroundTruthTokens(groundTruthPath);

    // (2), (3) Real, exact token-match extraction against the pinned #67
    // fixtures, via the in-memory load path this slice adds.
    checkSampleTokens(lib, fixturesDir, groundTruth, "pdf-training", "pdf-training.pdf");
    checkSampleTokens(lib, fixturesDir, groundTruth, "pdf-heldout-layout", "pdf-heldout-layout.pdf");

    // (4) Malformed fixture: distinct `malformed` outcome.
    {
        auto path = buildPath(fixturesDir, "pdf-malformed.pdf");
        expect(exists(path), "fixture exists: " ~ path);
        if (exists(path)) {
            auto bytes = cast(const(ubyte)[]) read(path);
            auto result = extractPdfTextV1(lib, bytes, 100, 1_000_000);
            expect(result.outcome == PdfExtractOutcomeV1.malformed,
                "pdf-malformed.pdf: extraction outcome is malformed");
        }
    }

    // (5) Encrypted fixture: distinct `encrypted` outcome.
    {
        auto path = buildPath(ownFixturesDir, "pdf-encrypted.pdf");
        expect(exists(path), "fixture exists: " ~ path);
        if (exists(path)) {
            auto bytes = cast(const(ubyte)[]) read(path);
            auto result = extractPdfTextV1(lib, bytes, 100, 1_000_000);
            expect(result.outcome == PdfExtractOutcomeV1.encrypted,
                "pdf-encrypted.pdf: extraction outcome is encrypted");
        }
    }

    // (6) Bounds are real, closed refusals.
    {
        auto path = buildPath(fixturesDir, "pdf-training.pdf");
        if (exists(path)) {
            auto bytes = cast(const(ubyte)[]) read(path);
            auto overPage = extractPdfTextV1(lib, bytes, 0, 1_000_000);
            expect(overPage.outcome == PdfExtractOutcomeV1.pageLimitExceeded,
                "maxPages=0 against a real 1-page document yields pageLimitExceeded");
            auto overText = extractPdfTextV1(lib, bytes, 100, 1);
            expect(overText.outcome == PdfExtractOutcomeV1.textLimitExceeded,
                "maxBytesPerPage=1 against real extracted text yields textLimitExceeded");
        }
    }

    writeln("TOTAL FAILURES: ", failures);
    return failures == 0 ? 0 : 1;
}
