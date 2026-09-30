/// Release-active(-adjacent), network-free real-fixture regression check for
/// issue #475's comment-section identification/extraction
/// (`effects.html_main_content`'s `commentsExtracted`/`comments` fields and
/// `includeComments` parameter). Unlike `experiments/html_main_content/check.d`
/// (hand-authored synthetic fixtures only), this driver reads real,
/// already-checked-into-this-repo corpus HTML
/// (`examples/pipeline-benchmark/corpus/`, the same 20-page corpus #411's own
/// 20/20 check uses) to satisfy issue #475's own acceptance criterion 2 ("a
/// real fixture with comments correctly separates them from article body; a
/// page with no comments is unaffected") with genuine third-party markup,
/// not synthetic-only fixtures. No network access; every HTML file it reads
/// is already checked into this repository.
///
/// Also emits one JSON line per page (`--json`) so
/// `compare_comments_trafilatura.sh` can compare scrubbed's own
/// comment/non-comment split against a real, pinned trafilatura==2.2.0 run
/// over the identical files (issue #475's acceptance criterion 1).
module experiments.html_main_content.comments_check;

import effects.html_main_content : MainContentResult, MainContentStatus,
    extractMainContent;
import effects.html_tree : defaultExtractHtmlBytes, parseHtml;
import std.algorithm.searching : canFind;
import std.conv : to;
import std.file : readText;
import std.getopt : getopt;
import std.path : buildPath;
import std.stdio : stdout, writeln;

private void need(bool condition, string label) {
    if (!condition) throw new Exception("html-main-content comments check: " ~ label);
}

private struct PageExpectation {
    string file;
    // Ground truth from a direct, real survey of this corpus (see
    // `effects.html_main_content`'s `commentSectionKeywords` doc comment for
    // the exact real markup each page carries) -- not a guess.
    bool expectCommentsExtracted;
    string[] expectedCommentSubstrings; // must appear in .comments when expected
    string[] mustNotLeakIntoMainText;   // must NOT appear in .text
}

private immutable PageExpectation[] expectations = [
    // Real WordPress-style comment threads: <div id="comments"> wrapping one
    // or more real <div id="comment-NNNN">/class="comment*" entries.
    PageExpectation("archiv-krimiblog-de.html", true,
        ["Hamburg feiert CSD"], ["Hamburg feiert CSD"]),
    PageExpectation("kleinegruenemonster-wordpress-com.html", true, [], []),
    // This corpus's largest real comment thread (140 entries, #411's own
    // docs measured this page's node/byte density directly).
    PageExpectation("scienceblogs-de.html", true, [], []),
    // Structurally comment-shaped (`<div class="comments">`) but carries no
    // comment text at all -- both fragment-link anchors are empty. Real,
    // distinct "found but nothing to read" case, not a guess.
    PageExpectation("france-attac-org.html", true, [], []),
    // A "comments" *glyph* icon (`<i class="fa fa-comments">`) inside nav
    // chrome, not a comment section -- must not false-positive.
    PageExpectation("www-tofugu-com.html", false, [], []),
    // No "comment"/"disqus" markup anywhere in this page at all (grep-
    // confirmed against the real file).
    PageExpectation("deleuze-enacademic-com.html", false, [], []),
    PageExpectation("neubau-wsl-ch.html", false, [], []),
    PageExpectation("www-spdfraktion-de.html", false, [], []),
];

private MainContentResult runPage(string root, string file) {
    auto html = readText(buildPath(root, file));
    auto parsed = parseHtml(cast(const(ubyte)[]) html, null, file, defaultExtractHtmlBytes);
    need(parsed.isParsed, file ~ " did not parse");
    return extractMainContent(parsed.tree);
}

void main(string[] args) {
    string root = "examples/pipeline-benchmark/corpus";
    bool json;
    getopt(args, "root", &root, "json", &json);

    foreach (expectation; expectations) {
        auto result = runPage(root, expectation.file);
        need(result.commentsExtracted == expectation.expectCommentsExtracted,
            expectation.file ~ ": expected commentsExtracted=" ~
            to!string(expectation.expectCommentsExtracted) ~ ", got " ~
            to!string(result.commentsExtracted));
        foreach (needle; expectation.expectedCommentSubstrings)
            need(result.comments.canFind(needle),
                expectation.file ~ ": expected comment text to contain \"" ~ needle ~ "\"");
        foreach (needle; expectation.mustNotLeakIntoMainText)
            need(!result.text.canFind(needle),
                expectation.file ~ ": comment text leaked into main content (\"" ~
                needle ~ "\")");

        // Opting out must suppress detection entirely on the same real page,
        // regardless of what markup it actually carries.
        auto html = readText(buildPath(root, expectation.file));
        auto parsed = parseHtml(cast(const(ubyte)[]) html, null, expectation.file,
            defaultExtractHtmlBytes);
        auto optedOut = extractMainContent(parsed.tree, false);
        need(!optedOut.commentsExtracted,
            expectation.file ~ ": includeComments=false must suppress detection");
        need(optedOut.comments.length == 0,
            expectation.file ~ ": includeComments=false must yield empty comments text");
        // The opt-out must not perturb main-content selection itself.
        need(optedOut.status == result.status && optedOut.node == result.node &&
            optedOut.score == result.score && optedOut.text == result.text,
            expectation.file ~ ": includeComments must not change main-content selection");

        if (json) {
            stdout.writefln(
                `{"page":"%s","commentsExtracted":%s,"commentsLength":%d,"status":"%s"}`,
                expectation.file, result.commentsExtracted, result.comments.length,
                result.status);
        }
    }
    if (!json) writeln("html-main-content comments check: all real-fixture expectations held");
}
