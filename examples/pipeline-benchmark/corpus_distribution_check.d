// examples/pipeline-benchmark/corpus_distribution_check.d
//
// Issue #422: pins `examples/pipeline-benchmark/corpus/`'s per-page
// selected/quarantined distribution so a future change that flips any
// page's outcome is caught automatically, instead of silently going stale
// until an owner question forces a manual re-verification -- exactly what
// happened twice before this ticket (#411, #412: a hand-maintained "18/20
// pages" / "5/6 phone" citation each drifted unnoticed).
//
// This check does not invent a new pipeline or a new decoding mechanism:
// it runs the exact repro command `docs/html-main-content.md`'s own
// "`examples/pipeline-benchmark` corpus: current 18/20 status" section
// documents (`scrubbed run --stage extract=html-main-content --stage
// pub=document-metadata-publish --explain`) against the real `scrubbed`
// release binary, once per real corpus page, and decodes each page's
// EXPLAIN line the same way `examples/cli/check.d` already parses EXPLAIN
// output (plain tab-separated `key=value`/`key="value"` fields on stdout).
//
// Expected table: the 20-page corpus's real, measured distribution as of
// 2026-09-29 (18 selected, 2 quarantined -- confirmed by a fresh run for
// this ticket, not copied from the possibly-stale doc claim). On any
// mismatch -- a page flips selected<->quarantined, a quarantine reason
// string changes, or the corpus's file set itself changes -- this check
// prints every mismatch as an expected-vs-actual diff and exits non-zero.
//
// Build and run (mirrors examples/cli/check.d's own build shape, per
// docs/cli-commands.md; no internal source/ imports needed since this only
// spawns the release `scrubbed` binary and parses its stdout):
//
//   dub build --compiler=ldc2 --build=release
//   ldc2 -O -release -of=/tmp/corpus-distribution-check \
//     examples/pipeline-benchmark/corpus_distribution_check.d
//   /tmp/corpus-distribution-check [path/to/scrubbed] [path/to/corpus/dir]
//
// Both arguments are optional and default to `./scrubbed` and
// `examples/pipeline-benchmark/corpus`, both resolved relative to the
// current working directory -- run it from the repository root, same as
// examples/cli/check.d and run.sh.
module corpus_distribution_check;

import std.algorithm.iteration : filter, map;
import std.algorithm.searching : canFind, startsWith;
import std.algorithm.sorting : sort;
import std.array : array;
import std.conv : to;
import std.file : SpanMode, dirEntries, exists, mkdirRecurse, rmdirRecurse, tempDir;
import std.path : baseName, buildPath;
import std.process : execute;
import std.stdio : stderr, writefln, writeln;
import std.string : split, strip;
import std.uuid : randomUUID;

private int mismatches;

/// One corpus page's expected outcome. `reason` is only meaningful when
/// `quarantined` is true; a selected page has no quarantine reason.
private struct ExpectedOutcome {
    string file;
    bool quarantined;
    string reason;
}

// Measured directly for this ticket (issue #422), 2026-09-29, against a
// freshly built `dub build --compiler=ldc2 --build=release` binary and the
// real, currently checked-in `examples/pipeline-benchmark/corpus/` files --
// matches docs/html-main-content.md's existing "18/20" claim exactly (no
// drift found at the time this check was written). See that document's
// "`examples/pipeline-benchmark` corpus: current 18/20 status" section for
// the root-cause investigation behind both quarantined pages.
private immutable ExpectedOutcome[] expected = [
    ExpectedOutcome("appen-com.html", false, ""),
    ExpectedOutcome("archiv-krimiblog-de.html", false, ""),
    ExpectedOutcome("deleuze-enacademic-com.html", false, ""),
    ExpectedOutcome("france-attac-org.html", false, ""),
    ExpectedOutcome("jobsnhire-com.html", false, ""),
    ExpectedOutcome("kleinegruenemonster-wordpress-com.html", false, ""),
    ExpectedOutcome("neubau-wsl-ch.html", false, ""),
    ExpectedOutcome("scienceblogs-de.html", true, "nodeLimit"),
    ExpectedOutcome("utopia-de.html", false, ""),
    ExpectedOutcome("world-kbs-co-kr.html", false, ""),
    ExpectedOutcome("www-be-ch.html", false, ""),
    ExpectedOutcome("www-chemietechnik-de.html", false, ""),
    ExpectedOutcome("www-dvgw-de.html", false, ""),
    ExpectedOutcome("www-for-me-online-de.html", false, ""),
    ExpectedOutcome("www-homify-de.html", true, "abstainedBelowThreshold"),
    ExpectedOutcome("www-laweekly-com.html", false, ""),
    ExpectedOutcome("www-munich2022-com.html", false, ""),
    ExpectedOutcome("www-pronats-de.html", false, ""),
    ExpectedOutcome("www-spdfraktion-de.html", false, ""),
    ExpectedOutcome("www-tofugu-com.html", false, ""),
];

private struct ActualOutcome {
    bool quarantined;
    string reason;
    bool decoded; // false if the EXPLAIN line could not be parsed at all
}

/// Pulls `key="value"` or `key=value` out of one EXPLAIN field list (tab-
/// separated, as scrubbed's --explain writer emits it -- see
/// examples/cli/check.d's identical parsing convention for the same wire
/// shape).
private string field(string[] parts, string key) {
    foreach (part; parts) {
        if (!part.startsWith(key ~ "=")) continue;
        auto value = part[key.length + 1 .. $];
        if (value.length >= 2 && value[0] == '"' && value[$ - 1] == '"')
            return value[1 .. $ - 1];
        return value;
    }
    return null;
}

private ActualOutcome runOnePage(string exe, string inputPath, string workDir) {
    auto outputPath = buildPath(workDir, "out");
    auto sidecarPath = buildPath(workDir, "sidecar");
    auto result = execute([exe, "run", "--input", inputPath, "--output", outputPath,
        "--sidecar-output", sidecarPath, "--explain", "--stage",
        "extract=html-main-content", "--stage", "pub=document-metadata-publish",
        "--threads", "1"]);
    string[] explainLines;
    foreach (line; result.output.split("\n"))
        if (line.startsWith("EXPLAIN\t")) explainLines ~= line;
    // The chain here is a single one-to-one stage sequence over a single
    // input document, so exactly one top-level pipeline EXPLAIN line (the
    // "status=..." record) is expected; a successful run additionally
    // prints one side-output EXPLAIN line for the metadata publish sink,
    // which carries no "status=" field and is simply not the one this
    // check decodes.
    foreach (line; explainLines) {
        auto parts = line["EXPLAIN\t".length .. $].split("\t");
        auto statusValue = field(parts, "status");
        if (statusValue is null) continue; // side-output record, not the pipeline one
        ActualOutcome outcome;
        outcome.decoded = true;
        outcome.quarantined = (statusValue == "quarantined");
        if (outcome.quarantined) {
            auto reason = field(parts, "reason");
            outcome.reason = reason is null ? "" : reason;
        }
        return outcome;
    }
    stderr.writefln("corpus_distribution_check: no decodable EXPLAIN status line for %s " ~
        "(exit=%d, output=%s)", inputPath, result.status, result.output);
    return ActualOutcome(false, "", false);
}

private void reportMismatch(string label, string expectedDescription,
        string actualDescription) {
    writefln("MISMATCH %s: expected %s, got %s", label, expectedDescription,
        actualDescription);
    ++mismatches;
}

private string describe(bool quarantined, string reason) {
    return quarantined ? "quarantined(" ~ reason ~ ")" : "selected";
}

void main(string[] args) {
    string exe = args.length > 1 ? args[1] : "./scrubbed";
    string corpusDir = args.length > 2 ? args[2]
        : buildPath("examples", "pipeline-benchmark", "corpus");

    if (!exists(exe)) {
        stderr.writefln("corpus_distribution_check: scrubbed binary not found at %s " ~
            "(build it first: dub build --compiler=ldc2 --build=release)", exe);
        import core.stdc.stdlib : exit;
        exit(2);
    }
    if (!exists(corpusDir)) {
        stderr.writefln("corpus_distribution_check: corpus directory not found at %s",
            corpusDir);
        import core.stdc.stdlib : exit;
        exit(2);
    }

    // Guard against silent corpus drift (a page added, removed, or
    // renamed) separately from per-page outcome drift, so that class of
    // change is also caught loudly rather than just skipped.
    string[] actualFiles = dirEntries(corpusDir, "*.html", SpanMode.shallow)
        .map!(entry => baseName(entry.name)).array;
    actualFiles.sort();
    string[] expectedFiles = expected.map!(e => e.file).array.dup;
    expectedFiles.sort();
    if (actualFiles != expectedFiles) {
        foreach (file; actualFiles)
            if (!expectedFiles.canFind(file))
                reportMismatch(file, "(no expectation on file)",
                    "present in corpus/ but not in this check's expected table");
        foreach (file; expectedFiles)
            if (!actualFiles.canFind(file))
                reportMismatch(file, "present in this check's expected table",
                    "missing from corpus/");
    }

    auto workRoot = buildPath(tempDir, "scrubbed-corpus-distribution-" ~
        randomUUID.toString);
    mkdirRecurse(workRoot);
    scope(exit) if (exists(workRoot)) rmdirRecurse(workRoot);

    size_t checked;
    foreach (item; expected) {
        auto inputPath = buildPath(corpusDir, item.file);
        if (!exists(inputPath)) continue; // already reported above
        auto pageWorkDir = buildPath(workRoot, item.file);
        mkdirRecurse(pageWorkDir);
        auto actual = runOnePage(exe, inputPath, pageWorkDir);
        ++checked;
        if (!actual.decoded) {
            reportMismatch(item.file, describe(item.quarantined, item.reason),
                "no decodable pipeline status (see stderr)");
            continue;
        }
        if (actual.quarantined != item.quarantined || actual.reason != item.reason)
            reportMismatch(item.file, describe(item.quarantined, item.reason),
                describe(actual.quarantined, actual.reason));
    }

    auto selectedCount = expected.filter!(e => !e.quarantined).array.length;
    auto quarantinedCount = expected.length - selectedCount;
    writefln("corpus_distribution_check: checked %d/%d pinned pages " ~
        "(expected distribution: %d selected, %d quarantined)", checked,
        expected.length, selectedCount, quarantinedCount);

    if (mismatches) {
        writefln("corpus_distribution_check: %d mismatch(es) -- the corpus's real " ~
            "pass/fail distribution has drifted from this check's pinned expected " ~
            "table. Update docs/html-main-content.md's \"examples/pipeline-benchmark " ~
            "corpus: current N/20 status\" section and this file's `expected` table " ~
            "together, with a fresh root-cause note for anything newly quarantined.",
            mismatches);
        import core.stdc.stdlib : exit;
        exit(1);
    }
    writeln("corpus_distribution_check: all pinned pages match the real corpus's " ~
        "current per-page outcome");
}
