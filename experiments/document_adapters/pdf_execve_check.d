/// Release-active evidence checker for issue #296's `effects.pdf_execve`:
/// opt-in, PATH-looked-up, bounded-subprocess PDF text extraction via
/// Poppler `pdftotext`. This proves the module's five accepted acceptance
/// criteria against real subprocess behavior (not mocked), reusing #67's
/// existing frozen fixture corpus (`samples.tsv` / `fixtures/*.pdf`) rather
/// than authoring a new PDF fixture.
///
/// Criteria proved here:
/// (1) declining without the opt-in flag never attempts a PATH lookup or
///     subprocess spawn;
/// (2) PATH lookup against a real, present "pdftotext" succeeds, and against
///     a deliberately binary-absent PATH fails with the exact fixed Poppler
///     install-hint text;
/// (3) a bounded subprocess run against the frozen `pdf-training.pdf`
///     fixture returns the exact expected extracted text -- proved for real
///     against the genuinely installed Poppler `pdftotext` when this
///     environment has one, and explicitly reported (not silently skipped)
///     when it does not;
/// (4) a subprocess exceeding the wall-clock cap is killed as a whole
///     process group, not just its leader, and reported as a timeout;
/// (5) a subprocess exceeding the output cap is rejected via RLIMIT_FSIZE,
///     not read unbounded.
module document_adapters.pdf_execve_check;

import core.sys.posix.sys.stat : chmod;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import effects.pdf_execve : PdfExtractFailureReason, PdfExtractLimits,
    extractPdfText, pdfExtractInstallHint, pdfExtractToolName;
import std.algorithm.searching : canFind;
import std.conv : octal, to;
import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;
import std.exception : enforce;
import std.file : exists, mkdirRecurse, read, readText, rmdirRecurse, tempDir,
    timeLastModified, write;
import std.path : buildPath;
import std.process : environment;
import std.stdio : stderr, writeln;
import std.string : split, splitLines, strip, toLower, toStringz;
import std.uuid : randomUUID;

private size_t assertions;
private void check(bool okay, string reason) {
    ++assertions;
    enforce(okay, reason);
}

private enum fixtureRoot = "experiments/document_adapters";

/// Minimal tab-separated row lookup: returns `column` of the row in
/// `fixtureRoot/file` whose `keyColumn` equals `key`. Deliberately not a
/// second copy of `check.d`'s richer TSV loader -- this checker only ever
/// needs one pinned field at a time.
private string tsvField(string file, string key, size_t keyColumn, size_t column) {
    auto lines = readText(buildPath(fixtureRoot, file)).splitLines;
    foreach (line; lines[1 .. $]) {
        if (line.strip.length == 0) continue;
        auto fields = line.split('\t');
        if (fields[keyColumn] == key) return fields[column];
    }
    throw new Exception(file ~ ": no row for " ~ key);
}

private string bytesHash(const(ubyte)[] bytes) {
    return sha256Of(bytes).toHexString.toLower;
}

/// Confirms this checker reuses #67's existing frozen fixture unchanged,
/// rather than a new PDF authored for this issue.
private string verifyFrozenFixtureReused() {
    auto relativePath = tsvField("samples.tsv", "pdf-training", 0, 4);
    auto pinnedHash = tsvField("samples.tsv", "pdf-training", 0, 5);
    check(relativePath == "fixtures/pdf-training.pdf",
        "pdf-training sample path drifted from #67's frozen corpus manifest");
    auto fullPath = buildPath(fixtureRoot, relativePath);
    check(exists(fullPath), "frozen fixture missing: " ~ fullPath);
    check(bytesHash(cast(ubyte[]) read(fullPath)) == pinnedHash,
        "frozen fixture bytes drifted from #67's pinned hash");
    return fullPath;
}

private string makeCheckDir(string label) {
    auto dir = buildPath(tempDir,
        "scrubbed-pdf-execve-check-" ~ label ~ "-" ~ randomUUID.toString);
    mkdirRecurse(dir);
    return dir;
}

private void makeFakeTool(string dir, string script) {
    auto path = buildPath(dir, pdfExtractToolName);
    write(path, script);
    check(chmod(path.toStringz, octal!755) == 0, "cannot mark fake tool executable");
}

/// Fake fixture scripts need ordinary coreutils (`sleep`, `date`, `yes`) to
/// resolve; only the directory intentionally holding (or lacking)
/// "pdftotext" is under test.
private string withCoreutils(string dir) {
    return dir ~ ":/bin:/usr/bin";
}

// ---- Criterion (1): declining is a structured no-op. ----

private void checkDeclinedNeverAttempts(string fixturePdf) {
    auto dir = makeCheckDir("declined");
    scope(exit) rmdirRecurse(dir);
    auto marker = buildPath(dir, "invoked");
    makeFakeTool(dir, "#!/bin/sh\ntouch \"" ~ marker ~ "\"\n");

    auto outcome = extractPdfText(fixturePdf, false, PdfExtractLimits.init, dir);
    check(!outcome.succeeded, "declined extraction reported success");
    check(outcome.failure.reason == PdfExtractFailureReason.declined,
        "declined extraction did not report the declined reason");
    check(!exists(marker), "declined extraction attempted a subprocess spawn");
}

// ---- Criterion (2): PATH lookup, both directions. ----

private void checkPathLookupMissing(string fixturePdf) {
    auto dir = makeCheckDir("missing");
    scope(exit) rmdirRecurse(dir);

    auto outcome = extractPdfText(fixturePdf, true, PdfExtractLimits.init, dir);
    check(!outcome.succeeded, "missing-tool lookup reported success");
    check(outcome.failure.reason == PdfExtractFailureReason.toolNotFound,
        "missing-tool lookup did not report toolNotFound");
    check(outcome.failure.installHint == pdfExtractInstallHint,
        "missing-tool lookup did not carry the exact fixed install hint");
    check(outcome.failure.installHint.canFind("pdftotext") &&
        outcome.failure.installHint.canFind("Poppler"),
        "install hint does not name pdftotext/Poppler by name");
}

private void checkPathLookupPresent(string fixturePdf) {
    auto dir = makeCheckDir("present");
    scope(exit) rmdirRecurse(dir);
    makeFakeTool(dir, "#!/bin/sh\nprintf 'FAKE EXTRACTED TEXT' > \"$3\"\n");

    auto outcome = extractPdfText(fixturePdf, true, PdfExtractLimits.init,
        withCoreutils(dir));
    check(outcome.succeeded, "present-tool lookup did not succeed");
    check(outcome.text == "FAKE EXTRACTED TEXT",
        "present-tool lookup did not return what the tool wrote");
}

// ---- Criterion (4): whole process-group kill on wall-timeout. ----

private void checkTimeoutKillsWholeGroup(string fixturePdf) {
    auto dir = makeCheckDir("timeout");
    scope(exit) rmdirRecurse(dir);
    auto heartbeat = buildPath(dir, "heartbeat");
    makeFakeTool(dir, "#!/bin/sh\n" ~
        "hb=\"" ~ heartbeat ~ "\"\n" ~
        "trap '' TERM\n" ~
        "( trap '' TERM; while true; do date +%s%N > \"$hb\" 2>/dev/null; sleep 0.02; done ) &\n" ~
        "sleep 100\n");

    PdfExtractLimits limits;
    limits.wallTimeoutMs = 800;
    const started = MonoTime.currTime;
    auto outcome = extractPdfText(fixturePdf, true, limits, withCoreutils(dir));
    const elapsed = MonoTime.currTime - started;

    check(!outcome.succeeded, "timed-out run reported success");
    check(outcome.failure.reason == PdfExtractFailureReason.timedOut,
        "timed-out run did not report timedOut");
    check(elapsed < 5.seconds, "timeout kill did not bound wall-clock time");

    check(exists(heartbeat), "grandchild never started");
    auto afterKill = timeLastModified(heartbeat);
    Thread.sleep(400.msecs);
    check(timeLastModified(heartbeat) == afterKill,
        "grandchild survived the process-group kill: only the leader was reaped");
}

// ---- Criterion (5): output cap is enforced, not read unbounded. ----

private void checkOutputCapExceeded(string fixturePdf) {
    auto dir = makeCheckDir("outputcap");
    scope(exit) rmdirRecurse(dir);
    // `exec` replaces the shell's own process image with `yes`, so the
    // direct child our fork/waitpid observes is the process that actually
    // hits RLIMIT_FSIZE (rlimits survive exec).
    makeFakeTool(dir, "#!/bin/sh\nexec yes 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' > \"$3\"\n");

    PdfExtractLimits limits;
    limits.maxOutputBytes = 65_536;
    limits.wallTimeoutMs = 10_000;
    auto outcome = extractPdfText(fixturePdf, true, limits, withCoreutils(dir));

    check(!outcome.succeeded, "output-cap-exceeding run reported success");
    check(outcome.failure.reason == PdfExtractFailureReason.outputCapExceeded,
        "output-cap-exceeding run did not report outputCapExceeded");
}

// ---- Criterion (3): real extraction against the frozen fixture. ----

private bool realPdftotextAvailable() {
    foreach (directory; environment.get("PATH", "").split(':'))
        if (directory.length && exists(buildPath(directory, pdfExtractToolName)))
            return true;
    return false;
}

private enum expectedTrainingText = "TRAINING PDF\n\nALPHA ONE\nBETA TWO\n\f";
private enum expectedTrainingSha256 =
    "cc48278691a1ce51c4dbd25914534c9d21fe430b57e8b371aeeb3dead68b75fd";

private bool checkRealExtraction(string fixturePdf) {
    if (!realPdftotextAvailable()) {
        stderr.writeln("SKIPPED: no \"pdftotext\" found on this environment's " ~
            "real PATH -- criterion (3)'s real end-to-end extraction proof " ~
            "was NOT verified here. Every other criterion above (opt-in " ~
            "gate, PATH-lookup install hint, wall-timeout process-group " ~
            "kill, output-cap enforcement) was still verified against a " ~
            "fake tool.");
        return false;
    }

    // No pathOverride: this exercises the real inherited PATH end to end.
    auto outcome = extractPdfText(fixturePdf, true);
    check(outcome.succeeded, "real pdftotext failed against the frozen fixture");
    check(outcome.text == expectedTrainingText,
        "real pdftotext output did not match the pinned frozen-fixture text");
    check(bytesHash(cast(ubyte[]) outcome.text) == expectedTrainingSha256,
        "real pdftotext output hash did not match #67's own pinned observation");

    // Bonus real-tool proof, reusing the frozen malformed fixture: a genuine
    // parse failure is a distinct nonZeroExit, never conflated with success
    // or with toolNotFound.
    auto malformedPath = tsvField("samples.tsv", "pdf-malformed", 0, 4);
    auto malformedOutcome = extractPdfText(buildPath(fixtureRoot, malformedPath), true);
    check(!malformedOutcome.succeeded, "real pdftotext accepted a malformed PDF");
    check(malformedOutcome.failure.reason == PdfExtractFailureReason.nonZeroExit,
        "real pdftotext malformed-input failure was not reported as nonZeroExit");
    return true;
}

void main() {
    auto fixturePdf = verifyFrozenFixtureReused();
    checkDeclinedNeverAttempts(fixturePdf);
    checkPathLookupMissing(fixturePdf);
    checkPathLookupPresent(fixturePdf);
    checkTimeoutKillsWholeGroup(fixturePdf);
    checkOutputCapExceeded(fixturePdf);
    auto realExtractionVerified = checkRealExtraction(fixturePdf);

    writeln("PASS: pdf execve check: ", assertions, " assertions passed; ",
        "real end-to-end extraction against a genuinely installed Poppler ",
        "pdftotext was ", realExtractionVerified ? "VERIFIED" : "NOT AVAILABLE " ~
            "(see SKIPPED message above)", ".");
}
